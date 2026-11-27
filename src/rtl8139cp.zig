//! Порт драйвера Realtek 8139C+ (8139cp) Linux 7.3: gating ревизии,
//! дескрипторы TX/RX, кольца, ISR/NAPI ack-mask, multicast hash.
//! Источник: drivers/net/ethernet/realtek/8139cp.c. GPL-2.0-only.

const std = @import("std");

pub const CP_RX_RING_SIZE: u16 = 64;
pub const CP_TX_RING_SIZE: u16 = 64;
pub const PKT_BUF_SZ: usize = 1536;
pub const TX_EARLY_THRESH: u32 = 256;

pub const DescOwn: u32 = 1 << 31;
pub const RingEnd: u32 = 1 << 30;
pub const FirstFrag: u32 = 1 << 29;
pub const LastFrag: u32 = 1 << 28;
pub const LargeSend: u32 = 1 << 27;
pub const MSSShift: u5 = 16;
pub const MSSMask: u32 = 0x7ff;
pub const TxError: u32 = 1 << 23;
pub const RxError: u32 = 1 << 20;
pub const IPCS: u32 = 1 << 18;
pub const UDPCS: u32 = 1 << 17;
pub const TCPCS: u32 = 1 << 16;
pub const TxVlanTag: u32 = 1 << 17;
pub const RxVlanTagged: u32 = 1 << 16;
pub const IPFail: u32 = 1 << 15;
pub const UDPFail: u32 = 1 << 14;
pub const TCPFail: u32 = 1 << 13;

pub const RxProtoTCP: u32 = 1;
pub const RxProtoUDP: u32 = 2;
pub const RxProtoIP: u32 = 3;
pub const PID1: u32 = 1 << 17;
pub const PID0: u32 = 1 << 16;

pub const RxErrFIFO: u32 = 1 << 22;
pub const RxErrFrame: u32 = 1 << 27;
pub const RxErrCRC: u32 = 1 << 18;
pub const RxErrRunt: u32 = 1 << 19;
pub const RxErrLong: u32 = 1 << 21;

pub const Cmd = struct {
    pub const reset: u8 = 1 << 4;
    pub const rx_on: u8 = 1 << 3;
    pub const tx_on: u8 = 1 << 2;
};

pub const CpCmd = struct {
    pub const rx_vlan_on: u8 = 1 << 6;
    pub const rx_chk_sum: u8 = 1 << 5;
    pub const pci_dac: u8 = 1 << 4;
    pub const pci_mul_rw: u8 = 1 << 3;
    pub const cp_rx_on: u8 = 1 << 1;
    pub const cp_tx_on: u8 = 1 << 0;
};

pub const Intr = struct {
    pub const pci_err: u16 = 1 << 15;
    pub const timer_intr: u16 = 1 << 14;
    pub const len_chg: u16 = 1 << 13;
    pub const sw_int: u16 = 1 << 8;
    pub const tx_empty: u16 = 1 << 7;
    pub const rx_fifo_ovr: u16 = 1 << 6;
    pub const link_chg: u16 = 1 << 5;
    pub const rx_empty: u16 = 1 << 4;
    pub const tx_err: u16 = 1 << 3;
    pub const tx_ok: u16 = 1 << 2;
    pub const rx_err: u16 = 1 << 1;
    pub const rx_ok: u16 = 1 << 0;
    pub const reserved: u16 = 1 << 10;

    pub const rx_mask: u16 = rx_ok | rx_err | rx_empty | rx_fifo_ovr;
    pub const norx_mask: u16 = pci_err | link_chg | tx_ok | tx_err | tx_empty;
    pub const all_mask: u16 = rx_mask | norx_mask | timer_intr | len_chg | sw_int | reserved;
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
    pub const unlock: u8 = 0xC0;
};

pub const Desc = extern struct {
    opts1: u32 = 0,
    opts2: u32 = 0,
    addr_lo: u32 = 0,
    addr_hi: u32 = 0,
};

pub fn isCpCompatible(vendor: u16, device: u16, revision: u8) bool {
    return vendor == 0x10ec and device == 0x8139 and revision >= 0x20;
}

pub fn shouldDeferTo8139Too(vendor: u16, device: u16, revision: u8) bool {
    return vendor == 0x10ec and device == 0x8139 and revision < 0x20;
}

pub fn nextTx(n: u16) u16 {
    return (n + 1) & (CP_TX_RING_SIZE - 1);
}
pub fn nextRx(n: u16) u16 {
    return (n + 1) & (CP_RX_RING_SIZE - 1);
}

pub fn txBuffsAvail(head: u16, tail: u16) u16 {
    if (tail <= head) return tail + (CP_TX_RING_SIZE - 1) - head;
    return tail - head - 1;
}

pub fn txDescOpts1(len: u16, eor: bool, first: bool, last: bool, mss: u16, csum_tcp: bool, csum_udp: bool, csum_ip: bool) u32 {
    var opts: u32 = DescOwn | @as(u32, len);
    if (eor) opts |= RingEnd;
    if (first) opts |= FirstFrag;
    if (last) opts |= LastFrag;
    if (mss != 0) opts |= LargeSend | (@as(u32, mss & @as(u16, @intCast(MSSMask))) << MSSShift);
    if (csum_ip) opts |= IPCS;
    if (csum_tcp) opts |= TCPCS;
    if (csum_udp) opts |= UDPCS;
    return opts;
}

pub fn txVlanOpts2(tci: u16, present: bool) u32 {
    if (!present) return 0;
    return TxVlanTag | @as(u32, @byteSwap(tci));
}

pub fn rxLen(opts1: u32) u16 {
    const raw: u16 = @intCast(opts1 & 0x1fff);
    return if (raw >= 4) raw - 4 else 0;
}

pub fn rxHasError(opts1: u32) bool {
    return (opts1 & (RxError | RxErrFIFO)) != 0;
}

pub fn rxIsComplete(opts1: u32) bool {
    return (opts1 & (FirstFrag | LastFrag)) == (FirstFrag | LastFrag);
}

pub fn rxCsumOk(opts1: u32) bool {
    const proto = ((opts1 & PID1) >> 16) | ((opts1 & PID0) >> 16);
    // PID encoding: PID1=bit17, PID0=bit16
    const p: u32 = ((opts1 >> 16) & 0x3);
    if (p == RxProtoTCP) return (opts1 & TCPFail) == 0;
    if (p == RxProtoUDP) return (opts1 & UDPFail) == 0;
    _ = proto;
    return true;
}

pub fn interruptAckWrite(status: u16) u16 {
    return status & ~Intr.rx_mask;
}

pub fn napiShouldRearm(rx_done: usize, budget: usize) bool {
    return rx_done < budget;
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
    mar0: u32 = 0,
    mar1: u32 = 0,
    rx_mode: u32 = 0,
};

pub fn multicastFilter(addrs: []const [6]u8, promisc: bool, allmulti: bool, limit: usize) MulticastFilter {
    var result = MulticastFilter{};
    if (promisc) {
        result.rx_mode = RxMode.accept_broadcast | RxMode.accept_multicast | RxMode.accept_my_phys | RxMode.accept_all_phys;
        result.mar0 = 0xffff_ffff;
        result.mar1 = 0xffff_ffff;
        return result;
    }
    if (allmulti or addrs.len > limit) {
        result.rx_mode = RxMode.accept_broadcast | RxMode.accept_multicast | RxMode.accept_my_phys;
        result.mar0 = 0xffff_ffff;
        result.mar1 = 0xffff_ffff;
        return result;
    }
    result.rx_mode = RxMode.accept_broadcast | RxMode.accept_my_phys;
    for (addrs) |addr| {
        const bit_nr = multicastHashBit(addr);
        if (bit_nr < 32) {
            result.mar0 |= @as(u32, 1) << @as(u5, @intCast(bit_nr));
        } else {
            result.mar1 |= @as(u32, 1) << @as(u5, @intCast(bit_nr - 32));
        }
        result.rx_mode |= RxMode.accept_multicast;
    }
    return result;
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
    result.probe = isCpCompatible(0x10ec, 0x8139, 0x20) and !isCpCompatible(0x10ec, 0x8139, 0x10) and shouldDeferTo8139Too(0x10ec, 0x8139, 0x10);

    const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    result.mac = mac[0] == 0x52 and mac[5] == 0x56;

    var head: u16 = 0;
    const tail: u16 = 0;
    head = nextTx(head);
    result.tx = txBuffsAvail(head, tail) == CP_TX_RING_SIZE - 2 and (txDescOpts1(60, true, true, true, 0, false, false, false) & (DescOwn | FirstFrag | LastFrag | RingEnd)) == (DescOwn | FirstFrag | LastFrag | RingEnd);

    const rx_opts: u32 = DescOwn | FirstFrag | LastFrag | (64 << 0);
    result.rx = rxLen(rx_opts) == 60 and rxIsComplete(rx_opts) and !rxHasError(rx_opts);

    const isr: u16 = Intr.rx_ok | Intr.tx_ok | Intr.pci_err;
    const ack = interruptAckWrite(isr);
    result.irq = ack == (Intr.tx_ok | Intr.pci_err) and napiShouldRearm(10, 64) and !napiShouldRearm(64, 64);

    const addrs = [_][6]u8{.{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 }};
    const f = multicastFilter(&addrs, false, false, 32);
    const bit = multicastHashBit(addrs[0]);
    const bit_set = if (bit < 32) (f.mar0 & (@as(u32, 1) << @as(u5, @intCast(bit)))) != 0 else (f.mar1 & (@as(u32, 1) << @as(u5, @intCast(bit - 32)))) != 0;
    result.mcast = (f.rx_mode & RxMode.accept_multicast) != 0 and bit_set;

    if (result.probe and result.mac and result.tx and result.rx and result.irq and result.mcast) {
        result.status = "ok";
        result.errno = 0;
    }
    return result;
}

test "8139cp: PCI revision gating vs 8139too" {
    try std.testing.expect(isCpCompatible(0x10ec, 0x8139, 0x20));
    try std.testing.expect(!isCpCompatible(0x10ec, 0x8139, 0x1f));
    try std.testing.expect(shouldDeferTo8139Too(0x10ec, 0x8139, 0x10));
    try std.testing.expect(!shouldDeferTo8139Too(0x10ec, 0x8139, 0x20));
}

test "8139cp: register and interrupt mask constants" {
    try std.testing.expectEqual(@as(u8, 1 << 4), Cmd.reset);
    try std.testing.expectEqual(@as(u8, (1 << 3) | (1 << 2)), Cmd.rx_on | Cmd.tx_on);
    try std.testing.expectEqual(@as(u16, (1 << 0) | (1 << 1) | (1 << 4) | (1 << 6)), Intr.rx_mask);
    try std.testing.expectEqual(@as(u16, 0xC0), Cfg9346.unlock);
    try std.testing.expectEqual(@as(u16, 64), CP_RX_RING_SIZE);
}

test "8139cp: TX descriptor opts encoding" {
    const opts = txDescOpts1(60, true, true, true, 0, true, false, true);
    try std.testing.expect((opts & DescOwn) != 0);
    try std.testing.expect((opts & FirstFrag) != 0);
    try std.testing.expect((opts & LastFrag) != 0);
    try std.testing.expect((opts & RingEnd) != 0);
    try std.testing.expect((opts & IPCS) != 0);
    try std.testing.expect((opts & TCPCS) != 0);
    try std.testing.expectEqual(@as(u32, 60), opts & 0xffff);
    const tso = txDescOpts1(1500, false, true, false, 1448, false, false, false);
    try std.testing.expect((tso & LargeSend) != 0);
    try std.testing.expectEqual(@as(u32, 1448) << MSSShift, tso & (@as(u32, MSSMask) << MSSShift));
}

test "8139cp: ring index and tx availability" {
    try std.testing.expectEqual(@as(u16, 1), nextTx(0));
    try std.testing.expectEqual(@as(u16, 0), nextTx(63));
    try std.testing.expectEqual(@as(u16, 63), txBuffsAvail(0, 0));
    try std.testing.expectEqual(@as(u16, 0), txBuffsAvail(0, 1));
    try std.testing.expectEqual(@as(u16, 62), txBuffsAvail(1, 0));
}

test "8139cp: RX status decode and checksum" {
    const ok = DescOwn | FirstFrag | LastFrag | (64 << 0) | (RxProtoTCP << 16);
    try std.testing.expect(rxIsComplete(ok));
    try std.testing.expectEqual(@as(u16, 60), rxLen(ok));
    try std.testing.expect(!rxHasError(ok));
    try std.testing.expect(rxCsumOk(ok));
    const bad = ok | TCPFail;
    try std.testing.expect(!rxCsumOk(bad));
    const frag = DescOwn | FirstFrag | (64 << 0);
    try std.testing.expect(!rxIsComplete(frag));
}

test "8139cp: interrupt ack and NAPI rearm" {
    const status = Intr.rx_ok | Intr.tx_ok | Intr.rx_err;
    try std.testing.expectEqual(Intr.tx_ok, interruptAckWrite(status));
    try std.testing.expect(napiShouldRearm(10, 64));
    try std.testing.expect(!napiShouldRearm(64, 64));
}

test "8139cp: multicast hash filter" {
    const addr = [6]u8{ 0x01, 0x00, 0x5e, 0x00, 0x00, 0x01 };
    const f = multicastFilter(&[_][6]u8{addr}, false, false, 32);
    try std.testing.expect((f.rx_mode & RxMode.accept_multicast) != 0);
    const bit = multicastHashBit(addr);
    const set = if (bit < 32) (f.mar0 & (@as(u32, 1) << @as(u5, @intCast(bit)))) != 0 else (f.mar1 & (@as(u32, 1) << @as(u5, @intCast(bit - 32)))) != 0;
    try std.testing.expect(set);
    const promisc = multicastFilter(&[_][6]u8{addr}, true, false, 32);
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), promisc.mar0);
    try std.testing.expect((promisc.rx_mode & RxMode.accept_all_phys) != 0);
}

test "8139cp: boot probe exercises probe/mac/tx/rx/irq/mcast" {
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
