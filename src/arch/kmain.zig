//! kmain() — архитектурный вход ziglinux. Вызывает уже портированный
//! start_kernel() (init/main.zig) поверх физической кучи, затем поднимает
//! preemption/tick, TTY и EEVDF-планировщик с настоящим ctx_switch.
const kl = @import("../kernel.zig");
const x86 = @import("x86_64.zig");
const boot = @import("boot.zig");
const printk = @import("printk.zig");
const serial = @import("drivers/serial.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pic = @import("pic.zig");
const pmm = @import("pmm.zig");
const paging = @import("paging.zig");
const heap = @import("heap.zig");
const arch_timer = @import("timer.zig");
const arch_sched = @import("sched.zig");
const apic = @import("apic.zig");
const smp = @import("smp.zig");
const user = @import("user.zig");
const disk = @import("drivers/disk.zig");
const netdrv = @import("drivers/net.zig");
const device = @import("../device.zig");
const ext4 = @import("../ext4.zig");
const vt_mod = @import("../vt.zig");
const pci = @import("drivers/pci.zig");
const console_drv = @import("drivers/console.zig");
const keyboard_drv = @import("drivers/keyboard.zig");
const xhci_drv = @import("drivers/xhci.zig");
const build_options = @import("build_options");

var kernel_instance: kl.init.Kernel = undefined;
var ap_rqs: [apic.MAX_CPUS]kl.sched.CfsRq = undefined;
var vts: vt_mod.Switcher = undefined;

fn vtSwitch(_: ?*anyopaque, from: usize, to: usize) void {
    console_drv.switchScreen(from, to);
}

fn bound(dev: *const device.Device) []const u8 {
    return if (dev.bound) "bound" else "unbound";
}

fn registerDrivers(xhci_pci: ?*pci.Device) void {
    if (xhci_pci) |p| xhci_drv.device.driver_data = @ptrCast(p);

    var platform_bus = device.Bus.init(
        "platform",
        platform_devices[0..],
        platform_drivers[0..],
    );
    var serio_bus = device.Bus.init("serio", serio_devices[0..], serio_drivers[0..]);
    var pci_bus = device.Bus.init("pci", pci_devices[0..], pci_drivers[0..]);

    platform_bus.addDriver(&console_drv.driver) catch printk.panic("console driver register");
    serio_bus.addDriver(&keyboard_drv.driver) catch printk.panic("atkbd driver register");
    pci_bus.addDriver(&xhci_drv.driver) catch printk.panic("xhci driver register");
    platform_bus.addDevice(&console_drv.device) catch printk.panic("console device register");
    serio_bus.addDevice(&keyboard_drv.device) catch printk.panic("atkbd device register");
    if (xhci_pci != null) {
        pci_bus.addDevice(&xhci_drv.device) catch printk.panic("xhci device register");
    }
}

var platform_devices = [_]*device.Device{&console_drv.device};
var platform_drivers = [_]*device.Driver{&console_drv.driver};
var serio_devices = [_]*device.Device{&keyboard_drv.device};
var serio_drivers = [_]*device.Driver{&keyboard_drv.driver};
var pci_devices = [_]*device.Device{&xhci_drv.device};
var pci_drivers = [_]*device.Driver{&xhci_drv.driver};

fn tickHook() void {
    arch_sched.onTick(arch_timer.now());
}

fn workerEntry() void {
    while (true) arch_sched.yield(arch_timer.now());
}

/// Idle-поток AP: после запуска ring3-демо на этом CPU планировщик сам
/// переключится с idle на пользовательскую задачу через EEVDF.
fn apIdleEntry() void {
    while (true) {
        arch_sched.yield(arch_timer.now());
        x86.sti();
        x86.hlt();
    }
}

fn setupSmp() void {
    smp.detect();
    var cpu_index: usize = 1;
    while (cpu_index < apic.nr_cpus) : (cpu_index += 1) {
        ap_rqs[cpu_index] = kl.sched.CfsRq.init();
        arch_sched.state(cpu_index).rq = &ap_rqs[cpu_index];
        const idle = arch_sched.spawnOn(
            &kernel_instance.tasks,
            kernel_instance.tasks.root.?,
            "idle/N",
            apIdleEntry,
            0,
            arch_timer.now(),
            cpu_index,
        ) catch {
            printk.panic("AP idle spawn failed");
        };
        arch_sched.state(cpu_index).idle = idle;
        arch_sched.setCurrent(cpu_index, idle);
        smp.prepareCpu(cpu_index, idle.arch.stack + idle.arch.pages * pmm.PAGE);
        _ = user.spawnDemoOn(&kernel_instance.tasks, kernel_instance.tasks.root.?, cpu_index) catch {
            printk.panic("AP ring3 demo spawn failed");
        };
    }
    smp.startAll();
}

fn printBootLog() void {
    printk.print("ziglinux {d}.{d} (port {s}): start_kernel\n", .{
        kl.version_major, kl.version_minor, kl.port_version,
    });
    for (kernel_instance.log.stages.items) |stage| {
        printk.print("  -> {s}\n", .{@tagName(stage)});
    }
}

pub fn kmain() noreturn {
    serial.init();
    const info = boot.info;
    printk.print("ziglinux: framebuffer {d}x{d} at {x:0>16}\n", .{
        info.fb_width, info.fb_height, info.fb_base,
    });

    gdt.init();
    idt.init();
    pic.init();
    printk.write("ziglinux: GDT, IDT, PIC ready\n");

    if (!pmm.init(info.regions)) printk.panic("no usable memory");
    const stats = pmm.stats();
    printk.print("ziglinux: PMM {d} MiB free\n", .{stats.free * 4 / 1024});

    paging.init();
    arch_timer.init();
    printk.print("ziglinux: paging ready, timer={s} {d} Hz ({s})\n", .{
        @tagName(arch_timer.source), arch_timer.HZ, @import("apic.zig").calib,
    });

    var host_pci: [32]pci.Device = undefined;
    const nr_pci = pci.scan(&host_pci);
    var xhci_pci: ?*pci.Device = null;
    for (host_pci[0..nr_pci]) |*dev| {
        if (dev.class == 0x0C and dev.subclass == 0x03 and dev.prog_if == 0x30) {
            xhci_pci = dev;
            break;
        }
    }
    registerDrivers(xhci_pci);
    printk.print("ziglinux: device core: console={s} atkbd={s} xhci={s}\n", .{
        bound(&console_drv.device), bound(&keyboard_drv.device), bound(&xhci_drv.device),
    });
    printk.print("ziglinux: atkbd i8042 present={s} ack={s}\n", .{
        if (keyboard_drv.info.present) "yes" else "no",
        if (keyboard_drv.info.ack) "yes" else "no",
    });
    if (xhci_drv.info) |xhci| {
        printk.print("ziglinux: xhci {x:0>4}:{x:0>2}.{d} at {x:0>8} slots={d} ports={d} ctx={d} kbd={s}\n", .{
            xhci.bus,       xhci.slot,      xhci.func,     xhci.bar,
            xhci.max_slots, xhci.max_ports, xhci.ctx_size, if (xhci_drv.kbd_ready) "yes" else "no",
        });
    }

    // Buddy-зона порта работает поверх физической кучи ядра.
    const sim_pages = @min(@as(usize, 4096), @max(@as(usize, 256), stats.free / 16));
    kernel_instance.boot(heap.allocator(), sim_pages) catch |e| {
        printk.print("start_kernel failed: {s}\n", .{@errorName(e)});
        printk.panic("start_kernel failed");
    };
    printBootLog();

    const init_task = kernel_instance.tasks.root.?;
    arch_sched.init(init_task, &kernel_instance.cfs);
    user.init(&kernel_instance.tasks, heap.allocator(), &kernel_instance.vfs);
    const scanned = disk.scanAndMount(heap.allocator(), user.boot_ns.?);
    printk.print("ziglinux: block scan: PCI {d}, virtio-blk {d}, virtio-scsi {d}, NVMe {d}, AHCI {d}, ext4 mounts {d}\n", .{
        scanned.scanned, scanned.virtio, scanned.scsi, scanned.nvme, scanned.ahci, scanned.mounted,
    });
    if (build_options.net_probe) {
        const probe = kl.net.probe(heap.allocator()) catch {
            printk.panic("net probe failed");
        };
        printk.print("ziglinux: net: {s} skb={s} clone={s} csum={s} bind={s} loopback={s} recv={s} inuse={s} refused={s} bytes={d} queue={d} packets={d} drops={d} errno={d}\n", .{
            probe.status,
            if (probe.skb_ok) "ok" else "failed",
            if (probe.clone_ok) "ok" else "failed",
            if (probe.csum_ok) "ok" else "failed",
            if (probe.bind_ok) "ok" else "failed",
            if (probe.loopback_ok) "ok" else "failed",
            if (probe.recv_ok) "ok" else "failed",
            if (probe.inuse_ok) "ok" else "failed",
            if (probe.refused_ok) "ok" else "failed",
            probe.bytes,
            probe.queue,
            probe.packets,
            probe.drops,
            probe.errno,
        });
        if (!probe.skb_ok or !probe.clone_ok or !probe.csum_ok or !probe.bind_ok or
            !probe.loopback_ok or !probe.recv_ok or !probe.inuse_ok or !probe.refused_ok)
            printk.panic("net probe failed");
    }
    if (build_options.tcp_probe) {
        const probe = kl.tcp.probe(heap.allocator()) catch {
            printk.panic("tcp probe failed");
        };
        printk.print("ziglinux: tcp: {s} checksum={s} handshake={s} stream={s} retransmit={s} close={s} bytes={d} segments={d} acks={d} state={s} errno={d}\n", .{
            probe.status,
            if (probe.checksum) "ok" else "failed",
            if (probe.handshake) "ok" else "failed",
            if (probe.stream) "ok" else "failed",
            if (probe.retransmit) "ok" else "failed",
            if (probe.close) "ok" else "failed",
            probe.bytes,
            probe.segments,
            probe.acks,
            probe.state,
            probe.errno,
        });
        if (!probe.checksum or !probe.handshake or !probe.stream or !probe.retransmit or !probe.close)
            printk.panic("tcp probe failed");
    }
    if (build_options.tcp_ca_probe) {
        const probe = kl.tcp_ca.probe();
        printk.print("ziglinux: tcp-ca: {s} reno={s} slow-start={s} avoidance={s} ssthresh={s} fast-retransmit={s} recovery={s} timeout={s} cwnd={d} threshold={d} dupacks={d} state={s} acks={d} errno={d}\n", .{
            probe.status,
            if (probe.reno) "ok" else "failed",
            if (probe.slow_start) "ok" else "failed",
            if (probe.avoidance) "ok" else "failed",
            if (probe.ssthresh) "ok" else "failed",
            if (probe.fast_retransmit) "ok" else "failed",
            if (probe.recovery) "ok" else "failed",
            if (probe.timeout) "ok" else "failed",
            probe.cwnd,
            probe.threshold,
            probe.dupacks,
            probe.state,
            probe.acks,
            probe.errno,
        });
        if (!probe.reno or !probe.slow_start or !probe.avoidance or !probe.ssthresh or
            !probe.fast_retransmit or !probe.recovery or !probe.timeout)
            printk.panic("tcp-ca probe failed");
    }
    if (build_options.tcp_options_probe) {
        const probe = kl.tcp.optionsProbe(heap.allocator()) catch {
            printk.panic("tcp-options probe failed");
        };
        printk.print("ziglinux: tcp-opt: {s} window-scale={s} sack={s} ofo={s} backoff={s} shift={d} blocks={d} sacked={d} rto={d}/{d}/{d} errno={d}\n", .{
            probe.status,
            if (probe.window_scale) "ok" else "failed",
            if (probe.sack) "ok" else "failed",
            if (probe.ofo) "ok" else "failed",
            if (probe.backoff) "ok" else "failed",
            probe.shift,
            probe.sack_blocks,
            probe.sacked,
            probe.rto[0],
            probe.rto[1],
            probe.rto[2],
            probe.errno,
        });
        if (!probe.window_scale or !probe.sack or !probe.ofo or !probe.backoff)
            printk.panic("tcp-options probe failed");
    }
    if (build_options.icmp6_probe) {
        const probe = kl.icmp6.probe(heap.allocator()) catch {
            printk.panic("icmp6 probe failed");
        };
        printk.print("ziglinux: icmp6: {s} echo={s} checksum={s} ndp={s} multicast={s} state={s} errno={d}\n", .{
            probe.status,
            if (probe.echo) "ok" else "failed",
            if (probe.checksum) "ok" else "failed",
            if (probe.ndp) "ok" else "failed",
            if (probe.multicast) "ok" else "failed",
            kl.icmp6.neighborStateName(probe.state),
            probe.errno,
        });
        if (!probe.echo or !probe.checksum or !probe.ndp or !probe.multicast)
            printk.panic("icmp6 probe failed");
    }
    if (build_options.queue_probe) {
        const qdisc_probe = kl.qdisc.probe(heap.allocator()) catch {
            printk.panic("qdisc probe failed");
        };
        const napi_probe = kl.napi.probe(heap.allocator()) catch {
            printk.panic("napi probe failed");
        };
        printk.print("ziglinux: queue: ok qdisc={s} priority={s} order={s} limit={s} napi={s} weight={s} schedule={s} budget={s} repoll={s} processed={d} errno={d}\n", .{
            qdisc_probe.status,
            if (qdisc_probe.priority) "ok" else "failed",
            if (qdisc_probe.order) "ok" else "failed",
            if (qdisc_probe.limit) "ok" else "failed",
            napi_probe.status,
            if (napi_probe.weight) "ok" else "failed",
            if (napi_probe.schedule) "ok" else "failed",
            if (napi_probe.budget) "ok" else "failed",
            if (napi_probe.repoll) "ok" else "failed",
            napi_probe.processed,
            napi_probe.errno,
        });
        if (!qdisc_probe.priority or !qdisc_probe.order or !qdisc_probe.limit or
            !napi_probe.weight or !napi_probe.schedule or !napi_probe.budget or !napi_probe.repoll)
            printk.panic("queue probe failed");
    }
    if (build_options.fq_codel_probe) {
        const probe = kl.fq_codel.probe(heap.allocator()) catch {
            printk.panic("fq_codel probe failed");
        };
        printk.print("ziglinux: fqcodel: {s} hash={s} rr={s} deficit={s} codel={s} ecn={s} overlimit={s} drops={d} marks={d} errno={d}\n", .{
            probe.status,
            if (probe.hash) "ok" else "failed",
            if (probe.round_robin) "ok" else "failed",
            if (probe.deficit) "ok" else "failed",
            if (probe.codel) "ok" else "failed",
            if (probe.ecn) "ok" else "failed",
            if (probe.overlimit) "ok" else "failed",
            probe.drops,
            probe.marks,
            probe.errno,
        });
        if (!probe.hash or !probe.round_robin or !probe.deficit or !probe.codel or
            !probe.ecn or !probe.overlimit)
            printk.panic("fq_codel probe failed");
    }
    if (build_options.htb_probe) {
        const probe = kl.htb.probe(heap.allocator()) catch {
            printk.panic("htb probe failed");
        };
        printk.print("ziglinux: htb: {s} rate={s} ceil={s} borrow={s} prio={s} deficit={s} limit={s} errno={d}\n", .{
            probe.status,
            if (probe.rate) "ok" else "failed",
            if (probe.ceil) "ok" else "failed",
            if (probe.borrow) "ok" else "failed",
            if (probe.prio) "ok" else "failed",
            if (probe.deficit) "ok" else "failed",
            if (probe.limit) "ok" else "failed",
            probe.errno,
        });
        if (!probe.rate or !probe.ceil or !probe.borrow or !probe.prio or
            !probe.deficit or !probe.limit)
            printk.panic("htb probe failed");
    }
    if (build_options.tcp_timers_probe) {
        const probe = kl.tcp_timers.probe() catch {
            printk.panic("tcp timers probe failed");
        };
        printk.print("ziglinux: tcptimers: {s} retrans={s} backoff={s} probe0={s} delack={s} keepalive={s} user-timeout={s} errno={d}\n", .{
            probe.status,
            if (probe.retrans) "ok" else "failed",
            if (probe.backoff) "ok" else "failed",
            if (probe.probe0) "ok" else "failed",
            if (probe.delack) "ok" else "failed",
            if (probe.keepalive) "ok" else "failed",
            if (probe.user_timeout) "ok" else "failed",
            probe.errno,
        });
        if (!probe.retrans or !probe.backoff or !probe.probe0 or !probe.delack or
            !probe.keepalive or !probe.user_timeout)
            printk.panic("tcp timers probe failed");
    }
    if (build_options.mld_probe) {
        const probe = kl.mld.probe(heap.allocator()) catch {
            printk.panic("mld probe failed");
        };
        printk.print("ziglinux: mld: {s} mld1={s} mld2={s} grec={s} mrc={s} qqic={s} ra={s} options={s} rs={s} errno={d}\n", .{
            probe.status,
            if (probe.mld1) "ok" else "failed",
            if (probe.mld2) "ok" else "failed",
            if (probe.grec) "ok" else "failed",
            if (probe.mrc) "ok" else "failed",
            if (probe.qqic) "ok" else "failed",
            if (probe.ra) "ok" else "failed",
            if (probe.options) "ok" else "failed",
            if (probe.rs) "ok" else "failed",
            probe.errno,
        });
        if (!probe.mld1 or !probe.mld2 or !probe.grec or !probe.mrc or !probe.qqic or
            !probe.ra or !probe.options or !probe.rs)
            printk.panic("mld probe failed");
    }
    if (build_options.tcp_v6_probe) {
        const probe = kl.tcp_v6.probe(heap.allocator()) catch {
            printk.panic("tcpv6 probe failed");
        };
        printk.print("ziglinux: tcpv6: {s} checksum={s} handshake={s} lookup={s} data={s} errno={d}\n", .{
            probe.status,
            if (probe.checksum) "ok" else "failed",
            if (probe.handshake) "ok" else "failed",
            if (probe.lookup) "ok" else "failed",
            if (probe.data) "ok" else "failed",
            probe.errno,
        });
        if (!probe.checksum or !probe.handshake or !probe.lookup or !probe.data)
            printk.panic("tcpv6 probe failed");
    }
    if (build_options.rx_mode_probe) {
        const probe = kl.rx_mode.probe(heap.allocator()) catch {
            printk.panic("rx mode probe failed");
        };
        printk.print("ziglinux: rxmode: {s} promisc={s} allmulti={s} mc={s} virtio={s} filter={s} errno={d}\n", .{
            probe.status,
            if (probe.promisc) "ok" else "failed",
            if (probe.allmulti) "ok" else "failed",
            if (probe.mc) "ok" else "failed",
            if (probe.virtio) "ok" else "failed",
            if (probe.filter) "ok" else "failed",
            probe.errno,
        });
        if (!probe.promisc or !probe.allmulti or !probe.mc or !probe.virtio or !probe.filter)
            printk.panic("rx mode probe failed");
    }
    if (build_options.usb_hotplug_probe) {
        const probe = kl.usb_hotplug.probe(heap.allocator()) catch {
            printk.panic("usb hotplug probe failed");
        };
        printk.print("ziglinux: usbhotplug: {s} decode={s} attach={s} detach={s} reset={s} reuse={s} errno={d}\n", .{
            probe.status,
            if (probe.decode) "ok" else "failed",
            if (probe.attach) "ok" else "failed",
            if (probe.detach) "ok" else "failed",
            if (probe.reset) "ok" else "failed",
            if (probe.reuse) "ok" else "failed",
            probe.errno,
        });
        if (!probe.decode or !probe.attach or !probe.detach or !probe.reset or !probe.reuse)
            printk.panic("usb hotplug probe failed");
    }
    if (build_options.xhci_cascade_probe) {
        const probe = kl.xhci_hub_cascade.probe();
        printk.print("ziglinux: xhci-cascade: {s} descriptor={s} depth={s} tt={s} cascade={s} bandwidth={s} errno={d}\n", .{
            probe.status,
            if (probe.descriptor) "ok" else "failed",
            if (probe.depth) "ok" else "failed",
            if (probe.tt) "ok" else "failed",
            if (probe.cascade) "ok" else "failed",
            if (probe.bandwidth) "ok" else "failed",
            probe.errno,
        });
        if (!probe.descriptor or !probe.depth or !probe.tt or !probe.cascade or !probe.bandwidth)
            printk.panic("xhci cascade probe failed");
    }
    if (build_options.pcnet32_probe) {
        const probe = kl.pcnet32.probe();
        printk.print("ziglinux: pcnet32: {s} probe={s} ring={s} mac={s} tx={s} rx={s} irq={s} errno={d}\n", .{
            probe.status,
            if (probe.probe) "ok" else "failed",
            if (probe.ring) "ok" else "failed",
            if (probe.mac) "ok" else "failed",
            if (probe.tx) "ok" else "failed",
            if (probe.rx) "ok" else "failed",
            if (probe.irq) "ok" else "failed",
            probe.errno,
        });
        if (!probe.probe or !probe.ring or !probe.mac or !probe.tx or !probe.rx or !probe.irq)
            printk.panic("pcnet32 probe failed");
    }
    if (build_options.ne2k_probe) {
        const probe = kl.ne2k.probe();
        printk.print("ziglinux: ne2k: {s} probe={s} mac={s} init={s} tx={s} rx={s} irq={s} errno={d}\n", .{
            probe.status,
            if (probe.probe) "ok" else "failed",
            if (probe.mac) "ok" else "failed",
            if (probe.init) "ok" else "failed",
            if (probe.tx) "ok" else "failed",
            if (probe.rx) "ok" else "failed",
            if (probe.irq) "ok" else "failed",
            probe.errno,
        });
        if (!probe.probe or !probe.mac or !probe.init or !probe.tx or !probe.rx or !probe.irq)
            printk.panic("ne2k probe failed");
    }
    if (build_options.ncq_probe) {
        const probe = kl.ncq.probe();
        printk.print("ziglinux: ncq: {s} cap={s} fis={s} queue={s} completion={s} errno={d}\n", .{
            probe.status,
            if (probe.cap) "ok" else "failed",
            if (probe.fis) "ok" else "failed",
            if (probe.queue) "ok" else "failed",
            if (probe.completion) "ok" else "failed",
            probe.errno,
        });
        if (!probe.cap or !probe.fis or !probe.queue or !probe.completion)
            printk.panic("ncq probe failed");
    }
    if (build_options.drm_probe) {
        const probe = kl.drm.probe();
        printk.print("ziglinux: drm: {s} basic={s} size={s} refresh={s} framebuffer={s} crtc={s} errno={d}\n", .{
            probe.status,
            if (probe.basic) "ok" else "failed",
            if (probe.size) "ok" else "failed",
            if (probe.refresh) "ok" else "failed",
            if (probe.framebuffer) "ok" else "failed",
            if (probe.crtc) "ok" else "failed",
            probe.errno,
        });
        if (!probe.basic or !probe.size or !probe.refresh or !probe.framebuffer or !probe.crtc)
            printk.panic("drm probe failed");
    }
    if (build_options.igmp_probe) {
        const probe = kl.igmp.probe(heap.allocator()) catch {
            printk.panic("igmp probe failed");
        };
        printk.print("ziglinux: igmp: {s} encoding={s} message={s} membership={s} query={s} leave={s} errno={d}\n", .{
            probe.status,
            if (probe.encoding) "ok" else "failed",
            if (probe.message) "ok" else "failed",
            if (probe.membership) "ok" else "failed",
            if (probe.query) "ok" else "failed",
            if (probe.leave) "ok" else "failed",
            probe.errno,
        });
        if (!probe.encoding or !probe.message or !probe.membership or
            !probe.query or !probe.leave)
            printk.panic("igmp probe failed");
    }
    if (build_options.ip_defrag_probe) {
        const probe = kl.ip_defrag.probe();
        printk.print("ziglinux: ipdefrag: {s} offsets={s} reorder={s} limits={s} timeout={s} errno={d}\n", .{
            probe.status,
            if (probe.offsets) "ok" else "failed",
            if (probe.reorder) "ok" else "failed",
            if (probe.limits) "ok" else "failed",
            if (probe.timeout) "ok" else "failed",
            probe.errno,
        });
        if (!probe.offsets or !probe.reorder or !probe.limits or !probe.timeout)
            printk.panic("ip defrag probe failed");
    }
    if (build_options.unix_sock_probe) {
        const probe = kl.unix_sock.probe();
        printk.print("ziglinux: unixsock: {s} names={s} pair={s} bind={s} datagram={s} close={s} errno={d}\n", .{
            probe.status,
            if (probe.names) "ok" else "failed",
            if (probe.pair) "ok" else "failed",
            if (probe.bind) "ok" else "failed",
            if (probe.datagram) "ok" else "failed",
            if (probe.close) "ok" else "failed",
            probe.errno,
        });
        if (!probe.names or !probe.pair or !probe.bind or !probe.datagram or !probe.close)
            printk.panic("unix socket probe failed");
    }
    if (build_options.ipv6_frag_probe) {
        const probe = kl.ipv6_frag.probe();
        printk.print("ziglinux: ipv6frag: {s} header={s} offsets={s} reorder={s} limits={s} timeout={s} errno={d}\n", .{
            probe.status,
            if (probe.header) "ok" else "failed",
            if (probe.offsets) "ok" else "failed",
            if (probe.reorder) "ok" else "failed",
            if (probe.limits) "ok" else "failed",
            if (probe.timeout) "ok" else "failed",
            probe.errno,
        });
        if (!probe.header or !probe.offsets or !probe.reorder or !probe.limits or !probe.timeout)
            printk.panic("ipv6 fragment probe failed");
    }
    if (build_options.netlink_probe) {
        const probe = kl.netlink.probe();
        printk.print("ziglinux: netlink: {s} header={s} messages={s} attrs={s} dispatch={s} socket={s} errno={d}\n", .{
            probe.status,
            if (probe.header) "ok" else "failed",
            if (probe.messages) "ok" else "failed",
            if (probe.attrs) "ok" else "failed",
            if (probe.dispatch) "ok" else "failed",
            if (probe.socket) "ok" else "failed",
            probe.errno,
        });
        if (!probe.header or !probe.messages or !probe.attrs or !probe.dispatch or !probe.socket)
            printk.panic("netlink probe failed");
    }
    if (build_options.cgroup_probe) {
        const probe = kl.cgroup.probe();
        printk.print("ziglinux: cgroup: {s} hierarchy={s} controllers={s} attach={s} limits={s} rmdir={s} errno={d}\n", .{
            probe.status,
            if (probe.hierarchy) "ok" else "failed",
            if (probe.controllers) "ok" else "failed",
            if (probe.attach) "ok" else "failed",
            if (probe.limits) "ok" else "failed",
            if (probe.rmdir) "ok" else "failed",
            probe.errno,
        });
        if (!probe.hierarchy or !probe.controllers or !probe.attach or !probe.limits or !probe.rmdir)
            printk.panic("cgroup probe failed");
    }
    if (build_options.cubic_probe) {
        const probe = kl.cubic.probe();
        printk.print("ziglinux: cubic: {s} root={s} ssthresh={s} update={s} growth={s} hystart={s} errno={d}\n", .{
            probe.status,
            if (probe.root) "ok" else "failed",
            if (probe.ssthresh) "ok" else "failed",
            if (probe.update) "ok" else "failed",
            if (probe.growth) "ok" else "failed",
            if (probe.hystart) "ok" else "failed",
            probe.errno,
        });
        if (!probe.root or !probe.ssthresh or !probe.update or !probe.growth or !probe.hystart)
            printk.panic("cubic probe failed");
    }
    if (build_options.e1000_probe) {
        const probe = kl.e1000.probe();
        printk.print("ziglinux: e1000: {s} ring={s} tx={s} rx={s} csum={s} napi={s} errno={d}\n", .{
            probe.status,
            if (probe.ring) "ok" else "failed",
            if (probe.tx) "ok" else "failed",
            if (probe.rx) "ok" else "failed",
            if (probe.csum) "ok" else "failed",
            if (probe.napi) "ok" else "failed",
            probe.errno,
        });
        if (!probe.ring or !probe.tx or !probe.rx or !probe.csum or !probe.napi)
            printk.panic("e1000 probe failed");
    }
    if (build_options.inet6_probe) {
        const probe = kl.net.probeInet6(heap.allocator()) catch {
            printk.panic("inet6 probe failed");
        };
        printk.print("ziglinux: inet6: {s} addr={s} csum={s} bind={s} loopback={s} recv={s} inuse={s} refused={s} bytes={d} queue={d} packets={d} drops={d} errno={d}\n", .{
            probe.status,
            if (probe.addr_ok) "ok" else "failed",
            if (probe.csum_ok) "ok" else "failed",
            if (probe.bind_ok) "ok" else "failed",
            if (probe.loopback_ok) "ok" else "failed",
            if (probe.recv_ok) "ok" else "failed",
            if (probe.inuse_ok) "ok" else "failed",
            if (probe.refused_ok) "ok" else "failed",
            probe.bytes,
            probe.queue,
            probe.packets,
            probe.drops,
            probe.errno,
        });
        if (!probe.addr_ok or !probe.csum_ok or !probe.bind_ok or !probe.loopback_ok or
            !probe.recv_ok or !probe.inuse_ok or !probe.refused_ok)
            printk.panic("inet6 probe failed");
    }
    if (build_options.netdev_probe) {
        const probe = netdrv.probe(heap.allocator());
        printk.print("ziglinux: netdev: {s} device={s} route={s} arp={s} icmp={s} mac={x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2} ifindex={d} prefix={d} tx={d} rx={d} errno={d}\n", .{
            probe.status,
            if (probe.device_ok) "ok" else "failed",
            if (probe.route_ok) "ok" else "failed",
            if (probe.arp_ok) "ok" else "failed",
            if (probe.icmp_ok) "ok" else "failed",
            probe.mac[0],
            probe.mac[1],
            probe.mac[2],
            probe.mac[3],
            probe.mac[4],
            probe.mac[5],
            probe.ifindex,
            probe.prefix,
            probe.tx,
            probe.rx,
            probe.errno,
        });
        if (!probe.device_ok or !probe.route_ok or !probe.arp_ok or !probe.icmp_ok)
            printk.panic("netdev probe failed");
    }
    if (build_options.fs_write_probe) {
        const probe = disk.probeExt4Write(user.boot_ns.?, "EXT4 WRITE\n");
        printk.print("ziglinux: ext4 write: {s} readback={s} bytes={d} dirty={d} synced={d} errno={d}\n", .{
            probe.status,
            if (probe.readback_ok) "ok" else "failed",
            probe.written,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.readback_ok) printk.panic("ext4 write probe failed");
    }
    if (build_options.fs_grow_probe) {
        const probe = disk.probeExt4Grow(user.boot_ns.?, "EXT4 GROW\n");
        printk.print("ziglinux: ext4 grow: {s} readback={s} bytes={d} size={d} free={d} dirty={d} synced={d} errno={d}\n", .{
            probe.status,
            if (probe.readback_ok) "ok" else "failed",
            probe.written,
            probe.size,
            probe.free_blocks,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.readback_ok) printk.panic("ext4 grow probe failed");
    }
    if (build_options.fs_namei_probe) {
        const probe = disk.probeExt4Namei(user.boot_ns.?);
        printk.print("ziglinux: ext4 namei: creat={s} unlink={s} readback={s} dirty={d} synced={d} errno={d}\n", .{
            if (probe.created) "ok" else probe.status,
            if (probe.unlinked) "ok" else probe.status,
            if (probe.readback_ok) "ok" else "failed",
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.created or !probe.unlinked or !probe.readback_ok) printk.panic("ext4 namei probe failed");
    }
    if (build_options.fs_mkdir_probe) {
        const probe = disk.probeExt4Mkdir(user.boot_ns.?);
        printk.print("ziglinux: ext4 mkdir: mkdir={s} create={s} readback={s} unlink={s} dirty={d} synced={d} errno={d}\n", .{
            if (probe.created) "ok" else probe.status,
            if (probe.nested) "ok" else probe.status,
            if (probe.readback_ok) "ok" else "failed",
            if (probe.unlinked) "ok" else probe.status,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.created or !probe.nested or !probe.readback_ok or !probe.unlinked) printk.panic("ext4 mkdir probe failed");
    }
    if (build_options.fs_rmdir_probe) {
        const probe = disk.probeExt4Rmdir(user.boot_ns.?);
        printk.print("ziglinux: ext4 rmdir: mkdir={s} nested={s} rmdir={s} dirty={d} synced={d} errno={d}\n", .{
            if (probe.created) "ok" else probe.status,
            if (probe.nested) "ok" else probe.status,
            if (probe.removed) "ok" else probe.status,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.created or !probe.nested or !probe.removed) printk.panic("ext4 rmdir probe failed");
    }
    if (build_options.fs_journal_probe) {
        const probe = disk.probeExt4Journal(user.boot_ns.?);
        printk.print("ziglinux: ext4 journal: active={s} readback={s} commits={d} replays={d} start={d} dirty={d} synced={d} errno={d}\n", .{
            if (probe.active) "ok" else probe.status,
            if (probe.readback_ok) "ok" else "failed",
            probe.commits,
            probe.replays,
            probe.start,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.active or !probe.readback_ok or probe.commits == 0 or probe.start != 0) printk.panic("ext4 journal probe failed");
    }
    if (build_options.jbd2_probe) {
        const probe = disk.probeExt4Jbd2(user.boot_ns.?);
        printk.print("ziglinux: jbd2: active={s} features={s} csum={s} revoke={s} commit={s} readback={s} commits={d} replays={d} start={d} dirty={d} synced={d} errno={d}\n", .{
            if (probe.active) "ok" else probe.status,
            if (probe.features == (ext4.JBD2_FEATURE_INCOMPAT_REVOKE |
                ext4.JBD2_FEATURE_INCOMPAT_64BIT | ext4.JBD2_FEATURE_INCOMPAT_CSUM_V3)) "ok" else probe.status,
            if (probe.csum_type == ext4.JBD2_CRC32C_CHKSUM) "ok" else probe.status,
            if (probe.revoke_set) "ok" else probe.status,
            if (probe.revoke_writes == 1) "ok" else probe.status,
            if (probe.readback_ok) "ok" else "failed",
            probe.commits,
            probe.replays,
            probe.start,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.active or !probe.readback_ok or !probe.revoke_set or
            probe.revoke_writes != 1 or probe.commits == 0 or probe.start != 0) printk.panic("jbd2 probe failed");
    }
    if (build_options.fs_split_probe) {
        const probe = disk.probeExt4Split(user.boot_ns.?, "EXT4 SPLIT\n");
        printk.print("ziglinux: ext4 split: depth={d} readback={s} bytes={d} size={d} free={d} dirty={d} synced={d} errno={d}\n", .{
            probe.depth,
            if (probe.readback_ok) "ok" else "failed",
            probe.written,
            probe.size,
            probe.free_blocks,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (probe.depth != 1 or !probe.readback_ok) printk.panic("ext4 split probe failed");
    }
    if (build_options.fs_sparse_probe) {
        const probe = disk.probeExt4Sparse(user.boot_ns.?, "SPARSE PROBE\n");
        printk.print("ziglinux: ext4 sparse: hole={s} readback={s} bytes={d} size={d} entries={d} depth={d} free={d} dirty={d} synced={d} errno={d}\n", .{
            if (probe.hole_ok) "ok" else probe.status,
            if (probe.readback_ok) "ok" else "failed",
            probe.written,
            probe.size,
            probe.entries,
            probe.depth,
            probe.free_blocks,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (!probe.hole_ok or !probe.readback_ok or probe.entries != 2 or probe.depth != 0) printk.panic("ext4 sparse probe failed");
    }
    if (build_options.fs_depth2_probe) {
        const probe = disk.probeExt4Depth2(user.boot_ns.?, "DEPTH2 PROBE\n");
        printk.print("ziglinux: ext4 depth2: depth={d} entries={d} hole={s} readback={s} bytes={d} size={d} free={d} dirty={d} synced={d} errno={d}\n", .{
            probe.depth,
            probe.entries,
            if (probe.hole_ok) "ok" else probe.status,
            if (probe.readback_ok) "ok" else "failed",
            probe.written,
            probe.size,
            probe.free_blocks,
            probe.dirty,
            probe.synced,
            probe.errno,
        });
        if (probe.depth != 2 or probe.entries != 2 or !probe.hole_ok or !probe.readback_ok) printk.panic("ext4 depth2 probe failed");
    }
    vts = vt_mod.Switcher.init(kernel_instance.ttys[0..], null, vtSwitch);
    for (&kernel_instance.ttys) |*t| {
        t.setPgrp(init_task.pid);
        console_drv.connect(t);
    }
    user.setupStdio(init_task, heap.allocator(), &vts) catch {
        printk.panic("stdio setup failed");
    };
    printk.print("ziglinux: stdio: fd 0/1/2 -> active tty pgrp {d}\n", .{init_task.pid});
    arch_timer.on_tick = tickHook;

    // Каждый VT получает собственный экран; переключение проверяется при загрузке.
    const ready = [_][]const u8{
        "ziglinux: tty1 ready\r\n",
        "ziglinux: tty2 ready\r\n",
        "ziglinux: tty3 ready\r\n",
        "ziglinux: tty4 ready\r\n",
    };
    for (ready, 0..) |msg, i| {
        vts.switchTo(i);
        kernel_instance.ttys[i].write(msg);
    }
    vts.switchTo(0);
    printk.print("ziglinux: vt: {d} VTs, active=tty{d}, switches={d}\n", .{
        ready.len, vts.active + 1, vts.switches,
    });

    _ = arch_sched.spawn(&kernel_instance.tasks, init_task, "kworker", workerEntry, 0, arch_timer.now()) catch {
        printk.panic("kworker spawn failed");
    };
    _ = user.spawnDemo(&kernel_instance.tasks, init_task) catch {
        printk.panic("ring3 demo spawn failed");
    };
    setupSmp();
    printk.print("ziglinux: {d} tasks, per-CPU EEVDF runqueues active\n", .{kernel_instance.tasks.nr_tasks});

    // idle loop: PS/2/UART/xHCI ввод, timer wheel, EEVDF schedule, HLT.
    while (true) {
        user.pumpTty(&vts);
        if (kernel_instance.timers.nr_timers > 0) _ = kernel_instance.timers.runTimers();
        const now = arch_timer.now();
        arch_sched.yield(now);
        x86.sti();
        x86.hlt();
    }
}
