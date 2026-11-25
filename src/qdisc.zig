//! Порт queueing discipline Linux 7.3: `struct Qdisc`, трёхполосный
//! `pfifo_fast` с `sch_default_prio2band` и статистикой `qlen`/`backlog`/drops.
//! Источники: include/uapi/linux/pkt_sched.h, include/net/sch_generic.h,
//! net/sched/sch_generic.c (pfifo_fast_enqueue/dequeue). GPL-2.0-only.
const std = @import("std");
const skb = @import("skb.zig");

pub const TC_PRIO_BESTEFFORT: u32 = 0;
pub const TC_PRIO_FILLER: u32 = 1;
pub const TC_PRIO_BULK: u32 = 2;
pub const TC_PRIO_INTERACTIVE: u32 = 3;
pub const TC_PRIO_CONTROL: u32 = 7;
pub const TC_PRIO_MAX: u32 = 15;

pub const PFIFO_FAST_BANDS: usize = 3;
pub const DEFAULT_LIMIT: usize = 1000;

/// net/sched/sch_generic.c: sch_default_prio2band[TC_PRIO_MAX + 1].
pub const default_prio2band = [16]u8{ 1, 2, 2, 2, 1, 2, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 };

pub const Stats = struct {
    qlen: usize = 0,
    backlog: usize = 0,
    enqueued: usize = 0,
    dequeued: usize = 0,
    drops: usize = 0,
};

/// `struct Qdisc` в минимальном faithful-подмножестве: три FIFO-полосы,
/// приоритет берётся из skb->priority, очередь переполняется по qlen.
pub const Qdisc = struct {
    allocator: std.mem.Allocator,
    bands: [PFIFO_FAST_BANDS]std.ArrayList(*skb.SkBuff) = .{ .empty, .empty, .empty },
    limit: usize = DEFAULT_LIMIT,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) Qdisc {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Qdisc) void {
        for (&self.bands) |*band| band.deinit(self.allocator);
    }

    pub fn bandFor(priority: u32) usize {
        return default_prio2band[priority & TC_PRIO_MAX];
    }

    /// pfifo_fast_enqueue(): при qlen >= limit пакет дропается и считается.
    pub fn enqueue(self: *Qdisc, packet: *skb.SkBuff) !void {
        const band = bandFor(packet.priority);
        if (self.stats.qlen >= self.limit) {
            self.stats.drops += 1;
            return error.Dropped;
        }
        try self.bands[band].append(self.allocator, packet);
        self.stats.qlen += 1;
        self.stats.backlog += packet.len();
        self.stats.enqueued += 1;
    }

    /// pfifo_fast_dequeue(): полосы обходятся от 0 (highest priority) до 2.
    pub fn dequeue(self: *Qdisc) ?*skb.SkBuff {
        for (&self.bands) |*band| {
            if (band.items.len == 0) continue;
            const packet = band.orderedRemove(0);
            self.stats.qlen -= 1;
            self.stats.backlog -= packet.len();
            self.stats.dequeued += 1;
            return packet;
        }
        return null;
    }

    pub fn peek(self: *const Qdisc) ?*skb.SkBuff {
        for (&self.bands) |*band| {
            if (band.items.len != 0) return band.items[0];
        }
        return null;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    priority: bool = false,
    order: bool = false,
    limit: bool = false,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    var q = Qdisc.init(allocator);
    defer q.deinit();
    q.limit = 2;

    var packets: [3]*skb.SkBuff = undefined;
    for (&packets) |*slot| slot.* = try skb.SkBuff.alloc(allocator, 16, 0);
    defer for (&packets) |*slot| slot.*.free();
    packets[0].priority = TC_PRIO_BULK;
    packets[1].priority = TC_PRIO_CONTROL;
    packets[2].priority = TC_PRIO_BESTEFFORT;
    for (0..3) |i| _ = try packets[i].put(&[_]u8{@intCast('a' + i)});

    try q.enqueue(packets[0]);
    try q.enqueue(packets[1]);
    p.limit = error.Dropped == q.enqueue(packets[2]);
    p.priority = Qdisc.bandFor(TC_PRIO_BULK) == 2 and
        Qdisc.bandFor(TC_PRIO_BESTEFFORT) == 1 and
        Qdisc.bandFor(TC_PRIO_CONTROL) == 0;
    // Control (band 0) обгоняет bulk (band 2), хотя bulk был добавлен раньше.
    p.order = q.dequeue().? == packets[1] and q.dequeue().? == packets[0] and q.dequeue() == null;
    p.status = "ok";
    return p;
}

test "qdisc: pfifo_fast priomap maps skb priority to three bands" {
    try std.testing.expectEqual(@as(usize, 1), Qdisc.bandFor(TC_PRIO_BESTEFFORT));
    try std.testing.expectEqual(@as(usize, 2), Qdisc.bandFor(TC_PRIO_INTERACTIVE));
    try std.testing.expectEqual(@as(usize, 0), Qdisc.bandFor(TC_PRIO_CONTROL));
    try std.testing.expectEqual(@as(usize, 1), Qdisc.bandFor(15));
}

test "qdisc: pfifo_fast dequeues highest-priority band first" {
    const a = std.testing.allocator;
    var q = Qdisc.init(a);
    defer q.deinit();
    const bulk = try skb.SkBuff.alloc(a, 8, 0);
    defer bulk.free();
    bulk.priority = TC_PRIO_BULK;
    _ = try bulk.put("x");
    const control = try skb.SkBuff.alloc(a, 8, 0);
    defer control.free();
    control.priority = TC_PRIO_CONTROL;
    _ = try control.put("y");
    try q.enqueue(bulk);
    try q.enqueue(control);
    try std.testing.expectEqual(control, q.peek().?);
    try std.testing.expectEqual(control, q.dequeue().?);
    try std.testing.expectEqual(bulk, q.dequeue().?);
    try std.testing.expectEqual(@as(usize, 0), q.stats.qlen);
    try std.testing.expectEqual(@as(usize, 0), q.stats.backlog);
}

test "qdisc: limit drops packets and boot probe passes" {
    const a = std.testing.allocator;
    var q = Qdisc.init(a);
    defer q.deinit();
    q.limit = 1;
    var packets: [2]*skb.SkBuff = undefined;
    for (&packets) |*slot| slot.* = try skb.SkBuff.alloc(a, 8, 0);
    defer for (&packets) |*slot| slot.*.free();
    try q.enqueue(packets[0]);
    try std.testing.expectError(error.Dropped, q.enqueue(packets[1]));
    try std.testing.expectEqual(@as(usize, 1), q.stats.drops);
    const p = try probe(a);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.priority);
    try std.testing.expect(p.order);
    try std.testing.expect(p.limit);
}
