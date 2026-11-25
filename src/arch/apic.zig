//! Local APIC (xAPIC/x2APIC) и периодический таймер. Калибровка: PIT канал 2,
//! запасной путь — частота кварца из CPUID.15H. Порядок регистров как в Linux
//! arch/x86/kernel/apic/apic.c + arch/x86/kernel/tsc.c.
const x86 = @import("x86_64.zig");
const paging = @import("paging.zig");

pub const VECTOR_TIMER: u8 = 0x40;
/// Максимум CPU, для которых выделяются per-CPU runqueue/TSS (как NR_CPUS в Linux).
pub const MAX_CPUS: usize = 8;

const REG_TPR = 0x80;
const REG_EOI = 0xB0;
const REG_SVR = 0xF0;
const REG_LVT_TIMER = 0x320;
const REG_TIMER_INIT = 0x380;
const REG_TIMER_CUR = 0x390;
const REG_TIMER_DIV = 0x3E0;

var x2: bool = false;
var base: usize = 0;
pub var active: bool = false;
pub var calib: []const u8 = "none";
/// Калиброванный BSP-счётчик periodic timer; AP-ы не трогают PIT channel 2.
var timer_count: u32 = 0;
/// Таблица APIC ID из MADT: индекс arrays = индеж CPU в per-CPU State.
pub var ids: [MAX_CPUS]u32 = @splat(0);
pub var nr_cpus: usize = 1;

fn read(reg: u32) u32 {
    if (x2) return @truncate(x86.rdmsr(0x800 + (reg >> 4)));
    const p: *volatile u32 = @ptrFromInt(base + reg);
    return p.*;
}

fn write(reg: u32, v: u64) void {
    if (x2) {
        x86.wrmsr(0x800 + (reg >> 4), v);
        return;
    }
    const p: *volatile u32 = @ptrFromInt(base + reg);
    p.* = @truncate(v);
}

pub fn id() u32 {
    if (x2) return @truncate(x86.rdmsr(0x802));
    return read(0x20) >> 24;
}

/// smp.detect() заполняет ids[] из MADT; до этого BSP — единственный CPU.
pub fn index() usize {
    const me = id();
    var i: usize = 0;
    while (i < nr_cpus) : (i += 1) {
        if (ids[i] == me) return i;
    }
    if (me < MAX_CPUS) return @intCast(me);
    return 0;
}

pub fn eoi() void {
    if (active) write(REG_EOI, 0);
}

/// Записать ICR для физического destination APIC ID (xAPIC: ID << 24, x2APIC: ID).
fn writeIcr(dest: u32, lo: u32) void {
    const hi: u32 = if (x2) dest else dest << 24;
    if (x2) {
        write(0x300, lo | (@as(u64, hi) << 32));
    } else {
        write(0x310, hi);
        write(0x300, lo);
    }
}

pub fn sendInit(dest: u32) void {
    writeIcr(dest, 0x4500); // INIT, assert level
    x86.pause();
    writeIcr(dest, 0x4000); // deassert
}

pub fn sendSipi(dest: u32, vector: u8) void {
    writeIcr(dest, 0x4600 | @as(u32, vector)); // SIPI, edge
}

/// AP поднимает свой локальный таймер уже после калибровки на BSP.
pub fn initSecondary() bool {
    if (timer_count == 0) return false;
    write(REG_TPR, 0);
    write(REG_SVR, 0x100 | 0xFF);
    write(REG_TIMER_DIV, 0x3);
    write(REG_LVT_TIMER, @as(u32, VECTOR_TIMER) | (1 << 17));
    write(REG_TIMER_INIT, timer_count);
    return true;
}

pub fn init(hz: u32) bool {
    if ((x86.cpuid(1, 0).edx & (1 << 9)) == 0) return false;

    var msr = x86.rdmsr(0x1B);
    if ((msr & (1 << 11)) == 0) {
        msr |= 1 << 11;
        x86.wrmsr(0x1B, msr);
    }
    x2 = (msr & (1 << 10)) != 0;
    base = @intCast(msr & 0x000F_FFFF_FFFF_F000);
    if (!x2) paging.mapMmio(base, 4096);

    write(REG_TPR, 0);
    write(REG_SVR, 0x100 | 0xFF); // enable + spurious vector 0xFF

    // 10 мс по PIT channel 2 (1193182 Гц / 11932 ≈ 10 мс).
    write(REG_TIMER_DIV, 0x3); // делитель 16
    write(REG_LVT_TIMER, 0x10000); // masked
    x86.outb(0x61, (x86.inb(0x61) & 0xFD) | 0x01);
    x86.outb(0x43, 0xB0);
    x86.outb(0x42, 0x9C); // 11932 = 0x2E9C
    x86.outb(0x42, 0x2E);
    write(REG_TIMER_INIT, 0xFFFFFFFF);
    var guard: u32 = 0;
    while ((x86.inb(0x61) & 0x20) == 0 and guard < 2_000_000) : (guard += 1) {}
    const cur = read(REG_TIMER_CUR);
    write(REG_TIMER_INIT, 0);

    var per_10ms: u64 = 0;
    if (guard < 2_000_000 and cur != 0xFFFFFFFF) {
        per_10ms = 0xFFFFFFFF - cur;
        calib = "PIT channel 2";
    }
    if (per_10ms < 1000) {
        const c15 = x86.cpuid(0x15, 0);
        if (c15.ecx != 0) {
            per_10ms = @as(u64, c15.ecx) / 16 / 100;
            calib = "CPUID 15h (crystal)";
        }
    }
    if (per_10ms < 1000) return false;

    const count: u64 = per_10ms * 100 / hz;
    if (count == 0 or count > 0xFFFFFFFF) return false;

    write(REG_TIMER_DIV, 0x3);
    write(REG_LVT_TIMER, @as(u32, VECTOR_TIMER) | (1 << 17)); // periodic
    write(REG_TIMER_INIT, @intCast(count));
    timer_count = @intCast(count);
    ids[0] = id();
    nr_cpus = 1;
    active = true;
    return true;
}
