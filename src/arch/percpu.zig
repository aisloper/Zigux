//! Per-CPU данные для syscall/IDT — порт arch/x86/include/asm/percpu.h и
//! MSR_GS_BASE из arch/x86/kernel/cpu/common.c. GS всегда указывает на активный
//! CPU, поэтому прерывания и SYSCALL выбирают CR3/стек своей задачи без глобальных
//! переменных; AP получит собственный слот так же, как BSP.
//!
//! Упрощение среза: пользовательский код не использует GS, поэтому и
//! MSR_GS_BASE, и MSR_KERNEL_GS_BASE указывают на один и тот же слот. Полный
//! Linux использует swapgs и отдельный TLS в ring 3; это будет добавлено с
//! поддержкой fs/gs-base syscall'ов.
const std = @import("std");
const x86 = @import("x86_64.zig");
const apic = @import("apic.zig");

/// Поля, к которым обращается ассемблер через %gs:<offset>. Порядок фиксирован.
pub const OFF_KCR3: u16 = 0;
pub const OFF_UCR3: u16 = 8;
pub const OFF_KSTACK: u16 = 16;
pub const OFF_URS: u16 = 24;
pub const OFF_SCRATCH: u16 = 32;
pub const OFF_USER_PML4: u16 = 40;
pub const OFF_USER_ENTRY: u16 = 48;
pub const OFF_USER_RSP: u16 = 56;
pub const OFF_FORK_FRAME: u16 = 64;
/// IDT сохраняет здесь CR3, который был в момент прерывания. Нельзя определять
/// его по CS: IRQ может прийти между сменой CR3/RSP и sysretq, когда CS ещё 0.
pub const OFF_SAVED_CR3: u16 = 72;

pub const SysState = extern struct {
    kcr3: u64,
    ucr3: u64,
    kstack: u64,
    urs: u64,
    scratch: u64,
    user_pml4: u64,
    user_entry: u64,
    user_rsp: u64,
    fork_frame: u64,
    saved_cr3: u64,
};

comptime {
    if (@offsetOf(SysState, "kcr3") != OFF_KCR3) @compileError("bad kcr3 offset");
    if (@offsetOf(SysState, "ucr3") != OFF_UCR3) @compileError("bad ucr3 offset");
    if (@offsetOf(SysState, "kstack") != OFF_KSTACK) @compileError("bad kstack offset");
    if (@offsetOf(SysState, "urs") != OFF_URS) @compileError("bad urs offset");
    if (@offsetOf(SysState, "scratch") != OFF_SCRATCH) @compileError("bad scratch offset");
    if (@offsetOf(SysState, "user_pml4") != OFF_USER_PML4) @compileError("bad user_pml4 offset");
    if (@offsetOf(SysState, "user_entry") != OFF_USER_ENTRY) @compileError("bad user_entry offset");
    if (@offsetOf(SysState, "user_rsp") != OFF_USER_RSP) @compileError("bad user_rsp offset");
    if (@offsetOf(SysState, "fork_frame") != OFF_FORK_FRAME) @compileError("bad fork_frame offset");
    if (@offsetOf(SysState, "saved_cr3") != OFF_SAVED_CR3) @compileError("bad saved_cr3 offset");
}

pub var states: [apic.MAX_CPUS]SysState = std.mem.zeroes([apic.MAX_CPUS]SysState);

pub fn state(cpu_index: usize) *SysState {
    return &states[cpu_index];
}

pub fn index() usize {
    return apic.index();
}

pub fn current() *SysState {
    return state(index());
}

const MSR_GS_BASE: u32 = 0xC0000101;
const MSR_KERNEL_GS_BASE: u32 = 0xC0000102;

/// GS base — привилегированный MSR; смещение %gs:off работает и в ring 0,
/// и в ring 3 без swapgs (пользовательский код GS не использует).
pub fn load(cpu_index: usize) void {
    const base = @intFromPtr(state(cpu_index));
    x86.wrmsr(MSR_GS_BASE, base);
    x86.wrmsr(MSR_KERNEL_GS_BASE, base);
}

pub fn loadCurrent() void {
    load(apic.index());
}

pub fn reset(cpu_index: usize) void {
    states[cpu_index] = std.mem.zeroes(SysState);
}

test "per-CPU syscall slots have stable %gs offsets" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(SysState));
    try std.testing.expectEqual(@as(usize, 0), OFF_KCR3);
    try std.testing.expectEqual(@as(usize, 32), OFF_SCRATCH);
    try std.testing.expectEqual(@as(usize, 64), OFF_FORK_FRAME);
    try std.testing.expectEqual(@as(usize, 72), OFF_SAVED_CR3);
    var a = state(0);
    var b = state(1);
    a.kcr3 = 0x1111;
    b.kcr3 = 0x2222;
    try std.testing.expectEqual(@as(u64, 0x1111), a.kcr3);
    try std.testing.expectEqual(@as(u64, 0x2222), b.kcr3);
    reset(0);
    reset(1);
}
