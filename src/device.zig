//! Минимальная модель device/driver из drivers/base/{dd,bus}.c Linux 7.3.
//! Сохранены инварианты: bus хранит устройства и драйверы, `match` выбирает
//! пару, `probe` вызывается после связывания, при ошибке probe связь снимается,
//! `remove` вызывается до очистки `device.driver`. Упущены sysfs, kobject,
//! devres, power management, deferred probe и блокировки SMP.
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const std = @import("std");

pub const BusKind = enum { platform, serio, usb, pci };

/// Упрощённый modalias: достаточно, чтобы драйвер мог выбрать устройство.
pub const Modalias = struct {
    bus: BusKind,
    vendor: u16 = 0,
    product: u16 = 0,
    class: u8 = 0,
    subclass: u8 = 0,
};

pub const Device = struct {
    name: []const u8,
    modalias: Modalias,
    driver: ?*Driver = null,
    driver_data: ?*anyopaque = null,
    bound: bool = false,

    pub fn init(name: []const u8, modalias: Modalias) Device {
        return .{ .name = name, .modalias = modalias };
    }
};

pub const Driver = struct {
    name: []const u8,
    match: *const fn (dev: *const Device, drv: *const Driver) bool,
    probe: *const fn (dev: *Device) anyerror!void,
    remove: ?*const fn (dev: *Device) void = null,

    pub fn init(
        name: []const u8,
        match: *const fn (dev: *const Device, drv: *const Driver) bool,
        probe_fn: *const fn (dev: *Device) anyerror!void,
        remove_fn: ?*const fn (dev: *Device) void,
    ) Driver {
        return .{ .name = name, .match = match, .probe = probe_fn, .remove = remove_fn };
    }
};

pub const Error = error{ NoSpace, Duplicate, NoDriver };

pub const Bus = struct {
    name: []const u8,
    devices: []*Device,
    drivers: []*Driver,
    nr_devices: usize = 0,
    nr_drivers: usize = 0,

    pub fn init(name: []const u8, devices: []*Device, drivers: []*Driver) Bus {
        return .{ .name = name, .devices = devices, .drivers = drivers };
    }

    /// device_add(): сначала registers device, затем пытается связать его с уже
    /// зарегистрированными драйверами (bus_add_device → driver_attach).
    pub fn addDevice(self: *Bus, dev: *Device) Error!void {
        for (self.devices[0..self.nr_devices]) |other| {
            if (other == dev) return error.Duplicate;
        }
        if (self.nr_devices == self.devices.len) return error.NoSpace;
        self.devices[self.nr_devices] = dev;
        self.nr_devices += 1;
        _ = self.attachDevice(dev);
    }

    /// driver_register(): registers driver, затем driver_attach() по всем
    /// устройствам шины. Ошибки probe не прерывают обход (как в Linux).
    pub fn addDriver(self: *Bus, drv: *Driver) Error!void {
        for (self.drivers[0..self.nr_drivers]) |other| {
            if (other == drv) return error.Duplicate;
        }
        if (self.nr_drivers == self.drivers.len) return error.NoSpace;
        self.drivers[self.nr_drivers] = drv;
        self.nr_drivers += 1;
        _ = self.attachDriver(drv);
    }

    /// driver_probe_device(): match → device_set_driver → probe → bound.
    /// При ошибке probe устройство остаётся свободным для другого драйвера.
    fn probeOne(dev: *Device, drv: *Driver) !void {
        dev.driver = drv;
        drv.probe(dev) catch |e| {
            dev.driver = null;
            return e;
        };
        dev.bound = true;
    }

    /// Попытка привязать одно устройство ко всем подходящим драйверам.
    pub fn attachDevice(self: *Bus, dev: *Device) ?*Driver {
        if (dev.bound) return dev.driver;
        for (self.drivers[0..self.nr_drivers]) |drv| {
            if (!drv.match(dev, drv)) continue;
            if (dev.driver != null and dev.driver != drv) continue;
            probeOne(dev, drv) catch continue;
            return drv;
        }
        return null;
    }

    /// driver_attach(): обход всех устройств шины ради одного драйвера.
    pub fn attachDriver(self: *Bus, drv: *Driver) usize {
        var bound: usize = 0;
        for (self.devices[0..self.nr_devices]) |dev| {
            if (dev.bound) continue;
            if (!drv.match(dev, drv)) continue;
            probeOne(dev, drv) catch continue;
            bound += 1;
        }
        return bound;
    }

    /// bus_rescan_devices(): повторный probe для ещё не связанных устройств.
    pub fn rescan(self: *Bus) usize {
        var bound: usize = 0;
        for (self.devices[0..self.nr_devices]) |dev| {
            if (self.attachDevice(dev) != null) bound += 1;
        }
        return bound;
    }
};

/// device_release_driver(): remove() вызывается до снятия связи.
pub fn release(dev: *Device) Error!void {
    const drv = dev.driver orelse return error.NoDriver;
    if (drv.remove) |remove_fn| remove_fn(dev);
    dev.bound = false;
    dev.driver = null;
}

const probe_log = struct {
    var count: usize = 0;
    var remove_count: usize = 0;
    var fail: bool = false;

    fn reset() void {
        count = 0;
        remove_count = 0;
        fail = false;
    }
};

fn serioMatch(dev: *const Device, drv: *const Driver) bool {
    _ = drv;
    return dev.modalias.bus == .serio;
}

fn probe(dev: *Device) anyerror!void {
    probe_log.count += 1;
    if (probe_log.fail) return error.ProbeFailed;
    dev.driver_data = &probe_log.count;
}

fn remove(dev: *Device) void {
    _ = dev;
    probe_log.remove_count += 1;
}

test "device model: driver_register binds an earlier device" {
    probe_log.reset();
    var devices = [_]Device{Device.init("serio0", .{ .bus = .serio })};
    var drivers = [_]Driver{Driver.init("atkbd", serioMatch, probe, remove)};
    var device_ptrs = [_]*Device{&devices[0]};
    var driver_ptrs = [_]*Driver{&drivers[0]};
    var bus = Bus.init("serio", device_ptrs[0..], driver_ptrs[0..]);

    try bus.addDevice(&devices[0]);
    try std.testing.expectEqual(@as(?*Driver, null), devices[0].driver);
    try bus.addDriver(&drivers[0]);
    try std.testing.expectEqual(&drivers[0], devices[0].driver.?);
    try std.testing.expectEqual(@as(usize, 1), probe_log.count);
    try std.testing.expect(devices[0].bound);

    try release(&devices[0]);
    try std.testing.expectEqual(@as(usize, 1), probe_log.remove_count);
    try std.testing.expectEqual(@as(?*Driver, null), devices[0].driver);
}

test "device model: failed probe leaves device free, rescan binds later" {
    probe_log.reset();
    probe_log.fail = true;
    var devices = [_]Device{Device.init("serio1", .{ .bus = .serio })};
    var drivers = [_]Driver{Driver.init("atkbd", serioMatch, probe, remove)};
    var device_ptrs = [_]*Device{&devices[0]};
    var driver_ptrs = [_]*Driver{&drivers[0]};
    var bus = Bus.init("serio", device_ptrs[0..], driver_ptrs[0..]);

    try bus.addDriver(&drivers[0]);
    try bus.addDevice(&devices[0]);
    try std.testing.expectEqual(@as(?*Driver, null), devices[0].driver);
    try std.testing.expect(!devices[0].bound);

    probe_log.fail = false;
    try std.testing.expectEqual(@as(usize, 1), bus.rescan());
    try std.testing.expectEqual(&drivers[0], devices[0].driver.?);
    try std.testing.expectEqual(@as(usize, 2), probe_log.count);
}

test "device model: duplicate registration and release without driver" {
    probe_log.reset();
    var devices = [_]Device{
        Device.init("serio0", .{ .bus = .serio }),
        Device.init("pci0", .{ .bus = .pci, .vendor = 0x8086 }),
    };
    var drivers = [_]Driver{Driver.init("atkbd", serioMatch, probe, remove)};
    var device_ptrs = [_]*Device{ &devices[0], &devices[1] };
    var driver_ptrs = [_]*Driver{&drivers[0]};
    var bus = Bus.init("test", device_ptrs[0..], driver_ptrs[0..]);

    try bus.addDevice(&devices[0]);
    try bus.addDevice(&devices[1]);
    try std.testing.expectError(error.Duplicate, bus.addDevice(&devices[0]));
    try bus.addDriver(&drivers[0]);
    try std.testing.expectError(error.Duplicate, bus.addDriver(&drivers[0]));
    try std.testing.expectError(error.NoDriver, release(&devices[1]));
    try std.testing.expectEqual(@as(usize, 1), probe_log.count);
}
