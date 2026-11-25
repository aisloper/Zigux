//! TTY-backed stdio: file_operations для fd 0/1/2 из fs/file.c ядра Linux.
//! read() опрашивает драйверы ввода и читает line discipline активного VT;
//! write() проходит через tty.write() (OPOST/ONLCR) и TtyOps.write.
//! Host-тестируемо без arch-слоя.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const file_mod = @import("file.zig");
const tty_mod = @import("tty.zig");
const vt_mod = @import("vt.zig");

pub const Ops = struct {
    switcher: *vt_mod.Switcher,
    /// arch-слой: PS/2 + UART + xHCI → tty.receive().
    pump: ?*const fn (sw: *vt_mod.Switcher) void = null,

    pub fn init(sw: *vt_mod.Switcher, pump: ?*const fn (sw: *vt_mod.Switcher) void) Ops {
        return .{ .switcher = sw, .pump = pump };
    }

    pub fn fileOps(self: *Ops) file_mod.FileOperations {
        return .{
            .ctx = @ptrCast(self),
            .read = readOp,
            .write = writeOp,
        };
    }

    fn from(ctx: ?*anyopaque) *Ops {
        return @ptrCast(@alignCast(ctx.?));
    }

    fn readOp(ctx: ?*anyopaque, _: *file_mod.File, buf: []u8, _: u64) i64 {
        const self = from(ctx);
        const t = self.switcher.activeTty();
        var n = t.read(buf);
        if (n == 0) {
            if (self.pump) |p| {
                p(self.switcher);
                n = t.read(buf);
            }
        }
        return @intCast(n);
    }

    fn writeOp(ctx: ?*anyopaque, _: *file_mod.File, bytes: []const u8, _: u64) i64 {
        const self = from(ctx);
        self.switcher.activeTty().write(bytes);
        return @intCast(bytes.len);
    }
};

const Sink = struct {
    var buf: [128]u8 = undefined;
    var len: usize = 0;

    fn write(_: ?*anyopaque, bytes: []const u8) void {
        @memcpy(Sink.buf[Sink.len .. Sink.len + bytes.len], bytes);
        Sink.len += bytes.len;
    }
};

var pump_calls: usize = 0;
fn testPump(sw: *vt_mod.Switcher) void {
    pump_calls += 1;
    sw.activeTty().receive("hi\r");
}

test "stdio: fd operations read canonical input through active tty" {
    var ttys = [_]tty_mod.Tty{tty_mod.Tty.init("tty1", 0)};
    var sw = vt_mod.Switcher.init(ttys[0..], null, null);
    ttys[0].ops.write = Sink.write;
    var ops = Ops.init(&sw, testPump);
    var f = file_mod.File{ .f_ops = ops.fileOps() };

    var buf: [16]u8 = undefined;
    const n = f.read(&buf);
    const count: usize = @intCast(n);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqualStrings("hi\n", buf[0..count]);
    try std.testing.expect(pump_calls > 0);
}

test "stdio: fd operations write through OPOST/ONLCR" {
    var ttys = [_]tty_mod.Tty{tty_mod.Tty.init("tty1", 0)};
    var sw = vt_mod.Switcher.init(ttys[0..], null, null);
    ttys[0].ops.write = Sink.write;
    var ops = Ops.init(&sw, null);
    var f = file_mod.File{ .f_ops = ops.fileOps() };

    Sink.len = 0;
    const n = f.write("a\nb");
    try std.testing.expectEqual(@as(i64, 3), n);
    try std.testing.expectEqualStrings("a\r\nb", Sink.buf[0..Sink.len]);
}
