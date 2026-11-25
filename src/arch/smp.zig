//! SMP/AP startup — порт arch/x86/kernel/smpboot.c + acpi/madt.c на Zig.
//! BSP читает MADT, копирует real-mode трамполин в низкую память и будит AP
//! через INIT/SIPI. AP выходит в long mode на ядерном PML4, грузит свой GDT/
//! IDT/TSS и попадает в уже подготовленную per-CPU EEVDF runqueue.
const std = @import("std");
const acpi = @import("acpi.zig");
const boot = @import("boot.zig");
const x86 = @import("x86_64.zig");
const apic = @import("apic.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const paging = @import("paging.zig");
const printk = @import("printk.zig");
const arch_sched = @import("sched.zig");
const percpu = @import("percpu.zig");
const user = @import("user.zig");

/// Физическая страница трамполина: адрес должен быть < 1 МиБ и выровнен на 4 КиБ.
pub const TRAMPOLINE_PHYS: usize = 0x7000;
const SHARED_PHYS: usize = 0x7200;
const SIPI_VECTOR: u8 = @intCast(TRAMPOLINE_PHYS >> 12);

/// Поля читаются трамполином по фиксированным физическим адресам.
const ApShared = packed struct {
    gdt_limit: u16,
    gdt_base: u32,
    pad: u16,
    cr3: u64,
    long_entry: u64,
    stack_top: u64,
    cr4: u64, // BSP CR4: PAE + OSXSAVE + XSAVE, иначе AP ловит #UD на AVX
};

var ap_stacks: [apic.MAX_CPUS]u64 = @splat(0);

// Трамполин не имеет relocations: все адреса — константы либо поля ApShared.
// Far jmp patchится BSP: offset 32-bit + selector 0x08 (длинный режим).
comptime {
    asm (
        \\.text
        \\.code16
        \\.globl ap_trampoline_start
        \\ap_trampoline_start:
        \\cli
        \\cld
        \\xorw %ax, %ax
        \\movw %ax, %ds
        \\movw %ax, %es
        \\movw %ax, %ss
        \\movw $0x6f00, %sp
        \\lgdtl 0x7200
        \\movl 0x7220, %eax
        \\movl %eax, %cr4
        \\movl $0xc0000080, %ecx
        \\rdmsr
        \\orl $0x100, %eax
        \\wrmsr
        \\movl 0x7208, %eax
        \\movl %eax, %cr3
        \\movl %cr0, %eax
        \\orl $0x80000001, %eax
        \\movl %eax, %cr0
        \\.balign 4, 0x90
        \\.byte 0x66, 0xea
        \\.globl ap_far_jump_offset
        \\ap_far_jump_offset:
        \\.long 0
        \\.word 0x0008
        \\.code64
        \\.globl ap_trampoline_long
        \\ap_trampoline_long:
        \\movw $0x10, %ax
        \\movw %ax, %ds
        \\movw %ax, %es
        \\movw %ax, %ss
        \\movw %ax, %fs
        \\movw %ax, %gs
        \\movabsq $0x7218, %rax
        \\movq (%rax), %rsp
        \\movabsq $0x7210, %rax
        \\movq (%rax), %rax
        \\xorl %ecx, %ecx
        \\callq *%rax
        \\1:
        \\hlt
        \\jmp 1b
        \\.balign 512, 0x90
        \\.globl ap_trampoline_end
        \\ap_trampoline_end:
        \\.code64
    );
}

extern fn ap_trampoline_start() void;
extern fn ap_trampoline_end() void;
extern fn ap_trampoline_long() void;
extern var ap_far_jump_offset: u32;

inline fn rd8(addr: usize) u8 {
    return @as(*const volatile u8, @ptrFromInt(addr)).*;
}

fn rd16(addr: usize) u16 {
    return @as(u16, rd8(addr)) | (@as(u16, rd8(addr + 1)) << 8);
}

fn rd32(addr: usize) u32 {
    return @as(u32, rd16(addr)) | (@as(u32, rd16(addr + 2)) << 16);
}

fn rd64(addr: usize) u64 {
    return @as(u64, rd32(addr)) | (@as(u64, rd32(addr + 4)) << 32);
}

fn checksum(addr: usize, len: u32) bool {
    var sum: u8 = 0;
    var i: u32 = 0;
    while (i < len) : (i += 1) sum +%= rd8(addr + i);
    return sum == 0;
}

fn isSig(addr: usize, comptime sig: *const [4:0]u8) bool {
    if (addr == 0) return false;
    inline for (0..4) |i| {
        if (rd8(addr + i) != sig[i]) return false;
    }
    return true;
}

fn rootTable(rsdp: usize) usize {
    if (rsdp == 0) return 0;
    const p: [*]const u8 = @ptrFromInt(rsdp);
    if (!std.mem.eql(u8, p[0..8], "RSD PTR ")) return 0;
    const len = rd8(rsdp + 20);
    if (len >= 36 and !checksum(rsdp, len)) return 0;

    const xsdt = rd64(rsdp + 24);
    if (isSig(xsdt, "XSDT") and checksum(xsdt, rd32(xsdt + 4))) return xsdt;
    const rsdt_addr = rd32(rsdp + 16);
    if (isSig(rsdt_addr, "RSDT") and checksum(rsdt_addr, rd32(rsdt_addr + 4))) return rsdt_addr;
    return 0;
}

fn findMadt() usize {
    const root = rootTable(boot.info.rsdp);
    if (!isSig(root, "RSDT") and !isSig(root, "XSDT")) return 0;
    const wide = isSig(root, "XSDT");
    const len = rd32(root + 4);
    const step: usize = if (wide) 8 else 4;
    var off: usize = 36;
    while (off + step <= len) : (off += step) {
        const addr: usize = @intCast(if (wide) rd64(root + off) else rd32(root + off));
        if (isSig(addr, "APIC")) {
            const l = rd32(addr + 4);
            if (l >= 44 and checksum(addr, l)) return addr;
        }
    }
    return 0;
}

/// linux: acpi_parse_madt_lapic_entries() — только процессорные LAPIC-записи.
pub fn detect() void {
    const bsp = apic.id();
    apic.ids[0] = bsp;
    apic.nr_cpus = 1;
    const madt = findMadt();
    if (madt == 0) {
        printk.print("ziglinux: SMP: MADT absent, 1 CPU (lapic {d})\n", .{bsp});
        return;
    }
    const len = rd32(madt + 4);
    const bytes: [*]const u8 = @ptrFromInt(madt);
    apic.nr_cpus = acpi.parseLapicIds(bytes[0..len], bsp, &apic.ids);
    printk.print("ziglinux: SMP: {d} CPUs from MADT (bsp lapic {d})\n", .{ apic.nr_cpus, bsp });
}

/// Стек idle-задачи CPU и его собственный TSS/GDT готовятся до SIPI.
pub fn prepareCpu(cpu_index: usize, stack_top: u64) void {
    ap_stacks[cpu_index] = stack_top;
    arch_sched.state(cpu_index).stack_top = stack_top;
    gdt.initSecondary(cpu_index, stack_top);
}

fn copyTrampoline() void {
    const start = @intFromPtr(&ap_trampoline_start);
    const len = @intFromPtr(&ap_trampoline_end) - start;
    if (len > SHARED_PHYS - TRAMPOLINE_PHYS) printk.panic("AP trampoline too large");

    const src: [*]const u8 = @ptrFromInt(start);
    const dst: [*]volatile u8 = @ptrFromInt(TRAMPOLINE_PHYS);
    for (0..len) |i| dst[i] = src[i];

    //patched far jump: physical address of the 64-bit part of the trampoline
    const jmp_off = @intFromPtr(&ap_far_jump_offset) - start;
    const long_off = @intFromPtr(&ap_trampoline_long) - start;
    const target: u32 = @intCast(TRAMPOLINE_PHYS + long_off);
    const patch: [*]volatile u8 = @ptrFromInt(TRAMPOLINE_PHYS + jmp_off);
    patch[0] = @truncate(target);
    patch[1] = @truncate(target >> 8);
    patch[2] = @truncate(target >> 16);
    patch[3] = @truncate(target >> 24);
}

fn delay(loops: usize) void {
    var i: usize = 0;
    while (i < loops) : (i += 1) {
        _ = x86.inb(0x80);
        x86.pause();
    }
}

fn isOnline(cpu_index: usize) bool {
    return @as(*volatile bool, &arch_sched.state(cpu_index).online).*;
}

fn startCpu(cpu_index: usize) void {
    const id = apic.ids[cpu_index];
    const shared: *volatile ApShared = @ptrFromInt(SHARED_PHYS);
    shared.gdt_limit = @sizeOf([7]u64) - 1;
    shared.gdt_base = @truncate(gdt.basePhys(cpu_index));
    shared.pad = 0;
    shared.cr3 = paging.kernelCr3();
    shared.long_entry = @intFromPtr(&apEntry);
    shared.stack_top = ap_stacks[cpu_index];
    shared.cr4 = x86.readCr4();

    @as(*volatile bool, &arch_sched.state(cpu_index).online).* = false;
    delay(10_000);
    apic.sendInit(id);
    delay(10_000);
    apic.sendSipi(id, SIPI_VECTOR);
    delay(2_000);
    if (!isOnline(cpu_index)) {
        apic.sendSipi(id, SIPI_VECTOR);
        var tries: usize = 0;
        while (!isOnline(cpu_index) and tries < 1_000) : (tries += 1) delay(1_000);
    }
    if (!isOnline(cpu_index)) {
        printk.print("ziglinux: CPU{d} (lapic {d}) did not come online\n", .{ cpu_index, id });
    }
}

/// Первые инструкции AP после SIPI: long mode уже включён трамполином.
fn apEntry() void {
    const ci = apic.index();
    // AP должен видеть свой слот GS до включения прерываний и первого SYSCALL.
    percpu.reset(ci);
    percpu.state(ci).kcr3 = paging.kernelCr3();
    percpu.load(ci);
    user.initSyscallMsrs();
    _ = apic.initSecondary();
    gdt.loadTr();
    idt.load();
    @as(*volatile bool, &arch_sched.state(ci).online).* = true;
    printk.print("ziglinux: CPU{d} online (lapic {d})\n", .{ ci, apic.id() });
    x86.sti();
    arch_sched.runCurrent();
}

pub fn startAll() void {
    if (!apic.active or apic.nr_cpus < 2) return;
    copyTrampoline();
    var cpu_index: usize = 1;
    while (cpu_index < apic.nr_cpus) : (cpu_index += 1) startCpu(cpu_index);
}
