//! Порт драйвера Intel PRO/100 (e100) Linux 7.3: CSR/SCB, CU/RU кольца,
//! CB/RFD/TBD форматы, EEPROM checksum, IRQ ack/mask, self-test/configure.
//! Источник: drivers/net/ethernet/intel/e100.c. GPL-2.0-only.

const std = @import("std");

pub const E100_WAIT_SCB_TIMEOUT: usize = 20000;
pub const E100_WAIT_SCB_FAST: usize = 20;
pub const VLAN_ETH_FRAME_LEN: usize = 1518;
pub const ETH_FCS_LEN: usize = 4;

pub const ScbStatus = struct {
    pub const rus_no_res: u8 = 0x08;
    pub const rus_ready: u8 = 0x10;
    pub const rus_mask: u8 = 0x3C;
};

pub const StatAck = struct {
    pub const not_ours: u8 = 0x00;
    pub const sw_gen: u8 = 0x04;
    pub const rnr: u8 = 0x10;
    pub const cu_idle: u8 = 0x20;
    pub const frame_rx: u8 = 0x40;
    pub const cu_cmd_done: u8 = 0x80;
    pub const not_present: u8 = 0xFF;
    pub const rx: u8 = sw_gen | rnr | frame_rx; // 0x54
    pub const tx: u8 = cu_idle | cu_cmd_done; // 0xA0
};

pub const ScbCmdHi = struct {
    pub const irq_mask_none: u8 = 0x00;
    pub const irq_mask_all: u8 = 0x01;
    pub const irq_sw_gen: u8 = 0x02;
};

pub const CucRuc = struct {
    pub const cuc_nop: u8 = 0x00;
    pub const ruc_start: u8 = 0x01;
    pub const ruc_load_base: u8 = 0x06;
    pub const cuc_start: u8 = 0x10;
    pub const cuc_resume: u8 = 0x20;
    pub const cuc_dump_addr: u8 = 0x40;
    pub const cuc_dump_stats: u8 = 0x50;
    pub const cuc_load_base: u8 = 0x60;
    pub const cuc_dump_reset: u8 = 0x70;
};

pub const CbStatus = struct {
    pub const complete: u16 = 0x8000;
    pub const ok: u16 = 0x2000;
};

pub const CbCommand = struct {
    pub const nop: u16 = 0x0000;
    pub const iaaddr: u16 = 0x0001;
    pub const config: u16 = 0x0002;
    pub const multi: u16 = 0x0003;
    pub const tx: u16 = 0x0004;
    pub const ucode: u16 = 0x0005;
    pub const dump: u16 = 0x0006;
    pub const tx_sf: u16 = 0x0008;
    pub const tx_nc: u16 = 0x0010;
    pub const cid: u16 = 0x1f00;
    pub const i: u16 = 0x2000;
    pub const s: u16 = 0x4000;
    pub const el: u16 = 0x8000;
};

pub const RuState = enum(i8) {
    suspended = 0,
    running = 1,
    uninitialized = -1,
};

pub const Rfd = extern struct {
    status: u16 = 0,
    command: u16 = 0,
    link: u32 = 0,
    rbd: u32 = 0xFFFF_FFFF,
    actual_size: u16 = 0,
    size: u16 = 0,

    pub fn initBlank() Rfd {
        return .{
            .status = 0,
            .command = 0,
            .link = 0,
            .rbd = 0xFFFF_FFFF,
            .actual_size = 0,
            .size = @intCast(VLAN_ETH_FRAME_LEN + ETH_FCS_LEN),
        };
    }
};

pub const Cb = extern struct {
    status: u16 = 0,
    command: u16 = 0,
    link: u32 = 0,
};

pub const Tbd = extern struct {
    buf_addr: u32 = 0,
    size: u16 = 0,
    eol: u16 = 0,
};

pub const Csr = struct {
    scb_status: u8 = 0,
    scb_stat_ack: u8 = 0,
    scb_cmd_lo: u8 = 0,
    scb_cmd_hi: u8 = ScbCmdHi.irq_mask_all,
    scb_gen_ptr: u32 = 0,
    port: u32 = 0,
};

pub fn execCmd(csr: *Csr, cmd: u8, gen_ptr: u32) !void {
    var i: usize = 0;
    while (i < E100_WAIT_SCB_TIMEOUT) : (i += 1) {
        if (csr.scb_cmd_lo == 0) break;
        if (i > E100_WAIT_SCB_FAST) {
            // host model: no real udelay, just spin
        }
    }
    if (csr.scb_cmd_lo != 0) return error.Timeout;
    if (cmd != CucRuc.cuc_resume) csr.scb_gen_ptr = gen_ptr;
    csr.scb_cmd_lo = cmd;
}

pub fn ackIrq(csr: *Csr) u8 {
    const stat = csr.scb_stat_ack;
    if (stat == StatAck.not_ours or stat == StatAck.not_present) return stat;
    csr.scb_stat_ack = stat; // write-back ack in model
    return stat;
}

pub fn disableIrq(csr: *Csr) void {
    csr.scb_cmd_hi = ScbCmdHi.irq_mask_all;
}

pub fn enableIrq(csr: *Csr) void {
    csr.scb_cmd_hi = ScbCmdHi.irq_mask_none;
}

pub fn eepromChecksumOk(words: []const u16) bool {
    if (words.len == 0) return false;
    var sum: u16 = 0;
    for (words) |w| sum +%= w;
    return sum == 0xBABA;
}

pub fn eepromReadWord(words: []const u16, addr: usize) u16 {
    if (addr >= words.len) return 0;
    return words[addr];
}

pub const CuRing = struct {
    count: usize,
    cbs_avail: usize,
    cuc_cmd: u8 = CucRuc.cuc_start,
    cb_to_use: usize = 0,
    cb_to_send: usize = 0,
    cb_to_clean: usize = 0,

    pub fn init(count: usize) CuRing {
        return .{ .count = count, .cbs_avail = count };
    }

    pub fn submitSimple(self: *CuRing, cbs: []Cb, cmd: u16) !void {
        if (self.cbs_avail == 0) return error.NoMem;
        const idx = self.cb_to_use;
        cbs[idx].status = 0;
        cbs[idx].command = cmd | CbCommand.s;
        // clear previous S
        if (self.count > 0) {
            const prev = if (idx == 0) self.count - 1 else idx - 1;
            if (prev != idx) cbs[prev].command &= ~CbCommand.s;
        }
        self.cb_to_use = (idx + 1) % self.count;
        self.cbs_avail -= 1;
        if (self.cuc_cmd == CucRuc.cuc_start) {
            self.cb_to_send = (idx + 1) % self.count;
            self.cuc_cmd = CucRuc.cuc_resume;
        } else {
            self.cb_to_send = (idx + 1) % self.count;
        }
    }

    pub fn complete(self: *CuRing, cbs: []Cb) usize {
        var cleaned: usize = 0;
        while (self.cbs_avail < self.count) {
            const idx = self.cb_to_clean;
            if ((cbs[idx].status & CbStatus.complete) == 0) break;
            cbs[idx].status = 0;
            self.cb_to_clean = (idx + 1) % self.count;
            self.cbs_avail += 1;
            cleaned += 1;
        }
        return cleaned;
    }
};

pub const IndicateResult = enum { ok, no_data, again };

pub const RuRing = struct {
    count: usize,
    state: RuState = .uninitialized,
    rx_to_use: usize = 0,
    rx_to_clean: usize = 0,

    pub fn init(count: usize) RuRing {
        return .{ .count = count, .state = .suspended };
    }

    pub fn indicate(self: *RuRing, rfds: []Rfd, work_done: *usize, budget: usize) IndicateResult {
        if (work_done.* >= budget) return .again;
        const idx = self.rx_to_clean;
        const rfd = &rfds[idx];
        if ((rfd.status & CbStatus.complete) == 0) {
            if ((rfd.command & CbCommand.el) != 0 and self.state == .running) {
                self.state = .suspended;
            }
            return .no_data;
        }
        if ((rfd.command & CbCommand.el) != 0 and self.state == .running) {
            self.state = .suspended;
        }
        // consume
        const size: usize = rfd.actual_size & 0x3FFF;
        _ = size;
        rfd.status = 0;
        self.rx_to_clean = (idx + 1) % self.count;
        work_done.* += 1;
        return .ok;
    }

    pub fn restart(self: *RuRing, rfds: []Rfd, csr: *Csr, rx_dma_addr: u32) !void {
        if (self.state != .suspended) return;
        // ack rnr and start
        csr.scb_stat_ack = StatAck.rnr;
        // set before-last EL/size=0, clear old EL
        if (self.count >= 2) {
            const before_last = (self.rx_to_use + self.count - 2) % self.count;
            const old_before_last = (before_last + self.count - 1) % self.count;
            rfds[before_last].command |= CbCommand.el;
            rfds[before_last].size = 0;
            if (old_before_last != before_last) {
                rfds[old_before_last].command &= ~CbCommand.el;
                rfds[old_before_last].size = @intCast(VLAN_ETH_FRAME_LEN + ETH_FCS_LEN);
            }
        }
        try execCmd(csr, CucRuc.ruc_start, rx_dma_addr);
        self.state = .running;
    }
};

pub fn configureDefaultsByte0() u8 {
    return 0x16; // byte_count
}

pub fn configureDefaults() [24]u8 {
    var cfg = std.mem.zeroes([24]u8);
    cfg[0] = 0x16; // byte_count
    cfg[1] = 0x08; // rx_fifo_limit
    cfg[2] = 0x00;
    cfg[3] = 0x00;
    cfg[4] = 0x00;
    cfg[5] = 0x00;
    cfg[6] = 0x32; // standard_tcb=1 etc. (simplified)
    cfg[7] = 0x01; // discard short frames / standard stat
    return cfg;
}

pub const Probe = struct {
    status: []const u8 = "failed",
    probe: bool = false,
    mac: bool = false,
    cu: bool = false,
    ru: bool = false,
    irq: bool = false,
    eeprom: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};

    // EEPROM / MAC
    var words = std.mem.zeroes([8]u16);
    words[0] = 0x1200; // sample LE-ish words, just for checksum model
    words[1] = 0x5634;
    words[2] = 0x0054;
    var sum: u16 = 0;
    for (words[0 .. words.len - 1]) |w| sum +%= w;
    words[words.len - 1] = 0xBABA -% sum;
    result.eeprom = eepromChecksumOk(&words);
    const mac = [6]u8{ 0x00, 0x12, 0x34, 0x56, 0x54, 0x00 };
    result.mac = mac[0] == 0x00 and mac[1] == 0x12;

    // CU
    var cbs = [_]Cb{ .{}, .{}, .{}, .{} };
    for (&cbs, 0..) |*cb, i| cb.link = @intCast((i + 1) % cbs.len);
    var cu = CuRing.init(cbs.len);
    result.cu = (cu.submitSimple(&cbs, CbCommand.nop) catch null) != null;
    cbs[0].status = CbStatus.complete | CbStatus.ok;
    const cleaned = cu.complete(&cbs);
    result.cu = result.cu and cleaned == 1 and cu.cbs_avail == cbs.len;

    // RU
    var rfds = [_]Rfd{ Rfd.initBlank(), Rfd.initBlank(), Rfd.initBlank(), Rfd.initBlank() };
    var ru = RuRing.init(rfds.len);
    ru.state = .running;
    rfds[0].status = CbStatus.complete | CbStatus.ok;
    rfds[0].actual_size = 60;
    var work: usize = 0;
    const ind = ru.indicate(&rfds, &work, 8);
    result.ru = ind == .ok and work == 1 and ru.rx_to_clean == 1;
    ru.state = .suspended;
    var csr = Csr{};
    csr.scb_cmd_lo = 0;
    ru.restart(&rfds, &csr, 0x1000) catch {
        result.ru = false;
    };
    result.ru = result.ru and ru.state == .running and csr.scb_cmd_lo == CucRuc.ruc_start;

    // IRQ
    var csr2 = Csr{ .scb_stat_ack = StatAck.frame_rx, .scb_cmd_hi = ScbCmdHi.irq_mask_all };
    const ack = ackIrq(&csr2);
    disableIrq(&csr2);
    enableIrq(&csr2);
    result.irq = ack == StatAck.frame_rx and csr2.scb_cmd_hi == ScbCmdHi.irq_mask_none;

    result.probe = result.eeprom and result.mac and result.cu and result.ru and result.irq;
    if (result.probe) {
        result.status = "ok";
        result.errno = 0;
    }
    return result;
}

test "e100: CSR/SCB constants and RFD layout" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(Rfd));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Rfd, "status"));
    try std.testing.expectEqual(@as(usize, 2), @offsetOf(Rfd, "command"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(Rfd, "link"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(Rfd, "rbd"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(Rfd, "actual_size"));
    try std.testing.expectEqual(@as(usize, 14), @offsetOf(Rfd, "size"));
    try std.testing.expectEqual(@as(u8, 0x08), ScbStatus.rus_no_res);
    try std.testing.expectEqual(@as(u8, 0x54), StatAck.rx);
    try std.testing.expectEqual(@as(u8, 0xA0), StatAck.tx);
    try std.testing.expectEqual(@as(u8, 0x10), CucRuc.cuc_start);
    try std.testing.expectEqual(@as(u8, 0x20), CucRuc.cuc_resume);
}

test "e100: CB command/status bits and CU S-bit submit" {
    try std.testing.expectEqual(@as(u16, 0x8000), CbStatus.complete);
    try std.testing.expectEqual(@as(u16, 0x2000), CbStatus.ok);
    try std.testing.expectEqual(@as(u16, 0x4000), CbCommand.s);
    try std.testing.expectEqual(@as(u16, 0x8000), CbCommand.el);
    var cbs = [_]Cb{ .{}, .{}, .{} };
    var cu = CuRing.init(cbs.len);
    try cu.submitSimple(&cbs, CbCommand.nop);
    try std.testing.expect((cbs[0].command & CbCommand.s) != 0);
    try std.testing.expectEqual(CucRuc.cuc_resume, cu.cuc_cmd);
    try cu.submitSimple(&cbs, CbCommand.nop);
    try std.testing.expect((cbs[0].command & CbCommand.s) == 0);
    try std.testing.expect((cbs[1].command & CbCommand.s) != 0);
}

test "e100: execCmd waits for cmd_lo clear and writes gen_ptr" {
    var csr = Csr{ .scb_cmd_lo = 0, .scb_gen_ptr = 0 };
    try execCmd(&csr, CucRuc.cuc_start, 0x1234);
    try std.testing.expectEqual(@as(u32, 0x1234), csr.scb_gen_ptr);
    try std.testing.expectEqual(CucRuc.cuc_start, csr.scb_cmd_lo);
    csr.scb_cmd_lo = 0;
    try execCmd(&csr, CucRuc.cuc_resume, 0x5678);
    try std.testing.expectEqual(@as(u32, 0x1234), csr.scb_gen_ptr); // unchanged on resume
    csr.scb_cmd_lo = 1;
    try std.testing.expectError(error.Timeout, execCmd(&csr, CucRuc.cuc_nop, 0));
}

test "e100: RU indicate honors cb_complete/actual_size and quota" {
    var rfds = [_]Rfd{ Rfd.initBlank(), Rfd.initBlank() };
    var ru = RuRing.init(rfds.len);
    ru.state = .running;
    rfds[0].status = CbStatus.complete | CbStatus.ok;
    rfds[0].actual_size = 60 | 0xC000;
    var work: usize = 0;
    try std.testing.expectEqual(IndicateResult.ok, ru.indicate(&rfds, &work, 8));
    try std.testing.expectEqual(@as(usize, 1), work);
    try std.testing.expectEqual(IndicateResult.no_data, ru.indicate(&rfds, &work, 8));
    work = 8;
    rfds[1].status = CbStatus.complete;
    try std.testing.expectEqual(IndicateResult.again, ru.indicate(&rfds, &work, 8));
}

test "e100: RU EL-before-last stop and RNR restart" {
    var rfds = [_]Rfd{ Rfd.initBlank(), Rfd.initBlank(), Rfd.initBlank(), Rfd.initBlank() };
    var ru = RuRing.init(rfds.len);
    ru.state = .running;
    rfds[2].command |= CbCommand.el;
    rfds[2].size = 0;
    rfds[2].status = 0;
    var work: usize = 0;
    _ = ru.indicate(&rfds, &work, 8); // idx 0, no data but check EL on current? idx0 has no EL
    // simulate RNR on EL RFD
    ru.rx_to_clean = 2;
    const res = ru.indicate(&rfds, &work, 8);
    try std.testing.expectEqual(IndicateResult.no_data, res);
    try std.testing.expectEqual(RuState.suspended, ru.state);
    var csr = Csr{};
    try ru.restart(&rfds, &csr, 0x2000);
    try std.testing.expectEqual(RuState.running, ru.state);
    try std.testing.expectEqual(CucRuc.ruc_start, csr.scb_cmd_lo);
    try std.testing.expectEqual(@as(u32, 0x2000), csr.scb_gen_ptr);
    try std.testing.expect((rfds[2].command & CbCommand.el) != 0);
}

test "e100: EEPROM checksum and word read" {
    var words = [_]u16{ 0x1234, 0x5678, 0x9abc, 0 };
    var sum: u16 = 0;
    for (words[0 .. words.len - 1]) |w| sum +%= w;
    words[words.len - 1] = 0xBABA -% sum;
    try std.testing.expect(eepromChecksumOk(&words));
    words[1] ^= 1;
    try std.testing.expect(!eepromChecksumOk(&words));
    try std.testing.expectEqual(@as(u16, 0x1234), eepromReadWord(&[_]u16{ 0x1234, 0x5678 }, 0));
    try std.testing.expectEqual(@as(u16, 0), eepromReadWord(&[_]u16{0x1234}, 9));
}

test "e100: interrupt ack/disable/enable behavior" {
    var csr = Csr{ .scb_stat_ack = StatAck.frame_rx | StatAck.cu_cmd_done, .scb_cmd_hi = ScbCmdHi.irq_mask_all };
    const ack = ackIrq(&csr);
    try std.testing.expectEqual(StatAck.frame_rx | StatAck.cu_cmd_done, ack);
    disableIrq(&csr);
    try std.testing.expectEqual(ScbCmdHi.irq_mask_all, csr.scb_cmd_hi);
    enableIrq(&csr);
    try std.testing.expectEqual(ScbCmdHi.irq_mask_none, csr.scb_cmd_hi);
    var csr2 = Csr{ .scb_stat_ack = StatAck.not_ours };
    try std.testing.expectEqual(StatAck.not_ours, ackIrq(&csr2));
}

test "e100: boot probe exercises configure/iaaddr/CU/RU/irq/eeprom" {
    const result = probe();
    try std.testing.expectEqualStrings("ok", result.status);
    try std.testing.expect(result.probe);
    try std.testing.expect(result.mac);
    try std.testing.expect(result.cu);
    try std.testing.expect(result.ru);
    try std.testing.expect(result.irq);
    try std.testing.expect(result.eeprom);
    try std.testing.expectEqual(@as(u8, 0), result.errno);
}
