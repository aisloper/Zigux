//! Минимальный reader/writer ext4 для порта Linux 7.3 на Zig:
//! superblock, block group descriptors, inode table, extent tree, directory
//! entries, fast symlinks. Файлы показываются в VFS через LookupOps +
//! file_operations; запись перезаписывает отображённые extent-ы и может
//! выделить новые блоки в единственной группе, сбрасывая грязные блоки через
//! writeback. Создание/удаление имён в корневом каталоге, mkdir и rmdir меняют
//! inode bitmap, счётчики и dir_entry_2 на месте. Грязные блоки сбрасываются
//! транзакциями JBD2 через внутренний journal inode, при `INCOMPAT_RECOVER`
//! записанный журнал восстанавливается при следующем монтировании. При
//! переполнении корневого листа дерево разрастается до depth 1 через новый
//! metadata-блок; следующие block-ы добавляются в этот лист. Запись за EOF
//! оставляет пропущенные block-ы дырами: extent-ы вставляются по ключу, а
//! чтение дыр возвращает нули без выделения блоков.
//! Источники: fs/ext4/super.c, fs/ext4/inode.c, fs/ext4/extents.c,
//! fs/ext4/namei.c, include/uapi/linux/ext4_fs.h.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const vfs = @import("vfs.zig");
const file = @import("file.zig");

pub const EXT4_MAGIC: u16 = 0xEF53;
pub const EXT4_FEATURE_COMPAT_HAS_JOURNAL: u32 = 0x0004;
pub const EXT4_FEATURE_INCOMPAT_RECOVER: u32 = 0x0004;
pub const JBD2_MAGIC_NUMBER: u32 = 0xC03B_3998;
pub const JBD2_DESCRIPTOR_BLOCK: u32 = 1;
pub const JBD2_COMMIT_BLOCK: u32 = 2;
pub const JBD2_REVOKE_BLOCK: u32 = 5;
pub const JBD2_SUPERBLOCK_V2: u32 = 4;
pub const JBD2_FLAG_ESCAPE: u16 = 1;
pub const JBD2_FLAG_SAME_UUID: u16 = 2;
pub const JBD2_FLAG_LAST_TAG: u16 = 8;
pub const JBD2_CRC32C_CHKSUM: u8 = 4;
pub const JBD2_SUPERBLOCK_CSUM_OFF: usize = 0xfc;
pub const JBD2_FEATURE_COMPAT_CHECKSUM: u32 = 0x0000_0001;
pub const JBD2_FEATURE_INCOMPAT_REVOKE: u32 = 0x0000_0001;
pub const JBD2_FEATURE_INCOMPAT_64BIT: u32 = 0x0000_0002;
pub const JBD2_FEATURE_INCOMPAT_CSUM_V2: u32 = 0x0000_0008;
pub const JBD2_FEATURE_INCOMPAT_CSUM_V3: u32 = 0x0000_0010;
const JBD2_KNOWN_INCOMPAT_FEATURES: u32 = JBD2_FEATURE_INCOMPAT_REVOKE |
    JBD2_FEATURE_INCOMPAT_64BIT |
    JBD2_FEATURE_INCOMPAT_CSUM_V2 |
    JBD2_FEATURE_INCOMPAT_CSUM_V3;
pub const EXT4_EXTENT_MAGIC: u16 = 0xF30A;
pub const EXT4_FEATURE_INCOMPAT_FILETYPE: u32 = 0x0002;
pub const EXT4_FEATURE_INCOMPAT_EXTENTS: u32 = 0x0040;
pub const EXT4_FEATURE_INCOMPAT_64BIT: u32 = 0x0080;
pub const EXT4_FEATURE_RO_COMPAT_GDT_CSUM: u32 = 0x0010;
pub const EXT4_FEATURE_RO_COMPAT_METADATA_CSUM: u32 = 0x0400;
pub const EXT4_EXTENTS_FL: u32 = 0x0008_0000;
pub const EXT4_ROOT_INO: u32 = 2;

pub const Ext4Error = error{
    Invalid,
    Corrupt,
    NoEnt,
    NotDir,
    IsDir,
    PathExists,
    ReadOnly,
    NoSpace,
    NotSupported,
};

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

fn rd16be(buf: []const u8, off: usize) !u16 {
    if (off + 2 > buf.len) return error.Corrupt;
    var tmp: [2]u8 = undefined;
    @memcpy(&tmp, buf[off..][0..2]);
    return std.mem.readInt(u16, &tmp, .big);
}

fn rd32be(buf: []const u8, off: usize) !u32 {
    if (off + 4 > buf.len) return error.Corrupt;
    var tmp: [4]u8 = undefined;
    @memcpy(&tmp, buf[off..][0..4]);
    return std.mem.readInt(u32, &tmp, .big);
}

fn rd64(buf: []const u8, off: usize) !u64 {
    if (off + 8 > buf.len) return error.Corrupt;
    var tmp: [8]u8 = undefined;
    @memcpy(&tmp, buf[off..][0..8]);
    return std.mem.readInt(u64, &tmp, .little);
}

fn rd64be(buf: []const u8, off: usize) !u64 {
    if (off + 8 > buf.len) return error.Corrupt;
    var tmp: [8]u8 = undefined;
    @memcpy(&tmp, buf[off..][0..8]);
    return std.mem.readInt(u64, &tmp, .big);
}

fn put16be(buf: []u8, off: usize, value: u16) void {
    var tmp: [2]u8 = undefined;
    std.mem.writeInt(u16, &tmp, value, .big);
    @memcpy(buf[off..][0..2], &tmp);
}

fn put32be(buf: []u8, off: usize, value: u32) void {
    var tmp: [4]u8 = undefined;
    std.mem.writeInt(u32, &tmp, value, .big);
    @memcpy(buf[off..][0..4], &tmp);
}

fn put64be(buf: []u8, off: usize, value: u64) void {
    var tmp: [8]u8 = undefined;
    std.mem.writeInt(u64, &tmp, value, .big);
    @memcpy(buf[off..][0..8], &tmp);
}

/// include/linux/crc32poly.h: CRC32C (Castagnoli) в отражённом порядке.
/// fs/jbd2/journal.c:jbd2_chksum() не инвертирует результат в конце.
fn crc32cByte(crc_in: u32, byte: u8) u32 {
    var crc = crc_in ^ byte;
    for (0..8) |_| {
        const mask: u32 = if ((crc & 1) != 0) 0x82f6_3b78 else 0;
        crc = (crc >> 1) ^ mask;
    }
    return crc;
}

fn crc32c(crc_in: u32, bytes: []const u8) u32 {
    var crc = crc_in;
    for (bytes) |byte| crc = crc32cByte(crc, byte);
    return crc;
}

/// crc32c() с нулевым диапазоном — так ядро считает checksum metadata,
/// не модифицируя сам блок (descriptor tail, commit h_chksum[0], revoke tail).
fn crc32cZeroRange(crc_in: u32, bytes: []const u8, zero_off: usize, zero_len: usize) u32 {
    var crc = crc_in;
    for (bytes, 0..) |byte, i| {
        crc = crc32cByte(crc, if (i >= zero_off and i < zero_off + zero_len) 0 else byte);
    }
    return crc;
}

/// fs/jbd2/journal.c:jbd2_superblock_csum() — crc32c(~0, 1024-байтовый jsb).
fn journalSuperCsum(block: []const u8) u32 {
    var tmp: [1024]u8 = undefined;
    @memcpy(&tmp, block[0..1024]);
    put32be(&tmp, JBD2_SUPERBLOCK_CSUM_OFF, 0);
    return crc32c(std.math.maxInt(u32), &tmp);
}

fn typeOf(mode: u32) u32 {
    return mode & 0o170000;
}

const GroupDesc = struct {
    block_bitmap: u64,
    inode_bitmap: u64,
    inode_table: u64,
    free_blocks: u32,
    free_inodes: u32,
    used_dirs: u32,
};

/// include/linux/ext4_fs.h: struct ext4_inode (только нужные поля).
const Inode = struct {
    ino: u32,
    mode: u32,
    size: u64,
    links: u16,
    blocks: u32,
    flags: u32,
    /// i_block[]: extent tree или тело быстрой символьной ссылки.
    block: [60]u8 = @splat(0),

    fn isDir(self: *const Inode) bool {
        return typeOf(self.mode) == vfs.S_IFDIR;
    }

    fn isLink(self: *const Inode) bool {
        return typeOf(self.mode) == vfs.S_IFLNK;
    }

    fn isReg(self: *const Inode) bool {
        return typeOf(self.mode) == vfs.S_IFREG;
    }
};

/// include/linux/jbd2.h: journal_superblock_t и состояние транзакции.
const Journal = struct {
    ino: u32,
    inode: *Inode,
    first: u32,
    maxlen: u32,
    sequence: u32,
    start: u32,
    features_compat: u32 = 0,
    features_incompat: u32 = 0,
    features_ro_compat: u32 = 0,
    checksum_type: u8 = 0,
    revoke_writes: usize = 0,
    uuid: [16]u8 = @splat(0),
    csum_seed: u32 = 0,
    /// fs/jbd2/revoke.c: четырех-/восьмибайтовые записи текущей транзакции.
    revoke: std.AutoHashMap(u64, u64),
    commits: usize = 0,
    replayed_blocks: usize = 0,
};

const Extent = struct {
    physical: u64,
    len: u32,
};

/// fs/super.c: super_operations данных ext4. Живёт отдельно от Ext4, чтобы
/// Минимальный контракт writeback: смещение в образе ФС и полный ext4-блок.
/// block.Device подключается имплементацией на стороне arch-драйвера.
pub const Writeback = struct {
    ctx: ?*anyopaque = null,
    write: *const fn (ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void,
};

/// ctx в SuperBlock не указывал на копию структуры, возвращённой из init().
const Meta = struct {
    blocks_count: u64 = 0,
    free_blocks: u64 = 0,
    inodes_count: u64 = 0,
    free_inodes: u64 = 0,
    bsize: u64 = 0,
    fs: ?*Ext4 = null,
    sync_calls: usize = 0,
    synced_blocks: usize = 0,
    sync_failed: bool = false,
};

/// Образ ФС лежит в памяти; грязные блоки сбрасываются через writeback.
pub const Ext4 = struct {
    allocator: std.mem.Allocator,
    image: []u8,
    sb: *vfs.SuperBlock,
    writeback: ?Writeback = null,
    dirty: std.AutoHashMap(u64, void),
    /// fs/jbd2/revoke.c: порядок последнего обращения к блокуภาย транзакции.
    touch: std.AutoHashMap(u64, u64),
    op_clock: u64 = 0,
    block_size: usize,
    first_data_block: u32,
    blocks_per_group: u32,
    inodes_per_group: u32,
    first_ino: u32,
    inodes_count: u32,
    inode_size: usize,
    desc_size: usize,
    feature_compat: u32,
    feature_incompat: u32,
    feature_ro_compat: u32,
    journal_ino: u32,
    journal: ?Journal = null,
    groups: []GroupDesc,
    meta: *Meta,
    inode_cache: std.AutoHashMap(u32, *Inode),
    /// VFS.iget() копирует i_link сразу, но буфер должен жить до конца обхода.
    links: std.ArrayList([]u8) = .empty,
    files: std.ArrayList(*file.File) = .empty,

    /// Инициализация на месте: Meta.fs должен указывать на стабильный Ext4,
    /// поэтому вызывающий создаёт структуру сам (heap или стек).
    pub fn init(
        self: *Ext4,
        allocator: std.mem.Allocator,
        image: []u8,
        sb: *vfs.SuperBlock,
        writeback: ?Writeback,
    ) !void {
        const meta = try allocator.create(Meta);
        meta.* = .{};

        self.* = .{
            .allocator = allocator,
            .image = image,
            .sb = sb,
            .writeback = writeback,
            .dirty = std.AutoHashMap(u64, void).init(allocator),
            .touch = std.AutoHashMap(u64, u64).init(allocator),
            .block_size = 0,
            .first_data_block = 0,
            .blocks_per_group = 0,
            .inodes_per_group = 0,
            .first_ino = 0,
            .inodes_count = 0,
            .inode_size = 0,
            .desc_size = 0,
            .feature_compat = 0,
            .feature_incompat = 0,
            .feature_ro_compat = 0,
            .journal_ino = 0,
            .journal = null,
            .groups = &.{},
            .meta = meta,
            .inode_cache = std.AutoHashMap(u32, *Inode).init(allocator),
        };
        errdefer self.deinit();
        self.meta.fs = self;

        try self.parseSuper();
        try self.initJournal();
        sb.setSuperOps(.{ .ctx = self.meta, .statfs = statfs, .sync_fs = syncFs });
        sb.setDirOps(.{
            .ctx = self,
            .create = create,
            .mkdir = mkdir,
            .unlink = unlink,
            .rmdir = rmdir,
            .instantiate = instantiate,
        });
    }

    pub fn deinit(self: *Ext4) void {
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
        var it = self.inode_cache.iterator();
        while (it.next()) |entry| self.allocator.destroy(entry.value_ptr.*);
        self.inode_cache.deinit();
        self.dirty.deinit();
        self.touch.deinit();
        if (self.journal) |j| {
            var journal = j;
            journal.revoke.deinit();
        }
        if (self.groups.len > 0) self.allocator.free(self.groups);
        self.meta.fs = null;
        self.allocator.destroy(self.meta);
    }

    pub fn ops(self: *Ext4) vfs.LookupOps {
        return .{ .ctx = self, .lookup = lookup };
    }

    /// super_block из VFSmount → ext4 для writeback-проверки на загрузке.
    pub fn fromSuper(sb: *vfs.SuperBlock) ?*Ext4 {
        const meta: ?*Meta = @ptrCast(@alignCast(sb.s_ops.ctx orelse return null));
        return if (meta) |m| m.fs else null;
    }

    pub fn dirtyBlocks(self: *const Ext4) usize {
        return self.dirty.count();
    }

    pub fn syncedBlocks(self: *const Ext4) usize {
        return self.meta.synced_blocks;
    }

    pub fn syncFailed(self: *const Ext4) bool {
        return self.meta.sync_failed;
    }

    /// Глубина extent-дерева иноды: boot-time probe проверяет split на диске.
    pub fn extentDepth(self: *const Ext4, ino: u32) u16 {
        const off = self.inodeOffset(ino) catch return 0;
        return rd16(self.image, off + 40 + 6) catch 0;
    }

    /// Число entries в корневом extent-блоке иноды (boot-time probe дыр).
    pub fn extentEntries(self: *const Ext4, ino: u32) u16 {
        const off = self.inodeOffset(ino) catch return 0;
        return rd16(self.image, off + 40 + 2) catch 0;
    }

    /// fs/ext4/super.c + fs/jbd2/journal.c: внутренний журнал обнаружен и
    /// готов принимать транзакции (или уже восстановлен при монтировании).
    pub fn journalActive(self: *const Ext4) bool {
        return self.journal != null;
    }

    pub fn journalCommits(self: *const Ext4) usize {
        return if (self.journal) |j| j.commits else 0;
    }

    pub fn journalReplays(self: *const Ext4) usize {
        return if (self.journal) |j| j.replayed_blocks else 0;
    }

    pub fn journalStart(self: *const Ext4) u32 {
        return if (self.journal) |j| j.start else 0;
    }

    /// fs/jbd2/journal.c: поддерживаемые на диске возможности журнала.
    pub fn journalIncompatFeatures(self: *const Ext4) u32 {
        return if (self.journal) |j| j.features_incompat else 0;
    }

    pub fn journalChecksumType(self: *const Ext4) u8 {
        return if (self.journal) |j| j.checksum_type else 0;
    }

    pub fn journalRevokes(self: *const Ext4) usize {
        return if (self.journal) |j| j.revoke.count() else 0;
    }

    /// Число записанных revoke-блоков за все коммиты (boot-проба проверяет,
    /// что revoke действительно попал в журнал, а не только в RAM).
    pub fn journalRevokeWrites(self: *const Ext4) usize {
        return if (self.journal) |j| j.revoke_writes else 0;
    }

    /// fs/jbd2/journal.c:jbd2_journal_set_features(). Boot-проба включает
    /// revoke/64-bit/csum-v3 на scratch-копии настоящего journal inode.
    pub fn journalEnableFeatures(self: *Ext4, features: u32) !void {
        var j = self.journal orelse return error.NotSupported;
        if (features & ~JBD2_KNOWN_INCOMPAT_FEATURES != 0) return error.Invalid;
        const combined = j.features_incompat | features;
        if (combined & JBD2_FEATURE_INCOMPAT_CSUM_V2 != 0 and
            combined & JBD2_FEATURE_INCOMPAT_CSUM_V3 != 0) return error.Invalid;
        if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_RECOVER != 0 and j.start != 0)
            return error.NotSupported;
        j.features_incompat = combined;
        if (combined & (JBD2_FEATURE_INCOMPAT_CSUM_V2 | JBD2_FEATURE_INCOMPAT_CSUM_V3) != 0) {
            j.checksum_type = JBD2_CRC32C_CHKSUM;
            j.csum_seed = crc32c(std.math.maxInt(u32), &j.uuid);
        }
        self.journal = j;
        _ = try self.writeJournalSuper(j.start, j.sequence);
    }

    /// fs/jbd2/revoke.c:jbd2_journal_revoke(). Отложенная запись следует за
    /// JournalWriteBlock(): revoke после dirty побеждает, dirty после revoke
    /// отменяет запись revocation record.
    pub fn revokeBlock(self: *Ext4, block_no: u64) !void {
        var j = self.journal orelse return error.NotSupported;
        if (j.features_incompat & JBD2_FEATURE_INCOMPAT_REVOKE == 0) return error.NotSupported;
        self.op_clock += 1;
        try j.revoke.put(block_no, self.op_clock);
        try self.touch.put(block_no, self.op_clock);
        self.journal = j;
    }

    fn parseSuper(self: *Ext4) !void {
        // ext4 superblock lives at byte 1024; group table follows first_data_block.
        const off: usize = 1024;
        if (try rd16(self.image, off + 56) != EXT4_MAGIC) return error.Invalid;
        const log_block_size = try rd32(self.image, off + 24);
        if (log_block_size > 16) return error.Invalid;
        self.block_size = @as(usize, 1024) << @intCast(log_block_size);
        var blocks_count: u64 = try rd32(self.image, off + 4);
        var free_blocks: u64 = try rd32(self.image, off + 12);
        const inodes_count = try rd32(self.image, off);
        const free_inodes = try rd32(self.image, off + 16);
        self.first_data_block = try rd32(self.image, off + 20);
        self.blocks_per_group = try rd32(self.image, off + 32);
        self.inodes_per_group = try rd32(self.image, off + 40);
        self.first_ino = try rd32(self.image, off + 84);
        self.inodes_count = inodes_count;
        const rev_level = try rd32(self.image, off + 76);
        self.inode_size = try rd16(self.image, off + 88);
        self.feature_compat = try rd32(self.image, off + 92);
        self.feature_incompat = try rd32(self.image, off + 96);
        self.feature_ro_compat = try rd32(self.image, off + 100);
        self.journal_ino = try rd32(self.image, off + 224);
        if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_64BIT != 0) {
            blocks_count |= @as(u64, try rd32(self.image, off + 336)) << 32;
            free_blocks |= @as(u64, try rd32(self.image, off + 344)) << 32;
        }
        if (rev_level >= 1) {
            self.desc_size = try rd16(self.image, off + 254);
            if (self.desc_size == 0) self.desc_size = 32;
        } else {
            self.desc_size = 32;
        }
        if (self.desc_size != 32 and self.desc_size != 64) return error.Invalid;
        if (self.blocks_per_group == 0 or self.inodes_per_group == 0) return error.Invalid;
        if (self.inode_size < 128 or self.inode_size > self.block_size) return error.Invalid;
        if (blocks_count <= self.first_data_block) return error.Invalid;

        const covered = blocks_count - self.first_data_block;
        const groups64 = (covered + self.blocks_per_group - 1) / self.blocks_per_group;
        if (groups64 == 0 or groups64 > 4096) return error.Invalid;
        const groups: usize = @intCast(groups64);

        self.meta.* = .{
            .blocks_count = blocks_count,
            .free_blocks = free_blocks,
            .inodes_count = inodes_count,
            .free_inodes = free_inodes,
            .bsize = self.block_size,
            .fs = self,
        };

        const gd_block: usize = if (self.block_size == 1024) 2 else 1;
        const table_off = gd_block * self.block_size;
        const descs = try self.allocator.alloc(GroupDesc, groups);
        errdefer self.allocator.free(descs);
        for (descs, 0..) |*g, i| {
            const base = table_off + i * self.desc_size;
            const bb = try rd32(self.image, base);
            const ib = try rd32(self.image, base + 4);
            var itable: u64 = try rd32(self.image, base + 8);
            if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_64BIT != 0 and self.desc_size == 64) {
                const hi = try rd32(self.image, base + 40);
                itable |= @as(u64, hi) << 32;
            }
            g.* = .{
                .block_bitmap = bb,
                .inode_bitmap = ib,
                .inode_table = itable,
                .free_blocks = try rd16(self.image, base + 12),
                .free_inodes = try rd16(self.image, base + 14),
                .used_dirs = try rd16(self.image, base + 16),
            };
        }
        self.groups = descs;
    }

    fn statfs(ctx: ?*anyopaque, _: *vfs.SuperBlock) vfs.SuperStats {
        const m: *const Meta = @ptrCast(@alignCast(ctx orelse return .{}));
        return .{
            .magic = EXT4_MAGIC,
            .bsize = m.bsize,
            .blocks = m.blocks_count,
            .bfree = m.free_blocks,
            .bavail = m.free_blocks,
            .files = m.inodes_count,
            .ffree = m.free_inodes,
        };
    }

    /// fs/jbd2/journal.c: записать один физический блок напрямую через
    /// writeback, минуя отложенный dirty-набор (журнал и superblock).
    fn writeBlockDirect(self: *Ext4, block_no: u64, bytes: []const u8) !usize {
        const wb = self.writeback orelse return error.ReadOnly;
        const offset = block_no * self.block_size;
        if (offset + bytes.len > self.image.len) return error.Corrupt;
        const start: usize = @intCast(offset);
        @memcpy(self.image[start..][0..bytes.len], bytes);
        try wb.write(wb.ctx, offset, bytes);
        return 1;
    }

    fn superBlockNumber(self: *const Ext4) u64 {
        return 1024 / self.block_size;
    }

    fn superBlockBytes(self: *const Ext4) []const u8 {
        return self.image[1024..][0..self.block_size];
    }

    /// fs/jbd2/journal.c: логический блок журнала → физический блок ФС через
    /// extent tree journal inode. s_maxlen — граница (не последний блок).
    fn journalPhysical(self: *Ext4, logical: u32) !u64 {
        const j = self.journal orelse return error.NotSupported;
        if (logical >= j.maxlen) return error.Corrupt;
        return (try self.mapBlock(j.inode, logical)) orelse return error.Corrupt;
    }

    fn readJournalBlock(self: *Ext4, logical: u32, buf: []u8) !void {
        if (buf.len != self.block_size) return error.Invalid;
        const physical = try self.journalPhysical(logical);
        const start: usize = @intCast(physical * self.block_size);
        if (start + self.block_size > self.image.len) return error.Corrupt;
        @memcpy(buf, self.image[start..][0..self.block_size]);
    }

    fn writeJournalBlock(self: *Ext4, logical: u32, bytes: []const u8) !usize {
        const physical = try self.journalPhysical(logical);
        return self.writeBlockDirect(physical, bytes);
    }

    /// fs/jbd2/journal.c: journal_superblock_t (все поля big-endian).
    fn writeJournalSuper(self: *Ext4, start: u32, sequence: u32) !usize {
        var j = self.journal orelse return error.NotSupported;
        const buf = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(buf);
        try self.readJournalBlock(0, buf);
        put32be(buf, 0, JBD2_MAGIC_NUMBER);
        put32be(buf, 4, JBD2_SUPERBLOCK_V2);
        put32be(buf, 8, sequence);
        put32be(buf, 12, @intCast(self.block_size));
        put32be(buf, 16, j.maxlen);
        put32be(buf, 20, j.first);
        put32be(buf, 24, sequence);
        put32be(buf, 28, start);
        put32be(buf, 32, 0); // s_errno
        put32be(buf, 0x24, j.features_compat);
        put32be(buf, 0x28, j.features_incompat);
        put32be(buf, 0x2c, j.features_ro_compat);
        @memcpy(buf[0x30..][0..16], &j.uuid);
        put32be(buf, 0x40, 1); // s_nr_users
        buf[0x50] = j.checksum_type;
        put32be(buf, JBD2_SUPERBLOCK_CSUM_OFF, 0);
        if (j.checksum_type == JBD2_CRC32C_CHKSUM)
            put32be(buf, JBD2_SUPERBLOCK_CSUM_OFF, journalSuperCsum(buf));
        const written = try self.writeJournalBlock(0, buf);
        j.start = start;
        j.sequence = sequence;
        self.journal = j;
        return written;
    }

    /// fs/ext4/super.c: найти s_journal_inum, прочитать JBD2 superblock и
    /// восстановить незавершённую транзакцию до появления VFS-mount.
    fn initJournal(self: *Ext4) !void {
        if (self.writeback == null) return;
        if (self.feature_compat & EXT4_FEATURE_COMPAT_HAS_JOURNAL == 0) return;
        if (self.journal_ino == 0 or self.journal_ino > self.inodes_count) return;
        const inode = self.loadInode(self.journal_ino) catch return;
        if (!inode.isReg() or inode.size < self.block_size) return;
        const sb_phys = (self.mapBlock(inode, 0) catch return) orelse return;
        const off: usize = @intCast(sb_phys * self.block_size);
        if (off + self.block_size > self.image.len) return;
        const buf = self.image[off..][0..self.block_size];
        if ((try rd32be(buf, 0)) != JBD2_MAGIC_NUMBER) return;
        if ((try rd32be(buf, 4)) != JBD2_SUPERBLOCK_V2) return;
        const bsize = try rd32be(buf, 12);
        if (bsize != self.block_size) return;
        const maxlen = try rd32be(buf, 16);
        const first = try rd32be(buf, 20);
        if (first == 0 or first >= maxlen or maxlen > inode.size / self.block_size) return;
        const jf_compat = try rd32be(buf, 0x24);
        const jf_incompat = try rd32be(buf, 0x28);
        const jf_ro_compat = try rd32be(buf, 0x2c);
        const checksum_type = buf[0x50];
        const has_csum = jf_incompat &
            (JBD2_FEATURE_INCOMPAT_CSUM_V2 | JBD2_FEATURE_INCOMPAT_CSUM_V3) != 0;
        const bad_features = jf_compat != 0 or jf_ro_compat != 0 or
            jf_incompat & ~JBD2_KNOWN_INCOMPAT_FEATURES != 0 or
            (jf_incompat & JBD2_FEATURE_INCOMPAT_CSUM_V2 != 0 and
                jf_incompat & JBD2_FEATURE_INCOMPAT_CSUM_V3 != 0) or
            (has_csum and checksum_type != JBD2_CRC32C_CHKSUM) or
            (has_csum and (rd32be(buf, JBD2_SUPERBLOCK_CSUM_OFF) catch 0) != journalSuperCsum(buf));
        if (bad_features) {
            if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_RECOVER != 0) return error.NotSupported;
            return;
        }
        var uuid: [16]u8 = @splat(0);
        @memcpy(&uuid, buf[0x30..][0..16]);
        const journal = Journal{
            .ino = self.journal_ino,
            .inode = inode,
            .first = first,
            .maxlen = maxlen,
            .sequence = try rd32be(buf, 24),
            .start = try rd32be(buf, 28),
            .features_compat = jf_compat,
            .features_incompat = jf_incompat,
            .features_ro_compat = jf_ro_compat,
            .checksum_type = checksum_type,
            .uuid = uuid,
            .csum_seed = if (has_csum) crc32c(std.math.maxInt(u32), &uuid) else 0,
            .revoke = std.AutoHashMap(u64, u64).init(self.allocator),
        };
        self.journal = journal;
        if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_RECOVER != 0 and journal.start != 0) {
            try self.recoverJournal();
        }
    }

    /// fs/jbd2/journal.c:journal_tag_bytes() — v3 всегда 16 байт, v2 добавляет
    /// 16-битную контрольную сумму, 64BIT добавляет старшие 32 бита номера.
    fn journalTagBytes(j: Journal) usize {
        if (j.features_incompat & JBD2_FEATURE_INCOMPAT_CSUM_V3 != 0) return 16;
        var size: usize = 8;
        if (j.features_incompat & JBD2_FEATURE_INCOMPAT_CSUM_V2 != 0) size += 2;
        if (j.features_incompat & JBD2_FEATURE_INCOMPAT_64BIT != 0) size += 4;
        return size;
    }

    fn journalHasCsum(j: Journal) bool {
        return j.features_incompat &
            (JBD2_FEATURE_INCOMPAT_CSUM_V2 | JBD2_FEATURE_INCOMPAT_CSUM_V3) != 0;
    }

    fn journalRevokeRecordLen(j: Journal) usize {
        return if (j.features_incompat & JBD2_FEATURE_INCOMPAT_64BIT != 0) 8 else 4;
    }

    /// fs/jbd2/recovery.c:wrap() — кольцевой журнал от s_first до s_maxlen.
    fn journalWrap(j: Journal, block: *u32) void {
        if (block.* >= j.maxlen) block.* -= j.maxlen - j.first;
    }

    fn journalNext(j: Journal, block: u32) u32 {
        var next = block + 1;
        journalWrap(j, &next);
        return next;
    }

    /// include/linux/jbd2.h:tid_geq() — сравнение с учётом wrap-around tid_t.
    fn tidGeq(a: u32, b: u32) bool {
        const diff: i32 = @bitCast(a -% b);
        return diff >= 0;
    }

    /// fs/jbd2/commit.c:jbd2_block_tag_csum_set(): crc32c(uuid-seed || tid || block).
    fn journalTagCsum(seed: u32, tid: u32, block_bytes: []const u8) u32 {
        var tid_bytes: [4]u8 = undefined;
        put32be(&tid_bytes, 0, tid);
        return crc32c(crc32c(seed, &tid_bytes), block_bytes);
    }

    fn writeJournalTag(
        j: Journal,
        buf: []u8,
        cursor: usize,
        block_no: u64,
        flags: u16,
        tid: u32,
        block_bytes: []const u8,
    ) !void {
        const tag_len = journalTagBytes(j);
        if (cursor + tag_len > buf.len) return error.NotSupported;
        @memset(buf[cursor..][0..tag_len], 0);
        put32be(buf, cursor, @truncate(block_no));
        // journal_block_tag3_t::t_flags — 32 бита, но ядро пишет младшие 16
        // через journal_block_tag_t::t_flags по тому же смещению 6.
        put16be(buf, cursor + 6, flags);
        if (j.features_incompat & JBD2_FEATURE_INCOMPAT_64BIT != 0)
            put32be(buf, cursor + 8, @truncate(block_no >> 32));
        if (journalHasCsum(j)) {
            const csum = journalTagCsum(j.csum_seed, tid, block_bytes);
            if (j.features_incompat & JBD2_FEATURE_INCOMPAT_CSUM_V3 != 0)
                put32be(buf, cursor + 12, csum)
            else
                put16be(buf, cursor + 4, @truncate(csum));
        }
    }

    const JournalTag = struct {
        target: u64,
        flags: u16,
        cursor: usize,
        data_log: u32,
    };

    fn readJournalTag(j: Journal, desc: []const u8, limit: usize, cursor: usize, data_log: u32) !JournalTag {
        const tag_len = journalTagBytes(j);
        if (cursor + tag_len > limit) return error.Corrupt;
        var target: u64 = try rd32be(desc, cursor);
        if (j.features_incompat & JBD2_FEATURE_INCOMPAT_64BIT != 0)
            target |= @as(u64, try rd32be(desc, cursor + 8)) << 32;
        return .{
            .target = target,
            .flags = try rd16be(desc, cursor + 6),
            .cursor = cursor,
            .data_log = data_log,
        };
    }

    fn verifyJournalTag(j: Journal, desc: []const u8, tag: JournalTag, tid: u32, block_bytes: []const u8) bool {
        if (!journalHasCsum(j)) return true;
        const csum = journalTagCsum(j.csum_seed, tid, block_bytes);
        if (j.features_incompat & JBD2_FEATURE_INCOMPAT_CSUM_V3 != 0)
            return (rd32be(desc, tag.cursor + 12) catch return false) == csum;
        return (rd16be(desc, tag.cursor + 4) catch return false) == @as(u16, @truncate(csum));
    }

    fn writeBlockTail(seed: u32, buf: []u8) void {
        const off = buf.len - 4;
        put32be(buf, off, 0);
        put32be(buf, off, crc32c(seed, buf));
    }

    fn verifyBlockTail(seed: u32, buf: []const u8) bool {
        const off = buf.len - 4;
        return (rd32be(buf, off) catch return false) == crc32cZeroRange(seed, buf, off, 4);
    }

    fn writeCommitChecksum(seed: u32, buf: []u8) void {
        put32be(buf, 16, 0);
        put32be(buf, 16, crc32c(seed, buf));
    }

    fn verifyCommitChecksum(seed: u32, buf: []const u8) bool {
        return (rd32be(buf, 16) catch return false) == crc32cZeroRange(seed, buf, 16, 4);
    }

    fn writeRevokeBlock(self: *Ext4, j: Journal, buf: []u8, revokes: []const u64, tid: u32) !usize {
        _ = self;
        @memset(buf, 0);
        put32be(buf, 0, JBD2_MAGIC_NUMBER);
        put32be(buf, 4, JBD2_REVOKE_BLOCK);
        put32be(buf, 8, tid);
        const record_len = journalRevokeRecordLen(j);
        const used = 16 + revokes.len * record_len;
        if (used > buf.len - 4) return error.NotSupported;
        put32be(buf, 12, @intCast(used));
        for (revokes, 0..) |block_no, i| {
            if (record_len == 4)
                put32be(buf, 16 + i * 4, @truncate(block_no))
            else
                put64be(buf, 16 + i * 8, block_no);
        }
        if (journalHasCsum(j)) writeBlockTail(j.csum_seed, buf);
        return 0;
    }

    fn scanRevokeBlock(self: *Ext4, j: Journal, buf: []const u8, tid: u32, revokes: *std.AutoHashMap(u64, u32)) !void {
        _ = self;
        if ((try rd32be(buf, 0)) != JBD2_MAGIC_NUMBER or
            (try rd32be(buf, 4)) != JBD2_REVOKE_BLOCK or
            (try rd32be(buf, 8)) != tid) return error.Corrupt;
        if (journalHasCsum(j) and !verifyBlockTail(j.csum_seed, buf)) return error.Corrupt;
        const rcount = try rd32be(buf, 12);
        const csum_size: usize = if (journalHasCsum(j)) 4 else 0;
        if (rcount < 16 or rcount > buf.len - csum_size) return error.Corrupt;
        const record_len = journalRevokeRecordLen(j);
        var cursor: usize = 16;
        while (cursor + record_len <= rcount) : (cursor += record_len) {
            const block_no = if (record_len == 4)
                @as(u64, try rd32be(buf, cursor))
            else
                try rd64be(buf, cursor);
            try revokes.put(block_no, tid);
        }
    }

    /// fs/jbd2/recovery.c:do_one_pass() — сканировать закоммиченную
    /// транзакцию, собрать revoke-записи и повторить не отозванные блоки.
    fn recoverJournal(self: *Ext4) !void {
        var j = self.journal orelse return error.NotSupported;
        if (j.start == 0) return;
        const tid = j.sequence;
        const capacity = j.maxlen - j.first;
        if (j.start < j.first or j.start >= j.maxlen or capacity < 2) return error.Corrupt;

        const desc = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(desc);
        const scan = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(scan);
        const data = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(data);
        var tags = std.ArrayList(JournalTag).empty;
        defer tags.deinit(self.allocator);
        var revokes = std.AutoHashMap(u64, u32).init(self.allocator);
        defer revokes.deinit();

        var log_block = j.start;
        var descriptors: usize = 0;
        var found_commit = false;
        var guard: usize = 0;
        while (guard < capacity) : (guard += 1) {
            try self.readJournalBlock(log_block, scan);
            if ((try rd32be(scan, 0)) != JBD2_MAGIC_NUMBER) return error.Corrupt;
            const block_type = try rd32be(scan, 4);
            if ((try rd32be(scan, 8)) != tid) return error.Corrupt;
            if (block_type == JBD2_DESCRIPTOR_BLOCK) {
                if (descriptors != 0) return error.NotSupported;
                descriptors += 1;
                try self.readJournalBlock(log_block, desc);
                if (journalHasCsum(j) and !verifyBlockTail(j.csum_seed, desc)) return error.Corrupt;
                const limit = self.block_size - (if (journalHasCsum(j)) @as(usize, 4) else 0);
                var cursor: usize = 12;
                var last = false;
                var next_data_log = journalNext(j, log_block);
                while (cursor + journalTagBytes(j) <= limit) {
                    const tag = try readJournalTag(j, desc, limit, cursor, next_data_log);
                    next_data_log = journalNext(j, next_data_log);
                    try tags.append(self.allocator, tag);
                    cursor += journalTagBytes(j);
                    if (tag.flags & JBD2_FLAG_SAME_UUID == 0) {
                        if (cursor + 16 > limit) return error.Corrupt;
                        cursor += 16;
                    }
                    if (tag.flags & JBD2_FLAG_LAST_TAG != 0) {
                        last = true;
                        break;
                    }
                }
                if (!last and tags.items.len != 0) return error.Corrupt;
                log_block = next_data_log;
            } else if (block_type == JBD2_REVOKE_BLOCK) {
                try self.scanRevokeBlock(j, scan, tid, &revokes);
                log_block = journalNext(j, log_block);
            } else if (block_type == JBD2_COMMIT_BLOCK) {
                if (journalHasCsum(j) and !verifyCommitChecksum(j.csum_seed, scan)) return error.Corrupt;
                found_commit = true;
                break;
            } else return error.Corrupt;
        }
        if (!found_commit) return error.Corrupt;

        var replayed: usize = 0;
        for (tags.items) |tag| {
            if (revokes.get(tag.target)) |revoked_tid| {
                if (tidGeq(revoked_tid, tid)) continue;
            }
            try self.readJournalBlock(tag.data_log, data);
            if (!verifyJournalTag(j, desc, tag, tid, data)) return error.Corrupt;
            if (tag.target < self.first_data_block or tag.target >= self.meta.blocks_count) return error.Corrupt;
            const off: usize = @intCast(tag.target * self.block_size);
            if (off + self.block_size > self.image.len) return error.Corrupt;
            @memcpy(self.image[off..][0..self.block_size], data);
            try self.markDirty(tag.target);
            replayed += 1;
        }

        _ = try self.writeDirty();
        // Сначала обнуляем s_start журнала, и только потом снимаем RECOVER
        // в ext4: иначе крах между записями потерял бы транзакцию.
        _ = try self.writeJournalSuper(0, tid + 1);
        self.feature_incompat &= ~@as(u32, EXT4_FEATURE_INCOMPAT_RECOVER);
        const sb_buf = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(sb_buf);
        @memcpy(sb_buf, self.superBlockBytes());
        put32(sb_buf, 96, self.feature_incompat);
        _ = try self.writeBlockDirect(self.superBlockNumber(), sb_buf);
        j = self.journal orelse return error.NotSupported;
        j.replayed_blocks = replayed;
        j.commits += 1;
        self.journal = j;
    }

    /// fs/jbd2/commit.c: один коммит — дескриптор, data blocks, revoke block,
    /// commit block, затем journal superblock с RECOVER, сброс целевых блоков
    /// и чистый суперблок. all log-блоки проходят через wrap().
    fn journalSync(self: *Ext4) !usize {
        var j = self.journal orelse return self.writeDirty();
        const has_csum = journalHasCsum(j);

        // fs/jbd2/revoke.c: revoke после dirty побеждает; dirty после revoke
        // отменяет запись revoke-записи в текущей транзакции.
        var revoked = std.ArrayList(u64).empty;
        defer revoked.deinit(self.allocator);
        var cancelled = std.ArrayList(u64).empty;
        defer cancelled.deinit(self.allocator);
        var rit = j.revoke.iterator();
        while (rit.next()) |entry| {
            const block_no = entry.key_ptr.*;
            const revoke_clock = entry.value_ptr.*;
            if (self.dirty.contains(block_no)) {
                if ((self.touch.get(block_no) orelse 0) > revoke_clock) {
                    try cancelled.append(self.allocator, block_no);
                } else {
                    _ = self.dirty.remove(block_no);
                    _ = self.touch.remove(block_no);
                    try revoked.append(self.allocator, block_no);
                }
            } else {
                try revoked.append(self.allocator, block_no);
            }
        }
        for (cancelled.items) |block_no| _ = j.revoke.remove(block_no);
        if (self.dirty.count() == 0 and revoked.items.len == 0) return 0;

        var blocks = std.ArrayList(u64).empty;
        defer blocks.deinit(self.allocator);
        var it = self.dirty.iterator();
        while (it.next()) |entry| try blocks.append(self.allocator, entry.key_ptr.*);

        const n = blocks.items.len;
        const revoke_blocks: usize = if (revoked.items.len == 0) 0 else 1;
        const needed = 1 + n + revoke_blocks + 1;
        const capacity = j.maxlen - j.first;
        if (needed > capacity) return error.NotSupported;
        const tag_len = journalTagBytes(j);
        const limit = self.block_size - (if (has_csum) @as(usize, 4) else 0) - 16;
        if (n != 0 and 12 + n * tag_len + 16 > limit) return error.NotSupported;

        const buf = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(buf);
        const data = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(data);
        var log_block = j.first;
        var written: usize = 0;
        var revoke_writes: usize = 0;

        if (n != 0) {
            @memset(buf, 0);
            put32be(buf, 0, JBD2_MAGIC_NUMBER);
            put32be(buf, 4, JBD2_DESCRIPTOR_BLOCK);
            put32be(buf, 8, j.sequence);
            var cursor: usize = 12;
            for (blocks.items, 0..) |block_no, i| {
                const off: usize = @intCast(block_no * self.block_size);
                if (off + self.block_size > self.image.len) return error.Corrupt;
                var flags: u16 = 0;
                if (i > 0) flags |= JBD2_FLAG_SAME_UUID;
                if (i + 1 == n) flags |= JBD2_FLAG_LAST_TAG;
                try writeJournalTag(j, buf, cursor, block_no, flags, j.sequence, self.image[off..][0..self.block_size]);
                cursor += tag_len;
                if (i == 0) {
                    @memcpy(buf[cursor..][0..16], &j.uuid);
                    cursor += 16;
                }
            }
            if (has_csum) writeBlockTail(j.csum_seed, buf);
            written += try self.writeJournalBlock(log_block, buf);
            log_block = journalNext(j, log_block);
            for (blocks.items) |block_no| {
                const off: usize = @intCast(block_no * self.block_size);
                @memcpy(data, self.image[off..][0..self.block_size]);
                written += try self.writeJournalBlock(log_block, data);
                log_block = journalNext(j, log_block);
            }
        }

        if (revoked.items.len != 0) {
            _ = try self.writeRevokeBlock(j, buf, revoked.items, j.sequence);
            written += try self.writeJournalBlock(log_block, buf);
            revoke_writes += 1;
            log_block = journalNext(j, log_block);
        }

        @memset(buf, 0);
        put32be(buf, 0, JBD2_MAGIC_NUMBER);
        put32be(buf, 4, JBD2_COMMIT_BLOCK);
        put32be(buf, 8, j.sequence);
        buf[12] = JBD2_CRC32C_CHKSUM;
        buf[13] = 4;
        if (has_csum) writeCommitChecksum(j.csum_seed, buf);
        written += try self.writeJournalBlock(log_block, buf);

        // RECOVER и s_start фиксируются до сброса целевых блоков: крах после
        // коммита журнала будет восстановлен при следующем монтировании.
        self.feature_incompat |= EXT4_FEATURE_INCOMPAT_RECOVER;
        @memcpy(buf, self.superBlockBytes());
        put32(buf, 96, self.feature_incompat);
        written += try self.writeBlockDirect(self.superBlockNumber(), buf);
        written += try self.writeJournalSuper(j.first, j.sequence);
        written += try self.writeDirty();

        // Порядок на диске: сначала чистый журнал, затем снятие RECOVER.
        written += try self.writeJournalSuper(0, j.sequence + 1);
        self.feature_incompat &= ~@as(u32, EXT4_FEATURE_INCOMPAT_RECOVER);
        @memcpy(buf, self.superBlockBytes());
        put32(buf, 96, self.feature_incompat);
        written += try self.writeBlockDirect(self.superBlockNumber(), buf);
        j = self.journal orelse return error.NotSupported;
        j.commits += 1;
        j.revoke_writes += revoke_writes;
        j.revoke.clearRetainingCapacity();
        self.journal = j;
        for (revoked.items) |block_no| _ = self.touch.remove(block_no);
        return written;
    }

    /// fs/ext4/super.c: ext4_sync_fs() — сбросить грязные extent-блоки.
    pub fn sync(self: *Ext4) !usize {
        if (self.writeback == null) return error.ReadOnly;
        if (self.dirty.count() == 0) return 0;
        if (self.journal != null) return self.journalSync();
        return self.writeDirty();
    }

    /// Общий путь пометки буфера как BJ_Metadata и учёта порядка относительно
    /// BJ_Forget/revoke в текущей транзакции.
    fn markDirty(self: *Ext4, block_no: u64) !void {
        try self.dirty.put(block_no, {});
        self.op_clock += 1;
        try self.touch.put(block_no, self.op_clock);
    }

    fn writeDirty(self: *Ext4) !usize {
        const wb = self.writeback orelse return error.ReadOnly;
        var it = self.dirty.iterator();
        var written: usize = 0;
        while (it.next()) |entry| {
            const block_no = entry.key_ptr.*;
            const offset = block_no * self.block_size;
            if (offset + self.block_size > self.image.len) return error.Corrupt;
            try wb.write(wb.ctx, offset, self.image[offset..][0..self.block_size]);
            written += 1;
        }
        self.dirty.clearRetainingCapacity();
        return written;
    }

    /// super_operations.sync_fs не может вернуть ошибку: фиксируем её в Meta.
    fn syncFs(ctx: ?*anyopaque, _: *vfs.SuperBlock) void {
        const m: *Meta = @ptrCast(@alignCast(ctx orelse return));
        m.sync_calls += 1;
        m.synced_blocks = 0;
        m.sync_failed = false;
        const fs = m.fs orelse {
            m.sync_failed = true;
            return;
        };
        const written = fs.sync() catch {
            m.sync_failed = true;
            return;
        };
        m.synced_blocks = written;
    }

    fn loadInode(self: *Ext4, ino: u32) !*Inode {
        if (ino == 0 or ino > self.inodes_count) return error.Invalid;
        if (self.inode_cache.get(ino)) |cached| return cached;
        const off = try self.inodeOffset(ino);

        const i = try self.allocator.create(Inode);
        errdefer self.allocator.destroy(i);
        i.* = .{
            .ino = ino,
            .mode = try rd16(self.image, off),
            .size = try rd32(self.image, off + 4),
            .links = try rd16(self.image, off + 26),
            .blocks = try rd32(self.image, off + 28),
            .flags = try rd32(self.image, off + 32),
        };
        if (i.isReg()) {
            const high = try rd32(self.image, off + 108);
            i.size |= @as(u64, high) << 32;
        }
        @memcpy(&i.block, self.image[off + 40 ..][0..60]);
        try self.inode_cache.put(ino, i);
        return i;
    }

    /// fs/ext4/inode.c: ext4_inode_table + ino-1 смещение в inode table.
    fn inodeOffset(self: *const Ext4, ino: u32) !usize {
        if (ino == 0 or ino > self.inodes_count) return error.Invalid;
        const per_group: usize = self.inodes_per_group;
        const idx0: usize = ino - 1;
        const group = idx0 / per_group;
        if (group >= self.groups.len) return error.Invalid;
        const index = idx0 % per_group;
        const off = @as(usize, @intCast(self.groups[group].inode_table)) * self.block_size + index * self.inode_size;
        if (off + self.inode_size > self.image.len) return error.Corrupt;
        return off;
    }

    /// Записать изменённый inode обратно в inode table и пометить блок грязным.
    fn flushInode(self: *Ext4, inode: *Inode) !void {
        const off = try self.inodeOffset(inode.ino);
        put16(self.image, off, @truncate(inode.mode));
        put32(self.image, off + 4, @truncate(inode.size));
        put16(self.image, off + 26, inode.links);
        put32(self.image, off + 28, inode.blocks);
        @memcpy(self.image[off + 40 ..][0..60], &inode.block);
        try self.markDirty(@intCast(off / self.block_size));
    }

    /// fs/ext4/balloc.c + fs/ext4/bitmap.c: first-fit в единственной группе.
    /// Проверяем отсутствие checksum-функций: без JBD2 их нельзя обновить.
    fn allocateBlock(self: *Ext4) !u64 {
        if (self.writeback == null) return error.ReadOnly;
        if (self.groups.len != 1) return error.Invalid;
        if (self.feature_ro_compat & (EXT4_FEATURE_RO_COMPAT_GDT_CSUM | EXT4_FEATURE_RO_COMPAT_METADATA_CSUM) != 0) return error.Invalid;
        if (@as(u64, self.blocks_per_group) > @as(u64, self.block_size) * 8) return error.Invalid;
        const group = &self.groups[0];
        if (group.free_blocks == 0 or self.meta.free_blocks == 0) return error.NoSpace;
        if (self.meta.blocks_count <= self.first_data_block) return error.Corrupt;

        const limit = @min(@as(u64, self.blocks_per_group), self.meta.blocks_count - self.first_data_block);
        const bitmap_block: usize = @intCast(group.block_bitmap);
        const base = bitmap_block * self.block_size;
        if (base + self.block_size > self.image.len) return error.Corrupt;

        var index: u64 = 0;
        while (index < limit) : (index += 1) {
            const byte = base + @as(usize, @intCast(index / 8));
            const mask: u8 = @as(u8, 1) << @intCast(index % 8);
            if (self.image[byte] & mask != 0) continue;
            self.image[byte] |= mask;

            group.free_blocks -= 1;
            self.meta.free_blocks -= 1;
            try self.markDirty(bitmap_block);

            const gd_block: usize = if (self.block_size == 1024) 2 else 1;
            const gd_off = gd_block * self.block_size;
            if (gd_off + self.desc_size > self.image.len) return error.Corrupt;
            put16(self.image, gd_off + 12, @truncate(group.free_blocks));
            if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_64BIT != 0 and self.desc_size == 64) {
                put16(self.image, gd_off + 44, @truncate(group.free_blocks >> 16));
            }
            try self.markDirty(gd_block);

            put32(self.image, 1024 + 12, @truncate(self.meta.free_blocks));
            if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_64BIT != 0) {
                put32(self.image, 1024 + 344, @truncate(self.meta.free_blocks >> 32));
            }
            try self.markDirty(1024 / self.block_size);

            return self.first_data_block + index;
        }
        return error.NoSpace;
    }

    /// Общие ограничения метаданных для операций namei: одна группа и без
    /// checksum-полей, которые мы не умеем пересчитывать без JBD2.
    fn checkWritableMeta(self: *const Ext4) !void {
        if (self.writeback == null) return error.ReadOnly;
        if (self.groups.len != 1) return error.NotSupported;
        if (self.feature_ro_compat & (EXT4_FEATURE_RO_COMPAT_GDT_CSUM | EXT4_FEATURE_RO_COMPAT_METADATA_CSUM) != 0) {
            return error.NotSupported;
        }
    }

    fn groupDescOffset(self: *const Ext4) usize {
        const gd_block: usize = if (self.block_size == 1024) 2 else 1;
        return gd_block * self.block_size;
    }

    /// fs/ext4/balloc.c + fs/ext4/ialloc.c: s_*_count_lo/hi и bg_*_count_lo/hi.
    fn writeCounts(self: *Ext4) !void {
        const group = &self.groups[0];
        const gd_off = self.groupDescOffset();
        put16(self.image, gd_off + 12, @truncate(group.free_blocks));
        put16(self.image, gd_off + 14, @truncate(group.free_inodes));
        if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_64BIT != 0 and self.desc_size == 64) {
            put16(self.image, gd_off + 44, @truncate(group.free_blocks >> 16));
            put16(self.image, gd_off + 46, @truncate(group.free_inodes >> 16));
        }
        try self.markDirty(@intCast(gd_off / self.block_size));

        put32(self.image, 1024 + 12, @truncate(self.meta.free_blocks));
        put32(self.image, 1024 + 16, @truncate(self.meta.free_inodes));
        if (self.feature_incompat & EXT4_FEATURE_INCOMPAT_64BIT != 0) {
            put32(self.image, 1024 + 344, @truncate(self.meta.free_blocks >> 32));
            put32(self.image, 1024 + 348, @truncate(self.meta.free_inodes >> 32));
        }
        try self.markDirty(1024 / self.block_size);
    }

    /// fs/ext4/ialloc.c: bg_used_dirs_count_lo в group descriptor.
    fn writeUsedDirs(self: *Ext4) !void {
        const gd_off = self.groupDescOffset();
        put16(self.image, gd_off + 16, @truncate(self.groups[0].used_dirs));
        try self.markDirty(@intCast(gd_off / self.block_size));
    }

    /// fs/ext4/ialloc.c: ext4_new_inode() — first-fit по inode bitmap группы 0.
    fn allocateInode(self: *Ext4) !u32 {
        try self.checkWritableMeta();
        const group = &self.groups[0];
        if (group.free_inodes == 0 or self.meta.free_inodes == 0) return error.NoSpace;
        if (@as(u64, self.inodes_per_group) > @as(u64, self.block_size) * 8) return error.NotSupported;

        const bitmap_block: usize = @intCast(group.inode_bitmap);
        const base = bitmap_block * self.block_size;
        if (base + self.block_size > self.image.len) return error.Corrupt;
        const start: u64 = if (self.first_ino > 0) self.first_ino - 1 else 0;
        var index: u64 = start;
        while (index < self.inodes_per_group) : (index += 1) {
            const byte = base + @as(usize, @intCast(index / 8));
            const mask: u8 = @as(u8, 1) << @intCast(index % 8);
            if (self.image[byte] & mask != 0) continue;
            self.image[byte] |= mask;
            group.free_inodes -= 1;
            self.meta.free_inodes -= 1;
            try self.markDirty(bitmap_block);
            try self.writeCounts();
            return @intCast(index + 1);
        }
        return error.NoSpace;
    }

    /// fs/ext4/inode.c: ext4_free_inode() — убрать inode из bitmap и golden
    /// data его extent-ов, если это последняя ссылка.
    fn freeInode(self: *Ext4, ino: u32) !void {
        try self.checkWritableMeta();
        if (ino == 0 or ino > self.inodes_count) return error.Invalid;
        const off = try self.inodeOffset(ino);
        if ((try rd32(self.image, off + 32)) & EXT4_EXTENTS_FL != 0) {
            const hdr = self.image[off + 40 ..][0..60];
            if (try rd16(hdr, 0) != EXT4_EXTENT_MAGIC) return error.Corrupt;
            if (try rd16(hdr, 6) != 0) return error.NotSupported;
            const entries = try rd16(hdr, 2);
            const max = try rd16(hdr, 4);
            if (entries > max) return error.Corrupt;
            var n: usize = 0;
            while (n < entries) : (n += 1) {
                const e = hdr[12 + n * 12 ..][0..12];
                const len: u64 = (try rd16(e, 4)) & 0x7fff;
                if (len == 0) continue;
                const physical = (@as(u64, try rd16(e, 6)) << 32) | @as(u64, try rd32(e, 8));
                try self.freeBlocks(physical, len);
            }
        }
        @memset(self.image[off..][0..self.inode_size], 0);
        self.dropCachedInode(ino);
        try self.markDirty(@intCast(off / self.block_size));

        const group = &self.groups[0];
        const bitmap_block: usize = @intCast(group.inode_bitmap);
        const base = bitmap_block * self.block_size;
        const index = @as(usize, ino) - 1;
        if (index >= self.inodes_per_group or base + self.block_size > self.image.len) return error.Corrupt;
        const byte = base + index / 8;
        const mask: u8 = @as(u8, 1) << @intCast(index % 8);
        if (self.image[byte] & mask == 0) return error.Corrupt;
        self.image[byte] &= ~mask;
        group.free_inodes += 1;
        self.meta.free_inodes += 1;
        try self.markDirty(bitmap_block);
        try self.writeCounts();
    }

    /// fs/ext4/bitmap.c: освободить continuous extent из block bitmap группы 0.
    fn freeBlocks(self: *Ext4, physical: u64, len: u64) !void {
        try self.checkWritableMeta();
        const group = &self.groups[0];
        if (len == 0) return;
        if (physical < self.first_data_block or physical + len > self.meta.blocks_count) return error.Corrupt;
        const bitmap_block: usize = @intCast(group.block_bitmap);
        const base = bitmap_block * self.block_size;
        if (base + self.block_size > self.image.len) return error.Corrupt;
        const start = physical - self.first_data_block;
        const end = physical + len - self.first_data_block;
        var index = start;
        while (index < end) : (index += 1) {
            if (index >= self.blocks_per_group) return error.NotSupported;
            const byte = base + @as(usize, @intCast(index / 8));
            const mask: u8 = @as(u8, 1) << @intCast(index % 8);
            if (self.image[byte] & mask == 0) return error.Corrupt;
            self.image[byte] &= ~mask;
            group.free_blocks += 1;
            self.meta.free_blocks += 1;
        }
        try self.markDirty(bitmap_block);
        try self.writeCounts();
    }

    /// fs/ext4/inode.c: пустой регулярный inode с depth-0 extent header.
    fn initInode(self: *Ext4, ino: u32, mode: u32) !vfs.InodeInfo {
        const off = try self.inodeOffset(ino);
        @memset(self.image[off..][0..self.inode_size], 0);
        put16(self.image, off, @truncate(mode));
        put16(self.image, off + 26, 1);
        put32(self.image, off + 32, EXT4_EXTENTS_FL);
        const hdr = self.image[off + 40 ..][0..60];
        put16(hdr, 0, EXT4_EXTENT_MAGIC);
        put16(hdr, 2, 0);
        put16(hdr, 4, 4);
        put16(hdr, 6, 0);
        put32(hdr, 8, 0);
        self.dropCachedInode(ino);
        try self.markDirty(@intCast(off / self.block_size));
        return .{ .ino = ino, .mode = mode, .size = 0 };
    }

    fn dirBlock(self: *Ext4, dir: *Inode) ![]u8 {
        if (!dir.isDir() or dir.size != self.block_size) return error.NotSupported;
        const data = try self.allocator.alloc(u8, self.block_size);
        errdefer self.allocator.free(data);
        const n = try self.readAt(dir, 0, data);
        if (n != data.len) return error.Corrupt;
        return data;
    }

    fn writeDirBlock(self: *Ext4, dir: *Inode, data: []const u8) !void {
        if (data.len != self.block_size) return error.Invalid;
        const physical = (try self.mapBlock(dir, 0)) orelse return error.Corrupt;
        const off = @as(usize, @intCast(physical)) * self.block_size;
        if (off + self.block_size > self.image.len) return error.Corrupt;
        @memcpy(self.image[off..][0..self.block_size], data);
        try self.markDirty(@intCast(physical));
    }

    fn dropCachedInode(self: *Ext4, ino: u32) void {
        if (self.inode_cache.fetchRemove(ino)) |entry| self.allocator.destroy(entry.value);
    }

    fn parentIno(parent: *const vfs.Dentry) !u32 {
        if (parent.isRoot()) return EXT4_ROOT_INO;
        const ino = parent.d_inode orelse return error.NoEnt;
        if (ino.i_ino == 1) return EXT4_ROOT_INO;
        if (ino.i_ino > std.math.maxInt(u32)) return error.Invalid;
        return @intCast(ino.i_ino);
    }

    fn instantiate(ctx: ?*anyopaque, d: *vfs.Dentry) anyerror!*anyopaque {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        return @ptrCast(try self.open(d));
    }

    const DirSlot = struct {
        off: usize,
        rec: usize,
        need: usize,
        old_need: usize,
        from_free: bool,
    };

    /// fs/ext4/namei.c: ext4_find_entry() + search_dirblock(): проверить уникальность
    /// имени и выбрать свободный/последний слот для split dir_entry_2.
    fn scanDirSlot(data: []const u8, q: vfs.Qstr) !DirSlot {
        const need = 8 + align4(q.name.len);
        var free_slot: ?usize = null;
        var last_slot: ?usize = null;
        var off: usize = 0;
        while (off + 8 <= data.len) {
            const ino = try rd32(data, off);
            const rec: usize = try rd16(data, off + 4);
            const name_len: usize = data[off + 6];
            if (rec < 8 or rec % 4 != 0 or off + rec > data.len) return error.Corrupt;
            if (name_len > 255 or 8 + align4(name_len) > rec) return error.Corrupt;
            if (ino != 0 and name_len == q.name.len and std.mem.eql(u8, data[off + 8 ..][0..name_len], q.name)) {
                return error.PathExists;
            }
            if (ino == 0 and rec >= need and free_slot == null) free_slot = off;
            last_slot = off;
            off += rec;
        }
        if (off != data.len) return error.Corrupt;
        const slot = free_slot orelse last_slot orelse return error.NoSpace;
        const rec: usize = try rd16(data, slot + 4);
        const old_ino = try rd32(data, slot);
        const old_need: usize = if (old_ino == 0) 8 else 8 + align4(@as(usize, data[slot + 6]));
        if (rec < need or rec < old_need) return error.Corrupt;
        return .{ .off = slot, .rec = rec, .need = need, .old_need = old_need, .from_free = free_slot != null };
    }

    /// fs/ext4/namei.c: ext4_add_entry() — split последней записи, либо повторное
    /// использование свободного слота. Сохраняет выравнивание rec_len по 4 байта.
    fn insertDirEntry(data: []u8, slot: DirSlot, ino: u32, q: vfs.Qstr, file_type: u8) void {
        const split = @max(slot.need, slot.old_need);
        if (slot.from_free or slot.rec - split < slot.need) {
            put32(data, slot.off, ino);
            put16(data, slot.off + 4, @intCast(slot.rec));
            data[slot.off + 6] = @intCast(q.name.len);
            data[slot.off + 7] = file_type;
            @memcpy(data[slot.off + 8 ..][0..q.name.len], q.name);
        } else {
            put16(data, slot.off + 4, @intCast(split));
            const at = slot.off + split;
            put32(data, at, ino);
            put16(data, at + 4, @intCast(slot.rec - split));
            data[at + 6] = @intCast(q.name.len);
            data[at + 7] = file_type;
            @memcpy(data[at + 8 ..][0..q.name.len], q.name);
        }
    }

    /// fs/ext4/namei.c: ext4_mkdir() — пустой каталог с "."/".." и свободным
    /// хвостом блока, плюс один depth-0 extent на выделенный блок данных.
    fn initDirInode(self: *Ext4, ino: u32, parent_ino: u32, physical: u64) !vfs.InodeInfo {
        const off = try self.inodeOffset(ino);
        @memset(self.image[off..][0..self.inode_size], 0);
        const mode = vfs.S_IFDIR | 0o755;
        put16(self.image, off, @truncate(mode));
        put32(self.image, off + 4, @intCast(self.block_size));
        put16(self.image, off + 26, 2); // "." и ".."
        put32(self.image, off + 28, @intCast(self.block_size / 512));
        put32(self.image, off + 32, EXT4_EXTENTS_FL);
        const hdr = self.image[off + 40 ..][0..60];
        put16(hdr, 0, EXT4_EXTENT_MAGIC);
        put16(hdr, 2, 1);
        put16(hdr, 4, 4);
        put16(hdr, 6, 0);
        put32(hdr, 8, 0);
        put32(hdr, 12, 0);
        put16(hdr, 16, 1);
        put16(hdr, 18, @truncate(physical >> 32));
        put32(hdr, 20, @truncate(physical));
        self.dropCachedInode(ino);
        try self.markDirty(@intCast(off / self.block_size));

        const data_off: usize = @as(usize, @intCast(physical)) * self.block_size;
        if (data_off + self.block_size > self.image.len) return error.Corrupt;
        @memset(self.image[data_off..][0..self.block_size], 0);
        var cursor: usize = data_off;
        putDirEntry(self.image, &cursor, ino, 2, ".", 12);
        putDirEntry(self.image, &cursor, parent_ino, 2, "..", 12);
        putDirEntry(self.image, &cursor, 0, 0, "", @intCast(self.block_size - 24));
        try self.markDirty(physical);
        return .{ .ino = ino, .mode = mode, .size = self.block_size };
    }

    /// fs/ext4/namei.c: ext4_create() — только root directory одного блока.
    fn create(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) anyerror!vfs.InodeInfo {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.checkWritableMeta();
        if (q.name.len == 0 or q.name.len > 255) return error.Invalid;
        const dir = try self.loadInode(try parentIno(parent));
        const data = try self.dirBlock(dir);
        defer self.allocator.free(data);
        const slot = try scanDirSlot(data, q);

        const ino = try self.allocateInode();
        const info = try self.initInode(ino, vfs.S_IFREG | 0o644);
        insertDirEntry(data, slot, ino, q, 1); // EXT4_FT_REG_FILE
        try self.writeDirBlock(dir, data);
        return info;
    }

    /// fs/ext4/namei.c: ext4_mkdir() — новый каталог в одном блоке. Родитель
    /// получает дополнительную ссылку через "..", bg_used_dirs_count увеличивается.
    fn mkdir(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) anyerror!vfs.InodeInfo {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.checkWritableMeta();
        if (q.name.len == 0 or q.name.len > 255) return error.Invalid;
        const pino = try parentIno(parent);
        const dir = try self.loadInode(pino);
        if (!dir.isDir()) return error.NotDir;
        const data = try self.dirBlock(dir);
        defer self.allocator.free(data);
        const slot = try scanDirSlot(data, q);

        try self.reserveBlocks(1);
        const ino = try self.allocateInode();
        const physical = try self.allocateBlock();
        const info = try self.initDirInode(ino, pino, physical);
        insertDirEntry(data, slot, ino, q, 2); // EXT4_FT_DIR
        try self.writeDirBlock(dir, data);
        dir.links += 1;
        try self.flushInode(dir);
        self.groups[0].used_dirs += 1;
        try self.writeUsedDirs();
        return info;
    }

    const DirLoc = struct {
        off: usize,
        prev: ?usize,
        ino: u32,
        rec: usize,
    };

    /// fs/ext4/namei.c: ext4_find_entry() — просканировать один блок каталога
    /// и вернуть слот с предыдущей записью для coalesce свободного rec_len.
    fn findDirLoc(data: []const u8, q: vfs.Qstr) !DirLoc {
        var off: usize = 0;
        var prev: ?usize = null;
        while (off + 8 <= data.len) {
            const ino = try rd32(data, off);
            const rec: usize = try rd16(data, off + 4);
            const name_len: usize = data[off + 6];
            if (rec < 8 or rec % 4 != 0 or off + rec > data.len) return error.Corrupt;
            if (name_len > 255 or 8 + align4(name_len) > rec) return error.Corrupt;
            if (ino != 0 and name_len == q.name.len and std.mem.eql(u8, data[off + 8 ..][0..name_len], q.name)) {
                return .{ .off = off, .prev = prev, .ino = ino, .rec = rec };
            }
            prev = off;
            off += rec;
        }
        if (off != data.len) return error.Corrupt;
        return error.NoEnt;
    }

    /// fs/ext4/namei.c: удалить dir_entry_2 и при необходимости склеить его
    /// со свободным предыдущим слотом.
    fn clearDirEntry(data: []u8, loc: DirLoc) !void {
        put32(data, loc.off, 0);
        data[loc.off + 6] = 0;
        data[loc.off + 7] = 0;
        if (loc.prev) |at| {
            if (try rd32(data, at) == 0) {
                put16(data, at + 4, @intCast((try rd16(data, at + 4)) + loc.rec));
            }
        }
    }

    /// fs/ext4/namei.c: ext4_unlink() — только root directory одного блока.
    fn unlink(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) anyerror!void {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.checkWritableMeta();
        const dir = try self.loadInode(try parentIno(parent));
        const data = try self.dirBlock(dir);
        defer self.allocator.free(data);
        const loc = try findDirLoc(data, q);

        const child = try self.loadInode(loc.ino);
        if (child.isDir()) return error.IsDir;
        try clearDirEntry(data, loc);
        try self.writeDirBlock(dir, data);
        try self.freeInode(loc.ino);
    }

    /// fs/ext4/namei.c: ext4_rmdir() — каталог должен содержать только "." и
    /// ".." (и свободный хвост блока), иначе удаление невозможно.
    fn rmdir(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) anyerror!void {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.checkWritableMeta();
        const pino = try parentIno(parent);
        const dir = try self.loadInode(pino);
        if (!dir.isDir() or dir.links < 2) return error.Corrupt;
        const data = try self.dirBlock(dir);
        defer self.allocator.free(data);
        const loc = try findDirLoc(data, q);

        const child = try self.loadInode(loc.ino);
        if (!child.isDir()) return error.NotDir;
        if (child.links != 2 or child.size != self.block_size) return error.NotEmpty;
        const child_data = try self.dirBlock(child);
        defer self.allocator.free(child_data);

        var off: usize = 0;
        var seen: usize = 0;
        while (off + 8 <= child_data.len) {
            const ino = try rd32(child_data, off);
            const rec: usize = try rd16(child_data, off + 4);
            const name_len: usize = child_data[off + 6];
            if (rec < 8 or rec % 4 != 0 or off + rec > child_data.len) return error.Corrupt;
            if (name_len > 255 or 8 + align4(name_len) > rec) return error.Corrupt;
            if (seen == 0) {
                if (ino != loc.ino or name_len != 1 or !std.mem.eql(u8, child_data[off + 8 ..][0..1], ".") or child_data[off + 7] != 2) return error.Corrupt;
            } else if (seen == 1) {
                if (ino != pino or name_len != 2 or !std.mem.eql(u8, child_data[off + 8 ..][0..2], "..") or child_data[off + 7] != 2) return error.Corrupt;
            } else if (ino != 0 or name_len != 0) {
                return error.NotEmpty;
            }
            seen += 1;
            off += rec;
        }
        if (off != child_data.len or seen < 2) return error.Corrupt;
        if (self.groups[0].used_dirs == 0) return error.Corrupt;

        try clearDirEntry(data, loc);
        try self.writeDirBlock(dir, data);
        dir.links -= 1;
        try self.flushInode(dir);
        self.groups[0].used_dirs -= 1;
        try self.writeUsedDirs();
        try self.freeInode(loc.ino);
    }

    fn align4(n: usize) usize {
        return (n + 3) & ~@as(usize, 3);
    }

    /// fs/ext4/balloc.c: убедиться до записи, что для всех новых блоков хватит
    /// свободных битов, иначе запись не оставит частично грязных блоков.
    fn reserveBlocks(self: *Ext4, needed: usize) !void {
        if (self.writeback == null) return error.ReadOnly;
        if (self.groups.len != 1) return error.Invalid;
        if (self.feature_ro_compat & (EXT4_FEATURE_RO_COMPAT_GDT_CSUM | EXT4_FEATURE_RO_COMPAT_METADATA_CSUM) != 0) return error.Invalid;
        if (@as(u64, self.blocks_per_group) > @as(u64, self.block_size) * 8) return error.Invalid;
        const group = &self.groups[0];
        if (@as(u64, needed) > group.free_blocks or @as(u64, needed) > self.meta.free_blocks) return error.NoSpace;
        if (self.meta.blocks_count <= self.first_data_block) return error.Corrupt;
        const limit = @min(@as(u64, self.blocks_per_group), self.meta.blocks_count - self.first_data_block);
        const base = @as(usize, @intCast(group.block_bitmap)) * self.block_size;
        if (base + self.block_size > self.image.len) return error.Corrupt;

        var available: u64 = 0;
        var index: u64 = 0;
        while (index < limit) : (index += 1) {
            const byte = base + @as(usize, @intCast(index / 8));
            const mask: u8 = @as(u8, 1) << @intCast(index % 8);
            if (self.image[byte] & mask == 0) {
                available += 1;
                if (available >= needed) return;
            }
        }
        return error.NoSpace;
    }

    fn leafMax(self: *const Ext4) u16 {
        return @intCast((self.block_size - 12) / 12);
    }

    /// fs/ext4/extents.c: конец последнего extent-а в header/leaf.
    fn lastExtentEnd(hdr: []const u8, entries: u16) !u64 {
        if (entries == 0) return 0;
        const e = hdr[12 + (@as(usize, entries) - 1) * 12 ..][0..12];
        const len: u32 = (try rd16(e, 4)) & 0x7fff;
        if (len == 0) return error.Corrupt;
        return @as(u64, try rd32(e, 0)) + len;
    }

    /// fs/ext4/extents.c: новый extent вставляется по возрастанию ee_block,
    /// поэтому дыра между старыми extent-ами остаётся без физических блоков.
    fn insertionSlot(hdr: []const u8, entries: u16, logical: u32) !usize {
        var n: usize = 0;
        while (n < entries) : (n += 1) {
            const e = hdr[12 + n * 12 ..][0..12];
            if (try rd32(e, 0) > logical) break;
        }
        return n;
    }

    /// fs/ext4/extents.c: проверить, что вставка не перекрывает соседние extent-ы.
    fn validateInsertion(hdr: []const u8, entries: u16, logical: u32) !void {
        const slot = try insertionSlot(hdr, entries, logical);
        if (slot > 0 and @as(u64, logical) < try lastExtentEnd(hdr, @intCast(slot))) return error.Invalid;
        if (slot < entries) {
            const next = hdr[12 + slot * 12 ..][0..12];
            if (try rd32(next, 0) <= logical) return error.Invalid;
        }
    }

    /// fs/ext4/extents.c: 12-байтный ext4_extent (ee_start_hi @+6).
    fn putExtentEntry(buf: []u8, off: usize, logical: u32, physical: u64) void {
        put32(buf, off, logical);
        put16(buf, off + 4, 1);
        put16(buf, off + 6, @truncate(physical >> 32));
        put32(buf, off + 8, @truncate(physical));
    }

    /// Сдвинуть хвост header-а и вставить extent в отсортированный слот.
    fn insertExtentEntry(hdr: []u8, slot: usize, entries: u16, logical: u32, physical: u64) void {
        var i: usize = entries;
        while (i > slot) : (i -= 1) {
            @memcpy(hdr[12 + i * 12 ..][0..12], hdr[12 + (i - 1) * 12 ..][0..12]);
        }
        putExtentEntry(hdr, 12 + slot * 12, logical, physical);
        put16(hdr, 2, entries + 1);
    }

    /// fs/ext4/extents.c: 12-байтный ext4_extent_idx (ei_leaf_lo @+4).
    fn putIndexEntry(buf: []u8, off: usize, first_logical: u32, physical: u64) void {
        put32(buf, off, first_logical);
        put32(buf, off + 4, @truncate(physical));
        put16(buf, off + 8, @truncate(physical >> 32));
        put16(buf, off + 10, 0);
    }

    const IndexEntry = struct {
        key: u32,
        physical: u64,
    };

    fn readIndexEntry(hdr: []const u8, slot: usize) !IndexEntry {
        const e = hdr[12 + slot * 12 ..][0..12];
        return .{
            .key = try rd32(e, 0),
            .physical = (@as(u64, try rd16(e, 8)) << 32) | @as(u64, try rd32(e, 4)),
        };
    }

    fn indexSlot(hdr: []const u8, entries: u16, key: u32) !usize {
        var n: usize = 0;
        while (n < entries) : (n += 1) {
            if (try rd32(hdr[12 + n * 12 ..][0..12], 0) > key) break;
        }
        return n;
    }

    fn validateIndexInsertion(hdr: []const u8, entries: u16, key: u32) !void {
        const slot = try indexSlot(hdr, entries, key);
        if (slot > 0 and key <= try rd32(hdr[12 + (slot - 1) * 12 ..][0..12], 0)) return error.Invalid;
        if (slot < entries and key >= try rd32(hdr[12 + slot * 12 ..][0..12], 0)) return error.Invalid;
    }

    fn insertIndexEntry(hdr: []u8, slot: usize, entries: u16, key: u32, physical: u64) void {
        var i: usize = entries;
        while (i > slot) : (i -= 1) {
            @memcpy(hdr[12 + i * 12 ..][0..12], hdr[12 + (i - 1) * 12 ..][0..12]);
        }
        putIndexEntry(hdr, 12 + slot * 12, key, physical);
        put16(hdr, 2, entries + 1);
    }

    fn setIndexKey(hdr: []u8, slot: usize, key: u32) void {
        put32(hdr, 12 + slot * 12, key);
    }

    fn nodeHeader(self: *Ext4, inode: *Inode, physical: u64, level: usize) ![]u8 {
        if (level == 0) return inode.block[0..60];
        const off: usize = @intCast(physical * self.block_size);
        if (off + self.block_size > self.image.len) return error.Corrupt;
        return self.image[off..][0..self.block_size];
    }

    const TreePath = struct {
        depth: u16 = 0,
        leaf: u64 = 0,
        slots: [2]usize = .{ 0, 0 },
        parents: [2]u64 = .{ 0, 0 },
    };

    /// fs/ext4/extents.c: ext4_ext_find_extent() — путь от корня до leaf.
    fn findLeafPath(self: *Ext4, inode: *Inode, logical: u32) !TreePath {
        const root = inode.block[0..60];
        var p = TreePath{ .depth = try rd16(root, 6) };
        if (p.depth > 2) return error.NotSupported;
        var level: usize = 0;
        var physical: u64 = 0;
        while (level < p.depth) : (level += 1) {
            const hdr = try self.nodeHeader(inode, physical, level);
            const entries = try rd16(hdr, 2);
            if (entries == 0) return error.Corrupt;
            const slot = try indexSlot(hdr, entries, logical);
            p.slots[level] = if (slot > 0) slot - 1 else 0;
            const e = try readIndexEntry(hdr, p.slots[level]);
            p.parents[level] = physical;
            physical = e.physical;
        }
        p.leaf = physical;
        return p;
    }

    const LeafSplit = struct {
        new_leaf: u64,
        left_first: u32,
        right_first: u32,
    };

    /// fs/ext4/extents.c: ext4_ext_split() — полный leaf делится пополам,
    /// новый extent вставляется по ключу до разреза, новый leaf пишется
    /// в выделенный metadata-блок.
    fn splitLeafAndInsert(self: *Ext4, inode: *Inode, path: TreePath, logical: u32, physical: u64) !LeafSplit {
        const leaf = try self.nodeHeader(inode, path.leaf, path.depth);
        const entries = try rd16(leaf, 2);
        const max = self.leafMax();
        if (entries == 0 or entries > max) return error.Corrupt;
        try validateInsertion(leaf, entries, logical);
        const generation = try rd32(leaf, 8);
        const slot = try insertionSlot(leaf, entries, logical);
        const total: usize = entries + 1;
        const joined = try self.allocator.alloc(u8, total * 12);
        defer self.allocator.free(joined);
        @memcpy(joined[0 .. entries * 12], leaf[12..][0 .. entries * 12]);
        var i: usize = entries;
        while (i > slot) : (i -= 1) {
            @memcpy(joined[12 + i * 12 ..][0..12], joined[12 + (i - 1) * 12 ..][0..12]);
        }
        putExtentEntry(joined, slot * 12, logical, physical);
        const left_count = (total + 1) / 2;

        const new_leaf = try self.allocateBlock();
        inode.blocks += @intCast(self.block_size / 512);
        put16(leaf, 0, EXT4_EXTENT_MAGIC);
        put16(leaf, 2, @intCast(left_count));
        put16(leaf, 4, max);
        put16(leaf, 6, 0);
        put32(leaf, 8, generation);
        @memcpy(leaf[12..][0 .. left_count * 12], joined[0 .. left_count * 12]);
        try self.markDirty(path.leaf);

        const off: usize = @intCast(new_leaf * self.block_size);
        if (off + self.block_size > self.image.len) return error.Corrupt;
        const fresh = self.image[off..][0..self.block_size];
        @memset(fresh, 0);
        put16(fresh, 0, EXT4_EXTENT_MAGIC);
        put16(fresh, 2, @intCast(total - left_count));
        put16(fresh, 4, max);
        put16(fresh, 6, 0);
        put32(fresh, 8, generation);
        @memcpy(fresh[12..][0 .. (total - left_count) * 12], joined[left_count * 12 ..][0 .. (total - left_count) * 12]);
        try self.markDirty(new_leaf);
        return .{
            .new_leaf = new_leaf,
            .left_first = try rd32(joined, 0),
            .right_first = try rd32(joined[left_count * 12 ..][0..12], 0),
        };
    }

    const IndexSplit = struct {
        new_block: u64,
        left_first: u32,
        right_first: u32,
    };

    /// fs/ext4/extents.c: split полного индексного узла depth 1; новый узел
    /// получает правую половину ключей, родитель обновляет ключ.
    fn splitIndexNode(self: *Ext4, inode: *Inode, hdr: []u8, depth: u16, max: u16, key: u32, physical: u64) !IndexSplit {
        const entries = try rd16(hdr, 2);
        if (entries == 0 or entries != max) return error.Corrupt;
        try validateIndexInsertion(hdr, entries, key);
        const generation = try rd32(hdr, 8);
        const slot = try indexSlot(hdr, entries, key);
        const total: usize = entries + 1;
        const joined = try self.allocator.alloc(u8, total * 12);
        defer self.allocator.free(joined);
        @memcpy(joined[0 .. entries * 12], hdr[12..][0 .. entries * 12]);
        var i: usize = entries;
        while (i > slot) : (i -= 1) {
            @memcpy(joined[12 + i * 12 ..][0..12], joined[12 + (i - 1) * 12 ..][0..12]);
        }
        putIndexEntry(joined, slot * 12, key, physical);
        const left_count = (total + 1) / 2;
        const new_block = try self.allocateBlock();
        inode.blocks += @intCast(self.block_size / 512 * 2);

        put16(hdr, 0, EXT4_EXTENT_MAGIC);
        put16(hdr, 2, @intCast(left_count));
        put16(hdr, 4, max);
        put16(hdr, 6, depth);
        put32(hdr, 8, generation);
        @memcpy(hdr[12..][0 .. left_count * 12], joined[0 .. left_count * 12]);
        const off: usize = @intCast(new_block * self.block_size);
        if (off + self.block_size > self.image.len) return error.Corrupt;
        const fresh = self.image[off..][0..self.block_size];
        @memset(fresh, 0);
        put16(fresh, 0, EXT4_EXTENT_MAGIC);
        put16(fresh, 2, @intCast(total - left_count));
        put16(fresh, 4, max);
        put16(fresh, 6, depth);
        put32(fresh, 8, generation);
        @memcpy(fresh[12..][0 .. (total - left_count) * 12], joined[left_count * 12 ..][0 .. (total - left_count) * 12]);
        try self.markDirty(new_block);
        return .{
            .new_block = new_block,
            .left_first = try rd32(joined, 0),
            .right_first = try rd32(joined[left_count * 12 ..][0..12], 0),
        };
    }

    /// fs/ext4/extents.c: расщепление полного корня depth 1 — старые индексы
    /// переносятся в два новых узла depth 1, корень становится depth 2.
    fn splitRootIndex(self: *Ext4, inode: *Inode, key: u32, physical: u64) !void {
        const root = inode.block[0..60];
        const old_entries = try rd16(root, 2);
        const old_max = try rd16(root, 4);
        if (old_entries == 0 or old_entries != old_max) return error.Corrupt;
        const generation = try rd32(root, 8);
        try validateIndexInsertion(root, old_entries, key);
        const slot = try indexSlot(root, old_entries, key);
        const total: usize = old_entries + 1;
        const joined = try self.allocator.alloc(u8, total * 12);
        defer self.allocator.free(joined);
        @memcpy(joined[0 .. old_entries * 12], root[12..][0 .. old_entries * 12]);
        var i: usize = old_entries;
        while (i > slot) : (i -= 1) {
            @memcpy(joined[12 + i * 12 ..][0..12], joined[12 + (i - 1) * 12 ..][0..12]);
        }
        putIndexEntry(joined, slot * 12, key, physical);
        const left_count = (total + 1) / 2;
        const right_count = total - left_count;
        const left_block = try self.allocateBlock();
        const right_block = try self.allocateBlock();
        inode.blocks += @intCast(self.block_size / 512 * 2);
        const max = self.leafMax();
        for ([_]u64{ left_block, right_block }, 0..) |block_no, part| {
            const off: usize = @intCast(block_no * self.block_size);
            if (off + self.block_size > self.image.len) return error.Corrupt;
            const node = self.image[off..][0..self.block_size];
            @memset(node, 0);
            put16(node, 0, EXT4_EXTENT_MAGIC);
            put16(node, 2, @intCast(if (part == 0) left_count else right_count));
            put16(node, 4, max);
            put16(node, 6, 1);
            put32(node, 8, generation);
            const base = if (part == 0) 0 else left_count * 12;
            const count = if (part == 0) left_count else right_count;
            @memcpy(node[12..][0 .. count * 12], joined[base..][0 .. count * 12]);
            try self.markDirty(block_no);
        }
        @memset(root, 0);
        put16(root, 0, EXT4_EXTENT_MAGIC);
        put16(root, 2, 2);
        put16(root, 4, old_max);
        put16(root, 6, 2);
        put32(root, 8, generation);
        putIndexEntry(root, 12, try rd32(joined, 0), left_block);
        putIndexEntry(root, 24, try rd32(joined[left_count * 12 ..][0..12], 0), right_block);
    }

    /// fs/ext4/extents.c: ext4_ext_insert_extent()。Данные уже выделены,
    /// metadata-блоки выделяются только при расщеплении узлов.
    fn insertExtentByDepth(self: *Ext4, inode: *Inode, logical: u32, physical: u64) !void {
        const root = inode.block[0..60];
        const depth = try rd16(root, 6);
        if (try rd16(root, 0) != EXT4_EXTENT_MAGIC) return error.Corrupt;
        if (depth == 0) {
            const entries = try rd16(root, 2);
            const max = try rd16(root, 4);
            if (entries == max) {
                try self.splitRootAndInsert(inode, logical, physical);
                return;
            }
            if (entries > max) return error.Corrupt;
            try validateInsertion(root, entries, logical);
            const slot = try insertionSlot(root, entries, logical);
            insertExtentEntry(root, slot, entries, logical, physical);
            return;
        }
        const path = try self.findLeafPath(inode, logical);
        if (path.depth == 1) {
            const leaf = try self.nodeHeader(inode, path.leaf, 1);
            const entries = try rd16(leaf, 2);
            const max = self.leafMax();
            if (entries > max) return error.Corrupt;
            try validateInsertion(leaf, entries, logical);
            if (entries < max) {
                const slot = try insertionSlot(leaf, entries, logical);
                insertExtentEntry(leaf, slot, entries, logical, physical);
                try self.markDirty(path.leaf);
                const chosen = try readIndexEntry(root, path.slots[0]);
                if (logical < chosen.key) setIndexKey(root, path.slots[0], logical);
                return;
            }
            const split = try self.splitLeafAndInsert(inode, path, logical, physical);
            setIndexKey(root, path.slots[0], split.left_first);
            const root_entries = try rd16(root, 2);
            if (root_entries < try rd16(root, 4)) {
                const slot = try indexSlot(root, root_entries, split.right_first);
                insertIndexEntry(root, slot, root_entries, split.right_first, split.new_leaf);
                return;
            }
            try self.splitRootIndex(inode, split.right_first, split.new_leaf);
            return;
        }

        const inner = try self.nodeHeader(inode, path.parents[1], 1);
        const inner_entries = try rd16(inner, 2);
        const leaf = try self.nodeHeader(inode, path.leaf, 2);
        const leaf_entries = try rd16(leaf, 2);
        const leaf_max = self.leafMax();
        if (leaf_entries > leaf_max or inner_entries > leaf_max) return error.Corrupt;
        try validateInsertion(leaf, leaf_entries, logical);
        if (leaf_entries < leaf_max) {
            const slot = try insertionSlot(leaf, leaf_entries, logical);
            insertExtentEntry(leaf, slot, leaf_entries, logical, physical);
            try self.markDirty(path.leaf);
            const chosen = try readIndexEntry(inner, path.slots[1]);
            if (logical < chosen.key) {
                setIndexKey(inner, path.slots[1], logical);
                try self.markDirty(path.parents[1]);
            }
            return;
        }
        const split = try self.splitLeafAndInsert(inode, path, logical, physical);
        setIndexKey(inner, path.slots[1], split.left_first);
        if (inner_entries < leaf_max) {
            const slot = try indexSlot(inner, inner_entries, split.right_first);
            insertIndexEntry(inner, slot, inner_entries, split.right_first, split.new_leaf);
            try self.markDirty(path.parents[1]);
            return;
        }
        const root_entries = try rd16(root, 2);
        if (root_entries >= try rd16(root, 4)) return error.NotSupported;
        const node_split = try self.splitIndexNode(inode, inner, 1, leaf_max, split.right_first, split.new_leaf);
        setIndexKey(root, path.slots[0], node_split.left_first);
        const slot = try indexSlot(root, root_entries, node_split.right_first);
        insertIndexEntry(root, slot, root_entries, node_split.right_first, node_split.new_block);
    }

    /// Выделить data-блок и вставить extent по ключу; метаданные split-а
    /// учитываются в i_blocks и попадают в ту же JBD2-транзакцию.
    fn appendDataBlock(self: *Ext4, inode: *Inode, logical: u32) !u64 {
        const physical = try self.allocateBlock();
        try self.insertExtentByDepth(inode, logical, physical);
        inode.blocks += @intCast(self.block_size / 512);
        return physical;
    }

    fn splitRootAndInsert(self: *Ext4, inode: *Inode, logical: u32, data_physical: u64) !void {
        const root = inode.block[0..60];
        const old_entries = try rd16(root, 2);
        const old_max = try rd16(root, 4);
        if (old_entries == 0 or old_entries != old_max) return error.Corrupt;
        const generation = try rd32(root, 8);
        const slot = try insertionSlot(root, old_entries, logical);
        const first_logical: u32 = if (slot == 0) logical else try rd32(root, 12);

        const leaf_physical = try self.allocateBlock();
        inode.blocks += @intCast(self.block_size / 512);
        const leaf = try self.allocator.alloc(u8, self.block_size);
        defer self.allocator.free(leaf);
        @memset(leaf, 0);
        put16(leaf, 0, EXT4_EXTENT_MAGIC);
        put16(leaf, 2, old_entries + 1);
        put16(leaf, 4, self.leafMax());
        put16(leaf, 6, 0);
        put32(leaf, 8, generation);
        const tail: usize = @as(usize, old_entries) - slot;
        if (slot > 0) @memcpy(leaf[12..][0 .. slot * 12], root[12..][0 .. slot * 12]);
        putExtentEntry(leaf, 12 + slot * 12, logical, data_physical);
        if (tail > 0) @memcpy(leaf[12 + (slot + 1) * 12 ..][0 .. tail * 12], root[12 + slot * 12 ..][0 .. tail * 12]);

        const off: usize = @intCast(leaf_physical * self.block_size);
        if (off + self.block_size > self.image.len) return error.Corrupt;
        @memcpy(self.image[off..][0..self.block_size], leaf);
        try self.markDirty(leaf_physical);

        @memset(root, 0);
        put16(root, 0, EXT4_EXTENT_MAGIC);
        put16(root, 2, 1);
        put16(root, 4, old_max);
        put16(root, 6, 1);
        put32(root, 8, generation);
        putIndexEntry(root, 12, first_logical, leaf_physical);
    }

    fn extentAt(hdr: []const u8, logical: u32, depth: u16) !?Extent {
        if (try rd16(hdr, 0) != EXT4_EXTENT_MAGIC) return error.Corrupt;
        const entries = try rd16(hdr, 2);
        const max = try rd16(hdr, 4);
        if (entries > max or entries == 0) return null;
        if (try rd16(hdr, 6) != depth) return error.Invalid;

        var n: usize = 0;
        while (n < entries) : (n += 1) {
            const e = hdr[12 + n * 12 ..][0..12];
            const first = try rd32(e, 0);
            if (depth == 0) {
                const raw_len = try rd16(e, 4);
                const len: u32 = raw_len & 0x7fff; // uninitialized extent
                if (len == 0) continue;
                if (logical >= first and @as(u64, logical) < @as(u64, first) + len) {
                    const start = (@as(u64, try rd16(e, 6)) << 32) | @as(u64, try rd32(e, 8));
                    return .{ .physical = start + (logical - first), .len = len - (logical - first) };
                }
            } else {
                const next = if (n + 1 < entries) try rd32(hdr[12 + (n + 1) * 12 ..][0..12], 0) else std.math.maxInt(u32);
                if (logical >= first and logical < next) {
                    const leaf = (@as(u64, try rd16(e, 8)) << 32) | @as(u64, try rd32(e, 4));
                    return .{ .physical = leaf, .len = 0 };
                }
            }
        }
        return null;
    }

    fn mapBlock(self: *Ext4, inode: *Inode, logical: u32) !?u64 {
        if (inode.flags & EXT4_EXTENTS_FL == 0) return error.Corrupt; // indirect blocks не поддерж.
        var hdr: []const u8 = inode.block[0..60];
        var depth = try rd16(hdr, 6);
        var level: usize = 0;
        while (true) {
            const ext = (try extentAt(hdr, logical, depth)) orelse return null;
            if (depth == 0) return ext.physical;
            if (level >= 5) return error.Corrupt;
            const leaf_off = @as(usize, @intCast(ext.physical)) * self.block_size;
            if (leaf_off + self.block_size > self.image.len) return error.Corrupt;
            hdr = self.image[leaf_off..][0..self.block_size];
            depth -= 1;
            level += 1;
        }
    }

    /// fs/ext4/inode.c: readpage через extent tree; дыры читаются нулями.
    fn readAt(self: *Ext4, inode: *Inode, offset: u64, buf: []u8) !usize {
        if (buf.len == 0 or offset >= inode.size) return 0;
        const want: usize = @intCast(@min(@as(u64, buf.len), inode.size - offset));
        var done: usize = 0;
        while (done < want) {
            const pos = offset + done;
            const logical: u32 = @intCast(pos / self.block_size);
            const in_block: usize = @intCast(pos % self.block_size);
            const chunk = @min(want - done, self.block_size - in_block);
            if (try self.mapBlock(inode, logical)) |physical| {
                const byte_off = @as(u64, physical) * self.block_size + in_block;
                if (byte_off + chunk > self.image.len) return error.Corrupt;
                const start: usize = @intCast(byte_off);
                @memcpy(buf[done..][0..chunk], self.image[start..][0..chunk]);
            } else {
                @memset(buf[done..][0..chunk], 0);
            }
            done += chunk;
        }
        return done;
    }

    /// fs/ext4/inode.c: ext4_write_begin/end. Перезапись идёт по готовым
    /// extent-ам, рост выделяет блоки только под записанные байты: пропуск
    /// между старым EOF и новой позицией остаётся дырой и читается нулями.
    /// Новый extent вставляется по ключу, поэтому дыры внутри файла тоже
    /// доступны для записи; при переполнении корня создаётся metadata-блок.
    fn writeAt(self: *Ext4, inode: *Inode, offset: u64, bytes: []const u8) !usize {
        if (bytes.len == 0) return 0;
        if (offset > std.math.maxInt(u64) - bytes.len) return error.Invalid;
        const end = offset + bytes.len;
        if ((end - 1) / self.block_size > std.math.maxInt(u32)) return error.Invalid;

        const root = inode.block[0..60];
        if (try rd16(root, 0) != EXT4_EXTENT_MAGIC) return error.Corrupt;
        const depth = try rd16(root, 6);
        const root_max = try rd16(root, 4);
        const root_entries = try rd16(root, 2);
        if (root_entries > root_max or root_max == 0) return error.Corrupt;
        if (depth > 2) return error.NotSupported;

        // Предпроверка: проверить каждый новый extent в его leaf и заранее
        // зарезервировать данные и metadata-блоки до первого memcpy.
        var leaf_loads = std.AutoHashMap(u64, usize).init(self.allocator);
        defer leaf_loads.deinit();
        var scan = offset;
        var new_blocks: usize = 0;
        while (scan < end) {
            const logical: u32 = @intCast(scan / self.block_size);
            const in_block: usize = @intCast(scan % self.block_size);
            const room: u64 = @as(u64, self.block_size - in_block);
            const chunk: usize = @intCast(@min(end - scan, room));
            if ((try self.mapBlock(inode, logical)) == null) {
                if (depth == 0) {
                    try validateInsertion(root, root_entries, logical);
                } else {
                    const path = try self.findLeafPath(inode, logical);
                    const leaf = try self.nodeHeader(inode, path.leaf, path.depth);
                    const present = try rd16(leaf, 2);
                    if (present > self.leafMax()) return error.Corrupt;
                    try validateInsertion(leaf, present, logical);
                    const gop = try leaf_loads.getOrPut(path.leaf);
                    if (!gop.found_existing) gop.value_ptr.* = 0;
                    gop.value_ptr.* += 1;
                }
                new_blocks += 1;
                if (depth == 0 and @as(usize, root_entries) + new_blocks > self.leafMax()) return error.NotSupported;
            }
            scan += chunk;
        }
        var meta_blocks: usize = 0;
        if (new_blocks > 0 and depth == 0) {
            if (@as(usize, root_entries) + new_blocks > root_max) meta_blocks = 1;
        } else if (new_blocks > 0) {
            const leaf_max: usize = self.leafMax();
            var extra_leaves: usize = 0;
            var it = leaf_loads.iterator();
            while (it.next()) |entry| {
                const leaf = try self.nodeHeader(inode, entry.key_ptr.*, depth);
                const present: usize = try rd16(leaf, 2);
                const total = present + entry.value_ptr.*;
                const needed = (total + leaf_max - 1) / leaf_max;
                if (needed > 1) extra_leaves += needed - 1;
            }
            meta_blocks += extra_leaves;
            if (depth == 1) {
                // Полный корень depth 1 превращается в depth 2 двумя новыми
                // индексными блоками; старые индексы переносятся в них.
                if (@as(usize, root_entries) + extra_leaves > root_max) meta_blocks += 2;
            } else {
                var inner_nodes: usize = 0;
                var current_leaves: usize = 0;
                for (0..root_entries) |slot| {
                    const inner_phys = (try readIndexEntry(root, slot)).physical;
                    const inner = try self.nodeHeader(inode, inner_phys, 1);
                    current_leaves += try rd16(inner, 2);
                    inner_nodes += 1;
                }
                const needed = (current_leaves + extra_leaves + leaf_max - 1) / leaf_max;
                if (needed > inner_nodes) {
                    const extra_inner = needed - inner_nodes;
                    if (@as(usize, root_entries) + extra_inner > root_max) return error.NotSupported;
                    meta_blocks += extra_inner;
                }
            }
        }
        if (new_blocks > 0) try self.reserveBlocks(new_blocks + meta_blocks);

        var flush_inode = false;
        var done: usize = 0;
        while (done < bytes.len) {
            const pos = offset + done;
            const logical: u32 = @intCast(pos / self.block_size);
            const in_block: usize = @intCast(pos % self.block_size);
            const chunk = @min(bytes.len - done, self.block_size - in_block);
            const physical = (try self.mapBlock(inode, logical)) orelse blk: {
                const allocated = try self.appendDataBlock(inode, logical);
                flush_inode = true;
                break :blk allocated;
            };
            const byte_off = physical * self.block_size + in_block;
            if (byte_off + chunk > self.image.len) return error.Corrupt;
            const start: usize = @intCast(byte_off);
            @memcpy(self.image[start..][0..chunk], bytes[done..][0..chunk]);
            try self.markDirty(@intCast(physical));
            done += chunk;
        }
        if (end > inode.size) {
            inode.size = end;
            flush_inode = true;
        }
        if (flush_inode) try self.flushInode(inode);
        return done;
    }

    fn fastLink(inode: *Inode) ?[]const u8 {
        if (!inode.isLink() or inode.blocks != 0 or inode.size >= 60) return null;
        return inode.block[0..@as(usize, @intCast(inode.size))];
    }

    /// fs/ext4/namei.c: ext4_lookup() — линейный перебор dir_entry_2.
    fn lookup(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) ?vfs.InodeInfo {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return null));
        // VFS root inode has number 1, ext4 root is EXT4_ROOT_INO.
        const pino: u32 = if (parent.isRoot()) EXT4_ROOT_INO else blk: {
            const ino = parent.d_inode orelse return null;
            if (ino.i_ino > std.math.maxInt(u32)) return null;
            break :blk @intCast(ino.i_ino);
        };
        const dir = self.loadInode(pino) catch return null;
        if (!dir.isDir()) return null;
        const size: usize = @intCast(dir.size);
        if (size == 0) return null;
        const data = self.allocator.alloc(u8, size) catch return null;
        defer self.allocator.free(data);
        _ = self.readAt(dir, 0, data) catch return null;

        var off: usize = 0;
        while (off + 8 <= data.len) {
            const ino = rd32(data, off) catch return null;
            const rec_len = rd16(data, off + 4) catch return null;
            const name_len: usize = data[off + 6];
            if (rec_len < 8 or off + rec_len > data.len or name_len > 255) return null;
            if (ino != 0 and name_len == q.name.len and std.mem.eql(u8, data[off + 8 ..][0..name_len], q.name)) {
                const child = self.loadInode(ino) catch return null;
                var link: ?[]const u8 = null;
                if (child.isLink()) {
                    if (fastLink(child)) |target| {
                        link = target;
                    } else {
                        const n: usize = @intCast(child.size);
                        const b = self.allocator.alloc(u8, n) catch return null;
                        _ = self.readAt(child, 0, b) catch {
                            self.allocator.free(b);
                            return null;
                        };
                        self.links.append(self.allocator, b) catch {
                            self.allocator.free(b);
                            return null;
                        };
                        link = b;
                    }
                }
                return .{ .ino = child.ino, .mode = child.mode, .size = child.size, .link = link };
            }
            off += rec_len;
        }
        return null;
    }

    /// struct file для dentry, полученной через VFS namei.
    pub fn open(self: *Ext4, d: *vfs.Dentry) !*file.File {
        const vfs_ino = d.d_inode orelse return error.NoEnt;
        if (vfs_ino.i_ino > std.math.maxInt(u32)) return error.Invalid;
        _ = try self.loadInode(@intCast(vfs_ino.i_ino));
        const f = try self.allocator.create(file.File);
        errdefer self.allocator.destroy(f);
        f.* = .{
            .f_ops = .{ .ctx = self, .read = fileRead, .write = fileWrite, .llseek = fileSeek },
            .dentry = d,
        };
        try self.files.append(self.allocator, f);
        return f;
    }

    pub fn fileFor(self: *const Ext4, d: *vfs.Dentry) ?*file.File {
        for (self.files.items) |f| {
            if (f.dentry == d) return f;
        }
        return null;
    }

    fn fileRead(ctx: ?*anyopaque, f: *file.File, buf: []u8, pos: u64) i64 {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return -file.Errno.EIO));
        const d = f.dentry orelse return -file.Errno.EIO;
        const vfs_ino = d.d_inode orelse return -file.Errno.EIO;
        if (vfs_ino.i_ino > std.math.maxInt(u32)) return -file.Errno.EIO;
        const inode = self.loadInode(@intCast(vfs_ino.i_ino)) catch return -file.Errno.EIO;
        const n = self.readAt(inode, pos, buf) catch return -file.Errno.EIO;
        return @intCast(n);
    }

    fn fileWrite(ctx: ?*anyopaque, f: *file.File, bytes: []const u8, pos: u64) i64 {
        const self: *Ext4 = @ptrCast(@alignCast(ctx orelse return -file.Errno.EIO));
        const d = f.dentry orelse return -file.Errno.EIO;
        const vfs_ino = d.d_inode orelse return -file.Errno.EIO;
        if (vfs_ino.i_ino > std.math.maxInt(u32)) return -file.Errno.EIO;
        const inode = self.loadInode(@intCast(vfs_ino.i_ino)) catch return -file.Errno.EIO;
        if (!inode.isReg()) return -file.Errno.EINVAL;
        if (self.writeback == null) return -file.Errno.EROFS;
        const n = self.writeAt(inode, pos, bytes) catch |e| return switch (e) {
            error.ReadOnly => -file.Errno.EROFS,
            error.NoSpace => -file.Errno.ENOSPC,
            else => -file.Errno.EINVAL,
        };
        vfs_ino.i_size = inode.size; // inode i_size в VFS должен видеть рост файла
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

fn inodeOff(ino: u32) usize {
    return 5 * 1024 + (@as(usize, ino) - 1) * 256;
}

fn putInode(buf: []u8, ino: u32, mode: u32, size: u32, links: u32, blocks: u32, flags: u32) void {
    const off = inodeOff(ino);
    put16(buf, off, @truncate(mode));
    put32(buf, off + 4, size);
    put16(buf, off + 26, @truncate(links));
    put32(buf, off + 28, blocks);
    put32(buf, off + 32, flags);
}

fn putExtent(buf: []u8, ino: u32, physical: u32) void {
    const off = inodeOff(ino) + 40;
    put16(buf, off, EXT4_EXTENT_MAGIC); // eh_magic
    put16(buf, off + 2, 1); // eh_entries
    put16(buf, off + 4, 4); // eh_max
    put16(buf, off + 6, 0); // eh_depth
    put32(buf, off + 8, 0); // eh_generation
    put32(buf, off + 12, 0); // ee_block
    put16(buf, off + 16, 1); // ee_len
    put16(buf, off + 18, 0); // ee_start_hi
    put32(buf, off + 20, physical); // ee_start_lo
}

fn putDirEntry(buf: []u8, cursor: *usize, ino: u32, typ: u8, name: []const u8, rec_len: u16) void {
    const off = cursor.*;
    put32(buf, off, ino);
    put16(buf, off + 4, rec_len);
    buf[off + 6] = @intCast(name.len);
    buf[off + 7] = typ;
    @memcpy(buf[off + 8 ..][0..name.len], name);
    cursor.* += rec_len;
}

/// Синтетический ext4-образ: 1KiB блоки, одна группа, extents, два файла.
pub fn makeTestImage(allocator: std.mem.Allocator) ![]u8 {
    const image = try allocator.alloc(u8, 16 * 1024);
    errdefer allocator.free(image);
    @memset(image, 0);

    // struct ext4_super_block @1024.
    put32(image, 1024, 16); // s_inodes_count
    put32(image, 1024 + 4, 16); // s_blocks_count_lo
    put32(image, 1024 + 12, 5); // s_free_blocks_count_lo
    put32(image, 1024 + 16, 13); // s_free_inodes_count
    put32(image, 1024 + 20, 1); // s_first_data_block
    put32(image, 1024 + 24, 0); // s_log_block_size = 1 KiB
    put32(image, 1024 + 32, 16); // s_blocks_per_group
    put32(image, 1024 + 40, 16); // s_inodes_per_group
    put16(image, 1024 + 56, EXT4_MAGIC);
    put16(image, 1024 + 58, 1); // s_state = clean
    put32(image, 1024 + 76, 1); // s_rev_level = dynamic
    put32(image, 1024 + 84, 11); // s_first_ino
    put16(image, 1024 + 88, 256); // s_inode_size
    put32(image, 1024 + 96, EXT4_FEATURE_INCOMPAT_FILETYPE | EXT4_FEATURE_INCOMPAT_EXTENTS);
    put16(image, 1024 + 254, 32); // s_desc_size

    // ext4_group_desc в блоке 2.
    put32(image, 2048, 3); // bg_block_bitmap_lo
    put32(image, 2048 + 4, 4); // bg_inode_bitmap_lo
    put32(image, 2048 + 8, 5); // bg_inode_table_lo
    put16(image, 2048 + 12, 5); // bg_free_blocks_count_lo
    put16(image, 2048 + 14, 13); // bg_free_inodes_count_lo
    // Блоки 1..10 заняты: super/GDT/bitmap/inode table/root dir/data.
    for (0..10) |index| image[3 * 1024 + index / 8] |= @as(u8, 1) << @intCast(index % 8);
    // Иноды 1..12 заняты: зарезервированные, root, hello.txt и symlink.
    for (0..12) |index| image[4 * 1024 + index / 8] |= @as(u8, 1) << @intCast(index % 8);

    const data = "hello ext4\n";
    putInode(image, 2, vfs.S_IFDIR | 0o755, 1024, 2, 2, EXT4_EXTENTS_FL);
    putExtent(image, 2, 9); // root directory block
    putInode(image, 11, vfs.S_IFREG | 0o644, @truncate(data.len), 1, 2, EXT4_EXTENTS_FL);
    putExtent(image, 11, 10); // file data block
    const target = "hello.txt";
    putInode(image, 12, vfs.S_IFLNK | 0o777, @truncate(target.len), 1, 0, 0); // fast symlink
    @memcpy(image[inodeOff(12) + 40 ..][0..target.len], target);

    var cursor: usize = 9 * 1024;
    putDirEntry(image, &cursor, 2, 2, ".", 12);
    putDirEntry(image, &cursor, 2, 2, "..", 12);
    putDirEntry(image, &cursor, 11, 1, "hello.txt", 20);
    const dir_end = 10 * 1024;
    putDirEntry(image, &cursor, 12, 7, "link", @intCast(dir_end - cursor));
    @memcpy(image[10 * 1024 ..][0..data.len], data);
    return image;
}

/// Синтетический образ с запасом блоков для split корневого extent-дерева:
/// те же 10 занятых блоков, 53 свободных, файл hello.txt с одним extent-ом.
pub fn makeSplitTestImage(allocator: std.mem.Allocator) ![]u8 {
    const base = try makeTestImage(allocator);
    errdefer allocator.free(base);
    const image = try allocator.realloc(base, 64 * 1024);
    errdefer allocator.free(image);
    @memset(image[16 * 1024 ..], 0);
    put32(image, 1024 + 4, 64); // s_blocks_count_lo
    put32(image, 1024 + 32, 64); // s_blocks_per_group: одна группа
    put32(image, 1024 + 12, 53); // s_free_blocks_count_lo
    put16(image, 2048 + 12, 53); // bg_free_blocks_count_lo
    return image;
}

/// Синтетический образ с полным depth 1: корень inode 11 содержит четыре
/// индекса, каждый ведёт в leaf на 339 extent-ов. Блоки данных и метаданных
/// отмечены в bitmap, счётчики согласованы с e2fsck. Одна запись в EOF
/// переполняет последний leaf и корень, поднимая дерево до depth 2.
pub fn makeDepthOneFullTestImage(allocator: std.mem.Allocator) ![]u8 {
    const base = try makeSplitTestImage(allocator);
    errdefer allocator.free(base);
    const block_size: usize = 1024;
    const blocks: usize = 4096;
    const image = try allocator.realloc(base, blocks * block_size);
    errdefer allocator.free(image);
    @memset(image[64 * 1024 ..], 0);

    const leaf_count: usize = 4;
    const leaf_max: usize = (block_size - 12) / 12;
    const extent_count = leaf_count * leaf_max;
    const leaf_base: usize = 10;
    const data_base = leaf_base + leaf_count;
    const last_used = data_base + extent_count - 1; // 1369
    const free_blocks: usize = blocks - 1 - last_used; // блок 0 вне данных

    const sb = 1024;
    put32(image, sb + 4, @intCast(blocks));
    put32(image, sb + 12, @intCast(free_blocks));
    put32(image, sb + 16, 4); // inodes 1..12 заняты
    put32(image, sb + 32, @intCast(blocks));
    put32(image, sb + 36, @intCast(blocks)); // s_clusters_per_group
    put16(image, 2048 + 12, @intCast(free_blocks));
    put16(image, 2048 + 14, 4);
    put16(image, 2048 + 16, 1); // bg_used_dirs_count

    for (1..last_used + 1) |physical| {
        const bit = physical - 1;
        image[3 * block_size + bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
    }
    // e2fsck требует, чтобы неиспользуемые биты карт были установлены.
    for (16..block_size * 8) |index| image[4 * block_size + index / 8] |= @as(u8, 1) << @intCast(index % 8);
    // Первый блок группы — физический блок 1, поэтому бит 4095 уже padding.
    for (blocks - 1..block_size * 8) |index| image[3 * block_size + index / 8] |= @as(u8, 1) << @intCast(index % 8);

    const root = image[inodeOff(11) + 40 ..][0..60];
    put16(root, 0, EXT4_EXTENT_MAGIC);
    put16(root, 2, leaf_count);
    put16(root, 4, 4);
    put16(root, 6, 1);
    put32(root, 8, 0);
    const off = inodeOff(11);
    put32(image, off + 4, @intCast(extent_count * block_size));
    put32(image, off + 28, @intCast((extent_count + leaf_count) * 2));

    for (0..leaf_count) |leaf| {
        const physical = leaf_base + leaf;
        const hdr = image[physical * block_size ..][0..block_size];
        @memset(hdr, 0);
        put16(hdr, 0, EXT4_EXTENT_MAGIC);
        put16(hdr, 2, leaf_max);
        put16(hdr, 4, leaf_max);
        put16(hdr, 6, 0);
        put32(hdr, 8, 0);
        for (0..leaf_max) |slot| {
            const entry = 12 + slot * 12;
            put32(hdr, entry, @intCast(leaf * leaf_max + slot));
            put16(hdr, entry + 4, 1);
            put16(hdr, entry + 6, 0);
            put32(hdr, entry + 8, @intCast(data_base + leaf * leaf_max + slot));
        }
        const idx = 12 + leaf * 12;
        put32(root, idx, @intCast(leaf * leaf_max));
        put32(root, idx + 4, @intCast(physical));
        put16(root, idx + 8, 0);
        put16(root, idx + 10, 0);
    }
    return image;
}

/// Синтетический образ с внутренним JBD2-журналом: inode 8, 16 блоков,
/// 32-битные теги без контрольных сумм. Блоки 12..27 отведены под журнал.
fn makeJournalTestImage(allocator: std.mem.Allocator) ![]u8 {
    const base = try makeTestImage(allocator);
    errdefer allocator.free(base);
    const image = try allocator.realloc(base, 32 * 1024);
    errdefer allocator.free(image);
    @memset(image[16 * 1024 ..], 0);

    const sb = 1024;
    put32(image, sb + 4, 32); // s_blocks_count_lo
    put32(image, sb + 92, (try rd32(image, sb + 92)) | EXT4_FEATURE_COMPAT_HAS_JOURNAL);
    put32(image, sb + 224, 8); // s_journal_inum
    var physical: usize = 12;
    while (physical < 28) : (physical += 1) {
        const bit = physical - 1;
        image[3 * 1024 + bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
    }

    putInode(image, 8, vfs.S_IFREG | 0o600, 16 * 1024, 1, 32, EXT4_EXTENTS_FL);
    const ext = inodeOff(8) + 40;
    put16(image, ext, EXT4_EXTENT_MAGIC);
    put16(image, ext + 2, 1); // eh_entries
    put16(image, ext + 4, 4); // eh_max
    put16(image, ext + 6, 0); // eh_depth
    put32(image, ext + 12, 0); // ee_block
    put16(image, ext + 16, 16); // ee_len
    put32(image, ext + 20, 12); // physical block 12

    const jsb = image[12 * 1024 ..][0..1024];
    @memset(jsb, 0);
    put32be(jsb, 0, JBD2_MAGIC_NUMBER);
    put32be(jsb, 4, JBD2_SUPERBLOCK_V2);
    put32be(jsb, 8, 1); // h_sequence
    put32be(jsb, 12, 1024);
    put32be(jsb, 16, 16); // s_maxlen
    put32be(jsb, 20, 1); // s_first
    put32be(jsb, 24, 1); // s_sequence
    put32be(jsb, 28, 0); // s_start: clean
    @memcpy(jsb[0x30..][0..16], image[sb + 0x68 ..][0..16]);
    put32be(jsb, 0x40, 1); // s_nr_users
    return image;
}

/// Тот же журнал, но с сразу включёнными возможностями JBD2 и корректным
/// checksum суперблока — используется для recovery-тестов с RECOVER.
fn makeAdvancedJournalTestImage(allocator: std.mem.Allocator, features: u32) ![]u8 {
    const image = try makeJournalTestImage(allocator);
    const jsb = image[12 * 1024 ..][0..1024];
    put32be(jsb, 0x28, features);
    @memcpy(jsb[0x30..][0..16], image[1024 + 0x68 ..][0..16]);
    if (features & (JBD2_FEATURE_INCOMPAT_CSUM_V2 | JBD2_FEATURE_INCOMPAT_CSUM_V3) != 0) {
        jsb[0x50] = JBD2_CRC32C_CHKSUM;
        put32be(jsb, JBD2_SUPERBLOCK_CSUM_OFF, journalSuperCsum(jsb));
    }
    return image;
}

test "ext4 reader: extents, namei, readlink and statfs through mount namespace" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 64);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 64);
    defer ext_sb.deinit();

    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");
    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, null);
    defer ext.deinit();

    // super_operations: statfs() читает поля настоящего ext4 superblock.
    const st = ext_sb.statfs();
    try std.testing.expectEqual(@as(u64, EXT4_MAGIC), st.magic);
    try std.testing.expectEqual(@as(u64, 1024), st.bsize);
    try std.testing.expectEqual(@as(u64, 16), st.blocks);
    try std.testing.expectEqual(@as(u64, 5), st.bfree);
    try std.testing.expectEqual(@as(u64, 16), st.files);
    try std.testing.expectEqual(@as(u64, 13), st.ffree);
    ext_sb.syncFs(); // без writeback: грязных блоков нет

    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    try std.testing.expectEqual(&ext_sb, d.d_sb);
    try std.testing.expectEqual(@as(u64, 11), d.d_inode.?.i_ino);
    const f = ext.fileFor(d) orelse try ext.open(d);
    var buf: [32]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 11), f.read(&buf));
    try std.testing.expectEqualStrings("hello ext4\n", buf[0..11]);
    try std.testing.expectEqual(@as(i64, 0), f.llseek(0, file.SEEK_SET));
    try std.testing.expectEqual(@as(i64, 5), f.read(buf[0..5]));
    try std.testing.expectEqualStrings("hello", buf[0..5]);

    // symlink: follow_final разыменовывает 'hello.txt' от корня ext4.
    const followed = try ns.lookupPath("/mnt/link");
    defer followed.d_sb.dPut(followed);
    try std.testing.expectEqual(@as(u64, 11), followed.d_inode.?.i_ino);

    const link = try ns.lookupPathNoFollow("/mnt/link");
    defer link.d_sb.dPut(link);
    try std.testing.expect(link.d_inode.?.isLink());
    try std.testing.expectEqualStrings("hello.txt", link.d_inode.?.i_link.?);

    try std.testing.expectError(error.NoEnt, ns.lookupPath("/mnt/missing"));
    try std.testing.expectError(error.NotDir, ns.lookupPath("/mnt/hello.txt/child"));
}

test "ext4 write: in-place extent overwrite and syncFs writeback" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    const wb: Writeback = .{ .ctx = &ctx, .write = Ctx.write };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, wb);
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, 11), f.write("EXT4 WRITE\n"));
    try std.testing.expectEqual(@as(usize, 1), ext.dirtyBlocks());
    try std.testing.expectEqualStrings("hello ext4\n", storage[10 * 1024 ..][0..11]);

    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 1), ext.syncedBlocks());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqualStrings("EXT4 WRITE\n", storage[10 * 1024 ..][0..11]);

    try std.testing.expectEqual(@as(i64, 0), f.llseek(0, file.SEEK_SET));
    var buf: [16]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 11), f.read(&buf));
    try std.testing.expectEqualStrings("EXT4 WRITE\n", buf[0..11]);
}

test "ext4 write: read-only mounts and overflowing offsets are rejected" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, null);
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, -file.Errno.EROFS), f.write("DATA"));

    ext.writeback = .{ .ctx = &sink, .write = Sink.write };
    try std.testing.expectEqual(@as(i64, -file.Errno.EINVAL), f.writeAt("X", std.math.maxInt(u64)));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
}

test "ext4 grow: append allocates blocks and flushes data plus metadata" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &ctx, .write = Ctx.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, 11), f.llseek(0, file.SEEK_END));

    var payload: [2050]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), f.write(&payload));
    try std.testing.expectEqual(@as(u64, 2061), d.d_inode.?.i_size);
    try std.testing.expectEqual(@as(i64, 2061), f.llseek(0, file.SEEK_END));
    try std.testing.expectEqual(@as(usize, 7), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u8, 0), storage[11 * 1024]);

    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 7), ext.syncedBlocks());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    // superblock, group descriptor и bitmap согласованы с новыми extent-ами.
    try std.testing.expectEqual(@as(u32, 3), rd32(storage, 1024 + 12) catch unreachable);
    try std.testing.expectEqual(@as(u16, 3), rd16(storage, 2048 + 12) catch unreachable);
    try std.testing.expect(storage[3 * 1024 + 1] & 0x04 != 0); // block 11
    try std.testing.expect(storage[3 * 1024 + 1] & 0x08 != 0); // block 12

    const off = inodeOff(11);
    try std.testing.expectEqual(@as(u32, 2061), rd32(storage, off + 4) catch unreachable);
    try std.testing.expectEqual(@as(u32, 6), rd32(storage, off + 28) catch unreachable);
    const hdr = storage[off + 40 ..][0..60];
    try std.testing.expectEqual(@as(u16, 3), rd16(hdr, 2) catch unreachable);
    try std.testing.expectEqual(@as(u32, 10), rd32(hdr[12..][0..12], 8) catch unreachable);
    try std.testing.expectEqual(@as(u32, 11), rd32(hdr[24..][0..12], 8) catch unreachable);
    try std.testing.expectEqual(@as(u32, 1), rd32(hdr[24..][0..12], 0) catch unreachable);
    try std.testing.expectEqual(@as(u32, 12), rd32(hdr[36..][0..12], 8) catch unreachable);
    try std.testing.expectEqual(@as(u32, 2), rd32(hdr[36..][0..12], 0) catch unreachable);

    try std.testing.expectEqual(@as(u64, 3), ext_sb.statfs().bfree);
    try std.testing.expectEqual(@as(i64, 0), f.llseek(0, file.SEEK_SET));
    const buf = try a.alloc(u8, 2061);
    defer a.free(buf);
    try std.testing.expectEqual(@as(i64, 2061), f.read(buf));
    try std.testing.expectEqualStrings("hello ext4\n", buf[0..11]);
    try std.testing.expectEqualSlices(u8, &payload, buf[11..]);
}

test "ext4 grow: no free blocks and checksum metadata are rejected" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    put32(image, 1024 + 12, 0); // s_free_blocks_count_lo
    put16(image, 2048 + 12, 0); // bg_free_blocks_count_lo

    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &sink, .write = Sink.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, 11), f.llseek(0, file.SEEK_END));
    try std.testing.expectEqual(@as(i64, -file.Errno.ENOSPC), f.write(&@as([1100]u8, @splat('X'))));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    ext.feature_ro_compat = EXT4_FEATURE_RO_COMPAT_METADATA_CSUM;
    try std.testing.expectEqual(@as(i64, -file.Errno.EINVAL), f.write(&@as([1100]u8, @splat('X'))));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
}

test "ext4 namei: creat writes a persistent inode, unlink removes it" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var disk1 = block.MemoryDisk{ .data = storage };
    var ctx1 = Ctx{ .dev = disk1.device() };
    var disk2 = block.MemoryDisk{ .data = storage };
    var ctx2 = Ctx{ .dev = disk2.device() };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &ctx1, .write = Ctx.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.createAt("/mnt/new.txt");
    defer d.d_sb.dPut(d);
    const f = try ext.open(d);
    try std.testing.expectEqual(@as(i64, 8), f.write("PERSIST\n"));
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    // bitmap/superblock/group descriptor согласованы с новым inode 13.
    try std.testing.expect(storage[4 * 1024 + 1] & 0x10 != 0);
    try std.testing.expect(storage[3 * 1024 + 1] & 0x04 != 0);
    try std.testing.expectEqual(@as(u32, 12), rd32(storage, 1024 + 16) catch unreachable);
    try std.testing.expectEqual(@as(u16, 12), rd16(storage, 2048 + 14) catch unreachable);
    try std.testing.expectEqual(@as(u64, 4), ext_sb.statfs().bfree);

    // Новый mount видит файл только через записанный на диск dir_entry_2/inode.
    var root2_sb: vfs.SuperBlock = undefined;
    try root2_sb.init(a, 32);
    defer root2_sb.deinit();
    var ext2_sb: vfs.SuperBlock = undefined;
    try ext2_sb.init(a, 32);
    defer ext2_sb.deinit();
    var root2 = ramfs.RamFs.init(a, &root2_sb);
    defer root2.deinit();
    try root2.mkdir("/mnt");
    var ext2: Ext4 = undefined;
    try ext2.init(a, storage, &ext2_sb, .{ .ctx = &ctx2, .write = Ctx.write });
    defer ext2.deinit();
    var ns2: vfs.Namespace = undefined;
    try ns2.init(a, &root2_sb, root2.ops());
    defer ns2.deinit();
    _ = try ns2.mount(&ext2_sb, ext2.ops(), "/mnt");

    const d2 = try ns2.lookupPath("/mnt/new.txt");
    defer d2.d_sb.dPut(d2);
    try std.testing.expectEqual(@as(u64, 13), d2.d_inode.?.i_ino);
    const f2 = try ext2.open(d2);
    var buf: [8]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 8), f2.read(&buf));
    try std.testing.expectEqualStrings("PERSIST\n", &buf);

    try ns2.unlinkAt("/mnt/new.txt");
    ext2_sb.syncFs();
    try std.testing.expect(!ext2.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext2.dirtyBlocks());
    try std.testing.expectError(error.NoEnt, ns2.lookupPath("/mnt/new.txt"));
    try std.testing.expectEqual(@as(u64, 13), ext2_sb.statfs().ffree);
    try std.testing.expectEqual(@as(u64, 5), ext2_sb.statfs().bfree);
    try std.testing.expect(storage[4 * 1024 + 1] & 0x10 == 0);
    try std.testing.expect(storage[3 * 1024 + 1] & 0x04 == 0);
    try std.testing.expectEqual(@as(u32, 0), rd32(storage, 9 * 1024 + 60) catch unreachable);
}

test "ext4 namei: no free inodes and checksum metadata reject creat" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    put32(image, 1024 + 16, 0);
    put16(image, 2048 + 14, 0);

    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &sink, .write = Sink.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    try std.testing.expectError(error.NoSpace, ns.createAt("/mnt/new.txt"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    ext.feature_ro_compat = EXT4_FEATURE_RO_COMPAT_METADATA_CSUM;
    try std.testing.expectError(error.NotSupported, ns.createAt("/mnt/new.txt"));
    try std.testing.expectError(error.NoEnt, ns.unlinkAt("/mnt/ghost.txt"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
}

test "ext4 mkdir: persistent subdirectory with nested file and directory counters" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var disk1 = block.MemoryDisk{ .data = storage };
    var ctx1 = Ctx{ .dev = disk1.device() };
    var disk2 = block.MemoryDisk{ .data = storage };
    var ctx2 = Ctx{ .dev = disk2.device() };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &ctx1, .write = Ctx.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const dd = try ns.mkdirAt("/mnt/sub");
    defer dd.d_sb.dPut(dd);
    const info = dd.d_inode.?;
    try std.testing.expectEqual(@as(u64, 13), info.i_ino);
    try std.testing.expect(info.i_mode & 0o170000 == vfs.S_IFDIR);
    try std.testing.expectEqual(@as(u64, 1024), info.i_size);
    try std.testing.expectEqual(@as(u16, 2), rd16(image, inodeOff(13) + 26) catch unreachable);

    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    // root: ссылка из ".." нового каталога; used_dirs + 1.
    try std.testing.expectEqual(@as(u16, 3), rd16(storage, inodeOff(2) + 26) catch unreachable);
    try std.testing.expectEqual(@as(u16, 1), rd16(storage, 2048 + 16) catch unreachable);
    try std.testing.expectEqual(@as(u32, 4), rd32(storage, 1024 + 12) catch unreachable);
    try std.testing.expectEqual(@as(u32, 12), rd32(storage, 1024 + 16) catch unreachable);
    try std.testing.expectEqual(@as(u16, 4), rd16(storage, 2048 + 12) catch unreachable);
    try std.testing.expectEqual(@as(u16, 12), rd16(storage, 2048 + 14) catch unreachable);

    // Новый dir block: ".", ".." и свободный хвост до конца блока.
    const dir_block: usize = 11 * 1024;
    try std.testing.expectEqual(@as(u32, 13), rd32(storage, dir_block) catch unreachable);
    try std.testing.expectEqual(@as(u16, 12), rd16(storage, dir_block + 4) catch unreachable);
    try std.testing.expectEqual(@as(u8, 2), storage[dir_block + 7]);
    try std.testing.expectEqualStrings(".", storage[dir_block + 8 .. dir_block + 9]);
    try std.testing.expectEqual(@as(u32, 2), rd32(storage, dir_block + 12) catch unreachable);
    try std.testing.expectEqual(@as(u8, 2), storage[dir_block + 19]);
    try std.testing.expectEqualStrings("..", storage[dir_block + 20 .. dir_block + 22]);
    try std.testing.expectEqual(@as(u32, 0), rd32(storage, dir_block + 24) catch unreachable);
    try std.testing.expectEqual(@as(u16, 1000), rd16(storage, dir_block + 28) catch unreachable);

    const d = try ns.createAt("/mnt/sub/new.txt");
    const f = try ext.open(d);
    try std.testing.expectEqual(@as(i64, 7), f.write("NESTED\n"));
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    // Свежий mount видит каталог и файл внутри него только через диск.
    var root2_sb: vfs.SuperBlock = undefined;
    try root2_sb.init(a, 32);
    defer root2_sb.deinit();
    var ext2_sb: vfs.SuperBlock = undefined;
    try ext2_sb.init(a, 32);
    defer ext2_sb.deinit();
    var root2 = ramfs.RamFs.init(a, &root2_sb);
    defer root2.deinit();
    try root2.mkdir("/mnt");
    var ext2: Ext4 = undefined;
    try ext2.init(a, storage, &ext2_sb, .{ .ctx = &ctx2, .write = Ctx.write });
    defer ext2.deinit();
    var ns2: vfs.Namespace = undefined;
    try ns2.init(a, &root2_sb, root2.ops());
    defer ns2.deinit();
    _ = try ns2.mount(&ext2_sb, ext2.ops(), "/mnt");

    const sub = try ns2.lookupPath("/mnt/sub");
    defer sub.d_sb.dPut(sub);
    try std.testing.expectEqual(@as(u64, 13), sub.d_inode.?.i_ino);
    try std.testing.expect(sub.d_inode.?.isDir());
    try std.testing.expectEqual(@as(u64, 1024), sub.d_inode.?.i_size);
    try std.testing.expectEqual(@as(u16, 2), rd16(storage, inodeOff(13) + 26) catch unreachable);

    const nested = try ns2.lookupPath("/mnt/sub/new.txt");
    defer nested.d_sb.dPut(nested);
    try std.testing.expectEqual(@as(u64, 14), nested.d_inode.?.i_ino);
    const f2 = try ext2.open(nested);
    var buf: [7]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 7), f2.read(&buf));
    try std.testing.expectEqualStrings("NESTED\n", &buf);

    try ns2.unlinkAt("/mnt/sub/new.txt");
    ext2_sb.syncFs();
    try std.testing.expect(!ext2.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext2.dirtyBlocks());
    try std.testing.expectError(error.NoEnt, ns2.lookupPath("/mnt/sub/new.txt"));
    try std.testing.expectEqual(@as(u64, 12), ext2_sb.statfs().ffree);
    try std.testing.expectEqual(@as(u64, 4), ext2_sb.statfs().bfree);
    try std.testing.expectEqual(@as(u32, 13), rd32(storage, dir_block) catch unreachable);

    // mkdir внутри подкаталога: родитель /mnt/sub получает ссылку и used_dirs.
    const inner = try ns2.mkdirAt("/mnt/sub/inner");
    defer inner.d_sb.dPut(inner);
    try std.testing.expectEqual(@as(u64, 14), inner.d_inode.?.i_ino);
    ext2_sb.syncFs();
    try std.testing.expect(!ext2.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext2.dirtyBlocks());
    try std.testing.expectEqual(@as(u16, 3), rd16(storage, inodeOff(13) + 26) catch unreachable);
    try std.testing.expectEqual(@as(u16, 2), rd16(storage, 2048 + 16) catch unreachable);
    try std.testing.expectEqual(@as(u64, 11), ext2_sb.statfs().ffree);
    try std.testing.expectEqual(@as(u64, 3), ext2_sb.statfs().bfree);
    const inner_block: usize = 12 * 1024;
    try std.testing.expectEqual(@as(u32, 14), rd32(storage, inner_block) catch unreachable);
    try std.testing.expectEqual(@as(u32, 13), rd32(storage, inner_block + 12) catch unreachable);
    const again = try ns2.lookupPath("/mnt/sub/inner");
    defer again.d_sb.dPut(again);
    try std.testing.expectEqual(@as(u64, 14), again.d_inode.?.i_ino);
    try std.testing.expect(again.d_inode.?.isDir());
}

test "ext4 mkdir: duplicate, non-directory and unsupported metadata are rejected" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);

    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &sink, .write = Sink.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    try std.testing.expectError(error.PathExists, ns.mkdirAt("/mnt/hello.txt"));
    try std.testing.expectError(error.NotDir, ns.mkdirAt("/mnt/hello.txt/sub"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    ext.feature_ro_compat = EXT4_FEATURE_RO_COMPAT_METADATA_CSUM;
    try std.testing.expectError(error.NotSupported, ns.mkdirAt("/mnt/fresh"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    ext.feature_ro_compat = 0;
    ext.meta.free_blocks = 0;
    ext.groups[0].free_blocks = 0;
    try std.testing.expectError(error.NoSpace, ns.mkdirAt("/mnt/fresh"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
}

test "ext4 rmdir: empty subdirectory removal restores links, bitmaps and counters" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var disk1 = block.MemoryDisk{ .data = storage };
    var ctx1 = Ctx{ .dev = disk1.device() };
    var disk2 = block.MemoryDisk{ .data = storage };
    var ctx2 = Ctx{ .dev = disk2.device() };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &ctx1, .write = Ctx.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const dd = try ns.mkdirAt("/mnt/sub");
    defer dd.d_sb.dPut(dd);
    try std.testing.expectEqual(@as(u64, 13), dd.d_inode.?.i_ino);
    const d = try ns.createAt("/mnt/sub/new.txt");
    defer d.d_sb.dPut(d);
    const f = try ext.open(d);
    try std.testing.expectEqual(@as(i64, 2), f.write("A\n"));
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    try ns.unlinkAt("/mnt/sub/new.txt");
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(u64, 4), ext_sb.statfs().bfree);

    try ns.rmdirAt("/mnt/sub");
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u64, 13), ext_sb.statfs().ffree);
    try std.testing.expectEqual(@as(u64, 5), ext_sb.statfs().bfree);
    try std.testing.expectEqual(@as(u16, 2), rd16(storage, inodeOff(2) + 26) catch unreachable);
    try std.testing.expectEqual(@as(u16, 0), rd16(storage, 2048 + 16) catch unreachable);
    try std.testing.expectEqual(@as(u32, 0), rd32(storage, inodeOff(13)) catch unreachable);
    try std.testing.expectEqual(@as(u8, 0), storage[4 * 1024 + 1] & (@as(u8, 1) << 4));
    try std.testing.expectEqual(@as(u8, 0), storage[3 * 1024 + 1] & (@as(u8, 1) << 2));
    try std.testing.expectError(error.NoEnt, ns.lookupPath("/mnt/sub"));
    try std.testing.expectEqual(@as(u32, 0), rd32(storage, 9 * 1024 + 68) catch unreachable);
    try std.testing.expectEqual(@as(u8, 0), storage[9 * 1024 + 74]);

    // Свежий mount видит только disperse на диске: имя удалено, inode и блок
    // снова доступны для следующего mkdir.
    var root2_sb: vfs.SuperBlock = undefined;
    try root2_sb.init(a, 32);
    defer root2_sb.deinit();
    var ext2_sb: vfs.SuperBlock = undefined;
    try ext2_sb.init(a, 32);
    defer ext2_sb.deinit();
    var root2 = ramfs.RamFs.init(a, &root2_sb);
    defer root2.deinit();
    try root2.mkdir("/mnt");
    var ext2: Ext4 = undefined;
    try ext2.init(a, storage, &ext2_sb, .{ .ctx = &ctx2, .write = Ctx.write });
    defer ext2.deinit();
    var ns2: vfs.Namespace = undefined;
    try ns2.init(a, &root2_sb, root2.ops());
    defer ns2.deinit();
    _ = try ns2.mount(&ext2_sb, ext2.ops(), "/mnt");

    try std.testing.expectError(error.NoEnt, ns2.lookupPath("/mnt/sub"));
    const reused = try ns2.mkdirAt("/mnt/again");
    defer reused.d_sb.dPut(reused);
    try std.testing.expectEqual(@as(u64, 13), reused.d_inode.?.i_ino);
    try std.testing.expect(reused.d_inode.?.isDir());
    ext2_sb.syncFs();
    try std.testing.expect(!ext2.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext2.dirtyBlocks());
}

test "ext4 rmdir: rejects regular files, nonempty directories and unsupported metadata" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeTestImage(a);
    defer a.free(image);

    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &sink, .write = Sink.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const dd = try ns.mkdirAt("/mnt/sub");
    defer dd.d_sb.dPut(dd);
    const d = try ns.createAt("/mnt/sub/file.txt");
    defer d.d_sb.dPut(d);
    const f = try ext.open(d);
    try std.testing.expectEqual(@as(i64, 1), f.write("x"));
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    try std.testing.expectError(error.NotEmpty, ns.rmdirAt("/mnt/sub"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try ns.unlinkAt("/mnt/sub/file.txt");
    ext_sb.syncFs();
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());

    ext.feature_ro_compat = EXT4_FEATURE_RO_COMPAT_METADATA_CSUM;
    try std.testing.expectError(error.NotSupported, ns.rmdirAt("/mnt/sub"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    ext.feature_ro_compat = 0;

    try std.testing.expectError(error.NotDir, ns.rmdirAt("/mnt/hello.txt"));
    try std.testing.expectError(error.NoEnt, ns.rmdirAt("/mnt/absent"));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u16, 3), rd16(image, inodeOff(2) + 26) catch unreachable);
    try std.testing.expectEqual(@as(u16, 1), rd16(image, 2048 + 16) catch unreachable);
}

test "ext4 journal: sync commits JBD2 transaction and clears recovery flag" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeJournalTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    const wb: Writeback = .{ .ctx = &ctx, .write = Ctx.write };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, wb);
    defer ext.deinit();
    try std.testing.expect(ext.journalActive());
    try std.testing.expectEqual(@as(usize, 0), ext.journalCommits());
    try std.testing.expectEqual(@as(u32, 0), ext.journalStart());

    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, 0), f.llseek(0, file.SEEK_SET));
    const payload = "journaled!";
    try std.testing.expectEqual(@as(i64, payload.len), f.write(payload));
    try std.testing.expect(ext.dirtyBlocks() > 0);

    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expect(ext.syncedBlocks() > ext.dirtyBlocks() + 1);
    try std.testing.expectEqual(@as(usize, 1), ext.journalCommits());
    try std.testing.expectEqual(@as(u32, 0), ext.journalStart());
    try std.testing.expectEqual(@as(u32, 0), rd32(image, 1024 + 96) catch unreachable & EXT4_FEATURE_INCOMPAT_RECOVER);
    try std.testing.expectEqual(JBD2_MAGIC_NUMBER, rd32be(image, 12 * 1024) catch unreachable);
    try std.testing.expectEqual(JBD2_SUPERBLOCK_V2, rd32be(image, 12 * 1024 + 4) catch unreachable);
    try std.testing.expectEqual(@as(u32, 0), rd32be(image, 12 * 1024 + 28) catch unreachable);
    try std.testing.expectEqual(@as(u32, 2), rd32be(image, 12 * 1024 + 8) catch unreachable);

    // Дескриптор, данные и commit block остаются в journal inode как след
    // выполненной транзакции; s_start==0 означает чистый журнал.
    const desc = image[13 * 1024 ..][0..1024];
    try std.testing.expectEqual(JBD2_MAGIC_NUMBER, rd32be(desc, 0) catch unreachable);
    try std.testing.expectEqual(JBD2_DESCRIPTOR_BLOCK, rd32be(desc, 4) catch unreachable);
    var cursor: usize = 12;
    var tags: usize = 0;
    var last = false;
    while (cursor + 8 <= desc.len) {
        const flags = rd16be(desc, cursor + 6) catch unreachable;
        tags += 1;
        cursor += 8;
        if (flags & JBD2_FLAG_SAME_UUID == 0) cursor += 16;
        if (flags & JBD2_FLAG_LAST_TAG != 0) {
            last = true;
            break;
        }
    }
    try std.testing.expect(last);
    try std.testing.expect(tags > 0);
    const commit = image[(14 + tags) * 1024 ..][0..1024];
    try std.testing.expectEqual(JBD2_MAGIC_NUMBER, rd32be(commit, 0) catch unreachable);
    try std.testing.expectEqual(JBD2_COMMIT_BLOCK, rd32be(commit, 4) catch unreachable);
    try std.testing.expectEqual(@as(u32, 1), rd32be(commit, 8) catch unreachable);

    try std.testing.expect(std.mem.eql(u8, storage[10 * 1024 ..][0..payload.len], payload));
    try std.testing.expect(std.mem.eql(u8, image[10 * 1024 ..][0..payload.len], payload));
    try std.testing.expectEqual(@as(i64, 0), f.llseek(0, file.SEEK_SET));
    var buf: [32]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, payload.len), f.read(buf[0..payload.len]));
    try std.testing.expectEqualStrings(payload, buf[0..payload.len]);
}

test "ext4 journal: recovery replays committed transaction and clears RECOVER" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeJournalTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);

    // Один закоммиченный transaction: дескриптор → данные → commit block.
    const jsb = image[12 * 1024 ..][0..1024];
    put32be(jsb, 8, 1);
    put32be(jsb, 24, 1);
    put32be(jsb, 28, 1); // s_start: журнал требует recovery

    const desc = image[13 * 1024 ..][0..1024];
    @memset(desc, 0);
    put32be(desc, 0, JBD2_MAGIC_NUMBER);
    put32be(desc, 4, JBD2_DESCRIPTOR_BLOCK);
    put32be(desc, 8, 1);
    put32be(desc, 12, 10); // целевой физический блок данных
    put16be(desc, 18, JBD2_FLAG_LAST_TAG);

    const recovered = "recovered!";
    const data = image[14 * 1024 ..][0..1024];
    @memset(data, 0);
    @memcpy(data[0..recovered.len], recovered);

    const commit = image[15 * 1024 ..][0..1024];
    @memset(commit, 0);
    put32be(commit, 0, JBD2_MAGIC_NUMBER);
    put32be(commit, 4, JBD2_COMMIT_BLOCK);
    put32be(commit, 8, 1);

    put32(image, 1024 + 96, EXT4_FEATURE_INCOMPAT_FILETYPE | EXT4_FEATURE_INCOMPAT_EXTENTS | EXT4_FEATURE_INCOMPAT_RECOVER);
    @memcpy(image[10 * 1024 ..][0..11], "hello ext4\n");
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    const wb: Writeback = .{ .ctx = &ctx, .write = Ctx.write };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, wb);
    defer ext.deinit();
    try std.testing.expect(ext.journalActive());
    try std.testing.expectEqual(@as(usize, 1), ext.journalReplays());
    try std.testing.expectEqual(@as(usize, 1), ext.journalCommits());
    try std.testing.expectEqual(@as(u32, 0), ext.journalStart());
    try std.testing.expectEqual(@as(u32, 0), rd32(image, 1024 + 96) catch unreachable & EXT4_FEATURE_INCOMPAT_RECOVER);
    try std.testing.expectEqual(@as(u32, 0), rd32be(image, 12 * 1024 + 28) catch unreachable);
    try std.testing.expectEqual(@as(u32, 2), rd32be(image, 12 * 1024 + 8) catch unreachable);
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expect(std.mem.eql(u8, image[10 * 1024 ..][0..recovered.len], recovered));
    try std.testing.expect(std.mem.eql(u8, storage[10 * 1024 ..][0..recovered.len], recovered));

    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");
    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    var buf: [32]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, recovered.len), f.read(buf[0..recovered.len]));
    try std.testing.expectEqualStrings(recovered, buf[0..recovered.len]);
}

test "ext4 split: full root splits to depth 1, persists and accepts leaf appends" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeSplitTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &ctx, .write = Ctx.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    var payload: [5 * 1024]u8 = undefined;
    for (&payload, 0..) |*b, i| b.* = @intCast('A' + (i % 26));
    try std.testing.expectEqual(@as(i64, 11), f.llseek(0, file.SEEK_END));
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), f.write(&payload));
    try std.testing.expectEqual(@as(u64, 5131), d.d_inode.?.i_size);
    try std.testing.expectEqual(@as(u16, 1), ext.extentDepth(11));
    try std.testing.expectEqual(@as(usize, 11), ext.dirtyBlocks()); // 6 data + leaf + inode + bitmap + gd + sb

    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 11), ext.syncedBlocks());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u64, 47), ext_sb.statfs().bfree);

    const root_hdr = storage[inodeOff(11) + 40 ..][0..60];
    try std.testing.expectEqual(@as(u16, EXT4_EXTENT_MAGIC), rd16(root_hdr, 0) catch unreachable);
    try std.testing.expectEqual(@as(u16, 1), rd16(root_hdr, 2) catch unreachable);
    try std.testing.expectEqual(@as(u16, 4), rd16(root_hdr, 4) catch unreachable);
    try std.testing.expectEqual(@as(u16, 1), rd16(root_hdr, 6) catch unreachable);
    const idx = root_hdr[12..][0..12];
    try std.testing.expectEqual(@as(u32, 0), rd32(idx, 0) catch unreachable);
    try std.testing.expectEqual(@as(u32, 15), rd32(idx, 4) catch unreachable);
    try std.testing.expectEqual(@as(u16, 0), rd16(idx, 8) catch unreachable);
    try std.testing.expectEqual(@as(u16, 0), rd16(idx, 10) catch unreachable);

    const leaf = storage[15 * 1024 ..][0..1024];
    try std.testing.expectEqual(@as(u16, EXT4_EXTENT_MAGIC), rd16(leaf, 0) catch unreachable);
    try std.testing.expectEqual(@as(u16, 6), rd16(leaf, 2) catch unreachable);
    try std.testing.expectEqual(@as(u16, 84), rd16(leaf, 4) catch unreachable);
    try std.testing.expectEqual(@as(u16, 0), rd16(leaf, 6) catch unreachable);
    const physicals = [_]u32{ 10, 11, 12, 13, 14, 16 };
    for (physicals, 0..) |physical, i| {
        const e = leaf[12 + i * 12 ..][0..12];
        try std.testing.expectEqual(@as(u32, @intCast(i)), rd32(e, 0) catch unreachable);
        try std.testing.expectEqual(@as(u16, 1), rd16(e, 4) catch unreachable);
        try std.testing.expectEqual(@as(u16, 0), rd16(e, 6) catch unreachable);
        try std.testing.expectEqual(physical, rd32(e, 8) catch unreachable);
    }
    try std.testing.expectEqual(@as(u32, 14), rd32(storage, inodeOff(11) + 28) catch unreachable);

    // Свежий mount читает через индексный блок, а не через кэш исходного FS.
    var root2_sb: vfs.SuperBlock = undefined;
    try root2_sb.init(a, 32);
    defer root2_sb.deinit();
    var ext2_sb: vfs.SuperBlock = undefined;
    try ext2_sb.init(a, 32);
    defer ext2_sb.deinit();
    var root2 = ramfs.RamFs.init(a, &root2_sb);
    defer root2.deinit();
    try root2.mkdir("/mnt");
    var ext2: Ext4 = undefined;
    try ext2.init(a, storage, &ext2_sb, .{ .ctx = &ctx, .write = Ctx.write });
    defer ext2.deinit();
    var ns2: vfs.Namespace = undefined;
    try ns2.init(a, &root2_sb, root2.ops());
    defer ns2.deinit();
    _ = try ns2.mount(&ext2_sb, ext2.ops(), "/mnt");

    const d2 = try ns2.lookupPath("/mnt/hello.txt");
    defer d2.d_sb.dPut(d2);
    const f2 = ext2.fileFor(d2) orelse try ext2.open(d2);
    const all = try a.alloc(u8, 5131);
    defer a.free(all);
    try std.testing.expectEqual(@as(i64, @intCast(all.len)), f2.read(all));
    try std.testing.expectEqualStrings("hello ext4\n", all[0..11]);
    try std.testing.expectEqualSlices(u8, &payload, all[11..]);

    // depth 1 остаётся depth 1: новые блоки идут в тот же leaf.
    const tail: [1024]u8 = @splat('T');
    try std.testing.expectEqual(@as(i64, @intCast(tail.len)), f2.write(&tail));
    ext2_sb.syncFs();
    try std.testing.expect(!ext2.syncFailed());
    try std.testing.expectEqual(@as(u16, 7), rd16(storage[15 * 1024 ..][0..1024], 2) catch unreachable);
    try std.testing.expectEqual(@as(u32, 17), rd32(storage[15 * 1024 + 12 + 6 * 12 ..][0..12], 8) catch unreachable);
    try std.testing.expectEqual(@as(u64, 46), ext2_sb.statfs().bfree);
}

test "ext4 split: metadata block is reserved before any data is dirtied" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeSplitTestImage(a);
    defer a.free(image);

    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &sink, .write = Sink.write });
    defer ext.deinit();
    ext.meta.free_blocks = 5;
    ext.groups[0].free_blocks = 5;
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, 11), f.llseek(0, file.SEEK_END));
    try std.testing.expectEqual(@as(i64, -file.Errno.ENOSPC), f.write(&@as([5 * 1024]u8, @splat('X'))));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u16, 0), ext.extentDepth(11));
    try std.testing.expectEqual(@as(u16, 1), rd16(image, inodeOff(11) + 40 + 2) catch unreachable);
    try std.testing.expectEqual(@as(u64, 11), d.d_inode.?.i_size);
    try std.testing.expectEqual(@as(u32, 2), rd32(image, inodeOff(11) + 28) catch unreachable);
}

test "ext4 sparse: write past EOF leaves a hole, inserts sorted extents and persists" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeSplitTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &ctx, .write = Ctx.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    var payload: [512]u8 = @splat('H');
    @memcpy(payload[0..12], "SPARSE DATA\n");
    try std.testing.expectEqual(@as(i64, 8192), f.llseek(8192, file.SEEK_SET));
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), f.write(&payload));
    try std.testing.expectEqual(@as(u64, 8704), d.d_inode.?.i_size);
    try std.testing.expectEqual(@as(u16, 2), ext.extentEntries(11));
    try std.testing.expectEqual(@as(u16, 0), ext.extentDepth(11));
    try std.testing.expectEqual(@as(usize, 5), ext.dirtyBlocks()); // data + inode + bitmap + gd + sb
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u64, 52), ext_sb.statfs().bfree);

    const root_hdr = storage[inodeOff(11) + 40 ..][0..60];
    try std.testing.expectEqual(@as(u32, 0), rd32(root_hdr[12..][0..12], 0) catch unreachable);
    try std.testing.expectEqual(@as(u32, 8), rd32(root_hdr[12 + 12 ..][0..12], 0) catch unreachable);
    try std.testing.expectEqual(@as(u32, 11), rd32(root_hdr[12 + 12 ..][0..12], 8) catch unreachable);
    try std.testing.expectEqual(@as(u32, 4), rd32(storage, inodeOff(11) + 28) catch unreachable);
    try std.testing.expectEqualSlices(u8, &payload, storage[11 * 1024 ..][0..payload.len]);

    // Свежий mount читает дыру нулями без обращения к старому кэшу extent-ов.
    var root2_sb: vfs.SuperBlock = undefined;
    try root2_sb.init(a, 32);
    defer root2_sb.deinit();
    var ext2_sb: vfs.SuperBlock = undefined;
    try ext2_sb.init(a, 32);
    defer ext2_sb.deinit();
    var root2 = ramfs.RamFs.init(a, &root2_sb);
    defer root2.deinit();
    try root2.mkdir("/mnt");
    var ext2: Ext4 = undefined;
    try ext2.init(a, storage, &ext2_sb, .{ .ctx = &ctx, .write = Ctx.write });
    defer ext2.deinit();
    var ns2: vfs.Namespace = undefined;
    try ns2.init(a, &root2_sb, root2.ops());
    defer ns2.deinit();
    _ = try ns2.mount(&ext2_sb, ext2.ops(), "/mnt");

    const d2 = try ns2.lookupPath("/mnt/hello.txt");
    defer d2.d_sb.dPut(d2);
    const f2 = ext2.fileFor(d2) orelse try ext2.open(d2);
    const all = try a.alloc(u8, 8704);
    defer a.free(all);
    try std.testing.expectEqual(@as(i64, @intCast(all.len)), f2.read(all));
    try std.testing.expectEqualStrings("hello ext4\n", all[0..11]);
    for (all[11..8192]) |b| try std.testing.expectEqual(@as(u8, 0), b);
    try std.testing.expectEqualSlices(u8, &payload, all[8192..]);

    // Запись в середину дыры вставляет extent по ключу, не перезаписывая 0-й.
    try std.testing.expectEqual(@as(i64, 1), f2.writeAt("M", 4096));
    try std.testing.expectEqual(@as(u16, 3), ext2.extentEntries(11));
    const hdr2 = storage[inodeOff(11) + 40 ..][0..60];
    try std.testing.expectEqual(@as(u32, 4), rd32(hdr2[12 + 12 ..][0..12], 0) catch unreachable);
    try std.testing.expectEqual(@as(u32, 8), rd32(hdr2[12 + 2 * 12 ..][0..12], 0) catch unreachable);
    ext2_sb.syncFs();
    try std.testing.expect(!ext2.syncFailed());
    var middle: [1]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 1), f2.readAt(&middle, 4096));
    try std.testing.expectEqual(@as(u8, 'M'), middle[0]);
    try std.testing.expectEqualStrings("hello ext4\n", storage[10 * 1024 ..][0..11]);
    try std.testing.expectEqual(@as(u64, 51), ext2_sb.statfs().bfree);
    try std.testing.expectEqual(@as(u32, 6), rd32(storage, inodeOff(11) + 28) catch unreachable);
}

test "ext4 sparse: ENOSPC preflight leaves the hole and inode untouched" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeSplitTestImage(a);
    defer a.free(image);

    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &sink, .write = Sink.write });
    defer ext.deinit();
    ext.meta.free_blocks = 1;
    ext.groups[0].free_blocks = 1;
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, -file.Errno.ENOSPC), f.writeAt(&@as([2048]u8, @splat('X')), 8192));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u16, 1), ext.extentEntries(11));
    try std.testing.expectEqual(@as(u16, 0), ext.extentDepth(11));
    try std.testing.expectEqual(@as(u64, 11), d.d_inode.?.i_size);
    try std.testing.expectEqual(@as(u32, 2), rd32(image, inodeOff(11) + 28) catch unreachable);
    try std.testing.expectEqual(@as(u8, 0), image[11 * 1024]);
}

test "ext4 depth2: full depth 1 root splits to depth 2, persists and inserts in holes" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeDepthOneFullTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &ctx, .write = Ctx.write });
    defer ext.deinit();
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    const old_size: u64 = 336 * 1024;
    try std.testing.expectEqual(@as(u64, old_size), d.d_inode.?.i_size);
    try std.testing.expectEqual(@as(u16, 1), ext.extentDepth(11));
    try std.testing.expectEqual(@as(u16, 4), ext.extentEntries(11));

    var payload: [1024]u8 = @splat('D');
    @memcpy(payload[0..13], "DEPTH2 PROBE\n");
    try std.testing.expectEqual(@as(i64, @intCast(old_size)), f.llseek(@intCast(old_size), file.SEEK_SET));
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), f.write(&payload));
    try std.testing.expectEqual(@as(u16, 2), ext.extentDepth(11));
    try std.testing.expectEqual(@as(u16, 2), ext.extentEntries(11));
    try std.testing.expectEqual(@as(usize, 9), ext.dirtyBlocks()); // data + old/new leaf + 2 idx + inode + bitmap + gd + sb
    ext_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 9), ext.syncedBlocks());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u64, 3742), ext_sb.statfs().bfree);
    try std.testing.expectEqual(@as(u32, 688), rd32(storage, inodeOff(11) + 28) catch unreachable);

    const root_hdr = storage[inodeOff(11) + 40 ..][0..60];
    try std.testing.expectEqual(@as(u16, 2), rd16(root_hdr, 6) catch unreachable);
    const left_key = rd32(root_hdr[12..][0..12], 0) catch unreachable;
    const right_key = rd32(root_hdr[12 + 12 ..][0..12], 0) catch unreachable;
    try std.testing.expectEqual(@as(u32, 0), left_key);
    try std.testing.expect(right_key > 0);
    try std.testing.expect(right_key < 336);

    // Свежий mount видит depth 2, нули в дырах и payload в конце файла.
    var root2_sb: vfs.SuperBlock = undefined;
    try root2_sb.init(a, 32);
    defer root2_sb.deinit();
    var ext2_sb: vfs.SuperBlock = undefined;
    try ext2_sb.init(a, 32);
    defer ext2_sb.deinit();
    var root2 = ramfs.RamFs.init(a, &root2_sb);
    defer root2.deinit();
    try root2.mkdir("/mnt");
    var ext2: Ext4 = undefined;
    try ext2.init(a, storage, &ext2_sb, .{ .ctx = &ctx, .write = Ctx.write });
    defer ext2.deinit();
    var ns2: vfs.Namespace = undefined;
    try ns2.init(a, &root2_sb, root2.ops());
    defer ns2.deinit();
    _ = try ns2.mount(&ext2_sb, ext2.ops(), "/mnt");
    const d2 = try ns2.lookupPath("/mnt/hello.txt");
    defer d2.d_sb.dPut(d2);
    const f2 = ext2.fileFor(d2) orelse try ext2.open(d2);
    const all = try a.alloc(u8, old_size + payload.len);
    defer a.free(all);
    try std.testing.expectEqual(@as(i64, @intCast(all.len)), f2.read(all));
    try std.testing.expectEqual(@as(u8, 0), all[1024]);
    try std.testing.expectEqual(@as(u8, 0), all[204800]);
    try std.testing.expectEqualSlices(u8, &payload, all[old_size..]);

    // Запись в середину дерева depth 2 делит leaf и вставляет индекс в узел.
    try std.testing.expectEqual(@as(i64, 1), f2.writeAt("M", 200 * 1024));
    try std.testing.expectEqual(@as(u16, 2), ext2.extentDepth(11));
    try std.testing.expectEqual(@as(u16, 2), ext2.extentEntries(11));
    ext2_sb.syncFs();
    try std.testing.expect(!ext2.syncFailed());
    var middle: [1]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 1), f2.readAt(&middle, 200 * 1024));
    try std.testing.expectEqual(@as(u8, 'M'), middle[0]);
    try std.testing.expectEqualSlices(u8, &payload, all[old_size..]);
    const tail = try a.alloc(u8, payload.len);
    defer a.free(tail);
    try std.testing.expectEqual(@as(i64, @intCast(payload.len)), f2.readAt(tail, old_size));
    try std.testing.expectEqualSlices(u8, &payload, tail);
}

test "ext4 depth2: metadata reserve is checked before dirtying data or tree" {
    const a = std.testing.allocator;
    const ramfs = @import("ramfs.zig");
    const image = try makeDepthOneFullTestImage(a);
    defer a.free(image);

    const Sink = struct {
        fn write(_: ?*anyopaque, _: u64, _: []const u8) anyerror!void {}
    };
    var sink = Sink{};
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, .{ .ctx = &sink, .write = Sink.write });
    defer ext.deinit();
    ext.meta.free_blocks = 2;
    ext.groups[0].free_blocks = 2;
    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    // Один data-блок + leaf + два индексных блока не помещаются в резерв.
    try std.testing.expectEqual(@as(i64, -file.Errno.ENOSPC), f.writeAt("X", 336 * 1024));
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(u16, 1), ext.extentDepth(11));
    try std.testing.expectEqual(@as(u16, 4), ext.extentEntries(11));
    try std.testing.expectEqual(@as(u64, 336 * 1024), d.d_inode.?.i_size);
    try std.testing.expectEqual(@as(u32, 680), rd32(image, inodeOff(11) + 28) catch unreachable);
}

test "ext4 jbd2: CRC32C and journal tag layouts follow include/linux/jbd2.h" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(@as(u32, 0x1cf9_6d7c), crc32c(std.math.maxInt(u32), "123456789"));

    var uuid: [16]u8 = undefined;
    for (&uuid, 0..) |*byte, i| byte.* = @intCast(i + 1);
    const seed = crc32c(std.math.maxInt(u32), &uuid);
    var inode: Inode = undefined;
    const v3_features = JBD2_FEATURE_INCOMPAT_REVOKE |
        JBD2_FEATURE_INCOMPAT_64BIT | JBD2_FEATURE_INCOMPAT_CSUM_V3;
    const j3 = Journal{
        .ino = 8,
        .inode = &inode,
        .first = 1,
        .maxlen = 16,
        .sequence = 9,
        .start = 0,
        .features_incompat = v3_features,
        .checksum_type = JBD2_CRC32C_CHKSUM,
        .uuid = uuid,
        .csum_seed = seed,
        .revoke = std.AutoHashMap(u64, u64).init(a),
    };
    defer {
        var journal = j3;
        journal.revoke.deinit();
    }
    try std.testing.expectEqual(@as(usize, 16), Ext4.journalTagBytes(j3));
    try std.testing.expectEqual(@as(usize, 8), Ext4.journalRevokeRecordLen(j3));

    const block_data = "TAGDATA\n";
    var tag3: [32]u8 = @splat(0);
    try Ext4.writeJournalTag(j3, &tag3, 0, 0x0000_0001_0000_000a, JBD2_FLAG_LAST_TAG, 9, block_data);
    try std.testing.expectEqual(@as(u32, 0x0000_000a), rd32be(&tag3, 0) catch unreachable);
    try std.testing.expectEqual(@as(u32, 1), rd32be(&tag3, 8) catch unreachable);
    try std.testing.expectEqual(JBD2_FLAG_LAST_TAG, rd16be(&tag3, 6) catch unreachable);
    try std.testing.expectEqual(Ext4.journalTagCsum(seed, 9, block_data), rd32be(&tag3, 12) catch unreachable);
    try std.testing.expect(Ext4.verifyJournalTag(j3, &tag3, .{
        .target = 0x1_0000_000a,
        .flags = JBD2_FLAG_LAST_TAG,
        .cursor = 0,
        .data_log = 2,
    }, 9, block_data));

    const v2_features = JBD2_FEATURE_INCOMPAT_CSUM_V2 | JBD2_FEATURE_INCOMPAT_64BIT;
    const j2 = Journal{
        .ino = 8,
        .inode = &inode,
        .first = 1,
        .maxlen = 16,
        .sequence = 9,
        .start = 0,
        .features_incompat = v2_features,
        .checksum_type = JBD2_CRC32C_CHKSUM,
        .uuid = uuid,
        .csum_seed = seed,
        .revoke = std.AutoHashMap(u64, u64).init(a),
    };
    defer {
        var journal = j2;
        journal.revoke.deinit();
    }
    try std.testing.expectEqual(@as(usize, 14), Ext4.journalTagBytes(j2));
    var tag2: [32]u8 = @splat(0);
    try Ext4.writeJournalTag(j2, &tag2, 0, 0x0000_0002_0000_000b, JBD2_FLAG_LAST_TAG, 9, block_data);
    try std.testing.expectEqual(@as(u16, @truncate(Ext4.journalTagCsum(seed, 9, block_data))), rd16be(&tag2, 4) catch unreachable);
    try std.testing.expectEqual(@as(u32, 2), rd32be(&tag2, 8) catch unreachable);
    try std.testing.expectEqual(@as(u32, 0), rd32be(&tag2, 10) catch unreachable & 0xffff);
}

test "ext4 jbd2: revoke, 64-bit tags and csum-v3 commit on a real journal inode" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const image = try makeJournalTestImage(a);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    const wb: Writeback = .{ .ctx = &ctx, .write = Ctx.write };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    const features = JBD2_FEATURE_INCOMPAT_REVOKE |
        JBD2_FEATURE_INCOMPAT_64BIT | JBD2_FEATURE_INCOMPAT_CSUM_V3;
    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, wb);
    defer ext.deinit();
    try ext.journalEnableFeatures(features);
    try std.testing.expectEqual(features, ext.journalIncompatFeatures());
    try std.testing.expectEqual(JBD2_CRC32C_CHKSUM, ext.journalChecksumType());
    try ext.revokeBlock(11);
    try std.testing.expectEqual(@as(usize, 1), ext.journalRevokes());

    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&ext_sb, ext.ops(), "/mnt");
    const d = try ns.lookupPath("/mnt/hello.txt");
    defer d.d_sb.dPut(d);
    const f = ext.fileFor(d) orelse try ext.open(d);
    try std.testing.expectEqual(@as(i64, 10), f.write("JBD2 CSUM\n"));
    const dirty = ext.dirtyBlocks();
    try std.testing.expect(dirty > 0);

    d.d_sb.syncFs();
    try std.testing.expect(!ext.syncFailed());
    try std.testing.expectEqual(@as(usize, 0), ext.dirtyBlocks());
    try std.testing.expectEqual(@as(usize, 1), ext.journalCommits());
    try std.testing.expectEqual(@as(usize, 1), ext.journalRevokeWrites());
    try std.testing.expectEqual(@as(usize, 0), ext.journalRevokes());
    try std.testing.expectEqual(@as(u32, 0), ext.journalStart());

    const jsb = image[12 * 1024 ..][0..1024];
    try std.testing.expectEqual(features, rd32be(jsb, 0x28) catch unreachable);
    try std.testing.expectEqual(@as(u8, JBD2_CRC32C_CHKSUM), jsb[0x50]);
    try std.testing.expectEqual(journalSuperCsum(jsb), rd32be(jsb, JBD2_SUPERBLOCK_CSUM_OFF) catch unreachable);

    var uuid: [16]u8 = @splat(0);
    @memcpy(&uuid, jsb[0x30..][0..16]);
    const j = ext.journal.?;
    const seed = crc32c(std.math.maxInt(u32), &uuid);
    try std.testing.expectEqual(seed, j.csum_seed);

    const desc = image[13 * 1024 ..][0..1024];
    try std.testing.expectEqual(JBD2_MAGIC_NUMBER, rd32be(desc, 0) catch unreachable);
    try std.testing.expectEqual(JBD2_DESCRIPTOR_BLOCK, rd32be(desc, 4) catch unreachable);
    try std.testing.expect(Ext4.verifyBlockTail(seed, desc));
    var cursor: usize = 12;
    var tags: usize = 0;
    var last = false;
    while (tags < dirty) : (tags += 1) {
        const target = (rd32be(desc, cursor) catch unreachable) |
            (@as(u64, rd32be(desc, cursor + 8) catch unreachable) << 32);
        const flags = rd16be(desc, cursor + 6) catch unreachable;
        const data_off = (14 + tags) * 1024;
        const data = image[data_off..][0..1024];
        try std.testing.expect(Ext4.verifyJournalTag(j, desc, .{
            .target = target,
            .flags = flags,
            .cursor = cursor,
            .data_log = @intCast(1 + tags),
        }, 1, data));
        cursor += 16;
        if (tags == 0) cursor += 16;
        if (flags & JBD2_FLAG_LAST_TAG != 0) last = true;
    }
    try std.testing.expect(last);
    try std.testing.expectEqual(@as(usize, dirty), tags);

    const revoke = image[(14 + dirty) * 1024 ..][0..1024];
    try std.testing.expectEqual(JBD2_MAGIC_NUMBER, rd32be(revoke, 0) catch unreachable);
    try std.testing.expectEqual(JBD2_REVOKE_BLOCK, rd32be(revoke, 4) catch unreachable);
    try std.testing.expectEqual(@as(u32, 24), rd32be(revoke, 12) catch unreachable);
    try std.testing.expectEqual(@as(u64, 11), rd64be(revoke, 16) catch unreachable);
    try std.testing.expect(Ext4.verifyBlockTail(seed, revoke));

    const commit = image[(15 + dirty) * 1024 ..][0..1024];
    try std.testing.expectEqual(JBD2_COMMIT_BLOCK, rd32be(commit, 4) catch unreachable);
    try std.testing.expectEqual(@as(u8, JBD2_CRC32C_CHKSUM), commit[12]);
    try std.testing.expectEqual(@as(u8, 4), commit[13]);
    try std.testing.expect(Ext4.verifyCommitChecksum(seed, commit));
}

test "ext4 jbd2: recovery honours revoke, 64-bit tags and log wrap-around" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const features = JBD2_FEATURE_INCOMPAT_REVOKE |
        JBD2_FEATURE_INCOMPAT_64BIT | JBD2_FEATURE_INCOMPAT_CSUM_V3;
    const image = try makeAdvancedJournalTestImage(a, features);
    defer a.free(image);
    const storage = try a.alloc(u8, image.len);
    defer a.free(storage);

    const tid: u32 = 9;
    const jsb = image[12 * 1024 ..][0..1024];
    put32be(jsb, 8, tid);
    put32be(jsb, 24, tid);
    put32be(jsb, 28, 14); // s_start: дескриптор в конце журнала
    put32be(jsb, JBD2_SUPERBLOCK_CSUM_OFF, journalSuperCsum(jsb));
    var uuid: [16]u8 = @splat(0);
    @memcpy(&uuid, jsb[0x30..][0..16]);
    const seed = crc32c(std.math.maxInt(u32), &uuid);
    var inode: Inode = undefined;
    const j = Journal{
        .ino = 8,
        .inode = &inode,
        .first = 1,
        .maxlen = 16,
        .sequence = tid,
        .start = 14,
        .features_incompat = features,
        .checksum_type = JBD2_CRC32C_CHKSUM,
        .uuid = uuid,
        .csum_seed = seed,
        .revoke = std.AutoHashMap(u64, u64).init(a),
    };
    defer {
        var journal = j;
        journal.revoke.deinit();
    }

    const old = "hello ext4\n";
    const desc = image[26 * 1024 ..][0..1024]; // logical 14
    @memset(desc, 0);
    put32be(desc, 0, JBD2_MAGIC_NUMBER);
    put32be(desc, 4, JBD2_DESCRIPTOR_BLOCK);
    put32be(desc, 8, tid);

    const revoked_data = image[27 * 1024 ..][0..1024]; // logical 15
    @memset(revoked_data, 0);
    @memcpy(revoked_data[0..10], "NEWDATA10\n");
    try Ext4.writeJournalTag(j, desc, 12, 10, 0, tid, revoked_data);
    @memcpy(desc[28..][0..16], &uuid);

    const replayed_data = image[13 * 1024 ..][0..1024]; // logical 1 после wrap
    @memset(replayed_data, 0);
    @memcpy(replayed_data[0..10], "NEWDATA11\n");
    try Ext4.writeJournalTag(j, desc, 44, 11, JBD2_FLAG_SAME_UUID | JBD2_FLAG_LAST_TAG, tid, replayed_data);
    Ext4.writeBlockTail(seed, desc);

    const revoke = image[14 * 1024 ..][0..1024]; // logical 2
    @memset(revoke, 0);
    put32be(revoke, 0, JBD2_MAGIC_NUMBER);
    put32be(revoke, 4, JBD2_REVOKE_BLOCK);
    put32be(revoke, 8, tid);
    put32be(revoke, 12, 24);
    put64be(revoke, 16, 10);
    Ext4.writeBlockTail(seed, revoke);

    const commit = image[15 * 1024 ..][0..1024]; // logical 3
    @memset(commit, 0);
    put32be(commit, 0, JBD2_MAGIC_NUMBER);
    put32be(commit, 4, JBD2_COMMIT_BLOCK);
    put32be(commit, 8, tid);
    commit[12] = JBD2_CRC32C_CHKSUM;
    commit[13] = 4;
    Ext4.writeCommitChecksum(seed, commit);

    put32(image, 1024 + 96, EXT4_FEATURE_INCOMPAT_FILETYPE |
        EXT4_FEATURE_INCOMPAT_EXTENTS | EXT4_FEATURE_INCOMPAT_RECOVER);
    @memcpy(image[10 * 1024 ..][0..old.len], old);
    @memcpy(storage, image);

    var disk = block.MemoryDisk{ .data = storage };
    const Ctx = struct {
        dev: block.Device,

        fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
            const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
            try self.dev.write(offset, bytes);
        }
    };
    var ctx = Ctx{ .dev = disk.device() };
    const wb: Writeback = .{ .ctx = &ctx, .write = Ctx.write };

    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 32);
    defer root_sb.deinit();
    var ext_sb: vfs.SuperBlock = undefined;
    try ext_sb.init(a, 32);
    defer ext_sb.deinit();
    var root = ramfs.RamFs.init(a, &root_sb);
    defer root.deinit();
    try root.mkdir("/mnt");

    var ext: Ext4 = undefined;
    try ext.init(a, image, &ext_sb, wb);
    defer ext.deinit();
    try std.testing.expect(ext.journalActive());
    try std.testing.expectEqual(@as(usize, 1), ext.journalReplays());
    try std.testing.expectEqual(@as(usize, 1), ext.journalCommits());
    try std.testing.expectEqual(@as(u32, 0), ext.journalStart());
    try std.testing.expectEqual(@as(u32, 0), rd32(image, 1024 + 96) catch unreachable & EXT4_FEATURE_INCOMPAT_RECOVER);
    try std.testing.expectEqualStrings(old, image[10 * 1024 ..][0..old.len]);
    try std.testing.expectEqualStrings("NEWDATA11\n", image[11 * 1024 ..][0..10]);
    try std.testing.expectEqualStrings("NEWDATA11\n", storage[11 * 1024 ..][0..10]);
    try std.testing.expectEqual(journalSuperCsum(jsb), rd32be(jsb, JBD2_SUPERBLOCK_CSUM_OFF) catch unreachable);
}

test "ext4 jbd2: invalid descriptor, tag and commit checksums abort recovery" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");
    const features = JBD2_FEATURE_INCOMPAT_64BIT | JBD2_FEATURE_INCOMPAT_CSUM_V3;
    const tid: u32 = 5;
    const payload = "CHECKSUM\n";

    for (0..3) |case| {
        const image = try makeAdvancedJournalTestImage(a, features);
        defer a.free(image);
        const storage = try a.alloc(u8, image.len);
        defer a.free(storage);

        const jsb = image[12 * 1024 ..][0..1024];
        put32be(jsb, 8, tid);
        put32be(jsb, 24, tid);
        put32be(jsb, 28, 1);
        put32be(jsb, JBD2_SUPERBLOCK_CSUM_OFF, journalSuperCsum(jsb));
        var uuid: [16]u8 = @splat(0);
        @memcpy(&uuid, jsb[0x30..][0..16]);
        const seed = crc32c(std.math.maxInt(u32), &uuid);
        var inode: Inode = undefined;
        const j = Journal{
            .ino = 8,
            .inode = &inode,
            .first = 1,
            .maxlen = 16,
            .sequence = tid,
            .start = 1,
            .features_incompat = features,
            .checksum_type = JBD2_CRC32C_CHKSUM,
            .uuid = uuid,
            .csum_seed = seed,
            .revoke = std.AutoHashMap(u64, u64).init(a),
        };
        defer {
            var journal = j;
            journal.revoke.deinit();
        }

        const desc = image[13 * 1024 ..][0..1024];
        @memset(desc, 0);
        put32be(desc, 0, JBD2_MAGIC_NUMBER);
        put32be(desc, 4, JBD2_DESCRIPTOR_BLOCK);
        put32be(desc, 8, tid);
        const data = image[14 * 1024 ..][0..1024];
        @memset(data, 0);
        @memcpy(data[0..payload.len], payload);
        try Ext4.writeJournalTag(j, desc, 12, 10, JBD2_FLAG_LAST_TAG, tid, data);
        @memcpy(desc[28..][0..16], &uuid);
        Ext4.writeBlockTail(seed, desc);

        const commit = image[15 * 1024 ..][0..1024];
        @memset(commit, 0);
        put32be(commit, 0, JBD2_MAGIC_NUMBER);
        put32be(commit, 4, JBD2_COMMIT_BLOCK);
        put32be(commit, 8, tid);
        commit[12] = JBD2_CRC32C_CHKSUM;
        commit[13] = 4;
        Ext4.writeCommitChecksum(seed, commit);

        switch (case) {
            0 => data[0] ^= 1,
            1 => desc[desc.len - 4] ^= 1,
            else => commit[16] ^= 1,
        }
        put32(image, 1024 + 96, EXT4_FEATURE_INCOMPAT_FILETYPE |
            EXT4_FEATURE_INCOMPAT_EXTENTS | EXT4_FEATURE_INCOMPAT_RECOVER);
        @memcpy(storage, image);

        var disk = block.MemoryDisk{ .data = storage };
        const Ctx = struct {
            dev: block.Device,

            fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
                const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
                try self.dev.write(offset, bytes);
            }
        };
        var ctx = Ctx{ .dev = disk.device() };
        const wb: Writeback = .{ .ctx = &ctx, .write = Ctx.write };

        var root_sb: vfs.SuperBlock = undefined;
        try root_sb.init(a, 32);
        defer root_sb.deinit();
        var ext_sb: vfs.SuperBlock = undefined;
        try ext_sb.init(a, 32);
        defer ext_sb.deinit();
        var root = ramfs.RamFs.init(a, &root_sb);
        defer root.deinit();
        try root.mkdir("/mnt");

        var ext: Ext4 = undefined;
        try std.testing.expectError(error.Corrupt, ext.init(a, image, &ext_sb, wb));
    }
}

test "ext4 jbd2: unsupported feature combinations and bad checksums are rejected" {
    const a = std.testing.allocator;
    const block = @import("block.zig");
    const ramfs = @import("ramfs.zig");

    const cases = [_]struct {
        name: []const u8,
        features: u32,
        csum_type: u8,
        valid_csum: bool,
        recover: bool,
        expected: ?anyerror,
    }{
        .{ .name = "unknown", .features = 0x8000_0000, .csum_type = 0, .valid_csum = true, .recover = true, .expected = error.NotSupported },
        .{ .name = "csum2+csum3", .features = JBD2_FEATURE_INCOMPAT_CSUM_V2 | JBD2_FEATURE_INCOMPAT_CSUM_V3, .csum_type = JBD2_CRC32C_CHKSUM, .valid_csum = true, .recover = true, .expected = error.NotSupported },
        .{ .name = "wrong type", .features = JBD2_FEATURE_INCOMPAT_CSUM_V3, .csum_type = 1, .valid_csum = true, .recover = true, .expected = error.NotSupported },
        .{ .name = "bad csum", .features = JBD2_FEATURE_INCOMPAT_CSUM_V3, .csum_type = JBD2_CRC32C_CHKSUM, .valid_csum = false, .recover = true, .expected = error.NotSupported },
        .{ .name = "clean mount", .features = 0x8000_0000, .csum_type = 0, .valid_csum = true, .recover = false, .expected = null },
    };

    for (cases) |case| {
        const image = try makeJournalTestImage(a);
        defer a.free(image);
        const jsb = image[12 * 1024 ..][0..1024];
        put32be(jsb, 0x28, case.features);
        jsb[0x50] = case.csum_type;
        if (case.valid_csum) put32be(jsb, JBD2_SUPERBLOCK_CSUM_OFF, journalSuperCsum(jsb));
        if (case.recover) {
            put32(image, 1024 + 96, EXT4_FEATURE_INCOMPAT_FILETYPE |
                EXT4_FEATURE_INCOMPAT_EXTENTS | EXT4_FEATURE_INCOMPAT_RECOVER);
        }
        put32be(jsb, 28, 0);

        const storage = try a.alloc(u8, image.len);
        defer a.free(storage);
        @memcpy(storage, image);
        var disk = block.MemoryDisk{ .data = storage };
        const Ctx = struct {
            dev: block.Device,

            fn write(ctx: ?*anyopaque, offset: u64, bytes: []const u8) anyerror!void {
                const self: *const @This() = @ptrCast(@alignCast(ctx orelse return error.Invalid));
                try self.dev.write(offset, bytes);
            }
        };
        var ctx = Ctx{ .dev = disk.device() };
        const wb: Writeback = .{ .ctx = &ctx, .write = Ctx.write };

        var root_sb: vfs.SuperBlock = undefined;
        try root_sb.init(a, 32);
        defer root_sb.deinit();
        var ext_sb: vfs.SuperBlock = undefined;
        try ext_sb.init(a, 32);
        defer ext_sb.deinit();
        var root = ramfs.RamFs.init(a, &root_sb);
        defer root.deinit();
        try root.mkdir("/mnt");

        var ext: Ext4 = undefined;
        if (case.expected) |expected| {
            try std.testing.expectError(expected, ext.init(a, image, &ext_sb, wb));
        } else {
            try ext.init(a, image, &ext_sb, wb);
            defer ext.deinit();
            try std.testing.expect(!ext.journalActive());
        }
    }
}
