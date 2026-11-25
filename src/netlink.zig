//! Порт ядра netlink Linux 7.3: include/uapi/linux/netlink.h (struct nlmsghdr,
//! NLMSG_OK/NLMSG_NEXT, struct nlattr, NLA_*), include/net/netlink.h
//! (nla_ok/nla_next/nla_type/nla_len) и net/netlink/af_netlink.c
//! (netlink_rcv_skb, netlink_bind, multicast groups). GPL-2.0-only.

const std = @import("std");

pub const NLMSG_ALIGNTO: usize = 4;
pub const NLMSG_HDRLEN: usize = 16;
pub const NLA_ALIGNTO: usize = 4;
pub const NLA_HDRLEN: usize = 4;

pub const NLM_F_REQUEST: u16 = 0x01;
pub const NLM_F_MULTI: u16 = 0x02;
pub const NLM_F_ACK: u16 = 0x04;
pub const NLM_F_REPLACE: u16 = 0x100;
pub const NLM_F_EXCL: u16 = 0x200;
pub const NLM_F_CREATE: u16 = 0x400;

pub const NLMSG_NOOP: u16 = 0x1;
pub const NLMSG_ERROR: u16 = 0x2;
pub const NLMSG_DONE: u16 = 0x3;
pub const NLMSG_OVERRUN: u16 = 0x4;
pub const NLMSG_MIN_TYPE: u16 = 0x10;

pub const NLA_F_NESTED: u16 = 1 << 15;
pub const NLA_F_NET_BYTEORDER: u16 = 1 << 14;
pub const NLA_TYPE_MASK: u16 = ~(NLA_F_NESTED | NLA_F_NET_BYTEORDER);

pub const NETLINK_ROUTE: u16 = 0;
pub const NETLINK_GENERIC: u16 = 16;

pub fn nlmsgAlign(len: usize) usize {
    return (len + NLMSG_ALIGNTO - 1) & ~(NLMSG_ALIGNTO - 1);
}

pub fn nlaAlign(len: usize) usize {
    return (len + NLA_ALIGNTO - 1) & ~(NLA_ALIGNTO - 1);
}

/// Netlink использует host byte order; на целевой x86_64 это little-endian.
fn read16(bytes: []const u8, off: usize) u16 {
    return @as(u16, bytes[off]) | (@as(u16, bytes[off + 1]) << 8);
}

fn write16(bytes: []u8, off: usize, value: u16) void {
    bytes[off] = @truncate(value);
    bytes[off + 1] = @truncate(value >> 8);
}

fn read32(bytes: []const u8, off: usize) u32 {
    return @as(u32, bytes[off]) | (@as(u32, bytes[off + 1]) << 8) |
        (@as(u32, bytes[off + 2]) << 16) | (@as(u32, bytes[off + 3]) << 24);
}

fn write32(bytes: []u8, off: usize, value: u32) void {
    bytes[off] = @truncate(value);
    bytes[off + 1] = @truncate(value >> 8);
    bytes[off + 2] = @truncate(value >> 16);
    bytes[off + 3] = @truncate(value >> 24);
}

/// include/uapi/linux/netlink.h: struct nlmsghdr (16 байт).
pub const Header = struct {
    len: u32,
    kind: u16,
    flags: u16,
    seq: u32,
    pid: u32,

    pub fn serialize(self: Header, out: []u8) !void {
        if (out.len < NLMSG_HDRLEN) return error.NoSpace;
        write32(out, 0, self.len);
        write16(out, 4, self.kind);
        write16(out, 6, self.flags);
        write32(out, 8, self.seq);
        write32(out, 12, self.pid);
    }

    pub fn parse(bytes: []const u8) !Header {
        if (bytes.len < NLMSG_HDRLEN) return error.Truncated;
        return .{
            .len = read32(bytes, 0),
            .kind = read16(bytes, 4),
            .flags = read16(bytes, 6),
            .seq = read32(bytes, 8),
            .pid = read32(bytes, 12),
        };
    }
};

pub const Message = struct {
    header: Header,
    payload: []const u8,
    raw: []const u8,
};

/// NLMSG_OK() + NLMSG_NEXT(): граница сообщения всегда выравнивается на 4,
/// но последний шаг усекается по длине буфера, как в netlink_rcv_skb().
pub fn nextMessage(bytes: []const u8, off: *usize) ?Message {
    if (off.* > bytes.len or bytes.len - off.* < NLMSG_HDRLEN) return null;
    const h = Header.parse(bytes[off.*..]) catch return null;
    if (h.len < NLMSG_HDRLEN or h.len > bytes.len - off.*) return null;
    const start = off.*;
    const msg = Message{
        .header = h,
        .payload = bytes[start + NLMSG_HDRLEN .. start + h.len],
        .raw = bytes[start .. start + h.len],
    };
    var step = nlmsgAlign(h.len);
    if (step > bytes.len - off.*) step = bytes.len - off.*;
    off.* += step;
    return msg;
}

pub fn countMessages(bytes: []const u8) usize {
    var off: usize = 0;
    var n: usize = 0;
    while (nextMessage(bytes, &off) != null) n += 1;
    return n;
}

/// include/net/netlink.h: struct nlattr (4 байта).
pub const Attr = struct {
    len: u16,
    raw_type: u16,

    pub fn typ(self: Attr) u16 {
        return self.raw_type & NLA_TYPE_MASK;
    }
    pub fn nested(self: Attr) bool {
        return (self.raw_type & NLA_F_NESTED) != 0;
    }
    pub fn networkByteOrder(self: Attr) bool {
        return (self.raw_type & NLA_F_NET_BYTEORDER) != 0;
    }
    pub fn payloadLen(self: Attr) u16 {
        return self.len - @as(u16, NLA_HDRLEN);
    }
};

pub const ParsedAttr = struct {
    attr: Attr,
    data: []const u8,
    raw: []const u8,
};

/// nla_ok() + nla_next() с выравниванием NLA_ALIGN().
pub fn nextAttr(bytes: []const u8, off: *usize) ?ParsedAttr {
    if (off.* > bytes.len or bytes.len - off.* < NLA_HDRLEN) return null;
    const len = read16(bytes, off.*);
    const raw_type = read16(bytes, off.* + 2);
    if (len < NLA_HDRLEN or len > bytes.len - off.*) return null;
    const start = off.*;
    const attr = Attr{ .len = len, .raw_type = raw_type };
    const result = ParsedAttr{
        .attr = attr,
        .data = bytes[start + NLA_HDRLEN .. start + len],
        .raw = bytes[start .. start + len],
    };
    var step = nlaAlign(len);
    if (step > bytes.len - off.*) step = bytes.len - off.*;
    off.* += step;
    return result;
}

/// nla_reserve()/nla_put(): nla_len не включает padding, но следующий
/// атрибут начинается на границе 4 байт.
pub fn putAttr(out: []u8, off: *usize, raw_type: u16, payload: []const u8) !void {
    const len = NLA_HDRLEN + payload.len;
    if (off.* > out.len or nlaAlign(len) > out.len - off.*) return error.NoSpace;
    write16(out, off.*, @intCast(len));
    write16(out, off.* + 2, raw_type);
    @memcpy(out[off.* + NLA_HDRLEN .. off.* + len], payload);
    off.* += nlaAlign(len);
}

/// netlink_bind(): pid 0 зарезервирован за ядром, группы — битовая маска.
pub const Socket = struct {
    family: u16 = NETLINK_ROUTE,
    pid: u32 = 0,
    groups: u32 = 0,
    bound: bool = false,

    pub fn bind(self: *Socket, family: u16, pid: u32, groups: u32) !void {
        if (self.bound or pid == 0) return error.Invalid;
        self.family = family;
        self.pid = pid;
        self.groups = groups;
        self.bound = true;
    }

    pub fn joinGroup(self: *Socket, group: u5) void {
        self.groups |= @as(u32, 1) << group;
    }

    pub fn leaveGroup(self: *Socket, group: u5) void {
        self.groups &= ~(@as(u32, 1) << group);
    }

    pub fn inGroup(self: *const Socket, group: u5) bool {
        return (self.groups & (@as(u32, 1) << group)) != 0;
    }
};

pub const Dispatch = struct {
    seen: usize = 0,
    handled: usize = 0,
    acked: usize = 0,
    failed: usize = 0,
};

/// netlink_rcv_skb(): только NLM_F_REQUEST и типы >= NLMSG_MIN_TYPE
/// попадают в обработчик; ACK или ошибка порождают netlink_ack().
pub fn dispatch(bytes: []const u8, cb: *const fn (Message) i32) Dispatch {
    var result = Dispatch{};
    var off: usize = 0;
    while (bytes.len - off >= NLMSG_HDRLEN) {
        const h = Header.parse(bytes[off..]) catch return result;
        if (h.len < NLMSG_HDRLEN or h.len > bytes.len - off) return result;
        result.seen += 1;
        const msg = Message{
            .header = h,
            .payload = bytes[off + NLMSG_HDRLEN .. off + h.len],
            .raw = bytes[off .. off + h.len],
        };
        var err: i32 = 0;
        if ((h.flags & NLM_F_REQUEST) == 0 or h.kind < NLMSG_MIN_TYPE) {
            err = 0;
        } else {
            err = cb(msg);
            result.handled += 1;
            if (err != 0) result.failed += 1;
        }
        if ((h.flags & NLM_F_ACK) != 0 or err != 0) result.acked += 1;
        var step = nlmsgAlign(h.len);
        if (step > bytes.len - off) step = bytes.len - off;
        off += step;
    }
    return result;
}

fn routeHandler(msg: Message) i32 {
    if (msg.payload.len < 4) return -1;
    var off: usize = 0;
    const first = nextAttr(msg.payload, &off) orelse return -1;
    if (first.attr.typ() != 1 or first.attr.nested()) return -1;
    return 0;
}

pub const Probe = struct {
    status: []const u8 = "none",
    header: bool = false,
    messages: bool = false,
    attrs: bool = false,
    dispatch: bool = false,
    socket: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    var hdr_bytes: [NLMSG_HDRLEN]u8 = @splat(0);
    const header = Header{
        .len = 20,
        .kind = NLMSG_MIN_TYPE + 1,
        .flags = NLM_F_REQUEST | NLM_F_ACK,
        .seq = 3,
        .pid = 42,
    };
    header.serialize(&hdr_bytes) catch return p;
    const parsed = Header.parse(&hdr_bytes) catch return p;
    p.header = parsed.len == 20 and parsed.kind == NLMSG_MIN_TYPE + 1 and
        parsed.flags == (NLM_F_REQUEST | NLM_F_ACK) and parsed.seq == 3 and parsed.pid == 42;

    var stream: [64]u8 = @splat(0);
    var off: usize = 0;
    header.serialize(stream[off..]) catch return p;
    stream[off + NLMSG_HDRLEN] = 4;
    stream[off + NLMSG_HDRLEN + 2] = 1;
    off += 20;
    const noop = Header{ .len = NLMSG_HDRLEN, .kind = NLMSG_NOOP, .flags = 0, .seq = 4, .pid = 42 };
    noop.serialize(stream[off..]) catch return p;
    off += NLMSG_HDRLEN;
    const third = Header{ .len = 19, .kind = NLMSG_MIN_TYPE + 2, .flags = NLM_F_REQUEST, .seq = 5, .pid = 42 };
    third.serialize(stream[off..]) catch return p;
    off += 19;
    var cursor: usize = 0;
    const m1 = nextMessage(stream[0..off], &cursor) orelse return p;
    const m2 = nextMessage(stream[0..off], &cursor) orelse return p;
    const m3 = nextMessage(stream[0..off], &cursor) orelse return p;
    p.messages = m1.payload.len == 4 and m1.payload[0] == 4 and m1.payload[2] == 1 and
        m2.header.kind == NLMSG_NOOP and m3.header.len == 19 and
        countMessages(stream[0..off]) == 3 and nextMessage(stream[0..off], &cursor) == null;
    var truncated: [16]u8 = @splat(0);
    write32(&truncated, 0, 32);
    var bad_cursor: usize = 0;
    if (nextMessage(&truncated, &bad_cursor) != null) return p;

    var attrs: [32]u8 = @splat(0);
    var aoff: usize = 0;
    putAttr(&attrs, &aoff, 1, &[_]u8{7}) catch return p;
    putAttr(&attrs, &aoff, NLA_F_NESTED | 3, &[_]u8{ 0, 0, 0, 0 }) catch return p;
    putAttr(&attrs, &aoff, NLA_F_NET_BYTEORDER | 4, &[_]u8{ 1, 2 }) catch return p;
    var acursor: usize = 0;
    const a1 = nextAttr(&attrs, &acursor) orelse return p;
    const a2 = nextAttr(&attrs, &acursor) orelse return p;
    const a3 = nextAttr(&attrs, &acursor) orelse return p;
    p.attrs = aoff == 24 and a1.attr.typ() == 1 and a1.data.len == 1 and a1.data[0] == 7 and
        a2.attr.typ() == 3 and a2.attr.nested() and a2.data.len == 4 and
        a3.attr.typ() == 4 and a3.attr.networkByteOrder() and a3.data.len == 2 and
        nextAttr(&attrs, &acursor) == null;

    const handled = dispatch(stream[0..off], routeHandler);
    p.dispatch = handled.seen == 3 and handled.handled == 2 and handled.acked == 2 and
        handled.failed == 1;

    var sock = Socket{};
    sock.bind(NETLINK_GENERIC, 1234, 1) catch return p;
    sock.joinGroup(3);
    const joined = sock.inGroup(3);
    sock.leaveGroup(3);
    p.socket = joined and !sock.inGroup(3) and sock.inGroup(0) and
        sock.pid == 1234 and sock.bound and sock.bind(NETLINK_ROUTE, 9, 0) == error.Invalid;

    p.status = "ok";
    return p;
}

test "netlink: nlmsghdr round-trip and NLMSG_OK truncation rules" {
    var bytes: [NLMSG_HDRLEN]u8 = @splat(0);
    const h = Header{ .len = 24, .kind = 0x12, .flags = NLM_F_REQUEST | NLM_F_CREATE, .seq = 9, .pid = 7 };
    try h.serialize(&bytes);
    const parsed = try Header.parse(&bytes);
    try std.testing.expectEqual(@as(u32, 24), parsed.len);
    try std.testing.expectEqual(@as(u16, 0x12), parsed.kind);
    try std.testing.expectEqual(@as(u32, 9), parsed.seq);
    try std.testing.expectError(error.Truncated, Header.parse(bytes[0..15]));
    try std.testing.expectEqual(@as(usize, 16), nlmsgAlign(13));
}

test "netlink: message stream honours aligned boundaries and rejects short headers" {
    var stream: [40]u8 = @splat(0);
    const h1 = Header{ .len = 19, .kind = NLMSG_MIN_TYPE + 1, .flags = NLM_F_REQUEST, .seq = 1, .pid = 1 };
    try h1.serialize(stream[0..]);
    stream[16] = 0xAB;
    const h2 = Header{ .len = NLMSG_HDRLEN, .kind = NLMSG_DONE, .flags = 0, .seq = 2, .pid = 1 };
    try h2.serialize(stream[20..]);
    var off: usize = 0;
    const m1 = nextMessage(&stream, &off).?;
    const m2 = nextMessage(&stream, &off).?;
    try std.testing.expectEqual(@as(usize, 3), m1.payload.len);
    try std.testing.expectEqual(@as(u8, 0xAB), m1.payload[0]);
    try std.testing.expectEqual(@as(u16, NLMSG_DONE), m2.header.kind);
    try std.testing.expectEqual(@as(usize, 2), countMessages(&stream));
    var no_more: usize = off;
    try std.testing.expect(nextMessage(&stream, &no_more) == null);
    var short_buf: [20]u8 = @splat(0);
    write32(&short_buf, 0, 4);
    var bad: usize = 0;
    try std.testing.expect(nextMessage(&short_buf, &bad) == null);
}

test "netlink: attributes mask type flags, skip padding and validate length" {
    var bytes: [24]u8 = @splat(0);
    var off: usize = 0;
    try putAttr(&bytes, &off, 1, &[_]u8{ 1, 2, 3 });
    try putAttr(&bytes, &off, NLA_F_NESTED | NLA_F_NET_BYTEORDER | 6, &[_]u8{4});
    try std.testing.expectEqual(@as(usize, 16), off);
    var cursor: usize = 0;
    const a1 = nextAttr(&bytes, &cursor).?;
    const a2 = nextAttr(&bytes, &cursor).?;
    try std.testing.expectEqual(@as(u16, 1), a1.attr.typ());
    try std.testing.expectEqual(@as(u16, 3), a1.attr.payloadLen());
    try std.testing.expect(a2.attr.nested());
    try std.testing.expect(a2.attr.networkByteOrder());
    try std.testing.expectEqual(@as(u16, 6), a2.attr.typ());
    try std.testing.expect(nextAttr(&bytes, &cursor) == null);
    var bad: [4]u8 = @splat(0);
    write16(&bad, 0, 2);
    var bad_cursor: usize = 0;
    try std.testing.expect(nextAttr(&bad, &bad_cursor) == null);
}

test "netlink: receive dispatch acknowledges requests and skips control messages" {
    var stream: [64]u8 = @splat(0);
    var off: usize = 0;
    const req = Header{ .len = 20, .kind = NLMSG_MIN_TYPE + 1, .flags = NLM_F_REQUEST | NLM_F_ACK, .seq = 1, .pid = 1 };
    try req.serialize(stream[off..]);
    stream[off + NLMSG_HDRLEN] = 4;
    stream[off + NLMSG_HDRLEN + 2] = 1;
    off += 20;
    const noop = Header{ .len = NLMSG_HDRLEN, .kind = NLMSG_NOOP, .flags = 0, .seq = 2, .pid = 1 };
    try noop.serialize(stream[off..]);
    off += NLMSG_HDRLEN;
    const bad = Header{ .len = NLMSG_HDRLEN, .kind = NLMSG_MIN_TYPE + 2, .flags = NLM_F_REQUEST, .seq = 3, .pid = 1 };
    try bad.serialize(stream[off..]);
    off += NLMSG_HDRLEN;
    const result = dispatch(stream[0..off], routeHandler);
    try std.testing.expectEqual(@as(usize, 3), result.seen);
    try std.testing.expectEqual(@as(usize, 2), result.handled);
    try std.testing.expectEqual(@as(usize, 2), result.acked);
    try std.testing.expectEqual(@as(usize, 1), result.failed);
}

test "netlink: bind and multicast membership" {
    var sock = Socket{};
    try std.testing.expectError(error.Invalid, sock.bind(NETLINK_ROUTE, 0, 0));
    try sock.bind(NETLINK_GENERIC, 4321, 1);
    sock.joinGroup(5);
    try std.testing.expect(sock.inGroup(0));
    try std.testing.expect(sock.inGroup(5));
    sock.leaveGroup(5);
    try std.testing.expect(!sock.inGroup(5));
    try std.testing.expectError(error.Invalid, sock.bind(NETLINK_ROUTE, 1, 0));
}

test "netlink: boot probe exercises header, messages, attrs, dispatch and socket" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.header);
    try std.testing.expect(p.messages);
    try std.testing.expect(p.attrs);
    try std.testing.expect(p.dispatch);
    try std.testing.expect(p.socket);
}
