//! Порт IPv4-заголовка и контрольной суммы из Linux 7.3: struct iphdr,
//! ip_fast_csum(), ip_rcv(). Источники: include/uapi/linux/ip.h,
//! include/net/ip.h, net/ipv4/ip_input.c. GPL-2.0-only.

const std = @import("std");
const skb = @import("skb.zig");

pub const IPPROTO_ICMP: u8 = 1;
pub const IPPROTO_UDP: u8 = 17;
pub const IPPROTO_TCP: u8 = 6;
pub const IP_HLEN: usize = 20;
pub const TTL_DEFAULT: u8 = 64;

pub const Header = struct {
    version: u4 = 4,
    ihl: u4 = 5,
    tos: u8 = 0,
    total_len: u16,
    id: u16 = 0,
    flags_frag: u16 = 0,
    ttl: u8 = TTL_DEFAULT,
    protocol: u8,
    checksum: u16,
    src: u32,
    dst: u32,
};

fn put16be(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

fn rd16be(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

/// include/net/ip.h:ip_fast_csum() — сумма 20-байтового заголовка без опций.
pub fn buildHeader(buf: []u8, protocol: u8, src: u32, dst: u32, payload_len: usize) ![]u8 {
    if (buf.len < IP_HLEN) return error.NoSpaceLeft;
    @memset(buf[0..IP_HLEN], 0);
    buf[0] = 0x45;
    put16be(buf, 2, @intCast(IP_HLEN + payload_len));
    buf[8] = TTL_DEFAULT;
    buf[9] = protocol;
    std.mem.writeInt(u32, buf[12..16], src, .big);
    std.mem.writeInt(u32, buf[16..20], dst, .big);
    put16be(buf, 10, skb.checksum(buf[0..IP_HLEN]));
    return buf[0..IP_HLEN];
}

pub fn parseHeader(bytes: []const u8) !Header {
    if (bytes.len < IP_HLEN) return error.Invalid;
    if (bytes[0] >> 4 != 4 or bytes[0] & 0x0f < 5) return error.Invalid;
    if (!skb.checksumValid(bytes[0..IP_HLEN], 0)) return error.Checksum;
    const total = rd16be(bytes, 2);
    if (total < IP_HLEN or total > bytes.len) return error.Invalid;
    const ihl: usize = @as(usize, bytes[0] & 0x0f) * 4;
    if (ihl < IP_HLEN or ihl > total) return error.Invalid;
    return .{
        .ihl = @intCast(ihl / 4),
        .tos = bytes[1],
        .total_len = total,
        .id = rd16be(bytes, 4),
        .flags_frag = rd16be(bytes, 6),
        .ttl = bytes[8],
        .protocol = bytes[9],
        .checksum = rd16be(bytes, 10),
        .src = std.mem.readInt(u32, bytes[12..16], .big),
        .dst = std.mem.readInt(u32, bytes[16..20], .big),
    };
}

test "ipv4: ip_fast_csum and parseHeader validate an IPv4 header" {
    var storage: [64]u8 = @splat(0);
    const src: u32 = 0x0a00_020f;
    const dst: u32 = 0x0808_0808;
    const header = try buildHeader(&storage, IPPROTO_ICMP, src, dst, 16);
    try std.testing.expectEqual(@as(usize, IP_HLEN), header.len);
    const parsed = try parseHeader(storage[0..36]);
    try std.testing.expectEqual(@as(u8, IPPROTO_ICMP), parsed.protocol);
    try std.testing.expectEqual(src, parsed.src);
    try std.testing.expectEqual(dst, parsed.dst);
    try std.testing.expectEqual(@as(u16, 36), parsed.total_len);
    storage[7] ^= 0x01;
    try std.testing.expectError(error.Checksum, parseHeader(storage[0..IP_HLEN]));
}
