//! Минимальный read-only reader btrfs для порта Linux 7.3 на Zig: superblock,
//! sys_chunk_array → chunk tree (logical→physical), B-tree (ctree) обход,
//! root/FS tree, INODE/DIR_INDEX/EXTENT_DATA items, inline symlinks.
//! Файлы показываются в VFS через LookupOps + file_operations + super_operations.
//! Источники: fs/btrfs/super.c, fs/btrfs/volumes.c, fs/btrfs/ctree.c,
//! fs/btrfs/inode.c, fs/btrfs/dir-item.c, include/linux/btrfs_tree.h.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const vfs = @import("vfs.zig");
const file = @import("file.zig");

/// include/linux/btrfs_tree.h: подпись на диске (не statfs magic).
pub const BTRFS_MAGIC: u64 = 0x4D5F_5366_5248_425F;
/// include/uapi/linux/magic.h: BTRFS_SUPER_MAGIC — то, что возвращает statfs.
pub const BTRFS_SUPER_MAGIC: u64 = 0x9123_683E;
/// fs/btrfs/ctree.h: суперблок btrfs живёт по фиксированному смещению.
pub const BTRFS_SUPER_INFO_OFFSET: usize = 64 * 1024;

const KeyType = struct {
    const INODE_ITEM: u8 = 1;
    const DIR_ITEM: u8 = 84;
    const DIR_INDEX: u8 = 96;
    const EXTENT_DATA: u8 = 108;
    const ROOT_ITEM: u8 = 132;
    const CHUNK_ITEM: u8 = 228;
};
const Obj = struct {
    const ROOT: u64 = 1;
    const CHUNK: u64 = 3;
    const FS: u64 = 5;
    /// fs/btrfs/ctree.h: BTRFS_FIRST_CHUNK_TREE_OBJECTID — objectid ключа
    /// CHUNK_ITEM и в chunk tree, и в sys_chunk_array. Логический адрес лежит
    /// в key.offset, а не в objectid!
    const FIRST_CHUNK: u64 = 0x100;
};
const DirFt = struct {
    const REG_FILE: u8 = 1;
    const DIR: u8 = 2;
    const SYMLINK: u8 = 7;
};
const BLOCK_GROUP_DATA: u64 = 1 << 0;
const BLOCK_GROUP_SYSTEM: u64 = 1 << 1;
const BLOCK_GROUP_METADATA: u64 = 1 << 2;
const BLOCK_GROUP_PROFILE_MASK: u64 = 0x3ff0; // RAID0/1/10/5/6/DUP/…

pub const BtrfsError = error{
    Invalid,
    Corrupt,
    NoEnt,
    NotDir,
};

const HEADER_SIZE: usize = 101; // sizeof(struct btrfs_header), packed
const ITEM_SIZE: usize = 25; // sizeof(struct btrfs_item)
const KEY_PTR_SIZE: usize = 33; // sizeof(struct btrfs_key_ptr)
const CHUNK_HDR_SIZE: usize = 48; // до массива stripe
const STRIPE_SIZE: usize = 32;
const MAX_LEVEL: usize = 8; // BTRFS_MAX_LEVEL

fn rd16(buf: []const u8, off: usize) !u16 {
    if (off + 2 > buf.len) return error.Corrupt;
    var tmp: [2]u8 = undefined;
    @memcpy(&tmp, buf[off..][0..2]);
    return std.mem.readInt(u16, &tmp, .little);
}

fn rd32(buf: []const u8, off: usize) !u32 {
    if (off + 4 > buf.len) return error.Corrupt;
    var tmp: [4]u8 = undefined;
    @memcpy(&tmp, buf[off..][0..4]);
    return std.mem.readInt(u32, &tmp, .little);
}

fn rd64(buf: []const u8, off: usize) !u64 {
    if (off + 8 > buf.len) return error.Corrupt;
    var tmp: [8]u8 = undefined;
    @memcpy(&tmp, buf[off..][0..8]);
    return std.mem.readInt(u64, &tmp, .little);
}

fn put16(buf: []u8, off: usize, value: u16) void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, value, .little);
    @memcpy(buf[off..][0..2], &tmp);
}

fn put32(buf: []u8, off: usize, value: u32) void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, value, .little);
    @memcpy(buf[off..][0..4], &tmp);
}

fn put64(buf: []u8, off: usize, value: u64) void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .little);
    @memcpy(buf[off..][0..8], &tmp);
}

/// struct btrfs_disk_key — packed: objectid(8), type(1), offset(8).
const Key = struct {
    objectid: u64,
    type: u8,
    offset: u64,

    fn parse(buf: []const u8) Key {
        return .{
            .objectid = rd64(buf, 0) catch 0,
            .type = if (buf.len > 8) buf[8] else 0,
            .offset = rd64(buf, 9) catch 0,
        };
    }

    fn write(buf: []u8, key: Key) void {
        put64(buf, 0, key.objectid);
        buf[8] = key.type;
        put64(buf, 9, key.offset);
    }

    fn eql(a: Key, b: Key) bool {
        return a.objectid == b.objectid and a.type == b.type and a.offset == b.offset;
    }
};

/// fs/btrfs/volumes.c: chunk — отображение логического адреса в физический.
const Chunk = struct {
    logical: u64,
    length: u64,
    physical: u64,
    flags: u64,
};

/// fs/super.c: super_operations btrfs.Ctx отделён от Btrfs, чтобы ctx в
/// SuperBlock не указывал на копию структуры, возвращённой из init().
const Meta = struct {
    total_bytes: u64,
    bytes_used: u64,
    sectorsize: u64,
    nr_inodes: u64,
};

/// Обратный вызов обхода B-tree: key + тело item внутри листа.
const Visitor = struct {
    ctx: *anyopaque,
    visit: *const fn (ctx: *anyopaque, key: Key, data: []const u8) anyerror!void,
};

/// read-only btrfs: образ ФС уже лежит в памяти (будущий block device).
pub const Btrfs = struct {
    allocator: std.mem.Allocator,
    image: []const u8,
    sb: *vfs.SuperBlock,
    sectorsize: usize,
    nodesize: usize,
    root_bytenr: u64,
    root_level: u8,
    chunk_root_bytenr: u64,
    chunk_root_level: u8,
    root_dir_objectid: u64,
    total_bytes: u64,
    bytes_used: u64,
    chunks: std.ArrayList(Chunk) = .empty,
    /// VFS.iget() копирует i_link сразу, но буфер должен жить до конца обхода.
    links: std.ArrayList([]u8) = .empty,
    meta: *Meta,
    files: std.ArrayList(*file.File) = .empty,

    pub fn init(allocator: std.mem.Allocator, image: []const u8, sb: *vfs.SuperBlock) !Btrfs {
        var self = Btrfs{
            .allocator = allocator,
            .image = image,
            .sb = sb,
            .sectorsize = 0,
            .nodesize = 0,
            .root_bytenr = 0,
            .root_level = 0,
            .chunk_root_bytenr = 0,
            .chunk_root_level = 0,
            .root_dir_objectid = 0,
            .total_bytes = 0,
            .bytes_used = 0,
            .meta = undefined,
        };
        errdefer self.chunks.deinit(allocator);
        errdefer self.links.deinit(allocator);
        try self.parseSuper();
        const meta = try allocator.create(Meta);
        meta.* = .{
            .total_bytes = self.total_bytes,
            .bytes_used = self.bytes_used,
            .sectorsize = self.sectorsize,
            .nr_inodes = 0,
        };
        self.meta = meta;
        errdefer allocator.destroy(meta);
        try self.bootstrapChunks();
        try self.loadChunks();
        sb.setSuperOps(.{ .ctx = meta, .statfs = statfs, .sync_fs = syncFs });
        meta.nr_inodes = try self.countInodes();
        return self;
    }

    pub fn deinit(self: *Btrfs) void {
        for (self.files.items) |f| {
            if (f.dentry) |d| {
                d.d_sb.dPut(d);
                f.dentry = null;
            }
            self.allocator.destroy(f);
        }
        self.files.deinit(self.allocator);
        for (self.links.items) |link| self.allocator.free(link);
        self.links.deinit(self.allocator);
        self.chunks.deinit(self.allocator);
        self.allocator.destroy(self.meta);
    }

    pub fn ops(self: *Btrfs) vfs.LookupOps {
        return .{ .ctx = self, .lookup = lookup };
    }

    fn parseSuper(self: *Btrfs) !void {
        const off = BTRFS_SUPER_INFO_OFFSET;
        if (try rd64(self.image, off + 64) != BTRFS_MAGIC) return error.Invalid;
        const sectorsize = try rd32(self.image, off + 144);
        const nodesize = try rd32(self.image, off + 148);
        if (sectorsize < 4096 or nodesize < 4096) return error.Invalid;
        if (sectorsize > 64 * 1024 or nodesize > 64 * 1024) return error.Invalid;
        if (sectorsize > self.image.len or nodesize > self.image.len) return error.Invalid;
        self.sectorsize = sectorsize;
        self.nodesize = nodesize;
        self.root_bytenr = try rd64(self.image, off + 80);
        self.chunk_root_bytenr = try rd64(self.image, off + 88);
        self.root_level = self.image[off + 198];
        self.chunk_root_level = self.image[off + 199];
        self.total_bytes = try rd64(self.image, off + 112);
        self.bytes_used = try rd64(self.image, off + 120);
        self.root_dir_objectid = try rd64(self.image, off + 128);
        if (self.root_level > MAX_LEVEL or self.chunk_root_level > MAX_LEVEL) return error.Invalid;
        if (self.root_dir_objectid == 0) return error.Invalid;
        // fs/btrfs/disk-io.c: RAID56 иExtent_Tree_V2 требуют другой логики.
        const incompat = try rd64(self.image, off + 188);
        if (incompat & ((1 << 7) | (1 << 13)) != 0) return error.Invalid;
    }

    fn addChunk(self: *Btrfs, logical: u64, length: u64, physical: u64, flags: u64) !void {
        if (length == 0 or logical + length < logical) return error.Corrupt;
        for (self.chunks.items) |c| {
            if (c.logical == logical and c.length == length) return;
        }
        try self.chunks.append(self.allocator, .{
            .logical = logical,
            .length = length,
            .physical = physical,
            .flags = flags,
        });
    }

    /// fs/btrfs/volumes.c: btrfs_read_sys_chunk_array() — загрузочные чанки,
    /// без которых нельзя прочитать сам chunk tree.
    fn bootstrapChunks(self: *Btrfs) !void {
        const sb = BTRFS_SUPER_INFO_OFFSET;
        const array_size = try rd32(self.image, sb + 160);
        if (array_size == 0 or array_size > 2048) return error.Invalid;
        const array = self.image[sb + 811 ..][0..array_size];
        var off: usize = 0;
        while (off + 17 + CHUNK_HDR_SIZE + STRIPE_SIZE <= array.len) {
            const key = Key.parse(array[off..][0..17]);
            if (key.type != KeyType.CHUNK_ITEM) return error.Corrupt;
            const chunk = array[off + 17 ..];
            const stripes = try rd16(chunk, 44);
            if (stripes == 0) {
                // Остаток массива — нулевое выравнивание суперблока.
                if (std.mem.allEqual(u8, array[off..], 0)) break;
                return error.Corrupt;
            }
            const size = CHUNK_HDR_SIZE + @as(usize, stripes) * STRIPE_SIZE;
            if (off + 17 + size > array.len) return error.Corrupt;
            const length = try rd64(chunk, 0);
            const flags = try rd64(chunk, 24);
            const profile = flags & BLOCK_GROUP_PROFILE_MASK;
            if (profile != 0 and profile != (1 << 5)) return error.Invalid;
            // fs/btrfs/volumes.c: key.offset — логический старт чанка;
            // single/DUP читают данные из stripe[0] (DUP зеркалирует в stripe[1]).
            const physical = try rd64(chunk, CHUNK_HDR_SIZE + 8);
            try self.addChunk(key.offset, length, physical, flags);
            off += 17 + size;
        }
        if (self.chunks.items.len == 0) return error.Invalid;
    }

    const ChunkCollector = struct {
        btrfs: *Btrfs,

        fn visit(ctx: *anyopaque, key: Key, data: []const u8) anyerror!void {
            const c: *ChunkCollector = @ptrCast(@alignCast(ctx));
            if (key.type != KeyType.CHUNK_ITEM) return;
            const length = try rd64(data, 0);
            const flags = try rd64(data, 24);
            const stripes = try rd16(data, 44);
            if (stripes == 0 or data.len < CHUNK_HDR_SIZE + @as(usize, stripes) * STRIPE_SIZE) return error.Corrupt;
            const profile = flags & BLOCK_GROUP_PROFILE_MASK;
            if (profile != 0 and profile != (1 << 5)) return error.Invalid; // только single/DUP
            const physical = try rd64(data, CHUNK_HDR_SIZE + 8);
            try c.btrfs.addChunk(key.offset, length, physical, flags);
        }

        fn visitor(self: *ChunkCollector) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    fn loadChunks(self: *Btrfs) !void {
        var collector = ChunkCollector{ .btrfs = self };
        try self.walkTree(self.chunk_root_bytenr, self.chunk_root_level, collector.visitor());
    }

    fn mapLogical(self: *const Btrfs, logical: u64) ?u64 {
        for (self.chunks.items) |c| {
            if (logical >= c.logical and logical < c.logical + c.length) {
                return c.physical + (logical - c.logical);
            }
        }
        return null;
    }

    fn node(self: *const Btrfs, logical: u64) ![]const u8 {
        const physical = self.mapLogical(logical) orelse return error.Corrupt;
        if (physical + self.nodesize > self.image.len) return error.Corrupt;
        const start: usize = @intCast(physical);
        return self.image[start..][0..self.nodesize];
    }

    /// fs/btrfs/ctree.c: обход дерева по уровням; лист содержит отсортированные
    /// item-ы, data-область растёт с конца блока (btrfs_leaf_data).
    fn walkTree(self: *const Btrfs, bytenr: u64, level: u8, visitor: Visitor) !void {
        if (level > MAX_LEVEL) return error.Corrupt;
        const block = try self.node(bytenr);
        const nritems = try rd32(block, 96);
        if (nritems == 0) return;
        if (level == 0) {
            if (nritems > (self.nodesize - HEADER_SIZE) / ITEM_SIZE) return error.Corrupt;
            // btrfs_leaf_data() — начало data-области relative to HEADER_SIZE;
            // offset каждого item считается отсюда, а не от конца массива item-ов.
            const data_base = HEADER_SIZE;
            var i: usize = 0;
            while (i < nritems) : (i += 1) {
                const item = block[HEADER_SIZE + i * ITEM_SIZE ..][0..ITEM_SIZE];
                const key = Key.parse(item[0..17]);
                const off = try rd32(item, 17);
                const size = try rd32(item, 21);
                const begin = data_base + off;
                if (begin + size > block.len) return error.Corrupt;
                try visitor.visit(visitor.ctx, key, block[begin..][0..size]);
            }
            return;
        }
        if (nritems > (self.nodesize - HEADER_SIZE) / KEY_PTR_SIZE) return error.Corrupt;
        var i: usize = 0;
        while (i < nritems) : (i += 1) {
            const ptr = block[HEADER_SIZE + i * KEY_PTR_SIZE ..][0..KEY_PTR_SIZE];
            const child = try rd64(ptr, 17);
            try self.walkTree(child, level - 1, visitor);
        }
    }

    const RootItem = struct { bytenr: u64 = 0, level: u8 = 0, found: bool = false };

    const RootCollector = struct {
        want: u64,
        out: *RootItem,

        fn visit(ctx: *anyopaque, key: Key, data: []const u8) anyerror!void {
            const c: *RootCollector = @ptrCast(@alignCast(ctx));
            if (key.type != KeyType.ROOT_ITEM or key.objectid != c.want) return;
            if (data.len < 239) return error.Corrupt;
            c.out.* = .{
                .bytenr = try rd64(data, 176),
                .level = data[238],
                .found = true,
            };
        }

        fn visitor(self: *RootCollector) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    const RootDirCheck = struct {
        want: u64,
        found: bool = false,

        fn visit(ctx: *anyopaque, key: Key, _: []const u8) anyerror!void {
            const c: *RootDirCheck = @ptrCast(@alignCast(ctx));
            if (key.type == KeyType.INODE_ITEM and key.objectid == c.want) c.found = true;
        }

        fn visitor(self: *RootDirCheck) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    /// fs/btrfs/disk-io.c: у top-level subvolume root dir (root_dir_objectid)
    /// лежит прямо в root tree; остальные subvolume-ы — в FS tree (objectid 5).
    fn fsTree(self: *const Btrfs) !RootItem {
        var check = RootDirCheck{ .want = self.root_dir_objectid };
        try self.walkTree(self.root_bytenr, self.root_level, check.visitor());
        if (check.found) {
            return .{ .bytenr = self.root_bytenr, .level = self.root_level, .found = true };
        }
        var out = RootItem{};
        var collector = RootCollector{ .want = Obj.FS, .out = &out };
        try self.walkTree(self.root_bytenr, self.root_level, collector.visitor());
        if (!out.found or out.level > MAX_LEVEL) return error.Corrupt;
        return out;
    }

    const InodeCollector = struct {
        want: u64,
        out: ?vfs.InodeInfo = null,

        fn visit(ctx: *anyopaque, key: Key, data: []const u8) anyerror!void {
            const c: *InodeCollector = @ptrCast(@alignCast(ctx));
            if (key.type != KeyType.INODE_ITEM or key.objectid != c.want) return;
            if (data.len < 56) return error.Corrupt;
            c.out = .{
                .ino = c.want,
                .mode = try rd32(data, 52),
                .size = try rd64(data, 16),
            };
        }

        fn visitor(self: *InodeCollector) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    fn inodeInfo(self: *const Btrfs, ino: u64) !vfs.InodeInfo {
        const fs = try self.fsTree();
        var collector = InodeCollector{ .want = ino };
        try self.walkTree(fs.bytenr, fs.level, collector.visitor());
        return collector.out orelse error.NoEnt;
    }

    const CountCollector = struct {
        count: u64 = 0,

        fn visit(ctx: *anyopaque, key: Key, _: []const u8) anyerror!void {
            const c: *CountCollector = @ptrCast(@alignCast(ctx));
            if (key.type == KeyType.INODE_ITEM) c.count += 1;
        }

        fn visitor(self: *CountCollector) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    fn countInodes(self: *const Btrfs) !u64 {
        const fs = try self.fsTree();
        var counter = CountCollector{};
        try self.walkTree(fs.bytenr, fs.level, counter.visitor());
        return counter.count;
    }

    /// fs/btrfs/inode.c: btrfs_get_extent() — inline и regular extents;
    /// дыры остаются нулями (buf уже обнулён вызывающим).
    fn readAt(self: *const Btrfs, ino: u64, offset: u64, buf: []u8) !usize {
        if (buf.len == 0) return 0;
        const info = try self.inodeInfo(ino);
        if (offset >= info.size) return 0;
        const want: usize = @intCast(@min(@as(u64, buf.len), info.size - offset));
        @memset(buf[0..want], 0);
        const fs = try self.fsTree();
        var reader = ExtentReader{
            .btrfs = self,
            .want_ino = ino,
            .start = offset,
            .end = offset + want,
            .dst = buf[0..want],
        };
        try self.walkTree(fs.bytenr, fs.level, reader.visitor());
        return want;
    }

    const ExtentReader = struct {
        btrfs: *const Btrfs,
        want_ino: u64,
        start: u64,
        end: u64,
        dst: []u8,

        fn visit(ctx: *anyopaque, key: Key, data: []const u8) anyerror!void {
            const r: *ExtentReader = @ptrCast(@alignCast(ctx));
            if (key.type != KeyType.EXTENT_DATA or key.objectid != r.want_ino) return;
            if (data.len < 21) return error.Corrupt;
            const compression = data[16];
            if (compression != 0) return error.Invalid;
            const extent_type = data[20];
            const ram_bytes = try rd64(data, 8);
            var logical_len: u64 = ram_bytes;
            var copy_from: ?[]const u8 = null;
            var disk_logical: u64 = 0;
            var disk_skip: u64 = 0;
            if (extent_type == 0) {
                // BTRFS_FILE_EXTENT_INLINE: данные начинаются сразу после type.
                if (data.len < 21 + ram_bytes) return error.Corrupt;
                copy_from = data[21..][0..@as(usize, @intCast(ram_bytes))];
            } else if (extent_type == 1) {
                if (data.len < 53) return error.Corrupt;
                disk_logical = try rd64(data, 21);
                const disk_num = try rd64(data, 29);
                disk_skip = try rd64(data, 37);
                logical_len = try rd64(data, 45);
                if (disk_skip > disk_num or logical_len > disk_num) return error.Corrupt;
            } else return error.Invalid;
            if (logical_len == 0) return;
            const extent_end = key.offset + logical_len;
            const from = @max(r.start, key.offset);
            const to = @min(r.end, extent_end);
            if (from >= to) return;
            const skip: usize = @intCast(from - key.offset);
            const n: usize = @intCast(to - from);
            if (copy_from) |inline_data| {
                if (skip + n > inline_data.len) return error.Corrupt;
                @memcpy(r.dst[from - r.start ..][0..n], inline_data[skip..][0..n]);
            } else {
                const physical = r.btrfs.mapLogical(disk_logical) orelse return error.Corrupt;
                const src: u64 = physical + disk_skip + skip;
                if (src + n > r.btrfs.image.len) return error.Corrupt;
                const begin: usize = @intCast(src);
                @memcpy(r.dst[from - r.start ..][0..n], r.btrfs.image[begin..][0..n]);
            }
        }

        fn visitor(self: *ExtentReader) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    fn readLink(self: *Btrfs, ino: u64) ?[]u8 {
        const info = self.inodeInfo(ino) catch return null;
        if (info.mode & 0o170000 != vfs.S_IFLNK) return null;
        if (info.size > 4096) return null;
        const buf = self.allocator.alloc(u8, @intCast(info.size)) catch return null;
        errdefer self.allocator.free(buf);
        _ = self.readAt(ino, 0, buf) catch return null;
        self.links.append(self.allocator, buf) catch {
            self.allocator.free(buf);
            return null;
        };
        return buf;
    }

    /// fs/btrfs/dir-item.c: запись subvolume указывает на ROOT_ITEM, а не на
    /// INODE_ITEM. ROOT_ITEM начинается со встроенного btrfs_inode_item.
    const RootInodeCollector = struct {
        want: u64,
        out: ?vfs.InodeInfo = null,

        fn visit(ctx: *anyopaque, key: Key, data: []const u8) anyerror!void {
            const c: *RootInodeCollector = @ptrCast(@alignCast(ctx));
            if (key.type != KeyType.ROOT_ITEM or key.objectid != c.want) return;
            if (data.len < 56) return error.Corrupt;
            c.out = .{
                .ino = c.want,
                .mode = try rd32(data, 52),
                .size = try rd64(data, 16),
            };
        }

        fn visitor(self: *RootInodeCollector) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    fn rootItemInfo(self: *const Btrfs, ino: u64) !vfs.InodeInfo {
        var collector = RootInodeCollector{ .want = ino };
        try self.walkTree(self.root_bytenr, self.root_level, collector.visitor());
        return collector.out orelse error.NoEnt;
    }

    const DirCollector = struct {
        btrfs: *Btrfs,
        want_ino: u64,
        name: []const u8,
        out: ?vfs.InodeInfo = null,

        fn visit(ctx: *anyopaque, key: Key, data: []const u8) anyerror!void {
            const c: *DirCollector = @ptrCast(@alignCast(ctx));
            if (key.objectid != c.want_ino) return;
            if (key.type != KeyType.DIR_ITEM and key.type != KeyType.DIR_INDEX) return;
            if (data.len < 30) return error.Corrupt;
            const name_len = try rd16(data, 27);
            if (@as(usize, name_len) + 30 > data.len) return error.Corrupt;
            if (!std.mem.eql(u8, data[30..][0..name_len], c.name)) return;
            const child = Key.parse(data[0..17]);
            const ft = data[29];
            const base: u32 = switch (ft) {
                DirFt.DIR => vfs.S_IFDIR | 0o755,
                DirFt.SYMLINK => vfs.S_IFLNK | 0o777,
                DirFt.REG_FILE => vfs.S_IFREG | 0o644,
                else => vfs.S_IFREG | 0o644,
            };
            const info = if (child.type == KeyType.ROOT_ITEM)
                c.btrfs.rootItemInfo(child.objectid) catch return error.NoEnt
            else
                c.btrfs.inodeInfo(child.objectid) catch return error.NoEnt;
            var link: ?[]u8 = null;
            if (info.mode & 0o170000 == vfs.S_IFLNK) {
                link = c.btrfs.readLink(child.objectid) orelse return error.NoEnt;
            }
            c.out = .{ .ino = child.objectid, .mode = base, .size = info.size, .link = link };
        }

        fn visitor(self: *DirCollector) Visitor {
            return .{ .ctx = self, .visit = visit };
        }
    };

    fn lookupDir(self: *Btrfs, dirid: u64, q: vfs.Qstr) ?vfs.InodeInfo {
        const fs = self.fsTree() catch return null;
        var collector = DirCollector{
            .btrfs = self,
            .want_ino = dirid,
            .name = q.name,
        };
        self.walkTree(fs.bytenr, fs.level, collector.visitor()) catch return null;
        return collector.out;
    }

    /// struct file для dentry, полученной через VFS namei.
    pub fn open(self: *Btrfs, d: *vfs.Dentry) !*file.File {
        const ino = d.d_inode orelse return error.NoEnt;
        _ = try self.inodeInfo(ino.i_ino);
        const f = try self.allocator.create(file.File);
        errdefer self.allocator.destroy(f);
        f.* = .{
            .f_ops = .{ .ctx = self, .read = fileRead, .llseek = fileSeek },
            .dentry = d,
        };
        try self.files.append(self.allocator, f);
        return f;
    }

    pub fn fileFor(self: *const Btrfs, d: *vfs.Dentry) ?*file.File {
        for (self.files.items) |f| {
            if (f.dentry == d) return f;
        }
        return null;
    }

    fn fileRead(ctx: ?*anyopaque, f: *file.File, buf: []u8, pos: u64) i64 {
        const self: *Btrfs = @ptrCast(@alignCast(ctx orelse return -file.Errno.EIO));
        const d = f.dentry orelse return -file.Errno.EIO;
        const ino = d.d_inode orelse return -file.Errno.EIO;
        const n = self.readAt(ino.i_ino, pos, buf) catch return -file.Errno.EIO;
        return @intCast(n);
    }

    fn fileSeek(_: ?*anyopaque, f: *file.File, off: i64, whence: u8) i64 {
        const d = f.dentry orelse return -file.Errno.EIO;
        const size: i64 = if (d.d_inode) |ino| @intCast(ino.i_size) else 0;
        const base: i64 = switch (whence) {
            file.SEEK_SET => 0,
            file.SEEK_CUR => @intCast(f.f_pos),
            file.SEEK_END => size,
            else => return -file.Errno.EINVAL,
        };
        const res = base + off;
        return if (res < 0) -file.Errno.EINVAL else res;
    }
};

fn statfs(ctx: ?*anyopaque, _: *vfs.SuperBlock) vfs.SuperStats {
    const m: *const Meta = @ptrCast(@alignCast(ctx orelse return .{}));
    const bsize = m.sectorsize;
    const used = @min(m.bytes_used, m.total_bytes);
    return .{
        .magic = BTRFS_SUPER_MAGIC,
        .bsize = bsize,
        .blocks = m.total_bytes / bsize,
        .bfree = (m.total_bytes - used) / bsize,
        .bavail = (m.total_bytes - used) / bsize,
        .files = m.nr_inodes,
        .ffree = 0,
    };
}

/// read-only: грязных данных для записи нет.
fn syncFs(_: ?*anyopaque, _: *vfs.SuperBlock) void {}

fn lookup(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) ?vfs.InodeInfo {
    const self: *Btrfs = @ptrCast(@alignCast(ctx orelse return null));
    const dirid = if (parent.isRoot()) self.root_dir_objectid else blk: {
        const ino = parent.d_inode orelse return null;
        break :blk ino.i_ino;
    };
    return self.lookupDir(dirid, q);
}

// ───────────────────────────── тестовый образ ─────────────────────────────

const ItemDef = struct { key: Key, data: []const u8 };
const PtrDef = struct { key: Key, blockptr: u64 };

fn buildNode(node: []u8, bytenr: u64, level: u8, ptrs: []const PtrDef) void {
    @memset(node, 0);
    put64(node, 48, bytenr);
    put64(node, 80, 1);
    put32(node, 96, @intCast(ptrs.len));
    node[100] = level;
    for (ptrs, 0..) |ptr, i| {
        const slot = node[HEADER_SIZE + i * KEY_PTR_SIZE ..][0..KEY_PTR_SIZE];
        Key.write(slot[0..17], ptr.key);
        put64(slot, 17, ptr.blockptr);
        put64(slot, 25, 1); // generation
    }
}

fn buildLeaf(node: []u8, bytenr: u64, level: u8, items: []const ItemDef) void {
    @memset(node, 0);
    put64(node, 48, bytenr); // btree_header.bytenr
    put64(node, 80, 1); // generation
    put32(node, 96, @intCast(items.len)); // nritems
    node[100] = level;
    const data_base = HEADER_SIZE;
    var cursor = node.len;
    for (items, 0..) |item, i| {
        // Data-область листа растёт с конца блока навстречу массиву item-ов.
        cursor -= item.data.len;
        @memcpy(node[cursor..][0..item.data.len], item.data);
        const slot = node[HEADER_SIZE + i * ITEM_SIZE ..][0..ITEM_SIZE];
        Key.write(slot[0..17], item.key);
        put32(slot, 17, @intCast(cursor - data_base));
        put32(slot, 21, @intCast(item.data.len));
    }
}

fn makeInode(mode: u32, size: u64) [160]u8 {
    var buf: [160]u8 = @splat(0);
    put64(&buf, 8, 1); // transid
    put64(&buf, 16, size);
    put64(&buf, 24, size); // nbytes
    put32(&buf, 40, 1); // nlink
    put32(&buf, 52, mode);
    return buf;
}

fn makeRootItem(bytenr: u64, level: u8) [439]u8 {
    var buf: [439]u8 = @splat(0);
    put64(&buf, 8, 1);
    put64(&buf, 160, 1); // generation
    put64(&buf, 168, 256); // root_dirid
    put64(&buf, 176, bytenr);
    buf[238] = level;
    put64(&buf, 239, 1); // generation_v2
    return buf;
}

fn makeChunk(length: u64, physical: u64, mirror: u64, flags: u64) [112]u8 {
    var buf: [112]u8 = @splat(0);
    put64(&buf, 0, length);
    put64(&buf, 16, 4096); // stripe_len
    put64(&buf, 24, flags);
    put32(&buf, 40, 4096); // sector_size
    put16(&buf, 44, if (mirror == 0) 1 else 2); // num_stripes
    put64(&buf, 48, 1); // devid stripe[0]
    put64(&buf, 56, physical);
    if (mirror != 0) {
        put64(&buf, 48 + STRIPE_SIZE, 1); // devid stripe[1]
        put64(&buf, 48 + STRIPE_SIZE + 8, mirror);
    }
    return buf;
}

fn makeDirItem(child: u64, name: []const u8, ft: u8) []u8 {
    const buf = std.heap.page_allocator.alloc(u8, 30 + name.len) catch unreachable;
    @memset(buf, 0);
    Key.write(buf[0..17], .{ .objectid = child, .type = KeyType.INODE_ITEM, .offset = 0 });
    put16(buf, 27, @intCast(name.len));
    buf[29] = ft;
    @memcpy(buf[30..][0..name.len], name);
    return buf;
}

fn makeExtent(logical: u64, physical: u64, len: u64) [53]u8 {
    var buf: [53]u8 = @splat(0);
    put64(&buf, 8, len); // ram_bytes
    buf[20] = 1; // BTRFS_FILE_EXTENT_REG
    put64(&buf, 21, logical);
    put64(&buf, 29, len);
    put64(&buf, 37, 0);
    put64(&buf, 45, len);
    _ = physical;
    return buf;
}

fn makeInline(data: []const u8) []u8 {
    const buf = std.heap.page_allocator.alloc(u8, 21 + data.len) catch unreachable;
    @memset(buf, 0);
    put64(buf, 8, data.len);
    buf[20] = 0; // BTRFS_FILE_EXTENT_INLINE
    @memcpy(buf[21..][0..data.len], data);
    return buf;
}

/// Синтетический btrfs: логические адреса 0x1000/0x2000/0x3000/0x9000
/// отображаются в физические 0x21000/0x22000/0x23000/0x31000 двумя чанками.
pub fn makeTestImage() ![]u8 {
    const image = try std.heap.page_allocator.alloc(u8, 256 * 1024);
    @memset(image, 0);
    const sb = BTRFS_SUPER_INFO_OFFSET;

    const root_item = makeRootItem(0x3000, 0);
    const chunk_a = makeChunk(0x8000, 0x20000, 0, BLOCK_GROUP_SYSTEM | BLOCK_GROUP_METADATA);
    // DUP-профиль с двумя stripes: первая содержит те же данные, вторая — зеркало.
    const chunk_b = makeChunk(0x4000, 0x30000, 0x40000, BLOCK_GROUP_DATA | (1 << 5));
    const root_node = try std.heap.page_allocator.alloc(u8, 4096);
    const root_leaf = try std.heap.page_allocator.alloc(u8, 4096);
    const chunk_node = try std.heap.page_allocator.alloc(u8, 4096);
    const fs_node = try std.heap.page_allocator.alloc(u8, 4096);

    const data = "hello btrfs\n";
    const target = "hello.txt";
    const dir_inode = makeInode(vfs.S_IFDIR | 0o755, 4096);
    const file_inode = makeInode(vfs.S_IFREG | 0o644, data.len);
    const link_inode = makeInode(vfs.S_IFLNK | 0o777, target.len);
    const file_extent = makeExtent(0x9000, 0x31000, data.len);
    const inline_extent = makeInline(target);
    const dot_entry = makeDirItem(256, ".", DirFt.DIR);
    const file_entry = makeDirItem(257, "hello.txt", DirFt.REG_FILE);
    const link_entry = makeDirItem(258, "link", DirFt.SYMLINK);

    // Корневое дерево двух уровней: node → leaf, чтобы покрыть обход ptrs[].
    buildNode(root_node, 0x1000, 1, &.{
        .{ .key = .{ .objectid = Obj.FS, .type = KeyType.ROOT_ITEM, .offset = 0 }, .blockptr = 0x4000 },
    });
    buildLeaf(root_leaf, 0x4000, 0, &.{
        .{ .key = .{ .objectid = Obj.FS, .type = KeyType.ROOT_ITEM, .offset = 0 }, .data = &root_item },
    });
    buildLeaf(chunk_node, 0x2000, 0, &.{
        .{ .key = .{ .objectid = Obj.FIRST_CHUNK, .type = KeyType.CHUNK_ITEM, .offset = 0 }, .data = &chunk_a },
        .{ .key = .{ .objectid = Obj.FIRST_CHUNK, .type = KeyType.CHUNK_ITEM, .offset = 0x8000 }, .data = &chunk_b },
    });
    buildLeaf(fs_node, 0x3000, 0, &.{
        .{ .key = .{ .objectid = 256, .type = KeyType.INODE_ITEM, .offset = 0 }, .data = &dir_inode },
        .{ .key = .{ .objectid = 256, .type = KeyType.DIR_INDEX, .offset = 2 }, .data = dot_entry },
        .{ .key = .{ .objectid = 256, .type = KeyType.DIR_INDEX, .offset = 3 }, .data = file_entry },
        .{ .key = .{ .objectid = 256, .type = KeyType.DIR_INDEX, .offset = 4 }, .data = link_entry },
        .{ .key = .{ .objectid = 257, .type = KeyType.INODE_ITEM, .offset = 0 }, .data = &file_inode },
        .{ .key = .{ .objectid = 257, .type = KeyType.EXTENT_DATA, .offset = 0 }, .data = &file_extent },
        .{ .key = .{ .objectid = 258, .type = KeyType.INODE_ITEM, .offset = 0 }, .data = &link_inode },
        .{ .key = .{ .objectid = 258, .type = KeyType.EXTENT_DATA, .offset = 0 }, .data = inline_extent },
    });

    @memcpy(image[0x21000..][0..4096], root_node);
    @memcpy(image[0x24000..][0..4096], root_leaf);
    @memcpy(image[0x22000..][0..4096], chunk_node);
    @memcpy(image[0x23000..][0..4096], fs_node);
    @memcpy(image[0x31000..][0..data.len], data);

    put64(image, sb + 64, BTRFS_MAGIC);
    put64(image, sb + 72, 1); // generation
    put64(image, sb + 80, 0x1000); // root (logical)
    put64(image, sb + 88, 0x2000); // chunk_root (logical)
    put64(image, sb + 112, image.len); // total_bytes
    put64(image, sb + 120, 5 * 4096); // bytes_used
    put64(image, sb + 128, 256); // root_dir_objectid
    put64(image, sb + 136, 1); // num_devices
    put32(image, sb + 144, 4096); // sectorsize
    put32(image, sb + 148, 4096); // nodesize
    put32(image, sb + 156, 4096); // stripesize

    put64(image, sb + 188, 1); // incompat_flags: DEFAULT_SUBVOL
    put16(image, sb + 196, 1); // csum_type CRC32C (проверка опущена)
    image[sb + 198] = 1; // root_level
    image[sb + 199] = 0; // chunk_root_level
    put64(image, sb + 201 + 8, image.len); // dev_item.total_bytes
    put64(image, sb + 201 + 16, 5 * 4096); // dev_item.bytes_used

    var cursor = sb + 811;
    var sys_size: u32 = 0;
    for ([_][]const u8{ &chunk_a, &chunk_b }, 0..) |c, i| {
        const logical: u64 = if (i == 0) 0 else 0x8000;
        Key.write(image[cursor..][0..17], .{ .objectid = Obj.FIRST_CHUNK, .type = KeyType.CHUNK_ITEM, .offset = logical });
        cursor += 17;
        const stripes: usize = rd16(c, 44) catch unreachable;
        const used = CHUNK_HDR_SIZE + stripes * STRIPE_SIZE;
        @memcpy(image[cursor..][0..used], c[0..used]);
        cursor += used;
        sys_size += @intCast(17 + used);
    }
    put32(image, sb + 160, sys_size); // sys_chunk_array_size
    return image;
}

test "btrfs reader: chunk mapping, ctree namei, inline symlink, statfs via mount" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage();
    defer std.heap.page_allocator.free(image);

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 64);
    defer root_sb.deinit();
    var btrfs_sb: vfs.SuperBlock = undefined;
    try btrfs_sb.init(a, 64);
    defer btrfs_sb.deinit();

    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var fs = try Btrfs.init(a, image, &btrfs_sb);
    defer fs.deinit();

    // super_operations: statfs() читает поля настоящего btrfs superblock.
    const st = btrfs_sb.statfs();
    try std.testing.expectEqual(BTRFS_SUPER_MAGIC, st.magic);
    try std.testing.expectEqual(@as(u64, 4096), st.bsize);
    try std.testing.expectEqual(@as(u64, 64), st.blocks);
    try std.testing.expectEqual(@as(u64, 3), st.files);
    btrfs_sb.syncFs(); // read-only: no-op

    // Чанки прочитаны из sys_chunk_array и chunk tree; логика != физический адрес.
    try std.testing.expect(fs.chunks.items.len >= 2);
    try std.testing.expectEqual(@as(u64, 0x31000), fs.mapLogical(0x9000).?);

    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&btrfs_sb, fs.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    try std.testing.expectEqual(&btrfs_sb, d.d_sb);
    try std.testing.expectEqual(@as(u64, 257), d.d_inode.?.i_ino);
    const f = fs.fileFor(d) orelse try fs.open(d);
    var buf: [32]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 12), f.read(&buf));
    try std.testing.expectEqualStrings("hello btrfs\n", buf[0..12]);
    try std.testing.expectEqual(@as(i64, 0), f.llseek(0, file.SEEK_SET));
    try std.testing.expectEqual(@as(i64, 5), f.read(buf[0..5]));
    try std.testing.expectEqualStrings("hello", buf[0..5]);

    // Символьная ссылка: inline extent → i_link → разыменование namei.
    const followed = try ns.lookupPath("/mnt/link");
    defer followed.d_sb.dPut(followed);
    try std.testing.expectEqual(@as(u64, 257), followed.d_inode.?.i_ino);
    const link = try ns.lookupPathNoFollow("/mnt/link");
    defer link.d_sb.dPut(link);
    try std.testing.expect(link.d_inode.?.isLink());
    try std.testing.expectEqualStrings("hello.txt", link.d_inode.?.i_link.?);

    try std.testing.expectError(error.NoEnt, ns.lookupPath("/mnt/missing"));
    try std.testing.expectError(error.NotDir, ns.lookupPath("/mnt/hello.txt/child"));
}
