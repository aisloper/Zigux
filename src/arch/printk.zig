//! arch/printk — минимальный printk поверх serial-драйвера (без libc, без std.io).
//! Драйвер serial.zig остаётся в исходном виде; здесь только форматирование ядра.
const std = @import("std");
const x86 = @import("x86_64.zig");
const serial = @import("drivers/serial.zig");

pub fn write(bytes: []const u8) void {
    serial.puts(bytes);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, fmt, args) catch {
        serial.puts("[printk] message truncated\n");
        return;
    };
    serial.puts(s);
}

pub fn panic(msg: []const u8) noreturn {
    x86.cli();
    print("\n*** KERNEL PANIC: {s}\n", .{msg});
    while (true) x86.hlt();
}
