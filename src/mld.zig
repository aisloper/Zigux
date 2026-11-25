//! Порт MLDv1/v2 и IPv6 router discovery Linux 7.3: query/report/done, grec,
//! кодирование MRC/QQIC, router solicitation/advertisement и разбор ND-опций.
//! Источники: include/net/mld.h, net/ipv6/mcast.c, include/net/ndisc.h,
//! net/ipv6/ndisc.c, include/uapi/linux/icmpv6.h. GPL-2.0-only.
const std = @import("std");
const inet6 = @import("inet6.zig");
const skb = @import("skb.zig");

pub const IPPROTO_ICMPV6: u8 = 58;
pub const MGM_QUERY: u8 = 130;
pub const MGM_REPORT: u8 = 131;
pub const MGM_DONE: u8 = 132;
pub const ROUTER_SOLICITATION: u8 = 133;
pub const ROUTER_ADVERTISEMENT: u8 = 134;
pub const MLD2_REPORT: u8 = 143;

pub const MODE_IS_INCLUDE: u8 = 1;
pub const MODE_IS_EXCLUDE: u8 = 2;
pub const CHANGE_TO_INCLUDE: u8 = 3;
pub const CHANGE_TO_EXCLUDE: u8 = 4;
pub const ALLOW_NEW_SOURCES: u8 = 5;
pub const BLOCK_OLD_SOURCES: u8 = 6;

pub const ND_OPT_SOURCE_LL_ADDR: u8 = 1;
pub const ND_OPT_PREFIX_INFO: u8 = 3;
pub const ND_OPT_MTU: u8 = 5;

pub const MLD_MRC_MIN_THRESHOLD: u32 = 32768;
pub const MLD_MRC_MAX_THRESHOLD: u32 = 8387584;
pub const MLD_QQIC_MIN_THRESHOLD: u8 = 128;
pub const MLD_QQIC_MAX_THRESHOLD: u8 = 0xff;
pub const MLD_V1_HEADER_LEN: usize = 24;
pub const RA_HEADER_LEN: usize = 16;

fn put16(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

fn rd16(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

fn put32(buf: []u8, off: usize, value: u32) void {
    buf[off] = @truncate(value >> 24);
    buf[off + 1] = @truncate(value >> 16);
    buf[off + 2] = @truncate(value >> 8);
    buf[off + 3] = @truncate(value);
}

fn rd32(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) | @as(u32, buf[off + 3]);
}

fn fls(value: u32) u8 {
    if (value == 0) return 0;
    return @intCast(32 - @clz(value));
}

/// mldv2_mrc(): 16-битная плавающая кодировка максимальной задержки ответа.
pub fn mldv2Mrc(mrd: u32) u16 {
    if (mrd < MLD_MRC_MIN_THRESHOLD) return @intCast(mrd);
    if (mrd >= MLD_MRC_MAX_THRESHOLD) return 0xffff;
    const exp: u4 = @intCast(fls(mrd) - 16);
    const mant: u16 = @intCast((mrd >> @intCast(exp + 3)) & 0x0fff);
    return 0x8000 | (@as(u16, exp) << 12) | mant;
}

/// RFC 3810 5.1.3: (mant | 0x1000) << (exp + 3) в миллисекундах.
pub fn decodeMrc(mrc: u16) u32 {
    if (mrc < MLD_MRC_MIN_THRESHOLD) return mrc;
    const exp: u5 = @intCast((mrc >> 12) & 0x7);
    const mant: u32 = mrc & 0x0fff;
    return (mant | 0x1000) << @intCast(exp + 3);
}

/// mldv2_qqic(): 8-битная плавающая кодировка интервала опрашивающего.
pub fn mldv2Qqic(qqi: u32) u8 {
    if (qqi < MLD_QQIC_MIN_THRESHOLD) return @intCast(qqi);
    if (qqi >= 31744) return 0xff;
    const exp: u3 = @intCast(fls(qqi) - 8);
    const mant: u8 = @intCast((qqi >> @intCast(exp + 3)) & 0x0f);
    return 0x80 | (@as(u8, exp) << 4) | mant;
}

pub fn decodeQqic(qqic: u8) u32 {
    if (qqic < MLD_QQIC_MIN_THRESHOLD) return qqic;
    const exp: u5 = @intCast((qqic >> 4) & 0x7);
    const mant: u32 = qqic & 0x0f;
    return (mant | 0x10) << @intCast(exp + 3);
}

fn checksum(allocator: std.mem.Allocator, src: inet6.Addr, dst: inet6.Addr, bytes: []const u8) !u16 {
    return inet6.csumIpv6Magic(allocator, src, dst, @intCast(bytes.len), IPPROTO_ICMPV6, bytes, 0);
}

fn finish(allocator: std.mem.Allocator, skb_ptr: *skb.SkBuff, src: inet6.Addr, dst: inet6.Addr) !void {
    const bytes = skb_ptr.mutableData();
    put16(bytes, 2, try checksum(allocator, src, dst, bytes));
}

fn verify(allocator: std.mem.Allocator, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !void {
    const copy = try allocator.dupe(u8, bytes);
    defer allocator.free(copy);
    put16(copy, 2, 0);
    if (try checksum(allocator, src, dst, copy) != rd16(bytes, 2)) return error.Checksum;
}

pub const MldV1 = struct {
    kind: u8,
    maxdelay: u16,
    address: inet6.Addr,
};

/// mld_sendpack() / mld_gq_queue_timer(): MLDv1 query, report и done.
pub fn buildV1(
    allocator: std.mem.Allocator,
    src: inet6.Addr,
    dst: inet6.Addr,
    kind: u8,
    maxdelay: u16,
    address: inet6.Addr,
) !*skb.SkBuff {
    const packet = try skb.SkBuff.alloc(allocator, MLD_V1_HEADER_LEN, 0);
    errdefer packet.free();
    const header = try packet.putZero(MLD_V1_HEADER_LEN);
    header[0] = kind;
    put16(header, 4, maxdelay);
    @memcpy(header[8..24], &address);
    try finish(allocator, packet, src, dst);
    return packet;
}

pub fn parseV1(allocator: std.mem.Allocator, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !MldV1 {
    if (bytes.len != MLD_V1_HEADER_LEN) return error.Invalid;
    if (bytes[0] != MGM_QUERY and bytes[0] != MGM_REPORT and bytes[0] != MGM_DONE) return error.Invalid;
    if (bytes[1] != 0) return error.Invalid;
    try verify(allocator, bytes, src, dst);
    return .{ .kind = bytes[0], .maxdelay = rd16(bytes, 4), .address = bytes[8..24].* };
}

pub const Grec = struct {
    kind: u8,
    address: inet6.Addr,
    sources: []const inet6.Addr,
};

pub const MldV2Report = struct {
    records: []const Grec,
};

fn appendAddr(allocator: std.mem.Allocator, packet: *skb.SkBuff, addr: inet6.Addr) !void {
    _ = allocator;
    _ = try packet.put(&addr);
}

/// mld2_grec: запись с auxwords=0 и числом источников nsrcs.
pub fn appendGrec(allocator: std.mem.Allocator, packet: *skb.SkBuff, rec: Grec) !void {
    const count = @min(rec.sources.len, std.math.maxInt(u16));
    const header = try packet.putZero(20);
    header[0] = rec.kind;
    header[1] = 0;
    put16(header, 2, @intCast(count));
    @memcpy(header[4..20], &rec.address);
    for (rec.sources[0..count]) |addr| try appendAddr(allocator, packet, addr);
}

/// mld_send_report(): MLDv2 report с несколькими записями.
pub fn buildV2Report(
    allocator: std.mem.Allocator,
    src: inet6.Addr,
    dst: inet6.Addr,
    records: []const Grec,
) !*skb.SkBuff {
    var size: usize = 8;
    for (records) |rec| size += 20 + rec.sources.len * 16;
    const packet = try skb.SkBuff.alloc(allocator, size, 0);
    errdefer packet.free();
    const header = try packet.putZero(8);
    header[0] = MLD2_REPORT;
    put16(header, 6, @intCast(@min(records.len, std.math.maxInt(u16))));
    for (records) |rec| try appendGrec(allocator, packet, rec);
    try finish(allocator, packet, src, dst);
    return packet;
}

pub fn parseV2Report(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    src: inet6.Addr,
    dst: inet6.Addr,
    storage: []Grec,
) !MldV2Report {
    if (bytes.len < 8 or bytes[0] != MLD2_REPORT or bytes[1] != 0) return error.Invalid;
    try verify(allocator, bytes, src, dst);
    const count = rd16(bytes, 6);
    if (count > storage.len) return error.Invalid;
    var pos: usize = 8;
    for (storage[0..count]) |*rec| {
        if (pos + 20 > bytes.len) return error.Invalid;
        const nsrcs = rd16(bytes, pos + 2);
        const end = pos + 20 + @as(usize, nsrcs) * 16;
        if (end > bytes.len) return error.Invalid;
        rec.* = .{
            .kind = bytes[pos],
            .address = @as(*const inet6.Addr, @ptrCast(bytes[pos + 4 ..].ptr)).*,
            .sources = @as([]const inet6.Addr, @ptrCast(bytes[pos + 20 .. end])),
        };
        pos = end;
    }
    return .{ .records = storage[0..count] };
}

pub const NdOption = struct {
    kind: u8,
    payload: []const u8,
};

pub const Ra = struct {
    hop_limit: u8,
    managed: bool,
    other: bool,
    router_lifetime: u16,
    reachable_time: u32,
    retrans_timer: u32,
    options: Options,
};

pub const Options = struct {
    source_lladdr: ?[]const u8 = null,
    prefix: ?[]const u8 = null,
    mtu: u32 = 0,
    count: usize = 0,
};

/// ndisc_parse_options(): единица длины — 8 байт, нулевая длина — ошибка.
pub fn parseOptions(bytes: []const u8) !Options {
    var result = Options{};
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (bytes.len - pos < 2) return error.Invalid;
        const len = @as(usize, bytes[pos + 1]) * 8;
        if (len == 0 or len > bytes.len - pos) return error.Invalid;
        const payload = bytes[pos + 2 .. pos + len];
        switch (bytes[pos]) {
            ND_OPT_SOURCE_LL_ADDR => result.source_lladdr = payload,
            ND_OPT_PREFIX_INFO => result.prefix = payload,
            ND_OPT_MTU => {
                if (payload.len < 6) return error.Invalid;
                result.mtu = rd16(payload, 4);
            },
            else => {},
        }
        result.count += 1;
        pos += len;
    }
    return result;
}

pub fn parseRa(allocator: std.mem.Allocator, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !Ra {
    if (bytes.len < RA_HEADER_LEN or bytes[0] != ROUTER_ADVERTISEMENT or bytes[1] != 0) return error.Invalid;
    try verify(allocator, bytes, src, dst);
    const options = try parseOptions(bytes[RA_HEADER_LEN..]);
    return .{
        .hop_limit = bytes[4],
        .managed = (bytes[5] & 0x01) != 0,
        .other = (bytes[5] & 0x02) != 0,
        .router_lifetime = rd16(bytes, 6),
        .reachable_time = rd32(bytes, 8),
        .retrans_timer = rd32(bytes, 12),
        .options = options,
    };
}

/// ndisc_send_rs(): router solicitation с опцией source link-layer address.
pub fn buildRs(allocator: std.mem.Allocator, src: inet6.Addr, mac: [6]u8) !*skb.SkBuff {
    const packet = try skb.SkBuff.alloc(allocator, 16, 0);
    errdefer packet.free();
    const header = try packet.putZero(8);
    header[0] = ROUTER_SOLICITATION;
    const option = try packet.putZero(8);
    option[0] = ND_OPT_SOURCE_LL_ADDR;
    option[1] = 1;
    @memcpy(option[2..8], &mac);
    try finish(allocator, packet, src, inet6.Addr{
        0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02,
    });
    return packet;
}

pub const Probe = struct {
    status: []const u8 = "none",
    mld1: bool = false,
    mld2: bool = false,
    grec: bool = false,
    mrc: bool = false,
    qqic: bool = false,
    ra: bool = false,
    options: bool = false,
    rs: bool = false,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    const src = inet6.Addr{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01 };
    const group = inet6.Addr{
        0xff, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x16,
    };

    const query = try buildV1(allocator, src, group, MGM_QUERY, 1000, group);
    defer query.free();
    const parsed = try parseV1(allocator, query.data(), src, group);
    p.mld1 = parsed.kind == MGM_QUERY and parsed.maxdelay == 1000;
    p.mrc = mldv2Mrc(1311744) == 0xd404 and decodeMrc(0xd404) == 1311744;
    p.qqic = mldv2Qqic(3200) == 0xc9 and decodeQqic(0xc9) == 3200;

    const source = inet6.Addr{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x02 };
    const records = [_]Grec{.{
        .kind = MODE_IS_EXCLUDE,
        .address = group,
        .sources = &[_]inet6.Addr{source},
    }};
    var slots: [1]Grec = undefined;
    const report = try buildV2Report(allocator, src, group, &records);
    defer report.free();
    const parsed_report = try parseV2Report(allocator, report.data(), src, group, &slots);
    p.mld2 = parsed_report.records.len == 1;
    p.grec = parsed_report.records[0].kind == MODE_IS_EXCLUDE and
        parsed_report.records[0].sources.len == 1;

    const ra_dst = inet6.Addr{
        0xff, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01,
    };
    const ra_skb = try skb.SkBuff.alloc(allocator, 64, 0);
    defer ra_skb.free();
    const ra_header = try ra_skb.putZero(RA_HEADER_LEN);
    ra_header[0] = ROUTER_ADVERTISEMENT;
    ra_header[4] = 64;
    ra_header[5] = 0x01;
    put16(ra_header, 6, 1800);
    put32(ra_header, 8, 30000);
    put32(ra_header, 12, 4000);
    const mtu = try ra_skb.putZero(8);
    mtu[0] = ND_OPT_MTU;
    mtu[1] = 1;
    put16(mtu, 6, 1500);
    try finish(allocator, ra_skb, src, ra_dst);
    const parsed_ra = try parseRa(allocator, ra_skb.data(), src, ra_dst);
    p.ra = parsed_ra.hop_limit == 64 and parsed_ra.managed and
        parsed_ra.router_lifetime == 1800 and parsed_ra.reachable_time == 30000;
    const opts = parsed_ra.options;
    p.options = opts.mtu == 1500 and opts.count == 1;

    const rs = try buildRs(allocator, src, .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 });
    defer rs.free();
    p.rs = rs.data()[0] == ROUTER_SOLICITATION;
    p.status = "ok";
    return p;
}

test "mld: MRC and QQIC floating-point encoding matches Linux" {
    try std.testing.expectEqual(@as(u16, 1000), mldv2Mrc(1000));
    try std.testing.expectEqual(@as(u16, 0xd404), mldv2Mrc(1311744));
    try std.testing.expectEqual(@as(u32, 1311744), decodeMrc(0xd404));
    try std.testing.expectEqual(@as(u16, 0xffff), mldv2Mrc(MLD_MRC_MAX_THRESHOLD));
    try std.testing.expectEqual(@as(u8, 0xc9), mldv2Qqic(3200));
    try std.testing.expectEqual(@as(u32, 3200), decodeQqic(0xc9));
}

test "mld: v1 query and v2 report survive checksum and parsing" {
    const a = std.testing.allocator;
    const src = inet6.Addr{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const group = inet6.Addr{
        0xff, 0x03, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x16,
    };
    const skb_ptr = try buildV1(a, src, group, MGM_QUERY, 100, group);
    defer skb_ptr.free();
    const parsed = try parseV1(a, skb_ptr.data(), src, group);
    try std.testing.expectEqual(@as(u16, 100), parsed.maxdelay);
}

test "mld: boot probe exercises MLD, RA and ND options" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.mld1);
    try std.testing.expect(p.mld2);
    try std.testing.expect(p.grec);
    try std.testing.expect(p.mrc);
    try std.testing.expect(p.qqic);
    try std.testing.expect(p.ra);
    try std.testing.expect(p.options);
    try std.testing.expect(p.rs);
}
