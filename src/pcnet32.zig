//! Порт драйвера AMD PCnet32 (Linux 7.3): определение доступа к CSR,
//! decode chipcode, инициализационный блок, кольца RX/TX, NAPI-маски
//! и последовательность reset/start/stop. Источник:
//! drivers/net/ethernet/amd/pcnet32.c. GPL-2.0-only (алгоритмы и константы).

const std = @import("std");

pub const Access = enum { wio, dwio };
pub const CSR_INIT: u16 = 0x0001;
pub const CSR_START: u16 = 0x0002;
pub const CSR_STOP: u16 = 0x0004;
pub const CSR_TXPOLL: u16 = 0x0008;
pub const CSR_INTEN: u16 = 0x0040;
pub const CSR_IDON: u16 = 0x0100;
pub const CSR_NORMAL: u16 = CSR_START | CSR_INTEN;
pub const CSR_KICK: u16 = CSR_INTEN | CSR_TXPOLL;
pub const CSR_LOW_MASK: u16 = 0x004f;
pub const CSR3_MASK: u16 = 0x5f00;
pub const OWN: u16 = 0x8000;
pub const TX_STATUS: u16 = 0x8300;
pub const RX_OK: u8 = 0x03;
pub const RX_SIZE: usize = 32;
pub const TX_SIZE: usize = 16;
pub const PKT_BUF_SKB: usize = 1544;
pub const NET_IP_ALIGN: usize = 2;
pub const PKT_BUF_SIZE: usize = PKT_BUF_SKB - NET_IP_ALIGN;
pub const RX_COPYBREAK: usize = 200;
pub const MAX_INTERRUPT_WORK: u8 = 2;
pub const BCR20_32BIT: u16 = 2;
pub const BCR20_16BIT: u16 = 4;
pub const NEG_BUF_SIZE: u16 = @bitCast(@as(i16, -1542)); // NET_IP_ALIGN - PKT_BUF_SKB

/// Имитация портов ввода-вывода: CSR/BCR адресуются через RAP, запись в
/// RDP/BDP выбирает нужный регистр. Reset читается как порт.
pub const FakeIo = struct {
    mode: Access = .wio,
    wio_bad: bool = false,
    dwio_bad: bool = false,
    csr: [128]u16 = std.mem.zeroes([128]u16),
    bcr: [128]u16 = std.mem.zeroes([128]u16),
    rap: u16 = 0,
    reset_reads: usize = 0,
    rap_reads: usize = 0,

    pub fn in16(self: *FakeIo, port: u16) u16 {
        const off: u16 = port & 0xff;
        if (off == 0x10) return self.csr[self.rap & 127];
        if (self.mode == .wio) {
            if (off == 0x12) {
                self.rap_reads += 1;
                return if (self.wio_bad) 0 else self.rap;
            }
            if (off == 0x14) {
                self.reset_reads += 1;
                return 0;
            }
            if (off == 0x16) return self.bcr[self.rap & 127];
        } else {
            if (off == 0x14) {
                self.rap_reads += 1;
                return if (self.dwio_bad) 0 else self.rap & 0xffff;
            }
            if (off == 0x18) {
                self.reset_reads += 1;
                return 0;
            }
            if (off == 0x1c) return self.bcr[self.rap & 127];
        }
        return 0;
    }

    pub fn out16(self: *FakeIo, port: u16, value: u16) void {
        const off: u16 = port & 0xff;
        if (self.mode == .wio) {
            if (off == 0x12) self.rap = value;
            if (off == 0x10) self.csr[self.rap & 127] = value;
            if (off == 0x16) self.bcr[self.rap & 127] = value;
        } else {
            if (off == 0x14) self.rap = value;
            if (off == 0x10) self.csr[self.rap & 127] = value;
            if (off == 0x1c) self.bcr[self.rap & 127] = value;
        }
    }
};

pub const ChipIo = struct {
    access: Access = .wio,

    fn rdp(_: ChipIo) u16 {
        return 0x10;
    }
    fn rap(self: ChipIo) u16 {
        return if (self.access == .wio) 0x12 else 0x14;
    }
    fn resetPort(self: ChipIo) u16 {
        return if (self.access == .wio) 0x14 else 0x18;
    }
    fn bdp(self: ChipIo) u16 {
        return if (self.access == .wio) 0x16 else 0x1c;
    }

    pub fn reset(self: ChipIo, io: *FakeIo, base: u16) void {
        _ = io.in16(base + self.resetPort());
    }
    pub fn select(self: ChipIo, io: *FakeIo, base: u16, reg: u16) void {
        io.out16(base + self.rap(), reg);
    }
    pub fn readCsr(self: ChipIo, io: *FakeIo, base: u16, reg: u16) u16 {
        self.select(io, base, reg);
        return io.in16(base + self.rdp());
    }
    pub fn writeCsr(self: ChipIo, io: *FakeIo, base: u16, reg: u16, value: u16) void {
        self.select(io, base, reg);
        io.out16(base + self.rdp(), value);
    }
    pub fn readBcr(self: ChipIo, io: *FakeIo, base: u16, reg: u16) u16 {
        self.select(io, base, reg);
        return io.in16(base + self.bdp());
    }
    pub fn writeBcr(self: ChipIo, io: *FakeIo, base: u16, reg: u16, value: u16) void {
        self.select(io, base, reg);
        io.out16(base + self.bdp(), value);
    }
};

/// 16-битный доступ проверяется первым (старые чипы), DWIO — запасной.
pub fn detectAccess(io: *FakeIo, base: u16) !ChipIo {
    var chip = ChipIo{ .access = .wio };
    io.mode = .wio;
    chip.reset(io, base);
    chip.writeCsr(io, base, 0, CSR_STOP);
    chip.select(io, base, 88);
    if (io.in16(base + chip.rap()) == 88) return chip;

    chip.access = .dwio;
    io.mode = .dwio;
    chip.reset(io, base);
    chip.writeCsr(io, base, 0, CSR_STOP);
    chip.select(io, base, 88);
    if ((io.in16(base + chip.rap()) & 0xffff) == 88) return chip;
    return error.NoAccess;
}

pub const ChipInfo = struct {
    code: u16,
    fdx: bool = false,
    mii: bool = false,
    fset: bool = false,
    sram: bool = false,
};

pub fn decodeChip(raw: u32) !ChipInfo {
    if ((raw & 0xfff) != 0x003) return error.BadChipId;
    const code: u16 = @truncate((raw >> 12) & 0xffff);
    return switch (code) {
        0x2420 => .{ .code = code },
        0x2430 => .{ .code = code },
        0x2621 => .{ .code = code, .fdx = true },
        0x2623, 0x2624 => .{ .code = code, .fdx = true, .mii = true, .fset = true },
        0x2625, 0x2627 => .{ .code = code, .fdx = true, .mii = true, .sram = true },
        0x2626, 0x2628 => .{ .code = code },
        else => error.UnknownChip,
    };
}

fn validMac(mac: [6]u8) bool {
    var nonzero = false;
    var all_ones = true;
    for (mac) |byte| {
        if (byte != 0) nonzero = true;
        if (byte != 0xff) all_ones = false;
    }
    return nonzero and !all_ones;
}

/// CSR12..14 хранят MAC парами little-endian; PROM — запасной источник.
pub fn macFromCsr(vals: [3]u16, prom: ?[6]u8) [6]u8 {
    var mac = std.mem.zeroes([6]u8);
    for (vals, 0..) |value, i| {
        mac[2 * i] = @truncate(value);
        mac[2 * i + 1] = @truncate(value >> 8);
    }
    if (validMac(mac)) return mac;
    if (prom) |fallback| {
        if (validMac(fallback)) return fallback;
    }
    return std.mem.zeroes([6]u8);
}

pub const InitBlock = struct {
    mode: u16,
    tlen_rlen: u16,
    phys_addr: [6]u8,
    filter: [2]u32 = .{ 0, 0 },
    rx_ring: u32,
    tx_ring: u32,
};

pub fn makeInitBlock(mac: [6]u8, rx_dma: u32, tx_dma: u32, log_rx: u4, log_tx: u4, port: u2) InitBlock {
    return .{
        .mode = @as(u16, port) << 7,
        .tlen_rlen = (@as(u16, log_tx) << 12) | (@as(u16, log_rx) << 4),
        .phys_addr = mac,
        .rx_ring = rx_dma,
        .tx_ring = tx_dma,
    };
}

pub const RxDesc = struct {
    base: u32,
    buf_length: u16,
    status: u16,
    msg_length: u32,
};

pub const TxDesc = struct {
    base: u32,
    length: u16,
    status: u16,
    misc: u32,
};

pub const Ring = struct {
    rx: [RX_SIZE]RxDesc = std.mem.zeroes([RX_SIZE]RxDesc),
    tx: [TX_SIZE]TxDesc = std.mem.zeroes([TX_SIZE]TxDesc),
    cur_rx: u32 = 0,
    cur_tx: u32 = 0,
    dirty_tx: u32 = 0,
    tx_full: bool = false,
    packets_rx: usize = 0,
    packets_tx: usize = 0,
    reposts: usize = 0,
    copy_bytes: usize = 0,
    irq_masks: u16 = 0,
    rx_errors: usize = 0,

    pub fn init(self: *Ring, ib: *InitBlock, mac: [6]u8, rx_dma: u32, tx_dma: u32) void {
        self.cur_rx = 0;
        self.cur_tx = 0;
        self.dirty_tx = 0;
        self.tx_full = false;
        self.rx = std.mem.zeroes([RX_SIZE]RxDesc);
        self.tx = std.mem.zeroes([TX_SIZE]TxDesc);
        for (&self.rx, 0..) |*desc, i| {
            desc.* = .{
                .base = rx_dma + @as(u32, @intCast(i * 16)),
                .buf_length = NEG_BUF_SIZE,
                .status = OWN,
                .msg_length = 0,
            };
        }
        ib.* = makeInitBlock(mac, rx_dma, tx_dma, 5, 4, 0);
    }

    /// Порядок записи существенен: base/length/misc, затем status с OWN.
    pub fn xmit(self: *Ring, len: usize, dma: u32) !u16 {
        if (len == 0 or len > PKT_BUF_SIZE) return error.BadLength;
        if (self.tx_full) return error.TxFull;
        const entry: usize = @intCast(self.cur_tx & (TX_SIZE - 1));
        const negative: i16 = -@as(i16, @intCast(len));
        self.tx[entry] = .{
            .base = dma,
            .length = @bitCast(negative),
            .status = 0,
            .misc = 0,
        };
        self.tx[entry].status = TX_STATUS;
        self.cur_tx += 1;
        const next: usize = @intCast(self.cur_tx & (TX_SIZE - 1));
        if (self.tx[next].base != 0) self.tx_full = true;
        return CSR_KICK;
    }

    /// Возвращает 1, если нужен restart из-за FIFO underflow.
    pub fn reapTx(self: *Ring) usize {
        var done: usize = 0;
        var need_restart: usize = 0;
        while (self.dirty_tx != self.cur_tx) {
            const entry: usize = @intCast(self.dirty_tx & (TX_SIZE - 1));
            const desc = &self.tx[entry];
            if ((desc.status & OWN) != 0) break;
            if ((desc.status & 0x4000) != 0 and (desc.misc & 0x40000000) != 0) need_restart = 1;
            if ((desc.status & 0x4000) == 0) self.packets_tx += 1;
            desc.base = 0;
            self.dirty_tx += 1;
            done += 1;
        }
        if (self.cur_tx - self.dirty_tx < TX_SIZE - 2) self.tx_full = false;
        return need_restart;
    }

    pub fn ingestRx(self: *Ring, status: u16, msg_length: u32, data: []const u8) void {
        const code: u8 = @truncate(status >> 8);
        if (code == RX_OK) {
            const length: usize = @intCast((msg_length & 0xfff) -| 4);
            if (length >= 60 and length <= PKT_BUF_SIZE) {
                self.packets_rx += 1;
                if (length <= RX_COPYBREAK) self.copy_bytes += @min(data.len, length);
            }
        } else if (code != 0) {
            self.rx_errors += 1;
        }
        const entry: usize = @intCast(self.cur_rx & (RX_SIZE - 1));
        self.rx[entry] = .{
            .base = self.rx[entry].base,
            .buf_length = NEG_BUF_SIZE,
            .status = OWN,
            .msg_length = 0,
        };
        self.cur_rx += 1;
        self.reposts += 1;
    }

    pub fn poll(self: *Ring, budget: usize) usize {
        var work: usize = 0;
        while (work < budget) : (work += 1) {
            const entry: usize = @intCast(self.cur_rx & (RX_SIZE - 1));
            if ((self.rx[entry].status & OWN) != 0) break;
            const status = self.rx[entry].status;
            const length = self.rx[entry].msg_length;
            self.ingestRx(status, length, &[_]u8{});
        }
        return work;
    }

    pub fn irqAck(csr0: u16) u16 {
        return csr0 & ~CSR_LOW_MASK;
    }

    pub fn maskIrq(self: *Ring) void {
        self.irq_masks |= CSR3_MASK;
    }

    pub fn unmaskIrq(self: *Ring) void {
        self.irq_masks &= 0x00ff;
    }

    pub fn restart(self: *Ring, chip: ChipIo, io: *FakeIo, base: u16, bits: u16) void {
        _ = self;
        chip.writeCsr(io, base, 0, CSR_STOP);
        chip.writeCsr(io, base, 0, CSR_INIT);
        _ = chip.readCsr(io, base, 0);
        chip.writeCsr(io, base, 0, bits);
    }

    pub fn stop(chip: ChipIo, io: *FakeIo, base: u16) void {
        chip.writeCsr(io, base, 0, CSR_STOP);
        chip.writeBcr(io, base, 20, BCR20_16BIT);
    }

    pub fn start(chip: ChipIo, io: *FakeIo, base: u16, ib_dma: u32) void {
        chip.writeBcr(io, base, 20, BCR20_32BIT);
        chip.writeBcr(io, base, 18, 0x0860);
        chip.writeCsr(io, base, 1, @truncate(ib_dma));
        chip.writeCsr(io, base, 2, @truncate(ib_dma >> 16));
        chip.writeCsr(io, base, 4, 0x0915);
        chip.writeCsr(io, base, 0, CSR_INIT);
        _ = chip.readCsr(io, base, 0);
        chip.writeCsr(io, base, 0, CSR_NORMAL);
    }
};

pub const Probe = struct {
    status: []const u8 = "failed",
    probe: bool = false,
    ring: bool = false,
    mac: bool = false,
    tx: bool = false,
    rx: bool = false,
    irq: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};
    var io = FakeIo{};
    const chip = detectAccess(&io, 0x300) catch return result;
    result.probe = chip.access == .wio and io.reset_reads >= 1;

    io.csr[88] = 0x1003;
    io.csr[89] = 0x0262;
    const info = decodeChip((@as(u32, io.csr[89]) << 16) | io.csr[88]) catch return result;
    result.probe = result.probe and info.code == 0x2621 and info.fdx;

    const mac = macFromCsr(.{ 0x1234, 0x5678, 0x9abc }, null);
    result.mac = std.mem.eql(u8, &mac, &[_]u8{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a });

    var ib = InitBlock{ .mode = 0, .tlen_rlen = 0, .phys_addr = mac, .rx_ring = 0, .tx_ring = 0 };
    var ring = Ring{};
    ring.init(&ib, mac, 0x1000, 0x2000);
    result.ring = ib.tlen_rlen == 0x4050 and ib.rx_ring == 0x1000 and ib.tx_ring == 0x2000 and
        ring.rx[0].status == OWN and ring.rx[0].buf_length == NEG_BUF_SIZE and
        ring.rx[RX_SIZE - 1].status == OWN and ring.tx[0].status == 0;

    const kick = ring.xmit(60, 0x3000) catch return result;
    result.tx = kick == CSR_KICK and ring.tx[0].base == 0x3000 and
        ring.tx[0].length == @as(u16, @bitCast(@as(i16, -60))) and ring.tx[0].status == TX_STATUS;
    ring.tx[0].status = 0x8300 & ~OWN;
    if (ring.reapTx() != 0) return result;
    result.tx = result.tx and ring.packets_tx == 1 and !ring.tx_full;

    ring.rx[0].status = @as(u16, RX_OK) << 8;
    ring.rx[0].msg_length = 68;
    const work = ring.poll(1);
    result.rx = work == 1 and ring.packets_rx == 1 and ring.reposts == 1 and
        ring.rx[0].status == OWN and ring.rx[0].buf_length == NEG_BUF_SIZE;

    result.irq = Ring.irqAck(0xc100) == 0xc100 and Ring.irqAck(0x0041) == 0;
    ring.maskIrq();
    result.irq = result.irq and ring.irq_masks == CSR3_MASK;
    ring.unmaskIrq();
    result.irq = result.irq and ring.irq_masks == 0;
    Ring.start(chip, &io, 0x300, 0x1000);
    ring.restart(chip, &io, 0x300, CSR_NORMAL);
    Ring.stop(chip, &io, 0x300);
    result.irq = result.irq and io.bcr[20] == BCR20_16BIT and io.bcr[18] == 0x0860;

    result.status = "ok";
    result.errno = 0;
    return result;
}

fn ioWithFailure(dwio: bool) FakeIo {
    var io = FakeIo{};
    io.wio_bad = !dwio;
    io.dwio_bad = dwio;
    return io;
}

test "pcnet32: WIO first, DWIO fallback, reset is a read and RAP=88 readback" {
    var io = FakeIo{};
    const chip = try detectAccess(&io, 0x300);
    try std.testing.expectEqual(Access.wio, chip.access);
    try std.testing.expect(io.reset_reads >= 1);
    try std.testing.expectEqual(@as(u16, 0x12), chip.rap());
    try std.testing.expectEqual(@as(u16, 0x16), chip.bdp());

    var fallback = ioWithFailure(false);
    const wide = try detectAccess(&fallback, 0x300);
    try std.testing.expectEqual(Access.dwio, wide.access);
    try std.testing.expectEqual(@as(u16, 0x14), wide.rap());
    try std.testing.expectEqual(@as(u16, 0x18), wide.resetPort());
    try std.testing.expectEqual(@as(u16, 0x1c), wide.bdp());

    var broken = FakeIo{ .wio_bad = true, .dwio_bad = true };
    try std.testing.expectError(error.NoAccess, detectAccess(&broken, 0x300));
}

test "pcnet32: chipcode decode uses csr88|csr89<<16 and feature flags" {
    const info = try decodeChip((@as(u32, 0x2621) << 12) | 0x003);
    try std.testing.expectEqual(@as(u16, 0x2621), info.code);
    try std.testing.expect(info.fdx);
    try std.testing.expect(!info.mii);
    const multi = try decodeChip((@as(u32, 0x2624) << 12) | 0x003);
    try std.testing.expect(multi.fdx and multi.mii and multi.fset);
    const sram = try decodeChip((@as(u32, 0x2625) << 12) | 0x003);
    try std.testing.expect(sram.sram and sram.mii);
    try std.testing.expectError(error.BadChipId, decodeChip(0x2621_004));
    try std.testing.expectError(error.UnknownChip, decodeChip(0x9999_003));
}

test "pcnet32: init block, style bits and CSR1/CSR2 DMA split" {
    const mac = [6]u8{ 0x34, 0x12, 0x78, 0x56, 0xbc, 0x9a };
    const ib = makeInitBlock(mac, 0x1234_5678, 0x9abc_def0, 5, 4, 1);
    try std.testing.expectEqual(@as(u16, 0x4050), ib.tlen_rlen);
    try std.testing.expectEqual(@as(u16, 0x0080), ib.mode);
    try std.testing.expectEqual(@as(u32, 0x1234_5678), ib.rx_ring);
    try std.testing.expect(std.mem.eql(u8, &ib.phys_addr, &mac));

    var io = FakeIo{};
    const chip = try detectAccess(&io, 0x300);
    Ring.start(chip, &io, 0x300, 0x1234_5678);
    try std.testing.expectEqual(@as(u16, BCR20_32BIT), io.bcr[20]);
    try std.testing.expectEqual(@as(u16, 0x0860), io.bcr[18]);
    try std.testing.expectEqual(@as(u16, 0x5678), io.csr[1]);
    try std.testing.expectEqual(@as(u16, 0x1234), io.csr[2]);
    try std.testing.expectEqual(@as(u16, 0x0915), io.csr[4]);
    try std.testing.expectEqual(CSR_NORMAL, io.csr[0]);
    Ring.stop(chip, &io, 0x300);
    try std.testing.expectEqual(@as(u16, BCR20_16BIT), io.bcr[20]);
    try std.testing.expectEqual(CSR_STOP, io.csr[0]);
}

test "pcnet32: ring init posts ownership and two's-complement buffer length" {
    const mac = [6]u8{ 1, 2, 3, 4, 5, 6 };
    var ib = InitBlock{ .mode = 0, .tlen_rlen = 0, .phys_addr = mac, .rx_ring = 0, .tx_ring = 0 };
    var ring = Ring{};
    ring.init(&ib, mac, 0x1000, 0x2000);
    try std.testing.expectEqual(NEG_BUF_SIZE, ring.rx[0].buf_length);
    try std.testing.expectEqual(@as(u16, OWN), ring.rx[0].status);
    try std.testing.expectEqual(@as(u32, 0x1000 + 31 * 16), ring.rx[31].base);
    try std.testing.expectEqual(@as(u16, OWN), ring.rx[31].status);
    try std.testing.expectEqual(@as(u16, 0), ring.tx[0].status);
    try std.testing.expect(!ring.tx_full);
    try std.testing.expectEqual(@as(usize, RX_SIZE / 2), ring.poll(0) + 16);
}

test "pcnet32: transmit writes base before status, kicks TXPOLL and wakes queue" {
    var ring = Ring{};
    ring.tx[1].base = 0x1234;
    try std.testing.expectEqual(CSR_KICK, try ring.xmit(60, 0x3000));
    try std.testing.expectEqual(@as(u32, 0x3000), ring.tx[0].base);
    try std.testing.expectEqual(@as(u16, @bitCast(@as(i16, -60))), ring.tx[0].length);
    try std.testing.expectEqual(@as(u16, TX_STATUS), ring.tx[0].status);
    try std.testing.expect(ring.tx_full);
    ring.tx[0].status = 0x4300; // major error + ownership cleared
    ring.tx[0].misc = 0x4000_0000;
    try std.testing.expectEqual(@as(usize, 1), ring.reapTx());
    try std.testing.expect(!ring.tx_full);
    ring.tx[1].base = 0x1234;
    ring.tx_full = true;
    try std.testing.expectError(error.TxFull, ring.xmit(60, 0));
    try std.testing.expectError(error.BadLength, ring.xmit(0, 0));
}

test "pcnet32: receive validates status, length and reposts with budget" {
    var ring = Ring{};
    ring.rx[0].base = 0x4000;
    ring.rx[0].status = @as(u16, RX_OK) << 8;
    ring.rx[0].msg_length = 68;
    try std.testing.expectEqual(@as(usize, 1), ring.poll(1));
    try std.testing.expectEqual(@as(usize, 1), ring.packets_rx);
    try std.testing.expectEqual(NEG_BUF_SIZE, ring.rx[0].buf_length);
    try std.testing.expectEqual(@as(u16, OWN), ring.rx[0].status);

    ring.rx[1].status = @as(u16, 0x08) << 8; // CRC error
    ring.rx[1].msg_length = 0;
    _ = ring.poll(1);
    try std.testing.expectEqual(@as(usize, 1), ring.rx_errors);
    try std.testing.expectEqual(@as(usize, 2), ring.reposts);
    try std.testing.expectEqual(@as(u16, OWN), ring.rx[1].status);
}

test "pcnet32: multicast hash, allmulti and promiscuous MAC rules" {
    const crc: u32 = 0xabc_def;
    var table = [_]u16{ 0, 0, 0, 0 };
    const index: usize = @intCast((crc >> 26) & 3);
    table[index] |= @as(u16, 1) << @intCast((crc >> 4) & 0xf);
    try std.testing.expect(table[index] != 0);
    const zero = macFromCsr(.{ 0, 0, 0 }, null);
    for (zero) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
    const prom = [6]u8{ 2, 3, 4, 5, 6, 7 };
    const fallback = macFromCsr(.{ 0, 0, 0 }, prom);
    try std.testing.expect(std.mem.eql(u8, &fallback, &prom));
    const from_csr = macFromCsr(.{ 0x1234, 0x5678, 0x9abc }, prom);
    try std.testing.expectEqual(@as(u8, 0x34), from_csr[0]);
}

test "pcnet32: IRQ NAPI mask, restart sequence and stop recover" {
    try std.testing.expectEqual(@as(u16, 0xc100), Ring.irqAck(0xc100));
    try std.testing.expectEqual(@as(u16, 0), Ring.irqAck(0x0041));
    var ring = Ring{};
    ring.maskIrq();
    try std.testing.expectEqual(@as(u16, CSR3_MASK), ring.irq_masks);
    ring.unmaskIrq();
    try std.testing.expectEqual(@as(u16, 0), ring.irq_masks);
    try std.testing.expectEqual(@as(u8, 2), MAX_INTERRUPT_WORK);

    var io = FakeIo{};
    const chip = try detectAccess(&io, 0x300);
    ring.restart(chip, &io, 0x300, CSR_NORMAL);
    try std.testing.expectEqual(CSR_NORMAL, io.csr[0]);
    Ring.stop(chip, &io, 0x300);
    try std.testing.expectEqual(CSR_STOP, io.csr[0]);
    try std.testing.expectEqual(@as(u16, BCR20_16BIT), io.bcr[20]);
}

test "pcnet32: boot probe exercises all six invariant groups" {
    const result = probe();
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expect(result.probe);
    try std.testing.expect(result.ring);
    try std.testing.expect(result.mac);
    try std.testing.expect(result.tx);
    try std.testing.expect(result.rx);
    try std.testing.expect(result.irq);
    try std.testing.expectEqual(@as(u8, 0), result.errno);
}
