//! Минимальный ELF64 loader (fs/exec.c + fs/binfmt_elf.c) для статических
//! PT_LOAD-сегментов. Пользовательские страницы отображаются сразу в PML4
//! процесса и ядра (ядро должно видеть user buffers после смены CR3).
//! Нет динамического линкера, RELA, interpreter, brk и demand paging.

const std = @import("std");
const x86 = @import("x86_64.zig");
const paging = @import("paging.zig");
const pmm = @import("pmm.zig");

pub const Range = struct {
    start: usize,
    end: usize,
    prot: u32, // PROT_READ/WRITE/EXEC из p_flags
};

pub const Loaded = struct {
    entry: u64,
    ranges: [8]Range = undefined,
    count: usize = 0,
};

const ET_EXEC: u16 = 2;
const ET_DYN: u16 = 3;
const EM_X86_64: u16 = 62;
const PT_LOAD: u32 = 1;
const PHDR_SIZE: usize = 56;

fn u16le(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) | (@as(u16, b[off + 1]) << 8);
}

fn u32le(b: []const u8, off: usize) u32 {
    var v: u32 = 0;
    for (0..4) |i| v |= @as(u32, b[off + i]) << @intCast(8 * i);
    return v;
}

fn u64le(b: []const u8, off: usize) u64 {
    var v: u64 = 0;
    for (0..8) |i| v |= @as(u64, b[off + i]) << @intCast(8 * i);
    return v;
}

fn alignDown(v: u64, align_: u64) u64 {
    return v & ~(align_ - 1);
}

fn alignUp(v: u64, align_: u64) u64 {
    return (v + align_ - 1) & ~(align_ - 1);
}

/// load_elf_binary(): разобрать program headers, выделить страницы под PT_LOAD,
/// скопировать file image и нулировать .bss. Возвращает точку входа и диапазоны
/// пользовательской памяти для проверки syscall-указателей.
pub fn load(kernel_cr3: u64, user_cr3: u64, image: []const u8) !Loaded {
    if (image.len < 64) return error.BadElf;
    if (!std.mem.eql(u8, image[0..4], "\x7fELF")) return error.BadElf;
    if (image[4] != 2 or image[5] != 1) return error.BadElf; // ELF64, little-endian

    const e_type = u16le(image, 16);
    if (e_type != ET_EXEC and e_type != ET_DYN) return error.BadElf;
    if (u16le(image, 18) != EM_X86_64) return error.BadElf;

    const entry = u64le(image, 24);
    const phoff: usize = @intCast(u64le(image, 32));
    const phentsize: usize = u16le(image, 54);
    const phnum: usize = u16le(image, 56);
    if (phentsize < PHDR_SIZE) return error.BadElf;
    if (phnum == 0 or phnum > 32) return error.BadElf;
    if (phoff + phnum * phentsize > image.len) return error.BadElf;

    var result = Loaded{ .entry = entry };
    for (0..phnum) |i| {
        const ph = phoff + i * phentsize;
        if (u32le(image, ph) != PT_LOAD) continue;
        const off: usize = @intCast(u64le(image, ph + 8));
        const vaddr = u64le(image, ph + 16);
        const filesz = u64le(image, ph + 32);
        const memsz = u64le(image, ph + 40);
        if (off + filesz > image.len or memsz < filesz) return error.BadElf;
        if (memsz == 0) continue;

        // ELF PF_R/PF_W/PF_X → PROT_READ/PROT_WRITE/PROT_EXEC.
        const pf = u32le(image, ph + 4);
        var prot: u32 = 0;
        if (pf & 4 != 0) prot |= 1; // PF_R
        if (pf & 2 != 0) prot |= 2; // PF_W
        if (pf & 1 != 0) prot |= 4; // PF_X

        const start = alignDown(vaddr, pmm.PAGE);
        const end = alignUp(vaddr + memsz, pmm.PAGE);
        const pages: usize = @intCast((end - start) / pmm.PAGE);
        const phys = pmm.allocContiguous(pages) orelse return error.OutOfMemory;
        var k: usize = 0;
        while (k < pages) : (k += 1) {
            const va: usize = @intCast(start + k * pmm.PAGE);
            try paging.mapUserPage(kernel_cr3, va, phys + k * pmm.PAGE);
            try paging.mapUserPage(user_cr3, va, phys + k * pmm.PAGE);
        }
        if (result.count < result.ranges.len) {
            result.ranges[result.count] = .{ .start = @intCast(start), .end = @intCast(end), .prot = prot };
            result.count += 1;
        }
    }
    if (result.count == 0) return error.BadElf;

    // Page-table записи обновлены, но TLB может хранить старые entries.
    x86.writeCr3(@intCast(kernel_cr3));

    // Теперь виртуальные адреса сегментов отображены и в ядерном PML4.
    for (0..phnum) |i| {
        const ph = phoff + i * phentsize;
        if (u32le(image, ph) != PT_LOAD) continue;
        const off: usize = @intCast(u64le(image, ph + 8));
        const vaddr: usize = @intCast(u64le(image, ph + 16));
        const filesz: usize = @intCast(u64le(image, ph + 32));
        const memsz: usize = @intCast(u64le(image, ph + 40));
        if (memsz == 0) continue;
        const dst: [*]u8 = @ptrFromInt(vaddr);
        @memcpy(dst[0..filesz], image[off .. off + filesz]);
        @memset(dst[filesz..memsz], 0);
    }

    // После копирования выставить RW по p_flags: firmware может оставить
    // CR0.WP=1, поэтому писать в ещё RO-страницы через kernel mapping нельзя.
    for (0..phnum) |i| {
        const ph = phoff + i * phentsize;
        if (u32le(image, ph) != PT_LOAD) continue;
        const vaddr = u64le(image, ph + 16);
        const memsz = u64le(image, ph + 40);
        if (memsz == 0) continue;
        const writable = (u32le(image, ph + 4) & 2) != 0; // PF_W
        const start = alignDown(vaddr, pmm.PAGE);
        const end = alignUp(vaddr + memsz, pmm.PAGE);
        var va = start;
        while (va < end) : (va += pmm.PAGE) {
            _ = paging.setUserPageWritable(kernel_cr3, @intCast(va), writable);
            _ = paging.setUserPageWritable(user_cr3, @intCast(va), writable);
        }
    }
    x86.writeCr3(@intCast(kernel_cr3));
    return result;
}
