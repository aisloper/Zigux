// Классический 8259 PIC: IRQ0..15 -> векторы 0x20..0x2F.
const arch = @import("x86_64.zig");

fn wait() void {
    arch.outb(0x80, 0);
}

pub fn init() void {
    arch.outb(0x20, 0x11);
    wait();
    arch.outb(0xA0, 0x11);
    wait();
    arch.outb(0x21, 0x20);
    wait();
    arch.outb(0xA1, 0x28);
    wait();
    arch.outb(0x21, 4);
    wait();
    arch.outb(0xA1, 2);
    wait();
    arch.outb(0x21, 1);
    wait();
    arch.outb(0xA1, 1);
    wait();
    arch.outb(0x21, 0xFF); // всё замаскировано
    arch.outb(0xA1, 0xFF);
}

pub fn unmask(irq: u8) void {
    const port: u16 = if (irq < 8) 0x21 else 0xA1;
    const bit: u3 = @intCast(irq & 7);
    arch.outb(port, arch.inb(port) & ~(@as(u8, 1) << bit));
    if (irq >= 8) unmask(2); // каскад
}

pub fn eoi(irq: u8) void {
    if (irq >= 8) arch.outb(0xA0, 0x20);
    arch.outb(0x20, 0x20);
}

/// true — прерывание ложное (EOI уже обработан как нужно).
pub fn spurious(irq: u8) bool {
    if (irq == 7) {
        arch.outb(0x20, 0x0B);
        return (arch.inb(0x20) & 0x80) == 0;
    }
    arch.outb(0xA0, 0x0B);
    if ((arch.inb(0xA0) & 0x80) == 0) {
        arch.outb(0x20, 0x20);
        return true;
    }
    return false;
}
