//! Порт TTY-подсистемы Linux 7.3 на Zig.
//! Источники: include/linux/tty.h, drivers/tty/n_tty.c, drivers/tty/tty_io.c,
//! drivers/tty/tty_jobctrl.c, include/uapi/asm-generic/termbits.h.
//! Port-слой: line discipline N_TTY, canonical/raw режимы, echo, job control.
//! Драйверы (keyboard/serial/framebuffer) остаются из zigos и подключаются
//! через интерфейс TtyOps. Упущено: PARMRK, packet mode, flow control,
//! wait_queue (блокирующий read возвращает EAGAIN), ldisc switching, PTY link.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");

pub const N_TTY_BUF_SIZE: usize = 4096;
const MASK = N_TTY_BUF_SIZE - 1;

/// include/uapi/asm-generic/termbits.h — c_iflag.
pub const IFlag = struct {
    pub const IGNBRK: u32 = 0x0000001;
    pub const BRKINT: u32 = 0x0000002;
    pub const IGNPAR: u32 = 0x0000004;
    pub const PARMRK: u32 = 0x0000008;
    pub const INPCK: u32 = 0x0000010;
    pub const ISTRIP: u32 = 0x0000020;
    pub const INLCR: u32 = 0x0000040;
    pub const IGNCR: u32 = 0x0000080;
    pub const ICRNL: u32 = 0x0000100;
    pub const IUCLC: u32 = 0x0000200;
    pub const IXON: u32 = 0x0000400;
    pub const IXANY: u32 = 0x0000800;
    pub const IXOFF: u32 = 0x0001000;
    pub const IMAXBEL: u32 = 0x0002000;
    pub const IUTF8: u32 = 0x0004000;
};

/// c_oflag.
pub const OFlag = struct {
    pub const OPOST: u32 = 0x0000001;
    pub const ONLCR: u32 = 0x0000004;
    pub const OCRNL: u32 = 0x0000008;
    pub const ONOCR: u32 = 0x0000010;
    pub const ONLRET: u32 = 0x0000020;
    pub const OFILL: u32 = 0x0000040;
    pub const OFDEL: u32 = 0x0000080;
};

/// c_cflag.
pub const CFlag = struct {
    pub const CSIZE: u32 = 0x0000030;
    pub const CS5: u32 = 0x0000000;
    pub const CS6: u32 = 0x0000010;
    pub const CS7: u32 = 0x0000020;
    pub const CS8: u32 = 0x0000030;
    pub const CSTOPB: u32 = 0x0000040;
    pub const CREAD: u32 = 0x0000080;
    pub const PARENB: u32 = 0x0000100;
    pub const PARODD: u32 = 0x0000200;
    pub const HUPCL: u32 = 0x0000400;
    pub const CLOCAL: u32 = 0x0000800;
};

/// c_lflag.
pub const LFlag = struct {
    pub const ISIG: u32 = 0x0000001;
    pub const ICANON: u32 = 0x0000002;
    pub const XCASE: u32 = 0x0000004;
    pub const ECHO: u32 = 0x0000008;
    pub const ECHOE: u32 = 0x0000010;
    pub const ECHOK: u32 = 0x0000020;
    pub const ECHONL: u32 = 0x0000040;
    pub const NOFLSH: u32 = 0x0000080;
    pub const TOSTOP: u32 = 0x0000100;
    pub const ECHOCTL: u32 = 0x0000200;
    pub const ECHOPRT: u32 = 0x0000400;
    pub const ECHOKE: u32 = 0x0000800;
    pub const FLUSHO: u32 = 0x0001000;
    pub const PENDIN: u32 = 0x0002000;
    pub const IEXTEN: u32 = 0x0008000;
    pub const EXTPROC: u32 = 0x0010000;
};

/// Индексы c_cc[] из include/uapi/asm-generic/termbits.h.
pub const CcIndex = struct {
    pub const VINTR: usize = 0;
    pub const VQUIT: usize = 1;
    pub const VERASE: usize = 2;
    pub const VKILL: usize = 3;
    pub const VEOF: usize = 4;
    pub const VTIME: usize = 5;
    pub const VMIN: usize = 6;
    pub const VSWTC: usize = 7;
    pub const VSTART: usize = 8;
    pub const VSTOP: usize = 9;
    pub const VSUSP: usize = 10;
    pub const VEOL: usize = 11;
    pub const VREPRINT: usize = 12;
    pub const VDISCARD: usize = 13;
    pub const VWERASE: usize = 14;
    pub const VLNEXT: usize = 15;
    pub const VEOL2: usize = 16;
    pub const NCCS: usize = 19;
};

/// include/linux/termios.h: struct ktermios.
pub const Termios = struct {
    c_iflag: u32 = 0,
    c_oflag: u32 = 0,
    c_cflag: u32 = 0,
    c_lflag: u32 = 0,
    c_line: u8 = 0,
    c_cc: [CcIndex.NCCS]u8 = @splat(0),
    c_ispeed: u32 = 0,
    c_ospeed: u32 = 0,

    /// Linux tty defaults: drivers/tty/tty_io.c: tty_std_termios.
    pub fn defaults() Termios {
        var t = Termios{
            .c_iflag = IFlag.ICRNL | IFlag.IXON | IFlag.BRKINT,
            .c_oflag = OFlag.OPOST | OFlag.ONLCR,
            .c_cflag = CFlag.CREAD | CFlag.CS8 | CFlag.HUPCL,
            .c_lflag = LFlag.ISIG | LFlag.ICANON | LFlag.ECHO |
                LFlag.ECHOE | LFlag.ECHOK | LFlag.ECHOCTL | LFlag.IEXTEN,
        };
        t.c_cc[CcIndex.VINTR] = 3; // ^C
        t.c_cc[CcIndex.VQUIT] = 28; // ^\
        t.c_cc[CcIndex.VERASE] = 127; // DEL
        t.c_cc[CcIndex.VKILL] = 21; // ^U
        t.c_cc[CcIndex.VEOF] = 4; // ^D
        t.c_cc[CcIndex.VMIN] = 1;
        t.c_cc[CcIndex.VSUSP] = 26; // ^Z
        t.c_cc[CcIndex.VEOL] = 0;
        t.c_cc[CcIndex.VREPRINT] = 18; // ^R
        t.c_cc[CcIndex.VWERASE] = 23; // ^W
        t.c_cc[CcIndex.VLNEXT] = 22; // ^V
        t.c_ispeed = 38400;
        t.c_ospeed = 38400;
        return t;
    }

    /// drivers/tty/tty_io.c: tty_mode_ioctl TCGETS/TCSETS.
    pub fn setFrom(self: *Termios, other: Termios) void {
        self.* = other;
    }

    pub inline fn icanon(self: *const Termios) bool {
        return self.c_lflag & LFlag.ICANON != 0;
    }
    pub inline fn echo(self: *const Termios) bool {
        return self.c_lflag & LFlag.ECHO != 0;
    }
    pub inline fn echoCtl(self: *const Termios) bool {
        return self.c_lflag & LFlag.ECHOCTL != 0;
    }
    pub inline fn isig(self: *const Termios) bool {
        return self.c_lflag & LFlag.ISIG != 0;
    }
    pub inline fn extproc(self: *const Termios) bool {
        return self.c_lflag & LFlag.EXTPROC != 0;
    }
    pub inline fn iexten(self: *const Termios) bool {
        return self.c_lflag & LFlag.IEXTEN != 0;
    }
    pub inline fn icrnl(self: *const Termios) bool {
        return self.c_iflag & IFlag.ICRNL != 0;
    }
    pub inline fn inlcr(self: *const Termios) bool {
        return self.c_iflag & IFlag.INLCR != 0;
    }
    pub inline fn igncr(self: *const Termios) bool {
        return self.c_iflag & IFlag.IGNCR != 0;
    }
    pub inline fn onlcr(self: *const Termios) bool {
        return self.c_oflag & OFlag.OPOST != 0 and self.c_oflag & OFlag.ONLCR != 0;
    }
};

/// drivers/tty/n_tty.c: struct n_tty_data (упрощённый, без PARMRK/packet).
pub const NTtyData = struct {
    read_buf: [N_TTY_BUF_SIZE]u8 = @splat(0),
    /// read_flags[i] = 1, если символ i завершает каноническую строку.
    read_flags: [N_TTY_BUF_SIZE]bool = @splat(false),
    echo_buf: [N_TTY_BUF_SIZE]u8 = @splat(0),

    read_head: usize = 0,
    commit_head: usize = 0,
    canon_head: usize = 0,
    echo_head: usize = 0,
    echo_commit: usize = 0,
    echo_mark: usize = 0,
    read_tail: usize = 0,
    line_start: usize = 0,

    erasing: bool = false,
    lnext: bool = false,
    push: bool = false,

    pub fn reset(self: *NTtyData) void {
        self.read_head = 0;
        self.commit_head = 0;
        self.canon_head = 0;
        self.read_tail = 0;
        self.line_start = 0;
        self.echo_head = 0;
        self.echo_commit = 0;
        self.echo_mark = 0;
        self.erasing = false;
        self.lnext = false;
        self.push = false;
        @memset(&self.read_flags, false);
    }

    inline fn put(self: *NTtyData, c: u8) void {
        self.read_buf[self.read_head & MASK] = c;
        self.read_head += 1;
    }

    inline fn readAt(self: *const NTtyData, i: usize) u8 {
        return self.read_buf[i & MASK];
    }

    inline fn readCount(self: *const NTtyData) usize {
        return self.read_head - self.read_tail;
    }

    inline fn canonicalAvailable(self: *const NTtyData) bool {
        return self.canon_head != self.read_tail;
    }
};

/// Операции драйвера (реализуются в zigos: serial/console/keyboard).
pub const TtyOps = struct {
    ctx: ?*anyopaque = null,
    /// Отправить байты на устройство (_serial write / console write).
    write: ?*const fn (ctx: ?*anyopaque, bytes: []const u8) void = null,
    /// Сигнал для foreground process group (job control из zigos/user.zig).
    signalPgrp: ?*const fn (ctx: ?*anyopaque, pgrp: u32, sig: u8) void = null,
};

/// include/linux/tty.h: struct tty_struct (упрощённый).
pub const Tty = struct {
    name: []const u8,
    index: u32,
    termios: Termios,
    ldata: NTtyData = .{},
    ops: TtyOps = .{},

    /// Job control (drivers/tty/tty_jobctrl.c): session и foreground pgrp.
    session: u32 = 0,
    pgrp: u32 = 0,

    pub fn init(name: []const u8, index: u32) Tty {
        return .{
            .name = name,
            .index = index,
            .termios = Termios.defaults(),
        };
    }

    /// tty_insert_flip_string(): драйвер → line discipline.
    pub fn receive(self: *Tty, bytes: []const u8) void {
        for (bytes) |raw| {
            var c = raw;
            // ICRNL: CR → NL (Linux n_tty_receive_char).
            if (self.termios.icrnl() and c == '\r') c = '\n';
            if (self.termios.inlcr() and c == '\n') c = '\r';
            if (self.termios.igncr() and c == '\r') continue;

            // ISIG: ^C/^\\/^Z → сигнал, не в буфер (n_tty_receive_char_special).
            if (self.termios.isig()) {
                const sig: ?u8 = if (c == self.termios.c_cc[CcIndex.VINTR]) 2 // SIGINT
                    else if (c == self.termios.c_cc[CcIndex.VQUIT]) 3 // SIGQUIT
                    else if (c == self.termios.c_cc[CcIndex.VSUSP]) 20 // SIGTSTP
                    else null;
                if (sig) |s| {
                    if (self.pgrp != 0) {
                        if (self.ops.signalPgrp) |fnc| fnc(self.ops.ctx, self.pgrp, s);
                    }
                    if (self.termios.echo() and self.termios.echoCtl()) self.echoControl(c);
                    continue;
                }
            }

            if (self.termios.icanon() and !self.termios.extproc()) {
                if (self.receiveCanon(c)) continue;
            }

            // Стандартная обработка + commit_head (raw mode).
            self.ldata.put(c);
            self.ldata.commit_head = self.ldata.read_head;
            if (self.termios.echo()) self.echoChar(c);
        }
    }

    /// n_tty_receive_char_canon(): обработка спецсимволов в canonical mode.
    fn receiveCanon(self: *Tty, c: u8) bool {
        const t = &self.termios;
        const l = &self.ldata;

        if (c == t.c_cc[CcIndex.VERASE] or c == t.c_cc[CcIndex.VKILL] or
            (c == t.c_cc[CcIndex.VWERASE] and t.iexten()))
        {
            // eraser(): откат read_head до line_start / границы слова.
            if (c == t.c_cc[CcIndex.VKILL]) {
                l.read_head = l.line_start; // VKILL удаляет всю строку
            } else if (c == t.c_cc[CcIndex.VERASE] and l.read_head > l.line_start) {
                l.read_head -= 1;
            } else if (c == t.c_cc[CcIndex.VWERASE] and l.read_head > l.line_start) {
                while (l.read_head > l.line_start and isBlank(l.readAt(l.read_head - 1))) l.read_head -= 1;
                while (l.read_head > l.line_start and !isBlank(l.readAt(l.read_head - 1))) l.read_head -= 1;
            }
            // canon_head не трогаем: он указывает на конец зафиксированных строк.
            if (t.echo()) self.echoErase(c);
            return true;
        }

        if (c == t.c_cc[CcIndex.VLNEXT] and t.iexten()) {
            l.lnext = true;
            return true;
        }

        if (c == t.c_cc[CcIndex.VREPRINT] and t.echo() and t.iexten()) {
            var i = l.line_start;
            while (i < l.read_head) : (i += 1) self.echoChar(l.readAt(i));
            return true;
        }

        // n_tty_receive_handle_newline(): CR/LF/EOF/EOL завершают строку.
        if (c == '\n' or c == t.c_cc[CcIndex.VEOF] or
            c == t.c_cc[CcIndex.VEOL] or
            (c == t.c_cc[CcIndex.VEOL2] and t.iexten()))
        {
            if (c == t.c_cc[CcIndex.VEOF]) {
                // ^D: завершает строку без самого символа.
            } else {
                l.read_flags[l.read_head & MASK] = true;
                l.put(c);
            }
            l.canon_head = l.read_head;
            if (t.echo() or (c == '\n' and t.c_lflag & LFlag.ECHONL != 0)) self.echoChar('\n');
            return true;
        }
        return false;
    }

    inline fn echoChar(self: *Tty, c: u8) void {
        if (self.ops.write == null) return;
        self.ops.write.?(self.ops.ctx, &[_]u8{c});
    }

    inline fn echoControl(self: *Tty, c: u8) void {
        self.echoChar('^');
        self.echoChar(c ^ 0x40);
        self.echoChar('\x08');
    }

    inline fn echoErase(self: *Tty, c: u8) void {
        _ = c;
        // ECHOE: backspace-space-backspace (Linux finish_erasing).
        self.echoChar('\x08');
        self.echoChar(' ');
        self.echoChar('\x08');
    }

    /// n_tty_read(): прочитать одну строку (icanon) или доступные байты (raw).
    /// Возвращает 0 если данных нет (эквивалент EAGAIN в host-симуляторе).
    pub fn read(self: *Tty, out: []u8) usize {
        const l = &self.ldata;
        if (self.termios.icanon() and !self.termios.extproc()) {
            if (!l.canonicalAvailable()) return 0;
            var n: usize = 0;
            while (n < out.len and l.read_tail < l.canon_head) {
                const i = l.read_tail & MASK;
                out[n] = l.read_buf[i];
                n += 1;
                l.read_tail += 1;
                if (l.read_flags[i]) {
                    l.read_flags[i] = false;
                    l.line_start = l.read_tail;
                    break; // одна строка за read
                }
            }
            return n;
        }
        // raw: копировать до commit_head.
        const avail = @min(l.commit_head - l.read_tail, out.len);
        for (0..avail) |i| out[i] = l.readAt(l.read_tail + i);
        l.read_tail += avail;
        return avail;
    }

    /// n_tty_write(): output processing (OPOST/ONLCR) → драйвер.
    pub fn write(self: *Tty, bytes: []const u8) void {
        if (self.ops.write == null) return;
        if (!self.termios.onlcr()) {
            self.ops.write.?(self.ops.ctx, bytes);
            return;
        }
        var buf: [N_TTY_BUF_SIZE * 2]u8 = undefined;
        var n: usize = 0;
        for (bytes) |c| {
            if (c == '\n') {
                buf[n] = '\r';
                n += 1;
            }
            buf[n] = c;
            n += 1;
        }
        self.ops.write.?(self.ops.ctx, buf[0..n]);
    }

    /// tcflush() / tty_flush_buffer().
    pub fn flush(self: *Tty) void {
        self.ldata.reset();
    }

    /// TIOCGPGRP / TIOCSPGRP (drivers/tty/tty_jobctrl.c).
    pub fn setPgrp(self: *Tty, pgrp: u32) void {
        self.pgrp = pgrp;
        if (self.session == 0) self.session = pgrp;
    }
};

/// Тестовый драйвер: буфер вывода и ловушка сигналов.
const TestSink = struct {
    var buf: [1024]u8 = undefined;
    var len: usize = 0;
    var pgrp: u32 = 0;
    var sig: u8 = 0;
    fn write(_: ?*anyopaque, bytes: []const u8) void {
        @memcpy(buf[len .. len + bytes.len], bytes);
        len += bytes.len;
    }
    fn signal(_: ?*anyopaque, pg: u32, s: u8) void {
        pgrp = pg;
        sig = s;
    }
};

inline fn isBlank(c: u8) bool {
    return c == ' ' or c == '\t';
}

test "N_TTY: ICRNL, canonical line, EOF, ERASE, ECHO и ONLCR" {
    var tty = Tty.init("ttyS0", 0);
    tty.ops = .{ .write = TestSink.write };

    // Ввод "abc\r" → ICRNL превращает CR в NL → каноничная строка "abc\n".
    tty.receive("abc\r");
    var out: [64]u8 = undefined;
    const n = tty.read(&out);
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("abc\n", out[0..n]);
    try std.testing.expectEqual(@as(usize, 0), tty.read(&out)); // строки больше нет

    // VERASE (DEL) стирает последний символ.
    tty.receive("xy\x7fz\n");
    const n2 = tty.read(&out);
    try std.testing.expectEqualStrings("xz\n", out[0..n2]);

    // ^D завершает строку без символа.
    tty.receive("hi\x04");
    const n3 = tty.read(&out);
    try std.testing.expectEqualStrings("hi", out[0..n3]);

    // ONLCR: "\n" → "\r\n" на выходе.
    TestSink.len = 0;
    tty.write("a\nb");
    try std.testing.expectEqualStrings("a\r\nb", TestSink.buf[0..TestSink.len]);

    // Сигнал ^C не попадает в буфер, callback получает SIGINT (2).
    tty.pgrp = 42;
    tty.ops.signalPgrp = TestSink.signal;
    TestSink.sig = 0;
    tty.receive(&[_]u8{3});
    try std.testing.expectEqual(@as(u32, 42), TestSink.pgrp);
    try std.testing.expectEqual(@as(u8, 2), TestSink.sig);
    try std.testing.expectEqual(@as(usize, 0), tty.read(&out));
}

test "N_TTY: raw mode (ICANON off) reads bytes immediately" {
    var tty = Tty.init("ttyS1", 1);
    tty.termios.c_lflag &= ~LFlag.ICANON;
    tty.termios.c_lflag &= ~LFlag.ECHO;
    tty.receive("abc");
    var out: [8]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), tty.read(&out));
    try std.testing.expectEqualStrings("abc", out[0..3]);
}
