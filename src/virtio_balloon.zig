//! Порт минимального среза virtio-balloon (Linux 7.3 drivers/virtio/virtio_balloon.c).
//! Чистая логика: PCI ID, feature bits, config-блок (num_pages/actual),
//! PFN-кодирование inflate-запроса и packed stats. Boot-проба под build-флагом
//! проверяет только host-тестируемую логику, без управления памятью хоста.
//! Источник: drivers/virtio/virtio_balloon.c, include/uapi/linux/virtio_balloon.h.
//! GPL-2.0-or-later / BSD-3-Clause UAPI.

const std = @import("std");

pub const VIRTIO_VENDOR: u16 = 0x1af4;
pub const VIRTIO_DEVICE_BALLOON_LEGACY: u16 = 0x1006;
pub const VIRTIO_ID_BALLOON: u8 = 5;
pub const PFN_SHIFT: u5 = 12;

pub const FEATURE_MUST_TELL_HOST: u64 = 1 << 0;
pub const FEATURE_STATS_VQ: u64 = 1 << 1;
pub const FEATURE_DEFLATE_ON_OOM: u64 = 1 << 2;
pub const FEATURE_FREE_PAGE_HINT: u64 = 1 << 3;
pub const FEATURE_PAGE_POISON: u64 = 1 << 4;
pub const FEATURE_REPORTING: u64 = 1 << 5;
pub const FEATURE_KNOWN_MASK: u64 = 0x3f;

pub const Config = struct {
    num_pages: u32 = 0,
    actual: u32 = 0,
    cmd_id: u32 = 0,
    poison: u32 = 0,
};

pub const Stat = struct {
    tag: u16 = 0,
    val: u64 = 0,
};

pub fn isSupported(vendor: u16, device: u16) bool {
    return vendor == VIRTIO_VENDOR and device == VIRTIO_DEVICE_BALLOON_LEGACY;
}

pub fn featuresSupported(features: u64) bool {
    return (features & ~FEATURE_KNOWN_MASK) == 0 and (features & FEATURE_STATS_VQ) != 0;
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

pub fn putLe64(out: []u8, value: u64) void {
    var i: usize = 0;
    while (i < 8) : (i += 1) out[i] = @truncate(value >> @intCast(i * 8));
}

pub fn getLe64(input: []const u8) u64 {
    var result: u64 = 0;
    var i: usize = 0;
    while (i < 8) : (i += 1) result |= @as(u64, input[i]) << @intCast(i * 8);
    return result;
}

pub fn decodeConfig(raw: [16]u8) Config {
    return .{
        .num_pages = getLe32(raw[0..4]),
        .actual = getLe32(raw[4..8]),
        .cmd_id = getLe32(raw[8..12]),
        .poison = getLe32(raw[12..16]),
    };
}

pub fn pfnToAddr(pfn: u32) u64 {
    return @as(u64, pfn) << PFN_SHIFT;
}

pub fn packPfn(out: []u8, pfn: u32) void {
    putLe32(out, pfn);
}

pub fn fillInflate(out: []u8, pfns: []const u32) usize {
    var offset: usize = 0;
    for (pfns) |pfn| {
        if (offset + 4 > out.len) break;
        packPfn(out[offset .. offset + 4], pfn);
        offset += 4;
    }
    return offset;
}

pub fn encodeStat(out: []u8, tag: u16, val: u64) void {
    out[0] = @truncate(tag);
    out[1] = @truncate(tag >> 8);
    putLe64(out[2..10], val);
}

pub fn decodeStat(raw: [10]u8) Stat {
    const tag: u16 = @as(u16, raw[0]) | (@as(u16, raw[1]) << 8);
    return .{ .tag = tag, .val = getLe64(raw[2..10]) };
}

pub const Probe = struct {
    status: []const u8 = "failed",
    probe: bool = false,
    feat: bool = false,
    cfg: bool = false,
    pfn: bool = false,
    stats: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};
    result.probe = isSupported(VIRTIO_VENDOR, VIRTIO_DEVICE_BALLOON_LEGACY) and VIRTIO_ID_BALLOON == 5;
    const features = FEATURE_MUST_TELL_HOST | FEATURE_STATS_VQ | FEATURE_DEFLATE_ON_OOM |
        FEATURE_FREE_PAGE_HINT | FEATURE_PAGE_POISON | FEATURE_REPORTING;
    result.feat = featuresSupported(features) and !featuresSupported(features | (1 << 6));

    var raw: [16]u8 = std.mem.zeroes([16]u8);
    putLe32(raw[0..4], 4);
    putLe32(raw[4..8], 2);
    putLe32(raw[8..12], 1);
    putLe32(raw[12..16], 0);
    const cfg = decodeConfig(raw);
    result.cfg = cfg.num_pages == 4 and cfg.actual == 2 and cfg.cmd_id == 1 and cfg.poison == 0;

    var request: [12]u8 = std.mem.zeroes([12]u8);
    const pfns = [_]u32{ 0x100, 0x200, 0x300 };
    const used = fillInflate(&request, &pfns);
    result.pfn = used == 12 and getLe32(request[0..4]) == 0x100 and
        getLe32(request[8..12]) == 0x300 and pfnToAddr(0x12345) == 0x12345000;

    var stat: [10]u8 = std.mem.zeroes([10]u8);
    encodeStat(&stat, 4, 0x1122334455667788);
    const decoded = decodeStat(stat);
    result.stats = decoded.tag == 4 and decoded.val == 0x1122334455667788;

    if (result.probe and result.feat and result.cfg and result.pfn and result.stats) {
        result.status = "ok";
        result.errno = 0;
    }
    return result;
}

test "virtio-balloon: PCI ID and features" {
    try std.testing.expect(isSupported(0x1af4, 0x1006));
    try std.testing.expect(!isSupported(0x1af4, 0x1005));
    try std.testing.expect(featuresSupported(FEATURE_STATS_VQ));
    try std.testing.expect(!featuresSupported(1 << 6));
}

test "virtio-balloon: config decode" {
    var raw: [16]u8 = std.mem.zeroes([16]u8);
    putLe32(raw[0..4], 7);
    putLe32(raw[4..8], 3);
    putLe32(raw[8..12], 1);
    putLe32(raw[12..16], 0xa5a5);
    const cfg = decodeConfig(raw);
    try std.testing.expectEqual(@as(u32, 7), cfg.num_pages);
    try std.testing.expectEqual(@as(u32, 3), cfg.actual);
    try std.testing.expectEqual(@as(u32, 1), cfg.cmd_id);
    try std.testing.expectEqual(@as(u32, 0xa5a5), cfg.poison);
}

test "virtio-balloon: PFN and inflate request" {
    var request: [8]u8 = std.mem.zeroes([8]u8);
    const pfns = [_]u32{ 0x1000, 0x2000 };
    try std.testing.expectEqual(@as(usize, 8), fillInflate(&request, &pfns));
    try std.testing.expectEqual(@as(u32, 0x1000), getLe32(request[0..4]));
    try std.testing.expectEqual(@as(u32, 0x2000), getLe32(request[4..8]));
    try std.testing.expectEqual(@as(u64, 0x1000_000), pfnToAddr(0x1000));
}

test "virtio-balloon: packed stats" {
    var raw: [10]u8 = std.mem.zeroes([10]u8);
    encodeStat(&raw, 5, 0x123456789abcdef0);
    const stat = decodeStat(raw);
    try std.testing.expectEqual(@as(u16, 5), stat.tag);
    try std.testing.expectEqual(@as(u64, 0x123456789abcdef0), stat.val);
}

test "virtio-balloon: boot probe" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.probe and p.feat and p.cfg and p.pfn and p.stats);
    try std.testing.expectEqual(@as(u8, 0), p.errno);
}
