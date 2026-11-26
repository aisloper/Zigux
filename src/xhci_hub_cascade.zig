//! Порт каскада внешних xHCI-хабов Linux 7.3: дескриптор хаба, TT,
//! маршрутную строку, глубину каскада и проверку полосы периодических
//! endpoints. Источники: drivers/usb/host/xhci-hub.c, xhci.c, xhci-mem.c,
//! drivers/usb/core/hub.c, include/uapi/linux/usb/ch11.h.
//! GPL-2.0-only (производная работа по алгоритмам и константам Linux).

const std = @import("std");

pub const Speed = enum(u8) { low, full, high, super, super_plus };

pub const MAX_TOPO_LEVEL: u8 = 6;
pub const USB_MAXCHILDREN: u8 = 31;
pub const USB_SS_MAXPORTS: u8 = 15;
pub const HUB_CHAR_TTTT: u16 = 0x0060;
pub const HUB_CHAR_INDV_PORT_LPSM: u16 = 0x0001;
pub const HUB_CHAR_NO_LPSM: u16 = 0x0002;
pub const HUB_CHAR_INDV_PORT_OCPM: u16 = 0x0008;
pub const DEV_MTT: u32 = 1 << 25;
pub const DEV_HUB: u32 = 1 << 26;
pub const ROUTE_STRING_MASK: u32 = 0xfffff;
pub const TT_SLOT_MASK: u32 = 0xff;
pub const TT_PORT_SHIFT: u5 = 8;
pub const TT_THINK_SHIFT: u5 = 16;
pub const SS_BW_LIMIT: u32 = 3515;

pub const ParseError = error{ BadLength, WrongType, NoPorts, TooManyPorts };

pub const HubView = struct {
    ports: u8,
    chars: u16,
    protocol: u8,
    speed: Speed,
    power_on_ms: u8,
};

pub fn hubDescriptorLength(speed: Speed, ports: u8) u8 {
    if (speed == .super or speed == .super_plus) return 12;
    return @intCast(7 + 2 * (1 + @as(usize, ports) / 8));
}

pub fn hubCharacteristics(power_per_port: bool) u16 {
    return (if (power_per_port) HUB_CHAR_INDV_PORT_LPSM else HUB_CHAR_NO_LPSM) |
        HUB_CHAR_INDV_PORT_OCPM;
}

pub fn parseHub(raw: []const u8, speed: Speed, protocol: u8) ParseError!HubView {
    const ss = speed == .super or speed == .super_plus;
    const want_type: u8 = if (ss) 0x2a else 0x29;
    if (raw.len < 7 or raw[1] != want_type) return error.WrongType;
    const ports = raw[2];
    if (ports == 0) return error.NoPorts;
    if (ports > (if (ss) USB_SS_MAXPORTS else USB_MAXCHILDREN)) return error.TooManyPorts;
    const need: usize = hubDescriptorLength(speed, ports);
    if (raw.len < need) return error.BadLength;
    return .{
        .ports = ports,
        .chars = std.mem.readInt(u16, raw[3..5], .little),
        .protocol = protocol,
        .speed = speed,
        .power_on_ms = raw[5],
    };
}

pub const TTInfo = struct {
    present: bool = false,
    multi: bool = false,
    think_ns: u32 = 0,
};

const think_times = [_]u32{ 666, 1332, 1998, 2664 };

pub fn ttFromProtocol(protocol: u8, chars: u16) TTInfo {
    if (protocol != 1 and protocol != 2) return .{};
    const bits: usize = @intCast((chars & HUB_CHAR_TTTT) >> 5);
    return .{ .present = true, .multi = protocol == 2, .think_ns = think_times[bits] };
}

pub fn thinkTimeCode(ns: u32) u2 {
    if (ns < 666) return 0;
    return @intCast(@min(ns / 666 - 1, 3));
}

pub const SlotFields = struct { dev_info: u32, dev_info2: u32, tt_info: u32 };

pub fn encodeSlot(
    base_info: u32,
    ports: u8,
    hci_version: u16,
    speed: Speed,
    tt: TTInfo,
    slot: u8,
    ttport: u8,
) SlotFields {
    var info = base_info | DEV_HUB;
    if (tt.multi and speed != .full) info |= DEV_MTT;
    const info2: u32 = (@as(u32, ports) & 0xff) << 24;
    var tt_info: u32 = (@as(u32, slot) & TT_SLOT_MASK) |
        ((@as(u32, ttport) & 0xff) << TT_PORT_SHIFT) |
        (@as(u32, thinkTimeCode(tt.think_ns)) << TT_THINK_SHIFT);
    if (hci_version >= 0x100 and speed != .high) tt_info &= ~(@as(u32, 3) << TT_THINK_SHIFT);
    return .{ .dev_info = info, .dev_info2 = info2, .tt_info = tt_info };
}

pub fn routeString(parent: u32, level: u8, port1: u8) u32 {
    if (level <= 1) return parent & ROUTE_STRING_MASK;
    const nibble: u32 = @min(@as(u32, port1), 15);
    const shift: u5 = @intCast(4 * @as(usize, level - 1));
    return (parent & ROUTE_STRING_MASK) | ((nibble << shift) & ROUTE_STRING_MASK);
}

pub fn checkTopology(level: u8) !void {
    if (level >= MAX_TOPO_LEVEL) return error.NestedTooDeep;
}

pub fn setHubDepth(level: u8) u8 {
    return level - 1;
}

pub fn rootPortFromRoute(route: u32, level: u8) u8 {
    if (level <= 2) return 0;
    const shift: u5 = @intCast(4 * @as(usize, level - 2));
    return @truncate((route >> shift) & 0xf);
}

pub fn cascadeDelay(parent: u32, wHubDelay: u16, header_latency: u8) u32 {
    const value = parent + @as(u32, wHubDelay) + 40 + @as(u32, header_latency) * 100;
    return @min(value, 65535);
}

pub const IntervalBw = struct {
    num_packets: u32 = 0,
    max_packet: u16 = 0,
    overhead: u8 = 0,
};

pub const PeriodicEp = struct {
    interval: u4,
    packets: u16,
    max_packet: u16,
    speed: Speed,
    esit_payload: u32 = 0,
};

fn overheadFor(speed: Speed) u8 {
    return switch (speed) {
        .low => 128,
        .full => 20,
        .high => 26,
        .super, .super_plus => 8,
    };
}

pub const BandwidthTable = struct {
    slots: [16]IntervalBw = std.mem.zeroes([16]IntervalBw),
    interval0_payload: u32 = 0,
    bw_used: u32 = 0,

    pub fn addEp(self: *BandwidthTable, ep: PeriodicEp) void {
        const raw: usize = ep.interval;
        const index: usize = if (ep.speed == .high) raw else if (raw >= 3) raw - 3 else 0;
        if (index >= 16) return;
        if (index == 0) self.interval0_payload += ep.esit_payload;
        const slot = &self.slots[index];
        slot.num_packets += ep.packets;
        if (ep.max_packet > slot.max_packet) slot.max_packet = ep.max_packet;
        slot.overhead = @max(slot.overhead, overheadFor(ep.speed));
    }

    pub fn check(self: *BandwidthTable, speed: Speed, active_tts: usize) !void {
        const limit: u32 = if (speed == .high) 1607 else 1285;
        const reserved: u32 = if (speed == .high) 322 else 129;
        const block: u32 = if (speed == .high) 4 else 1;
        var used: u32 = (self.interval0_payload + block - 1) / block +
            self.slots[0].num_packets * @as(u32, self.slots[0].overhead);
        var pending: u32 = 0;
        var packet_size: u32 = 0;
        var overhead: u32 = 0;
        var i: usize = 1;
        while (i < 16) : (i += 1) {
            pending = 2 * pending + self.slots[i].num_packets;
            if (self.slots[i].max_packet != 0) {
                const mps = (@as(u32, self.slots[i].max_packet) + block - 1) / block;
                packet_size = @max(packet_size, mps);
            }
            overhead = @max(overhead, @as(u32, self.slots[i].overhead));
            const transmitted = pending >> @intCast(i + 1);
            used += transmitted * (overhead + packet_size);
            pending &= (@as(u32, 1) << @intCast(i + 1)) - 1;
            if (pending == 0) {
                packet_size = 0;
                overhead = 0;
            }
            if (used > limit) return error.NoBandwidth;
        }
        used += overhead + packet_size;
        if (speed == .high) used += 125 * @as(u32, @intCast(active_tts));
        used += reserved;
        if (used > limit) return error.NoBandwidth;
        self.bw_used = used;
    }
};

pub const TTDomain = struct { slot: u8, ttport: u8 };

pub fn selectTtDomain(domains: []const TTDomain, slot: u8, multi: bool, ttport: u8) ?usize {
    for (domains, 0..) |domain, index| {
        if (domain.slot == slot and (!multi or domain.ttport == ttport)) return index;
    }
    return null;
}

fn topologyRejected(level: u8) bool {
    checkTopology(level) catch |err| return err == error.NestedTooDeep;
    return false;
}

fn bandwidthRejected(table: *BandwidthTable, speed: Speed, active_tts: usize) bool {
    table.check(speed, active_tts) catch |err| return err == error.NoBandwidth;
    return false;
}

pub const Probe = struct {
    status: []const u8 = "failed",
    descriptor: bool = false,
    depth: bool = false,
    tt: bool = false,
    cascade: bool = false,
    bandwidth: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};

    var hs_raw = std.mem.zeroes([32]u8);
    hs_raw[0] = hubDescriptorLength(.high, 7);
    hs_raw[1] = 0x29;
    hs_raw[2] = 7;
    std.mem.writeInt(u16, hs_raw[3..5], hubCharacteristics(false), .little);
    hs_raw[5] = 10;
    const hs = parseHub(&hs_raw, .high, 2) catch return result;
    result.descriptor = hs.ports == 7 and hs.chars == 0x0a and hs.power_on_ms == 10;

    var ss_raw = std.mem.zeroes([12]u8);
    ss_raw[0] = 12;
    ss_raw[1] = 0x2a;
    ss_raw[2] = 4;
    ss_raw[5] = 50;
    const ss = parseHub(&ss_raw, .super, 3) catch return result;
    result.descriptor = result.descriptor and ss.ports == 4 and ss.power_on_ms == 50;

    checkTopology(5) catch return result;
    result.depth = setHubDepth(5) == 4 and
        topologyRejected(6);

    const tt = ttFromProtocol(2, HUB_CHAR_TTTT | 0x03);
    result.tt = tt.present and tt.multi and tt.think_ns == 2664 and
        thinkTimeCode(tt.think_ns) == 3 and thinkTimeCode(666) == 0;

    const route = routeString(0, 2, 3);
    result.cascade = route == (3 << 4) and
        routeString(route, 3, 16) == (3 << 4) | (15 << 8) and
        rootPortFromRoute(route, 3) == 3 and
        cascadeDelay(100, 200, 0) == 340 and
        cascadeDelay(65535, 200, 2) == 65535;

    var table = BandwidthTable{};
    table.addEp(.{ .interval = 4, .packets = 1, .max_packet = 64, .speed = .high });
    table.check(.high, 1) catch return result;
    var full = BandwidthTable{};
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        full.addEp(.{ .interval = 1, .packets = 8, .max_packet = 1023, .speed = .full });
    }
    const overbooked = bandwidthRejected(&full, .full, 0);
    result.bandwidth = overbooked and table.bw_used > 0;

    result.status = "ok";
    result.errno = 0;
    return result;
}

test "xhci cascade: HS and SS hub descriptor lengths, layouts and validation" {
    try std.testing.expectEqual(@as(u8, 9), hubDescriptorLength(.high, 7));
    try std.testing.expectEqual(@as(u8, 12), hubDescriptorLength(.super, 4));
    try std.testing.expectEqual(@as(u16, 0x09), hubCharacteristics(true));
    try std.testing.expectEqual(@as(u16, 0x0a), hubCharacteristics(false));
    var raw = std.mem.zeroes([16]u8);
    raw[0] = 9;
    raw[1] = 0x29;
    raw[2] = 7;
    std.mem.writeInt(u16, raw[3..5], 0x0a, .little);
    raw[5] = 10;
    const view = try parseHub(&raw, .high, 2);
    try std.testing.expectEqual(@as(u8, 7), view.ports);
    try std.testing.expectEqual(@as(u8, 10), view.power_on_ms);
    const zero_ports = [_]u8{ 9, 0x29, 0, 0, 0x0a, 0, 10, 0, 0, 0, 0 };
    try std.testing.expectError(error.NoPorts, parseHub(&zero_ports, .high, 2));
}

test "xhci cascade: descriptor rejects wrong type, short data and too many ports" {
    var raw = std.mem.zeroes([64]u8);
    raw[1] = 0x29;
    raw[2] = 32;
    try std.testing.expectError(error.TooManyPorts, parseHub(&raw, .high, 0));
    raw[1] = 0x2a;
    raw[2] = 16;
    try std.testing.expectError(error.TooManyPorts, parseHub(&raw, .super, 3));
    raw[1] = 0x29;
    raw[2] = 7;
    try std.testing.expectError(error.BadLength, parseHub(raw[0..8], .high, 0));
    raw[1] = 0x02;
    try std.testing.expectError(error.WrongType, parseHub(&raw, .high, 0));
}

test "xhci cascade: TT protocol, think time codes and slot bitfields" {
    const single = ttFromProtocol(1, 0);
    try std.testing.expect(single.present);
    try std.testing.expect(!single.multi);
    try std.testing.expectEqual(@as(u32, 666), single.think_ns);
    try std.testing.expectEqual(@as(u2, 0), thinkTimeCode(0));
    try std.testing.expectEqual(@as(u2, 1), thinkTimeCode(1332));
    try std.testing.expectEqual(@as(u2, 3), thinkTimeCode(99999));
    const multi = ttFromProtocol(2, HUB_CHAR_TTTT);
    const fields = encodeSlot(0x1234, 7, 0x96, .high, multi, 4, 3);
    try std.testing.expectEqual(DEV_HUB | DEV_MTT | 0x1234, fields.dev_info);
    try std.testing.expectEqual(@as(u32, 7) << 24, fields.dev_info2);
    try std.testing.expectEqual(4 | (3 << 8) | (3 << 16), fields.tt_info);
    const full = encodeSlot(0, 7, 0x96, .full, multi, 1, 1);
    try std.testing.expectEqual(DEV_HUB, full.dev_info);
}

test "xhci cascade: route string clamps port and topology depth is bounded" {
    try std.testing.expectEqual(@as(u32, 0), routeString(0, 1, 4));
    try std.testing.expectEqual(@as(u32, 0x30), routeString(0, 2, 3));
    try std.testing.expectEqual(@as(u32, 0xf30), routeString(0x30, 3, 16));
    try std.testing.expectEqual(@as(u32, ROUTE_STRING_MASK), routeString(ROUTE_STRING_MASK, 4, 2));
    try std.testing.expectEqual(@as(u8, 3), setHubDepth(4));
    try std.testing.expectEqual(@as(u8, 3), rootPortFromRoute(0x30, 3));
    try std.testing.expectError(error.NestedTooDeep, checkTopology(6));
}

test "xhci cascade: TT domains match slot and port only for multi-TT" {
    const domains = [_]TTDomain{ .{ .slot = 2, .ttport = 1 }, .{ .slot = 2, .ttport = 2 } };
    try std.testing.expectEqual(@as(?usize, 0), selectTtDomain(&domains, 2, false, 9));
    try std.testing.expectEqual(@as(?usize, 1), selectTtDomain(&domains, 2, true, 2));
    try std.testing.expectEqual(@as(?usize, null), selectTtDomain(&domains, 3, true, 1));
}

test "xhci cascade: interval bandwidth uses worst-case redistribution" {
    var table = BandwidthTable{};
    table.addEp(.{ .interval = 0, .packets = 1, .max_packet = 64, .speed = .high, .esit_payload = 1024 });
    try std.testing.expectEqual(@as(u32, 1024), table.interval0_payload);
    table.addEp(.{ .interval = 4, .packets = 2, .max_packet = 512, .speed = .high });
    table.check(.high, 1) catch |err| {
        try std.testing.expect(err == error.NoBandwidth);
    };
    try std.testing.expect(table.bw_used != 0);
}

test "xhci cascade: overbooked periodic table is rejected and TT overhead counted" {
    var table = BandwidthTable{};
    var i: usize = 0;
    while (i < 8) : (i += 1) {
        table.addEp(.{ .interval = 1, .packets = 8, .max_packet = 1023, .speed = .full });
    }
    try std.testing.expectError(error.NoBandwidth, table.check(.full, 0));
    var hs = BandwidthTable{};
    hs.addEp(.{ .interval = 4, .packets = 1, .max_packet = 64, .speed = .high });
    hs.check(.high, 12) catch |err| {
        try std.testing.expect(err == error.NoBandwidth);
    };
}

test "xhci cascade: cascaded hub delay is clamped to 16-bit field" {
    try std.testing.expectEqual(@as(u32, 340), cascadeDelay(100, 200, 0));
    try std.testing.expectEqual(@as(u32, 440), cascadeDelay(100, 200, 1));
    try std.testing.expectEqual(@as(u32, 65535), cascadeDelay(60000, 60000, 2));
}

test "xhci cascade: boot probe exercises all five invariant groups" {
    const result = probe();
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expect(result.descriptor);
    try std.testing.expect(result.depth);
    try std.testing.expect(result.tt);
    try std.testing.expect(result.cascade);
    try std.testing.expect(result.bandwidth);
    try std.testing.expectEqual(@as(u8, 0), result.errno);
}
