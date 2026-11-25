//! Порт ICMPv6 и NDP из Linux 7.3: echo request/reply (RFC 4443), neighbor
//! solicitation/advertisement и solicited-node multicast (RFC 4291/4861).
//! Форматы из include/uapi/linux/icmpv6.h и include/net/ndisc.h, checksum —
//! csum_ipv6_magic() из net/ipv6/addrconf.c. GPL-2.0-only.
const std = @import("std");
const inet6 = @import("inet6.zig");
const skbuff = @import("skb.zig");

pub const IPPROTO_ICMPV6: u8 = 58;
pub const ECHO_REQUEST: u8 = 128;
pub const ECHO_REPLY: u8 = 129;
pub const NS: u8 = 135;
pub const NA: u8 = 136;
pub const OPT_SRC_LLADDR: u8 = 1;
pub const OPT_TGT_LLADDR: u8 = 2;
pub const ECHO_HEADER_LEN: usize = 8;
pub const NDISC_HEADER_LEN: usize = 24;
pub const NA_FLAG_SOLICITED: u32 = @as(u32, 0x40) << 24;

pub const Mac = [6]u8;

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

/// icmp6_csum(): ICMPv6 использует тот же псевдозаголовок, что UDP6.
fn checksum(allocator: std.mem.Allocator, src: inet6.Addr, dst: inet6.Addr, bytes: []const u8) !u16 {
    return inet6.csumIpv6Magic(allocator, src, dst, @intCast(bytes.len), IPPROTO_ICMPV6, bytes, 0);
}

fn finish(allocator: std.mem.Allocator, skb: *skbuff.SkBuff, src: inet6.Addr, dst: inet6.Addr) !void {
    const bytes = skb.mutableData();
    put16(bytes, 2, try checksum(allocator, src, dst, bytes));
}

fn verify(allocator: std.mem.Allocator, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !void {
    const copy = try allocator.dupe(u8, bytes);
    defer allocator.free(copy);
    put16(copy, 2, 0);
    if (try checksum(allocator, src, dst, copy) != rd16(bytes, 2)) return error.Checksum;
}

pub const Echo = struct {
    kind: u8,
    id: u16,
    sequence: u16,
    payload: []const u8,
};

pub fn buildEcho(
    allocator: std.mem.Allocator,
    src: inet6.Addr,
    dst: inet6.Addr,
    kind: u8,
    id: u16,
    sequence: u16,
    payload: []const u8,
) !*skbuff.SkBuff {
    const skb = try skbuff.SkBuff.alloc(allocator, ECHO_HEADER_LEN + payload.len, 0);
    errdefer skb.free();
    const header = try skb.putZero(ECHO_HEADER_LEN);
    header[0] = kind;
    header[1] = 0;
    put16(header, 4, id);
    put16(header, 6, sequence);
    if (payload.len != 0) _ = try skb.put(payload);
    try finish(allocator, skb, src, dst);
    return skb;
}

pub fn parseEcho(allocator: std.mem.Allocator, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !Echo {
    if (bytes.len < ECHO_HEADER_LEN) return error.Invalid;
    if (bytes[0] != ECHO_REQUEST and bytes[0] != ECHO_REPLY) return error.Invalid;
    if (bytes[1] != 0) return error.Invalid;
    try verify(allocator, bytes, src, dst);
    return .{
        .kind = bytes[0],
        .id = rd16(bytes, 4),
        .sequence = rd16(bytes, 6),
        .payload = bytes[ECHO_HEADER_LEN..],
    };
}

/// ipv6_solicited_node_mcast(): ff02::1:ff00:0 плюс младшие 24 бита адреса.
pub fn solicitedNode(addr: inet6.Addr) inet6.Addr {
    var result = inet6.Addr{
        0xff, 0x02, 0, 0, 0,    0, 0, 0,
        0,    0,    0, 1, 0xff, 0, 0, 0,
    };
    result[13] = addr[13];
    result[14] = addr[14];
    result[15] = addr[15];
    return result;
}

pub const Neighbor = struct {
    kind: u8,
    target: inet6.Addr,
    mac: ?Mac = null,
    solicited: bool = false,
};

fn appendLladdr(allocator: std.mem.Allocator, skb: *skbuff.SkBuff, kind: u8, mac: Mac) !void {
    const option = try skb.putZero(8);
    option[0] = kind;
    option[1] = 1; // 8 байт = 1 единица длины
    @memcpy(option[2..8], &mac);
    _ = allocator;
}

pub fn buildSolicit(
    allocator: std.mem.Allocator,
    src: inet6.Addr,
    target: inet6.Addr,
    mac: Mac,
) !*skbuff.SkBuff {
    const skb = try skbuff.SkBuff.alloc(allocator, NDISC_HEADER_LEN + 8, 0);
    errdefer skb.free();
    const header = try skb.putZero(NDISC_HEADER_LEN);
    header[0] = NS;
    @memcpy(header[8..24], &target);
    try appendLladdr(allocator, skb, OPT_SRC_LLADDR, mac);
    try finish(allocator, skb, src, solicitedNode(target));
    return skb;
}

pub fn parseSolicit(allocator: std.mem.Allocator, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !Neighbor {
    if (bytes.len < NDISC_HEADER_LEN) return error.Invalid;
    if (bytes[0] != NS or bytes[1] != 0) return error.Invalid;
    try verify(allocator, bytes, src, dst);
    var result = Neighbor{ .kind = NS, .target = bytes[8..24].* };
    if (bytes.len >= NDISC_HEADER_LEN + 8 and bytes[24] == OPT_SRC_LLADDR and bytes[25] == 1) {
        result.mac = bytes[26..32].*;
    }
    return result;
}

pub fn buildAdvert(
    allocator: std.mem.Allocator,
    src: inet6.Addr,
    dst: inet6.Addr,
    target: inet6.Addr,
    mac: Mac,
    solicited: bool,
) !*skbuff.SkBuff {
    const skb = try skbuff.SkBuff.alloc(allocator, NDISC_HEADER_LEN + 8, 0);
    errdefer skb.free();
    const header = try skb.putZero(NDISC_HEADER_LEN);
    header[0] = NA;
    put32(header, 4, if (solicited) NA_FLAG_SOLICITED else 0);
    @memcpy(header[8..24], &target);
    try appendLladdr(allocator, skb, OPT_TGT_LLADDR, mac);
    try finish(allocator, skb, src, dst);
    return skb;
}

pub fn parseAdvert(allocator: std.mem.Allocator, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !Neighbor {
    if (bytes.len < NDISC_HEADER_LEN) return error.Invalid;
    if (bytes[0] != NA or bytes[1] != 0) return error.Invalid;
    try verify(allocator, bytes, src, dst);
    var result = Neighbor{
        .kind = NA,
        .target = bytes[8..24].*,
        .solicited = rd32(bytes, 4) & NA_FLAG_SOLICITED != 0,
    };
    if (bytes.len >= NDISC_HEADER_LEN + 8 and bytes[24] == OPT_TGT_LLADDR and bytes[25] == 1) {
        result.mac = bytes[26..32].*;
    }
    return result;
}

pub const NeighborState = enum { none, incomplete, reachable, stale };

pub fn neighborStateName(state: NeighborState) []const u8 {
    return switch (state) {
        .none => "None",
        .incomplete => "Incomplete",
        .reachable => "Reachable",
        .stale => "Stale",
    };
}

pub const CacheEntry = struct {
    addr: inet6.Addr = inet6.ANY,
    mac: Mac = .{ 0, 0, 0, 0, 0, 0 },
    state: NeighborState = .none,
};

/// neigh_table: небольшая таблица соседей для boot-пробы и loopback-стека.
pub const NeighborCache = struct {
    entries: [16]CacheEntry = std.mem.zeroes([16]CacheEntry),

    pub fn find(self: *const NeighborCache, addr: inet6.Addr) ?*const CacheEntry {
        for (&self.entries) |*entry| {
            if (entry.state != .none and inet6.addrEqual(entry.addr, addr)) return entry;
        }
        return null;
    }

    pub fn lookup(self: *const NeighborCache, addr: inet6.Addr) ?Mac {
        const entry = self.find(addr) orelse return null;
        return if (entry.state == .reachable or entry.state == .stale) entry.mac else null;
    }

    pub fn solicit(self: *NeighborCache, addr: inet6.Addr) void {
        if (self.find(addr)) |_| return;
        for (&self.entries) |*entry| {
            if (entry.state != .none) continue;
            entry.* = .{ .addr = addr, .state = .incomplete };
            return;
        }
    }

    /// neigh_update(): NA с target link-layer address делает запись reachable.
    pub fn learn(self: *NeighborCache, addr: inet6.Addr, mac: Mac) void {
        for (&self.entries) |*entry| {
            if (entry.state != .none and inet6.addrEqual(entry.addr, addr)) {
                entry.mac = mac;
                entry.state = .reachable;
                return;
            }
        }
        for (&self.entries) |*entry| {
            if (entry.state != .none) continue;
            entry.* = .{ .addr = addr, .mac = mac, .state = .reachable };
            return;
        }
    }

    pub fn stale(self: *NeighborCache, addr: inet6.Addr) void {
        for (&self.entries) |*entry| {
            if (entry.state != .none and inet6.addrEqual(entry.addr, addr)) entry.state = .stale;
        }
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    echo: bool = false,
    checksum: bool = false,
    ndp: bool = false,
    multicast: bool = false,
    multicast_addr: inet6.Addr = inet6.ANY,
    state: NeighborState = .none,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    const src: inet6.Addr = .{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const peer: inet6.Addr = .{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    const payload = "ICMPv6\n";

    const request = try buildEcho(allocator, src, peer, ECHO_REQUEST, 0x1234, 1, payload);
    defer request.free();
    const echo_req = try parseEcho(allocator, request.data(), src, peer);
    const reply = try buildEcho(allocator, peer, src, ECHO_REPLY, echo_req.id, echo_req.sequence, echo_req.payload);
    defer reply.free();
    const echo_rep = try parseEcho(allocator, reply.data(), peer, src);
    p.echo = echo_req.kind == ECHO_REQUEST and echo_rep.kind == ECHO_REPLY and
        echo_req.id == echo_rep.id and echo_req.sequence == echo_rep.sequence and
        std.mem.eql(u8, echo_req.payload, payload) and std.mem.eql(u8, echo_rep.payload, payload);

    var bad = try allocator.dupe(u8, request.data());
    defer allocator.free(bad);
    bad[5] ^= 1;
    p.checksum = blk: {
        _ = parseEcho(allocator, bad, src, peer) catch |err| break :blk err == error.Checksum;
        break :blk false;
    };

    p.multicast_addr = solicitedNode(peer);
    const expected: inet6.Addr = .{ 0xff, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0xff, 0, 0, 2 };
    p.multicast = inet6.addrEqual(p.multicast_addr, expected);

    const mac: Mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    var cache = NeighborCache{};
    cache.solicit(peer);
    const ns = try buildSolicit(allocator, src, peer, mac);
    defer ns.free();
    const parsed_ns = try parseSolicit(allocator, ns.data(), src, p.multicast_addr);
    const na = try buildAdvert(allocator, peer, src, parsed_ns.target, mac, true);
    defer na.free();
    const parsed_na = try parseAdvert(allocator, na.data(), peer, src);
    if (cache.lookup(peer) != null) return error.Invalid;
    cache.learn(parsed_na.target, parsed_na.mac.?);
    p.ndp = parsed_ns.mac != null and parsed_na.solicited and
        inet6.addrEqual(parsed_na.target, peer) and cache.lookup(peer) != null;
    cache.stale(peer);
    p.state = cache.find(peer).?.state;
    p.ndp = p.ndp and p.state == .stale;

    p.status = "ok";
    return p;
}

test "icmp6: solicited-node address takes the low 24 bits" {
    const addr: inet6.Addr = .{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0xaa, 0xbb, 0xcc, 0xdd };
    const mcast = solicitedNode(addr);
    try std.testing.expectEqual(@as(u8, 0xff), mcast[0]);
    try std.testing.expectEqual(@as(u8, 0x02), mcast[1]);
    try std.testing.expectEqual(@as(u8, 0xff), mcast[12]);
    try std.testing.expectEqual(@as(u8, 0xbb), mcast[13]);
    try std.testing.expectEqual(@as(u8, 0xcc), mcast[14]);
    try std.testing.expectEqual(@as(u8, 0xdd), mcast[15]);
}

test "icmp6: echo request and reply validate the pseudo-header checksum" {
    const a = std.testing.allocator;
    const src: inet6.Addr = .{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const dst: inet6.Addr = .{ 0x20, 1, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    const skb = try buildEcho(a, src, dst, ECHO_REQUEST, 7, 3, "PING");
    defer skb.free();
    const echo = try parseEcho(a, skb.data(), src, dst);
    try std.testing.expectEqual(@as(u16, 7), echo.id);
    try std.testing.expectEqual(@as(u16, 3), echo.sequence);
    try std.testing.expectEqualStrings("PING", echo.payload);
    const copy = try a.dupe(u8, skb.data());
    defer a.free(copy);
    copy[4] ^= 1;
    try std.testing.expectError(error.Checksum, parseEcho(a, copy, src, dst));
}

test "icmp6: neighbor discovery transition and boot probe" {
    var cache = NeighborCache{};
    const addr: inet6.Addr = .{ 0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 9 };
    const mac: Mac = .{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    cache.solicit(addr);
    try std.testing.expectEqual(NeighborState.incomplete, cache.find(addr).?.state);
    cache.learn(addr, mac);
    try std.testing.expectEqual(NeighborState.reachable, cache.find(addr).?.state);
    try std.testing.expectEqual(mac, cache.lookup(addr).?);
    cache.stale(addr);
    try std.testing.expectEqual(NeighborState.stale, cache.find(addr).?.state);

    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.echo);
    try std.testing.expect(p.checksum);
    try std.testing.expect(p.multicast);
    try std.testing.expect(p.ndp);
    try std.testing.expectEqual(NeighborState.stale, p.state);
}
