// GDT: null, kernel code (0x08), kernel data (0x10), user data (0x18), user code (0x20), TSS (0x28).
// Порядок user data / user code нужен для SYSRET (STAR[63:48] = 0x10).
// SMP: у каждого CPU свой TSS и своя копия GDT с тем же layout селекторов.
const arch = @import("x86_64.zig");
const apic = @import("apic.zig");

const MAX_CPUS = apic.MAX_CPUS;

var tss: [MAX_CPUS][26]u32 align(16) = @splat(@splat(0));

fn makeTable(cpu: usize) [7]u64 {
    var table = [7]u64{
        0,
        0x00AF9A000000FFFF, // kernel code 64-bit
        0x00CF92000000FFFF, // kernel data
        0x00CFF2000000FFFF, // user data (DPL 3)
        0x00AFFA000000FFFF, // user code 64-bit (DPL 3)
        0,
        0,
    };
    tss[cpu][25] = 104 << 16;
    const base: u64 = @intFromPtr(&tss[cpu]);
    const limit: u64 = 103;
    table[5] = (limit & 0xFFFF) | ((base & 0xFFFFFF) << 16) | (@as(u64, 0x89) << 40) | (((limit >> 16) & 0xF) << 48) | (((base >> 24) & 0xFF) << 56);
    table[6] = base >> 32;
    return table;
}

var tables: [MAX_CPUS][7]u64 = undefined;

/// Физический адрес GDT CPU — AP-трамполин грузит его в real mode.
pub fn basePhys(cpu: usize) u64 {
    return @intFromPtr(&tables[cpu]);
}

pub fn descriptor(cpu: usize) arch.DescPtr {
    return .{ .limit = @sizeOf([7]u64) - 1, .base = basePhys(cpu) };
}

/// Стек ядра для прерываний из ring 3 (CPU 0 — compatibility wrapper).
pub fn setRsp0(top: u64) void {
    setRsp0Cpu(0, top);
}

pub fn setRsp0Cpu(cpu: usize, top: u64) void {
    tss[cpu][1] = @truncate(top);
    tss[cpu][2] = @truncate(top >> 32);
}

/// AP: GDT уже загружена трамполином, осталось только выбрать собственный TSS.
pub fn loadTr() void {
    asm volatile (
        \\movw $0x28, %%ax
        \\ltr %%ax
        ::: .{ .rax = true, .memory = true });
}

fn lgdt(cpu: usize) void {
    const p = descriptor(cpu);
    asm volatile ("lgdt (%[p])"
        :
        : [p] "r" (&p),
        : .{ .memory = true });
}

pub fn initSecondary(cpu: usize, rsp0: u64) void {
    setRsp0Cpu(cpu, rsp0);
    tables[cpu] = makeTable(cpu);
}

pub fn init() void {
    for (0..MAX_CPUS) |cpu| tables[cpu] = makeTable(cpu);
    lgdt(0);
    asm volatile (
        \\pushq $0x08
        \\leaq 1f(%%rip), %%rax
        \\pushq %%rax
        \\lretq
        \\1:
        \\movw $0x10, %%ax
        \\movw %%ax, %%ds
        \\movw %%ax, %%es
        \\movw %%ax, %%ss
        \\movw %%ax, %%fs
        \\movw %%ax, %%gs
        ::: .{ .rax = true, .memory = true });
    loadTr();
}
