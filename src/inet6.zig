//! Порт IPv6-уровня Linux 7.3 (AF_INET6/SOCK_DGRAM loopback): struct in6_addr,
//! struct sockaddr_in6, ipv6_addr_equal/any/loopback, csum_ipv6_magic() с
//! 40-байтовым псевдозаголовком RFC 2460 и UDP-дейтаграммы поверх sk_buff.
//! Источники: include/uapi/linux/in6.h, include/linux/socket.h,
//! include/net/ipv6.h, include/net/ip6_checksum.h, net/ipv6/udp.c,
//! net/ipv6/addrconf.c. GPL-2.0-only (производная работа по алгоритмам Linux).

const std = @import("std");
const skbuff = @import("skb.zig");

pub const AF_INET6: u16 = 10;
pub const IPPROTO_UDP: u8 = 17;
pub const ADDR_LEN: usize = 16;
pub const UDP_HEADER_LEN: usize = 8;

pub const Addr = [ADDR_LEN]u8;

pub const ANY: Addr = @splat(0);
pub const LOOPBACK: Addr = .{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };

/// include/uapi/linux/in6.h: struct sockaddr_in6.
pub const SockAddrIn6 = struct {
    port: u16 = 0,
    addr: Addr = LOOPBACK,
    flowinfo: u32 = 0,
    scope_id: u32 = 0,
};

/// include/net/ipv6.h: ipv6_addr_equal().
pub fn addrEqual(a: Addr, b: Addr) bool {
    return std.mem.eql(u8, &a, &b);
}

/// include/net/ipv6.h: ipv6_addr_any().
pub fn addrAny(a: Addr) bool {
    for (a) |byte| if (byte != 0) return false;
    return true;
}

/// include/net/ipv6.h: ipv6_addr_loopback() — ::1.
pub fn addrLoopback(a: Addr) bool {
    for (a[0 .. ADDR_LEN - 1]) |byte| if (byte != 0) return false;
    return a[ADDR_LEN - 1] == 1;
}

fn put16be(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

fn rd16be(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

fn put32be(buf: []u8, off: usize, value: u32) void {
    buf[off] = @truncate(value >> 24);
    buf[off + 1] = @truncate(value >> 16);
    buf[off + 2] = @truncate(value >> 8);
    buf[off + 3] = @truncate(value);
}

/// include/net/ip6_checksum.h: csum_ipv6_magic(). Псевдозаголовок:
/// src[16], dst[16], upper-layer length[4], zero[3], next header[1],
/// затем сам сегмент с нулевым полем checksum.
pub fn csumIpv6Magic(
    allocator: std.mem.Allocator,
    src: Addr,
    dst: Addr,
    upper_len: u32,
    proto: u8,
    bytes: []const u8,
    base: u16,
) !u16 {
    if (@as(usize, @intCast(upper_len)) != bytes.len) return error.Invalid;
    const buf = try allocator.alloc(u8, 40 + bytes.len);
    defer allocator.free(buf);
    @memset(buf, 0);
    @memcpy(buf[0..16], &src);
    @memcpy(buf[16..32], &dst);
    put32be(buf, 32, upper_len);
    buf[39] = proto;
    @memcpy(buf[40..], bytes);
    return skbuff.checksumWithBase(buf, base);
}

pub const Datagram = struct {
    src: SockAddrIn6,
    dst: SockAddrIn6,
    length: u16,
    checksum: u16,
    payload: []const u8,
};

/// udp6_set_csum(): собрать UDP-дейтаграмму в sk_buff с checksum IPv6.
pub fn buildDatagram(
    allocator: std.mem.Allocator,
    src: SockAddrIn6,
    dst: SockAddrIn6,
    payload: []const u8,
) !*skbuff.SkBuff {
    if (UDP_HEADER_LEN + payload.len > 65535) return error.Invalid;
    const skb = try skbuff.SkBuff.alloc(allocator, UDP_HEADER_LEN + payload.len, UDP_HEADER_LEN);
    errdefer skb.free();
    _ = try skb.put(payload);
    const header = try skb.push(UDP_HEADER_LEN);
    @memset(header, 0);
    put16be(header, 0, src.port);
    put16be(header, 2, dst.port);
    put16be(header, 4, @intCast(UDP_HEADER_LEN + payload.len));
    const bytes = skb.mutableData();
    const sum = try csumIpv6Magic(
        allocator,
        src.addr,
        dst.addr,
        @intCast(bytes.len),
        IPPROTO_UDP,
        bytes,
        0,
    );
    put16be(bytes, 6, sum);
    return skb;
}

/// udp6_csum_init(): проверить checksum и разобрать заголовок дейтаграммы.
pub fn parseDatagram(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    src: Addr,
    dst: Addr,
) !Datagram {
    if (bytes.len < UDP_HEADER_LEN) return error.Invalid;
    const length = rd16be(bytes, 4);
    if (length < UDP_HEADER_LEN or @as(usize, length) != bytes.len) return error.Invalid;
    const stored = rd16be(bytes, 6);
    const copy = try allocator.dupe(u8, bytes);
    defer allocator.free(copy);
    put16be(copy, 6, 0);
    const expected = try csumIpv6Magic(allocator, src, dst, length, IPPROTO_UDP, copy, 0);
    if (expected != stored) return error.Checksum;
    return .{
        .src = .{ .port = rd16be(bytes, 0), .addr = src },
        .dst = .{ .port = rd16be(bytes, 2), .addr = dst },
        .length = length,
        .checksum = stored,
        .payload = bytes[UDP_HEADER_LEN..],
    };
}

test "inet6: address helpers follow include/net/ipv6.h" {
    try std.testing.expect(addrAny(ANY));
    try std.testing.expect(!addrAny(LOOPBACK));
    try std.testing.expect(addrLoopback(LOOPBACK));
    try std.testing.expect(!addrLoopback(ANY));
    try std.testing.expect(addrEqual(LOOPBACK, LOOPBACK));
    try std.testing.expect(!addrEqual(ANY, LOOPBACK));
    const documented: Addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    try std.testing.expect(!addrEqual(documented, LOOPBACK));
}

test "inet6: csum_ipv6_magic uses the RFC 2460 pseudo-header" {
    const a = std.testing.allocator;
    const src: Addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const dst: Addr = .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    const segment: [12]u8 = .{
        0x04, 0xd2, 0x00, 0x50, 0x00, 0x0c, 0x00, 0x00,
        'P',  'I',  'N',  'G',
    };
    try std.testing.expectEqual(@as(u16, 0x00af), try csumIpv6Magic(a, src, dst, 12, IPPROTO_UDP, &segment, 0));
    try std.testing.expectError(error.Invalid, csumIpv6Magic(a, src, dst, 11, IPPROTO_UDP, &segment, 0));
}

test "inet6: buildDatagram and parseDatagram round-trip a UDP payload" {
    const a = std.testing.allocator;
    const src: SockAddrIn6 = .{ .port = 1234, .addr = LOOPBACK };
    const dst: SockAddrIn6 = .{ .port = 80, .addr = LOOPBACK };
    const skb = try buildDatagram(a, src, dst, "PING");
    defer skb.free();
    try std.testing.expectEqual(@as(usize, 12), skb.len());

    const parsed = try parseDatagram(a, skb.data(), LOOPBACK, LOOPBACK);
    try std.testing.expectEqual(@as(u16, 1234), parsed.src.port);
    try std.testing.expectEqual(@as(u16, 80), parsed.dst.port);
    try std.testing.expectEqual(@as(u16, 12), parsed.length);
    try std.testing.expectEqualStrings("PING", parsed.payload);

    const corrupted = try a.dupe(u8, skb.data());
    defer a.free(corrupted);
    corrupted[8] ^= 1;
    try std.testing.expectError(error.Checksum, parseDatagram(a, corrupted, LOOPBACK, LOOPBACK));
}
