//! virtio-net driver for the UEFI kernel (PCI legacy interface).
//! Port of the Linux virtio_pci/virtio_net algorithms: split virtqueue with
//! separate receive/transmit queues, virtio_net_hdr, MAC feature and
//! polling of the used rings. Feeds the generic net_device in src/netdev.zig.
//! Sources: drivers/net/virtio_net.c, drivers/virtio/virtio_pci_legacy.c,
//! drivers/virtio/virtio_ring.c, include/uapi/linux/virtio_net.h.
//! GPL-2.0-only (derivative work based on Linux algorithms and API).

const std = @import("std");
const pci = @import("pci.zig");
const paging = @import("../paging.zig");
const x86 = @import("../x86_64.zig");
const netdev = @import("../../netdev.zig");
const skb = @import("../../skb.zig");

pub const VENDOR_VIRTIO: u16 = 0x1af4;
pub const DEVICE_NET_LEGACY: u16 = 0x1000;
pub const DEVICE_NET_MODERN: u16 = 0x1040;
pub const VIRTIO_NET_F_MAC: u32 = 1 << 5;

const STATUS_ACKNOWLEDGE: u8 = 1;
const STATUS_DRIVER: u8 = 2;
const STATUS_DRIVER_OK: u8 = 4;

const REG_HOST_FEATURES: u16 = 0x00;
const REG_GUEST_FEATURES: u16 = 0x04;
const REG_QUEUE_PFN: u16 = 0x08;
const REG_QUEUE_NUM: u16 = 0x0c;
const REG_QUEUE_SEL: u16 = 0x0e;
const REG_QUEUE_NOTIFY: u16 = 0x10;
const REG_STATUS: u16 = 0x12;
const CONFIG_MAC: u16 = 0x14;

const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

/// struct virtio_net_hdr: flags, gso_type, hdr_len, gso_size,
/// csum_start, csum_offset. Legacy non-mergeable receive buffers always
/// carry this 10-byte prefix before the Ethernet frame.
pub const HDR_LEN: usize = 10;
pub const MAX_FRAME: usize = 2048;

/// Host-only ring addresses used by the simulated device in host tests.
pub var simulated_ring_phys_rx: usize = 0;
pub var simulated_ring_phys_tx: usize = 0;

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
    return @as(*volatile u8, @ptrFromInt(@intFromPtr(ctx.?) + off)).*;
}
fn mmioOut8(ctx: ?*anyopaque, off: u16, value: u8) void {
    @as(*volatile u8, @ptrFromInt(@intFromPtr(ctx.?) + off)).* = value;
}
fn mmioIn16(ctx: ?*anyopaque, off: u16) u16 {
    return @as(*volatile u16, @ptrFromInt(@intFromPtr(ctx.?) + off)).*;
}
fn mmioOut16(ctx: ?*anyopaque, off: u16, value: u16) void {
    @as(*volatile u16, @ptrFromInt(@intFromPtr(ctx.?) + off)).* = value;
}
fn mmioIn32(ctx: ?*anyopaque, off: u16) u32 {
    return @as(*volatile u32, @ptrFromInt(@intFromPtr(ctx.?) + off)).*;
}
fn mmioOut32(ctx: ?*anyopaque, off: u16, value: u32) void {
    @as(*volatile u32, @ptrFromInt(@intFromPtr(ctx.?) + off)).* = value;
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

pub fn isNetDevice(d: pci.Device) bool {
    if (d.vendor != VENDOR_VIRTIO) return false;
    // QEMU legacy virtio-net is 1af4:1000; virtio-blk is 1af4:1001.
    return d.device == DEVICE_NET_LEGACY or d.device == DEVICE_NET_MODERN;
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
    data: usize,
    total: usize,
};

/// Split virtqueue, followed by the 10-byte virtio_net_hdr and one
/// MAX_FRAME-byte payload buffer. Each queue owns two descriptors.
pub fn ringLayout(queue_size: u16) RingLayout {
    const desc = 0;
    const desc_bytes = @as(usize, queue_size) * 16;
    const avail = alignUp(desc_bytes, 16);
    const avail_bytes = 4 + @as(usize, queue_size) * 2 + 2;
    const used = alignUp(avail + avail_bytes, 4096);
    const used_bytes = 4 + @as(usize, queue_size) * 8;
    const header = alignUp(used + used_bytes, 16);
    const data = header + HDR_LEN;
    return .{
        .queue_size = queue_size,
        .desc = desc,
        .avail = avail,
        .used = used,
        .header = header,
        .data = data,
        .total = alignUp(data + MAX_FRAME, 16),
    };
}

fn volatileU16(base: usize, off: usize) *volatile u16 {
    return @ptrFromInt(base + off);
}
fn volatileU32(base: usize, off: usize) *volatile u32 {
    return @ptrFromInt(base + off);
}

fn setDesc(base: usize, index: usize, addr: usize, len: u32, flags: u16, next: u16) void {
    const off = base + index * 16;
    @as(*volatile u64, @ptrFromInt(off)).* = addr;
    @as(*volatile u32, @ptrFromInt(off + 8)).* = len;
    @as(*volatile u16, @ptrFromInt(off + 12)).* = flags;
    @as(*volatile u16, @ptrFromInt(off + 14)).* = next;
}

fn postAvail(base: usize, layout: RingLayout, slot: u16, index: u16) void {
    volatileU16(base, layout.avail + 4 + @as(usize, slot) * 2).* = index;
    fence();
    volatileU16(base, layout.avail + 2).* = slot +% 1;
    fence();
}

pub const VirtioNet = struct {
    allocator: std.mem.Allocator,
    bus: Bus,
    rx_ring: []align(4096) u8,
    tx_ring: []align(4096) u8,
    rx_phys: usize,
    tx_phys: usize,
    layout: RingLayout,
    mac: [6]u8,
    next_rx: u16 = 0,
    last_rx: u16 = 0,
    next_tx: u16 = 0,
    last_tx: u16 = 0,
    device: netdev.NetDevice,

    fn notify(self: *VirtioNet, queue: u16) void {
        self.bus.write16(self.bus.ctx, REG_QUEUE_NOTIFY, queue);
    }

    fn postRx(self: *VirtioNet) void {
        setDesc(self.rx_phys, 0, self.rx_phys + self.layout.header, HDR_LEN, DESC_WRITE | DESC_NEXT, 1);
        setDesc(self.rx_phys, 1, self.rx_phys + self.layout.data, MAX_FRAME, DESC_WRITE, 0);
        const slot = self.next_rx % self.layout.queue_size;
        postAvail(self.rx_phys, self.layout, slot, 0);
        self.next_rx +%= 1;
        self.notify(0);
    }

    fn opsXmit(ctx: ?*anyopaque, packet: *skb.SkBuff) anyerror!usize {
        const self: *VirtioNet = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.sendFrame(packet.data());
        return packet.len();
    }

    pub fn sendFrame(self: *VirtioNet, frame: []const u8) !void {
        if (frame.len == 0 or frame.len > MAX_FRAME) return error.Invalid;
        const header: [*]volatile u8 = @ptrFromInt(self.tx_phys + self.layout.header);
        var i: usize = 0;
        while (i < HDR_LEN) : (i += 1) header[i] = 0;
        const data: [*]volatile u8 = @ptrFromInt(self.tx_phys + self.layout.data);
        for (frame, 0..) |byte, k| data[k] = byte;
        setDesc(self.tx_phys, 0, self.tx_phys + self.layout.header, HDR_LEN, DESC_NEXT, 1);
        setDesc(self.tx_phys, 1, self.tx_phys + self.layout.data, @intCast(frame.len), 0, 0);
        const slot = self.next_tx % self.layout.queue_size;
        postAvail(self.tx_phys, self.layout, slot, 0);
        self.next_tx +%= 1;
        self.notify(1);

        var guard: usize = 0;
        while (volatileU16(self.tx_phys, self.layout.used + 2).* == self.last_tx) {
            x86.pause();
            guard += 1;
            if (guard > 20_000_000) return error.Io;
        }
        const used_slot = self.last_tx % self.layout.queue_size;
        const id = volatileU16(self.tx_phys, self.layout.used + 4 + @as(usize, used_slot) * 8).*;
        self.last_tx +%= 1;
        if (id != 0) return error.Io;
    }

    /// Возвращает следующий Ethernet-кадр без virtio_net_hdr.
    pub fn recvFrame(self: *VirtioNet, buf: []u8) ![]const u8 {
        if (volatileU16(self.rx_phys, self.layout.used + 2).* == self.last_rx) return error.WouldBlock;
        const used_slot = self.last_rx % self.layout.queue_size;
        const len = volatileU32(self.rx_phys, self.layout.used + 8 + @as(usize, used_slot) * 8).*;
        self.last_rx +%= 1;
        if (len < HDR_LEN or len > HDR_LEN + buf.len) return error.Invalid;
        const frame_len = len - HDR_LEN;
        const src: [*]volatile u8 = @ptrFromInt(self.rx_phys + self.layout.data);
        for (0..frame_len) |i| buf[i] = src[i];
        self.postRx();
        return buf[0..frame_len];
    }

    /// drivers/virtio/virtio_pci_legacy.c:virtio_pci_legacy_probe().
    pub fn init(allocator: std.mem.Allocator, bus: Bus) !*VirtioNet {
        bus.write8(bus.ctx, REG_STATUS, 0);
        bus.write8(bus.ctx, REG_STATUS, STATUS_ACKNOWLEDGE);
        bus.write8(bus.ctx, REG_STATUS, STATUS_DRIVER);
        const host_features = bus.read32(bus.ctx, REG_HOST_FEATURES);
        if (host_features & VIRTIO_NET_F_MAC == 0) return error.NoMac;
        bus.write32(bus.ctx, REG_GUEST_FEATURES, VIRTIO_NET_F_MAC);

        bus.write16(bus.ctx, REG_QUEUE_SEL, 0);
        const queue_size = bus.read16(bus.ctx, REG_QUEUE_NUM);
        if (queue_size < 8) return error.Invalid;
        const layout = ringLayout(queue_size);

        const rx_ring = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), layout.total);
        errdefer allocator.free(rx_ring);
        @memset(rx_ring, 0);
        const tx_ring = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), layout.total);
        errdefer allocator.free(tx_ring);
        @memset(tx_ring, 0);

        const self = try allocator.create(VirtioNet);
        errdefer allocator.destroy(self);
        var mac: [6]u8 = @splat(0);
        for (&mac, 0..) |*byte, i| byte.* = bus.read8(bus.ctx, CONFIG_MAC + @as(u16, @intCast(i)));
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .rx_ring = rx_ring,
            .tx_ring = tx_ring,
            .rx_phys = @intFromPtr(rx_ring.ptr),
            .tx_phys = @intFromPtr(tx_ring.ptr),
            .layout = layout,
            .mac = mac,
            .device = undefined,
        };
        var name: [16]u8 = @splat(0);
        @memcpy(name[0..4], "eth0");
        self.device = .{
            .name = name,
            .name_len = 4,
            .dev_addr = mac,
            .ops = .{ .ctx = self, .start_xmit = opsXmit },
        };

        simulated_ring_phys_rx = self.rx_phys;
        simulated_ring_phys_tx = self.tx_phys;
        // Legacy PFN is page-granular; queues are set up before DRIVER_OK.
        bus.write32(bus.ctx, REG_QUEUE_PFN, @truncate(self.rx_phys >> 12));
        self.postRx();
        bus.write16(bus.ctx, REG_QUEUE_SEL, 1);
        bus.write32(bus.ctx, REG_QUEUE_PFN, @truncate(self.tx_phys >> 12));
        bus.write8(bus.ctx, REG_STATUS, STATUS_DRIVER_OK);
        return self;
    }

    pub fn deinit(self: *VirtioNet) void {
        self.allocator.free(self.rx_ring);
        self.allocator.free(self.tx_ring);
        self.allocator.destroy(self);
    }
};

pub fn initFromPci(allocator: std.mem.Allocator, dev: pci.Device) !*VirtioNet {
    if (!isNetDevice(dev)) return error.Invalid;
    const bar = pci.bar0(dev);
    pci.enable(dev, 0x407);
    switch (bar.kind) {
        .io => return VirtioNet.init(allocator, portBus(@intCast(bar.base))),
        .mem32, .mem64 => {
            paging.mapMmio(@intCast(bar.base), 0x1000);
            return VirtioNet.init(allocator, mmioBus(@intCast(bar.base)));
        },
    }
}

test "virtio-net: legacy PCI negotiation and split ring transmit/receive" {
    const Fake = struct {
        regs: [0x40]u32 = @splat(0),
        queue_sel: u16 = 0,
        queue_phys: [2]usize = .{ 0, 0 },
        guest_features: u32 = 0,
        tx_captured: [MAX_FRAME]u8 = @splat(0),
        tx_len: usize = 0,
        rx_pending: bool = false,

        fn read8(ctx: ?*anyopaque, off: u16) u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u8 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            return p.*;
        }
        fn write8(ctx: ?*anyopaque, off: u16, value: u8) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const p: *volatile u8 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            p.* = value;
            if (off == REG_STATUS and value == STATUS_ACKNOWLEDGE) {
                // VIRTIO_NET_F_MAC, and six bytes of MAC in config space.
                self.regs[REG_HOST_FEATURES / 4] = VIRTIO_NET_F_MAC;
                for (0..6) |i| {
                    const bp: *volatile u8 = @ptrFromInt(@intFromPtr(&self.regs) + CONFIG_MAC + i);
                    bp.* = @intCast(0x52 + i);
                }
            }
        }
        fn read16(ctx: ?*anyopaque, off: u16) u16 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (off == REG_QUEUE_NUM) return 8;
            if (off == REG_QUEUE_SEL) return self.queue_sel;
            const p: *volatile u16 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            return p.*;
        }
        fn write16(ctx: ?*anyopaque, off: u16, value: u16) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (off == REG_QUEUE_SEL) {
                self.queue_sel = value;
                return;
            }
            if (off == REG_QUEUE_NOTIFY) {
                self.notify(value);
                return;
            }
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
            if (off == REG_QUEUE_PFN) {
                // Host pointers may exceed 32 bits; use the full simulated ring
                // address instead of the truncated legacy PFN.
                self.queue_phys[self.queue_sel] = if (self.queue_sel == 0)
                    simulated_ring_phys_rx
                else
                    simulated_ring_phys_tx;
            }
            if (off == REG_GUEST_FEATURES) self.guest_features = value;
            const p: *volatile u32 = @ptrFromInt(@intFromPtr(&self.regs) + off);
            p.* = value;
        }

        fn notify(self: *@This(), queue: u16) void {
            const phys = self.queue_phys[queue];
            const layout = ringLayout(8);
            if (queue == 1) {
                const head = volatileU16(phys, layout.avail + 4).*;
                const off = phys + @as(usize, head) * 16;
                const addr: usize = @intCast(@as(*volatile u64, @ptrFromInt(off + 16)).*);
                const data_len = volatileU32(phys, @as(usize, head) * 16 + 16 + 8).*;
                const src: [*]volatile u8 = @ptrFromInt(addr);
                for (0..data_len) |i| self.tx_captured[i] = src[i];
                self.tx_len = data_len;
                volatileU16(phys, layout.used + 4).* = head;
                volatileU16(phys, layout.used + 2).* +%= 1;
            } else if (self.rx_pending) {
                const head = volatileU16(phys, layout.avail + 4).*;
                const off = phys + @as(usize, head) * 16 + 16;
                const addr: usize = @intCast(@as(*volatile u64, @ptrFromInt(off)).*);
                const frame = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 1, 2, 3, 4, 5, 6, 0x08, 0x00, 0xaa };
                const dst: [*]volatile u8 = @ptrFromInt(addr);
                for (frame, 0..) |b, i| dst[i] = b;
                volatileU32(phys, layout.used + 8).* = HDR_LEN + frame.len;
                volatileU16(phys, layout.used + 4).* = head;
                volatileU16(phys, layout.used + 2).* +%= 1;
                self.rx_pending = false;
            }
        }
    };

    const a = std.testing.allocator;
    var fake = Fake{};
    const bus = Bus{
        .ctx = &fake,
        .read8 = Fake.read8,
        .write8 = Fake.write8,
        .read16 = Fake.read16,
        .write16 = Fake.write16,
        .read32 = Fake.read32,
        .write32 = Fake.write32,
    };
    const nic = try VirtioNet.init(a, bus);
    defer nic.deinit();
    try std.testing.expectEqual(VIRTIO_NET_F_MAC, fake.guest_features);
    try std.testing.expectEqual([6]u8{ 0x52, 0x53, 0x54, 0x55, 0x56, 0x57 }, nic.mac);

    const frame = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10 };
    nic.device.flags = netdev.IFF_UP | netdev.IFF_RUNNING;
    const packet = try skb.SkBuff.alloc(a, 64, 0);
    defer packet.free();
    _ = try packet.put(&frame);
    _ = try netdev.devQueueXmit(&nic.device, packet);
    try std.testing.expectEqual(@as(usize, frame.len), fake.tx_len);
    try std.testing.expectEqualSlices(u8, &frame, fake.tx_captured[0..fake.tx_len]);
    try std.testing.expectEqual(@as(usize, 1), nic.device.stats.tx_packets);

    fake.rx_pending = true;
    nic.notify(0);
    var buf: [MAX_FRAME]u8 = @splat(0);
    const received = try nic.recvFrame(&buf);
    try std.testing.expectEqual(@as(usize, 15), received.len);
    try std.testing.expectEqual(@as(u8, 0xaa), received[14]);
    try std.testing.expect(simulated_ring_phys_rx != 0);
}
