//! ACPI MADT разбор на Zig — аналог acpi/madt.c в ядре Linux.
//! Чистые функции без архитектурных зависимостей: работают и в host-тестах,
//! и в UEFI-ядре поверх физической памяти через срез байтов.
const std = @import("std");

pub fn checksum(bytes: []const u8) bool {
    var sum: u8 = 0;
    for (bytes) |b| sum +%= b;
    return sum == 0;
}

fn read32(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) |
        (@as(u32, bytes[1]) << 8) |
        (@as(u32, bytes[2]) << 16) |
        (@as(u32, bytes[3]) << 24);
}

/// linux: acpi_parse_madt_lapic_entries(). out[0] — BSP, остальные —
/// включённые процессорные LAPIC-записи в порядке появления в MADT.
pub fn parseLapicIds(madt: []const u8, bsp: u32, out: []u32) usize {
    if (madt.len < 44 or out.len == 0) return 0;
    out[0] = bsp;
    var nr: usize = 1;
    var off: usize = 44;
    while (off + 2 <= madt.len) {
        const kind = madt[off];
        const len: usize = madt[off + 1];
        if (len < 2 or off + len > madt.len) break;
        if (kind == 0 and len >= 8 and nr < out.len) {
            const id: u32 = madt[off + 3];
            const flags = read32(madt[off + 4 .. off + 8]);
            if ((flags & 1) != 0 and id != bsp) {
                out[nr] = id;
                nr += 1;
            }
        }
        off += len;
    }
    return nr;
}

fn addEntry(buf: []u8, off: usize, kind: u8, len: u8, id: u8, flags: u32) void {
    buf[off] = kind;
    buf[off + 1] = len;
    if (len >= 8) {
        buf[off + 3] = id;
        const f = [4]u8{
            @truncate(flags),
            @truncate(flags >> 8),
            @truncate(flags >> 16),
            @truncate(flags >> 24),
        };
        @memcpy(buf[off + 4 .. off + 8], &f);
    }
}

test "MADT LAPIC entries: enabled AP IDs, skip BSP/disabled/IO APIC" {
    var madt: [76]u8 = @splat(0);
    @memcpy(madt[0..4], "APIC");
    madt[4] = 76;
    madt[8] = 1;
    addEntry(&madt, 44, 0, 8, 0, 1); // BSP
    addEntry(&madt, 52, 0, 8, 1, 1); // AP
    addEntry(&madt, 60, 1, 8, 2, 1); // IO APIC: skipped
    addEntry(&madt, 68, 0, 8, 3, 0); // disabled CPU: skipped
    var sum: u8 = 0;
    for (madt) |b| sum +%= b;
    madt[9] = 0 -% sum;
    try std.testing.expect(checksum(&madt));

    var ids = [4]u32{ 0xDEAD, 0xDEAD, 0xDEAD, 0xDEAD };
    try std.testing.expectEqual(@as(usize, 2), parseLapicIds(&madt, 0, &ids));
    try std.testing.expectEqual(@as(u32, 0), ids[0]);
    try std.testing.expectEqual(@as(u32, 1), ids[1]);
}

test "MADT parser honors disabled CPUs and output capacity" {
    var madt: [68]u8 = @splat(0);
    madt[4] = 68;
    addEntry(&madt, 44, 0, 8, 1, 1);
    addEntry(&madt, 52, 0, 8, 2, 0); // disabled
    addEntry(&madt, 60, 0, 8, 3, 1);

    var ids = [2]u32{ 0, 0 };
    try std.testing.expectEqual(@as(usize, 2), parseLapicIds(&madt, 0, &ids));
    try std.testing.expectEqual(@as(u32, 1), ids[1]);

    var full: [76]u8 = @splat(0);
    full[4] = 76;
    addEntry(&full, 44, 0, 8, 1, 1);
    addEntry(&full, 52, 0, 8, 2, 1);
    addEntry(&full, 60, 0, 8, 3, 1);
    var cap = [2]u32{ 0, 0 };
    try std.testing.expectEqual(@as(usize, 2), parseLapicIds(&full, 0, &cap));
    try std.testing.expectEqual(@as(u32, 1), cap[1]);
}
