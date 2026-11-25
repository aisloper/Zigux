//! Порт fq_codel Linux 7.3: стохастическое разбиение на очереди потоков, два
//! списка round-robin (новые/старые), дефицит и CoDel AQM из include/net/codel*.h.
//! Источники: net/sched/sch_fq_codel.c, include/net/codel.h,
//! include/net/codel_impl.h. GPL-2.0-only (алгоритмы и константы Linux).
const std = @import("std");
const skb = @import("skb.zig");

pub const CODEL_SHIFT: u5 = 10;
pub const DEFAULT_LIMIT: usize = 10 * 1024;
pub const DEFAULT_FLOWS: usize = 1024;
pub const DEFAULT_MEMORY_LIMIT: usize = 32 << 20;
pub const DEFAULT_DROP_BATCH: usize = 64;
pub const DEFAULT_QUANTUM: usize = 1500;
pub const CODEL_MAX_DROPS_PER_DEQUEUE: usize = 256;

pub fn msToTime(ms: u32) u32 {
    return (ms * 1_000_000) >> CODEL_SHIFT;
}

pub const DEFAULT_TARGET: u32 = msToTime(5);
pub const DEFAULT_INTERVAL: u32 = msToTime(100);

pub fn timeAfter(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) > 0;
}

pub fn timeAfterEq(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) >= 0;
}

pub fn timeBefore(a: u32, b: u32) bool {
    return timeAfter(b, a);
}

pub fn reciprocalScale(a: u32, b: u32) u32 {
    return @truncate((@as(u64, a) * @as(u64, b)) >> 32);
}

pub const Params = struct {
    target: u32 = DEFAULT_TARGET,
    interval: u32 = DEFAULT_INTERVAL,
    mtu: usize = DEFAULT_QUANTUM,
    ecn: bool = true,
};

pub const Vars = struct {
    count: u32 = 0,
    lastcount: u32 = 0,
    dropping: bool = false,
    /// Q0.16 обратный корень из count; ~0 >> 16 в Linux.
    rec_inv_sqrt: u16 = 0xffff,
    first_above_time: u32 = 0,
    drop_next: u32 = 0,
    ldelay: u32 = 0,

    pub fn newtonStep(self: *Vars) void {
        const invsqrt: u32 = @as(u32, self.rec_inv_sqrt) << 16;
        const invsqrt2: u32 = @truncate((@as(u64, invsqrt) * invsqrt) >> 32);
        const product = @as(u64, self.count) * invsqrt2;
        const ceiling: u64 = @as(u64, 3) << 32;
        // Linux использует беззнаковое вычитание с переполнением: повторяем
        // его поведение для больших count вместо усечения результата.
        const val64: u64 = ceiling -% product;
        const val = ((val64 >> 2) *% invsqrt) >> 31;
        self.rec_inv_sqrt = @truncate(val >> 16);
    }

    pub fn controlLaw(self: *const Vars, t: u32, interval: u32) u32 {
        const scaled = reciprocalScale(interval, @as(u32, self.rec_inv_sqrt) << 16);
        return t +% @max(@as(u32, 1), scaled);
    }
};

pub const Stats = struct {
    qlen: usize = 0,
    backlog: usize = 0,
    memory_usage: usize = 0,
    maxpacket: usize = 0,
    drop_count: usize = 0,
    drop_len: usize = 0,
    ecn_mark: usize = 0,
    overlimit: usize = 0,
};

const FlowState = enum { none, new, old };

const Queued = struct {
    packet: *skb.SkBuff,
    enqueue_time: u32,
};

const Flow = struct {
    queue: std.ArrayList(Queued) = .empty,
    cvars: Vars = .{},
    deficit: isize = 0,
    backlog: usize = 0,
    state: FlowState = .none,
};

/// `struct fq_codel_sched_data` в минимальном faithful-подмножестве:
/// классификация по skb->priority вместо внешнего tc-фильтра, без gso_skb
/// и tc-действий; учёт памяти на поток упрощён: truesize заменён длиной пакета.
pub const FqCodel = struct {
    allocator: std.mem.Allocator,
    flows: []Flow,
    new_flows: std.ArrayList(usize) = .empty,
    old_flows: std.ArrayList(usize) = .empty,
    params: Params = .{},
    stats: Stats = .{},
    limit: usize = DEFAULT_LIMIT,
    memory_limit: usize = DEFAULT_MEMORY_LIMIT,
    drop_batch_size: usize = DEFAULT_DROP_BATCH,
    quantum: usize = DEFAULT_QUANTUM,
    now: u32 = 0,

    pub fn init(allocator: std.mem.Allocator, flows_count: usize) !FqCodel {
        const flows = try allocator.alloc(Flow, flows_count);
        for (flows) |*flow| flow.* = .{};
        return .{ .allocator = allocator, .flows = flows };
    }

    pub fn deinit(self: *FqCodel) void {
        for (self.flows) |*flow| {
            for (flow.queue.items) |q| q.packet.free();
            flow.queue.deinit(self.allocator);
        }
        self.new_flows.deinit(self.allocator);
        self.old_flows.deinit(self.allocator);
        self.allocator.free(self.flows);
    }

    pub fn setNow(self: *FqCodel, now: u32) void {
        self.now = now;
    }

    pub fn hashPriority(priority: u32) u32 {
        return priority *% 0x9e3779b9;
    }

    pub fn flowFor(self: *const FqCodel, priority: u32) usize {
        return reciprocalScale(hashPriority(priority), @intCast(self.flows.len));
    }

    fn removeFlow(self: *FqCodel, idx: usize) void {
        const flow = &self.flows[idx];
        const list = switch (flow.state) {
            .new => &self.new_flows,
            .old => &self.old_flows,
            .none => return,
        };
        for (list.items, 0..) |item, i| {
            if (item == idx) {
                _ = list.orderedRemove(i);
                break;
            }
        }
        flow.state = .none;
    }

    fn moveToOld(self: *FqCodel, idx: usize) !void {
        self.removeFlow(idx);
        try self.old_flows.append(self.allocator, idx);
        self.flows[idx].state = .old;
    }

    fn takeHead(self: *FqCodel, idx: usize) ?Queued {
        const flow = &self.flows[idx];
        if (flow.queue.items.len == 0) return null;
        const q = flow.queue.orderedRemove(0);
        const len = q.packet.len();
        flow.backlog -= len;
        self.stats.qlen -= 1;
        self.stats.backlog -= len;
        self.stats.memory_usage -= len;
        return q;
    }

    fn dropPacket(self: *FqCodel, packet: *skb.SkBuff) void {
        self.stats.drop_len += packet.len();
        self.stats.drop_count += 1;
        packet.free();
    }

    /// fq_codel_drop(): найти «толстый» поток и выбросить половину его очереди.
    pub fn dropFatFlow(self: *FqCodel) usize {
        var idx: usize = 0;
        var max_backlog: usize = 0;
        for (self.flows, 0..) |flow, i| {
            if (flow.backlog > max_backlog) {
                max_backlog = flow.backlog;
                idx = i;
            }
        }
        const threshold = max_backlog >> 1;
        var dropped: usize = 0;
        var len: usize = 0;
        // do-while из fq_codel_drop(): первый пакет удаляется даже при
        // нулевом пороге, затем удаление идёт до половины backlog или лимита.
        while (true) {
            const q = self.takeHead(idx) orelse break;
            len += q.packet.len();
            self.dropPacket(q.packet);
            dropped += 1;
            if (dropped >= self.drop_batch_size or len >= threshold) break;
        }
        self.flows[idx].cvars.count +%= @truncate(dropped);
        self.stats.overlimit += dropped;
        return dropped;
    }

    pub fn enqueue(self: *FqCodel, packet: *skb.SkBuff) !usize {
        const idx = self.flowFor(packet.priority);
        const flow = &self.flows[idx];
        try flow.queue.append(self.allocator, .{ .packet = packet, .enqueue_time = self.now });
        const len = packet.len();
        flow.backlog += len;
        self.stats.qlen += 1;
        self.stats.backlog += len;
        self.stats.memory_usage += len;
        if (flow.state == .none) {
            flow.state = .new;
            try self.new_flows.append(self.allocator, idx);
            flow.deficit = @intCast(self.quantum);
        }
        if (self.stats.qlen <= self.limit and self.stats.memory_usage <= self.memory_limit)
            return 0;
        return self.dropFatFlow();
    }

    fn shouldDrop(self: *FqCodel, idx: usize, enqueue_time: u32) bool {
        const cvars = &self.flows[idx].cvars;
        cvars.ldelay = self.now -% enqueue_time;
        if (cvars.ldelay < self.params.target or self.stats.backlog <= self.params.mtu) {
            cvars.first_above_time = 0;
            return false;
        }
        if (cvars.first_above_time == 0) {
            cvars.first_above_time = self.now +% self.params.interval;
            return false;
        }
        return timeAfter(self.now, cvars.first_above_time);
    }

    /// codel_dequeue(): CoDel на голове одного потока; текущее время задаётся
    /// тестом или загрузочной пробой.
    pub fn codelDequeue(self: *FqCodel, idx: usize) ?*skb.SkBuff {
        const flow = &self.flows[idx];
        if (flow.queue.items.len == 0) {
            flow.cvars.first_above_time = 0;
            flow.cvars.dropping = false;
            return null;
        }
        var q = self.takeHead(idx).?;
        var packet = q.packet;
        var drop = self.shouldDrop(idx, q.enqueue_time);

        if (flow.cvars.dropping) {
            if (!drop) {
                flow.cvars.dropping = false;
            } else if (timeAfterEq(self.now, flow.cvars.drop_next)) {
                var drops: usize = 0;
                while (flow.cvars.dropping and timeAfterEq(self.now, flow.cvars.drop_next)) {
                    drops += 1;
                    if (drops > CODEL_MAX_DROPS_PER_DEQUEUE) {
                        flow.cvars.drop_next = flow.cvars.controlLaw(self.now, self.params.interval);
                        break;
                    }
                    flow.cvars.count +%= 1;
                    flow.cvars.newtonStep();
                    if (self.params.ecn and packet.ecn_capable) {
                        packet.ecn_ce = true;
                        self.stats.ecn_mark += 1;
                        flow.cvars.drop_next = flow.cvars.controlLaw(flow.cvars.drop_next, self.params.interval);
                        break;
                    }
                    self.dropPacket(packet);
                    const next = self.takeHead(idx) orelse return null;
                    q = next;
                    packet = q.packet;
                    drop = self.shouldDrop(idx, q.enqueue_time);
                    if (!drop) {
                        flow.cvars.dropping = false;
                    } else {
                        flow.cvars.drop_next = flow.cvars.controlLaw(flow.cvars.drop_next, self.params.interval);
                    }
                }
            }
        } else if (drop) {
            if (self.params.ecn and packet.ecn_capable) {
                packet.ecn_ce = true;
                self.stats.ecn_mark += 1;
            } else {
                self.dropPacket(packet);
                const next = self.takeHead(idx) orelse return null;
                q = next;
                packet = q.packet;
                drop = self.shouldDrop(idx, q.enqueue_time);
            }
            flow.cvars.dropping = true;
            const delta = flow.cvars.count -% flow.cvars.lastcount;
            if (delta > 1 and timeBefore(self.now -% flow.cvars.drop_next, 16 * self.params.interval)) {
                flow.cvars.count = delta;
                flow.cvars.newtonStep();
            } else {
                flow.cvars.count = 1;
                flow.cvars.rec_inv_sqrt = 0xffff;
            }
            flow.cvars.lastcount = flow.cvars.count;
            flow.cvars.drop_next = flow.cvars.controlLaw(self.now, self.params.interval);
        }
        if (packet.len() > self.stats.maxpacket) self.stats.maxpacket = packet.len();
        return packet;
    }

    /// __fq_codel_dequeue(): новые потоки имеют приоритет; исчерпавший
    /// дефицит поток получает квоту и переходит в список старых потоков.
    pub fn dequeue(self: *FqCodel) ?*skb.SkBuff {
        while (true) {
            const from_new = self.new_flows.items.len != 0;
            const list = if (from_new) &self.new_flows else &self.old_flows;
            if (list.items.len == 0) return null;
            const idx = list.items[0];
            const flow = &self.flows[idx];
            if (flow.deficit <= 0) {
                flow.deficit += @intCast(self.quantum);
                self.moveToOld(idx) catch return null;
                continue;
            }
            const packet = self.codelDequeue(idx) orelse {
                if (from_new and self.old_flows.items.len != 0) {
                    self.moveToOld(idx) catch return null;
                } else {
                    self.removeFlow(idx);
                }
                continue;
            };
            flow.deficit -= @intCast(packet.len());
            return packet;
        }
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    hash: bool = false,
    round_robin: bool = false,
    deficit: bool = false,
    codel: bool = false,
    ecn: bool = false,
    overlimit: bool = false,
    drops: usize = 0,
    marks: usize = 0,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    var q = try FqCodel.init(allocator, 4);
    defer q.deinit();
    q.limit = 4;
    q.memory_limit = 64;
    q.quantum = 8;
    q.drop_batch_size = 2;
    q.params.target = 4;
    q.params.interval = 8;
    q.params.mtu = 0;

    var packets: [8]*skb.SkBuff = undefined;
    for (&packets) |*slot| slot.* = try skb.SkBuff.alloc(allocator, 16, 0);
    var returned: std.ArrayList(*skb.SkBuff) = .empty;
    defer {
        for (returned.items) |packet| packet.free();
        returned.deinit(allocator);
    }
    for (&packets, 0..) |*slot, i| {
        slot.*.priority = @intCast(i);
        slot.*.ecn_capable = i == 2;
        _ = try slot.*.put(&[_]u8{@intCast('a' + i)});
    }

    p.hash = q.flowFor(0) != q.flowFor(1) and q.flowFor(1) != q.flowFor(3) and
        q.flowFor(3) != q.flowFor(4);
    q.setNow(0);
    _ = try q.enqueue(packets[0]);
    _ = try q.enqueue(packets[1]);
    _ = try q.enqueue(packets[2]);
    p.round_robin = q.new_flows.items.len == 2;
    p.deficit = q.flows[q.flowFor(0)].deficit == 8;

    // Первое извлечение только открывает интервал CoDel (first_above_time).
    q.setNow(10);
    if (q.dequeue()) |packet| {
        try returned.append(allocator, packet);
    }
    // Второе извлечение: время в очереди 20 больше целевого, интервал истёк → ECN.
    q.setNow(20);
    if (q.dequeue()) |packet| {
        p.ecn = packet.ecn_ce;
        try returned.append(allocator, packet);
    }
    p.codel = q.stats.ecn_mark > 0;

    // Переполнение лимита: fq_codel_drop() выбирает самый «толстый» поток.
    for ([_]usize{ 3, 4, 5, 6, 7 }) |i| _ = try q.enqueue(packets[i]);
    p.overlimit = q.stats.overlimit > 0;
    p.drops = q.stats.drop_count;
    p.marks = q.stats.ecn_mark;
    p.status = "ok";
    return p;
}

test "codel: wrap-safe time comparisons and control law" {
    try std.testing.expect(timeAfter(5, 4));
    try std.testing.expect(!timeAfter(4, 5));
    try std.testing.expect(timeAfterEq(5, 5));
    try std.testing.expect(timeBefore(4, 5));
    var v = Vars{};
    try std.testing.expectEqual(@as(u16, 0xffff), v.rec_inv_sqrt);
    try std.testing.expectEqual(@as(u32, 109), v.controlLaw(10, 100));
    v.count = 4;
    v.newtonStep();
    try std.testing.expect(v.rec_inv_sqrt < 0xffff);
}

test "fq_codel: flow hash, round-robin and deficit are Linux-compatible" {
    const a = std.testing.allocator;
    var q = try FqCodel.init(a, 4);
    defer q.deinit();
    q.quantum = 8;
    const first = try skb.SkBuff.alloc(a, 8, 0);
    defer first.free();
    first.priority = 0;
    _ = try first.put("x");
    const second = try skb.SkBuff.alloc(a, 8, 0);
    second.priority = 1;
    _ = try second.put("y");
    try std.testing.expect(q.flowFor(0) != q.flowFor(1));
    _ = try q.enqueue(first);
    _ = try q.enqueue(second);
    try std.testing.expectEqual(@as(usize, 2), q.new_flows.items.len);
    try std.testing.expectEqual(@as(isize, 8), q.flows[q.flowFor(0)].deficit);
    try std.testing.expect(q.dequeue() != null);
    try std.testing.expectEqual(@as(isize, 7), q.flows[q.flowFor(0)].deficit);
}

test "fq_codel: boot probe exercises CoDel, ECN and overlimit" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.hash);
    try std.testing.expect(p.round_robin);
    try std.testing.expect(p.deficit);
    try std.testing.expect(p.codel);
    try std.testing.expect(p.ecn);
    try std.testing.expect(p.overlimit);
    try std.testing.expectEqual(@as(usize, 2), p.drops);
    try std.testing.expectEqual(@as(usize, 1), p.marks);
}
