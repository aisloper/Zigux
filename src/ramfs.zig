//! Минимальный in-memory FS для порта Linux 7.3: реальный path walk через
//! vfs.SuperBlock.lookupPath() + struct file с file_operations. Это не ext4,
//! но уже настоящий namei (dcache/inode по компонентам), а не плоский registry.
//! Источники: fs/ramfs/inode.c, fs/namei.c, include/linux/fs.h.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const vfs = @import("vfs.zig");
const file = @import("file.zig");

/// include/uapi/linux/magic.h: RAMFS_MAGIC.
pub const RAMFS_MAGIC: u64 = 0x8584_58f6;

pub const Entry = struct {
    allocator: std.mem.Allocator,
    path: []u8,
    data: []u8,
    ino: u64,
    mode: u32 = vfs.S_IFREG,
    /// Symlink имеет inode/dentry, но не открывается как struct file.
    f: ?*file.File = null,
    /// unlink() убирает имя, но struct file остаётся живым до закрытия fd.
    deleted: bool = false,
};

/// struct super_operations + private data ФС, привязанные к общему VFS-ядру.
pub const RamFs = struct {
    allocator: std.mem.Allocator,
    sb: *vfs.SuperBlock,
    entries: std.ArrayList(*Entry) = .empty,
    next_ino: u64 = 100,

    pub fn init(allocator: std.mem.Allocator, sb: *vfs.SuperBlock) RamFs {
        sb.setSuperOps(.{ .statfs = statfs, .sync_fs = syncFs });
        return .{ .allocator = allocator, .sb = sb };
    }

    pub fn deinit(self: *RamFs) void {
        for (self.entries.items) |e| {
            if (e.f) |f| {
                if (f.dentry) |d| {
                    self.sb.dPut(d); // снять ссылку, которую держит struct file
                    f.dentry = null;
                }
                self.allocator.destroy(f);
            }
            self.allocator.free(e.path);
            self.allocator.free(e.data);
            self.allocator.destroy(e);
        }
        self.entries.deinit(self.allocator);
    }

    fn findEntry(self: *const RamFs, path: []const u8) ?*Entry {
        for (self.entries.items) |e| {
            if (!e.deleted and std.mem.eql(u8, e.path, path)) return e;
        }
        return null;
    }

    const PathSplit = struct { parent: []const u8, name: []const u8 };

    fn splitPath(path: []const u8) PathSplit {
        if (std.mem.lastIndexOfScalar(u8, path, '/')) |slash| {
            const parent = if (slash == 0) "/" else path[0..slash];
            return .{ .parent = parent, .name = path[slash + 1 ..] };
        }
        return .{ .parent = "/", .name = path };
    }

    fn entryInfo(e: *const Entry) vfs.InodeInfo {
        return .{
            .ino = e.ino,
            .mode = e.mode,
            .size = e.data.len,
            .link = if (e.mode & 0o170000 == vfs.S_IFLNK) e.data else null,
        };
    }

    fn newEntry(self: *RamFs, path: []const u8, data: []const u8, mode: u32) !*Entry {
        if (self.findEntry(path) != null) return error.PathExists;
        const e = try self.allocator.create(Entry);
        errdefer self.allocator.destroy(e);
        const path_copy = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(path_copy);
        const data_copy = try self.allocator.dupe(u8, data);
        errdefer self.allocator.free(data_copy);
        e.* = .{
            .allocator = self.allocator,
            .path = path_copy,
            .data = data_copy,
            .ino = self.next_ino,
            .mode = mode,
        };
        self.next_ino += 1;
        try self.entries.append(self.allocator, e);
        errdefer _ = self.entries.pop();
        return e;
    }

    fn dataRead(ctx: ?*anyopaque, _: *file.File, buf: []u8, pos: u64) i64 {
        const e: *Entry = @ptrCast(@alignCast(ctx orelse return -file.Errno.EIO));
        if (pos >= e.data.len) return 0;
        const n = @min(buf.len, e.data.len - @as(usize, @intCast(pos)));
        @memcpy(buf[0..n], e.data[@intCast(pos)..][0..n]);
        return @intCast(n);
    }

    fn dataWrite(ctx: ?*anyopaque, _: *file.File, bytes: []const u8, pos: u64) i64 {
        const e: *Entry = @ptrCast(@alignCast(ctx orelse return -file.Errno.EIO));
        // generic_file_write_iter(): запись за концом файла расширяет данные.
        if (pos > std.math.maxInt(usize) or bytes.len > std.math.maxInt(usize) - @as(usize, @intCast(pos))) return -file.Errno.EINVAL;
        const start: usize = @intCast(pos);
        const end = start + bytes.len;
        if (end > e.data.len) {
            e.data = e.allocator.realloc(e.data, end) catch return -file.Errno.ENOMEM;
        }
        @memcpy(e.data[start..end], bytes);
        return @intCast(bytes.len);
    }

    fn dataSeek(ctx: ?*anyopaque, f: *file.File, off: i64, whence: u8) i64 {
        const e: *Entry = @ptrCast(@alignCast(ctx orelse return -file.Errno.EIO));
        const base: i64 = switch (whence) {
            file.SEEK_SET => 0,
            file.SEEK_CUR => @intCast(f.f_pos),
            file.SEEK_END => @intCast(e.data.len),
            else => return -file.Errno.EINVAL,
        };
        const res = base + off;
        return if (res < 0) -file.Errno.EINVAL else res;
    }

    /// fs/ramfs/inode.c: lookup() — по имени из dcache вернуть inode.
    fn lookup(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) ?vfs.InodeInfo {
        const self: *RamFs = @ptrCast(@alignCast(ctx orelse return null));
        var parent_buf: [512]u8 = undefined;
        const p = self.sb.pathString(parent, &parent_buf) catch return null;
        var full_buf: [1024]u8 = undefined;
        const joined = if (std.mem.eql(u8, p, "/"))
            std.fmt.bufPrint(&full_buf, "/{s}", .{q.name}) catch return null
        else
            std.fmt.bufPrint(&full_buf, "{s}/{s}", .{ p, q.name }) catch return null;
        if (self.findEntry(joined)) |e| return entryInfo(e);
        // Промежуточный компонент (/etc в /etc/version) — синтетическая
        // директория RamFs: fs/ramfs/inode.c создаёт inode по требованию.
        for (self.entries.items) |e| {
            if (e.deleted) continue;
            if (e.path.len > joined.len and std.mem.startsWith(u8, e.path, joined) and e.path[joined.len] == '/') {
                const dir_ino: u64 = @as(u64, vfs.hashName(joined)) | 0x1_0000_0000;
                return .{ .ino = dir_ino, .mode = vfs.S_IFDIR | 0o755, .size = 0 };
            }
        }
        return null;
    }

    /// fs/super.c: super_operations.statfs() для in-memory ФС.
    fn statfs(_: ?*anyopaque, sb: *vfs.SuperBlock) vfs.SuperStats {
        return .{
            .magic = RAMFS_MAGIC,
            .bsize = 4096,
            .blocks = sb.nr_dentries,
            .bfree = 0,
            .bavail = 0,
            .files = sb.nr_inodes,
            .ffree = 0,
        };
    }

    /// ramfs не имеет внешнего носителя, поэтому sync_fs() — no-op.
    fn syncFs(_: ?*anyopaque, _: *vfs.SuperBlock) void {}

    pub fn ops(self: *RamFs) vfs.LookupOps {
        return .{ .ctx = self, .lookup = lookup };
    }

    /// Создать файл в RamFs и зарегистрировать его dentry/inode в VFS.
    pub fn addFile(self: *RamFs, path: []const u8, data: []const u8) !*file.File {
        const e = try self.newEntry(path, data, vfs.S_IFREG | 0o644);
        errdefer self.removeEntry(e);

        // namei: создать/найти dentry + inode через общий VFS path walk.
        const d = try self.sb.lookupPath(path, self.ops());
        const f = self.allocator.create(file.File) catch |err| {
            self.sb.dPut(d);
            return err;
        };
        f.* = .{
            .f_ops = .{ .ctx = e, .read = dataRead, .write = dataWrite, .llseek = dataSeek },
            .dentry = d, // struct file держит dget()
        };
        e.f = f;
        return f;
    }

    /// fs/ramfs/inode.c: mkdir() — новая директория с dentry/inode.
    pub fn mkdir(self: *RamFs, path: []const u8) !void {
        const e = try self.newEntry(path, "", vfs.S_IFDIR | 0o755);
        errdefer self.removeEntry(e);
        const parts = splitPath(path);
        const parent = try self.sb.lookupPath(parts.parent, self.ops());
        defer self.sb.dPut(parent);
        const d = try self.sb.createNode(parent, vfs.makeQstr(parts.name), entryInfo(e));
        self.sb.dPut(d);
    }

    /// fs/ramfs/inode.c: creat() — пустой файл с struct file.
    pub fn creat(self: *RamFs, path: []const u8) !*file.File {
        return self.addFile(path, "");
    }

    /// fs/ramfs/inode.c: symlink() — цель хранится в inode как i_link.
    /// Возвращает dentry самой ссылки (lookupPath() разыменует её при обходе).
    pub fn addSymlink(self: *RamFs, path: []const u8, target: []const u8) !*vfs.Dentry {
        const e = try self.newEntry(path, target, vfs.S_IFLNK | 0o777);
        errdefer self.removeEntry(e);
        return self.sb.lookupPathNoFollow(path, self.ops());
    }

    fn removeEntry(self: *RamFs, e: *Entry) void {
        for (self.entries.items, 0..) |item, i| {
            if (item == e) {
                _ = self.entries.orderedRemove(i);
                self.allocator.free(e.path);
                self.allocator.free(e.data);
                self.allocator.destroy(e);
                return;
            }
        }
    }

    /// fs/namei.c: vfs_unlink()/vfs_rmdir() — убрать имя из dcache. Entry и
    /// struct file живут до deinit(), чтобы открытые fd не повисли.
    pub fn unlink(self: *RamFs, path: []const u8, allow_dir: bool) !void {
        const e = self.findEntry(path) orelse return error.NoEnt;
        const parts = splitPath(path);
        const parent = try self.sb.lookupPath(parts.parent, self.ops());
        defer self.sb.dPut(parent);
        // Держать dget() снятого имени: unlinkNode() только снимает его из
        // хеша, а последующий dput() решает, жить dentry или нет.
        const d = try self.sb.lookupPathNoFollow(path, self.ops());
        defer self.sb.dPut(d);
        try self.sb.unlinkNode(parent, vfs.makeQstr(parts.name), allow_dir);
        e.deleted = true;
    }

    /// path_lookupat() с компонентами '.'/'..', symlink и кешем dentry.
    pub fn lookupPath(self: *RamFs, path: []const u8) !*vfs.Dentry {
        return self.sb.lookupPath(path, self.ops());
    }

    /// readlink(): последний symlink-компонент остаётся неразыменованным.
    pub fn lookupPathNoFollow(self: *RamFs, path: []const u8) !*vfs.Dentry {
        return self.sb.lookupPathNoFollow(path, self.ops());
    }

    /// Открытый файл по dentry из namei (struct file ↔ struct dentry).
    pub fn fileFor(self: *const RamFs, d: *vfs.Dentry) ?*file.File {
        for (self.entries.items) |e| {
            if (e.f) |f| {
                if (f.dentry == d) return f;
            }
        }
        return null;
    }
};

test "ramfs: real namei resolves path and struct file reads/writes data" {
    const a = std.testing.allocator;
    var sb: vfs.SuperBlock = undefined;
    try sb.init(a, 64);
    defer sb.deinit();
    var fs = RamFs.init(a, &sb);
    defer fs.deinit();

    const f = try fs.addFile("/tmp/hello", "hello");
    const d = try fs.lookupPath("/tmp/hello");
    defer sb.dPut(d);
    try std.testing.expectEqual(@as(u64, 100), d.d_inode.?.i_ino);
    try std.testing.expect(fs.fileFor(d) == f);

    var buf: [8]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 5), f.read(&buf));
    try std.testing.expectEqualStrings("hello", buf[0..5]);

    // dcache hit: повторный lookup возвращает тот же dentry.
    const d2 = try fs.lookupPath("/tmp/./hello");
    defer sb.dPut(d2);
    try std.testing.expectEqual(d, d2);

    try std.testing.expectError(error.NoEnt, fs.lookupPath("/tmp/missing"));

    // symlink: namei разыменовывает ссылку, readlink видит её саму.
    const link = try fs.addSymlink("/tmp/hello-link", "/tmp/hello");
    defer sb.dPut(link);
    try std.testing.expect(link.d_inode.?.isLink());

    const resolved = try fs.lookupPath("/tmp/hello-link");
    defer sb.dPut(resolved);
    try std.testing.expectEqual(d, resolved);
    try std.testing.expect(fs.fileFor(resolved) == f);

    const nofollow = try fs.lookupPathNoFollow("/tmp/hello-link");
    defer sb.dPut(nofollow);
    try std.testing.expectEqualStrings("/tmp/hello", nofollow.d_inode.?.i_link.?);

    // inode_operations: mkdir/creat/unlink меняют и RamFs, и dcache/inode.
    try fs.mkdir("/var");
    const dir = try fs.lookupPath("/var");
    defer sb.dPut(dir);
    try std.testing.expect(dir.d_inode.?.isDir());

    const created = try fs.creat("/var/log");
    var cbuf: [8]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 4), created.write("data"));
    _ = created.llseek(0, file.SEEK_SET);
    try std.testing.expectEqual(@as(i64, 4), created.read(&cbuf));
    try std.testing.expectEqualStrings("data", cbuf[0..4]);
    try std.testing.expectError(error.PathExists, fs.creat("/var/log"));

    try fs.unlink("/var/log", false);
    try std.testing.expectError(error.NoEnt, fs.lookupPath("/var/log"));
    // Открытый файл всё ещё держит dentry, поэтому rmdir видит каталог непустым.
    try std.testing.expectError(error.NotEmpty, fs.unlink("/var", true));
}

test "ramfs: super_operations and mount namespace resolve mounted files" {
    const a = std.testing.allocator;
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(a, 64);
    defer root_sb.deinit();
    var mounted_sb: vfs.SuperBlock = undefined;
    try mounted_sb.init(a, 64);
    defer mounted_sb.deinit();

    var root = RamFs.init(a, &root_sb);
    defer root.deinit();
    var mounted = RamFs.init(a, &mounted_sb);
    defer mounted.deinit();

    try root.mkdir("/mnt");
    _ = try root.addFile("/host.txt", "HOST!");
    const guest = try mounted.addFile("/from-mount.txt", "MOUNT!");
    _ = guest;

    const st = root_sb.statfs();
    try std.testing.expectEqual(RAMFS_MAGIC, st.magic);
    try std.testing.expectEqual(@as(u64, 4096), st.bsize);
    try std.testing.expectEqual(@as(u64, root_sb.nr_inodes), st.files);
    root_sb.syncFs(); // ramfs: no-op

    var ns: vfs.Namespace = undefined;
    try ns.init(a, &root_sb, root.ops());
    defer ns.deinit();
    _ = try ns.mount(&mounted_sb, mounted.ops(), "/mnt");

    const d = try ns.lookupPath("/mnt/from-mount.txt");
    defer d.d_sb.dPut(d);
    try std.testing.expectEqual(&mounted_sb, d.d_sb);
    const f = mounted.fileFor(d) orelse unreachable;
    var buf: [16]u8 = @splat(0);
    try std.testing.expectEqual(@as(i64, 6), f.read(&buf));
    try std.testing.expectEqualStrings("MOUNT!", buf[0..6]);

    const host_d = try ns.lookupPath("/host.txt");
    defer host_d.d_sb.dPut(host_d);
    try std.testing.expectEqual(&root_sb, host_d.d_sb);

    try ns.umount("/mnt");
    try std.testing.expectError(error.NoEnt, ns.lookupPath("/mnt/from-mount.txt"));
}
