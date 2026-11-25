//! Порт базового DRM-ядра Linux 7.3: проверка видеорежима, расчёт частоты
//! обновления, framebuffer и page flip CRTC. Источники:
//! drivers/gpu/drm/drm_modes.c (drm_mode_validate_basic, validate_size,
//! drm_mode_vrefresh), drivers/gpu/drm/drm_framebuffer.c,
//! drivers/gpu/drm/drm_crtc.c, include/uapi/drm/drm_mode.h.
//! GPL-2.0-only (производная работа по алгоритмам и константам Linux).

const std = @import("std");

pub const DRM_MODE_FLAG_NHSYNC: u32 = 1 << 1;
pub const DRM_MODE_FLAG_PVSYNC: u32 = 1 << 2;
pub const DRM_MODE_FLAG_INTERLACE: u32 = 1 << 4;
pub const DRM_MODE_FLAG_DBLSCAN: u32 = 1 << 5;
pub const DRM_MODE_FLAG_ALL: u32 = 0x3FFF;
pub const DRM_MODE_TYPE_DRIVER: u32 = 1 << 6;
pub const DRM_MODE_TYPE_PREFERRED: u32 = 1 << 3;
pub const DRM_MODE_TYPE_ALL: u32 = DRM_MODE_TYPE_PREFERRED | DRM_MODE_TYPE_DRIVER;

pub const ModeStatus = enum {
    ok,
    clock_low,
    h_illegal,
    v_illegal,
    virtual_x,
    virtual_y,
    bad,
};

pub const Mode = struct {
    clock: u32 = 0,
    hdisplay: u32 = 0,
    hsync_start: u32 = 0,
    hsync_end: u32 = 0,
    htotal: u32 = 0,
    vdisplay: u32 = 0,
    vsync_start: u32 = 0,
    vsync_end: u32 = 0,
    vtotal: u32 = 0,
    vscan: u32 = 1,
    flags: u32 = DRM_MODE_FLAG_NHSYNC | DRM_MODE_FLAG_PVSYNC,
    kind: u32 = DRM_MODE_TYPE_DRIVER,
};

/// drm_mode_validate_basic(): биты и монотонные границы H/V timings.
pub fn validateBasic(mode: Mode) ModeStatus {
    if ((mode.kind & ~DRM_MODE_TYPE_ALL) != 0) return .bad;
    if ((mode.flags & ~DRM_MODE_FLAG_ALL) != 0) return .bad;
    if (mode.clock == 0) return .clock_low;
    if (mode.hdisplay == 0 or mode.hsync_start < mode.hdisplay or
        mode.hsync_end < mode.hsync_start or mode.htotal < mode.hsync_end)
        return .h_illegal;
    if (mode.vdisplay == 0 or mode.vsync_start < mode.vdisplay or
        mode.vsync_end < mode.vsync_start or mode.vtotal < mode.vsync_end)
        return .v_illegal;
    return .ok;
}

/// drm_mode_validate_size(): ограничения коннектора по ширине/высоте.
pub fn validateSize(mode: Mode, max_x: u32, max_y: u32) ModeStatus {
    if (max_x > 0 and mode.hdisplay > max_x) return .virtual_x;
    if (max_y > 0 and mode.vdisplay > max_y) return .virtual_y;
    return .ok;
}

/// drm_mode_vrefresh(): num/den с INTERLACE, DBLSCAN и vscan,
/// округление до ближайшего целого (DIV_ROUND_CLOSEST_ULL).
pub fn vrefresh(mode: Mode) u32 {
    if (mode.htotal == 0 or mode.vtotal == 0) return 0;
    var num: u64 = 1;
    var den: u64 = 1;
    if ((mode.flags & DRM_MODE_FLAG_INTERLACE) != 0) num *= 2;
    if ((mode.flags & DRM_MODE_FLAG_DBLSCAN) != 0) den *= 2;
    if (mode.vscan > 1) den *= mode.vscan;
    den *= @as(u64, mode.htotal) * @as(u64, mode.vtotal);
    const numerator: u64 = @as(u64, mode.clock) * num * 1000;
    return @intCast((numerator + den / 2) / den);
}

/// drm_framebuffer_init(): минимальная проверка geometry/pitch/size.
pub const Framebuffer = struct {
    width: u32,
    height: u32,
    bpp: u32,
    pitch: u32,
    size: usize,

    pub fn init(width: u32, height: u32, bpp: u32, pitch: u32) !Framebuffer {
        if (width == 0 or height == 0 or bpp == 0) return error.InvalidGeometry;
        const row_bytes: u64 = @as(u64, width) * @as(u64, bpp);
        if (pitch * 8 < row_bytes) return error.PitchTooSmall;
        const bytes: u64 = @as(u64, pitch) * @as(u64, height);
        return .{
            .width = width,
            .height = height,
            .bpp = bpp,
            .pitch = pitch,
            .size = @intCast(bytes),
        };
    }
};

/// drm_crtc_set_mode() + drm_crtc_page_flip(): режим должен помещаться
/// в framebuffer; flip меняет fb и увеличивает счётчик present.
pub const Crtc = struct {
    fb: ?*const Framebuffer = null,
    mode: ?Mode = null,
    flips: usize = 0,
    mode_sets: usize = 0,

    pub fn setMode(self: *Crtc, fb: *const Framebuffer, mode: Mode) !void {
        if (validateBasic(mode) != .ok) return error.BadMode;
        if (mode.hdisplay > fb.width or mode.vdisplay > fb.height) return error.ModeTooLarge;
        self.mode = mode;
        self.fb = fb;
        self.mode_sets += 1;
    }

    pub fn pageFlip(self: *Crtc, fb: *const Framebuffer) void {
        self.fb = fb;
        self.flips += 1;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    basic: bool = false,
    size: bool = false,
    refresh: bool = false,
    framebuffer: bool = false,
    crtc: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    const mode = Mode{
        .clock = 65000,
        .hdisplay = 1024,
        .hsync_start = 1064,
        .hsync_end = 1168,
        .htotal = 1344,
        .vdisplay = 768,
        .vsync_start = 771,
        .vsync_end = 777,
        .vtotal = 806,
    };
    p.basic = validateBasic(mode) == .ok and
        validateBasic(.{ .clock = 0 }) == .clock_low and
        validateBasic(.{ .clock = 1, .hdisplay = 10, .hsync_start = 5, .hsync_end = 20, .htotal = 20, .vdisplay = 10, .vsync_start = 10, .vsync_end = 10, .vtotal = 10 }) == .h_illegal;
    p.size = validateSize(mode, 1920, 1080) == .ok and
        validateSize(mode, 800, 1080) == .virtual_x and
        validateSize(mode, 1920, 600) == .virtual_y;
    p.refresh = vrefresh(mode) == 60 and
        vrefresh(.{ .htotal = 0 }) == 0;
    var fb = Framebuffer.init(1024, 768, 32, 4096) catch return p;
    p.framebuffer = fb.size == 4096 * 768;
    var crtc = Crtc{};
    crtc.setMode(&fb, mode) catch return p;
    crtc.pageFlip(&fb);
    p.crtc = crtc.mode_sets == 1 and crtc.flips == 1 and crtc.fb == &fb;
    p.status = "ok";
    return p;
}

test "drm: basic mode validation matches drm_mode_validate_basic" {
    const mode = Mode{
        .clock = 65000,
        .hdisplay = 1024,
        .hsync_start = 1064,
        .hsync_end = 1168,
        .htotal = 1344,
        .vdisplay = 768,
        .vsync_start = 771,
        .vsync_end = 777,
        .vtotal = 806,
    };
    try std.testing.expectEqual(ModeStatus.ok, validateBasic(mode));
    try std.testing.expectEqual(ModeStatus.clock_low, validateBasic(.{ .clock = 0 }));
    var bad = mode;
    bad.hsync_start = 1000;
    try std.testing.expectEqual(ModeStatus.h_illegal, validateBasic(bad));
    bad = mode;
    bad.vsync_start = 700;
    try std.testing.expectEqual(ModeStatus.v_illegal, validateBasic(bad));
    bad = mode;
    bad.kind = 1 << 20;
    try std.testing.expectEqual(ModeStatus.bad, validateBasic(bad));
}

test "drm: size limits and refresh rate follow Linux helpers" {
    const mode = Mode{
        .clock = 65000,
        .hdisplay = 1024,
        .hsync_start = 1064,
        .hsync_end = 1168,
        .htotal = 1344,
        .vdisplay = 768,
        .vsync_start = 771,
        .vsync_end = 777,
        .vtotal = 806,
    };
    try std.testing.expectEqual(ModeStatus.ok, validateSize(mode, 1920, 1080));
    try std.testing.expectEqual(ModeStatus.virtual_x, validateSize(mode, 800, 1080));
    try std.testing.expectEqual(ModeStatus.virtual_y, validateSize(mode, 1920, 600));
    try std.testing.expectEqual(@as(u32, 60), vrefresh(mode));
    try std.testing.expectEqual(@as(u32, 0), vrefresh(.{}));
    var interlaced = mode;
    interlaced.flags |= DRM_MODE_FLAG_INTERLACE;
    try std.testing.expectEqual(@as(u32, 120), vrefresh(interlaced));
}

test "drm: framebuffer geometry and CRTC page flip" {
    try std.testing.expectError(error.PitchTooSmall, Framebuffer.init(1024, 768, 32, 2048));
    const fb = try Framebuffer.init(1024, 768, 32, 4096);
    try std.testing.expectEqual(@as(usize, 4096 * 768), fb.size);
    var crtc = Crtc{};
    const mode = Mode{
        .clock = 65000,
        .hdisplay = 1024,
        .hsync_start = 1064,
        .hsync_end = 1168,
        .htotal = 1344,
        .vdisplay = 768,
        .vsync_start = 771,
        .vsync_end = 777,
        .vtotal = 806,
    };
    try crtc.setMode(&fb, mode);
    try std.testing.expectError(error.ModeTooLarge, crtc.setMode(&fb, .{
        .clock = 1,
        .hdisplay = 1920,
        .hsync_start = 1920,
        .hsync_end = 1921,
        .htotal = 1922,
        .vdisplay = 1080,
        .vsync_start = 1080,
        .vsync_end = 1081,
        .vtotal = 1082,
    }));
    crtc.pageFlip(&fb);
    try std.testing.expectEqual(@as(usize, 1), crtc.flips);
    try std.testing.expectEqual(@as(usize, 1), crtc.mode_sets);
}

test "drm: boot probe exercises validation, refresh, framebuffer and flip" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.basic);
    try std.testing.expect(p.size);
    try std.testing.expect(p.refresh);
    try std.testing.expect(p.framebuffer);
    try std.testing.expect(p.crtc);
}
