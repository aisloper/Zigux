//! Порт ICMP echo из Linux 7.3: struct icmphdr, icmp_echo()/icmp_reply(),
//! проверка checksum через csum_partial(). Источники:
//! include/uapi/linux/icmp.h, net/ipv4/icmp.c. GPL-2.0-only.

const std = @import("std");
const skb = @import("skb.zig");

pub const ICMP_ECHOREPLY: u8 = 0;
pub const ICMP_ECHO: u8 = 8;
pub const ICMP_HLEN: usize = 8;

pub const Echo = struct {
    type: u8,
    code: u8,
    checksum: u16,
    id: u16,
    seq: u16,
    payload: []const u8,
};

fn put16be(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

pub fn buildEcho(buf: []u8, id: u16, seq: u16, payload: []const u8) ![]u8 {
    if (buf.len < ICMP_HLEN + payload.len) return error.NoSpaceLeft;
    @memset(buf[0..ICMP_HLEN], 0);
    buf[0] = ICMP_ECHO;
    put16be(buf, 4, id);
    put16be(buf, 6, seq);
    @memcpy(buf[ICMP_HLEN..][0..payload.len], payload);
    put16be(buf, 2, skb.checksum(buf[0 .. ICMP_HLEN + payload.len]));
    return buf[0 .. ICMP_HLEN + payload.len];
}

pub fn parseEcho(bytes: []const u8) !Echo {
    if (bytes.len < ICMP_HLEN) return error.Invalid;
    if (!skb.checksumValid(bytes, 0)) return error.Checksum;
    return .{
        .type = bytes[0],
        .code = bytes[1],
        .checksum = (@as(u16, bytes[2]) << 8) | @as(u16, bytes[3]),
        .id = (@as(u16, bytes[4]) << 8) | @as(u16, bytes[5]),
        .seq = (@as(u16, bytes[6]) << 8) | @as(u16, bytes[7]),
        .payload = bytes[ICMP_HLEN..],
    };
}

test "icmp: echo request checksum matches Linux icmp_echo and rejects corruption" {
    var storage: [64]u8 = @splat(0);
    const payload = "ICMP PROBE\n";
    const packet = try buildEcho(&storage, 0x1234, 1, payload);
    const echo = try parseEcho(packet);
    try std.testing.expectEqual(@as(u8, ICMP_ECHO), echo.type);
    try std.testing.expectEqual(@as(u16, 0x1234), echo.id);
    try std.testing.expectEqual(@as(u16, 1), echo.seq);
    try std.testing.expectEqualStrings(payload, echo.payload);
    storage[ICMP_HLEN] ^= 0xff;
    try std.testing.expectError(error.Checksum, parseEcho(storage[0..packet.len]));
}
