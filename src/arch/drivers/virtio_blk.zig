//! Read/write virtio-blk driver for the UEFI kernel (PCI legacy interface).
//! Port of the Linux virtio_pci/virtio_blk algorithms: split virtqueue,
//! descriptor chain header/data/status, polling the used ring, and a
//! block.Device vtable consumed by the existing partition/FS writeback.
//! Sources: include/linux/virtio_blk.h, drivers/block/virtio_blk.c,
//! drivers/virtio/virtio_pci_legacy.c, drivers/virtio/virtio_ring.c.
//! GPL-2.0-only (derivative work based on Linux algorithms and API).

const std = @import("std");
const block = @import("../../block.zig");
const pci = @import("pci.zig");
const paging = @import("../paging.zig");
const x86 = @import("../x86_64.zig");

pub const VENDOR_VIRTIO: u16 = 0x1AF4;
pub const DEVICE_BLK_LEGACY: u16 = 0x1001;
pub const DEVICE_BLK_MODERN: u16 = 0x1042;

const STATUS_ACKNOWLEDGE: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;

const REG_HOST_FEATURES: u16 = 0x00;
const REG_GUEST_FEATURES: u16 = 0x04;
const REG_QUEUE_PFN: u16 = 0x08;
const REG_QUEUE_NUM: u16 = 0x0C;
const REG_QUEUE_SEL: u16 = 0x0E;
const REG_QUEUE_NOTIFY: u16 = 0x10;
const REG_STATUS: u16 = 0x12;
const CONFIG_CAPACITY: u16 = 0x14;

/// Host-only: the ring address used by the simulated device when the real
/// pointer does not fit into the 32-bit legacy PFN register.
pub var simulated_ring_phys: usize = 0;

const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

/// include/uapi/linux/virtio_blk.h: struct virtio_blk_outhdr vr_type.
const VIRTIO_BLK_T_IN: u32 = 0;
const VIRTIO_BLK_T_OUT: u32 = 1;

/// Transport register access. Port and MMIO backends share the same offsets.
pub const Bus = struct {
    ctx: ?*anyopaque,
    read8: *const fn (?*anyopaque, u16) u8,
    write8: *const fn (?*anyopaque, u16, u8) void,
    read16: *const fn (?*anyopaque, u16) u16,
    write16: *const fn (?*anyopaque, u16, u16) void,
    read32: *const fn (?*anyopaque, u16) u32,
    write32: *const fn (?*anyopaque, u16, u32) void,
};

fn portBase(ctx: ?*anyopaque) u16 {
    return @intCast(@intFromPtr(ctx.?));
}

fn portIn8(ctx: ?*anyopaque, off: u16) u8 {
    return x86.inb(portBase(ctx) + off);
}
fn portOut8(ctx: ?*anyopaque, off: u16, value: u8) void {
    x86.outb(portBase(ctx) + off, value);
}
fn portIn16(ctx: ?*anyopaque, off: u16) u16 {
    return x86.inw(portBase(ctx) + off);
}
fn portOut16(ctx: ?*anyopaque, off: u16, value: u16) void {
    x86.outw(portBase(ctx) + off, value);
}
fn portIn32(ctx: ?*anyopaque, off: u16) u32 {
    return x86.inl(portBase(ctx) + off);
}
fn portOut32(ctx: ?*anyopaque, off: u16, value: u32) void {
    x86.outl(portBase(ctx) + off, value);
}

pub fn portBus(base: u16) Bus {
    return .{
        .ctx = @ptrFromInt(base),
        .read8 = portIn8,
        .write8 = portOut8,
        .read16 = portIn16,
        .write16 = portOut16,
        .read32 = portIn32,
        .write32 = portOut32,
    };
}

fn mmioIn8(ctx: ?*anyopaque, off: u16) u8 {
    const p: *volatile u8 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    return p.*;
}
fn mmioOut8(ctx: ?*anyopaque, off: u16, value: u8) void {
    const p: *volatile u8 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    p.* = value;
}
fn mmioIn16(ctx: ?*anyopaque, off: u16) u16 {
    const p: *volatile u16 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    return p.*;
}
fn mmioOut16(ctx: ?*anyopaque, off: u16, value: u16) void {
    const p: *volatile u16 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    p.* = value;
}
fn mmioIn32(ctx: ?*anyopaque, off: u16) u32 {
    const p: *volatile u32 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    return p.*;
}
fn mmioOut32(ctx: ?*anyopaque, off: u16, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    p.* = value;
}

pub fn mmioBus(base: usize) Bus {
    return .{
        .ctx = @ptrFromInt(base),
        .read8 = mmioIn8,
        .write8 = mmioOut8,
        .read16 = mmioIn16,
        .write16 = mmioOut16,
        .read32 = mmioIn32,
        .write32 = mmioOut32,
    };
}

pub fn isBlockDevice(d: pci.Device) bool {
    if (d.vendor != VENDOR_VIRTIO) return false;
    return d.device == DEVICE_BLK_LEGACY or d.device == DEVICE_BLK_MODERN;
}

fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

pub const RingLayout = struct {
    queue_size: u16,
    desc: usize,
    avail: usize,
    used: usize,
    header: usize,
    status: usize,
    total: usize,
};

/// Split virtqueue layout: descriptor table, available ring, used ring,
/// then the 16-byte block request header and one status byte.
pub fn ringLayout(queue_size: u16) RingLayout {
    const desc = 0;
    const desc_bytes = @as(usize, queue_size) * 16;
    const avail = alignUp(desc_bytes, 16);
    // Linux vring_init(): the used ring starts at the next 4096-byte
    // boundary after the available ring (including its used_event slot).
    const avail_bytes = 4 + @as(usize, queue_size) * 2 + 2;
    const used = alignUp(avail + avail_bytes, 4096);
    const used_bytes = 4 + @as(usize, queue_size) * 8;
    const header = alignUp(used + used_bytes, 16);
    const status = header + 16;
    return .{
        .queue_size = queue_size,
        .desc = desc,
        .avail = avail,
        .used = used,
        .header = header,
        .status = status,
        .total = alignUp(status + 1, 16),
    };
}

fn volatileU8(base: usize, off: usize) *volatile u8 {
    return @ptrFromInt(base + off);
}
fn volatileU16(base: usize, off: usize) *volatile u16 {
    return @ptrFromInt(base + off);
}
fn volatileU32(base: usize, off: usize) *volatile u32 {
    return @ptrFromInt(base + off);
}
fn volatileU64(base: usize, off: usize) *volatile u64 {
    return @ptrFromInt(base + off);
}

pub const VirtioBlk = struct {
    allocator: std.mem.Allocator,
    bus: Bus,
    ring: []align(4096) u8,
    ring_phys: usize,
    layout: RingLayout,
    capacity_sectors: u64,
    next_avail: u16 = 0,
    last_used: u16 = 0,
    device: block.Device,

    fn setDesc(self: *VirtioBlk, index: u16, addr: usize, len: u32, flags: u16, next: u16) void {
        const off = self.ring_phys + @as(usize, index) * 16;
        volatileU64(off, 0).* = addr;
        volatileU32(off, 8).* = len;
        volatileU16(off, 12).* = flags;
        volatileU16(off, 14).* = next;
    }

    /// struct virtio_blk_outhdr: type,reserved,sector + data + status.
    /// При OUT дескриптор данных доступен устройству на чтение (без DESC_WRITE),
    /// status всегда доступен на запись.
    fn submitSector(self: *VirtioBlk, sector: u64, buf: []const u8, out: bool) !void {
        if (buf.len != block.SECTOR_SIZE) return error.Invalid;
        if (sector >= self.capacity_sectors) return error.OutOfRange;

        volatileU32(self.ring_phys, self.layout.header).* = if (out) VIRTIO_BLK_T_OUT else VIRTIO_BLK_T_IN;
        volatileU32(self.ring_phys, self.layout.header + 4).* = 0;
        volatileU64(self.ring_phys, self.layout.header + 8).* = sector;

        const base = self.ring_phys;
        const data_flags: u16 = if (out) DESC_NEXT else DESC_NEXT | DESC_WRITE;
        self.setDesc(0, base + self.layout.header, 16, DESC_NEXT, 1);
        self.setDesc(1, @intFromPtr(buf.ptr), @intCast(buf.len), data_flags, 2);
        self.setDesc(2, base + self.layout.status, 1, DESC_WRITE, 0);
        volatileU8(base, self.layout.status).* = 0xFF;

        const slot = self.next_avail % self.layout.queue_size;
        volatileU16(base, self.layout.avail + 4 + @as(usize, slot) * 2).* = 0;
        fence();
        volatileU16(base, self.layout.avail + 2).* = self.next_avail +% 1;
        fence();
        self.next_avail +%= 1;
        self.bus.write16(self.bus.ctx, REG_QUEUE_NOTIFY, 0);
        var guard: usize = 0;
        while (volatileU16(base, self.layout.used + 2).* == self.last_used) {
            x86.pause();
            guard += 1;
            if (guard > 10_000_000) return error.Io;
        }
        const used_slot = self.last_used % self.layout.queue_size;
        const id = volatileU16(base, self.layout.used + 4 + @as(usize, used_slot) * 8).*;
        const len = volatileU32(base, self.layout.used + 8 + @as(usize, used_slot) * 8).*;
        const min_len: u32 = if (out) 1 else @as(u32, @intCast(buf.len)) + 1;
        self.last_used +%= 1;
        if (id != 0 or len < min_len) return error.Io;
        if (volatileU8(base, self.layout.status).* != 0) return error.Io;
    }

    fn readSector(self: *VirtioBlk, sector: u64, buf: []u8) !void {
        try self.submitSector(sector, buf, false);
    }

    fn writeSector(self: *VirtioBlk, sector: u64, bytes: []const u8) !void {
        try self.submitSector(sector, bytes, true);
    }

    fn opsRead(ctx: ?*anyopaque, sector: u64, buf: []u8) anyerror!void {
        const self: *VirtioBlk = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.readSector(sector, buf);
    }

    fn opsWrite(ctx: ?*anyopaque, sector: u64, bytes: []const u8) anyerror!void {
        const self: *VirtioBlk = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.writeSector(sector, bytes);
    }

    fn opsCapacity(ctx: ?*anyopaque) u64 {
        const self: *const VirtioBlk = @ptrCast(@alignCast(ctx orelse return 0));
        return self.capacity_sectors * block.SECTOR_SIZE;
    }

    /// drivers/virtio/virtio_pci_legacy.c: virtio_pci_legacy_probe().
    pub fn init(allocator: std.mem.Allocator, bus: Bus) !*VirtioBlk {
        bus.write8(bus.ctx, REG_STATUS, 0);
        bus.write8(bus.ctx, REG_STATUS, STATUS_ACKNOWLEDGE);
        bus.write8(bus.ctx, REG_STATUS, STATUS_DRIVER);
        _ = bus.read32(bus.ctx, REG_HOST_FEATURES);
        bus.write32(bus.ctx, REG_GUEST_FEATURES, 0);

        bus.write16(bus.ctx, REG_QUEUE_SEL, 0);
        const max_queue = bus.read16(bus.ctx, REG_QUEUE_NUM);
        if (max_queue < 8) return error.Invalid;

        // Legacy virtio has no VIRTIO_PCI_QUEUE_NUM_WRITE: the device owns
        // the ring size, so use the full advertised queue length.
        const layout = ringLayout(max_queue);
        // PFN is page-granular: the ring base itself must be 4096-aligned.
        const ring = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), layout.total);
        errdefer allocator.free(ring);
        @memset(ring, 0);

        const self = try allocator.create(VirtioBlk);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .ring = ring,
            .ring_phys = @intFromPtr(ring.ptr),
            .layout = layout,
            .capacity_sectors = 0,
            .device = undefined,
        };
        self.device = .{ .ops = .{
            .ctx = self,
            .read = opsRead,
            .write = opsWrite,
            .capacity = opsCapacity,
        } };

        // PFN is the physical address of the split virtqueue; the kernel heap
        // returns identity-mapped physical pages in the UEFI build.
        simulated_ring_phys = self.ring_phys;
        bus.write32(bus.ctx, REG_QUEUE_PFN, @truncate(self.ring_phys >> 12));
        bus.write8(bus.ctx, REG_STATUS, STATUS_DRIVER_OK);

        const lo = bus.read32(bus.ctx, CONFIG_CAPACITY);
        const hi = bus.read32(bus.ctx, CONFIG_CAPACITY + 4);
        self.capacity_sectors = @as(u64, lo) | (@as(u64, hi) << 32);
        return self;
    }

    pub fn deinit(self: *VirtioBlk) void {
        self.allocator.free(self.ring);
        self.allocator.destroy(self);
    }
};

pub fn initFromPci(allocator: std.mem.Allocator, dev: pci.Device) !*VirtioBlk {
    if (!isBlockDevice(dev)) return error.Invalid;
    const bar = pci.bar0(dev);
    // PCI_COMMAND: io+mem, bus master, disable INTx (polling driver).
    pci.enable(dev, 0x407);
    switch (bar.kind) {
        .io => return VirtioBlk.init(allocator, portBus(@intCast(bar.base))),
        .mem32, .mem64 => {
            paging.mapMmio(@intCast(bar.base), 0x1000);
            return VirtioBlk.init(allocator, mmioBus(@intCast(bar.base)));
        },
    }
}

test "virtio-blk: split virtqueue reads and writes sectors through a simulated BAR" {
    const Fake = struct {
        const capacity: u64 = 16;
        regs: [0x40]u32 = @splat(0),
        data: [capacity][block.SECTOR_SIZE]u8 = undefined,
        queue_pfn: usize = 0,
        layout: RingLayout = ringLayout(8),

        fn build(seed: u8) @This() {
            var f = @This(){};
            for (0..capacity) |sector| {
                @memset(&f.data[sector], seed +% @as(u8, @intCast(sector)));
            }
            return f;
        }

        fn read8(ctx: ?*anyopaque, off: u16) u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u8 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            return p.*;
        }
        fn write8(ctx: ?*anyopaque, off: u16, value: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u8 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            p.* = value;
        }
        fn read16(ctx: ?*anyopaque, off: u16) u16 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u16 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            return p.*;
        }
        fn write16Generic(ctx: ?*anyopaque, off: u16, value: u16) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u16 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            p.* = value;
        }
        fn read32(ctx: ?*anyopaque, off: u16) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u32 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            return p.*;
        }
        fn write32(ctx: ?*anyopaque, off: u16, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u32 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            p.* = value;
            if (off == REG_QUEUE_PFN) self.queue_pfn = @as(usize, value) << 12;
        }
        fn write16Notify(ctx: ?*anyopaque, off: u16, value: u16) void {
            write16Generic(ctx, off, value);
            if (off == REG_QUEUE_NOTIFY) {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                self.notify();
            }
        }

        /// Minimal device model: consume one available descriptor chain,
        /// fill the writable data buffer, post one used-ring entry.
        fn notify(self: *@This()) void {
            const ring = simulated_ring_phys;
            const layout = self.layout;
            const avail_idx = @as(*volatile u16, @ptrFromInt(ring + layout.avail + 2)).*;
            if (avail_idx == 0) return;
            const head = @as(*volatile u16, @ptrFromInt(ring + layout.avail + 4)).*;
            var desc = head;
            var sector: u64 = 0;
            var request_type: u32 = 0;
            var data_addr: usize = 0;
            var data_len: u32 = 0;
            var status_addr: usize = 0;
            var steps: usize = 0;
            while (steps < 8) : (steps += 1) {
                const off = ring + @as(usize, desc) * 16;
                const addr = @as(*volatile u64, @ptrFromInt(off)).*;
                const len = @as(*volatile u32, @ptrFromInt(off + 8)).*;
                const flags = @as(*volatile u16, @ptrFromInt(off + 12)).*;
                const next = @as(*volatile u16, @ptrFromInt(off + 14)).*;
                if (desc == 0) {
                    request_type = @as(*volatile u32, @ptrFromInt(@as(usize, @intCast(addr)))).*;
                    sector = @as(*volatile u64, @ptrFromInt(@as(usize, @intCast(addr)) + 8)).*;
                } else if (flags & DESC_WRITE != 0 and len == 1) {
                    status_addr = @intCast(addr);
                } else {
                    data_addr = @intCast(addr);
                    data_len = len;
                }
                if (flags & DESC_NEXT == 0) break;
                desc = next;
            }
            if (request_type == VIRTIO_BLK_T_OUT) {
                const src: [*]const volatile u8 = @ptrFromInt(data_addr);
                for (0..data_len) |i| self.data[@intCast(sector)][i] = src[i];
            } else {
                const dst: [*]volatile u8 = @ptrFromInt(data_addr);
                for (0..data_len) |i| dst[i] = self.data[@intCast(sector)][i];
            }
            @as(*volatile u8, @ptrFromInt(status_addr)).* = 0;
            const used = ring + layout.used;
            const used_idx = @as(*volatile u16, @ptrFromInt(used + 2)).*;
            const slot = used_idx % layout.queue_size;
            @as(*volatile u16, @ptrFromInt(used + 4 + @as(usize, slot) * 8)).* = head;
            @as(*volatile u32, @ptrFromInt(used + 8 + @as(usize, slot) * 8)).* = data_len + 1;
            @as(*volatile u16, @ptrFromInt(used + 2)).* = used_idx +% 1;
        }

        fn bus(self: *@This()) Bus {
            return .{
                .ctx = self,
                .read8 = read8,
                .write8 = write8,
                .read16 = read16,
                .write16 = write16Notify,
                .read32 = read32,
                .write32 = write32,
            };
        }
    };

    const a = std.testing.allocator;
    var fake = Fake.build(0x42);
    std.mem.writeInt(u16, std.mem.asBytes(&fake.regs[REG_QUEUE_NUM / 4])[0..2], 8, .little);
    std.mem.writeInt(u32, std.mem.asBytes(&fake.regs[CONFIG_CAPACITY / 4]), @truncate(Fake.capacity), .little);
    std.mem.writeInt(u32, std.mem.asBytes(&fake.regs[(CONFIG_CAPACITY + 4) / 4]), @truncate(Fake.capacity >> 32), .little);

    var dev = try VirtioBlk.init(a, fake.bus());
    defer dev.deinit();

    var sector: [block.SECTOR_SIZE]u8 = @splat(0);
    try dev.device.read(3 * block.SECTOR_SIZE, &sector);
    for (sector) |b| try std.testing.expectEqual(0x42 + 3, b);

    var unaligned: [7]u8 = @splat(0);
    try dev.device.read(5 * block.SECTOR_SIZE + 2, &unaligned);
    for (unaligned) |b| try std.testing.expectEqual(0x42 + 5, b);

    var pattern: [block.SECTOR_SIZE]u8 = @splat(0xA5);
    try dev.device.write(3 * block.SECTOR_SIZE, &pattern);
    try std.testing.expectEqualSlices(u8, &pattern, &fake.data[3]);
    var written: [block.SECTOR_SIZE]u8 = @splat(0);
    try dev.device.read(3 * block.SECTOR_SIZE, &written);
    try std.testing.expectEqualSlices(u8, &pattern, &written);
    try std.testing.expectEqual(Fake.capacity * block.SECTOR_SIZE, dev.device.capacity());
}
