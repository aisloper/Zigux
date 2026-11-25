//! Порт IGMPv1/v2/v3 Linux 7.3: кодирование MRC/QQIC, разбор и сборка
//! query/report/leave, контрольная сумма, состояние групп и ответ по таймеру.
//! Источники: net/ipv4/igmp.c (igmp_heard_query, igmp_send_report),
//! include/linux/igmp.h, include/uapi/linux/igmp.h. GPL-2.0-only.

const std = @import("std");

pub const HOST_QUERY: u8 = 0x11;
pub const V1_REPORT: u8 = 0x12;
pub const V2_REPORT: u8 = 0x16;
pub const LEAVE: u8 = 0x17;
pub const V3_REPORT: u8 = 0x22;
pub const MIN_LEN: usize = 8;
pub const TIMER_SCALE: u10 = 10;
pub const QUERY_RESPONSE_INTERVAL: u32 = 100;
pub const EXP_MIN_THRESHOLD: u32 = 128;
pub const EXP_MAX_THRESHOLD: u32 = 31744;

pub const all_hosts = [4]u8{ 224, 0, 0, 1 };
pub const all_routers = [4]u8{ 224, 0, 0, 2 };
pub const v3_all_mcr = [4]u8{ 224, 0, 0, 22 };

/// igmpv3_exp_field_encode() / igmpv3_exp_field_decode().
pub fn expEncode(value: u32) u8 {
    if (value < EXP_MIN_THRESHOLD) return @intCast(value);
    if (value >= EXP_MAX_THRESHOLD) return 0xFF;
    const exp: u5 = @intCast(32 - @clz(value) - 8);
    const mant: u8 = @intCast((value >> @intCast(exp + 3)) & 0x0F);
    return 0x80 | (@as(u8, exp) << 4) | mant;
}

pub fn expDecode(code: u8) u32 {
    if (code < EXP_MIN_THRESHOLD) return code;
    const exp: u5 = @intCast((code >> 4) & 0x07);
    const mant: u32 = code & 0x0F;
    return (mant | 0x10) << @intCast(exp + 3);
}

/// RFC 1071-контрольная сумма заголовка IGMP.
pub fn checksum(bytes: []const u8) u16 {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | bytes[i + 1];
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xFFFF) + (sum >> 16);
    return @truncate(~sum);
}

pub const Message = struct {
    kind: u8,
    code: u8,
    checksum: u16,
    group: [4]u8,
    qrv: u3 = 0,
    qqic: u8 = 0,
    sources: usize = 0,

    /// igmp_rcv(): минимальная длина и корректная контрольная сумма.
    pub fn parse(bytes: []const u8) !Message {
        if (bytes.len < MIN_LEN) return error.Invalid;
        const stored = read16(bytes, 2);
        var copy: [MIN_LEN]u8 = undefined;
        @memcpy(&copy, bytes[0..MIN_LEN]);
        write16(&copy, 2, 0);
        if (checksum(&copy) != stored) return error.Checksum;
        var msg = Message{
            .kind = bytes[0],
            .code = bytes[1],
            .checksum = stored,
            .group = bytes[4..8].*,
        };
        if (bytes.len >= 12) {
            msg.qrv = @intCast(bytes[8] & 0x07);
            msg.qqic = bytes[9];
            msg.sources = read16(bytes, 10);
            if (bytes.len < 12 + @as(usize, msg.sources) * 4) return error.Invalid;
        }
        return msg;
    }

    pub fn serialize(self: Message, out: []u8) !usize {
        const len = if (self.kind == HOST_QUERY and self.qqic != 0) 12 else MIN_LEN;
        if (out.len < len) return error.NoSpace;
        @memset(out[0..len], 0);
        out[0] = self.kind;
        out[1] = self.code;
        @memcpy(out[4..8], &self.group);
        if (len == 12) {
            out[8] = @as(u8, self.qrv);
            out[9] = self.qqic;
            write16(out, 10, @intCast(self.sources));
        }
        write16(out, 2, checksum(out[0..len]));
        return len;
    }
};

fn read16(bytes: []const u8, off: usize) u16 {
    return (@as(u16, bytes[off]) << 8) | bytes[off + 1];
}

fn write16(bytes: []u8, off: usize, value: u16) void {
    bytes[off] = @truncate(value >> 8);
    bytes[off + 1] = @truncate(value);
}

pub const FilterMode = enum { include, exclude };

pub const Group = struct {
    addr: [4]u8,
    mode: FilterMode = .exclude,
    timer_ms: u32 = 0,
    reports: usize = 0,
    leaves: usize = 0,
};

pub const Stack = struct {
    allocator: std.mem.Allocator,
    groups: std.ArrayList(Group) = .empty,
    reports_tx: usize = 0,
    leaves_tx: usize = 0,
    queries_rx: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Stack) void {
        self.groups.deinit(self.allocator);
    }

    fn find(self: *Stack, addr: [4]u8) ?*Group {
        for (self.groups.items) |*g| {
            if (std.mem.eql(u8, &g.addr, &addr)) return g;
        }
        return null;
    }

    pub fn join(self: *Stack, addr: [4]u8, mode: FilterMode) !void {
        if (self.find(addr) != null) return;
        try self.groups.append(self.allocator, .{ .addr = addr, .mode = mode });
        self.reports_tx += 1;
    }

    /// igmp_send_report(IGMP_HOST_LEAVE_MESSAGE) только для последнего члена.
    pub fn leave(self: *Stack, addr: [4]u8) void {
        for (self.groups.items, 0..) |g, i| {
            if (std.mem.eql(u8, &g.addr, &addr)) {
                _ = self.groups.orderedRemove(i);
                self.leaves_tx += 1;
                return;
            }
        }
    }

    /// igmp_heard_query(): group==0 — общий query, MRC в 0.1 c, джиттер
    /// по последнему октету адреса, как детерминированная модель таймера.
    pub fn onQuery(self: *Stack, msg: Message) void {
        if (msg.kind != HOST_QUERY) return;
        self.queries_rx += 1;
        const mrt = if (msg.code == 0) QUERY_RESPONSE_INTERVAL else expDecode(msg.code);
        for (self.groups.items) |*g| {
            if (!zero(msg.group) and !std.mem.eql(u8, &g.addr, &msg.group)) continue;
            const jitter: u32 = if (g.addr[3] > 0) @as(u32, g.addr[3]) % (mrt + 1) else 0;
            g.timer_ms = jitter * 100;
        }
    }

    /// Истечение таймера: IGMPv2/V3 посылает report для группы.
    pub fn expire(self: *Stack) void {
        for (self.groups.items) |*g| {
            if (g.timer_ms == 0) continue;
            g.timer_ms = 0;
            g.reports += 1;
            self.reports_tx += 1;
        }
    }
};

fn zero(addr: [4]u8) bool {
    for (addr) |b| if (b != 0) return false;
    return true;
}

pub const Probe = struct {
    status: []const u8 = "none",
    encoding: bool = false,
    message: bool = false,
    membership: bool = false,
    query: bool = false,
    leave: bool = false,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    p.encoding = expEncode(1000) == expEncode(1000) and expDecode(expEncode(1000)) >= 992 and
        expDecode(expEncode(1000)) <= 1024 and expEncode(3200) == 0xC9 and
        expDecode(0x00) == 0;
    var bytes: [16]u8 = @splat(0);
    const query = Message{ .kind = HOST_QUERY, .code = 100, .group = zeroAddr(), .checksum = 0 };
    const len = try query.serialize(&bytes);
    const parsed = try Message.parse(bytes[0..len]);
    p.message = parsed.kind == HOST_QUERY and zero(parsed.group);
    var stack = Stack.init(allocator);
    defer stack.deinit();
    const group = [4]u8{ 239, 1, 1, 1 };
    try stack.join(group, .exclude);
    const before = stack.reports_tx;
    stack.onQuery(parsed);
    p.query = stack.groups.items[0].timer_ms == 100 and stack.queries_rx == 1;
    stack.expire();
    p.membership = stack.reports_tx == before + 1 and stack.groups.items[0].reports == 1;
    stack.leave(group);
    p.leave = stack.leaves_tx == 1 and stack.groups.items.len == 0;
    p.status = "ok";
    return p;
}

test "igmp: exponential MRC/QQIC encoding follows RFC 3376" {
    try std.testing.expectEqual(@as(u8, 100), expEncode(100));
    try std.testing.expectEqual(@as(u32, 100), expDecode(100));
    try std.testing.expectEqual(@as(u8, 0xC9), expEncode(3200));
    try std.testing.expectEqual(@as(u32, 3200), expDecode(0xC9));
    try std.testing.expectEqual(@as(u8, 0xFF), expEncode(99_999));
    try std.testing.expectEqual(@as(u8, 0), expEncode(0));
}

test "igmp: query and report parse round-trip with checksum" {
    var bytes: [16]u8 = @splat(0);
    const v2 = Message{ .kind = HOST_QUERY, .code = 100, .group = all_routers, .checksum = 0 };
    const len = try v2.serialize(&bytes);
    try std.testing.expectEqual(@as(usize, 8), len);
    const parsed = try Message.parse(bytes[0..len]);
    try std.testing.expectEqual(@as(u8, HOST_QUERY), parsed.kind);
    try std.testing.expect(std.mem.eql(u8, &parsed.group, &all_routers));
    bytes[5] ^= 1;
    try std.testing.expectError(error.Checksum, Message.parse(bytes[0..len]));
}

test "igmp: query schedules a response and leave removes the group" {
    var stack = Stack.init(std.testing.allocator);
    defer stack.deinit();
    const group = [4]u8{ 239, 1, 1, 1 };
    try stack.join(group, .include);
    try std.testing.expectEqual(@as(usize, 1), stack.reports_tx);
    stack.onQuery(.{ .kind = HOST_QUERY, .code = 20, .group = zeroAddr(), .checksum = 0 });
    try std.testing.expectEqual(@as(u32, 100), stack.groups.items[0].timer_ms);
    stack.expire();
    try std.testing.expectEqual(@as(usize, 1), stack.groups.items[0].reports);
    stack.leave(group);
    try std.testing.expectEqual(@as(usize, 1), stack.leaves_tx);
    try std.testing.expectEqual(@as(usize, 0), stack.groups.items.len);
}

fn zeroAddr() [4]u8 {
    return [4]u8{ 0, 0, 0, 0 };
}

test "igmp: boot probe exercises encoding, parsing, query and leave" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.encoding);
    try std.testing.expect(p.message);
    try std.testing.expect(p.membership);
    try std.testing.expect(p.query);
    try std.testing.expect(p.leave);
}
