//! Read/write virtio-scsi driver for the UEFI kernel (PCI legacy interface).
//! Port of Linux drivers/scsi/virtio_scsi.c and include/linux/virtio_scsi.h:
//! split virtqueues for the control and request queues, SCSI INQUIRY,
//! READ CAPACITY(10), READ(10) and WRITE(10), polling only, block.Device vtable.
//! GPL-2.0-only (derivative work based on Linux algorithms and API).

const std = @import("std");
const block = @import("../../block.zig");
const pci = @import("pci.zig");
const paging = @import("../paging.zig");
const x86 = @import("../x86_64.zig");
const virtio_blk = @import("virtio_blk.zig");

pub const VENDOR_VIRTIO: u16 = 0x1AF4;
pub const DEVICE_SCSI_LEGACY: u16 = 0x1004;

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

const CONTROL_QUEUE: u16 = 0;
const EVENT_QUEUE: u16 = 1;
const REQUEST_QUEUE: u16 = 2; // VIRTIO_SCSI_VQ_BASE

const DESC_NEXT: u16 = 1;
const DESC_WRITE: u16 = 2;

const REQUEST_SIZE: usize = 51; // 8-byte LUN, tag, task_attr/prio/crn, 32-byte CDB
const RESPONSE_SIZE: usize = 108; // sense_len, resid, qualifier, status, response, 96-byte sense
const CONFIG_SENSE_SIZE: u16 = 0x28;
const CONFIG_CDB_SIZE: u16 = 0x2C;
const RESPONSE_MIN: usize = 11; // status at offset 10, virtio response at offset 11
const DATA_SIZE: usize = block.SECTOR_SIZE;

/// Host-only: the request ring address used by the simulated device.
pub var simulated_request_phys: usize = 0;

pub const Bus = virtio_blk.Bus;
pub const portBus = virtio_blk.portBus;
pub const mmioBus = virtio_blk.mmioBus;

fn fence() void {
    asm volatile ("mfence" ::: .{ .memory = true });
}

fn alignUp(value: usize, alignment: usize) usize {
    return (value + alignment - 1) & ~(alignment - 1);
}

pub const QueueLayout = struct {
    queue_size: u16,
    desc: usize,
    avail: usize,
    used: usize,
    request: usize,
    data: usize,
    response: usize,
    total: usize,
};

/// Split virtqueue followed by one SCSI request, data buffer and response.
pub fn queueLayout(queue_size: u16) QueueLayout {
    const desc = 0;
    const desc_bytes = @as(usize, queue_size) * 16;
    const avail = alignUp(desc_bytes, 16);
    const avail_bytes = 4 + @as(usize, queue_size) * 2 + 2;
    const used = alignUp(avail + avail_bytes, 4096);
    const used_bytes = 4 + @as(usize, queue_size) * 8;
    const request = alignUp(used + used_bytes, 16);
    const data = alignUp(request + REQUEST_SIZE, 4);
    const response = alignUp(data + DATA_SIZE, 4);
    return .{
        .queue_size = queue_size,
        .desc = desc,
        .avail = avail,
        .used = used,
        .request = request,
        .data = data,
        .response = response,
        .total = alignUp(response + RESPONSE_SIZE, 16),
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

const Queue = struct {
    ring: []align(4096) u8,
    ring_phys: usize,
    layout: QueueLayout,
    next_avail: u16 = 0,
    last_used: u16 = 0,
};

pub fn isScsiDevice(d: pci.Device) bool {
    if (d.vendor != VENDOR_VIRTIO) return false;
    return d.device == DEVICE_SCSI_LEGACY;
}

pub const Controller = struct {
    allocator: std.mem.Allocator,
    bus: Bus,
    control: Queue,
    event_q: Queue,
    request_q: Queue,
    tag: u64 = 1,
    capacity_sectors: u64,
    device: block.Device,

    fn setDesc(q: *Queue, index: u16, addr: usize, len: usize, flags: u16, next: u16) void {
        const off = q.ring_phys + @as(usize, index) * 16;
        volatileU64(off, 0).* = addr;
        volatileU32(off, 8).* = @intCast(len);
        volatileU16(off, 12).* = flags;
        volatileU16(off, 14).* = next;
    }

    /// drivers/virtio/virtio_ring.c: virtqueue_add() + virtqueue_get_buf().
    fn submit(self: *Controller, q: *Queue, qid: u16, min_write: usize) !usize {
        const slot = q.next_avail % q.layout.queue_size;
        volatileU16(q.ring_phys, q.layout.avail + 4 + @as(usize, slot) * 2).* = 0;
        fence();
        volatileU16(q.ring_phys, q.layout.avail + 2).* = q.next_avail +% 1;
        fence();
        q.next_avail +%= 1;
        self.bus.write16(self.bus.ctx, REG_QUEUE_NOTIFY, qid);

        var guard: usize = 0;
        while (volatileU16(q.ring_phys, q.layout.used + 2).* == q.last_used) {
            x86.pause();
            guard += 1;
            if (guard > 10_000_000) return error.Io;
        }
        const used_slot = q.last_used % q.layout.queue_size;
        const id = volatileU16(q.ring_phys, q.layout.used + 4 + @as(usize, used_slot) * 8).*;
        const len = volatileU32(q.ring_phys, q.layout.used + 8 + @as(usize, used_slot) * 8).*;
        q.last_used +%= 1;
        if (id != 0 or len < min_write) return error.Io;
        return len;
    }

    /// drivers/scsi/virtio_scsi.c: virtio_scsi_execute() for one CDB.
    fn issue(self: *Controller, cdb: []const u8, data_len: usize, data_out: bool) !void {
        const q = &self.request_q;
        const layout = q.layout;
        const req = q.ring_phys + layout.request;
        const resp = q.ring_phys + layout.response;
        @memset(q.ring.ptr[layout.request .. layout.request + REQUEST_SIZE], 0);
        @memset(q.ring.ptr[layout.response .. layout.response + RESPONSE_SIZE], 0);

        // Linux virtio_scsi_init_hdr(): legacy SCSI address [1, id, LUN, 0].
        volatileU8(req, 0).* = 1;
        volatileU8(req, 1).* = 0; // target id
        volatileU8(req, 2).* = 0x40; // LUN high byte
        volatileU8(req, 3).* = 0; // LUN low byte
        // task_attr=SIMPLE, prio=0, crn=0 at offsets 16..18.
        volatileU64(req, 8).* = self.tag;
        for (cdb, 0..) |byte, i| volatileU8(req, 19 + i).* = byte;
        self.tag +%= 1;
        volatileU8(resp, 10).* = 0xff; // SCSI status, zero on success

        // virtio_scsi_execute(): device-readable descriptors precede writable
        // ones, so WRITE(10) places data-out before the response buffer.
        setDesc(q, 0, req, REQUEST_SIZE, DESC_NEXT, 1);
        if (data_out) {
            setDesc(q, 1, q.ring_phys + layout.data, data_len, DESC_NEXT, 2);
            setDesc(q, 2, resp, RESPONSE_SIZE, DESC_WRITE, 0);
        } else {
            setDesc(q, 1, resp, RESPONSE_SIZE, DESC_NEXT | DESC_WRITE, 2);
            setDesc(q, 2, q.ring_phys + layout.data, data_len, DESC_WRITE, 0);
        }
        fence();

        const min_write = if (data_out) RESPONSE_MIN else data_len + RESPONSE_MIN;
        _ = self.submit(q, REQUEST_QUEUE, min_write) catch |e| return e;
        if (volatileU8(resp, 10).* != 0) return error.Io; // SCSI status
        if (volatileU8(resp, 11).* != 0) return error.Io; // virtio response
        if (volatileU32(resp, 4).* != 0) return error.Io; // resid
    }

    fn dataByte(self: *Controller, index: usize) u8 {
        return volatileU8(self.request_q.ring_phys, self.request_q.layout.data + index).*;
    }

    fn setData(self: *Controller, bytes: []const u8) void {
        const base = self.request_q.ring_phys + self.request_q.layout.data;
        for (bytes, 0..) |byte, i| volatileU8(base, i).* = byte;
    }

    fn inquiry(self: *Controller) !void {
        const cdb = [_]u8{ 0x12, 0, 0, 0, 0, 36, 0, 0, 0, 0 };
        try self.issue(&cdb, 36, false);
        if (self.dataByte(0) & 0x1f != 0) return error.Invalid; // direct-access LUN
    }

    fn readCapacity(self: *Controller) !void {
        const cdb = [_]u8{ 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
        var attempt: usize = 0;
        while (true) {
            self.issue(&cdb, 8, false) catch |e| {
                attempt += 1;
                if (e == error.Io and attempt < 4) continue;
                return e;
            };
            break;
        }
        const last_lba = std.mem.readInt(u32, &[_]u8{
            self.dataByte(0), self.dataByte(1), self.dataByte(2), self.dataByte(3),
        }, .big);
        const block_size = std.mem.readInt(u32, &[_]u8{
            self.dataByte(4), self.dataByte(5), self.dataByte(6), self.dataByte(7),
        }, .big);
        if (block_size != block.SECTOR_SIZE) return error.Invalid;
        self.capacity_sectors = @as(u64, last_lba) + 1;
    }

    fn readSectors(self: *Controller, sector: u64, buf: []u8) !void {
        if (buf.len != block.SECTOR_SIZE) return error.Invalid;
        if (sector >= self.capacity_sectors) return error.OutOfRange;
        const cdb = [_]u8{
            0x28,                    0,
            @truncate(sector >> 24), @truncate(sector >> 16),
            @truncate(sector >> 8),  @truncate(sector),
            0,                       0,
            1,                       0,
        };
        try self.issue(&cdb, buf.len, false);
        for (buf, 0..) |*b, i| b.* = self.dataByte(i);
    }

    fn writeSectors(self: *Controller, sector: u64, bytes: []const u8) !void {
        if (bytes.len != block.SECTOR_SIZE) return error.Invalid;
        if (sector >= self.capacity_sectors) return error.OutOfRange;
        self.setData(bytes);
        const cdb = [_]u8{
            0x2A,                    0,
            @truncate(sector >> 24), @truncate(sector >> 16),
            @truncate(sector >> 8),  @truncate(sector),
            0,                       0,
            1,                       0,
        };
        try self.issue(&cdb, bytes.len, true);
    }

    fn opsRead(ctx: ?*anyopaque, sector: u64, buf: []u8) anyerror!void {
        const self: *Controller = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.readSectors(sector, buf);
    }
    fn opsWrite(ctx: ?*anyopaque, sector: u64, bytes: []const u8) anyerror!void {
        const self: *Controller = @ptrCast(@alignCast(ctx orelse return error.Invalid));
        try self.writeSectors(sector, bytes);
    }
    fn opsCapacity(ctx: ?*anyopaque) u64 {
        const self: *const Controller = @ptrCast(@alignCast(ctx orelse return 0));
        return self.capacity_sectors * block.SECTOR_SIZE;
    }

    fn allocQueue(allocator: std.mem.Allocator, queue_size: u16) !Queue {
        const layout = queueLayout(queue_size);
        const ring = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), layout.total);
        errdefer allocator.free(ring);
        @memset(ring, 0);
        return .{ .ring = ring, .ring_phys = @intFromPtr(ring.ptr), .layout = layout };
    }

    /// drivers/virtio/virtio_pci_legacy.c: virtio_pci_legacy_probe().
    pub fn init(allocator: std.mem.Allocator, bus: Bus) !*Controller {
        bus.write8(bus.ctx, REG_STATUS, 0);
        bus.write8(bus.ctx, REG_STATUS, STATUS_ACKNOWLEDGE);
        bus.write8(bus.ctx, REG_STATUS, STATUS_DRIVER);
        bus.write32(bus.ctx, REG_GUEST_FEATURES, 0);
        // Linux virtscsi_init(): pin the config sizes used by the request/response headers.
        bus.write32(bus.ctx, CONFIG_SENSE_SIZE, 96);
        bus.write32(bus.ctx, CONFIG_CDB_SIZE, 32);

        bus.write16(bus.ctx, REG_QUEUE_SEL, CONTROL_QUEUE);
        const control_size = bus.read16(bus.ctx, REG_QUEUE_NUM);
        bus.write16(bus.ctx, REG_QUEUE_SEL, REQUEST_QUEUE);
        const request_size = bus.read16(bus.ctx, REG_QUEUE_NUM);
        if (control_size < 8 or request_size < 8) return error.Invalid;

        bus.write16(bus.ctx, REG_QUEUE_SEL, EVENT_QUEUE);
        const event_size = bus.read16(bus.ctx, REG_QUEUE_NUM);
        if (event_size < 8) return error.Invalid;

        const control = try allocQueue(allocator, control_size);
        errdefer allocator.free(control.ring);
        var event_q = try allocQueue(allocator, event_size);
        errdefer allocator.free(event_q.ring);
        const request_q = try allocQueue(allocator, request_size);
        errdefer allocator.free(request_q.ring);

        // Linux virtscsi_event_node_add(): keep one input buffer posted.
        setDesc(&event_q, 0, event_q.ring_phys + event_q.layout.response, 16, DESC_WRITE, 0);
        volatileU16(event_q.ring_phys, event_q.layout.avail + 4).* = 0;
        fence();
        volatileU16(event_q.ring_phys, event_q.layout.avail + 2).* = 1;
        fence();

        const self = try allocator.create(Controller);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .control = control,
            .event_q = event_q,
            .request_q = request_q,
            .capacity_sectors = 0,
            .device = undefined,
        };
        self.device = .{ .ops = .{
            .ctx = self,
            .read = opsRead,
            .write = opsWrite,
            .capacity = opsCapacity,
        } };

        // PFN is page-granular; the UEFI heap returns identity-mapped pages.
        simulated_request_phys = request_q.ring_phys;
        bus.write16(bus.ctx, REG_QUEUE_SEL, CONTROL_QUEUE);
        bus.write32(bus.ctx, REG_QUEUE_PFN, @truncate(control.ring_phys >> 12));
        bus.write16(bus.ctx, REG_QUEUE_SEL, EVENT_QUEUE);
        bus.write32(bus.ctx, REG_QUEUE_PFN, @truncate(event_q.ring_phys >> 12));
        bus.write16(bus.ctx, REG_QUEUE_SEL, REQUEST_QUEUE);
        bus.write32(bus.ctx, REG_QUEUE_PFN, @truncate(request_q.ring_phys >> 12));
        bus.write8(bus.ctx, REG_STATUS, STATUS_DRIVER_OK);
        bus.write16(bus.ctx, REG_QUEUE_NOTIFY, EVENT_QUEUE);

        try self.inquiry();
        try self.readCapacity();
        return self;
    }

    pub fn deinit(self: *Controller) void {
        self.allocator.free(self.request_q.ring);
        self.allocator.free(self.event_q.ring);
        self.allocator.free(self.control.ring);
        self.allocator.destroy(self);
    }
};

pub fn initFromPci(allocator: std.mem.Allocator, dev: pci.Device) !*Controller {
    if (!isScsiDevice(dev)) return error.Invalid;
    const bar = pci.bar0(dev);
    pci.enable(dev, 0x407);
    switch (bar.kind) {
        .io => return Controller.init(allocator, portBus(@intCast(bar.base))),
        .mem32, .mem64 => {
            paging.mapMmio(@intCast(bar.base), 0x1000);
            return Controller.init(allocator, mmioBus(@intCast(bar.base)));
        },
    }
}

test "virtio-scsi: INQUIRY, READ CAPACITY, WRITE(10) and READ(10) through a simulated BAR" {
    const Fake = struct {
        const capacity: u64 = 16;
        regs: [0x40]u32 = @splat(0),
        storage: [@as(usize, capacity) * block.SECTOR_SIZE]u8 = undefined,
        layout: QueueLayout = queueLayout(8),

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
        }
        fn write16Notify(ctx: ?*anyopaque, off: u16, value: u16) void {
            write16Generic(ctx, off, value);
            if (off == REG_QUEUE_NOTIFY and value == REQUEST_QUEUE) {
                const self: *@This() = @ptrCast(@alignCast(ctx.?));
                self.execute();
            }
        }

        fn volatileSlice(addr: usize, len: usize) []volatile u8 {
            return @as([*]volatile u8, @ptrFromInt(addr))[0..len];
        }

        fn writeU32Be(addr: usize, value: u32) void {
            volatileU8(addr, 0).* = @truncate(value >> 24);
            volatileU8(addr, 1).* = @truncate(value >> 16);
            volatileU8(addr, 2).* = @truncate(value >> 8);
            volatileU8(addr, 3).* = @truncate(value);
        }

        fn execute(self: *@This()) void {
            const ring = simulated_request_phys;
            const layout = self.layout;
            const avail_idx = volatileU16(ring, layout.avail + 2).*;
            if (avail_idx == 0) return;
            const head = volatileU16(ring, layout.avail + 4).*;
            const req_addr: usize = @intCast(volatileU64(ring, head * 16).*);
            const op = volatileU8(req_addr, 19).*;
            const data_out = op == 0x2A;
            const resp_desc: usize = if (data_out) 2 else 1;
            const data_desc: usize = if (data_out) 1 else 2;
            const resp_addr: usize = @intCast(volatileU64(ring, resp_desc * 16).*);
            const data_addr: usize = @intCast(volatileU64(ring, data_desc * 16).*);

            var written: usize = 11;
            switch (op) {
                0x12 => { // INQUIRY
                    volatileU8(data_addr, 0).* = 0; // direct-access block device
                    written += 36;
                },
                0x25 => { // READ CAPACITY(10)
                    writeU32Be(data_addr, @truncate(@as(u64, capacity) - 1));
                    writeU32Be(data_addr + 4, block.SECTOR_SIZE);
                    written += 8;
                },
                0x2A, 0x28 => { // WRITE(10), READ(10)
                    const lba = (@as(u64, volatileU8(req_addr, 21).*) << 24) |
                        (@as(u64, volatileU8(req_addr, 22).*) << 16) |
                        (@as(u64, volatileU8(req_addr, 23).*) << 8) |
                        @as(u64, volatileU8(req_addr, 24).*);
                    const sectors = (@as(usize, volatileU8(req_addr, 26).*) << 8) |
                        @as(usize, volatileU8(req_addr, 27).*);
                    const start: usize = @intCast(lba * block.SECTOR_SIZE);
                    const bytes = sectors * block.SECTOR_SIZE;
                    if (op == 0x2A) {
                        @memcpy(self.storage[start..][0..bytes], volatileSlice(data_addr, bytes));
                    } else {
                        @memcpy(volatileSlice(data_addr, bytes), self.storage[start..][0..bytes]);
                    }
                    written += bytes;
                },
                else => return,
            }
            volatileU8(resp_addr, 10).* = 0; // SCSI GOOD
            volatileU8(resp_addr, 11).* = 0; // VIRTIO_SCSI_S_OK
            volatileU32(resp_addr, 4).* = 0; // resid

            const used = ring + layout.used;
            const used_idx = volatileU16(used, 2).*;
            const slot = used_idx % layout.queue_size;
            volatileU16(used, 4 + @as(usize, slot) * 8).* = head;
            volatileU32(used, 8 + @as(usize, slot) * 8).* = @intCast(written);
            volatileU16(used, 2).* = used_idx +% 1;
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
    var fake = Fake{};
    for (0..Fake.capacity) |lba| {
        for (0..block.SECTOR_SIZE) |i| fake.storage[lba * block.SECTOR_SIZE + i] = @truncate(lba +% i);
    }
    std.mem.writeInt(u16, std.mem.asBytes(&fake.regs[REG_QUEUE_NUM / 4])[0..2], 8, .little);

    const dev = try Controller.init(a, fake.bus());
    defer dev.deinit();
    try std.testing.expectEqual(@as(u64, Fake.capacity * block.SECTOR_SIZE), dev.device.capacity());

    var sector: [block.SECTOR_SIZE]u8 = @splat(0xff);
    try dev.device.ops.read(dev.device.ops.ctx, 3, &sector);
    for (sector, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(3 + i)), b);
    try std.testing.expectError(error.OutOfRange, dev.device.ops.read(dev.device.ops.ctx, Fake.capacity, &sector));

    var pattern: [block.SECTOR_SIZE]u8 = @splat(0x3C);
    try dev.device.ops.write.?(dev.device.ops.ctx, 3, &pattern);
    var written: [block.SECTOR_SIZE]u8 = @splat(0);
    try dev.device.ops.read(dev.device.ops.ctx, 3, &written);
    try std.testing.expectEqualSlices(u8, &pattern, &written);
    try std.testing.expectEqualSlices(u8, &pattern, fake.storage[3 * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE]);
}
