//! Порт базовой подсистемы таймеров Linux 7.3 на Zig.
//! Источники: include/linux/jiffies.h, kernel/time/timer.c, kernel/time/jiffies.c.
//! Упрощено: один level timer wheel (вместо 5-level), без hrtimer/nohz/rcu.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");
const list = @import("list.zig");

/// HZ = 250 — значение по умолчанию для x86_64 в Linux 7.3 (CONFIG_HZ_250).
pub const HZ: u64 = 250;
pub const USER_HZ: u64 = 100;
pub const JIFFIES_SHIFT: u6 = 8;
pub const TIMER_WHEEL_SIZE: usize = 256;

/// Начальное значение jiffies (Linux: INITIAL_JIFFIES = -300*HZ).
pub const INITIAL_JIFFIES: u64 = 0 -% (300 * HZ);

/// suseconds_t и helpers из include/linux/jiffies.h.
pub fn msecsToJiffies(msecs: u64) u64 {
    return (msecs * HZ + 999) / 1000;
}

pub fn jiffiesToMsecs(jiffies: u64) u64 {
    return (jiffies * 1000) / HZ;
}

pub fn timeAfter(a: u64, b: u64) bool {
    return @as(i64, @bitCast(a -% b)) > 0;
}

pub fn timeBefore(a: u64, b: u64) bool {
    return @as(i64, @bitCast(a -% b)) < 0;
}

pub fn timeAfterEq(a: u64, b: u64) bool {
    return @as(i64, @bitCast(a -% b)) >= 0;
}

pub fn timeBeforeEq(a: u64, b: u64) bool {
    return @as(i64, @bitCast(a -% b)) <= 0;
}

const TimerEntry = struct {
    node: list.Node = .{},
    expires: u64,
    data: usize,
    callback: *const fn (usize) void,
};

/// timer_base для CPU0: один level с 256 бакетами.
pub const TimerBase = struct {
    allocator: std.mem.Allocator,
    wheel: [TIMER_WHEEL_SIZE]list.Head,
    jiffies: u64 = INITIAL_JIFFIES,
    nr_timers: usize = 0,
    nr_fired: usize = 0,

    pub fn init(self: *TimerBase, allocator: std.mem.Allocator) void {
        self.* = .{
            .allocator = allocator,
            .wheel = undefined,
        };
        for (&self.wheel) |*b| list.init(b);
    }

    pub fn deinit(self: *TimerBase) void {
        // Собираем всё вручную: list.iterator() читает node.next после free(),
        // поэтому сохраняем следующий узел до освобождения текущего.
        for (&self.wheel) |*b| {
            var cur = b.next;
            while (cur) |node| {
                if (node == b) break;
                const next = node.next;
                const e: *TimerEntry = @fieldParentPtr("node", node);
                self.allocator.destroy(e);
                cur = next;
            }
        }
    }

    /// add_timer() / mod_timer(): добавить таймер с абсолютным expires.
    pub fn add(self: *TimerBase, expires: u64, data: usize, callback: *const fn (usize) void) !void {
        const e = try self.allocator.create(TimerEntry);
        e.* = .{ .expires = expires, .data = data, .callback = callback };
        const bucket: usize = @intCast(expires & (TIMER_WHEEL_SIZE - 1));
        list.addTail(&self.wheel[bucket], &e.node);
        self.nr_timers += 1;
    }

    /// addTimerMillis(): добавить таймер через N мс от текущего jiffies.
    pub fn addMillis(self: *TimerBase, millis: u64, data: usize, callback: *const fn (usize) void) !void {
        try self.add(self.jiffies +% msecsToJiffies(millis), data, callback);
    }

    /// __run_timers(): обработать все просроченные таймеры до current jiffies.
    /// Возвращает общее число сработавших.
    pub fn runTimers(self: *TimerBase) usize {
        // Упрощённый порт: сканируем все бакеты. В Linux 7.3 используется
        // каскад из 5 уровней (LVL_START=5) и check/gearing по base->clk;
        // здесь один уровень на 256 слотов достаточно для HZ=250 и задержек <1с.
        for (&self.wheel) |*bucket| {
            var cur = bucket.next;
            while (cur) |node| {
                if (node == bucket) break;
                const next = node.next; // сохраняем до list.del()
                const e: *TimerEntry = @fieldParentPtr("node", node);
                if (!timeAfter(e.expires, self.jiffies)) {
                    list.del(&e.node);
                    self.nr_timers -= 1;
                    self.nr_fired += 1;
                    e.callback(e.data);
                    self.allocator.destroy(e);
                }
                cur = next;
            }
        }
        return self.nr_fired;
    }

    /// jiffies64 — счётчик тиков. Инкремент из timer interrupt.
    pub fn tick(self: *TimerBase) void {
        self.jiffies +%= 1;
    }

    pub fn advance(self: *TimerBase, ticks: u64) void {
        self.jiffies +%= ticks;
        _ = self.runTimers();
    }
};

var global_fired: usize = 0;
fn testCallback(data: usize) void {
    global_fired += data;
}

test "jiffies helpers и timer wheel" {
    try std.testing.expectEqual(@as(u64, 250), msecsToJiffies(1000));
    try std.testing.expectEqual(@as(u64, 1), msecsToJiffies(4));
    try std.testing.expect(timeAfter(10, 5));
    try std.testing.expect(!timeAfter(5, 10));

    var base: TimerBase = undefined;
    base.init(std.testing.allocator);
    defer base.deinit();

    global_fired = 0;
    try base.addMillis(40, 3, testCallback); // 10 jiffies
    try base.addMillis(8, 5, testCallback); // 2 jiffies
    try std.testing.expectEqual(@as(usize, 2), base.nr_timers);

    base.advance(msecsToJiffies(20));
    try std.testing.expectEqual(@as(usize, 1), base.nr_fired);
    try std.testing.expectEqual(@as(usize, 5), global_fired);
    try std.testing.expectEqual(@as(usize, 1), base.nr_timers);
}
