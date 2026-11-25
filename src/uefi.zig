//! UEFI-точка входа ziglinux: GOP + карта памяти → ExitBootServices → kmain().
//! Целевая версия Zig: 0.17.x; собственные UEFI-привязки (efi.zig) вместо std.os.uefi.
const std = @import("std");
const efi = @import("arch/efi.zig");
const boot = @import("arch/boot.zig");
const x86 = @import("arch/x86_64.zig");
const kernel = @import("arch/kmain.zig");
const printk = @import("arch/printk.zig");

var mmap_buf: [64 * 1024]u8 align(8) = undefined;
var regions: [512]boot.Region = undefined;
var kstack: [128 * 1024]u8 align(16) = undefined;

pub const panic = std.debug.FullPanic(panicHandler);
fn panicHandler(msg: []const u8, _: ?usize) noreturn {
    @import("arch/x86_64.zig").cli();
    const pf = @import("arch/printk.zig");
    pf.print("\nPANIC: {s}\n", .{msg});
    while (true) @import("arch/x86_64.zig").hlt();
}

fn W(comptime s: []const u8) *const [s.len:0]u16 {
    const r = comptime blk: {
        var out: [s.len:0]u16 = @splat(0);
        for (s, 0..) |c, i| out[i] = c;
        break :blk out;
    };
    return &r;
}

fn say(st: *efi.SystemTable, s: [*:0]const u16) void {
    if (st.con_out) |c| _ = c.output_string(c, s);
}

fn findRsdp(st: *efi.SystemTable) usize {
    var v1: usize = 0;
    var i: usize = 0;
    while (i < st.number_of_table_entries) : (i += 1) {
        const e = &st.configuration_table[i];
        if (efi.guidEql(&e.guid, &efi.acpi20_guid)) return e.table;
        if (efi.guidEql(&e.guid, &efi.acpi10_guid)) v1 = e.table;
    }
    return v1;
}

pub export fn EfiMain(handle: usize, st: *efi.SystemTable) callconv(.c) usize {
    const bs = st.boot_services;
    _ = bs.set_watchdog_timer(0, 0, 0, null);
    if (st.con_out) |c| _ = c.clear_screen(c);
    say(st, W("ziglinux 7.3: booting...\r\n"));

    var gop_ptr: ?*anyopaque = null;
    if (bs.locate_protocol(&efi.gop_guid, null, &gop_ptr) != efi.success or gop_ptr == null) {
        say(st, W("No GOP framebuffer\r\n"));
        return efi.unsupported;
    }
    const gop: *efi.GraphicsOutput = @ptrCast(@alignCast(gop_ptr.?));
    const gi = gop.mode.info;
    if (gi.pixel_format > 1) {
        say(st, W("Unsupported GOP pixel format\r\n"));
        return efi.unsupported;
    }
    boot.info = .{
        .fb_base = @intCast(gop.mode.frame_buffer_base),
        .fb_width = gi.horizontal_resolution,
        .fb_height = gi.vertical_resolution,
        .fb_stride = gi.pixels_per_scan_line,
        .fb_bgr = gi.pixel_format == 1,
        .rsdp = findRsdp(st),
        .regions = &.{},
    };

    // После получения карты памяти нельзя ничего выводить до ExitBootServices.
    var tries: usize = 0;
    while (tries < 4) : (tries += 1) {
        var size: usize = mmap_buf.len;
        var key: usize = 0;
        var dsize: usize = 0;
        var dver: u32 = 0;
        const mm: [*]efi.MemoryDescriptor = @ptrCast(&mmap_buf);
        if (bs.get_memory_map(&size, mm, &key, &dsize, &dver) != efi.success) return efi.aborted;

        x86.cli();
        if (bs.exit_boot_services(handle, key) != efi.success) continue;

        const n = convertMap(@intFromPtr(&mmap_buf), size, dsize);
        boot.info.regions = regions[0..n];
        enterKernel();
    }
    return efi.aborted;
}

fn convertMap(base: usize, size: usize, dsize: usize) usize {
    var n: usize = 0;
    var off: usize = 0;
    while (off + dsize <= size) : (off += dsize) {
        const d: *const efi.MemoryDescriptor = @ptrFromInt(base + off);
        const kind: boot.Kind = switch (d.type) {
            7 => .usable,
            3, 4 => .firmware,
            1, 2 => .loader,
            9 => .acpi_reclaim,
            10 => .acpi_nvs,
            5, 6 => .runtime,
            11, 12 => .mmio,
            else => .reserved,
        };
        const start: usize = @intCast(d.physical_start);
        const pages: usize = @intCast(d.number_of_pages);
        if (n > 0) {
            const p = &regions[n - 1];
            if (p.kind == kind and p.start + p.pages * 4096 == start) {
                p.pages += pages;
                continue;
            }
        }
        if (n == regions.len) break;
        regions[n] = .{ .start = start, .pages = pages, .kind = kind };
        n += 1;
    }
    return n;
}

fn enterKernel() noreturn {
    const top = (@intFromPtr(&kstack) + kstack.len) & ~@as(usize, 15);
    asm volatile (
        \\cli
        \\movq %[top], %%rsp
        \\xorl %%ebp, %%ebp
        \\call *%[entry]
        :
        : [top] "r" (top),
          [entry] "r" (@intFromPtr(&kernel.kmain)),
        : .{ .memory = true });
    unreachable;
}
