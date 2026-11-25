//! Куча ядра как std.mem.Allocator поверх физического аллокатора страниц.
//! Позволяет запускать уже портированные подсистемы (Kernel.boot) в UEFI-среде,
//! не меняя их код: free() восстанавливает число страниц из заголовка блока.
const std = @import("std");
const pmm = @import("pmm.zig");

const MAGIC: u64 = 0x5a676c696e757831; // "zglinux1"
const Header = struct {
    magic: u64,
    addr: usize,
    pages: usize,
    len: usize,
};
const hdr_size = @sizeOf(Header);

fn alignUp(v: usize, a: usize) usize {
    return (v + a - 1) & ~(a - 1);
}

fn allocRaw(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
    _ = ctx;
    _ = ret_addr;
    if (len == 0) return null;
    const a = alignment.toByteUnits();
    const bytes = hdr_size + len + a - 1;
    const pages = (bytes + pmm.PAGE - 1) / pmm.PAGE;
    const raw = pmm.allocContiguous(pages) orelse return null;
    const data = alignUp(raw + hdr_size, a);
    const h: *align(8) Header = @ptrFromInt(data - hdr_size);
    h.* = .{ .magic = MAGIC, .addr = raw, .pages = pages, .len = len };
    return @ptrFromInt(data);
}

fn freeRaw(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
    _ = ctx;
    _ = alignment;
    _ = ret_addr;
    if (memory.len == 0) return;
    const addr = @intFromPtr(memory.ptr);
    if (addr < hdr_size) return;
    const h: *align(8) const Header = @ptrFromInt(addr - hdr_size);
    if (h.magic != MAGIC) return;
    pmm.free(h.addr, h.pages);
}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocRaw,
    .free = freeRaw,
    .resize = std.mem.Allocator.noResize,
    .remap = std.mem.Allocator.noRemap,
};

var state: u8 = 0;

pub fn allocator() std.mem.Allocator {
    return .{ .ptr = &state, .vtable = &vtable };
}
