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

/// The slowest statements seen, so "the server is slow" can be answered with
/// *which query* rather than a percentile.
///
/// A fixed-size min-heap-ish array rather than a real heap: `capacity` is tiny,
/// the scan to find the current minimum is a handful of comparisons, and it
/// only runs for a statement already slower than the cheapest resident. The
/// alternative — recording every statement and sorting later — would keep
/// tens of thousands of SQL strings alive for a debug endpoint.
///
/// SQL is truncated to `sql_limit` bytes and copied into a caller-owned buffer,
/// because the statement text is arena-allocated per request and gone by the
/// time anyone reads /debug/stats.
pub fn SlowQueries(comptime capacity: usize, comptime sql_limit: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            us: u64 = 0,
            len: usize = 0,
            buf: [sql_limit]u8 = undefined,

            pub fn sql(e: *const Entry) []const u8 {
                return e.buf[0..e.len];
            }
        };

        entries: [capacity]Entry = @splat(.{}),
        /// Number of slots filled, so a short run does not report empties.
        len: usize = 0,

        pub fn record(self: *Self, us: u64, sql: []const u8) void {
            var slot: usize = undefined;
            if (self.len < capacity) {
                slot = self.len;
                self.len += 1;
            } else {
                // Evict the fastest resident, and only if this beats it.
                var min_i: usize = 0;
                for (self.entries[0..self.len], 0..) |e, i| {
                    if (e.us < self.entries[min_i].us) min_i = i;
                }
                if (us <= self.entries[min_i].us) return;
                slot = min_i;
            }
            const n = @min(sql.len, sql_limit);
            self.entries[slot].us = us;
            self.entries[slot].len = n;
            @memcpy(self.entries[slot].buf[0..n], sql[0..n]);
        }

        /// Entries slowest-first. Sorts a copy of the index order; the array is
        /// `capacity` long, so this is free at any capacity worth having.
        pub fn sorted(self: *const Self, out: *[capacity]*const Entry) []const *const Entry {
            for (out[0..self.len], 0..) |*p, i| p.* = &self.entries[i];
            const slice = out[0..self.len];
            std.mem.sort(*const Entry, slice, {}, struct {
                fn slower(_: void, a: *const Entry, b: *const Entry) bool {
                    return a.us > b.us;
                }
            }.slower);
            return slice;
        }
    };
}

const testing = std.testing;

test "slow queries keeps the slowest and evicts the fastest" {
    var q: SlowQueries(3, 16) = .{};
    q.record(10, "ten");
    q.record(30, "thirty");
    q.record(20, "twenty");
    q.record(5, "five"); // slower than nothing resident -> dropped
    q.record(40, "forty"); // evicts "ten"

    var buf: [3]*const @TypeOf(q).Entry = undefined;
    const top = q.sorted(&buf);
    try testing.expectEqual(@as(usize, 3), top.len);
    try testing.expectEqualStrings("forty", top[0].sql());
    try testing.expectEqualStrings("thirty", top[1].sql());
    try testing.expectEqualStrings("twenty", top[2].sql());
}

test "slow queries truncates SQL to the limit" {
    var q: SlowQueries(2, 4) = .{};
    q.record(1, "abcdefgh");
    var buf: [2]*const @TypeOf(q).Entry = undefined;
    try testing.expectEqualStrings("abcd", q.sorted(&buf)[0].sql());
}

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
