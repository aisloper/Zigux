//! Порт ядра sk_buff из Linux 7.3: линейный буфер с head/data/tail/end,
//! refcount и операциями skb_put/skb_push/skb_pull/skb_trim, clone/copy и
//! контрольная сумма RFC 1071 (csum_partial). Источники: include/linux/skbuff.h,
//! net/core/skbuff.c, lib/checksum.c. GPL-2.0-only (алгоритмы Linux).

const std = @import("std");

/// Однокомплектная сумма с переносом: то же преобразование, что csum_partial()
/// в lib/checksum.c, в сетевом порядке байтов.
pub fn checksum(bytes: []const u8) u16 {
    return checksumWithBase(bytes, 0);
}

/// csum_partial() с уже накопленным __wsum: используется IPv6-псевдозаголовком.
pub fn checksumWithBase(bytes: []const u8, base: u16) u16 {
    var sum: u32 = base;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | @as(u32, bytes[i + 1]);
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @truncate(~sum);
}

/// Проверка входящей дейтаграммы: сумма заголовка и данных должна давать 0xffff.
pub fn checksumValid(bytes: []const u8, expected: u16) bool {
    var sum: u32 = 0;
    var i: usize = 0;
    while (i + 1 < bytes.len) : (i += 2) {
        sum += (@as(u32, bytes[i]) << 8) | @as(u32, bytes[i + 1]);
    }
    if (i < bytes.len) sum += @as(u32, bytes[i]) << 8;
    sum += @as(u32, expected);
    while ((sum >> 16) != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @as(u16, @truncate(sum)) == 0xffff;
}

/// Разделяемый линейный буфер: dataref из sk_buff, но без полей VFS.
const DataBuffer = struct {
    allocator: std.mem.Allocator,
    storage: []u8,
    refs: std.atomic.Value(usize),
};

pub const SkBuff = struct {
    buffer: *DataBuffer,
    data_off: usize,
    tail_off: usize,
    /// skb->priority из include/linux/skbuff.h (используется queueing discipline).
    priority: u32 = 0,
    /// Упрощённые ECN-биты IP-заголовка для fq_codel(INET_ECN_set_ce()).
    ecn_capable: bool = false,
    ecn_ce: bool = false,

    /// net/core/skbuff.c: alloc_skb() — head/data/tail/end в одном линейном блоке.
    pub fn alloc(allocator: std.mem.Allocator, capacity: usize, reserved: usize) !*SkBuff {
        if (reserved > capacity) return error.Invalid;
        const bytes = try allocator.alloc(u8, capacity);
        @memset(bytes, 0);
        const buffer = try allocator.create(DataBuffer);
        errdefer allocator.destroy(buffer);
        errdefer allocator.free(bytes);
        buffer.* = .{
            .allocator = allocator,
            .storage = bytes,
            .refs = std.atomic.Value(usize).init(1),
        };
        const skb = try allocator.create(SkBuff);
        errdefer allocator.destroy(skb);
        skb.* = .{ .buffer = buffer, .data_off = reserved, .tail_off = reserved };
        return skb;
    }

    fn storage(self: *const SkBuff) []u8 {
        return self.buffer.storage;
    }

    /// Весь линейный буфер от head до end — для контроля суммы сегмента.
    pub fn storageForChecksum(self: *const SkBuff) []const u8 {
        return self.storage();
    }

    /// Изменяемый вид для записи checksum в уже собранный сегмент.
    pub fn mutableStorage(self: *SkBuff) []u8 {
        return self.storage();
    }

    pub fn headroom(self: *const SkBuff) usize {
        return self.data_off;
    }

    pub fn tailroom(self: *const SkBuff) usize {
        return self.storage().len - self.tail_off;
    }

    pub fn len(self: *const SkBuff) usize {
        return self.tail_off - self.data_off;
    }

    pub fn data(self: *const SkBuff) []const u8 {
        return self.storage()[self.data_off..self.tail_off];
    }

    pub fn mutableData(self: *SkBuff) []u8 {
        return self.storage()[self.data_off..self.tail_off];
    }

    pub fn refcount(self: *const SkBuff) usize {
        return self.buffer.refs.load(.monotonic);
    }

    /// skb_put(): занять место в хвосте и вернуть его под запись.
    pub fn put(self: *SkBuff, bytes: []const u8) ![]u8 {
        if (bytes.len > self.tailroom()) return error.Invalid;
        const dst = self.storage()[self.tail_off..][0..bytes.len];
        @memcpy(dst, bytes);
        self.tail_off += bytes.len;
        return dst;
    }

    /// skb_put_zero(): зарезервировать ноль-заполненный хвост.
    pub fn putZero(self: *SkBuff, count: usize) ![]u8 {
        if (count > self.tailroom()) return error.Invalid;
        const dst = self.storage()[self.tail_off..][0..count];
        @memset(dst, 0);
        self.tail_off += count;
        return dst;
    }

    /// skb_push(): добавить заголовок перед данными из headroom.
    pub fn push(self: *SkBuff, count: usize) ![]u8 {
        if (count > self.headroom()) return error.Invalid;
        self.data_off -= count;
        return self.storage()[self.data_off..][0..count];
    }

    /// skb_pull(): убрать заголовок из начала данных.
    pub fn pull(self: *SkBuff, count: usize) ![]u8 {
        if (count > self.len()) return error.Invalid;
        const head = self.storage()[self.data_off..][0..count];
        self.data_off += count;
        return head;
    }

    /// skb_trim(): обрезать хвост до заданной длины.
    pub fn trim(self: *SkBuff, count: usize) !void {
        if (count > self.len()) return error.Invalid;
        self.tail_off = self.data_off + count;
    }

    /// skb_clone(): новый sk_buff с общий dataref буфера.
    pub fn clone(self: *SkBuff) !*SkBuff {
        _ = self.buffer.refs.fetchAdd(1, .monotonic);
        const cloned = try self.buffer.allocator.create(SkBuff);
        errdefer {
            _ = self.buffer.refs.fetchSub(1, .acq_rel);
            self.buffer.allocator.destroy(cloned);
        }
        cloned.* = .{ .buffer = self.buffer, .data_off = self.data_off, .tail_off = self.tail_off };
        return cloned;
    }

    /// skb_copy(): независимая копия с сохранением headroom/tailroom.
    pub fn copy(self: *const SkBuff) !*SkBuff {
        const fresh = try SkBuff.alloc(self.buffer.allocator, self.storage().len, self.data_off);
        @memcpy(fresh.storage(), self.storage());
        fresh.tail_off = self.tail_off;
        return fresh;
    }

    /// pskb_expand_head() в упрощённом варианте: разделить общий буфер перед
    /// изменением данных, если на него ссылается больше одного skb.
    pub fn unshare(self: *SkBuff) !*SkBuff {
        if (self.refcount() == 1) return self;
        const fresh = try self.copy();
        self.free();
        return fresh;
    }

    /// kfree_skb(): последний dataref освобождает storage.
    pub fn free(self: *SkBuff) void {
        const buffer = self.buffer;
        self.buffer.allocator.destroy(self);
        if (buffer.refs.fetchSub(1, .acq_rel) != 1) return;
        buffer.allocator.free(buffer.storage);
        buffer.allocator.destroy(buffer);
    }

    pub fn csum(self: *const SkBuff) u16 {
        return checksum(self.data());
    }
};

test "skb: put/push/pull/trim preserve Linux headroom and tailroom invariants" {
    const skb = try SkBuff.alloc(std.testing.allocator, 128, 16);
    defer skb.free();
    try std.testing.expectEqual(@as(usize, 16), skb.headroom());
    try std.testing.expectEqual(@as(usize, 112), skb.tailroom());
    try std.testing.expectEqual(@as(usize, 0), skb.len());

    _ = try skb.put("hello");
    try std.testing.expectEqual(@as(usize, 5), skb.len());
    try std.testing.expectEqual(@as(usize, 107), skb.tailroom());
    try std.testing.expectEqualStrings("hello", skb.data());

    const header = try skb.push(8);
    @memset(header, 0xaa);
    try std.testing.expectEqual(@as(usize, 8), skb.headroom());
    try std.testing.expectEqual(@as(usize, 13), skb.len());
    try std.testing.expectEqual(@as(u8, 0xaa), skb.data()[0]);

    const pulled = try skb.pull(8);
    try std.testing.expectEqual(@as(usize, 8), pulled.len);
    try std.testing.expectEqual(@as(usize, 16), skb.headroom());
    try std.testing.expectEqual(@as(usize, 5), skb.len());
    try std.testing.expectEqualStrings("hello", skb.data());

    try skb.trim(3);
    try std.testing.expectEqualStrings("hel", skb.data());
    try std.testing.expectError(error.Invalid, skb.pull(4));
    try std.testing.expectError(error.Invalid, skb.push(17));
    var too_big: [110]u8 = undefined;
    @memset(&too_big, 0);
    try std.testing.expectError(error.Invalid, skb.put(&too_big));
}

test "skb: clone shares storage, copy and unshare give independent buffers" {
    const skb = try SkBuff.alloc(std.testing.allocator, 64, 4);
    _ = try skb.put("shared");
    const cloned = try skb.clone();
    try std.testing.expectEqual(@as(usize, 2), skb.refcount());
    try std.testing.expectEqual(@as(usize, 2), cloned.refcount());
    try std.testing.expectEqual(@as([*]const u8, skb.data().ptr), cloned.data().ptr);

    const copied = try skb.copy();
    defer copied.free();
    try std.testing.expectEqual(@as(usize, 1), copied.refcount());
    try std.testing.expect(copied.data().ptr != skb.data().ptr);
    copied.mutableData()[0] = 'X';
    try std.testing.expectEqualStrings("shared", skb.data());

    const unshared = try cloned.unshare();
    defer unshared.free();
    try std.testing.expectEqual(@as(usize, 1), skb.refcount());
    try std.testing.expectEqual(@as(usize, 1), unshared.refcount());
    try std.testing.expectEqualStrings("shared", unshared.data());
    try std.testing.expect(unshared.data().ptr != skb.data().ptr);
    skb.free();
}

test "skb: RFC 1071 checksum folds carry bytes and validates a datagram" {
    const skb = try SkBuff.alloc(std.testing.allocator, 64, 0);
    defer skb.free();
    _ = try skb.put(&[_]u8{ 0x45, 0x00, 0x00, 0x19, 0x00, 0x01 });
    const sum = skb.csum();
    try std.testing.expect(sum != 0);
    try std.testing.expect(checksumValid(skb.data(), sum));

    var corrupt: [6]u8 = undefined;
    @memcpy(&corrupt, skb.data());
    corrupt[0] ^= 1;
    try std.testing.expect(!checksumValid(&corrupt, sum));
}
