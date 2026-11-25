//! xHCI boot-keyboard: PCI discovery, инициализация контроллера, event ring и
//! interrupt-IN transfer HID boot-protocol. Только опрос: без MSI/IRQ, хабов,
//! hotplug и нескольких клавиатур. Алгоритм следует Linux 7.3 xhci-pci/hid
//! и справочнику zigos (его исходный файл не изменялся).
//! GPL-2.0-only (производная работа по алгоритмам и API Linux).

const arch = @import("../x86_64.zig");
const paging = @import("../paging.zig");
const printk = @import("../printk.zig");
const pmm = @import("../pmm.zig");
const timer = @import("../timer.zig");
const pci = @import("pci.zig");
const keyboard_drv = @import("keyboard.zig");
const vt_mod = @import("../../vt.zig");
const hid_mod = @import("../../hid.zig");
const device_mod = @import("../../device.zig");

pub const Info = struct {
    bus: u8,
    slot: u8,
    func: u8,
    vendor: u16,
    product: u16,
    bar: u64,
    caplength: u8,
    max_slots: u32,
    max_ports: u32,
    ctx_size: usize,
    kbd_slot: u32,
    kbd_dci: u32,
};

pub var info: ?Info = null;
pub var ready: bool = false;
pub var kbd_ready: bool = false;
pub var err: []const u8 = "";
pub var trace: bool = false;

pub var device = device_mod.Device.init("xhci", .{ .bus = .pci, .class = 0x0C, .subclass = 0x03 });
pub var driver = device_mod.Driver.init("xhci-pci", match, probe, null);

const TRBS: usize = 256;
const PAGE: usize = 4096;
const NS_PER_MS: u64 = 1_000_000;
const NEUTRAL: u32 = (1 << 9) | (3 << 14) | (7 << 25);

const Ring = struct {
    base: usize = 0,
    idx: usize = 0,
    cycle: u32 = 1,
};

var found: pci.Device = undefined;
var op: usize = 0;
var rt: usize = 0;
var db: usize = 0;
var cs: usize = 32;
var max_ports: u32 = 0;
var max_slots: u32 = 0;
var bar_base: u64 = 0;
var caplength: u8 = 0;
var dcbaa: usize = 0;
var ictx: usize = 0;
var dbuf: usize = 0;
var rbuf: usize = 0;
var cmd_ring: Ring = .{};
var ev_base: usize = 0;
var ev_idx: usize = 0;
var ev_cycle: u32 = 1;
var ep0_rings: [16]Ring = undefined;
var out_ctx: [16]usize = undefined;
var kbd_ring: Ring = .{};
var kbd_slot: u32 = 0;
var kbd_dci: u32 = 0;

var cmd_done: bool = false;
var cmd_code: u32 = 0;
var cmd_slot: u32 = 0;
var ctl_done: bool = false;
var ctl_code: u32 = 0;
var decoder = hid_mod.Decoder.init();

fn match(dev: *const device_mod.Device, _: *const device_mod.Driver) bool {
    return dev.modalias.bus == .pci and
        dev.modalias.class == 0x0C and dev.modalias.subclass == 0x03;
}

fn probe(dev: *device_mod.Device) !void {
    const raw = dev.driver_data orelse return error.NoPciDevice;
    const p: *const pci.Device = @ptrCast(@alignCast(raw));
    if (!init(p.*)) {
        printk.print("[usb] init failed: {s}\n", .{err});
        return error.XhciInitFailed;
    }
}

fn rd32(a: usize) u32 {
    const p: *volatile u32 = @ptrFromInt(a);
    return p.*;
}

fn wr32(a: usize, v: u32) void {
    const p: *volatile u32 = @ptrFromInt(a);
    p.* = v;
}

fn wr64(a: usize, v: u64) void {
    wr32(a, @truncate(v));
    wr32(a + 4, @truncate(v >> 32));
}

fn rb(a: usize) u8 {
    const p: *volatile u8 = @ptrFromInt(a);
    return p.*;
}

fn zero(a: usize) void {
    const p: [*]u8 = @ptrFromInt(a);
    @memset(p[0..PAGE], 0);
}

fn page() ?usize {
    const a = pmm.allocFrame() orelse return null;
    zero(a);
    return a;
}

fn fail(msg: []const u8) bool {
    err = msg;
    return false;
}

fn delayMs(ms: u32) void {
    const end = timer.now() + @as(u64, ms) * NS_PER_MS;
    var guard: u32 = 0;
    while (timer.now() < end and guard < 50_000_000) : (guard += 1) arch.pause();
}

fn waitBit(addr: usize, mask: u32, want: u32) bool {
    var n: u32 = 0;
    while ((rd32(addr) & mask) != want) : (n += 1) {
        if (n > 20_000_000) return false;
        arch.pause();
    }
    return true;
}

fn refreshInfo() void {
    info = .{
        .bus = found.bus,
        .slot = found.slot,
        .func = found.func,
        .vendor = found.vendor,
        .product = found.device,
        .bar = bar_base,
        .caplength = caplength,
        .max_slots = max_slots,
        .max_ports = max_ports,
        .ctx_size = cs,
        .kbd_slot = kbd_slot,
        .kbd_dci = kbd_dci,
    };
}

// ---------- кольца ----------

fn ringInit(r: *Ring) bool {
    r.base = page() orelse return false;
    r.idx = 0;
    r.cycle = 1;
    return true;
}

fn ringPush(r: *Ring, param: u64, status: u32, ctrl: u32) void {
    const a = r.base + r.idx * 16;
    wr64(a, param);
    wr32(a + 8, status);
    wr32(a + 12, ctrl | r.cycle); // cycle-бит пишем последним
    r.idx += 1;
    if (r.idx == TRBS - 1) {
        const l = r.base + r.idx * 16;
        wr64(l, @intCast(r.base));
        wr32(l + 8, 0);
        wr32(l + 12, (6 << 10) | (1 << 1) | r.cycle);
        r.idx = 0;
        r.cycle ^= 1;
    }
}

fn ring(slot: u32, target: u32) void {
    wr32(db + @as(usize, slot) * 4, target);
}

// ---------- события ----------

fn rearm() void {
    zero(rbuf);
    ringPush(&kbd_ring, @intCast(rbuf), 8, (1 << 10) | (1 << 5) | (1 << 2));
    ring(kbd_slot, kbd_dci);
}

fn kbdEvent(code: u32) void {
    if (code != 1 and code != 13) {
        kbd_ready = false;
        return;
    }
    var rep: [8]u8 = undefined;
    for (0..8) |i| rep[i] = rb(rbuf + i);
    decoder.handle(&keyboard_drv.kbd, &rep, timer.now());
    if (decoder.reports == 1) {
        printk.print("[usb] hid report mods={x:0>2} key0={x:0>2}\n", .{ rep[0], rep[2] });
    }
    rearm();
}

fn handleEvent(typ: u32, d2: u32, d3: u32) void {
    if (trace and typ != 33) {
        printk.print("[xhci ev type={d} slot={d} ep={d} code={d}]\n", .{
            typ, d3 >> 24, (d3 >> 16) & 0x1F, d2 >> 24,
        });
    }
    switch (typ) {
        33 => {
            cmd_code = d2 >> 24;
            cmd_slot = d3 >> 24;
            cmd_done = true;
        },
        32 => {
            const slot = d3 >> 24;
            const ep = (d3 >> 16) & 0x1F;
            const code = d2 >> 24;
            if (ep == 1) {
                ctl_code = code;
                ctl_done = true;
            } else if (kbd_ready and slot == kbd_slot and ep == kbd_dci) {
                kbdEvent(code);
            }
        },
        else => {},
    }
}

fn processEvents() void {
    var any = false;
    while (true) {
        const a = ev_base + ev_idx * 16;
        const d3 = rd32(a + 12);
        if ((d3 & 1) != ev_cycle) break;
        handleEvent((d3 >> 10) & 0x3F, rd32(a + 8), d3);
        ev_idx += 1;
        if (ev_idx == TRBS) {
            ev_idx = 0;
            ev_cycle ^= 1;
        }
        any = true;
    }
    if (any) {
        wr32(op + 4, 1 << 3); // USBSTS.EINT (RW1C)
        wr32(rt + 0x20, rd32(rt + 0x20) | 1); // IMAN.IP (RW1C)
        wr64(rt + 0x38, @as(u64, @intCast(ev_base + ev_idx * 16)) | 8);
    }
}

/// Из главного цикла и из file_operations.read(): забирает HID-отчёты.
pub fn poll(sw: *vt_mod.Switcher) void {
    if (!ready) return;
    processEvents();
    decoder.tick(&keyboard_drv.kbd, timer.now());
    keyboard_drv.drain(sw);
}

pub fn usbsts() u32 {
    return if (ready) rd32(op + 4) else 0xFFFF_FFFF;
}

fn command(param: u64, ctrl: u32) bool {
    cmd_done = false;
    ringPush(&cmd_ring, param, 0, ctrl);
    ring(0, 0);
    var n: u32 = 0;
    while (n < 20_000_000) : (n += 1) {
        processEvents();
        const p: *const volatile bool = &cmd_done;
        if (p.*) return cmd_code == 1 or fail("command failed");
        arch.pause();
    }
    return fail("command timeout");
}

fn ctrlXfer(slot: u32, req_type: u8, req: u8, value: u16, index: u16, len: u16, buf: usize) bool {
    const dir_in = (req_type & 0x80) != 0;
    const r = &ep0_rings[@intCast(slot)];
    const setup: u64 = @as(u64, req_type) |
        (@as(u64, req) << 8) |
        (@as(u64, value) << 16) |
        (@as(u64, index) << 32) |
        (@as(u64, len) << 48);
    const trt: u32 = if (len == 0) 0 else if (dir_in) 3 else 2;
    ctl_done = false;
    ringPush(r, setup, 8, (2 << 10) | (1 << 6) | (trt << 16));
    if (len > 0) {
        const dirbit: u32 = if (dir_in) 1 << 16 else 0;
        ringPush(r, @intCast(buf), len, (3 << 10) | dirbit);
    }
    const sdir: u32 = if (len == 0 or !dir_in) 1 << 16 else 0;
    ringPush(r, 0, 0, (4 << 10) | (1 << 5) | sdir);
    ring(slot, 1);
    var n: u32 = 0;
    while (n < 20_000_000) : (n += 1) {
        processEvents();
        const p: *const volatile bool = &ctl_done;
        if (p.*) return ctl_code == 1 or ctl_code == 13 or fail("control transfer failed");
        arch.pause();
    }
    return fail("control transfer timeout");
}

// ---------- перечисление устройства ----------

fn enumerate(port: u32, speed: u32) void {
    if (!command(0, 9 << 10)) return; // Enable Slot
    const slot = cmd_slot;
    if (slot == 0 or slot >= 16) return;
    const s: usize = @intCast(slot);
    const out = page() orelse return;
    out_ctx[s] = out;
    wr64(dcbaa + s * 8, @intCast(out));
    if (!ringInit(&ep0_rings[s])) return;

    zero(ictx);
    wr32(ictx + 4, 3); // add: slot + EP0
    wr32(ictx + cs, (speed << 20) | (1 << 27));
    wr32(ictx + cs + 4, port << 16);
    const e0 = ictx + 2 * cs;
    const mps0: u32 = switch (speed) {
        1, 2 => 8,
        3 => 64,
        else => 512,
    };
    wr32(e0 + 4, (3 << 1) | (4 << 3) | (mps0 << 16));
    wr64(e0 + 8, @as(u64, @intCast(ep0_rings[s].base)) | 1);
    wr32(e0 + 16, 8);
    if (!command(@intCast(ictx), (11 << 10) | (slot << 24))) return;

    if (speed == 1) {
        zero(dbuf);
        if (!ctrlXfer(slot, 0x80, 6, 0x0100, 0, 8, dbuf)) return;
        const mps: u32 = rb(dbuf + 7);
        if (mps != 8 and (mps == 16 or mps == 32 or mps == 64)) {
            zero(ictx);
            wr32(ictx + 4, 2);
            wr32(ictx + 2 * cs + 4, (3 << 1) | (4 << 3) | (mps << 16));
            if (!command(@intCast(ictx), (13 << 10) | (slot << 24))) return;
        }
    }

    zero(dbuf);
    if (!ctrlXfer(slot, 0x80, 6, 0x0100, 0, 18, dbuf)) return;
    const dclass = rb(dbuf + 4);
    const vid: u32 = @as(u32, rb(dbuf + 8)) | (@as(u32, rb(dbuf + 9)) << 8);
    const pid: u32 = @as(u32, rb(dbuf + 10)) | (@as(u32, rb(dbuf + 11)) << 8);
    printk.print("[usb] port {d}: {x:0>4}:{x:0>4} class {d} speed {d}\n", .{
        port, vid, pid, dclass, speed,
    });
    if (dclass == 9) {
        printk.write("[usb]   hub - not supported\n");
        return;
    }

    zero(dbuf);
    if (!ctrlXfer(slot, 0x80, 6, 0x0200, 0, 9, dbuf)) return;
    var total: usize = @as(usize, rb(dbuf + 2)) | (@as(usize, rb(dbuf + 3)) << 8);
    if (total > 512) total = 512;
    if (total < 9) return;
    zero(dbuf);
    if (!ctrlXfer(slot, 0x80, 6, 0x0200, 0, @intCast(total), dbuf)) return;

    const cfg_val = rb(dbuf + 5);
    var in_kbd = false;
    var have_ep = false;
    var iface: u8 = 0;
    var ep_addr: u8 = 0;
    var ep_mps: u32 = 8;
    var ep_int: u8 = 10;
    var off: usize = 0;
    while (off + 2 <= total) {
        const l: usize = rb(dbuf + off);
        const t = rb(dbuf + off + 1);
        if (l < 2) break;
        if (t == 4) {
            const cls = rb(dbuf + off + 5);
            const sub = rb(dbuf + off + 6);
            const proto = rb(dbuf + off + 7);
            printk.print("[usb]   iface {d}: class {d}/{d}/{d}\n", .{
                rb(dbuf + off + 2), cls, sub, proto,
            });
            in_kbd = cls == 3 and sub == 1 and proto == 1;
            if (in_kbd) iface = rb(dbuf + off + 2);
        } else if (t == 5 and in_kbd and !have_ep) {
            const a = rb(dbuf + off + 2);
            const attr = rb(dbuf + off + 3);
            if ((a & 0x80) != 0 and (attr & 3) == 3) {
                ep_addr = a;
                ep_mps = (@as(u32, rb(dbuf + off + 4)) | (@as(u32, rb(dbuf + off + 5)) << 8)) & 0x7FF;
                ep_int = rb(dbuf + off + 6);
                have_ep = true;
            }
        }
        off += l;
    }
    if (!have_ep) {
        printk.write("[usb]   not a boot keyboard\n");
        return;
    }

    const dci: u32 = @as(u32, ep_addr & 0xF) * 2 + 1;
    var interval: u32 = 0;
    if (speed >= 3) {
        interval = if (ep_int > 0) @as(u32, ep_int) - 1 else 0;
        if (interval > 15) interval = 15;
    } else {
        const v: u32 = if (ep_int == 0) 1 else ep_int;
        interval = (32 - @as(u32, @intCast(@clz(v)))) + 2;
        if (interval > 10) interval = 10;
    }
    zero(ictx);
    wr32(ictx + 4, 1 | (@as(u32, 1) << @intCast(dci)));
    for (0..8) |i| wr32(ictx + cs + i * 4, rd32(out + i * 4));
    wr32(ictx + cs, (rd32(out) & 0x07FFFFFF) | (dci << 27));
    const ep = ictx + (@as(usize, dci) + 1) * cs;
    if (!ringInit(&kbd_ring)) return;
    wr32(ep, interval << 16);
    wr32(ep + 4, (3 << 1) | (7 << 3) | (ep_mps << 16));
    wr64(ep + 8, @as(u64, @intCast(kbd_ring.base)) | 1);
    wr32(ep + 16, 8 | (8 << 16));
    if (!command(@intCast(ictx), (12 << 10) | (slot << 24))) return;

    if (!ctrlXfer(slot, 0x00, 9, cfg_val, 0, 0, 0)) return;
    _ = ctrlXfer(slot, 0x21, 0x0B, 0, iface, 0, 0); // SET_PROTOCOL(boot)

    kbd_slot = slot;
    kbd_dci = dci;
    kbd_ready = true;
    refreshInfo();
    rearm();
    printk.write("[usb]   boot keyboard ready\n");
}

fn scanPorts() void {
    var p: u32 = 1;
    while (p <= max_ports and !kbd_ready) : (p += 1) {
        const ps = op + 0x400 + @as(usize, p - 1) * 0x10;
        var v = rd32(ps);
        if ((v & (1 << 9)) == 0) {
            wr32(ps, (v & NEUTRAL) | (1 << 9));
            delayMs(20);
            v = rd32(ps);
        }
        if ((v & 1) == 0) continue;
        printk.print("[usb] port {d}: device connected (speed {d})\n", .{
            p, (v >> 10) & 0xF,
        });
        if ((v & 2) == 0) {
            wr32(ps, (v & NEUTRAL) | (1 << 4));
            var n: u32 = 0;
            while ((rd32(ps) & (1 << 21)) == 0 and n < 20_000_000) : (n += 1) arch.pause();
            v = rd32(ps);
            wr32(ps, (v & NEUTRAL) | (1 << 21) | (1 << 17));
            delayMs(10);
            v = rd32(ps);
            if ((v & 2) == 0) continue;
        }
        err = "";
        enumerate(p, (v >> 10) & 0xF);
        if (!kbd_ready and err.len != 0) {
            printk.print("[usb]   failed: {s}\n", .{err});
        }
    }
}

pub fn init(d: pci.Device) bool {
    if (ready) return true;
    found = d;
    err = "";
    kbd_ready = false;
    kbd_slot = 0;
    kbd_dci = 0;
    decoder = hid_mod.Decoder.init();

    pci.enable(found, 0x0002 | 0x0004 | 0x0400);
    const bar = pci.bar0(found);
    if (bar.kind == .io or bar.base == 0) return fail("xHCI BAR0 is empty");
    const base: usize = @intCast(bar.base);
    bar_base = bar.base;
    paging.mapMmio(base, 0x10000);

    const caplen: usize = rd32(base) & 0xFF;
    caplength = @intCast(caplen);
    const hcs1 = rd32(base + 4);
    const hcs2 = rd32(base + 8);
    const hcc = rd32(base + 0x10);
    op = base + caplen;
    db = base + @as(usize, @intCast(rd32(base + 0x14) & ~@as(u32, 3)));
    rt = base + @as(usize, @intCast(rd32(base + 0x18) & ~@as(u32, 0x1F)));
    max_slots = hcs1 & 0xFF;
    max_ports = hcs1 >> 24;
    cs = if ((hcc & 4) != 0) 64 else 32;
    if ((hcc & 1) == 0) return fail("xHCI without 64-bit addressing is not supported");

    // USB Legacy Support: забрать контроллер у BIOS.
    var xecp: usize = @as(usize, @intCast((hcc >> 16) & 0xFFFF)) << 2;
    var guard: u32 = 0;
    while (xecp != 0 and guard < 32) : (guard += 1) {
        const cap = rd32(base + xecp);
        if ((cap & 0xFF) == 1 and (cap & (1 << 16)) != 0) {
            wr32(base + xecp, cap | (1 << 24));
            _ = waitBit(base + xecp, 1 << 16, 0);
        }
        const next = (cap >> 8) & 0xFF;
        if (next == 0) break;
        xecp += @as(usize, next) << 2;
    }

    wr32(op, rd32(op) & ~@as(u32, 1));
    if (!waitBit(op + 4, 1, 1)) return fail("xHCI does not halt");
    wr32(op, rd32(op) | 2);
    if (!waitBit(op, 2, 0) or !waitBit(op + 4, 1 << 11, 0)) return fail("xHCI reset timeout");

    const slots: u32 = if (max_slots > 15) 15 else max_slots;
    wr32(op + 0x38, slots);

    dcbaa = page() orelse return fail("out of memory");
    const nscratch: usize = @as(usize, @intCast(((hcs2 >> 21) & 0x1F) << 5)) |
        @as(usize, @intCast((hcs2 >> 27) & 0x1F));
    if (nscratch > 0) {
        if (nscratch > 512) return fail("too many scratchpad buffers");
        const arr = page() orelse return fail("out of memory");
        for (0..nscratch) |i| {
            const scratch = page() orelse return fail("out of memory");
            wr64(arr + i * 8, @intCast(scratch));
        }
        wr64(dcbaa, @intCast(arr));
    }
    wr64(op + 0x30, @intCast(dcbaa));

    if (!ringInit(&cmd_ring)) return fail("out of memory");
    wr64(op + 0x18, @as(u64, @intCast(cmd_ring.base)) | 1);

    ev_base = page() orelse return fail("out of memory");
    const erst = page() orelse return fail("out of memory");
    wr64(erst, @intCast(ev_base));
    wr32(erst + 8, @intCast(TRBS));
    wr32(rt + 0x28, 1);
    wr64(rt + 0x38, @intCast(ev_base));
    wr64(rt + 0x30, @intCast(erst));
    ev_idx = 0;
    ev_cycle = 1;

    ictx = page() orelse return fail("out of memory");
    dbuf = page() orelse return fail("out of memory");
    rbuf = page() orelse return fail("out of memory");

    wr32(op, rd32(op) | 1);
    if (!waitBit(op + 4, 1, 0)) return fail("xHCI does not start");
    ready = true;
    refreshInfo();
    scanPorts();
    return true;
}
