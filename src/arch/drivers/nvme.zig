//! Read/write NVMe PCIe driver for the UEFI kernel: one admin queue and one
//! I/O queue, polling doorbells, no MSI-X. Port of Linux
//! drivers/nvme/host/{pci,core}.c and include/linux/nvme.h algorithms.
//! GPL-2.0-only (derivative work based on Linux algorithms and API).

const std = @import("std");
const block = @import("../../block.zig");
const pci = @import("pci.zig");
const paging = @import("../paging.zig");
const x86 = @import("../x86_64.zig");

pub const DEPTH: usize = 64;
const BOUNCE_SIZE: usize = 8192;

const REG_CAP: usize = 0x00;
const REG_CC: usize = 0x14;
const REG_CSTS: usize = 0x1C;
const REG_AQA: usize = 0x24;
const REG_ASQ: usize = 0x28;
const REG_ACQ: usize = 0x30;
const DOORBELL_BASE: usize = 0x1000;

const CC_ENABLE: u32 = 1;
const CC_IOSQES: u32 = 6 << 16;
const CC_IOCQES: u32 = 4 << 20;
const CSTS_READY: u32 = 1;

const OPC_DELETE_SQ: u32 = 0x00;
const OPC_CREATE_SQ: u32 = 0x01;
const OPC_WRITE: u32 = 0x01;
const OPC_READ: u32 = 0x02;
const OPC_DELETE_CQ: u32 = 0x04;
const OPC_CREATE_CQ: u32 = 0x05;
const OPC_IDENTIFY: u32 = 0x06;

const QUEUE_PHYS_CONTIG: u32 = 1;

/// MMIO transport. The fake device used by host tests implements the same
/// read32/write32 contract as the PCIe BAR.
pub const Bus = struct {
    ctx: ?*anyopaque,
    read32: *const fn (?*anyopaque, usize) u32,
    write32: *const fn (?*anyopaque, usize, u32) void,
};

fn mmioRead32(ctx: ?*anyopaque, off: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    return p.*;
}
fn mmioWrite32(ctx: ?*anyopaque, off: usize, value: u32) void {
    const p: *volatile u32 = @ptrFromInt(@intFromPtr(ctx.?) + off);
    p.* = value;
}

pub fn mmioBus(base: usize) Bus {
    return .{
        .ctx = @ptrFromInt(base),
        .read32 = mmioRead32,
        .write32 = mmioWrite32,
    };
}

pub fn isNvme(d: pci.Device) bool {
    return d.class == 0x01 and d.subclass == 0x08 and d.prog_if == 0x02;
}

const Command = struct {
    opcode: u32,
    nsid: u32 = 0,
    prp1: u64 = 0,
    prp2: u64 = 0,
    cdw10: u32 = 0,
    cdw11: u32 = 0,
    cdw12: u32 = 0,
};

const Queue = struct {
    sq: [*]volatile u32,
    cq: [*]volatile u16,
    qid: u16,
    tail: u16 = 0,
    head: u16 = 0,
    phase: u16 = 1,
};

pub const Controller = struct {
    allocator: std.mem.Allocator,
    bus: Bus,
    stride: usize,
    admin: Queue,
    admin_sq_mem: []align(4096) u8,
    admin_cq_mem: []align(4096) u8,
    io: Queue,
    identify_buf: []align(4096) u8,
    sq_mem: []align(4096) u8,
    cq_mem: []align(4096) u8,
    bounce: []align(4096) u8,
    sector_size: u64,
    capacity_sectors: u64,
    next_cid: u16 = 1,
    device: block.Device,

    fn write64(self: *Controller, off: usize, value: u64) void {
        self.bus.write32(self.bus.ctx, off, @truncate(value));
        self.bus.write32(self.bus.ctx, off + 4, @truncate(value >> 32));
    }

    fn waitReady(self: *Controller, want: u32) !void {
        var guard: usize = 0;
        while ((self.bus.read32(self.bus.ctx, REG_CSTS) & CSTS_READY) != want) {
            x86.pause();
            guard += 1;
            if (guard > 20_000_000) return error.Io;
        }
    }

    /// include/linux/nvme.h: struct nvme_common_command + CQE phase rules.
    fn submit(self: *Controller, q: *Queue, cmd: Command) !u32 {
        const slot = @as(usize, q.tail % DEPTH) * 16;
        const sq = q.sq[slot..][0..16];
        const cid = self.next_cid;
        self.next_cid +%= 1;
        sq[0] = (cmd.opcode & 0xff) | (@as(u32, cid) << 16);
        sq[1] = cmd.nsid;
        sq[2] = 0;
        sq[3] = 0;
        sq[4] = 0;
        sq[5] = 0;
        sq[6] = @truncate(cmd.prp1);
        sq[7] = @truncate(cmd.prp1 >> 32);
        sq[8] = @truncate(cmd.prp2);
        sq[9] = @truncate(cmd.prp2 >> 32);
        sq[10] = cmd.cdw10;
        sq[11] = cmd.cdw11;
        sq[12] = cmd.cdw12;
        sq[13] = 0;
        sq[14] = 0;
        sq[15] = 0;
        q.tail +%= 1;
        asm volatile ("" ::: .{ .memory = true });
        self.bus.write32(self.bus.ctx, DOORBELL_BASE + 2 * @as(usize, q.qid) * self.stride, @intCast(q.tail % DEPTH));

        var guard: usize = 0;
        while (true) {
            const cq = q.cq[@as(usize, q.head) * 8 ..][0..8];
            const status = cq[7];
            if ((status & 1) == q.phase) {
                if (cq[6] != cid or (status >> 1) != 0) return error.Io;
                q.head +%= 1;
                if (q.head == DEPTH) {
                    q.head = 0;
                    q.phase ^= 1;
                }
                self.bus.write32(self.bus.ctx, DOORBELL_BASE + (2 * @as(usize, q.qid) + 1) * self.stride, q.head);
                return cq[0];
            }
            x86.pause();
            guard += 1;
            if (guard > 20_000_000) return error.Io;
        }
    }

    fn identify(self: *Controller, cns: u32, nsid: u32) !void {
        const phys = @intFromPtr(self.identify_buf.ptr);
        _ = try self.submit(&self.admin, .{
            .opcode = OPC_IDENTIFY,
            .nsid = nsid,
            .prp1 = phys,
            .cdw10 = cns,
        });
    }

    fn createIoQueues(self: *Controller) !void {
        _ = try self.submit(&self.admin, .{
            .opcode = OPC_CREATE_CQ,
            .prp1 = @intFromPtr(self.cq_mem.ptr),
            .cdw10 = ((DEPTH - 1) << 16) | 1,
            .cdw11 = QUEUE_PHYS_CONTIG,
        });
        _ = try self.submit(&self.admin, .{
            .opcode = OPC_CREATE_SQ,
            .prp1 = @intFromPtr(self.sq_mem.ptr),
            .cdw10 = ((DEPTH - 1) << 16) | 1,
            .cdw11 = (1 << 16) | QUEUE_PHYS_CONTIG,
        });
    }

    fn ioLba(self: *Controller, opcode: u32, lba: u64, count: u64) !void {
        if (count == 0 or count > BOUNCE_SIZE / self.sector_size) return error.Invalid;
        const phys = @intFromPtr(self.bounce.ptr);
        _ = try self.submit(&self.io, .{
            .opcode = opcode,
            .nsid = 1,
            .prp1 = phys,
            .prp2 = if (count * self.sector_size > 4096) phys + 4096 else 0,
            .cdw10 = @truncate(lba),
            .cdw11 = @truncate(lba >> 32),
            .cdw12 = @intCast(count - 1),
        });
    }

    fn readLba(self: *Controller, lba: u64, count: u64) !void {
        try self.ioLba(OPC_READ, lba, count);
    }

    fn writeLba(self: *Controller, lba: u64, count: u64) !void {
        try self.ioLba(OPC_WRITE, lba, count);
    }

    fn readSectors(self: *Controller, sector: u64, buf: []u8) !void {
        if (buf.len != block.SECTOR_SIZE) return error.Invalid;
        if (sector >= self.capacity_sectors) return error.OutOfRange;
        const per_lba = self.sector_size / block.SECTOR_SIZE;
        const lba = sector / per_lba;
        try self.readLba(lba, 1);
        const off: usize = @intCast((sector % per_lba) * block.SECTOR_SIZE);
        @memcpy(buf, self.bounce[off .. off + block.SECTOR_SIZE]);
    }

    fn writeSectors(self: *Controller, sector: u64, bytes: []const u8) !void {
        if (bytes.len != block.SECTOR_SIZE) return error.Invalid;
        if (sector >= self.capacity_sectors) return error.OutOfRange;
        const per_lba = self.sector_size / block.SECTOR_SIZE;
        const lba = sector / per_lba;
        const off: usize = @intCast((sector % per_lba) * block.SECTOR_SIZE);
        // 512-byte block.Device sectors may share one larger NVMe LBA.
        if (per_lba > 1) try self.readLba(lba, 1);
        @memcpy(self.bounce[off .. off + block.SECTOR_SIZE], bytes);
        try self.writeLba(lba, 1);
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

    /// drivers/nvme/host/core.c: nvme_enable_ctrl() + nvme_identify_ns().
    pub fn init(allocator: std.mem.Allocator, bus: Bus) !*Controller {
        const cap_hi = bus.read32(bus.ctx, REG_CAP + 4);
        const dstrd: u6 = @intCast(cap_hi & 0xF);
        const stride = @as(usize, 4) << dstrd;
        if (stride > 64) return error.Invalid;
        // CAP.MPSMIN is an exponent relative to 4 KiB; MPSMIN != 0 needs
        // larger host pages than this minimal kernel supports.
        if ((cap_hi >> 16) & 0xF != 0) return error.Invalid;

        bus.write32(bus.ctx, REG_CC, 0);
        const reset = try allocator.create(Controller);
        errdefer allocator.destroy(reset);
        reset.* = .{
            .allocator = allocator,
            .bus = bus,
            .stride = stride,
            .admin = undefined,
            .admin_sq_mem = undefined,
            .admin_cq_mem = undefined,
            .io = undefined,
            .identify_buf = undefined,
            .sq_mem = undefined,
            .cq_mem = undefined,
            .bounce = undefined,
            .sector_size = 512,
            .capacity_sectors = 0,
            .device = undefined,
        };
        try reset.waitReady(0);

        const asq = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
        errdefer allocator.free(asq);
        const acq = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
        errdefer allocator.free(acq);
        @memset(asq, 0);
        @memset(acq, 0);
        reset.admin_sq_mem = asq;
        reset.admin_cq_mem = acq;
        reset.admin = .{
            .sq = @ptrCast(@alignCast(asq.ptr)),
            .cq = @ptrCast(@alignCast(acq.ptr)),
            .qid = 0,
        };

        bus.write32(bus.ctx, REG_AQA, ((DEPTH - 1) << 16) | (DEPTH - 1));
        reset.write64(REG_ASQ, @intFromPtr(asq.ptr));
        reset.write64(REG_ACQ, @intFromPtr(acq.ptr));
        bus.write32(bus.ctx, REG_CC, CC_IOSQES | CC_IOCQES | CC_ENABLE);
        try reset.waitReady(CSTS_READY);

        reset.identify_buf = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
        errdefer allocator.free(reset.identify_buf);
        @memset(reset.identify_buf, 0);
        try reset.identify(1, 0); // Identify Controller
        try reset.identify(0, 1); // Identify Namespace 1

        var nsze: u64 = 0;
        for (0..8) |i| nsze |= @as(u64, reset.identify_buf[i]) << @intCast(8 * i);
        const lbaf: usize = reset.identify_buf[26] & 0xF;
        if (lbaf >= 64) return error.Invalid;
        const ds = reset.identify_buf[128 + lbaf * 4 + 2];
        if (ds < 9 or ds > 12) return error.Invalid;
        reset.sector_size = @as(u64, 1) << @intCast(ds);
        reset.capacity_sectors = nsze * (@as(u64, 1) << @intCast(ds - 9));
        if (reset.capacity_sectors == 0) return error.Invalid;

        reset.sq_mem = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
        errdefer allocator.free(reset.sq_mem);
        reset.cq_mem = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
        errdefer allocator.free(reset.cq_mem);
        @memset(reset.sq_mem, 0);
        @memset(reset.cq_mem, 0);
        try reset.createIoQueues();
        reset.io = .{
            .sq = @ptrCast(@alignCast(reset.sq_mem.ptr)),
            .cq = @ptrCast(@alignCast(reset.cq_mem.ptr)),
            .qid = 1,
        };

        reset.bounce = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), BOUNCE_SIZE);
        errdefer allocator.free(reset.bounce);
        @memset(reset.bounce, 0);
        reset.device = .{ .ops = .{
            .ctx = reset,
            .read = opsRead,
            .write = opsWrite,
            .capacity = opsCapacity,
        } };
        return reset;
    }

    pub fn deinit(self: *Controller) void {
        _ = self.submit(&self.admin, .{ .opcode = OPC_DELETE_SQ, .cdw10 = 1 }) catch {};
        _ = self.submit(&self.admin, .{ .opcode = OPC_DELETE_CQ, .cdw10 = 1 }) catch {};
        self.allocator.free(self.bounce);
        self.allocator.free(self.admin_cq_mem);
        self.allocator.free(self.admin_sq_mem);
        self.allocator.free(self.cq_mem);
        self.allocator.free(self.sq_mem);
        self.allocator.free(self.identify_buf);
        self.allocator.destroy(self);
    }
};

pub fn initFromPci(allocator: std.mem.Allocator, dev: pci.Device) !*Controller {
    if (!isNvme(dev)) return error.Invalid;
    const bar = pci.bar0(dev);
    if (bar.kind == .io) return error.Invalid;
    // Memory space, bus master and INTx disable: the driver polls doorbells.
    pci.enable(dev, 0x406);
    paging.mapMmio(@intCast(bar.base), 0x4000);
    return Controller.init(allocator, mmioBus(@intCast(bar.base)));
}

test "nvme: admin identify, I/O queues, write and read through a simulated BAR" {
    const Fake = struct {
        const nsze: u64 = 32;
        regs: [0x2000]u32 = @splat(0),
        admin_sq: usize = 0,
        admin_sq_hi: u32 = 0,
        admin_cq: usize = 0,
        admin_cq_hi: u32 = 0,
        io_sq: usize = 0,
        io_cq: usize = 0,
        admin_tail: u16 = 0,
        io_tail: u16 = 0,
        admin_head: u16 = 0,
        io_head: u16 = 0,
        phase: u16 = 1,
        storage: [@as(usize, nsze) * block.SECTOR_SIZE]u8 = undefined,

        fn sqe(base: usize, tail: u16) []volatile u32 {
            return @as([*]volatile u32, @ptrFromInt(base))[@as(usize, tail % DEPTH) * 16 ..][0..16];
        }
        fn cqe(base: usize, head: u16) []volatile u16 {
            return @as([*]volatile u16, @ptrFromInt(base))[@as(usize, head % DEPTH) * 8 ..][0..8];
        }
        fn post(self: *@This(), base: usize, head_ptr: *u16, result: u32, cid: u16) void {
            const c = cqe(base, head_ptr.*);
            c[0] = @truncate(result);
            c[6] = cid;
            c[7] = self.phase; // generic status 0, phase in bit 0
            head_ptr.* +%= 1;
            if (head_ptr.* == DEPTH) {
                head_ptr.* = 0;
                self.phase ^= 1;
            }
        }
        fn read32(ctx: ?*anyopaque, off: usize) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (off < DOORBELL_BASE) return self.regs[off / 4];
            return 0;
        }
        fn write32(ctx: ?*anyopaque, off: usize, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            if (off < DOORBELL_BASE) {
                self.regs[off / 4] = value;
                if (off == REG_CC) {
                    if (value & CC_ENABLE != 0) self.regs[REG_CSTS / 4] |= CSTS_READY else self.regs[REG_CSTS / 4] &= ~CSTS_READY;
                } else if (off == REG_ASQ) {
                    self.admin_sq = value;
                } else if (off == REG_ASQ + 4) {
                    self.admin_sq_hi = value;
                } else if (off == REG_ACQ) {
                    self.admin_cq = value;
                } else if (off == REG_ACQ + 4) {
                    self.admin_cq_hi = value;
                }
                return;
            }
            if (off == DOORBELL_BASE) {
                self.admin_tail = @truncate(value);
                self.handleAdmin();
            } else if (off == DOORBELL_BASE + 4) {
                self.admin_head = @truncate(value);
            } else if (off == DOORBELL_BASE + 8) {
                self.io_tail = @truncate(value);
                self.handleIo();
            } else if (off == DOORBELL_BASE + 12) {
                self.io_head = @truncate(value);
            }
        }
        fn handleAdmin(self: *@This()) void {
            const sq_base = self.admin_sq | (@as(usize, self.admin_sq_hi) << 32);
            const cq_base = self.admin_cq | (@as(usize, self.admin_cq_hi) << 32);
            const c = sqe(sq_base, self.admin_tail -% 1);
            switch (c[0] & 0xff) {
                OPC_CREATE_CQ => self.io_cq = @intCast(@as(u64, c[6]) | (@as(u64, c[7]) << 32)),
                OPC_CREATE_SQ => self.io_sq = @intCast(@as(u64, c[6]) | (@as(u64, c[7]) << 32)),
                OPC_IDENTIFY => {
                    const buf: [*]u8 = @ptrFromInt(@as(usize, c[6]) | (@as(usize, c[7]) << 32));
                    if (c[10] == 0) {
                        for (0..8) |i| buf[i] = @truncate(nsze >> @intCast(8 * i));
                        buf[26] = 0;
                        buf[128 + 2] = 9; // LBA format 0: 512-byte sectors
                    } else {
                        @memcpy(buf[24..33], "fake nvme");
                    }
                },
                else => {},
            }
            self.post(cq_base, &self.admin_head, 0, @truncate(c[0] >> 16));
        }
        fn handleIo(self: *@This()) void {
            const c = sqe(self.io_sq, self.io_tail -% 1);
            const op = c[0] & 0xff;
            const lba = @as(u64, c[10]) | (@as(u64, c[11]) << 32);
            const p1: usize = @intCast(@as(u64, c[6]) | (@as(u64, c[7]) << 32));
            const bytes: usize = (@as(usize, c[12]) + 1) * block.SECTOR_SIZE;
            const start: usize = @intCast(lba * block.SECTOR_SIZE);
            var i: usize = 0;
            while (i < bytes) : (i += 1) {
                const buf: *volatile u8 = @ptrFromInt(p1 + i);
                if (op == OPC_WRITE) {
                    self.storage[start + i] = buf.*;
                } else {
                    buf.* = self.storage[start + i];
                }
            }
            self.post(self.io_cq, &self.io_head, 0, @truncate(c[0] >> 16));
        }
    };

    var fake = Fake{};
    for (0..Fake.nsze) |lba| {
        for (0..block.SECTOR_SIZE) |i| fake.storage[lba * block.SECTOR_SIZE + i] = @truncate(lba +% i);
    }
    fake.regs[0] = 0x7ff; // MQES
    fake.regs[4] = 0; // DSTRD = 0, MPSMIN = 0
    const bus = Bus{ .ctx = &fake, .read32 = Fake.read32, .write32 = Fake.write32 };
    const a = std.testing.allocator;
    const ctrl = try Controller.init(a, bus);
    defer ctrl.deinit();

    try std.testing.expectEqual(@as(u64, 512), ctrl.sector_size);
    try std.testing.expectEqual(@as(u64, Fake.nsze), ctrl.capacity_sectors);

    var buf: [block.SECTOR_SIZE]u8 = @splat(0xff);
    try ctrl.device.ops.read(ctrl.device.ops.ctx, 7, &buf);
    for (buf, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(7 + i)), b);
    try std.testing.expectError(error.OutOfRange, ctrl.device.ops.read(ctrl.device.ops.ctx, Fake.nsze, &buf));

    var pattern: [block.SECTOR_SIZE]u8 = @splat(0xA5);
    try ctrl.device.ops.write.?(ctrl.device.ops.ctx, 7, &pattern);
    var written: [block.SECTOR_SIZE]u8 = @splat(0);
    try ctrl.device.ops.read(ctrl.device.ops.ctx, 7, &written);
    try std.testing.expectEqualSlices(u8, &pattern, &written);
    try std.testing.expectEqualSlices(u8, &pattern, fake.storage[7 * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE]);
}
