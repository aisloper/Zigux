//! Порт lib/xarray.c + include/linux/xarray.h (Linux 7.3) на Zig.
//! Радикс-дерево с 6 битами на уровень, 64 слота, 2 тега на запись.
//! Реализованы xa_load/xa_store/xa_erase/xa_alloc/xa_mark-семейство.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const XA_CHUNK_SHIFT: u6 = 6;
pub const XA_CHUNK_SIZE: usize = 64;
pub const XA_CHUNK_MASK: u64 = XA_CHUNK_SIZE - 1;
pub const XA_MAX_TAGS: usize = 2;
pub const XA_MAX_HEIGHT: u8 = 11; // ceil(64 / 6)

fn heightFor(index: u64) u8 {
    var h: u8 = 0;
    var limit: u128 = XA_CHUNK_SIZE;
    while (@as(u128, index) >= limit and h < XA_MAX_HEIGHT) : (h += 1) {
        limit <<= XA_CHUNK_SHIFT;
    }
    return h;
}

fn slotFor(index: u64, height: u8) usize {
    if (height == 0) return @intCast(index & XA_CHUNK_MASK);
    return @intCast((index >> @intCast(XA_CHUNK_SHIFT * height)) & XA_CHUNK_MASK);
}

pub fn XArray(comptime V: type) type {
    return struct {
        const Self = @This();

        const Slot = union(enum) {
            empty: void,
            value: V,
            node: *Node,
        };

        fn initSlots() [XA_CHUNK_SIZE]Slot {
            var s: [XA_CHUNK_SIZE]Slot = undefined;
            for (&s) |*e| e.* = .{ .empty = {} };
            return s;
        }

        const Node = struct {
            slots: [XA_CHUNK_SIZE]Slot = initSlots(),
            marks: [XA_MAX_TAGS]u64 = @splat(0),

            fn isEmpty(self: *const Node) bool {
                for (&self.slots) |*s| switch (s.*) {
                    .empty => {},
                    else => return false,
                };
                return true;
            }
        };

        allocator: Allocator,
        root: ?*Node = null,
        height: u8 = 0,
        max_index: u64 = 0,

        pub fn init(allocator: Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.deinitNode(self.root, self.height);
            self.root = null;
            self.height = 0;
        }

        fn deinitNode(self: *Self, node_opt: ?*Node, height: u8) void {
            const node = node_opt orelse return;
            if (height > 0) {
                for (&node.slots) |*s| switch (s.*) {
                    .node => |child| self.deinitNode(child, height - 1),
                    else => {},
                };
            }
            self.allocator.destroy(node);
        }

        fn newNode(self: *Self) !*Node {
            const n = try self.allocator.create(Node);
            n.* = .{};
            return n;
        }

        fn descend(self: *Self, index: u64, create: bool) !?*Node {
            if (create and self.root == null) {
                self.root = try self.newNode();
                self.height = heightFor(index);
            }
            var node = self.root orelse return null;
            var h = self.height;
            while (h > 0) : (h -= 1) {
                const slot = slotFor(index, h);
                switch (node.slots[slot]) {
                    .node => |child| node = child,
                    .empty => {
                        if (!create) return null;
                        const child = try self.newNode();
                        child.marks = .{ 0, 0 };
                        node.slots[slot] = .{ .node = child };
                        node = child;
                    },
                    .value => unreachable, // значение на промежуточном уровне
                }
            }
            return node;
        }

        pub fn load(self: *Self, index: u64) ?V {
            const node_opt = self.descend(index, false) catch return null;
            const node = node_opt orelse return null;
            return switch (node.slots[slotFor(index, 0)]) {
                .value => |v| v,
                else => null,
            };
        }

        /// xa_store: возвращает старое значение, если было.
        pub fn store(self: *Self, index: u64, value: V) !?V {
            const need = heightFor(index);
            if (need > self.height) {
                // Старый корень покрывает диапазон с индекса 0, поэтому он
                // подвешивается по нулевым слотам новых уровней (как в xa_store).
                const old_root = self.root;
                const old_h = self.height;
                const new_root = try self.newNode();
                var cur = new_root;
                var h = need;
                while (h > old_h + 1) : (h -= 1) {
                    const child = try self.newNode();
                    cur.slots[0] = .{ .node = child };
                    cur = child;
                }
                if (old_root) |old| cur.slots[0] = .{ .node = old };
                self.root = new_root;
                self.height = need;
            }
            const node = (try self.descend(index, true)).?;
            const slot = slotFor(index, 0);
            const old = switch (node.slots[slot]) {
                .value => |v| @as(?V, v),
                else => null,
            };
            node.slots[slot] = .{ .value = value };
            if (index > self.max_index) self.max_index = index;
            return old;
        }

        /// xa_erase: возвращает удалённое значение, если было.
        pub fn erase(self: *Self, index: u64) ?V {
            const node_opt = self.descend(index, false) catch return null;
            const node = node_opt orelse return null;
            const slot = slotFor(index, 0);
            const old = switch (node.slots[slot]) {
                .value => |v| @as(?V, v),
                else => return null,
            };
            node.slots[slot] = .{ .empty = {} };
            for (&node.marks) |*m| m.* &= ~(@as(u64, 1) << @intCast(slot));
            if (node.isEmpty()) self.prune(index);
            return old;
        }

        fn prune(self: *Self, index: u64) void {
            var node_opt = self.root;
            var h = self.height;
            while (h > 0) : (h -= 1) {
                const node = node_opt orelse return;
                const slot = slotFor(index, h);
                const child = switch (node.slots[slot]) {
                    .node => |c| c,
                    else => return,
                };
                if (child.isEmpty()) {
                    self.allocator.destroy(child);
                    node.slots[slot] = .{ .empty = {} };
                    for (&node.marks) |*m| m.* &= ~(@as(u64, 1) << @intCast(slot));
                } else return;
                node_opt = node;
            }
            if (self.root) |r| {
                if (r.isEmpty()) {
                    self.allocator.destroy(r);
                    self.root = null;
                    self.height = 0;
                }
            }
        }

        /// xa_alloc: выделить первый свободный индекс в [min, max].
        pub fn alloc(self: *Self, min: u64, max: u64) !?u64 {
            var i = min;
            while (i <= max) : (i += 1) {
                if (self.load(i) == null) return i;
            }
            return null;
        }

        pub fn mark(self: *Self, index: u64, tag: usize) void {
            const node_opt = self.descend(index, false) catch return;
            const node = node_opt orelse return;
            node.marks[tag] |= @as(u64, 1) << @intCast(slotFor(index, 0));
        }

        pub fn unmark(self: *Self, index: u64, tag: usize) void {
            const node_opt = self.descend(index, false) catch return;
            const node = node_opt orelse return;
            node.marks[tag] &= ~(@as(u64, 1) << @intCast(slotFor(index, 0)));
        }

        pub fn tagged(self: *Self, index: u64, tag: usize) bool {
            const node_opt = self.descend(index, false) catch return false;
            const node = node_opt orelse return false;
            const m = node.marks[tag] & (@as(u64, 1) << @intCast(slotFor(index, 0)));
            return m != 0;
        }

        pub const WalkCtx = ?*anyopaque;
        pub const WalkFn = *const fn (ctx: WalkCtx, index: u64, value: V) void;

        pub fn walk(self: *Self, ctx: WalkCtx, comptime unused_tag: ?usize, f: WalkFn) void {
            _ = unused_tag;
            if (self.root) |root| self.walkNode(root, self.height, 0, ctx, f);
        }

        fn walkNode(self: *Self, node: *Node, height: u8, prefix: u64, ctx: WalkCtx, f: WalkFn) void {
            for (&node.slots, 0..) |*s, i| {
                const index = prefix | (@as(u64, @intCast(i)) << @intCast(XA_CHUNK_SHIFT * height));
                switch (s.*) {
                    .empty => {},
                    .value => |v| f(ctx, index, v),
                    .node => |child| self.walkNode(child, height - 1, index, ctx, f),
                }
            }
        }
    };
}

const WalkEntry = struct { i: u64, v: []const u8 };
const CollectCtx = struct { list: *std.ArrayList(WalkEntry), allocator: Allocator };

fn collect(ctx: ?*anyopaque, index: u64, value: []const u8) void {
    const c: *CollectCtx = @ptrCast(@alignCast(ctx.?));
    c.list.append(c.allocator, .{ .i = index, .v = value }) catch unreachable;
}

test "xarray store/load/erase/alloc/tags/walk" {
    var xa = XArray([]const u8).init(std.testing.allocator);
    defer xa.deinit();
    try std.testing.expect((try xa.store(5, "five")) == null);
    try std.testing.expectEqualStrings("five", xa.load(5).?);
    try std.testing.expectEqualStrings("five", (try xa.store(5, "FIVE")).?);
    _ = try xa.store(70, "seventy");
    _ = try xa.store(5000, "five thousand");
    try std.testing.expectEqualStrings("seventy", xa.load(70).?);
    try std.testing.expectEqualStrings("five thousand", xa.load(5000).?);
    try std.testing.expectEqual(@as(?u64, 0), try xa.alloc(0, 100));

    xa.mark(70, 0);
    try std.testing.expect(xa.tagged(70, 0));
    try std.testing.expect(!xa.tagged(5, 0));
    xa.unmark(70, 0);
    try std.testing.expect(!xa.tagged(70, 0));

    var list: std.ArrayList(WalkEntry) = .empty;
    defer list.deinit(std.testing.allocator);
    var cctx = CollectCtx{ .list = &list, .allocator = std.testing.allocator };
    xa.walk(&cctx, null, collect);
    try std.testing.expectEqual(@as(usize, 3), list.items.len);

    try std.testing.expectEqualStrings("five thousand", xa.erase(5000).?);
    try std.testing.expect(xa.load(5000) == null);
}

fn sumCtx(ctx: ?*anyopaque, index: u64, value: u32) void {
    _ = index;
    const s: *u32 = @ptrCast(@alignCast(ctx.?));
    s.* += value;
}

test "xarray 4096 entries across radix levels" {
    var xa = XArray(u32).init(std.testing.allocator);
    defer xa.deinit();
    for (0..4096) |i| _ = try xa.store(@intCast(i), @intCast(i * 2));
    var sum: u32 = 0;
    xa.walk(&sum, null, sumCtx);
    var expected: u32 = 0;
    for (0..4096) |i| expected += @intCast(i * 2);
    try std.testing.expectEqual(expected, sum);
    for (0..4096) |i| {
        try std.testing.expectEqual(@as(u32, @intCast(i * 2)), xa.load(@intCast(i)).?);
    }
}
