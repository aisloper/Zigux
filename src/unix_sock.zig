//! Порт ядра AF_UNIX Linux 7.3: net/unix/af_unix.c (unix_validate_addr,
//! unix_bind_bsd/abstract, unix_find_other, unix_stream_connect, unix_socketpair,
//! unix_stream_sendmsg/recvmsg) и include/uapi/linux/un.h. GPL-2.0-only.

const std = @import("std");

pub const AF_UNIX: u16 = 1;
pub const SOCK_STREAM: u8 = 1;
pub const SOCK_DGRAM: u8 = 2;
pub const UNIX_PATH_MAX: usize = 108;

pub const Addr = struct {
    abstract: bool = false,
    data: [UNIX_PATH_MAX]u8 = @splat(0),
    len: usize = 0,

    /// unix_validate_addr(): 1..108 байт sun_path; для BSD-имени длина
    /// определяется первым NUL, для abstract — вся длина incl. ведущий NUL.
    pub fn init(bytes: []const u8) !Addr {
        if (bytes.len == 0 or bytes.len > UNIX_PATH_MAX) return error.Invalid;
        var a = Addr{};
        a.abstract = bytes[0] == 0;
        const len = if (a.abstract) bytes.len else (std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len);
        if (len == 0) return error.Invalid;
        @memcpy(a.data[0..bytes.len], bytes);
        a.len = len;
        return a;
    }

    pub fn key(self: *const Addr) []const u8 {
        return self.data[0..self.len];
    }

    pub fn eql(self: *const Addr, other: *const Addr) bool {
        return self.abstract == other.abstract and std.mem.eql(u8, self.key(), other.key());
    }
};

pub const State = enum { unbound, bound, listening, connected };

pub const MAX_SOCKETS: usize = 16;
pub const MAX_MESSAGES: usize = 16;
pub const MSG_CAP: usize = 64;

pub const Message = struct {
    data: [MSG_CAP]u8 = @splat(0),
    len: usize = 0,
    off: usize = 0,
};

pub const Socket = struct {
    used: bool = false,
    kind: u8 = SOCK_STREAM,
    state: State = .unbound,
    addr: Addr = .{},
    peer: ?usize = null,
    pending: [MAX_SOCKETS]usize = @splat(0),
    nr_pending: usize = 0,
    messages: [MAX_MESSAGES]Message = undefined,
    nr_messages: usize = 0,

    fn reset(self: *Socket, kind: u8) void {
        self.* = .{ .used = true, .kind = kind };
    }
};

/// unix_socket_table + list of sockets: фиксированные слоты вместо SLAB,
/// чтобы probe работал без аллокатора в загрузочном ядре.
pub const Namespace = struct {
    sockets: [MAX_SOCKETS]Socket = undefined,
    nr_sockets: usize = 0,

    pub fn socket(self: *Namespace, kind: u8) !usize {
        if (kind != SOCK_STREAM and kind != SOCK_DGRAM) return error.InvalidType;
        if (self.nr_sockets == MAX_SOCKETS) return error.NoSpace;
        const idx = self.nr_sockets;
        self.sockets[idx].reset(kind);
        self.nr_sockets += 1;
        return idx;
    }

    fn get(self: *Namespace, idx: usize) !*Socket {
        if (idx >= self.nr_sockets or !self.sockets[idx].used) return error.BadSocket;
        return &self.sockets[idx];
    }

    /// unix_bind(): abstract-имя уникально в таблице, как и BSD-путь.
    pub fn bind(self: *Namespace, idx: usize, addr: Addr) !void {
        const s = try self.get(idx);
        if (s.state != .unbound) return error.AlreadyBound;
        for (self.sockets[0..self.nr_sockets]) |other| {
            if (other.used and other.state != .unbound and other.addr.eql(&addr))
                return error.AddressInUse;
        }
        s.addr = addr;
        s.state = .bound;
    }

    pub fn listen(self: *Namespace, idx: usize) !void {
        const s = try self.get(idx);
        if (s.kind != SOCK_STREAM or s.state != .bound) return error.InvalidState;
        s.state = .listening;
    }

    fn find(self: *Namespace, addr: *const Addr, kind: u8) ?usize {
        for (self.sockets[0..self.nr_sockets], 0..) |s, i| {
            if (s.used and s.kind == kind and s.state == .listening and s.addr.eql(addr))
                return i;
        }
        return null;
    }

    /// unix_stream_connect(): ищет слушающий сокет по имени; тип — часть ключа.
    pub fn connect(self: *Namespace, idx: usize, addr: Addr) !usize {
        const s = try self.get(idx);
        if (s.kind != SOCK_STREAM or s.state == .connected) return error.InvalidState;
        const peer_idx = self.find(&addr, SOCK_STREAM) orelse return error.ConnectionRefused;
        const peer = &self.sockets[peer_idx];
        if (peer.nr_pending == MAX_SOCKETS) return error.Busy;
        s.state = .connected;
        s.addr = addr;
        peer.pending[peer.nr_pending] = idx;
        peer.nr_pending += 1;
        return peer_idx;
    }

    /// unix_accept(): возвращает подключённый сокет из очереди слушателя.
    pub fn accept(self: *Namespace, idx: usize) !usize {
        const s = try self.get(idx);
        if (s.state != .listening or s.nr_pending == 0) return error.WouldBlock;
        const child = s.pending[0];
        s.nr_pending -= 1;
        for (0..s.nr_pending) |i| s.pending[i] = s.pending[i + 1];
        // unix_accept(): создаёт отдельный сокет на стороне сервера.
        const server = try self.socket(self.sockets[child].kind);
        self.sockets[server].state = .connected;
        self.sockets[server].addr = self.sockets[child].addr;
        self.sockets[server].peer = child;
        self.sockets[child].peer = server;
        return server;
    }

    /// unix_socketpair(): два уже связанных сокета, имена не нужны.
    pub fn socketpair(self: *Namespace, kind: u8) ![2]usize {
        const a = try self.socket(kind);
        const b = try self.socket(kind);
        self.sockets[a].state = .connected;
        self.sockets[b].state = .connected;
        self.sockets[a].peer = b;
        self.sockets[b].peer = a;
        return .{ a, b };
    }

    /// unix_stream_sendmsg()/unix_dgram_sendmsg(): сообщение в очередь peer.
    pub fn send(self: *Namespace, idx: usize, bytes: []const u8) !void {
        const s = try self.get(idx);
        if (s.state != .connected) return error.NotConnected;
        const peer_idx = s.peer orelse return error.NotConnected;
        const peer = &self.sockets[peer_idx];
        if (peer.nr_messages == MAX_MESSAGES) return error.Busy;
        if (bytes.len > MSG_CAP) return error.MessageTooLong;
        var msg = Message{};
        @memcpy(msg.data[0..bytes.len], bytes);
        msg.len = bytes.len;
        peer.messages[peer.nr_messages] = msg;
        peer.nr_messages += 1;
    }

    /// SOCK_STREAM читает через границы сообщений, SOCK_DGRAM — по одному.
    pub fn recv(self: *Namespace, idx: usize, out: []u8) !usize {
        const s = try self.get(idx);
        if (s.nr_messages == 0) return 0;
        if (s.kind == SOCK_DGRAM) {
            const msg = &s.messages[0];
            const n = @min(out.len, msg.len - msg.off);
            @memcpy(out[0..n], msg.data[msg.off .. msg.off + n]);
            msg.off += n;
            if (msg.off == msg.len) {
                s.nr_messages -= 1;
                for (0..s.nr_messages) |i| s.messages[i] = s.messages[i + 1];
            }
            return n;
        }
        var copied: usize = 0;
        while (copied < out.len and s.nr_messages > 0) {
            const msg = &s.messages[0];
            const n = @min(out.len - copied, msg.len - msg.off);
            @memcpy(out[copied .. copied + n], msg.data[msg.off .. msg.off + n]);
            msg.off += n;
            copied += n;
            if (msg.off == msg.len) {
                s.nr_messages -= 1;
                for (0..s.nr_messages) |i| s.messages[i] = s.messages[i + 1];
            }
        }
        return copied;
    }

    /// unix_release_sock(): разрывает пару и снимает имя с таблицы.
    pub fn close(self: *Namespace, idx: usize) !void {
        const s = try self.get(idx);
        if (s.peer) |peer_idx| {
            const peer = &self.sockets[peer_idx];
            if (peer.peer == idx) peer.peer = null;
        }
        s.* = .{};
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    names: bool = false,
    pair: bool = false,
    bind: bool = false,
    datagram: bool = false,
    close: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    var long_name: [109]u8 = undefined;
    @memset(&long_name, 'x');
    const valid = Addr.init("/tmp/ziglinux.sock") catch return p;
    const abstract = Addr.init(&[_]u8{ 0, 'z', 'i', 'g' }) catch return p;
    p.names = std.mem.eql(u8, valid.key(), "/tmp/ziglinux.sock") and !valid.abstract and
        abstract.abstract and std.mem.eql(u8, abstract.key(), &[_]u8{ 0, 'z', 'i', 'g' }) and
        Addr.init("") == error.Invalid and Addr.init(&long_name) == error.Invalid;

    var ns = Namespace{};
    const pair = ns.socketpair(SOCK_STREAM) catch return p;
    ns.send(pair[0], "unix") catch return p;
    var buf: [16]u8 = @splat(0);
    const got = ns.recv(pair[1], &buf) catch return p;
    p.pair = got == 4 and std.mem.eql(u8, buf[0..got], "unix");

    const path = Addr.init("/tmp/ziglinux.sock") catch return p;
    const listener = ns.socket(SOCK_STREAM) catch return p;
    ns.bind(listener, path) catch return p;
    ns.listen(listener) catch return p;
    const client = ns.socket(SOCK_STREAM) catch return p;
    _ = ns.connect(client, path) catch return p;
    const accepted = ns.accept(listener) catch return p;
    ns.send(client, "hello") catch return p;
    const n = ns.recv(accepted, &buf) catch return p;
    const again = ns.socket(SOCK_STREAM) catch return p;
    const dup = ns.bind(again, path) == error.AddressInUse;
    p.bind = ns.sockets[accepted].peer == client and ns.sockets[client].peer == accepted and
        n == 5 and std.mem.eql(u8, buf[0..n], "hello") and dup;

    const dgram = ns.socketpair(SOCK_DGRAM) catch return p;
    ns.send(dgram[0], "abc") catch return p;
    ns.send(dgram[0], "de") catch return p;
    const n1 = ns.recv(dgram[1], &buf) catch return p;
    const n2 = ns.recv(dgram[1], &buf) catch return p;
    p.datagram = n1 == 3 and n2 == 2 and std.mem.eql(u8, buf[0..n2], "de");

    ns.close(client) catch return p;
    ns.close(dgram[0]) catch return p;
    p.close = ns.sockets[accepted].peer == null and ns.sockets[dgram[1]].peer == null and
        ns.sockets[listener].nr_pending == 0;
    p.status = "ok";
    return p;
}

test "unix: sockaddr validation and abstract vs BSD names" {
    const path = try Addr.init("/tmp/ziglinux.sock");
    try std.testing.expect(!path.abstract);
    try std.testing.expectEqualStrings("/tmp/ziglinux.sock", path.key());
    const abstract = try Addr.init(&[_]u8{ 0, 'z', 'i', 'g' });
    try std.testing.expect(abstract.abstract);
    try std.testing.expectEqual(@as(usize, 4), abstract.len);
    try std.testing.expect(!path.eql(&abstract));
    try std.testing.expectError(error.Invalid, Addr.init(""));
    var long_name: [109]u8 = undefined;
    @memset(&long_name, 'x');
    try std.testing.expectError(error.Invalid, Addr.init(&long_name));
}

test "unix: socketpair streams bytes across message boundaries" {
    var ns = Namespace{};
    const pair = try ns.socketpair(SOCK_STREAM);
    try ns.send(pair[0], "ab");
    try ns.send(pair[0], "cd");
    var buf: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try ns.recv(pair[1], &buf));
    try std.testing.expectEqualStrings("abcd", &buf);
    try std.testing.expectEqual(@as(usize, 0), try ns.recv(pair[1], &buf));
    try std.testing.expectError(error.BadSocket, ns.get(MAX_SOCKETS));
}

test "unix: bind, listen, connect, accept and address uniqueness" {
    var ns = Namespace{};
    const name = try Addr.init(&[_]u8{ 0, 'z', 'g', 'x' });
    const listener = try ns.socket(SOCK_STREAM);
    try ns.bind(listener, name);
    try ns.listen(listener);
    const client = try ns.socket(SOCK_STREAM);
    try std.testing.expectEqual(listener, try ns.connect(client, name));
    const accepted = try ns.accept(listener);
    try std.testing.expect(ns.sockets[accepted].peer == client);
    const duplicate = try ns.socket(SOCK_STREAM);
    try std.testing.expectError(error.AddressInUse, ns.bind(duplicate, name));
    try ns.send(client, "ping");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try ns.recv(accepted, &buf));
    try std.testing.expectEqualStrings("ping", buf[0..4]);
    try std.testing.expectError(error.WouldBlock, ns.accept(listener));
}

test "unix: datagram boundaries and release of peer links" {
    var ns = Namespace{};
    const pair = try ns.socketpair(SOCK_DGRAM);
    try ns.send(pair[0], "abc");
    try ns.send(pair[0], "de");
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try ns.recv(pair[1], &buf));
    try std.testing.expectEqual(@as(usize, 2), try ns.recv(pair[1], &buf));
    try std.testing.expectEqualStrings("de", buf[0..2]);
    try ns.close(pair[0]);
    try std.testing.expect(ns.sockets[pair[1]].peer == null);
    try std.testing.expectError(error.NotConnected, ns.send(pair[1], "x"));
}

test "unix: boot probe exercises names, socketpair, bind, dgram and close" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.names);
    try std.testing.expect(p.pair);
    try std.testing.expect(p.bind);
    try std.testing.expect(p.datagram);
    try std.testing.expect(p.close);
}
