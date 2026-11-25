//! Порт файлового слоя Linux 7.3 на Zig.
//! Источники: include/linux/fs.h (struct file, file_operations, files_struct),
//! fs/file.c (alloc_fd, dup_fd), fs/read_write.c (vfs_read/vfs_write).
//! Упрощено: нет user-space указателей, aio, splice, fasync, locks,
//! credentials, pathname в file; registry используется вместо реального open().
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const vfs = @import("vfs.zig");

pub const Errno = struct {
    pub const EBADF: i64 = 9;
    pub const EIO: i64 = 5;
    pub const ENOMEM: i64 = 12;
    pub const EINVAL: i64 = 22;
    pub const EMFILE: i64 = 24;
    pub const ESPIPE: i64 = 29;
    pub const ENOSYS: i64 = 38;
    pub const EROFS: i64 = 30;
    pub const ENOSPC: i64 = 28;
};

pub const SEEK_SET: u8 = 0;
pub const SEEK_CUR: u8 = 1;
pub const SEEK_END: u8 = 2;

/// include/uapi/asm-generic/fcntl.h: FD_CLOEXEC.
pub const FD_CLOEXEC: u32 = 0x80000;

/// include/uapi/linux/stat.h: битExecute файла для setuid/setgid при exec.
pub const S_IFMT: u32 = 0xF000;
pub const S_IFREG: u32 = 0x8000;
pub const S_ISUID: u32 = 0x800;
pub const S_ISGID: u32 = 0x400;

/// include/linux/fs.h: struct file_operations (упрощённый subset).
pub const FileOperations = struct {
    ctx: ?*anyopaque = null,
    read: ?*const fn (ctx: ?*anyopaque, f: *File, buf: []u8, pos: u64) i64 = null,
    write: ?*const fn (ctx: ?*anyopaque, f: *File, bytes: []const u8, pos: u64) i64 = null,
    llseek: ?*const fn (ctx: ?*anyopaque, f: *File, offset: i64, whence: u8) i64 = null,
    release: ?*const fn (ctx: ?*anyopaque, f: *File) void = null,
};

/// include/linux/fs.h: struct file.
pub const File = struct {
    f_ops: FileOperations = .{},
    f_pos: u64 = 0,
    f_flags: u32 = 0,
    f_mode: u32 = S_IFREG | 0o755,
    count: u32 = 1,
    dentry: ?*vfs.Dentry = null,
    /// Владелец файла — используется bprm_creds_for_exec() для setuid/setgid.
    uid: u32 = 0,
    gid: u32 = 0,

    pub inline fn closeOnExec(self: *const File) bool {
        return self.f_flags & FD_CLOEXEC != 0;
    }

    pub inline fn setCloseOnExec(self: *File, value: bool) void {
        if (value) self.f_flags |= FD_CLOEXEC else self.f_flags &= ~FD_CLOEXEC;
    }

    /// vfs_read(): вернуть байты или -errno.
    pub fn read(self: *File, buf: []u8) i64 {
        if (self.f_ops.read == null) return -Errno.ENOSYS;
        const n = self.f_ops.read.?(self.f_ops.ctx, self, buf, self.f_pos);
        if (n >= 0) self.f_pos += @intCast(n);
        return n;
    }

    /// vfs_write().
    pub fn write(self: *File, bytes: []const u8) i64 {
        if (self.f_ops.write == null) return -Errno.ENOSYS;
        const n = self.f_ops.write.?(self.f_ops.ctx, self, bytes, self.f_pos);
        if (n >= 0) self.f_pos += @intCast(n);
        return n;
    }

    /// file-backed fault: прочитать страницу по смещению, не трогая f_pos.
    pub fn readAt(self: *File, buf: []u8, pos: u64) i64 {
        const op = self.f_ops.read orelse return -Errno.ENOSYS;
        return op(self.f_ops.ctx, self, buf, pos);
    }

    /// Аналог для будущего writeback MAP_SHARED (пока не вызывается faults).
    pub fn writeAt(self: *File, bytes: []const u8, pos: u64) i64 {
        const op = self.f_ops.write orelse return -Errno.ENOSYS;
        return op(self.f_ops.ctx, self, bytes, pos);
    }

    /// vfs_llseek().
    pub fn llseek(self: *File, offset: i64, whence: u8) i64 {
        if (self.f_ops.llseek) |fnc| {
            const res = fnc(self.f_ops.ctx, self, offset, whence);
            if (res >= 0) self.f_pos = @intCast(res); // vfs_llseek(): обновляем f_pos
            return res;
        }
        return -Errno.ESPIPE;
    }

    pub fn get(self: *File) void {
        self.count += 1;
    }

    /// fput(): true, когда объект можно освобождать.
    pub fn put(self: *File) bool {
        self.count -= 1;
        if (self.count != 0) return false;
        if (self.f_ops.release) |fnc| fnc(self.f_ops.ctx, self);
        return true;
    }
};

/// include/linux/fs.h: struct files_struct + fdtable (упрощённо).
pub const FilesStruct = struct {
    allocator: std.mem.Allocator,
    fd: std.ArrayList(?*File) = .empty,
    count: u32 = 1,
    next_fd: u32 = 0,
    max_fds: u32 = 1024,

    pub fn init(allocator: std.mem.Allocator) FilesStruct {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *FilesStruct) void {
        for (self.fd.items) |slot| {
            if (slot) |f| {
                if (f.put()) self.allocator.destroy(f);
            }
        }
        self.fd.deinit(self.allocator);
    }

    pub fn get(self: *const FilesStruct, fd: u32) ?*File {
        if (fd >= self.fd.items.len) return null;
        return self.fd.items[fd];
    }

    /// fs/file.c: __alloc_fd() — первый свободный слот.
    pub fn allocFd(self: *FilesStruct, file: *File) !u32 {
        for (self.fd.items, 0..) |slot, i| {
            if (slot == null) {
                file.get(); // fd-слот владеет одной ссылкой
                self.fd.items[i] = file;
                return @intCast(i);
            }
        }
        if (self.fd.items.len >= self.max_fds) return error.EMFILE;
        file.get();
        try self.fd.append(self.allocator, file);
        return @intCast(self.fd.items.len - 1);
    }

    /// sys_close(): вернуть true, если дескриптор был открыт.
    pub fn close(self: *FilesStruct, fd: u32) bool {
        const f = self.get(fd) orelse return false;
        self.fd.items[fd] = null;
        if (f.put()) self.allocator.destroy(f);
        return true;
    }

    /// fs/file.c: dup_fd() — копия таблицы для fork без CLONE_FILES.
    pub fn cloneFiles(self: *FilesStruct) !FilesStruct {
        var copy = FilesStruct.init(self.allocator);
        // dup_fd(): сохраняем номера дескрипторов, как в ядре.
        while (copy.fd.items.len < self.fd.items.len) try copy.fd.append(self.allocator, null);
        for (self.fd.items, 0..) |slot, i| {
            if (slot) |f| {
                f.get();
                copy.fd.items[i] = f;
            }
        }
        return copy;
    }

    /// fs/exec.c: unshare_files() + close_on_exec() — exec создаёт новую
    /// fdtable и закрывает все дескрипторы с FD_CLOEXEC. Номера остальных fd
    /// сохраняются, как в Linux.
    pub fn cloneForExec(self: *FilesStruct) !FilesStruct {
        var copy = FilesStruct.init(self.allocator);
        while (copy.fd.items.len < self.fd.items.len) try copy.fd.append(self.allocator, null);
        for (self.fd.items, 0..) |slot, i| {
            if (slot) |f| {
                if (f.closeOnExec()) continue;
                f.get();
                copy.fd.items[i] = f;
            }
        }
        return copy;
    }

    /// sys_dup()/sys_dup2().
    pub fn dupFd(self: *FilesStruct, oldfd: u32) !u32 {
        const f = self.get(oldfd) orelse return error.EBADF;
        return self.allocFd(f);
    }

    pub fn dup2Fd(self: *FilesStruct, oldfd: u32, newfd: u32) !u32 {
        const f = self.get(oldfd) orelse return error.EBADF;
        if (oldfd == newfd) return newfd;
        if (newfd >= self.max_fds) return error.EINVAL;
        while (self.fd.items.len <= newfd) try self.fd.append(self.allocator, null);
        if (self.get(newfd)) |old| {
            self.fd.items[newfd] = null;
            if (old.put()) self.allocator.destroy(old);
        }
        f.get();
        self.fd.items[newfd] = f;
        return newfd;
    }
};

/// Упрощённый аналог привязки superblock: path → file (instead of
/// full namei + dev/inode → file). Используется sys_open() в syscall.zig.
pub const Registry = struct {
    allocator: std.mem.Allocator,
    files: std.StringHashMap(*File),

    pub fn init(allocator: std.mem.Allocator) Registry {
        return .{ .files = std.StringHashMap(*File).init(allocator), .allocator = allocator };
    }

    pub fn deinit(self: *Registry) void {
        var it = self.files.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.put()) self.allocator.destroy(entry.value_ptr.*);
            self.allocator.free(entry.key_ptr.*);
        }
        self.files.deinit();
    }

    pub fn register(self: *Registry, path: []const u8, file: *File) !void {
        const key = try self.allocator.dupe(u8, path);
        try self.files.put(key, file);
    }

    pub fn lookup(self: *const Registry, path: []const u8) ?*File {
        return self.files.get(path);
    }
};

test "file: FileOperations read/write, f_pos, refcount" {
    const Data = struct {
        var bytes: [64]u8 = @splat(0);
        var len: usize = 0;
        fn read(_: ?*anyopaque, f: *File, buf: []u8, pos: u64) i64 {
            _ = f;
            if (pos >= len) return 0;
            const n: usize = @intCast(@min(@as(u64, buf.len), len - pos));
            @memcpy(buf[0..n], bytes[@intCast(pos)..][0..n]);
            return @intCast(n);
        }
        fn write(_: ?*anyopaque, f: *File, bytes_in: []const u8, pos: u64) i64 {
            _ = f;
            const p: usize = @intCast(pos);
            const n = @min(bytes_in.len, bytes.len - p);
            @memcpy(bytes[p .. p + n], bytes_in[0..n]);
            len = @max(len, p + n);
            return @intCast(n);
        }
        fn seek(_: ?*anyopaque, f: *File, off: i64, whence: u8) i64 {
            const base: i64 = switch (whence) {
                SEEK_SET => 0,
                SEEK_CUR => @intCast(f.f_pos),
                SEEK_END => @intCast(len),
                else => return -Errno.EINVAL,
            };
            const res = base + off;
            if (res < 0) return -Errno.EINVAL;
            return res;
        }
    };
    @memcpy(Data.bytes[0..5], "hello");
    Data.len = 5;

    var f = File{ .f_ops = .{ .read = Data.read, .write = Data.write, .llseek = Data.seek } };
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(i64, 5), f.read(&buf));
    try std.testing.expectEqualStrings("hello", buf[0..5]);
    try std.testing.expectEqual(@as(i64, 0), f.read(&buf)); // EOF
    try std.testing.expectEqual(@as(u64, 5), f.f_pos);
    try std.testing.expectEqual(@as(i64, 0), f.llseek(0, SEEK_SET));
    f.f_pos = @intCast(f.llseek(0, SEEK_SET));
    try std.testing.expectEqual(@as(i64, 2), f.write("HI"));
    try std.testing.expectEqual(@as(i64, 5), f.readAt(&buf, 0));
    try std.testing.expectEqualStrings("HI", buf[0..2]);
    try std.testing.expectEqual(@as(u64, 2), f.f_pos); // readAt не двигает f_pos
    try std.testing.expectEqualStrings("HI", Data.bytes[0..2]);

    f.get();
    try std.testing.expectEqual(@as(u32, 2), f.count);
    try std.testing.expect(!f.put());
    try std.testing.expect(f.put());
}

test "files_struct: alloc_fd, close reuse, dup/dup2, cloneFiles" {
    var files = FilesStruct.init(std.testing.allocator);
    const a = try std.testing.allocator.create(File);
    a.* = .{};
    const fd0 = try files.allocFd(a);
    const fd1 = try files.dupFd(fd0);
    try std.testing.expectEqual(@as(u32, 0), fd0);
    try std.testing.expectEqual(@as(u32, 1), fd1);
    try std.testing.expectEqual(@as(u32, 3), a.count); // initial + alloc + dup

    const fd2 = try files.dup2Fd(fd0, 5);
    try std.testing.expectEqual(@as(u32, 5), fd2);
    try std.testing.expectEqual(@as(u32, 4), a.count); // + dup2
    try std.testing.expect(files.get(fd2) == a);

    try std.testing.expect(files.close(fd1));
    try std.testing.expect(!files.close(fd1));
    const reused = try files.allocFd(a);
    try std.testing.expectEqual(@as(u32, 1), reused);

    var copy = try files.cloneFiles();
    try std.testing.expect(copy.get(fd0) == a);
    try std.testing.expect(copy.get(fd2) == a);
    try std.testing.expect(a.count > 1);

    copy.deinit();
    files.deinit();
    if (a.put()) std.testing.allocator.destroy(a); // стартовая ссылка теста
}

test "files_struct: exec unshares and closes FD_CLOEXEC" {
    var files = FilesStruct.init(std.testing.allocator);

    const keep = try std.testing.allocator.create(File);
    keep.* = .{};
    const drop = try std.testing.allocator.create(File);
    drop.* = .{};
    drop.setCloseOnExec(true);

    const fd0 = try files.allocFd(keep);
    const fd1 = try files.allocFd(drop);
    try std.testing.expectEqual(@as(u32, 0), fd0);
    try std.testing.expectEqual(@as(u32, 1), fd1);

    var exec_files = try files.cloneForExec();
    try std.testing.expect(exec_files.get(fd0) == keep);
    try std.testing.expect(exec_files.get(fd1) == null);
    try std.testing.expect(keep.count > 1);

    exec_files.deinit();
    files.deinit();
    if (keep.put()) std.testing.allocator.destroy(keep);
    if (drop.put()) std.testing.allocator.destroy(drop);
}
