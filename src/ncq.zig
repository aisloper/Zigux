//! Порт NCQ для AHCI Linux 7.3: возможность устройства и контроллера,
//! глубина очереди из CAP.NCS, построение H2D FIS FPDMA READ/WRITE,
//! регистры SActive/CI и завершение команд по тегу. Источники:
//! drivers/ata/libata-core.c (ata_build_rw_tf), drivers/ata/ahci.h,
//! include/linux/ata.h, include/linux/libata.h. GPL-2.0-only.

const std = @import("std");

pub const ATA_CMD_FPDMA_READ: u8 = 0x60;
pub const ATA_CMD_FPDMA_WRITE: u8 = 0x61;
pub const ATA_CMD_SET_FEATURES: u8 = 0xEF;
pub const ATA_ID_SATA_CAPABILITY: usize = 76;
pub const ATA_DFLAG_NCQ: u32 = 1 << 3;
pub const ATA_DFLAG_NCQ_OFF: u32 = 1 << 18;

pub const HOST_CAP_NCQ: u32 = 1 << 30;
pub const CAP_NCS_SHIFT: u5 = 21;
pub const CAP_NCS_MASK: u32 = 0x1F << CAP_NCS_SHIFT;
pub const MAX_QUEUE_DEPTH: u6 = 32;

/// ata_id_has_ncq(): IDENTIFY word 76 bit 8.
pub fn deviceSupportsNcq(identify: []const u16) bool {
    if (identify.len <= ATA_ID_SATA_CAPABILITY) return false;
    return (identify[ATA_ID_SATA_CAPABILITY] & (1 << 8)) != 0;
}

/// ahci_init_one(): NCQ работает только если CAP.NCQ включён и драйвер не
/// отключил его для конкретного устройства.
pub fn ncqEnabled(cap: u32, identify: []const u16, device_flags: u32) bool {
    if ((cap & HOST_CAP_NCQ) == 0) return false;
    if ((device_flags & ATA_DFLAG_NCQ_OFF) != 0) return false;
    return (device_flags & ATA_DFLAG_NCQ) != 0 or deviceSupportsNcq(identify);
}

/// CAP.NCS хранит глубину очереди минус один; без NCQ остаётся один слот.
pub fn queueDepth(cap: u32) u6 {
    if ((cap & HOST_CAP_NCQ) == 0) return 1;
    const ncs: u32 = (cap & CAP_NCS_MASK) >> CAP_NCS_SHIFT;
    const depth: u32 = ncs + 1;
    return @intCast(@min(depth, MAX_QUEUE_DEPTH));
}

/// H2D register FIS для FPDMA: тег в nsect (биты 7..3), счётчик в feature,
/// LBA48 в lbah/lbam/lbal и hob-старших байтах.
pub fn buildFpdmaFis(tag: u8, write: bool, lba: u64, sectors: u16) [20]u8 {
    var fis: [20]u8 = @splat(0);
    fis[0] = 0x27;
    fis[1] = 0x80;
    fis[2] = if (write) ATA_CMD_FPDMA_WRITE else ATA_CMD_FPDMA_READ;
    fis[3] = @truncate(sectors);
    fis[4] = @truncate(lba);
    fis[5] = @truncate(lba >> 8);
    fis[6] = @truncate(lba >> 16);
    fis[7] = 0x40; // ATA_LBA
    fis[8] = @truncate(lba >> 24);
    fis[9] = @truncate(lba >> 32);
    fis[10] = @truncate(lba >> 40);
    fis[11] = @truncate(sectors >> 8);
    fis[12] = tag << 3;
    return fis;
}

/// Очередь NCQ: бит тега в SActive и бит слота в CI снимаются по завершении.
pub const Queue = struct {
    depth: u6,
    sactive: u32 = 0,
    ci: u32 = 0,
    issued: usize = 0,
    completed: usize = 0,

    pub fn init(cap: u32) Queue {
        return .{ .depth = queueDepth(cap) };
    }

    pub fn submit(self: *Queue, tag: u8) !void {
        const t: u6 = @intCast(tag);
        if (t >= self.depth) return error.TagOutOfRange;
        const bit: u32 = @as(u32, 1) << @intCast(t);
        if ((self.sactive & bit) != 0) return error.TagBusy;
        if (self.issued - self.completed >= self.depth) return error.QueueFull;
        self.sactive |= bit;
        self.ci |= bit;
        self.issued += 1;
    }

    pub fn complete(self: *Queue, tag: u8) !void {
        const t: u6 = @intCast(tag);
        if (t >= self.depth) return error.TagOutOfRange;
        const bit: u32 = @as(u32, 1) << @intCast(t);
        if ((self.sactive & bit) == 0) return error.TagNotActive;
        self.sactive &= ~bit;
        self.ci &= ~bit;
        self.completed += 1;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    cap: bool = false,
    fis: bool = false,
    queue: bool = false,
    completion: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    const cap = HOST_CAP_NCQ | (@as(u32, 31) << CAP_NCS_SHIFT);
    var identify: [77]u16 = @splat(0);
    identify[ATA_ID_SATA_CAPABILITY] = 1 << 8;
    p.cap = ncqEnabled(cap, &identify, ATA_DFLAG_NCQ) and queueDepth(cap) == 32 and
        queueDepth(0) == 1;
    const read = buildFpdmaFis(5, false, 0x1234_5678_9ABC, 7);
    const write = buildFpdmaFis(6, true, 0x1234_5678_9ABC, 7);
    p.fis = read[0] == 0x27 and read[2] == ATA_CMD_FPDMA_READ and read[12] == (5 << 3) and
        read[3] == 7 and read[4] == 0xBC and read[10] == 0x12 and
        write[2] == ATA_CMD_FPDMA_WRITE and write[12] == (6 << 3);
    var q = Queue.init(cap);
    q.submit(0) catch return p;
    q.submit(1) catch return p;
    p.queue = q.sactive == 3 and q.ci == 3 and q.issued == 2;
    q.complete(0) catch return p;
    p.completion = q.sactive == 2 and q.ci == 2 and q.completed == 1;
    p.status = "ok";
    return p;
}

test "ncq: capability and depth follow AHCI CAP and IDENTIFY" {
    var identify: [77]u16 = @splat(0);
    identify[ATA_ID_SATA_CAPABILITY] = 1 << 8;
    try std.testing.expect(deviceSupportsNcq(&identify));
    try std.testing.expect(ncqEnabled(HOST_CAP_NCQ, &identify, 0));
    try std.testing.expect(!ncqEnabled(0, &identify, 0));
    try std.testing.expect(!ncqEnabled(HOST_CAP_NCQ, &identify, ATA_DFLAG_NCQ_OFF));
    try std.testing.expectEqual(@as(u6, 4), queueDepth(HOST_CAP_NCQ | (3 << CAP_NCS_SHIFT)));
    try std.testing.expectEqual(@as(u6, 32), queueDepth(HOST_CAP_NCQ | (0x1F << CAP_NCS_SHIFT)));
}

test "ncq: FPDMA FIS places tag, sector count and LBA48 correctly" {
    const fis = buildFpdmaFis(9, false, 0x0102_0304_0506, 0x0123);
    try std.testing.expectEqual(@as(u8, 0x27), fis[0]);
    try std.testing.expectEqual(@as(u8, ATA_CMD_FPDMA_READ), fis[2]);
    try std.testing.expectEqual(@as(u8, 0x23), fis[3]);
    try std.testing.expectEqual(@as(u8, 0x01), fis[11]);
    try std.testing.expectEqual(@as(u8, 9 << 3), fis[12]);
    try std.testing.expectEqual(@as(u8, 0x06), fis[4]);
    try std.testing.expectEqual(@as(u8, 0x03), fis[8]);
    try std.testing.expectEqual(@as(u8, 0x01), fis[10]);
    try std.testing.expectEqual(@as(u8, 0x40), fis[7]);
}

test "ncq: SActive and CI track tags until completion" {
    var q = Queue.init(HOST_CAP_NCQ | (3 << CAP_NCS_SHIFT));
    try q.submit(0);
    try q.submit(3);
    try std.testing.expectEqual(@as(u32, 0b1001), q.sactive);
    try std.testing.expectError(error.TagBusy, q.submit(0));
    try std.testing.expectError(error.TagOutOfRange, q.submit(4));
    try q.complete(3);
    try std.testing.expectEqual(@as(u32, 1), q.sactive);
    try std.testing.expectEqual(@as(u32, 1), q.ci);
    try q.submit(1);
    try std.testing.expectEqual(@as(u32, 0b0011), q.sactive);
    try std.testing.expect(q.issued == 3 and q.completed == 1);
}

test "ncq: boot probe exercises capability, FIS, queue and completion" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.cap);
    try std.testing.expect(p.fis);
    try std.testing.expect(p.queue);
    try std.testing.expect(p.completion);
}
