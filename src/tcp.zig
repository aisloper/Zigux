//! Порт TCP из Linux 7.3 (loopback-срез): состояния из include/net/tcp_states.h,
//! заголовок struct tcphdr, контрольная сумма tcp_v4_check() с псевдозаголовком
//! IPv4, трёхстороннее установление соединения, передача потока с ACK и
//! ретрансляцией, закрытие FIN. Источники: include/net/tcp_states.h,
//! include/uapi/linux/tcp.h, include/net/tcp.h, net/ipv4/tcp.c,
//! net/ipv4/tcp_input.c, net/ipv4/tcp_ipv4.c, net/ipv4/tcp_cong.c.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const skbuff = @import("skb.zig");
const tcp_ca = @import("tcp_ca.zig");
const tcp_options = @import("tcp_options.zig");

pub const IPPROTO_TCP: u8 = 6;
pub const TCP_MSS: usize = 536;
pub const TCP_DEFAULT_WND: u16 = 4096;
pub const TCP_MAX_RETRIES: u8 = 3;
pub const TCP_RTO_MIN: u32 = 200;
pub const TCP_RTO_MAX: u32 = 51200;

/// include/net/tcp_states.h: sk_state TCP-сокета.
pub const State = enum(u8) {
    CLOSED = 0,
    ESTABLISHED = 1,
    SYN_SENT = 2,
    SYN_RECV = 3,
    FIN_WAIT1 = 4,
    FIN_WAIT2 = 5,
    TIME_WAIT = 6,
    CLOSE = 7,
    CLOSE_WAIT = 8,
    LAST_ACK = 9,
    LISTEN = 10,
    CLOSING = 11,
};

pub fn stateName(s: State) []const u8 {
    return switch (s) {
        .CLOSED => "CLOSED",
        .ESTABLISHED => "ESTABLISHED",
        .SYN_SENT => "SYN_SENT",
        .SYN_RECV => "SYN_RECV",
        .FIN_WAIT1 => "FIN_WAIT1",
        .FIN_WAIT2 => "FIN_WAIT2",
        .TIME_WAIT => "TIME_WAIT",
        .CLOSE => "CLOSE",
        .CLOSE_WAIT => "CLOSE_WAIT",
        .LAST_ACK => "LAST_ACK",
        .LISTEN => "LISTEN",
        .CLOSING => "CLOSING",
    };
}

/// include/uapi/linux/tcp.h: биты второго 16-битного слова tcphdr
/// (little-endian раскладка, используется в QEMU x86_64).
pub const Flag = struct {
    pub const FIN: u8 = 1 << 0;
    pub const SYN: u8 = 1 << 1;
    pub const RST: u8 = 1 << 2;
    pub const PSH: u8 = 1 << 3;
    pub const ACK: u8 = 1 << 4;
    pub const URG: u8 = 1 << 5;
    pub const ECE: u8 = 1 << 6;
    pub const CWR: u8 = 1 << 7;
};

pub const SockAddr = struct {
    port: u16,
    addr: [4]u8 = .{ 127, 0, 0, 1 },
};

pub const Segment = struct {
    src_port: u16,
    dst_port: u16,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    checksum: u16,
    payload: []const u8,
    options: []const u8 = &.{},
};

/// Явный набор ошибок разрывает цикл вывода error set между input()/reply().
pub const TcpError = error{
    Invalid,
    Checksum,
    NoMemory,
    NotConnected,
    AddrInUse,
    Full,
    WouldBlock,
    OutOfMemory,
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

/// csum_tcpudp_magic() из include/net/tcp.h: псевдозаголовок IPv4 (src, dst,
/// zero, IPPROTO_TCP, tcp length) плюс сегмент с нулевым полем check.
fn checksum(allocator: std.mem.Allocator, src: [4]u8, dst: [4]u8, segment: []const u8) !u16 {
    const buf = try allocator.alloc(u8, 12 + segment.len);
    defer allocator.free(buf);
    @memcpy(buf[0..4], &src);
    @memcpy(buf[4..8], &dst);
    buf[8] = 0;
    buf[9] = IPPROTO_TCP;
    wr16(buf, 10, @intCast(segment.len));
    @memcpy(buf[12..], segment);
    return skbuff.checksum(buf);
}

/// Собрать полный TCP-сегмент в sk_buff, включая checksum и полезную нагрузку.
/// Возвращает владельца буфера — вызывающий обязан освободить его через free().
pub fn buildSegment(
    allocator: std.mem.Allocator,
    src: SockAddr,
    dst: SockAddr,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    payload: []const u8,
) !*skbuff.SkBuff {
    return buildSegmentOpt(allocator, src, dst, seq, ack, flags, window, payload, &.{});
}

/// tcphdr с опциями: doff увеличивается на длину выровненных опций.
pub fn buildSegmentOpt(
    allocator: std.mem.Allocator,
    src: SockAddr,
    dst: SockAddr,
    seq: u32,
    ack: u32,
    flags: u8,
    window: u16,
    payload: []const u8,
    options: []const u8,
) !*skbuff.SkBuff {
    if (options.len % 4 != 0) return error.Invalid;
    const header_len = 20 + options.len;
    const skb = try skbuff.SkBuff.alloc(allocator, header_len + payload.len, 0);
    errdefer skb.free();
    const header = try skb.putZero(header_len);
    wr16(header, 0, src.port);
    wr16(header, 2, dst.port);
    wr32(header, 4, seq);
    wr32(header, 8, ack);
    header[12] = @intCast((5 + options.len / 4) << 4);
    header[13] = flags;
    wr16(header, 14, window);
    wr16(header, 16, 0);
    wr16(header, 18, 0);
    if (options.len != 0) @memcpy(header[20..], options);
    if (payload.len != 0) _ = try skb.put(payload);

    const bytes = skb.mutableStorage();
    wr16(bytes, 16, try checksum(allocator, src.addr, dst.addr, bytes));
    return skb;
}

/// snd_wnd из заголовка умножается на согласованный snd_wscale.
fn scaledSndWnd(sock: *const Sock) u32 {
    return @as(u32, sock.snd_wnd) << @intCast(sock.snd_wscale);
}

/// Размер окна в заголовке: rcv_wnd << rcv_wscale, не более 65535.
fn advertisedWnd(sock: *const Sock) u16 {
    return @truncate(@min(@as(u32, sock.rcv_wnd) << @intCast(sock.rcv_wscale), 65535));
}

/// Разобрать сегмент из sk_buff и проверить checksum по псевдозаголовку.
pub fn parseSegment(allocator: std.mem.Allocator, bytes: []const u8, src: [4]u8, dst: [4]u8) !Segment {
    if (bytes.len < 20) return error.Invalid;
    const doff = (bytes[12] >> 4) * 4;
    if (doff < 20 or doff > bytes.len) return error.Invalid;
    const stored = rd16(bytes, 16);
    const copy = try allocator.dupe(u8, bytes);
    defer allocator.free(copy);
    wr16(copy, 16, 0);
    const expected = try checksum(allocator, src, dst, copy);
    if (expected != stored) return error.Checksum;
    return .{
        .src_port = rd16(bytes, 0),
        .dst_port = rd16(bytes, 2),
        .seq = rd32(bytes, 4),
        .ack = rd32(bytes, 8),
        .flags = bytes[13],
        .window = rd16(bytes, 14),
        .checksum = stored,
        .payload = bytes[doff..],
        .options = bytes[20..doff],
    };
}

/// Недостающий фрагмент потока, полученный вне порядка (tcp_ofo_queue).
const Gap = struct {
    seq: u32,
    bytes: []u8,
};

const Pending = struct {
    seq: u32,
    bytes: []u8,
    flags: u8,
    tries: u8 = 0,
};

pub const Sock = struct {
    allocator: std.mem.Allocator,
    state: State = .CLOSED,
    local: SockAddr = .{ .port = 0 },
    peer: SockAddr = .{ .port = 0 },
    iss: u32 = 0,
    irs: u32 = 0,
    snd_nxt: u32 = 0,
    snd_una: u32 = 0,
    rcv_nxt: u32 = 0,
    snd_wnd: u16 = TCP_DEFAULT_WND,
    rcv_wnd: u16 = TCP_DEFAULT_WND,
    recv_stream: std.ArrayList(u8),
    retransmit: std.ArrayList(Pending),
    accept_queue: std.ArrayList(*Sock),
    parent: ?*Sock = null,
    fin_sent: bool = false,
    fin_received: bool = false,
    time_wait: u8 = 0,
    backlog: usize = 4,
    /// Переговоры window scale (RFC 7323).
    ws_offered: u5 = 0,
    snd_wscale: u5 = 0,
    rcv_wscale: u5 = 0,
    sack_enabled: bool = false,
    /// Очередь вне Sequencing порядка и выборочные подтверждения.
    gaps: std.ArrayList(Gap),
    sacks: std.ArrayList(tcp_options.Range),
    /// tcp_backoff(): интервал ретрансляции удваивается до TCP_RTO_MAX.
    rto_ms: u32 = TCP_RTO_MIN,
    /// net/ipv4/tcp_cong.c: состояние Reno для этого сокета.
    ca: tcp_ca.Congestion = .{},
    /// Число данных сегментов в полёте (tp->packets_out).
    packets_out: u32 = 0,
    /// loopback без узкого места не limiting; тест может смоделировать его.
    cwnd_limited: bool = false,
};

fn enterTimeWait(sock: *Sock) void {
    sock.state = .TIME_WAIT;
    sock.time_wait = 2;
}

pub const Stack = struct {
    allocator: std.mem.Allocator,
    sockets: std.ArrayList(*Sock),
    next_iss: u32 = 1,
    next_port: u16 = 50000,
    segments_tx: usize = 0,
    segments_rx: usize = 0,
    checksum_ok: usize = 0,
    checksum_bad: usize = 0,
    retransmits: usize = 0,
    acks: usize = 0,
    drops: usize = 0,
    congestion_acks: usize = 0,
    fast_retransmits: usize = 0,
    timeouts: usize = 0,
    sack_blocks: usize = 0,
    sacked_segments: usize = 0,
    window_scales: usize = 0,
    backoffs: usize = 0,

    pub fn init(allocator: std.mem.Allocator) !*Stack {
        const self = try allocator.create(Stack);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .sockets = std.ArrayList(*Sock).empty,
        };
        return self;
    }

    fn freeSock(self: *Stack, sock: *Sock) void {
        for (sock.retransmit.items) |p| self.allocator.free(p.bytes);
        for (sock.gaps.items) |gap| self.allocator.free(gap.bytes);
        sock.gaps.deinit(self.allocator);
        sock.sacks.deinit(self.allocator);
        sock.retransmit.deinit(self.allocator);
        sock.recv_stream.deinit(self.allocator);
        sock.accept_queue.deinit(self.allocator);
        self.allocator.destroy(sock);
    }

    pub fn deinit(self: *Stack) void {
        for (self.sockets.items) |sock| self.freeSock(sock);
        self.sockets.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn socket(self: *Stack) !*Sock {
        const sock = try self.allocator.create(Sock);
        errdefer self.allocator.destroy(sock);
        sock.* = .{
            .allocator = self.allocator,
            .recv_stream = std.ArrayList(u8).empty,
            .retransmit = std.ArrayList(Pending).empty,
            .accept_queue = std.ArrayList(*Sock).empty,
            .gaps = std.ArrayList(Gap).empty,
            .sacks = std.ArrayList(tcp_options.Range).empty,
            .ws_offered = tcp_options.DEFAULT_WS,
            .rcv_wscale = tcp_options.DEFAULT_WS,
        };
        try self.sockets.append(self.allocator, sock);
        return sock;
    }

    fn ephemeralPort(self: *Stack) u16 {
        const port = self.next_port;
        self.next_port = if (port == 65535) 50000 else port + 1;
        return port;
    }

    pub fn bind(self: *Stack, sock: *Sock, addr: SockAddr) !void {
        if (sock.local.port != 0 or addr.port == 0) return error.Invalid;
        for (self.sockets.items) |other| {
            if (other != sock and other.local.port == addr.port) return error.AddrInUse;
        }
        sock.local = addr;
    }

    fn assignLocal(self: *Stack, sock: *Sock) !void {
        if (sock.local.port != 0) return;
        var attempts: usize = 0;
        while (attempts < 16384) : (attempts += 1) {
            const port = self.ephemeralPort();
            var used = false;
            for (self.sockets.items) |other| {
                if (other.local.port == port) {
                    used = true;
                    break;
                }
            }
            if (!used) {
                sock.local.port = port;
                return;
            }
        }
        return error.Full;
    }

    /// tcp_listen(): из CLOSED в LISTEN, порт может быть назначен автоматически.
    pub fn listen(self: *Stack, sock: *Sock, backlog: usize) !void {
        if (sock.state != .CLOSED) return error.Invalid;
        try self.assignLocal(sock);
        sock.backlog = @max(1, backlog);
        sock.state = .LISTEN;
    }

    /// tcp_v4_connect(): ISS, SYN_SENT и отправка SYN (tcp_connect()).
    pub fn connect(self: *Stack, sock: *Sock, peer: SockAddr) !void {
        if (sock.state != .CLOSED or peer.port == 0) return error.Invalid;
        try self.assignLocal(sock);
        sock.peer = peer;
        sock.iss = self.next_iss;
        self.next_iss += 1;
        sock.snd_nxt = sock.iss;
        sock.snd_una = sock.iss;
        sock.state = .SYN_SENT;
        const options = try self.helloOptions(sock);
        defer self.allocator.free(options);
        try self.transmitDataOpt(sock, sock.iss, Flag.SYN, "", options);
        sock.snd_nxt = sock.iss + 1;
    }

    /// inet_csk_accept(): вернуть следующее установленное соединение из очереди.
    pub fn accept(self: *Stack, listener: *Sock) !*Sock {
        _ = self;
        if (listener.state != .LISTEN or listener.accept_queue.items.len == 0) return error.WouldBlock;
        return listener.accept_queue.orderedRemove(0);
    }

    /// tcp_sendmsg_locked(): разбить поток на MSS-сегменты и поставить в
    /// retransmit queue до получения ACK.
    pub fn send(self: *Stack, sock: *Sock, data: []const u8) !void {
        if (sock.state != .ESTABLISHED) return error.NotConnected;
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(TCP_MSS, data.len - off);
            if (sock.packets_out >= sock.ca.cwnd) return error.WouldBlock;
            // tcp_window_allows(): snd_wnd из заголовка домножается на
            // snd_wscale, согласованный в SYN/SYN-ACK.
            const in_flight = sock.snd_nxt -% sock.snd_una;
            if (in_flight + @as(u32, @intCast(n)) > scaledSndWnd(sock)) return error.WouldBlock;
            const bytes = try self.allocator.dupe(u8, data[off .. off + n]);
            errdefer self.allocator.free(bytes);
            try sock.retransmit.append(self.allocator, .{
                .seq = sock.snd_nxt,
                .bytes = bytes,
                .flags = Flag.PSH | Flag.ACK,
            });
            sock.snd_nxt += @intCast(n);
            sock.packets_out += 1;
            try self.transmitData(sock, sock.snd_nxt - @as(u32, @intCast(n)), Flag.PSH | Flag.ACK, bytes);
            off += n;
        }
    }

    pub fn recv(sock: *Sock, buf: []u8) !usize {
        if (sock.recv_stream.items.len == 0) return error.WouldBlock;
        const n = @min(buf.len, sock.recv_stream.items.len);
        @memcpy(buf[0..n], sock.recv_stream.items[0..n]);
        _ = sock.recv_stream.orderedRemove(0);
        var i: usize = 1;
        while (i < n) : (i += 1) _ = sock.recv_stream.orderedRemove(0);
        return n;
    }

    /// tcp_close(): FIN для активной стороны и для пассивной (CLOSE_WAIT).
    pub fn close(self: *Stack, sock: *Sock) !void {
        switch (sock.state) {
            .ESTABLISHED => {
                sock.fin_sent = true;
                sock.state = .FIN_WAIT1;
                try self.transmit(sock, Flag.FIN | Flag.ACK, "");
                sock.snd_nxt += 1;
            },
            .CLOSE_WAIT => {
                sock.fin_sent = true;
                sock.state = .LAST_ACK;
                try self.transmit(sock, Flag.FIN | Flag.ACK, "");
                sock.snd_nxt += 1;
            },
            .LISTEN => sock.state = .CLOSE,
            else => {},
        }
    }

    /// tcp_retransmit_timer(): повторить первый неподтверждённый сегмент.
    pub fn tick(self: *Stack) !void {
        for (self.sockets.items) |sock| {
            if (sock.state == .TIME_WAIT and sock.time_wait > 0) {
                sock.time_wait -= 1;
                if (sock.time_wait == 0) sock.state = .CLOSE;
            }
            if (sock.retransmit.items.len == 0) continue;
            const first = &sock.retransmit.items[0];
            if (first.tries >= TCP_MAX_RETRIES) continue;
            if (first.tries == 0) {
                sock.ca.onTimeout();
                self.timeouts += 1;
            } else {
                // tcp_backoff(): каждый следующий RTO удваивает интервал.
                sock.rto_ms = @min(sock.rto_ms * 2, TCP_RTO_MAX);
                self.backoffs += 1;
            }
            first.tries += 1;
            self.retransmits += 1;
            try self.transmitData(sock, first.seq, first.flags, first.bytes);
        }
    }

    fn transmit(self: *Stack, sock: *Sock, flags: u8, payload: []const u8) TcpError!void {
        try self.transmitData(sock, sock.snd_nxt, flags, payload);
    }

    fn transmitData(self: *Stack, sock: *Sock, seq: u32, flags: u8, payload: []const u8) TcpError!void {
        try self.transmitDataOpt(sock, seq, flags, payload, &.{});
    }

    fn transmitDataOpt(self: *Stack, sock: *Sock, seq: u32, flags: u8, payload: []const u8, options: []const u8) TcpError!void {
        const skb = try buildSegmentOpt(self.allocator, sock.local, sock.peer, seq, sock.rcv_nxt, flags, advertisedWnd(sock), payload, options);
        defer skb.free();
        self.segments_tx += 1;
        try self.deliver(skb.storageForChecksum(), sock);
    }

    /// SYN и SYN-ACK несут window scale и SACK permitted (RFC 7323/2018).
    fn helloOptions(self: *Stack, sock: *Sock) TcpError![]u8 {
        var list: std.ArrayList(u8) = .empty;
        errdefer list.deinit(self.allocator);
        try tcp_options.appendWindowScale(&list, self.allocator, sock.ws_offered);
        try tcp_options.appendSackPermitted(&list, self.allocator);
        return try list.toOwnedSlice(self.allocator);
    }

    /// Не возвращаем собственный сегмент отправителю.
    fn deliver(self: *Stack, bytes: []const u8, sender: *Sock) TcpError!void {
        const header_src = rd16(bytes, 0);
        const header_dst = rd16(bytes, 2);
        const peer = self.findPeer(sender, header_src, header_dst) orelse {
            self.drops += 1;
            return;
        };
        const seg = parseSegment(self.allocator, bytes, sender.local.addr, peer.local.addr) catch {
            self.checksum_bad += 1;
            return;
        };
        self.checksum_ok += 1;
        self.segments_rx += 1;
        try self.input(peer, seg);
    }

    fn findPeer(self: *Stack, sender: *Sock, src_port: u16, dst_port: u16) ?*Sock {
        for (self.sockets.items) |s| {
            if (s == sender or s.state == .CLOSED or s.state == .CLOSE) continue;
            if (s.local.port == dst_port and s.peer.port == src_port) return s;
        }
        for (self.sockets.items) |s| {
            if (s == sender or s.state != .LISTEN) continue;
            if (s.local.port == dst_port) return s;
        }
        return null;
    }

    fn input(self: *Stack, sock: *Sock, seg: Segment) TcpError!void {
        const opts = tcp_options.parse(seg.options);
        if (seg.flags & Flag.RST != 0) {
            sock.state = .CLOSE;
            return;
        }
        const has_ack = seg.flags & Flag.ACK != 0;
        const has_syn = seg.flags & Flag.SYN != 0;
        const has_fin = seg.flags & Flag.FIN != 0;

        if (sock.state == .LISTEN and has_syn) {
            if (sock.accept_queue.items.len >= sock.backlog) {
                self.drops += 1;
                return;
            }
            const child = try self.socket();
            child.local = sock.local;
            child.peer = .{ .port = seg.src_port, .addr = senderAddr(seg) };
            child.irs = seg.seq;
            child.rcv_nxt = seg.seq + 1;
            child.iss = self.next_iss;
            self.next_iss += 1;
            child.snd_nxt = child.iss + 1;
            child.snd_una = child.iss;
            child.parent = sock;
            child.state = .SYN_RECV;
            child.snd_wnd = seg.window;
            child.snd_wscale = opts.ws orelse 0;
            child.rcv_wscale = if (opts.ws != null) child.ws_offered else 0;
            child.sack_enabled = opts.sack_perm;
            try self.reply(child, seg, Flag.SYN | Flag.ACK, "", &.{});
            return;
        }

        if (sock.state == .SYN_SENT) {
            if (!has_syn or !has_ack) return;
            sock.snd_wscale = opts.ws orelse 0;
            sock.rcv_wscale = if (opts.ws != null) sock.ws_offered else 0;
            sock.sack_enabled = opts.sack_perm;
            if (sock.snd_wscale != 0 and sock.rcv_wscale != 0) self.window_scales += 1;
            sock.irs = seg.seq;
            sock.rcv_nxt = seg.seq + 1;
            sock.snd_una = seg.ack;
            sock.snd_nxt = @max(sock.snd_nxt, seg.ack);
            sock.snd_wnd = seg.window;
            sock.state = .ESTABLISHED;
            try self.acknowledge(sock, 1, false);
            try self.reply(sock, seg, Flag.ACK, "", &.{});
            return;
        }

        if (sock.state == .SYN_RECV) {
            if (!has_ack) return;
            sock.snd_una = seg.ack;
            sock.state = .ESTABLISHED;
            try self.acknowledge(sock, 1, false);
            if (sock.parent) |parent| try parent.accept_queue.append(self.allocator, sock);
            return;
        }

        // tcp_sacktag_write_queue(): SACK подтверждает непоследовательные
        // сегменты, не сдвигая snd_una.
        if (has_ack and sock.sack_enabled and opts.sack_count != 0) {
            for (opts.sacks[0..opts.sack_count]) |range| {
                self.sack_blocks += 1;
                if (sock.sacks.items.len < 16) try sock.sacks.append(self.allocator, range);
                var j: usize = 0;
                while (j < sock.retransmit.items.len) {
                    const p = sock.retransmit.items[j];
                    const end = p.seq + @as(u32, @intCast(p.bytes.len));
                    if (range.left <= p.seq and end <= range.right) {
                        self.allocator.free(p.bytes);
                        _ = sock.retransmit.orderedRemove(j);
                        sock.packets_out -|= 1;
                        self.sacked_segments += 1;
                    } else {
                        j += 1;
                    }
                }
            }
        }

        if (has_ack and sock.snd_una != seg.ack and seg.ack > sock.snd_una) {
            const limited = sock.cwnd_limited or sock.packets_out >= sock.ca.cwnd;
            const delta = seg.ack - sock.snd_una;
            sock.snd_una = seg.ack;
            sock.snd_wnd = seg.window;
            const mss: u32 = @intCast(TCP_MSS);
            const acked: u32 = @max(1, (delta + mss - 1) / mss);
            self.acks += 1;
            try self.acknowledge(sock, acked, limited);
        }

        // tcp_fastretrans_alert(): три чистых dup ACK при неподтверждённых
        // данных запускают Reno fast retransmit.
        if (has_ack and !has_syn and !has_fin and seg.payload.len == 0 and
            seg.ack == sock.snd_una and sock.retransmit.items.len != 0)
        {
            try self.onDupAck(sock);
        }

        if (seg.payload.len != 0) {
            if (seg.seq == sock.rcv_nxt) {
                try sock.recv_stream.appendSlice(self.allocator, seg.payload);
                sock.rcv_nxt += @intCast(seg.payload.len);
                // tcp_ofo_queue(): сшить ранее полученные фрагменты.
                while (sock.gaps.items.len != 0) {
                    const gap = sock.gaps.items[0];
                    if (gap.seq != sock.rcv_nxt) break;
                    try sock.recv_stream.appendSlice(self.allocator, gap.bytes);
                    sock.rcv_nxt += @intCast(gap.bytes.len);
                    self.allocator.free(gap.bytes);
                    _ = sock.gaps.orderedRemove(0);
                    self.sacked_segments += 1;
                }
                try self.reply(sock, seg, Flag.ACK, "", &.{});
            } else if (seg.seq > sock.rcv_nxt and sock.sack_enabled) {
                // tcp_data_queue(): вне порядка — в очередь пропусков и SACK.
                const bytes = try self.allocator.dupe(u8, seg.payload);
                errdefer self.allocator.free(bytes);
                const gap = Gap{ .seq = seg.seq, .bytes = bytes };
                var at: usize = 0;
                while (at < sock.gaps.items.len and sock.gaps.items[at].seq < seg.seq) : (at += 1) {}
                try sock.gaps.insert(self.allocator, at, gap);
                var blocks: [tcp_options.MAX_SACK_BLOCKS]tcp_options.Range = undefined;
                var count: usize = 0;
                for (sock.gaps.items) |queued| {
                    if (count == blocks.len) break;
                    blocks[count] = .{
                        .left = queued.seq,
                        .right = queued.seq + @as(u32, @intCast(queued.bytes.len)),
                    };
                    count += 1;
                }
                try self.reply(sock, seg, Flag.ACK, "", blocks[0..count]);
            } else {
                self.drops += 1;
                try self.reply(sock, seg, Flag.ACK, "", &.{});
            }
        }

        if (has_fin and !sock.fin_received) {
            sock.fin_received = true;
            sock.rcv_nxt += 1;
            try self.reply(sock, seg, Flag.ACK, "", &.{});
            switch (sock.state) {
                .ESTABLISHED => sock.state = .CLOSE_WAIT,
                .FIN_WAIT1 => sock.state = .CLOSING,
                .FIN_WAIT2 => enterTimeWait(sock),
                else => {},
            }
        }

        if (has_ack and sock.fin_sent) {
            switch (sock.state) {
                .FIN_WAIT1 => sock.state = .FIN_WAIT2,
                .CLOSING => enterTimeWait(sock),
                .LAST_ACK => sock.state = .CLOSE,
                else => {},
            }
        }
    }

    fn senderAddr(seg: Segment) [4]u8 {
        _ = seg;
        return .{ 127, 0, 0, 1 };
    }

    /// ACK, отправленный в ответ на входящий сегмент, меняет стороны.
    fn reply(self: *Stack, sock: *Sock, seg: Segment, flags: u8, payload: []const u8, sacks: []const tcp_options.Range) TcpError!void {
        const remote: SockAddr = .{ .port = seg.src_port, .addr = senderAddr(seg) };
        const local: SockAddr = .{ .port = seg.dst_port, .addr = sock.local.addr };
        var options: std.ArrayList(u8) = .empty;
        defer options.deinit(self.allocator);
        if (flags & Flag.SYN != 0) {
            const hello = try self.helloOptions(sock);
            defer self.allocator.free(hello);
            try options.appendSlice(self.allocator, hello);
        }
        if (sacks.len != 0) try tcp_options.appendSack(&options, self.allocator, sacks);
        // SYN занимает один порядковый номер: seq = ISS, а snd_nxt уже ISS+1.
        const seq = if (flags & Flag.SYN != 0) sock.iss else sock.snd_nxt;
        const skb = try buildSegmentOpt(self.allocator, local, remote, seq, sock.rcv_nxt, flags, advertisedWnd(sock), payload, options.items);
        defer skb.free();
        self.segments_tx += 1;
        for (self.sockets.items) |peer| {
            if (peer == sock or peer.local.port != remote.port) continue;
            if (peer.peer.port != local.port) continue;
            const parsed = parseSegment(self.allocator, skb.storageForChecksum(), local.addr, peer.local.addr) catch {
                self.checksum_bad += 1;
                return;
            };
            self.checksum_ok += 1;
            self.segments_rx += 1;
            try self.input(peer, parsed);
            return;
        }
        self.drops += 1;
    }

    /// tcp_fastretrans_alert(): третий dup ACK уполовинивает ssthresh и
    /// повторно отправляет первый неподтверждённый сегмент.
    fn onDupAck(self: *Stack, sock: *Sock) TcpError!void {
        if (!sock.ca.onDupAck()) return;
        const first = sock.retransmit.items[0];
        self.fast_retransmits += 1;
        self.retransmits += 1;
        try self.transmitData(sock, first.seq, first.flags, first.bytes);
    }

    fn acknowledge(self: *Stack, sock: *Sock, acked: u32, cwnd_limited: bool) TcpError!void {
        var i: usize = 0;
        while (i < sock.retransmit.items.len) {
            const p = sock.retransmit.items[i];
            const end = p.seq + @as(u32, @intCast(p.bytes.len));
            if (end <= sock.snd_una) {
                self.allocator.free(p.bytes);
                _ = sock.retransmit.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        sock.packets_out = sock.packets_out -| acked;
        sock.ca.onNewAck(acked, cwnd_limited);
        self.congestion_acks += 1;
    }
};

pub const OptionsProbe = struct {
    status: []const u8 = "none",
    window_scale: bool = false,
    sack: bool = false,
    ofo: bool = false,
    backoff: bool = false,
    shift: u5 = 0,
    sack_blocks: usize = 0,
    sacked: usize = 0,
    rto: [3]u32 = .{ 0, 0, 0 },
    errno: i64 = 0,
};

/// Boot-time проба опций TCP: согласование window scale, SACK на внеочередных
/// данных и экспоненциальный откат RTO — без сетевого драйвера.
pub fn optionsProbe(allocator: std.mem.Allocator) !OptionsProbe {
    var p = OptionsProbe{};
    const stack = try Stack.init(allocator);
    defer stack.deinit();

    const server = try stack.socket();
    try stack.bind(server, .{ .port = 48000 });
    try stack.listen(server, 2);
    const client = try stack.socket();
    try stack.connect(client, .{ .port = 48000 });
    const child = try stack.accept(server);
    p.window_scale = client.snd_wscale == tcp_options.DEFAULT_WS and
        client.rcv_wscale == tcp_options.DEFAULT_WS and child.snd_wscale == tcp_options.DEFAULT_WS and
        child.rcv_wscale == tcp_options.DEFAULT_WS and stack.window_scales == 1 and
        client.sack_enabled and child.sack_enabled;
    p.shift = client.rcv_wscale;

    // Второй сегмент приходит раньше первого: получатель обязан вернуть SACK.
    const first = client.snd_nxt;
    try stack.transmitData(client, first + 4, Flag.PSH | Flag.ACK, "WXYZ");
    p.sack = child.gaps.items.len == 1 and stack.sack_blocks >= 1;
    try stack.transmitData(client, first, Flag.PSH | Flag.ACK, "ABCD");
    var buf: [64]u8 = undefined;
    const got = try Stack.recv(child, &buf);
    p.ofo = got == 8 and std.mem.eql(u8, buf[0..got], "ABCDWXYZ") and
        child.gaps.items.len == 0 and stack.sacked_segments >= 1;
    p.sack_blocks = stack.sack_blocks;
    p.sacked = stack.sacked_segments;

    // Осиротевший сокет не получает ACK, поэтому таймеры не сбрасываются.
    const orphan = try stack.socket();
    const retry = try allocator.dupe(u8, "RTO!");
    try orphan.retransmit.append(allocator, .{
        .seq = 1,
        .bytes = retry,
        .flags = Flag.PSH | Flag.ACK,
    });
    try stack.tick();
    p.rto[0] = orphan.rto_ms;
    try stack.tick();
    p.rto[1] = orphan.rto_ms;
    try stack.tick();
    p.rto[2] = orphan.rto_ms;
    p.backoff = std.mem.eql(u32, &p.rto, &.{ 200, 400, 800 }) and stack.backoffs == 2;

    p.status = "ok";
    return p;
}

pub const Probe = struct {
    status: []const u8 = "none",
    checksum: bool = false,
    handshake: bool = false,
    stream: bool = false,
    retransmit: bool = false,
    close: bool = false,
    bytes: usize = 0,
    segments: usize = 0,
    acks: usize = 0,
    state: []const u8 = "CLOSED",
    errno: i64 = 0,
};

/// Boot-time проба TCP без сетевого драйвера: строит настоящие сегменты,
/// проверяет checksum, handshake, поток, ретрансляцию и FIN-закрытие.
pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    const stack = try Stack.init(allocator);
    defer stack.deinit();

    const src: [4]u8 = .{ 127, 0, 0, 1 };
    const dst: [4]u8 = .{ 127, 0, 0, 1 };
    const sample = try buildSegment(allocator, .{ .port = 40001 }, .{ .port = 40000 }, 1, 0, Flag.SYN, 4096, "");
    defer sample.free();
    _ = parseSegment(allocator, sample.storageForChecksum(), src, dst) catch return error.Invalid;
    p.checksum = true;

    const server = try stack.socket();
    try stack.bind(server, .{ .port = 40000 });
    try stack.listen(server, 2);
    const client = try stack.socket();
    try stack.connect(client, .{ .port = 40000 });
    const child = stack.accept(server) catch return error.Invalid;
    p.handshake = client.state == .ESTABLISHED and child.state == .ESTABLISHED and
        client.rcv_nxt == child.iss + 1 and child.rcv_nxt == client.iss + 1;

    const payload = "TCP PROBE\n";
    try stack.send(client, payload);
    var buf: [64]u8 = undefined;
    const got = try Stack.recv(child, &buf);
    p.stream = got == payload.len and std.mem.eql(u8, buf[0..got], payload) and client.retransmit.items.len == 0;
    p.bytes = got;

    const retry = try allocator.dupe(u8, "RETRY");
    try child.retransmit.append(allocator, .{
        .seq = child.snd_nxt,
        .bytes = retry,
        .flags = Flag.PSH | Flag.ACK,
    });
    child.snd_nxt += @intCast(retry.len);
    try stack.tick();
    const retried = try Stack.recv(client, &buf);
    p.retransmit = stack.retransmits == 1 and retried == 5 and
        std.mem.eql(u8, buf[0..retried], "RETRY");

    try stack.close(client);
    try stack.close(child);
    p.close = client.state == .TIME_WAIT and child.state == .CLOSE;
    try stack.tick();
    try stack.tick();
    p.state = stateName(client.state);
    p.segments = stack.segments_tx;
    p.acks = stack.acks;
    p.status = "ok";
    return p;
}

test "tcp: checksum follows the IPv4 pseudo-header and detects corruption" {
    const a = std.testing.allocator;
    const src: [4]u8 = .{ 10, 0, 0, 1 };
    const dst: [4]u8 = .{ 10, 0, 0, 2 };
    var seg: [20]u8 = .{
        0x04, 0xd2, 0x00, 0x50, 0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x00, 0x50, 0x02, 0x10, 0x00,
        0x00, 0x00, 0x00, 0x00,
    };
    try std.testing.expectEqual(@as(u16, 0x86bd), try checksum(a, src, dst, &seg));
    wr16(&seg, 16, 0x86bd);
    const parsed = try parseSegment(a, &seg, src, dst);
    try std.testing.expectEqual(@as(u16, 1234), parsed.src_port);
    try std.testing.expectEqual(@as(u16, 80), parsed.dst_port);
    try std.testing.expectEqual(@as(u32, 1), parsed.seq);
    try std.testing.expectEqual(Flag.SYN, parsed.flags);
    try std.testing.expectEqual(@as(u16, 4096), parsed.window);
    seg[13] ^= 1;
    try std.testing.expectError(error.Checksum, parseSegment(a, &seg, src, dst));
}

test "tcp: buildSegment and parseSegment round-trip a payload" {
    const a = std.testing.allocator;
    const skb = try buildSegment(a, .{ .port = 1234 }, .{ .port = 80 }, 7, 9, Flag.SYN | Flag.ACK, 4096, "abc");
    defer skb.free();
    const p = try parseSegment(a, skb.storageForChecksum(), .{ 127, 0, 0, 1 }, .{ 127, 0, 0, 1 });
    try std.testing.expectEqual(@as(u16, 1234), p.src_port);
    try std.testing.expectEqual(@as(u16, 80), p.dst_port);
    try std.testing.expectEqual(@as(u32, 7), p.seq);
    try std.testing.expectEqual(@as(u32, 9), p.ack);
    try std.testing.expectEqual(Flag.SYN | Flag.ACK, p.flags);
    try std.testing.expectEqualStrings("abc", p.payload);
}

test "tcp: three-way handshake moves both sockets to ESTABLISHED" {
    const a = std.testing.allocator;
    const stack = try Stack.init(a);
    defer stack.deinit();
    const server = try stack.socket();
    try stack.bind(server, .{ .port = 8080 });
    try stack.listen(server, 4);
    const client = try stack.socket();
    try stack.connect(client, .{ .port = 8080 });

    try std.testing.expectEqual(State.ESTABLISHED, client.state);
    try std.testing.expectEqual(State.ESTABLISHED, server.accept_queue.items[0].state);
    const child = try stack.accept(server);
    try std.testing.expectEqual(@as(u32, client.iss + 1), client.snd_nxt);
    try std.testing.expectEqual(@as(u32, client.iss + 1), child.rcv_nxt);
    try std.testing.expectEqual(@as(u32, child.iss + 1), client.rcv_nxt);
    try std.testing.expectEqual(@as(u32, child.iss + 1), child.snd_una);
    try std.testing.expectEqual(client.local.port, child.peer.port);
    try std.testing.expect(stack.segments_tx >= 3);
    try std.testing.expect(stack.checksum_ok >= 3);
    try std.testing.expectEqual(@as(usize, 0), stack.checksum_bad);
}

test "tcp: stream data is acknowledged and retransmitted on tick" {
    const a = std.testing.allocator;
    const stack = try Stack.init(a);
    defer stack.deinit();
    const server = try stack.socket();
    try stack.bind(server, .{ .port = 9001 });
    try stack.listen(server, 2);
    const client = try stack.socket();
    try stack.connect(client, .{ .port = 9001 });
    const child = try stack.accept(server);

    try stack.send(client, "hello stream");
    var buf: [64]u8 = undefined;
    const n = try Stack.recv(child, &buf);
    try std.testing.expectEqual(@as(usize, 12), n);
    try std.testing.expectEqualStrings("hello stream", buf[0..n]);
    try std.testing.expectEqual(@as(usize, 0), client.retransmit.items.len);
    try std.testing.expectEqual(client.snd_una, client.snd_nxt);
    try std.testing.expect(stack.acks >= 1);

    const retry = try a.dupe(u8, "RETRY");
    try child.retransmit.append(a, .{ .seq = child.snd_nxt, .bytes = retry, .flags = Flag.PSH | Flag.ACK });
    child.snd_nxt += @intCast(retry.len);
    try stack.tick();
    try std.testing.expectEqual(@as(usize, 1), stack.retransmits);
    const got = try Stack.recv(client, &buf);
    try std.testing.expectEqual(@as(usize, 5), got);
    try std.testing.expectEqualStrings("RETRY", buf[0..got]);
    try std.testing.expectEqual(@as(usize, 0), child.retransmit.items.len);
}

test "tcp: FIN handshake closes both sides and TIME_WAIT expires" {
    const a = std.testing.allocator;
    const stack = try Stack.init(a);
    defer stack.deinit();
    const server = try stack.socket();
    try stack.bind(server, .{ .port = 9100 });
    try stack.listen(server, 2);
    const client = try stack.socket();
    try stack.connect(client, .{ .port = 9100 });
    const child = try stack.accept(server);

    try stack.close(client);
    try std.testing.expectEqual(State.FIN_WAIT2, client.state);
    try std.testing.expectEqual(State.CLOSE_WAIT, child.state);
    try stack.close(child);
    try std.testing.expectEqual(State.TIME_WAIT, client.state);
    try std.testing.expectEqual(State.CLOSE, child.state);
    try stack.tick();
    try stack.tick();
    try std.testing.expectEqual(State.CLOSE, client.state);
}

test "tcp: bind conflicts and invalid state transitions are rejected" {
    const a = std.testing.allocator;
    const stack = try Stack.init(a);
    defer stack.deinit();
    const first = try stack.socket();
    try stack.bind(first, .{ .port = 9200 });
    const second = try stack.socket();
    try std.testing.expectError(error.AddrInUse, stack.bind(second, .{ .port = 9200 }));
    try std.testing.expectError(error.NotConnected, stack.send(first, "x"));
    var empty: [4]u8 = undefined;
    @memset(&empty, 0);
    try std.testing.expectError(error.WouldBlock, Stack.recv(first, &empty));
    try stack.listen(first, 1);
    try std.testing.expectError(error.Invalid, stack.connect(first, .{ .port = 9201 }));
    try std.testing.expectError(error.WouldBlock, stack.accept(first));
}

test "tcp: boot probe validates checksum, handshake, stream, retransmit and close" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.checksum);
    try std.testing.expect(p.handshake);
    try std.testing.expect(p.stream);
    try std.testing.expect(p.retransmit);
    try std.testing.expect(p.close);
    try std.testing.expectEqual(@as(usize, 10), p.bytes);
    try std.testing.expectEqualStrings("CLOSE", p.state);
}

test "tcp: Reno gates sends by cwnd and fast-retransmits after three dup ACKs" {
    const a = std.testing.allocator;
    const stack = try Stack.init(a);
    defer stack.deinit();
    const server = try stack.socket();
    try stack.bind(server, .{ .port = 9500 });
    try stack.listen(server, 2);
    const client = try stack.socket();
    try stack.connect(client, .{ .port = 9500 });
    const child = try stack.accept(server);

    child.ca.cwnd = 1;
    child.packets_out = 1;
    try std.testing.expectError(error.WouldBlock, stack.send(child, "blocked"));
    child.packets_out = 0;
    child.ca.cwnd = 10;

    const retry = try a.dupe(u8, "LOSS");
    try child.retransmit.append(a, .{ .seq = child.snd_nxt, .bytes = retry, .flags = Flag.PSH | Flag.ACK });
    child.snd_nxt += @intCast(retry.len);
    const dup = Segment{
        .src_port = child.peer.port,
        .dst_port = child.local.port,
        .seq = child.rcv_nxt,
        .ack = child.snd_una,
        .flags = Flag.ACK,
        .window = TCP_DEFAULT_WND,
        .checksum = 0,
        .payload = &.{},
    };
    try stack.input(child, dup);
    try stack.input(child, dup);
    try std.testing.expectEqual(@as(usize, 0), stack.fast_retransmits);
    try stack.input(child, dup);
    try std.testing.expectEqual(@as(usize, 1), stack.fast_retransmits);
    try std.testing.expectEqual(@as(usize, 1), stack.retransmits);
    try std.testing.expectEqual(@as(u32, 5), child.ca.ssthresh);
    try std.testing.expectEqual(@as(u32, 5), child.ca.cwnd);

    const lost = try a.dupe(u8, "RTO");
    try child.retransmit.append(a, .{ .seq = child.snd_nxt, .bytes = lost, .flags = Flag.PSH | Flag.ACK });
    child.snd_nxt += @intCast(lost.len);
    try stack.tick();
    try std.testing.expectEqual(@as(usize, 1), stack.timeouts);
    try std.testing.expectEqual(tcp_ca.CaState.loss, child.ca.ca_state);
}

test "tcp: window scale, SACK reassembly and RTO backoff" {
    const p = try optionsProbe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.window_scale);
    try std.testing.expect(p.sack);
    try std.testing.expect(p.ofo);
    try std.testing.expect(p.backoff);
    try std.testing.expectEqual(@as(u5, 7), p.shift);
    try std.testing.expect(p.sack_blocks >= 1);
    try std.testing.expect(p.sacked >= 1);
    try std.testing.expectEqual(@as(u32, 200), p.rto[0]);
    try std.testing.expectEqual(@as(u32, 400), p.rto[1]);
    try std.testing.expectEqual(@as(u32, 800), p.rto[2]);
}
