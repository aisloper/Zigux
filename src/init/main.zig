//! Порт порядка инициализации из init/main.c (Linux 7.3) на Zig.
//! start_kernel() → setup_arch() → mm_core_init() → kmem_cache_init()
//! → vfs_caches_init() → sched_init() → timers_init() → rest_init().
//! Архитектурный слой (UEFI, GDT/IDT, CR3) подключается отдельным этапом;
//! здесь подсистемы инициализируются в том же порядке, что и в Linux.

const std = @import("std");
const page_alloc = @import("../mm/page_alloc.zig");
const slab = @import("../mm/slab.zig");
const sched = @import("../sched.zig");
const vfs = @import("../vfs.zig");
const task = @import("../task.zig");
const timer = @import("../timer.zig");
const tty = @import("../tty.zig");

pub const BootStage = enum {
    setup_arch,
    setup_per_cpu_areas,
    boot_cpu_init,
    mm_core_init,
    kmem_cache_init,
    vfs_caches_init,
    sched_init,
    init_timers,
    tty_init,
    rest_init,
};

/// Номера/имена виртуальных терминалов (как NVT в zigos, /dev/ttyN в Linux).
pub const nr_ttys: usize = 4;
const tty_names = [_][]const u8{ "tty1", "tty2", "tty3", "tty4" };

/// Точка сопряжения ядра с драйверами: TTY посылает сигнал foreground pgrp.
/// Драйверы (keyboard/serial/console) остаются из zigos и вызывают tty.receive().
fn ttySignalPgrp(ctx: ?*anyopaque, pgrp: u32, sig: u8) void {
    if (ctx) |ptr| {
        const tm: *task.TaskManager = @ptrCast(@alignCast(ptr));
        tm.signalPgrp(pgrp, sig);
    }
}

pub const BootLog = struct {
    stages: std.ArrayList(BootStage) = .empty,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) BootLog {
        return .{ .allocator = allocator };
    }

    pub fn add(self: *BootLog, stage: BootStage) !void {
        try self.stages.append(self.allocator, stage);
    }

    pub fn deinit(self: *BootLog) void {
        self.stages.deinit(self.allocator);
    }
};

pub const Kernel = struct {
    allocator: std.mem.Allocator,
    log: BootLog,
    zone: page_alloc.Zone,
    kmem_cache: slab.KmemCache,
    vfs: vfs.SuperBlock,
    cfs: sched.CfsRq,
    tasks: task.TaskManager,
    timers: timer.TimerBase,
    ttys: [nr_ttys]tty.Tty,
    nr_pages: usize,

    /// in-place: Zone/KmemCache/SuperBlock/TaskManager/TimerBase содержат
    /// интрузивные структуры со ссылками на себя; копировать по значению нельзя.
    pub fn boot(self: *Kernel, allocator: std.mem.Allocator, nr_pages: usize) !void {
        self.* = undefined;
        self.allocator = allocator;
        self.nr_pages = nr_pages;
        self.log = BootLog.init(allocator);
        const log = &self.log;
        errdefer log.deinit();

        // setup_arch(): дескрипторы CPU/память из firmware (здесь — параметры хоста).
        try log.add(.setup_arch);
        try log.add(.setup_per_cpu_areas);
        try log.add(.boot_cpu_init);

        // mm_core_init(): buddy allocator и зоны.
        try log.add(.mm_core_init);
        try self.zone.init(allocator, nr_pages, 0);
        errdefer self.zone.deinit();

        // kmem_cache_init(): SLUB-подобный кэш для ядерных объектов.
        try log.add(.kmem_cache_init);
        try self.kmem_cache.init(allocator, &self.zone, "task_struct", @sizeOf(sched.SchedEntity), null);
        errdefer self.kmem_cache.deinit();

        // vfs_caches_init(): dcache/icache.
        try log.add(.vfs_caches_init);
        try self.vfs.init(allocator, 256);
        errdefer self.vfs.deinit();

        // sched_init(): корневая runqueue CFS/EEVDF + init-задача.
        try log.add(.sched_init);
        self.cfs = sched.CfsRq.init();
        self.tasks.init(allocator);
        errdefer self.tasks.deinit();
        const init_task = try self.tasks.createInit();
        init_task.setComm("swapper/0");

        // init_timers(): timer wheel + jiffies.
        try log.add(.init_timers);
        self.timers.init(allocator);
        errdefer self.timers.deinit();

        // tty_init(): line discipline N_TTY + signal hook в job control.
        try log.add(.tty_init);
        for (&self.ttys, tty_names, 0..) |*t, name, i| {
            t.* = tty.Tty.init(name, @intCast(i));
            t.ops = .{ .ctx = &self.tasks, .signalPgrp = ttySignalPgrp };
        }

        try log.add(.rest_init);
    }

    pub fn deinit(self: *Kernel) void {
        self.timers.deinit();
        self.tasks.deinit();
        self.kmem_cache.deinit();
        self.vfs.deinit();
        self.zone.deinit();
        self.log.deinit();
    }
};

test "start_kernel boot order" {
    var k: Kernel = undefined;
    try k.boot(std.testing.allocator, 1024);
    defer k.deinit();
    try std.testing.expectEqual(@as(usize, 10), k.log.stages.items.len);
    try std.testing.expectEqual(BootStage.setup_arch, k.log.stages.items[0]);
    try std.testing.expectEqual(BootStage.tty_init, k.log.stages.items[8]);
    try std.testing.expectEqual(BootStage.rest_init, k.log.stages.items[9]);
    try std.testing.expectEqual(@as(usize, 4), k.ttys.len);
    try std.testing.expectEqualStrings("tty1", k.ttys[0].name);
    try std.testing.expectEqual(@as(usize, 1024), k.nr_pages);
    try std.testing.expect(k.tasks.root != null);
    try std.testing.expectEqual(@as(u32, 1), k.tasks.root.?.pid);
}
