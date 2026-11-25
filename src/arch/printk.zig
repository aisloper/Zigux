//! arch/printk — минимальный printk поверх serial-драйвера (без libc, без std.io).
//! Драйвер serial.zig остаётся в исходном виде; здесь только форматирование ядра.
//! На SMP вывод сериализуется spinlock (аналог console_lock в Linux 7.3):
//! без него сообщения CPU0 и CPU1 перемешиваются внутри одной строки.
const std = @import("std");
const x86 = @import("x86_64.zig");
const serial = @import("drivers/serial.zig");

var output_lock = std.atomic.Value(u32).init(0);

fn lockAcquire() void {
    while (output_lock.cmpxchgStrong(0, 1, .acquire, .monotonic) != null) {
        while (output_lock.load(.monotonic) != 0) std.atomic.spinLoopHint();
    }
}

fn lockRelease() void {
    output_lock.store(0, .release);
}

pub fn write(bytes: []const u8) void {
    lockAcquire();
    defer lockRelease();
    serial.puts(bytes);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        write("[printk] message truncated\n");
        return;
    };
    write(s);
}

pub fn panic(msg: []const u8) noreturn {
    x86.cli();
    print("\n*** KERNEL PANIC: {s}\n", .{msg});
    while (true) x86.hlt();
}
