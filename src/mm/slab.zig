//! Упрощённый порт mm/slub.c (Linux 7.3) на Zig: kmem_cache + partial-листы.
//! Различия с SLUB 7.3: нет per-CPU sheaf/barn, cmpxchg_double и NUMA-узлов;
//! метаданные slab хранятся отдельно (не в struct page). Invariants partial/full
//! и вызов ctor при построении slab сохранены.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const page_alloc = @import("page_alloc.zig");
const list = @import("../list.zig");

pub const PAGE_SIZE: usize = 4096;
pub const ObjPtr = [*]u8;
pub const Ctor = *const fn (obj: ObjPtr) void;

const Slab = struct {
    link: list.Node = .{},
    all_link: list.Node = .{},
    pfn: u64,
    order: u8,
    /// В хостовом симуляторе данные slab отделены от struct page: в реальном
    /// ядре это virt_to_page(pfn) / phys_to_virt(pfn << PAGE_SHIFT).
    storage: []u8,
    base: ObjPtr,
    freelist: ?ObjPtr,
    inuse: usize,
    objects: usize,
    on_partial: bool,

    fn contains(self: *const Slab, cache: *const KmemCache, obj: ObjPtr) bool {
        const a = @intFromPtr(obj);
        const begin = @intFromPtr(self.base);
        const end = begin + self.objects * cache.size;
        return a >= begin and a < end and (a - begin) % cache.size == 0;
    }
};

pub const KmemCache = struct {
    allocator: std.mem.Allocator,
    zone: *page_alloc.Zone,
    name: []const u8,
    object_size: usize,
    size: usize,
    offset: usize,
    order: u8,
    objects: usize,
    ctor: ?Ctor,
    min_partial: usize,
    partial: list.Head,
    all_slabs: list.Head,
    by_pfn: std.AutoHashMap(u64, *Slab),
    nr_alloc: usize = 0,
    nr_slabs_created: usize = 0,

    /// in-place: partial/all_slabs — sentinel-списки со ссылками на сам кэш.
    pub fn init(self: *KmemCache, allocator: std.mem.Allocator, zone: *page_alloc.Zone, name: []const u8, object_size: usize, ctor: ?Ctor) !void {
        // freepointer после объекта, как в SLUB с ctor (mm/slub.c:7923):
        // size включает слово под freepointer, offset выровнен по word.
        const offset = std.mem.alignForward(usize, object_size, @alignOf(usize));
        const size = std.mem.alignForward(usize, offset + @sizeOf(ObjPtr), @alignOf(usize));
        var order: u8 = 0;
        while ((PAGE_SIZE << @intCast(order)) / size < 1 and order < 4) : (order += 1) {}
        const objects = (PAGE_SIZE << @intCast(order)) / size;
        self.* = KmemCache{
            .allocator = allocator,
            .zone = zone,
            .name = name,
            .object_size = object_size,
            .size = size,
            .offset = offset,
            .order = order,
            .objects = objects,
            .ctor = ctor,
            .min_partial = 1,
            .partial = .{},
            .all_slabs = .{},
            .by_pfn = std.AutoHashMap(u64, *Slab).init(allocator),
        };
        list.init(&self.partial);
        list.init(&self.all_slabs);
    }

    pub fn deinit(self: *KmemCache) void {
        var node = self.all_slabs.next;
        while (node) |n| {
            if (n == &self.all_slabs) break; // sentinel
            const next = n.next; // сохраняем до освобождения узла
            const slab: *Slab = @fieldParentPtr("all_link", n);
            self.allocator.free(slab.storage);
            self.zone.freePages(slab.pfn, slab.order, .unmovable);
            self.allocator.destroy(slab);
            node = next;
        }
        self.by_pfn.deinit();
    }

    fn setFree(self: *const KmemCache, obj: ObjPtr, next: ?ObjPtr) void {
        // Слот freepointer внутри страницы slab (offset вычислен в create()).
        const slot: *?ObjPtr = @ptrCast(@alignCast(obj + self.offset));
        slot.* = next;
    }

    fn getFree(self: *const KmemCache, obj: ObjPtr) ?ObjPtr {
        const slot: *const ?ObjPtr = @ptrCast(@alignCast(obj + self.offset));
        return slot.*;
    }

    fn addSlab(self: *KmemCache) !*Slab {
        const pfn = self.zone.allocPages(self.order, .unmovable) orelse return error.OutOfMemory;
        const slab = try self.allocator.create(Slab);
        const storage = try self.allocator.alloc(u8, PAGE_SIZE << @intCast(self.order));
        slab.* = .{
            .pfn = pfn,
            .order = self.order,
            .storage = storage,
            .base = storage.ptr,
            .freelist = null,
            .inuse = 0,
            .objects = self.objects,
            .on_partial = false,
        };
        // build_slab_freelist(): ctor вызывается один раз на объект при создании slab.
        var i: usize = self.objects;
        while (i > 0) {
            i -= 1;
            const obj = slab.base + i * self.size;
            self.setFree(obj, slab.freelist);
            slab.freelist = obj;
            if (self.ctor) |f| f(obj);
        }
        try self.by_pfn.put(pfn, slab);
        list.addHead(&self.all_slabs, &slab.all_link);
        self.addPartial(slab);
        self.nr_slabs_created += 1;
        return slab;
    }

    fn addPartial(self: *KmemCache, slab: *Slab) void {
        if (slab.on_partial) return;
        list.addHead(&self.partial, &slab.link);
        slab.on_partial = true;
    }

    fn removePartial(self: *KmemCache, slab: *Slab) void {
        _ = self;
        if (!slab.on_partial) return;
        list.del(&slab.link);
        slab.on_partial = false;
    }

    pub fn alloc(self: *KmemCache) !ObjPtr {
        var slab: *Slab = undefined;
        if (list.empty(&self.partial)) {
            slab = try self.addSlab();
        } else {
            slab = @fieldParentPtr("link", self.partial.next.?);
        }
        const obj = slab.freelist orelse return error.OutOfMemory;
        slab.freelist = self.getFree(obj);
        slab.inuse += 1;
        self.nr_alloc += 1;
        if (slab.freelist == null) self.removePartial(slab);
        return obj;
    }

    pub fn free(self: *KmemCache, obj: ObjPtr) void {
        var found: ?*Slab = null;
        var it = list.iterator(&self.all_slabs);
        while (it.next()) |node| {
            const s: *Slab = @fieldParentPtr("all_link", node);
            if (s.contains(self, obj)) {
                found = s;
                break;
            }
        }
        const slab = found orelse return;
        const was_full = slab.freelist == null;
        self.setFree(obj, slab.freelist);
        slab.freelist = obj;
        slab.inuse -= 1;
        self.nr_alloc -= 1;
        if (was_full) self.addPartial(slab);
        // min_partial: пустой slab оставляем в списке, как SLUB.
    }
};

var test_ctor_count: usize = 0;
fn testCtor(obj: ObjPtr) void {
    _ = obj;
    test_ctor_count += 1;
}

test "kmem_cache: freelist, ctor once per object, reuse and free" {
    var zone: page_alloc.Zone = undefined;
    try zone.init(std.testing.allocator, 1024, 0);
    defer zone.deinit();
    test_ctor_count = 0;
    var cache: KmemCache = undefined;
    try cache.init(std.testing.allocator, &zone, "test", 16, testCtor);
    defer cache.deinit();
    try std.testing.expect(cache.size >= 16);
    const a = try cache.alloc();
    // SLUB вызывает ctor один раз на объект при построении slab.
    try std.testing.expectEqual(cache.objects, test_ctor_count);
    const b = try cache.alloc();
    @as(*u32, @ptrCast(@alignCast(a))).* = 0x11223344;
    try std.testing.expectEqual(@as(u32, 0x11223344), @as(*u32, @ptrCast(@alignCast(a))).*);
    cache.free(a);
    const c = try cache.alloc();
    try std.testing.expectEqual(@as(u32, 0x11223344), @as(*u32, @ptrCast(@alignCast(c))).*);
    cache.free(b);
    cache.free(c);
    try std.testing.expectEqual(@as(usize, 0), cache.nr_alloc);
}
