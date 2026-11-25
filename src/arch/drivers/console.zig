//! Текстовая консоль на GOP framebuffer ( drivers/tty/vt/vt.c Linux 7.3 ).
//! Перерисовываются только изменившиеся ячейки; шрифт 8x16 из zigos
//! используется как data-файл (исходный драйвер не изменялся).
//! Реализует tty.TtyOps.write: байты идут и в UART, и в framebuffer.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const boot = @import("../boot.zig");
const font = @import("font.zig");
const serial = @import("serial.zig");
const tty_mod = @import("../../tty.zig");
const device_mod = @import("../../device.zig");

pub const MAX_COLS: usize = 128;
pub const MAX_ROWS: usize = 64;
const CELL_W: usize = 8;
const CELL_H: usize = 16;

const Cell = struct {
    ch: u8 = ' ',
    fg: u32 = 0xC8C8C8,
    bg: u32 = 0x0B0F14,
};

const blank = Cell{};

pub const Console = struct {
    cells: [MAX_COLS * MAX_ROWS]Cell = undefined,
    drawn: [MAX_COLS * MAX_ROWS]Cell = undefined,
    cols: usize = 0,
    rows: usize = 0,
    row: usize = 0,
    col: usize = 0,
    dirty_all: bool = true,
    fb: ?[*]volatile u32 = null,
    width: usize = 0,
    stride: usize = 0,
    height: usize = 0,
    bgr: bool = true,

    pub fn setGeometry(self: *Console, width: usize, height: usize, stride: usize, bgr: bool) void {
        self.cols = @min(MAX_COLS, width / CELL_W);
        self.rows = @min(MAX_ROWS, height / CELL_H);
        self.width = width;
        self.height = height;
        self.stride = stride;
        self.bgr = bgr;
    }

    pub fn setFramebuffer(self: *Console, info: boot.BootInfo) void {
        self.setGeometry(info.fb_width, info.fb_height, info.fb_stride, info.fb_bgr);
        self.fb = @ptrFromInt(info.fb_base);
        self.clear();
    }

    pub fn clear(self: *Console) void {
        for (&self.cells) |*cell| cell.* = blank;
        self.row = 0;
        self.col = 0;
        self.dirty_all = true;
        self.render();
    }

    fn scroll(self: *Console) void {
        var r: usize = 0;
        while (r + 1 < self.rows) : (r += 1) {
            const dst = self.cells[r * MAX_COLS ..][0..self.cols];
            const src = self.cells[(r + 1) * MAX_COLS ..][0..self.cols];
            std.mem.copyForwards(Cell, dst, src);
        }
        for (0..self.cols) |c| self.cells[(self.rows - 1) * MAX_COLS + c] = blank;
        self.row = self.rows - 1;
        self.dirty_all = true;
    }

    pub fn putc(self: *Console, ch: u8) void {
        if (self.cols == 0 or self.rows == 0) return;
        switch (ch) {
            '\n' => {
                self.row += 1;
                self.col = 0;
            },
            '\r' => self.col = 0,
            8 => {
                if (self.col > 0) self.col -= 1;
            },
            else => {
                if (ch < 0x20) return;
                self.cells[self.row * MAX_COLS + self.col] = .{ .ch = ch };
                self.col += 1;
            },
        }
        if (self.col >= self.cols) {
            self.col = 0;
            self.row += 1;
        }
        if (self.row >= self.rows) self.scroll();
    }

    pub fn write(self: *Console, bytes: []const u8) void {
        for (bytes) |ch| self.putc(ch);
        self.render();
    }

    fn packColor(self: *const Console, color: u32) u32 {
        if (self.bgr) return color;
        const r = (color >> 16) & 0xFF;
        const g = (color >> 8) & 0xFF;
        const b = color & 0xFF;
        return (b << 16) | (g << 8) | r;
    }

    fn drawCell(self: *Console, index: usize) void {
        const fb = self.fb orelse return;
        const r = index / MAX_COLS;
        const c = index % MAX_COLS;
        if (c >= self.cols or r >= self.rows) return;
        const cell = self.cells[index];
        const glyph = font.glyphs[cell.ch];
        const x0 = c * CELL_W;
        const y0 = r * CELL_H;
        if (x0 + CELL_W > self.width or y0 + CELL_H > self.height) return;
        for (0..CELL_H) |gy| {
            const bits = glyph[gy];
            for (0..CELL_W) |gx| {
                const bit: u32 = @as(u32, 1) << @intCast(7 - gx);
                const color = if ((bits & @as(u8, @intCast(bit))) != 0) cell.fg else cell.bg;
                fb[(y0 + gy) * self.stride + x0 + gx] = self.packColor(color);
            }
        }
        self.drawn[index] = cell;
    }

    pub fn render(self: *Console) void {
        if (self.fb == null) return;
        for (0..MAX_ROWS) |r| {
            for (0..self.cols) |c| {
                const i = r * MAX_COLS + c;
                if (self.dirty_all or !std.meta.eql(self.cells[i], self.drawn[i])) self.drawCell(i);
            }
        }
        self.dirty_all = false;
    }

    /// vt.c swapState(): обменять живой экран и курсор с состоянием VT.
    pub fn swapState(self: *Console, saved: *VtState) void {
        for (0..MAX_COLS * MAX_ROWS) |i| {
            const tmp = self.cells[i];
            self.cells[i] = saved.cells[i];
            saved.cells[i] = tmp;
        }
        const tmp_row = self.row;
        self.row = saved.row;
        saved.row = tmp_row;
        const tmp_col = self.col;
        self.col = saved.col;
        saved.col = tmp_col;
        self.dirty_all = true;
    }
};

/// Состояние экрана неактивного VT (drivers/tty/vt/vt.c: struct vc_data).
pub const VtState = struct {
    cells: [MAX_COLS * MAX_ROWS]Cell = @splat(blank),
    row: usize = 0,
    col: usize = 0,
};

pub var screens: [4]VtState = @splat(.{});
pub var console: Console = undefined;
pub var ready: bool = false;

pub var device = device_mod.Device.init("gop-console", .{ .bus = .platform });
pub var driver = device_mod.Driver.init("vt-console", match, probe, null);

fn match(dev: *const device_mod.Device, _: *const device_mod.Driver) bool {
    return dev.modalias.bus == .platform;
}

fn probe(_: *device_mod.Device) !void {
    init(boot.info);
    ready = true;
}

/// tty.TtyOps.write: UART остаётся основным отладочным каналом, консоль
/// дублирует вывод в framebuffer.
pub fn ttyWrite(_: ?*anyopaque, bytes: []const u8) void {
    serial.puts(bytes);
    console.write(bytes);
}

pub fn connect(t: *tty_mod.Tty) void {
    t.ops.write = ttyWrite;
}

/// vt.c switchTo(): сохранить экран ушедшего VT, загрузить экран нового.
pub fn switchScreen(from: usize, to: usize) void {
    if (from < screens.len) console.swapState(&screens[from]);
    if (to < screens.len) console.swapState(&screens[to]);
    console.render();
}

pub fn init(info: boot.BootInfo) void {
    console = Console{};
    console.setFramebuffer(info);
}

test "VT console: geometry, line wrap and scroll" {
    var c = Console{};
    c.clear();
    c.setGeometry(800, 600, 800, true);
    try std.testing.expectEqual(@as(usize, 100), c.cols);
    try std.testing.expectEqual(@as(usize, 37), c.rows);

    c.write("abc");
    try std.testing.expectEqual(@as(u8, 'a'), c.cells[0].ch);
    try std.testing.expectEqual(@as(u8, 'b'), c.cells[1].ch);
    try std.testing.expectEqual(@as(u8, 'c'), c.cells[2].ch);
    try std.testing.expectEqual(@as(usize, 3), c.col);
    c.putc('\n');
    try std.testing.expectEqual(@as(usize, 1), c.row);
    try std.testing.expectEqual(@as(usize, 0), c.col);

    c.cells[MAX_COLS].ch = 'B';
    c.row = c.rows - 1;
    c.col = c.cols - 1;
    c.putc('x');
    try std.testing.expectEqual(@as(u8, 'B'), c.cells[0].ch);
    try std.testing.expectEqual(@as(usize, c.rows - 1), c.row);
}

test "VT console: render changed glyph into framebuffer" {
    var fb: [16 * 16]u32 = undefined;
    @memset(&fb, 0);
    var c = Console{};
    c.clear();
    c.setGeometry(16, 16, 16, true);
    c.fb = @ptrCast(&fb);
    c.cells[0] = .{ .ch = 'A' };
    c.render();
    var painted: usize = 0;
    for (fb) |pixel| {
        if (pixel != 0) painted += 1;
    }
    try std.testing.expect(painted > 0);
}

test "VT console: swapState keeps independent screens" {
    var c = Console{};
    c.clear();
    c.setGeometry(16, 32, 16, true);
    var first = VtState{};
    var second = VtState{};

    c.write("AA");
    c.swapState(&first);
    try std.testing.expectEqual(@as(u8, ' '), c.cells[0].ch);
    try std.testing.expectEqual(@as(u8, 'A'), first.cells[0].ch);
    c.write("BB");
    c.swapState(&second);

    c.swapState(&first);
    try std.testing.expectEqual(@as(u8, 'A'), c.cells[0].ch);
    c.swapState(&second);
    try std.testing.expectEqual(@as(u8, 'B'), c.cells[0].ch);
    try std.testing.expectEqual(@as(u8, 'A'), second.cells[0].ch);
}
