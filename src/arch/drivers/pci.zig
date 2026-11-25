//! Port of PCI enumeration from include/linux/pci.h and drivers/pci/probe.c.
//! Minimal variant: legacy config mechanism #1 (0xCF8/0xCFC), available
//! immediately after ExitBootServices without UEFI PCI protocols.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const x86 = @import("../x86_64.zig");

pub const MAX_BUSES: usize = 16;

pub const Device = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    device: u16,
    class: u8,
    subclass: u8,
    prog_if: u8,
    subsystem_vendor: u16 = 0,
    subsystem_device: u16 = 0,
};

fn configAddr(bus: u8, slot: u8, func: u8, off: u8) u32 {
    return 0x8000_0000 |
        (@as(u32, bus) << 16) |
        (@as(u32, slot) << 11) |
        (@as(u32, func) << 8) |
        (off & 0xFC);
}

pub fn read32(bus: u8, slot: u8, func: u8, off: u8) u32 {
    x86.outl(0xCF8, configAddr(bus, slot, func, off));
    return x86.inl(0xCFC);
}

pub fn write32(bus: u8, slot: u8, func: u8, off: u8, value: u32) void {
    x86.outl(0xCF8, configAddr(bus, slot, func, off));
    x86.outl(0xCFC, value);
}

pub fn read16(bus: u8, slot: u8, func: u8, off: u8) u16 {
    const word = off & 0xFE;
    const shift: u5 = @intCast((off - word) * 8);
    return @truncate(read32(bus, slot, func, word) >> shift);
}

pub fn read8(bus: u8, slot: u8, func: u8, off: u8) u8 {
    const dword = off & 0xFC;
    const shift: u5 = @intCast((off - dword) * 8);
    return @truncate(read32(bus, slot, func, dword) >> shift);
}

pub fn write16(bus: u8, slot: u8, func: u8, off: u8, value: u16) void {
    const word = off & 0xFE;
    var v = read32(bus, slot, func, word);
    const mask: u32 = @as(u32, 0xFFFF) << @intCast((off - word) * 8);
    v = (v & ~mask) | (@as(u32, value) << @intCast((off - word) * 8));
    write32(bus, slot, func, word, v);
}

pub fn command(d: Device) u16 {
    return read16(d.bus, d.slot, d.func, 0x04);
}

/// PCI_COMMAND: memory/io space, bus master, and INTx disable.
pub fn enable(d: Device, bits: u16) void {
    write16(d.bus, d.slot, d.func, 0x04, command(d) | bits);
}

pub const BarKind = enum { io, mem32, mem64 };

pub const Bar = struct {
    kind: BarKind,
    base: u64,
};

/// drivers/pci/setup-res.c: decode BAR0 without touching its size.
pub fn bar(d: Device, index: usize) Bar {
    const off: u8 = @intCast(0x10 + index * 4);
    const lo = read32(d.bus, d.slot, d.func, off);
    if (lo & 1 != 0) return .{ .kind = .io, .base = lo & ~@as(u32, 3) };
    const base: u64 = lo & ~@as(u32, 0xF);
    if ((lo >> 1) & 3 == 2) {
        const hi = read32(d.bus, d.slot, d.func, off + 4);
        return .{ .kind = .mem64, .base = (@as(u64, hi) << 32) | base };
    }
    return .{ .kind = .mem32, .base = base };
}

pub fn bar0(d: Device) Bar {
    return bar(d, 0);
}

/// pci_scan_root_bus(): collect devices from buses 0..MAX_BUSES.
pub fn scan(devices: []Device) usize {
    var count: usize = 0;
    var bus: usize = 0;
    while (bus < MAX_BUSES and count < devices.len) : (bus += 1) {
        var slot: usize = 0;
        while (slot < 32 and count < devices.len) : (slot += 1) {
            if (read16(@intCast(bus), @intCast(slot), 0, 0x00) == 0xFFFF) continue;
            const header = read8(@intCast(bus), @intCast(slot), 0, 0x0C);
            const funcs: usize = if (header & 0x80 != 0) 8 else 1;
            var func: usize = 0;
            while (func < funcs and count < devices.len) : (func += 1) {
                const ids = read32(@intCast(bus), @intCast(slot), @intCast(func), 0x00);
                const vendor: u16 = @truncate(ids);
                if (vendor == 0xFFFF or vendor == 0) continue;
                const classes = read32(@intCast(bus), @intCast(slot), @intCast(func), 0x08);
                devices[count] = .{
                    .bus = @intCast(bus),
                    .slot = @intCast(slot),
                    .func = @intCast(func),
                    .vendor = vendor,
                    .device = @truncate(ids >> 16),
                    .class = @truncate(classes >> 24),
                    .subclass = @truncate(classes >> 16),
                    .prog_if = @truncate(classes >> 8),
                    .subsystem_vendor = read16(@intCast(bus), @intCast(slot), @intCast(func), 0x2c),
                    .subsystem_device = read16(@intCast(bus), @intCast(slot), @intCast(func), 0x2e),
                };
                count += 1;
            }
        }
    }
    return count;
}
