//! Минимальный input-слой клавиатуры: set-1 scancodes → байты/special keys.
//! Алгоритм и раскладка портированы из drivers/input/keyboard/atkbd.c и
//! drivers/tty/vt/keyboard.c Linux 7.3 (упрощённая US-раскладка).
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");

pub const Key = struct {
    pub const up: u16 = 0x100;
    pub const down: u16 = 0x101;
    pub const left: u16 = 0x102;
    pub const right: u16 = 0x103;
    pub const home: u16 = 0x104;
    pub const end: u16 = 0x105;
    pub const delete: u16 = 0x106;
    pub const insert: u16 = 0x107;
    pub const pgup: u16 = 0x108;
    pub const pgdn: u16 = 0x109;
    pub const f1: u16 = 0x10A;
    pub const f12: u16 = 0x115;
};

const queue_len = 128;

const lower = [_]u8{
    0,   27,  '1', '2', '3', '4', '5', '6', '7',  '8', '9', '0',  '-',  '=', 8,   9,
    'q', 'w', 'e', 'r', 't', 'y', 'u', 'i', 'o',  'p', '[', ']',  '\n', 0,   'a', 's',
    'd', 'f', 'g', 'h', 'j', 'k', 'l', ';', '\'', '`', 0,   '\\', 'z',  'x', 'c', 'v',
    'b', 'n', 'm', ',', '.', '/', 0,   '*', 0,    ' ',
};

fn shifted(c: u8) u8 {
    return switch (c) {
        '1' => '!',
        '2' => '@',
        '3' => '#',
        '4' => '$',
        '5' => '%',
        '6' => '^',
        '7' => '&',
        '8' => '*',
        '9' => '(',
        '0' => ')',
        '-' => '_',
        '=' => '+',
        '[' => '{',
        ']' => '}',
        '\\' => '|',
        ';' => ':',
        '\'' => '"',
        '`' => '~',
        ',' => '<',
        '.' => '>',
        '/' => '?',
        'a'...'z' => c - 32,
        else => c,
    };
}

pub const Keyboard = struct {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    caps: bool = false,
    extended: bool = false,
    ps2_events: u64 = 0,
    usb_events: u64 = 0,
    queue: [queue_len]u16 = undefined,
    head: usize = 0,
    tail: usize = 0,

    pub fn init() Keyboard {
        return .{};
    }

    /// drivers/tty/vt/keyboard.c: состояние Alt для Alt+Fn.
    pub fn altDown(self: *const Keyboard) bool {
        return self.alt;
    }

    /// HID boot-protocol: модификаторы из первого байта отчёта.
    pub fn usbMods(self: *Keyboard, shift: bool, ctrl: bool, alt: bool) void {
        self.shift = shift;
        self.ctrl = ctrl;
        self.alt = alt;
    }

    pub fn usbCaps(self: *Keyboard) void {
        self.caps = !self.caps;
    }

    pub fn noteUsb(self: *Keyboard) void {
        self.usb_events +%= 1;
    }

    /// HID usage → US-символ без Shift; Shift/Caps/Ctrl применяются здесь.
    pub fn usbChar(self: *Keyboard, c: u8) void {
        var ch = c;
        if (c >= 'a' and c <= 'z') {
            if (self.shift != self.caps) ch = shifted(c);
        } else if (self.shift) {
            ch = shifted(c);
        }
        if (self.ctrl) {
            const lower_char = c | 0x20;
            if (lower_char >= 'a' and lower_char <= 'z') self.push(lower_char - 'a' + 1);
            return;
        }
        if (ch != 0) self.push(ch);
    }

    pub fn usbSpecial(self: *Keyboard, code: u16) void {
        self.push(code);
    }

    fn push(self: *Keyboard, code: u16) void {
        const next_tail = (self.tail + 1) % queue_len;
        if (next_tail == self.head) return;
        self.queue[self.tail] = code;
        self.tail = next_tail;
    }

    pub fn next(self: *Keyboard) ?u16 {
        if (self.head == self.tail) return null;
        const code = self.queue[self.head];
        self.head = (self.head + 1) % queue_len;
        return code;
    }

    fn modifier(self: *Keyboard, code: u8, pressed: bool) bool {
        switch (code) {
            0x1D => self.ctrl = pressed,
            0x38 => self.alt = pressed,
            0x2A, 0x36 => self.shift = pressed,
            0x3A => {
                if (pressed) self.caps = !self.caps;
            },
            else => return false,
        }
        return true;
    }

    fn extendedKey(code: u8) ?u16 {
        return switch (code) {
            0x47 => Key.home,
            0x48 => Key.up,
            0x49 => Key.pgup,
            0x4B => Key.left,
            0x4D => Key.right,
            0x4F => Key.end,
            0x50 => Key.down,
            0x51 => Key.pgdn,
            0x52 => Key.insert,
            0x53 => Key.delete,
            else => null,
        };
    }

    /// atkbd interrupt path: one byte from port 0x60 (set 1 translation on).
    pub fn feed(self: *Keyboard, scancode: u8) void {
        self.ps2_events +%= 1;
        if (scancode == 0xE0) {
            self.extended = true;
            return;
        }
        if (scancode == 0xE1) {
            self.extended = true;
            return;
        }
        const pressed = (scancode & 0x80) == 0;
        const code = scancode & 0x7F;
        if (self.modifier(code, pressed)) {
            if (!pressed) self.extended = false;
            return;
        }
        if (!pressed) {
            self.extended = false;
            return;
        }
        if (self.extended) {
            self.extended = false;
            if (extendedKey(code)) |key| self.push(key);
            return;
        }
        if (code >= lower.len) return;
        var c = lower[code];
        if (c == 0) return;
        if (c >= 'a' and c <= 'z') {
            if (self.shift != self.caps) c = shifted(c);
        } else if (self.shift) {
            c = shifted(c);
        }
        self.push(c);
    }
};

test "input: set-1 scancodes decode into N_TTY bytes" {
    var kbd = Keyboard.init();
    for ([_]u8{ 0x23, 0x12, 0x26, 0x26, 0x18, 0x1C }) |sc| kbd.feed(sc);
    var out: [16]u8 = undefined;
    var n: usize = 0;
    while (kbd.next()) |code| : (n += 1) out[n] = @intCast(code);
    try std.testing.expectEqualStrings("hello\n", out[0..n]);
}

test "input: shift and caps lock modify letters" {
    var kbd = Keyboard.init();
    for ([_]u8{ 0x2A, 0x1E, 0xAA, 0x3A, 0xBA, 0x1F, 0x9F, 0x3A, 0xBA, 0x20 }) |sc| kbd.feed(sc);
    var out: [8]u8 = undefined;
    var n: usize = 0;
    while (kbd.next()) |code| : (n += 1) out[n] = @intCast(code);
    try std.testing.expectEqualStrings("ASd", out[0..n]);
}

test "input: extended scancodes produce special keys and controls" {
    var kbd = Keyboard.init();
    for ([_]u8{ 0xE0, 0x4D, 0xE0, 0xCB, 0x0E, 0x0F }) |sc| kbd.feed(sc);
    try std.testing.expectEqual(@as(u16, Key.right), kbd.next().?);
    try std.testing.expectEqual(@as(u16, 8), kbd.next().?);
    try std.testing.expectEqual(@as(u16, 9), kbd.next().?);
    try std.testing.expectEqual(@as(?u16, null), kbd.next());
}

test "input: HID boot chars apply shift, caps and ctrl" {
    var kbd = Keyboard.init();
    kbd.noteUsb();
    kbd.usbMods(false, false, false);
    kbd.usbChar('a');
    kbd.usbMods(true, false, false);
    kbd.usbChar('b');
    kbd.usbCaps();
    kbd.usbChar('c');
    kbd.usbMods(false, true, false);
    kbd.usbChar('d');
    try std.testing.expectEqual(@as(u16, 'a'), kbd.next().?);
    try std.testing.expectEqual(@as(u16, 'B'), kbd.next().?);
    try std.testing.expectEqual(@as(u16, 'c'), kbd.next().?);
    try std.testing.expectEqual(@as(u16, 4), kbd.next().?);
    try std.testing.expectEqual(@as(u64, 1), kbd.usb_events);
}
