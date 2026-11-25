//! Порт подмножества net_device/netdev_ops из Linux 7.3:Поиск devices,
//! flags, MTU, ifindex, dev_queue_xmit()/netif_rx() и статистика.
//! Источники: include/linux/netdevice.h, net/core/dev.c.
//! GPL-2.0-only (алгоритмы и инварианты Linux).

const std = @import("std");
const skb = @import("skb.zig");

pub const IFF_UP: u32 = 1 << 0;
pub const IFF_BROADCAST: u32 = 1 << 2;
pub const IFF_RUNNING: u32 = 1 << 6;
pub const ARPHRD_ETHER: u16 = 1;

pub const NetDevOps = struct {
    ctx: ?*anyopaque = null,
    /// net_device_ops.ndo_start_xmit(): драйвер забирает skb и возвращает
    /// число переданных байт. Вызывается только через dev_queue_xmit().
    start_xmit: *const fn (?*anyopaque, *skb.SkBuff) anyerror!usize,
};

pub const Stats = struct {
    tx_packets: usize = 0,
    tx_bytes: usize = 0,
    rx_packets: usize = 0,
    rx_bytes: usize = 0,
    tx_dropped: usize = 0,
    rx_dropped: usize = 0,
};

pub const NetDevice = struct {
    name: [16]u8 = @splat(0),
    name_len: usize = 0,
    dev_addr: [6]u8 = @splat(0),
    broadcast_addr: [6]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
    flags: u32 = 0,
    features: u32 = 0,
    mtu: u16 = 1500,
    ifindex: u32 = 0,
    type: u16 = ARPHRD_ETHER,
    ops: NetDevOps,
    stats: Stats = .{},

    pub fn init(name: []const u8, mac: [6]u8, ops: NetDevOps) !NetDevice {
        if (name.len == 0 or name.len > 15) return error.Invalid;
        var dev = NetDevice{ .ops = ops };
        @memcpy(dev.name[0..name.len], name);
        dev.name_len = name.len;
        dev.dev_addr = mac;
        return dev;
    }

    pub fn nameSlice(self: *const NetDevice) []const u8 {
        return self.name[0..self.name_len];
    }

    pub fn isUp(self: *const NetDevice) bool {
        return self.flags & IFF_UP != 0;
    }

    pub fn carrier(self: *const NetDevice) bool {
        return self.flags & IFF_RUNNING != 0;
    }
};

/// include/linux/netdevice.h:dev_queue_xmit() — Очередь вызов ndo_start_xmit
/// только для поднятого интерфейса; dropped-счётчик растёт при DOWN.
pub fn devQueueXmit(dev: *NetDevice, packet: *skb.SkBuff) !usize {
    if (!dev.isUp() or !dev.carrier()) {
        dev.stats.tx_dropped += 1;
        return error.NetworkDown;
    }
    const sent = try dev.ops.start_xmit(dev.ops.ctx, packet);
    dev.stats.tx_packets += 1;
    dev.stats.tx_bytes += sent;
    return sent;
}

/// net/core/dev.c:netif_rx() — Statistics для пакета, поступившего от NIC.
pub fn netifRx(dev: *NetDevice, bytes: []const u8) void {
    if (bytes.len == 0) {
        dev.stats.rx_dropped += 1;
        return;
    }
    dev.stats.rx_packets += 1;
    dev.stats.rx_bytes += bytes.len;
}

/// net/core/dev.c:alloc_netdev_mqs() + register_netdev() в инициализации ядра.
/// UEFI-ядро однопоточно, поэтому registry — фиксированный массив без блокировок.
pub const Registry = struct {
    devices: [8]?*NetDevice = @splat(null),
    next_ifindex: u32 = 1,

    pub fn register(self: *Registry, dev: *NetDevice) !u32 {
        if (self.count() >= self.devices.len) return error.Full;
        for (self.devices) |slot| {
            if (slot == dev) return dev.ifindex;
        }
        dev.ifindex = self.next_ifindex;
        self.next_ifindex += 1;
        for (&self.devices) |*slot| {
            if (slot.* == null) {
                slot.* = dev;
                return dev.ifindex;
            }
        }
        return error.Full;
    }

    pub fn count(self: *const Registry) usize {
        var n: usize = 0;
        for (self.devices) |slot| {
            if (slot != null) n += 1;
        }
        return n;
    }

    pub fn find(self: *const Registry, name: []const u8) ?*NetDevice {
        for (self.devices) |slot| {
            if (slot) |dev| {
                if (std.mem.eql(u8, dev.nameSlice(), name)) return dev;
            }
        }
        return null;
    }

    pub fn byIndex(self: *const Registry, ifindex: u32) ?*NetDevice {
        for (self.devices) |slot| {
            if (slot) |dev| {
                if (dev.ifindex == ifindex) return dev;
            }
        }
        return null;
    }
};

pub var registry: Registry = .{};

test "netdev: dev_queue_xmit respects IFF_UP and counts packets and bytes" {
    const a = std.testing.allocator;
    const Ctx = struct {
        bytes: usize = 0,
        calls: usize = 0,

        fn xmit(ctx: ?*anyopaque, packet: *skb.SkBuff) anyerror!usize {
            const self: *@This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            self.calls += 1;
            self.bytes = packet.len();
            return self.bytes;
        }
    };
    var ctx = Ctx{};
    var dev = try NetDevice.init("eth0", .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }, .{
        .ctx = &ctx,
        .start_xmit = Ctx.xmit,
    });
    try std.testing.expectEqualStrings("eth0", dev.nameSlice());
    try std.testing.expect(!dev.isUp());

    const packet = try skb.SkBuff.alloc(a, 32, 0);
    defer packet.free();
    _ = try packet.put("NETDEV\n");
    try std.testing.expectError(error.NetworkDown, devQueueXmit(&dev, packet));
    try std.testing.expectEqual(@as(usize, 1), dev.stats.tx_dropped);

    dev.flags = IFF_UP | IFF_BROADCAST | IFF_RUNNING;
    try std.testing.expectEqual(@as(usize, 7), try devQueueXmit(&dev, packet));
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    try std.testing.expectEqual(@as(usize, 1), dev.stats.tx_packets);
    try std.testing.expectEqual(@as(usize, 7), dev.stats.tx_bytes);

    netifRx(&dev, "REPLY\n");
    try std.testing.expectEqual(@as(usize, 1), dev.stats.rx_packets);
    try std.testing.expectEqual(@as(usize, 6), dev.stats.rx_bytes);
    netifRx(&dev, "");
    try std.testing.expectEqual(@as(usize, 1), dev.stats.rx_dropped);
}

test "netdev: registry assigns ifindex and resolves devices by name and index" {
    var reg = Registry{};
    const Ctx = struct {
        fn xmit(_: ?*anyopaque, _: *skb.SkBuff) anyerror!usize {
            return 0;
        }
    };
    var eth0 = try NetDevice.init("eth0", .{ 1, 2, 3, 4, 5, 6 }, .{ .start_xmit = Ctx.xmit });
    var eth1 = try NetDevice.init("eth1", .{ 6, 5, 4, 3, 2, 1 }, .{ .start_xmit = Ctx.xmit });
    try std.testing.expectEqual(@as(u32, 1), try reg.register(&eth0));
    try std.testing.expectEqual(@as(u32, 1), try reg.register(&eth0));
    try std.testing.expectEqual(@as(u32, 2), try reg.register(&eth1));
    try std.testing.expectEqual(@as(usize, 2), reg.count());
    try std.testing.expectEqual(@as(*NetDevice, &eth0), reg.find("eth0").?);
    try std.testing.expectEqual(@as(*NetDevice, &eth1), reg.byIndex(2).?);
    try std.testing.expect(reg.find("eth2") == null);
}
