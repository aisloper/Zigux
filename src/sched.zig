//! Порт EEVDF-планировщика Linux 7.3 (kernel/sched/fair.c, core.c) на Zig.
//! В 7.3 уже нет классического CFS с min_vruntime в cfs_rq: дерево
//! отсортировано по deadline, curr живёт вне дерева, выбор — минимальный
//! deadline среди элигибльных (lag >= 0). Аугментация min_vruntime используется
//! для отсечения неэлигибльных поддеревьев.
//! Опущены: PELT, group scheduling, bandwidth, sched_delayed, NUMA.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const rb = @import("rbtree.zig");

pub const NICE_0_LOAD: u64 = 1024;
pub const BASE_SLICE_NS: u64 = 700_000; // sysctl_sched_base_slice
pub const TICK_NSEC: u64 = 1_000_000;

/// kernel/sched/core.c: __sched_prio_to_weight[nice + 20]
pub const sched_prio_to_weight = [40]u32{
    88761, 71755, 56483, 46273, 36291, 29154, 23254, 18705, 14949, 11916,
    9548,  7620,  6100,  4904,  3906,  3121,  2501,  1991,  1586,  1277,
    1024,  820,   655,   526,   423,   335,   272,   215,   172,   137,
    110,   87,    70,    56,    45,    36,    29,    23,    18,    15,
};

pub fn niceToWeight(nice: i8) u64 {
    const idx: usize = @intCast(@as(i16, nice) + 20);
    return sched_prio_to_weight[@min(idx, 39)];
}

pub const LoadWeight = struct {
    weight: u64 = NICE_0_LOAD,
};

pub const SchedEntity = struct {
    run_node: rb.Node = .{},
    load: LoadWeight = .{},
    h_load: LoadWeight = .{},

    vruntime: u64 = 0,
    deadline: u64 = 0,
    vlag: i64 = 0,
    vprot: u64 = 0,

    min_vruntime: u64 = 0, // аугментация поддерева
    min_slice: u64 = 0,
    max_slice: u64 = 0,
    slice: u64 = 0,

    exec_start: u64 = 0,
    sum_exec_runtime: u64 = 0,
    on_rq: bool = false,

    pub fn setLoadWeight(self: *SchedEntity, nice: i8) void {
        const w = niceToWeight(nice);
        self.load.weight = w;
        self.h_load.weight = w; // плоский порт: h_load == load
    }
};

pub const TaskState = enum { ready, running, blocked, exited };

pub const Task = struct {
    pid: u32,
    comm: []const u8 = "",
    se: SchedEntity = .{},
    state: TaskState = .ready,
};

inline fn vruntimeCmp(a: u64, b: u64) i64 {
    return @bitCast(a -% b);
}

inline fn key(c: *const CfsRq, vruntime: u64) i64 {
    return @bitCast(vruntime -% c.zero_vruntime);
}

fn seFromNode(n: *rb.Node) *SchedEntity {
    return @fieldParentPtr("run_node", n);
}

fn augmentCopy(ctx: ?*anyopaque, dst: *rb.Node, src: *rb.Node) void {
    _ = ctx;
    const d = seFromNode(dst);
    const s = seFromNode(src);
    d.min_vruntime = s.min_vruntime;
    d.min_slice = s.min_slice;
    d.max_slice = s.max_slice;
}

fn augmentPropagate(ctx: ?*anyopaque, node: *rb.Node) void {
    _ = ctx;
    const se = seFromNode(node);
    var m = se.vruntime;
    if (node.left) |l| m = @min(m, seFromNode(l).min_vruntime);
    if (node.right) |r| m = @min(m, seFromNode(r).min_vruntime);
    se.min_vruntime = m;
}

fn augmentRotate(ctx: ?*anyopaque, old: *rb.Node, new: *rb.Node) void {
    _ = old;
    augmentPropagate(ctx, new);
}

fn entityBefore(a: *rb.Node, b: *rb.Node) bool {
    return vruntimeCmp(seFromNode(a).deadline, seFromNode(b).deadline) < 0;
}

pub const CfsRq = struct {
    timeline: rb.Tree,
    curr: ?*SchedEntity = null,
    load: u64 = 0,
    nr_queued: usize = 0,
    sum_weight: u64 = 0,
    sum_w_vruntime: i128 = 0,
    zero_vruntime: u64 = 0,
    need_resched: bool = false,

    pub fn init() CfsRq {
        return .{ .timeline = rb.Tree.init(.{
            .copy = augmentCopy,
            .propagate = augmentPropagate,
            .rotate = augmentRotate,
        }) };
    }

    pub fn nrRunning(self: *const CfsRq) usize {
        return self.nr_queued + @as(usize, if (self.curr != null) 1 else 0);
    }

    pub fn calcDeltaFair(delta: u64, se: *const SchedEntity) u64 {
        const w = se.h_load.weight;
        if (w == NICE_0_LOAD) return delta;
        return (delta * NICE_0_LOAD) / w;
    }

    /// avg_vruntime(): одновременно сдвигает zero_vruntime (clear).
    pub fn avgVruntime(self: *CfsRq) u64 {
        var w: u64 = self.sum_weight;
        var s: i128 = self.sum_w_vruntime;
        if (self.curr) |cur| {
            s += @as(i128, key(self, cur.vruntime)) * @as(i128, cur.h_load.weight);
            w += cur.h_load.weight;
        }
        if (w == 0) return self.zero_vruntime;
        const d: i64 = @intCast(@divFloor(s, @as(i128, w)));
        self.sum_w_vruntime -= @as(i128, w) * d;
        self.zero_vruntime +%= @as(u64, @bitCast(d));
        return self.zero_vruntime;
    }

    pub fn isEligible(self: *CfsRq, vruntime: u64) bool {
        var w: u64 = self.sum_weight;
        var s: i128 = self.sum_w_vruntime;
        if (self.curr) |cur| {
            s += @as(i128, key(self, cur.vruntime)) * @as(i128, cur.h_load.weight);
            w += cur.h_load.weight;
        }
        return s >= @as(i128, key(self, vruntime)) * @as(i128, w);
    }

    /// update_curr() + update_deadline() из fair.c.
    pub fn updateCurr(self: *CfsRq, now: u64) void {
        const cur = self.curr orelse return;
        // arch-таймер и тик-хук могут обновить accounting раньше, чем вызывающий
        // поток доберётся до schedule(); не допускаем ")время назад" в u64.
        if (now <= cur.exec_start) return;
        const delta = now - cur.exec_start;
        cur.exec_start = now;
        cur.sum_exec_runtime +%= delta;
        cur.vruntime +%= calcDeltaFair(delta, cur);
        if (vruntimeCmp(cur.vruntime, cur.deadline) >= 0) {
            cur.slice = BASE_SLICE_NS;
            cur.deadline = cur.vruntime +% calcDeltaFair(cur.slice, cur);
            self.need_resched = true;
        }
        if (self.nr_queued > 1 and vruntimeCmp(cur.vruntime, cur.vprot) >= 0) {
            self.need_resched = true;
        }
    }

    fn placeEntity(self: *CfsRq, se: *SchedEntity, initial: bool) void {
        const V = self.avgVruntime();
        se.slice = BASE_SLICE_NS;
        var vs = calcDeltaFair(se.slice, se);
        if (initial) vs /= 2;
        var lag = se.vlag;
        if (self.nr_queued > 0 and lag != 0) {
            const W = self.sum_weight + (if (self.curr) |c| c.h_load.weight else 0);
            if (W > 0) lag += @divTrunc(lag * @as(i64, @intCast(se.h_load.weight)), @as(i64, @intCast(W)));
        }
        se.vruntime = V -% @as(u64, @bitCast(lag));
        se.deadline = se.vruntime +% vs;
        se.min_vruntime = se.vruntime;
        se.min_slice = se.slice;
        se.max_slice = se.slice;
    }

    fn accountEntityEnqueue(self: *CfsRq, se: *SchedEntity) void {
        self.sum_w_vruntime += @as(i128, key(self, se.vruntime)) * @as(i128, se.h_load.weight);
        self.sum_weight += se.h_load.weight;
        self.nr_queued += 1;
        se.on_rq = true;
        self.timeline.insert(&se.run_node, entityBefore);
    }

    pub fn enqueueEntity(self: *CfsRq, se: *SchedEntity, now: u64, initial: bool) void {
        self.updateCurr(now);
        self.load += se.load.weight;
        self.placeEntity(se, initial);
        self.accountEntityEnqueue(se);
    }

    fn updateEntityLag(self: *CfsRq, se: *SchedEntity) void {
        const V = self.avgVruntime();
        const limit = calcDeltaFair(se.max_slice + TICK_NSEC, se);
        const lag = key(self, V) - key(self, se.vruntime);
        const lim: i64 = @intCast(@min(limit, std.math.maxInt(i64)));
        se.vlag = std.math.clamp(lag, -lim, lim);
    }

    pub fn dequeueEntity(self: *CfsRq, se: *SchedEntity, now: u64) void {
        self.updateCurr(now);
        self.updateEntityLag(se);
        if (self.curr == se) {
            self.curr = null;
        } else {
            self.timeline.erase(&se.run_node);
            self.sum_w_vruntime -= @as(i128, key(self, se.vruntime)) * @as(i128, se.h_load.weight);
            self.sum_weight -= se.h_load.weight;
            self.nr_queued -= 1;
        }
        self.load -= se.load.weight;
        se.on_rq = false;
        se.deadline -%= se.vruntime; // rel_deadline
    }

    /// set_next_task_fair(): текущая сущность уходит из дерева.
    pub fn setNextEntity(self: *CfsRq, se: *SchedEntity, now: u64) void {
        if (self.curr == se) return; // тот же tasks Continues, accounting не трогаем
        if (se.on_rq) {
            // curr не хранится в дереве и не входит в sum_weight/nr_queued;
            // avg_vruntime() добавляет его ad hoc.
            self.timeline.erase(&se.run_node);
            self.sum_w_vruntime -= @as(i128, key(self, se.vruntime)) * @as(i128, se.h_load.weight);
            self.sum_weight -= se.h_load.weight;
            self.nr_queued -= 1;
        }
        se.exec_start = now;
        se.vprot = se.deadline;
        self.curr = se;
    }

    /// pick_eevdf(): минимальный deadline среди элигибльных.
    pub fn pickNextEntity(self: *CfsRq) ?*SchedEntity {
        if (self.nr_queued == 0) return self.curr;
        if (self.nr_queued == 1) {
            const first = self.timeline.minimum() orelse return self.curr;
            return seFromNode(first);
        }
        if (self.curr) |cur| {
            if (!self.isEligible(cur.vruntime)) self.curr = null;
        }
        if (self.curr) |cur| {
            if (vruntimeCmp(cur.vruntime, cur.vprot) < 0) return cur; // защита среза
        }
        const left = self.timeline.minimum() orelse return self.curr;
        if (self.isEligible(seFromNode(left).vruntime)) return seFromNode(left);
        var n = self.timeline.root;
        while (n) |node| {
            if (node.left) |l| {
                if (self.isEligible(seFromNode(l).min_vruntime)) {
                    n = l;
                    continue;
                }
            }
            const se = seFromNode(node);
            if (self.isEligible(se.vruntime)) return se;
            n = node.right;
        }
        return self.curr;
    }

    /// Один тик: вернуть true, если нужно переключиться.
    pub fn entityTick(self: *CfsRq, now: u64) bool {
        self.updateCurr(now);
        return self.need_resched;
    }

    /// __schedule(): put_prev → pick → set_next (порядок как в kernel/sched/core.c).
    pub fn schedule(self: *CfsRq, now: u64) ?*SchedEntity {
        self.updateCurr(now);
        const prev = self.curr;
        self.curr = null;
        if (prev) |p| self.accountEntityEnqueue(p);
        const next = self.pickNextEntity() orelse prev;
        self.need_resched = false;
        if (next) |n| self.setNextEntity(n, now);
        return next;
    }
};

test "niceToWeight table" {
    try std.testing.expect(niceToWeight(-20) > niceToWeight(0));
    try std.testing.expectEqual(@as(u64, 1024), niceToWeight(0));
    try std.testing.expect(niceToWeight(19) < niceToWeight(0));
}

test "per-CPU runqueues are independent EEVDF instances" {
    var rq0 = CfsRq.init();
    var rq1 = CfsRq.init();
    var se0 = SchedEntity{ .exec_start = 1000 };
    var se1 = SchedEntity{ .exec_start = 2000 };
    se0.setLoadWeight(0);
    se1.setLoadWeight(0);

    rq0.enqueueEntity(&se0, 1000, true);
    rq1.enqueueEntity(&se1, 2000, true);
    try std.testing.expectEqual(@as(usize, 1), rq0.nr_queued);
    try std.testing.expectEqual(@as(usize, 1), rq1.nr_queued);

    const next0 = rq0.schedule(1000) orelse return error.TestExpectedEntity;
    const next1 = rq1.schedule(2000) orelse return error.TestExpectedEntity;
    try std.testing.expectEqual(&se0, next0);
    try std.testing.expectEqual(&se1, next1);
    try std.testing.expectEqual(@as(usize, 0), rq0.nr_queued);
    try std.testing.expectEqual(@as(usize, 0), rq1.nr_queued);
}

test "updateCurr ignores non-monotonic timestamps" {
    // Тик из IDT и вызов schedule() могут дать метки в разном порядке;
    // accounting не должен превратить now < exec_start в огромный delta.
    var rq = CfsRq.init();
    var se = SchedEntity{ .exec_start = 1000 };
    rq.curr = &se;

    rq.updateCurr(900);
    try std.testing.expectEqual(@as(u64, 1000), se.exec_start);
    try std.testing.expectEqual(@as(u64, 0), se.sum_exec_runtime);

    rq.updateCurr(1100);
    try std.testing.expectEqual(@as(u64, 100), se.sum_exec_runtime);
    try std.testing.expectEqual(@as(u64, 1100), se.exec_start);
}

test "EEVDF: high priority task gets more CPU time" {
    var cfs = CfsRq.init();
    var tasks: [4]Task = .{
        .{ .pid = 1, .comm = "high" },
        .{ .pid = 2, .comm = "normal1" },
        .{ .pid = 3, .comm = "normal2" },
        .{ .pid = 4, .comm = "low" },
    };
    const nices = [4]i8{ -10, 0, 0, 10 };
    for (&tasks, nices) |*t, nice| {
        t.se.setLoadWeight(nice);
        cfs.enqueueEntity(&t.se, 0, true);
    }
    var now: u64 = 0;
    _ = cfs.schedule(now);
    var ticks: [4]u64 = .{ 0, 0, 0, 0 };
    for (0..2000) |_| {
        now += TICK_NSEC;
        if (cfs.entityTick(now)) _ = cfs.schedule(now);
        for (&tasks, 0..) |*t, i| {
            if (cfs.curr == &t.se) ticks[i] += TICK_NSEC;
        }
    }
    // Соотношение CPU-времени ≈ 9548:1024:1024:110 (веса nice -10/0/0/+10).
    try std.testing.expect(ticks[0] > ticks[1] * 7);
    try std.testing.expect(ticks[1] > ticks[3] * 5);
    try std.testing.expect(ticks[1] > 0);
    try std.testing.expect(ticks[2] > 0);
    try std.testing.expect(ticks[3] > 0);
    try std.testing.expect(cfs.nrRunning() == 4);
}
