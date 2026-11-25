// Минимальные привязки к UEFI по спецификации (x86_64).
// Намеренно НЕ используем std.os.uefi: его API менялся между 0.14 → 0.15 → 0.16 → 0.17.
// Соглашение вызова `.c` на цели x86_64-uefi = Microsoft x64 ABI.

pub const Guid = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

pub fn guidEql(a: *const Guid, b: *const Guid) bool {
    if (a.data1 != b.data1 or a.data2 != b.data2 or a.data3 != b.data3) return false;
    for (a.data4, b.data4) |x, y| {
        if (x != y) return false;
    }
    return true;
}

pub const gop_guid = Guid{ .data1 = 0x9042a9de, .data2 = 0x23dc, .data3 = 0x4a38, .data4 = .{ 0x96, 0xfb, 0x7a, 0xde, 0xd0, 0x80, 0x51, 0x6a } };
pub const acpi20_guid = Guid{ .data1 = 0x8868e871, .data2 = 0xe4f1, .data3 = 0x11d3, .data4 = .{ 0xbc, 0x22, 0x00, 0x80, 0xc7, 0x3c, 0x88, 0x81 } };
pub const acpi10_guid = Guid{ .data1 = 0xeb9d2d30, .data2 = 0x2d88, .data3 = 0x11d3, .data4 = .{ 0x9a, 0x16, 0x00, 0x90, 0x27, 0x3f, 0xc1, 0x4d } };

pub const success: usize = 0;
pub const unsupported: usize = 0x8000000000000003;
pub const aborted: usize = 0x8000000000000015;

pub const TableHeader = extern struct {
    signature: u64,
    revision: u32,
    header_size: u32,
    crc32: u32,
    reserved: u32,
};

pub const TextOutput = extern struct {
    reset: usize,
    output_string: *const fn (*TextOutput, [*:0]const u16) callconv(.c) usize,
    test_string: usize,
    query_mode: usize,
    set_mode: usize,
    set_attribute: usize,
    clear_screen: *const fn (*TextOutput) callconv(.c) usize,
};

pub const MemoryDescriptor = extern struct {
    type: u32,
    physical_start: u64,
    virtual_start: u64,
    number_of_pages: u64,
    attribute: u64,
};

pub const BootServices = extern struct {
    hdr: TableHeader,
    raise_tpl: usize,
    restore_tpl: usize,
    allocate_pages: usize,
    free_pages: usize,
    get_memory_map: *const fn (*usize, [*]MemoryDescriptor, *usize, *usize, *u32) callconv(.c) usize,
    allocate_pool: usize,
    free_pool: usize,
    create_event: usize,
    set_timer: usize,
    wait_for_event: usize,
    signal_event: usize,
    close_event: usize,
    check_event: usize,
    install_protocol_interface: usize,
    reinstall_protocol_interface: usize,
    uninstall_protocol_interface: usize,
    handle_protocol: usize,
    reserved: usize,
    register_protocol_notify: usize,
    locate_handle: usize,
    locate_device_path: usize,
    install_configuration_table: usize,
    load_image: usize,
    start_image: usize,
    exit: usize,
    unload_image: usize,
    exit_boot_services: *const fn (usize, usize) callconv(.c) usize,
    get_next_monotonic_count: usize,
    stall: usize,
    set_watchdog_timer: *const fn (usize, u64, usize, ?[*:0]const u16) callconv(.c) usize,
    connect_controller: usize,
    disconnect_controller: usize,
    open_protocol: usize,
    close_protocol: usize,
    open_protocol_information: usize,
    protocols_per_handle: usize,
    locate_handle_buffer: usize,
    locate_protocol: *const fn (*const Guid, ?*anyopaque, *?*anyopaque) callconv(.c) usize,
};

pub const ConfigTable = extern struct {
    guid: Guid,
    table: usize,
};

pub const SystemTable = extern struct {
    hdr: TableHeader,
    firmware_vendor: usize,
    firmware_revision: u32,
    console_in_handle: usize,
    con_in: usize,
    console_out_handle: usize,
    con_out: ?*TextOutput,
    standard_error_handle: usize,
    std_err: usize,
    runtime_services: usize,
    boot_services: *BootServices,
    number_of_table_entries: usize,
    configuration_table: [*]ConfigTable,
};

pub const ModeInfo = extern struct {
    version: u32,
    horizontal_resolution: u32,
    vertical_resolution: u32,
    pixel_format: u32, // 0 = RGBX, 1 = BGRX, 2 = bitmask, 3 = blt only
    red_mask: u32,
    green_mask: u32,
    blue_mask: u32,
    reserved_mask: u32,
    pixels_per_scan_line: u32,
};

pub const GopMode = extern struct {
    max_mode: u32,
    mode: u32,
    info: *ModeInfo,
    size_of_info: usize,
    frame_buffer_base: u64,
    frame_buffer_size: usize,
};

pub const GraphicsOutput = extern struct {
    query_mode: usize,
    set_mode: usize,
    blt: usize,
    mode: *GopMode,
};
