//! Boot probe for the IPv4 netdev slice: register a real virtio-net NIC,
//! resolve the gateway with ARP and exchange an ICMP echo through the
//! static FIB. Sources: net/core/dev.c, net/ipv4/arp.c, net/ipv4/icmp.c.
//! GPL-2.0-only (алгоритмы Linux).

const std = @import("std");
const x86 = @import("../x86_64.zig");
const pci = @import("pci.zig");
const virtio_net = @import("virtio_net.zig");
const netdev = @import("../../netdev.zig");
const route = @import("../../route.zig");
const ethernet = @import("../../ethernet.zig");
const arp = @import("../../arp.zig");
const ipv4 = @import("../../ipv4.zig");
const icmp = @import("../../icmp.zig");
const skb = @import("../../skb.zig");

const GUEST_IP: u32 = 0x0a00_020f; // 10.0.2.15, QEMU user-mode default
const GATEWAY_IP: u32 = 0x0a00_0202; // 10.0.2.2
const ECHO_ID: u16 = 0x1234;
const ECHO_PAYLOAD = "NETDEV NIC PROBE\n";

pub const NetdevProbe = struct {
    status: []const u8 = "none",
    device_ok: bool = false,
    route_ok: bool = false,
    arp_ok: bool = false,
    icmp_ok: bool = false,
    mac: [6]u8 = @splat(0),
    ifindex: u32 = 0,
    prefix: u8 = 0,
    tx: usize = 0,
    rx: usize = 0,
    errno: i64 = 0,
};

fn transmit(allocator: std.mem.Allocator, dev: *netdev.NetDevice, frame: []const u8) !void {
    const packet = try skb.SkBuff.alloc(allocator, frame.len, 0);
    defer packet.free();
    _ = try packet.put(frame);
    _ = try netdev.devQueueXmit(dev, packet);
}

fn nextFrame(nic: *virtio_net.VirtioNet, buf: []u8) ?[]const u8 {
    var guard: usize = 0;
    while (guard < 20_000_000) : (guard += 1) {
        if (nic.recvFrame(buf)) |frame| {
            return frame;
        } else |err| {
            switch (err) {
                error.WouldBlock => x86.pause(),
                else => return null,
            }
        }
    }
    return null;
}

/// Прошивка QEMU не имеет DHCP-клиента: адрес 10.0.2.15 и шлюз 10.0.2.2
/// заданы статически, как в минимальном сетевом initramfs Linux.
pub fn probe(allocator: std.mem.Allocator) NetdevProbe {
    var result = NetdevProbe{};
    var devices: [32]pci.Device = undefined;
    const scanned = pci.scan(&devices);
    var nic: ?*virtio_net.VirtioNet = null;
    for (devices[0..scanned]) |dev| {
        if (virtio_net.isNetDevice(dev)) {
            nic = virtio_net.initFromPci(allocator, dev) catch {
                result.status = "init";
                return result;
            };
            break;
        }
    }
    const net = nic orelse {
        result.status = "device";
        return result;
    };
    defer net.deinit();
    result.mac = net.mac;
    result.device_ok = true;

    result.ifindex = netdev.registry.register(&net.device) catch {
        result.status = "register";
        return result;
    };
    net.device.flags = netdev.IFF_UP | netdev.IFF_BROADCAST | netdev.IFF_RUNNING;
    net.device.mtu = 1500;

    var routes: [2]route.FibEntry = undefined;
    var table = route.FibTable.init(&routes);
    table.add(.{ .dst = 0, .prefix = 0, .gateway = GATEWAY_IP, .oif = result.ifindex, .metric = 100 }) catch {
        result.status = "route-table";
        return result;
    };
    const connected = route.parseIpv4("10.0.2.0") catch unreachable;
    table.add(.{ .dst = connected, .prefix = 24, .oif = result.ifindex }) catch {
        result.status = "route-table";
        return result;
    };
    const selected = table.lookup(.{ .daddr = GATEWAY_IP }) orelse {
        result.status = "route-lookup";
        return result;
    };
    if (selected.oif != result.ifindex or selected.prefix != 24) {
        result.status = "route-result";
        return result;
    }
    result.prefix = selected.prefix;
    result.route_ok = true;

    var neighbors: [2]arp.Neighbor = undefined;
    var neighbor_table = arp.Table.init(&neighbors);
    const framebuf = allocator.alloc(u8, virtio_net.MAX_FRAME) catch {
        result.status = "alloc";
        return result;
    };
    defer allocator.free(framebuf);

    const request = arp.buildRequest(framebuf, net.mac, GUEST_IP, GATEWAY_IP) catch {
        result.status = "arp-build";
        return result;
    };
    transmit(allocator, &net.device, request) catch {
        result.status = "arp-xmit";
        result.errno = -1;
        return result;
    };
    const arp_frame = nextFrame(net, framebuf) orelse {
        result.status = "arp-timeout";
        return result;
    };
    netdev.netifRx(&net.device, arp_frame);
    const reply = arp.parse(arp_frame) catch {
        result.status = "arp-parse";
        return result;
    };
    if (reply.op != arp.ARPOP_REPLY or reply.spa != GATEWAY_IP or reply.tpa != GUEST_IP) {
        result.status = "arp-reply";
        return result;
    }
    neighbor_table.update(GATEWAY_IP, reply.sha) catch {
        result.status = "neighbor-full";
        return result;
    };
    const gateway_mac = neighbor_table.lookup(GATEWAY_IP) orelse {
        result.status = "neighbor-lookup";
        return result;
    };
    result.arp_ok = true;

    var icmpbuf: [64]u8 = @splat(0);
    const echo = icmp.buildEcho(&icmpbuf, ECHO_ID, 1, ECHO_PAYLOAD) catch unreachable;
    var ipbuf: [128]u8 = @splat(0);
    _ = ipv4.buildHeader(&ipbuf, ipv4.IPPROTO_ICMP, GUEST_IP, GATEWAY_IP, echo.len) catch unreachable;
    @memcpy(ipbuf[ipv4.IP_HLEN..][0..echo.len], echo);
    const datagram = ethernet.build(framebuf, gateway_mac, net.mac, ethernet.ETH_P_IP, ipbuf[0 .. ipv4.IP_HLEN + echo.len]) catch {
        result.status = "icmp-build";
        return result;
    };
    transmit(allocator, &net.device, datagram) catch {
        result.status = "icmp-xmit";
        result.errno = -2;
        return result;
    };
    const icmp_frame = nextFrame(net, framebuf) orelse {
        result.status = "icmp-timeout";
        return result;
    };
    netdev.netifRx(&net.device, icmp_frame);
    const ether = ethernet.parse(icmp_frame) catch {
        result.status = "ether-parse";
        return result;
    };
    if (ether.ethertype != ethernet.ETH_P_IP) {
        result.status = "ether-type";
        return result;
    }
    const ip = ipv4.parseHeader(ether.payload) catch {
        result.status = "ipv4-parse";
        return result;
    };
    if (ip.protocol != ipv4.IPPROTO_ICMP or ip.src != GATEWAY_IP or ip.dst != GUEST_IP) {
        result.status = "ipv4-fields";
        return result;
    }
    const answer = icmp.parseEcho(ether.payload[@as(usize, ip.ihl) * 4 .. ip.total_len]) catch {
        result.status = "icmp-parse";
        return result;
    };
    if (answer.type != icmp.ICMP_ECHOREPLY or answer.id != ECHO_ID or answer.seq != 1 or
        !std.mem.eql(u8, answer.payload, ECHO_PAYLOAD))
    {
        result.status = "icmp-reply";
        return result;
    }
    result.icmp_ok = true;
    result.tx = net.device.stats.tx_packets;
    result.rx = net.device.stats.rx_packets;
    result.status = "ok";
    return result;
}
