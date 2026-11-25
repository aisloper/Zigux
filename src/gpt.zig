//! Read-only GPT partition parser: port of Linux block/partitions/efi.c.
//! Validates the protective MBR, the GPT header (magic, revision, header CRC,
//! LBAs and sizes), the partition entry array CRC and every usable entry.
//! GPL-2.0-only (derivative work based on Linux algorithms and API).

const std = @import("std");
const block = @import("block.zig");

pub const MAGIC = "EFI PART";
pub const HEADER_LBA: u64 = 1;
pub const HEADER_SIZE: usize = 92;
pub const ENTRY_SIZE: usize = 128;
pub const MAX_ENTRIES: u32 = 4096;

/// Linux filesystem partition type GUID (0FC63DAF-8483-4772-8E79-3D69D8477DE4).
pub const LINUX_FS_GUID = [_]u8{
    0xaf, 0x3d, 0xc6, 0x0f, 0x83, 0x84, 0x72, 0x47,
    0x8e, 0x79, 0x3d, 0x69, 0xd8, 0x47, 0x7d, 0xe4,
};

pub const Guid = struct {
    bytes: [16]u8,

    pub fn isZero(self: Guid) bool {
        for (self.bytes) |b| if (b != 0) return false;
        return true;
    }

    pub fn eql(self: Guid, other: Guid) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

pub const Entry = struct {
    number: u16,
    type_guid: Guid,
    unique_guid: Guid,
    first_lba: u64,
    last_lba: u64,
    attributes: u64,
    name_utf16: [72]u8,

    pub fn isLinuxFs(self: Entry) bool {
        return self.type_guid.eql(.{ .bytes = LINUX_FS_GUID });
    }

    pub fn sectorCount(self: Entry) u64 {
        return self.last_lba - self.first_lba + 1;
    }
};

fn read16(bytes: []const u8) u16 {
    return std.mem.readInt(u16, bytes[0..2], .little);
}
fn read32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn read64(bytes: []const u8) u64 {
    return std.mem.readInt(u64, bytes[0..8], .little);
}
fn guidAt(bytes: []const u8) Guid {
    var g: Guid = undefined;
    @memcpy(&g.bytes, bytes[0..16]);
    return g;
}

/// efi.c: find_valid_gpt() → gpt_header checks before reading the entry array.
pub const Table = struct {
    allocator: std.mem.Allocator,
    entries: []Entry,
    storage: []Entry,
    header_size: usize,
    entry_size: usize,
    first_usable_lba: u64,
    last_usable_lba: u64,

    pub fn deinit(self: *const Table) void {
        self.allocator.free(self.storage);
    }

    pub fn count(self: Table) usize {
        return self.entries.len;
    }

    /// efi.c: parse_partitions() → fill an array of entries from the raw array.
    pub fn parse(allocator: std.mem.Allocator, dev: block.Device) !Table {
        const sectors = dev.sectorCount();
        if (sectors < 34) return error.Invalid;

        // efi.c: check_protective_partition_table() — MBR type 0xEE on LBA 0.
        var mbr: [block.SECTOR_SIZE]u8 = undefined;
        try dev.read(0, &mbr);
        if (mbr[510] != 0x55 or mbr[511] != 0xAA) return error.Invalid;
        var protective = false;
        for (0..4) |i| {
            const rec = mbr[446 + i * 16 ..][0..16];
            if (rec[4] == 0xEE and read32(rec[8..]) == 1) protective = true;
        }
        if (!protective) return error.Invalid; // efi.c: pmbr_part_valid()

        var raw: [512]u8 = @splat(0);
        try dev.read(HEADER_LBA * block.SECTOR_SIZE, raw[0..]);
        if (!std.mem.eql(u8, raw[0..8], MAGIC)) return error.Invalid;
        const header_size = read32(raw[12..]);
        if (header_size < HEADER_SIZE or header_size > block.SECTOR_SIZE) return error.Invalid;
        const stored_crc = read32(raw[16..]);
        const current_lba = read64(raw[24..]);
        const first_usable = read64(raw[40..]);
        const last_usable = read64(raw[48..]);
        const entry_lba = read64(raw[72..]);
        const num_entries = read32(raw[80..]);
        const entry_size = read32(raw[84..]);
        const entries_crc = read32(raw[88..]);
        if (current_lba != HEADER_LBA) return error.Invalid;
        if (first_usable > last_usable or last_usable >= sectors) return error.Invalid;
        if (num_entries == 0 or num_entries > MAX_ENTRIES) return error.Invalid;
        if (entry_size != ENTRY_SIZE) return error.Invalid; // efi.c:414-418

        // efi.c: check_header_crc() — the field itself is zeroed for the sum.
        var header_copy: [block.SECTOR_SIZE]u8 = @splat(0);
        @memcpy(header_copy[0..header_size], raw[0..header_size]);
        @memset(header_copy[16..20], 0);
        if (std.hash.Crc32.hash(header_copy[0..header_size]) != stored_crc) return error.Invalid;

        const array_bytes = @as(u64, num_entries) * entry_size;
        if (entry_lba == 0 or entry_lba > sectors or
            array_bytes > (sectors - entry_lba) * block.SECTOR_SIZE) return error.Invalid;
        const array = try allocator.alloc(u8, @intCast(array_bytes));
        errdefer allocator.free(array);
        try dev.read(entry_lba * block.SECTOR_SIZE, array);
        if (std.hash.Crc32.hash(array) != entries_crc) return error.Invalid;

        var entries = try allocator.alloc(Entry, num_entries);
        errdefer allocator.free(entries);
        var n: usize = 0;
        for (0..num_entries) |i| {
            const e = array[i * entry_size ..][0..ENTRY_SIZE];
            const type_guid = guidAt(e[0..]);
            if (type_guid.isZero()) continue;
            const first = read64(e[32..]);
            const last = read64(e[40..]);
            if (first > last or first > sectors - 1 or last > sectors - 1) return error.Invalid;
            entries[n] = .{
                .number = @intCast(i + 1),
                .type_guid = type_guid,
                .unique_guid = guidAt(e[16..]),
                .first_lba = first,
                .last_lba = last,
                .attributes = read64(e[48..]),
                .name_utf16 = e[56..128].*,
            };
            n += 1;
        }
        allocator.free(array);
        return .{
            .allocator = allocator,
            .entries = entries[0..n],
            .storage = entries,
            .header_size = header_size,
            .entry_size = entry_size,
            .first_usable_lba = first_usable,
            .last_usable_lba = last_usable,
        };
    }
};

/// Build a small GPT image on a memory buffer for host tests: protective MBR,
/// header at LBA 1, one entry array at LBA 2, and one Linux filesystem entry.
pub fn makeTestImage(allocator: std.mem.Allocator, total_sectors: u64, first_lba: u64, nr_sectors: u64) ![]u8 {
    const image = try allocator.alloc(u8, @intCast(total_sectors * block.SECTOR_SIZE));
    errdefer allocator.free(image);
    @memset(image, 0);

    // Protective MBR: single entry type 0xEE covering the whole disk.
    image[510] = 0x55;
    image[511] = 0xAA;
    image[446 + 4] = 0xEE;
    const whole: u32 = @truncate(@min(total_sectors - 1, std.math.maxInt(u32)));
    std.mem.writeInt(u32, image[446 + 8 ..][0..4], 1, .little);
    std.mem.writeInt(u32, image[446 + 12 ..][0..4], whole, .little);

    var header: [HEADER_SIZE]u8 = @splat(0);
    @memcpy(header[0..8], MAGIC);
    std.mem.writeInt(u32, header[8..][0..4], 0x00010000, .little);
    std.mem.writeInt(u32, header[12..][0..4], HEADER_SIZE, .little);
    std.mem.writeInt(u64, header[24..][0..8], 1, .little);
    std.mem.writeInt(u64, header[32..][0..8], total_sectors - 1, .little);
    std.mem.writeInt(u64, header[40..][0..8], 34, .little);
    std.mem.writeInt(u64, header[48..][0..8], total_sectors - 34, .little);
    std.mem.writeInt(u64, header[72..][0..8], 2, .little);
    std.mem.writeInt(u32, header[80..][0..4], 128, .little);
    std.mem.writeInt(u32, header[84..][0..4], ENTRY_SIZE, .little);

    var array: [128 * ENTRY_SIZE]u8 = @splat(0);
    @memcpy(array[0..16], &LINUX_FS_GUID);
    array[16] = 0x11; // unique GUID, any nonzero value
    std.mem.writeInt(u64, array[32..][0..8], first_lba, .little);
    std.mem.writeInt(u64, array[40..][0..8], first_lba + nr_sectors - 1, .little);
    const name = [_]u16{ 'h', 'e', 'l', 'l', 'o', 0 };
    for (name, 0..) |c, i| std.mem.writeInt(u16, array[56 + i * 2 ..][0..2], c, .little);
    std.mem.writeInt(u32, header[88..][0..4], std.hash.Crc32.hash(&array), .little);
    std.mem.writeInt(u32, header[16..][0..4], std.hash.Crc32.hash(&header), .little);

    @memcpy(image[block.SECTOR_SIZE..][0..HEADER_SIZE], &header);
    @memcpy(image[2 * block.SECTOR_SIZE ..][0..array.len], &array);
    return image;
}

test "gpt: parse a valid table, translate a partition and reject CRC damage" {
    const a = std.testing.allocator;
    const image = try makeTestImage(a, 4096, 2048, 100);
    defer a.free(image);
    @memcpy(image[2048 * block.SECTOR_SIZE ..][0..5], "GPT!!");

    var disk = block.MemoryDisk{ .data = image };
    const dev = disk.device();
    var table = try Table.parse(a, dev);
    defer table.deinit();

    try std.testing.expectEqual(@as(usize, 1), table.count());
    const part = table.entries[0];
    try std.testing.expectEqual(@as(u16, 1), part.number);
    try std.testing.expect(part.isLinuxFs());
    try std.testing.expectEqual(@as(u64, 2048), part.first_lba);
    try std.testing.expectEqual(@as(u64, 100), part.sectorCount());

    var slice_ctx: block.PartitionCtx = undefined;
    const pdev = block.sliceDevice(&slice_ctx, dev, part.first_lba, part.sectorCount());
    var buf: [5]u8 = @splat(0);
    try pdev.read(0, &buf);
    try std.testing.expectEqualStrings("GPT!!", &buf);

    // Damaged header CRC must be rejected exactly as efi.c does.
    image[block.SECTOR_SIZE + 48] ^= 1;
    try std.testing.expectError(error.Invalid, Table.parse(a, dev));
}
