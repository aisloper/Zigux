//! Порт минимального среза DEC Tulip DC21143 (Linux 7.3 tulip_core.c/tulip.h).
//! Чистая логика: PCI gating, дескрипторы, кольца, CSR6 режим, multicast hash.
//! Источник: drivers/net/ethernet/dec/tulip/. GPL-2.0-only.

const std = @import("std");

pub const PCI_VENDOR_DEC: u16 = 0x1011;
pub const PCI_DEVICE_DC21143: u16 = 0x0019;

pub const RX_RING_SIZE: u16 = 32;
pub const TX_RING_SIZE: u16 = 32;
pub const PKT_BUF_SZ: u32 = 1536;

pub const DescOwned: u32 = 0x8000_0000;
pub const RxWholePkt: u32 = 0x0300_0000;
pub const DescEndRing: u32 = 0x0200_0000;
pub const DescChain: u32 = 0x0100_0000;

pub const TxWholePkt: u32 = 0x6000_0000;
pub const TxNoIntr: u32 = 0x6000_0000;
pub const TxIntr: u32 = 0xE000_0000;

pub const Csr6 = struct {
    pub const rx_tx: u32 = 0x0002_0000 | 0x0000_2000;
    pub const tx_start: u32 = 0x0000_2000;
    pub const rx_start: u32 = 0x0000_0002;
    pub const promisc: u32 = 0x0000_0040;
    pub const all_multi: u32 = 0x0000_0080;
    pub const full_duplex: u32 = 0x0000_0200;
};

pub const RxStatus = struct {
    pub const frame_len_shift: u5 = 16;
    pub const frame_len_mask: u32 = 0x3fff;
    pub const error_summary: u32 = 0x0000_8000;
    pub const crc_error: u32 = 0x0000_0002;
};

pub const Desc = extern struct {
    status: u32 = 0,
    length: u32 = 0,
    buffer1: u32 = 0,
    buffer2: u32 = 0,
};

pub fn isSupported(vendor: u16, device: u16) bool {
    return vendor == PCI_VENDOR_DEC and device == PCI_DEVICE_DC21143;
}

pub fn ringNext(i: u16, size: u16) u16 {
    return (i + 1) % size;
}

pub fn txFlag(entry: u16, dirty: u16, ring_size: u16) u32 {
    const used = if (entry >= dirty) entry - dirty else ring_size - dirty + entry;
    const free = ring_size - 1 - used;
    if (free < 2) return 0;
    if (free < 4) return TxIntr;
    return TxNoIntr;
}

pub fn initTxDesc(desc: *Desc, next_addr: u32, end_ring: bool) void {
    desc.* = .{ .status = 0, .length = if (end_ring) DescEndRing else 0, .buffer1 = 0, .buffer2 = next_addr };
}

pub fn initRxDesc(desc: *Desc, buf_addr: u32, next_addr: u32, end_ring: bool) void {
    desc.* = .{
        .status = DescOwned,
        .length = PKT_BUF_SZ | (if (end_ring) DescEndRing else 0),
        .buffer1 = buf_addr,
        .buffer2 = next_addr,
    };
}

pub fn rxFrameLen(status: u32) u16 {
    const raw: u16 = @intCast((status >> RxStatus.frame_len_shift) & RxStatus.frame_len_mask);
    return if (raw >= 4) raw - 4 else 0;
}

pub fn rxHasError(status: u32) bool {
    return (status & RxStatus.error_summary) != 0;
}

pub fn rxOwned(status: u32) bool {
    return (status & DescOwned) != 0;
}

pub fn etherCrcLe(addr: [6]u8) u32 {
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
    return crc;
}

pub fn multicastHashBit(addr: [6]u8) u8 {
    // 512-bit hash filter -> 9 bits; index = high bits, bit = low 4 bits.
    return @intCast((etherCrcLe(addr) >> 23) & 0xff);
}

pub const Filter = struct {
    csr6: u32 = Csr6.tx_start | Csr6.rx_start,
    hash_hi: u32 = 0,
    hash_lo: u32 = 0,
    hash: [16]u16 = [_]u16{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 },
};

pub fn buildFilter(addrs: []const [6]u8, promisc: bool, allmulti: bool) Filter {
    var f = Filter{};
    if (promisc) {
        f.csr6 |= Csr6.promisc;
        @memset(&f.hash, 0xffff);
        f.hash_hi = 0xffff_ffff;
        f.hash_lo = 0xffff_ffff;
        return f;
    }
    if (allmulti) {
        f.csr6 |= Csr6.all_multi;
        @memset(&f.hash, 0xffff);
        f.hash_hi = 0xffff_ffff;
        f.hash_lo = 0xffff_ffff;
        return f;
    }
    for (addrs) |addr| {
        const bit = multicastHashBit(addr);
        const idx: usize = bit >> 4;
        const off: u4 = @intCast(bit & 0xf);
        f.hash[idx] |= @as(u16, 1) << off;
    }
    f.hash_lo = (@as(u32, f.hash[1]) << 16) | f.hash[0];
    f.hash_hi = (@as(u32, f.hash[3]) << 16) | f.hash[2];
    return f;
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
    result.probe = isSupported(PCI_VENDOR_DEC, PCI_DEVICE_DC21143) and !isSupported(0x8086, 0x100e);
    const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    result.mac = mac[0] == 0x52 and mac[5] == 0x56;
    var tx = Desc{};
    initTxDesc(&tx, 0x2000, true);
    result.tx = (tx.length & DescEndRing) != 0 and tx.buffer2 == 0x2000 and txFlag(0, 0, TX_RING_SIZE) == TxNoIntr;
    var rx = Desc{};
    initRxDesc(&rx, 0x3000, 0x3010, true);
    result.rx = rxOwned(rx.status) and (rx.length & DescEndRing) != 0 and rx.buffer1 == 0x3000 and !rxHasError(rx.status);
    const status: u32 = 0x0001_0000;
    result.irq = (status & 0x0001_0000) != 0 and ringNext(31, RX_RING_SIZE) == 0;
    const addrs = [_][6]u8{.{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 }};
    const f = buildFilter(&addrs, false, false);
    const bit = multicastHashBit(addrs[0]);
    const set = (f.hash[bit >> 4] & (@as(u16, 1) << @as(u4, @intCast(bit & 0xf)))) != 0;
    result.mcast = set and (f.csr6 & Csr6.promisc) == 0 and (f.csr6 & Csr6.all_multi) == 0;
    if (result.probe and result.mac and result.tx and result.rx and result.irq and result.mcast) {
        result.status = "ok";
        result.errno = 0;
    }
    return result;
}

test "tulip: PCI DC21143 gating" {
    try std.testing.expect(isSupported(0x1011, 0x0019));
    try std.testing.expect(!isSupported(0x1011, 0x0009));
    try std.testing.expect(!isSupported(0x8086, 0x100e));
}

test "tulip: descriptor ring wrap and init" {
    var tx = Desc{};
    initTxDesc(&tx, 0x1000, true);
    try std.testing.expectEqual(@as(u32, DescEndRing), tx.length & DescEndRing);
    try std.testing.expectEqual(@as(u32, 0x1000), tx.buffer2);
    var rx = Desc{};
    initRxDesc(&rx, 0x2000, 0x2040, false);
    try std.testing.expect(rxOwned(rx.status));
    try std.testing.expectEqual(@as(u32, PKT_BUF_SZ), rx.length & ~DescEndRing);
    try std.testing.expectEqual(@as(u16, 0), ringNext(31, 32));
}

test "tulip: tx flag selection and rx length" {
    try std.testing.expectEqual(TxNoIntr, txFlag(0, 0, 32));
    try std.testing.expectEqual(TxIntr, txFlag(29, 0, 32));
    const status: u32 = (@as(u32, 64) << RxStatus.frame_len_shift);
    try std.testing.expectEqual(@as(u16, 60), rxFrameLen(status));
    try std.testing.expect(!rxHasError(status));
}

test "tulip: multicast hash filter" {
    const addr = [6]u8{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 };
    const bit = multicastHashBit(addr);
    const f = buildFilter(&[_][6]u8{addr}, false, false);
    try std.testing.expect((f.hash[bit >> 4] & (@as(u16, 1) << @as(u4, @intCast(bit & 0xf)))) != 0);
    const promisc = buildFilter(&[_][6]u8{addr}, true, false);
    try std.testing.expect((promisc.csr6 & Csr6.promisc) != 0);
    try std.testing.expectEqual(@as(u16, 0xffff), promisc.hash[0]);
    const allmulti = buildFilter(&[_][6]u8{addr}, false, true);
    try std.testing.expect((allmulti.csr6 & Csr6.all_multi) != 0);
}

test "tulip: probe smoke" {
    const result = probe();
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expectEqual(@as(u8, 0), result.errno);
}
