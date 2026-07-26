//! Per-route request timing. No Go counterpart — bigquery-emulator relies on
//! the caller timing requests, and recidiviz's own stats block only works
//! against the Docker image, so a local binary reports nothing.
//!
//! Durations go into a log2-microsecond histogram: percentiles from a fixed
//! 32-word table, no allocation and no sorting on the request path.

const std = @import("std");

pub const bucket_count = 32;

pub const RouteStats = struct {
    count: u64 = 0,
    total_us: u64 = 0,
    min_us: u64 = std.math.maxInt(u64),
    max_us: u64 = 0,
    /// buckets[i] counts durations in [2^(i-1), 2^i) microseconds.
    buckets: [bucket_count]u64 = @splat(0),

    pub fn record(s: *RouteStats, us: u64) void {
        s.count += 1;
        s.total_us += us;
        if (us < s.min_us) s.min_us = us;
        if (us > s.max_us) s.max_us = us;
        const idx: usize = if (us == 0) 0 else @min(
            bucket_count - 1,
            @as(usize, @intCast(64 - @clz(us))),
        );
        s.buckets[idx] += 1;
    }

    /// Upper bound of the bucket holding the p-th percentile, in microseconds.
    /// Coarse by construction — a bucket spans a factor of two.
    pub fn percentileUs(s: *const RouteStats, p: f64) u64 {
        if (s.count == 0) return 0;
        // Round up, so p99.9 of 101 requests reaches the 101st rather than
        // stopping at the 100th.
        const target = @max(
            1,
            @as(u64, @intFromFloat(@ceil(@as(f64, @floatFromInt(s.count)) * p))),
        );
        var seen: u64 = 0;
        for (s.buckets, 0..) |n, i| {
            seen += n;
            if (seen >= target) return @as(u64, 1) << @intCast(i);
        }
        return s.max_us;
    }

    pub fn meanUs(s: *const RouteStats) f64 {
        if (s.count == 0) return 0;
        return @as(f64, @floatFromInt(s.total_us)) / @as(f64, @floatFromInt(s.count));
    }
};

const testing = std.testing;

test "records count, extremes and mean" {
    var s = RouteStats{};
    for ([_]u64{ 10, 20, 30, 40 }) |us| s.record(us);
    try testing.expectEqual(@as(u64, 4), s.count);
    try testing.expectEqual(@as(u64, 10), s.min_us);
    try testing.expectEqual(@as(u64, 40), s.max_us);
    try testing.expectEqual(@as(f64, 25), s.meanUs());
}

test "percentiles land in the right power-of-two bucket" {
    var s = RouteStats{};
    // 100 fast requests around 8us, 1 slow one at ~4ms.
    for (0..100) |_| s.record(8);
    s.record(4096);
    // p50 sits with the fast ones, p99+ reaches the slow bucket.
    try testing.expect(s.percentileUs(0.5) <= 16);
    try testing.expect(s.percentileUs(0.999) >= 4096);
    try testing.expectEqual(@as(u64, 4096), s.max_us);
}

test "zero-length requests do not break bucketing" {
    var s = RouteStats{};
    s.record(0);
    try testing.expectEqual(@as(u64, 1), s.count);
    try testing.expectEqual(@as(u64, 0), s.min_us);
}

test "empty stats report zero rather than dividing by zero" {
    const s = RouteStats{};
    try testing.expectEqual(@as(f64, 0), s.meanUs());
    try testing.expectEqual(@as(u64, 0), s.percentileUs(0.5));
}
