//! Порт TCP Reno из Linux 7.3: управление окном перегрузки. Прямо перенесены
//! tcp_slow_start(), tcp_cong_avoid_ai(), tcp_reno_ssthresh(),
//! tcp_reno_undo_cwnd() и состояния TCP_CA_*; быстрая ретрансляция после трёх
//! dup ACK и выход из recovery следуют RFC 5681 и tcp_input.c.
//! Источники: include/net/tcp.h, net/ipv4/tcp_cong.c, net/ipv4/tcp_input.c,
//! include/uapi/linux/tcp.h. GPL-2.0-only (производная работа по алгоритмам Linux).

const std = @import("std");

/// Начальное окно из include/net/tcp.h: TCP_INIT_CWND.
pub const TCP_INIT_CWND: u32 = 10;
pub const TCP_INFINITE_SSTHRESH: u32 = 0x7fffffff;
pub const TCP_MIN_SSTHRESH: u32 = 2;
pub const TCP_DUPACK_THRESHOLD: u32 = 3;

/// include/uapi/linux/tcp.h: enum tcp_ca_state.
pub const CaState = enum(u8) {
    open = 0,
    disorder = 1,
    cwr = 2,
    recovery = 3,
    loss = 4,
};

pub fn stateName(state: CaState) []const u8 {
    return switch (state) {
        .open => "Open",
        .disorder => "Disorder",
        .cwr => "CWR",
        .recovery => "Recovery",
        .loss => "Loss",
    };
}

/// Подмножество struct tcp_sock, нужное классическому Reno. Окно измеряется
/// в сегментах MSS, как и snd_cwnd в Linux.
pub const Congestion = struct {
    cwnd: u32 = TCP_INIT_CWND,
    ssthresh: u32 = TCP_INFINITE_SSTHRESH,
    cwnd_cnt: u32 = 0,
    cwnd_clamp: u32 = std.math.maxInt(u32),
    prior_cwnd: u32 = TCP_INIT_CWND,
    ca_state: CaState = .open,
    dupacks: u32 = 0,

    /// tcp_in_slow_start(): cwnd < ssthresh.
    pub fn inSlowStart(self: *const Congestion) bool {
        return self.cwnd < self.ssthresh;
    }

    /// tcp_in_cwnd_reduction(): CWR или Recovery.
    pub fn inCwndReduction(self: *const Congestion) bool {
        return self.ca_state == .cwr or self.ca_state == .recovery;
    }

    /// net/ipv4/tcp_cong.c: tcp_slow_start(). Растянутый ACK consuming
    /// возвращает неиспользованные кредиты для congestion avoidance.
    pub fn slowStart(self: *Congestion, acked: u32) u32 {
        const old = self.cwnd;
        const grown = @min(old +| acked, self.ssthresh);
        const left = acked - (grown - old);
        self.cwnd = @min(grown, self.cwnd_clamp);
        return left;
    }

    /// net/ipv4/tcp_cong.c: tcp_cong_avoid_ai(). Один сегмент на cwnd ACK-ов,
    /// счётчик кредитов сохраняется между вызовами.
    pub fn congAvoidAi(self: *Congestion, w: u32, acked: u32) void {
        if (w == 0) return;
        if (self.cwnd_cnt >= w) {
            self.cwnd_cnt = 0;
            self.cwnd = @min(self.cwnd +| 1, self.cwnd_clamp);
        }
        self.cwnd_cnt +|= acked;
        if (self.cwnd_cnt >= w) {
            const delta = self.cwnd_cnt / w;
            self.cwnd_cnt -= delta * w;
            self.cwnd = @min(self.cwnd +| delta, self.cwnd_clamp);
        }
    }

    /// net/ipv4/tcp_cong.c: tcp_reno_cong_avoid(). Вне cwnd-limited окно
    /// не растёт — как и проверка tcp_is_cwnd_limited() в Linux.
    pub fn renoCongAvoid(self: *Congestion, cwnd_limited: bool, acked: u32) void {
        if (!cwnd_limited) return;
        var left = acked;
        if (self.inSlowStart()) {
            left = self.slowStart(left);
            if (left == 0) return;
        }
        self.congAvoidAi(self.cwnd, left);
    }

    /// net/ipv4/tcp_cong.c: tcp_reno_ssthresh() — половина окна, минимум 2.
    pub fn renoSsthresh(self: *const Congestion) u32 {
        return @max(self.cwnd >> 1, TCP_MIN_SSTHRESH);
    }

    /// net/ipv4/tcp_cong.c: tcp_reno_undo_cwnd() — наибольшее сохранённое окно.
    pub fn renoUndoCwnd(self: *const Congestion) u32 {
        return @max(self.cwnd, self.prior_cwnd);
    }

    /// tcp_init_cwnd_reduction(): сохранить prior_cwnd, уполовинить порог и
    /// раздуть окно на три подтверждённых dup ACK (fast retransmit).
    pub fn enterRecovery(self: *Congestion) void {
        self.prior_cwnd = self.cwnd;
        self.ssthresh = self.renoSsthresh();
        self.cwnd = @min(self.ssthresh + TCP_DUPACK_THRESHOLD, self.cwnd_clamp);
        self.cwnd_cnt = 0;
        self.dupacks = 0;
        self.ca_state = .recovery;
    }

    /// Очередной dup ACK: третий запускает быструю ретрансляцию, последующие
    /// продолжают раздувать окно до прихода нового ACK.
    pub fn onDupAck(self: *Congestion) bool {
        self.dupacks += 1;
        if (self.dupacks == TCP_DUPACK_THRESHOLD and !self.inCwndReduction()) {
            self.enterRecovery();
            return true;
        }
        if (self.ca_state == .recovery) {
            self.cwnd = @min(self.cwnd +| 1, self.cwnd_clamp);
        }
        return false;
    }

    /// tcp_end_cwnd_reduction(): сдуть окно до ssthresh и вернуться в Open.
    /// Вне recovery обычный учёт ACK через Reno.
    pub fn onNewAck(self: *Congestion, acked: u32, cwnd_limited: bool) void {
        if (self.ca_state == .recovery) {
            self.cwnd = @max(self.ssthresh, 1);
            self.cwnd_cnt = 0;
            self.dupacks = 0;
            self.ca_state = .open;
            return;
        }
        self.renoCongAvoid(cwnd_limited, acked);
    }

    /// tcp_enter_loss() по таймеру retransmission timeout: порог делится
    /// пополам, окно сбрасывается до одного сегмента.
    pub fn onTimeout(self: *Congestion) void {
        self.prior_cwnd = self.cwnd;
        self.ssthresh = self.renoSsthresh();
        self.cwnd = 1;
        self.cwnd_cnt = 0;
        self.dupacks = 0;
        self.ca_state = .loss;
    }
};

pub const Probe = struct {
    status: []const u8 = "none",
    reno: bool = false,
    slow_start: bool = false,
    avoidance: bool = false,
    ssthresh: bool = false,
    fast_retransmit: bool = false,
    recovery: bool = false,
    timeout: bool = false,
    cwnd: u32 = 0,
    threshold: u32 = 0,
    dupacks: u32 = 0,
    state: []const u8 = "Open",
    acks: u32 = 0,
    errno: i64 = 0,
};

/// Boot-time проба алгоритма без NIC: проходит slow start, avoidance,
/// половинный ssthresh, быструю ретрансляцию, recovery и RTO.
pub fn probe() Probe {
    var result = Probe{};
    var acks: u32 = 0;

    var init = Congestion{};
    result.reno = init.cwnd == TCP_INIT_CWND and
        init.ssthresh == TCP_INFINITE_SSTHRESH and init.inSlowStart();

    init.ssthresh = 20;
    init.cwnd = 8;
    const leftover = init.slowStart(16);
    acks += 1;
    result.slow_start = init.cwnd == 20 and leftover == 4;

    var avoid = Congestion{};
    avoid.cwnd = 20;
    avoid.ssthresh = TCP_MIN_SSTHRESH;
    avoid.renoCongAvoid(false, 10);
    acks += 1;
    avoid.congAvoidAi(20, 20);
    acks += 1;
    result.avoidance = avoid.cwnd == 21 and avoid.cwnd_cnt == 0;

    avoid.cwnd = 20;
    const half = avoid.renoSsthresh();
    avoid.cwnd = 1;
    avoid.prior_cwnd = 24;
    acks += 1;
    result.ssthresh = half == 10 and avoid.renoUndoCwnd() == 24;

    var recovery = Congestion{};
    recovery.cwnd = 20;
    const first = recovery.onDupAck();
    const second = recovery.onDupAck();
    acks += 2;
    const third = recovery.onDupAck();
    acks += 1;
    result.fast_retransmit = !first and !second and third and
        recovery.ssthresh == 10 and recovery.cwnd == 13 and
        recovery.inCwndReduction();
    _ = recovery.onDupAck();
    acks += 1;
    const inflated = recovery.cwnd == 14;
    recovery.onNewAck(1, true);
    acks += 1;
    result.recovery = inflated and recovery.cwnd == 10 and
        recovery.ca_state == .open and recovery.dupacks == 0;

    recovery.cwnd = 16;
    recovery.onTimeout();
    acks += 1;
    result.timeout = recovery.cwnd == 1 and recovery.ssthresh == 8 and
        recovery.ca_state == .loss;

    result.cwnd = recovery.cwnd;
    result.threshold = recovery.ssthresh;
    result.dupacks = recovery.dupacks;
    result.state = stateName(recovery.ca_state);
    result.acks = acks;
    if (result.reno and result.slow_start and result.avoidance and result.ssthresh and
        result.fast_retransmit and result.recovery and result.timeout)
    {
        result.status = "ok";
    }
    return result;
}

test "tcp-ca: slow start stops at ssthresh and returns the leftover credit" {
    var ca = Congestion{};
    try std.testing.expectEqual(@as(u32, 10), ca.cwnd);
    try std.testing.expectEqual(@as(u32, 0), ca.slowStart(4));
    try std.testing.expectEqual(@as(u32, 14), ca.cwnd);
    ca.cwnd = 8;
    ca.ssthresh = 12;
    try std.testing.expectEqual(@as(u32, 4), ca.slowStart(8));
    try std.testing.expectEqual(@as(u32, 12), ca.cwnd);
    try std.testing.expect(!ca.inSlowStart());
}

test "tcp-ca: Reno avoidance grows the window once per cwnd acknowledgements" {
    var ca = Congestion{};
    ca.cwnd = 10;
    ca.ssthresh = 1;
    ca.renoCongAvoid(false, 10);
    try std.testing.expectEqual(@as(u32, 10), ca.cwnd);
    ca.congAvoidAi(10, 4);
    try std.testing.expectEqual(@as(u32, 4), ca.cwnd_cnt);
    ca.congAvoidAi(10, 6);
    try std.testing.expectEqual(@as(u32, 11), ca.cwnd);
    try std.testing.expectEqual(@as(u32, 0), ca.cwnd_cnt);
    ca.congAvoidAi(11, 12);
    try std.testing.expectEqual(@as(u32, 12), ca.cwnd);
    try std.testing.expectEqual(@as(u32, 1), ca.cwnd_cnt);
}

test "tcp-ca: Reno ssthresh halves cwnd and undo keeps the larger window" {
    var ca = Congestion{};
    ca.cwnd = 20;
    try std.testing.expectEqual(@as(u32, 10), ca.renoSsthresh());
    ca.cwnd = 1;
    ca.prior_cwnd = 24;
    try std.testing.expectEqual(@as(u32, 24), ca.renoUndoCwnd());
    ca.cwnd = 30;
    try std.testing.expectEqual(@as(u32, 30), ca.renoUndoCwnd());
    ca.cwnd = 2;
    try std.testing.expectEqual(@as(u32, 2), ca.renoSsthresh());
}

test "tcp-ca: three duplicate ACKs enter recovery and a new ACK deflates cwnd" {
    var ca = Congestion{};
    ca.cwnd = 20;
    try std.testing.expect(!ca.onDupAck());
    try std.testing.expect(!ca.onDupAck());
    try std.testing.expect(ca.onDupAck());
    try std.testing.expectEqual(@as(u32, 10), ca.ssthresh);
    try std.testing.expectEqual(@as(u32, 13), ca.cwnd);
    try std.testing.expectEqual(CaState.recovery, ca.ca_state);
    try std.testing.expect(!ca.onDupAck());
    try std.testing.expectEqual(@as(u32, 14), ca.cwnd);
    ca.onNewAck(1, true);
    try std.testing.expectEqual(@as(u32, 10), ca.cwnd);
    try std.testing.expectEqual(CaState.open, ca.ca_state);
    try std.testing.expectEqual(@as(u32, 0), ca.dupacks);
}

test "tcp-ca: retransmission timeout enters loss with a one-segment window" {
    var ca = Congestion{};
    ca.cwnd = 16;
    ca.onTimeout();
    try std.testing.expectEqual(@as(u32, 1), ca.cwnd);
    try std.testing.expectEqual(@as(u32, 8), ca.ssthresh);
    try std.testing.expectEqual(CaState.loss, ca.ca_state);
    try std.testing.expectEqual(@as(u32, 16), ca.prior_cwnd);
}

test "tcp-ca: boot probe validates all Reno stages" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.reno);
    try std.testing.expect(p.slow_start);
    try std.testing.expect(p.avoidance);
    try std.testing.expect(p.ssthresh);
    try std.testing.expect(p.fast_retransmit);
    try std.testing.expect(p.recovery);
    try std.testing.expect(p.timeout);
    try std.testing.expectEqual(@as(u32, 1), p.cwnd);
    try std.testing.expectEqual(@as(u32, 8), p.threshold);
    try std.testing.expectEqualStrings("Loss", p.state);
    try std.testing.expectEqual(@as(u32, 10), p.acks);
}
