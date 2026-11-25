//! HID boot-protocol decoder: 8-байтовый report → input.Keyboard.
//! Алгоритм портирован из drivers/hid/usbhid/hid-core.c и zigos/src/hid.zig
//! (исходный файл zigos не изменялся). Проверяется host-тестами без железа.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const input = @import("input.zig");

pub const REPEAT_DELAY_NS: u64 = 500 * 1_000_000;
pub const REPEAT_RATE_NS: u64 = 33 * 1_000_000;

/// Индекс = usage ID - 4 (0x04..0x38), US-раскладка без Shift.
const lower = "abcdefghijklmnopqrstuvwxyz1234567890\n\x1b\x08\t -=[]\\#;'`,./";
/// Keypad: usage 0x54..0x63.
const keypad = "/*-+\n1234567890.";

pub const Decoder = struct {
    prev: [8]u8 = .{ 0, 0, 0, 0, 0, 0, 0, 0 },
    held: u8 = 0,
    next_rep: u64 = 0,
    reports: u64 = 0,
    repeats: u64 = 0,

    pub fn init() Decoder {
        return .{};
    }

    fn wasDown(self: *const Decoder, k: u8) bool {
        for (self.prev[2..8]) |p| {
            if (p == k) return true;
        }
        return false;
    }

    fn stillDown(_: *const Decoder, rep: *const [8]u8, k: u8) bool {
        for (rep[2..8]) |p| {
            if (p == k) return true;
        }
        return false;
    }

    fn repeatable(k: u8) bool {
        return (k >= 0x04 and k <= 0x38) or
            (k >= 0x49 and k <= 0x52) or
            (k >= 0x54 and k <= 0x63);
    }

    fn emit(k: u8, kbd: *input.Keyboard) void {
        switch (k) {
            0x49 => kbd.usbSpecial(input.Key.insert),
            0x4A => kbd.usbSpecial(input.Key.home),
            0x4B => kbd.usbSpecial(input.Key.pgup),
            0x4C => kbd.usbSpecial(input.Key.delete),
            0x4D => kbd.usbSpecial(input.Key.end),
            0x4E => kbd.usbSpecial(input.Key.pgdn),
            0x4F => kbd.usbSpecial(input.Key.right),
            0x50 => kbd.usbSpecial(input.Key.left),
            0x51 => kbd.usbSpecial(input.Key.down),
            0x52 => kbd.usbSpecial(input.Key.up),
            0x3A...0x45 => kbd.usbSpecial(input.Key.f1 + (k - 0x3A)),
            0x04...0x38 => kbd.usbChar(lower[k - 4]),
            0x54...0x63 => kbd.usbChar(keypad[k - 0x54]),
            else => {},
        }
    }

    pub fn handle(self: *Decoder, kbd: *input.Keyboard, rep: *const [8]u8, now: u64) void {
        kbd.noteUsb();
        self.reports +%= 1;

        const mods = rep[0];
        kbd.usbMods((mods & 0x22) != 0, (mods & 0x11) != 0, (mods & 0x44) != 0);

        var newest: u8 = 0;
        for (rep[2..8]) |k| {
            if (k < 4 or self.wasDown(k)) continue; // 1 = report overflow
            if (k == 0x39) {
                kbd.usbCaps();
                continue;
            }
            emit(k, kbd);
            newest = k;
        }

        if (newest != 0 and repeatable(newest)) {
            self.held = newest;
            self.next_rep = now + REPEAT_DELAY_NS;
        } else if (self.held != 0 and !self.stillDown(rep, self.held)) {
            self.held = 0;
        }
        self.prev = rep.*;
    }

    /// Повтор удерживаемой клавиши; вызывается из главного цикла ядра.
    pub fn tick(self: *Decoder, kbd: *input.Keyboard, now: u64) void {
        if (self.held == 0 or now < self.next_rep) return;
        emit(self.held, kbd);
        self.repeats +%= 1;
        self.next_rep = now + REPEAT_RATE_NS;
    }
};

fn report(mods: u8, keys: [6]u8) [8]u8 {
    return .{ mods, 0, keys[0], keys[1], keys[2], keys[3], keys[4], keys[5] };
}

test "hid: boot report decodes US letters and shift modifier" {
    var kbd = input.Keyboard.init();
    var dec = Decoder.init();
    dec.handle(&kbd, &report(0, .{ 0x04, 0, 0, 0, 0, 0 }), 0);
    dec.handle(&kbd, &report(0x22, .{ 0x05, 0, 0, 0, 0, 0 }), 0);
    try std.testing.expectEqual(@as(u16, 'a'), kbd.next().?);
    try std.testing.expectEqual(@as(u16, 'B'), kbd.next().?);
    try std.testing.expectEqual(@as(u64, 2), dec.reports);
}

test "hid: caps lock and control letters match AT keyboard" {
    var kbd = input.Keyboard.init();
    var dec = Decoder.init();
    dec.handle(&kbd, &report(0, .{ 0x39, 0, 0, 0, 0, 0 }), 0);
    dec.handle(&kbd, &report(0, .{ 0x04, 0, 0, 0, 0, 0 }), 0);
    dec.handle(&kbd, &report(0, .{ 0, 0, 0, 0, 0, 0 }), 0);
    dec.handle(&kbd, &report(0x11, .{ 0x04, 0, 0, 0, 0, 0 }), 0);
    try std.testing.expectEqual(@as(u16, 'A'), kbd.next().?);
    try std.testing.expectEqual(@as(u16, 1), kbd.next().?);
}

test "hid: held key repeats after delay and stops on release" {
    var kbd = input.Keyboard.init();
    var dec = Decoder.init();
    const initial = report(0, .{ 0x06, 0, 0, 0, 0, 0 });
    dec.handle(&kbd, &initial, 0);
    try std.testing.expectEqual(@as(u16, 'c'), kbd.next().?);
    dec.tick(&kbd, REPEAT_DELAY_NS - 1);
    try std.testing.expectEqual(@as(?u16, null), kbd.next());
    dec.tick(&kbd, REPEAT_DELAY_NS);
    try std.testing.expectEqual(@as(u16, 'c'), kbd.next().?);
    try std.testing.expectEqual(@as(u64, 1), dec.repeats);

    dec.handle(&kbd, &report(0, .{ 0, 0, 0, 0, 0, 0 }), REPEAT_DELAY_NS);
    dec.tick(&kbd, REPEAT_DELAY_NS + REPEAT_RATE_NS);
    try std.testing.expectEqual(@as(?u16, null), kbd.next());
}

test "hid: navigation usages become special keys" {
    var kbd = input.Keyboard.init();
    var dec = Decoder.init();
    dec.handle(&kbd, &report(0, .{ 0x3A, 0x4F, 0, 0, 0, 0 }), 0);
    try std.testing.expectEqual(@as(u16, input.Key.f1), kbd.next().?);
    try std.testing.expectEqual(@as(u16, input.Key.right), kbd.next().?);
}
