//! Порт lib/rbtree.c + include/linux/rbtree.h (Linux 7.3) на Zig.
//! Красное-чёрное дерево с аугментацией (как в CFS: subtree min_vruntime).
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

pub const Color = enum { red, black };

pub const Node = struct {
    parent: ?*Node = null,
    left: ?*Node = null,
    right: ?*Node = null,
    color: Color = .red,

    pub inline fn parentColor(self: *const Node) ?*Node {
        return self.parent;
    }
};

/// Дополнительные операции аугментации (аналог struct rb_augment_callbacks).
pub const Augment = struct {
    ctx: ?*anyopaque = null,
    /// Скопировать аугментированные данные src -> dst.
    copy: ?*const fn (ctx: ?*anyopaque, dst: *Node, src: *Node) void = null,
    /// Пересчитать аугментированные данные node по детям.
    propagate: ?*const fn (ctx: ?*anyopaque, node: *Node) void = null,
    /// Вызывается после поворота (old ушёл вниз, new поднялся).
    rotate: ?*const fn (ctx: ?*anyopaque, old: *Node, new: *Node) void = null,
};

pub const Tree = struct {
    root: ?*Node = null,
    augment: Augment = .{},

    pub fn init(augment: Augment) Tree {
        return .{ .augment = augment };
    }

    pub fn empty(self: *const Tree) bool {
        return self.root == null;
    }

    pub inline fn setParent(n: *Node, p: ?*Node) void {
        n.parent = p;
    }

    fn rotateLeft(self: *Tree, old: *Node) void {
        const new = old.right orelse return;
        old.right = new.left;
        if (new.left) |l| setParent(l, old);
        setParent(new, old.parent);
        if (old.parent) |p| {
            if (p.left == old) p.left = new else p.right = new;
        } else {
            self.root = new;
        }
        new.left = old;
        setParent(old, new);
        if (self.augment.rotate) |f| f(self.augment.ctx, old, new);
    }

    fn rotateRight(self: *Tree, old: *Node) void {
        const new = old.left orelse return;
        old.left = new.right;
        if (new.right) |r| setParent(r, old);
        setParent(new, old.parent);
        if (old.parent) |p| {
            if (p.right == old) p.right = new else p.left = new;
        } else {
            self.root = new;
        }
        new.right = old;
        setParent(old, new);
        if (self.augment.rotate) |f| f(self.augment.ctx, old, new);
    }

    fn propagateUp(self: *Tree, node: *Node) void {
        var n: ?*Node = node;
        while (n) |cur| {
            if (self.augment.propagate) |f| f(self.augment.ctx, cur);
            n = cur.parent;
        }
    }

    /// Вставка с компаратором `less(a, b)` — true, если a должен быть левее b.
    pub fn insert(self: *Tree, node: *Node, less: *const fn (*Node, *Node) bool) void {
        node.left = null;
        node.right = null;
        node.color = .red;

        var parent: ?*Node = null;
        var cur = self.root;
        while (cur) |n| {
            parent = n;
            cur = if (less(node, n)) n.left else n.right;
        }
        setParent(node, parent);
        if (parent) |p| {
            if (less(node, p)) p.left = node else p.right = node;
        } else {
            self.root = node;
        }
        self.propagateUp(node);
        self.insertFixup(node);
    }

    fn insertFixup(self: *Tree, z_initial: *Node) void {
        var z = z_initial;
        while (z.parent) |p| {
            if (p.color == .black) break;
            const gp = p.parent orelse break; // корень всегда чёрный
            if (p == gp.left) {
                const uncle = gp.right;
                if (uncle != null and uncle.?.color == .red) {
                    p.color = .black;
                    uncle.?.color = .black;
                    gp.color = .red;
                    z = gp;
                } else {
                    if (z == p.right) {
                        z = p;
                        self.rotateLeft(z);
                    }
                    const p2 = z.parent.?;
                    p2.color = .black;
                    const g2 = p2.parent.?;
                    g2.color = .red;
                    self.rotateRight(g2);
                }
            } else {
                const uncle = gp.left;
                if (uncle != null and uncle.?.color == .red) {
                    p.color = .black;
                    uncle.?.color = .black;
                    gp.color = .red;
                    z = gp;
                } else {
                    if (z == p.left) {
                        z = p;
                        self.rotateRight(z);
                    }
                    const p2 = z.parent.?;
                    p2.color = .black;
                    const g2 = p2.parent.?;
                    g2.color = .red;
                    self.rotateLeft(g2);
                }
            }
        }
        if (self.root) |r| r.color = .black;
    }

    fn transplant(self: *Tree, old: *Node, new: ?*Node) void {
        if (old.parent) |p| {
            if (p.left == old) p.left = new else p.right = new;
        } else {
            self.root = new;
        }
        if (new) |n| setParent(n, old.parent);
    }

    pub fn minimum(self: *const Tree) ?*Node {
        var n = self.root orelse return null;
        while (n.left) |l| n = l;
        return n;
    }

    pub fn maximum(self: *const Tree) ?*Node {
        var n = self.root orelse return null;
        while (n.right) |r| n = r;
        return n;
    }

    pub fn next(_: *const Tree, node: *Node) ?*Node {
        if (node.right) |r| {
            var n = r;
            while (n.left) |l| n = l;
            return n;
        }
        var cur = node;
        while (cur.parent) |p| {
            if (p.left == cur) return p;
            cur = p;
        }
        return null;
    }

    pub fn prev(_: *const Tree, node: *Node) ?*Node {
        if (node.left) |l| {
            var n = l;
            while (n.right) |r| n = r;
            return n;
        }
        var cur = node;
        while (cur.parent) |p| {
            if (p.right == cur) return p;
            cur = p;
        }
        return null;
    }

    pub fn erase(self: *Tree, z: *Node) void {
        if (self.augment.propagate) |f| {
            var p: ?*Node = z;
            while (p) |n| : (p = n.parent) {
                // перед удалением пересчитываем вверх, чтобы аугментации
                // не потеряли данные удаляемого узла
                if (n != z) f(self.augment.ctx, n);
            }
        }

        var y = z;
        var y_original_color = y.color;
        var x: ?*Node = null;
        var x_parent: ?*Node = null;

        if (z.left == null) {
            x = z.right;
            x_parent = z.parent;
            self.transplant(z, z.right);
        } else if (z.right == null) {
            x = z.left;
            x_parent = z.parent;
            self.transplant(z, z.left);
        } else {
            y = z.right.?;
            while (y.left) |l| y = l;
            y_original_color = y.color;
            x = y.right;
            if (y.parent == z) {
                x_parent = y;
                if (x) |n| setParent(n, y);
            } else {
                x_parent = y.parent;
                self.transplant(y, y.right);
                y.right = z.right;
                setParent(y.right.?, y);
            }
            self.transplant(z, y);
            y.left = z.left;
            setParent(y.left.?, y);
            y.color = z.color;
            if (self.augment.copy) |f| f(self.augment.ctx, y, z);
        }

        if (y_original_color == .black) self.eraseFixup(x, x_parent);
        if (self.root) |r| r.color = .black;
        self.propagateUp(y);

        z.parent = null;
        z.left = null;
        z.right = null;
        z.color = .red;
    }

    /// CLRS RB-DELETE-FIXUP без NIL-сентинела: x_parent явно хранит родителя
    /// «нулевого» ребёнка, чтобы не потерять позицию при x == null.
    fn eraseFixup(self: *Tree, x_initial: ?*Node, xp_initial: ?*Node) void {
        var x = x_initial;
        var xp = xp_initial;
        while (x != self.root and (x == null or x.?.color == .black)) {
            const p = xp orelse break;
            if (x == p.left or x == null and p.left == null) {
                var sibling = p.right;
                if (sibling == null) break;
                if (sibling.?.color == .red) {
                    sibling.?.color = .black;
                    p.color = .red;
                    self.rotateLeft(p);
                    sibling = p.right;
                    if (sibling == null) break;
                }
                const sl_black = sibling.?.left == null or sibling.?.left.?.color == .black;
                const sr_black = sibling.?.right == null or sibling.?.right.?.color == .black;
                if (sl_black and sr_black) {
                    sibling.?.color = .red;
                    xp = p.parent;
                    x = p;
                } else {
                    const s = sibling.?;
                    if (sr_black) {
                        if (s.left) |sl| sl.color = .black;
                        s.color = .red;
                        self.rotateRight(s);
                        sibling = p.right;
                    }
                    const s2 = sibling orelse break;
                    s2.color = p.color;
                    p.color = .black;
                    if (s2.right) |sr| sr.color = .black;
                    self.rotateLeft(p);
                    x = self.root;
                    xp = null;
                }
            } else {
                var sibling = p.left;
                if (sibling == null) break;
                if (sibling.?.color == .red) {
                    sibling.?.color = .black;
                    p.color = .red;
                    self.rotateRight(p);
                    sibling = p.left;
                    if (sibling == null) break;
                }
                const sr_black = sibling.?.right == null or sibling.?.right.?.color == .black;
                const sl_black = sibling.?.left == null or sibling.?.left.?.color == .black;
                if (sr_black and sl_black) {
                    sibling.?.color = .red;
                    xp = p.parent;
                    x = p;
                } else {
                    const s = sibling.?;
                    if (sl_black) {
                        if (s.right) |sr| sr.color = .black;
                        s.color = .red;
                        self.rotateLeft(s);
                        sibling = p.left;
                    }
                    const s2 = sibling orelse break;
                    s2.color = p.color;
                    p.color = .black;
                    if (s2.left) |sl| sl.color = .black;
                    self.rotateRight(p);
                    x = self.root;
                    xp = null;
                }
            }
        }
        if (x) |n| n.color = .black;
    }
};

fn lessNode(a: *Node, b: *Node) bool {
    return @intFromPtr(a) < @intFromPtr(b);
}

fn checkTree(n: ?*Node, min: ?*Node, max: ?*Node, expected_black: usize, blacks: *?usize) bool {
    const node = n orelse return true;
    if (node.color == .red) {
        if ((node.left != null and node.left.?.color == .red) or
            (node.right != null and node.right.?.color == .red)) return false;
    }
    if (min) |m| if (@intFromPtr(node) <= @intFromPtr(m)) return false;
    if (max) |m| if (@intFromPtr(node) >= @intFromPtr(m)) return false;
    var b = expected_black;
    if (node.color == .black) b += 1;
    if (node.left == null and node.right == null) {
        if (blacks.*) |prev| {
            if (prev != b) return false;
        } else blacks.* = b;
    }
    return checkTree(node.left, min, node, b, blacks) and checkTree(node.right, node, max, b, blacks);
}

test "rbtree insert/erase: sorted order and red-black invariants" {
    var tree: Tree = .{};
    var nodes: [200]Node = undefined;
    var order: [nodes.len]usize = undefined;
    for (&order, 0..) |*o, i| o.* = i;
    // детерминированная перестановка
    for (&order, 0..) |*o, i| o.* = (i * 73 + 19) % nodes.len;
    for (order) |i| tree.insert(&nodes[i], lessNode);
    try std.testing.expectEqual(@as(usize, nodes.len), count(&tree));
    var blacks: ?usize = null;
    try std.testing.expect(checkTree(tree.root, null, null, 0, &blacks));

    var prev: ?*Node = null;
    var it = tree.root;
    // обход в порядке с помощью next()
    it = tree.minimum();
    var n: usize = 0;
    while (it) |cur| : (it = tree.next(cur)) {
        if (prev) |p| try std.testing.expect(@intFromPtr(p) < @intFromPtr(cur));
        prev = cur;
        n += 1;
    }
    try std.testing.expectEqual(nodes.len, n);

    for (order) |i| {
        tree.erase(&nodes[i]);
        blacks = null;
        if (tree.root != null and !checkTree(tree.root, null, null, 0, &blacks)) {
            std.debug.print("rbtree invariant broken after erasing node {d}\n", .{i});
            try std.testing.expect(false);
        }
    }
    try std.testing.expect(tree.empty());
}

fn count(tree: *const Tree) usize {
    var n: usize = 0;
    var cur = tree.minimum();
    while (cur) |c| : (cur = tree.next(c)) n += 1;
    return n;
}

const std = @import("std");
