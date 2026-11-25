//! IDT и 256 заглушек прерываний. Ассемблерный/common-handler шаблон сохранён
//! от проверенной реализации (Win64: rcx + 32 байта shadow space, дубль в rdi);
//! диспетчер и обработчик исключений переписаны под printk ziglinux.
const std = @import("std");
const apic = @import("apic.zig");
const x86 = @import("x86_64.zig");
const pic = @import("pic.zig");
const printk = @import("printk.zig");
const percpu = @import("percpu.zig");

pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

comptime {
    @setEvalBranchQuota(1_000_000);
    const gs_saved_cr3 = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_SAVED_CR3});
    const gs_kcr3 = std.fmt.comptimePrint("%gs:{d}", .{percpu.OFF_KCR3});
    var s: []const u8 = ".text\n.globl isr_stub_0\n";
    for (0..256) |i| {
        s = s ++ ".balign 16\n";
        if (i == 0) s = s ++ "isr_stub_0:\n";
        const has_err = switch (i) {
            8, 10, 11, 12, 13, 14, 17, 21, 30 => true,
            else => false,
        };
        if (!has_err) s = s ++ "pushq $0\n";
        s = s ++ std.fmt.comptimePrint("pushq ${d}\njmp isr_common\n", .{i});
    }
    s = s ++
        ".balign 16\n" ++
        "isr_common:\n" ++
        "pushq %rax\n" ++
        "pushq %rbx\n" ++
        "pushq %rcx\n" ++
        "pushq %rdx\n" ++
        "pushq %rsi\n" ++
        "pushq %rdi\n" ++
        "pushq %rbp\n" ++
        "pushq %r8\n" ++
        "pushq %r9\n" ++
        "pushq %r10\n" ++
        "pushq %r11\n" ++
        "pushq %r12\n" ++
        "pushq %r13\n" ++
        "pushq %r14\n" ++
        "pushq %r15\n" ++
        "cld\n" ++
        // CR3 на входе может быть как ядерным, так и пользовательским:
        // IRQ способен прийти между сменой CR3 и sysretq. Сохраняем его и
        // восстанавливаем на выходе, а ядро всегда видит свой PML4.
        "movq %cr3, %rax\n" ++
        "movq %rax, " ++ gs_saved_cr3 ++ "\n" ++
        "movq " ++ gs_kcr3 ++ ", %rax\n" ++
        "movq %rax, %cr3\n" ++
        "movq %rsp, %rbx\n" ++
        "subq $512, %rsp\n" ++
        "andq $-16, %rsp\n" ++
        "fxsave (%rsp)\n" ++
        "movq %rbx, %rdi\n" ++
        "movq %rbx, %rcx\n" ++
        "subq $32, %rsp\n" ++
        "call interruptDispatch\n" ++
        "addq $32, %rsp\n" ++
        "fxrstor (%rsp)\n" ++
        "movq %rbx, %rsp\n" ++
        "movq " ++ gs_saved_cr3 ++ ", %rax\n" ++
        "movq %rax, %cr3\n" ++
        "popq %r15\n" ++
        "popq %r14\n" ++
        "popq %r13\n" ++
        "popq %r12\n" ++
        "popq %r11\n" ++
        "popq %r10\n" ++
        "popq %r9\n" ++
        "popq %r8\n" ++
        "popq %rbp\n" ++
        "popq %rdi\n" ++
        "popq %rsi\n" ++
        "popq %rdx\n" ++
        "popq %rcx\n" ++
        "popq %rbx\n" ++
        "popq %rax\n" ++
        "addq $16, %rsp\n" ++
        "iretq\n";
    asm (s);
}

extern fn isr_stub_0() void;

const Entry = extern struct {
    off_lo: u16,
    sel: u16,
    ist: u8,
    attr: u8,
    off_mid: u16,
    off_hi: u32,
    zero: u32,
};

var table: [256]Entry = std.mem.zeroes([256]Entry);
var handlers: [256]?*const fn () void = @splat(null);

pub fn setHandler(vector: u8, h: *const fn () void) void {
    handlers[vector] = h;
}

fn setGate(v: usize, addr: usize) void {
    table[v] = .{
        .off_lo = @truncate(addr),
        .sel = 0x08,
        .ist = 0,
        .attr = 0x8E, // present, DPL0, interrupt gate
        .off_mid = @truncate(addr >> 16),
        .off_hi = @truncate(addr >> 32),
        .zero = 0,
    };
}

/// IDTR — per-CPU регистр; AP загружает ту же таблицу после выхода в long mode.
pub fn load() void {
    const p = x86.DescPtr{ .limit = @sizeOf(@TypeOf(table)) - 1, .base = @intFromPtr(&table) };
    asm volatile ("lidt (%[p])"
        :
        : [p] "r" (&p),
        : .{ .memory = true });
}

pub fn init() void {
    const base = @intFromPtr(&isr_stub_0);
    var i: usize = 0;
    while (i < 256) : (i += 1) setGate(i, base + i * 16);
    load();
}

const names = [_][]const u8{
    "Divide Error",         "Debug",                "NMI",                "Breakpoint",
    "Overflow",             "Bound Range Exceeded", "Invalid Opcode",     "Device Not Available",
    "Double Fault",         "Coprocessor Overrun",  "Invalid TSS",        "Segment Not Present",
    "Stack-Segment Fault",  "General Protection",   "Page Fault",         "Reserved",
    "x87 FP Exception",     "Alignment Check",      "Machine Check",      "SIMD FP Exception",
    "Virtualization",       "Control Protection",   "Reserved",           "Reserved",
    "Reserved",             "Reserved",             "Reserved",           "Reserved",
    "Hypervisor Injection", "VMM Communication",    "Security Exception", "Reserved",
};

pub var user_fault_hook: ?*const fn (u64, u64, u64, u64) noreturn = null;
/// Обработать #PF из ring 3 и вернуть true, если ошибка устранена (demand paging).
pub var user_page_fault_hook: ?*const fn (*Frame) bool = null;

fn exception(f: *Frame) void {
    if (f.vector == 14 and (f.cs & 3) != 0) {
        if (user_page_fault_hook) |h| {
            if (h(f)) return;
        }
    }
    x86.cli();
    if ((f.cs & 3) != 0) {
        if (user_fault_hook) |h| h(f.vector, f.rip, f.error_code, x86.readCr2());
    }
    const v: usize = @intCast(f.vector);
    printk.print("\n*** CPU EXCEPTION #{d}: {s} ***\n", .{ v, names[v] });
    printk.print("error={x} rip={x:0>16} cs={x} rflags={x}\n", .{ f.error_code, f.rip, f.cs, f.rflags });
    printk.print("rax={x:0>16} rbx={x:0>16} rcx={x:0>16}\n", .{ f.rax, f.rbx, f.rcx });
    printk.print("rdx={x:0>16} rsi={x:0>16} rdi={x:0>16}\n", .{ f.rdx, f.rsi, f.rdi });
    printk.print("rbp={x:0>16} rsp={x:0>16} r8 ={x:0>16}\n", .{ f.rbp, f.rsp, f.r8 });
    if (v == 14) printk.print("cr2={x:0>16}\n", .{x86.readCr2()});
    printk.write("System halted.\n");
    x86.halt();
}

pub var user_irq_hook: ?*const fn (*Frame) void = null;

fn userIrq(f: *Frame) void {
    if ((f.cs & 3) != 0) {
        if (user_irq_hook) |h| h(f);
    }
}

export fn interruptDispatch(f: *Frame) void {
    const v: usize = @intCast(f.vector);
    if (v < 32) {
        exception(f);
        return;
    }
    if (v < 48) {
        const irq: u8 = @intCast(v - 32);
        if ((irq == 7 or irq == 15) and pic.spurious(irq)) return;
        if (handlers[v]) |h| h();
        pic.eoi(irq);
        userIrq(f);
        return;
    }
    if (v == 0xFF) return; // LAPIC spurious: EOI не нужен
    if (handlers[v]) |h| h();
    apic.eoi();
    userIrq(f);
}
