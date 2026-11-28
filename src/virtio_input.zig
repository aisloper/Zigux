//! Порт минимального среза virtio-input (Linux 7.3 drivers/virtio/virtio_input.c).
//! Чистая логика: PCI ID, device-specific config select, devids/absInfo,
//! 8-байтовый формат event/status и EVENT bitmap. Boot-проба под build-флагом
//! проверяет только host-тестируемую логику, без реального input-dev registration.
//! Источник: drivers/virtio/virtio_input.c, include/uapi/linux/virtio_input.h.
//! GPL-2.0-only / BSD-3-Clause UAPI.

const std = @import("std");

pub const VIRTIO_VENDOR: u16 = 0x1af4;
pub const VIRTIO_DEVICE_INPUT_LEGACY: u16 = 0x1012;
pub const VIRTIO_ID_INPUT: u8 = 18;

pub const CFG_UNSET: u8 = 0x00;
pub const CFG_ID_NAME: u8 = 0x01;
pub const CFG_ID_SERIAL: u8 = 0x02;
pub const CFG_ID_DEVIDS: u8 = 0x03;
pub const CFG_PROP_BITS: u8 = 0x10;
pub const CFG_EV_BITS: u8 = 0x11;
pub const CFG_ABS_INFO: u8 = 0x12;

pub const ConfigHeader = struct {
    select: u8 = 0,
    subsel: u8 = 0,
    size: u8 = 0,
};

pub const DevIds = struct {
    bustype: u16 = 0,
    vendor: u16 = 0,
    product: u16 = 0,
    version: u16 = 0,
};

pub const AbsInfo = struct {
    min: u32 = 0,
    max: u32 = 0,
    fuzz: u32 = 0,
    flat: u32 = 0,
    res: u32 = 0,
};

pub const Event = struct {
    type: u16 = 0,
    code: u16 = 0,
    value: u32 = 0,
};

pub fn isSupported(vendor: u16, device: u16) bool {
    return vendor == VIRTIO_VENDOR and device == VIRTIO_DEVICE_INPUT_LEGACY;
}

pub fn featuresSupported(features: u64) bool {
    return features == 0;
}

pub fn putLe16(out: []u8, value: u16) void {
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
}

pub fn getLe16(input: []const u8) u16 {
    return @as(u16, input[0]) | (@as(u16, input[1]) << 8);
}

pub fn putLe32(out: []u8, value: u32) void {
    out[0] = @truncate(value);
    out[1] = @truncate(value >> 8);
    out[2] = @truncate(value >> 16);
    out[3] = @truncate(value >> 24);
}

pub fn getLe32(input: []const u8) u32 {
    return @as(u32, input[0]) |
        (@as(u32, input[1]) << 8) |
        (@as(u32, input[2]) << 16) |
        (@as(u32, input[3]) << 24);
}

pub fn decodeHeader(raw: [8]u8) ConfigHeader {
    return .{ .select = raw[0], .subsel = raw[1], .size = raw[2] };
}

pub fn decodeDevIds(raw: [8]u8) DevIds {
    return .{
        .bustype = getLe16(raw[0..2]),
        .vendor = getLe16(raw[2..4]),
        .product = getLe16(raw[4..6]),
        .version = getLe16(raw[6..8]),
    };
}

pub fn decodeAbsInfo(raw: [20]u8) AbsInfo {
    return .{
        .min = getLe32(raw[0..4]),
        .max = getLe32(raw[4..8]),
        .fuzz = getLe32(raw[8..12]),
        .flat = getLe32(raw[12..16]),
        .res = getLe32(raw[16..20]),
    };
}

pub fn encodeEvent(out: []u8, event: Event) void {
    putLe16(out[0..2], event.type);
    putLe16(out[2..4], event.code);
    putLe32(out[4..8], event.value);
}

pub fn decodeEvent(raw: [8]u8) Event {
    return .{
        .type = getLe16(raw[0..2]),
        .code = getLe16(raw[2..4]),
        .value = getLe32(raw[4..8]),
    };
}

pub fn setEvBit(bitmap: []u8, code: u16) bool {
    const byte: usize = code / 8;
    const bit: u3 = @intCast(code % 8);
    if (byte >= bitmap.len) return false;
    bitmap[byte] |= @as(u8, 1) << bit;
    return true;
}

pub fn hasEvBit(bitmap: []const u8, code: u16) bool {
    const byte: usize = code / 8;
    const bit: u3 = @intCast(code % 8);
    if (byte >= bitmap.len) return false;
    return (bitmap[byte] & (@as(u8, 1) << bit)) != 0;
}

pub const Probe = struct {
    status: []const u8 = "failed",
    probe: bool = false,
    feat: bool = false,
    cfg: bool = false,
    evt: bool = false,
    bits: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};
    result.probe = isSupported(VIRTIO_VENDOR, VIRTIO_DEVICE_INPUT_LEGACY) and VIRTIO_ID_INPUT == 18;
    result.feat = featuresSupported(0) and !featuresSupported(1);

    var raw_header: [8]u8 = std.mem.zeroes([8]u8);
    raw_header[0] = CFG_ID_DEVIDS;
    raw_header[1] = 0;
    raw_header[2] = 8;
    const header = decodeHeader(raw_header);
    var raw_ids: [8]u8 = std.mem.zeroes([8]u8);
    putLe16(raw_ids[0..2], 0x01);
    putLe16(raw_ids[2..4], 0x02);
    putLe16(raw_ids[4..6], 0x03);
    putLe16(raw_ids[6..8], 0x04);
    const ids = decodeDevIds(raw_ids);
    var raw_abs: [20]u8 = std.mem.zeroes([20]u8);
    putLe32(raw_abs[0..4], 0);
    putLe32(raw_abs[4..8], 1024);
    putLe32(raw_abs[8..12], 2);
    putLe32(raw_abs[12..16], 4);
    putLe32(raw_abs[16..20], 1);
    const abs = decodeAbsInfo(raw_abs);
    result.cfg = header.select == CFG_ID_DEVIDS and header.size == 8 and
        ids.bustype == 0x01 and ids.vendor == 0x02 and ids.product == 0x03 and
        ids.version == 0x04 and abs.max == 1024 and abs.res == 1;

    var raw_event: [8]u8 = std.mem.zeroes([8]u8);
    const event = Event{ .type = 0x01, .code = 30, .value = 1 };
    encodeEvent(&raw_event, event);
    const decoded = decodeEvent(raw_event);
    result.evt = decoded.type == 0x01 and decoded.code == 30 and decoded.value == 1;

    var bitmap: [32]u8 = std.mem.zeroes([32]u8);
    const bit_ok = setEvBit(&bitmap, 30) and hasEvBit(&bitmap, 30) and !hasEvBit(&bitmap, 31);
    result.bits = bit_ok;

    if (result.probe and result.feat and result.cfg and result.evt and result.bits) {
        result.status = "ok";
        result.errno = 0;
    }
    return result;
}

test "virtio-input: PCI ID and features" {
    try std.testing.expect(isSupported(0x1af4, 0x1012));
    try std.testing.expect(!isSupported(0x1af4, 0x1006));
    try std.testing.expect(featuresSupported(0));
    try std.testing.expect(!featuresSupported(1));
}

test "virtio-input: config header and devids" {
    var header_raw: [8]u8 = std.mem.zeroes([8]u8);
    header_raw[0] = CFG_ID_DEVIDS;
    header_raw[2] = 8;
    const header = decodeHeader(header_raw);
    try std.testing.expectEqual(CFG_ID_DEVIDS, header.select);
    try std.testing.expectEqual(@as(u8, 8), header.size);

    var ids_raw: [8]u8 = std.mem.zeroes([8]u8);
    putLe16(ids_raw[0..2], 0x11);
    putLe16(ids_raw[6..8], 0x22);
    const ids = decodeDevIds(ids_raw);
    try std.testing.expectEqual(@as(u16, 0x11), ids.bustype);
    try std.testing.expectEqual(@as(u16, 0x22), ids.version);
}

test "virtio-input: absInfo decode" {
    var raw: [20]u8 = std.mem.zeroes([20]u8);
    putLe32(raw[0..4], 10);
    putLe32(raw[4..8], 20);
    putLe32(raw[16..20], 3);
    const abs = decodeAbsInfo(raw);
    try std.testing.expectEqual(@as(u32, 10), abs.min);
    try std.testing.expectEqual(@as(u32, 20), abs.max);
    try std.testing.expectEqual(@as(u32, 3), abs.res);
}

test "virtio-input: event and bitmap" {
    var raw: [8]u8 = std.mem.zeroes([8]u8);
    encodeEvent(&raw, .{ .type = 1, .code = 30, .value = 1 });
    const event = decodeEvent(raw);
    try std.testing.expectEqual(@as(u16, 1), event.type);
    try std.testing.expectEqual(@as(u16, 30), event.code);
    try std.testing.expectEqual(@as(u32, 1), event.value);

    var bitmap: [32]u8 = std.mem.zeroes([32]u8);
    try std.testing.expect(setEvBit(&bitmap, 30));
    try std.testing.expect(hasEvBit(&bitmap, 30));
    try std.testing.expect(!hasEvBit(&bitmap, 31));
}

test "virtio-input: boot probe" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.probe and p.feat and p.cfg and p.evt and p.bits);
    try std.testing.expectEqual(@as(u8, 0), p.errno);
}
