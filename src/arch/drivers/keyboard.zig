//! PS/2 (i8042) драйвер клавиатуры: set-1 scancodes → N_TTY.
//! Логика настройки порта и опроса port 0x60/0x64 взята из zigos (без изменений
//! исходного файла) и Linux drivers/input/keyboard/atkbd.c; декодирование — в
//! host-тестируемом модуле src/input.zig.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const arch = @import("../x86_64.zig");
const input = @import("../../input.zig");
const vt_mod = @import("../../vt.zig");
const device_mod = @import("../../device.zig");

pub const Ps2Info = struct {
    present: bool = false,
    status: u8 = 0,
    cfg_before: u8 = 0,
    cfg_after: u8 = 0,
    ack: bool = false,
};

pub var info: Ps2Info = .{};
pub var kbd = input.Keyboard.init();

pub var device = device_mod.Device.init("i8042", .{ .bus = .serio });
pub var driver = device_mod.Driver.init("atkbd", match, probe, null);

fn match(dev: *const device_mod.Device, _: *const device_mod.Driver) bool {
    return dev.modalias.bus == .serio;
}

fn probe(_: *device_mod.Device) !void {
    info = initPs2();
    if (!info.present) return error.NoDevice;
}

fn waitIn() bool {
    var n: usize = 0;
    while ((arch.inb(0x64) & 2) != 0) : (n += 1) {
        if (n > 100_000) return false;
    }
    return true;
}

fn waitOut() bool {
    var n: usize = 0;
    while ((arch.inb(0x64) & 1) == 0) : (n += 1) {
        if (n > 300_000) return false;
    }
    return true;
}

fn command(cmd: u8) bool {
    if (!waitIn()) return false;
    arch.outb(0x64, cmd);
    return true;
}

fn writeData(value: u8) bool {
    if (!waitIn()) return false;
    arch.outb(0x60, value);
    return true;
}

fn readData() ?u8 {
    if (!waitOut()) return null;
    return arch.inb(0x60);
}

fn flush() void {
    var n: usize = 0;
    while ((arch.inb(0x64) & 1) != 0 and n < 32) : (n += 1) _ = arch.inb(0x60);
}

/// i8042: IRQ1 + set-1 translation, затем «начать сканирование».
pub fn initPs2() Ps2Info {
    var result = Ps2Info{ .status = arch.inb(0x64) };
    if (result.status == 0xFF) return result;
    result.present = true;
    _ = command(0xAD);
    _ = command(0xA7);
    flush();
    if (command(0x20)) {
        if (readData()) |c| result.cfg_before = c;
    }
    const cfg = (result.cfg_before | 0x41) & ~@as(u8, 0x12);
    _ = command(0x60) and writeData(cfg);
    _ = command(0xAE);
    flush();
    if (writeData(0xF4)) {
        if (readData()) |r| result.ack = (r == 0xFA);
    }
    if (command(0x20)) {
        if (readData()) |c| result.cfg_after = c;
    }
    return result;
}

/// Общий путь для PS/2 и HID: события из input.Keyboard → активный VT.
pub fn drain(sw: *vt_mod.Switcher) void {
    while (kbd.next()) |code| sw.feedKey(&kbd, code);
}

/// Опрос i8042; HID-драйвер кормит тот же kbd через input.Keyboard USB API.
pub fn poll(sw: *vt_mod.Switcher) void {
    if (info.present) {
        arch.cli();
        var n: usize = 0;
        while (n < 16) : (n += 1) {
            const status = arch.inb(0x64);
            if (status == 0xFF or (status & 1) == 0) break;
            const scancode = arch.inb(0x60);
            if ((status & 0x20) != 0) continue; // мышь
            kbd.feed(scancode);
        }
        arch.sti();
    }
    drain(sw);
}
