//! Порт опций TCP из Linux 7.3: window scale (RFC 7323), SACK permissive и
//! выборочные подтверждения (RFC 2018/2883). Форматы из
//! include/uapi/linux/tcp.h (TCPOPT_*, TCPOLEN_*), разбор — по образцу
//! tcp_parse_options() из net/ipv4/tcp_input.c.
//! GPL-2.0-only (производная работа по алгоритмам Linux).

const std = @import("std");

pub const OPT_END: u8 = 0;
pub const OPT_NOP: u8 = 1;
pub const OPT_MSS: u8 = 2;
pub const OPT_WINDOW_SCALE: u8 = 3;
pub const OPT_SACK_PERM: u8 = 4;
pub const OPT_SACK: u8 = 5;
pub const WS_LEN: u8 = 3;
pub const MAX_WINSHIFT: u8 = 14;
pub const DEFAULT_WS: u5 = 7;
pub const MAX_SACK_BLOCKS: usize = 2;

/// Полуоткрытый интервал последовательных номеров: right не входит.
pub const Range = struct {
    left: u32,
    right: u32,
};

pub const Parsed = struct {
    ws: ?u5 = null,
    sack_perm: bool = false,
    sacks: [MAX_SACK_BLOCKS]Range = .{ .{ .left = 0, .right = 0 }, .{ .left = 0, .right = 0 } },
    sack_count: usize = 0,
};

fn rd32(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) | @as(u32, buf[off + 3]);
}

fn append32(list: *std.ArrayList(u8), allocator: std.mem.Allocator, value: u32) !void {
    try list.append(allocator, @truncate(value >> 24));
    try list.append(allocator, @truncate(value >> 16));
    try list.append(allocator, @truncate(value >> 8));
    try list.append(allocator, @truncate(value));
}

/// tcp_parse_options(): аккуратно пропускает неизвестные и урезанные опции.
pub fn parse(options: []const u8) Parsed {
    var result = Parsed{};
    var i: usize = 0;
    while (i < options.len) {
        const kind = options[i];
        if (kind == OPT_END) break;
        if (kind == OPT_NOP) {
            i += 1;
            continue;
        }
        if (i + 1 >= options.len) break;
        const len = @as(usize, options[i + 1]);
        if (len < 2 or i + len > options.len) break;
        switch (kind) {
            OPT_WINDOW_SCALE => {
                if (len >= 3) {
                    const shift: u8 = @min(options[i + 2], MAX_WINSHIFT);
                    result.ws = @intCast(shift);
                }
            },
            OPT_SACK_PERM => result.sack_perm = true,
            OPT_SACK => {
                var at = i + 2;
                while (at + 8 <= i + len and result.sack_count < result.sacks.len) : (at += 8) {
                    result.sacks[result.sack_count] = .{
                        .left = rd32(options, at),
                        .right = rd32(options, at + 4),
                    };
                    result.sack_count += 1;
                }
            },
            else => {},
        }
        i += len;
    }
    return result;
}

fn pad(list: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    while (list.items.len % 4 != 0) try list.append(allocator, OPT_NOP);
}

/// TCPOLEN_WINDOW = 3 плюс NOP до границы 4 байт.
pub fn appendWindowScale(list: *std.ArrayList(u8), allocator: std.mem.Allocator, shift: u5) !void {
    try list.append(allocator, OPT_WINDOW_SCALE);
    try list.append(allocator, WS_LEN);
    try list.append(allocator, shift);
    try pad(list, allocator);
}

pub fn appendSackPermitted(list: *std.ArrayList(u8), allocator: std.mem.Allocator) !void {
    try list.append(allocator, OPT_SACK_PERM);
    try list.append(allocator, 2);
    try pad(list, allocator);
}

/// Один SACK-блок занимает 8 байт; заголовок options выравнивается NOP-ами.
pub fn appendSack(list: *std.ArrayList(u8), allocator: std.mem.Allocator, blocks: []const Range) !void {
    if (blocks.len == 0) return;
    const count: usize = @min(blocks.len, MAX_SACK_BLOCKS);
    try list.append(allocator, OPT_SACK);
    try list.append(allocator, @intCast(2 + 8 * count));
    for (blocks[0..count]) |block| {
        try append32(list, allocator, block.left);
        try append32(list, allocator, block.right);
    }
    try pad(list, allocator);
}

test "tcp-options: window scale option round-trips and clamps to 14" {
    const a = std.testing.allocator;
    var options: std.ArrayList(u8) = .empty;
    defer options.deinit(a);
    try appendWindowScale(&options, a, 7);
    try std.testing.expectEqual(@as(usize, 4), options.items.len);
    const parsed = parse(options.items);
    try std.testing.expectEqual(@as(u5, 7), parsed.ws.?);

    options.clearRetainingCapacity();
    try appendWindowScale(&options, a, 14);
    try std.testing.expectEqual(@as(u5, 14), parse(options.items).ws.?);
}

test "tcp-options: two SACK blocks survive option serialization" {
    const a = std.testing.allocator;
    var options: std.ArrayList(u8) = .empty;
    defer options.deinit(a);
    const blocks = [_]Range{
        .{ .left = 1000, .right = 1100 },
        .{ .left = 1200, .right = 1300 },
    };
    try appendSackPermitted(&options, a);
    try appendSack(&options, a, &blocks);
    try std.testing.expectEqual(@as(usize, 24), options.items.len);
    const parsed = parse(options.items);
    try std.testing.expect(parsed.sack_perm);
    try std.testing.expectEqual(@as(usize, 2), parsed.sack_count);
    try std.testing.expectEqual(@as(u32, 1000), parsed.sacks[0].left);
    try std.testing.expectEqual(@as(u32, 1300), parsed.sacks[1].right);
}

test "tcp-options: malformed and unknown options are ignored safely" {
    const truncated = [_]u8{ OPT_WINDOW_SCALE, 4, 9 };
    try std.testing.expect(parse(&truncated).ws == null);
    const unknown = [_]u8{ 42, 6, 1, 2, 3, 4 };
    try std.testing.expect(parse(&unknown).sack_count == 0);
    const huge_shift = [_]u8{ OPT_WINDOW_SCALE, 3, 255, OPT_NOP };
    try std.testing.expectEqual(@as(u5, 14), parse(&huge_shift).ws.?);
}
