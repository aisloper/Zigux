//! Порт TCP CUBIC Linux 7.3: net/ipv4/tcp_cubic.c (cubic_root, bictcp_update,
//! cubictcp_cong_avoid, cubictcp_recalc_ssthresh, hystart_update),
//! include/net/tcp.h. GPL-2.0-only.

const std = @import("std");

pub const BETA_SCALE: u64 = 1024;
pub const BETA: u64 = 717;
pub const BIC_SCALE: u64 = 41;
pub const BICTCP_HZ: u6 = 10;
pub const BETA_SCALE_FACTOR: u64 = 8 * (BETA_SCALE + BETA) / 3 / (BETA_SCALE - BETA);
pub const CUBE_RTT_SCALE: u64 = BIC_SCALE * 10;
pub const CUBE_FACTOR: u64 = (@as(u64, 1) << (10 + 3 * BICTCP_HZ)) / (BIC_SCALE * 10);

pub const HYSTART_MIN_SAMPLES: u8 = 8;
pub const HYSTART_DELAY_MIN: u32 = 4000;
pub const HYSTART_DELAY_MAX: u32 = 16000;
pub const HYSTART_LOW_WINDOW: u32 = 16;

/// Целочисленный кубический корень; Linux использует таблицу + Ньютон,
/// здесь то же самое значение получается бинарным поиском без таблицы.
pub fn cubicRoot(a: u64) u32 {
    if (a == 0) return 0;
    var lo: u32 = 1;
    var hi: u32 = @intCast(@min(@as(u64, std.math.maxInt(u32)), a));
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cube = @as(u128, mid) * mid * mid;
        if (cube <= a) {
            lo = mid + 1;
        } else {
            hi = mid;
        }
    }
    return if (lo > 1) lo - 1 else 1;
}

/// bictcp: состояние CUBIC на one TCP-поток (inet_csk_ca).
pub const Control = struct {
    last_max_cwnd: u32 = 0,
    last_cwnd: u32 = 0,
    last_time: u32 = 0,
    epoch_start: u32 = 0,
    ack_cnt: u32 = 0,
    tcp_cwnd: u32 = 0,
    bic_K: u32 = 0,
    bic_origin_point: u32 = 0,
    delay_min: u32 = 0,
    curr_rtt: u32 = std.math.maxInt(u32),
    sample_cnt: u8 = 0,
    cnt: u32 = 2,
    ssthresh: u32 = 0,
    found: bool = false,

    pub fn resetOnLoss(self: *Control) void {
        self.epoch_start = 0;
        self.last_max_cwnd = 0;
        self.bic_K = 0;
        self.bic_origin_point = 0;
        self.curr_rtt = std.math.maxInt(u32);
        self.sample_cnt = 0;
        self.delay_min = 0;
        self.found = false;
    }
};

/// cubictcp_recalc_ssthresh(): beta=717/1024 и fast convergence.
pub fn recalcSsthresh(ca: *Control, cwnd: u32) u32 {
    ca.epoch_start = 0;
    if (cwnd < ca.last_max_cwnd) {
        ca.last_max_cwnd = @intCast((@as(u64, cwnd) * (BETA_SCALE + BETA)) / (2 * BETA_SCALE));
    } else {
        ca.last_max_cwnd = cwnd;
    }
    return @intCast(@max((@as(u64, cwnd) * BETA) / BETA_SCALE, 2));
}

/// bictcp_update(): CUBIC-функция, TCP-дружелюбие и предел роста.
pub fn update(ca: *Control, cwnd: u32, acked: u32, now_ms: u32) void {
    ca.ack_cnt +%= acked;
    if (ca.last_cwnd == cwnd and now_ms -% ca.last_time <= 31) return;
    if (ca.epoch_start != 0 and now_ms == ca.last_time) return;

    ca.last_cwnd = cwnd;
    ca.last_time = now_ms;
    if (ca.epoch_start == 0) {
        ca.epoch_start = now_ms;
        ca.ack_cnt = acked;
        ca.tcp_cwnd = cwnd;
        if (ca.last_max_cwnd <= cwnd) {
            ca.bic_K = 0;
            ca.bic_origin_point = cwnd;
        } else {
            ca.bic_K = cubicRoot(CUBE_FACTOR * (ca.last_max_cwnd - cwnd));
            ca.bic_origin_point = ca.last_max_cwnd;
        }
    }

    const elapsed: u64 = now_ms -% ca.epoch_start;
    const t: u64 = (elapsed + ca.delay_min / 1000) * 1024 / 1000;
    const offs: u64 = if (t < ca.bic_K) ca.bic_K - t else t - ca.bic_K;
    const delta: u64 = @intCast((@as(u128, CUBE_RTT_SCALE) * offs * offs * offs) >> (10 + 3 * BICTCP_HZ));
    const bic_target: u64 = if (t < ca.bic_K)
        ca.bic_origin_point -| delta
    else
        @as(u64, ca.bic_origin_point) + delta;

    if (bic_target > cwnd) {
        ca.cnt = cwnd / @as(u32, @intCast(bic_target - cwnd));
    } else {
        ca.cnt = 100 * cwnd;
    }
    if (ca.last_max_cwnd == 0 and ca.cnt > 20) ca.cnt = 20;

    // tcp_friendliness: AIMD-ветвь не должна отставать от CUBIC.
    const scale: u64 = (cwnd * BETA_SCALE_FACTOR) >> 3;
    if (scale > 0) {
        while (ca.ack_cnt > scale) {
            ca.ack_cnt -= @intCast(scale);
            ca.tcp_cwnd +%= 1;
        }
    }
    if (ca.tcp_cwnd > cwnd) {
        const diff = ca.tcp_cwnd - cwnd;
        const max_cnt = cwnd / diff;
        if (ca.cnt > max_cnt) ca.cnt = max_cnt;
    }
    ca.cnt = @max(ca.cnt, 2);
}

/// cubictcp_cong_avoid(): slow start и AIMD-рост с шагом acked/cnt.
pub fn congAvoid(ca: *Control, cwnd: u32, acked: u32, now_ms: u32, limited: bool) u32 {
    if (!limited) return cwnd;
    if (cwnd < ca.ssthresh) {
        return cwnd +| acked;
    }
    update(ca, cwnd, acked, now_ms);
    return cwnd +| (acked / ca.cnt);
}

/// hystart_update(): ack-train и увеличение задержки как признак конгестии.
pub fn hystart(ca: *Control, cwnd: u32, delay_us: u32) bool {
    if (cwnd < HYSTART_LOW_WINDOW) return false;
    if (ca.delay_min == 0 or ca.delay_min > delay_us) ca.delay_min = delay_us;
    ca.curr_rtt = if (delay_us == 0) 1 else delay_us;
    if (ca.sample_cnt < HYSTART_MIN_SAMPLES) {
        ca.sample_cnt += 1;
        return false;
    }
    const threshold = @min(@max(ca.delay_min >> 3, HYSTART_DELAY_MIN), HYSTART_DELAY_MAX);
    if (ca.curr_rtt > ca.delay_min + threshold) {
        ca.found = true;
        ca.ssthresh = cwnd;
        return true;
    }
    return false;
}

pub const Probe = struct {
    status: []const u8 = "none",
    root: bool = false,
    ssthresh: bool = false,
    update: bool = false,
    growth: bool = false,
    hystart: bool = false,
    errno: i64 = 0,
};

pub fn probe() Probe {
    var p = Probe{};
    p.root = cubicRoot(0) == 0 and cubicRoot(1) == 1 and cubicRoot(7) == 1 and
        cubicRoot(8) == 2 and cubicRoot(26) == 2 and cubicRoot(27) == 3 and
        cubicRoot(1000000) == 100;

    var ca = Control{};
    const first = recalcSsthresh(&ca, 100);
    ca.last_max_cwnd = 200;
    const second = recalcSsthresh(&ca, 100);
    p.ssthresh = first == 70 and second == 70 and ca.last_max_cwnd == 85;

    var cubic = Control{};
    cubic.last_max_cwnd = 120;
    update(&cubic, 60, 4, 100);
    const started = cubic.epoch_start == 100 and cubic.bic_K > 0 and
        cubic.bic_origin_point == 120 and cubic.cnt >= 2;
    update(&cubic, 61, 8, 200);
    p.update = started and cubic.cnt >= 2 and cubic.ack_cnt > 0;

    var grow = Control{ .ssthresh = 32 };
    const ss = congAvoid(&grow, 16, 8, 10, true);
    const capped = congAvoid(&grow, 40, 8, 20, false);
    const ai = congAvoid(&grow, 40, 8, 30, true);
    p.growth = ss == 24 and capped == 40 and ai >= 40 and grow.cnt >= 2;

    var hy = Control{ .delay_min = 1000, .curr_rtt = 1000 };
    var fired = false;
    for (0..8) |_| {
        if (hystart(&hy, 32, 1200)) fired = true;
    }
    const later = hystart(&hy, 32, 9000);
    p.hystart = !fired and later and hy.found and hy.ssthresh == 32;

    p.status = "ok";
    return p;
}

test "cubic: integer cube root matches exact cubes" {
    try std.testing.expectEqual(@as(u32, 0), cubicRoot(0));
    try std.testing.expectEqual(@as(u32, 2), cubicRoot(8));
    try std.testing.expectEqual(@as(u32, 3), cubicRoot(27));
    try std.testing.expectEqual(@as(u32, 100), cubicRoot(1000000));
    try std.testing.expectEqual(@as(u32, 4095), cubicRoot(4095 * 4095 * 4095));
}

test "cubic: ssthresh applies beta and fast convergence" {
    var ca = Control{};
    const plain = recalcSsthresh(&ca, 100);
    try std.testing.expectEqual(@as(u32, 70), plain);
    try std.testing.expectEqual(@as(u32, 100), ca.last_max_cwnd);
    ca.last_max_cwnd = 200;
    const converged = recalcSsthresh(&ca, 100);
    try std.testing.expectEqual(@as(u32, 70), converged);
    try std.testing.expectEqual(@as(u32, 85), ca.last_max_cwnd);
    try std.testing.expectEqual(@as(u32, 2), recalcSsthresh(&ca, 2));
}

test "cubic: update starts an epoch and respects the minimum cnt" {
    var ca = Control{};
    ca.last_max_cwnd = 120;
    update(&ca, 60, 4, 100);
    try std.testing.expectEqual(@as(u32, 100), ca.epoch_start);
    try std.testing.expect(ca.bic_K > 0);
    try std.testing.expectEqual(@as(u32, 120), ca.bic_origin_point);
    try std.testing.expect(ca.cnt >= 2);
    update(&ca, 61, 8, 200);
    try std.testing.expect(ca.cnt >= 2);
    try std.testing.expect(ca.ack_cnt > 0);
}

test "cubic: slow start doubles cwnd and limited mode adds acked/cnt" {
    var ca = Control{ .ssthresh = 32 };
    try std.testing.expectEqual(@as(u32, 24), congAvoid(&ca, 16, 8, 10, true));
    try std.testing.expectEqual(@as(u32, 40), congAvoid(&ca, 40, 8, 20, false));
    const next = congAvoid(&ca, 40, 8, 30, true);
    try std.testing.expect(next >= 40);
    try std.testing.expect(ca.cnt >= 2);
}

test "cubic: hystart needs eight samples before raising an alarm" {
    var ca = Control{ .delay_min = 1000, .curr_rtt = 1000 };
    try std.testing.expect(!hystart(&ca, 8, 9000));
    for (0..7) |_| try std.testing.expect(!hystart(&ca, 32, 1200));
    try std.testing.expect(!hystart(&ca, 32, 1200));
    try std.testing.expect(hystart(&ca, 32, 9000));
    try std.testing.expect(ca.found);
    try std.testing.expectEqual(@as(u32, 32), ca.ssthresh);
}

test "cubic: boot probe exercises root, ssthresh, update, growth and hystart" {
    const p = probe();
    try std.testing.expectEqualStrings("ok", p.status);
    try std.testing.expect(p.root);
    try std.testing.expect(p.ssthresh);
    try std.testing.expect(p.update);
    try std.testing.expect(p.growth);
    try std.testing.expect(p.hystart);
}
