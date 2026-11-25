//! Порт таймеров TCP Linux 7.3: retransmit/probe0/delack/keepalive и окно
//! обнуления. Источники: net/ipv4/tcp_timer.c, net/ipv4/tcp_output.c,
//! include/net/tcp.h, include/net/inet_connection_sock.h.
//! GPL-2.0-only (алгоритмы и константы Linux).
const std = @import("std");

pub const RTO_MIN: u32 = 200;
pub const RTO_MAX: u32 = 120_000;
pub const TIMEOUT_INIT: u32 = 1_000;
pub const TIMEOUT_MIN: u32 = 2;
pub const RETRIES2: u8 = 15;
pub const DELACK_MIN: u32 = 40;
pub const DELACK_MAX: u32 = 200;
pub const KEEPALIVE_TIME: u32 = 120 * 60 * 1_000;
pub const KEEPALIVE_PROBES: u8 = 9;
pub const KEEPALIVE_INTVL: u32 = 75_000;
pub const RESOURCE_PROBE_INTERVAL: u32 = 500;
/// ilog2(TCP_RTO_MAX / TCP_RTO_MIN) + 1 = ilog2(600) + 1 = 10.
pub const PROBE0_MAX_BACKOFF: u8 = 10;

pub const Timer = enum(u8) {
    none = 0,
    retrans,
    probe0,
    delack,
    keepalive,
    loss_probe,
    reo_timeout,
};

pub const State = enum(u8) {
    closed,
    listen,
    syn_sent,
    established,
    fin_wait2,
    time_wait,
    close_wait,
    last_ack,
};

/// inet_csk_rto_backoff(): rto << backoff с насыщением по максимуму.
pub fn rtoBackoff(rto: u32, backoff: u8, max_when: u32) u32 {
    var when: u64 = rto;
    var i: u8 = 0;
    while (i < backoff) : (i += 1) when = @min(when * 2, max_when);
    return @intCast(@min(when, max_when));
}

/// tcp_probe0_when(): base = max(rto, TCP_RTO_MIN), сдвиг ограничен ilog2.
pub fn probe0When(rto: u32, backoff: u8) u32 {
    const base = @max(rto, RTO_MIN);
    const shift: u8 = @min(PROBE0_MAX_BACKOFF, backoff);
    var when: u64 = base;
    var i: u8 = 0;
    while (i < shift) : (i += 1) when = @min(when * 2, RTO_MAX);
    return @intCast(@min(when, RTO_MAX));
}

/// tcp_clamp_probe0_to_user_timeout(): не ждать дольше user timeout.
pub fn clampProbe0(when: u32, now: u32, probes_tstamp: u32, user_timeout: u32) u32 {
    if (user_timeout == 0 or probes_tstamp == 0) return when;
    const elapsed = if (now >= probes_tstamp) now - probes_tstamp else 0;
    const remaining = @max(@as(i64, user_timeout) - @as(i64, elapsed), TIMEOUT_MIN);
    return @intCast(@min(@as(i64, when), remaining));
}

/// Упрощённый inet_connection_sock + tcp_sock: только поля, нужные таймерам.
pub const Timers = struct {
    now: u32 = 0,
    state: State = .closed,
    pending: Timer = .none,
    expires: u32 = 0,
    rto: u32 = TIMEOUT_INIT,
    backoff: u8 = 0,
    probes_out: u8 = 0,
    probes_tstamp: u32 = 0,
    user_timeout: u32 = 0,
    retries2: u8 = RETRIES2,
    packets_out: u32 = 0,
    write_queue_empty: bool = true,
    keepalive_enabled: bool = false,
    keepalive_time: u32 = KEEPALIVE_TIME,
    keepalive_intvl: u32 = KEEPALIVE_INTVL,
    keepalive_probes: u8 = KEEPALIVE_PROBES,
    rcv_tstamp: u32 = 0,

    retransmits: usize = 0,
    probes_sent: usize = 0,
    acks_sent: usize = 0,
    keepalive_probes_sent: usize = 0,
    timeouts: usize = 0,
    local_congestion: bool = false,

    /// inet_csk_reset_xmit_timer(): отложенное событие с абсолютным сроком.
    pub fn resetTimer(self: *Timers, kind: Timer, when: u32) void {
        self.pending = kind;
        self.expires = self.now +% @max(when, TIMEOUT_MIN);
    }

    pub fn clearTimer(self: *Timers) void {
        self.pending = .none;
        self.expires = 0;
    }

    pub fn advance(self: *Timers, now: u32) bool {
        self.now = now;
        return self.pending != .none and now >= self.expires;
    }

    /// tcp_write_timer(): диспетчер событий retransmit timer.
    pub fn writeTimer(self: *Timers) !void {
        const event = self.pending;
        if (event == .none) return;
        self.clearTimer();
        switch (event) {
            .retrans => try self.retransmitTimer(),
            .probe0 => try self.probeTimer(),
            .loss_probe, .reo_timeout => self.resetTimer(event, self.rto),
            else => {},
        }
    }

    /// tcp_retransmit_timer(): tcp_backoff, tcp_retries2 и перепланирование.
    pub fn retransmitTimer(self: *Timers) !void {
        self.retransmits += 1;
        if (self.packets_out == 0) {
            self.backoff = 0;
            return;
        }
        if (self.backoff >= self.retries2) {
            self.timeouts += 1;
            return error.TimedOut;
        }
        const when = rtoBackoff(self.rto, self.backoff, RTO_MAX);
        self.backoff +|= 1;
        self.resetTimer(.retrans, when);
    }

    /// tcp_check_probe_timer(): запуск persist-таймера при нулевом окне.
    pub fn checkProbeTimer(self: *Timers) void {
        if (self.packets_out == 0 and self.pending == .none)
            self.resetTimer(.probe0, @max(self.rto, RTO_MIN));
    }

    /// tcp_probe_timer(): watchdog нулевого окна по RFC 1122 4.2.2.17.
    pub fn probeTimer(self: *Timers) !void {
        if (self.packets_out != 0 or !self.write_queue_empty) {
            self.probes_out = 0;
            self.probes_tstamp = 0;
            self.backoff = 0;
            return;
        }
        if (self.probes_tstamp == 0) self.probes_tstamp = self.now;
        if (self.probes_out >= self.retries2) {
            self.timeouts += 1;
            return error.TimedOut;
        }
        try self.sendProbe0();
    }

    /// tcp_send_probe0(): ACK с seq=snd_una-1, увеличение backoff и новый timeout.
    pub fn sendProbe0(self: *Timers) !void {
        self.probes_sent += 1;
        self.probes_out +|= 1;
        var timeout: u32 = RESOURCE_PROBE_INTERVAL;
        if (!self.local_congestion) {
            if (self.backoff < self.retries2) self.backoff +|= 1;
            timeout = probe0When(self.rto, self.backoff);
        }
        timeout = clampProbe0(timeout, self.now, self.probes_tstamp, self.user_timeout);
        self.resetTimer(.probe0, timeout);
    }

    /// tcp_delack_timer(): отложенный ACK с границами DELACK_MIN/MAX.
    pub fn delackTimer(self: *Timers) void {
        self.acks_sent += 1;
        self.clearTimer();
    }

    pub fn scheduleDelack(self: *Timers, ato: u32) void {
        const delay = std.math.clamp(ato, DELACK_MIN, DELACK_MAX);
        self.resetTimer(.delack, delay);
    }

    /// tcp_keepalive_timer(): idle 2 часа, затем 9 проб с интервалом 75 с.
    pub fn keepaliveTimer(self: *Timers) !void {
        if (!self.keepalive_enabled or
            self.state == .closed or self.state == .syn_sent or self.state == .listen)
            return;
        if (self.packets_out != 0 or !self.write_queue_empty) {
            self.resetTimer(.keepalive, self.keepalive_time);
            return;
        }
        const elapsed = if (self.now >= self.rcv_tstamp) self.now - self.rcv_tstamp else 0;
        if (elapsed < self.keepalive_time) {
            self.resetTimer(.keepalive, self.keepalive_time - elapsed);
            return;
        }
        if (self.probes_out >= self.keepalive_probes) {
            self.timeouts += 1;
            return error.TimedOut;
        }
        self.keepalive_probes_sent += 1;
        self.probes_out +|= 1;
        self.resetTimer(.keepalive, self.keepalive_intvl);
    }

    /// tcp_ack() сбрасывает счётчик проб окна после любого входящего ACK.
    pub fn onAck(self: *Timers, window_open: bool) void {
        if (window_open) {
            self.probes_out = 0;
            self.probes_tstamp = 0;
            self.backoff = 0;
            self.clearTimer();
        }
        self.rcv_tstamp = self.now;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    retrans: bool = false,
    backoff: bool = false,
    probe0: bool = false,
    keepalive: bool = false,
    delack: bool = false,
    user_timeout: bool = false,
    errno: i64 = 0,
};

pub fn probe() !Probe {
    var p = Probe{};
    var t = Timers{ .state = .established, .packets_out = 1, .rto = 200 };

    // Retransmit: 200 → 400 → 800 мс, как в tcp_backoff().
    const first = rtoBackoff(t.rto, t.backoff, RTO_MAX);
    t.resetTimer(.retrans, first);
    try t.writeTimer();
    const second = rtoBackoff(t.rto, t.backoff, RTO_MAX);
    t.resetTimer(.retrans, second);
    try t.writeTimer();
    p.backoff = second == 400 and rtoBackoff(t.rto, t.backoff, RTO_MAX) == 800;
    p.retrans = t.retransmits == 2 and t.backoff == 2;

    // Probe0: нулевое окно, ACK с seq=snd_una-1 и backoff 200 → 400.
    t = .{ .state = .established, .rto = 200 };
    t.checkProbeTimer();
    try t.writeTimer();
    p.probe0 = t.probes_sent == 1 and t.probes_out == 1 and t.pending == .probe0;
    t.local_congestion = true;
    t.resetTimer(.probe0, RESOURCE_PROBE_INTERVAL);
    try t.writeTimer();
    t.scheduleDelack(0);
    t.delackTimer();
    p.delack = t.acks_sent == 1 and t.probes_sent == 2;

    // Keepalive: после двух часов простоя отправляется первая проба.
    t = .{
        .state = .established,
        .keepalive_enabled = true,
        .rcv_tstamp = 0,
    };
    t.now = KEEPALIVE_TIME;
    try t.keepaliveTimer();
    p.keepalive = t.keepalive_probes_sent == 1 and t.probes_out == 1;
    t.now += KEEPALIVE_INTVL;
    _ = t.advance(t.now);
    try t.keepaliveTimer();
    p.keepalive = p.keepalive and t.keepalive_probes_sent == 2;

    // user timeout ограничивает ожидание window probe.
    p.user_timeout = clampProbe0(3_200, 2_200, 2_100, 1_000) == 900;
    p.status = "ok";
    return p;
}

test "tcp timers: rto backoff, probe0 and user timeout clamp" {
    try std.testing.expectEqual(@as(u32, 800), rtoBackoff(200, 2, RTO_MAX));
    try std.testing.expectEqual(@as(u32, RTO_MAX), rtoBackoff(200, 20, RTO_MAX));
    try std.testing.expectEqual(@as(u32, 400), probe0When(200, 1));
    try std.testing.expectEqual(@as(u32, RTO_MAX), probe0When(200, 200));
    try std.testing.expectEqual(@as(u32, 900), clampProbe0(3_200, 2_200, 2_100, 1_000));
}

test "tcp timers: retransmission backoff and retries" {
    var t = Timers{ .packets_out = 1, .rto = 200 };
    t.resetTimer(.retrans, 200);
    try t.writeTimer();
    try std.testing.expectEqual(@as(u8, 1), t.backoff);
    try std.testing.expectEqual(@as(u32, 200), t.expires - t.now);
    t.resetTimer(.retrans, 400);
    try t.writeTimer();
    try std.testing.expectEqual(@as(u8, 2), t.backoff);
    try std.testing.expectEqual(@as(u32, 400), t.expires - t.now);
    t.backoff = RETRIES2;
    try std.testing.expectError(error.TimedOut, t.retransmitTimer());
}

test "tcp timers: boot probe exercises all timer paths" {
    const p = try probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.retrans);
    try std.testing.expect(p.backoff);
    try std.testing.expect(p.probe0);
    try std.testing.expect(p.delack);
    try std.testing.expect(p.keepalive);
    try std.testing.expect(p.user_timeout);
}
