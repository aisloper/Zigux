//! Порт HTB Linux 7.3 (упрощённое подмножество, соответствующее Linux):
//! иерархический token bucket с rate/ceil, buffer/cbuffer, гистерезисом,
//! заимствованием у родителя и deficit round-robin по приоритетам.
//! Источник: net/sched/sch_htb.c. GPL-2.0-only (алгоритмы и константы Linux).
const std = @import("std");
const skb = @import("skb.zig");

pub const HTB_MAXDEPTH: usize = 7;
pub const HTB_NUMPRIO: usize = 8;
/// TC_HTB_MAXDEPTH из include/linux/pkt_sched.h.
pub const MAXDEPTH: usize = HTB_MAXDEPTH;

pub const Cmode = enum { can_send, may_borrow, cant_send };

/// psched_ratecfg в упрощённом виде: скорость в битах в секунду.
/// psched_l2t_ns() = bytes * 8 * NSEC_PER_SEC / rate_bps.
pub const RateCfg = struct {
    rate_bps: u64,

    pub fn l2tNs(self: RateCfg, bytes: usize) u64 {
        if (self.rate_bps == 0) return 0;
        return (@as(u64, bytes) * 8 * std.time.ns_per_s) / self.rate_bps;
    }
};

fn zeroDeficits() [HTB_NUMPRIO]isize {
    var out: [HTB_NUMPRIO]isize = undefined;
    for (&out) |*value| value.* = 0;
    return out;
}

pub const Class = struct {
    rate: RateCfg = .{ .rate_bps = 0 },
    ceil: RateCfg = .{ .rate_bps = 0 },
    buffer: i64 = 0,
    cbuffer: i64 = 0,
    tokens: i64 = 0,
    ctokens: i64 = 0,
    t_c: i64 = 0,
    prio: usize = 0,
    quantum: usize = 1500,
    level: usize = 0,
    parent: ?usize = null,
    cmode: Cmode = .cant_send,
    deficit: [HTB_NUMPRIO]isize = undefined,
    queue: std.ArrayList(*skb.SkBuff) = .empty,
    lends: usize = 0,
    borrows: usize = 0,

    pub fn mbuffer(self: Class) i64 {
        return @max(self.buffer, self.cbuffer);
    }
};

pub const Stats = struct {
    qlen: usize = 0,
    backlog: usize = 0,
    overlimits: usize = 0,
    drops: usize = 0,
    borrowed: usize = 0,
    lent: usize = 0,
};

pub const Htb = struct {
    allocator: std.mem.Allocator,
    classes: std.ArrayList(Class) = .empty,
    /// Активные листья по приоритетам (индексы классов).
    rows: [HTB_NUMPRIO]std.ArrayList(usize) = undefined,
    now: i64 = 0,
    rate2quantum: usize = 10,
    stats: Stats = .{},

    pub fn init(allocator: std.mem.Allocator) !Htb {
        var q = Htb{ .allocator = allocator };
        for (&q.rows) |*row| row.* = .empty;
        return q;
    }

    pub fn deinit(self: *Htb) void {
        for (self.classes.items) |*cl| {
            for (cl.queue.items) |packet| packet.free();
            cl.queue.deinit(self.allocator);
        }
        for (&self.rows) |*row| row.deinit(self.allocator);
        self.classes.deinit(self.allocator);
    }

    /// htb_create(): корневой класс — уровень 1, листья — уровень 0, как в дереве классов Linux.
    pub fn addRoot(self: *Htb, rate_bps: u64, ceil_bps: u64, buffer_ns: i64, cbuffer_ns: i64) !usize {
        try self.classes.append(self.allocator, .{
            .rate = .{ .rate_bps = rate_bps },
            .ceil = .{ .rate_bps = ceil_bps },
            .buffer = buffer_ns,
            .cbuffer = cbuffer_ns,
            .tokens = buffer_ns,
            .ctokens = cbuffer_ns,
            .level = 1,
            .deficit = zeroDeficits(),
            .cmode = .can_send,
        });
        return self.classes.items.len - 1;
    }

    pub fn addLeaf(self: *Htb, parent: usize, rate_bps: u64, ceil_bps: u64, buffer_ns: i64, cbuffer_ns: i64, prio: usize) !usize {
        const quantum: usize = @intCast(@max(@as(u64, 1), rate_bps / @as(u64, self.rate2quantum) / 8));
        try self.classes.append(self.allocator, .{
            .rate = .{ .rate_bps = rate_bps },
            .ceil = .{ .rate_bps = ceil_bps },
            .buffer = buffer_ns,
            .cbuffer = cbuffer_ns,
            .tokens = buffer_ns,
            .ctokens = cbuffer_ns,
            .prio = @min(prio, HTB_NUMPRIO - 1),
            .quantum = quantum,
            .level = 0,
            .deficit = zeroDeficits(),
            .parent = parent,
            .cmode = .can_send,
        });
        return self.classes.items.len - 1;
    }

    pub fn setNow(self: *Htb, now: i64) void {
        self.now = now;
    }

    fn refill(cl: *Class, now: i64) void {
        const elapsed = @max(@as(i64, 0), @min(now - cl.t_c, cl.mbuffer()));
        cl.tokens = @min(cl.buffer, cl.tokens + elapsed);
        cl.ctokens = @min(cl.cbuffer, cl.ctokens + elapsed);
        cl.t_c = now;
    }

    fn lowater(cl: *Class) i64 {
        // htb_hysteresis включён по умолчанию.
        return if (cl.cmode != .cant_send) -cl.cbuffer else 0;
    }

    fn hiwater(cl: *Class) i64 {
        return if (cl.cmode == .can_send) -cl.buffer else 0;
    }

    fn mode(cl: *Class) Cmode {
        if (cl.ctokens < lowater(cl)) return .cant_send;
        if (cl.tokens >= hiwater(cl)) return .can_send;
        return .may_borrow;
    }

    fn activate(self: *Htb, idx: usize) !void {
        const cl = &self.classes.items[idx];
        const row = &self.rows[cl.prio];
        for (row.items) |item| if (item == idx) return;
        try row.append(self.allocator, idx);
    }

    fn deactivate(self: *Htb, idx: usize) void {
        const cl = &self.classes.items[idx];
        const row = &self.rows[cl.prio];
        for (row.items, 0..) |item, i| {
            if (item == idx) {
                _ = row.orderedRemove(i);
                break;
            }
        }
    }

    /// htb_enqueue(): приоритет пакета выбирает класс, как tc-фильтр с резервным классом.
    pub fn enqueue(self: *Htb, packet: *skb.SkBuff) !void {
        const idx = @min(@as(usize, packet.priority), self.classes.items.len - 1);
        const cl = &self.classes.items[idx];
        try cl.queue.append(self.allocator, packet);
        self.stats.qlen += 1;
        self.stats.backlog += packet.len();
        if (cl.queue.items.len == 1) try self.activate(idx);
    }

    fn charge(self: *Htb, leaf: usize, level: usize, bytes: usize) void {
        var idx: ?usize = leaf;
        while (idx) |i| {
            const cl = &self.classes.items[i];
            refill(cl, self.now);
            if (cl.level >= level) {
                if (cl.level == level) {
                    cl.lends += 1;
                    self.stats.lent += 1;
                }
                const toks = cl.tokens - @as(i64, @intCast(cl.rate.l2tNs(bytes)));
                cl.tokens = @max(toks, 1 - cl.mbuffer());
            } else {
                // Предок ниже уровня заимствования только обновляет токены.
            }
            const ctoks = cl.ctokens - @as(i64, @intCast(cl.ceil.l2tNs(bytes)));
            cl.ctokens = @max(ctoks, 1 - cl.mbuffer());
            cl.cmode = mode(cl);
            idx = cl.parent;
        }
    }

    /// htb_dequeue_tree(): самый высокий приоритет, дефицит, затем зарядка.
    pub fn dequeue(self: *Htb) ?*skb.SkBuff {
        for (0..HTB_NUMPRIO) |prio| {
            const row = &self.rows[prio];
            var pos: usize = 0;
            while (pos < row.items.len) {
                const idx = row.items[pos];
                const cl = &self.classes.items[idx];
                refill(cl, self.now);
                cl.cmode = mode(cl);
                if (cl.cmode == .cant_send or cl.queue.items.len == 0) {
                    self.deactivate(idx);
                    continue;
                }
                const can_borrow = cl.cmode == .may_borrow;
                if (can_borrow) {
                    // Долг листа перед родителем: htb_charge_class() списывает
                    // токены и с листа, и с предков, но заимствование фиксируем здесь.
                    cl.borrows += 1;
                    self.stats.borrowed += 1;
                    if (cl.parent) |parent| {
                        const p = &self.classes.items[parent];
                        refill(p, self.now);
                        if (p.tokens < 0) {
                            pos += 1;
                            continue;
                        }
                    }
                }
                if (cl.deficit[prio] <= 0) cl.deficit[prio] += @intCast(cl.quantum);
                if (cl.deficit[prio] <= 0) {
                    // Перенос в конец строки, как list_move_tail() в HTB.
                    _ = row.orderedRemove(pos);
                    row.append(self.allocator, idx) catch return null;
                    continue;
                }
                const packet = cl.queue.orderedRemove(0);
                const len = packet.len();
                self.stats.qlen -= 1;
                self.stats.backlog -= len;
                cl.deficit[prio] -= @intCast(len);
                if (can_borrow) {
                    self.charge(idx, 0, len);
                } else {
                    self.charge(idx, cl.level, len);
                }
                if (cl.queue.items.len == 0) self.deactivate(idx);
                return packet;
            }
        }
        self.stats.overlimits += 1;
        return null;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    rate: bool = false,
    ceil: bool = false,
    borrow: bool = false,
    prio: bool = false,
    deficit: bool = false,
    limit: bool = false,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    var q = try Htb.init(allocator);
    defer q.deinit();
    // 8000 бит/с = 1000 байт/с: один байт потребляет 1 мс токена.
    const root = try q.addRoot(8_000, 16_000, 10_000_000, 20_000_000);
    const low = try q.addLeaf(root, 8_000, 16_000, 500_000, 2_000_000, 1);
    const high = try q.addLeaf(root, 8_000, 16_000, 500_000, 2_000_000, 2);
    const packets = try allocator.alloc(*skb.SkBuff, 4);
    defer allocator.free(packets);
    for (packets) |*slot| slot.* = try skb.SkBuff.alloc(allocator, 16, 0);
    defer for (packets) |packet| packet.free();
    for (packets, 0..) |packet, i| {
        packet.priority = @intCast(if (i == 0) low else high);
        _ = try packet.put(&[_]u8{@intCast('a' + i)});
    }

    q.setNow(0);
    for (packets) |packet| try q.enqueue(packet);
    p.prio = q.rows[1].items.len == 1 and q.rows[2].items.len == 1;
    p.deficit = q.classes.items[low].quantum == 100;

    // Первый пакет уходит по rate из младшего приоритета, затем три пакета
    // старшего приоритета; четвёртый требует заимствования у корня.
    _ = q.dequeue();
    p.rate = q.classes.items[low].tokens < q.classes.items[low].buffer;
    _ = q.dequeue();
    p.ceil = q.classes.items[high].ctokens < q.classes.items[high].cbuffer;
    _ = q.dequeue();
    _ = q.dequeue();
    p.borrow = q.stats.borrowed > 0 and q.stats.lent > 0;
    p.limit = q.stats.qlen == 0;
    p.status = "ok";
    return p;
}

test "htb: psched_l2t_ns converts bytes to token time" {
    const rate = RateCfg{ .rate_bps = 8_000 };
    try std.testing.expectEqual(@as(u64, 1_000_000), rate.l2tNs(1));
    try std.testing.expectEqual(@as(u64, 0), (RateCfg{ .rate_bps = 0 }).l2tNs(10));
}

test "htb: hierarchy, priority rows and token charging" {
    const a = std.testing.allocator;
    var q = try Htb.init(a);
    defer q.deinit();
    const root = try q.addRoot(8_000, 16_000, 10_000_000, 20_000_000);
    const leaf = try q.addLeaf(root, 8_000, 16_000, 500_000, 2_000_000, 0);
    const packet = try skb.SkBuff.alloc(a, 16, 0);
    defer packet.free();
    packet.priority = @intCast(leaf);
    _ = try packet.put("x");
    q.setNow(0);
    try q.enqueue(packet);
    try std.testing.expectEqual(@as(usize, 1), q.rows[0].items.len);
    const out = q.dequeue().?;
    try std.testing.expect(out == packet);
    try std.testing.expect(q.classes.items[leaf].tokens < q.classes.items[leaf].buffer);
}

test "htb: boot probe exercises rate, ceil, borrowing and priority" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.rate);
    try std.testing.expect(p.ceil);
    try std.testing.expect(p.borrow);
    try std.testing.expect(p.prio);
    try std.testing.expect(p.deficit);
    try std.testing.expect(p.limit);
}
