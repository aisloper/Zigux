// PIT (канал 0) — резервный источник тиков, если LAPIC недоступен.
const arch = @import("x86_64.zig");
const pic = @import("pic.zig");

pub fn init(hz: u32) void {
    const div: u16 = @intCast(1193182 / hz);
    arch.outb(0x43, 0x36);
    arch.outb(0x40, @truncate(div));
    arch.outb(0x40, @truncate(div >> 8));
    pic.unmask(0);
}
