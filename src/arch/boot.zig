// Данные, которые загрузчик передаёт ядру.

pub const Kind = enum { usable, firmware, loader, acpi_reclaim, acpi_nvs, runtime, mmio, reserved };

pub const Region = struct {
    start: usize,
    pages: usize, // страницы по 4 КиБ
    kind: Kind,
};

pub const BootInfo = struct {
    fb_base: usize,
    fb_width: u32,
    fb_height: u32,
    fb_stride: u32, // в пикселях
    fb_bgr: bool, // true: байты B,G,R,X; false: R,G,B,X
    rsdp: usize, // физический адрес ACPI RSDP или 0
    regions: []const Region,
};

pub var info: BootInfo = undefined;
