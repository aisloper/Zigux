//! Read/write AHCI driver for the UEFI kernel: polling one command slot,
//! ATA READ/WRITE DMA EXT (LBA48) and IDENTIFY. Port of Linux drivers/ata/ahci.c,
//! libahci.c and libata-sata.c algorithms.
//! GPL-2.0-only (derivative work based on Linux algorithms and API).

const std = @import("std");
const block = @import("../../block.zig");
const pci = @import("pci.zig");
const paging = @import("../paging.zig");
const x86 = @import("../x86_64.zig");

const HBA_CAP: usize = 0x00;
const HBA_GHC: usize = 0x04;
const HBA_IS: usize = 0x08;
const HBA_PI: usize = 0x0c;
const PORT_STRIDE: usize = 0x80;
const PORT_BASE: usize = 0x100;

const P_CLB: usize = 0x00;
const P_CLBU: usize = 0x04;
const P_FB: usize = 0x08;
const P_FBU: usize = 0x0c;
const P_IS: usize = 0x10;
const P_SERR: usize = 0x30;
const P_CMD: usize = 0x18;
const P_TFD: usize = 0x20;
const P_SSTS: usize = 0x28;
const P_CI: usize = 0x38;

const GHC_AE: u32 = 1 << 31;
const CMD_FIS_RX: u32 = 1 << 4;
const CMD_POWER: u32 = 1 << 2;
const CMD_SPIN_UP: u32 = 1 << 1;
const CMD_START: u32 = 1 << 0;

const ATA_IDENTIFY: u8 = 0xEC;
const ATA_READ_DMA_EXT: u8 = 0x25;
const ATA_WRITE_DMA_EXT: u8 = 0x35;
const CMD_HDR_W: u32 = 1 << 5;
const ATA_BUSY: u8 = 0x80;
const ATA_ERR: u8 = 0x01;
const ATA_DF: u8 = 0x20;

const TABLE_SIZE: usize = 0x80 + 16;
const DATA_SIZE: usize = 4096;

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
    return .{ .ctx = @ptrFromInt(base), .read32 = mmioRead32, .write32 = mmioWrite32 };
}

pub fn isAhci(d: pci.Device) bool {
    return d.class == 0x01 and d.subclass == 0x06 and d.prog_if == 0x01;
}

pub const Controller = struct {
    allocator: std.mem.Allocator,
    bus: Bus,
    port: usize,
    cmd_list: []align(4096) u8,
    table: []align(4096) u8,
    fis: []align(4096) u8,
    data: []align(4096) u8,
    capacity_sectors: u64,
    device: block.Device,

    fn portReg(self: *Controller, off: usize) usize {
        return PORT_BASE + self.port * PORT_STRIDE + off;
    }
    fn read(self: *Controller, off: usize) u32 {
        return self.bus.read32(self.bus.ctx, off);
    }
    fn write(self: *Controller, off: usize, value: u32) void {
        self.bus.write32(self.bus.ctx, off, value);
    }
    fn write64(self: *Controller, off: usize, value: u64) void {
        self.write(self.portReg(off), @truncate(value));
        self.write(self.portReg(off + 4), @truncate(value >> 32));
    }

    fn waitNotBusy(self: *Controller) !void {
        var guard: usize = 0;
        while (self.read(self.portReg(P_TFD)) & ATA_BUSY != 0) {
            x86.pause();
            guard += 1;
            if (guard > 20_000_000) return error.Io;
        }
    }

    /// libahci.c: ahci_fill_cmd_slot() + ahci_fill_sg() + polled command.
    fn issue(self: *Controller, fis_cmd: u8, lba: u64, sectors: u16) !void {
        try self.waitNotBusy();
        const is_write = fis_cmd == ATA_WRITE_DMA_EXT;
        const table = self.table.ptr;
        const cfis = table[0..20];
        @memset(cfis, 0);
        cfis[0] = 0x27; // H2D register FIS
        cfis[1] = 0x80; // command FIS
        cfis[2] = fis_cmd;
        cfis[3] = 0;
        if (fis_cmd == ATA_READ_DMA_EXT or is_write) {
            cfis[4] = @truncate(lba);
            cfis[5] = @truncate(lba >> 8);
            cfis[6] = @truncate(lba >> 16);
            cfis[7] = 0x40; // LBA, no slave
            cfis[8] = @truncate(lba >> 24);
            cfis[9] = @truncate(lba >> 32);
            cfis[10] = @truncate(lba >> 40);
            cfis[11] = 0;
            cfis[12] = @truncate(sectors);
            cfis[13] = @truncate(sectors >> 8);
        } else {
            cfis[4] = @truncate(sectors);
            cfis[7] = 0;
        }
        cfis[14] = 0;
        cfis[15] = 0;

        @memset(table[0x80..TABLE_SIZE], 0);
        const prd = table[0x80..][0..16];
        std.mem.writeInt(u64, prd[0..8], @intFromPtr(self.data.ptr), .little);
        std.mem.writeInt(u32, prd[8..12], 0, .little);
        std.mem.writeInt(u32, prd[12..16], @as(u32, @intCast(sectors * block.SECTOR_SIZE)) - 1, .little);

        const hdr = self.cmd_list.ptr[0..32];
        @memset(hdr, 0);
        // CFL=5 dwords, PRDTL=1; AHCI command-header W bit for writes.
        const opts: u32 = 5 | (1 << 16) | (if (is_write) CMD_HDR_W else 0);
        std.mem.writeInt(u32, hdr[0..4], opts, .little);
        std.mem.writeInt(u32, hdr[4..8], 0, .little);
        std.mem.writeInt(u64, hdr[8..16], @intFromPtr(self.table.ptr), .little);

        asm volatile ("" ::: .{ .memory = true });
        self.write(self.portReg(P_CI), 1);
        var guard: usize = 0;
        while (self.read(self.portReg(P_CI)) & 1 != 0) {
            x86.pause();
            guard += 1;
            if (guard > 20_000_000) return error.Io;
        }
        const status: u8 = @truncate(self.read(self.portReg(P_TFD)));
        if (status == 0xff or status & ATA_BUSY != 0 or status & (ATA_ERR | ATA_DF) != 0) return error.Io;
    }

    fn identify(self: *Controller) !void {
        try self.issue(ATA_IDENTIFY, 0, 1);
        const w = struct {
            fn at(buf: []u8, index: usize) u16 {
                return std.mem.readInt(u16, buf[index * 2 ..][0..2], .little);
            }
        }.at;
        const lba28 = @as(u64, w(self.data, 60)) | (@as(u64, w(self.data, 61)) << 16);
        const lba48 = @as(u64, w(self.data, 100)) |
            (@as(u64, w(self.data, 101)) << 16) |
            (@as(u64, w(self.data, 102)) << 32) |
            (@as(u64, w(self.data, 103)) << 48);
        self.capacity_sectors = if (lba48 != 0) lba48 else lba28;
        if (self.capacity_sectors == 0) return error.Invalid;
    }

    fn readSectors(self: *Controller, sector: u64, buf: []u8) !void {
        if (buf.len != block.SECTOR_SIZE) return error.Invalid;
        if (sector >= self.capacity_sectors) return error.OutOfRange;
        try self.issue(ATA_READ_DMA_EXT, sector, 1);
        @memcpy(buf, self.data[0..block.SECTOR_SIZE]);
    }

    fn writeSectors(self: *Controller, sector: u64, bytes: []const u8) !void {
        if (bytes.len != block.SECTOR_SIZE) return error.Invalid;
        if (sector >= self.capacity_sectors) return error.OutOfRange;
        @memcpy(self.data[0..block.SECTOR_SIZE], bytes);
        try self.issue(ATA_WRITE_DMA_EXT, sector, 1);
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

    /// libahci.c: ahci_reset_controller() + ahci_port_start() without interrupts.
    pub fn init(allocator: std.mem.Allocator, bus: Bus) !*Controller {
        bus.write32(bus.ctx, HBA_GHC, GHC_AE);
        if (bus.read32(bus.ctx, HBA_GHC) & GHC_AE == 0) return error.Invalid;
        const ports = bus.read32(bus.ctx, HBA_PI);
        if (ports == 0) return error.Invalid;

        const self = try allocator.create(Controller);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .bus = bus,
            .port = 0,
            .cmd_list = undefined,
            .table = undefined,
            .fis = undefined,
            .data = undefined,
            .capacity_sectors = 0,
            .device = undefined,
        };

        var found = false;
        for (0..32) |p| {
            if (ports & (@as(u32, 1) << @intCast(p)) == 0) continue;
            self.port = p;
            // PxSSTS.DET: device present and PHY ready.
            // QEMU reports DET=3 (device present, PHY ready) for an attached disk.
            const det = bus.read32(bus.ctx, PORT_BASE + p * PORT_STRIDE + P_SSTS) & 0xF;
            if (det == 0 or det == 0xF) continue;
            found = true;
            break;
        }
        if (!found) return error.Invalid;

        self.cmd_list = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 1024);
        errdefer allocator.free(self.cmd_list);
        self.table = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 4096);
        errdefer allocator.free(self.table);
        self.fis = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), 256);
        errdefer allocator.free(self.fis);
        self.data = try allocator.alignedAlloc(u8, std.mem.Alignment.fromByteUnits(4096), DATA_SIZE);
        errdefer allocator.free(self.data);
        @memset(self.cmd_list, 0);
        @memset(self.table, 0);
        @memset(self.fis, 0);
        @memset(self.data, 0);

        // Clear stale port/HBA status (W1C registers).
        for ([_]usize{ P_SERR, P_IS }) |off| {
            const v = bus.read32(bus.ctx, self.portReg(off));
            bus.write32(bus.ctx, self.portReg(off), v);
        }
        bus.write32(bus.ctx, HBA_IS, @as(u32, 1) << @intCast(self.port));

        self.write64(P_CLB, @intFromPtr(self.cmd_list.ptr));
        self.write64(P_FB, @intFromPtr(self.fis.ptr));
        const cmd = CMD_POWER | CMD_SPIN_UP | CMD_FIS_RX | CMD_START;
        self.write(self.portReg(P_CMD), self.read(self.portReg(P_CMD)) | cmd);
        if (self.read(self.portReg(P_CMD)) & cmd != cmd) return error.Io;
        try self.waitNotBusy();
        try self.identify();

        self.device = .{ .ops = .{
            .ctx = self,
            .read = opsRead,
            .write = opsWrite,
            .capacity = opsCapacity,
        } };
        return self;
    }

    pub fn deinit(self: *Controller) void {
        self.write(self.portReg(P_CMD), self.read(self.portReg(P_CMD)) & ~CMD_START);
        self.allocator.free(self.data);
        self.allocator.free(self.fis);
        self.allocator.free(self.table);
        self.allocator.free(self.cmd_list);
        self.allocator.destroy(self);
    }
};

pub fn initFromPci(allocator: std.mem.Allocator, dev: pci.Device) !*Controller {
    if (!isAhci(dev)) return error.Invalid;
    const bar = pci.bar(dev, 5);
    if (bar.kind == .io or bar.base == 0) return error.Invalid;
    pci.enable(dev, 0x406);
    paging.mapMmio(@intCast(bar.base), 0x1000);
    return Controller.init(allocator, mmioBus(@intCast(bar.base)));
}

test "ahci: IDENTIFY, WRITE DMA EXT and READ DMA EXT through a simulated BAR" {
    const Fake = struct {
        const capacity: u64 = 16;
        regs: [0x400]u32 = @splat(0),
        storage: [@as(usize, capacity) * block.SECTOR_SIZE]u8 = undefined,
        clb: usize = 0,
        clb_hi: u32 = 0,
        fb: usize = 0,
        fb_hi: u32 = 0,

        fn init(self: *@This()) void {
            self.regs[HBA_PI / 4] = 1;
            self.regs[(PORT_BASE + P_SSTS) / 4] = 1;
        }
        fn read32(ctx: ?*anyopaque, off: usize) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            return self.regs[off / 4];
        }
        fn write32(ctx: ?*anyopaque, off: usize, value: u32) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.regs[off / 4] = value;
            if (off == PORT_BASE + P_CLB) {
                self.clb = value;
            } else if (off == PORT_BASE + P_CLB + 4) {
                self.clb_hi = value;
            } else if (off == PORT_BASE + P_FB) {
                self.fb = value;
            } else if (off == PORT_BASE + P_FB + 4) {
                self.fb_hi = value;
            } else if (off == PORT_BASE + P_CI and value & 1 != 0) {
                self.execute();
                self.regs[(PORT_BASE + P_CI) / 4] = 0;
                self.regs[(PORT_BASE + P_TFD) / 4] = 0x40;
            }
        }
        fn execute(self: *@This()) void {
            const hdr: [*]u8 = @ptrFromInt(self.clb | (@as(usize, self.clb_hi) << 32));
            const table_addr = std.mem.readInt(u64, hdr[8..16], .little);
            const table: [*]u8 = @ptrFromInt(@as(usize, @intCast(table_addr)));
            const cmd = table[2];
            const prd = table[0x80..][0..16];
            const data_addr: usize = @intCast(std.mem.readInt(u64, prd[0..8], .little));
            if (cmd == ATA_IDENTIFY) {
                const buf: [*]u8 = @ptrFromInt(data_addr);
                std.mem.writeInt(u16, buf[120..122], @truncate(@This().capacity), .little);
                std.mem.writeInt(u16, buf[122..124], @truncate(@This().capacity >> 16), .little);
            } else {
                const lba = @as(u64, table[4]) |
                    (@as(u64, table[5]) << 8) |
                    (@as(u64, table[6]) << 16) |
                    (@as(u64, table[8]) << 24) |
                    (@as(u64, table[9]) << 32) |
                    (@as(u64, table[10]) << 40);
                const buf: [*]u8 = @ptrFromInt(data_addr);
                const start: usize = @intCast(lba * block.SECTOR_SIZE);
                const opts = std.mem.readInt(u32, hdr[0..4], .little);
                if (opts & CMD_HDR_W != 0) {
                    @memcpy(self.storage[start..][0..block.SECTOR_SIZE], buf[0..block.SECTOR_SIZE]);
                } else {
                    @memcpy(buf[0..block.SECTOR_SIZE], self.storage[start..][0..block.SECTOR_SIZE]);
                }
            }
        }
    };

    var fake = Fake{};
    for (0..Fake.capacity) |lba| {
        for (0..block.SECTOR_SIZE) |i| fake.storage[lba * block.SECTOR_SIZE + i] = @truncate(lba +% i);
    }
    fake.init();
    const bus = Bus{ .ctx = &fake, .read32 = Fake.read32, .write32 = Fake.write32 };
    const a = std.testing.allocator;
    const ctrl = try Controller.init(a, bus);
    defer ctrl.deinit();

    try std.testing.expectEqual(@as(u64, Fake.capacity), ctrl.capacity_sectors);
    var buf: [block.SECTOR_SIZE]u8 = @splat(0xff);
    try ctrl.device.ops.read(ctrl.device.ops.ctx, 3, &buf);
    for (buf, 0..) |b, i| try std.testing.expectEqual(@as(u8, @truncate(3 + i)), b);
    try std.testing.expectError(error.OutOfRange, ctrl.device.ops.read(ctrl.device.ops.ctx, Fake.capacity, &buf));

    var pattern: [block.SECTOR_SIZE]u8 = @splat(0x5A);
    try ctrl.device.ops.write.?(ctrl.device.ops.ctx, 3, &pattern);
    var written: [block.SECTOR_SIZE]u8 = @splat(0);
    try ctrl.device.ops.read(ctrl.device.ops.ctx, 3, &written);
    try std.testing.expectEqualSlices(u8, &pattern, &written);
    try std.testing.expectEqualSlices(u8, &pattern, fake.storage[3 * block.SECTOR_SIZE ..][0..block.SECTOR_SIZE]);
}
