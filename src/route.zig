//! Порт подмножества IPv4 FIB из Linux 7.3: flowi4, fib_result, longest
//! prefix match, default route, metric and iif-фильтр. Источники:
//! include/net/ip_fib.h, net/ipv4/fib_frontend.c, net/ipv4/fib_trie.c.
//! GPL-2.0-only (алгоритмы Linux).

const std = @import("std");

pub const RTN_UNICAST: u8 = 1;
pub const RTF_GATEWAY: u32 = 2;

pub const Flowi4 = struct {
    daddr: u32,
    saddr: u32 = 0,
    iif: u32 = 0,
    oif: u32 = 0,
    tos: u8 = 0,
    mark: u32 = 0,
};

pub const FibEntry = struct {
    dst: u32,
    prefix: u8,
    gateway: u32 = 0,
    src: u32 = 0,
    oif: u32,
    iif: u32 = 0,
    metric: u32 = 0,
    type: u8 = RTN_UNICAST,
};

pub const FibResult = struct {
    dst: u32,
    prefix: u8,
    gateway: u32,
    src: u32,
    oif: u32,
    metric: u32,
    type: u8,
};

pub fn parseIpv4(text: []const u8) !u32 {
    var octets: [4]u8 = undefined;
    var iter = std.mem.splitScalar(u8, text, '.');
    var i: usize = 0;
    while (iter.next()) |part| {
        if (i >= 4) return error.Invalid;
        octets[i] = std.fmt.parseInt(u8, part, 10) catch return error.Invalid;
        i += 1;
    }
    if (i != 4) return error.Invalid;
    return (@as(u32, octets[0]) << 24) | (@as(u32, octets[1]) << 16) |
        (@as(u32, octets[2]) << 8) | @as(u32, octets[3]);
}

pub fn formatIpv4(buf: []u8, addr: u32) ![]const u8 {
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{
        @as(u8, @truncate(addr >> 24)),
        @as(u8, @truncate(addr >> 16)),
        @as(u8, @truncate(addr >> 8)),
        @as(u8, @truncate(addr)),
    });
}

pub fn prefixMask(prefix: u8) u32 {
    if (prefix == 0) return 0;
    if (prefix > 32) return 0xffff_ffff;
    return @as(u32, 0xffff_ffff) << @intCast(@as(u6, 32) - @as(u6, @intCast(prefix)));
}

/// net/ipv4/fib_trie.c:fib_table_lookup() — самая длинная совпавшая сеть,
/// при равенстве префиксов выбирается меньшая метрика.
pub const FibTable = struct {
    entries: []FibEntry,
    len: usize = 0,

    pub fn init(entries: []FibEntry) FibTable {
        return .{ .entries = entries };
    }

    pub fn add(self: *FibTable, entry: FibEntry) !void {
        if (entry.prefix > 32 or entry.oif == 0) return error.Invalid;
        for (self.entries[0..self.len]) |*existing| {
            if (existing.dst == entry.dst and existing.prefix == entry.prefix and
                existing.iif == entry.iif)
            {
                existing.* = entry;
                return;
            }
        }
        if (self.len >= self.entries.len) return error.Full;
        self.entries[self.len] = entry;
        self.len += 1;
    }

    pub fn remove(self: *FibTable, dst: u32, prefix: u8, iif: u32) bool {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (entry.dst == dst and entry.prefix == prefix and entry.iif == iif) {
                var j = i;
                while (j + 1 < self.len) : (j += 1) self.entries[j] = self.entries[j + 1];
                self.len -= 1;
                return true;
            }
        }
        return false;
    }

    pub fn lookup(self: *const FibTable, flow: Flowi4) ?FibResult {
        var best: ?FibResult = null;
        for (self.entries[0..self.len]) |entry| {
            if (entry.iif != 0 and entry.iif != flow.iif) continue;
            const key_mask = prefixMask(entry.prefix);
            if (flow.daddr & key_mask != entry.dst & key_mask) continue;
            if (best) |current| {
                if (entry.prefix < current.prefix) continue;
                if (entry.prefix == current.prefix and entry.metric >= current.metric) continue;
            }
            best = .{
                .dst = entry.dst,
                .prefix = entry.prefix,
                .gateway = entry.gateway,
                .src = entry.src,
                .oif = entry.oif,
                .metric = entry.metric,
                .type = entry.type,
            };
        }
        return best;
    }
};

test "route: parse/format IPv4 and prefix masks follow include/net/ip_fib.h" {
    try std.testing.expectEqual(@as(u32, 0x0a00_020f), try parseIpv4("10.0.2.15"));
    try std.testing.expectError(error.Invalid, parseIpv4("10.0.2"));
    try std.testing.expectError(error.Invalid, parseIpv4("10.0.2.999"));
    var buf: [16]u8 = undefined;
    try std.testing.expectEqualStrings("10.0.2.15", try formatIpv4(&buf, 0x0a00_020f));
    try std.testing.expectEqual(@as(u32, 0), prefixMask(0));
    try std.testing.expectEqual(@as(u32, 0xffff_ff00), prefixMask(24));
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), prefixMask(32));
}

test "route: fib lookup picks longest prefix, then the lowest metric" {
    var storage: [6]FibEntry = undefined;
    var table = FibTable.init(&storage);
    const net = try parseIpv4("10.0.2.0");
    const gateway = try parseIpv4("10.0.2.2");
    const local = try parseIpv4("10.0.2.15");
    try table.add(.{ .dst = 0, .prefix = 0, .gateway = gateway, .oif = 1, .metric = 100 });
    try table.add(.{ .dst = net, .prefix = 24, .oif = 1, .metric = 0 });
    try table.add(.{ .dst = local, .prefix = 32, .oif = 2, .metric = 0 });
    const subnet = try parseIpv4("10.0.2.128");
    try table.add(.{ .dst = subnet, .prefix = 25, .oif = 3, .iif = 9, .metric = 1 });

    const exact = table.lookup(.{ .daddr = local }).?;
    try std.testing.expectEqual(@as(u8, 32), exact.prefix);
    try std.testing.expectEqual(@as(u32, 2), exact.oif);
    const connected = table.lookup(.{ .daddr = try parseIpv4("10.0.2.99") }).?;
    try std.testing.expectEqual(@as(u8, 24), connected.prefix);
    try std.testing.expectEqual(@as(u32, 0), connected.gateway);
    const default_route = table.lookup(.{ .daddr = try parseIpv4("8.8.8.8") }).?;
    try std.testing.expectEqual(@as(u8, 0), default_route.prefix);
    try std.testing.expectEqual(gateway, default_route.gateway);
    const from_if = table.lookup(.{ .daddr = try parseIpv4("10.0.2.200"), .iif = 9 }).?;
    try std.testing.expectEqual(@as(u32, 3), from_if.oif);

    try std.testing.expect(table.remove(subnet, 25, 9));
    try std.testing.expect(!table.remove(subnet, 25, 9));
}
