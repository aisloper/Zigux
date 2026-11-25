// Физический аллокатор страниц: битовая карта по "conventional memory".
// Предполагается identity-mapping (его оставила прошивка).
const boot = @import("boot.zig");
const x86 = @import("x86_64.zig");

pub const PAGE: usize = 4096;
const LOW_LIMIT: usize = 0x100000; // первый МиБ не трогаем

var bitmap: [*]u8 = undefined;
var frames: usize = 0;
var free_frames: usize = 0;
var usable_frames: usize = 0;
var hint: usize = 0;
/// SMP: один битовый указатель на все CPU, поэтому выделение/освобождение
/// сериализуется простым spinlock (аналог page_alloc_lock в Linux).
var alloc_lock: u32 = 0;

fn lockAcquire() void {
    while (@cmpxchgStrong(u32, &alloc_lock, 0, 1, .acquire, .monotonic) != null) {
        while (@atomicLoad(u32, &alloc_lock, .monotonic) != 0) x86.pause();
    }
}

fn lockRelease() void {
    _ = @atomicRmw(u32, &alloc_lock, .Xchg, 0, .release);
}

fn isSet(i: usize) bool {
    return (bitmap[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
}
fn setBit(i: usize) void {
    bitmap[i >> 3] |= @as(u8, 1) << @intCast(i & 7);
}
fn clearBit(i: usize) void {
    bitmap[i >> 3] &= ~(@as(u8, 1) << @intCast(i & 7));
}

pub fn init(regions: []const boot.Region) bool {
    var top: usize = 0;
    for (regions) |r| {
        if (r.kind == .usable) top = @max(top, r.start + r.pages * PAGE);
    }
    frames = top / PAGE;
    const bytes = (frames + 7) / 8;
    const need = (bytes + PAGE - 1) / PAGE;

    var home: usize = 0;
    for (regions) |r| {
        if (r.kind != .usable) continue;
        const s = @max(r.start, LOW_LIMIT);
        const e = r.start + r.pages * PAGE;
        if (e > s and (e - s) / PAGE >= need) {
            home = s;
            break;
        }
    }
    if (home == 0) return false;

    bitmap = @ptrFromInt(home);
    @memset(bitmap[0..bytes], 0xFF);

    for (regions) |r| {
        if (r.kind != .usable) continue;
        var p = r.start / PAGE;
        const end = p + r.pages;
        while (p < end) : (p += 1) {
            if (p * PAGE < LOW_LIMIT) continue;
            clearBit(p);
            free_frames += 1;
        }
    }
    var i: usize = 0;
    const first = home / PAGE;
    while (i < need) : (i += 1) {
        if (!isSet(first + i)) {
            setBit(first + i);
            free_frames -= 1;
        }
    }
    usable_frames = free_frames;
    return true;
}

fn findRun(from: usize, to: usize, n: usize) ?usize {
    var run: usize = 0;
    var i = from;
    while (i < to) : (i += 1) {
        if (isSet(i)) {
            run = 0;
            continue;
        }
        run += 1;
        if (run == n) return i + 1 - n;
    }
    return null;
}

/// n подряд идущих страниц; возвращает физический адрес.
pub fn allocContiguous(n: usize) ?usize {
    if (n == 0) return null;
    lockAcquire();
    defer lockRelease();
    if (n > free_frames) return null;
    const s = findRun(hint, frames, n) orelse findRun(0, frames, n) orelse return null;
    var k: usize = 0;
    while (k < n) : (k += 1) setBit(s + k);
    free_frames -= n;
    hint = s + n;
    if (hint >= frames) hint = 0;
    return s * PAGE;
}

pub fn allocFrame() ?usize {
    return allocContiguous(1);
}

pub fn free(addr: usize, n: usize) void {
    lockAcquire();
    defer lockRelease();
    var k: usize = 0;
    const s = addr / PAGE;
    while (k < n) : (k += 1) {
        if (isSet(s + k)) {
            clearBit(s + k);
            free_frames += 1;
        }
    }
}

pub fn stats() struct { usable: usize, free: usize } {
    return .{ .usable = usable_frames, .free = free_frames };
}
