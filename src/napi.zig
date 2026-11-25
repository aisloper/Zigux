//! Порт NAPI Linux 7.3: `struct napi_struct`, `napi_schedule_prep()`,
//! `netif_napi_add_weight()` с NAPI_POLL_WEIGHT=64 и `net_rx_action()` с
//! netdev_budget=300 и перепланированием недообработанных поллов.
//! Источники: include/linux/netdevice.h, net/core/dev.c. GPL-2.0-only.
const std = @import("std");
const skb = @import("skb.zig");

pub const NAPI_STATE_SCHED: u32 = 1 << 0;
pub const NAPI_STATE_DISABLED: u32 = 1 << 1;
pub const NAPI_POLL_WEIGHT: usize = 64;
pub const NETDEV_BUDGET: usize = 300;

pub const Napi = struct {
    allocator: std.mem.Allocator,
    state: u32 = 0,
    weight: usize = NAPI_POLL_WEIGHT,
    budget_used: usize = 0,
    completed: usize = 0,
    rx: std.ArrayList(*skb.SkBuff) = .empty,

    pub fn init(allocator: std.mem.Allocator, weight: usize) Napi {
        if (weight == 0 or weight > NAPI_POLL_WEIGHT) return .{
            .allocator = allocator,
            .weight = NAPI_POLL_WEIGHT,
        };
        return .{ .allocator = allocator, .weight = weight };
    }

    pub fn deinit(self: *Napi) void {
        for (self.rx.items) |packet| packet.free();
        self.rx.deinit(self.allocator);
    }

    pub fn isScheduled(self: *const Napi) bool {
        return self.state & NAPI_STATE_SCHED != 0;
    }

    pub fn enable(self: *Napi) void {
        self.state &= ~NAPI_STATE_DISABLED;
    }

    pub fn disable(self: *Napi) void {
        self.state |= NAPI_STATE_DISABLED;
    }

    /// napi_schedule_prep(): повторный schedule запрещён, пока бит SCHED снят
    /// poll-циклом; отключённый NAPI не планируется.
    pub fn schedulePrep(self: *Napi) bool {
        if (self.state & (NAPI_STATE_SCHED | NAPI_STATE_DISABLED) != 0) return false;
        self.state |= NAPI_STATE_SCHED;
        return true;
    }

    pub fn complete(self: *Napi) void {
        self.state &= ~NAPI_STATE_SCHED;
        self.completed += 1;
    }

    /// ndo_poll(): разбор входящих sk_buff в рамках budget и weight.
    pub fn poll(self: *Napi, budget: usize) usize {
        const limit = @min(budget, self.weight);
        var work: usize = 0;
        while (work < limit and self.rx.items.len != 0) : (work += 1) {
            self.rx.orderedRemove(0).free();
        }
        self.budget_used += work;
        return work;
    }

    pub fn enqueueRx(self: *Napi, packet: *skb.SkBuff) !void {
        try self.rx.append(self.allocator, packet);
    }
};

/// `softnet_data` в минимальном подмножестве: список запланированных NAPI,
/// бюджет softirq и счётчик time_squeeze из net_rx_action().
pub const SoftnetData = struct {
    poll_list: std.ArrayList(*Napi) = .empty,
    budget: usize = NETDEV_BUDGET,
    time_squeeze: usize = 0,
    processed: usize = 0,

    pub fn init() SoftnetData {
        return .{};
    }

    pub fn deinit(self: *SoftnetData, allocator: std.mem.Allocator) void {
        self.poll_list.deinit(allocator);
    }

    /// ____napi_schedule(): добавить в poll_list только после schedulePrep().
    pub fn schedule(self: *SoftnetData, allocator: std.mem.Allocator, napi: *Napi) !bool {
        if (!napi.schedulePrep()) return false;
        try self.poll_list.append(allocator, napi);
        return true;
    }

    /// net_rx_action(): каждый NAPI получает оставшийся budget; если работа не
    /// закончена или бюджет исчерпан, NAPI остаётся в poll_list (repoll).
    pub fn netRxAction(self: *SoftnetData, allocator: std.mem.Allocator) !void {
        var current = std.ArrayList(*Napi).empty;
        defer current.deinit(allocator);
        var repoll = std.ArrayList(*Napi).empty;
        defer repoll.deinit(allocator);
        for (self.poll_list.items) |napi| try current.append(allocator, napi);
        self.poll_list.clearRetainingCapacity();

        var budget = self.budget;
        var i: usize = 0;
        while (i < current.items.len) : (i += 1) {
            const napi = current.items[i];
            const available = @min(budget, napi.weight);
            const work = napi.poll(budget);
            self.processed += work;
            budget -= work;
            if (work < available) {
                napi.complete();
            } else {
                try repoll.append(allocator, napi);
            }
            if (budget == 0) {
                self.time_squeeze += 1;
                for (current.items[i + 1 ..]) |rest| try repoll.append(allocator, rest);
                break;
            }
        }
        for (repoll.items) |napi| try self.poll_list.append(allocator, napi);
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    schedule: bool = false,
    budget: bool = false,
    repoll: bool = false,
    weight: bool = false,
    processed: usize = 0,
    errno: i64 = 0,
};

fn makePackets(allocator: std.mem.Allocator, napi: *Napi, count: usize) !void {
    for (0..count) |_| {
        const packet = try skb.SkBuff.alloc(allocator, 8, 0);
        errdefer packet.free();
        _ = try packet.put("N");
        try napi.enqueueRx(packet);
    }
}

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    var sd = SoftnetData.init();
    defer sd.deinit(allocator);
    var first = Napi.init(allocator, NAPI_POLL_WEIGHT);
    defer first.deinit();
    var second = Napi.init(allocator, 32);
    defer second.deinit();
    p.weight = first.weight == NAPI_POLL_WEIGHT and second.weight == 32 and
        Napi.init(allocator, NAPI_POLL_WEIGHT + 1).weight == NAPI_POLL_WEIGHT;
    try makePackets(allocator, &first, 10);
    try makePackets(allocator, &second, 5);
    p.schedule = try sd.schedule(allocator, &first) and
        try sd.schedule(allocator, &second) and
        !try sd.schedule(allocator, &first);
    try sd.netRxAction(allocator);
    p.processed = sd.processed;
    p.budget = p.processed == 15 and sd.poll_list.items.len == 0 and
        !first.isScheduled() and !second.isScheduled();

    second.enable();
    try makePackets(allocator, &second, 9);
    _ = try sd.schedule(allocator, &second);
    sd.budget = 4;
    try sd.netRxAction(allocator);
    p.repoll = sd.processed == 19 and sd.time_squeeze == 1 and
        sd.poll_list.items.len == 1 and second.isScheduled();
    try sd.netRxAction(allocator);
    sd.budget = NETDEV_BUDGET;
    try sd.netRxAction(allocator);
    p.processed = sd.processed;
    p.repoll = p.repoll and sd.processed == 24 and !second.isScheduled();
    p.status = "ok";
    return p;
}

test "napi: schedulePrep rejects duplicate and disabled instances" {
    var n = Napi.init(std.testing.allocator, 16);
    defer n.deinit();
    try std.testing.expect(n.schedulePrep());
    try std.testing.expect(!n.schedulePrep());
    n.complete();
    n.disable();
    try std.testing.expect(!n.schedulePrep());
    n.enable();
    try std.testing.expect(n.schedulePrep());
}

test "napi: budget limits work and remaining poll is rescheduled" {
    const a = std.testing.allocator;
    var sd = SoftnetData.init();
    defer sd.deinit(a);
    var n = Napi.init(a, 64);
    defer n.deinit();
    try makePackets(a, &n, 6);
    _ = try sd.schedule(a, &n);
    sd.budget = 4;
    try sd.netRxAction(a);
    try std.testing.expectEqual(@as(usize, 4), sd.processed);
    try std.testing.expectEqual(@as(usize, 1), sd.time_squeeze);
    try std.testing.expect(n.isScheduled());
    try sd.netRxAction(a);
    try std.testing.expectEqual(@as(usize, 6), sd.processed);
    try std.testing.expect(!n.isScheduled());
}

test "napi: boot probe exercises weight, schedule, budget and repoll" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.weight);
    try std.testing.expect(p.schedule);
    try std.testing.expect(p.budget);
    try std.testing.expect(p.repoll);
    try std.testing.expectEqual(@as(usize, 24), p.processed);
}
