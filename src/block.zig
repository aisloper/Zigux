//! Порт block layer Linux 7.3 на Zig: struct block_device/request_queue/bio,
//! gendisk с MBR-разделами, memory- и file-backed диски. Ответственность
//! слоя — секторный доступ и suburban bi_sector → physic; ФС (ext4/btrfs)
//! получают уже смещённое устройство раздела.
//! Источники: include/linux/blkdev.h, include/linux/bio.h, block/bio.c,
//! block/blk-mq.c, block/partition-generic.c, fs/partitions/msdos.c.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");

/// include/linux/blkdev.h: LOGICAL_BLOCK_SIZE для host-дисков.
pub const SECTOR_SIZE: usize = 512;

pub const BlockError = error{
    Invalid,
    Io,
    OutOfRange,
    ReadOnly,
    NoSpace,
};

/// include/linux/block_device_operations + gendisk: таблица операций диска.
pub const Ops = struct {
    ctx: ?*anyopaque = null,
    read: *const fn (ctx: ?*anyopaque, sector: u64, buf: []u8) anyerror!void,
    write: ?*const fn (ctx: ?*anyopaque, sector: u64, bytes: []const u8) anyerror!void = null,
    capacity: *const fn (ctx: ?*anyopaque) u64,
};

/// fs/buffer.c: struct block_device. Публичный API — байтовые смещения,
/// внутри всё выравнивается на 512-байтовые сектора.
pub const Device = struct {
    ops: Ops,

    pub fn capacity(self: Device) u64 {
        return self.ops.capacity(self.ops.ctx);
    }

    pub fn sectorCount(self: Device) u64 {
        return self.capacity() / SECTOR_SIZE;
    }

    /// block/bio.c: bio_add_page() + submit_bio() для чтения. Невыровненные
    /// запросы читают целый сектор и выдают нужный срез.
    pub fn read(self: Device, offset: u64, buf: []u8) !void {
        if (buf.len == 0) return;
        if (offset + buf.len > self.capacity()) return error.OutOfRange;
        const first = offset / SECTOR_SIZE;
        const last = (offset + buf.len - 1) / SECTOR_SIZE;
        const start_skip: usize = @intCast(offset - first * SECTOR_SIZE);
        var cursor: usize = 0;
        var sector = first;
        while (sector <= last) : (sector += 1) {
            var block: [SECTOR_SIZE]u8 = undefined;
            try self.ops.read(self.ops.ctx, sector, &block);
            const in_block = if (sector == first) start_skip else 0;
            const n = @min(buf.len - cursor, SECTOR_SIZE - in_block);
            @memcpy(buf[cursor..][0..n], block[in_block..][0..n]);
            cursor += n;
        }
    }

    pub fn write(self: Device, offset: u64, bytes: []const u8) !void {
        if (bytes.len == 0) return;
        const write_op = self.ops.write orelse return error.ReadOnly;
        if (offset + bytes.len > self.capacity()) return error.OutOfRange;
        const first = offset / SECTOR_SIZE;
        const last = (offset + bytes.len - 1) / SECTOR_SIZE;
        const start_skip: usize = @intCast(offset - first * SECTOR_SIZE);
        var cursor: usize = 0;
        var sector = first;
        while (sector <= last) : (sector += 1) {
            var block: [SECTOR_SIZE]u8 = @splat(0);
            const in_block = if (sector == first) start_skip else 0;
            const n = @min(bytes.len - cursor, SECTOR_SIZE - in_block);
            if (in_block != 0 or n < SECTOR_SIZE) {
                // read-modify-write для неполного сектора; полные сектора
                // перезаписываются целиком, как в bio для PAGE_SIZE.
                try self.ops.read(self.ops.ctx, sector, &block);
            }
            @memcpy(block[in_block..][0..n], bytes[cursor..][0..n]);
            try write_op(self.ops.ctx, sector, &block);
            cursor += n;
        }
    }
};

/// include/linux/bio.h: struct bio — сектор + vec (у нас один непрерывный buf).
pub const Bio = struct {
    dev: Device,
    sector: u64,
    buf: []u8,
    write: bool = false,

    pub fn sectors(self: Bio) u64 {
        return (self.buf.len + SECTOR_SIZE - 1) / SECTOR_SIZE;
    }
};

/// block/blk-mq.c: упрощённая очередь с plug/merge соседних bio.
pub const RequestQueue = struct {
    allocator: std.mem.Allocator,
    pending: std.ArrayList(Pending) = .empty,
    nr_bios: u64 = 0,
    nr_merges: u64 = 0,
    nr_sectors: u64 = 0,

    const Pending = struct {
        dev: Device,
        sector: u64,
        data: std.ArrayList(u8),
        write: bool,
    };

    pub fn init(allocator: std.mem.Allocator) RequestQueue {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *RequestQueue) void {
        for (self.pending.items) |*p| p.data.deinit(self.allocator);
        self.pending.deinit(self.allocator);
    }

    /// blk_queue_bio(): если bio примыкает к предыдущему — склеиваем.
    pub fn plug(self: *RequestQueue, bio: Bio) !void {
        self.nr_bios += 1;
        self.nr_sectors += bio.sectors();
        if (self.pending.items.len > 0) {
            var last = &self.pending.items[self.pending.items.len - 1];
            const end = last.sector + (last.data.items.len + SECTOR_SIZE - 1) / SECTOR_SIZE;
            if (last.dev.ops.ctx == bio.dev.ops.ctx and last.write == bio.write and end == bio.sector) {
                try last.data.appendSlice(self.allocator, bio.buf);
                self.nr_merges += 1;
                return;
            }
        }
        var data: std.ArrayList(u8) = .empty;
        errdefer data.deinit(self.allocator);
        try data.appendSlice(self.allocator, bio.buf);
        try self.pending.append(self.allocator, .{
            .dev = bio.dev,
            .sector = bio.sector,
            .data = data,
            .write = bio.write,
        });
    }

    /// blk_mq_run_hw_queue():.dispatch всех сгруппированных bio на диск.
    pub fn dispatch(self: *RequestQueue) !void {
        for (self.pending.items) |p| {
            if (p.write) {
                try p.dev.write(p.sector * SECTOR_SIZE, p.data.items);
            } else {
                try p.dev.read(p.sector * SECTOR_SIZE, p.data.items);
            }
        }
        for (self.pending.items) |*p| p.data.deinit(self.allocator);
        self.pending.clearRetainingCapacity();
    }
};

/// fs/partitions/msdos.c: MBR-запись (4 первичных раздела).
pub const Partition = struct {
    number: u8,
    start_sector: u64,
    nr_sectors: u64,
    system: u8,
};

pub const PartitionCtx = struct {
    base: Device,
    start: u64,
    size: u64,
};

/// block/partitions/efi.c: hd_struct → block_device for a GPT partition.
/// The caller owns the context; it stays valid for the lifetime of the device.
pub fn sliceDevice(ctx: *PartitionCtx, base: Device, start_sector: u64, nr_sectors: u64) Device {
    ctx.* = .{
        .base = base,
        .start = start_sector,
        .size = nr_sectors * SECTOR_SIZE,
    };
    return .{ .ops = .{
        .ctx = ctx,
        .read = partitionRead,
        .write = partitionWrite,
        .capacity = partitionCapacity,
    } };
}

fn partitionRead(ctx: ?*anyopaque, sector: u64, buf: []u8) anyerror!void {
    const p: *PartitionCtx = @ptrCast(@alignCast(ctx orelse return error.Invalid));
    if (sector >= p.size / SECTOR_SIZE) return error.OutOfRange;
    try p.base.ops.read(p.base.ops.ctx, p.start + sector, buf);
}

fn partitionWrite(ctx: ?*anyopaque, sector: u64, bytes: []const u8) anyerror!void {
    const p: *PartitionCtx = @ptrCast(@alignCast(ctx orelse return error.Invalid));
    if (sector >= p.size / SECTOR_SIZE) return error.OutOfRange;
    const w = p.base.ops.write orelse return error.ReadOnly;
    try w(p.base.ops.ctx, p.start + sector, bytes);
}

fn partitionCapacity(ctx: ?*anyopaque) u64 {
    const p: *const PartitionCtx = @ptrCast(@alignCast(ctx orelse return 0));
    return p.size;
}

pub const ClonedPartition = struct {
    device: Device,
    ctx: *PartitionCtx,
};

/// fs/partitions/core.c: hd_struct живёт дольше mount — копируем контекст
/// раздела в heap, чтобы writeback после возврата из scanAndMount() не висел
/// на стековом Gendisk/PartitionCtx.
pub fn clonePartition(allocator: std.mem.Allocator, dev: Device) !ClonedPartition {
    if (dev.ops.read != partitionRead or dev.ops.capacity != partitionCapacity) return error.Invalid;
    if (dev.ops.write == null or dev.ops.write.? != partitionWrite) return error.Invalid;
    const src: *const PartitionCtx = @ptrCast(@alignCast(dev.ops.ctx orelse return error.Invalid));
    const ctx = try allocator.create(PartitionCtx);
    errdefer allocator.destroy(ctx);
    ctx.* = src.*;
    return .{
        .device = sliceDevice(ctx, src.base, src.start, src.size / SECTOR_SIZE),
        .ctx = ctx,
    };
}

/// include/linux/genhd.h: struct gendisk + массив partition hd_struct-ов.
pub const Gendisk = struct {
    disk: Device,
    partitions: [4]?Partition = .{ null, null, null, null },
    ctx: [4]PartitionCtx = undefined,

    pub fn init(disk: Device) Gendisk {
        return .{ .disk = disk };
    }

    /// block/partition-generic.c: parse_partitions() для MBR.
    pub fn parseMbr(self: *Gendisk) !void {
        var sector: [SECTOR_SIZE]u8 = undefined;
        try self.disk.read(0, &sector);
        if (sector[510] != 0x55 or sector[511] != 0xAA) return error.Invalid;
        for (0..4) |i| {
            const off = 446 + i * 16;
            if (sector[off + 4] == 0) continue;
            const start = std.mem.readInt(u32, sector[off + 8 ..][0..4], .little);
            const size = std.mem.readInt(u32, sector[off + 12 ..][0..4], .little);
            if (start == 0 or size == 0) return error.Invalid;
            if ((@as(u64, start) + size) * SECTOR_SIZE > self.disk.capacity()) return error.Invalid;
            self.partitions[i] = .{
                .number = @intCast(i + 1),
                .start_sector = start,
                .nr_sectors = size,
                .system = sector[off + 4],
            };
        }
    }

    /// struct block_device раздела: mutable ctx живёт внутри Gendisk.
    pub fn partitionDevice(self: *Gendisk, index: usize) ?Device {
        if (index >= 4) return null;
        const part = self.partitions[index] orelse return null;
        return sliceDevice(&self.ctx[index], self.disk, part.start_sector, part.nr_sectors);
    }
};

/// memory-backed диск (initrd/ramdisk в host-тестах).
pub const MemoryDisk = struct {
    data: []u8,

    pub fn device(self: *MemoryDisk) Device {
        return .{ .ops = .{ .ctx = self, .read = read, .write = write, .capacity = capacity } };
    }

    fn read(ctx: ?*anyopaque, sector: u64, buf: []u8) anyerror!void {
        const d: *MemoryDisk = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        const off: usize = @intCast(sector * SECTOR_SIZE);
        if (off + buf.len > d.data.len) return error.OutOfRange;
        @memcpy(buf, d.data[off..][0..buf.len]);
    }

    fn write(ctx: ?*anyopaque, sector: u64, bytes: []const u8) anyerror!void {
        const d: *MemoryDisk = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        const off: usize = @intCast(sector * SECTOR_SIZE);
        if (off + bytes.len > d.data.len) return error.OutOfRange;
        @memcpy(d.data[off..][0..bytes.len], bytes);
    }

    fn capacity(ctx: ?*anyopaque) u64 {
        const d: *const MemoryDisk = @ptrCast(@alignCast(ctx orelse return 0));
        return d.data.len;
    }
};

/// host-file диск: настоящий образ ФС на диске, читаемый через std.Io.
pub const FileDisk = struct {
    io: std.Io,
    file: std.Io.File,
    size: u64,

    pub fn create(io: std.Io, path: []const u8, size: u64) !FileDisk {
        const file = try std.Io.Dir.cwd().createFile(io, path, .{ .read = true });
        errdefer file.close(io);
        try file.setLength(io, size);
        return .{ .io = io, .file = file, .size = size };
    }

    pub fn open(io: std.Io, path: []const u8) !FileDisk {
        const file = try std.Io.Dir.cwd().openFile(io, path, .{ .mode = .read_write });
        errdefer file.close(io);
        const stat = try file.stat(io);
        return .{ .io = io, .file = file, .size = stat.size };
    }

    pub fn deinit(self: *FileDisk) void {
        self.file.close(self.io);
    }

    pub fn device(self: *FileDisk) Device {
        return .{ .ops = .{ .ctx = self, .read = read, .write = write, .capacity = capacity } };
    }

    fn read(ctx: ?*anyopaque, sector: u64, buf: []u8) anyerror!void {
        const d: *FileDisk = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        const off = sector * SECTOR_SIZE;
        if (off + buf.len > d.size) return error.OutOfRange;
        var scratch: [4096]u8 = undefined;
        var reader = std.Io.File.Reader.init(d.file, d.io, &scratch);
        try reader.seekTo(off);
        try reader.interface.readSliceAll(buf);
    }

    fn write(ctx: ?*anyopaque, sector: u64, bytes: []const u8) anyerror!void {
        const d: *FileDisk = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        const off = sector * SECTOR_SIZE;
        if (off + bytes.len > d.size) return error.OutOfRange;
        var scratch: [4096]u8 = undefined;
        var writer = std.Io.File.Writer.init(d.file, d.io, &scratch);
        try writer.seekTo(off);
        try writer.interface.writeAll(bytes);
        try writer.interface.flush();
    }

    fn capacity(ctx: ?*anyopaque) u64 {
        const d: *const FileDisk = @ptrCast(@alignCast(ctx orelse return 0));
        return d.size;
    }
};

/// fs/buffer.c: прочитать всё устройство в память ( образ для FS reader-ов ).
pub fn readAll(allocator: std.mem.Allocator, dev: Device) ![]u8 {
    const size: usize = @intCast(dev.capacity());
    const buf = try allocator.alloc(u8, size);
    errdefer allocator.free(buf);
    try dev.read(0, buf);
    return buf;
}

test "block device: unaligned read/write and capacity" {
    var storage: [8 * SECTOR_SIZE]u8 = @splat(0);
    var disk = MemoryDisk{ .data = &storage };
    const dev = disk.device();
    try std.testing.expectEqual(storage.len, dev.capacity());
    try std.testing.expectEqual(@as(u64, 8), dev.sectorCount());

    try dev.write(510, "ABCDE"); // через границу двух секторов
    var buf: [5]u8 = @splat(0);
    try dev.read(510, &buf);
    try std.testing.expectEqualStrings("ABCDE", &buf);
    try std.testing.expectEqualStrings("ABC", storage[510..513]);
    try std.testing.expectEqualStrings("CDE", storage[512..515]);
    try std.testing.expectError(error.OutOfRange, dev.read(storage.len - 1, &buf));
}

test "request_queue: merges contiguous bios and dispatches them" {
    var storage: [8 * SECTOR_SIZE]u8 = @splat(0);
    var disk = MemoryDisk{ .data = &storage };
    const dev = disk.device();
    var queue = RequestQueue.init(std.testing.allocator);
    defer queue.deinit();

    var b1: [5]u8 = "first".*;
    var b2: [6]u8 = "second".*;
    var b3: [5]u8 = "third".*;
    try queue.plug(.{ .dev = dev, .sector = 2, .buf = &b1, .write = true });
    try queue.plug(.{ .dev = dev, .sector = 3, .buf = &b2, .write = true }); // next sector → merge
    try queue.plug(.{ .dev = dev, .sector = 5, .buf = &b3, .write = true }); // gap → new request
    try std.testing.expectEqual(@as(u64, 3), queue.nr_bios);
    try std.testing.expectEqual(@as(u64, 1), queue.nr_merges);
    try std.testing.expectEqual(@as(usize, 2), queue.pending.items.len);

    try queue.dispatch();
    try std.testing.expectEqualStrings("firstsecond", storage[2 * SECTOR_SIZE ..][0..11]);
    try std.testing.expectEqualStrings("third", storage[5 * SECTOR_SIZE ..][0..5]);
    try std.testing.expectEqual(@as(usize, 0), queue.pending.items.len);
}

test "gendisk: MBR partitions translate sector numbers" {
    var storage: [64 * SECTOR_SIZE]u8 = @splat(0);
    storage[510] = 0x55;
    storage[511] = 0xAA;
    // Partition 1: тип 0x83, start=8, size=16 секторов.
    storage[446 + 4] = 0x83;
    std.mem.writeInt(u32, storage[446 + 8 ..][0..4], 8, .little);
    std.mem.writeInt(u32, storage[446 + 12 ..][0..4], 16, .little);
    @memcpy(storage[8 * SECTOR_SIZE ..][0..5], "PART1");

    var disk = MemoryDisk{ .data = &storage };
    var gendisk = Gendisk.init(disk.device());
    try gendisk.parseMbr();
    const part = gendisk.partitions[0].?;
    try std.testing.expectEqual(@as(u8, 1), part.number);
    try std.testing.expectEqual(@as(u64, 8), part.start_sector);
    try std.testing.expectEqual(@as(u64, 16), part.nr_sectors);

    const pdev = gendisk.partitionDevice(0).?;
    try std.testing.expectEqual(@as(u64, 16 * SECTOR_SIZE), pdev.capacity());
    var buf: [5]u8 = @splat(0);
    try pdev.read(0, &buf);
    try std.testing.expectEqualStrings("PART1", &buf);
    try pdev.write(0, "PART2");
    try std.testing.expectEqualStrings("PART2", storage[8 * SECTOR_SIZE ..][0..5]);
    try std.testing.expect(gendisk.partitionDevice(1) == null);
}

test "block device: real ext4/btrfs images are read from a host file through a partition" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    const path = "/tmp/ziglinux-block-test.img";
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const ext4 = @import("ext4.zig");
    const btrfs = @import("btrfs.zig");
    const vfs = @import("vfs.zig");
    const ramfs = @import("ramfs.zig");

    const ext_image = try ext4.makeTestImage(a);
    defer a.free(ext_image);
    const bt_image = try btrfs.makeTestImage();
    defer std.heap.page_allocator.free(bt_image);
    const part_sectors: u64 = 1024;
    const part_start: u64 = 8;
    const total = (part_start + part_sectors) * SECTOR_SIZE;

    // Пишем MBR + оба образа в настоящий файл через file-backed диск.
    var file_disk = try FileDisk.create(io, path, total);
    defer file_disk.deinit();
    const raw = file_disk.device();
    var mbr: [SECTOR_SIZE]u8 = @splat(0);
    mbr[510] = 0x55;
    mbr[511] = 0xAA;
    mbr[446 + 4] = 0x83;
    std.mem.writeInt(u32, mbr[446 + 8 ..][0..4], @intCast(part_start), .little);
    std.mem.writeInt(u32, mbr[446 + 12 ..][0..4], @intCast(part_sectors), .little);
    try raw.write(0, &mbr);
    try raw.write(part_start * SECTOR_SIZE, ext_image);

    var gendisk = Gendisk.init(raw);
    try gendisk.parseMbr();
    const pdev = gendisk.partitionDevice(0).?;

    // ext4: образ прочитан с диска через bio-слой и смонтирован в VFS.
    const loaded_ext = try readAll(a, pdev);
    defer a.free(loaded_ext);
    try std.testing.expectEqualSlices(u8, ext_image, loaded_ext[0..ext_image.len]);

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ext: ext4.Ext4 = undefined;
    try ext.init(a, loaded_ext, &ext_sb, null);
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");
    const fd = try ns.lookupPath("/mnt/hello.txt");
    defer fd.d_sb.dPut(fd);
    const f = ext.fileFor(fd) orelse try ext.open(fd);
    var buf: [32]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 11), f.read(&buf));
    try std.testing.expectEqualStrings("hello ext4\n", buf[0..11]);

    // btrfs: тот же путь, но образ заменяется на диске и читается заново.
    try raw.write(part_start * SECTOR_SIZE, bt_image);
    const loaded_bt = try readAll(a, pdev);
    defer a.free(loaded_bt);
    var bt_sb: vfs.SuperBlock = undefined;
    try bt_sb.init(a, 32);
    defer bt_sb.deinit();
    var fs = try btrfs.Btrfs.init(a, loaded_bt, &bt_sb);
    defer fs.deinit();

    var ns2: vfs.Namespace = undefined;
    try ns2.init(a, &root_sb, root.ops());
    defer ns2.deinit();
    _ = try ns2.mount(&bt_sb, fs.ops(), "/mnt");
    const bd = try ns2.lookupPath("/mnt/hello.txt");
    defer bd.d_sb.dPut(bd);
    const bf = fs.fileFor(bd) orelse try fs.open(bd);
    try std.testing.expectEqual(@as(i64, 12), bf.read(&buf));
    try std.testing.expectEqualStrings("hello btrfs\n", buf[0..12]);
}
