//! Точка сопряжения line discipline ziglinux с драйвером serial из zigos.
//! Драйвер не модифицируется: ядро только registered TtyOps.write и передаёт
//! принятые драйвером байты в tty.receive().
const tty_mod = @import("../tty.zig");
const serial = @import("drivers/serial.zig");

pub fn write(_: ?*anyopaque, bytes: []const u8) void {
    serial.puts(bytes);
}

pub fn connect(t: *tty_mod.Tty) void {
    t.ops.write = write;
}

/// Опрос UART: байт → N_TTY line discipline (ICRNL/ISIG/canonical/ECHO).
pub fn poll(t: *tty_mod.Tty) void {
    while (serial.read()) |c| {
        var one = [1]u8{c};
        t.receive(&one);
    }
}
