//! Порт xHCI hotplug и корневого хаба Linux 7.3: декодирование Port Status
//! Change Event, состояние порта по PORTSC, подключение/отключение устройства,
//! сброс порта и повторное использование слотов. Источники:
//! drivers/usb/host/xhci-ring.c (handle_port_status), drivers/usb/host/xhci.h,
//! drivers/usb/core/hub.c (port_event), include/uapi/linux/usb/ch11.h.
//! GPL-2.0-only (производная работа по алгоритмам и константам Linux).

const std = @import("std");

pub const TRB_PORT_STATUS: u32 = 34;
pub const TRB_TYPE_SHIFT: u5 = 10;
pub const TRB_TYPE_MASK: u32 = 0x3F << TRB_TYPE_SHIFT;

pub const PORT_CONNECT: u16 = 0x0001;
pub const PORT_ENABLE: u16 = 0x0002;
pub const PORT_RESET: u16 = 0x0010;
pub const PORT_POWER: u16 = 0x0100;
pub const PORT_LOW_SPEED: u16 = 0x0200;
pub const PORT_HIGH_SPEED: u16 = 0x0400;
pub const PORT_C_CONNECTION: u16 = 0x0001;
pub const PORT_C_ENABLE: u16 = 0x0002;
pub const PORT_C_RESET: u16 = 0x0010;

/// Скорость порта xHCI: биты 10..13 PORTSC (SPEED).
pub fn portSpeed(portsc: u32) u8 {
    return @truncate((portsc >> 10) & 0xF);
}

/// Уровень физического соединения: биты 5..8 PORTSC (PLS).
pub fn linkState(portsc: u32) u8 {
    return @truncate((portsc >> 5) & 0xF);
}

/// Port Status Change Event: тип в dw3, номер порта в dw0 (биты 24..31).
pub fn decodePortEvent(d0: u32, d3: u32) ?u8 {
    if ((d3 & TRB_TYPE_MASK) != (TRB_PORT_STATUS << TRB_TYPE_SHIFT)) return null;
    const port: u32 = d0 >> 24;
    if (port == 0) return null;
    return @intCast(port);
}

/// Порт корневого хаба: состояние, слот и флаги-changing.
pub const Port = struct {
    status: u16 = PORT_POWER,
    change: u16 = 0,
    connected: bool = false,
    reset_pending: bool = false,
    slot: u32 = 0,
};

pub const Controller = struct {
    ports: []Port,
    /// Владелец слота: 0 — свободен, иначе номер порта. Индекс — ID слота.
    slots: []u8,
    attaches: usize = 0,
    detaches: usize = 0,
    events: usize = 0,
    resets: usize = 0,

    pub fn init(allocator: std.mem.Allocator, ports: []Port, max_slots: u32) !Controller {
        const slots = try allocator.alloc(u8, max_slots + 1);
        @memset(slots, 0);
        return .{ .ports = ports, .slots = slots };
    }

    pub fn deinit(self: *Controller, allocator: std.mem.Allocator) void {
        allocator.free(self.slots);
    }

    fn port(self: *Controller, id: u8) ?*Port {
        if (id == 0 or id > self.ports.len) return null;
        return &self.ports[id - 1];
    }

    fn allocSlot(self: *Controller, id: u8) ?u32 {
        for (self.slots[1..], 1..) |owner, slot| {
            if (owner == 0) {
                self.slots[slot] = id;
                return @intCast(slot);
            }
        }
        return null;
    }

    fn freeSlot(self: *Controller, slot: u32) void {
        if (slot != 0 and slot < self.slots.len) self.slots[@intCast(slot)] = 0;
    }

    /// Аналог port_event(): C_CONNECTION запускает attach/detach, флаг сброса
    /// снимается, повторное событие без изменения не выделяет новый слот.
    pub fn portStatusChange(self: *Controller, id: u8, status: u16, change: u16) !void {
        const p = self.port(id) orelse return error.InvalidPort;
        self.events += 1;
        p.status = status;
        p.change |= change;
        if ((p.change & PORT_C_CONNECTION) != 0) {
            p.change &= ~PORT_C_CONNECTION;
            const present = (status & PORT_CONNECT) != 0;
            if (present and !p.connected) {
                p.slot = self.allocSlot(id) orelse return error.NoSlots;
                p.connected = true;
                self.attaches += 1;
            } else if (!present and p.connected) {
                self.freeSlot(p.slot);
                p.slot = 0;
                p.connected = false;
                p.reset_pending = false;
                self.detaches += 1;
            }
        }
        if ((p.change & PORT_C_ENABLE) != 0) p.change &= ~PORT_C_ENABLE;
        if ((p.change & PORT_C_RESET) != 0) {
            p.change &= ~PORT_C_RESET;
            p.reset_pending = false;
            p.status = (p.status & ~PORT_RESET) | PORT_ENABLE;
            self.resets += 1;
        }
    }

    /// xhci_start_port_reset(): сброс только подключённого порта.
    pub fn startReset(self: *Controller, id: u8) !void {
        const p = self.port(id) orelse return error.InvalidPort;
        if (!p.connected or (p.status & PORT_ENABLE) != 0) return error.PortNotResettable;
        p.status |= PORT_RESET;
        p.reset_pending = true;
    }

    pub fn keyboardSlot(self: *const Controller, id: u8) ?u32 {
        if (id == 0 or id > self.ports.len) return null;
        const slot = self.ports[id - 1].slot;
        return if (slot != 0) slot else null;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    decode: bool = false,
    attach: bool = false,
    detach: bool = false,
    reset: bool = false,
    reuse: bool = false,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    const ports = try allocator.alloc(Port, 4);
    defer allocator.free(ports);
    for (ports) |*port| port.* = .{};
    var ctl = try Controller.init(allocator, ports, 2);
    defer ctl.deinit(allocator);

    p.decode = decodePortEvent(0x0100_0000, TRB_PORT_STATUS << TRB_TYPE_SHIFT) == 1 and
        decodePortEvent(0x0100_0000, 33 << TRB_TYPE_SHIFT) == null;
    try ctl.portStatusChange(1, PORT_CONNECT | PORT_POWER | (3 << 10), PORT_C_CONNECTION);
    p.attach = ctl.attaches == 1 and ctl.keyboardSlot(1) == 1;
    try ctl.startReset(1);
    try ctl.portStatusChange(1, PORT_CONNECT | PORT_POWER | PORT_ENABLE | (3 << 10), PORT_C_RESET);
    p.reset = ctl.resets == 1 and (ctl.ports[0].status & PORT_ENABLE) != 0;
    try ctl.portStatusChange(2, PORT_CONNECT | PORT_POWER | (3 << 10), PORT_C_CONNECTION);
    p.attach = p.attach and ctl.attaches == 2 and ctl.keyboardSlot(2) == 2;
    try ctl.portStatusChange(1, PORT_POWER, PORT_C_CONNECTION);
    p.detach = ctl.detaches == 1 and ctl.keyboardSlot(1) == null;
    try ctl.portStatusChange(3, PORT_CONNECT | PORT_POWER | (3 << 10), PORT_C_CONNECTION);
    p.reuse = ctl.keyboardSlot(3) == 1 and ctl.slots[1] == 3;
    p.status = "ok";
    return p;
}

test "xhci hotplug: Port Status Change Event decoding follows TRB layout" {
    try std.testing.expectEqual(@as(?u8, 1), decodePortEvent(0x0100_0000, TRB_PORT_STATUS << TRB_TYPE_SHIFT));
    try std.testing.expectEqual(@as(?u8, 12), decodePortEvent(0x0c00_0000, TRB_PORT_STATUS << TRB_TYPE_SHIFT));
    try std.testing.expectEqual(@as(?u8, null), decodePortEvent(0x0100_0000, 33 << TRB_TYPE_SHIFT));
    try std.testing.expectEqual(@as(?u8, null), decodePortEvent(0, TRB_PORT_STATUS << TRB_TYPE_SHIFT));
}

test "xhci hotplug: connection change allocates and releases slots once" {
    var ports = [3]Port{ .{}, .{}, .{} };
    var ctl = try Controller.init(std.testing.allocator, &ports, 2);
    defer ctl.deinit(std.testing.allocator);
    try ctl.portStatusChange(1, PORT_CONNECT | PORT_POWER, PORT_C_CONNECTION);
    try ctl.portStatusChange(1, PORT_CONNECT | PORT_POWER, PORT_C_CONNECTION);
    try std.testing.expectEqual(@as(usize, 1), ctl.attaches);
    try std.testing.expectEqual(@as(u32, 1), ctl.keyboardSlot(1).?);
    try ctl.portStatusChange(1, PORT_POWER, PORT_C_CONNECTION);
    try ctl.portStatusChange(1, PORT_POWER, PORT_C_CONNECTION);
    try std.testing.expectEqual(@as(usize, 1), ctl.detaches);
    try std.testing.expectEqual(@as(?u32, null), ctl.keyboardSlot(1));
}

test "xhci hotplug: reset enables the port and freed slots are reused" {
    var ports = [4]Port{ .{}, .{}, .{}, .{} };
    var ctl = try Controller.init(std.testing.allocator, &ports, 2);
    defer ctl.deinit(std.testing.allocator);
    try ctl.portStatusChange(1, PORT_CONNECT | PORT_POWER | (3 << 10), PORT_C_CONNECTION);
    try ctl.startReset(1);
    try std.testing.expect(ctl.ports[0].reset_pending);
    try ctl.portStatusChange(1, PORT_CONNECT | PORT_POWER | (3 << 10) | PORT_RESET, PORT_C_RESET);
    try std.testing.expect(!ctl.ports[0].reset_pending);
    try std.testing.expect((ctl.ports[0].status & PORT_ENABLE) != 0);
    try ctl.portStatusChange(2, PORT_CONNECT | PORT_POWER, PORT_C_CONNECTION);
    try ctl.portStatusChange(1, PORT_POWER, PORT_C_CONNECTION);
    try ctl.portStatusChange(3, PORT_CONNECT | PORT_POWER, PORT_C_CONNECTION);
    try std.testing.expectEqual(@as(u32, 1), ctl.keyboardSlot(3).?);
    try std.testing.expectError(error.NoSlots, ctl.portStatusChange(4, PORT_CONNECT | PORT_POWER, PORT_C_CONNECTION));
}

test "xhci hotplug: boot probe exercises decode, attach, detach, reset and reuse" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.decode);
    try std.testing.expect(p.attach);
    try std.testing.expect(p.detach);
    try std.testing.expect(p.reset);
    try std.testing.expect(p.reuse);
}
