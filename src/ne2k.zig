//! Порт NE2000/RTL8019 (8390 ISA) ядра Linux 7.3: probe/SAPROM, layout
//! кольца RX/TX, заголовок кадра, ISR и recovery при overrun.
//! Источники: drivers/net/ethernet/8390/ne.c, lib8390.c, 8390.h.
//! GPL-2.0-only (алгоритмы и константы).

const std = @import("std");

pub const PAGE_SIZE: u16 = 256;
pub const TX_PAGES: u8 = 12;
pub const HDR_SIZE: usize = 4;
pub const MAX_SERVICE: u8 = 12;

pub const NE_CMD: u8 = 0x00;
pub const NE_DATAPORT: u8 = 0x10;
pub const NE_RESET: u8 = 0x1f;
pub const NE_IO_EXTENT: u8 = 0x20;

pub const DCR_VAL: u8 = 0x49;
pub const E8390_STOP: u8 = 0x01;
pub const E8390_START: u8 = 0x02;
pub const E8390_TRANS: u8 = 0x04;
pub const E8390_RREAD: u8 = 0x08;
pub const E8390_NODMA: u8 = 0x20;
pub const E8390_PAGE0: u8 = 0x00;
pub const E8390_PAGE1: u8 = 0x40;

pub const EN0_ISR: u8 = 0x07;
pub const ENISR_RX: u8 = 0x01;
pub const ENISR_TX: u8 = 0x02;
pub const ENISR_RX_ERR: u8 = 0x04;
pub const ENISR_TX_ERR: u8 = 0x08;
pub const ENISR_OVER: u8 = 0x10;
pub const ENISR_COUNTERS: u8 = 0x20;
pub const ENISR_RDC: u8 = 0x40;
pub const ENISR_RESET: u8 = 0x80;
pub const ENISR_ALL: u8 = 0x3f;

pub const ENRSR_RXOK: u8 = 0x01;
pub const E8390_RXOFF: u8 = 0x20;
pub const E8390_TXOFF: u8 = 0x02;
pub const E8390_TXCONFIG: u8 = 0x00;
pub const E8390_RXCONFIG: u8 = 0x04;

pub const RxHeader = struct {
    status: u8,
    next: u8,
    count: u16,
};

pub const RingLayout = struct {
    tx_start: u8,
    rx_start: u8,
    stop: u8,
    word16: bool,

    pub fn ne1sm() RingLayout {
        return .{ .tx_start = 0x20, .rx_start = 0x20 + TX_PAGES, .stop = 0x40, .word16 = false };
    }
    pub fn nesm(word16: bool) RingLayout {
        return .{ .tx_start = 0x40, .rx_start = 0x40 + TX_PAGES, .stop = 0x80, .word16 = word16 };
    }
    pub fn rxPages(self: RingLayout) u8 {
        return self.stop - self.rx_start;
    }
};

pub const ProbeResult = struct {
    word16: bool,
    tx_start: u8,
    rx_start: u8,
    stop: u8,
    mac: [6]u8,
    rtl8019: bool,
};

pub fn validMac(mac: [6]u8) bool {
    var nonzero = false;
    var ones = true;
    for (mac) |b| {
        if (b != 0) nonzero = true;
        if (b != 0xff) ones = false;
    }
    return nonzero and !ones;
}

/// 32 байта SAPROM читаются DMA; в 16-битном режиме байты продублированы.
pub fn decodeProm(prom32: [32]u8, dcr: u8, rcntlo: u8, rcnthi: u8) ProbeResult {
    var word16 = true;
    for (0..16) |i| {
        if (prom32[2 * i] != prom32[2 * i + 1]) {
            word16 = false;
            break;
        }
    }
    var mac = std.mem.zeroes([6]u8);
    if (word16) {
        for (0..6) |i| mac[i] = prom32[2 * i];
    } else {
        for (0..6) |i| mac[i] = prom32[i];
    }

    var layout = if (word16) RingLayout.nesm(true) else RingLayout.ne1sm();
    const rtl8019 = !word16 and (dcr & 1) == 0 and rcntlo == 0x50 and rcnthi == 0x70;
    if (rtl8019) layout.stop = 0x60;
    const rtl_prefix = mac[0] == 0x00 and mac[1] == 0x00 and mac[2] == 0xe8;
    return .{
        .word16 = word16,
        .tx_start = layout.tx_start,
        .rx_start = layout.rx_start,
        .stop = layout.stop,
        .mac = mac,
        .rtl8019 = rtl8019 or rtl_prefix,
    };
}

pub fn nextRxFrame(this_frame: u8, pkt_len: usize) u8 {
    const pages: u16 = @intCast(1 + ((pkt_len + 4) >> 8));
    return @truncate(@as(u16, this_frame) + pages);
}

pub fn validNextPtr(next: u8, expected: u8, rx_start: u8, rx_pages: u8) bool {
    const stop = @as(u16, rx_start) + rx_pages;
    var c0: u16 = expected;
    var c1: u16 = @as(u16, expected) + 1;
    if (c0 >= stop) c0 = @as(u16, rx_start) + (c0 - stop);
    if (c1 >= stop) c1 = @as(u16, rx_start) + (c1 - stop);
    return next == @as(u8, @truncate(c0)) or next == @as(u8, @truncate(c1));
}

pub fn wrapPage(page: u8, rx_start: u8, stop: u8) u8 {
    if (page >= stop) return rx_start;
    return page;
}

pub fn rxAccept(status: u8, pkt_len: usize) bool {
    if ((status & 0x0f) != ENRSR_RXOK) return false;
    return pkt_len >= 60 and pkt_len <= 1518;
}

pub const InitPlan = struct {
    cmd_stop: u8 = E8390_NODMA | E8390_PAGE0 | E8390_STOP,
    dcfg: u8,
    rxcr_off: u8 = E8390_RXOFF,
    txcr_off: u8 = E8390_TXOFF,
    tx_start: u8,
    rx_start: u8,
    boundary: u8,
    stop: u8,
    imr_start: u8 = ENISR_ALL,
    txcr_start: u8 = E8390_TXCONFIG,
    rxcr_start: u8 = E8390_RXCONFIG,
};

pub fn initPlan(layout: RingLayout) InitPlan {
    return .{
        .dcfg = if (layout.word16) 0x49 else 0x48,
        .tx_start = layout.tx_start,
        .rx_start = layout.rx_start,
        .boundary = layout.stop - 1,
        .stop = layout.stop,
    };
}

pub const TxSlot = struct {
    page: u8,
    len: u16,
    busy: bool = false,
};

pub const Nic = struct {
    layout: RingLayout,
    tx1: TxSlot = undefined,
    tx2: TxSlot = undefined,
    txing: bool = false,
    cur_rx: u8 = 0,
    boundary: u8 = 0,
    tx_packets: usize = 0,
    rx_packets: usize = 0,
    rx_errors: usize = 0,
    overruns: usize = 0,

    pub fn init(self: *Nic, layout: RingLayout) InitPlan {
        self.layout = layout;
        self.tx1 = .{ .page = layout.tx_start, .len = 0, .busy = false };
        self.tx2 = .{ .page = layout.tx_start + TX_PAGES / 2, .len = 0, .busy = false };
        self.txing = false;
        self.cur_rx = layout.rx_start;
        self.boundary = layout.stop - 1;
        return initPlan(layout);
    }

    pub fn txSlot(self: *Nic) ?*TxSlot {
        if (!self.tx1.busy) return &self.tx1;
        if (!self.tx2.busy) return &self.tx2;
        return null;
    }

    pub fn queueTx(self: *Nic, len: u16) bool {
        const slot = self.txSlot() orelse return false;
        slot.len = len;
        slot.busy = true;
        if (!self.txing) self.txing = true;
        return true;
    }

    pub fn txComplete(self: *Nic) bool {
        if (self.tx1.busy) {
            self.tx1.busy = false;
            self.tx_packets += 1;
        } else if (self.tx2.busy) {
            self.tx2.busy = false;
            self.tx_packets += 1;
        } else return false;
        self.txing = self.tx1.busy or self.tx2.busy;
        return true;
    }

    pub fn receive(self: *Nic, header: RxHeader) bool {
        const pkt_len: usize = if (header.count >= HDR_SIZE) header.count - HDR_SIZE else 0;
        if (!rxAccept(header.status, pkt_len)) {
            self.rx_errors += 1;
            return false;
        }
        const expected = nextRxFrame(self.boundary +% 1, pkt_len);
        if (!validNextPtr(header.next, expected, self.layout.rx_start, self.layout.rxPages())) {
            self.rx_errors += 1;
            return false;
        }
        self.cur_rx = wrapPage(header.next, self.layout.rx_start, self.layout.stop);
        const next_boundary = if (self.cur_rx == self.layout.rx_start) self.layout.stop - 1 else self.cur_rx - 1;
        self.boundary = next_boundary;
        self.rx_packets += 1;
        return true;
    }

    pub fn handleIsr(self: *Nic, isr: u8) u8 {
        var ack: u8 = 0;
        if ((isr & ENISR_OVER) != 0) {
            self.overruns += 1;
            ack |= ENISR_OVER;
            self.boundary = self.layout.stop - 1;
            self.cur_rx = self.layout.rx_start;
            return ack;
        }
        if ((isr & (ENISR_RX | ENISR_RX_ERR)) != 0) ack |= ENISR_RX | ENISR_RX_ERR;
        if ((isr & ENISR_TX) != 0) {
            _ = self.txComplete();
            ack |= ENISR_TX;
        } else if ((isr & ENISR_TX_ERR) != 0) {
            _ = self.txComplete();
            ack |= ENISR_TX_ERR;
        }
        if ((isr & ENISR_COUNTERS) != 0) ack |= ENISR_COUNTERS;
        if ((isr & ENISR_RDC) != 0) ack |= ENISR_RDC;
        return ack;
    }
};

pub const Probe = struct {
    status: []const u8 = "failed",
    probe: bool = false,
    mac: bool = false,
    init: bool = false,
    tx: bool = false,
    rx: bool = false,
    irq: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};
    var prom = std.mem.zeroes([32]u8);
    const mac = [6]u8{ 0x00, 0x11, 0x22, 0x33, 0x44, 0x55 };
    for (mac, 0..) |b, i| {
        prom[2 * i] = b;
        prom[2 * i + 1] = b;
    }
    prom[14] = 0x57;
    prom[15] = 0x57;
    const pr = decodeProm(prom, DCR_VAL, 0x00, 0x00);
    result.probe = pr.word16 and pr.tx_start == 0x40 and pr.rx_start == 0x4c and pr.stop == 0x80;
    result.mac = validMac(pr.mac) and std.mem.eql(u8, &pr.mac, &mac);

    var nic = Nic{ .layout = RingLayout.ne1sm() };
    const plan = nic.init(RingLayout.nesm(true));
    result.init = plan.cmd_stop == (E8390_NODMA | E8390_PAGE0 | E8390_STOP) and
        plan.dcfg == 0x49 and plan.tx_start == 0x40 and plan.stop == 0x80 and
        nic.boundary == 0x7f and nic.cur_rx == 0x4c;

    result.tx = nic.queueTx(60) and nic.tx1.busy and nic.txing;
    result.tx = result.tx and nic.queueTx(64) and nic.tx2.busy;
    result.tx = result.tx and !nic.queueTx(64);
    result.tx = result.tx and nic.handleIsr(ENISR_TX) == ENISR_TX;
    result.tx = result.tx and !nic.tx1.busy and nic.tx2.busy and nic.tx_packets == 1;

    const ok = nic.receive(.{ .status = ENRSR_RXOK, .next = 0x4d, .count = 64 });
    result.rx = ok and nic.rx_packets == 1 and nic.cur_rx == 0x4d and nic.boundary == 0x4c;
    result.rx = result.rx and !nic.receive(.{ .status = 0, .next = 0x4d, .count = 64 });

    const ack = nic.handleIsr(ENISR_OVER | ENISR_RDC);
    result.irq = ack == ENISR_OVER and nic.overruns == 1 and nic.cur_rx == 0x4c and nic.boundary == 0x7f;

    result.status = "ok";
    result.errno = 0;
    return result;
}

test "ne2k: PROM dedupe selects 16-bit NE2000 layout and MAC" {
    var prom = std.mem.zeroes([32]u8);
    const mac = [6]u8{ 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 };
    for (mac, 0..) |b, i| {
        prom[2 * i] = b;
        prom[2 * i + 1] = b;
    }
    const pr = decodeProm(prom, DCR_VAL, 0, 0);
    try std.testing.expect(pr.word16);
    try std.testing.expect(std.mem.eql(u8, &pr.mac, &mac));
    try std.testing.expectEqual(@as(u8, 0x40), pr.tx_start);
    try std.testing.expectEqual(@as(u8, 0x4c), pr.rx_start);
    try std.testing.expectEqual(@as(u8, 0x80), pr.stop);
}

test "ne2k: RTL8019 8-bit quirk sets stop page 0x60" {
    var prom = std.mem.zeroes([32]u8);
    prom[0] = 0x00;
    prom[1] = 0x00;
    prom[2] = 0xe8;
    prom[3] = 0x11;
    prom[4] = 0x22;
    prom[5] = 0x33;
    const pr = decodeProm(prom, 0x48, 0x50, 0x70);
    try std.testing.expect(!pr.word16);
    try std.testing.expect(pr.rtl8019);
    try std.testing.expectEqual(@as(u8, 0x60), pr.stop);
    try std.testing.expectEqual(@as(u8, 0x20), pr.tx_start);
    try std.testing.expectEqual(@as(u8, 0x2c), pr.rx_start);
}

test "ne2k: init plan and NIC state match 8390 ring layout" {
    var nic = Nic{ .layout = RingLayout.ne1sm() };
    const plan = nic.init(RingLayout.nesm(true));
    try std.testing.expectEqual(E8390_NODMA | E8390_PAGE0 | E8390_STOP, plan.cmd_stop);
    try std.testing.expectEqual(@as(u8, 0x49), plan.dcfg);
    try std.testing.expectEqual(@as(u8, 0x20), plan.rxcr_off);
    try std.testing.expectEqual(@as(u8, 0x02), plan.txcr_off);
    try std.testing.expectEqual(@as(u8, 0x7f), nic.boundary);
    try std.testing.expectEqual(@as(u8, 0x4c), nic.cur_rx);
    try std.testing.expectEqual(@as(u8, 0x40), nic.tx1.page);
    try std.testing.expectEqual(@as(u8, 0x46), nic.tx2.page);
}

test "ne2k: two TX slots, busy reject and completion bookkeeping" {
    var nic = Nic{ .layout = RingLayout.ne1sm() };
    _ = nic.init(RingLayout.nesm(true));
    try std.testing.expect(nic.queueTx(60));
    try std.testing.expect(nic.queueTx(128));
    try std.testing.expect(!nic.queueTx(128));
    try std.testing.expect(nic.tx1.busy and nic.tx2.busy and nic.txing);
    try std.testing.expect(nic.txComplete());
    try std.testing.expect(!nic.tx1.busy and nic.tx2.busy);
    try std.testing.expectEqual(@as(usize, 1), nic.tx_packets);
}

test "ne2k: rx header next-frame formula and pointer validation" {
    try std.testing.expectEqual(@as(u8, 0x4d), nextRxFrame(0x4c, 60));
    try std.testing.expectEqual(@as(u8, 0x4e), nextRxFrame(0x4c, 252));
    try std.testing.expect(validNextPtr(0x4d, 0x4d, 0x4c, 0x34));
    try std.testing.expect(validNextPtr(0x4e, 0x4d, 0x4c, 0x34));
    try std.testing.expect(!validNextPtr(0x60, 0x4d, 0x4c, 0x34));
}

test "ne2k: rx accept/reject by status and length, ring advances" {
    var nic = Nic{ .layout = RingLayout.ne1sm() };
    _ = nic.init(RingLayout.nesm(true));
    try std.testing.expect(rxAccept(ENRSR_RXOK, 60));
    try std.testing.expect(!rxAccept(0, 60));
    try std.testing.expect(!rxAccept(ENRSR_RXOK, 59));
    try std.testing.expect(!rxAccept(ENRSR_RXOK, 1519));
    try std.testing.expect(nic.receive(.{ .status = ENRSR_RXOK, .next = 0x4d, .count = 64 }));
    try std.testing.expectEqual(@as(u8, 0x4d), nic.cur_rx);
    try std.testing.expectEqual(@as(u8, 0x4c), nic.boundary);
    try std.testing.expect(!nic.receive(.{ .status = 0x02, .next = 0x4e, .count = 64 }));
    try std.testing.expectEqual(@as(usize, 1), nic.rx_errors);
}

test "ne2k: ISR dispatch acks TX/RX and overrun recovery resets ring" {
    var nic = Nic{ .layout = RingLayout.ne1sm() };
    _ = nic.init(RingLayout.nesm(true));
    _ = nic.queueTx(60);
    const ack = nic.handleIsr(ENISR_TX | ENISR_RX);
    try std.testing.expectEqual(ENISR_TX | ENISR_RX | ENISR_RX_ERR, ack);
    try std.testing.expectEqual(@as(usize, 1), nic.tx_packets);

    const over = nic.handleIsr(ENISR_OVER | ENISR_RDC);
    try std.testing.expectEqual(ENISR_OVER, over);
    try std.testing.expectEqual(@as(usize, 1), nic.overruns);
    try std.testing.expectEqual(@as(u8, 0x4c), nic.cur_rx);
    try std.testing.expectEqual(@as(u8, 0x7f), nic.boundary);
}

test "ne2k: boot probe exercises probe, mac, init, tx, rx and irq" {
    const result = probe();
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expect(result.probe);
    try std.testing.expect(result.mac);
    try std.testing.expect(result.init);
    try std.testing.expect(result.tx);
    try std.testing.expect(result.rx);
    try std.testing.expect(result.irq);
    try std.testing.expectEqual(@as(u8, 0), result.errno);
}
