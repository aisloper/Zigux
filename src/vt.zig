//! Виртуальные терминалы: активный VT, Alt+Fn и маршрутизация ввода.
//! Порт алгоритмов drivers/tty/vt/vt.c и drivers/tty/vt/keyboard.c Linux 7.3
//! (NVT, switchTo, special keys). Драйверы остаются снаружи: перерисовку экрана
//! задаёт SwitchHook, host-тесты работают без arch-слоя и железа.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const input = @import("input.zig");
const tty_mod = @import("tty.zig");

pub const SwitchHook = *const fn (ctx: ?*anyopaque, from: usize, to: usize) void;

/// Escape-последовательности для F1..F12 (linux_keycode → terminfo).
const fn_keys = [_][]const u8{
    "\x1bOP",   "\x1bOQ",   "\x1bOR",   "\x1bOS",
    "\x1b[15~", "\x1b[17~", "\x1b[18~", "\x1b[19~",
    "\x1b[20~", "\x1b[21~", "\x1b[23~", "\x1b[24~",
};

/// Общий путь PS/2 и HID: event из input.Keyboard → line discipline активного VT.
pub fn feedKeyTo(t: *tty_mod.Tty, code: u16) void {
    if (code < 0x100) {
        var one = [1]u8{@intCast(code)};
        t.receive(&one);
        return;
    }
    if (code >= input.Key.f1 and code <= input.Key.f12) {
        const index: usize = @intCast(code - input.Key.f1);
        t.receive(fn_keys[index]);
        return;
    }
    const seq: ?[]const u8 = switch (code) {
        input.Key.up => "\x1b[A",
        input.Key.down => "\x1b[B",
        input.Key.right => "\x1b[C",
        input.Key.left => "\x1b[D",
        input.Key.home => "\x1b[H",
        input.Key.end => "\x1b[F",
        input.Key.delete => "\x1b[3~",
        input.Key.insert => "\x1b[2~",
        input.Key.pgup => "\x1b[5~",
        input.Key.pgdn => "\x1b[6~",
        else => null,
    };
    if (seq) |s| t.receive(s);
}

/// vt.c: active VT, число виртуальных консолей и вызов swapState/redraw.
pub const Switcher = struct {
    ttys: []tty_mod.Tty,
    active: usize = 0,
    switches: u64 = 0,
    ctx: ?*anyopaque = null,
    on_switch: ?SwitchHook = null,

    pub fn init(ttys: []tty_mod.Tty, ctx: ?*anyopaque, hook: ?SwitchHook) Switcher {
        return .{ .ttys = ttys, .ctx = ctx, .on_switch = hook };
    }

    pub fn activeTty(self: *Switcher) *tty_mod.Tty {
        return &self.ttys[self.active];
    }

    pub fn switchTo(self: *Switcher, index: usize) void {
        if (index >= self.ttys.len or index == self.active) return;
        const from = self.active;
        self.active = index;
        self.switches +%= 1;
        if (self.on_switch) |hook| hook(self.ctx, from, index);
    }

    /// keyboard.c feedKey(): Alt+F1..FN переключает VT, остальное идёт в Tty.
    pub fn feedKey(self: *Switcher, kbd: *const input.Keyboard, code: u16) void {
        if (kbd.altDown() and code >= input.Key.f1 and code <= input.Key.f12) {
            const index: usize = @intCast(code - input.Key.f1);
            if (index < self.ttys.len) {
                self.switchTo(index);
                return;
            }
        }
        feedKeyTo(self.activeTty(), code);
    }
};

var hook_from: usize = 0;
var hook_to: usize = 0;
var hook_calls: usize = 0;
fn testHook(_: ?*anyopaque, from: usize, to: usize) void {
    hook_from = from;
    hook_to = to;
    hook_calls += 1;
}

fn rawTty(t: *tty_mod.Tty) void {
    t.termios.c_lflag &= ~tty_mod.LFlag.ICANON;
    t.termios.c_lflag &= ~tty_mod.LFlag.ECHO;
}

test "vt: Alt+F2 switches active console and routes subsequent input" {
    var ttys = [_]tty_mod.Tty{ tty_mod.Tty.init("tty1", 0), tty_mod.Tty.init("tty2", 1) };
    var sw = Switcher.init(ttys[0..], null, testHook);
    var kbd = input.Keyboard.init();
    rawTty(&ttys[0]);
    rawTty(&ttys[1]);
    hook_calls = 0;

    kbd.alt = true;
    sw.feedKey(&kbd, input.Key.f1 + 1);
    try std.testing.expectEqual(@as(usize, 1), sw.active);
    try std.testing.expectEqual(@as(usize, 1), hook_calls);
    try std.testing.expectEqual(@as(usize, 0), hook_from);
    try std.testing.expectEqual(@as(usize, 1), hook_to);
    try std.testing.expectEqual(@as(u64, 1), sw.switches);

    kbd.alt = false;
    sw.feedKey(&kbd, 'x');
    var buf: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), ttys[1].read(&buf));
    try std.testing.expectEqualStrings("x", buf[0..1]);
    try std.testing.expectEqual(@as(usize, 0), ttys[0].read(&buf));
}

test "vt: F2 without Alt sends terminfo escape sequence" {
    var ttys = [_]tty_mod.Tty{tty_mod.Tty.init("tty1", 0)};
    var sw = Switcher.init(ttys[0..], null, testHook);
    var kbd = input.Keyboard.init();
    rawTty(&ttys[0]);

    sw.feedKey(&kbd, input.Key.f1 + 1);
    try std.testing.expectEqual(@as(usize, 0), sw.active);
    var buf: [16]u8 = undefined;
    const n = ttys[0].read(&buf);
    try std.testing.expectEqualStrings("\x1bOQ", buf[0..n]);
}

test "vt: Alt+F9 is ignored when only four consoles exist" {
    var ttys = [_]tty_mod.Tty{tty_mod.Tty.init("tty1", 0)};
    var sw = Switcher.init(ttys[0..], null, testHook);
    var kbd = input.Keyboard.init();
    kbd.alt = true;

    sw.feedKey(&kbd, input.Key.f1 + 8);
    try std.testing.expectEqual(@as(usize, 0), sw.active);
    try std.testing.expectEqual(@as(u64, 0), sw.switches);
}

test "vt: switchTo is idempotent for same or invalid VT" {
    var ttys = [_]tty_mod.Tty{ tty_mod.Tty.init("tty1", 0), tty_mod.Tty.init("tty2", 1) };
    var sw = Switcher.init(ttys[0..], null, testHook);
    hook_calls = 0;

    sw.switchTo(0);
    sw.switchTo(7);
    try std.testing.expectEqual(@as(usize, 0), sw.active);
    try std.testing.expectEqual(@as(usize, 0), hook_calls);
    sw.switchTo(1);
    sw.switchTo(1);
    try std.testing.expectEqual(@as(usize, 1), sw.active);
    try std.testing.expectEqual(@as(u64, 1), sw.switches);
}
