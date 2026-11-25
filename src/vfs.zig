//! Порт базового VFS Linux 7.3 на Zig: qstr/hash, dentry cache, inode cache,
//! path walk (. / .. / компоненты, negative dentries, symlink traversal с
//! лимитом SYMLOOP_MAX), mount namespace с переходом через точки монтирования
//! и super_operations (statfs/sync_fs). Без RCU и seqlock.
//! Источники: include/linux/dcache.h, fs/dcache.c, fs/inode.c, fs/namei.c,
//! fs/namespace.c, fs/super.c.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const list = @import("list.zig");

pub const S_IFDIR: u32 = 0o040000;
pub const S_IFREG: u32 = 0o100000;
pub const S_IFLNK: u32 = 0o120000;

const GOLDEN_RATIO_64: u64 = 0x9E3779B97F4A7C15;
/// fs/namei.c: SYMLOOP_MAX — защита от циклических символьных ссылок.
pub const SYMLOOP_MAX: usize = 40;
const MAX_PATH_COMPONENTS: usize = 64;

pub const Qstr = struct {
    hash: u32 = 0,
    len: u32 = 0,
    name: []const u8 = "",

    pub fn eql(self: Qstr, other: Qstr) bool {
        return self.hash == other.hash and std.mem.eql(u8, self.name, other.name);
    }
};

/// include/linux/stringhash.h: full_name_hash() + hash_long() (32 бита).
pub fn hashName(name: []const u8) u32 {
    var h: u64 = 0;
    for (name) |c| {
        h = (h + (@as(u64, c) << 4) + (@as(u64, c) >> 4)) *% 11;
    }
    return @truncate((h *% GOLDEN_RATIO_64) >> 32);
}

pub fn makeQstr(name: []const u8) Qstr {
    return .{ .hash = hashName(name), .len = @intCast(name.len), .name = name };
}

pub const Inode = struct {
    i_ino: u64,
    i_mode: u32 = S_IFREG,
    i_size: u64 = 0,
    i_nlink: u32 = 1,
    i_count: u32 = 1,
    i_sb: *SuperBlock,
    i_hash: list.HNode = .{},
    i_dentry: list.HHead = null,
    hashed: bool = false,
    /// Содержимое symlink (цель) живёт вместе с inode, как i_link в Linux.
    i_link: ?[]u8 = null,

    pub inline fn isDir(self: *const Inode) bool {
        return self.i_mode & 0o170000 == S_IFDIR;
    }

    pub inline fn isLink(self: *const Inode) bool {
        return self.i_mode & 0o170000 == S_IFLNK;
    }
};

pub const DentryFlags = struct {
    pub const ROOT: u8 = 1 << 0;
    pub const NEGATIVE: u8 = 1 << 1;
    pub const KILLED: u8 = 1 << 2;
};

pub const Dentry = struct {
    d_name: Qstr,
    d_name_buf: []u8,
    d_parent: ?*Dentry,
    d_inode: ?*Inode = null,
    d_sb: *SuperBlock,
    d_child: list.Node = .{}, // в parent.d_children
    d_children: list.Head = .{},
    d_hash: list.HNode = .{},
    d_alias: list.HNode = .{}, // в inode.i_dentry
    d_lru: list.Node = .{}, // в sb.dentry_lru (d_count == 0)
    d_count: u32 = 1,
    d_flags: u8 = 0,

    pub inline fn isRoot(self: *const Dentry) bool {
        return self.d_flags & DentryFlags.ROOT != 0;
    }

    pub inline fn isHashed(self: *const Dentry) bool {
        return self.d_hash.pprev != null;
    }

    pub inline fn isOnLru(self: *const Dentry) bool {
        return self.d_lru.next != null;
    }
};

pub const InodeInfo = struct {
    ino: u64,
    mode: u32 = S_IFREG,
    size: u64 = 0,
    /// Не-null только для symlink; SuperBlock.iget() копирует цель в inode.
    link: ?[]const u8 = null,
};

/// Разбить путь на компоненты и положить их в стек в обратном порядке, чтобы
/// первый компонент оказался на вершине. `stack[old_sp..]` — только новые
/// компоненты, поэтому цель symlink вытесняет исходный остаток пути.
fn pushComponents(stack: *[MAX_PATH_COMPONENTS][]const u8, sp: *usize, path: []const u8) !void {
    const old = sp.*;
    var added: usize = 0;
    var start: usize = 0;
    while (start < path.len) {
        var end = start;
        while (end < path.len and path[end] != '/') end += 1;
        if (end > start) {
            if (sp.* >= stack.len) return error.NameTooLong;
            stack[sp.*] = path[start..end];
            sp.* += 1;
            added += 1;
        }
        start = end + 1;
    }
    if (added < 2) return;
    var i: usize = 0;
    var j = old + added - 1;
    while (i < j) {
        const tmp = stack[old + i];
        stack[old + i] = stack[j];
        stack[j] = tmp;
        i += 1;
        j -= 1;
    }
}

/// Операции конкретной ФС: вызываются для отсутствующих в dcache имён.
pub const LookupOps = struct {
    ctx: ?*anyopaque = null,
    lookup: *const fn (ctx: ?*anyopaque, parent: *Dentry, name: Qstr) ?InodeInfo,
};

/// fs/namei.c: vfs_create()/vfs_unlink() для конкретной ФС. Вызываются после
/// резолвинга родителя, но до изменения dcache: носитель обновляется первым.
pub const DirOps = struct {
    ctx: ?*anyopaque = null,
    create: ?*const fn (ctx: ?*anyopaque, parent: *Dentry, name: Qstr) anyerror!InodeInfo = null,
    mkdir: ?*const fn (ctx: ?*anyopaque, parent: *Dentry, name: Qstr) anyerror!InodeInfo = null,
    unlink: ?*const fn (ctx: ?*anyopaque, parent: *Dentry, name: Qstr) anyerror!void = null,
    rmdir: ?*const fn (ctx: ?*anyopaque, parent: *Dentry, name: Qstr) anyerror!void = null,
    /// fops->open без user-space: превратить dentry в struct file, который
    /// держит dget() на этой dentry.
    instantiate: ?*const fn (ctx: ?*anyopaque, dentry: *Dentry) anyerror!*anyopaque = null,
};

/// include/uapi/linux/magic.h + fs/super.c: statfs() результат super_operations.
pub const SuperStats = struct {
    magic: u64 = 0,
    bsize: u64 = 4096,
    blocks: u64 = 0,
    bfree: u64 = 0,
    bavail: u64 = 0,
    files: u64 = 0,
    ffree: u64 = 0,
};

/// include/linux/fs.h: struct super_operations (упрощённый набор).
pub const SuperOperations = struct {
    ctx: ?*anyopaque = null,
    statfs: ?*const fn (ctx: ?*anyopaque, sb: *SuperBlock) SuperStats = null,
    sync_fs: ?*const fn (ctx: ?*anyopaque, sb: *SuperBlock) void = null,
};

/// fs/pnode.c: Shared Subtree. Точка монтирования с `MS_SHARED` входит в peer
/// group: новые mount/umount в поддереве распространяются на все namespace-ы,
/// которые содержат пиров этой группы.
pub const Propagation = enum { private, shared };

pub const PeerGroup = struct {
    allocator: std.mem.Allocator,
    members: std.ArrayList(*Mount) = .empty,

    fn add(self: *PeerGroup, m: *Mount) !void {
        try self.members.append(self.allocator, m);
        m.group = self;
        m.propagation = .shared;
    }

    fn remove(self: *PeerGroup, m: *Mount) void {
        for (self.members.items, 0..) |item, i| {
            if (item == m) {
                _ = self.members.orderedRemove(i);
                break;
            }
        }
        if (self.members.items.len == 0) {
            self.members.deinit(self.allocator);
            self.allocator.destroy(self);
        }
    }
};

/// fs/namespace.c: struct mount. Держит dget() на mountpoint и на root.
pub const Mount = struct {
    sb: *SuperBlock,
    ops: LookupOps,
    root: *Dentry,
    mountpoint: ?*Dentry = null,
    parent: ?*Mount = null,
    children: std.ArrayList(*Mount) = .empty,
    /// Обратная ссылка нужна для propagation между namespace-ами.
    ns: ?*Namespace = null,
    propagation: Propagation = .private,
    group: ?*PeerGroup = null,
    detached: bool = false,
};

/// include/uapi/linux/fs.h: MS_SHARED/MS_PRIVATE для mount propagation.
pub const MountFlags = struct {
    pub const shared: u8 = 1 << 0;
    pub const private: u8 = 1 << 1;
};

/// fs/namei.c: struct path — dentry вместе с vfsmount.
pub const Path = struct {
    mnt: *Mount,
    dentry: *Dentry,
};

pub const SuperBlock = struct {
    allocator: std.mem.Allocator,
    s_root: *Dentry,
    dentry_buckets: []list.HHead,
    inode_buckets: []list.HHead,
    next_ino: u64 = 2,
    nr_dentries: usize = 0,
    nr_inodes: usize = 0,
    /// fs/dcache.c: dentry_unused — LRU неиспользуемых (d_count == 0) dentry.
    dentry_lru: list.Head = .{},
    nr_lru: usize = 0,
    s_ops: SuperOperations = .{},
    s_dir_ops: DirOps = .{},

    /// in-place: dentry/d_parent и inode.i_sb хранят указатель на super_block.
    pub fn init(self: *SuperBlock, allocator: std.mem.Allocator, bucket_count: usize) !void {
        const db = try allocator.alloc(list.HHead, bucket_count);
        for (db) |*b| b.* = null;
        const ib = try allocator.alloc(list.HHead, bucket_count);
        for (ib) |*b| b.* = null;
        self.* = SuperBlock{
            .allocator = allocator,
            .s_root = undefined,
            .dentry_buckets = db,
            .inode_buckets = ib,
        };
        list.init(&self.dentry_lru);
        // Корень: d_inode != NULL, d_parent == self (IS_ROOT).
        const root = try self.allocDentry(null, makeQstr("/"));
        root.d_flags |= DentryFlags.ROOT;
        root.d_parent = root;
        const info = InodeInfo{ .ino = 1, .mode = S_IFDIR | 0o755 };
        const inode = try self.iget(info);
        self.dInstantiate(root, inode);
        self.dRehash(root);
        self.s_root = root;
    }

    /// fs/super.c: super_operations Registration для конкретной ФС.
    pub fn setSuperOps(self: *SuperBlock, ops: SuperOperations) void {
        self.s_ops = ops;
    }

    /// fs/super.c: Registration directory operations конкретной ФС.
    pub fn setDirOps(self: *SuperBlock, ops: DirOps) void {
        self.s_dir_ops = ops;
    }

    pub fn statfs(self: *SuperBlock) SuperStats {
        if (self.s_ops.statfs) |f| return f(self.s_ops.ctx, self);
        return .{ .files = self.nr_inodes, .ffree = 0 };
    }

    pub fn syncFs(self: *SuperBlock) void {
        if (self.s_ops.sync_fs) |f| f(self.s_ops.ctx, self);
    }

    pub fn deinit(self: *SuperBlock) void {
        // Освобождаем все dentry по корневому дереву.
        self.freeTree(self.s_root);
        self.allocator.free(self.dentry_buckets);
        // Иноды, если остались, снимаем с хеша.
        for (self.inode_buckets) |*bucket| {
            var cur = bucket.*;
            while (cur) |n| {
                const next = n.next;
                const ino: *Inode = @fieldParentPtr("i_hash", n);
                if (ino.hashed) list.hDel(&ino.i_hash);
                if (ino.i_link) |link| self.allocator.free(link);
                self.allocator.destroy(ino);
                self.nr_inodes -= 1;
                cur = next;
            }
        }
        self.allocator.free(self.inode_buckets);
    }

    fn freeTree(self: *SuperBlock, d: *Dentry) void {
        var it = list.iterator(&d.d_children);
        var child_node = it.next();
        while (child_node) |cn| {
            const child: *Dentry = @fieldParentPtr("d_child", cn);
            child_node = it.next();
            self.freeTree(child);
        }
        self.freeDentry(d);
    }

    /// fs/dcache.c: dentry_free() — снять с hash/LRU, освободить inode и память.
    fn freeDentry(self: *SuperBlock, d: *Dentry) void {
        if (d.isHashed()) list.hDel(&d.d_hash);
        if (d.isOnLru()) {
            list.del(&d.d_lru);
            self.nr_lru -= 1;
        }
        if (d.d_inode) |ino| {
            list.hDel(&d.d_alias);
            d.d_inode = null;
            self.iput(ino);
        }
        const parent = d.d_parent;
        if (d.d_child.next != null) list.del(&d.d_child);
        self.allocator.free(d.d_name_buf);
        self.allocator.destroy(d);
        self.nr_dentries -= 1;
        // d_free() снимает dget() родителя, который держал ребёнок.
        // d_parent корня указывает на самого себя (IS_ROOT) — ref не снимаем.
        if (parent) |p| {
            if (p != d) self.dPut(p);
        }
    }

    /// fs/dcache.c: prune_dcache_sb() — вытеснить неиспользуемые dentry с LRU.
    /// Освобождение родителя может перевести ребёнка в LRU, поэтому цикл до цели.
    pub fn pruneDcache(self: *SuperBlock, max_lru: usize) void {
        while (self.nr_lru > max_lru) {
            const node = self.dentry_lru.next orelse break;
            if (node == &self.dentry_lru) break;
            const d: *Dentry = @fieldParentPtr("d_lru", node);
            self.freeDentry(d);
        }
    }

    fn dentryBucket(self: *SuperBlock, q: Qstr) *list.HHead {
        return &self.dentry_buckets[q.hash % self.dentry_buckets.len];
    }

    fn inodeBucket(self: *SuperBlock, ino: u64) *list.HHead {
        const h: u64 = (ino *% GOLDEN_RATIO_64) >> 32;
        return &self.inode_buckets[@intCast(h % self.inode_buckets.len)];
    }

    fn allocDentry(self: *SuperBlock, parent: ?*Dentry, q: Qstr) !*Dentry {
        const d = try self.allocator.create(Dentry);
        const buf = try self.allocator.dupe(u8, q.name);
        d.* = .{
            .d_name = .{ .hash = q.hash, .len = q.len, .name = buf },
            .d_name_buf = buf,
            .d_parent = parent,
            .d_sb = self,
        };
        list.init(&d.d_children);
        if (parent) |p| {
            // d_alloc(): child держит ссылку на родителя (dget_dlock).
            p.d_count += 1;
            list.addTail(&p.d_children, &d.d_child);
        }
        self.nr_dentries += 1;
        return d;
    }

    fn dRehash(self: *SuperBlock, d: *Dentry) void {
        // dget() снимает dentry с LRU перед повторным хешированием.
        if (d.isOnLru()) {
            list.del(&d.d_lru);
            self.nr_lru -= 1;
        }
        if (d.isHashed()) list.hDel(&d.d_hash);
        list.hAdd(self.dentryBucket(d.d_name), &d.d_hash);
    }

    fn dDrop(self: *SuperBlock, d: *Dentry) void {
        if (d.isOnLru()) {
            list.del(&d.d_lru);
            self.nr_lru -= 1;
        }
        if (d.isHashed()) {
            list.hDel(&d.d_hash);
            d.d_flags |= DentryFlags.KILLED;
        }
    }

    /// d_lookup(): поиск по (parent, hash, bytes) в бакете dentry_hashtable.
    pub fn dLookup(self: *SuperBlock, parent: *Dentry, q: Qstr) ?*Dentry {
        const bucket = self.dentryBucket(q);
        var cur = bucket.*;
        while (cur) |n| : (cur = n.next) {
            const d: *Dentry = @fieldParentPtr("d_hash", n);
            if (d.d_name.hash != q.hash) continue;
            if (d.d_parent != parent) continue;
            if (!d.isHashed()) continue;
            if (!std.mem.eql(u8, d.d_name.name, q.name)) continue;
            // dget(): воскресить dentry из LRU, не дожидаясь повторного lookup().
            if (d.isOnLru()) {
                list.del(&d.d_lru);
                self.nr_lru -= 1;
            }
            d.d_count += 1;
            return d;
        }
        return null;
    }

    fn dInstantiate(self: *SuperBlock, d: *Dentry, inode: *Inode) void {
        _ = self;
        d.d_inode = inode;
        d.d_flags &= ~DentryFlags.NEGATIVE;
        list.hAdd(&inode.i_dentry, &d.d_alias);
    }

    /// vfs_create(): связать новую inode с dentry в parent и вернуть dget().
    pub fn createNode(self: *SuperBlock, parent: *Dentry, q: Qstr, info: InodeInfo) !*Dentry {
        if (parent.d_inode) |ino| {
            if (!ino.isDir()) return error.NotDir;
        }
        if (self.dLookup(parent, q)) |old| {
            const exists = old.d_flags & DentryFlags.NEGATIVE == 0;
            self.dPut(old);
            if (exists) return error.PathExists;
            const inode = try self.iget(info);
            errdefer self.iput(inode);
            self.dInstantiate(old, inode);
            return old;
        }
        const inode = try self.iget(info);
        errdefer self.iput(inode);
        const fresh = try self.allocDentry(parent, q);
        errdefer self.dPut(fresh);
        self.dInstantiate(fresh, inode);
        self.dRehash(fresh);
        return fresh;
    }

    /// fs/dcache.c: dentry, снятый с хеша unlink(), остаётся в d_children до
    /// последнего dput(). Для rmdir такие удалённые имена не считаются детьми.
    fn hasLiveChild(d: *Dentry) bool {
        var it = list.iterator(&d.d_children);
        while (it.next()) |cn| {
            const child: *Dentry = @fieldParentPtr("d_child", cn);
            if (child.d_flags & DentryFlags.KILLED == 0) return true;
        }
        return false;
    }

    /// vfs_unlink(): снять имя из dcache и releases dentry при последнем dput().
    /// struct inode живёт, пока открытые struct file держат ссылку на dentry.
    pub fn unlinkNode(self: *SuperBlock, parent: *Dentry, q: Qstr, allow_dir: bool) !void {
        if (parent.d_inode) |ino| {
            if (!ino.isDir()) return error.NotDir;
        }
        const d = self.dLookup(parent, q) orelse return error.NoEnt;
        defer self.dPut(d);
        if (d.d_flags & DentryFlags.NEGATIVE != 0) return error.NoEnt;
        if (d.d_inode) |ino| {
            if (ino.isDir() and !allow_dir) return error.IsDir;
            if (!ino.isDir() and allow_dir) return error.NotDir;
            if (ino.isDir() and hasLiveChild(d)) return error.NotEmpty;
        }
        self.dDrop(d);
    }

    pub fn dPut(self: *SuperBlock, d: *Dentry) void {
        if (d.d_count > 0) d.d_count -= 1;
        if (d.d_count != 0 or d.isRoot()) return;
        if (d.d_flags & DentryFlags.KILLED != 0) {
            // Отвязанное имя в кеше бесполезно — освобождаем сразу.
            self.freeDentry(d);
            return;
        }
        // fs/dcache.c: dput() → d_lru_add(); inode остаётся живым до вытеснения.
        if (!d.isOnLru()) {
            list.addTail(&self.dentry_lru, &d.d_lru);
            self.nr_lru += 1;
        }
    }

    fn findInode(self: *SuperBlock, ino: u64) ?*Inode {
        const bucket = self.inodeBucket(ino);
        var cur = bucket.*;
        while (cur) |n| : (cur = n.next) {
            const i: *Inode = @fieldParentPtr("i_hash", n);
            if (i.i_ino == ino) {
                i.i_count += 1;
                return i;
            }
        }
        return null;
    }

    /// iget_locked(): найти инод по (sb, ino) или создать.
    pub fn iget(self: *SuperBlock, info: InodeInfo) !*Inode {
        // Номер inode мог быть переиспользован ФС после unlink, пока старый
        // dentry ещё жив в dcache. Освежить тип/размер, как ext4_iget() делает
        // для уже закешированного inode после изменения на диске.
        if (self.findInode(info.ino)) |i| {
            if (i.i_mode != info.mode) {
                if (i.i_link) |old| self.allocator.free(old);
                i.i_link = if (info.link) |link| try self.allocator.dupe(u8, link) else null;
            }
            i.i_mode = info.mode;
            i.i_size = info.size;
            return i;
        }
        const inode = try self.allocator.create(Inode);
        const link_copy = if (info.link) |link| try self.allocator.dupe(u8, link) else null;
        errdefer if (link_copy) |link| self.allocator.free(link);
        inode.* = .{
            .i_ino = info.ino,
            .i_mode = info.mode,
            .i_size = info.size,
            .i_sb = self,
            .i_link = link_copy,
        };
        inode.i_dentry = null;
        if (info.ino >= self.next_ino) self.next_ino = info.ino + 1;
        list.hAdd(self.inodeBucket(info.ino), &inode.i_hash);
        inode.hashed = true;
        self.nr_inodes += 1;
        return inode;
    }

    pub fn iput(self: *SuperBlock, inode: *Inode) void {
        if (inode.i_count > 0) inode.i_count -= 1;
        if (inode.i_count != 0) return;
        if (inode.hashed) {
            list.hDel(&inode.i_hash);
            inode.hashed = false;
        }
        if (inode.i_link) |link| self.allocator.free(link);
        self.nr_inodes -= 1;
        self.allocator.destroy(inode);
    }

    /// fs/namei.c: path_lookupat() — обход с разбором '.'/'..' и symlinks.
    pub fn lookupPath(self: *SuperBlock, path: []const u8, ops: LookupOps) !*Dentry {
        return self.walkPath(path, ops, true, null, null);
    }

    /// readlink()/lstat(): последний компонент symlink не разыменовывается.
    pub fn lookupPathNoFollow(self: *SuperBlock, path: []const u8, ops: LookupOps) !*Dentry {
        return self.walkPath(path, ops, false, null, null);
    }

    /// Общий обход: `ns != null` включает переход через mountpoint-ы и
    /// использует LookupOps каждого mount, а не один ops для всего superblock.
    fn walkPath(
        self: *SuperBlock,
        path: []const u8,
        ops: LookupOps,
        follow_final: bool,
        ns: ?*Namespace,
        out_mnt: ?*?*Mount,
    ) !*Dentry {
        // Компоненты складываются в стек: символьная ссылка добавляет свою
        // цель поверх остатка пути, как undo_list в fs/namei.c.
        var stack: [MAX_PATH_COMPONENTS][]const u8 = undefined;
        var sp: usize = 0;
        try pushComponents(&stack, &sp, path);

        // path_get(): один ref обхода живёт в `current` до возврата результата.
        var mnt: ?*Mount = if (ns) |n| n.root else null;
        var current: *Dentry = if (mnt) |m| m.root else self.s_root;
        current.d_count += 1;
        errdefer current.d_sb.dPut(current);
        if (out_mnt) |o| o.* = mnt;

        // Разыменованные symlink-ы держат свои inode живыми до конца обхода:
        // их i_link используется как буфер компонентов стека.
        var held: [SYMLOOP_MAX + 1]?*Dentry = undefined;
        var held_n: usize = 0;
        defer {
            for (held[0..held_n]) |d| d.?.d_sb.dPut(d.?);
        }

        var links: usize = 0;
        while (sp > 0) {
            const component = stack[sp - 1];
            sp -= 1;
            if (component.len == 0 or std.mem.eql(u8, component, ".")) continue;
            if (std.mem.eql(u8, component, "..")) {
                // follow_dotdot(): '..' на корне mount уходит в родительский
                // mount через dentry точки монтирования.
                if (mnt) |m| {
                    if (ns != null and current == m.root and m.parent != null and m.mountpoint != null) {
                        const mp = m.mountpoint.?;
                        const parent_d = mp.d_parent orelse mp;
                        parent_d.d_count += 1;
                        current.d_sb.dPut(current);
                        current = parent_d;
                        mnt = m.parent;
                        continue;
                    }
                }
                if (!current.isRoot()) {
                    const p = current.d_parent orelse current;
                    p.d_count += 1; // path_get(parent)
                    current.d_sb.dPut(current); // снять ref обхода с текущего
                    current = p;
                }
                continue;
            }
            const active_sb = if (mnt) |m| m.sb else self;
            const active_ops = if (mnt) |m| m.ops else ops;
            if (current.d_inode) |ino| {
                if (!ino.isDir()) return error.NotDir;
            }

            const q = makeQstr(component);
            var d = active_sb.dLookup(current, q);
            var negative: ?*Dentry = null;
            if (d) |existing| {
                // d_lookup() находит и отрицательные dentry — для path walk
                // они означают ENOENT, пока lookup() не создаст inode.
                if (existing.d_flags & DentryFlags.NEGATIVE != 0) {
                    negative = existing;
                    d = null;
                }
            }
            if (d == null) {
                const info = active_ops.lookup(active_ops.ctx, current, q) orelse {
                    if (negative) |neg| {
                        // dput() возвращает отрицательный dentry в LRU.
                        active_sb.dPut(neg);
                    } else {
                        const neg = try active_sb.allocDentry(current, q);
                        neg.d_flags |= DentryFlags.NEGATIVE;
                        active_sb.dRehash(neg);
                        active_sb.dPut(neg);
                    }
                    return error.NoEnt;
                };
                const inode = try active_sb.iget(info);
                errdefer active_sb.iput(inode);
                const fresh = negative orelse try active_sb.allocDentry(current, q);
                active_sb.dInstantiate(fresh, inode);
                active_sb.dRehash(fresh);
                d = fresh;
            }
            var next = d.?;
            if (next.d_inode) |ino| {
                if (ino.isLink()) {
                    if (!follow_final and sp == 0) {
                        current.d_sb.dPut(current);
                        current = next;
                        break;
                    }
                    links += 1;
                    if (links > SYMLOOP_MAX) {
                        next.d_sb.dPut(next);
                        return error.Loop;
                    }
                    const target = ino.i_link orelse {
                        next.d_sb.dPut(next);
                        return error.NoEnt;
                    };
                    if (target.len == 0) {
                        next.d_sb.dPut(next);
                        return error.NoEnt;
                    }
                    // Ссылка не становится `current`: относительная цель
                    // разыменовывается от родительского dentry. Dentry ссылки
                    // живёт до конца обхода, чтобы i_link оставался валидным.
                    held[held_n] = next;
                    held_n += 1;
                    if (target[0] == '/') {
                        current.d_sb.dPut(current);
                        if (ns) |n| {
                            mnt = n.root;
                            current = n.root.root;
                        } else {
                            current = self.s_root;
                        }
                        current.d_count += 1;
                    }
                    try pushComponents(&stack, &sp, target);
                    continue;
                }
            }
            // follow_managed(): dentry точки монтирования заменяется root ФС.
            if (ns) |n| {
                if (mnt) |m| {
                    if (n.mountFor(m, next)) |child| {
                        next.d_sb.dPut(next);
                        mnt = child;
                        next = child.root;
                        next.d_count += 1;
                    }
                }
            }
            current.d_sb.dPut(current); // снять ref обхода с родителя
            current = next;
        }
        // Текущий ref обхода и есть ref результата: dput() вызывающего
        // должен переводить dentry в LRU, а не оставлять «висячий» ref.
        if (out_mnt) |o| o.* = mnt;
        return current;
    }

    pub fn pathString(self: *SuperBlock, d: *Dentry, buf: []u8) ![]const u8 {
        var parts: [32][]const u8 = undefined;
        var n: usize = 0;
        var cur = d;
        while (!cur.isRoot()) {
            if (n >= parts.len) return error.NameTooLong;
            parts[n] = cur.d_name.name;
            n += 1;
            cur = cur.d_parent.?;
        }
        var len: usize = 1;
        for (parts[0..n]) |p| len += p.len + 1;
        if (len > buf.len) return error.NameTooLong;
        var pos: usize = 0;
        buf[pos] = '/';
        pos += 1;
        var i = n;
        while (i > 0) {
            i -= 1;
            @memcpy(buf[pos .. pos + parts[i].len], parts[i]);
            pos += parts[i].len;
            if (i > 0) {
                buf[pos] = '/';
                pos += 1;
            }
        }
        _ = self;
        return buf[0..pos];
    }
};

/// fs/namespace.c: namespace + list of mounts. Каждый mount удерживает dget()
/// на своей точке входа; umount() снимает эти ссылки.
pub const Namespace = struct {
    allocator: std.mem.Allocator,
    root: *Mount,
    mounts: std.ArrayList(*Mount) = .empty,
    /// namespace делится между задачами без CLONE_NEWNS; последняя ссылка
    /// вызывает deinit(). Тесты, создающие namespace на стеке, вызывают
    /// deinit() напрямую и не пользуются get()/put().
    ref_count: u32 = 1,

    /// In-place инициализация: Mount.ns указывает на этот namespace, поэтому
    /// его адрес не должен меняться после создания.
    pub fn init(self: *Namespace, allocator: std.mem.Allocator, sb: *SuperBlock, ops: LookupOps) !void {
        const m = try allocator.create(Mount);
        errdefer allocator.destroy(m);
        m.* = .{ .sb = sb, .ops = ops, .root = sb.s_root, .ns = self };
        sb.s_root.d_count += 1;
        errdefer sb.s_root.d_sb.dPut(sb.s_root);
        self.* = .{ .allocator = allocator, .root = m };
        try self.mounts.append(allocator, m);
    }

    pub fn get(self: *Namespace) void {
        self.ref_count += 1;
    }

    /// put_task_ns(): последняя ссылка освобождает namespace и его mounts.
    pub fn put(self: *Namespace) void {
        if (self.ref_count > 0) self.ref_count -= 1;
        if (self.ref_count == 0) {
            self.deinit();
            self.allocator.destroy(self);
        }
    }

    pub fn deinit(self: *Namespace) void {
        // Снимаем в обратном порядке: позже смонтированные дети идут после
        // родителя в self.mounts.
        while (self.mounts.items.len > 1) {
            self.detach(self.mounts.items[self.mounts.items.len - 1]);
        }
        const root = self.root;
        if (root.group) |g| g.remove(root);
        root.root.d_sb.dPut(root.root);
        root.children.deinit(self.allocator);
        self.allocator.destroy(root);
        self.mounts.deinit(self.allocator);
    }

    /// fs/namespace.c: copy_tree() — CLONE_NEWNS/unshare(CLONE_NEWNS).
    /// Разделяемые mount остаются в тех же peer group, приватные копируются
    /// независимо: изменения в новой namespace не видны родительской.
    pub fn clone(self: *Namespace, out: *Namespace) !void {
        out.* = .{ .allocator = self.allocator, .root = undefined };
        errdefer out.freeClonedMounts();

        var map = std.AutoHashMap(*Mount, *Mount).init(self.allocator);
        defer map.deinit();

        for (self.mounts.items) |src| {
            if (src.group) |g| try g.members.ensureUnusedCapacity(self.allocator, 1);
            const dst = try self.allocator.create(Mount);
            errdefer self.allocator.destroy(dst);
            dst.* = .{
                .sb = src.sb,
                .ops = src.ops,
                .root = src.root,
                .mountpoint = src.mountpoint,
                .ns = out,
                .propagation = src.propagation,
            };
            src.root.d_count += 1;
            if (src.mountpoint) |mp| mp.d_count += 1;
            errdefer {
                src.root.d_sb.dPut(src.root);
                if (src.mountpoint) |mp| mp.d_sb.dPut(mp);
            }
            try out.mounts.append(self.allocator, dst);
            try map.put(src, dst);
        }
        for (self.mounts.items) |src| {
            if (src.parent) |sp| {
                try map.get(sp).?.children.ensureUnusedCapacity(self.allocator, 1);
            }
        }
        for (self.mounts.items) |src| {
            const dst = map.get(src).?;
            if (src.parent) |sp| {
                const dp = map.get(sp).?;
                dst.parent = dp;
                dp.children.appendAssumeCapacity(dst);
            }
            if (src.group) |g| {
                g.members.appendAssumeCapacity(dst);
                dst.group = g;
                dst.propagation = .shared;
            }
        }
        out.root = map.get(self.root).?;
    }

    fn freeClonedMounts(self: *Namespace) void {
        for (self.mounts.items) |m| {
            if (m.group) |g| g.remove(m);
            m.root.d_sb.dPut(m.root);
            if (m.mountpoint) |mp| mp.d_sb.dPut(mp);
            m.children.deinit(self.allocator);
            self.allocator.destroy(m);
        }
        self.mounts.deinit(self.allocator);
    }

    pub fn lookupPath(self: *Namespace, path: []const u8) !*Dentry {
        return (try self.lookupPathWithMount(path, true)).dentry;
    }

    pub fn lookupPathNoFollow(self: *Namespace, path: []const u8) !*Dentry {
        return (try self.lookupPathWithMount(path, false)).dentry;
    }

    pub fn lookupPathWithMount(self: *Namespace, path: []const u8, follow_final: bool) !Path {
        var mnt: ?*Mount = null;
        const d = try self.root.sb.walkPath(path, self.root.ops, follow_final, self, &mnt);
        return .{ .mnt = mnt orelse unreachable, .dentry = d };
    }

    const NameSplit = struct { parent: []const u8, name: []const u8 };

    fn splitName(path: []const u8) !NameSplit {
        if (path.len == 0 or path[0] != '/' or path[path.len - 1] == '/') return error.Invalid;
        const slash = std.mem.lastIndexOfScalar(u8, path, '/') orelse return error.Invalid;
        const name = path[slash + 1 ..];
        if (name.len == 0 or name.len > 255) return error.NameTooLong;
        return .{ .parent = if (slash == 0) "/" else path[0..slash], .name = name };
    }

    /// fs/namei.c: vfs_create() — записать имя на носителе, затем связать
    /// dentry/inode в dcache. Возвращает dentry с одним dget() для вызывающего.
    pub fn createAt(self: *Namespace, path: []const u8) !*Dentry {
        const parts = try splitName(path);
        const p = try self.lookupPathWithMount(parts.parent, true);
        const parent = p.dentry;
        defer parent.d_sb.dPut(parent);
        const ops = parent.d_sb.s_dir_ops;
        const create = ops.create orelse return error.NotSupported;
        const q = makeQstr(parts.name);
        if (parent.d_sb.dLookup(parent, q)) |old| {
            const exists = old.d_flags & DentryFlags.NEGATIVE == 0;
            parent.d_sb.dPut(old);
            if (exists) return error.PathExists;
        }
        const info = try create(ops.ctx, parent, q);
        return try parent.d_sb.createNode(parent, q, info);
    }

    /// fs/namei.c: vfs_mkdir() — записать новый каталог на носителе, затем
    /// связать dentry/inode в dcache. Возвращает dentry с одним dget().
    pub fn mkdirAt(self: *Namespace, path: []const u8) !*Dentry {
        const parts = try splitName(path);
        const p = try self.lookupPathWithMount(parts.parent, true);
        const parent = p.dentry;
        defer parent.d_sb.dPut(parent);
        const ops = parent.d_sb.s_dir_ops;
        const mkdir = ops.mkdir orelse return error.NotSupported;
        const q = makeQstr(parts.name);
        if (parent.d_sb.dLookup(parent, q)) |old| {
            const exists = old.d_flags & DentryFlags.NEGATIVE == 0;
            parent.d_sb.dPut(old);
            if (exists) return error.PathExists;
        }
        const info = try mkdir(ops.ctx, parent, q);
        return try parent.d_sb.createNode(parent, q, info);
    }

    /// fs/namei.c: vfs_rmdir() — проверить пустоту каталога на носителе и в
    /// dcache, затем удалить имя. dentry снимается с хеша только после успешной
    /// мутации ФС, как и в unlinkAt().
    pub fn rmdirAt(self: *Namespace, path: []const u8) !void {
        const parts = try splitName(path);
        if (std.mem.eql(u8, parts.name, ".") or std.mem.eql(u8, parts.name, "..")) return error.Invalid;
        const p = try self.lookupPathWithMount(parts.parent, true);
        const parent = p.dentry;
        defer parent.d_sb.dPut(parent);
        const ops = parent.d_sb.s_dir_ops;
        const rmdir = ops.rmdir orelse return error.NotSupported;
        const q = makeQstr(parts.name);
        if (parent.d_sb.dLookup(parent, q) == null) {
            const target = self.lookupPathWithMount(path, false) catch return error.NoEnt;
            target.dentry.d_sb.dPut(target.dentry);
        }
        try rmdir(ops.ctx, parent, q);
        try parent.d_sb.unlinkNode(parent, q, true);
    }

    /// fs/namei.c: vfs_unlink() — сначала убрать имя с носителя, потом из
    /// dcache. dentry должен быть проинстанцирован (обычно через lookupPath).
    pub fn unlinkAt(self: *Namespace, path: []const u8) !void {
        const parts = try splitName(path);
        const p = try self.lookupPathWithMount(parts.parent, true);
        const parent = p.dentry;
        defer parent.d_sb.dPut(parent);
        const ops = parent.d_sb.s_dir_ops;
        const unlink = ops.unlink orelse return error.NotSupported;
        const q = makeQstr(parts.name);
        if (parent.d_sb.dLookup(parent, q) == null) {
            const target = self.lookupPathWithMount(path, false) catch return error.NoEnt;
            target.dentry.d_sb.dPut(target.dentry);
        }
        try unlink(ops.ctx, parent, q);
        try parent.d_sb.unlinkNode(parent, q, false);
    }

    fn mountFor(self: *Namespace, parent: *Mount, d: *Dentry) ?*Mount {
        _ = self;
        for (parent.children.items) |m| {
            if (m.mountpoint == d and !m.detached) return m;
        }
        return null;
    }

    /// do_add_mount(): привязать source_sb к уже найденной точке монтирования.
    fn mountOn(
        self: *Namespace,
        parent: *Mount,
        mp: *Dentry,
        source_sb: *SuperBlock,
        ops: LookupOps,
        group: ?*PeerGroup,
        flags: u8,
    ) !*Mount {
        if (mp.d_inode) |ino| {
            if (!ino.isDir()) return error.NotDir;
        }
        const m = try self.allocator.create(Mount);
        errdefer self.allocator.destroy(m);
        m.* = .{
            .sb = source_sb,
            .ops = ops,
            .root = source_sb.s_root,
            .mountpoint = mp,
            .parent = parent,
            .ns = self,
        };
        mp.d_count += 1; // dget(mountpoint), живёт до umount()
        source_sb.s_root.d_count += 1; // dget(mnt_root)
        errdefer {
            mp.d_sb.dPut(mp);
            source_sb.s_root.d_sb.dPut(source_sb.s_root);
        }

        // Новый mount становится shared, если явно запрошен MS_SHARED или
        // родитель уже разделяемый; MS_PRIVATE разрывает propagation.
        var target_group = group;
        if (flags & MountFlags.private == 0 and group == null and
            (flags & MountFlags.shared != 0 or parent.group != null))
        {
            const g = try self.allocator.create(PeerGroup);
            errdefer self.allocator.destroy(g);
            g.* = .{ .allocator = self.allocator };
            target_group = g;
        }
        if (target_group) |g| try g.members.ensureUnusedCapacity(self.allocator, 1);
        try parent.children.ensureUnusedCapacity(self.allocator, 1);
        try self.mounts.ensureUnusedCapacity(self.allocator, 1);

        parent.children.appendAssumeCapacity(m);
        self.mounts.appendAssumeCapacity(m);
        if (target_group) |g| {
            g.members.appendAssumeCapacity(m);
            m.group = g;
            m.propagation = .shared;
        }
        return m;
    }

    /// fs/namespace.c: do_new_mount() — привязать source_sb к каталогу target.
    pub fn mount(self: *Namespace, source_sb: *SuperBlock, ops: LookupOps, target: []const u8) !*Mount {
        return self.mountWithFlags(source_sb, ops, target, 0);
    }

    /// propagate_mnt(): новый mount под shared-родителем повторяется на всех
    /// пирах родителя в других namespace-ах.
    pub fn mountWithFlags(self: *Namespace, source_sb: *SuperBlock, ops: LookupOps, target: []const u8, flags: u8) !*Mount {
        const p = try self.lookupPathWithMount(target, true);
        defer p.dentry.d_sb.dPut(p.dentry); // ref path walk
        const parent_group = p.mnt.group;
        const m = try self.mountOn(p.mnt, p.dentry, source_sb, ops, null, flags);
        var propagated = std.ArrayList(*Mount).empty;
        defer propagated.deinit(self.allocator);
        errdefer {
            for (propagated.items) |pm| {
                if (!pm.detached) pm.ns.?.detach(pm);
            }
            if (!m.detached) self.detach(m);
        }
        if (parent_group) |pg| {
            for (pg.members.items) |peer| {
                if (peer == p.mnt) continue;
                const peer_ns = peer.ns orelse continue;
                if (peer_ns.mountFor(peer, p.dentry) != null) continue;
                const copy = try peer_ns.mountOn(peer, p.dentry, source_sb, ops, m.group, MountFlags.private);
                try propagated.append(self.allocator, copy);
            }
        }
        return m;
    }

    /// fs/namespace.c: do_umount() — снять mount, если он не занят детьми.
    /// Umount под shared-родителем и umount shared mount распространяются на
    /// пиры так же, как mount.
    pub fn umount(self: *Namespace, target: []const u8) !void {
        const p = try self.lookupPathWithMount(target, true);
        defer p.dentry.d_sb.dPut(p.dentry);
        if (p.mnt == self.root or p.dentry != p.mnt.root) return error.Inval;
        const m = p.mnt;
        const mp = m.mountpoint orelse return error.Inval;

        var victims = std.ArrayList(*Mount).empty;
        defer victims.deinit(self.allocator);
        try victims.append(self.allocator, m);
        if (m.group) |g| {
            for (g.members.items) |peer| {
                if (peer != m) try victims.append(self.allocator, peer);
            }
        }
        if (m.parent) |parent| {
            if (parent.group) |pg| {
                for (pg.members.items) |peer| {
                    const peer_ns = peer.ns orelse continue;
                    const child = peer_ns.mountFor(peer, mp) orelse continue;
                    var seen = false;
                    for (victims.items) |v| {
                        if (v == child) seen = true;
                    }
                    if (!seen) try victims.append(self.allocator, child);
                }
            }
        }
        for (victims.items) |v| {
            if (v.children.items.len != 0) return error.Busy;
        }
        for (victims.items) |v| {
            if (!v.detached) v.ns.?.detach(v);
        }
    }

    fn detach(self: *Namespace, m: *Mount) void {
        m.detached = true;
        if (m.parent) |parent| {
            for (parent.children.items, 0..) |child, i| {
                if (child == m) {
                    _ = parent.children.orderedRemove(i);
                    break;
                }
            }
        }
        for (self.mounts.items, 0..) |item, i| {
            if (item == m) {
                _ = self.mounts.orderedRemove(i);
                break;
            }
        }
        if (m.mountpoint) |mp| mp.d_sb.dPut(mp);
        m.root.d_sb.dPut(m.root);
        if (m.group) |g| {
            m.group = null;
            m.propagation = .private;
            g.remove(m);
        }
        m.children.deinit(self.allocator);
        self.allocator.destroy(m);
    }
};

test "dcache + path walk: lookup, cache hit, dot/dotdot, negative entry" {
    const Fixture = struct {
        const Entry = struct {
            path: []const u8,
            ino: u64,
            mode: u32,
            link: ?[]const u8 = null,
        };
        const table = [_]Entry{
            .{ .path = "/usr", .ino = 10, .mode = S_IFDIR },
            .{ .path = "/usr/bin", .ino = 11, .mode = S_IFDIR },
            .{ .path = "/usr/bin/zig", .ino = 12, .mode = S_IFREG },
            .{ .path = "/etc", .ino = 20, .mode = S_IFDIR },
            .{ .path = "/etc/passwd", .ino = 21, .mode = S_IFREG },
            .{ .path = "/bin", .ino = 30, .mode = S_IFLNK | 0o777, .link = "usr/bin" },
            .{ .path = "/etc/zig", .ino = 31, .mode = S_IFLNK | 0o777, .link = "/usr/bin/zig" },
            .{ .path = "/loopa", .ino = 32, .mode = S_IFLNK | 0o777, .link = "/loopb" },
            .{ .path = "/loopb", .ino = 33, .mode = S_IFLNK | 0o777, .link = "/loopa" },
        };

        fn lookup(ctx: ?*anyopaque, parent: *Dentry, q: Qstr) ?InodeInfo {
            _ = ctx;
            const sb = parent.d_sb;
            var buf: [256]u8 = undefined;
            const p = sb.pathString(parent, &buf) catch return null;
            var full: [512]u8 = undefined;
            const joined = if (std.mem.eql(u8, p, "/"))
                std.fmt.bufPrint(&full, "/{s}", .{q.name}) catch return null
            else
                std.fmt.bufPrint(&full, "{s}/{s}", .{ p, q.name }) catch return null;
            for (table) |e| {
                if (std.mem.eql(u8, e.path, joined)) return .{ .ino = e.ino, .mode = e.mode, .link = e.link };
            }
            return null;
        }

        fn ops() LookupOps {
            return .{ .lookup = lookup };
        }
    };

    var sb: SuperBlock = undefined;
    try sb.init(std.testing.allocator, 64);
    defer sb.deinit();
    const ops = Fixture.ops();

    const zig = try sb.lookupPath("/usr/bin/zig", ops);
    defer sb.dPut(zig);
    try std.testing.expectEqual(@as(u64, 12), zig.d_inode.?.i_ino);

    // Повторный поиск должен попасть в dcache (новый inode не создаётся).
    const nr_before = sb.nr_inodes;
    const zig2 = try sb.lookupPath("./usr/bin/./zig", ops);
    defer sb.dPut(zig2);
    try std.testing.expectEqual(zig, zig2);
    try std.testing.expectEqual(nr_before, sb.nr_inodes);

    const passwd = try sb.lookupPath("/usr/bin/../../etc/passwd", ops);
    defer sb.dPut(passwd);
    try std.testing.expectEqual(@as(u64, 21), passwd.d_inode.?.i_ino);

    try std.testing.expectError(error.NoEnt, sb.lookupPath("/no/such/file", ops));
    try std.testing.expectError(error.NotDir, sb.lookupPath("/usr/bin/zig/child", ops));

    // fs/namei.c: относительная и абсолютная symlink, плюс readlink без
    // разыменования последнего компонента.
    const via_rel = try sb.lookupPath("/bin/zig", ops);
    defer sb.dPut(via_rel);
    try std.testing.expectEqual(@as(u64, 12), via_rel.d_inode.?.i_ino);

    const via_abs = try sb.lookupPath("/etc/zig", ops);
    defer sb.dPut(via_abs);
    try std.testing.expectEqual(zig, via_abs);

    const link = try sb.lookupPathNoFollow("/etc/zig", ops);
    defer sb.dPut(link);
    try std.testing.expect(link.d_inode.?.isLink());
    try std.testing.expectEqualStrings("/usr/bin/zig", link.d_inode.?.i_link.?);

    try std.testing.expectError(error.Loop, sb.lookupPath("/loopa", ops));
}

const MountTable = struct {
    const Ent = struct {
        path: []const u8,
        ino: u64,
        mode: u32,
        link: ?[]const u8 = null,
    };

    entries: []const Ent,

    fn lookup(ctx: ?*anyopaque, parent: *Dentry, q: Qstr) ?InodeInfo {
        const t: *const MountTable = @ptrCast(@alignCast(ctx orelse return null));
        var buf: [256]u8 = undefined;
        const p = parent.d_sb.pathString(parent, &buf) catch return null;
        var full: [512]u8 = undefined;
        const joined = if (std.mem.eql(u8, p, "/"))
            std.fmt.bufPrint(&full, "/{s}", .{q.name}) catch return null
        else
            std.fmt.bufPrint(&full, "{s}/{s}", .{ p, q.name }) catch return null;
        for (t.entries) |e| {
            if (std.mem.eql(u8, e.path, joined)) {
                return .{ .ino = e.ino, .mode = e.mode, .link = e.link };
            }
        }
        return null;
    }

    fn ops(self: *const MountTable) LookupOps {
        return .{ .ctx = @constCast(self), .lookup = lookup };
    }
};

const SuperFixture = struct {
    const Counters = struct { syncs: u32 = 0 };

    fn statfs(_: ?*anyopaque, sb: *SuperBlock) SuperStats {
        return .{
            .magic = 0x1234,
            .bsize = 1024,
            .blocks = 10,
            .bfree = 4,
            .bavail = 4,
            .files = sb.nr_inodes,
            .ffree = 2,
        };
    }

    fn sync(ctx: ?*anyopaque, _: *SuperBlock) void {
        const c: *Counters = @ptrCast(@alignCast(ctx orelse return));
        c.syncs += 1;
    }
};

test "mount namespace: traverse mountpoints, dotdot back, umount and super_operations" {
    const root_entries = [_]MountTable.Ent{
        .{ .path = "/mnt", .ino = 2, .mode = S_IFDIR },
        .{ .path = "/etc", .ino = 3, .mode = S_IFDIR },
        .{ .path = "/etc/rootfile", .ino = 4, .mode = S_IFREG },
    };
    const mid_entries = [_]MountTable.Ent{
        .{ .path = "/frommnt", .ino = 101, .mode = S_IFREG },
        .{ .path = "/sub", .ino = 102, .mode = S_IFDIR },
        .{ .path = "/sub/leaf", .ino = 103, .mode = S_IFREG },
    };
    const nested_entries = [_]MountTable.Ent{
        .{ .path = "/nested", .ino = 201, .mode = S_IFREG },
    };

    var root_table = MountTable{ .entries = &root_entries };
    var mid_table = MountTable{ .entries = &mid_entries };
    var nested_table = MountTable{ .entries = &nested_entries };
    var root_sb: SuperBlock = undefined;
    var mid_sb: SuperBlock = undefined;
    var nested_sb: SuperBlock = undefined;
    try root_sb.init(std.testing.allocator, 64);
    defer root_sb.deinit();
    try mid_sb.init(std.testing.allocator, 64);
    defer mid_sb.deinit();
    try nested_sb.init(std.testing.allocator, 64);
    defer nested_sb.deinit();

    var ns: Namespace = undefined;
    try ns.init(std.testing.allocator, &root_sb, root_table.ops());
    defer ns.deinit();
    _ = try ns.mount(&mid_sb, mid_table.ops(), "/mnt");

    // follow_managed(): /mnt/frommnt продолжает обход уже в смонтированной ФС.
    const from_mnt = try ns.lookupPathWithMount("/mnt/frommnt", true);
    defer from_mnt.dentry.d_sb.dPut(from_mnt.dentry);
    try std.testing.expectEqual(&mid_sb, from_mnt.mnt.sb);
    try std.testing.expectEqual(@as(u64, 101), from_mnt.dentry.d_inode.?.i_ino);

    // '..' внутри mount остаётся внутри, а на корне mount уходит в родительский.
    const up_mid = try ns.lookupPathWithMount("/mnt/sub/leaf/..", true);
    defer up_mid.dentry.d_sb.dPut(up_mid.dentry);
    try std.testing.expectEqual(&mid_sb, up_mid.mnt.sb);
    try std.testing.expectEqual(@as(u64, 102), up_mid.dentry.d_inode.?.i_ino);

    const up_root = try ns.lookupPathWithMount("/mnt/../etc/rootfile", true);
    defer up_root.dentry.d_sb.dPut(up_root.dentry);
    try std.testing.expectEqual(&root_sb, up_root.mnt.sb);
    try std.testing.expectEqual(@as(u64, 4), up_root.dentry.d_inode.?.i_ino);

    // Вложенный mount: /mnt/sub теперь указывает на третий superblock.
    _ = try ns.mount(&nested_sb, nested_table.ops(), "/mnt/sub");
    const nested = try ns.lookupPathWithMount("/mnt/sub/nested", true);
    defer nested.dentry.d_sb.dPut(nested.dentry);
    try std.testing.expectEqual(&nested_sb, nested.mnt.sb);

    try std.testing.expectError(error.Busy, ns.umount("/mnt"));
    try ns.umount("/mnt/sub");
    const after_nested = try ns.lookupPathWithMount("/mnt/sub/leaf", true);
    defer after_nested.dentry.d_sb.dPut(after_nested.dentry);
    try std.testing.expectEqual(&mid_sb, after_nested.mnt.sb);

    try ns.umount("/mnt");
    const after_umount = try ns.lookupPathWithMount("/mnt", true);
    defer after_umount.dentry.d_sb.dPut(after_umount.dentry);
    try std.testing.expectEqual(&root_sb, after_umount.mnt.sb);
    try std.testing.expectEqual(@as(u64, 2), after_umount.dentry.d_inode.?.i_ino);
    try std.testing.expectError(error.Inval, ns.umount("/etc"));

    // struct super_operations: statfs() и sync_fs() вызываются через sb.
    var counters = SuperFixture.Counters{};
    root_sb.setSuperOps(.{
        .ctx = &counters,
        .statfs = SuperFixture.statfs,
        .sync_fs = SuperFixture.sync,
    });
    const st = root_sb.statfs();
    try std.testing.expectEqual(@as(u64, 0x1234), st.magic);
    try std.testing.expectEqual(@as(u64, 1024), st.bsize);
    try std.testing.expectEqual(@as(u64, 10), st.blocks);
    try std.testing.expectEqual(@as(u64, 4), st.bfree);
    try std.testing.expectEqual(root_sb.nr_inodes, st.files);
    root_sb.syncFs();
    mid_sb.syncFs(); // без super_operations — no-op
    try std.testing.expectEqual(@as(u32, 1), counters.syncs);
}

test "dentry LRU: dput, dget resurrection, negative entries and prune_dcache_sb" {
    const entries = [_]MountTable.Ent{
        .{ .path = "/a", .ino = 10, .mode = S_IFDIR },
        .{ .path = "/a/b", .ino = 11, .mode = S_IFREG },
    };
    var table = MountTable{ .entries = &entries };
    var sb: SuperBlock = undefined;
    try sb.init(std.testing.allocator, 16);
    defer sb.deinit();
    const ops = table.ops();

    const d = try sb.lookupPath("/a/b", ops);
    try std.testing.expectEqual(@as(u32, 1), d.d_count);
    try std.testing.expectEqual(@as(usize, 0), sb.nr_lru);
    sb.dPut(d);
    try std.testing.expect(d.isOnLru());
    try std.testing.expectEqual(@as(usize, 1), sb.nr_lru);

    // d_lookup() находит dentry в hcache и снимает её с LRU (dget).
    const parent = try sb.lookupPath("/a", ops);
    const revived = sb.dLookup(parent, makeQstr("b")) orelse unreachable;
    try std.testing.expectEqual(d, revived);
    try std.testing.expect(!revived.isOnLru());
    try std.testing.expectEqual(@as(usize, 0), sb.nr_lru);
    sb.dPut(revived);
    sb.dPut(parent);
    try std.testing.expectEqual(@as(usize, 1), sb.nr_lru);

    // Отрицательный dentry тоже живёт в LRU и вытесняется prune_dcache_sb().
    try std.testing.expectError(error.NoEnt, sb.lookupPath("/nope", ops));
    try std.testing.expectEqual(@as(usize, 2), sb.nr_lru);
    sb.pruneDcache(0);
    try std.testing.expectEqual(@as(usize, 0), sb.nr_lru);
    try std.testing.expectEqual(@as(usize, 1), sb.nr_dentries); // только root
    const fresh = try sb.lookupPath("/a/b", ops);
    defer sb.dPut(fresh);
    try std.testing.expect(fresh != d);
    try std.testing.expectEqual(@as(u64, 11), fresh.d_inode.?.i_ino);
}

test "CLONE_NEWNS copy_tree: private isolation, shared propagation and umount" {
    const root_entries = [_]MountTable.Ent{
        .{ .path = "/shared", .ino = 2, .mode = S_IFDIR },
        .{ .path = "/private", .ino = 3, .mode = S_IFDIR },
    };
    const shared_entries = [_]MountTable.Ent{
        .{ .path = "/sub", .ino = 100, .mode = S_IFDIR },
        .{ .path = "/file", .ino = 101, .mode = S_IFREG },
    };
    const private_entries = [_]MountTable.Ent{
        .{ .path = "/file", .ino = 200, .mode = S_IFREG },
    };
    const extra_entries = [_]MountTable.Ent{
        .{ .path = "/fromextra", .ino = 300, .mode = S_IFREG },
    };

    var root_table = MountTable{ .entries = &root_entries };
    var shared_table = MountTable{ .entries = &shared_entries };
    var private_table = MountTable{ .entries = &private_entries };
    var extra_table = MountTable{ .entries = &extra_entries };
    var root_sb: SuperBlock = undefined;
    var shared_sb: SuperBlock = undefined;
    var private_sb: SuperBlock = undefined;
    var extra_sb: SuperBlock = undefined;
    try root_sb.init(std.testing.allocator, 16);
    defer root_sb.deinit();
    try shared_sb.init(std.testing.allocator, 16);
    defer shared_sb.deinit();
    try private_sb.init(std.testing.allocator, 16);
    defer private_sb.deinit();
    try extra_sb.init(std.testing.allocator, 16);
    defer extra_sb.deinit();

    var parent: Namespace = undefined;
    try parent.init(std.testing.allocator, &root_sb, root_table.ops());
    defer parent.deinit();
    _ = try parent.mountWithFlags(&shared_sb, shared_table.ops(), "/shared", MountFlags.shared);
    try std.testing.expectEqual(@as(usize, 2), parent.mounts.items.len);

    var child: Namespace = undefined;
    try parent.clone(&child);
    defer child.deinit();
    try std.testing.expectEqual(@as(usize, 2), child.mounts.items.len);
    try std.testing.expect(parent.mounts.items[1].group != null);
    try std.testing.expectEqual(parent.mounts.items[1].group, child.mounts.items[1].group);

    // Обе namespace видят исходный mount; после копирования он один peer group.
    for ([_]*Namespace{ &parent, &child }) |ns| {
        const seen = try ns.lookupPathWithMount("/shared/file", true);
        defer seen.dentry.d_sb.dPut(seen.dentry);
        try std.testing.expectEqual(&shared_sb, seen.mnt.sb);
    }

    // Приватный mount в дочерней namespace не виден родительской.
    _ = try child.mount(&private_sb, private_table.ops(), "/private");
    const hidden = parent.lookupPath("/private/file");
    try std.testing.expectError(error.NoEnt, hidden);

    // Mount под shared-родителем распространяется на пира в родительской ns.
    _ = try child.mount(&extra_sb, extra_table.ops(), "/shared/sub");
    const propagated = try parent.lookupPathWithMount("/shared/sub/fromextra", true);
    defer propagated.dentry.d_sb.dPut(propagated.dentry);
    try std.testing.expectEqual(&extra_sb, propagated.mnt.sb);

    // И снятие mount распространяется на оба namespace-а.
    try child.umount("/shared/sub");
    try std.testing.expectError(error.NoEnt, parent.lookupPath("/shared/sub/fromextra"));
    try std.testing.expectError(error.NoEnt, child.lookupPath("/shared/sub/fromextra"));
}
