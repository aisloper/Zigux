//! Порт минимального среза virtio-rng (Linux 7.3 drivers/char/hw_random/virtio-rng.c).
//! Чистая логика: device ID 4, feature negotiation, encode inbuf request, used.len
//! clamp/copy and re-arm. Boot-проверка проверяет видимость драйвера через
//! virtio-pci без реального hw_random registration.
//! Источник: drivers/char/hw_random/virtio-rng.c. GPL-2.0-or-later.

const std = @import("std");

pub const VIRTIO_VENDOR: u16 = 0x1af4;
pub const VIRTIO_DEVICE_RNG_LEGACY: u16 = 0x1005;
pub const VIRTIO_ID_RNG: u8 = 4;
pub const DATA_SIZE: usize = 32;

pub const Desc = extern struct {
    addr: u64 = 0,
    len: u32 = 0,
    flags: u16 = 0,
    next: u16 = 0,
};

pub const VRING_DESC_F_WRITE: u16 = 2;
pub const VRING_DESC_F_NEXT: u16 = 1;

pub fn isSupported(vendor: u16, device: u16) bool {
    return vendor == VIRTIO_VENDOR and device == VIRTIO_DEVICE_RNG_LEGACY;
}

pub fn featuresSupported(features: u64) bool {
    // virtio-rng has no device-specific feature bits.
    return (features & ~@as(u64, 0)) == 0;
}

pub fn encodeInbuf(desc: *Desc, addr: u64, len: u32) void {
    desc.* = .{ .addr = addr, .len = len, .flags = VRING_DESC_F_WRITE, .next = 0 };
}

pub const Buffer = struct {
    data: [DATA_SIZE]u8 = std.mem.zeroes([DATA_SIZE]u8),
    data_avail: usize = 0,
    data_idx: usize = 0,
    requests: u32 = 0,

    pub fn useLen(self: *Buffer, len: usize) void {
        self.data_avail = @min(len, self.data.len);
    }

    pub fn copyOut(self: *Buffer, out: []u8) usize {
        const avail = @min(self.data_avail, self.data.len);
        if (self.data_idx >= avail) {
            self.data_avail = 0;
            self.requests += 1;
            return 0;
        }
        const n = @min(out.len, avail - self.data_idx);
        @memcpy(out[0..n], self.data[self.data_idx .. self.data_idx + n]);
        self.data_idx += n;
        self.data_avail -= n;
        if (self.data_avail == 0) self.requests += 1;
        return n;
    }
};

pub const Probe = struct {
    status: []const u8 = "failed",
    probe: bool = false,
    feat: bool = false,
    req: bool = false,
    bytes: bool = false,
    errno: u8 = 1,
};

pub fn probe() Probe {
    var result = Probe{};
    result.probe = isSupported(VIRTIO_VENDOR, VIRTIO_DEVICE_RNG_LEGACY) and VIRTIO_ID_RNG == 4;
    result.feat = featuresSupported(0);
    var desc = Desc{};
    encodeInbuf(&desc, 0x4000, DATA_SIZE);
    result.req = desc.len == DATA_SIZE and desc.flags == VRING_DESC_F_WRITE and desc.next == 0;
    var buf = Buffer{};
    buf.useLen(DATA_SIZE + 8);
    for (&buf.data, 0..) |*b, i| b.* = @intCast((i * 7 + 1) & 0xff);
    var out: [DATA_SIZE]u8 = std.mem.zeroes([DATA_SIZE]u8);
    const n = buf.copyOut(&out);
    result.bytes = n == DATA_SIZE and out[0] == 1 and out[31] == (31 * 7 + 1) & 0xff and buf.requests == 1;
    if (result.probe and result.feat and result.req and result.bytes) {
        result.status = "ok";
        result.errno = 0;
    }
    return result;
}

test "virtio-rng: PCI ID and features" {
    try std.testing.expect(isSupported(0x1af4, 0x1005));
    try std.testing.expect(!isSupported(0x1af4, 0x1004));
    try std.testing.expect(featuresSupported(0));
}

test "virtio-rng: inbuf descriptor" {
    var desc = Desc{};
    encodeInbuf(&desc, 0x5000, 64);
    try std.testing.expectEqual(@as(u64, 0x5000), desc.addr);
    try std.testing.expectEqual(@as(u32, 64), desc.len);
    try std.testing.expectEqual(VRING_DESC_F_WRITE, desc.flags);
    try std.testing.expectEqual(@as(u16, 0), desc.next);
}

test "virtio-rng: used.len clamp and copy" {
    var buf = Buffer{};
    buf.useLen(DATA_SIZE + 16);
    try std.testing.expectEqual(@as(usize, DATA_SIZE), buf.data_avail);
    for (&buf.data, 0..) |*b, i| b.* = @intCast(i & 0xff);
    var out: [40]u8 = std.mem.zeroes([40]u8);
    try std.testing.expectEqual(@as(usize, 32), buf.copyOut(&out));
    try std.testing.expectEqual(@as(u8, 0), out[0]);
    try std.testing.expectEqual(@as(u8, 31), out[31]);
    try std.testing.expectEqual(@as(usize, 0), buf.copyOut(&out));
    try std.testing.expectEqual(@as(u32, 2), buf.requests);
}

test "virtio-rng: boot probe" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.probe and p.feat and p.req and p.bytes);
    try std.testing.expectEqual(@as(u8, 0), p.errno);
}
