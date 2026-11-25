// COM1, 115200 8N1 — отладочный вывод (QEMU: -serial stdio).
const arch = @import("../x86_64.zig");

const COM1: u16 = 0x3F8;

pub fn init() void {
    arch.outb(COM1 + 1, 0x00); // без прерываний
    arch.outb(COM1 + 3, 0x80); // DLAB
    arch.outb(COM1 + 0, 0x01); // делитель = 1 -> 115200
    arch.outb(COM1 + 1, 0x00);
    arch.outb(COM1 + 3, 0x03); // 8N1
    arch.outb(COM1 + 2, 0xC7); // FIFO
    arch.outb(COM1 + 4, 0x0B);
}

/// Регистр состояния линии (LSR): 0x60 — передатчик пуст, 0xFF — UART нет.
pub fn lineStatus() u8 {
    return arch.inb(COM1 + 5);
}

const koi_lower = [_]u8{
    0xC1, 0xC2, 0xD7, 0xC7, 0xC4, 0xC5, 0xD6, 0xDA, 0xC9, 0xCA, 0xCB, 0xCC, 0xCD, 0xCE, 0xCF, 0xD0,
    0xD2, 0xD3, 0xD4, 0xD5, 0xC6, 0xC8, 0xC3, 0xDE, 0xDB, 0xDD, 0xDF, 0xD9, 0xD8, 0xDC, 0xC0, 0xD1,
};

fn koiToCp(c: u8) u16 {
    if (c == 0xA3) return 0x451; // ё
    if (c == 0xB3) return 0x401; // Ё
    var i: u16 = 0;
    while (i < 32) : (i += 1) {
        if (koi_lower[i] == c) return 0x430 + i;
        if (koi_lower[i] + 0x20 == c) return 0x410 + i;
    }
    return 0;
}

/// Байт консоли (KOI8-R) -> UTF-8 в терминал.
pub fn writeKoi(c: u8) void {
    if (c < 0x80) {
        write(c);
        return;
    }
    const cp = koiToCp(c);
    if (cp == 0) {
        write('?');
        return;
    }
    write(@intCast(0xC0 | (cp >> 6)));
    write(@intCast(0x80 | (cp & 0x3F)));
}

pub fn putsKoi(s: []const u8) void {
    for (s) |c| writeKoi(c);
}

pub fn puts(s: []const u8) void {
    for (s) |c| write(c);
}

pub fn hex8(v: u8) void {
    const d = "0123456789ABCDEF";
    write(d[v >> 4]);
    write(d[v & 15]);
}

pub fn hex32(v: u32) void {
    var i: u32 = 8;
    while (i > 0) {
        i -= 1;
        const nib: u8 = @intCast((v >> @intCast(i * 4)) & 0xF);
        write("0123456789ABCDEF"[nib]);
    }
}

pub fn dec(v: u64) void {
    var buf: [20]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        write('0');
        return;
    }
    while (x > 0) : (x /= 10) {
        buf[n] = '0' + @as(u8, @intCast(x % 10));
        n += 1;
    }
    while (n > 0) {
        n -= 1;
        write(buf[n]);
    }
}

/// Принятый байт или null. 0xFF в LSR — UART отсутствует.
pub fn read() ?u8 {
    const lsr = arch.inb(COM1 + 5);
    if (lsr == 0xFF or (lsr & 1) == 0) return null;
    return arch.inb(COM1);
}

pub fn write(c: u8) void {
    var n: u32 = 0;
    while ((arch.inb(COM1 + 5) & 0x20) == 0 and n < 100_000) : (n += 1) {}
    arch.outb(COM1, c);
}
