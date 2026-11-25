//! Boot-time block device discovery: PCI scan → virtio-blk/virtio-scsi/NVMe/
//! AHCI → GPT/MBR partition scan → ext4 superblock mounted into the task mount
//! namespace. This is the arch-side counterpart of block.zig (generic layer)
//! and ext4.zig (FS). Sources: drivers/block/virtio_blk.c,
//! drivers/scsi/virtio_scsi.c, block/partitions/{efi,msdos}.c, fs/namespace.c.
//! GPL-2.0-only.

const std = @import("std");
const block = @import("../../block.zig");
const ext4 = @import("../../ext4.zig");
const gpt = @import("../../gpt.zig");
const nvme = @import("nvme.zig");
const ahci = @import("ahci.zig");
const ramfs = @import("../../ramfs.zig");
const vfs = @import("../../vfs.zig");
const file = @import("../../file.zig");
const printk = @import("../printk.zig");
const pci = @import("pci.zig");
const virtio_blk = @import("virtio_blk.zig");
const virtio_scsi = @import("virtio_scsi.zig");

/// ext4.Writeback → block.Device: байтовое смещение раздела уже включено в image.
const WriteCtx = struct {
    dev: block.Device,

    fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
        const self: *const WriteCtx = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.dev.write(offset, bytes);
    }
};

pub const MountedExt4 = struct {
    allocator: std.mem.Allocator,
    ns: *vfs.Namespace,
    target: []const u8,
    image: []u8,
    sb: *vfs.SuperBlock,
    fs: *ext4.Ext4,
    mount: *vfs.Mount,
    write_ctx: WriteCtx,
    partition_ctx: ?*block.PartitionCtx = null,

    pub fn deinit(self: *MountedExt4) void {
        self.ns.umount(self.target) catch {};
        self.fs.deinit();
        self.allocator.destroy(self.fs);
        self.sb.deinit();
        self.allocator.destroy(self.sb);
        if (self.partition_ctx) |ctx| self.allocator.destroy(ctx);
        self.allocator.free(self.image);
        self.allocator.destroy(self);
    }
};

/// fs/partitions/msdos.c → mount_bdev(): read the whole partition into
/// memory and mount an ext4 reader with in-place writeback in the task namespace.
pub fn mountExt4Partition(
    allocator: std.mem.Allocator,
    ns: *vfs.Namespace,
    dev: block.Device,
    target: []const u8,
) !*MountedExt4 {
    var backed_dev = dev;
    var cloned: ?block.ClonedPartition = null;
    if (block.clonePartition(allocator, dev)) |c| {
        cloned = c;
        backed_dev = c.device;
    } else |_| {}
    errdefer {
        if (cloned) |c| allocator.destroy(c.ctx);
    }

    const image = try block.readAll(allocator, backed_dev);
    errdefer allocator.free(image);

    const sb = try allocator.create(vfs.SuperBlock);
    errdefer allocator.destroy(sb);
    sb.* = undefined;
    try sb.init(allocator, 64);
    errdefer sb.deinit();

    const result = try allocator.create(MountedExt4);
    errdefer allocator.destroy(result);
    result.* = .{
        .allocator = allocator,
        .ns = ns,
        .target = target,
        .image = image,
        .sb = sb,
        .fs = undefined,
        .mount = undefined,
        .write_ctx = .{ .dev = backed_dev },
        .partition_ctx = if (cloned) |c| c.ctx else null,
    };
    cloned = null; // владение контекстом раздела передано result

    const fs = try allocator.create(ext4.Ext4);
    errdefer allocator.destroy(fs);
    try fs.init(allocator, image, sb, .{ .ctx = &result.write_ctx, .write = WriteCtx.write });
    errdefer fs.deinit();

    const mount = try ns.mount(sb, fs.ops(), target);
    result.fs = fs;
    result.mount = mount;
    return result;
}

pub const ScanResult = struct {
    scanned: usize = 0,
    virtio: usize = 0,
    scsi: usize = 0,
    nvme: usize = 0,
    ahci: usize = 0,
    gpt: usize = 0,
    mbr: usize = 0,
    mounted: usize = 0,
};

pub const DiskInfo = struct {
    kind: []const u8, // "GPT" or "MBR"
    number: u16,
    mount: *MountedExt4,

    pub fn deinit(self: *DiskInfo) void {
        self.mount.deinit();
    }
};

/// block/partitions/core.c: probe GPT before msdos, then mount the first
/// ext4 partition. Returns the partition number on success.
pub fn mountFirstExt4(
    allocator: std.mem.Allocator,
    ns: *vfs.Namespace,
    dev: block.Device,
    target: []const u8,
) !DiskInfo {
    if (gpt.Table.parse(allocator, dev)) |table| {
        defer table.deinit();
        for (table.entries) |entry| {
            var ctx: block.PartitionCtx = undefined;
            const part = block.sliceDevice(&ctx, dev, entry.first_lba, entry.sectorCount());
            const mount = mountExt4Partition(allocator, ns, part, target) catch continue;
            return .{ .kind = "GPT", .number = entry.number, .mount = mount };
        }
        return error.NoExt4Partition;
    } else |_| {}

    const gd = allocator.create(block.Gendisk) catch return error.OutOfMemory;
    defer allocator.destroy(gd);
    gd.* = block.Gendisk.init(dev);
    gd.parseMbr() catch return error.Invalid;
    for (0..4) |index| {
        const part = gd.partitionDevice(index) orelse continue;
        const mount = mountExt4Partition(allocator, ns, part, target) catch continue;
        return .{ .kind = "MBR", .number = @intCast(index + 1), .mount = mount };
    }
    return error.NoExt4Partition;
}

fn mountAndReport(
    allocator: std.mem.Allocator,
    ns: *vfs.Namespace,
    dev: block.Device,
    result: *ScanResult,
    label: []const u8,
) void {
    const info = mountFirstExt4(allocator, ns, dev, "/mnt") catch |e| {
        printk.print("ziglinux: {s} mount failed: {s}\n", .{ label, @errorName(e) });
        return;
    };
    result.mounted += 1;
    if (std.mem.eql(u8, info.kind, "GPT")) result.gpt += 1 else result.mbr += 1;
    printk.print("ziglinux: {s} {s} partition {d} ext4 mounted at /mnt\n", .{
        label, info.kind, info.number,
    });
    if (ns.lookupPath("/mnt/hello.txt")) |d| {
        printk.print("ziglinux: /mnt/hello.txt ino {d}\n", .{d.d_inode.?.i_ino});
        d.d_sb.dPut(d);
    } else |_| {}
}

pub const WriteProbe = struct {
    status: []const u8 = "none",
    written: usize = 0,
    synced: usize = 0,
    dirty: usize = 0,
    readback_ok: bool = false,
    errno: i64 = 0,
};

/// Boot-time probe: in-place overwrite of the mounted /mnt/hello.txt,
/// sync_fs() writeback and readback through the same file_operations.
pub fn probeExt4Write(ns: *vfs.Namespace, text: []const u8) WriteProbe {
    var p = WriteProbe{};
    if (text.len > 64 or text.len == 0) {
        p.status = "text";
        return p;
    }
    const d = ns.lookupPath("/mnt/hello.txt") catch {
        p.status = "lookup";
        return p;
    };
    defer d.d_sb.dPut(d);

    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    var f: *file.File = undefined;
    if (fs.fileFor(d)) |existing| {
        f = existing;
    } else {
        f = fs.open(d) catch {
            p.status = "open";
            return p;
        };
    }

    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek-write";
        return p;
    }
    const n = f.write(text);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    p.written = @intCast(n);

    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }

    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek-read";
        return p;
    }
    var buf: [64]u8 = undefined;
    const rn = f.read(buf[0..text.len]);
    if (rn != @as(i64, @intCast(text.len)) or !std.mem.eql(u8, buf[0..text.len], text)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.status = "ok";
    return p;
}

pub const GrowProbe = struct {
    status: []const u8 = "none",
    written: usize = 0,
    synced: usize = 0,
    dirty: usize = 0,
    readback_ok: bool = false,
    errno: i64 = 0,
    size: u64 = 0,
    free_blocks: u64 = 0,
};

/// Boot-time probe: append a payload long enough to cross one 1 KiB extent
/// boundary, sync_fs(), then read back the appended bytes through file.File.
pub fn probeExt4Grow(ns: *vfs.Namespace, marker: []const u8) GrowProbe {
    var p = GrowProbe{};
    if (marker.len == 0 or marker.len > 64) {
        p.status = "marker";
        return p;
    }
    const d = ns.lookupPath("/mnt/hello.txt") catch {
        p.status = "lookup";
        return p;
    };
    defer d.d_sb.dPut(d);

    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    var f: *file.File = undefined;
    if (fs.fileFor(d)) |existing| {
        f = existing;
    } else {
        f = fs.open(d) catch {
            p.status = "open";
            return p;
        };
    }

    const old_size = f.llseek(0, file.SEEK_END);
    if (old_size < 0) {
        p.status = "seek-end";
        return p;
    }
    var payload: [1100]u8 = @splat('G');
    @memcpy(payload[0..marker.len], marker);
    const n = f.write(&payload);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    p.written = @intCast(n);
    p.size = @as(u64, @intCast(old_size)) + p.written;

    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    p.free_blocks = d.d_sb.statfs().bfree;
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }

    if (f.llseek(old_size, file.SEEK_SET) < 0) {
        p.status = "seek-read";
        return p;
    }
    var buf: [payload.len]u8 = undefined;
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(payload.len)) or !std.mem.eql(u8, &buf, &payload)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.status = "ok";
    return p;
}

pub const SplitProbe = struct {
    status: []const u8 = "none",
    written: usize = 0,
    depth: u16 = 0,
    synced: usize = 0,
    dirty: usize = 0,
    readback_ok: bool = false,
    errno: i64 = 0,
    size: u64 = 0,
    free_blocks: u64 = 0,
};

/// Boot-time probe: написать достаточно блоков, чтобы корневой лист extent-а
/// переполнился, проверить node depth 1 на диске и прочитать payload назад.
pub fn probeExt4Split(ns: *vfs.Namespace, marker: []const u8) SplitProbe {
    var p = SplitProbe{};
    if (marker.len == 0 or marker.len > 64) {
        p.status = "marker";
        return p;
    }
    const d = ns.lookupPath("/mnt/hello.txt") catch {
        p.status = "lookup";
        return p;
    };
    defer d.d_sb.dPut(d);

    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    var f: *file.File = undefined;
    if (fs.fileFor(d)) |existing| {
        f = existing;
    } else {
        f = fs.open(d) catch {
            p.status = "open";
            return p;
        };
    }

    const old_size = f.llseek(0, file.SEEK_END);
    if (old_size < 0) {
        p.status = "seek-end";
        return p;
    }
    var payload: [5120]u8 = @splat('S');
    @memcpy(payload[0..marker.len], marker);
    const n = f.write(&payload);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    p.written = @intCast(n);
    p.size = @as(u64, @intCast(old_size)) + p.written;

    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    p.free_blocks = d.d_sb.statfs().bfree;
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }
    const ino = d.d_inode orelse {
        p.status = "inode";
        return p;
    };
    if (ino.i_ino > std.math.maxInt(u32)) {
        p.status = "inode-number";
        return p;
    }
    p.depth = fs.extentDepth(@intCast(ino.i_ino));

    if (f.llseek(old_size, file.SEEK_SET) < 0) {
        p.status = "seek-read";
        return p;
    }
    var buf: [payload.len]u8 = undefined;
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(payload.len)) or !std.mem.eql(u8, &buf, &payload)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.status = "ok";
    return p;
}

pub const SparseProbe = struct {
    status: []const u8 = "none",
    offset: u64 = 0,
    written: usize = 0,
    size: u64 = 0,
    hole_ok: bool = false,
    readback_ok: bool = false,
    entries: u16 = 0,
    depth: u16 = 0,
    synced: usize = 0,
    dirty: usize = 0,
    free_blocks: u64 = 0,
    errno: i64 = 0,
};

/// Boot-time probe: записать за EOF, не трогая пропущенные блоки; проверить,
/// что extent вставлен по ключу, дыра читается нулями, а payload — обратно.
pub fn probeExt4Sparse(ns: *vfs.Namespace, marker: []const u8) SparseProbe {
    var p = SparseProbe{};
    if (marker.len == 0 or marker.len > 64) {
        p.status = "marker";
        return p;
    }
    const d = ns.lookupPath("/mnt/hello.txt") catch {
        p.status = "lookup";
        return p;
    };
    defer d.d_sb.dPut(d);

    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    var f: *file.File = undefined;
    if (fs.fileFor(d)) |existing| {
        f = existing;
    } else {
        f = fs.open(d) catch {
            p.status = "open";
            return p;
        };
    }

    const old_size = f.llseek(0, file.SEEK_END);
    if (old_size < 0) {
        p.status = "seek-end";
        return p;
    }
    if (old_size >= 8192) {
        p.status = "size";
        return p;
    }
    p.offset = 8192;
    if (f.llseek(@intCast(p.offset), file.SEEK_SET) < 0) {
        p.status = "seek-write";
        return p;
    }
    var payload: [512]u8 = @splat('H');
    @memcpy(payload[0..marker.len], marker);
    const n = f.write(&payload);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    p.written = @intCast(n);
    p.size = p.offset + p.written;

    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    p.free_blocks = d.d_sb.statfs().bfree;
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }
    const ino = d.d_inode orelse {
        p.status = "inode";
        return p;
    };
    if (ino.i_ino > std.math.maxInt(u32)) {
        p.status = "inode-number";
        return p;
    }
    p.entries = fs.extentEntries(@intCast(ino.i_ino));
    p.depth = fs.extentDepth(@intCast(ino.i_ino));

    var pos: u64 = @intCast(old_size);
    var hole: [1024]u8 = undefined;
    while (pos < p.offset) {
        if (f.llseek(@intCast(pos), file.SEEK_SET) < 0) {
            p.status = "seek-hole";
            return p;
        }
        const want: usize = @intCast(@min(@as(u64, hole.len), p.offset - pos));
        const rn = f.read(hole[0..want]);
        if (rn != @as(i64, @intCast(want))) {
            p.status = "read-hole";
            p.errno = rn;
            return p;
        }
        for (hole[0..want]) |b| {
            if (b != 0) {
                p.status = "hole";
                return p;
            }
        }
        pos += want;
    }
    p.hole_ok = true;

    if (f.llseek(@intCast(p.offset), file.SEEK_SET) < 0) {
        p.status = "seek-read";
        return p;
    }
    var buf: [payload.len]u8 = undefined;
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(payload.len)) or !std.mem.eql(u8, &buf, &payload)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.status = "ok";
    return p;
}

pub const Depth2Probe = struct {
    status: []const u8 = "none",
    written: usize = 0,
    size: u64 = 0,
    depth: u16 = 0,
    entries: u16 = 0,
    hole_ok: bool = false,
    readback_ok: bool = false,
    synced: usize = 0,
    dirty: usize = 0,
    free_blocks: u64 = 0,
    errno: i64 = 0,
};

/// Boot-time probe: полное depth 1 дерево (четыре leaf по 84 extent-а)
/// принимает запись в EOF: расщепляется leaf и корень, дерево становится
/// depth 2, дыры читаются нулями, а payload — обратно с диска.
pub fn probeExt4Depth2(ns: *vfs.Namespace, marker: []const u8) Depth2Probe {
    var p = Depth2Probe{};
    if (marker.len == 0 or marker.len > 64) {
        p.status = "marker";
        return p;
    }
    const d = ns.lookupPath("/mnt/hello.txt") catch {
        p.status = "lookup";
        return p;
    };
    defer d.d_sb.dPut(d);

    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    var f: *file.File = undefined;
    if (fs.fileFor(d)) |existing| {
        f = existing;
    } else {
        f = fs.open(d) catch {
            p.status = "open";
            return p;
        };
    }

    const old_size = f.llseek(0, file.SEEK_END);
    if (old_size < 0 or old_size != 336 * 1024) {
        p.status = "size";
        return p;
    }
    if (f.llseek(old_size, file.SEEK_SET) < 0) {
        p.status = "seek-write";
        return p;
    }
    var payload: [1024]u8 = @splat('D');
    @memcpy(payload[0..marker.len], marker);
    const n = f.write(&payload);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    p.written = @intCast(n);
    p.size = @as(u64, @intCast(old_size)) + p.written;

    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    p.free_blocks = d.d_sb.statfs().bfree;
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }
    const ino = d.d_inode orelse {
        p.status = "inode";
        return p;
    };
    if (ino.i_ino > std.math.maxInt(u32)) {
        p.status = "inode-number";
        return p;
    }
    p.depth = fs.extentDepth(@intCast(ino.i_ino));
    p.entries = fs.extentEntries(@intCast(ino.i_ino));

    var hole: [1024]u8 = undefined;
    for ([_]u64{ 1024, 200 * 1024 }) |offset| {
        if (f.llseek(@intCast(offset), file.SEEK_SET) < 0) {
            p.status = "seek-hole";
            return p;
        }
        const rn = f.read(&hole);
        if (rn != @as(i64, @intCast(hole.len))) {
            p.status = "read-hole";
            p.errno = rn;
            return p;
        }
        for (hole) |b| {
            if (b != 0) {
                p.status = "hole";
                return p;
            }
        }
    }
    p.hole_ok = true;

    if (f.llseek(old_size, file.SEEK_SET) < 0) {
        p.status = "seek-read";
        return p;
    }
    var buf: [payload.len]u8 = undefined;
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(payload.len)) or !std.mem.eql(u8, &buf, &payload)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.status = "ok";
    return p;
}

pub const NameiProbe = struct {
    status: []const u8 = "none",
    created: bool = false,
    unlinked: bool = false,
    readback_ok: bool = false,
    synced: usize = 0,
    dirty: usize = 0,
    errno: i64 = 0,
};

fn nameiErrno(e: anyerror) i64 {
    return switch (e) {
        error.PathExists => -17, // EEXIST
        error.NoEnt => -2, // ENOENT
        error.NotDir => -20, // ENOTDIR
        error.IsDir => -21, // EISDIR
        error.NoSpace => -file.Errno.ENOSPC,
        error.NotSupported => -file.Errno.ENOSYS,
        else => -file.Errno.EIO,
    };
}

/// Boot-time probe: vfs_create()/vfs_unlink() на смонтированном ext4. Создаёт
/// новый inode в root directory, пишет данные, читает их назад и удаляет имя.
pub fn probeExt4Namei(ns: *vfs.Namespace) NameiProbe {
    var p = NameiProbe{};
    const path = "/mnt/zigux-namei.txt";
    const text = "NAMEI OK\n";

    const d = ns.createAt(path) catch |e| {
        p.status = "creat";
        p.errno = nameiErrno(e);
        return p;
    };
    defer d.d_sb.dPut(d);
    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    const f = fs.open(d) catch {
        p.status = "open";
        return p;
    };
    const n = f.write(text);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }

    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek";
        return p;
    }
    var buf: [text.len]u8 = @splat(0);
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(text.len)) or !std.mem.eql(u8, &buf, text)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.created = true;

    ns.unlinkAt(path) catch |e| {
        p.status = "unlink";
        p.errno = nameiErrno(e);
        return p;
    };
    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    if (fs.syncFailed()) {
        p.status = "unlink-sync";
        return p;
    }
    if (ns.lookupPath(path)) |still| {
        still.d_sb.dPut(still);
        p.status = "visible";
        return p;
    } else |_| {}
    p.unlinked = true;
    p.status = "ok";
    return p;
}

pub const MkdirProbe = struct {
    status: []const u8 = "none",
    created: bool = false,
    nested: bool = false,
    readback_ok: bool = false,
    unlinked: bool = false,
    synced: usize = 0,
    dirty: usize = 0,
    errno: i64 = 0,
};

/// Boot-time probe: vfs_mkdir() в корне ext4, затем creat/write/readback внутри
/// нового каталога. Файл удаляется, пустой каталог остаётся на scratch-образе.
pub fn probeExt4Mkdir(ns: *vfs.Namespace) MkdirProbe {
    var p = MkdirProbe{};
    const dir_path = "/mnt/zigux-dir";
    const file_path = "/mnt/zigux-dir/note.txt";
    const text = "DIR OK\n";

    const dd = ns.mkdirAt(dir_path) catch |e| {
        p.status = "mkdir";
        p.errno = nameiErrno(e);
        return p;
    };
    dd.d_sb.dPut(dd);
    p.created = true;

    const dir = ns.lookupPath(dir_path) catch |e| {
        p.status = "lookup-dir";
        p.errno = nameiErrno(e);
        return p;
    };
    defer dir.d_sb.dPut(dir);
    const ino = dir.d_inode orelse {
        p.status = "dir-inode";
        return p;
    };
    if (!ino.isDir()) {
        p.status = "dir-mode";
        return p;
    }

    const d = ns.createAt(file_path) catch |e| {
        p.status = "create";
        p.errno = nameiErrno(e);
        return p;
    };
    defer d.d_sb.dPut(d);
    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    const f = fs.open(d) catch {
        p.status = "open";
        return p;
    };
    const n = f.write(text);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    d.d_sb.syncFs();
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }
    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek";
        return p;
    }
    var buf: [text.len]u8 = @splat(0);
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(text.len)) or !std.mem.eql(u8, &buf, text)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.nested = true;

    ns.unlinkAt(file_path) catch |e| {
        p.status = "unlink";
        p.errno = nameiErrno(e);
        return p;
    };
    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    if (fs.syncFailed()) {
        p.status = "unlink-sync";
        return p;
    }
    if (ns.lookupPath(file_path)) |still| {
        still.d_sb.dPut(still);
        p.status = "visible";
        return p;
    } else |_| {}
    p.unlinked = true;
    p.status = "ok";
    return p;
}

pub const RmdirProbe = struct {
    status: []const u8 = "none",
    created: bool = false,
    nested: bool = false,
    removed: bool = false,
    synced: usize = 0,
    dirty: usize = 0,
    errno: i64 = 0,
};

/// Boot-time probe: mkdir, записать файл внутри каталога, unlink файла и
/// rmdir пустого каталога. Проверяет, что счётчики и bitmap дошли до носителя.
pub fn probeExt4Rmdir(ns: *vfs.Namespace) RmdirProbe {
    var p = RmdirProbe{};
    const dir_path = "/mnt/zigux-rmdir";
    const file_path = "/mnt/zigux-rmdir/note.txt";
    const text = "RMDIR OK\n";

    const dd = ns.mkdirAt(dir_path) catch |e| {
        p.status = "mkdir";
        p.errno = nameiErrno(e);
        return p;
    };
    dd.d_sb.dPut(dd);
    p.created = true;

    const d = ns.createAt(file_path) catch |e| {
        p.status = "create";
        p.errno = nameiErrno(e);
        return p;
    };
    defer d.d_sb.dPut(d);
    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    const f = fs.open(d) catch {
        p.status = "open";
        return p;
    };
    const n = f.write(text);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }
    d.d_sb.syncFs();
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }
    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek";
        return p;
    }
    var buf: [text.len]u8 = @splat(0);
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(text.len)) or !std.mem.eql(u8, &buf, text)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.nested = true;

    ns.unlinkAt(file_path) catch |e| {
        p.status = "unlink";
        p.errno = nameiErrno(e);
        return p;
    };
    ns.rmdirAt(dir_path) catch |e| {
        p.status = "rmdir";
        p.errno = nameiErrno(e);
        return p;
    };
    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    if (fs.syncFailed()) {
        p.status = "rmdir-sync";
        return p;
    }
    if (ns.lookupPath(dir_path)) |still| {
        still.d_sb.dPut(still);
        p.status = "visible";
        return p;
    } else |_| {}
    p.removed = true;
    p.status = "ok";
    return p;
}

pub const JournalProbe = struct {
    status: []const u8 = "none",
    active: bool = false,
    readback_ok: bool = false,
    commits: usize = 0,
    replays: usize = 0,
    start: u32 = 1,
    synced: usize = 0,
    dirty: usize = 0,
    errno: i64 = 0,
};

/// Boot-time probe: записать в /mnt/hello.txt, сбросить sync_fs() через
/// внутренний JBD2-журнал и проверить, что транзакция закоммичена, а
/// `s_start` журнала снова нулевой (журнал чист, RECOVER снят).
pub fn probeExt4Journal(ns: *vfs.Namespace) JournalProbe {
    var p = JournalProbe{};
    const d = ns.lookupPath("/mnt/hello.txt") catch {
        p.status = "lookup";
        return p;
    };
    defer d.d_sb.dPut(d);

    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    p.active = fs.journalActive();
    if (!p.active) {
        p.status = "journal";
        return p;
    }

    var f: *file.File = undefined;
    if (fs.fileFor(d)) |existing| {
        f = existing;
    } else {
        f = fs.open(d) catch {
            p.status = "open";
            return p;
        };
    }
    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek-write";
        return p;
    }
    const text = "JBD2 OK\n";
    const n = f.write(text);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }

    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    p.commits = fs.journalCommits();
    p.replays = fs.journalReplays();
    p.start = fs.journalStart();
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }
    if (p.commits == 0 or p.start != 0) {
        p.status = "commit";
        return p;
    }

    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek-read";
        return p;
    }
    var buf: [text.len]u8 = @splat(0);
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(text.len)) or !std.mem.eql(u8, &buf, text)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.status = "ok";
    return p;
}

pub const Jbd2Probe = struct {
    status: []const u8 = "none",
    active: bool = false,
    features: u32 = 0,
    csum_type: u8 = 0,
    revoke_set: bool = false,
    revoke_writes: usize = 0,
    commits: usize = 0,
    replays: usize = 0,
    start: u32 = 1,
    dirty: usize = 1,
    synced: usize = 0,
    readback_ok: bool = false,
    errno: i64 = 0,
};

/// Boot-time probe: включить REVOKE/64BIT/CSUM_V3 на настоящем journal inode
/// scratch-образа, отозвать неиспользуемый блок, записать файл и убедиться,
/// что коммит содержит revoke-блок, 64-битные теги, checksum и чистый s_start.
/// Работает только под -Djbd2-probe; образ должен быть scratch-копией.
pub fn probeExt4Jbd2(ns: *vfs.Namespace) Jbd2Probe {
    var p = Jbd2Probe{};
    const d = ns.lookupPath("/mnt/hello.txt") catch {
        p.status = "lookup";
        return p;
    };
    defer d.d_sb.dPut(d);

    const fs = ext4.Ext4.fromSuper(d.d_sb) orelse {
        p.status = "superblock";
        return p;
    };
    p.active = fs.journalActive();
    if (!p.active) {
        p.status = "journal";
        return p;
    }

    const features = ext4.JBD2_FEATURE_INCOMPAT_REVOKE |
        ext4.JBD2_FEATURE_INCOMPAT_64BIT |
        ext4.JBD2_FEATURE_INCOMPAT_CSUM_V3;
    fs.journalEnableFeatures(features) catch {
        p.status = "features";
        return p;
    };
    p.features = fs.journalIncompatFeatures();
    p.csum_type = fs.journalChecksumType();
    if (p.features != features or p.csum_type != ext4.JBD2_CRC32C_CHKSUM) {
        p.status = "features-check";
        return p;
    }

    // Блок 1363 не принадлежит /hello.txt (его данных — блок 1362) и не
    // трогается записью, поэтому revoke не отменяется последующим dirty.
    fs.revokeBlock(1363) catch {
        p.status = "revoke";
        return p;
    };
    if (fs.journalRevokes() != 1) {
        p.status = "revoke-check";
        return p;
    }
    p.revoke_set = true;

    var f: *file.File = undefined;
    if (fs.fileFor(d)) |existing| {
        f = existing;
    } else {
        f = fs.open(d) catch {
            p.status = "open";
            return p;
        };
    }
    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek-write";
        return p;
    }
    const text = "JBD2 V3 OK\n";
    const n = f.write(text);
    if (n < 0) {
        p.status = "write";
        p.errno = n;
        return p;
    }

    d.d_sb.syncFs();
    p.synced = fs.syncedBlocks();
    p.dirty = fs.dirtyBlocks();
    p.commits = fs.journalCommits();
    p.replays = fs.journalReplays();
    p.start = fs.journalStart();
    p.revoke_writes = fs.journalRevokeWrites();
    if (fs.syncFailed()) {
        p.status = "sync";
        return p;
    }
    if (p.commits == 0 or p.start != 0 or p.revoke_writes != 1 or fs.journalRevokes() != 0) {
        p.status = "commit";
        return p;
    }

    if (f.llseek(0, file.SEEK_SET) < 0) {
        p.status = "seek-read";
        return p;
    }
    var buf: [text.len]u8 = @splat(0);
    const rn = f.read(&buf);
    if (rn != @as(i64, @intCast(text.len)) or !std.mem.eql(u8, &buf, text)) {
        p.status = "readback";
        p.errno = rn;
        return p;
    }
    p.readback_ok = true;
    p.status = "ok";
    return p;
}

/// pci_scan_root_bus() + driver probe + add_disk(): the UEFI kernel has no
/// hotplug, so the scan and mount run once at boot.
pub fn scanAndMount(allocator: std.mem.Allocator, ns: *vfs.Namespace) ScanResult {
    var result = ScanResult{};
    var devices: [32]pci.Device = undefined;
    result.scanned = pci.scan(&devices);

    for (devices[0..result.scanned]) |dev| {
        if (virtio_blk.isBlockDevice(dev)) {
            result.virtio += 1;
            const vb = virtio_blk.initFromPci(allocator, dev) catch continue;
            printk.print("ziglinux: virtio-blk {d} sectors at {x:0>4}:{x:0>2}\n", .{
                vb.capacity_sectors, dev.bus, dev.slot,
            });
            mountAndReport(allocator, ns, vb.device, &result, "virtio-blk");
        } else if (virtio_scsi.isScsiDevice(dev)) {
            result.scsi += 1;
            const ctrl = virtio_scsi.initFromPci(allocator, dev) catch continue;
            printk.print("ziglinux: virtio-scsi {d} sectors at {x:0>4}:{x:0>2}\n", .{
                ctrl.capacity_sectors, dev.bus, dev.slot,
            });
            mountAndReport(allocator, ns, ctrl.device, &result, "virtio-scsi");
        } else if (nvme.isNvme(dev)) {
            result.nvme += 1;
            const ctrl = nvme.initFromPci(allocator, dev) catch continue;
            printk.print("ziglinux: NVMe {d} sectors at {x:0>4}:{x:0>2}\n", .{
                ctrl.capacity_sectors, dev.bus, dev.slot,
            });
            mountAndReport(allocator, ns, ctrl.device, &result, "NVMe");
        } else if (ahci.isAhci(dev)) {
            result.ahci += 1;
            const ctrl = ahci.initFromPci(allocator, dev) catch continue;
            printk.print("ziglinux: AHCI {d} sectors at {x:0>4}:{x:0>2}\n", .{
                ctrl.capacity_sectors, dev.bus, dev.slot,
            });
            mountAndReport(allocator, ns, ctrl.device, &result, "AHCI");
        }
    }
    return result;
}

test "boot disk: GPT partition mounts ext4 through the same block path" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeTestImage(a);
    defer a.free(ext_image);
    const first_lba: u64 = 2048;
    const nr_sectors: u64 = @intCast((ext_image.len + block.SECTOR_SIZE - 1) / block.SECTOR_SIZE);
    const image = try gpt.makeTestImage(a, 4096, first_lba, nr_sectors);
    defer a.free(image);
    @memcpy(image[first_lba * block.SECTOR_SIZE ..][0..ext_image.len], ext_image);

    var memory = block.MemoryDisk{ .data = image };
    const dev = memory.device();
    var table = try gpt.Table.parse(a, dev);
    defer table.deinit();
    var ctx: block.PartitionCtx = undefined;
    const part = block.sliceDevice(&ctx, dev, table.entries[0].first_lba, table.entries[0].sectorCount());

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();

    const mounted = try mountExt4Partition(a, &ns, part, "/mnt");
    defer mounted.deinit();
    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = try mounted.fs.open(d);
    defer _ = f.put();
    var buf: [16]u8 = @splat(0);
    const n: usize = @intCast(f.read(&buf));
    try std.testing.expectEqualStrings("hello ext4\n", buf[0..n]);
}

test "boot disk scan: mountFirstExt4 probes GPT and falls back to MBR" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeTestImage(a);
    defer a.free(ext_image);
    const nr: u64 = @intCast((ext_image.len + block.SECTOR_SIZE - 1) / block.SECTOR_SIZE);

    const gpt_image = try gpt.makeTestImage(a, 4096, 2048, nr);
    defer a.free(gpt_image);
    @memcpy(gpt_image[2048 * block.SECTOR_SIZE ..][0..ext_image.len], ext_image);

    const mbr_image = try a.alloc(u8, 4096 * block.SECTOR_SIZE);
    defer a.free(mbr_image);
    @memset(mbr_image, 0);
    @memcpy(mbr_image[2048 * block.SECTOR_SIZE ..][0..ext_image.len], ext_image);
    mbr_image[510] = 0x55;
    mbr_image[511] = 0xAA;
    mbr_image[446 + 4] = 0x83;
    std.mem.writeInt(u32, mbr_image[446 + 8 ..][0..4], 2048, .little);
    std.mem.writeInt(u32, mbr_image[446 + 12 ..][0..4], @intCast(nr), .little);

    const images = [_][]u8{ gpt_image, mbr_image };
    const kinds = [_][]const u8{ "GPT", "MBR" };
    for (images, kinds) |image, kind| {
        var memory = block.MemoryDisk{ .data = image };
        var root_sb: vfs.SuperBlock = undefined;
        try root_sb.init(a, 32);
        defer root_sb.deinit();
        var root = ramfs.RamFs.init(a, &root_sb);
        defer root.deinit();
        try root.mkdir("/mnt");
        var ns: vfs.Namespace = undefined;
        try ns.init(a, &root_sb, root.ops());
        defer ns.deinit();

        var info = try mountFirstExt4(a, &ns, memory.device(), "/mnt");
        defer info.deinit();
        try std.testing.expectEqualStrings(kind, info.kind);
        try std.testing.expectEqual(@as(u16, 1), info.number);
        const d = try ns.lookupPath("/mnt/hello.txt");
        defer d.d_sb.dPut(d);
        try std.testing.expect(d.d_inode.?.i_ino > 0);
    }
}

test "boot disk: MBR partition from virtio-style device mounts ext4 in namespace" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeTestImage(a);
    defer a.free(ext_image);

    const disk_bytes = try a.alloc(u8, 1024 * 1024);
    defer a.free(disk_bytes);
    @memset(disk_bytes, 0);
    const start_sector: usize = 8;
    @memcpy(disk_bytes[start_sector * block.SECTOR_SIZE ..][0..ext_image.len], ext_image);
    disk_bytes[510] = 0x55;
    disk_bytes[511] = 0xAA;
    const entry = 446;
    disk_bytes[entry + 4] = 0x83;
    std.mem.writeInt(u32, disk_bytes[entry + 8 ..][0..4], @intCast(start_sector), .little);
    std.mem.writeInt(u32, disk_bytes[entry + 12 ..][0..4], @intCast(ext_image.len / block.SECTOR_SIZE), .little);

    var memory = block.MemoryDisk{ .data = disk_bytes };
    var gd = block.Gendisk.init(memory.device());
    try gd.parseMbr();
    const part = gd.partitionDevice(0) orelse return error.TestExpectedPartition;

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();

    const mounted = try mountExt4Partition(a, &ns, part, "/mnt");
    defer mounted.deinit();
    try std.testing.expectEqual(@as(usize, 1024), mounted.fs.block_size);

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = try mounted.fs.open(d);
    defer _ = f.put();
    var buf: [16]u8 = @splat(0);
    const n = f.read(&buf);
    try std.testing.expect(n > 0);
    const count: usize = @intCast(n);
    try std.testing.expectEqualStrings("hello ext4\n", buf[0..count]);
}

test "boot disk writeback: probe overwrites ext4 file on the backing partition" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeTestImage(a);
    defer a.free(ext_image);
    const start_sector: u64 = 8;
    const nr_sectors: u64 = @intCast(ext_image.len / block.SECTOR_SIZE);
    const bytes = try a.alloc(u8, @intCast((start_sector + nr_sectors) * block.SECTOR_SIZE));
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[@intCast(start_sector * block.SECTOR_SIZE)..][0..ext_image.len], ext_image);
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    bytes[446 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], @intCast(start_sector), .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], @intCast(nr_sectors), .little);

    var memory = block.MemoryDisk{ .data = bytes };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();

    var info = try mountFirstExt4(a, &ns, memory.device(), "/mnt");
    defer info.deinit();
    const probe = probeExt4Write(&ns, "EXT4 WRITE\n");
    try std.testing.expectEqualStrings("ok", probe.status);
    try std.testing.expect(probe.readback_ok);
    try std.testing.expectEqual(@as(usize, 11), probe.written);
    try std.testing.expectEqual(@as(usize, 1), probe.synced);
    try std.testing.expectEqual(@as(usize, 0), probe.dirty);
    const file_off: usize = @intCast(start_sector * block.SECTOR_SIZE + 10 * 1024);
    try std.testing.expectEqualStrings("EXT4 WRITE\n", bytes[file_off..][0..11]);
}

test "boot disk grow: probe appends across an extent and writes back to partition" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeTestImage(a);
    defer a.free(ext_image);
    const start_sector: u64 = 8;
    const nr_sectors: u64 = @intCast(ext_image.len / block.SECTOR_SIZE);
    const bytes = try a.alloc(u8, @intCast((start_sector + nr_sectors) * block.SECTOR_SIZE));
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[@intCast(start_sector * block.SECTOR_SIZE)..][0..ext_image.len], ext_image);
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    bytes[446 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], @intCast(start_sector), .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], @intCast(nr_sectors), .little);

    var memory = block.MemoryDisk{ .data = bytes };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();

    var info = try mountFirstExt4(a, &ns, memory.device(), "/mnt");
    defer info.deinit();
    const probe = probeExt4Grow(&ns, "EXT4 GROW\n");
    try std.testing.expectEqualStrings("ok", probe.status);
    try std.testing.expect(probe.readback_ok);
    try std.testing.expectEqual(@as(usize, 1100), probe.written);
    try std.testing.expectEqual(@as(u64, 1111), probe.size);
    try std.testing.expectEqual(@as(u64, 4), probe.free_blocks);
    try std.testing.expectEqual(@as(usize, 6), probe.synced);
    try std.testing.expectEqual(@as(usize, 0), probe.dirty);

    const base: usize = @intCast(start_sector * block.SECTOR_SIZE);
    try std.testing.expectEqualStrings("EXT4 GROW\n", bytes[base + 10 * 1024 + 11 ..][0..10]);
    try std.testing.expectEqual(@as(u8, 'G'), bytes[base + 11 * 1024]);
    try std.testing.expectEqual(@as(u8, 'G'), bytes[base + 11 * 1024 + 86]); // последний байт payload
    try std.testing.expectEqual(@as(u8, 0), bytes[base + 11 * 1024 + 87]);
}

test "boot disk split: probe grows extent tree through partition writeback" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeSplitTestImage(a);
    defer a.free(ext_image);
    const start_sector: u64 = 8;
    const nr_sectors: u64 = @intCast(ext_image.len / block.SECTOR_SIZE);
    const bytes = try a.alloc(u8, @intCast((start_sector + nr_sectors) * block.SECTOR_SIZE));
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[@intCast(start_sector * block.SECTOR_SIZE)..][0..ext_image.len], ext_image);
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    bytes[446 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], @intCast(start_sector), .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], @intCast(nr_sectors), .little);

    var memory = block.MemoryDisk{ .data = bytes };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();

    var info = try mountFirstExt4(a, &ns, memory.device(), "/mnt");
    defer info.deinit();
    const probe = probeExt4Split(&ns, "EXT4 SPLIT\n");
    try std.testing.expectEqualStrings("ok", probe.status);
    try std.testing.expect(probe.readback_ok);
    try std.testing.expectEqual(@as(u16, 1), probe.depth);
    try std.testing.expectEqual(@as(usize, 5120), probe.written);
    try std.testing.expectEqual(@as(u64, 5131), probe.size);
    try std.testing.expectEqual(@as(u64, 47), probe.free_blocks);
    try std.testing.expectEqual(@as(usize, 11), probe.synced);
    try std.testing.expectEqual(@as(usize, 0), probe.dirty);

    const base: usize = @intCast(start_sector * block.SECTOR_SIZE);
    try std.testing.expectEqualStrings("EXT4 SPLIT\n", bytes[base + 10 * 1024 + 11 ..][0..11]);
    try std.testing.expectEqual(@as(u8, 'S'), bytes[base + 11 * 1024]);
    try std.testing.expectEqual(@as(u8, 'S'), bytes[base + 16 * 1024 + 10]);
    try std.testing.expectEqual(@as(u8, 0), bytes[base + 16 * 1024 + 11]);
}

test "boot disk sparse: probe writes past EOF and reads the hole as zeros" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeSplitTestImage(a);
    defer a.free(ext_image);
    const start_sector: u64 = 8;
    const nr_sectors: u64 = @intCast(ext_image.len / block.SECTOR_SIZE);
    const bytes = try a.alloc(u8, @intCast((start_sector + nr_sectors) * block.SECTOR_SIZE));
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[@intCast(start_sector * block.SECTOR_SIZE)..][0..ext_image.len], ext_image);
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    bytes[446 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], @intCast(start_sector), .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], @intCast(nr_sectors), .little);

    var memory = block.MemoryDisk{ .data = bytes };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();

    var info = try mountFirstExt4(a, &ns, memory.device(), "/mnt");
    defer info.deinit();
    const probe = probeExt4Sparse(&ns, "SPARSE PROBE\n");
    try std.testing.expectEqualStrings("ok", probe.status);
    try std.testing.expect(probe.hole_ok);
    try std.testing.expect(probe.readback_ok);
    try std.testing.expectEqual(@as(u64, 8192), probe.offset);
    try std.testing.expectEqual(@as(usize, 512), probe.written);
    try std.testing.expectEqual(@as(u64, 8704), probe.size);
    try std.testing.expectEqual(@as(u16, 2), probe.entries);
    try std.testing.expectEqual(@as(u16, 0), probe.depth);
    try std.testing.expectEqual(@as(u64, 52), probe.free_blocks);
    try std.testing.expectEqual(@as(usize, 0), probe.dirty);
    try std.testing.expectEqual(@as(usize, 5), probe.synced); // без journal inode: writeDirty

    const base: usize = @intCast(start_sector * block.SECTOR_SIZE);
    try std.testing.expectEqualStrings("hello ext4\n", bytes[base + 10 * 1024 ..][0..11]);
    try std.testing.expectEqualStrings("SPARSE PROBE\n", bytes[base + 11 * 1024 ..][0..13]);
    try std.testing.expectEqual(@as(u8, 'H'), bytes[base + 11 * 1024 + 13]);
}

test "boot disk depth2: probe splits a full depth 1 tree into depth 2" {
    const a = std.testing.allocator;
    const ext_image = try ext4.makeDepthOneFullTestImage(a);
    defer a.free(ext_image);
    const start_sector: u64 = 2048;
    const nr_sectors: u64 = @intCast(ext_image.len / block.SECTOR_SIZE);
    const bytes = try a.alloc(u8, @intCast((start_sector + nr_sectors) * block.SECTOR_SIZE));
    defer a.free(bytes);
    @memset(bytes, 0);
    @memcpy(bytes[@intCast(start_sector * block.SECTOR_SIZE)..][0..ext_image.len], ext_image);
    bytes[510] = 0x55;
    bytes[511] = 0xAA;
    bytes[446 + 4] = 0x83;
    std.mem.writeInt(u32, bytes[446 + 8 ..][0..4], @intCast(start_sector), .little);
    std.mem.writeInt(u32, bytes[446 + 12 ..][0..4], @intCast(nr_sectors), .little);

    var memory = block.MemoryDisk{ .data = bytes };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();

    var info = try mountFirstExt4(a, &ns, memory.device(), "/mnt");
    defer info.deinit();
    const probe = probeExt4Depth2(&ns, "DEPTH2 PROBE\n");
    try std.testing.expectEqualStrings("ok", probe.status);
    try std.testing.expect(probe.hole_ok);
    try std.testing.expect(probe.readback_ok);
    try std.testing.expectEqual(@as(usize, 1024), probe.written);
    try std.testing.expectEqual(@as(u64, 345088), probe.size);
    try std.testing.expectEqual(@as(u16, 2), probe.depth);
    try std.testing.expectEqual(@as(u16, 2), probe.entries);
    try std.testing.expectEqual(@as(u64, 3742), probe.free_blocks);
    try std.testing.expectEqual(@as(usize, 0), probe.dirty);
    try std.testing.expectEqual(@as(usize, 9), probe.synced);

    const base: usize = @intCast(start_sector * block.SECTOR_SIZE);
    // Первый свободный физический блок после 336 extent-ов — 350.
    try std.testing.expectEqualStrings("DEPTH2 PROBE\n", bytes[base + 350 * 1024 ..][0..13]);
    try std.testing.expectEqual(@as(u8, 'D'), bytes[base + 350 * 1024 + 13]);
}
