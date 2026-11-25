//! Архитектурный адаптер планировщика: ctx_switch между task_struct порта,
//! выбор следующей задачи через EEVDF (CfsRq.schedule). Ядро Linux использует
//! thread.sp в task_struct и __switch_to(); здесь та же точка переключения.
//! SMP: у каждого CPU своя CfsRq/текущая задача, индекс берётся из локального APIC.
const task = @import("../task.zig");
const sched = @import("../sched.zig");
const timer = @import("timer.zig");
const pmm = @import("pmm.zig");
const x86 = @import("x86_64.zig");
const apic = @import("apic.zig");
const percpu = @import("percpu.zig");

extern fn ctx_switch(old_sp: *usize, new_sp: usize) void;

// Win64 ABI: rcx = &old_sp, rdx = new_sp. Сохраняем callee-saved GPR и xmm6-15.
comptime {
    asm (
        \\.text
        \\.globl ctx_switch
        \\ctx_switch:
        \\pushq %rbp
        \\pushq %rbx
        \\pushq %rdi
        \\pushq %rsi
        \\pushq %r12
        \\pushq %r13
        \\pushq %r14
        \\pushq %r15
        \\subq $160, %rsp
        \\movups %xmm6, 0(%rsp)
        \\movups %xmm7, 16(%rsp)
        \\movups %xmm8, 32(%rsp)
        \\movups %xmm9, 48(%rsp)
        \\movups %xmm10, 64(%rsp)
        \\movups %xmm11, 80(%rsp)
        \\movups %xmm12, 96(%rsp)
        \\movups %xmm13, 112(%rsp)
        \\movups %xmm14, 128(%rsp)
        \\movups %xmm15, 144(%rsp)
        \\movq %rsp, (%rcx)
        \\movq %rdx, %rsp
        \\movups 0(%rsp), %xmm6
        \\movups 16(%rsp), %xmm7
        \\movups 32(%rsp), %xmm8
        \\movups 48(%rsp), %xmm9
        \\movups 64(%rsp), %xmm10
        \\movups 80(%rsp), %xmm11
        \\movups 96(%rsp), %xmm12
        \\movups 112(%rsp), %xmm13
        \\movups 128(%rsp), %xmm14
        \\movups 144(%rsp), %xmm15
        \\addq $160, %rsp
        \\popq %r15
        \\popq %r14
        \\popq %r13
        \\popq %r12
        \\popq %rsi
        \\popq %rdi
        \\popq %rbx
        \\popq %rbp
        \\ret
    );
}

pub const CpuState = struct {
    current: ?*task.TaskStruct = null,
    rq: ?*sched.CfsRq = null,
    idle: ?*task.TaskStruct = null,
    stack_top: u64 = 0,
    online: bool = false,
};

pub var cpus: [apic.MAX_CPUS]CpuState = undefined;
pub var switch_hook: ?*const fn () void = null;

pub const STACK_PAGES: usize = 8;

pub fn state(cpu_index: usize) *CpuState {
    return &cpus[cpu_index];
}

pub fn current() ?*task.TaskStruct {
    return cpus[apic.index()].current;
}

pub fn rq() ?*sched.CfsRq {
    return cpus[apic.index()].rq;
}

pub fn setCurrent(cpu_index: usize, t: *task.TaskStruct) void {
    cpus[cpu_index].current = t;
}

pub fn init(t: *task.TaskStruct, cfs: *sched.CfsRq) void {
    for (0..apic.MAX_CPUS) |i| cpus[i] = .{};
    const ci = apic.index();
    cpus[ci].current = t;
    cpus[ci].rq = cfs;
    cpus[ci].online = true;
    t.arch.sp = 0;
    t.state = task.TaskStateFlags.RUNNING;
    cfs.curr = &t.se;
    cfs.setNextEntity(&t.se, timer.now());
}

fn trampoline() noreturn {
    if (switch_hook) |h| h();
    const t = current() orelse x86.halt();
    if (t.arch.entry) |e| e();
    exit();
}

/// Подготовить kernel stack + возврат в trampoline() для новой задачи.
/// Используется spawn() и ring3 fork(), которому нужен отдельный entry.
pub fn setupStack(t: *task.TaskStruct, stack: usize, pages: usize, entry: *const fn () void) void {
    t.arch.stack = stack;
    t.arch.pages = pages;
    t.arch.entry = entry;
    makeFrame(t, stack + pages * pmm.PAGE);
}

fn makeFrame(t: *task.TaskStruct, top: usize) void {
    // [xmm6-15: 160][r15..rbp: 64][return -> trampoline: 8][0]
    const sp = top - 240;
    const frame: [*]usize = @ptrFromInt(sp);
    @memset(frame[0 .. 240 / 8], 0);
    frame[(240 - 16) / 8] = @intFromPtr(&trampoline);
    t.arch.sp = sp;
}

/// fork + EEVDF enqueue + подготовка стека ядерного потока на заданном CPU.
pub fn spawnOn(tasks: *task.TaskManager, parent: *task.TaskStruct, name: []const u8, entry: *const fn () void, nice: i8, now: u64, cpu_index: usize) !*task.TaskStruct {
    const stack = pmm.allocContiguous(STACK_PAGES) orelse return error.OutOfMemory;
    const t = tasks.fork(parent, 0) catch |e| {
        pmm.free(stack, STACK_PAGES);
        return e;
    };
    t.setComm(name);
    t.on_cpu = @intCast(cpu_index);
    setupStack(t, stack, STACK_PAGES, entry);
    t.se.setLoadWeight(nice);
    const cfs = cpus[cpu_index].rq orelse return t;
    cfs.enqueueEntity(&t.se, now, true);
    return t;
}

pub fn spawn(tasks: *task.TaskManager, parent: *task.TaskStruct, name: []const u8, entry: *const fn () void, nice: i8, now: u64) !*task.TaskStruct {
    return spawnOn(tasks, parent, name, entry, nice, now, apic.index());
}

/// AP выходит из трамполина на отдельный boot stack и сразу запускает свою
/// idle-задачу. Старт через ctx_switch не нужен: idle уже переназначен в
/// CpuState.current, а первая задача из runqueue получит управление через
/// arch_sched.yield() и tt-переключение стека. GS/CR3/ring3-состояние теперь
/// per-CPU, поэтому AP может запускать те же ring3-задачи, что и BSP.
pub fn runCurrent() noreturn {
    const ci = apic.index();
    const t = cpus[ci].current orelse x86.halt();
    t.state = task.TaskStateFlags.RUNNING;
    if (t.arch.entry) |e| e();
    exit();
}

/// __schedule(): put_prev/pick_next/set_next + ctx_switch с сохранением IF.
/// Время берётся внутри critical section: тик-хук из IDT не должен успеть
/// сдвинуть exec_start между чтением метки и вызовом schedule().
pub fn yield(now: u64) void {
    _ = now;
    const flags = x86.rflags(); // IF принадлежит задаче
    x86.cli();
    defer {
        if ((flags & 0x200) != 0) x86.sti() else x86.cli();
    }

    const ci = apic.index();
    const c = &cpus[ci];
    const cfs = c.rq orelse return;
    const next_se = cfs.schedule(timer.now()) orelse return;
    const next: *task.TaskStruct = @fieldParentPtr("se", next_se);
    const prev = c.current orelse {
        c.current = next;
        return;
    };
    if (next == prev) return;
    next.state = task.TaskStateFlags.RUNNING;
    next.on_cpu = @intCast(ci);
    c.current = next;
    ctx_switch(&prev.arch.sp, next.arch.sp);
    if (switch_hook) |h| h();
}

pub fn onTick(now: u64) void {
    if (rq()) |cfs| _ = cfs.entityTick(now);
}

pub fn exit() noreturn {
    if (current()) |t| t.state |= task.TaskStateFlags.DEAD;
    while (true) {
        x86.sti();
        yield(timer.now());
        x86.hlt();
    }
}

/// do_exit() для задачи, ушедшей в ring 3: снимаем её с EEVDF-очереди
/// (иначе планировщик вернётся в уже мёртвый контекст), затем уступаем CPU.
pub fn exitCurrent(now: u64) noreturn {
    const ci = apic.index();
    const c = &cpus[ci];
    if (c.rq) |cfs| {
        if (c.current) |t| {
            if (t.se.on_rq) cfs.dequeueEntity(&t.se, now);
            if (cfs.curr == &t.se) cfs.curr = null;
        }
    }
    while (true) {
        yield(timer.now());
        x86.sti();
        x86.hlt();
    }
}
