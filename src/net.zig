//! Порт сетевого ядра Linux 7.3: sk_buff и socket layer с AF_INET,
//! SOCK_DGRAM loopback и SOCK_STREAM/TCP. Источники: include/linux/net.h,
//! include/linux/socket.h, net/socket.c, net/core/datagram.c, net/ipv4/udp.c.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const skbuff = @import("skb.zig");
const inet6 = @import("inet6.zig");
const tcp = @import("tcp.zig");

pub const AF_INET: u16 = 2;
pub const AF_INET6: u16 = inet6.AF_INET6;
pub const SOCK_STREAM: u8 = 1;
pub const SOCK_DGRAM: u8 = 2;
pub const SOCK_RAW: u8 = 3;
pub const IPPROTO_UDP: u8 = 17;
pub const IPPROTO_TCP: u8 = tcp.IPPROTO_TCP;
pub const IPPROTO_UDP6: u8 = inet6.IPPROTO_UDP;

// include/uapi/linux/net.h: socket_state.
pub const SS_FREE: u8 = 0;
pub const SS_UNCONNECTED: u8 = 1;
pub const SS_CONNECTING: u8 = 2;
pub const SS_CONNECTED: u8 = 3;
pub const SS_DISCONNECTING: u8 = 4;

pub const NetError = error{
    Invalid,
    AddrInUse,
    NotBound,
    Refused,
    Checksum,
    Full,
    WouldBlock,
    Closed,
    NoMemory,
};

pub const SockAddrIn = struct {
    port: u16 = 0,
    addr: [4]u8 = .{ 127, 0, 0, 1 },
};

pub const Received = struct {
    len: usize,
    from: SockAddrIn,
};

pub const Received6 = struct {
    len: usize,
    from: inet6.SockAddrIn6,
};

const Queued = struct {
    skb: *skbuff.SkBuff,
    from: SockAddrIn,
};

const Queued6 = struct {
    skb: *skbuff.SkBuff,
    from: inet6.SockAddrIn6,
};

const BindFn = *const fn (?*anyopaque, *Socket, SockAddrIn) NetError!void;
const ConnectFn = *const fn (?*anyopaque, *Socket, SockAddrIn) NetError!void;
const SendFn = *const fn (?*anyopaque, *Socket, []const u8, SockAddrIn) NetError!void;
const RecvFn = *const fn (?*anyopaque, *Socket, []u8) NetError!Received;
const ReleaseFn = *const fn (?*anyopaque, *Socket) NetError!void;
const ListenFn = *const fn (?*anyopaque, *Socket, usize) NetError!void;
const AcceptFn = *const fn (?*anyopaque, *Socket) NetError!*Socket;

/// net/socket.c: struct proto_ops — операции, через которые socket layer
/// вызывает конкретный протокол, не зная его внутреннего устройства.
pub const ProtoOps = struct {
    ctx: ?*anyopaque,
    bind: BindFn,
    connect: ConnectFn,
    sendto: SendFn,
    recvfrom: RecvFn,
    release: ReleaseFn,
    listen: ?ListenFn = null,
    accept: ?AcceptFn = null,
};

const Bind6Fn = *const fn (?*anyopaque, *Socket, inet6.SockAddrIn6) NetError!void;
const Connect6Fn = *const fn (?*anyopaque, *Socket, inet6.SockAddrIn6) NetError!void;
const Send6Fn = *const fn (?*anyopaque, *Socket, []const u8, inet6.SockAddrIn6) NetError!void;
const Recv6Fn = *const fn (?*anyopaque, *Socket, []u8) NetError!Received6;

/// AF_INET6 использует тот же socket layer, но отдельный набор proto_ops.
pub const ProtoOps6 = struct {
    ctx: ?*anyopaque,
    bind: Bind6Fn,
    connect: Connect6Fn,
    sendto: Send6Fn,
    recvfrom: Recv6Fn,
    release: ReleaseFn,
};

pub const Socket = struct {
    family: u16,
    type: u8,
    protocol: u8,
    state: u8 = SS_UNCONNECTED,
    local: ?SockAddrIn = null,
    peer: ?SockAddrIn = null,
    local6: ?inet6.SockAddrIn6 = null,
    peer6: ?inet6.SockAddrIn6 = null,
    queue: std.ArrayList(Queued),
    queue6: std.ArrayList(Queued6),
    ops: ?ProtoOps = null,
    ops6: ?ProtoOps6 = null,
    tcp_sock: ?*tcp.Sock = null,
};

fn put16be(buf: []u8, off: usize, value: u16) void {
    buf[off] = @truncate(value >> 8);
    buf[off + 1] = @truncate(value);
}

fn rd16be(buf: []const u8, off: usize) u16 {
    return (@as(u16, buf[off]) << 8) | @as(u16, buf[off + 1]);
}

/// udp.c: udp4_csum_init() — псевдозаголовок IPv4 плюс полезная нагрузка.
fn udpChecksum(allocator: std.mem.Allocator, src: [4]u8, dst: [4]u8, payload: []const u8) NetError!u16 {
    const buf = allocator.alloc(u8, 12 + payload.len) catch return error.NoMemory;
    defer allocator.free(buf);
    @memcpy(buf[0..4], &src);
    @memcpy(buf[4..8], &dst);
    buf[8] = 0;
    buf[9] = IPPROTO_UDP;
    put16be(buf, 10, @intCast(payload.len));
    @memcpy(buf[12..], payload);
    return skbuff.checksum(buf);
}

pub const Net = struct {
    allocator: std.mem.Allocator,
    sockets: std.ArrayList(*Socket),
    bindings: std.AutoHashMap(u16, *Socket),
    bindings6: std.AutoHashMap(u16, *Socket),
    next_port: u16 = 49152,
    next_port6: u16 = 61000,
    packets: usize = 0,
    drops: usize = 0,
    checksum_ok: usize = 0,
    checksum_bad: usize = 0,
    packets6: usize = 0,
    drops6: usize = 0,
    checksum6_ok: usize = 0,
    checksum6_bad: usize = 0,
    ops: ProtoOps = undefined,
    ops6: ProtoOps6 = undefined,
    tcp_ops: ProtoOps = undefined,
    tcp_stack: *tcp.Stack = undefined,

    pub fn init(allocator: std.mem.Allocator) !*Net {
        const self = try allocator.create(Net);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .sockets = std.ArrayList(*Socket).empty,
            .bindings = std.AutoHashMap(u16, *Socket).init(allocator),
            .bindings6 = std.AutoHashMap(u16, *Socket).init(allocator),
        };
        self.ops = .{
            .ctx = self,
            .bind = udpBind,
            .connect = udpConnect,
            .sendto = udpSendto,
            .recvfrom = udpRecvfrom,
            .release = udpRelease,
        };
        self.ops6 = .{
            .ctx = self,
            .bind = udp6Bind,
            .connect = udp6Connect,
            .sendto = udp6Sendto,
            .recvfrom = udp6Recvfrom,
            .release = udp6Release,
        };
        self.tcp_ops = .{
            .ctx = self,
            .bind = tcpBind,
            .connect = tcpConnect,
            .sendto = tcpSendto,
            .recvfrom = tcpRecvfrom,
            .release = tcpRelease,
            .listen = tcpListen,
            .accept = tcpAccept,
        };
        self.tcp_stack = try tcp.Stack.init(allocator);
        errdefer self.tcp_stack.deinit();
        return self;
    }

    fn destroySocket(self: *Net, sock: *Socket) void {
        if (sock.local) |addr| _ = self.bindings.remove(addr.port);
        if (sock.local6) |addr| _ = self.bindings6.remove(addr.port);
        for (sock.queue.items) |queued| queued.skb.free();
        for (sock.queue6.items) |queued| queued.skb.free();
        sock.queue.deinit(self.allocator);
        sock.queue6.deinit(self.allocator);
        self.allocator.destroy(sock);
    }

    pub fn deinit(self: *Net) void {
        for (self.sockets.items) |sock| self.destroySocket(sock);
        self.sockets.deinit(self.allocator);
        self.bindings.deinit();
        self.bindings6.deinit();
        self.tcp_stack.deinit();
        self.allocator.destroy(self);
    }

    /// net/socket.c: __sock_create() — проверить family/type/protocol.
    pub fn socket(self: *Net, family: u16, typ: u8, protocol: u8) NetError!*Socket {
        if (family != AF_INET and family != AF_INET6) return error.Invalid;
        if (typ == SOCK_DGRAM) {
            if (family == AF_INET and protocol != 0 and protocol != IPPROTO_UDP) return error.Invalid;
            if (family == AF_INET6 and protocol != 0 and protocol != IPPROTO_UDP6) return error.Invalid;
        } else if (typ == SOCK_STREAM) {
            if (family != AF_INET or (protocol != 0 and protocol != IPPROTO_TCP)) return error.Invalid;
        } else return error.Invalid;

        var tcp_sock: ?*tcp.Sock = null;
        if (typ == SOCK_STREAM) tcp_sock = self.tcp_stack.socket() catch return error.NoMemory;
        const sock = self.allocator.create(Socket) catch return error.NoMemory;
        errdefer self.allocator.destroy(sock);
        sock.* = .{
            .family = family,
            .type = typ,
            .protocol = protocol,
            .queue = std.ArrayList(Queued).empty,
            .queue6 = std.ArrayList(Queued6).empty,
            .ops = if (typ == SOCK_STREAM) self.tcp_ops else if (family == AF_INET6) null else self.ops,
            .ops6 = if (typ == SOCK_DGRAM and family == AF_INET6) self.ops6 else null,
            .tcp_sock = tcp_sock,
        };
        self.sockets.append(self.allocator, sock) catch return error.NoMemory;
        return sock;
    }

    /// net/socket.c: __sys_listen() → proto_ops.listen (только TCP).
    pub fn listen(self: *Net, sock: *Socket, backlog: usize) NetError!void {
        _ = self;
        const ops = sock.ops orelse return error.Closed;
        const fn_listen = ops.listen orelse return error.Invalid;
        return fn_listen(ops.ctx, sock, backlog);
    }

    /// net/socket.c: __sys_accept4() → proto_ops.accept (только TCP).
    pub fn accept(self: *Net, sock: *Socket) NetError!*Socket {
        _ = self;
        const ops = sock.ops orelse return error.Closed;
        const fn_accept = ops.accept orelse return error.Invalid;
        return fn_accept(ops.ctx, sock);
    }

    /// tcp_retransmit_timer() и TIME_WAIT для всех TCP-сокетов.
    pub fn tick(self: *Net) NetError!void {
        self.tcp_stack.tick() catch |e| return mapTcpError(e);
    }

    fn ephemeralPort(self: *Net) NetError!u16 {
        var attempts: usize = 0;
        while (attempts < 16384) : (attempts += 1) {
            const port = self.next_port;
            self.next_port = if (port == 65535) 49152 else port + 1;
            if (!self.bindings.contains(port)) return port;
        }
        return error.Full;
    }

    /// net/socket.c: __sys_bind() → proto_ops.bind.
    pub fn bind(self: *Net, sock: *Socket, addr: SockAddrIn) NetError!void {
        _ = self;
        const ops = sock.ops orelse return error.Closed;
        if (sock.state == SS_FREE) return error.Closed;
        return ops.bind(ops.ctx, sock, addr);
    }

    /// net/socket.c: __sys_connect() → proto_ops.connect.
    pub fn connect(self: *Net, sock: *Socket, peer: SockAddrIn) NetError!void {
        _ = self;
        const ops = sock.ops orelse return error.Closed;
        if (sock.state == SS_FREE) return error.Closed;
        return ops.connect(ops.ctx, sock, peer);
    }

    pub fn sendto(self: *Net, sock: *Socket, payload: []const u8, dest: SockAddrIn) NetError!void {
        _ = self;
        const ops = sock.ops orelse return error.Closed;
        if (sock.state == SS_FREE) return error.Closed;
        return ops.sendto(ops.ctx, sock, payload, dest);
    }

    /// Отправить уже подключённому peer-у (send() без адреса).
    pub fn send(self: *Net, sock: *Socket, payload: []const u8) NetError!void {
        if (sock.family == AF_INET6) return self.send6(sock, payload);
        const peer = sock.peer orelse return error.NotBound;
        return self.sendto(sock, payload, peer);
    }

    pub fn recvfrom(self: *Net, sock: *Socket, buf: []u8) NetError!Received {
        _ = self;
        const ops = sock.ops orelse return error.Closed;
        if (sock.state == SS_FREE) return error.Closed;
        return ops.recvfrom(ops.ctx, sock, buf);
    }

    fn ops6Of(sock: *Socket) NetError!ProtoOps6 {
        if (sock.state == SS_FREE) return error.Closed;
        return sock.ops6 orelse error.Invalid;
    }

    /// AF_INET6: bind() через отдельный proto_ops6.
    pub fn bind6(self: *Net, sock: *Socket, addr: inet6.SockAddrIn6) NetError!void {
        _ = self;
        const ops = try ops6Of(sock);
        return ops.bind(ops.ctx, sock, addr);
    }

    pub fn connect6(self: *Net, sock: *Socket, peer: inet6.SockAddrIn6) NetError!void {
        _ = self;
        const ops = try ops6Of(sock);
        return ops.connect(ops.ctx, sock, peer);
    }

    pub fn sendto6(self: *Net, sock: *Socket, payload: []const u8, dest: inet6.SockAddrIn6) NetError!void {
        _ = self;
        const ops = try ops6Of(sock);
        return ops.sendto(ops.ctx, sock, payload, dest);
    }

    pub fn send6(self: *Net, sock: *Socket, payload: []const u8) NetError!void {
        const peer = sock.peer6 orelse return error.NotBound;
        return self.sendto6(sock, payload, peer);
    }

    pub fn recvfrom6(self: *Net, sock: *Socket, buf: []u8) NetError!Received6 {
        _ = self;
        const ops = try ops6Of(sock);
        return ops.recvfrom(ops.ctx, sock, buf);
    }

    /// net/socket.c: sock_close() → proto_ops.release.
    pub fn close(self: *Net, sock: *Socket) NetError!void {
        _ = self;
        if (sock.state == SS_FREE) return error.Closed;
        if (sock.ops6) |ops6| return ops6.release(ops6.ctx, sock);
        const ops = sock.ops orelse return error.Closed;
        return ops.release(ops.ctx, sock);
    }

    fn mapTcpError(e: tcp.TcpError) NetError {
        return switch (e) {
            error.Invalid => error.Invalid,
            error.Checksum => error.Checksum,
            error.NoMemory, error.OutOfMemory => error.NoMemory,
            error.NotConnected => error.NotBound,
            error.AddrInUse => error.AddrInUse,
            error.Full => error.Full,
            error.WouldBlock => error.WouldBlock,
        };
    }

    fn tcpSock(sock: *Socket) NetError!*tcp.Sock {
        return sock.tcp_sock orelse error.Closed;
    }

    fn tcpBind(ctx: ?*anyopaque, sock: *Socket, addr: SockAddrIn) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        const ts = try tcpSock(sock);
        self.tcp_stack.bind(ts, .{ .port = addr.port, .addr = addr.addr }) catch |e| return mapTcpError(e);
        sock.local = addr;
    }

    fn tcpListen(ctx: ?*anyopaque, sock: *Socket, backlog: usize) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        const ts = try tcpSock(sock);
        self.tcp_stack.listen(ts, backlog) catch |e| return mapTcpError(e);
        if (ts.local.port != 0 and sock.local == null) sock.local = .{ .port = ts.local.port, .addr = ts.local.addr };
    }

    fn tcpConnect(ctx: ?*anyopaque, sock: *Socket, peer: SockAddrIn) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        const ts = try tcpSock(sock);
        self.tcp_stack.connect(ts, .{ .port = peer.port, .addr = peer.addr }) catch |e| return mapTcpError(e);
        if (ts.local.port != 0 and sock.local == null) sock.local = .{ .port = ts.local.port, .addr = ts.local.addr };
        sock.peer = peer;
        sock.state = SS_CONNECTED;
    }

    fn tcpAccept(ctx: ?*anyopaque, sock: *Socket) NetError!*Socket {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        const ts = try tcpSock(sock);
        const child = self.tcp_stack.accept(ts) catch |e| return mapTcpError(e);
        const accepted = self.allocator.create(Socket) catch return error.NoMemory;
        errdefer self.allocator.destroy(accepted);
        accepted.* = .{
            .family = AF_INET,
            .type = SOCK_STREAM,
            .protocol = IPPROTO_TCP,
            .state = SS_CONNECTED,
            .local = .{ .port = child.local.port, .addr = child.local.addr },
            .peer = .{ .port = child.peer.port, .addr = child.peer.addr },
            .queue = std.ArrayList(Queued).empty,
            .queue6 = std.ArrayList(Queued6).empty,
            .ops = sock.ops,
            .tcp_sock = child,
        };
        self.sockets.append(self.allocator, accepted) catch return error.NoMemory;
        return accepted;
    }

    fn tcpSendto(ctx: ?*anyopaque, sock: *Socket, payload: []const u8, dest: SockAddrIn) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        const ts = try tcpSock(sock);
        _ = dest;
        self.tcp_stack.send(ts, payload) catch |e| return mapTcpError(e);
    }

    fn tcpRecvfrom(ctx: ?*anyopaque, sock: *Socket, buf: []u8) NetError!Received {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        _ = self;
        const ts = try tcpSock(sock);
        const n = tcp.Stack.recv(ts, buf) catch |e| return mapTcpError(e);
        return .{ .len = n, .from = sock.peer orelse .{} };
    }

    fn tcpRelease(ctx: ?*anyopaque, sock: *Socket) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (sock.state == SS_FREE) return error.Closed;
        const ts = sock.tcp_sock orelse return error.Closed;
        self.tcp_stack.close(ts) catch |e| return mapTcpError(e);
        sock.state = SS_FREE;
        for (self.sockets.items, 0..) |item, i| {
            if (item == sock) {
                _ = self.sockets.orderedRemove(i);
                break;
            }
        }
        self.destroySocket(sock);
    }

    fn ephemeralPort6(self: *Net) NetError!u16 {
        var attempts: usize = 0;
        while (attempts < 16384) : (attempts += 1) {
            const port = self.next_port6;
            self.next_port6 = if (port == 65535) 61000 else port + 1;
            if (!self.bindings6.contains(port)) return port;
        }
        return error.Full;
    }

    fn udp6Bind(ctx: ?*anyopaque, sock: *Socket, addr: inet6.SockAddrIn6) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (addr.port == 0 or sock.local6 != null) return error.Invalid;
        if (self.bindings6.contains(addr.port)) return error.AddrInUse;
        self.bindings6.put(addr.port, sock) catch return error.NoMemory;
        sock.local6 = addr;
    }

    fn udp6Connect(ctx: ?*anyopaque, sock: *Socket, peer: inet6.SockAddrIn6) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (peer.port == 0) return error.Invalid;
        if (sock.local6 == null) {
            const port = try self.ephemeralPort6();
            self.bindings6.put(port, sock) catch return error.NoMemory;
            sock.local6 = .{ .port = port, .addr = inet6.LOOPBACK };
        }
        sock.peer6 = peer;
        sock.state = SS_CONNECTED;
    }

    fn udp6Sendto(ctx: ?*anyopaque, sock: *Socket, payload: []const u8, dest: inet6.SockAddrIn6) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (dest.port == 0) return error.Invalid;
        if (sock.local6 == null) {
            const port = try self.ephemeralPort6();
            self.bindings6.put(port, sock) catch return error.NoMemory;
            sock.local6 = .{ .port = port, .addr = inet6.LOOPBACK };
        }
        const receiver = self.bindings6.get(dest.port) orelse {
            self.drops6 += 1;
            return error.Refused;
        };
        if (receiver.queue6.items.len >= 8) {
            self.drops6 += 1;
            return error.Full;
        }
        const packet = inet6.buildDatagram(self.allocator, sock.local6.?, dest, payload) catch return error.NoMemory;
        errdefer packet.free();
        receiver.queue6.append(self.allocator, .{ .skb = packet, .from = sock.local6.? }) catch return error.NoMemory;
        self.packets6 += 1;
    }

    fn udp6Recvfrom(ctx: ?*anyopaque, sock: *Socket, buf: []u8) NetError!Received6 {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (sock.queue6.items.len == 0) return error.WouldBlock;
        const queued = sock.queue6.orderedRemove(0);
        defer queued.skb.free();
        const source = sock.local6 orelse return error.NotBound;
        const datagram = inet6.parseDatagram(self.allocator, queued.skb.data(), queued.from.addr, source.addr) catch |e| {
            return switch (e) {
                error.Checksum => blk: {
                    self.checksum6_bad += 1;
                    break :blk error.Checksum;
                },
                error.OutOfMemory => error.NoMemory,
                else => error.Invalid,
            };
        };
        if (datagram.payload.len > buf.len) return error.Invalid;
        @memcpy(buf[0..datagram.payload.len], datagram.payload);
        self.checksum6_ok += 1;
        return .{ .len = datagram.payload.len, .from = queued.from };
    }

    fn udp6Release(ctx: ?*anyopaque, sock: *Socket) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (sock.state == SS_FREE) return error.Closed;
        sock.state = SS_FREE;
        for (self.sockets.items, 0..) |item, i| {
            if (item == sock) {
                _ = self.sockets.orderedRemove(i);
                break;
            }
        }
        self.destroySocket(sock);
    }

    fn udpBind(ctx: ?*anyopaque, sock: *Socket, addr: SockAddrIn) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (addr.port == 0 or sock.local != null) return error.Invalid;
        if (self.bindings.contains(addr.port)) return error.AddrInUse;
        self.bindings.put(addr.port, sock) catch return error.NoMemory;
        sock.local = addr;
    }

    fn udpConnect(ctx: ?*anyopaque, sock: *Socket, peer: SockAddrIn) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (peer.port == 0) return error.Invalid;
        if (sock.local == null) {
            const port = try self.ephemeralPort();
            self.bindings.put(port, sock) catch return error.NoMemory;
            sock.local = .{ .port = port, .addr = .{ 127, 0, 0, 1 } };
        }
        sock.peer = peer;
        sock.state = SS_CONNECTED;
    }

    fn udpSendto(ctx: ?*anyopaque, sock: *Socket, payload: []const u8, dest: SockAddrIn) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (dest.port == 0) return error.Invalid;
        if (sock.local == null) {
            const port = try self.ephemeralPort();
            self.bindings.put(port, sock) catch return error.NoMemory;
            sock.local = .{ .port = port, .addr = .{ 127, 0, 0, 1 } };
        }
        const receiver = self.bindings.get(dest.port) orelse {
            self.drops += 1;
            return error.Refused;
        };
        if (receiver.queue.items.len >= 8) {
            self.drops += 1;
            return error.Full;
        }

        const packet = skbuff.SkBuff.alloc(self.allocator, 8 + payload.len, 8) catch return error.NoMemory;
        errdefer packet.free();
        _ = packet.put(payload) catch return error.NoMemory;
        const csum = udpChecksum(self.allocator, sock.local.?.addr, dest.addr, packet.data()) catch return error.NoMemory;
        const header = packet.push(8) catch return error.NoMemory;
        put16be(header, 0, sock.local.?.port);
        put16be(header, 2, dest.port);
        put16be(header, 4, @intCast(payload.len));
        put16be(header, 6, csum);
        receiver.queue.append(self.allocator, .{ .skb = packet, .from = sock.local.? }) catch return error.NoMemory;
        self.packets += 1;
    }

    fn udpRecvfrom(ctx: ?*anyopaque, sock: *Socket, buf: []u8) NetError!Received {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (sock.queue.items.len == 0) return error.WouldBlock;
        const queued = sock.queue.orderedRemove(0);
        defer queued.skb.free();

        const header = queued.skb.pull(8) catch return error.Invalid;
        const stored = rd16be(header, 6);
        const payload = queued.skb.data();
        const source = sock.local orelse return error.NotBound;
        const expected = udpChecksum(self.allocator, queued.from.addr, source.addr, payload) catch return error.NoMemory;
        if (expected != stored) {
            self.checksum_bad += 1;
            return error.Checksum;
        }
        if (payload.len > buf.len) return error.Invalid;
        @memcpy(buf[0..payload.len], payload);
        self.checksum_ok += 1;
        return .{ .len = payload.len, .from = queued.from };
    }

    fn udpRelease(ctx: ?*anyopaque, sock: *Socket) NetError!void {
        const self: *Net = @ptrCast(@alignCast(ctx orelse return error.Closed));
        if (sock.state == SS_FREE) return error.Closed;
        sock.state = SS_FREE;
        for (self.sockets.items, 0..) |item, i| {
            if (item == sock) {
                _ = self.sockets.orderedRemove(i);
                break;
            }
        }
        self.destroySocket(sock);
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    skb_ok: bool = false,
    clone_ok: bool = false,
    csum_ok: bool = false,
    bind_ok: bool = false,
    loopback_ok: bool = false,
    recv_ok: bool = false,
    inuse_ok: bool = false,
    refused_ok: bool = false,
    bytes: usize = 0,
    queue: usize = 0,
    packets: usize = 0,
    drops: usize = 0,
    errno: i64 = 0,
};

/// Boot-time проба без отдельного сетевого устройства: проверяет sk_buff,
/// proto_ops, bind-конфликт и loopback UDP с checksum-ом.
pub fn probe(allocator: std.mem.Allocator) !Probe {
    var p = Probe{};
    const payload = "NET PROBE\n";

    const skb = try skbuff.SkBuff.alloc(allocator, 128, 16);
    defer skb.free();
    _ = try skb.put(payload);
    _ = try skb.push(8);
    p.skb_ok = skb.headroom() == 8 and skb.len() == payload.len + 8;
    _ = try skb.pull(8);
    p.csum_ok = skbuff.checksumValid(skb.data(), skb.csum());

    const cloned = try skb.clone();
    const copied = try skb.copy();
    defer copied.free();
    p.clone_ok = skb.refcount() == 2 and cloned.refcount() == 2 and
        std.mem.eql(u8, cloned.data(), skb.data()) and copied.data().ptr != skb.data().ptr;
    (try cloned.unshare()).free();

    const net = try Net.init(allocator);
    defer net.deinit();
    const client = try net.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    const server = try net.socket(AF_INET, SOCK_DGRAM, 0);
    net.bind(client, .{ .port = 7001 }) catch return error.Invalid;
    net.bind(server, .{ .port = 7000 }) catch return error.Invalid;
    p.bind_ok = client.local.?.port == 7001 and server.local.?.port == 7000;

    const conflict = try net.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    p.inuse_ok = if (net.bind(conflict, .{ .port = 7000 })) |_| false else |err| err == error.AddrInUse;

    const before = net.packets;
    net.sendto(client, payload, .{ .port = 7000 }) catch return error.Invalid;
    p.loopback_ok = net.packets == before + 1 and server.queue.items.len == 1;

    var buf: [64]u8 = undefined;
    const received = net.recvfrom(server, &buf) catch return error.Invalid;
    p.recv_ok = received.len == payload.len and received.from.port == 7001 and
        std.mem.eql(u8, buf[0..received.len], payload);
    p.bytes = received.len;
    p.queue = server.queue.items.len;

    p.refused_ok = if (net.sendto(client, payload, .{ .port = 7999 })) |_| false else |err| err == error.Refused;
    p.packets = net.packets;
    p.drops = net.drops;
    p.status = "ok";
    return p;
}

pub const Probe6 = struct {
    status: []const u8 = "none",
    addr_ok: bool = false,
    csum_ok: bool = false,
    bind_ok: bool = false,
    loopback_ok: bool = false,
    recv_ok: bool = false,
    inuse_ok: bool = false,
    refused_ok: bool = false,
    bytes: usize = 0,
    queue: usize = 0,
    packets: usize = 0,
    drops: usize = 0,
    errno: i64 = 0,
};

/// Boot-time проба AF_INET6/SOCK_DGRAM: ::1, csum_ipv6_magic, bind-конфликт,
/// loopback через sk_buff и IPv6 UDP checksum. Диск не используется.
pub fn probeInet6(allocator: std.mem.Allocator) !Probe6 {
    var p = Probe6{};
    const payload = "INET6 PROBE\n";

    p.addr_ok = inet6.addrLoopback(inet6.LOOPBACK) and !inet6.addrAny(inet6.LOOPBACK);
    const sample = inet6.buildDatagram(
        allocator,
        .{ .port = 40001, .addr = inet6.LOOPBACK },
        .{ .port = 40000, .addr = inet6.LOOPBACK },
        payload,
    ) catch return error.Invalid;
    defer sample.free();
    const parsed = inet6.parseDatagram(allocator, sample.data(), inet6.LOOPBACK, inet6.LOOPBACK) catch return error.Invalid;
    p.csum_ok = std.mem.eql(u8, parsed.payload, payload);

    const net = try Net.init(allocator);
    defer net.deinit();
    const client = try net.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP6);
    const server = try net.socket(AF_INET6, SOCK_DGRAM, 0);
    try net.bind6(client, .{ .port = 7101, .addr = inet6.LOOPBACK });
    try net.bind6(server, .{ .port = 7100, .addr = inet6.LOOPBACK });
    p.bind_ok = client.local6.?.port == 7101 and server.local6.?.port == 7100;

    const conflict = try net.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP6);
    p.inuse_ok = if (net.bind6(conflict, .{ .port = 7100 })) |_| false else |err| err == error.AddrInUse;

    try net.connect6(client, .{ .port = 7100, .addr = inet6.LOOPBACK });
    try net.sendto6(client, payload, .{ .port = 7100, .addr = inet6.LOOPBACK });
    p.loopback_ok = net.packets6 == 1 and server.queue6.items.len == 1;

    var buf: [64]u8 = undefined;
    const received = try net.recvfrom6(server, &buf);
    p.recv_ok = received.len == payload.len and received.from.port == 7101 and
        std.mem.eql(u8, buf[0..received.len], payload);
    p.bytes = received.len;
    p.queue = server.queue6.items.len;

    p.refused_ok = if (net.sendto6(client, payload, .{ .port = 7999 })) |_| false else |err| err == error.Refused;
    p.packets = net.packets6;
    p.drops = net.drops6;
    p.status = "ok";
    return p;
}

test "skb socket layer: proto_ops bind conflict, loopback datagram and checksum" {
    const a = std.testing.allocator;
    const net = try Net.init(a);
    defer net.deinit();

    try std.testing.expectError(error.Invalid, net.socket(AF_INET, SOCK_DGRAM, IPPROTO_TCP));
    try std.testing.expectError(error.Invalid, net.socket(AF_INET, SOCK_STREAM, IPPROTO_UDP));
    try std.testing.expectError(error.Invalid, net.socket(11, SOCK_DGRAM, 0));
    try std.testing.expectError(error.Invalid, net.socket(AF_INET, 7, 0));

    const client = try net.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    const server = try net.socket(AF_INET, SOCK_DGRAM, 0);
    try net.bind(client, .{ .port = 7101 });
    try net.bind(server, .{ .port = 7100 });
    const conflict = try net.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    try std.testing.expectError(error.AddrInUse, net.bind(conflict, .{ .port = 7100 }));
    try std.testing.expectError(error.Invalid, net.bind(client, .{ .port = 7102 }));

    try net.connect(client, .{ .port = 7100 });
    try std.testing.expectEqual(@as(u8, SS_CONNECTED), client.state);
    try net.send(client, "hello");
    try std.testing.expectEqual(@as(usize, 1), server.queue.items.len);

    var buf: [32]u8 = undefined;
    const got = try net.recvfrom(server, &buf);
    try std.testing.expectEqual(@as(usize, 5), got.len);
    try std.testing.expectEqual(@as(u16, 7101), got.from.port);
    try std.testing.expectEqualStrings("hello", buf[0..got.len]);
    try std.testing.expectEqual(@as(usize, 1), net.checksum_ok);
    try std.testing.expectEqual(@as(usize, 1), net.packets);
    try std.testing.expectError(error.WouldBlock, net.recvfrom(server, &buf));

    try std.testing.expectError(error.Refused, net.sendto(client, "x", .{ .port = 7999 }));
    try std.testing.expectEqual(@as(usize, 1), net.drops);

    try net.close(client);
    try std.testing.expect(net.bindings.get(7101) == null);
    try std.testing.expectEqual(@as(usize, 2), net.sockets.items.len);
}

test "skb socket layer: corrupt datagram is dropped by udp checksum" {
    const a = std.testing.allocator;
    const net = try Net.init(a);
    defer net.deinit();
    const client = try net.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    const server = try net.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    try net.bind(client, .{ .port = 7201 });
    try net.bind(server, .{ .port = 7200 });
    try net.sendto(client, "checksum", .{ .port = 7200 });

    const queued = server.queue.orderedRemove(0);
    const header = queued.skb.pull(8) catch unreachable;
    put16be(header, 6, rd16be(header, 6) ^ 1);
    const payload = queued.skb.mutableData();
    payload[0] ^= 1;
    server.queue.append(a, .{ .skb = queued.skb, .from = queued.from }) catch unreachable;

    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.Checksum, net.recvfrom(server, &buf));
    try std.testing.expectEqual(@as(usize, 1), net.checksum_bad);
}

test "skb socket layer: boot probe completes with Linux socket states" {
    const p = try probe(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.skb_ok);
    try std.testing.expect(p.clone_ok);
    try std.testing.expect(p.csum_ok);
    try std.testing.expect(p.bind_ok);
    try std.testing.expect(p.loopback_ok);
    try std.testing.expect(p.recv_ok);
    try std.testing.expect(p.inuse_ok);
    try std.testing.expect(p.refused_ok);
    try std.testing.expectEqual(@as(usize, 10), p.bytes);
    try std.testing.expectEqual(@as(usize, 0), p.queue);
}

test "socket layer: AF_INET/SOCK_STREAM uses TCP proto_ops and loopback" {
    const a = std.testing.allocator;
    const net = try Net.init(a);
    defer net.deinit();

    const server = try net.socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    try net.bind(server, .{ .port = 7300 });
    try net.listen(server, 4);
    try std.testing.expectEqual(@as(u8, SS_UNCONNECTED), server.state);

    const client = try net.socket(AF_INET, SOCK_STREAM, 0);
    try net.connect(client, .{ .port = 7300 });
    try std.testing.expectEqual(@as(u8, SS_CONNECTED), client.state);
    const child = try net.accept(server);
    try std.testing.expectEqual(@as(u16, 7300), child.local.?.port);
    try std.testing.expectEqual(client.local.?.port, child.peer.?.port);
    try std.testing.expectEqual(@as(u8, SS_CONNECTED), child.state);

    try net.send(client, "stream over socket layer");
    var buf: [64]u8 = undefined;
    const got = try net.recvfrom(child, &buf);
    try std.testing.expectEqual(@as(usize, 24), got.len);
    try std.testing.expectEqualStrings("stream over socket layer", buf[0..got.len]);
    try std.testing.expectEqual(@as(usize, 0), net.bindings.count());
    try net.tick();
    try net.close(client);
    try net.close(child);
    try std.testing.expectEqual(@as(usize, 1), net.sockets.items.len);
    try std.testing.expectEqual(@as(usize, 3), net.tcp_stack.sockets.items.len);
}

test "socket layer: stream operations reject invalid protocol and listen on datagrams" {
    const a = std.testing.allocator;
    const net = try Net.init(a);
    defer net.deinit();
    const udp = try net.socket(AF_INET, SOCK_DGRAM, 0);
    try std.testing.expectError(error.Invalid, net.listen(udp, 1));
    try std.testing.expectError(error.Invalid, net.accept(udp));
    const stream = try net.socket(AF_INET, SOCK_STREAM, 0);
    try std.testing.expectError(error.WouldBlock, net.accept(stream));
    try std.testing.expectError(error.NotBound, net.send(stream, "x"));
}

test "socket layer: AF_INET6/SOCK_DGRAM uses proto_ops6 and IPv6 checksum" {
    const a = std.testing.allocator;
    const net = try Net.init(a);
    defer net.deinit();

    try std.testing.expectError(error.Invalid, net.socket(AF_INET6, SOCK_DGRAM, IPPROTO_TCP));
    try std.testing.expectError(error.Invalid, net.socket(AF_INET6, SOCK_STREAM, 0));

    const client = try net.socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP6);
    const server = try net.socket(AF_INET6, SOCK_DGRAM, 0);
    try net.bind6(client, .{ .port = 7301, .addr = inet6.LOOPBACK });
    try net.bind6(server, .{ .port = 7300, .addr = inet6.LOOPBACK });
    const conflict = try net.socket(AF_INET6, SOCK_DGRAM, 0);
    try std.testing.expectError(error.AddrInUse, net.bind6(conflict, .{ .port = 7300 }));
    try std.testing.expectError(error.Invalid, net.bind6(client, .{ .port = 7302 }));

    try net.connect6(client, .{ .port = 7300, .addr = inet6.LOOPBACK });
    try std.testing.expectEqual(@as(u8, SS_CONNECTED), client.state);
    try net.send6(client, "ipv6 stream");
    var buf: [32]u8 = undefined;
    const got = try net.recvfrom6(server, &buf);
    try std.testing.expectEqual(@as(usize, 11), got.len);
    try std.testing.expectEqual(@as(u16, 7301), got.from.port);
    try std.testing.expect(inet6.addrLoopback(got.from.addr));
    try std.testing.expectEqualStrings("ipv6 stream", buf[0..got.len]);
    try std.testing.expectEqual(@as(usize, 1), net.checksum6_ok);
    try std.testing.expectEqual(@as(usize, 1), net.packets6);
    try std.testing.expectError(error.WouldBlock, net.recvfrom6(server, &buf));
    try net.close(client);
    try std.testing.expect(net.bindings6.get(7301) == null);
}

test "socket layer: corrupt IPv6 datagram is dropped by checksum" {
    const a = std.testing.allocator;
    const net = try Net.init(a);
    defer net.deinit();
    const client = try net.socket(AF_INET6, SOCK_DGRAM, 0);
    const server = try net.socket(AF_INET6, SOCK_DGRAM, 0);
    try net.bind6(client, .{ .port = 7401 });
    try net.bind6(server, .{ .port = 7400 });
    try net.sendto6(client, "checksum6", .{ .port = 7400 });

    const queued = server.queue6.orderedRemove(0);
    const payload = queued.skb.mutableData();
    payload[8] ^= 1;
    server.queue6.append(a, queued) catch unreachable;

    var buf: [32]u8 = undefined;
    try std.testing.expectError(error.Checksum, net.recvfrom6(server, &buf));
    try std.testing.expectEqual(@as(usize, 1), net.checksum6_bad);
}

test "socket layer: AF_INET6 boot probe validates address, checksum and loopback" {
    const p = try probeInet6(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.addr_ok);
    try std.testing.expect(p.csum_ok);
    try std.testing.expect(p.bind_ok);
    try std.testing.expect(p.loopback_ok);
    try std.testing.expect(p.recv_ok);
    try std.testing.expect(p.inuse_ok);
    try std.testing.expect(p.refused_ok);
    try std.testing.expectEqual(@as(usize, 12), p.bytes);
    try std.testing.expectEqual(@as(usize, 0), p.queue);
    try std.testing.expectEqual(@as(usize, 1), p.packets);
    try std.testing.expectEqual(@as(usize, 1), p.drops);
}
