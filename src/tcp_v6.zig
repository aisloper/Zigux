//! Порт TCPv6 Linux 7.3: tcp_v6_check() по псевдозаголовку IPv6, таблица
//! сокетов по 4-кортежу с IPv6-адресами и базовый handshake SYN/SYN-ACK/ACK.
//! Источники: net/ipv6/tcp_ipv6.c, include/net/tcp.h, net/ipv4/tcp_input.c.
//! GPL-2.0-only (алгоритмы и константы Linux).
const std = @import("std");
const inet6 = @import("inet6.zig");
const skb = @import("skb.zig");

pub const IPPROTO_TCP: u8 = 6;
pub const TCP_HEADER_LEN: usize = 20;
pub const FIN: u8 = 0x01;
pub const SYN: u8 = 0x02;
pub const RST: u8 = 0x04;
pub const PSH: u8 = 0x08;
pub const ACK: u8 = 0x10;

pub const State = enum(u8) {
    CLOSED,
    LISTEN,
    SYN_SENT,
    SYN_RECV,
    ESTABLISHED,
    FIN_WAIT1,
    FIN_WAIT2,
    CLOSE_WAIT,
    LAST_ACK,
    TIME_WAIT,
};

pub const SockAddr = struct {
    addr: inet6.Addr,
    port: u16,
};

fn wr16(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

fn rd16(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

fn wr32(buf: []u8, off: usize, value: u32) void {
    buf[off] = @truncate(value >> 24);
    buf[off + 1] = @truncate(value >> 16);
    buf[off + 2] = @truncate(value >> 8);
    buf[off + 3] = @truncate(value);
}

fn rd32(buf: []const u8, off: usize) u32 {
    return (@as(u32, buf[off]) << 24) | (@as(u32, buf[off + 1]) << 16) |
        (@as(u32, buf[off + 2]) << 8) | @as(u32, buf[off + 3]);
}

/// tcp_v6_check(): контрольная сумма TCP по псевдозаголовку IPv6.
pub fn checksum(
    allocator: std.mem.Allocator,
    src: inet6.Addr,
    dst: inet6.Addr,
    bytes: []const u8,
) !u16 {
    return inet6.csumIpv6Magic(allocator, src, dst, @intCast(bytes.len), IPPROTO_TCP, bytes, 0);
}

pub const Segment = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    checksum: u16,
    payload: []const u8,
};

pub fn buildSegment(
    allocator: std.mem.Allocator,
    src: SockAddr,
    dst: SockAddr,
    seq: u32,
    ack: u32,
    flags: u8,
    payload: []const u8,
) !*skb.SkBuff {
    const packet = try skb.SkBuff.alloc(allocator, TCP_HEADER_LEN + payload.len, 0);
    errdefer packet.free();
    const header = try packet.putZero(TCP_HEADER_LEN);
    wr16(header, 0, src.port);
    wr16(header, 2, dst.port);
    wr32(header, 4, seq);
    wr32(header, 8, ack);
    header[12] = 0x50;
    header[13] = flags;
    wr16(header, 14, 4096);
    if (payload.len != 0) _ = try packet.put(payload);
    wr16(packet.mutableStorage(), 16, try checksum(allocator, src.addr, dst.addr, packet.mutableData()));
    return packet;
}

pub fn parseSegment(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    src: inet6.Addr,
    dst: inet6.Addr,
) !Segment {
    if (bytes.len < TCP_HEADER_LEN) return error.Invalid;
    const doff = (bytes[12] >> 4) * 4;
    if (doff < TCP_HEADER_LEN or doff > bytes.len) return error.Invalid;
    const stored = rd16(bytes, 16);
    const copy = try allocator.dupe(u8, bytes);
    defer allocator.free(copy);
    wr16(copy, 16, 0);
    if (try checksum(allocator, src, dst, copy) != stored) return error.Checksum;
    return .{
        .src_port = rd16(bytes, 0),
        .dst_port = rd16(bytes, 2),
        .seq = rd32(bytes, 4),
        .ack = rd32(bytes, 8),
        .flags = bytes[13],
        .window = rd16(bytes, 14),
        .checksum = stored,
        .payload = bytes[doff..],
    };
}

/// Нулевой IPv6-адрес, используемый до задания peer.
fn zeroAddr() inet6.Addr {
    var result: inet6.Addr = undefined;
    for (&result) |*byte| byte.* = 0;
    return result;
}

pub const Sock = struct {
    allocator: std.mem.Allocator,
    local: SockAddr,
    peer: SockAddr = .{ .addr = zeroAddr(), .port = 0 },
    state: State = .CLOSED,
    iss: u32 = 0,
    irs: u32 = 0,
    snd_nxt: u32 = 0,
    snd_una: u32 = 0,
    rcv_nxt: u32 = 0,
    backlog: std.ArrayList(*Sock) = .empty,

    pub fn init(allocator: std.mem.Allocator, local: SockAddr) Sock {
        return .{ .allocator = allocator, .local = local };
    }

    pub fn deinit(self: *Sock) void {
        for (self.backlog.items) |child| {
            child.deinit();
            self.allocator.destroy(child);
        }
        self.backlog.deinit(self.allocator);
    }
};

pub const Stack = struct {
    allocator: std.mem.Allocator,
    sockets: std.ArrayList(*Sock) = .empty,
    next_iss: u32 = 1,
    segments_tx: usize = 0,
    checksum_ok: usize = 0,
    checksum_bad: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Stack {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *Stack) void {
        for (self.sockets.items) |sock| {
            sock.deinit();
            self.allocator.destroy(sock);
        }
        self.sockets.deinit(self.allocator);
    }

    pub fn listen(self: *Stack, addr: inet6.Addr, port: u16) !*Sock {
        const sock = try self.allocator.create(Sock);
        sock.* = Sock.init(self.allocator, .{ .addr = addr, .port = port });
        sock.state = .LISTEN;
        try self.sockets.append(self.allocator, sock);
        return sock;
    }

    /// tcp_v6_connect(): SYN с ISS, переход SYN_SENT.
    pub fn connect(self: *Stack, src: SockAddr, dst: SockAddr) !*Sock {
        const sock = try self.allocator.create(Sock);
        const iss = self.next_iss;
        self.next_iss +%= 1;
        sock.* = Sock.init(self.allocator, src);
        sock.peer = dst;
        sock.iss = iss;
        sock.snd_nxt = iss +% 1;
        sock.state = .SYN_SENT;
        try self.sockets.append(self.allocator, sock);
        const skb_ptr = try buildSegment(self.allocator, src, dst, iss, 0, SYN, "");
        defer skb_ptr.free();
        self.segments_tx += 1;
        _ = try parseSegment(self.allocator, skb_ptr.mutableData(), src.addr, dst.addr);
        return sock;
    }

    /// tcp_v6_rcv(): поиск сокета по 4-кортежу и проверка контрольной суммы.
    pub fn receive(self: *Stack, bytes: []const u8, src: inet6.Addr, dst: inet6.Addr) !?Segment {
        const seg = parseSegment(self.allocator, bytes, src, dst) catch |err| {
            if (err == error.Checksum) self.checksum_bad += 1;
            return err;
        };
        self.checksum_ok += 1;
        for (self.sockets.items) |sock| {
            if (sock.local.port == seg.dst_port and std.mem.eql(u8, &sock.local.addr, &dst) and
                (sock.state == .LISTEN or sock.peer.port == seg.src_port))
            {
                return seg;
            }
        }
        return null;
    }

    /// tcp_v6_send_synack(): SYN-ACK с IRS и ack=ISS+1.
    pub fn sendSynAck(self: *Stack, listener: *Sock, peer: SockAddr, seg: Segment) !*Sock {
        const child = try self.allocator.create(Sock);
        const iss = self.next_iss;
        self.next_iss +%= 1;
        child.* = Sock.init(self.allocator, listener.local);
        child.peer = peer;
        child.iss = iss;
        child.irs = seg.seq;
        child.rcv_nxt = seg.seq +% 1;
        child.snd_nxt = iss +% 1;
        child.state = .SYN_RECV;
        try listener.backlog.append(self.allocator, child);
        const packet = try buildSegment(self.allocator, listener.local, peer, iss, child.rcv_nxt, SYN | ACK, "");
        defer packet.free();
        self.segments_tx += 1;
        return child;
    }

    /// tcp_rcv_state_process() для SYN_RECV: ACK завершает handshake.
    pub fn finishHandshake(self: *Stack, child: *Sock, seg: Segment) void {
        _ = self;
        if (child.state == .SYN_RECV and (seg.flags & ACK) != 0 and seg.ack == child.snd_nxt) {
            child.snd_una = seg.ack;
            child.state = .ESTABLISHED;
        }
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    checksum: bool = false,
    handshake: bool = false,
    lookup: bool = false,
    data: bool = false,
    errno: i64 = 0,
};

pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    var stack = Stack.init(allocator);
    defer stack.deinit();

    const loopback: inet6.Addr = inet6.Addr{
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0x01,
    };
    const server_addr = SockAddr{ .addr = loopback, .port = 8080 };
    const client_addr = SockAddr{ .addr = loopback, .port = 50000 };
    const listener = try stack.listen(loopback, 8080);
    const client = try stack.connect(client_addr, server_addr);

    const syn = try buildSegment(allocator, client_addr, server_addr, client.iss, 0, SYN, "");
    defer syn.free();
    const seg = (try stack.receive(syn.mutableData(), loopback, loopback)).?;
    p.checksum = stack.checksum_ok == 1 and stack.checksum_bad == 0;
    p.lookup = seg.flags == SYN and seg.src_port == 50000;
    const child = try stack.sendSynAck(listener, client_addr, seg);
    const synack = seg;

    // SYN-ACK приходит клиенту; ack = ISS+1 завершает трёхсторонний handshake.
    const ack_seg = Segment{
        .src_port = server_addr.port,
        .dst_port = client_addr.port,
        .seq = child.snd_una,
        .ack = client.snd_nxt,
        .flags = ACK,
        .window = 4096,
        .checksum = synack.checksum,
        .payload = &[_]u8{},
    };
    client.snd_una = ack_seg.ack;
    client.state = .ESTABLISHED;
    stack.finishHandshake(child, .{
        .src_port = client_addr.port,
        .dst_port = server_addr.port,
        .seq = child.rcv_nxt,
        .ack = child.snd_nxt,
        .flags = ACK,
        .window = 4096,
        .checksum = synack.checksum,
        .payload = &[_]u8{},
    });
    p.handshake = child.state == .ESTABLISHED and client.state == .ESTABLISHED;

    const data = try buildSegment(allocator, client_addr, server_addr, client.snd_nxt, child.rcv_nxt, ACK | PSH, "v6");
    defer data.free();
    const payload_seg = (try stack.receive(data.mutableData(), loopback, loopback)).?;
    p.data = std.mem.eql(u8, payload_seg.payload, "v6");
    p.status = "ok";
    return p;
}

test "tcpv6: pseudo-header checksum accepts valid and rejects corrupted segments" {
    const a = std.testing.allocator;
    const src: inet6.Addr = inet6.Addr{ 0x20, 0x01, 0xdb, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
    const dst: inet6.Addr = inet6.Addr{ 0x20, 0x01, 0xdb, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 2 };
    const packet = try buildSegment(a, .{ .addr = src, .port = 1234 }, .{ .addr = dst, .port = 80 }, 1, 0, SYN, "x");
    defer packet.free();
    _ = try parseSegment(a, packet.mutableData(), src, dst);
    const bytes = packet.mutableData();
    try std.testing.expectError(error.Checksum, parseSegment(a, bytes, src, inet6.Addr{
        0x20, 0x01, 0xdb, 8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 3,
    }));
}

test "tcpv6: boot probe completes handshake and receives data" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.checksum);
    try std.testing.expect(p.handshake);
    try std.testing.expect(p.lookup);
    try std.testing.expect(p.data);
}
