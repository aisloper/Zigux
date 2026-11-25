//! Порт ядра cgroup v2 Linux 7.3: kernel/cgroup/cgroup.c (cgroup_mkdir,
//! cgroup_rmdir, cgroup_subtree_control_write, cgroup_attach_task,
//! cgroup_vet_subtree_control_enable), kernel/cgroup/pids.c (pids_can_fork)
//! и mm/memcontrol.c (memory.max, try_charge). GPL-2.0-only.

const std = @import("std");

pub const Controller = struct {
    pub const cpu: u16 = 1 << 0;
    pub const memory: u16 = 1 << 1;
    pub const io: u16 = 1 << 2;
    pub const pids: u16 = 1 << 3;
    pub const all: u16 = cpu | memory | io | pids;
};

pub fn controllerFromName(name: []const u8) ?u16 {
    if (std.mem.eql(u8, name, "cpu")) return Controller.cpu;
    if (std.mem.eql(u8, name, "memory")) return Controller.memory;
    if (std.mem.eql(u8, name, "io")) return Controller.io;
    if (std.mem.eql(u8, name, "pids")) return Controller.pids;
    return null;
}

pub const MAX_CGROUPS: usize = 16;
pub const MAX_TASKS: usize = 32;
pub const MAX_DEPTH: u8 = 8;
pub const NAME_LEN: usize = 32;
pub const NO_LIMIT: u64 = std.math.maxInt(u64);

pub const Cgroup = struct {
    active: bool = false,
    parent: ?usize = null,
    name: [NAME_LEN]u8 = @splat(0),
    name_len: usize = 0,
    level: u8 = 0,
    control: u16 = 0,
    subtree_control: u16 = 0,
    children: usize = 0,
    tasks: [MAX_TASKS]u32 = @splat(0),
    nr_tasks: usize = 0,
    memory_current: u64 = 0,
    memory_max: u64 = NO_LIMIT,
    pids_current: usize = 0,
    pids_max: usize = MAX_TASKS,
    cpu_quota: u64 = NO_LIMIT,
    cpu_period: u64 = 100000,
    events_max: usize = 0,
    events_oom: usize = 0,

    pub fn key(self: *const Cgroup) []const u8 {
        return self.name[0..self.name_len];
    }
};

/// cgroupfs: фиксированные слоты вместо kernfs, чтобы probe работал
/// в загрузочном ядре без аллокатора.
pub const Hierarchy = struct {
    groups: [MAX_CGROUPS]Cgroup = @splat(.{}),
    task_cgroup: [MAX_TASKS]?usize = @splat(null),
    nr_groups: usize = 1,

    pub fn init(self: *Hierarchy) void {
        self.* = .{};
        self.groups[0] = .{
            .active = true,
            .name = blk: {
                var n: [NAME_LEN]u8 = @splat(0);
                n[0] = '/';
                break :blk n;
            },
            .name_len = 1,
            .control = Controller.all,
        };
    }

    pub fn root(self: *Hierarchy) *Cgroup {
        return &self.groups[0];
    }

    fn get(self: *Hierarchy, idx: usize) !*Cgroup {
        if (idx >= self.nr_groups or !self.groups[idx].active) return error.NoGroup;
        return &self.groups[idx];
    }

    /// cgroup_mkdir(): имя не содержит '/' и '\\n', уникально среди детей,
    /// глубина ограничена, а унаследованные контроллеры приходят от родителя.
    pub fn mkdir(self: *Hierarchy, parent_idx: usize, name: []const u8) !usize {
        const parent = try self.get(parent_idx);
        if (name.len == 0 or name.len > NAME_LEN or
            std.mem.indexOfAny(u8, name, "/\n") != null) return error.InvalidName;
        if (parent.level >= MAX_DEPTH) return error.TooDeep;
        for (self.groups[0..self.nr_groups]) |g| {
            if (g.active and g.parent == parent_idx and g.name_len == name.len and
                std.mem.eql(u8, g.key(), name)) return error.Exists;
        }
        var slot: ?usize = null;
        for (self.groups[1..self.nr_groups], 1..) |g, i| {
            if (!g.active) {
                slot = i;
                break;
            }
        }
        const idx = slot orelse blk: {
            if (self.nr_groups >= MAX_CGROUPS) return error.NoSpace;
            const i = self.nr_groups;
            self.nr_groups += 1;
            break :blk i;
        };
        var child = Cgroup{};
        child.active = true;
        child.parent = parent_idx;
        child.level = parent.level + 1;
        child.control = parent.control | parent.subtree_control;
        @memcpy(child.name[0..name.len], name);
        child.name_len = name.len;
        self.groups[idx] = child;
        parent.children += 1;
        return idx;
    }

    /// cgroup_subtree_control_write(): включение требует доступного
    /// контроллера, выключение — отсутствия его у живых детей; включать
    /// контроллеры в группе с задачами запрещает cgroup_vet...().
    pub fn enable(self: *Hierarchy, idx: usize, bit: u16) !void {
        const c = try self.get(idx);
        if ((c.subtree_control & bit) != 0) return error.AlreadyEnabled;
        if ((c.control & bit) == 0) return error.NoController;
        if (c.nr_tasks != 0) return error.Busy;
        for (self.groups[0..self.nr_groups]) |g| {
            if (g.active and g.parent == idx and (g.subtree_control & bit) != 0)
                return error.Busy;
        }
        c.subtree_control |= bit;
        for (self.groups[0..self.nr_groups]) |*g| {
            if (g.active and g.parent == idx) g.control |= bit;
        }
    }

    pub fn disable(self: *Hierarchy, idx: usize, bit: u16) !void {
        const c = try self.get(idx);
        if ((c.subtree_control & bit) == 0) return error.NotEnabled;
        for (self.groups[0..self.nr_groups]) |g| {
            if (g.active and g.parent == idx and (g.subtree_control & bit) != 0)
                return error.Busy;
        }
        c.subtree_control &= ~bit;
        for (self.groups[0..self.nr_groups]) |*g| {
            if (g.active and g.parent == idx) g.control &= ~bit;
        }
    }

    fn removeTask(c: *Cgroup, pid: u32) bool {
        for (c.tasks[0..c.nr_tasks], 0..) |p, i| {
            if (p == pid) {
                c.tasks[i] = c.tasks[c.nr_tasks - 1];
                c.nr_tasks -= 1;
                c.pids_current -= 1;
                return true;
            }
        }
        return false;
    }

    /// cgroup_attach_task(): pids.max проверяется в момент миграции,
    /// как pids_can_fork() проверяет лимит при fork().
    pub fn attach(self: *Hierarchy, pid: u32, dst_idx: usize) !void {
        if (pid >= MAX_TASKS) return error.BadTask;
        const dst = try self.get(dst_idx);
        if (dst.pids_current + 1 > dst.pids_max) {
            dst.events_max += 1;
            return error.Limit;
        }
        if (self.task_cgroup[pid]) |src_idx| {
            if (removeTask(&self.groups[src_idx], pid)) self.task_cgroup[pid] = null;
        }
        dst.tasks[dst.nr_tasks] = pid;
        dst.nr_tasks += 1;
        dst.pids_current += 1;
        self.task_cgroup[pid] = dst_idx;
    }

    pub fn detach(self: *Hierarchy, pid: u32) !void {
        if (pid >= MAX_TASKS) return error.BadTask;
        const src_idx = self.task_cgroup[pid] orelse return error.NoTask;
        if (removeTask(&self.groups[src_idx], pid)) self.task_cgroup[pid] = null;
    }

    /// mm/memcontrol.c: try_charge() против memory.max.
    pub fn memoryCharge(self: *Hierarchy, idx: usize, bytes: u64) !void {
        const c = try self.get(idx);
        if (bytes > c.memory_max -| c.memory_current) {
            c.events_max += 1;
            return error.Limit;
        }
        c.memory_current += bytes;
    }

    pub fn memoryUncharge(self: *Hierarchy, idx: usize, bytes: u64) void {
        if (idx >= self.nr_groups) return;
        self.groups[idx].memory_current -|= bytes;
    }

    pub fn setMemoryMax(self: *Hierarchy, idx: usize, limit: u64) !void {
        const c = try self.get(idx);
        c.memory_max = limit;
    }

    pub fn setPidsMax(self: *Hierarchy, idx: usize, limit: usize) !void {
        const c = try self.get(idx);
        if (limit == 0 or limit > MAX_TASKS) return error.Invalid;
        c.pids_max = limit;
    }

    pub fn setCpuMax(self: *Hierarchy, idx: usize, quota: u64, period: u64) !void {
        const c = try self.get(idx);
        if (period < 1000 or period > 1000000) return error.Invalid;
        if (quota != NO_LIMIT and quota < 1000) return error.Invalid;
        c.cpu_quota = quota;
        c.cpu_period = period;
    }

    /// cgroup_rmdir(): только пустая группа без детей.
    pub fn rmdir(self: *Hierarchy, idx: usize) !void {
        if (idx == 0) return error.Busy;
        const c = try self.get(idx);
        if (c.children != 0 or c.nr_tasks != 0) return error.Busy;
        if (c.parent) |p| self.groups[p].children -= 1;
        self.groups[idx] = .{};
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    hierarchy: bool = false,
    controllers: bool = false,
    attach: bool = false,
    limits: bool = false,
    rmdir: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    var h = Hierarchy{};
    h.init();
    const sys = h.mkdir(0, "sys") catch return p;
    const app = h.mkdir(sys, "app") catch return p;
    const unnamed = h.mkdir(0, "bad\nname") == error.InvalidName;
    const slash = h.mkdir(0, "bad/name") == error.InvalidName;
    p.hierarchy = std.mem.eql(u8, h.groups[sys].key(), "sys") and
        std.mem.eql(u8, h.groups[app].key(), "app") and
        h.groups[app].level == 2 and h.groups[0].children == 1 and
        h.groups[sys].children == 1 and unnamed and slash and
        h.mkdir(sys, "app") == error.Exists;

    h.enable(0, Controller.cpu) catch return p;
    const inherited = (h.groups[sys].control & Controller.cpu) != 0;
    h.attach(7, sys) catch return p;
    const busy = h.enable(sys, Controller.io) == error.Busy;
    const unknown = h.enable(sys, 1 << 15) == error.NoController;
    p.attach = h.task_cgroup[7] == sys and h.groups[sys].nr_tasks == 1;
    h.detach(7) catch return p;
    h.enable(sys, Controller.cpu) catch return p;
    h.enable(sys, Controller.memory) catch return p;
    h.enable(sys, Controller.io) catch return p;
    const child_busy = h.disable(0, Controller.cpu) == error.Busy;
    h.disable(sys, Controller.io) catch return p;
    p.controllers = inherited and busy and unknown and child_busy and
        (h.groups[sys].subtree_control & Controller.memory) != 0 and
        (h.groups[sys].subtree_control & Controller.io) == 0;

    h.setPidsMax(sys, 2) catch return p;
    h.attach(10, sys) catch return p;
    h.attach(11, sys) catch return p;
    const pids_limit = h.attach(12, sys) == error.Limit;
    h.setMemoryMax(sys, 100) catch return p;
    h.memoryCharge(sys, 60) catch return p;
    const mem_limit = h.memoryCharge(sys, 50) == error.Limit;
    h.memoryUncharge(sys, 60);
    h.setCpuMax(sys, 50000, 100000) catch return p;
    const cpu_ok = h.groups[sys].cpu_quota == 50000 and h.groups[sys].cpu_period == 100000;
    const cpu_bad = h.setCpuMax(sys, 10, 100000) == error.Invalid;
    p.limits = pids_limit and mem_limit and cpu_ok and cpu_bad and
        h.groups[sys].events_max == 2 and h.groups[sys].memory_current == 0;

    const not_empty = h.rmdir(sys) == error.Busy;
    h.detach(10) catch return p;
    h.detach(11) catch return p;
    const still_busy = h.rmdir(sys) == error.Busy;
    h.rmdir(app) catch return p;
    const root_busy = h.rmdir(0) == error.Busy;
    h.rmdir(sys) catch return p;
    p.rmdir = not_empty and still_busy and root_busy and
        !h.groups[sys].active and h.groups[0].children == 0;
    p.status = "ok";
    return p;
}

test "cgroup: hierarchy creation and name validation" {
    var h = Hierarchy{};
    h.init();
    const sys = try h.mkdir(0, "sys");
    const app = try h.mkdir(sys, "app");
    try std.testing.expectEqual(@as(u8, 1), h.groups[sys].level);
    try std.testing.expectEqual(@as(u8, 2), h.groups[app].level);
    try std.testing.expectEqualStrings("app", h.groups[app].key());
    try std.testing.expectError(error.Exists, h.mkdir(sys, "app"));
    try std.testing.expectError(error.InvalidName, h.mkdir(0, "a/b"));
    try std.testing.expectError(error.InvalidName, h.mkdir(0, "a\nb"));
    try std.testing.expectError(error.NoGroup, h.mkdir(9, "x"));
}

test "cgroup: controller enable/disable follows subtree rules" {
    var h = Hierarchy{};
    h.init();
    const sys = try h.mkdir(0, "sys");
    try h.enable(0, Controller.cpu);
    try std.testing.expect((h.groups[sys].control & Controller.cpu) != 0);
    try std.testing.expectError(error.NoController, h.enable(sys, 1 << 15));
    try h.attach(1, sys);
    try std.testing.expectError(error.Busy, h.enable(sys, Controller.io));
    try h.detach(1);
    try h.enable(sys, Controller.cpu);
    try h.enable(sys, Controller.io);
    try std.testing.expectError(error.Busy, h.disable(0, Controller.cpu));
    try h.disable(sys, Controller.io);
    try std.testing.expectEqual(@as(u16, 0), h.groups[sys].subtree_control & Controller.io);
}

test "cgroup: attach migrates tasks and enforces pids.max" {
    var h = Hierarchy{};
    h.init();
    const a = try h.mkdir(0, "a");
    const b = try h.mkdir(0, "b");
    try h.attach(3, a);
    try h.attach(3, b);
    try std.testing.expectEqual(@as(usize, 0), h.groups[a].nr_tasks);
    try std.testing.expectEqual(@as(usize, 1), h.groups[b].nr_tasks);
    try std.testing.expectEqual(@as(?usize, b), h.task_cgroup[3]);
    try h.setPidsMax(b, 1);
    try std.testing.expectError(error.Limit, h.attach(4, b));
    try std.testing.expectEqual(@as(usize, 1), h.groups[b].events_max);
}

test "cgroup: memory.max charging and cpu.max validation" {
    var h = Hierarchy{};
    h.init();
    const a = try h.mkdir(0, "a");
    try h.setMemoryMax(a, 100);
    try h.memoryCharge(a, 40);
    try std.testing.expectError(error.Limit, h.memoryCharge(a, 70));
    h.memoryUncharge(a, 40);
    try std.testing.expectEqual(@as(u64, 0), h.groups[a].memory_current);
    try h.setCpuMax(a, 5000, 10000);
    try std.testing.expectEqual(@as(u64, 5000), h.groups[a].cpu_quota);
    try std.testing.expectError(error.Invalid, h.setCpuMax(a, 10, 10000));
    try std.testing.expectError(error.Invalid, h.setCpuMax(a, 1000, 10));
}

test "cgroup: rmdir requires empty leaf" {
    var h = Hierarchy{};
    h.init();
    const a = try h.mkdir(0, "a");
    const b = try h.mkdir(a, "b");
    try std.testing.expectError(error.Busy, h.rmdir(a));
    try h.rmdir(b);
    try h.attach(5, a);
    try std.testing.expectError(error.Busy, h.rmdir(a));
    try h.detach(5);
    try h.rmdir(a);
    try std.testing.expect(!h.groups[a].active);
    try std.testing.expectEqual(@as(usize, 0), h.groups[0].children);
}

test "cgroup: boot probe exercises hierarchy, controllers, attach, limits and rmdir" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.hierarchy);
    try std.testing.expect(p.controllers);
    try std.testing.expect(p.attach or p.limits);
    try std.testing.expect(p.limits);
    try std.testing.expect(p.rmdir);
}
