//! Порт дефрагментации IPv6 Linux 7.3: net/ipv6/reassembly.c
//! (ip6_frag_queue, ip6_frag_reasm), include/net/ipv6_frag.h и
//! include/net/ipv6.h (IP6_MF, IP6_OFFSET). GPL-2.0-only.

const std = @import("std");

pub const IP6_MF: u16 = 0x0001;
pub const IP6_OFFSET: u16 = 0xFFF8;
pub const IPV6_MAXPLEN: usize = 65535;
pub const FRAG_HDR_LEN: usize = 8;
pub const NEXTHDR_TCP: u8 = 6;
pub const NEXTHDR_UDP: u8 = 17;

pub const MAX_FRAGS: usize = 16;
pub const MAX_LEN: usize = 2048;

/// include/net/ipv6_frag.h: struct frag_hdr (8 байт).
pub const FragHeader = struct {
    next_header: u8,
    reserved: u8 = 0,
    frag_off: u16,
    identification: u32,

    pub fn serialize(self: FragHeader, out: []u8) !void {
        if (out.len < FRAG_HDR_LEN) return error.NoSpace;
        out[0] = self.next_header;
        out[1] = self.reserved;
        write16(out, 2, self.frag_off);
        const v = self.identification;
        out[4] = @truncate(v >> 24);
        out[5] = @truncate(v >> 16);
        out[6] = @truncate(v >> 8);
        out[7] = @truncate(v);
    }

    pub fn parse(bytes: []const u8) !FragHeader {
        if (bytes.len < FRAG_HDR_LEN) return error.Invalid;
        return .{
            .next_header = bytes[0],
            .reserved = bytes[1],
            .frag_off = read16(bytes, 2),
            .identification = (@as(u32, bytes[4]) << 24) | (@as(u32, bytes[5]) << 16) |
                (@as(u32, bytes[6]) << 8) | bytes[7],
        };
    }
};

fn read16(bytes: []const u8, off: usize) u16 {
    return (@as(u16, bytes[off]) << 8) | bytes[off + 1];
}

fn write16(bytes: []u8, off: usize, value: u16) void {
    bytes[off] = @truncate(value >> 8);
    bytes[off + 1] = @truncate(value);
}

pub const Fragment = struct {
    offset: usize,
    end: usize,
    len: usize,
    mf: bool,
};

pub const Queue = struct {
    frags: [MAX_FRAGS]Fragment = undefined,
    data: [MAX_LEN]u8 = @splat(0),
    nr_frags: usize = 0,
    len: usize = 0,
    meat: usize = 0,
    first_in: bool = false,
    last_in: bool = false,
    complete: bool = false,
    next_header: u8 = 0,
    stamp: u64 = 0,
    drops: usize = 0,

    pub fn reset(self: *Queue) void {
        self.nr_frags = 0;
        self.len = 0;
        self.meat = 0;
        self.first_in = false;
        self.last_in = false;
        self.complete = false;
        self.next_header = 0;
    }

    fn overlaps(self: *const Queue, offset: usize, end: usize) bool {
        for (self.frags[0..self.nr_frags]) |f| {
            if (offset < f.end and end > f.offset) return true;
        }
        return false;
    }

    /// ip6_frag_queue(): в отличие от IPv4, MF-фрагмент обязан заканчиваться
    /// на границе 8 байт (иначе RFC 2460 требует ParamProblem), а длина
    /// не может превышать IPV6_MAXPLEN.
    pub fn queue(self: *Queue, frag_off: u16, payload: []const u8, next_header: u8, now: u64) !void {
        if (self.complete) return error.Duplicate;
        if (self.nr_frags == MAX_FRAGS) return error.NoSpace;

        const offset: usize = frag_off & IP6_OFFSET;
        const mf = (frag_off & IP6_MF) != 0;
        const end = offset + payload.len;
        if (end > IPV6_MAXPLEN or offset > MAX_LEN or end > MAX_LEN) return error.TooLarge;
        if (mf and (end & 7) != 0) return error.Unaligned;
        if (end == offset) return error.EmptyFragment;

        if (!mf) {
            if (end < self.len or (self.last_in and end != self.len)) return error.BadEnd;
            self.last_in = true;
            self.len = end;
        } else if (end > self.len) {
            if (self.last_in) return error.BadEnd;
            self.len = end;
        }

        for (self.frags[0..self.nr_frags]) |f| {
            if (f.offset == offset and f.end == end) return error.Duplicate;
        }
        if (self.overlaps(offset, end)) return error.Overlap;

        @memcpy(self.data[offset..end], payload);
        self.frags[self.nr_frags] = .{ .offset = offset, .end = end, .len = payload.len, .mf = mf };
        self.nr_frags += 1;
        self.meat += payload.len;
        self.stamp = now;
        if (offset == 0) {
            self.first_in = true;
            self.next_header = next_header;
        }
        if (self.first_in and self.last_in and self.meat == self.len and self.len > 0)
            self.complete = true;
    }

    /// ip6_frag_reasm(): первый next-header берётся из первого фрагмента,
    /// 8-байтовый frag header исключён из полезной нагрузки.
    pub fn reassembled(self: *const Queue) []const u8 {
        if (!self.complete) return &.{};
        return self.data[0..self.len];
    }

    pub fn expire(self: *Queue, now: u64, timeout: u64) bool {
        if (!self.complete and self.nr_frags > 0 and now >= self.stamp +% timeout) {
            self.drops += 1;
            self.reset();
            self.stamp = 0;
            return true;
        }
        return false;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    header: bool = false,
    offsets: bool = false,
    reorder: bool = false,
    limits: bool = false,
    timeout: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    var hdr_bytes: [FRAG_HDR_LEN]u8 = @splat(0);
    const hdr = FragHeader{ .next_header = NEXTHDR_TCP, .frag_off = IP6_MF | 8, .identification = 0x11223344 };
    hdr.serialize(&hdr_bytes) catch return p;
    const parsed = FragHeader.parse(&hdr_bytes) catch return p;
    p.header = parsed.next_header == NEXTHDR_TCP and parsed.frag_off == (IP6_MF | 8) and
        parsed.identification == 0x11223344;
    p.offsets = (IP6_OFFSET & IP6_MF) == 0 and (@as(u16, 9) & IP6_OFFSET) == 8;

    var q = Queue{};
    q.queue(IP6_MF, "01234567", NEXTHDR_TCP, 10) catch return p;
    q.queue(IP6_MF | 8, "89abcdef", 0, 11) catch return p;
    q.queue(16, "XYZ", 0, 12) catch return p;
    p.reorder = q.complete and q.next_header == NEXTHDR_TCP and
        std.mem.eql(u8, q.reassembled(), "0123456789abcdefXYZ");

    var bad = Queue{};
    bad.queue(IP6_MF, "01234567", NEXTHDR_UDP, 1) catch return p;
    const dup = bad.queue(IP6_MF, "01234567", NEXTHDR_UDP, 1) == error.Duplicate;
    const overlap = bad.queue(0, "0123456789abcdef", 0, 1) == error.Overlap;
    var unaligned = Queue{};
    const bad_align = unaligned.queue(IP6_MF, "0123456789ab", NEXTHDR_TCP, 1) == error.Unaligned;
    var oversized = Queue{};
    var big: [16]u8 = @splat(0);
    const too_large = oversized.queue(0xFFF8, &big, NEXTHDR_TCP, 1) == error.TooLarge;
    p.limits = dup and overlap and bad_align and too_large;

    var expiring = Queue{};
    expiring.queue(IP6_MF, "01234567", NEXTHDR_TCP, 5) catch return p;
    const before = expiring.expire(30, 10);
    expiring.queue(IP6_MF | 8, "89abcdef", 0, 31) catch return p;
    p.timeout = before and expiring.nr_frags == 1 and !expiring.expire(35, 10) and
        expiring.expire(45, 10) and expiring.drops == 2;
    p.status = "ok";
    return p;
}

test "ipv6 frag: fragment header round-trip and IP6_MF offset mask" {
    var bytes: [FRAG_HDR_LEN]u8 = @splat(0);
    const hdr = FragHeader{ .next_header = NEXTHDR_UDP, .frag_off = IP6_MF | 86, .identification = 0xDEADBEEF };
    try hdr.serialize(&bytes);
    const parsed = try FragHeader.parse(&bytes);
    try std.testing.expectEqual(@as(u8, NEXTHDR_UDP), parsed.next_header);
    try std.testing.expectEqual(@as(u16, IP6_MF | 86), parsed.frag_off);
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), parsed.identification);
    try std.testing.expectEqual(@as(u16, 0), IP6_OFFSET & IP6_MF);
}

test "ipv6 frag: out-of-order reassembly restores next header" {
    var q = Queue{};
    try q.queue(IP6_MF, "01234567", NEXTHDR_TCP, 10);
    try q.queue(IP6_MF | 8, "89abcdef", 0, 11);
    try std.testing.expect(!q.complete);
    try q.queue(16, "XYZ", 0, 12);
    try std.testing.expect(q.complete);
    try std.testing.expectEqual(@as(u8, NEXTHDR_TCP), q.next_header);
    try std.testing.expectEqualStrings("0123456789abcdefXYZ", q.reassembled());
    try std.testing.expectError(error.Duplicate, q.queue(IP6_MF, "01234567", NEXTHDR_TCP, 13));
}

test "ipv6 frag: IPv6-specific limits reject unaligned MF and oversize" {
    var q = Queue{};
    try q.queue(IP6_MF, "01234567", NEXTHDR_TCP, 1);
    try std.testing.expectError(error.Duplicate, q.queue(IP6_MF, "01234567", NEXTHDR_TCP, 1));
    try std.testing.expectError(error.Overlap, q.queue(0, "0123456789abcdef", 0, 1));
    var unaligned = Queue{};
    try std.testing.expectError(error.Unaligned, unaligned.queue(IP6_MF, "0123456789ab", NEXTHDR_TCP, 1));
    var oversized = Queue{};
    const big: [16]u8 = @splat(0);
    try std.testing.expectError(error.TooLarge, oversized.queue(0xFFF8, &big, NEXTHDR_TCP, 1));
    var last = Queue{};
    try last.queue(IP6_MF, "0123456789abcdef", NEXTHDR_TCP, 1);
    try std.testing.expectError(error.BadEnd, last.queue(8, "Z", 0, 1));
}

test "ipv6 frag: expiry reuses the queue and counts drops" {
    var q = Queue{};
    try q.queue(IP6_MF, "01234567", NEXTHDR_TCP, 5);
    try std.testing.expect(q.expire(30, 10));
    try q.queue(IP6_MF | 8, "89abcdef", 0, 31);
    try std.testing.expect(!q.expire(35, 10));
    try std.testing.expect(q.expire(45, 10));
    try std.testing.expectEqual(@as(usize, 2), q.drops);
}

test "ipv6 frag: boot probe exercises header, order, limits and timeout" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.header);
    try std.testing.expect(p.offsets);
    try std.testing.expect(p.reorder);
    try std.testing.expect(p.limits);
    try std.testing.expect(p.timeout);
}
