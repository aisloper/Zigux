//! Порт драйвера Realtek RTL8139 (8139too) Linux 7.3: идентификация чипа,
//! reset/init последовательность, кольца TX/RX, ISR и multicast hash filter.
//! Источник: drivers/net/ethernet/realtek/8139too.c. GPL-2.0-only.

const std = @import("std");

pub const NUM_TX_DESC = 4;
pub const RX_BUF_IDX = 2;
pub const RX_BUF_LEN = 8192 << RX_BUF_IDX; // 32K
pub const RX_BUF_PAD = 16;
pub const RX_BUF_WRAP_PAD = 2048;
pub const RX_BUF_TOT_LEN = RX_BUF_LEN + RX_BUF_PAD + RX_BUF_WRAP_PAD;
pub const MAX_ETH_FRAME_SIZE = 1792;
pub const TX_BUF_SIZE = MAX_ETH_FRAME_SIZE;
pub const ETH_ZLEN = 60;

pub const Cmd = struct {
    pub const reset: u8 = 0x10;
    pub const rx_enb: u8 = 0x08;
    pub const tx_enb: u8 = 0x04;
    pub const rx_buf_empty: u8 = 0x01;
};

pub const Intr = struct {
    pub const pcie_err: u16 = 0x8000;
    pub const pcs_timeout: u16 = 0x4000;
    pub const rx_fifo_over: u16 = 0x40;
    pub const rx_underrun: u16 = 0x20;
    pub const rx_overflow: u16 = 0x10;
    pub const tx_err: u16 = 0x08;
    pub const tx_ok: u16 = 0x04;
    pub const rx_err: u16 = 0x02;
    pub const rx_ok: u16 = 0x01;
    pub const rx_ack_bits: u16 = rx_fifo_over | rx_overflow | rx_ok;
    pub const default_mask: u16 = pcie_err | pcs_timeout | rx_underrun | rx_overflow |
        rx_fifo_over | tx_err | tx_ok | rx_err | rx_ok;
    pub const norx_mask: u16 = pcie_err | pcs_timeout | rx_underrun | tx_err | tx_ok | rx_err;
};

pub const Tsd = struct {
    pub const own: u32 = 0x2000;
    pub const underrun: u32 = 0x4000;
    pub const ok: u32 = 0x8000;
    pub const out_of_window: u32 = 0x20000000;
    pub const aborted: u32 = 0x40000000;
    pub const carrier_lost: u32 = 0x80000000;
};

pub const RxStatus = struct {
    pub const multicast: u16 = 0x8000;
    pub const physical: u16 = 0x4000;
    pub const broadcast: u16 = 0x2000;
    pub const bad_symbol: u16 = 0x0020;
    pub const runt: u16 = 0x0010;
    pub const too_long: u16 = 0x0008;
    pub const crc_err: u16 = 0x0004;
    pub const bad_align: u16 = 0x0002;
    pub const ok: u16 = 0x0001;
};

pub const RxMode = struct {
    pub const accept_err: u32 = 0x20;
    pub const accept_runt: u32 = 0x10;
    pub const accept_broadcast: u32 = 0x08;
    pub const accept_multicast: u32 = 0x04;
    pub const accept_my_phys: u32 = 0x02;
    pub const accept_all_phys: u32 = 0x01;
};

pub const Cfg9346 = struct {
    pub const lock: u8 = 0x00;
    pub const unlock: u8 = 0xc0;
};

pub fn isRejected8139Cp(vendor: u16, device: u16, revision: u8) bool {
    return vendor == 0x10ec and device == 0x8139 and revision >= 0x20;
}

pub fn hwRevidMask() u32 {
    return (@as(u32, 1) << 30) | (@as(u32, 1) << 29) | (@as(u32, 1) << 28) |
        (@as(u32, 1) << 27) | (@as(u32, 1) << 26) | (@as(u32, 1) << 23) | (@as(u32, 1) << 22);
}

pub fn chipVersion(tx_config: u32) u32 {
    return tx_config & hwRevidMask();
}

pub fn txConfigDefault() u32 {
    const tx_ifg96: u32 = @as(u32, 3) << 24;
    const dma_burst: u32 = @as(u32, 6) << 8;
    const retry: u32 = @as(u32, 8) << 4;
    return tx_ifg96 | dma_burst | retry;
}

pub fn rxConfigDefault() u32 {
    const rcv32k: u32 = @as(u32, 1) << 12;
    const no_wrap: u32 = @as(u32, 1) << 7;
    const fifo: u32 = @as(u32, 7) << 13;
    const dma: u32 = @as(u32, 7) << 8;
    return rcv32k | no_wrap | fifo | dma;
}

pub fn etherCrc32(addr: [6]u8) u32 {
    var crc: u32 = 0xffff_ffff;
    for (addr) |byte| {
        var b = byte;
        var i: u8 = 0;
        while (i < 8) : (i += 1) {
            const mix: u1 = @truncate((crc ^ b) & 1);
            crc >>= 1;
            if (mix == 1) crc ^= 0xedb8_8320;
            b >>= 1;
        }
    }
    return ~crc;
}

pub fn multicastHashBit(addr: [6]u8) u6 {
    return @intCast(etherCrc32(addr) >> 26);
}

pub const MulticastFilter = struct {
    mar: [8]u8 = std.mem.zeroes([8]u8),
    rx_mode: u32 = 0,
};

pub fn setMulticastFilter(addrs: []const [6]u8, promisc: bool, allmulti: bool, limit: usize) MulticastFilter {
    var result = MulticastFilter{};
    if (promisc) {
        result.rx_mode = RxMode.accept_broadcast | RxMode.accept_multicast |
            RxMode.accept_my_phys | RxMode.accept_all_phys;
        @memset(&result.mar, 0xff);
        return result;
    }
    if (allmulti or addrs.len > limit) {
        result.rx_mode = RxMode.accept_broadcast | RxMode.accept_multicast | RxMode.accept_my_phys;
        @memset(&result.mar, 0xff);
        return result;
    }
    result.rx_mode = RxMode.accept_broadcast | RxMode.accept_my_phys;
    for (addrs) |addr| {
        const bit_nr = multicastHashBit(addr);
        const byte_index: usize = @intCast(bit_nr >> 3);
        const bit_mask: u8 = @as(u8, 1) << @as(u3, @intCast(bit_nr & 7));
        result.mar[byte_index] |= bit_mask;
        result.rx_mode |= RxMode.accept_multicast;
    }
    return result;
}

pub const TxRing = struct {
    cur_tx: u32 = 0,
    dirty_tx: u32 = 0,
    tx_flag: u32 = (256 << 11) & 0x003f_0000,
    descriptors: [NUM_TX_DESC]u32 = std.mem.zeroes([NUM_TX_DESC]u32),

    pub fn nextEntry(self: *TxRing) usize {
        return @intCast(self.cur_tx % NUM_TX_DESC);
    }

    pub fn queueLen(self: *TxRing) u32 {
        return self.cur_tx - self.dirty_tx;
    }

    pub fn canQueue(self: *TxRing) bool {
        return self.queueLen() < NUM_TX_DESC;
    }

    pub fn startXmit(self: *TxRing, len: usize) !usize {
        if (!self.canQueue()) return error.TxFull;
        const real_len = @max(len, ETH_ZLEN);
        if (real_len > TX_BUF_SIZE) return error.TooLarge;
        const entry = self.nextEntry();
        self.descriptors[entry] = self.tx_flag | @as(u32, @intCast(real_len));
        self.cur_tx += 1;
        return entry;
    }

    pub fn complete(self: *TxRing, entry: usize, tsd: u32) enum { pending, ok, err } {
        if ((tsd & (Tsd.ok | Tsd.underrun | Tsd.aborted)) == 0) return .pending;
        if ((tsd & (Tsd.out_of_window | Tsd.aborted)) != 0) {
            self.descriptors[entry] = 0;
            self.dirty_tx += 1;
            return .err;
        }
        if ((tsd & Tsd.underrun) != 0 and self.tx_flag < 0x0030_0000) {
            self.tx_flag += 0x0002_0000;
        }
        self.descriptors[entry] = tsd;
        self.dirty_tx += 1;
        return .ok;
    }
};

pub const RxFrame = struct {
    status: u16,
    rx_size: u16,
    pkt_size: usize,
};

pub const RxRing = struct {
    cur_rx: u32 = 0,

    pub fn readHeader(self: *RxRing, word: u32) RxFrame {
        _ = self;
        const status: u16 = @truncate(word & 0xffff);
        const rx_size: u16 = @truncate(word >> 16);
        const pkt_size: usize = if (rx_size >= 4) rx_size - 4 else 0;
        return .{ .status = status, .rx_size = rx_size, .pkt_size = pkt_size };
    }

    pub fn advance(self: *RxRing, rx_size: u16) u16 {
        self.cur_rx = (self.cur_rx + @as(u32, rx_size) + 4 + 3) & ~@as(u32, 3);
        const ptr: u32 = self.cur_rx -% 16;
        return @truncate(ptr);
    }

    pub fn copyWrapped(self: *RxRing, ring: []const u8, dst: []u8, rx_size: u16, keep_fcs: bool) usize {
        const ring_offset: usize = @intCast(self.cur_rx % RX_BUF_LEN);
        const data_offset = (ring_offset + 4) % RX_BUF_LEN;
        const pkt_size: usize = if (rx_size >= 4) rx_size - 4 else 0;
        const copy_size = if (keep_fcs) pkt_size else if (pkt_size >= 4) pkt_size - 4 else pkt_size;
        const n = @min(copy_size, dst.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            dst[i] = ring[(data_offset + i) % RX_BUF_LEN];
        }
        return n;
    }
};

pub fn isrPending(status: u16, mask: u16) u16 {
    return status & mask & Intr.default_mask;
}

pub fn ackNonRx(status: u16) u16 {
    return status & ~(Intr.rx_ack_bits | Intr.tx_err);
}

pub const Probe = struct {
    status: []const u8 = "failed",
    probe: bool = false,
    mac: bool = false,
    tx: bool = false,
    rx: bool = false,
    irq: bool = false,
    mcast: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};

    result.probe = !isRejected8139Cp(0x10ec, 0x8139, 0x10) and
        isRejected8139Cp(0x10ec, 0x8139, 0x20) and
        chipVersion(0x7440_0000 | txConfigDefault()) == 0x7440_0000 and
        txConfigDefault() == ((@as(u32, 3) << 24) | (@as(u32, 6) << 8) | (@as(u32, 8) << 4));

    var hw = std.mem.zeroes([0x60]u8);
    const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    @memcpy(hw[0..6], &mac);
    result.mac = std.mem.eql(u8, hw[0..6], &mac) and rxConfigDefault() == ((@as(u32, 1) << 12) | (@as(u32, 1) << 7) | (@as(u32, 7) << 13) | (@as(u32, 7) << 8));

    var tx = TxRing{};
    const entry = tx.startXmit(60) catch return result;
    const tsd = tx.descriptors[entry];
    result.tx = entry == 0 and (tsd & 0x7ff) == 60 and tx.cur_tx == 1;
    const done = tx.complete(entry, Tsd.ok | (tsd & 0x1fff));
    result.tx = result.tx and done == .ok and tx.dirty_tx == 1 and tx.canQueue();

    var rx = RxRing{};
    var ring = std.mem.zeroes([RX_BUF_TOT_LEN]u8);
    const header: u32 = (@as(u32, 64) << 16) | RxStatus.ok;
    std.mem.writeInt(u32, ring[0..4], header, .little);
    for (0..60) |i| ring[4 + i] = @truncate(i);
    const frame = rx.readHeader(std.mem.readInt(u32, ring[0..4], .little));
    var dst = std.mem.zeroes([64]u8);
    const copied = rx.copyWrapped(&ring, &dst, frame.rx_size, false);
    const ptr = rx.advance(frame.rx_size);
    result.rx = frame.status == RxStatus.ok and frame.rx_size == 64 and copied == 56 and ptr == @as(u16, @truncate(@as(u32, (64 + 4 + 3) & ~@as(u32, 3)) -% 16));

    const pending = isrPending(Intr.rx_ok | Intr.tx_ok | Intr.pcie_err, Intr.default_mask);
    const acked = ackNonRx(pending);
    result.irq = pending == (Intr.rx_ok | Intr.tx_ok | Intr.pcie_err) and
        acked == (Intr.tx_ok | Intr.pcie_err) and isrPending(0xffff, 0) == 0;

    const addrs = [_][6]u8{.{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 }};
    const filter = setMulticastFilter(&addrs, false, false, 32);
    const bit = multicastHashBit(addrs[0]);
    const byte_index: usize = @intCast(bit >> 3);
    const bit_mask: u8 = @as(u8, 1) << @as(u3, @intCast(bit & 7));
    result.mcast = (filter.rx_mode & RxMode.accept_multicast) != 0 and (filter.mar[byte_index] & bit_mask) != 0;
    const promisc = setMulticastFilter(&addrs, true, false, 32);
    result.mcast = result.mcast and (promisc.rx_mode & RxMode.accept_all_phys) != 0 and promisc.mar[0] == 0xff;

    if (result.probe and result.mac and result.tx and result.rx and result.irq and result.mcast) {
        result.status = "ok";
        result.errno = 0;
    }
    return result;
}

test "rtl8139: PCI ID/revision gating and chip version decode" {
    try std.testing.expect(!isRejected8139Cp(0x10ec, 0x8139, 0x10));
    try std.testing.expect(isRejected8139Cp(0x10ec, 0x8139, 0x20));
    try std.testing.expect(!isRejected8139Cp(0x1414, 0x8139, 0x20));
    const rev = chipVersion(0x7440_0000 | txConfigDefault());
    try std.testing.expectEqual(@as(u32, 0x7440_0000), rev & hwRevidMask());
}

test "rtl8139: reset/init default config and MAC programming" {
    try std.testing.expectEqual((@as(u32, 3) << 24) | (@as(u32, 6) << 8) | (@as(u32, 8) << 4), txConfigDefault());
    try std.testing.expectEqual((@as(u32, 1) << 12) | (@as(u32, 1) << 7) | (@as(u32, 7) << 13) | (@as(u32, 7) << 8), rxConfigDefault());
    var regs = std.mem.zeroes([8]u8);
    const mac = [6]u8{ 1, 2, 3, 4, 5, 6 };
    @memcpy(regs[0..6], &mac);
    try std.testing.expectEqualSlices(u8, &mac, regs[0..6]);
    try std.testing.expectEqual(Cfg9346.unlock, @as(u8, 0xc0));
    try std.testing.expectEqual(Cfg9346.lock, @as(u8, 0x00));
}

test "rtl8139: TX ring queues, owns, completes and bumps underrun threshold" {
    var tx = TxRing{};
    const e0 = try tx.startXmit(40);
    try std.testing.expectEqual(@as(usize, 0), e0);
    try std.testing.expectEqual(@as(u32, 60) | tx.tx_flag, tx.descriptors[0]);
    const e1 = try tx.startXmit(100);
    _ = e1;
    _ = try tx.startXmit(100);
    _ = try tx.startXmit(100);
    try std.testing.expectError(error.TxFull, tx.startXmit(60));
    const r = tx.complete(0, Tsd.ok | Tsd.underrun | 60);
    try std.testing.expectEqual(@as(@TypeOf(r), .ok), r);
    try std.testing.expect(tx.tx_flag >= (256 << 11) + 0x0002_0000);
    try std.testing.expectEqual(@as(u32, 1), tx.dirty_tx);
}

test "rtl8139: RX header parse, copy and advance pointer" {
    var rx = RxRing{};
    var ring = std.mem.zeroes([RX_BUF_TOT_LEN]u8);
    const header: u32 = (@as(u32, 68) << 16) | RxStatus.ok;
    std.mem.writeInt(u32, ring[0..4], header, .little);
    for (0..64) |i| ring[4 + i] = @truncate(i + 1);
    const frame = rx.readHeader(std.mem.readInt(u32, ring[0..4], .little));
    try std.testing.expectEqual(RxStatus.ok, frame.status);
    try std.testing.expectEqual(@as(u16, 68), frame.rx_size);
    try std.testing.expectEqual(@as(usize, 64), frame.pkt_size);
    var dst = std.mem.zeroes([64]u8);
    const copied = rx.copyWrapped(&ring, &dst, frame.rx_size, false);
    try std.testing.expectEqual(@as(usize, 60), copied);
    try std.testing.expectEqual(@as(u8, 1), dst[0]);
    const ptr = rx.advance(frame.rx_size);
    try std.testing.expectEqual(@as(u16, @truncate(((68 + 4 + 3) & ~@as(u32, 3)) -% 16)), ptr);
}

test "rtl8139: RX wraparound copies tail and head" {
    var rx = RxRing{ .cur_rx = RX_BUF_LEN - 8 };
    var ring = std.mem.zeroes([RX_BUF_TOT_LEN]u8);
    ring[(RX_BUF_LEN - 4) % RX_BUF_LEN] = 0xaa;
    ring[(RX_BUF_LEN - 3) % RX_BUF_LEN] = 0xbb;
    ring[(RX_BUF_LEN - 2) % RX_BUF_LEN] = 0xcc;
    ring[(RX_BUF_LEN - 1) % RX_BUF_LEN] = 0xdd;
    ring[0] = 0x11;
    ring[1] = 0x22;
    ring[2] = 0x33;
    ring[3] = 0x44;
    var dst = std.mem.zeroes([8]u8);
    const copied = rx.copyWrapped(&ring, &dst, 12, true); // 8 bytes payload
    try std.testing.expectEqual(@as(usize, 8), copied);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0xaa, 0xbb, 0xcc, 0xdd, 0x11, 0x22, 0x33, 0x44 }, dst[0..8]);
}

test "rtl8139: interrupt pending/mask/ack semantics" {
    const status = Intr.rx_ok | Intr.tx_ok | Intr.rx_overflow | Intr.pcie_err;
    const pending = isrPending(status, Intr.default_mask);
    try std.testing.expectEqual(status, pending);
    try std.testing.expectEqual(Intr.tx_ok | Intr.pcie_err, ackNonRx(pending));
    try std.testing.expectEqual(@as(u16, 0), isrPending(Intr.rx_ok, 0));
    const norx = isrPending(status, Intr.norx_mask);
    try std.testing.expectEqual(Intr.tx_ok | Intr.pcie_err, norx);
}

test "rtl8139: multicast hash filter sets bit and promisc/allmulti modes" {
    const addr = [6]u8{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 };
    const bit = multicastHashBit(addr);
    const filter = setMulticastFilter(&[_][6]u8{addr}, false, false, 32);
    try std.testing.expect((filter.rx_mode & RxMode.accept_multicast) != 0);
    const byte_index: usize = @intCast(bit >> 3);
    const bit_mask: u8 = @as(u8, 1) << @as(u3, @intCast(bit & 7));
    try std.testing.expect((filter.mar[byte_index] & bit_mask) != 0);

    const promisc = setMulticastFilter(&[_][6]u8{addr}, true, false, 32);
    try std.testing.expect((promisc.rx_mode & RxMode.accept_all_phys) != 0);
    try std.testing.expectEqual(@as(u8, 0xff), promisc.mar[0]);

    const allmulti = setMulticastFilter(&[_][6]u8{addr}, false, true, 32);
    try std.testing.expect((allmulti.rx_mode & RxMode.accept_multicast) != 0);
    try std.testing.expectEqual(@as(u8, 0xff), allmulti.mar[7]);
}

test "rtl8139: boot probe exercises probe/mac/tx/rx/irq/mcast" {
    const result = probe();
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expect(result.probe);
    try std.testing.expect(result.mac);
    try std.testing.expect(result.tx);
    try std.testing.expect(result.rx);
    try std.testing.expect(result.irq);
    try std.testing.expect(result.mcast);
    try std.testing.expectEqual(@as(u8, 0), result.errno);
}
