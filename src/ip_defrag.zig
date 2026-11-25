//! Порт IPv4 defragmentation из Linux 7.3: net/ipv4/ip_fragment.c
//! (ip_frag_queue, ip_frag_reasm, завершение по FIRST_IN/LAST_IN/meat==len)
//! и include/net/inet_frag.h. GPL-2.0-only (алгоритмы и константы Linux).

const std = @import("std");

pub const MF: u16 = 0x2000;
pub const DF: u16 = 0x4000;
pub const OFFSET_MASK: u16 = 0x1FFF;

pub const MAX_FRAGS: usize = 16;
pub const MAX_LEN: usize = 2048;

/// IP_MF и смещение из ip_hdr()->frag_off в 8-байтовых блоках.
pub fn offsetFrom(frag_off: u16) usize {
    return @as(usize, frag_off & OFFSET_MASK) * 8;
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
    stamp: u64 = 0,
    drops: usize = 0,

    pub fn reset(self: *Queue) void {
        self.nr_frags = 0;
        self.len = 0;
        self.meat = 0;
        self.first_in = false;
        self.last_in = false;
        self.complete = false;
    }

    /// inet_frag_queue_insert(): дубликат и частичное перекрытие недопустимы.
    fn overlaps(self: *const Queue, offset: usize, end: usize) bool {
        for (self.frags[0..self.nr_frags]) |f| {
            if (offset < f.end and end > f.offset) return true;
        }
        return false;
    }

    /// ip_frag_queue(): проверки границ, усечение MF до 8-байтовой границы,
    /// учёт FIRST_IN/LAST_IN/meat и запуск ip_frag_reasm() при полноте.
    pub fn queue(self: *Queue, frag_off: u16, payload: []const u8, now: u64) !void {
        if (self.complete) return error.Duplicate;
        if (self.nr_frags == MAX_FRAGS) return error.NoSpace;

        const offset = offsetFrom(frag_off);
        const mf = (frag_off & MF) != 0;
        var end = offset + payload.len;
        if (end > MAX_LEN or offset > MAX_LEN) return error.TooLarge;

        if (mf) {
            if ((end & 7) != 0) end &= ~@as(usize, 7);
        }
        if (end == offset) return error.EmptyFragment;
        if (!mf) {
            // Последний фрагмент не может быть короче уже известного конца
            // или расходиться с ним (ветка IP_MF == 0 в ip_frag_queue()).
            if (end < self.len or (self.last_in and end != self.len)) return error.BadEnd;
            self.last_in = true;
            self.len = end;
        }
        if (end > self.len) {
            if (self.last_in) return error.BadEnd;
            self.len = end;
        }
        // inet_frag_queue_insert(): точный дубликат проверяется раньше
        // поиска частичного перекрытия.
        for (self.frags[0..self.nr_frags]) |f| {
            if (f.offset == offset and f.end == end) return error.Duplicate;
        }
        if (self.overlaps(offset, end)) return error.Overlap;

        const kept = payload[0 .. end - offset];
        @memcpy(self.data[offset..end], kept);
        self.frags[self.nr_frags] = .{
            .offset = offset,
            .end = end,
            .len = kept.len,
            .mf = mf,
        };
        self.nr_frags += 1;
        self.meat += kept.len;
        self.stamp = now;
        if (offset == 0) self.first_in = true;

        if (self.first_in and self.last_in and self.meat == self.len and self.len > 0)
            self.complete = true;
    }

    /// ip_frag_reasm(): собранный датаграмм без заголовка IPv4.
    pub fn reassembled(self: *const Queue) []const u8 {
        if (!self.complete) return &.{};
        return self.data[0..self.len];
    }

    /// inet_frag_evictor(): истёкшая очередь переиспользуется заново.
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
    offsets: bool = false,
    reorder: bool = false,
    limits: bool = false,
    timeout: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    p.offsets = offsetFrom(0x0001) == 8 and offsetFrom(MF | 0x0100) == 2048 and
        (MF & OFFSET_MASK) == 0 and (DF & MF) == 0;

    var q = Queue{};
    q.queue(MF | 1, "89abcdef", 10) catch return p;
    q.queue(MF | 0, "01234567", 11) catch return p;
    q.queue(2, "XYZ", 12) catch return p;
    p.reorder = q.complete and std.mem.eql(u8, q.reassembled(), "0123456789abcdefXYZ");

    var bad = Queue{};
    bad.queue(MF | 0, "01234567", 1) catch return p;
    const dup_rejected = bad.queue(MF | 0, "01234567", 1) == error.Duplicate;
    const overlap_rejected = bad.queue(0, "0123456789abcdef", 1) == error.Overlap;
    var last = Queue{};
    last.queue(MF | 0, "0123456789abcdef", 1) catch return p;
    const bad_end = last.queue(1, "Z", 1) == error.BadEnd;
    var trim = Queue{};
    trim.queue(MF | 0, "01234567", 1) catch return p;
    trim.queue(MF | 1, "89abcdefWXYZ", 1) catch return p;
    trim.queue(2, "Z", 1) catch return p;
    const trimmed = trim.frags[1].len == 8 and trim.frags[1].end == 16;
    p.limits = dup_rejected and overlap_rejected and bad_end and trimmed;

    var expiring = Queue{};
    expiring.queue(MF | 0, "01234567", 5) catch return p;
    const before = expiring.expire(30, 10);
    expiring.queue(MF | 1, "89abcdef", 31) catch return p;
    p.timeout = before and expiring.nr_frags == 1 and !expiring.expire(35, 10) and
        expiring.expire(45, 10) and expiring.drops == 2;
    p.status = "ok";
    return p;
}

test "ip defrag: frag_off decoding follows IP_MF and IP_OFFSET" {
    try std.testing.expectEqual(@as(usize, 0), offsetFrom(0));
    try std.testing.expectEqual(@as(usize, 8), offsetFrom(1));
    try std.testing.expectEqual(@as(usize, 2048), offsetFrom(MF | 0x100));
    try std.testing.expectEqual(@as(u16, 0), MF & OFFSET_MASK);
}

test "ip defrag: out-of-order fragments reassemble in linear order" {
    var q = Queue{};
    try q.queue(MF | 1, "89abcdef", 10);
    try q.queue(MF | 0, "01234567", 11);
    try std.testing.expect(!q.complete);
    try std.testing.expectEqual(@as(usize, 16), q.len);
    try q.queue(2, "XYZ", 12);
    try std.testing.expect(q.complete);
    try std.testing.expectEqual(@as(usize, 19), q.len);
    try std.testing.expectEqualStrings("0123456789abcdefXYZ", q.reassembled());
    // ip_frag_queue(): после завершения повтор фрагмента отклоняется.
    try std.testing.expectError(error.Duplicate, q.queue(MF | 0, "01234567", 13));
}

test "ip defrag: duplicates, overlaps, short last fragment and MF trimming" {
    var q = Queue{};
    try q.queue(MF | 0, "01234567", 1);
    try std.testing.expectError(error.Duplicate, q.queue(MF | 0, "01234567", 1));
    try std.testing.expectError(error.Overlap, q.queue(0, "0123456789abcdef", 1));
    try std.testing.expectError(error.EmptyFragment, q.queue(1, "", 1));
    var last = Queue{};
    try last.queue(MF | 0, "0123456789abcdef", 1);
    try std.testing.expectError(error.BadEnd, last.queue(1, "Z", 1));
    var trim = Queue{};
    try trim.queue(MF | 0, "01234567", 1);
    try trim.queue(MF | 1, "89abcdefWXYZ", 1);
    try std.testing.expectEqual(@as(usize, 8), trim.frags[1].len);
    try std.testing.expectEqual(@as(usize, 16), trim.frags[1].end);
    try trim.queue(2, "Z", 1);
    try std.testing.expectEqualStrings("0123456789abcdefZ", trim.reassembled());
}

test "ip defrag: incomplete queue expires and can be reused" {
    var q = Queue{};
    try q.queue(MF | 0, "01234567", 5);
    try std.testing.expect(q.expire(30, 10));
    try std.testing.expectEqual(@as(usize, 0), q.nr_frags);
    try q.queue(MF | 1, "89abcdef", 31);
    try std.testing.expect(!q.expire(35, 10));
    try std.testing.expect(q.expire(45, 10));
    try std.testing.expectEqual(@as(usize, 2), q.drops);
}

test "ip defrag: boot probe exercises offsets, order, limits and timeout" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.offsets);
    try std.testing.expect(p.reorder);
    try std.testing.expect(p.limits);
    try std.testing.expect(p.timeout);
}
