// ziglinux — каркас ядра, портируемого с Linux 7.3 на Zig 0.17.x.
// Сборка: zig build test / zig build run (host-симулятор ядерных подсистем).
const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const fs_write_probe = b.option(
        bool,
        "fs-write-probe",
        "Exercise ext4 in-place writeback on the boot disk (use a scratch image)",
    ) orelse false;
    const fs_grow_probe = b.option(
        bool,
        "fs-grow-probe",
        "Exercise ext4 block allocation and file growth on the boot disk (use a scratch image)",
    ) orelse false;
    const fs_namei_probe = b.option(
        bool,
        "fs-namei-probe",
        "Exercise ext4 creat/unlink on the boot disk (use a scratch image)",
    ) orelse false;
    const fs_mkdir_probe = b.option(
        bool,
        "fs-mkdir-probe",
        "Exercise ext4 mkdir and nested files on the boot disk (use a scratch image)",
    ) orelse false;
    const fs_rmdir_probe = b.option(
        bool,
        "fs-rmdir-probe",
        "Exercise ext4 mkdir/rmdir of an empty subdirectory (use a scratch image)",
    ) orelse false;
    const fs_journal_probe = b.option(
        bool,
        "fs-journal-probe",
        "Exercise ext4 JBD2 journal commit on the boot disk (use a scratch image)",
    ) orelse false;
    const fs_split_probe = b.option(
        bool,
        "fs-split-probe",
        "Exercise ext4 extent tree depth split on the boot disk (use a scratch image)",
    ) orelse false;
    const fs_sparse_probe = b.option(
        bool,
        "fs-sparse-probe",
        "Exercise ext4 sparse write past EOF on the boot disk (use a scratch image)",
    ) orelse false;
    const fs_depth2_probe = b.option(
        bool,
        "fs-depth2-probe",
        "Exercise ext4 depth 1 to depth 2 extent tree split (use a scratch image)",
    ) orelse false;
    const net_probe = b.option(
        bool,
        "net-probe",
        "Exercise sk_buff and AF_INET/SOCK_DGRAM loopback socket layer",
    ) orelse false;
    const tcp_probe = b.option(
        bool,
        "tcp-probe",
        "Exercise AF_INET/SOCK_STREAM TCP handshake, stream, retransmit and close",
    ) orelse false;
    const inet6_probe = b.option(
        bool,
        "inet6-probe",
        "Exercise AF_INET6/SOCK_DGRAM loopback with IPv6 pseudo-header checksum",
    ) orelse false;
    const jbd2_probe = b.option(
        bool,
        "jbd2-probe",
        "Exercise JBD2 revoke, 64-bit tags, checksums and commit on the boot disk (use a scratch image)",
    ) orelse false;
    const netdev_probe = b.option(
        bool,
        "netdev-probe",
        "Attach virtio-net and exercise net_device, IPv4 FIB, ARP and ICMP echo",
    ) orelse false;
    const tcp_ca_probe = b.option(
        bool,
        "tcp-ca-probe",
        "Exercise TCP Reno cwnd, ssthresh, fast retransmit and recovery",
    ) orelse false;
    const tcp_options_probe = b.option(
        bool,
        "tcp-options-probe",
        "Exercise TCP window scale, SACK, out-of-order reassembly and RTO backoff",
    ) orelse false;
    const icmp6_probe = b.option(
        bool,
        "icmp6-probe",
        "Exercise ICMPv6 echo, checksums, NDP neighbour discovery and solicited-node multicast",
    ) orelse false;
    const queue_probe = b.option(
        bool,
        "queue-probe",
        "Exercise pfifo_fast qdisc bands, NAPI budget, weight and repoll",
    ) orelse false;
    const fq_codel_probe = b.option(
        bool,
        "fq-codel-probe",
        "Exercise fq_codel flow hash, deficit round-robin, CoDel and ECN",
    ) orelse false;
    const htb_probe = b.option(
        bool,
        "htb-probe",
        "Exercise HTB rate/ceil buckets, borrowing, priority and deficit",
    ) orelse false;
    const tcp_timers_probe = b.option(
        bool,
        "tcp-timers-probe",
        "Exercise TCP retransmit, probe0, delack, keepalive and user timeout",
    ) orelse false;
    const mld_probe = b.option(
        bool,
        "mld-probe",
        "Exercise MLDv1/v2, floating-point MRC/QQIC, RA and ND options",
    ) orelse false;
    const tcp_v6_probe = b.option(
        bool,
        "tcpv6-probe",
        "Exercise TCPv6 checksum, socket lookup, handshake and payload",
    ) orelse false;
    const rx_mode_probe = b.option(
        bool,
        "rx-mode-probe",
        "Exercise promiscuity, allmulti, multicast list and virtio RX commands",
    ) orelse false;
    const usb_hotplug_probe = b.option(
        bool,
        "usb-hotplug-probe",
        "Exercise xHCI port status events, connect, reset and slot reuse",
    ) orelse false;
    const xhci_cascade_probe = b.option(
        bool,
        "xhci-cascade-probe",
        "Exercise xHCI external hub descriptors, TT, cascade depth and bandwidth",
    ) orelse false;
    const ncq_probe = b.option(
        bool,
        "ncq-probe",
        "Exercise AHCI NCQ capability, FPDMA FIS, SActive and CI",
    ) orelse false;
    const drm_probe = b.option(
        bool,
        "drm-probe",
        "Exercise DRM mode validation, vrefresh, framebuffer and page flip",
    ) orelse false;
    const igmp_probe = b.option(
        bool,
        "igmp-probe",
        "Exercise IGMPv3 encoding, query, report and leave",
    ) orelse false;
    const ip_defrag_probe = b.option(
        bool,
        "ip-defrag-probe",
        "Exercise IPv4 fragment queue, reassembly and expiry",
    ) orelse false;
    const unix_sock_probe = b.option(
        bool,
        "unix-sock-probe",
        "Exercise AF_UNIX names, socketpair, bind, datagrams and close",
    ) orelse false;
    const ipv6_frag_probe = b.option(
        bool,
        "ipv6-frag-probe",
        "Exercise IPv6 fragment header, queue, reassembly and expiry",
    ) orelse false;
    const netlink_probe = b.option(
        bool,
        "netlink-probe",
        "Exercise netlink headers, attributes, receive dispatch and groups",
    ) orelse false;
    const cgroup_probe = b.option(
        bool,
        "cgroup-probe",
        "Exercise cgroup v2 hierarchy, controllers, tasks and limits",
    ) orelse false;
    const cubic_probe = b.option(
        bool,
        "cubic-probe",
        "Exercise CUBIC congestion control, slow start and HyStart",
    ) orelse false;
    const e1000_probe = b.option(
        bool,
        "e1000-probe",
        "Exercise Intel PRO/1000 TX/RX rings, checksum and NAPI",
    ) orelse false;
    const options = b.addOptions();
    options.addOption(bool, "fs_write_probe", fs_write_probe);
    options.addOption(bool, "fs_grow_probe", fs_grow_probe);
    options.addOption(bool, "fs_namei_probe", fs_namei_probe);
    options.addOption(bool, "fs_mkdir_probe", fs_mkdir_probe);
    options.addOption(bool, "fs_rmdir_probe", fs_rmdir_probe);
    options.addOption(bool, "fs_journal_probe", fs_journal_probe);
    options.addOption(bool, "fs_split_probe", fs_split_probe);
    options.addOption(bool, "fs_sparse_probe", fs_sparse_probe);
    options.addOption(bool, "fs_depth2_probe", fs_depth2_probe);
    options.addOption(bool, "net_probe", net_probe);
    options.addOption(bool, "tcp_probe", tcp_probe);
    options.addOption(bool, "inet6_probe", inet6_probe);
    options.addOption(bool, "jbd2_probe", jbd2_probe);
    options.addOption(bool, "netdev_probe", netdev_probe);
    options.addOption(bool, "tcp_ca_probe", tcp_ca_probe);
    options.addOption(bool, "tcp_options_probe", tcp_options_probe);
    options.addOption(bool, "icmp6_probe", icmp6_probe);
    options.addOption(bool, "queue_probe", queue_probe);
    options.addOption(bool, "fq_codel_probe", fq_codel_probe);
    options.addOption(bool, "htb_probe", htb_probe);
    options.addOption(bool, "tcp_timers_probe", tcp_timers_probe);
    options.addOption(bool, "mld_probe", mld_probe);
    options.addOption(bool, "tcp_v6_probe", tcp_v6_probe);
    options.addOption(bool, "rx_mode_probe", rx_mode_probe);
    options.addOption(bool, "usb_hotplug_probe", usb_hotplug_probe);
    options.addOption(bool, "xhci_cascade_probe", xhci_cascade_probe);
    options.addOption(bool, "ncq_probe", ncq_probe);
    options.addOption(bool, "drm_probe", drm_probe);
    options.addOption(bool, "igmp_probe", igmp_probe);
    options.addOption(bool, "ip_defrag_probe", ip_defrag_probe);
    options.addOption(bool, "unix_sock_probe", unix_sock_probe);
    options.addOption(bool, "ipv6_frag_probe", ipv6_frag_probe);
    options.addOption(bool, "netlink_probe", netlink_probe);
    options.addOption(bool, "cgroup_probe", cgroup_probe);
    options.addOption(bool, "cubic_probe", cubic_probe);
    options.addOption(bool, "e1000_probe", e1000_probe);

    const lib = b.addLibrary(.{
        .name = "ziglinux",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/kernel.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(lib);

    const sim = b.addExecutable(.{
        .name = "ziglinux-sim",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    b.installArtifact(sim);

    const run = b.addRunArtifact(sim);
    const run_step = b.step("run", "Запустить симулятор загрузки ядра");
    run_step.dependOn(&run.step);

    // Тесты всех портированных модулей: zig build test
    const unit = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/tests.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });
    const test_step = b.step("test", "Тесты портированных подсистем Linux");
    test_step.dependOn(&b.addRunArtifact(unit).step);

    // UEFI-цель: zig build efi → zig-out/esp/EFI/BOOT/BOOTX64.efi
    // Не входит в default install, чтобы host-сборка/тесты оставались зелёными.
    const efi_target = b.resolveTargetQuery(.{ .cpu_arch = .x86_64, .os_tag = .uefi });
    const efi_module = b.createModule(.{
        .root_source_file = b.path("src/uefi.zig"),
        .target = efi_target,
        .optimize = optimize,
        .strip = false,
    });
    efi_module.addOptions("build_options", options);
    const efi_exe = b.addExecutable(.{
        .name = "BOOTX64",
        .root_module = efi_module,
    });
    const efi_install = b.addInstallArtifact(efi_exe, .{
        .dest_dir = .{ .override = .{ .custom = "esp/EFI/BOOT" } },
    });
    const efi_step = b.step("efi", "Собрать UEFI-ядро BOOTX64.efi");
    efi_step.dependOn(&efi_install.step);

    // Обычный образ OVMF есть в distro-пакете edk2-ovmf; оставляем локальный
    // OVMF.fd как запасной вариант.
    var ovmf: []const u8 = "OVMF.fd";
    for ([_][]const u8{
        "/usr/share/edk2/x64/OVMF.4m.fd",
        "/usr/share/OVMF/OVMF.fd",
        "OVMF.fd",
    }) |candidate| {
        std.Io.Dir.cwd().access(b.graph.io, candidate, .{}) catch continue;
        ovmf = candidate;
        break;
    }

    const boot_disk = b.option([]const u8, "boot-disk", "Boot disk image for QEMU") orelse "tests/data/boot-disk.img";
    const boot_drive = std.fmt.allocPrint(b.allocator, "if=none,format=raw,file={s},id=zigdisk", .{boot_disk}) catch @panic("OOM");

    const disk_backend = b.option([]const u8, "disk-backend", "QEMU disk: virtio (default), nvme, ahci, or scsi") orelse "virtio";
    const usb_kbd = b.option(bool, "usb-kbd", "Attach QEMU xHCI and a USB keyboard") orelse false;
    const use_scsi = std.mem.eql(u8, disk_backend, "scsi");
    const disk_device = if (std.mem.eql(u8, disk_backend, "nvme"))
        "nvme,drive=zigdisk,serial=zigux,bootindex=1"
    else if (std.mem.eql(u8, disk_backend, "ahci"))
        "ide-hd,drive=zigdisk,bus=ahci.0,bootindex=1"
    else
        "virtio-blk-pci,drive=zigdisk,disable-modern=true,bootindex=1";

    var args: std.ArrayList([]const u8) = .empty;
    const add = struct {
        fn arg(list: *std.ArrayList([]const u8), allocator: std.mem.Allocator, value: []const u8) void {
            list.append(allocator, value) catch @panic("OOM");
        }
    }.arg;
    add(&args, b.allocator, "qemu-system-x86_64");
    add(&args, b.allocator, "-machine");
    add(&args, b.allocator, "q35");
    add(&args, b.allocator, "-smp");
    add(&args, b.allocator, "2");
    add(&args, b.allocator, "-m");
    add(&args, b.allocator, "512M");
    add(&args, b.allocator, "-bios");
    add(&args, b.allocator, ovmf);
    add(&args, b.allocator, "-drive");
    add(&args, b.allocator, "format=raw,file=fat:rw:zig-out/esp");
    add(&args, b.allocator, "-drive");
    add(&args, b.allocator, boot_drive);
    if (std.mem.eql(u8, disk_backend, "ahci")) {
        add(&args, b.allocator, "-device");
        add(&args, b.allocator, "ich9-ahci,id=ahci");
    }
    if (use_scsi) {
        add(&args, b.allocator, "-device");
        add(&args, b.allocator, "virtio-scsi-pci,id=scsi0,disable-modern=true");
        add(&args, b.allocator, "-device");
        add(&args, b.allocator, "scsi-hd,drive=zigdisk,bus=scsi0.0,scsi-id=0,lun=0,bootindex=1");
    } else {
        add(&args, b.allocator, "-device");
        add(&args, b.allocator, disk_device);
    }
    if (usb_kbd) {
        add(&args, b.allocator, "-device");
        add(&args, b.allocator, "qemu-xhci,id=xhci0");
        add(&args, b.allocator, "-device");
        add(&args, b.allocator, "usb-kbd,bus=xhci0.0");
    }
    if (netdev_probe) {
        add(&args, b.allocator, "-netdev");
        add(&args, b.allocator, "user,id=ziglan");
        add(&args, b.allocator, "-device");
        add(&args, b.allocator, "virtio-net-pci,netdev=ziglan,disable-modern=true,mac=52:54:00:12:34:56");
    }
    add(&args, b.allocator, "-serial");
    add(&args, b.allocator, "stdio");
    add(&args, b.allocator, "-display");
    add(&args, b.allocator, "none");
    add(&args, b.allocator, "-no-reboot");

    const qemu = b.addSystemCommand(args.items);
    qemu.step.dependOn(&efi_install.step);
    const qemu_step = b.step("qemu", "Запустить UEFI-ядро в QEMU");
    qemu_step.dependOn(&qemu.step);
}
