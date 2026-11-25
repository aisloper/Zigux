//! Порт include/linux/list.h (Linux 7.3) на Zig.
//! Intrusive doubly-linked list и hlist. Узлы встраиваются в структуру,
//! контейнер получается через @fieldParentPtr — как container_of() в Linux.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

pub const Node = struct {
    next: ?*Node = null,
    prev: ?*Node = null,
};

/// Аналог struct list_head: тот же Node, но используется как sentinel.
pub const Head = Node;

pub fn init(head: *Head) void {
    head.next = head;
    head.prev = head;
}

pub inline fn empty(head: *const Head) bool {
    return head.next.? == @constCast(head);
}

/// list_add(new, prev, next)
pub fn add(new: *Node, prev: *Node, next: *Node) void {
    next.prev = new;
    new.next = next;
    new.prev = prev;
    prev.next = new;
}

pub fn addHead(head: *Head, new: *Node) void {
    add(new, head, head.next.?);
}

pub fn addTail(head: *Head, new: *Node) void {
    add(new, head.prev.?, head);
}

pub fn del(entry: *Node) void {
    entry.prev.?.next = entry.next;
    entry.next.?.prev = entry.prev;
    entry.next = null;
    entry.prev = null;
}

pub fn delInit(entry: *Node) void {
    del(entry);
    init(entry);
}

pub fn moveTail(head: *Head, entry: *Node) void {
    del(entry);
    addTail(head, entry);
}

pub fn replace(old: *Node, new: *Node) void {
    new.next = old.next;
    new.prev = old.prev;
    new.next.?.prev = new;
    new.prev.?.next = new;
}

pub fn splice(head: *Head, list: *Head) void {
    if (empty(list)) return;
    const first = list.next.?;
    const last = list.prev.?;
    first.prev = head;
    head.next.?.prev = last;
    last.next = head.next;
    head.next = first;
    init(list);
}

pub fn count(head: *const Head) usize {
    var n: usize = 0;
    var cur = head.next.?;
    while (cur != @constCast(head)) : (cur = cur.next.?) n += 1;
    return n;
}

pub const Iterator = struct {
    head: *Head,
    cur: *Node,

    pub fn next(self: *Iterator) ?*Node {
        const n = self.cur.next orelse return null;
        if (n == self.head) return null;
        self.cur = n;
        return n;
    }
};

pub fn iterator(head: *Head) Iterator {
    return .{ .head = head, .cur = head };
}

/// hlist: односвязный список с указателем на указатель (include/linux/list.h).
pub const HNode = struct {
    next: ?*HNode = null,
    pprev: ?*?*HNode = null,
};

pub const HHead = ?*HNode;

pub fn hAdd(head: *HHead, node: *HNode) void {
    node.next = head.*;
    node.pprev = head;
    if (head.*) |first| first.pprev = &node.next;
    head.* = node;
}

pub fn hAddTail(head: *HHead, node: *HNode) void {
    node.next = null;
    if (head.* == null) {
        node.pprev = head;
        head.* = node;
        return;
    }
    var last = head.*.?;
    while (last.next) |n| last = n;
    last.next = node;
    node.pprev = &last.next;
}

pub fn hDel(node: *HNode) void {
    const pp = node.pprev orelse return;
    pp.* = node.next;
    if (node.next) |n| n.pprev = pp;
    node.next = null;
    node.pprev = null;
}

pub fn hEmpty(head: *const HHead) bool {
    return head.* == null;
}

test "list head/add/iterate/del" {
    const Item = struct { value: u32, link: Node = .{} };
    var head: Head = .{};
    init(&head);
    var a = Item{ .value = 1 };
    var b = Item{ .value = 2 };
    addTail(&head, &a.link);
    addTail(&head, &b.link);
    try std.testing.expectEqual(@as(usize, 2), count(&head));
    var it = iterator(&head);
    const first = it.next().?;
    const item_a: *Item = @fieldParentPtr("link", first);
    try std.testing.expectEqual(@as(u32, 1), item_a.value);
    del(&a.link);
    try std.testing.expectEqual(@as(usize, 1), count(&head));
}

test "hlist add/del" {
    const Item = struct { value: u32, link: HNode = .{} };
    var head: HHead = null;
    var a = Item{ .value = 1 };
    var b = Item{ .value = 2 };
    hAdd(&head, &a.link);
    hAdd(&head, &b.link);
    try std.testing.expectEqual(@as(*HNode, &a.link), b.link.next.?);
    hDel(&a.link);
    try std.testing.expectEqual(@as(?*HNode, &b.link), head);
}

const std = @import("std");
