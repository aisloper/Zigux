//! ring3 + syscall entry для x86_64: порт подсистемы user mode из zigos с
//! привязкой к task_struct/EEVDF/syscall-диспетчеру ziglinux.
//! Источники: arch/x86/entry/entry_64.S, arch/x86/kernel/cpu/common.c (MSR_STAR,
//! MSR_LSTAR, MSR_SFMASK), fs/exec.c (setup_arg_pages). Демо-бинарник ниже —
//! минимальная statically linked программа, вызывающая write(1, ...) и exit(0).
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const task = @import("../task.zig");
const k_sched = @import("../sched.zig");
const syscall = @import("../syscall.zig");
const vma = @import("../mm/vma.zig");
const file = @import("../file.zig");
const vfs = @import("../vfs.zig");
const ramfs = @import("../ramfs.zig");
const x86 = @import("x86_64.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const elf = @import("elf.zig");
const fault = @import("fault.zig");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");
const printk = @import("printk.zig");
const arch_sched = @import("sched.zig");
const percpu = @import("percpu.zig");
const timer = @import("timer.zig");
const vt_mod = @import("../vt.zig");
const stdio_mod = @import("../stdio.zig");
const arch_tty = @import("tty.zig");
const keyboard_drv = @import("drivers/keyboard.zig");
const xhci_drv = @import("drivers/xhci.zig");

// Ассемблерные входы в ring3 читают те же per-CPU слоты, что syscall_entry/IDT.
const gs_fork_frame = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_FORK_FRAME});
const gs_user_pml4 = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_USER_PML4});
const gs_user_entry = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_USER_ENTRY});
const gs_user_rsp = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_USER_RSP});

/// USER_BASE из zigos/user.zig: не конфликтует с identity-map физической памяти.
pub const USER_BASE: usize = 0x0000_7000_0000_0000;
const USER_STACK_PAGES: usize = 4;
/// Далеко от ELF/heap: 16 МиБ max brk не дотянутся до стека.
const USER_STACK_BASE: usize = USER_BASE + 0x4000_0000;
const USER_STACK_TOP: usize = USER_STACK_BASE + USER_STACK_PAGES * pmm.PAGE;

/// Статический ELF64 (src/arch/userdemo.s), собранный `ld -nostdlib -static`.
const demo_elf = @embedFile("userdemo.elf");

pub var task_manager: ?*task.TaskManager = null;

/// Реальный namei: общий vfs.SuperBlock + RamFs. Файл доступен и ring3-демо
/// (open), и fault handler (file-backed mmap).
var demo_fs: ramfs.RamFs = undefined;
/// init task's mount namespace (non-owning global; task_struct.ns owns ref).
pub var boot_ns: ?*vfs.Namespace = null;

fn setupDemoFiles(allocator: std.mem.Allocator, sb: *vfs.SuperBlock) void {
    demo_fs = ramfs.RamFs.init(allocator, sb);
    _ = demo_fs.addFile("/demo-data.txt", "FILE!\n") catch x86.halt();
    demo_fs.mkdir("/mnt") catch x86.halt();
    // ring3-демо открывает /demo.txt; namei должен пройти через symlink.
    _ = demo_fs.addSymlink("/demo.txt", "/demo-data.txt") catch x86.halt();
}

/// Порядок регистров совпадает с последовательностью push в syscall_entry.
pub const SysFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    rbp: u64,
    rbx: u64,
    r9: u64,
    r8: u64,
    r10: u64,
    rdx: u64,
    rsi: u64,
    rdi: u64,
    nr: u64,
    rip: u64,
    rflags: u64,
    rsp: u64,
};

extern fn syscall_entry() void;

/// arch/x86/include/asm/sigframe.h: struct rt_sigframe ( без FPU-состояния ).
/// pretcode + ucontext + siginfo; смещения совпадают с Linux 7.3, поэтому
/// user-space signal handler видит обычный ucontext_t.
pub const SigFrame = extern struct {
    pretcode: u64,
    uc_flags: u64,
    uc_link: u64,
    uc_stack: [3]u64,
    gregs: [23]u64,
    uc_sigmask: u64,
    info: [16]u64,
};

pub const UserSigAction = extern struct {
    handler: u64,
    flags: u64,
    mask: u64,
    restorer: u64,
};

const REG_R8: usize = 0;
const REG_RDI: usize = 8;
const REG_RAX: usize = 13;
const REG_RCX: usize = 14;
const REG_RSP: usize = 15;
const REG_RIP: usize = 16;
const REG_EFL: usize = 17;
const UC_OFFSET: usize = 8;
const INFO_OFFSET: usize = @sizeOf(SigFrame) - 128;

/// __kernel_rt_sigreturn из vdso: mov $__NR_rt_sigreturn,%eax; syscall.
const sigtramp_code = [_]u8{ 0xb8, 0x0f, 0x00, 0x00, 0x00, 0x0f, 0x05 };
const SIGTRAMPOLINE: usize = USER_STACK_BASE;

// Win64 ABI: syscallDispatch(frame) вызывается с rcx/rdi = frame + 32-byte shadow.
// Все слоты берутся через %gs текущего CPU — BSP и AP используют один и тот же
// entrance code, но разные CR3/kernel stack/таблицы страниц пользователя.
comptime {
    const gs_scratch = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_SCRATCH});
    const gs_kcr3 = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_KCR3});
    const gs_ucr3 = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_UCR3});
    const gs_kstack = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_KSTACK});
    const gs_urs = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_URS});
    asm (".text\n" ++
            ".globl syscall_entry\n" ++
            "syscall_entry:\n" ++
            "movq %rax, " ++ gs_scratch ++ "\n" ++
            "movq " ++ gs_kcr3 ++ ", %rax\n" ++
            "movq %rax, %cr3\n" ++
            "movq %rsp, " ++ gs_urs ++ "\n" ++
            "movq " ++ gs_kstack ++ ", %rsp\n" ++
            "movq " ++ gs_scratch ++ ", %rax\n" ++
            "pushq " ++ gs_urs ++ "\n" ++
            "pushq %r11\n" ++
            "pushq %rcx\n" ++
            "pushq %rax\n" ++
            "pushq %rdi\n" ++
            "pushq %rsi\n" ++
            "pushq %rdx\n" ++
            "pushq %r10\n" ++
            "pushq %r8\n" ++
            "pushq %r9\n" ++
            "pushq %rbx\n" ++
            "pushq %rbp\n" ++
            "pushq %r12\n" ++
            "pushq %r13\n" ++
            "pushq %r14\n" ++
            "pushq %r15\n" ++
            "cld\n" ++
            "movq %rsp, %rbx\n" ++
            "subq $512, %rsp\n" ++
            "andq $-16, %rsp\n" ++
            "fxsave (%rsp)\n" ++
            "movq %rbx, %rcx\n" ++
            "movq %rbx, %rdi\n" ++
            "subq $32, %rsp\n" ++
            "call syscallDispatch\n" ++
            "cli\n" ++
            "movq %rax, " ++ gs_scratch ++ "\n" ++
            "addq $32, %rsp\n" ++
            "fxrstor (%rsp)\n" ++
            "movq %rbx, %rsp\n" ++
            "popq %r15\n" ++
            "popq %r14\n" ++
            "popq %r13\n" ++
            "popq %r12\n" ++
            "popq %rbp\n" ++
            "popq %rbx\n" ++
            "popq %r9\n" ++
            "popq %r8\n" ++
            "popq %r10\n" ++
            "popq %rdx\n" ++
            "popq %rsi\n" ++
            "popq %rdi\n" ++
            "addq $8, %rsp\n" ++
            "popq %rcx\n" ++
            "popq %r11\n" ++
            "popq %rax\n" ++
            "movq %rax, " ++ gs_urs ++ "\n" ++
            "movq " ++ gs_ucr3 ++ ", %rax\n" ++
            "movq %rax, %cr3\n" ++
            "movq " ++ gs_urs ++ ", %rsp\n" ++
            "movq " ++ gs_scratch ++ ", %rax\n" ++
            "sysretq\n");
}

fn userFault(vector: u64, rip: u64, error_code: u64, cr2: u64) noreturn {
    printk.print("user fault: vector={d} rip={x:0>16} error={x} cr2={x:0>16}\n", .{ vector, rip, error_code, cr2 });
    arch_sched.exitCurrent(timer.now());
}

/// ENTRY_SYSCALL: EFER.SCE + STAR/LSTAR/SFMASK. MSR per-CPU, поэтому BSP и
/// каждый AP вызывают это после своей GDT/IDT/per-CPU загрузки.
pub fn initSyscallMsrs() void {
    x86.wrmsr(0xC0000080, x86.rdmsr(0xC0000080) | 1); // EFER.SCE
    x86.wrmsr(0xC0000081, (@as(u64, 0x10) << 48) | (@as(u64, 0x08) << 32)); // STAR
    x86.wrmsr(0xC0000082, @intFromPtr(&syscall_entry)); // LSTAR
    x86.wrmsr(0xC0000084, 0x40700); // SFMASK: IF, DF, TF, AC
}

/// Должно вызываться после gdt.init(), idt.init(), paging.init() и
/// arch_sched.init() на BSP.
pub fn init(tm: *task.TaskManager, allocator: std.mem.Allocator, sb: *vfs.SuperBlock) void {
    task_manager = tm;
    setupDemoFiles(allocator, sb);
    // task_struct.nsproxy.mnt_ns для init и всех fork-детей: mountpoint-ы
    // disk-драйвера видны и ring3 через syscall.Context.ns.
    const ns = allocator.create(vfs.Namespace) catch x86.halt();
    ns.* = undefined;
    ns.init(allocator, sb, demo_fs.ops()) catch x86.halt();
    if (tm.root) |init_task| init_task.ns = ns;
    boot_ns = ns;
    const ci = percpu.index();
    percpu.reset(ci);
    percpu.state(ci).kcr3 = paging.kernelCr3();
    percpu.load(ci);
    initSyscallMsrs();
    idt.user_fault_hook = userFault;
    idt.user_page_fault_hook = fault.handlePageFault;
    arch_sched.switch_hook = switchUserContext;
    printk.write("ziglinux: SYSCALL/SYSRET ready\n");
}

/// Общий опрос драйверов ввода: PS/2, UART и HID кормят активный VT.
pub fn pumpTty(sw: *vt_mod.Switcher) void {
    keyboard_drv.poll(sw); // PS/2 → input.Keyboard → vt.feedKey()
    arch_tty.poll(sw.activeTty()); // UART → tty.receive()
    xhci_drv.poll(sw); // HID boot reports → input.Keyboard → vt.feedKey()
}

/// fs/file.c: fd 0/1/2 работают через line discipline активного TTY.
pub fn setupStdio(t: *task.TaskStruct, allocator: std.mem.Allocator, sw: *vt_mod.Switcher) !void {
    const files = t.files orelse return error.NoFiles;
    const ops = try allocator.create(stdio_mod.Ops);
    ops.* = stdio_mod.Ops.init(sw, pumpTty);
    for (0..3) |_| {
        const f = try allocator.create(file.File);
        f.* = .{ .f_ops = ops.fileOps() };
        _ = try files.allocFd(f); // fd 0, 1, 2
    }
}

fn userSlice(addr: u64, len: u64) ?[]const u8 {
    const start: usize = @intCast(addr);
    const n: usize = @intCast(len);
    const end = std.math.add(usize, start, n) catch return null;
    // access_ok() сверяется с VMA текущего mm, затем get_user_pages()
    // подготавливает страницы anon-стека/кучи до чтения ядром.
    if (!fault.accessOk(start, n) or !fault.ensureRange(start, end)) return null;
    return @as([*]const u8, @ptrFromInt(start))[0..n];
}

/// sys_open(): скопировать NUL-терминированный pathname из ring 3.
fn userCString(addr: u64, buf: []u8) ?[]const u8 {
    // По байтам: pathname может заканчиваться в конце VMA, поэтому нельзя
    // требовать весь 256-байтный буфер сразу (как userSlice делает для read).
    var i: usize = 0;
    while (i < buf.len) : (i += 1) {
        const b = readUser(u8, addr + i) orelse return null;
        if (b == 0) return buf[0..i];
        buf[i] = b;
    }
    return null;
}

fn userSliceMut(addr: u64, len: u64) ?[]u8 {
    const start: usize = @intCast(addr);
    const n: usize = @intCast(len);
    const end = std.math.add(usize, start, n) catch return null;
    if (!fault.accessOk(start, n) or !fault.ensureRange(start, end)) return null;
    return @as([*]u8, @ptrFromInt(start))[0..n];
}

fn readUser(comptime T: type, addr: u64) ?T {
    const bytes = userSlice(addr, @sizeOf(T)) orelse return null;
    var value: T = undefined;
    @memcpy(std.mem.asBytes(&value), bytes);
    return value;
}

fn writeUser(comptime T: type, addr: u64, value: T) bool {
    const bytes = userSliceMut(addr, @sizeOf(T)) orelse return false;
    @memcpy(bytes, std.mem.asBytes(&value));
    return true;
}

fn syserr(e: i32) u64 {
    return @bitCast(-@as(i64, e));
}

/// arch/x86/kernel/signal.c: setup_rt_frame(). Кладём struct rt_sigframe на
/// пользовательский стек и подменяем SysFrame так, чтобы sysretq вошёл в
/// handler с RDI=signo, RSI=&siginfo, RDX=&ucontext. Возврат из handler
/// переходит на sigtrampoline, который вызывает rt_sigreturn.
fn setupSignalFrame(f: *SysFrame, t: *task.TaskStruct, sig: u8, rax: u64, action: task.SigAction) bool {
    const frame_size = @sizeOf(SigFrame);
    const sp = (f.rsp - 8) & ~@as(u64, 15);
    const base = sp - frame_size;
    if (!fault.accessOk(@intCast(base), frame_size) or !fault.ensureRange(@intCast(base), @intCast(base + frame_size))) return false;

    var frame = std.mem.zeroes(SigFrame);
    frame.pretcode = SIGTRAMPOLINE;
    frame.uc_stack[1] = 2; // SS_DISABLE
    frame.gregs = .{
        f.r8,  f.r9,     f.r10, f.rflags, f.r12, f.r13, f.r14, f.r15,
        f.rdi, f.rsi,    f.rbp, f.rbx,    f.rdx, rax,   f.rip, f.rsp,
        f.rip, f.rflags, 0x23,  0,        0,     0x1b,  0,
    };
    frame.uc_sigmask = t.signals.blocked.bits;
    frame.info[0] = sig; // si_signo
    frame.info[1] = 0; // si_code = SI_USER
    if (!writeUser(SigFrame, base, frame)) return false;

    // во время handler сигнал заблокирован, sa_mask тоже действует
    t.signals.blocked.bits |= task.SigSet.mask(sig) | action.user_mask;
    if (action.flags & task.SA_NODEFER != 0) t.signals.blocked.bits &= ~task.SigSet.mask(sig);

    f.rdi = sig;
    f.rsi = base + INFO_OFFSET;
    f.rdx = base + UC_OFFSET;
    f.rip = action.user_handler;
    f.rsp = base; // pretcode — первый qword кадра, адрес возврата из handler
    return true;
}

/// arch/x86/kernel/signal_64.c: sys_rt_sigreturn(). Восстановить SysFrame из
/// rt_sigframe и вернуть сохранённое значение RAX (результат прерванного syscall).
fn doRtSigreturn(f: *SysFrame, t: *task.TaskStruct) ?u64 {
    const base = f.rsp - 8;
    const frame = readUser(SigFrame, base) orelse return null;
    t.signals.blocked.bits = frame.uc_sigmask & ~task.SigSet.IMMUTABLE;
    const g = frame.gregs;
    f.r8 = g[0];
    f.r9 = g[1];
    f.r10 = g[2];
    f.r12 = g[4];
    f.r13 = g[5];
    f.r14 = g[6];
    f.r15 = g[7];
    f.rdi = g[8];
    f.rsi = g[9];
    f.rbp = g[10];
    f.rbx = g[11];
    f.rdx = g[12];
    f.rip = g[16];
    f.rflags = g[17] | 0x202; // IF always on in user mode
    f.rsp = g[15];
    f.nr = syscall.SyscallNo.rt_sigreturn;
    return g[REG_RAX];
}

fn doRtSigaction(t: *task.TaskStruct, f: *SysFrame) u64 {
    if (f.r10 != 8) return syserr(syscall.Errno.EINVAL);
    const sig: u8 = @truncate(f.rdi);
    const act = readUser(UserSigAction, f.rsi) orelse return syserr(syscall.Errno.EFAULT);
    const prev = t.signals.setAction(sig, act.handler, act.flags, act.mask, act.restorer) catch {
        return syserr(syscall.Errno.EINVAL);
    };
    if (f.rdx != 0) {
        const old = UserSigAction{
            .handler = prev.user_handler,
            .flags = prev.flags,
            .mask = prev.user_mask,
            .restorer = prev.restorer,
        };
        if (!writeUser(UserSigAction, f.rdx, old)) return syserr(syscall.Errno.EFAULT);
    }
    return 0;
}

fn doRtSigprocmask(t: *task.TaskStruct, f: *SysFrame) u64 {
    if (f.r10 != 8) return syserr(syscall.Errno.EINVAL);
    const bits = if (f.rsi != 0) (readUser(u64, f.rsi) orelse return syserr(syscall.Errno.EFAULT)) else 0;
    const prev = t.signals.applyMask(@truncate(f.rdi), bits) catch {
        return syserr(syscall.Errno.EINVAL);
    };
    if (f.rdx != 0 and !writeUser(u64, f.rdx, prev)) return syserr(syscall.Errno.EFAULT);
    return 0;
}

/// do_signal() на границе syscall → user mode. Default action для fatal-сигналов
/// завершает задачу; перехваченный сигнал получает rt_sigframe.
fn deliverSignal(f: *SysFrame, rax: u64) void {
    const t = arch_sched.current() orelse return;
    var sig: u8 = 0;
    for (1..task.Signal.NSIG) |s| {
        const num: u8 = @intCast(s);
        if (t.signals.pending.has(num) and !t.signals.blocked.has(num)) {
            sig = num;
            break;
        }
    }
    if (sig == 0) return;
    t.signals.pending.del(sig);
    const action = t.signals.actions[sig];
    if (action.user_handler == 1) return; // SIG_IGN
    if (action.user_handler == 0) {
        switch (task.Signal.defaultAction(sig)) {
            .ignore, .continue_ => return,
            .stop => {
                t.signals.stopped = true;
                t.state |= task.TaskStateFlags.STOPPED;
                return;
            },
            .terminate, .core => {
                t.exit_code = -@as(i32, sig);
                arch_sched.exitCurrent(timer.now());
            },
        }
    }
    if (!setupSignalFrame(f, t, sig, rax, action)) {
        printk.print("ziglinux: signal frame failed for sig={d}\n", .{sig});
        arch_sched.exitCurrent(timer.now());
    }
}

/// __kernel_rt_sigreturn из vdso: mov $__NR_rt_sigreturn,%eax; syscall.
fn setupSignalTrampoline(kernel_cr3: u64, user_cr3: u64) void {
    const phys = pmm.allocFrame() orelse x86.halt();
    const code: [*]u8 = @ptrFromInt(phys);
    @memset(code[0..pmm.PAGE], 0);
    @memcpy(code[0..sigtramp_code.len], &sigtramp_code);
    paging.mapUserPage(kernel_cr3, SIGTRAMPOLINE, phys) catch x86.halt();
    paging.mapUserPage(user_cr3, SIGTRAMPOLINE, phys) catch x86.halt();
    x86.writeCr3(@intCast(kernel_cr3));
}

/// switch_to() для ring3: sysret/IDT должны видеть PML4 и kernel stack новой
/// задачи. Вызывается из arch_sched.yield()/trampoline() на каждом CPU.
fn switchUserContext() void {
    const t = arch_sched.current() orelse return;
    if (t.arch.user_cr3 == 0) return;
    const st = percpu.current();
    st.user_pml4 = t.arch.user_cr3;
    st.ucr3 = t.arch.user_cr3;
    st.kcr3 = if (t.arch.kernel_cr3 != 0) t.arch.kernel_cr3 else paging.kernelCr3();
    st.kstack = t.arch.stack + t.arch.pages * pmm.PAGE;
    gdt.setRsp0Cpu(percpu.index(), st.kstack);
    x86.writeCr3(@intCast(st.kcr3));
}

/// copy_process()+wake_up_new_task() для fork() из ring3. Вместо CLONE_VM
/// ребёнок получает копию mm/VMA, отдельный PML4 с COW-PTE и собственный
/// kernel stack; sysret в ребёнка возвращает RAX=0 в точке после syscall.
fn doFork(parent: *task.TaskStruct, f: *SysFrame, tm: *task.TaskManager) u64 {
    const parent_cr3 = percpu.current().ucr3;
    const rq = arch_sched.rq() orelse return syserr(syscall.Errno.ENOSYS);
    if (parent_cr3 == 0) return syserr(syscall.Errno.ENOSYS);
    const stack = pmm.allocContiguous(arch_sched.STACK_PAGES) orelse return syserr(syscall.Errno.ENOMEM);
    const child = tm.fork(parent, 0) catch |e| {
        pmm.free(stack, arch_sched.STACK_PAGES);
        return syserr(if (e == error.OutOfMemory) syscall.Errno.ENOMEM else syscall.Errno.EAGAIN);
    };
    child.arch.user_cr3 = paging.cloneUserPml4(parent_cr3);
    child.arch.kernel_cr3 = paging.newKernelAlias();
    child.se.setLoadWeight(0);
    arch_sched.setupStack(child, stack, arch_sched.STACK_PAGES, enterForkedUser);

    const frame = tm.allocator.create(SysFrame) catch {
        pmm.free(stack, arch_sched.STACK_PAGES);
        return syserr(syscall.Errno.ENOMEM);
    };
    frame.* = f.*;
    child.arch.fork_frame = frame;

    // Новорожденному — небольшой vlag, как wake_up_new_task(): иначе EEVDF
    // может держать slice у текущего kworker и не запустить ребёнка.
    child.se.vlag = 20 * 1000 * 1000;
    rq.enqueueEntity(&child.se, timer.now(), true);
    rq.need_resched = true;
    paging.flushUserTlb(parent_cr3);
    printk.print("ziglinux: fork child {d} cr3={x:0>16}\n", .{ child.pid, child.arch.user_cr3 });
    return @intCast(child.pid);
}

/// Первый запуск ребёнка после fork(): вернуться в ring 3 в точке syscall,
/// но с RAX=0. VMA/PML4 уже разделены, SysFrame сохранён в task_struct.
fn enterForkedUser() noreturn {
    const t = arch_sched.current() orelse x86.halt();
    const f: *SysFrame = @ptrCast(@alignCast(t.arch.fork_frame orelse x86.halt()));
    switchUserContext();
    percpu.current().fork_frame = @intFromPtr(f);
    // sysretq восстанавливает только RIP/RFLAGS/RSP — GPR ребёнка берём из
    // сохранённого SysFrame (как обычный epilogue syscall_entry).
    asm volatile ("movq " ++ gs_fork_frame ++ ", %rax\n" ++
            "movq 0(%rax), %r15\n" ++
            "movq 8(%rax), %r14\n" ++
            "movq 16(%rax), %r13\n" ++
            "movq 24(%rax), %r12\n" ++
            "movq 32(%rax), %rbp\n" ++
            "movq 40(%rax), %rbx\n" ++
            "movq 48(%rax), %r9\n" ++
            "movq 56(%rax), %r8\n" ++
            "movq 64(%rax), %r10\n" ++
            "movq 72(%rax), %rdx\n" ++
            "movq 80(%rax), %rsi\n" ++
            "movq 88(%rax), %rdi\n" ++
            "movq 104(%rax), %rcx\n" ++
            "movq 112(%rax), %r11\n" ++
            "movq 120(%rax), %rsp\n" ++
            "movq " ++ gs_user_pml4 ++ ", %rax\n" ++
            "movq %rax, %cr3\n" ++
            "xorl %eax, %eax\n" ++
            "sysretq\n" ::: .{ .rax = true, .rcx = true, .r11 = true, .rsp = true, .memory = true });
    unreachable;
}

fn enterDemo() noreturn {
    const t = arch_sched.current() orelse x86.halt();
    // У каждой ring3-задачи свой kernel alias: общий PML4 ядра не должен
    // хранить чужие user-страницы по одним и тем же виртуальным адресам.
    const kernel_cr3 = paging.newKernelAlias();
    const user_pml4 = paging.cloneKernelPml4();
    // vdso-подобная trampoline для rt_sigreturn: отображается в beide PML4.
    setupSignalTrampoline(kernel_cr3, user_pml4);

    // fs/binfmt_elf.c: загрузить PT_LOAD-сегменты static ELF в PML4 процесса
    // и зарегистрировать их VMA с правами из ELF p_flags.
    const loaded = elf.load(kernel_cr3, user_pml4, demo_elf) catch x86.halt();
    const mm = t.mm orelse x86.halt();
    var heap_end: u64 = 0;
    for (loaded.ranges[0..loaded.count]) |r| {
        _ = mm.vmas.insertRaw(@intCast(r.start), @intCast(r.end), vma.flagsForProt(r.prot) | vma.VM_ACCOUNT, r.prot) catch x86.halt();
        heap_end = @max(heap_end, @as(u64, @intCast(r.end)));
    }

    // setup_arg_pages(): VM_ANON-стек. Страницы не выделяются заранее — первое
    // обращение из ring 3 вызовет #PF, который обработает fault.handlePageFault()
    // по образцу do_anonymous_page() из mm/memory.c.
    _ = mm.vmas.insertRaw(@intCast(USER_STACK_BASE), @intCast(USER_STACK_TOP), vma.flagsForProt(vma.PROT_READ | vma.PROT_WRITE) | vma.VM_GROWSDOWN | vma.VM_ACCOUNT, vma.PROT_READ | vma.PROT_WRITE) catch x86.halt();

    // brk(2) расширяет кучу через anon-VMA; первая запись — тоже demand page fault.
    mm.start_brk = vma.alignUp(heap_end + 0x10000, vma.PAGE_SIZE);
    mm.brk = mm.start_brk;

    const st = percpu.current();
    st.kcr3 = kernel_cr3;
    st.ucr3 = user_pml4;
    st.user_pml4 = user_pml4;
    st.user_entry = loaded.entry;
    st.user_rsp = USER_STACK_TOP - 16;
    st.kstack = t.arch.stack + t.arch.pages * pmm.PAGE;
    t.arch.user_cr3 = user_pml4;
    t.arch.kernel_cr3 = kernel_cr3;
    gdt.setRsp0Cpu(percpu.index(), st.kstack);
    x86.wrmsr(0xC0000100, 0); // FS base
    asm volatile ("xorl %eax, %eax\n" ++
            "xorl %ebx, %ebx\n" ++
            "xorl %ecx, %ecx\n" ++
            "xorl %edx, %edx\n" ++
            "xorl %esi, %esi\n" ++
            "xorl %edi, %edi\n" ++
            "xorl %r8d, %r8d\n" ++
            "xorl %r9d, %r9d\n" ++
            "xorl %r10d, %r10d\n" ++
            "xorl %r11d, %r11d\n" ++
            "movq " ++ gs_user_rsp ++ ", %rsp\n" ++
            "movq " ++ gs_user_pml4 ++ ", %rax\n" ++
            "movq %rax, %cr3\n" ++
            "movq " ++ gs_user_entry ++ ", %rcx\n" ++
            "movq $0x202, %r11\n" ++
            "sysretq\n" ::: .{ .rax = true, .rcx = true, .r11 = true, .rsp = true, .memory = true });
    unreachable;
}

/// sys_mprotect(): VMA уже обновлён Context.dispatch(), синхронизируем RW-бит
/// в PTE ядерного и пользовательского PML4 (protection_map[] в mm/mprotect.c).
fn syncMprotect(start: u64, len: u64, prot: u64) void {
    const writable = (prot & vma.PROT_WRITE) != 0;
    const begin = vma.alignDown(start, vma.PAGE_SIZE);
    const end = vma.alignUp(start +| len, vma.PAGE_SIZE);
    const st = percpu.current();
    const kcr3 = st.kcr3;
    const ucr3 = st.ucr3;
    var va = begin;
    while (va < end) : (va += vma.PAGE_SIZE) {
        _ = paging.setUserPageWritable(kcr3, @intCast(va), writable);
        _ = paging.setUserPageWritable(ucr3, @intCast(va), writable);
    }
    x86.writeCr3(@intCast(kcr3)); // сброс TLB
}

/// arch/x86/entry/common.c: do_syscall_64(). Возвращаемое значение уходит в RAX.
export fn syscallDispatch(f: *SysFrame) u64 {
    const t = arch_sched.current() orelse return @bitCast(-@as(i64, syscall.Errno.ESRCH));
    const tm = task_manager orelse return @bitCast(-@as(i64, syscall.Errno.ENOSYS));
    var ctx = syscall.Context{
        .current = t,
        .tasks = tm,
        .cfs = arch_sched.rq(),
        .fs = &demo_fs,
        .ns = t.ns,
    };
    const args = syscall.Args{
        .a1 = f.rdi,
        .a2 = f.rsi,
        .a3 = f.rdx,
        .a4 = f.r10,
        .a5 = f.r8,
        .a6 = f.r9,
    };
    const nr: u32 = @truncate(f.nr);

    // Пока в ring 3 доступен ограниченный ABI; остальные вызовы вернут ENOSYS,
    // а не будут менять ядерные структуры без копирования пользовательских указателей.
    const allowed = switch (nr) {
        syscall.SyscallNo.read,
        syscall.SyscallNo.write,
        syscall.SyscallNo.open,
        syscall.SyscallNo.creat,
        syscall.SyscallNo.mkdir,
        syscall.SyscallNo.unlink,
        syscall.SyscallNo.symlink,
        syscall.SyscallNo.readlink,
        syscall.SyscallNo.close,
        syscall.SyscallNo.lseek,
        syscall.SyscallNo.dup,
        syscall.SyscallNo.dup2,
        syscall.SyscallNo.mmap,
        syscall.SyscallNo.munmap,
        syscall.SyscallNo.getpid,
        syscall.SyscallNo.gettid,
        syscall.SyscallNo.getuid,
        syscall.SyscallNo.geteuid,
        syscall.SyscallNo.getgid,
        syscall.SyscallNo.getegid,
        syscall.SyscallNo.brk,
        syscall.SyscallNo.mprotect,
        syscall.SyscallNo.fork,
        syscall.SyscallNo.rt_sigaction,
        syscall.SyscallNo.rt_sigprocmask,
        syscall.SyscallNo.rt_sigreturn,
        syscall.SyscallNo.kill,
        syscall.SyscallNo.tkill,
        syscall.SyscallNo.tgkill,
        syscall.SyscallNo.exit,
        syscall.SyscallNo.exit_group,
        syscall.SyscallNo.sched_yield,
        => true,
        else => false,
    };
    if (!allowed) return @bitCast(-@as(i64, syscall.Errno.ENOSYS));

    // fork() и rt_sig* работают напрямую с user-space структурами и PML4.
    switch (nr) {
        syscall.SyscallNo.fork => return doFork(t, f, tm),
        syscall.SyscallNo.rt_sigaction => return doRtSigaction(t, f),
        syscall.SyscallNo.rt_sigprocmask => return doRtSigprocmask(t, f),
        syscall.SyscallNo.rt_sigreturn => return doRtSigreturn(f, t) orelse syserr(syscall.Errno.EFAULT),
        else => {},
    }

    // sched_yield() из пользователя должен реально менять стек через ctx_switch.
    if (nr == syscall.SyscallNo.sched_yield) {
        arch_sched.yield(timer.now());
        return 0;
    }

    // user-space указатели: скопировать/проверить до вызова ядерного хендлера.
    var path_buf: [256]u8 = undefined;
    var target_buf: [256]u8 = undefined;
    switch (nr) {
        syscall.SyscallNo.write => {
            if (f.rdi == 1 or f.rdi == 2) ctx.io_data = userSlice(f.rsi, f.rdx) orelse &.{};
        },
        syscall.SyscallNo.read => {
            ctx.io_buf = userSliceMut(f.rsi, f.rdx) orelse &.{};
        },
        syscall.SyscallNo.open,
        syscall.SyscallNo.creat,
        syscall.SyscallNo.mkdir,
        syscall.SyscallNo.unlink,
        => {
            ctx.open_path = userCString(f.rdi, &path_buf) orelse return syserr(syscall.Errno.EFAULT);
        },
        syscall.SyscallNo.symlink => {
            ctx.link_target = userCString(f.rdi, &target_buf) orelse return syserr(syscall.Errno.EFAULT);
            ctx.open_path = userCString(f.rsi, &path_buf) orelse return syserr(syscall.Errno.EFAULT);
        },
        syscall.SyscallNo.readlink => {
            ctx.open_path = userCString(f.rdi, &path_buf) orelse return syserr(syscall.Errno.EFAULT);
            ctx.io_buf = userSliceMut(f.rsi, f.rdx) orelse return syserr(syscall.Errno.EFAULT);
        },
        else => {},
    }

    const rc = ctx.dispatch(nr, args);
    if (nr == syscall.SyscallNo.mprotect and rc >= 0) syncMprotect(f.rdi, f.rsi, f.rdx);
    if (nr == syscall.SyscallNo.munmap and rc >= 0) {
        const start: usize = @intCast(f.rdi);
        const end = std.math.add(usize, start, @as(usize, @intCast(f.rsi))) catch start;
        _ = fault.unmapRange(start, end);
    }
    if (nr == syscall.SyscallNo.exit or nr == syscall.SyscallNo.exit_group) {
        arch_sched.exitCurrent(timer.now());
    }
    // do_signal(): доставить pending-сигнал перед возвратом в ring 3.
    deliverSignal(f, @bitCast(rc));
    return @bitCast(rc);
}

pub fn spawnDemo(tasks: *task.TaskManager, parent: *task.TaskStruct) !*task.TaskStruct {
    return arch_sched.spawn(tasks, parent, "user-demo", enterDemo, 0, timer.now());
}

/// Тот же ELF-демо, но в runqueue конкретного CPU: AP запускает ring3 так же,
/// как BSP, потому что GS/CR3/kernel stack теперь per-CPU.
pub fn spawnDemoOn(tasks: *task.TaskManager, parent: *task.TaskStruct, cpu_index: usize) !*task.TaskStruct {
    return arch_sched.spawnOn(tasks, parent, "user-demo", enterDemo, 0, timer.now(), cpu_index);
}
