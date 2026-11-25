//! Порт promiscuous/allmulti и multicast-фильтра Linux 7.3: счётчики
//! promiscuity/allmulti, dev_mc_add()/dev_mc_del(), virtio-net control RX
//! и решение о приёме кадра по MAC. Источники: net/core/dev.c,
//! net/core/dev_addr_lists.c, drivers/net/virtio_net.c,
//! include/uapi/linux/virtio_net.h. GPL-2.0-only.
const std = @import("std");

pub const IFF_PROMISC: u32 = 0x100;
pub const IFF_ALLMULTI: u32 = 0x200;
pub const IFF_BROADCAST: u32 = 0x2;
pub const IFF_MULTICAST: u32 = 0x1000;
pub const IFF_RUNNING: u32 = 0x40;

pub const VIRTIO_NET_CTRL_RX: u8 = 0;
pub const VIRTIO_NET_CTRL_RX_PROMISC: u8 = 0;
pub const VIRTIO_NET_CTRL_RX_ALLMULTI: u8 = 1;
pub const VIRTIO_NET_CTRL_RX_ALLUNI: u8 = 2;
pub const VIRTIO_NET_CTRL_RX_NOMULTI: u8 = 3;
pub const VIRTIO_NET_CTRL_RX_NOUNI: u8 = 4;
pub const VIRTIO_NET_CTRL_RX_NOBCAST: u8 = 5;

pub const Mac = [6]u8;

pub const McEntry = struct {
    addr: Mac,
    refs: usize,
};

/// __dev_set_promiscuity() / __dev_set_allmulti(): флаг производен от счётчика.
pub const Device = struct {
    allocator: std.mem.Allocator,
    flags: u32 = IFF_BROADCAST | IFF_RUNNING | IFF_MULTICAST,
    addr: Mac,
    promiscuity: usize = 0,
    allmulti: usize = 0,
    mc: std.ArrayList(McEntry) = .empty,
    rx_mode_calls: usize = 0,
    virtio_commands: usize = 0,
    last_command: [3]u8 = .{ 0, 0, 0 },

    pub fn init(allocator: std.mem.Allocator, addr: Mac) Device {
        return .{ .allocator = allocator, .addr = addr };
    }

    pub fn deinit(self: *Device) void {
        self.mc.deinit(self.allocator);
    }

    /// netif_set_promiscuity(): inc<0 при нулевом счётчике — EOVERFLOW.
    pub fn setPromiscuity(self: *Device, inc: isize) !void {
        if (inc < 0 and self.promiscuity == 0) return error.Overflow;
        if (inc > 0 and self.promiscuity == std.math.maxInt(usize)) return error.Overflow;
        const old = self.flags;
        self.promiscuity = if (inc > 0)
            self.promiscuity + @as(usize, @intCast(inc))
        else
            self.promiscuity - @as(usize, @intCast(-inc));
        self.flags = if (self.promiscuity != 0) old | IFF_PROMISC else old & ~IFF_PROMISC;
        if (old != self.flags) try self.setRxMode();
    }

    /// netif_set_allmulti(): тот же инвариант для IFF_ALLMULTI.
    pub fn setAllmulti(self: *Device, inc: isize) !void {
        if (inc < 0 and self.allmulti == 0) return error.Overflow;
        if (inc > 0 and self.allmulti == std.math.maxInt(usize)) return error.Overflow;
        const old = self.flags;
        self.allmulti = if (inc > 0)
            self.allmulti + @as(usize, @intCast(inc))
        else
            self.allmulti - @as(usize, @intCast(-inc));
        self.flags = if (self.allmulti != 0) old | IFF_ALLMULTI else old & ~IFF_ALLMULTI;
        if (old != self.flags) try self.setRxMode();
    }

    /// __hw_addr_add_ex(): повторная регистрация увеличивает refs.
    pub fn mcAdd(self: *Device, addr: Mac) !void {
        for (self.mc.items) |*entry| {
            if (std.mem.eql(u8, &entry.addr, &addr)) {
                entry.refs += 1;
                return;
            }
        }
        try self.mc.append(self.allocator, .{ .addr = addr, .refs = 1 });
    }

    /// __hw_addr_del(): удаление последней ссылки убирает адрес из фильтра.
    pub fn mcDel(self: *Device, addr: Mac) !void {
        for (self.mc.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, &entry.addr, &addr)) {
                if (entry.refs > 1) {
                    entry.refs -= 1;
                } else {
                    _ = self.mc.orderedRemove(i);
                }
                return;
            }
        }
        return error.NotFound;
    }

    pub fn mcCount(self: *const Device) usize {
        return self.mc.items.len;
    }

    /// virtnet_set_rx_mode(): control-команды PROMISC и ALLMULTI.
    pub fn setRxMode(self: *Device) !void {
        self.rx_mode_calls += 1;
        try self.virtioCommand(VIRTIO_NET_CTRL_RX, VIRTIO_NET_CTRL_RX_PROMISC, (self.flags & IFF_PROMISC) != 0);
        try self.virtioCommand(VIRTIO_NET_CTRL_RX, VIRTIO_NET_CTRL_RX_ALLMULTI, (self.flags & IFF_ALLMULTI) != 0);
    }

    fn virtioCommand(self: *Device, class: u8, cmd: u8, enable: bool) !void {
        self.last_command = .{ class, cmd, if (enable) 1 else 0 };
        self.virtio_commands += 1;
    }

    pub fn isMulticast(addr: Mac) bool {
        return (addr[0] & 0x01) != 0;
    }

    pub fn isBroadcast(addr: Mac) bool {
        for (addr) |byte| if (byte != 0xff) return false;
        return true;
    }

    /// Фильтр приёма: broadcast проходит всегда, остальное — по списку и флагам.
    pub fn accept(self: *const Device, dst: Mac) bool {
        if (isBroadcast(dst)) return true;
        if ((self.flags & IFF_PROMISC) != 0) return true;
        if (std.mem.eql(u8, &dst, &self.addr)) return true;
        if (!isMulticast(dst)) return false;
        if ((self.flags & IFF_ALLMULTI) != 0) return true;
        for (self.mc.items) |entry| {
            if (std.mem.eql(u8, &entry.addr, &dst)) return true;
        }
        return false;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    promisc: bool = false,
    allmulti: bool = false,
    mc: bool = false,
    virtio: bool = false,
    filter: bool = false,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    var dev = Device.init(allocator, .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 });
    defer dev.deinit();
    const group = Mac{ 0x01, 0x00, 0x5e, 0, 0, 1 };
    const other = Mac{ 0x01, 0x00, 0x5e, 0, 0, 2 };

    try dev.setPromiscuity(1);
    p.promisc = (dev.flags & IFF_PROMISC) != 0 and dev.promiscuity == 1;
    try dev.setPromiscuity(-1);
    p.promisc = p.promisc and (dev.flags & IFF_PROMISC) == 0;
    p.virtio = dev.virtio_commands == 4 and dev.last_command[1] == VIRTIO_NET_CTRL_RX_ALLMULTI;

    try dev.mcAdd(group);
    try dev.mcAdd(group);
    try dev.mcDel(group);
    p.mc = dev.mcCount() == 1;
    p.filter = dev.accept(group) and !dev.accept(other);
    try dev.mcDel(group);
    p.filter = p.filter and !dev.accept(group);

    try dev.setAllmulti(1);
    p.allmulti = dev.accept(other) and (dev.flags & IFF_ALLMULTI) != 0;
    try dev.setAllmulti(-1);
    p.allmulti = p.allmulti and !dev.accept(other);
    p.status = "ok";
    return p;
}

test "rx mode: promiscuity and allmulti counters drive IFF flags" {
    var dev = Device.init(std.testing.allocator, .{ 0x52, 0x54, 0, 0, 0, 1 });
    defer dev.deinit();
    try dev.setPromiscuity(2);
    try std.testing.expectEqual(@as(usize, 2), dev.promiscuity);
    try std.testing.expect((dev.flags & IFF_PROMISC) != 0);
    try dev.setPromiscuity(-2);
    try std.testing.expect((dev.flags & IFF_PROMISC) == 0);
    try std.testing.expectError(error.Overflow, dev.setPromiscuity(-1));
}

test "rx mode: multicast reference counting and frame filtering" {
    var dev = Device.init(std.testing.allocator, .{ 0x52, 0x54, 0, 0, 0, 1 });
    defer dev.deinit();
    const group = Mac{ 0x01, 0, 0x5e, 0, 0, 1 };
    try dev.mcAdd(group);
    try dev.mcAdd(group);
    try std.testing.expectEqual(@as(usize, 1), dev.mcCount());
    try dev.mcDel(group);
    try std.testing.expect(dev.accept(group));
    try dev.mcDel(group);
    try std.testing.expect(!dev.accept(group));
}

test "rx mode: boot probe exercises promisc, allmulti, mc and virtio" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.promisc);
    try std.testing.expect(p.allmulti);
    try std.testing.expect(p.mc);
    try std.testing.expect(p.virtio);
    try std.testing.expect(p.filter);
}
