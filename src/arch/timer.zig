//! arch-таймер: LAPIC (периодический, калибровка по PIT) или PIT через PIC.
//! Тик продвигает счётчик ядра и зовёт хук (jiffies/timer wheel из port).
const apic = @import("apic.zig");
const idt = @import("idt.zig");
const pit = @import("pit.zig");
const port_sched = @import("../sched.zig");

pub const HZ: u32 = 250; // совпадает с timer.HZ в порту Linux 7.3
pub const Source = enum { none, pit, lapic };
pub var source: Source = .none;
var ticks: u64 = 0;

/// Хук ядра: kmain ставит сюда k.timers.tick().
pub var on_tick: ?*const fn () void = null;

fn tick() void {
    ticks +%= 1;
    if (on_tick) |h| h();
}

/// EEVDF считает vruntime в наносекундах — как и host-порт (sched.TICK_NSEC).
pub fn now() u64 {
    const p: *const volatile u64 = &ticks;
    return p.* *% port_sched.TICK_NSEC;
}

pub fn init() void {
    idt.setHandler(apic.VECTOR_TIMER, tick);
    idt.setHandler(0x20, tick);
    if (apic.init(HZ)) {
        source = .lapic;
    } else {
        pit.init(HZ);
        source = .pit;
    }
}
