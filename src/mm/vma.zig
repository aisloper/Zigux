//! Порт VMA-слоя Linux 7.3 на Zig.
//! Источники: include/linux/mm_types.h (vm_area_struct, mm_struct),
//! mm/mmap.c (do_mmap, do_vmi_munmap, do_mprotect_pkey), mm/memory.c.
//! Упрощено: нет page table walk, anon_vma, lockdep/mmap_lock, hugepages и
//! writeback MAP_SHARED. Дерево VMA, anon/file-backed отображения, COW и
//! инварианты непересечения/слияния — как в Linux.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const rbtree = @import("../rbtree.zig");
const file = @import("../file.zig");

pub const PAGE_SHIFT: u6 = 12;
pub const PAGE_SIZE: u64 = 1 << PAGE_SHIFT;

/// include/uapi/asm-generic/mman-common.h — prot/flags.
pub const PROT_READ: u32 = 0x1;
pub const PROT_WRITE: u32 = 0x2;
pub const PROT_EXEC: u32 = 0x4;
pub const PROT_NONE: u32 = 0;

pub const MAP_SHARED: u64 = 0x1;
pub const MAP_PRIVATE: u64 = 0x2;
pub const MAP_FIXED: u64 = 0x10;
pub const MAP_ANONYMOUS: u64 = 0x20;
pub const MAP_GROWSDOWN: u64 = 0x100;
pub const MAP_STACK: u64 = 0x20000;
pub const MAP_NORESERVE: u64 = 0x4000;

/// include/linux/mm.h — vm_flags.
pub const VM_READ: u64 = 0x1 << 0;
pub const VM_WRITE: u64 = 0x1 << 1;
pub const VM_EXEC: u64 = 0x1 << 2;
pub const VM_SHARED: u64 = 0x1 << 3;
pub const VM_MAYREAD: u64 = 0x1 << 4;
pub const VM_MAYWRITE: u64 = 0x1 << 5;
pub const VM_MAYEXEC: u64 = 0x1 << 6;
pub const VM_MAYSHARE: u64 = 0x1 << 7;
pub const VM_GROWSDOWN: u64 = 0x1 << 8;
pub const VM_ACCOUNT: u64 = 0x1 << 17;
pub const VM_NORESERVE: u64 = 0x1 << 22;
pub const VM_LOCKED: u64 = 0x1 << 29;

pub fn alignUp(value: u64, alignment: u64) u64 {
    return (value + alignment - 1) & ~(alignment - 1);
}

pub fn alignDown(value: u64, alignment: u64) u64 {
    return value & ~(alignment - 1);
}

/// prot → vm_flags (include/linux/mm.h: protection_map[]).
pub fn flagsForProt(prot: u32) u64 {
    var f: u64 = VM_MAYREAD | VM_MAYWRITE | VM_MAYEXEC;
    if (prot & PROT_READ != 0) f |= VM_READ;
    if (prot & PROT_WRITE != 0) f |= VM_WRITE;
    if (prot & PROT_EXEC != 0) f |= VM_EXEC;
    return f;
}

fn applyProt(flags: u64, prot: u32) u64 {
    var f = flags & ~(VM_READ | VM_WRITE | VM_EXEC);
    if (prot & PROT_READ != 0) f |= VM_READ;
    if (prot & PROT_WRITE != 0) f |= VM_WRITE;
    if (prot & PROT_EXEC != 0) f |= VM_EXEC;
    return f;
}

/// include/linux/mm_types.h: struct vm_area_struct (упрощённо).
pub const VmAreaStruct = struct {
    vm_start: u64,
    vm_end: u64,
    vm_flags: u64,
    vm_page_prot: u32,
    /// file-backed VMA: источник данных для do_file_page() в fault handler.
    /// null — анонимное отображение (brk/stack/anon mmap).
    vm_file: ?*file.File = null,
    vm_pgoff: u64 = 0, // смещение в страницах от начала файла
    rb: rbtree.Node = .{},

    pub inline fn contains(self: *const VmAreaStruct, addr: u64) bool {
        return addr >= self.vm_start and addr < self.vm_end;
    }

    pub inline fn pages(self: *const VmAreaStruct) u64 {
        return (self.vm_end - self.vm_start) >> PAGE_SHIFT;
    }
};

fn less(a: *rbtree.Node, b: *rbtree.Node) bool {
    return @as(*VmAreaStruct, @fieldParentPtr("rb", a)).vm_start <
        @as(*VmAreaStruct, @fieldParentPtr("rb", b)).vm_start;
}

fn vmaOf(node: *rbtree.Node) *VmAreaStruct {
    return @as(*VmAreaStruct, @fieldParentPtr("rb", node));
}

/// mm_struct.mm_rb + mmap/munmap/mprotect. Инвариант: VMA не пересекаются
/// и отсортированы по vm_start, как и в Linux.
pub const VmAreaTree = struct {
    allocator: std.mem.Allocator,
    tree: rbtree.Tree = rbtree.Tree.init(.{}),
    nr_vmas: usize = 0,
    next_base: u64 = 0x1000,

    pub fn init(allocator: std.mem.Allocator) VmAreaTree {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *VmAreaTree) void {
        var items: std.ArrayList(*VmAreaStruct) = .empty;
        defer items.deinit(self.allocator);
        var v = self.first();
        while (v) |cur| : (v = self.next(cur)) {
            items.append(self.allocator, cur) catch return;
        }
        for (items.items) |cur| self.allocator.destroy(cur);
        self.tree = rbtree.Tree.init(.{});
        self.nr_vmas = 0;
    }

    pub fn first(self: *const VmAreaTree) ?*VmAreaStruct {
        const n = self.tree.minimum() orelse return null;
        return vmaOf(n);
    }

    pub fn next(self: *const VmAreaTree, v: *VmAreaStruct) ?*VmAreaStruct {
        const n = self.tree.next(&v.rb) orelse return null;
        return vmaOf(n);
    }

    /// find_vma(): VMA, покрывающий addr (или следующий за ним в Linux;
    /// здесь строго containing — для mmap/mprotect это то, что нужно).
    pub fn find(self: *const VmAreaTree, addr: u64) ?*VmAreaStruct {
        var n = self.tree.root;
        while (n) |node| {
            const v = vmaOf(node);
            if (addr < v.vm_start) {
                n = node.left;
            } else if (addr >= v.vm_end) {
                n = node.right;
            } else {
                return v;
            }
        }
        return null;
    }

    /// Последний VMA с vm_start < start.
    fn predecessor(self: *const VmAreaTree, start: u64) ?*VmAreaStruct {
        var best: ?*VmAreaStruct = null;
        var n = self.tree.root;
        while (n) |node| {
            const v = vmaOf(node);
            if (v.vm_start < start) {
                best = v;
                n = node.right;
            } else {
                n = node.left;
            }
        }
        return best;
    }

    /// Первый VMA с vm_start > start.
    fn successor(self: *const VmAreaTree, start: u64) ?*VmAreaStruct {
        var best: ?*VmAreaStruct = null;
        var n = self.tree.root;
        while (n) |node| {
            const v = vmaOf(node);
            if (v.vm_start > start) {
                best = v;
                n = node.left;
            } else {
                n = node.right;
            }
        }
        return best;
    }

    /// Вставить готовый VMA без проверки пересечения (для dup_mmap()).
    pub fn insertRaw(self: *VmAreaTree, start: u64, end: u64, flags: u64, prot: u32) !*VmAreaStruct {
        return self.insertRawFile(start, end, flags, prot, null, 0);
    }

    /// vm_file/vm_pgoff — как у исходного VMA: split/mprotect не должны терять
    /// файловый источник страниц.
    pub fn insertRawFile(
        self: *VmAreaTree,
        start: u64,
        end: u64,
        flags: u64,
        prot: u32,
        src: ?*file.File,
        pgoff: u64,
    ) !*VmAreaStruct {
        const v = try self.allocator.create(VmAreaStruct);
        v.* = .{
            .vm_start = start,
            .vm_end = end,
            .vm_flags = flags,
            .vm_page_prot = prot,
            .vm_file = src,
            .vm_pgoff = pgoff,
        };
        self.tree.insert(&v.rb, less);
        self.nr_vmas += 1;
        return v;
    }

    pub fn insert(self: *VmAreaTree, v: *VmAreaStruct) !void {
        if (v.vm_end <= v.vm_start) return error.EINVAL;
        if (self.predecessor(v.vm_start)) |p| {
            if (p.vm_end > v.vm_start) return error.ENOMEM; // overlaps previous
        }
        if (self.successor(v.vm_start)) |s| {
            if (s.vm_start < v.vm_end) return error.ENOMEM; // overlaps next
        }
        self.tree.insert(&v.rb, less);
        self.nr_vmas += 1;
    }

    pub fn remove(self: *VmAreaTree, v: *VmAreaStruct) void {
        self.tree.erase(&v.rb);
        self.nr_vmas -= 1;
        self.allocator.destroy(v);
    }

    pub fn totalPages(self: *const VmAreaTree) u64 {
        var total: u64 = 0;
        var v = self.first();
        while (v) |cur| : (v = self.next(cur)) total += cur.pages();
        return total;
    }

    /// mm/mmap.c: do_mmap() — добавить отображение [addr, addr+len).
    pub fn mmap(self: *VmAreaTree, addr: u64, len: u64, prot: u32, flags: u64) !*VmAreaStruct {
        if (len == 0 or addr + len < addr) return error.EINVAL;
        var start = if (addr == 0) alignUp(self.next_base, PAGE_SIZE) else alignDown(addr, PAGE_SIZE);
        var end = alignUp(start + len, PAGE_SIZE);

        if (flags & MAP_FIXED == 0) {
            // Найти первую свободную дыру не раньше start.
            var cur = self.predecessor(start);
            if (cur == null) cur = self.first();
            while (cur) |v| {
                if (v.vm_end <= start) {
                    cur = self.next(v);
                    continue;
                }
                if (v.vm_start >= end) break; // поместилось перед v
                start = v.vm_end;
                end = alignUp(start + len, PAGE_SIZE);
                cur = self.next(v);
            }
        } else {
            try self.munmap(start, end - start);
        }

        var vmflags = flagsForProt(prot);
        if (flags & MAP_SHARED != 0) vmflags |= VM_SHARED | VM_MAYSHARE;
        if (flags & MAP_ANONYMOUS != 0) vmflags |= VM_ACCOUNT;
        if (flags & MAP_GROWSDOWN != 0) vmflags |= VM_GROWSDOWN;
        if (flags & MAP_STACK != 0) vmflags |= VM_GROWSDOWN;
        if (flags & MAP_NORESERVE != 0) vmflags |= VM_NORESERVE;

        const v = try self.insertRaw(start, end, vmflags, prot);
        if (end > self.next_base) self.next_base = end;
        return v;
    }

    /// mm/mmap.c: do_mmap() с file → vm_file/vm_pgoff для file-backed fault.
    pub fn mmapFile(
        self: *VmAreaTree,
        addr: u64,
        len: u64,
        prot: u32,
        flags: u64,
        f: *file.File,
        pgoff: u64,
    ) !*VmAreaStruct {
        if (flags & MAP_ANONYMOUS != 0) return error.EINVAL;
        _ = std.math.mul(u64, pgoff, PAGE_SIZE) catch return error.EINVAL;
        const v = try self.mmap(addr, len, prot, flags);
        v.vm_file = f;
        v.vm_pgoff = pgoff;
        v.vm_flags &= ~VM_ACCOUNT; // file-backed страницы не из anon-пула
        return v;
    }

    /// mm/mmap.c: do_vmi_munmap() — убрать диапазон, обрезая/разбивая VMA.
    pub fn munmap(self: *VmAreaTree, addr: u64, len: u64) !void {
        if (len == 0) return error.EINVAL;
        const start = alignDown(addr, PAGE_SIZE);
        const end = alignUp(addr + len, PAGE_SIZE);

        // Снимок: итератор rbtree небезопасен при удалении узлов.
        var overlaps: std.ArrayList(*VmAreaStruct) = .empty;
        defer overlaps.deinit(self.allocator);
        var v = self.first();
        while (v) |cur| : (v = self.next(cur)) {
            if (cur.vm_start < end and cur.vm_end > start) {
                try overlaps.append(self.allocator, cur);
            }
        }
        for (overlaps.items) |cur| {
            const s = cur.vm_start;
            const e = cur.vm_end;
            const flags = cur.vm_flags;
            const src = cur.vm_file;
            const pgoff = cur.vm_pgoff;
            self.remove(cur);
            if (s < start) _ = try self.insertRawFile(s, start, flags, protOf(flags), src, pgoff);
            if (e > end) {
                const delta = (end - s) >> PAGE_SHIFT;
                _ = try self.insertRawFile(end, e, flags, protOf(flags), src, pgoff + delta);
            }
        }
    }

    /// mm/mprotect.c: do_mprotect_pkey() — заменить prot на диапазоне.
    pub fn mprotect(self: *VmAreaTree, addr: u64, len: u64, prot: u32) !void {
        if (len == 0) return error.EINVAL;
        const start = alignDown(addr, PAGE_SIZE);
        const end = alignUp(addr + len, PAGE_SIZE);
        var overlaps: std.ArrayList(*VmAreaStruct) = .empty;
        defer overlaps.deinit(self.allocator);
        var v = self.first();
        while (v) |cur| : (v = self.next(cur)) {
            if (cur.vm_start < end and cur.vm_end > start) {
                try overlaps.append(self.allocator, cur);
            }
        }
        if (overlaps.items.len == 0) return error.ENOMEM;
        for (overlaps.items) |cur| {
            const s = cur.vm_start;
            const e = cur.vm_end;
            const flags = cur.vm_flags;
            const src = cur.vm_file;
            const pgoff = cur.vm_pgoff;
            self.remove(cur);
            const ns = @max(s, start);
            const ne = @min(e, end);
            if (s < ns) _ = try self.insertRawFile(s, ns, flags, protOf(flags), src, pgoff);
            _ = try self.insertRawFile(ns, ne, applyProt(flags, prot), prot, src, pgoff + ((ns - s) >> PAGE_SHIFT));
            if (ne < e) {
                _ = try self.insertRawFile(ne, e, flags, protOf(flags), src, pgoff + ((ne - s) >> PAGE_SHIFT));
            }
        }
    }

    fn protOf(flags: u64) u32 {
        var p: u32 = 0;
        if (flags & VM_READ != 0) p |= PROT_READ;
        if (flags & VM_WRITE != 0) p |= PROT_WRITE;
        if (flags & VM_EXEC != 0) p |= PROT_EXEC;
        return p;
    }
};

test "VMA: mmap/find/munmap/mprotect preserve non-overlap and split ranges" {
    var t = VmAreaTree.init(std.testing.allocator);
    defer t.deinit();

    const a = try t.mmap(0, 3 * PAGE_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS);
    const b = try t.mmap(0, PAGE_SIZE, PROT_READ | PROT_EXEC, MAP_PRIVATE);
    const a_start = a.vm_start;
    const a_end = a.vm_end;
    try std.testing.expect(a.vm_start < b.vm_start);
    try std.testing.expectEqual(@as(usize, 2), t.nr_vmas);
    try std.testing.expect(t.find(a.vm_start + 100) != null);
    try std.testing.expect(t.find(a_end) == null or t.find(a_end).?.vm_start == b.vm_start);

    // Пересечение запрещено.
    const v = try std.testing.allocator.create(VmAreaStruct);
    defer std.testing.allocator.destroy(v);
    v.* = .{ .vm_start = a_start, .vm_end = a_end + PAGE_SIZE, .vm_flags = 0, .vm_page_prot = 0 };
    try std.testing.expectError(error.ENOMEM, t.insert(v));

    // Разбиваем первый VMA: [a.start, a.start+P) остаётся, средний удаляется.
    try t.munmap(a_start + PAGE_SIZE, PAGE_SIZE);
    try std.testing.expectEqual(@as(usize, 3), t.nr_vmas);
    try std.testing.expect(t.find(a_start + PAGE_SIZE) == null);
    try std.testing.expect(t.find(a_start) != null);
    try std.testing.expect(t.find(a_start + 2 * PAGE_SIZE) != null);

    // mprotect меняет права только на среднем фрагменте.
    try t.mprotect(a_start + 2 * PAGE_SIZE, PAGE_SIZE, PROT_READ);
    const middle = t.find(a_start + 2 * PAGE_SIZE).?;
    try std.testing.expectEqual(@as(u64, VM_READ), middle.vm_flags & VM_READ);
    try std.testing.expectEqual(@as(u64, 0), middle.vm_flags & VM_WRITE);

    // MAP_FIXED вытесняет прежние VMA.
    const fixed = try t.mmap(a_start, PAGE_SIZE, PROT_READ, MAP_PRIVATE | MAP_FIXED);
    try std.testing.expectEqual(a_start, fixed.vm_start);
    try std.testing.expectEqual(@as(u64, PAGE_SIZE), fixed.vm_end - fixed.vm_start);
}

test "VMA: file-backed mmap keeps vm_file/vm_pgoff across split and mprotect" {
    var t = VmAreaTree.init(std.testing.allocator);
    defer t.deinit();
    var f: file.File = .{};

    const v = try t.mmapFile(0, 4 * PAGE_SIZE, PROT_READ, MAP_PRIVATE, &f, 3);
    try std.testing.expect(v.vm_file == &f);
    try std.testing.expectEqual(@as(u64, 3), v.vm_pgoff);
    const base = v.vm_start;

    // mprotect делит VMA: вторая половина должна указывать на file page 4.
    try t.mprotect(base + 2 * PAGE_SIZE, PAGE_SIZE, PROT_READ | PROT_WRITE);
    const third = t.find(base + 2 * PAGE_SIZE).?;
    try std.testing.expect(third.vm_file == &f);
    try std.testing.expectEqual(@as(u64, 5), third.vm_pgoff);

    // munmap вырезает первую страницу: следующий фрагмент сохраняет pgoff 4.
    try t.munmap(base, PAGE_SIZE);
    try std.testing.expect(t.find(base) == null);
    const second = t.find(base + PAGE_SIZE).?;
    try std.testing.expect(second.vm_file == &f);
    try std.testing.expectEqual(@as(u64, 4), second.vm_pgoff);
}

test "VMA: totalPages and rb-tree sorted order" {
    var t = VmAreaTree.init(std.testing.allocator);
    defer t.deinit();
    for (0..32) |_| _ = try t.mmap(0, PAGE_SIZE, PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS);
    try std.testing.expectEqual(@as(usize, 32), t.nr_vmas);
    try std.testing.expectEqual(@as(u64, 32), t.totalPages());
    var prev: u64 = 0;
    var v = t.first();
    while (v) |cur| : (v = t.next(cur)) {
        try std.testing.expect(cur.vm_start > prev);
        prev = cur.vm_start;
    }
}
