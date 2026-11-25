//! Порт подмножества ARP из Linux 7.3: arphdr, arp_request()/arp_reply()
//! и neighbor table (NUD_REACHABLE). Источники: include/uapi/linux/if_arp.h,
//! net/ipv4/arp.c, net/core/neighbour.c. GPL-2.0-only.

const std = @import("std");
const ethernet = @import("ethernet.zig");

pub const ARPHRD_ETHER: u16 = 1;
pub const ARPOP_REQUEST: u16 = 1;
pub const ARPOP_REPLY: u16 = 2;
pub const ARP_HLEN: usize = 28;

pub const Packet = struct {
    op: u16,
    sha: [6]u8,
    spa: u32,
    tha: [6]u8,
    tpa: u32,
};

fn put16be(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

fn put32be(buf: []u8, off: usize, value: u32) void {
    buf[off] = @truncate(value >> 24);
    buf[off + 1] = @truncate(value >> 16);
    buf[off + 2] = @truncate(value >> 8);
    buf[off + 3] = @truncate(value);
}

fn rd16be(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

fn rd32be(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) | @as(u32, buf[off + 3]);
}

fn putPacket(buf: []u8, packet: Packet) void {
    put16be(buf, 0, ARPHRD_ETHER);
    put16be(buf, 2, ethernet.ETH_P_IP);
    buf[4] = 6;
    buf[5] = 4;
    put16be(buf, 6, packet.op);
    @memcpy(buf[8..][0..6], &packet.sha);
    put32be(buf, 14, packet.spa);
    @memcpy(buf[18..][0..6], &packet.tha);
    put32be(buf, 24, packet.tpa);
}

/// net/ipv4/arp.c:arp_send() — broadcast ARP request inside an Ethernet frame.
pub fn buildRequest(buf: []u8, sha: [6]u8, spa: u32, tpa: u32) ![]u8 {
    if (buf.len < ethernet.ETH_HLEN + ARP_HLEN) return error.NoSpaceLeft;
    var arp: [ARP_HLEN]u8 = @splat(0);
    putPacket(&arp, .{
        .op = ARPOP_REQUEST,
        .sha = sha,
        .spa = spa,
        .tha = @splat(0),
        .tpa = tpa,
    });
    return ethernet.build(buf, ethernet.broadcast, sha, ethernet.ETH_P_ARP, &arp);
}

pub fn buildReply(buf: []u8, sha: [6]u8, spa: u32, tha: [6]u8, tpa: u32) ![]u8 {
    if (buf.len < ethernet.ETH_HLEN + ARP_HLEN) return error.NoSpaceLeft;
    var arp: [ARP_HLEN]u8 = @splat(0);
    putPacket(&arp, .{ .op = ARPOP_REPLY, .sha = sha, .spa = spa, .tha = tha, .tpa = tpa });
    return ethernet.build(buf, tha, sha, ethernet.ETH_P_ARP, &arp);
}

pub fn parse(frame: []const u8) !Packet {
    const ether = try ethernet.parse(frame);
    if (ether.ethertype != ethernet.ETH_P_ARP or ether.payload.len < ARP_HLEN) return error.Invalid;
    const bytes = ether.payload;
    if (rd16be(bytes, 0) != ARPHRD_ETHER or rd16be(bytes, 2) != ethernet.ETH_P_IP or
        bytes[4] != 6 or bytes[5] != 4) return error.Invalid;
    var sha: [6]u8 = undefined;
    var tha: [6]u8 = undefined;
    @memcpy(&sha, bytes[8..][0..6]);
    @memcpy(&tha, bytes[18..][0..6]);
    return .{
        .op = rd16be(bytes, 6),
        .sha = sha,
        .spa = rd32be(bytes, 14),
        .tha = tha,
        .tpa = rd32be(bytes, 24),
    };
}

pub const Neighbor = struct {
    ipv4: u32,
    mac: [6]u8,
    reachable: bool = true,
};

/// net/core/neighbour.c:neigh_table + neigh_lookup() с фиксированнымёмкость.
pub const Table = struct {
    entries: []Neighbor,
    len: usize = 0,

    pub fn init(entries: []Neighbor) Table {
        return .{ .entries = entries };
    }

    pub fn update(self: *Table, ipv4: u32, mac: [6]u8) !void {
        for (self.entries[0..self.len]) |*entry| {
            if (entry.ipv4 == ipv4) {
                entry.mac = mac;
                entry.reachable = true;
                return;
            }
        }
        if (self.len >= self.entries.len) return error.Full;
        self.entries[self.len] = .{ .ipv4 = ipv4, .mac = mac };
        self.len += 1;
    }

    pub fn lookup(self: *const Table, ipv4: u32) ?[6]u8 {
        for (self.entries[0..self.len]) |entry| {
            if (entry.ipv4 == ipv4 and entry.reachable) return entry.mac;
        }
        return null;
    }

    pub fn count(self: *const Table) usize {
        return self.len;
    }
};

test "arp: request and reply frames round-trip through ethhdr/arphdr" {
    var storage: [128]u8 = @splat(0);
    const local: [6]u8 = .{ 0x52, 0x54, 0, 1, 2, 3 };
    const target: [6]u8 = .{ 0x52, 0x54, 0, 4, 5, 6 };
    const sip: u32 = 0x0a00_020f;
    const tip: u32 = 0x0a00_0202;
    const request = try buildRequest(&storage, local, sip, tip);
    const parsed_request = try parse(request);
    try std.testing.expectEqual(@as(u16, ARPOP_REQUEST), parsed_request.op);
    try std.testing.expectEqual(local, parsed_request.sha);
    try std.testing.expectEqual(sip, parsed_request.spa);
    try std.testing.expectEqual(tip, parsed_request.tpa);

    const reply = try buildReply(&storage, target, tip, local, sip);
    const parsed_reply = try parse(reply);
    try std.testing.expectEqual(@as(u16, ARPOP_REPLY), parsed_reply.op);
    try std.testing.expectEqual(target, parsed_reply.sha);
    try std.testing.expectEqual(local, parsed_reply.tha);
    try std.testing.expectEqual(tip, parsed_reply.spa);
}

test "arp: neighbor table updates and resolves IPv4 to MAC" {
    var storage: [2]Neighbor = undefined;
    var table = Table.init(&storage);
    try std.testing.expect(table.lookup(1) == null);
    const mac: [6]u8 = .{ 1, 2, 3, 4, 5, 6 };
    try table.update(1, mac);
    try std.testing.expectEqual(mac, table.lookup(1).?);
    try table.update(1, .{ 6, 5, 4, 3, 2, 1 });
    try std.testing.expectEqual(@as(usize, 1), table.count());
    try std.testing.expectEqual(@as(u8, 6), table.lookup(1).?[0]);
    try table.update(2, mac);
    try std.testing.expectError(error.Full, table.update(3, mac));
}
