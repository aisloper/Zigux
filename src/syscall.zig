//! Порт syscall-слоя Linux 7.3 (x86_64 ABI) на Zig.
//! Источники: arch/x86/entry/syscalls/syscall_64.tbl, include/uapi/asm-generic/unistd.h,
//! kernel/sys.c, kernel/fork.c, fs/open.c, fs/read_write.c.
//! Упрощено: нет user-space указателей (копирование/проверка), сигналов,
//! credentials/capabilities, seccomp, ptrace. Обработчики работают с ядерными структурами.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const task = @import("task.zig");
const sched = @import("sched.zig");
const vfs = @import("vfs.zig");
const file = @import("file.zig");
const ramfs = @import("ramfs.zig");
const vma_mod = @import("mm/vma.zig");

/// arch/x86/entry/syscalls/syscall_64.tbl (x86_64, Linux 7.3).
pub const SyscallNo = struct {
    pub const read: u32 = 0;
    pub const write: u32 = 1;
    pub const open: u32 = 2;
    pub const close: u32 = 3;
    pub const mkdir: u32 = 83;
    pub const rmdir: u32 = 84;
    pub const creat: u32 = 85;
    pub const unlink: u32 = 87;
    pub const symlink: u32 = 88;
    pub const readlink: u32 = 89;
    pub const stat: u32 = 4;
    pub const fstat: u32 = 5;
    pub const lseek: u32 = 8;
    pub const mmap: u32 = 9;
    pub const mprotect: u32 = 10;
    pub const munmap: u32 = 11;
    pub const brk: u32 = 12;
    pub const rt_sigaction: u32 = 13;
    pub const rt_sigprocmask: u32 = 14;
    pub const rt_sigreturn: u32 = 15;
    pub const ioctl: u32 = 16;
    pub const readv: u32 = 19;
    pub const writev: u32 = 20;
    pub const access: u32 = 21;
    pub const pipe: u32 = 22;
    pub const select: u32 = 23;
    pub const sched_yield: u32 = 24;
    pub const mremap: u32 = 25;
    pub const msync: u32 = 26;
    pub const mincore: u32 = 27;
    pub const madvise: u32 = 28;
    pub const shmget: u32 = 29;
    pub const fork: u32 = 57;
    pub const vfork: u32 = 58;
    pub const execve: u32 = 59;
    pub const exit: u32 = 60;
    pub const wait4: u32 = 61;
    pub const kill: u32 = 62;
    pub const uname: u32 = 63;
    pub const semaphore: u32 = 64;
    pub const shmctl: u32 = 65;
    pub const dup: u32 = 66;
    pub const dup2: u32 = 67;
    pub const pause: u32 = 68;
    pub const nanosleep: u32 = 35;
    pub const setpgid: u32 = 109;
    pub const getpgrp: u32 = 111;
    pub const setsid: u32 = 112;
    pub const getsid: u32 = 124;
    pub const getitimer: u32 = 36;
    pub const alarm: u32 = 37;
    pub const setitimer: u32 = 38;
    pub const getpid: u32 = 39;
    pub const sendfile: u32 = 40;
    pub const socket: u32 = 41;
    pub const connect: u32 = 42;
    pub const accept: u32 = 43;
    pub const sendto: u32 = 44;
    pub const recvfrom: u32 = 45;
    pub const socketpair: u32 = 53;
    pub const clone: u32 = 56;
    pub const unshare: u32 = 272;
    pub const getuid: u32 = 102;
    pub const getgid: u32 = 104;
    pub const setuid: u32 = 105;
    pub const setgid: u32 = 106;
    pub const geteuid: u32 = 107;
    pub const getegid: u32 = 108;
    pub const gettid: u32 = 186;
    pub const prctl: u32 = 157;
    pub const tkill: u32 = 200;
    pub const futex: u32 = 202;
    pub const tgkill: u32 = 234;
    pub const sched_setaffinity: u32 = 203;
    pub const sched_getaffinity: u32 = 204;
    pub const clock_settime: u32 = 227;
    pub const clock_gettime: u32 = 228;
    pub const clock_getres: u32 = 229;
    pub const clock_nanosleep: u32 = 230;
    pub const exit_group: u32 = 231;
    pub const epoll_create1: u32 = 291;
    pub const timerfd_create: u32 = 283;
    pub const eventfd: u32 = 284;
    pub const signalfd4: u32 = 289;
    pub const getrandom: u32 = 318;
};

/// Linux errno (include/uapi/asm-generic/errno-base.h).
pub const Errno = struct {
    pub const EPERM: i32 = 1;
    pub const ENOENT: i32 = 2;
    pub const ECHILD: i32 = 10;
    pub const ESRCH: i32 = 3;
    pub const EINTR: i32 = 4;
    pub const EIO: i32 = 5;
    pub const ENXIO: i32 = 6;
    pub const EBADF: i32 = 9;
    pub const EAGAIN: i32 = 11;
    pub const ENOMEM: i32 = 12;
    pub const EACCES: i32 = 13;
    pub const EFAULT: i32 = 14;
    pub const EEXIST: i32 = 17;
    pub const ENAMETOOLONG: i32 = 36;
    pub const ENOSYS: i32 = 38;
    pub const ENOTDIR: i32 = 20;
    pub const EISDIR: i32 = 21;
    pub const EINVAL: i32 = 22;
    pub const EMFILE: i32 = 24;
    pub const ENOSPC: i32 = 28;
    pub const ELOOP: i32 = 40;
    pub const ENOTEMPTY: i32 = 39;
};

/// Результат Linux syscall: nonnegative = success, negative = -errno.
pub const SyscallResult = i64;

fn err(e: i32) SyscallResult {
    return -@as(i64, e);
}

/// fs/namei.c ошибки namei/inode_operations в Linux errno.
fn fsErrno(e: anyerror) i32 {
    return switch (e) {
        error.PathExists => Errno.EEXIST,
        error.NoEnt => Errno.ENOENT,
        error.NotDir => Errno.ENOTDIR,
        error.IsDir => Errno.EISDIR,
        error.NotEmpty => Errno.ENOTEMPTY,
        error.Loop => Errno.ELOOP,
        error.NameTooLong => Errno.ENAMETOOLONG,
        error.NoSpace => Errno.ENOSPC,
        error.NotSupported => Errno.ENOSYS,
        else => Errno.EIO,
    };
}

/// fs/open.c: do_filp_open() для newly созданного dentry. Если ФС зарегистрировала
/// instantiate, она сама создаёт struct file и забирает dget() у dentry.
fn instantiateFile(d: *vfs.Dentry) !*file.File {
    const ops = d.d_sb.s_dir_ops;
    const instantiate = ops.instantiate orelse return error.NotSupported;
    const raw = try instantiate(ops.ctx, d);
    return @ptrCast(@alignCast(raw));
}

fn createFileAt(self: *Context) !*file.File {
    if (self.ns) |ns| {
        if (ns.createAt(self.open_path)) |d| {
            return instantiateFile(d) catch |e| {
                d.d_sb.dPut(d);
                return e;
            };
        } else |e| {
            if (e != error.NotSupported) return e;
        }
    }
    const fs = self.fs orelse return error.NotSupported;
    return fs.creat(self.open_path);
}

fn unlinkAt(self: *Context) !void {
    if (self.ns) |ns| {
        if (ns.unlinkAt(self.open_path)) |_| return else |e| {
            if (e != error.NotSupported) return e;
        }
    }
    const fs = self.fs orelse return error.NotSupported;
    try fs.unlink(self.open_path, false);
}

/// fs/namei.c: vfs_mkdir() — сначала DirOps смонтированной ФС, затем RamFs.
fn makeDirAt(self: *Context) !void {
    if (self.ns) |ns| {
        if (ns.mkdirAt(self.open_path)) |d| {
            d.d_sb.dPut(d);
            return;
        } else |e| {
            if (e != error.NotSupported) return e;
        }
    }
    const fs = self.fs orelse return error.NotSupported;
    try fs.mkdir(self.open_path);
}

/// fs/namei.c: vfs_rmdir() — сначала DirOps смонтированной ФС, затем RamFs.
fn removeDirAt(self: *Context) !void {
    if (self.ns) |ns| {
        if (ns.rmdirAt(self.open_path)) |_| return else |e| {
            if (e != error.NotSupported) return e;
        }
    }
    const fs = self.fs orelse return error.NotSupported;
    try fs.unlink(self.open_path, true);
}

/// Аргументы syscall в формате x86_64 SysV (rdi, rsi, rdx, r10, r8, r9).
pub const Args = struct {
    a1: u64 = 0,
    a2: u64 = 0,
    a3: u64 = 0,
    a4: u64 = 0,
    a5: u64 = 0,
    a6: u64 = 0,
};

/// Контекст диспетчера: текущая задача и менеджер задач.
pub const Context = struct {
    current: *task.TaskStruct,
    tasks: *task.TaskManager,
    cfs: ?*sched.CfsRq = null,
    /// Замена user-space указателей для host-порта: буферы syscall-а.
    /// x86_64 ABI всё ещё передаёт a2/a3 как «указатель/размер».
    io_buf: []u8 = &.{},
    io_data: []const u8 = &.{},
    open_path: []const u8 = "",
    /// symlink(old, new): цель берётся отсюда, имя ссылки — из open_path.
    link_target: []const u8 = "",
    /// execve() в host-порту: путь берётся отсюда вместо user-space указателя.
    exec_path: []const u8 = "",
    exec_argv: []const []const u8 = &.{},
    registry: ?*file.Registry = null,
    /// Реальный namei через VFS: приоритетный путь для open() в ring3.
    fs: ?*ramfs.RamFs = null,
    /// Активный mount namespace задачи (task_struct.nsproxy->mnt_ns).
    /// Если задан, open()/readlink() ходят через него и видят mountpoint-ы.
    ns: ?*vfs.Namespace = null,

    /// do_syscall_64() → __x64_sys_*ByName.
    pub fn dispatch(self: *Context, nr: u32, args: Args) SyscallResult {
        return switch (nr) {
            SyscallNo.getpid => @intCast(self.current.tgid),
            SyscallNo.gettid => @intCast(self.current.pid),
            SyscallNo.getuid => @intCast(self.current.cred.uid),
            SyscallNo.geteuid => @intCast(self.current.cred.euid),
            SyscallNo.getgid => @intCast(self.current.cred.gid),
            SyscallNo.getegid => @intCast(self.current.cred.egid),
            SyscallNo.setuid => blk: {
                self.current.cred.setuid(@truncate(args.a1)) catch break :blk err(Errno.EPERM);
                break :blk 0;
            },
            SyscallNo.setgid => blk: {
                self.current.cred.setresgid(@truncate(args.a1), @truncate(args.a1), @truncate(args.a1)) catch break :blk err(Errno.EPERM);
                break :blk 0;
            },
            SyscallNo.prctl => blk: {
                // PR_SET_NO_NEW_PRIVS / PR_GET_NO_NEW_PRIVS (include/linux/prctl.h).
                if (args.a1 == 38) {
                    self.current.cred.no_new_privs = args.a2 != 0;
                    break :blk 0;
                }
                if (args.a1 == 39) break :blk @intFromBool(self.current.cred.no_new_privs);
                break :blk err(Errno.EINVAL);
            },
            SyscallNo.read => blk: {
                const fd: u32 = @truncate(args.a1);
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                const f = files.get(fd) orelse break :blk err(Errno.EBADF);
                const n: usize = @intCast(@min(args.a3, self.io_buf.len));
                break :blk f.read(self.io_buf[0..n]);
            },
            SyscallNo.write => blk: {
                const fd: u32 = @truncate(args.a1);
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                const f = files.get(fd) orelse break :blk err(Errno.EBADF);
                const n: usize = @intCast(@min(args.a3, self.io_data.len));
                break :blk f.write(self.io_data[0..n]);
            },
            SyscallNo.open => blk: {
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                var f: *file.File = undefined;
                if (self.fs) |fs| {
                    // fs/namei.c: path_lookupat() → dentry → struct file.
                    // С ns обход идёт через mountpoint-ы текущего namespace.
                    var d: *vfs.Dentry = undefined;
                    if (self.ns) |ns| {
                        const p = ns.lookupPathWithMount(self.open_path, true) catch |e| break :blk err(switch (e) {
                            error.Loop => Errno.ELOOP,
                            error.NameTooLong => Errno.ENAMETOOLONG,
                            error.NotDir => Errno.ENOTDIR,
                            else => Errno.ENOENT,
                        });
                        d = p.dentry;
                    } else {
                        d = fs.lookupPath(self.open_path) catch |e| break :blk err(switch (e) {
                            error.Loop => Errno.ELOOP,
                            error.NameTooLong => Errno.ENAMETOOLONG,
                            error.NotDir => Errno.ENOTDIR,
                            else => Errno.ENOENT,
                        });
                    }
                    if (instantiateFile(d)) |opened| {
                        f = opened; // struct file забрал dget() у dentry
                    } else |e| {
                        if (e != error.NotSupported) {
                            d.d_sb.dPut(d);
                            break :blk err(fsErrno(e));
                        }
                        f = fs.fileFor(d) orelse {
                            d.d_sb.dPut(d);
                            break :blk err(Errno.EACCES);
                        };
                        d.d_sb.dPut(d); // struct file уже держит dget()
                    }
                } else {
                    // Хост-совместимость: старый путь через file.Registry.
                    const reg = self.registry orelse break :blk err(Errno.ENOENT);
                    f = reg.lookup(self.open_path) orelse break :blk err(Errno.ENOENT);
                }
                const fd = files.allocFd(f) catch break :blk err(Errno.EMFILE);
                break :blk @intCast(fd);
            },
            SyscallNo.readlink => blk: {
                const fs = self.fs orelse break :blk err(Errno.ENOSYS);
                var d: *vfs.Dentry = undefined;
                if (self.ns) |ns| {
                    const p = ns.lookupPathWithMount(self.open_path, false) catch |e| break :blk err(switch (e) {
                        error.Loop => Errno.ELOOP,
                        error.NameTooLong => Errno.ENAMETOOLONG,
                        error.NotDir => Errno.ENOTDIR,
                        else => Errno.ENOENT,
                    });
                    d = p.dentry;
                } else {
                    d = fs.lookupPathNoFollow(self.open_path) catch |e| break :blk err(switch (e) {
                        error.Loop => Errno.ELOOP,
                        error.NameTooLong => Errno.ENAMETOOLONG,
                        error.NotDir => Errno.ENOTDIR,
                        else => Errno.ENOENT,
                    });
                }
                defer d.d_sb.dPut(d);
                const ino = d.d_inode orelse break :blk err(Errno.ENOENT);
                const target = ino.i_link orelse break :blk err(Errno.EINVAL);
                const capacity: usize = @intCast(@min(args.a3, @as(u64, self.io_buf.len)));
                const n = @min(capacity, target.len);
                @memcpy(self.io_buf[0..n], target[0..n]);
                break :blk @intCast(n);
            },
            SyscallNo.mkdir => blk: {
                makeDirAt(self) catch |e| break :blk err(fsErrno(e));
                break :blk 0;
            },
            SyscallNo.rmdir => blk: {
                removeDirAt(self) catch |e| break :blk err(fsErrno(e));
                break :blk 0;
            },
            SyscallNo.creat => blk: {
                const f = createFileAt(self) catch |e| break :blk err(fsErrno(e));
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                const fd = files.allocFd(f) catch break :blk err(Errno.EMFILE);
                break :blk @intCast(fd);
            },
            SyscallNo.unlink => blk: {
                unlinkAt(self) catch |e| break :blk err(fsErrno(e));
                break :blk 0;
            },
            SyscallNo.symlink => blk: {
                const fs = self.fs orelse break :blk err(Errno.ENOSYS);
                const d = fs.addSymlink(self.open_path, self.link_target) catch |e| break :blk err(fsErrno(e));
                fs.sb.dPut(d); // dcache держит своё ref
                break :blk 0;
            },
            SyscallNo.close => blk: {
                const fd: u32 = @truncate(args.a1);
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                break :blk if (files.close(fd)) @as(SyscallResult, 0) else err(Errno.EBADF);
            },
            SyscallNo.dup => blk: {
                const fd: u32 = @truncate(args.a1);
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                const nfd = files.dupFd(fd) catch |e| break :blk err(if (e == error.EBADF) Errno.EBADF else Errno.EMFILE);
                break :blk @intCast(nfd);
            },
            SyscallNo.dup2 => blk: {
                const fd: u32 = @truncate(args.a1);
                const nfd: u32 = @truncate(args.a2);
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                const res = files.dup2Fd(fd, nfd) catch |e| break :blk err(if (e == error.EBADF) Errno.EBADF else Errno.EINVAL);
                break :blk @intCast(res);
            },
            SyscallNo.lseek => blk: {
                const fd: u32 = @truncate(args.a1);
                const files = self.current.files orelse break :blk err(Errno.EBADF);
                const f = files.get(fd) orelse break :blk err(Errno.EBADF);
                const off: i64 = @bitCast(@as(u64, args.a2));
                break :blk f.llseek(off, @truncate(args.a3));
            },
            SyscallNo.mmap => blk: {
                const mm = self.current.mm orelse break :blk err(Errno.ENOMEM);
                const flags = args.a4;
                if (flags & vma_mod.MAP_ANONYMOUS == 0) {
                    // file-backed mmap(): struct file из fdtable, pgoff из offset.
                    if (args.a6 & (vma_mod.PAGE_SIZE - 1) != 0) break :blk err(Errno.EINVAL);
                    const fd: u32 = @truncate(args.a5);
                    const files = self.current.files orelse break :blk err(Errno.EBADF);
                    const f = files.get(fd) orelse break :blk err(Errno.EBADF);
                    const v = mm.vmas.mmapFile(
                        args.a1,
                        args.a2,
                        @truncate(args.a3),
                        flags,
                        f,
                        args.a6 >> vma_mod.PAGE_SHIFT,
                    ) catch break :blk err(Errno.EINVAL);
                    break :blk @intCast(v.vm_start);
                }
                const v = mm.vmas.mmap(args.a1, args.a2, @truncate(args.a3), flags) catch break :blk err(Errno.ENOMEM);
                break :blk @intCast(v.vm_start);
            },
            SyscallNo.munmap => blk: {
                const mm = self.current.mm orelse break :blk err(Errno.ENOMEM);
                mm.vmas.munmap(args.a1, args.a2) catch break :blk err(Errno.EINVAL);
                break :blk 0;
            },
            SyscallNo.mprotect => blk: {
                const mm = self.current.mm orelse break :blk err(Errno.ENOMEM);
                mm.vmas.mprotect(args.a1, args.a2, @truncate(args.a3)) catch break :blk err(Errno.ENOMEM);
                break :blk 0;
            },
            SyscallNo.brk => blk: {
                // mm/mmap.c: sys_brk() — граница кучи и anon-VMA.
                const mm = self.current.mm orelse break :blk err(Errno.ENOMEM);
                const value = mm.setBrk(args.a1) catch break :blk err(Errno.ENOMEM);
                break :blk @intCast(value);
            },
            SyscallNo.getpgrp => @intCast(self.current.pgrp),
            SyscallNo.getsid => @intCast(self.current.session),
            SyscallNo.setpgid => blk: {
                const pid: u32 = @truncate(args.a1);
                const pgid: u32 = @truncate(args.a2);
                const t = if (pid == 0)
                    self.current
                else
                    self.tasks.find(pid) orelse break :blk err(Errno.ESRCH);
                self.tasks.setpgid(t, pgid) catch break :blk err(Errno.EPERM);
                break :blk 0;
            },
            SyscallNo.setsid => blk: {
                self.tasks.setsid(self.current) catch break :blk err(Errno.EPERM);
                break :blk @as(SyscallResult, @intCast(self.current.session));
            },
            SyscallNo.wait4 => blk: {
                // a2/a3 (status/rusage) игнорируются — нет user-space указателей.
                const r = self.tasks.wait4(self.current) orelse break :blk err(Errno.ECHILD);
                break :blk @intCast(r.pid);
            },
            SyscallNo.kill, SyscallNo.tkill, SyscallNo.tgkill => blk: {
                if (nr == SyscallNo.tgkill) {
                    const tgid: u32 = @truncate(args.a1);
                    const tid: u32 = @truncate(args.a2);
                    const sig: u8 = @truncate(args.a3);
                    const t = self.tasks.find(tid) orelse break :blk err(Errno.ESRCH);
                    if (t.tgid != tgid) break :blk err(Errno.ESRCH);
                    self.tasks.signal(t, sig);
                    break :blk 0;
                }
                if (nr == SyscallNo.tkill) {
                    const tid: u32 = @truncate(args.a1);
                    const sig: u8 = @truncate(args.a2);
                    const t = self.tasks.find(tid) orelse break :blk err(Errno.ESRCH);
                    self.tasks.signal(t, sig);
                    break :blk 0;
                }
                const pid: i32 = @bitCast(@as(u32, @truncate(args.a1)));
                const sig: u8 = @truncate(args.a2);
                if (pid < 0) {
                    self.tasks.signalPgrp(@intCast(-@as(i64, pid)), sig);
                } else if (pid == 0) {
                    self.tasks.signalPgrp(self.current.pgrp, sig);
                } else {
                    const t = self.tasks.find(@intCast(pid)) orelse break :blk err(Errno.ESRCH);
                    self.tasks.signal(t, sig);
                }
                break :blk 0;
            },
            SyscallNo.execve => blk: {
                _ = self.exec_argv; // host-порт: argv не копируется из user space
                const reg = self.registry orelse break :blk err(Errno.ENOENT);
                const binary = reg.lookup(self.exec_path) orelse break :blk err(Errno.ENOENT);
                const path = self.exec_path;
                const comm = if (std.mem.lastIndexOfScalar(u8, path, '/')) |i| path[i + 1 ..] else path;
                self.tasks.execve(self.current, binary, comm) catch |e| break :blk err(switch (e) {
                    error.EACCES => Errno.EACCES,
                    error.EPERM => Errno.EPERM,
                    error.ENOMEM => Errno.ENOMEM,
                    else => Errno.EIO,
                });
                break :blk 0;
            },
            SyscallNo.exit, SyscallNo.exit_group => blk: {
                const code: i32 = @bitCast(@as(u32, @truncate(args.a1)));
                self.tasks.exit(self.current, code);
                break :blk 0;
            },
            SyscallNo.fork => blk: {
                const child = self.tasks.fork(self.current, 0) catch break :blk err(Errno.EAGAIN);
                child.setComm(self.current.name());
                // В Linux fork() ребёнку возвращает 0; здесь возвращаем pid
                // вызывающему, ребёнок получит 0 при первом запуске через set_next.
                break :blk @intCast(child.pid);
            },
            SyscallNo.clone => blk: {
                const flags: u64 = args.a1;
                const child = self.tasks.fork(self.current, flags) catch break :blk err(Errno.EAGAIN);
                break :blk @intCast(child.pid);
            },
            SyscallNo.unshare => blk: {
                const flags: u64 = args.a1;
                // Пока портирован только CLONE_NEWNS: unshare(2) с другими
                // флагами возвращает EINVAL, как и unsupported setns.
                if (flags == 0 or flags & ~@as(u64, task.CloneFlags.NEWNS) != 0) break :blk err(Errno.EINVAL);
                const old = self.current.ns orelse break :blk err(Errno.EINVAL);
                const ns = self.tasks.allocator.create(vfs.Namespace) catch break :blk err(Errno.ENOMEM);
                errdefer self.tasks.allocator.destroy(ns);
                old.clone(ns) catch break :blk err(Errno.ENOMEM);
                errdefer {
                    ns.deinit();
                    self.tasks.allocator.destroy(ns);
                }
                old.put(); // unshare() больше не делит namespace с родителем
                self.current.ns = ns;
                if (self.ns == old) self.ns = ns;
                break :blk 0;
            },
            SyscallNo.sched_yield => blk: {
                if (self.cfs) |cfs| {
                    _ = cfs.schedule(@truncate(args.a1));
                }
                break :blk 0;
            },
            SyscallNo.nanosleep => blk: {
                // Упрощено: arg1 = миллисекунды (в Linux — struct timespec*).
                _ = args.a1;
                break :blk 0;
            },
            SyscallNo.uname => blk: {
                // Упрощённый порт: 1 = Linux, 7 = major, 3 = minor.
                break :blk 7 * 1000 + 3;
            },
            SyscallNo.getrandom => 0,
            SyscallNo.futex, SyscallNo.sched_setaffinity, SyscallNo.sched_getaffinity => 0,
            SyscallNo.clock_gettime, SyscallNo.clock_getres => 0,
            else => err(Errno.ENOSYS),
        };
    }

    /// do_signal(): доставить pending-сигналы перед возвратом в user mode.
    pub fn deliverSignals(self: *Context) bool {
        return self.tasks.deliverSignals(self.current);
    }
};

test "syscall dispatch: getpid/gettid/fork/exit/yield/ENOSYS" {
    var tm: task.TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();
    const init = try tm.createInit();
    var cfs = sched.CfsRq.init();
    var ctx = Context{ .current = init, .tasks = &tm, .cfs = &cfs };

    try std.testing.expectEqual(@as(i64, 1), ctx.dispatch(SyscallNo.getpid, .{}));
    try std.testing.expectEqual(@as(i64, 1), ctx.dispatch(SyscallNo.gettid, .{}));

    const pid = ctx.dispatch(SyscallNo.fork, .{});
    try std.testing.expect(pid > 1);
    try std.testing.expectEqual(@as(usize, 2), tm.nr_tasks);

    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.sched_yield, .{}));
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.exit, .{ .a1 = 42 }));
    try std.testing.expect(init.isDead());
    try std.testing.expectEqual(@as(i64, -Errno.ENOSYS), ctx.dispatch(9999, .{}));
}

test "syscall: job control setpgid/kill(-pgrp)/wait4" {
    var tm: task.TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();
    const init = try tm.createInit();
    var ctx = Context{ .current = init, .tasks = &tm };

    const child = try tm.fork(init, 0);
    child.setComm("job");
    const child_pid = child.pid;
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.setpgid, .{
        .a1 = child_pid,
        .a2 = child_pid,
    }));
    try std.testing.expectEqual(child_pid, child.pgrp);
    try std.testing.expectEqual(@as(i64, @intCast(init.pgrp)), ctx.dispatch(SyscallNo.getpgrp, .{}));

    // kill(-pgid, SIGTERM): тот же путь, что ^C через TTY sig_hook.
    const neg_pgrp: u64 = @bitCast(@as(i64, -@as(i64, child_pid)));
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.kill, .{
        .a1 = neg_pgrp,
        .a2 = task.Signal.SIGTERM,
    }));
    try std.testing.expect(child.signals.pending.has(task.Signal.SIGTERM));
    try std.testing.expect(tm.deliverSignals(child));
    try std.testing.expect(child.isDead());

    const reaped = ctx.dispatch(SyscallNo.wait4, .{});
    try std.testing.expectEqual(@as(i64, child_pid), reaped);
    try std.testing.expectEqual(@as(i64, -Errno.ECHILD), ctx.dispatch(SyscallNo.wait4, .{}));
    try std.testing.expectEqual(@as(i64, -Errno.ESRCH), ctx.dispatch(SyscallNo.kill, .{
        .a1 = child_pid,
        .a2 = task.Signal.SIGTERM,
    }));
}

test "syscall: open/read/write/dup/lseek/close and mmap/mprotect/munmap" {
    var tm: task.TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();
    const init = try tm.createInit();

    const Mem = struct {
        var data: [64]u8 = @splat(0);
        var len: usize = 0;
        fn read(_: ?*anyopaque, _: *file.File, buf: []u8, pos: u64) i64 {
            if (pos >= len) return 0;
            const n: usize = @intCast(@min(@as(u64, buf.len), len - pos));
            @memcpy(buf[0..n], data[@intCast(pos)..][0..n]);
            return @intCast(n);
        }
        fn write(_: ?*anyopaque, _: *file.File, bytes: []const u8, pos: u64) i64 {
            const p: usize = @intCast(pos);
            const n = @min(bytes.len, data.len - p);
            @memcpy(data[p .. p + n], bytes[0..n]);
            len = @max(len, p + n);
            return @intCast(n);
        }
        fn seek(_: ?*anyopaque, f: *file.File, off: i64, whence: u8) i64 {
            const base: i64 = switch (whence) {
                file.SEEK_SET => 0,
                file.SEEK_CUR => @intCast(f.f_pos),
                file.SEEK_END => @intCast(len),
                else => return -file.Errno.EINVAL,
            };
            const res = base + off;
            return if (res < 0) -file.Errno.EINVAL else res;
        }
    };
    @memcpy(Mem.data[0..5], "hello");
    Mem.len = 5;
    const f = try std.testing.allocator.create(file.File);
    f.* = .{ .f_ops = .{ .read = Mem.read, .write = Mem.write, .llseek = Mem.seek } };

    var reg = file.Registry.init(std.testing.allocator);
    defer reg.deinit();
    try reg.register("/tmp/test", f);

    var rbuf: [16]u8 = @splat(0);
    var ctx = Context{
        .current = init,
        .tasks = &tm,
        .registry = &reg,
        .io_data = "hi",
        .io_buf = &rbuf,
        .open_path = "/tmp/test",
    };

    const fd: u32 = @intCast(ctx.dispatch(SyscallNo.open, .{}));
    try std.testing.expectEqual(@as(i64, 2), ctx.dispatch(SyscallNo.write, .{ .a1 = fd, .a3 = 2 }));
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.lseek, .{ .a1 = fd, .a2 = 0, .a3 = file.SEEK_SET }));
    try std.testing.expectEqual(@as(i64, 5), ctx.dispatch(SyscallNo.read, .{ .a1 = fd, .a3 = 16 }));
    try std.testing.expectEqualStrings("hillo", rbuf[0..5]);

    const nfd: u32 = @intCast(ctx.dispatch(SyscallNo.dup, .{ .a1 = fd }));
    try std.testing.expect(nfd != fd);
    try std.testing.expect(init.files.?.get(nfd) != null);
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.close, .{ .a1 = fd }));
    try std.testing.expect(init.files.?.get(fd) == null);
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.close, .{ .a1 = nfd }));
    try std.testing.expectEqual(@as(i64, -Errno.EBADF), ctx.dispatch(SyscallNo.read, .{ .a1 = fd }));

    const addr = ctx.dispatch(SyscallNo.mmap, .{
        .a1 = 0,
        .a2 = vma_mod.PAGE_SIZE,
        .a3 = vma_mod.PROT_READ | vma_mod.PROT_WRITE,
        .a4 = vma_mod.MAP_PRIVATE | vma_mod.MAP_ANONYMOUS,
    });
    try std.testing.expect(addr > 0);
    try std.testing.expectEqual(@as(usize, 1), init.mm.?.nrVmas());
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.mprotect, .{
        .a1 = @intCast(addr),
        .a2 = vma_mod.PAGE_SIZE,
        .a3 = vma_mod.PROT_READ,
    }));
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.munmap, .{
        .a1 = @intCast(addr),
        .a2 = vma_mod.PAGE_SIZE,
    }));
    try std.testing.expectEqual(@as(usize, 0), init.mm.?.nrVmas());

    // file-backed mmap: VMA хранит struct file и pgoff из syscall-аргументов.
    ctx.open_path = "/tmp/test";
    const fd2: u32 = @intCast(ctx.dispatch(SyscallNo.open, .{}));
    const mapped = ctx.dispatch(SyscallNo.mmap, .{
        .a1 = 0,
        .a2 = vma_mod.PAGE_SIZE,
        .a3 = vma_mod.PROT_READ,
        .a4 = vma_mod.MAP_PRIVATE,
        .a5 = fd2,
        .a6 = 0,
    });
    try std.testing.expect(mapped > 0);
    const fvma = init.mm.?.vmas.find(@intCast(mapped)).?;
    try std.testing.expect(fvma.vm_file == f);
    try std.testing.expectEqual(@as(u64, 0), fvma.vm_pgoff);
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.munmap, .{
        .a1 = @intCast(mapped),
        .a2 = vma_mod.PAGE_SIZE,
    }));
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.close, .{ .a1 = fd2 }));
    try std.testing.expectEqual(@as(usize, 0), init.mm.?.nrVmas());
}

test "syscall: open() uses VFS namei (RamFs) and returns ENOENT/ENOTDIR" {
    const a = std.testing.allocator;
    var sb: vfs.SuperBlock = undefined;
    try sb.init(a, 64);
    defer sb.deinit();
    var fs = ramfs.RamFs.init(a, &sb);
    defer fs.deinit();
    _ = try fs.addFile("/etc/version", "7.3");
    _ = try fs.addSymlink("/etc/ver-link", "/etc/version");

    var tm: task.TaskManager = undefined;
    tm.init(a);
    defer tm.deinit();
    const init = try tm.createInit();

    var buf: [32]u8 = @splat(0);
    var ctx = Context{
        .current = init,
        .tasks = &tm,
        .fs = &fs,
        .open_path = "/etc/version",
        .io_buf = &buf,
    };
    const fd: u32 = @intCast(ctx.dispatch(SyscallNo.open, .{}));
    try std.testing.expectEqual(@as(i64, 3), ctx.dispatch(SyscallNo.read, .{ .a1 = fd, .a3 = 3 }));
    try std.testing.expectEqualStrings("7.3", buf[0..3]);

    // dup divided struct file (общий f_pos): lseek + read через копию fd.
    try std.testing.expectEqual(@as(i64, 1), ctx.dispatch(SyscallNo.lseek, .{
        .a1 = fd,
        .a2 = 1,
        .a3 = file.SEEK_SET,
    }));
    const dup_fd: u32 = @intCast(ctx.dispatch(SyscallNo.dup, .{ .a1 = fd }));
    try std.testing.expectEqual(@as(i64, 2), ctx.dispatch(SyscallNo.read, .{ .a1 = dup_fd, .a3 = 2 }));
    try std.testing.expectEqualStrings(".3", buf[0..2]);
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.close, .{ .a1 = dup_fd }));

    // open() разыменовывает symlink, readlink() возвращает цель как есть.
    ctx.open_path = "/etc/ver-link";
    const link_fd: u32 = @intCast(ctx.dispatch(SyscallNo.open, .{}));
    _ = ctx.dispatch(SyscallNo.lseek, .{ .a1 = link_fd, .a2 = 0, .a3 = file.SEEK_SET });
    try std.testing.expectEqual(@as(i64, 3), ctx.dispatch(SyscallNo.read, .{ .a1 = link_fd, .a3 = 3 }));
    try std.testing.expectEqualStrings("7.3", buf[0..3]);
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.close, .{ .a1 = link_fd }));
    @memset(&buf, 0);
    try std.testing.expectEqual(@as(i64, 12), ctx.dispatch(SyscallNo.readlink, .{ .a3 = buf.len }));
    try std.testing.expectEqualStrings("/etc/version", buf[0..12]);

    ctx.open_path = "/etc/missing";
    try std.testing.expectEqual(@as(i64, -Errno.ENOENT), ctx.dispatch(SyscallNo.open, .{}));
    ctx.open_path = "/etc/version/child";
    try std.testing.expectEqual(@as(i64, -Errno.ENOTDIR), ctx.dispatch(SyscallNo.open, .{}));
}

test "syscall: unshare(CLONE_NEWNS) isolates mount namespace" {
    const a = std.testing.allocator;
    var sb: vfs.SuperBlock = undefined;
    try sb.init(a, 64);
    defer sb.deinit();
    var fs = ramfs.RamFs.init(a, &sb);
    defer fs.deinit();
    try fs.mkdir("/mnt");
    const original = try fs.addFile("/mnt/file", "original");

    var overlay_sb: vfs.SuperBlock = undefined;
    try overlay_sb.init(a, 16);
    defer overlay_sb.deinit();
    var overlay = ramfs.RamFs.init(a, &overlay_sb);
    defer overlay.deinit();

    var tm: task.TaskManager = undefined;
    tm.init(a);
    defer tm.deinit();
    const init = try tm.createInit();

    const ns = try a.create(vfs.Namespace);
    try ns.init(a, &sb, fs.ops());
    init.ns = ns;
    ns.get(); // тест сохраняет ссылку на старую namespace после unshare
    defer ns.put();

    var buf: [32]u8 = @splat(0);
    var ctx = Context{
        .current = init,
        .tasks = &tm,
        .fs = &fs,
        .ns = ns,
        .io_buf = &buf,
    };
    try std.testing.expectEqual(@as(i64, -Errno.EINVAL), ctx.dispatch(SyscallNo.unshare, .{ .a1 = task.CloneFlags.NEWNS | task.CloneFlags.NEWUTS }));
    try std.testing.expectEqual(init.ns, ns);

    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.unshare, .{ .a1 = task.CloneFlags.NEWNS }));
    const fresh = init.ns orelse unreachable;
    try std.testing.expect(fresh != ns);
    try std.testing.expectEqual(fresh, ctx.ns.?);

    // Новый mount виден только в новой namespace: старая сохраняет /mnt/file.
    _ = try fresh.mount(&overlay_sb, overlay.ops(), "/mnt");
    try std.testing.expectError(error.NoEnt, fresh.lookupPath("/mnt/file"));
    const old = try ns.lookupPath("/mnt/file");
    defer old.d_sb.dPut(old);
    try std.testing.expectEqual(original.dentry, old);
}

test "syscall: inode_operations mkdir/creat/symlink/unlink through RamFs" {
    const a = std.testing.allocator;
    var sb: vfs.SuperBlock = undefined;
    try sb.init(a, 64);
    defer sb.deinit();
    var fs = ramfs.RamFs.init(a, &sb);
    defer fs.deinit();

    var tm: task.TaskManager = undefined;
    tm.init(a);
    defer tm.deinit();
    const init = try tm.createInit();

    var buf: [32]u8 = @splat(0);
    var ctx = Context{
        .current = init,
        .tasks = &tm,
        .fs = &fs,
        .io_buf = &buf,
        .io_data = "abc",
    };

    ctx.open_path = "/run";
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.mkdir, .{}));
    try std.testing.expectEqual(@as(i64, -Errno.EEXIST), ctx.dispatch(SyscallNo.mkdir, .{}));

    ctx.open_path = "/run/log";
    const fd: u32 = @intCast(ctx.dispatch(SyscallNo.creat, .{}));
    try std.testing.expectEqual(@as(i64, 3), ctx.dispatch(SyscallNo.write, .{ .a1 = fd, .a3 = 3 }));
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.close, .{ .a1 = fd }));
    ctx.open_path = "/run";
    try std.testing.expectEqual(@as(i64, -Errno.ENOTEMPTY), ctx.dispatch(SyscallNo.rmdir, .{}));

    ctx.open_path = "/run/log-link";
    ctx.link_target = "/run/log";
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.symlink, .{}));
    ctx.open_path = "/run/log-link";
    const link_fd: u32 = @intCast(ctx.dispatch(SyscallNo.open, .{}));
    _ = ctx.dispatch(SyscallNo.lseek, .{ .a1 = link_fd, .a2 = 0, .a3 = file.SEEK_SET });
    try std.testing.expectEqual(@as(i64, 3), ctx.dispatch(SyscallNo.read, .{ .a1 = link_fd, .a3 = 3 }));
    try std.testing.expectEqualStrings("abc", buf[0..3]);
    @memset(&buf, 0);
    try std.testing.expectEqual(@as(i64, 8), ctx.dispatch(SyscallNo.readlink, .{ .a3 = buf.len }));
    try std.testing.expectEqualStrings("/run/log", buf[0..8]);

    ctx.open_path = "/run/log-link";
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.unlink, .{}));
    try std.testing.expectEqual(@as(i64, -Errno.ENOENT), ctx.dispatch(SyscallNo.open, .{}));
    ctx.open_path = "/run/log";
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.unlink, .{}));
    try std.testing.expectEqual(@as(i64, -Errno.ENOENT), ctx.dispatch(SyscallNo.open, .{}));
    ctx.open_path = "/empty";
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.mkdir, .{}));
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.rmdir, .{}));
    try std.testing.expectEqual(@as(i64, -Errno.ENOENT), ctx.dispatch(SyscallNo.rmdir, .{}));
}

fn execHandler(_: u8) void {}

test "syscall: execve unshares mm/files, resets handlers and applies setuid" {
    var tm: task.TaskManager = undefined;
    tm.init(std.testing.allocator);
    const init = try tm.createInit();

    // Registry владеет File; сначала освобождаем fd-таблицы задач (tm.deinit),
    // затем файлы (reg.deinit).
    var reg = file.Registry.init(std.testing.allocator);
    const bin = try std.testing.allocator.create(file.File);
    bin.* = .{ .f_mode = file.S_IFREG | file.S_ISUID | 0o755, .uid = 0 };
    try reg.register("/bin/app", bin);

    const keep = try std.testing.allocator.create(file.File);
    keep.* = .{};
    try reg.register("/keep", keep);
    const drop = try std.testing.allocator.create(file.File);
    drop.* = .{};
    try reg.register("/drop", drop);
    drop.setCloseOnExec(true);
    const fd0 = try init.files.?.allocFd(keep);
    const fd1 = try init.files.?.allocFd(drop);

    var ctx = Context{ .current = init, .tasks = &tm, .registry = &reg, .exec_path = "/bin/app" };
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.setuid, .{ .a1 = 1000 }));
    try std.testing.expectEqual(@as(i64, 1000), ctx.dispatch(SyscallNo.geteuid, .{}));

    _ = try init.mm.?.vmas.insertRaw(0, vma_mod.PAGE_SIZE, 0, 0);
    init.signals.actions[task.Signal.SIGINT].handler = execHandler;
    try std.testing.expect(init.signals.actions[task.Signal.SIGINT].handler != null);

    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.execve, .{}));
    try std.testing.expectEqualStrings("app", init.name());
    try std.testing.expectEqual(@as(usize, 0), init.mm.?.nrVmas());
    try std.testing.expect(init.files.?.get(fd0) == keep);
    try std.testing.expect(init.files.?.get(fd1) == null);
    try std.testing.expect(init.signals.actions[task.Signal.SIGINT].handler == null);
    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.geteuid, .{}));

    try std.testing.expectEqual(@as(i64, 0), ctx.dispatch(SyscallNo.prctl, .{ .a1 = 38, .a2 = 1 }));
    try std.testing.expectEqual(@as(i64, 1), ctx.dispatch(SyscallNo.prctl, .{ .a1 = 39 }));

    tm.deinit();
    reg.deinit();
}

test "syscall: brk grows and shrinks anon VMA" {
    var tm: task.TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();
    const init = try tm.createInit();
    var ctx = Context{ .current = init, .tasks = &tm };
    const mm = init.mm.?;
    mm.start_brk = 0x100000;
    mm.brk = 0x100000;

    try std.testing.expectEqual(@as(i64, 0x100000), ctx.dispatch(SyscallNo.brk, .{}));
    const grown = ctx.dispatch(SyscallNo.brk, .{ .a1 = 0x100000 + 2 * vma_mod.PAGE_SIZE + 1 });
    try std.testing.expectEqual(@as(i64, 0x103000), grown);
    try std.testing.expectEqual(@as(usize, 1), mm.nrVmas());
    const v = mm.vmas.find(0x100000).?;
    try std.testing.expectEqual(@as(u64, 0x103000), v.vm_end);
    try std.testing.expect(v.vm_flags & vma_mod.VM_WRITE != 0);

    const shrunk = ctx.dispatch(SyscallNo.brk, .{ .a1 = 0x101000 });
    try std.testing.expectEqual(@as(i64, 0x101000), shrunk);
    try std.testing.expectEqual(@as(u64, 0x101000), mm.vmas.find(0x100000).?.vm_end);
    try std.testing.expectEqual(@as(i64, -Errno.ENOMEM), ctx.dispatch(SyscallNo.brk, .{ .a1 = 0x1000 }));
}
