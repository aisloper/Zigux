//! host-симулятор загрузки ziglinux: показывает, что портированные подсистемы
//! работают вместе. Реальный UEFI/ELF-вход будет подключён в следующем этапе.
const std = @import("std");
const kl = @import("kernel.zig");
const sched = @import("sched.zig");
const vfs = @import("vfs.zig");
const task = @import("task.zig");
const timer = @import("timer.zig");
const tty = @import("tty.zig");
const syscall = @import("syscall.zig");
const file = @import("file.zig");
const vma_mod = @import("mm/vma.zig");

const FsFixture = struct {
    const Entry = struct { path: []const u8, ino: u64, mode: u32 };
    const table = [_]Entry{
        .{ .path = "/bin", .ino = 10, .mode = vfs.S_IFDIR },
        .{ .path = "/bin/sh", .ino = 11, .mode = vfs.S_IFREG },
        .{ .path = "/etc", .ino = 20, .mode = vfs.S_IFDIR },
        .{ .path = "/etc/passwd", .ino = 21, .mode = vfs.S_IFREG },
        .{ .path = "/proc", .ino = 30, .mode = vfs.S_IFDIR },
        .{ .path = "/proc/version", .ino = 31, .mode = vfs.S_IFREG },
    };

    fn lookup(ctx: ?*anyopaque, parent: *vfs.Dentry, q: vfs.Qstr) ?vfs.InodeInfo {
        _ = ctx;
        const sb = parent.d_sb;
        var pbuf: [256]u8 = undefined;
        var fbuf: [512]u8 = undefined;
        const p = sb.pathString(parent, &pbuf) catch return null;
        const joined = if (std.mem.eql(u8, p, "/"))
            std.fmt.bufPrint(&fbuf, "/{s}", .{q.name}) catch return null
        else
            std.fmt.bufPrint(&fbuf, "{s}/{s}", .{ p, q.name }) catch return null;
        for (table) |e| {
            if (std.mem.eql(u8, e.path, joined)) return .{ .ino = e.ino, .mode = e.mode };
        }
        return null;
    }

    fn ops() vfs.LookupOps {
        return .{ .lookup = lookup };
    }
};

var timer_fired: usize = 0;
fn timerCallback(data: usize) void {
    timer_fired += data;
}

/// Тестовый драйвер вывода: TTY → sink вместо serial/console из zigos.
const TtySink = struct {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    fn write(_: ?*anyopaque, bytes: []const u8) void {
        @memcpy(buf[len .. len + bytes.len], bytes);
        len += bytes.len;
    }
};

fn escape(bytes: []const u8, out: []u8) []const u8 {
    var n: usize = 0;
    for (bytes) |c| {
        const rep: []const u8 = switch (c) {
            '\n' => "\\n",
            '\r' => "\\r",
            0x08 => "\\b",
            else => &[_]u8{c},
        };
        @memcpy(out[n .. n + rep.len], rep);
        n += rep.len;
    }
    return out[0..n];
}

pub fn main() !void {
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    const a = gpa.allocator();

    var k: kl.init.Kernel = undefined;
    try k.boot(a, 4096);
    defer k.deinit();

    std.debug.print("ziglinux {d}.{d} (Linux {d}.{d} port {s})\n", .{
        kl.version_major, kl.version_minor, kl.version_major, kl.version_minor, kl.port_version,
    });

    std.debug.print("start_kernel:\n", .{});
    for (k.log.stages.items) |stage| std.debug.print("  -> {s}\n", .{@tagName(stage)});

    std.debug.print("memory: {d} pages managed, {d} free, {d} allocated\n", .{
        k.zone.managed_pages, k.zone.nrFree(), k.zone.nrAllocated(),
    });
    const obj = try k.kmem_cache.alloc();
    std.debug.print("slab:   cache={s}, objects/slab={d}, allocated={d}\n", .{
        k.kmem_cache.name, k.kmem_cache.objects, k.kmem_cache.nr_alloc,
    });
    k.kmem_cache.free(obj);

    // Path walk + dcache.
    const ops = FsFixture.ops();
    const passwd = try k.vfs.lookupPath("/etc/../etc/passwd", ops);
    defer k.vfs.dPut(passwd);
    std.debug.print("vfs:    /etc/passwd -> inode {d} ({d} dentries, {d} inodes cached)\n", .{
        passwd.d_inode.?.i_ino, k.vfs.nr_dentries, k.vfs.nr_inodes,
    });

    // Процессы: fork/clone из init-задачи.
    const init = k.tasks.root.?;
    const worker = try k.tasks.fork(init, 0);
    worker.setComm("worker");
    const thread = try k.tasks.fork(init, task.CloneFlags.VM | task.CloneFlags.FILES | task.CloneFlags.THREAD);
    thread.setComm("worker-thread");
    std.debug.print("task:   {d} tasks (pid1={s}, fork={s}, thread={s}, tgid={d})\n", .{
        k.tasks.nr_tasks, init.name(), worker.name(), thread.name(), thread.tgid,
    });

    // TTY: line discipline + job control. В host-симуляторе arch-драйверы
    // заменены sink-ом; в UEFI их подключает user.pumpTty().
    try k.tasks.setpgid(worker, worker.pid);
    const vt = &k.ttys[0];
    vt.setPgrp(worker.pid);
    vt.ops.write = TtySink.write;
    vt.receive("he\x7flp\r"); // VERASE стирает 'e', ICRNL даёт '\n'
    var ibuf: [128]u8 = undefined;
    var iesc: [256]u8 = undefined;
    var oesc: [256]u8 = undefined;
    const ilen = vt.read(&ibuf);
    TtySink.len = 0;
    vt.write("tty ready\n"); // OPOST|ONLCR: '\n' → "\r\n"
    std.debug.print("tty:    {d} VTs, input=\"{s}\", output=\"{s}\"\n", .{
        k.ttys.len, escape(ibuf[0..ilen], &iesc), escape(TtySink.buf[0..TtySink.len], &oesc),
    });
    vt.receive(&[_]u8{vt.termios.c_cc[tty.CcIndex.VINTR]}); // ^C → sig_hook → signalPgrp
    std.debug.print("signal: ^C -> pgrp {d}: worker pending={}, dead={}\n", .{
        worker.pid, worker.signals.pending.has(task.Signal.SIGINT), worker.isDead(),
    });
    _ = k.tasks.deliverSignals(worker);
    std.debug.print("signal: worker dead={}, exit_code={d}\n", .{
        worker.isDead(), worker.exit_code,
    });

    // Syscall-слой: fork/kill/wait4 через контекст диспетчера.
    var sctx = syscall.Context{ .current = init, .tasks = &k.tasks, .cfs = &k.cfs };
    const sc_pid = sctx.dispatch(syscall.SyscallNo.getpid, .{});
    const sc_child_pid: u32 = @intCast(sctx.dispatch(syscall.SyscallNo.fork, .{}));
    const sc_setpgid = sctx.dispatch(syscall.SyscallNo.setpgid, .{ .a1 = sc_child_pid, .a2 = sc_child_pid });
    const sc_kill = sctx.dispatch(syscall.SyscallNo.kill, .{
        .a1 = sc_child_pid,
        .a2 = task.Signal.SIGTERM,
    });
    const sc_child = k.tasks.find(sc_child_pid).?;
    const sc_delivered = k.tasks.deliverSignals(sc_child);
    const sc_wait = sctx.dispatch(syscall.SyscallNo.wait4, .{});
    std.debug.print("syscall: getpid={d}, fork={d}, setpgid={d}, kill={d}, delivered={}, wait4={d}\n", .{
        sc_pid, sc_child_pid, sc_setpgid, sc_kill, sc_delivered, sc_wait,
    });

    // Файловый слой и VMA через syscall-диспетчер (file_operations +
    // mm_struct.vmas). Реальный open() заменён registry для host-порта.
    const MemFile = struct {
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
    @memcpy(MemFile.data[0..5], "linux");
    MemFile.len = 5;
    const memfile = try a.create(file.File);
    memfile.* = .{ .f_ops = .{ .read = MemFile.read, .write = MemFile.write, .llseek = MemFile.seek } };
    var reg = file.Registry.init(a);
    defer reg.deinit();
    try reg.register("/demo", memfile);

    var fbuf: [16]u8 = @splat(0);
    var fctx = syscall.Context{
        .current = init,
        .tasks = &k.tasks,
        .cfs = &k.cfs,
        .registry = &reg,
        .open_path = "/demo",
        .io_data = "Z",
        .io_buf = &fbuf,
    };
    const ffd: u32 = @intCast(fctx.dispatch(syscall.SyscallNo.open, .{}));
    const n_written = fctx.dispatch(syscall.SyscallNo.write, .{ .a1 = ffd, .a3 = 1 });
    _ = fctx.dispatch(syscall.SyscallNo.lseek, .{ .a1 = ffd, .a2 = 0, .a3 = file.SEEK_SET });
    const n_read = fctx.dispatch(syscall.SyscallNo.read, .{ .a1 = ffd, .a3 = fbuf.len });
    const map_addr = fctx.dispatch(syscall.SyscallNo.mmap, .{
        .a1 = 0,
        .a2 = 2 * vma_mod.PAGE_SIZE,
        .a3 = vma_mod.PROT_READ | vma_mod.PROT_WRITE,
        .a4 = vma_mod.MAP_PRIVATE | vma_mod.MAP_ANONYMOUS,
    });
    const vmas_before = init.mm.?.nrVmas();
    _ = fctx.dispatch(syscall.SyscallNo.mprotect, .{
        .a1 = @intCast(map_addr),
        .a2 = vma_mod.PAGE_SIZE,
        .a3 = vma_mod.PROT_READ,
    });
    const vmas_split = init.mm.?.nrVmas();
    _ = fctx.dispatch(syscall.SyscallNo.munmap, .{
        .a1 = @intCast(map_addr),
        .a2 = 2 * vma_mod.PAGE_SIZE,
    });
    std.debug.print("file/mm: fd={d}, write={d}, read={d}, data=\"{s}\"; mmap=0x{x}, VMA {d}->{d}->{d}\n", .{
        ffd,         n_written,  n_read,             fbuf[0..@intCast(n_read)], map_addr,
        vmas_before, vmas_split, init.mm.?.nrVmas(),
    });
    _ = fctx.dispatch(syscall.SyscallNo.close, .{ .a1 = ffd });

    // execve + credentials: setuid-бинарник поднимает euid и capabilities,
    // FD_CLOEXEC уже закрыт, signal handlers сброшены.
    const exec_file = try a.create(file.File);
    exec_file.* = .{ .f_mode = file.S_IFREG | file.S_ISUID | 0o755, .uid = 0 };
    try reg.register("/bin/init", exec_file);
    _ = fctx.dispatch(syscall.SyscallNo.setuid, .{ .a1 = 1000 });
    const euid_before = fctx.dispatch(syscall.SyscallNo.geteuid, .{});
    fctx.exec_path = "/bin/init";
    const exec_rc = fctx.dispatch(syscall.SyscallNo.execve, .{});
    const euid_after = fctx.dispatch(syscall.SyscallNo.geteuid, .{});
    std.debug.print("execve: rc={d}, euid={d}->{d}, comm={s}, VMA={d}\n", .{
        exec_rc, euid_before, euid_after, init.name(), init.mm.?.nrVmas(),
    });

    // Таймеры: jiffies + timer wheel.
    try k.timers.addMillis(8, 5, timerCallback);
    try k.timers.addMillis(40, 3, timerCallback);
    k.timers.advance(timer.msecsToJiffies(20));
    std.debug.print("timer:  HZ={d}, jiffies=+{d}, fired={d} callbacks (sum={d})\n", .{
        timer.HZ, timer.msecsToJiffies(20), k.timers.nr_fired, timer_fired,
    });

    // EEVDF: четыре задачи с разными nice.
    var tasks = [_]sched.Task{
        .{ .pid = 1, .comm = "rt-low" },
        .{ .pid = 2, .comm = "user1" },
        .{ .pid = 3, .comm = "user2" },
        .{ .pid = 4, .comm = "idle" },
    };
    const nices = [_]i8{ -10, 0, 0, 10 };
    for (&tasks, nices) |*t, nice| {
        t.se.setLoadWeight(nice);
        k.cfs.enqueueEntity(&t.se, 0, true);
    }
    _ = k.cfs.schedule(0);
    var now: u64 = 0;
    var switches: usize = 0;
    for (0..2000) |_| {
        now += sched.TICK_NSEC;
        if (k.cfs.entityTick(now)) {
            _ = k.cfs.schedule(now);
            switches += 1;
        }
    }
    std.debug.print("sched:  EEVDF, cpu time per task:\n", .{});
    for (tasks) |t| {
        std.debug.print("  pid {d} {s: <8} weight={d: >5} runtime={d: >9.3} ms vruntime={d}\n", .{
            t.pid,                                                        t.comm,        t.se.load.weight,
            @as(f64, @floatFromInt(t.se.sum_exec_runtime)) / 1_000_000.0, t.se.vruntime,
        });
    }
    std.debug.print("sched:  {d} reschedules in {d} ticks, {d} runnable\n", .{
        switches, 2000, k.cfs.nrRunning(),
    });
    std.debug.print("OK: all subsystems linked and functional.\n", .{});
}
