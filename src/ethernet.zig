//! Порт Ethernet-кадров из Linux 7.3: struct ethhdr, eth_header(),
//! eth_type_trans(). Источники: include/uapi/linux/if_ether.h,
//! net/ethernet/eth.c. GPL-2.0-only.

const std = @import("std");

pub const ETH_ALEN: usize = 6;
pub const ETH_HLEN: usize = 14;
pub const ETH_P_IP: u16 = 0x0800;
pub const ETH_P_ARP: u16 = 0x0806;
pub const ETH_P_IPV6: u16 = 0x86dd;
pub const broadcast: [ETH_ALEN]u8 = .{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff };

pub const Header = struct {
    dst: [ETH_ALEN]u8,
    src: [ETH_ALEN]u8,
    ethertype: u16,
    payload: []const u8,
};

fn put16be(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

fn rd16be(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

/// net/core/dev.c:dev_hard_header() → eth_header().
pub fn build(buf: []u8, dst: [ETH_ALEN]u8, src: [ETH_ALEN]u8, ethertype: u16, payload: []const u8) ![]u8 {
    if (buf.len < ETH_HLEN + payload.len) return error.NoSpaceLeft;
    @memcpy(buf[0..ETH_ALEN], &dst);
    @memcpy(buf[ETH_ALEN..][0..ETH_ALEN], &src);
    put16be(buf, ETH_ALEN * 2, ethertype);
    @memcpy(buf[ETH_HLEN..][0..payload.len], payload);
    return buf[0 .. ETH_HLEN + payload.len];
}

/// include/linux/if_ether.h: EthHeader + eth_type_trans() без sk_buff.
pub fn parse(frame: []const u8) !Header {
    if (frame.len < ETH_HLEN) return error.Invalid;
    var dst: [ETH_ALEN]u8 = undefined;
    var src: [ETH_ALEN]u8 = undefined;
    @memcpy(&dst, frame[0..ETH_ALEN]);
    @memcpy(&src, frame[ETH_ALEN..][0..ETH_ALEN]);
    return .{
        .dst = dst,
        .src = src,
        .ethertype = rd16be(frame, ETH_ALEN * 2),
        .payload = frame[ETH_HLEN..],
    };
}

test "ethernet: build and parse an Ethernet II frame" {
    var storage: [64]u8 = @splat(0);
    const payload = "ETH PAYLOAD\n";
    const frame = try build(&storage, broadcast, .{ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, ETH_P_IP, payload);
    try std.testing.expectEqual(@as(usize, ETH_HLEN + payload.len), frame.len);
    const parsed = try parse(frame);
    try std.testing.expectEqual(broadcast, parsed.dst);
    try std.testing.expectEqual(@as(u16, ETH_P_IP), parsed.ethertype);
    try std.testing.expectEqualStrings(payload, parsed.payload);
}
