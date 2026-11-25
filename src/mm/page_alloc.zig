//! Порт mm/page_alloc.c + include/linux/mmzone.h (Linux 7.3) на Zig.
//! Зонный buddy-аллокатор: free_area[order][migratetype], PageBuddy/private,
//! __find_buddy_pfn = pfn ^ (1 << order), expand(), __free_one_page().
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const list = @import("../list.zig");

pub const MAX_PAGE_ORDER: u8 = 10;
pub const NR_PAGE_ORDERS: u8 = MAX_PAGE_ORDER + 1;
pub const PAGE_ALLOC_COSTLY_ORDER: u8 = 3;

pub const MigrateType = enum(u8) {
    unmovable = 0,
    movable = 1,
    reclaimable = 2,
};
pub const NR_MIGRATE_TYPES: usize = 3;

/// Из mm/page_alloc.c: fallbacks[MIGRATE_PCPTYPES][MIGRATE_PCPTYPES - 1].
pub const fallbacks = [NR_MIGRATE_TYPES][NR_MIGRATE_TYPES - 1]MigrateType{
    .{ .reclaimable, .movable },
    .{ .reclaimable, .unmovable },
    .{ .unmovable, .movable },
};

pub const PAGE_BUDDY: u32 = 1 << 0;
pub const PAGE_ALLOCATED: u32 = 1 << 1;

/// Упрощённый struct page: buddy_list (lru), flags, private=buddy_order.
pub const Page = struct {
    lru: list.Node = .{},
    flags: u32 = 0,
    buddy_order: u8 = 0,
    migratetype: MigrateType = .movable,
    refcount: u32 = 0,
    private: ?*anyopaque = null,

    pub inline fn isBuddy(self: *const Page) bool {
        return self.flags & PAGE_BUDDY != 0;
    }
};

pub const FreeArea = struct {
    free_list: [NR_MIGRATE_TYPES]list.Head,
    nr_free: usize = 0,

    pub fn init(self: *FreeArea) void {
        for (&self.free_list) |*h| list.init(h);
    }
};

pub const Zone = struct {
    allocator: std.mem.Allocator,
    pages: []Page,
    free_area: [NR_PAGE_ORDERS]FreeArea,
    zone_start_pfn: u64,
    managed_pages: usize,
    nr_free_pages: usize,

    /// Инициализация обязательно in-place: sentinel-узлы free_area хранят
    /// указатели на ЭТУ структуру, поэтому её нельзя возвращать по значению.
    pub fn init(self: *Zone, allocator: std.mem.Allocator, nr_pages: usize, start_pfn: u64) !void {
        self.* = Zone{
            .allocator = allocator,
            .pages = try allocator.alloc(Page, nr_pages),
            .free_area = undefined,
            .zone_start_pfn = start_pfn,
            .managed_pages = nr_pages,
            .nr_free_pages = 0,
        };
        for (self.pages) |*p| p.* = .{};
        for (&self.free_area) |*fa| fa.init();
        // Загрузочный момент: отдаём память в buddy крупными блоками.
        var pfn: usize = 0;
        while (pfn < nr_pages) {
            var order: u8 = MAX_PAGE_ORDER;
            while (order > 0 and (pfn + (@as(usize, 1) << @intCast(order)) > nr_pages or
                !isAligned(start_pfn + @as(u64, @intCast(pfn)), order))) : (order -= 1)
            {}
            self.freeOnePage(start_pfn + @as(u64, @intCast(pfn)), order, .movable);
            pfn += @as(usize, 1) << @intCast(order);
        }
    }

    pub fn deinit(self: *Zone) void {
        self.allocator.free(self.pages);
    }

    inline fn index(self: *const Zone, pfn: u64) usize {
        return @intCast(pfn - self.zone_start_pfn);
    }

    inline fn validPfn(self: *const Zone, pfn: u64) bool {
        return pfn >= self.zone_start_pfn and pfn - self.zone_start_pfn < self.pages.len;
    }

    pub inline fn page(self: *Zone, pfn: u64) *Page {
        return &self.pages[self.index(pfn)];
    }

    pub fn isAligned(pfn: u64, order: u8) bool {
        return pfn & ((@as(u64, 1) << @intCast(order)) - 1) == 0;
    }

    /// page_is_buddy(): сосед по XOR должен быть свободен и иметь тот же order.
    pub fn isBuddyPage(self: *Zone, pfn: u64, order: u8) bool {
        const mask = (@as(u64, 1) << @intCast(order)) - 1;
        if (pfn & mask != 0) return false;
        const buddy_pfn = pfn ^ (@as(u64, 1) << @intCast(order));
        if (!self.validPfn(buddy_pfn)) return false;
        const b = self.page(buddy_pfn);
        return b.isBuddy() and b.buddy_order == order;
    }

    fn addToFreeList(self: *Zone, pfn: u64, order: u8, mt: MigrateType) void {
        const p = self.page(pfn);
        p.flags |= PAGE_BUDDY;
        p.buddy_order = order;
        p.migratetype = mt;
        const fa = &self.free_area[order];
        list.addHead(&fa.free_list[@backingInt(mt)], &p.lru);
        fa.nr_free += 1;
        self.nr_free_pages += @as(usize, 1) << @intCast(order);
    }

    fn delFromFreeList(self: *Zone, pfn: u64, order: u8, mt: MigrateType) void {
        const p = self.page(pfn);
        list.del(&p.lru);
        const fa = &self.free_area[order];
        fa.nr_free -= 1;
        self.nr_free_pages -= @as(usize, 1) << @intCast(order);
        p.flags &= ~PAGE_BUDDY;
        p.buddy_order = 0;
        _ = mt;
    }

    /// expand(): разбить блок [order=high] до нужного order.
    fn expand(self: *Zone, pfn: u64, order: u8, high: u8, mt: MigrateType) void {
        var current_high = high;
        while (current_high > order) {
            current_high -= 1;
            const buddy_pfn = pfn + (@as(u64, 1) << @intCast(current_high));
            self.addToFreeList(buddy_pfn, current_high, mt);
        }
    }

    /// __rmqueue_smallest(): первый свободный блок нужного/старшего порядка.
    fn rmqueueSmallest(self: *Zone, order: u8, mt: MigrateType) ?u64 {
        var current_order: u8 = order;
        while (current_order < NR_PAGE_ORDERS) : (current_order += 1) {
            const head = &self.free_area[current_order].free_list[@backingInt(mt)];
            if (!list.empty(head)) {
                const node = head.next.?;
                const p: *Page = @fieldParentPtr("lru", node);
                const off: usize = @intCast(@intFromPtr(p) - @intFromPtr(&self.pages[0]));
                const pfn = self.zone_start_pfn + @as(u64, @intCast(off / @sizeOf(Page)));
                self.delFromFreeList(pfn, current_order, mt);
                self.expand(pfn, order, current_order, mt);
                return pfn;
            }
        }
        return null;
    }

    fn rmqueueFallbacks(self: *Zone, order: u8, mt: MigrateType) ?u64 {
        if (self.rmqueueSmallest(order, mt)) |pfn| return pfn;
        if (@backingInt(mt) >= NR_MIGRATE_TYPES) return null;
        for (fallbacks[@backingInt(mt)]) |fallback| {
            if (self.rmqueueSmallest(order, fallback)) |pfn| return pfn;
        }
        return null;
    }

    /// alloc_pages(): вернуть PFN first page блока order или null.
    pub fn allocPages(self: *Zone, order: u8, mt: MigrateType) ?u64 {
        if (order >= NR_PAGE_ORDERS) return null;
        const pfn = self.rmqueueFallbacks(order, mt) orelse return null;
        const p = self.page(pfn);
        p.flags &= ~PAGE_BUDDY;
        p.buddy_order = 0;
        p.refcount = 1;
        p.private = null;
        return pfn;
    }

    /// __free_one_page(): слияние с buddy по XOR, пока order < MAX_PAGE_ORDER.
    pub fn freeOnePage(self: *Zone, pfn_initial: u64, order_initial: u8, mt_initial: MigrateType) void {
        var pfn = pfn_initial;
        var order = order_initial;
        var mt = mt_initial;
        while (order < MAX_PAGE_ORDER) {
            if (!self.isBuddyPage(pfn, order)) break;
            const buddy_pfn = pfn ^ (@as(u64, 1) << @intCast(order));
            const buddy = self.page(buddy_pfn);
            const buddy_mt = buddy.migratetype;
            self.delFromFreeList(buddy_pfn, order, buddy_mt);
            pfn = pfn & buddy_pfn; // min(pfn, buddy_pfn)
            order += 1;
            _ = &mt;
        }
        self.addToFreeList(pfn, order, mt);
    }

    /// __free_pages(): подготовка, сброс refcount и возврат в buddy.
    pub fn freePages(self: *Zone, pfn: u64, order: u8, mt: MigrateType) void {
        if (order >= NR_PAGE_ORDERS or !self.validPfn(pfn)) return;
        const p = self.page(pfn);
        p.refcount = 0;
        p.flags = 0;
        p.private = null;
        self.freeOnePage(pfn, order, mt);
    }

    pub fn nrFree(self: *const Zone) usize {
        return self.nr_free_pages;
    }

    pub fn nrAllocated(self: *const Zone) usize {
        return self.managed_pages - self.nr_free_pages;
    }

    /// Количество блоков в free_area[order] (для диагностики/тестов).
    pub fn nrBlocks(self: *const Zone, order: u8) usize {
        var n: usize = 0;
        for (&self.free_area[order].free_list) |*h| n += list.count(h);
        return n;
    }
};

fn pageIndexFromNode(zone: *Zone, node: *list.Node) usize {
    const p: *Page = @fieldParentPtr("lru", node);
    return @intCast((@intFromPtr(p) - @intFromPtr(&zone.pages[0])) / @sizeOf(Page));
}

test "buddy: allocate all orders then coalesce back to one block" {
    var zone: Zone = undefined;
    try zone.init(std.testing.allocator, 4096, 0);
    defer zone.deinit();
    // 4096 страниц = 4 блока MAX_ORDER (дальше сливать нельзя).
    try std.testing.expectEqual(@as(usize, 4), zone.nrBlocks(MAX_PAGE_ORDER));

    var pfns: [MAX_PAGE_ORDER]u64 = undefined;
    _ = &pfns;
    for (&pfns, 0..) |*p, o| {
        p.* = zone.allocPages(@intCast(o), .movable).?;
        try std.testing.expect(Zone.isAligned(p.*, @intCast(o)));
    }
    try std.testing.expect(zone.nrAllocated() != 0);
    for (pfns, 0..) |p, o| zone.freePages(p, @intCast(o), .movable);
    try std.testing.expectEqual(@as(usize, 0), zone.nrAllocated());
    try std.testing.expectEqual(@as(usize, 4), zone.nrBlocks(MAX_PAGE_ORDER));
}

test "buddy: randomized alloc/free keeps blocks disjoint" {
    var zone: Zone = undefined;
    try zone.init(std.testing.allocator, 1024, 0);
    defer zone.deinit();
    var used: [1024]bool = @splat(false);
    const Entry = struct { pfn: u64, order: u8 };
    var live: std.ArrayList(Entry) = .empty;
    defer live.deinit(std.testing.allocator);
    var seed: u64 = 0x12345678;
    for (0..2000) |_| {
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        if (live.items.len == 0 or (seed & 1) == 0) {
            const order: u8 = @intCast((seed >> 8) % 4);
            if (zone.allocPages(order, .unmovable)) |pfn| {
                const idx: usize = @intCast(pfn);
                for (0..(@as(usize, 1) << @intCast(order))) |k| {
                    try std.testing.expect(!used[idx + k]);
                    used[idx + k] = true;
                }
                try live.append(std.testing.allocator, .{ .pfn = pfn, .order = order });
            }
        } else {
            const i: usize = @intCast((seed >> 16) % live.items.len);
            const e = live.swapRemove(i);
            for (0..(@as(usize, 1) << @intCast(e.order))) |k| used[@as(usize, @intCast(e.pfn)) + k] = false;
            zone.freePages(e.pfn, e.order, .unmovable);
        }
    }
    for (live.items) |e| zone.freePages(e.pfn, e.order, .unmovable);
    try std.testing.expectEqual(@as(usize, 0), zone.nrAllocated());
    try std.testing.expectEqual(@as(usize, 1), zone.nrBlocks(MAX_PAGE_ORDER));
}
