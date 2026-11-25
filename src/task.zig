//! Порт task_struct и базовых операций с процессами Linux 7.3 на Zig.
//! Источники: include/linux/sched.h, include/linux/sched/task.h, kernel/fork.c,
//! kernel/exit.c. Упрощено: нет mm_struct/files_struct/signals в полном объёме,
//! RCU, cgroups, ptrace, namespaces. Добавлено в этапе 1b.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const list = @import("list.zig");
const sched = @import("sched.zig");
const file = @import("file.zig");
const cred_mod = @import("cred.zig");
const vma = @import("mm/vma.zig");
const vfs = @import("vfs.zig");

/// include/linux/sched.h: TASK_* биты.
pub const TaskStateFlags = struct {
    pub const RUNNING: u32 = 0;
    pub const INTERRUPTIBLE: u32 = 1;
    pub const UNINTERRUPTIBLE: u32 = 2;
    pub const STOPPED: u32 = 4;
    pub const TRACED: u32 = 8;
    pub const DEAD: u32 = 16;
    pub const WAKEKILL: u32 = 32;
    pub const WAKING: u32 = 64;
    pub const PARKED: u32 = 128;
    pub const IDLE: u32 = 256;
    pub const NOLOAD: u32 = 512;
    pub const NEW: u32 = 1024;
    pub const REPORT_DEAD: u32 = 2048;
    pub const WAKE_UPDATED: u32 = 4096;
};

pub const CloneFlags = struct {
    pub const VM: u64 = 1 << 0; // CLONE_VM — разделять адресное пространство
    pub const FS: u64 = 1 << 1; // CLONE_FS
    pub const FILES: u64 = 1 << 2; // CLONE_FILES
    pub const SIGHAND: u64 = 1 << 3; // CLONE_SIGHAND
    pub const PTRACE: u64 = 1 << 4;
    pub const VFORK: u64 = 1 << 5;
    pub const PARENT: u64 = 1 << 6;
    pub const THREAD: u64 = 1 << 7; // CLONE_THREAD — поток в той же группе
    pub const SYSVSEM: u64 = 1 << 8;
    pub const NEWNS: u64 = 1 << 9;
    pub const SETTLS: u64 = 1 << 10;
    pub const DETACHED: u64 = 1 << 11;
    pub const NEWUTS: u64 = 1 << 12;
    pub const NEWIPC: u64 = 1 << 13;
    pub const NEWPID: u64 = 1 << 14;
    pub const NEWNET: u64 = 1 << 15;
    pub const IO: u64 = 1 << 18;
    pub const NEWCGROUP: u64 = 1 << 19;
    pub const NEWUSER: u64 = 1 << 20;
    pub const NEWTIME: u64 = 1 << 21;
};

/// mm_struct — адресное пространство процесса с VMA-деревом (mm/mmap.c).
pub const MmStruct = struct {
    allocator: std.mem.Allocator,
    mm_count: u32 = 1,
    vmas: vma.VmAreaTree = undefined,
    /// mm_struct.start_brk/brk: границы кучи процесса. Хост-порт оставляет их
    /// нулевыми; arch/user.zig задаёт высокий адрес при загрузке ELF.
    start_brk: u64 = 0,
    brk: u64 = 0,

    pub const MAX_BRK: u64 = 16 * 1024 * 1024;

    pub fn init(allocator: std.mem.Allocator) MmStruct {
        return .{ .allocator = allocator, .vmas = vma.VmAreaTree.init(allocator) };
    }

    /// copy_mm()/dup_mmap(): копия VMA-дерева при fork без CLONE_VM.
    pub fn dup(allocator: std.mem.Allocator, other: *const MmStruct) !MmStruct {
        var m = MmStruct.init(allocator);
        m.start_brk = other.start_brk;
        m.brk = other.brk;
        var v = other.vmas.first();
        while (v) |cur| : (v = other.vmas.next(cur)) {
            _ = try m.vmas.insertRaw(cur.vm_start, cur.vm_end, cur.vm_flags, cur.vm_page_prot);
        }
        return m;
    }

    pub fn get(self: *MmStruct) void {
        self.mm_count += 1;
    }

    pub fn put(self: *MmStruct) bool {
        self.mm_count -= 1;
        if (self.mm_count == 0) self.vmas.deinit(); // mmdrop()
        return self.mm_count == 0;
    }

    pub fn nrVmas(self: *const MmStruct) usize {
        return self.vmas.nr_vmas;
    }

    pub fn totalVm(self: *const MmStruct) u64 {
        return self.vmas.totalPages();
    }

    /// sys_brk(): расширить/сжать кучу, создавая или убивая anon-VMA.
    /// Возвращает новую границу (при args=0 — текущую), как Linux.
    pub fn setBrk(self: *MmStruct, addr: u64) !u64 {
        if (addr == 0) return self.brk;
        if (self.start_brk == 0 or addr < self.start_brk) return error.ENOMEM;
        if (addr - self.start_brk > MAX_BRK) return error.ENOMEM;
        const next = vma.alignUp(addr, vma.PAGE_SIZE);
        if (next > self.brk) {
            _ = try self.vmas.mmap(self.brk, next - self.brk, vma.PROT_READ | vma.PROT_WRITE, vma.MAP_PRIVATE | vma.MAP_ANONYMOUS | vma.MAP_FIXED);
        } else if (next < self.brk) {
            try self.vmas.munmap(next, self.brk - next);
        }
        self.brk = next;
        return self.brk;
    }
};

/// struct files_struct / fdtable из file.zig.
pub const FilesStruct = file.FilesStruct;

/// include/asm-generic/thread_info.h / arch/x86/include/asm/thread_info.h:
/// архивно-зависимая часть task_struct (указатель стека, entry потока).
pub const ArchThread = struct {
    sp: usize = 0,
    stack: usize = 0,
    pages: usize = 0,
    entry: ?*const fn () void = null,
    /// ring3: PML4 задачи и отдельный kernel alias для доступа ядра к её
    /// буферам. sysret/IDT берут их из per-CPU слота текущего CPU.
    user_cr3: u64 = 0,
    kernel_cr3: u64 = 0,
    /// ring3: SysFrame после fork — результат syscall fork для ребёнка (RAX=0).
    fork_frame: ?*anyopaque = null,
};

/// task_struct — процесс/поток. Интрузивные списки требуют in-place init.
pub const TaskStruct = struct {
    pid: u32,
    tgid: u32, // Thread Group ID (getpid())
    comm: [16]u8 = @splat(0),
    comm_len: u8 = 0,

    state: u32 = TaskStateFlags.NEW,
    exit_code: i32 = 0,
    exit_signal: u8 = 0,

    se: sched.SchedEntity = .{},
    arch: ArchThread = .{},

    /// include/linux/sched.h: cred — uid/gid, capabilities, no_new_privs.
    cred: cred_mod.Cred = .{},

    parent: ?*TaskStruct = null,
    sibling: list.Node = .{}, // в parent.children
    children: list.Head = .{},
    tasks: list.Node = .{}, // во всех задачах

    mm: ?*MmStruct = null,
    files: ?*FilesStruct = null,
    /// include/linux/nsproxy.h: task_struct.nsproxy->mnt_ns.
    /// NULL означает задачу без VFS (host-тесты mm/sched) или init до vfs_caches_init.
    ns: ?*vfs.Namespace = null,

    flags: u64 = 0, // PF_* / clone flags при rfork
    on_cpu: ?u32 = null,
    wake_time: u64 = 0,

    /// Job control (kernel/signal.c, drivers/tty/tty_jobctrl.c).
    session: u32 = 0, // sid — setsid()
    pgrp: u32 = 0, // pgid — setpgid()
    ctty: ?u32 = null, // controlling terminal index (из zigos/user.zig)
    signals: SignalState = .{},

    pub fn setComm(self: *TaskStruct, comm: []const u8) void {
        const n = @min(comm.len, self.comm.len);
        @memcpy(self.comm[0..n], comm[0..n]);
        self.comm_len = @intCast(n);
    }

    pub fn name(self: *const TaskStruct) []const u8 {
        return self.comm[0..self.comm_len];
    }

    pub fn isThreadGroupLeader(self: *const TaskStruct) bool {
        return self.pid == self.tgid;
    }

    pub fn isDead(self: *const TaskStruct) bool {
        return self.state & TaskStateFlags.DEAD != 0;
    }

    pub fn isRunnable(self: *const TaskStruct) bool {
        return self.state == TaskStateFlags.RUNNING;
    }
};

/// Менеджер задач: analogue of pidhash + tasklist_lock. На SMP pidhash,
/// next_pid и списки children общие для CPU, поэтому изменения сериализует
/// spinlock (аналог tasklist_lock/kernel/fork.c в Linux 7.3).
pub const TaskManager = struct {
    allocator: std.mem.Allocator,
    tasks: std.AutoHashMap(u32, *TaskStruct),
    next_pid: u32 = 1,
    root: ?*TaskStruct = null,
    nr_tasks: usize = 0,
    lock: std.atomic.Value(u32) = .init(0),

    pub fn init(self: *TaskManager, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .tasks = std.AutoHashMap(u32, *TaskStruct).init(allocator),
        };
    }

    fn lockAcquire(self: *TaskManager) void {
        while (self.lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
            while (self.lock.load(.monotonic) != 0) std.atomic.spinLoopHint();
        }
    }

    fn lockRelease(self: *TaskManager) void {
        self.lock.store(0, .release);
    }

    pub fn deinit(self: *TaskManager) void {
        var it = self.tasks.valueIterator();
        while (it.next()) |t| {
            const task = t.*;
            if (task.mm) |mm| {
                if (mm.put()) self.allocator.destroy(mm);
            }
            if (task.files) |files| {
                files.count -= 1;
                if (files.count == 0) {
                    files.deinit(); // закрываем все fd при последней ссылке
                    self.allocator.destroy(files);
                }
            }
            if (task.ns) |ns| {
                task.ns = null;
                ns.put();
            }
            self.allocator.destroy(task);
        }
        self.tasks.deinit();
    }

    /// Создать init-задачу (pid=1) по образцу kernel/init_task.c.
    pub fn createInit(self: *TaskManager) !*TaskStruct {
        self.lockAcquire();
        defer self.lockRelease();
        const t = try self.allocTask(null, CloneFlags.VM | CloneFlags.FILES);
        t.pid = 1;
        t.tgid = 1;
        t.setComm("swapper/0");
        t.state = TaskStateFlags.RUNNING;
        t.parent = null;
        try self.tasks.put(1, t);
        self.root = t;
        self.nr_tasks += 1;
        return t;
    }

    fn allocTask(self: *TaskManager, parent: ?*TaskStruct, flags: u64) !*TaskStruct {
        const t = try self.allocator.create(TaskStruct);
        const pid = if (self.next_pid == 0) 1 else self.next_pid;
        self.next_pid += 1;
        t.* = .{
            .pid = pid,
            .tgid = if (flags & CloneFlags.THREAD != 0 and parent != null) parent.?.tgid else pid,
            .parent = parent,
            .flags = flags,
        };
        list.init(&t.children);

        // CLONE_VM: разделяем mm_struct (copy_mm() в kernel/fork.c).
        if (parent) |p| {
            if (flags & CloneFlags.VM != 0) {
                t.mm = p.mm;
                if (t.mm) |mm| mm.get();
            } else {
                const mm = try self.allocator.create(MmStruct);
                mm.* = if (p.mm) |pmm| try MmStruct.dup(self.allocator, pmm) else MmStruct.init(self.allocator);
                t.mm = mm;
            }
            // CLONE_FILES: разделяем files_struct, иначе dup_fd().
            if (flags & CloneFlags.FILES != 0) {
                t.files = p.files;
                if (t.files) |f| f.count += 1;
            } else {
                const files = try self.allocator.create(FilesStruct);
                if (p.files) |pf| {
                    files.* = try pf.cloneFiles();
                } else {
                    files.* = FilesStruct.init(self.allocator);
                }
                t.files = files;
            }
            // copy_process(): наследуем сессию, foreground group и ctty
            // (используются TTY job control), а также signal mask/handlers.
            t.session = p.session;
            t.pgrp = p.pgrp;
            t.ctty = p.ctty;
            t.signals.blocked = p.signals.blocked;
            @memcpy(&t.signals.actions, &p.signals.actions);
            // copy_namespaces(): CLONE_NEWNS вызывает copy_tree() — ребёнок
            // получает независимую копию mount namespace; без флага namespace
            // разделяется по refcount, как mm/files при CLONE_VM/CLONE_FILES.
            if (flags & CloneFlags.NEWNS != 0) {
                const pns = p.ns orelse return error.Inval;
                const ns = try self.allocator.create(vfs.Namespace);
                errdefer self.allocator.destroy(ns);
                try pns.clone(ns);
                errdefer {
                    ns.deinit();
                    self.allocator.destroy(ns);
                }
                t.ns = ns;
            } else if (p.ns) |pns| {
                t.ns = pns;
                pns.get();
            }
            list.addTail(&p.children, &t.sibling);
        } else {
            const mm = try self.allocator.create(MmStruct);
            mm.* = MmStruct.init(self.allocator);
            t.mm = mm;
            const files = try self.allocator.create(FilesStruct);
            files.* = FilesStruct.init(self.allocator);
            t.files = files;
        }
        return t;
    }

    /// copy_process() + wake_up_new_task(): fork/clone.
    pub fn fork(self: *TaskManager, parent: *TaskStruct, flags: u64) !*TaskStruct {
        self.lockAcquire();
        defer self.lockRelease();
        const child = try self.allocTask(parent, flags);
        child.setComm(parent.name());
        child.state = TaskStateFlags.RUNNING;
        child.wake_time = 0;
        try self.tasks.put(child.pid, child);
        self.nr_tasks += 1;
        return child;
    }

    /// fs/exec.c: bprm_execve() — заменить mm/files/creds и handlers.
    /// Упрощения: нет ELF loader/user-space указателей; бинарник уже представлен
    /// `struct file` из registry, argv игнорируется (comm берётся от вызывающего).
    pub fn execve(self: *TaskManager, t: *TaskStruct, binary: *const file.File, comm: []const u8) !void {
        self.lockAcquire();
        defer self.lockRelease();
        if ((binary.f_mode & file.S_IFMT) != file.S_IFREG) return error.EACCES;
        if (t.flags & CloneFlags.THREAD != 0) return error.EPERM; // де_thread() не портирован

        const allocator = if (t.mm) |m|
            m.allocator
        else if (t.files) |f|
            f.allocator
        else
            return error.ENOMEM;

        const new_mm = try allocator.create(MmStruct);
        new_mm.* = MmStruct.init(allocator);
        const new_files = try allocator.create(FilesStruct);
        if (t.files) |old| {
            new_files.* = try old.cloneForExec();
        } else {
            new_files.* = FilesStruct.init(allocator);
        }

        // exit_mm()/exit_files(): старые mm/files освобождаются, если ссылка последняя.
        if (t.mm) |old| {
            if (old.put()) allocator.destroy(old);
        }
        if (t.files) |old| {
            old.count -= 1;
            if (old.count == 0) {
                old.deinit();
                allocator.destroy(old);
            }
        }

        t.mm = new_mm;
        t.files = new_files;
        t.cred = t.cred.forExec(binary.f_mode, binary.uid, binary.gid);
        t.signals.resetForExec();
        t.setComm(comm);
        t.state = TaskStateFlags.RUNNING;
        t.exit_code = 0;
        t.exit_signal = @intCast(Signal.SIGCHLD);
        t.flags &= ~(CloneFlags.VM | CloneFlags.FILES | CloneFlags.SIGHAND | CloneFlags.THREAD);
    }

    /// do_exit(): освободить ресурсы и пометить DEAD.
    pub fn exit(self: *TaskManager, t: *TaskStruct, code: i32) void {
        self.lockAcquire();
        defer self.lockRelease();
        t.exit_code = code;
        t.exit_signal = 0;
        t.state |= TaskStateFlags.DEAD;
        // Зомби остаётся в parent.children до wait4()/reap() — как в Linux.
        // do_exit() только перевешивает детей (forget_original_parent()).
        // forget_original_parent(): перед переносом узла из t.children
        // сохраняем next — иначе итератор уйдёт в новый список.
        var node = t.children.next.?;
        while (node != &t.children) {
            const next = node.next.?;
            const child: *TaskStruct = @fieldParentPtr("sibling", node);
            if (t.parent) |p| list.moveTail(&p.children, &child.sibling);
            child.parent = t.parent;
            node = next;
        }
        if (t.mm) |mm| {
            if (mm.put()) self.allocator.destroy(mm);
            t.mm = null;
        }
        if (t.files) |files| {
            files.count -= 1;
            if (files.count == 0) {
                files.deinit(); // fput() всех fd при последней ссылке
                self.allocator.destroy(files);
            }
            t.files = null;
        }
        if (t.ns) |ns| {
            t.ns = null; // put_task_ns(): последняя ссылка вызывает deinit
            ns.put();
        }
    }

    pub fn find(self: *TaskManager, pid: u32) ?*TaskStruct {
        self.lockAcquire();
        defer self.lockRelease();
        return self.tasks.get(pid);
    }

    pub fn reap(self: *TaskManager, pid: u32) void {
        self.lockAcquire();
        defer self.lockRelease();
        self.reapLocked(pid);
    }

    fn reapLocked(self: *TaskManager, pid: u32) void {
        if (self.tasks.fetchRemove(pid)) |kv| {
            const t = kv.value;
            // Отцепляем зомби от родителя только сейчас (release_task()).
            if (t.parent != null and t.sibling.next != null) list.del(&t.sibling);
            if (t.ns) |ns| {
                t.ns = null;
                ns.put();
            }
            self.allocator.destroy(t);
            self.nr_tasks -= 1;
        }
    }

    /// send_signal() — положить сигнал в pending mask задачи.
    pub fn signal(self: *TaskManager, t: *TaskStruct, sig: u8) void {
        _ = self;
        if (sig >= Signal.NSIG) return;
        // SIGKILL и SIGSTOP не блокируются.
        if (t.signals.blocked.has(sig) and sig != Signal.SIGKILL and sig != Signal.SIGSTOP) return;
        t.signals.pending.add(sig);
        t.signals.need_resched = true;
    }

    /// kill_pgrp() — sys_kill(-pgid, sig) / tty signal hook.
    pub fn signalPgrp(self: *TaskManager, pgrp: u32, sig: u8) void {
        self.lockAcquire();
        defer self.lockRelease();
        var it = self.tasks.valueIterator();
        while (it.next()) |t| {
            if (t.*.pgrp == pgrp) self.signal(t.*, sig);
        }
    }

    /// do_signal() — обработать pending сигналы (упрощённый default action).
    /// Возвращает true, если задача завершилась/остановилась.
    pub fn deliverSignals(self: *TaskManager, t: *TaskStruct) bool {
        var handled = false;
        for (1..Signal.NSIG) |sig_num| {
            const sig: u8 = @intCast(sig_num);
            if (!t.signals.pending.has(sig)) continue;
            t.signals.pending.del(sig);
            const action = t.signals.actions[sig].handler;
            if (action != null) {
                // Пользовательский handler: в порту просто вызываем.
                action.?(sig);
                continue;
            }
            switch (Signal.defaultAction(sig)) {
                .ignore => {},
                .terminate, .core => {
                    self.exit(t, if (sig <= 0x7f) 128 + @as(i32, sig) else -1);
                    return true;
                },
                .stop => {
                    t.signals.stopped = true;
                    t.state |= TaskStateFlags.STOPPED;
                    handled = true;
                },
                .continue_ => {
                    t.signals.stopped = false;
                    t.state &= ~TaskStateFlags.STOPPED;
                    handled = true;
                },
            }
        }
        t.signals.need_resched = false;
        return handled;
    }

    /// sys_setpgid() (kernel/sys.c).
    pub fn setpgid(self: *TaskManager, t: *TaskStruct, pgid: u32) !void {
        _ = self;
        if (t.session == 0) t.session = t.pid; // становится лидером сессии
        if (pgid == 0) {
            t.pgrp = t.pid;
        } else {
            t.pgrp = pgid;
        }
    }

    /// sys_setsid() (kernel/sys.c): новая сессия, сброс ctty.
    pub fn setsid(self: *TaskManager, t: *TaskStruct) !void {
        _ = self;
        if (t.pgrp == t.pid) return error.EPERM; // уже лидер группы
        t.session = t.pid;
        t.pgrp = t.pid;
        t.ctty = null;
    }

    /// Результат sys_wait4(): pid ребёнка и код завершения.
    pub const WaitResult = struct { pid: u32, code: i32 };

    /// sys_wait4(): проверить, есть ли завершившийся ребёнок; вернуть exit_code.
    pub fn wait4(self: *TaskManager, parent: *TaskStruct) ?WaitResult {
        self.lockAcquire();
        defer self.lockRelease();
        var it = list.iterator(&parent.children);
        while (it.next()) |node| {
            const child: *TaskStruct = @fieldParentPtr("sibling", node);
            if (child.isDead()) {
                const result = WaitResult{ .pid = child.pid, .code = child.exit_code };
                self.reapLocked(child.pid);
                return result;
            }
        }
        return null;
    }
};

test "task_struct: fork shares VM with CLONE_VM, separate without" {
    var tm: TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();

    const init = try tm.createInit();
    try std.testing.expectEqual(@as(u32, 1), init.pid);
    try std.testing.expectEqual(@as(u32, 1), init.tgid);
    try std.testing.expect(init.mm != null);

    // CLONE_VM | CLONE_FILES — поток: разделяем mm и files.
    const thread = try tm.fork(init, CloneFlags.VM | CloneFlags.FILES | CloneFlags.THREAD);
    try std.testing.expectEqual(init.tgid, thread.tgid);
    try std.testing.expectEqual(init.mm, thread.mm);
    try std.testing.expectEqual(@as(u32, 2), init.mm.?.mm_count);
    try std.testing.expectEqual(init.files, thread.files);

    // fork() без CLONE_VM — процесс: отдельные mm/files.
    const child = try tm.fork(init, 0);
    try std.testing.expect(child.mm != init.mm);
    try std.testing.expect(child.files != init.files);
    try std.testing.expect(child.tgid == child.pid);

    try std.testing.expectEqual(@as(usize, 3), tm.nr_tasks);

    tm.exit(child, 42);
    try std.testing.expect(child.isDead());
    try std.testing.expectEqual(@as(i32, 42), child.exit_code);
    tm.reap(child.pid);
    try std.testing.expectEqual(@as(usize, 2), tm.nr_tasks);
}

test "CLONE_NEWNS: fork shares mnt namespace or copies tree, exit drops refs" {
    const EmptyOps = struct {
        fn lookup(_: ?*anyopaque, _: *vfs.Dentry, _: vfs.Qstr) ?vfs.InodeInfo {
            return null;
        }
    };
    var root_sb: vfs.SuperBlock = undefined;
    try root_sb.init(std.testing.allocator, 8);
    defer root_sb.deinit();

    var tm: TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();
    const init = try tm.createInit();

    const ns = try std.testing.allocator.create(vfs.Namespace);
    try ns.init(std.testing.allocator, &root_sb, .{ .lookup = EmptyOps.lookup });
    init.ns = ns;
    try std.testing.expectEqual(@as(u32, 1), ns.ref_count);

    const shared = try tm.fork(init, 0);
    try std.testing.expectEqual(ns, shared.ns);
    try std.testing.expectEqual(@as(u32, 2), ns.ref_count);

    const cloned = try tm.fork(init, CloneFlags.NEWNS);
    try std.testing.expect(cloned.ns != null and cloned.ns != ns);
    try std.testing.expectEqual(ns.mounts.items.len, cloned.ns.?.mounts.items.len);
    try std.testing.expectEqual(@as(u32, 1), cloned.ns.?.ref_count);

    tm.exit(shared, 0);
    try std.testing.expect(shared.ns == null);
    try std.testing.expectEqual(@as(u32, 1), ns.ref_count);
    tm.exit(cloned, 0);
    try std.testing.expect(cloned.ns == null); // последняя ссылка освобождает namespace
}

// ─── Сигналы и job control (include/linux/signal.h, kernel/signal.c) ─────────

/// include/uapi/asm-generic/signal.h — номера сигналов Linux.
pub const Signal = struct {
    pub const SIGHUP: u8 = 1;
    pub const SIGINT: u8 = 2;
    pub const SIGQUIT: u8 = 3;
    pub const SIGILL: u8 = 4;
    pub const SIGTRAP: u8 = 5;
    pub const SIGABRT: u8 = 6;
    pub const SIGBUS: u8 = 7;
    pub const SIGFPE: u8 = 8;
    pub const SIGKILL: u8 = 9;
    pub const SIGUSR1: u8 = 10;
    pub const SIGSEGV: u8 = 11;
    pub const SIGUSR2: u8 = 12;
    pub const SIGPIPE: u8 = 13;
    pub const SIGALRM: u8 = 14;
    pub const SIGTERM: u8 = 15;
    pub const SIGSTKFLT: u8 = 16;
    pub const SIGCHLD: u8 = 17;
    pub const SIGCONT: u8 = 18;
    pub const SIGSTOP: u8 = 19;
    pub const SIGTSTP: u8 = 20;
    pub const SIGTTIN: u8 = 21;
    pub const SIGTTOU: u8 = 22;
    pub const SIGURG: u8 = 23;
    pub const SIGXCPU: u8 = 24;
    pub const SIGXFSZ: u8 = 25;
    pub const SIGVTALRM: u8 = 26;
    pub const SIGPROF: u8 = 27;
    pub const SIGWINCH: u8 = 28;
    pub const SIGIO: u8 = 29;
    pub const SIGPWR: u8 = 30;
    pub const SIGSYS: u8 = 31;
    pub const NSIG: u8 = 64;

    /// Действие по умолчанию (kernel/signal.c: sig_task_ignored/sig_ignored).
    pub fn defaultAction(sig: u8) Action {
        return switch (sig) {
            SIGCHLD, SIGURG, SIGWINCH, SIGIO, 0 => .ignore,
            SIGCONT => .continue_,
            SIGSTOP, SIGTSTP, SIGTTIN, SIGTTOU => .stop,
            SIGKILL, SIGINT, SIGQUIT, SIGABRT, SIGTERM, SIGHUP => .terminate,
            SIGTRAP, SIGILL, SIGFPE, SIGBUS, SIGSEGV, SIGSYS => .core,
            else => .terminate,
        };
    }
};

pub const Action = enum { ignore, terminate, core, stop, continue_ };

/// include/linux/signal_types.h: struct sigaction (упрощённо).
pub const SigAction = struct {
    handler: ?*const fn (u8) void = null, // host-порт: ядерный callback
    flags: u32 = 0,
    sa_restart: bool = false,
    /// ring3: адрес user-space handler из rt_sigaction (SIG_DFL/SIG_IGN = 0/1).
    user_handler: u64 = 0,
    /// ring3: sa_mask и sa_restorer из struct sigaction.
    user_mask: u64 = 0,
    restorer: u64 = 0,
};

/// BIAS для 64-битных масок сигналов (include/uapi/asm-generic/signal-defs.h).
pub const SigSet = struct {
    bits: u64 = 0,

    /// linux/signal.h: sigmask(sig) — бит сигнала в 64-битном sigset_t.
    pub fn mask(sig: u8) u64 {
        if (sig == 0 or sig >= Signal.NSIG) return 0;
        return @as(u64, 1) << @intCast(sig - 1);
    }

    /// SIGKILL/SIGSTOP нельзя блокировать (rt_sigprocmask/pthread_sigmask).
    pub const IMMUTABLE: u64 = mask(Signal.SIGKILL) | mask(Signal.SIGSTOP);

    pub fn add(self: *SigSet, sig: u8) void {
        if (sig == 0 or sig >= Signal.NSIG) return;
        self.bits |= @as(u64, 1) << @intCast(sig - 1);
    }

    pub fn del(self: *SigSet, sig: u8) void {
        if (sig == 0 or sig >= Signal.NSIG) return;
        self.bits &= ~(@as(u64, 1) << @intCast(sig - 1));
    }

    pub fn has(self: SigSet, sig: u8) bool {
        if (sig == 0 or sig >= Signal.NSIG) return false;
        return self.bits & (@as(u64, 1) << @intCast(sig - 1)) != 0;
    }
};

/// Расширяем TaskStruct полями session/pgrp/signals. Интрузивные списки
/// уже инициализируются в allocTask; дополнительные поля просто нулевые.
pub const SignalState = struct {
    pending: SigSet = .{},
    blocked: SigSet = .{},
    actions: [Signal.NSIG]SigAction = @splat(.{}),
    stopped: bool = false,
    /// syscall preemption point — доставить сигналы перед возвратом в user.
    need_resched: bool = false,

    /// fs/exec.c: flush_signal_handlers() — перехваченные сигналы сбрасываются
    /// на действие по умолчанию, маска blocked сохраняется, pending очищается.
    pub fn resetForExec(self: *SignalState) void {
        for (&self.actions) |*action| {
            if (action.handler != null or action.user_handler > 1) action.* = .{};
        }
        self.pending = .{};
        self.stopped = false;
        self.need_resched = false;
    }

    /// __x64_sys_rt_sigaction(): установить/вернуть prev handler, mask, restorer.
    pub fn setAction(self: *SignalState, sig: u8, handler: u64, flags: u64, mask_bits: u64, restorer: u64) !SigAction {
        if (sig == 0 or sig >= Signal.NSIG) return error.EINVAL;
        // SIGKILL/SIGSTOP не перехватываются.
        if (sig == Signal.SIGKILL or sig == Signal.SIGSTOP) return error.EINVAL;
        const prev = self.actions[sig];
        self.actions[sig] = .{
            .handler = null,
            .flags = @truncate(flags),
            .sa_restart = (flags & SA_RESTART) != 0,
            .user_handler = handler,
            .user_mask = mask_bits & ~SigSet.IMMUTABLE,
            .restorer = restorer,
        };
        return prev;
    }

    /// __x64_sys_rt_sigprocmask(): how = SIG_BLOCK/SIG_UNBLOCK/SIG_SETMASK.
    pub fn applyMask(self: *SignalState, how: u32, bits: u64) !u64 {
        const set = bits & ~SigSet.IMMUTABLE;
        const prev = self.blocked.bits;
        self.blocked.bits = switch (how) {
            SIG_BLOCK => prev | set,
            SIG_UNBLOCK => prev & ~set,
            SIG_SETMASK => set,
            else => return error.EINVAL,
        };
        return prev;
    }
};

/// include/uapi/asm-generic/signal.h / asm/signal.h.
pub const SIG_BLOCK: u32 = 0;
pub const SIG_UNBLOCK: u32 = 1;
pub const SIG_SETMASK: u32 = 2;
pub const SA_SIGINFO: u64 = 0x0000_0004;
pub const SA_NODEFER: u64 = 0x4000_0000;
pub const SA_RESTORER: u64 = 0x0400_0000;
pub const SA_RESTART: u64 = 0x1000_0000;

test "signals: SigSet masks, default actions" {
    var set: SigSet = .{};
    set.add(Signal.SIGINT);
    set.add(Signal.SIGKILL);
    try std.testing.expect(set.has(Signal.SIGINT));
    try std.testing.expect(set.has(Signal.SIGKILL));
    try std.testing.expect(!set.has(Signal.SIGTERM));
    set.del(Signal.SIGINT);
    try std.testing.expect(!set.has(Signal.SIGINT));
    try std.testing.expectEqual(Action.stop, Signal.defaultAction(Signal.SIGTSTP));
    try std.testing.expectEqual(Action.ignore, Signal.defaultAction(Signal.SIGCHLD));
    try std.testing.expectEqual(Action.terminate, Signal.defaultAction(Signal.SIGINT));
}

test "rt_sigaction/rt_sigprocmask: handler, mask and immutable signals" {
    var state: SignalState = .{};
    const prev = try state.setAction(Signal.SIGUSR1, 0x7000_0000_1000, SA_SIGINFO | SA_RESTART, SigSet.mask(Signal.SIGUSR2) | SigSet.IMMUTABLE, 0x7000_0000_2000);
    try std.testing.expectEqual(@as(u64, 0), prev.user_handler);
    try std.testing.expectEqual(@as(u64, 0x7000_0000_1000), state.actions[Signal.SIGUSR1].user_handler);
    try std.testing.expect(state.actions[Signal.SIGUSR1].sa_restart);
    try std.testing.expectEqual(SigSet.mask(Signal.SIGUSR2), state.actions[Signal.SIGUSR1].user_mask);
    try std.testing.expectError(error.EINVAL, state.setAction(Signal.SIGKILL, 1, 0, 0, 0));
    try std.testing.expectEqual(@as(u64, 0), try state.applyMask(SIG_BLOCK, SigSet.mask(Signal.SIGUSR1) | SigSet.IMMUTABLE));
    try std.testing.expect(state.blocked.has(Signal.SIGUSR1));
    try std.testing.expect(!state.blocked.has(Signal.SIGKILL));
    try std.testing.expectEqual(SigSet.mask(Signal.SIGUSR1), try state.applyMask(SIG_SETMASK, SigSet.mask(Signal.SIGUSR1)));
    try std.testing.expectEqual(@as(u64, SigSet.mask(Signal.SIGUSR1)), try state.applyMask(SIG_UNBLOCK, SigSet.mask(Signal.SIGUSR1)));
    try std.testing.expect(!state.blocked.has(Signal.SIGUSR1));
}

test "exit: children are reparented without corrupting the sibling list" {
    var tm: TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();
    const init = try tm.createInit();
    const child = try tm.fork(init, 0);
    const grandchild = try tm.fork(child, 0);
    try std.testing.expectEqual(@as(usize, 1), list.count(&child.children));
    tm.exit(child, 0);
    try std.testing.expectEqual(init, grandchild.parent.?);
    try std.testing.expectEqual(@as(usize, 2), list.count(&init.children));
    try std.testing.expectEqual(@as(usize, 3), tm.nr_tasks);
}

test "job control: signalPgrp delivers ^C, SIGTSTP stops, wait4 reaps" {
    var tm: TaskManager = undefined;
    tm.init(std.testing.allocator);
    defer tm.deinit();
    const init = try tm.createInit();
    const child = try tm.fork(init, 0);
    child.setComm("worker");
    try tm.setpgid(child, 50);

    // ^C: SIGINT по указателю tty.pgrp = 50.
    tm.signalPgrp(50, Signal.SIGINT);
    try std.testing.expect(child.signals.pending.has(Signal.SIGINT));
    try std.testing.expect(tm.deliverSignals(child));
    try std.testing.expect(child.isDead());
    try std.testing.expectEqual(@as(i32, 130), child.exit_code); // 128 + SIGINT

    // wait4(): забрать код завершения (сохраняем pid до reap()).
    const child_pid = child.pid;
    const reaped = tm.wait4(init).?;
    try std.testing.expectEqual(child_pid, reaped.pid);
    try std.testing.expectEqual(@as(i32, 130), reaped.code);

    // ^Z: SIGTSTP останавливает, SIGCONT продолжает.
    const worker = try tm.fork(init, 0);
    try tm.setpgid(worker, 60);
    tm.signal(worker, Signal.SIGTSTP);
    _ = tm.deliverSignals(worker);
    try std.testing.expect(worker.signals.stopped);
    try std.testing.expect(worker.state & TaskStateFlags.STOPPED != 0);
    tm.signal(worker, Signal.SIGCONT);
    _ = tm.deliverSignals(worker);
    try std.testing.expect(!worker.signals.stopped);

    // setsid(): новая сессия сбрасывает ctty.
    worker.ctty = 0;
    try tm.setsid(worker);
    try std.testing.expectEqual(worker.pid, worker.session);
    try std.testing.expect(worker.ctty == null);
}

fn concurrentForkWorker(tm: *TaskManager, parent: *TaskStruct, count: usize) void {
    for (0..count) |_| {
        _ = tm.fork(parent, CloneFlags.VM | CloneFlags.FILES) catch unreachable;
    }
}

test "SMP: concurrent fork serializes pidhash and allocates unique pids" {
    var tm: TaskManager = undefined;
    tm.init(std.heap.page_allocator);
    defer tm.deinit();
    const init = try tm.createInit();

    const workers = 4;
    const per_worker = 32;
    var threads: [workers]std.Thread = undefined;
    for (&threads) |*thread| {
        thread.* = try std.Thread.spawn(.{}, concurrentForkWorker, .{ &tm, init, per_worker });
    }
    for (threads) |thread| thread.join();

    const expected = 1 + workers * per_worker;
    try std.testing.expectEqual(expected, tm.nr_tasks);
    try std.testing.expectEqual(expected, tm.tasks.count());

    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();
    var it = tm.tasks.keyIterator();
    while (it.next()) |pid| try seen.put(pid.*, {});
    try std.testing.expectEqual(expected, seen.count());
}
