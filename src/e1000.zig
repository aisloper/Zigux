//! Порт драйвера Intel PRO/1000 Linux 7.3: drivers/net/ethernet/intel/e1000/
//! (e1000_xmit_frame, e1000_clean_tx_irq, e1000_clean_rx_irq, e1000_alloc_rx_buffers),
//! e1000_hw.h/e1000.h (дескрипторы, биты статуса, E1000_DESC_UNUSED).
//! GPL-2.0-only.

const std = @import("std");

pub const MAX_DATA_PER_TXD: usize = 1 << 12;
pub const TX_WAKE_THRESHOLD: usize = 32;
pub const NAPI_BUDGET: usize = 64;
pub const RING_LEN: usize = 16;

pub const TxCmd = struct {
    pub const eop: u8 = 1 << 0;
    pub const ifcs: u8 = 1 << 1;
    pub const insert_csum: u8 = 1 << 2;
    pub const report_status: u8 = 1 << 3;
    pub const tso: u8 = 1 << 6;
};

pub const RxStatus = struct {
    pub const dd: u8 = 1 << 0;
    pub const eop: u8 = 1 << 1;
    pub const tcpcs: u8 = 1 << 5;
    pub const ipcs: u8 = 1 << 6;
};

pub const RxError = struct {
    pub const crc: u8 = 1 << 0;
    pub const symbol: u8 = 1 << 1;
    pub const sequence: u8 = 1 << 2;
    pub const tcp: u8 = 1 << 5;
    pub const ip: u8 = 1 << 6;
    pub const rx: u8 = 1 << 7;
    pub const frame_mask: u8 = crc | symbol | sequence | tcp | ip | rx;
};

pub const TxDesc = struct {
    addr: u64 = 0,
    length: u16 = 0,
    cso: u8 = 0,
    cmd: u8 = 0,
    status: u8 = 0,
    css: u8 = 0,
    special: u16 = 0,
};

pub const RxDesc = struct {
    addr: u64 = 0,
    length: u16 = 0,
    csum: u16 = 0,
    status: u8 = 0,
    errors: u8 = 0,
    special: u16 = 0,
};

pub const TxRing = struct {
    desc: [RING_LEN]TxDesc = @splat(.{}),
    next_to_watch: [RING_LEN]usize = @splat(0),
    next_use: usize = 0,
    next_clean: usize = 0,
    tdh: u16 = 0,
    tdt: u16 = 0,
    stopped: bool = false,
    packets: usize = 0,
    bytes: usize = 0,
    completions: usize = 0,
    wakes: usize = 0,

    /// E1000_DESC_UNUSED(): (clean > use ? 0 : count) + clean - use - 1.
    /// Один слот всегда остаётся свободным, как в драйвере Linux.
    pub fn unused(self: *const TxRing) usize {
        const base: usize = if (self.next_clean > self.next_use) 0 else self.desc.len;
        return base + self.next_clean - self.next_use - 1;
    }

    /// e1000_xmit_frame(): TSO/checksum-offload требуют context-дескриптора,
    /// данные режутся на куски не больше MAX_DATA_PER_TXD; последний несёт RS|EOP.
    pub fn transmit(self: *TxRing, bytes: usize, tso: bool, checksum: bool) !usize {
        if (bytes == 0) return error.Empty;
        const chunks = (bytes + MAX_DATA_PER_TXD - 1) / MAX_DATA_PER_TXD;
        const need = chunks + @as(usize, if (tso or checksum) 1 else 0);
        if (need > self.unused()) {
            self.stopped = true;
            return error.NoDesc;
        }
        const first = self.next_use;
        if (tso or checksum) {
            self.desc[self.next_use] = .{
                .cmd = TxCmd.tso | if (checksum) TxCmd.insert_csum else 0,
            };
            self.next_use = (self.next_use + 1) % self.desc.len;
        }
        var left = bytes;
        var i: usize = 0;
        while (left > 0) : (i += 1) {
            const part = @min(left, MAX_DATA_PER_TXD);
            const idx = self.next_use;
            self.desc[idx] = .{
                .addr = 0x1000 + @as(u64, idx) * MAX_DATA_PER_TXD,
                .length = @intCast(part),
                .cmd = TxCmd.ifcs | TxCmd.eop | if (i + 1 == chunks) TxCmd.report_status else 0,
                .cso = if (checksum and i == 0) 14 else 0,
            };
            self.next_use = (self.next_use + 1) % self.desc.len;
            left -= part;
        }
        const eop = (self.next_use + self.desc.len - 1) % self.desc.len;
        self.next_to_watch[first] = eop;
        self.packets += 1;
        self.bytes += bytes;
        self.tdt = @intCast(self.next_use);
        return first;
    }

    /// e1000_clean_tx_irq(): очищаем только по EOP-дескриптору с DD,
    /// wake_queue когда свободных слотов снова достаточно.
    pub fn clean(self: *TxRing, budget: usize) usize {
        var count: usize = 0;
        var i = self.next_clean;
        while (count < budget and count < self.desc.len) {
            const eop = self.next_to_watch[i];
            if ((self.desc[eop].status & 1) == 0) break;
            while (true) {
                self.desc[i] = .{};
                self.next_to_watch[i] = 0;
                i = (i + 1) % self.desc.len;
                count += 1;
                if (i == eop + 1 or (eop + 1 == self.desc.len and i == 0)) break;
                if (count >= budget) break;
            }
            self.completions += 1;
            if (count >= budget) break;
        }
        self.next_clean = i;
        self.tdh = @intCast(i);
        if (count != 0 and self.stopped and
            self.unused() >= @min(TX_WAKE_THRESHOLD, self.desc.len - 1))
        {
            self.stopped = false;
            self.wakes += 1;
        }
        return count;
    }
};

pub const RxRing = struct {
    desc: [RING_LEN]RxDesc = @splat(.{}),
    next_use: usize = 0,
    next_clean: usize = 0,
    fill_next: usize = 0,
    packets: usize = 0,
    bytes: usize = 0,
    drops: usize = 0,
    csum_valid: usize = 0,
    reposted: usize = 0,

    pub fn unused(self: *const RxRing) usize {
        const base: usize = if (self.next_clean > self.next_use) 0 else self.desc.len;
        return base + self.next_clean - self.next_use - 1;
    }

    /// e1000_alloc_rx_buffers(): новые буферы выставляются в свободные слоты
    /// и только после этого next_use сдвигается (DD hardware выставит позже).
    pub fn post(self: *RxRing, n: usize) !void {
        if (n > self.unused()) return error.NoDesc;
        for (0..n) |_| {
            const idx = self.next_use;
            self.desc[idx] = .{ .addr = 0x2000 + @as(u64, idx) * 2048 };
            self.next_use = (self.next_use + 1) % self.desc.len;
            self.reposted += 1;
        }
    }

    /// Модель DMA-записи: DD выставляется после записи длины и статуса.
    pub fn ingest(self: *RxRing, bytes: usize, tcp_csum_ok: bool, errors: u8) !void {
        if (self.unused() == 0) return error.NoDesc;
        const idx = self.fill_next;
        self.desc[idx].length = @intCast(@min(bytes, 65535));
        self.desc[idx].csum = 0;
        self.desc[idx].errors = errors;
        self.desc[idx].status = RxStatus.dd | RxStatus.eop |
            if (tcp_csum_ok) RxStatus.tcpcs | RxStatus.ipcs else 0;
        self.fill_next = (self.fill_next + 1) % self.desc.len;
    }

    /// e1000_clean_rx_irq(): NAPI-бюджет, проверка DD/EOP и ошибок кадра,
    /// повторный постинг буферов после очистки.
    pub fn clean(self: *RxRing, budget: usize) usize {
        var processed: usize = 0;
        var accepted: usize = 0;
        while ((self.desc[self.next_clean].status & RxStatus.dd) != 0 and processed < budget) {
            processed += 1;
            const d = self.desc[self.next_clean];
            self.next_clean = (self.next_clean + 1) % self.desc.len;
            if ((d.status & RxStatus.eop) == 0 or (d.errors & RxError.frame_mask) != 0) {
                self.drops += 1;
                continue;
            }
            if ((d.status & (RxStatus.tcpcs | RxStatus.ipcs)) == (RxStatus.tcpcs | RxStatus.ipcs))
                self.csum_valid += 1;
            self.packets += 1;
            self.bytes += d.length;
            accepted += 1;
        }
        if (processed != 0) self.post(processed) catch {};
        return accepted;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    ring: bool = false,
    tx: bool = false,
    rx: bool = false,
    csum: bool = false,
    napi: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    var tx = TxRing{};
    p.ring = tx.unused() == RING_LEN - 1 and tx.desc.len == RING_LEN;

    const first = tx.transmit(10000, true, true) catch return p;
    const ctx_cmd = tx.desc[first].cmd;
    p.tx = first == 0 and tx.desc[0].addr == 0 and
        (ctx_cmd & TxCmd.tso) != 0 and (ctx_cmd & TxCmd.insert_csum) != 0 and
        tx.desc[1].length == MAX_DATA_PER_TXD and
        tx.desc[2].length == MAX_DATA_PER_TXD and
        tx.desc[3].length == 10000 - 2 * MAX_DATA_PER_TXD and
        (tx.desc[3].cmd & TxCmd.eop) != 0 and
        (tx.desc[3].cmd & TxCmd.report_status) != 0 and
        tx.next_use == 4 and tx.tdt == 4;

    tx.desc[3].status = 1;
    const reclaimed = tx.clean(4);
    p.tx = p.tx and reclaimed == 4 and tx.completions == 1 and tx.next_clean == 4;

    var rx = RxRing{};
    rx.post(8) catch return p;
    rx.ingest(64, true, 0) catch return p;
    rx.ingest(64, false, RxError.crc) catch return p;
    const got = rx.clean(NAPI_BUDGET);
    p.rx = got == 1 and rx.packets == 1 and rx.drops == 1 and
        rx.bytes == 64 and rx.reposted == 10;

    var csum_rx = RxRing{};
    csum_rx.post(2) catch return p;
    csum_rx.ingest(100, true, 0) catch return p;
    _ = csum_rx.clean(NAPI_BUDGET);
    p.csum = csum_rx.csum_valid == 1;

    var limited = RxRing{};
    limited.post(4) catch return p;
    for (0..4) |_| limited.ingest(64, true, 0) catch return p;
    const first_pass = limited.clean(2);
    const second_pass = limited.clean(2);
    p.napi = first_pass == 2 and second_pass == 2 and limited.packets == 4;

    p.status = "ok";
    return p;
}

test "e1000: transmit splits TSO data and inserts a context descriptor" {
    var tx = TxRing{};
    const first = try tx.transmit(9000, true, false);
    try std.testing.expectEqual(@as(usize, 0), first);
    try std.testing.expectEqual(@as(u8, TxCmd.tso), tx.desc[0].cmd);
    try std.testing.expectEqual(@as(u16, MAX_DATA_PER_TXD), tx.desc[1].length);
    try std.testing.expectEqual(@as(u16, MAX_DATA_PER_TXD), tx.desc[2].length);
    try std.testing.expectEqual(@as(u16, 9000 - 2 * MAX_DATA_PER_TXD), tx.desc[3].length);
    try std.testing.expect((tx.desc[3].cmd & TxCmd.report_status) != 0);
    try std.testing.expectEqual(@as(usize, 4), tx.next_use);
}

test "e1000: transmit stops the queue when descriptors run out" {
    var tx = TxRing{};
    for (0..RING_LEN - 1) |_| _ = try tx.transmit(64, false, false);
    try std.testing.expectError(error.NoDesc, tx.transmit(64, false, false));
    try std.testing.expect(tx.stopped);
    try std.testing.expectEqual(@as(usize, 0), tx.unused());
}

test "e1000: clean TX uses the EOP DD bit and wakes the queue" {
    var tx = TxRing{};
    for (0..RING_LEN - 1) |_| _ = try tx.transmit(64, false, false);
    tx.stopped = true;
    try std.testing.expectEqual(@as(usize, 0), tx.clean(RING_LEN));
    for (0..RING_LEN - 1) |i| tx.desc[i].status = 1;
    try std.testing.expectEqual(@as(usize, RING_LEN - 1), tx.clean(RING_LEN));
    try std.testing.expectEqual(@as(usize, RING_LEN - 1), tx.completions);
    try std.testing.expect(!tx.stopped);
    try std.testing.expectEqual(@as(usize, 1), tx.wakes);
    try std.testing.expectEqual(@as(usize, RING_LEN - 1), tx.unused());
}

test "e1000: receive drops CRC errors and reposts consumed buffers" {
    var rx = RxRing{};
    try rx.post(4);
    try rx.ingest(128, true, 0);
    try rx.ingest(128, false, RxError.crc);
    try std.testing.expectEqual(@as(usize, 1), rx.clean(NAPI_BUDGET));
    try std.testing.expectEqual(@as(usize, 1), rx.packets);
    try std.testing.expectEqual(@as(usize, 1), rx.drops);
    try std.testing.expectEqual(@as(usize, 128), rx.bytes);
    try std.testing.expectEqual(@as(usize, 6), rx.reposted);
}

test "e1000: receive honors the NAPI budget across calls" {
    var rx = RxRing{};
    try rx.post(4);
    for (0..4) |_| try rx.ingest(64, true, 0);
    try std.testing.expectEqual(@as(usize, 2), rx.clean(2));
    try std.testing.expectEqual(@as(usize, 2), rx.clean(2));
    try std.testing.expectEqual(@as(usize, 4), rx.packets);
    try std.testing.expectEqual(@as(usize, 4), rx.csum_valid);
}

test "e1000: boot probe exercises rings, TX, RX, checksum and NAPI" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.ring);
    try std.testing.expect(p.tx);
    try std.testing.expect(p.rx);
    try std.testing.expect(p.csum);
    try std.testing.expect(p.napi);
}
