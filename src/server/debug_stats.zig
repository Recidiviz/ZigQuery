//! The `/debug/stats` body, as types rather than as text.
//!
//! Not a BigQuery endpoint: it exists because the emulator is the only place
//! that can measure server-side request cost. Field order here is the wire
//! order, and the precisions are the ones a human reads these at — a mean in
//! microseconds and a fraction to four places are different questions.

const std = @import("std");
const json_pb = @import("json_pb.zig");

/// Milliseconds, at the precision the quantity deserves.
pub const Ms1 = json_pb.Fixed(1);
pub const Ms3 = json_pb.Fixed(3);
/// A ratio in [0,1].
pub const Frac3 = json_pb.Fixed(3);
pub const Frac4 = json_pb.Fixed(4);

pub const Contention = struct {
    requests: u64,
    totalWaitMs: Ms1,
    totalHandleMs: Ms1,
    meanWaitMs: Ms3,
    meanHandleMs: Ms3,
    waitFraction: Frac3,
    maxWaiters: u64,
    waitersNow: u64,
};

pub const Sqlite = struct {
    prepareMs: Ms1,
    prepareCount: u64,
    stepMs: Ms1,
    stepCount: u64,
    execMs: Ms1,
    execCount: u64,
    engineMs: Ms1,
    catalogMs: Ms1,
    metadataMs: Ms1,
    catalogPrepareMs: Ms1,
    catalogPrepareCount: u64,
    catalogStepMs: Ms1,
};

pub const Codec = struct {
    /// False means the numbers below are zero because nothing was measured.
    /// See -Dcodec-timers.
    timersEnabled: bool,
    encodeMs: Ms1,
    encodeCount: u64,
    decodeMs: Ms1,
    decodeCount: u64,
    literalMs: Ms1,
    literalCount: u64,
};

pub const Phases = struct {
    analyzeMs: Ms1,
    analyzeCount: u64,
    transformMs: Ms1,
    transformCount: u64,
    sqliteMs: Ms1,
    sqlite: Sqlite,
    preparedSqlBytes: u64,
    codecMs: Ms1,
    codecCount: u64,
    codec: Codec,
    /// Measured against total handle time, so the remainder is HTTP, JSON and
    /// glue. Wall time under N parallel analyzers is bounded by (1-f) + f/N.
    analysisFraction: Frac3,
    sqliteFraction: Frac3,
};

pub const Lookaside = struct {
    hit: i64,
    missSize: i64,
    missFull: i64,
    /// Near 1.0 means allocation is off the critical path. Near 0 with
    /// `missFull` high means the pool is exhausted.
    hitRate: Frac4,
    slotsInUse: i64,
    slotsPeak: i64,
};

pub const SqliteAlloc = struct {
    memoryUsedBytes: i64,
    memoryUsedPeakBytes: i64,
    mallocsOutstanding: i64,
    mallocsOutstandingPeak: i64,
    largestAllocBytes: i64,
    schemaBytes: i64,
    stmtBytes: i64,
    pagerCacheBytes: i64,
    lookaside: Lookaside,
};

pub const Route = struct {
    route: []const u8,
    count: u64,
    meanMs: Ms3,
    minMs: Ms3,
    p50Ms: Ms3,
    p90Ms: Ms3,
    p99Ms: Ms3,
    maxMs: Ms3,
    totalMs: Ms1,
};

pub const SlowQuery = struct {
    ms: Ms3,
    sql: []const u8,
};

pub const Snapshot = struct {
    uptimeSeconds: i64,
    contention: Contention,
    phases: Phases,
    sqliteAlloc: SqliteAlloc,
    routes: []const Route,
    slowQueries: []const SlowQuery,
};

/// Microseconds to milliseconds, at a chosen precision.
pub fn msFromUs(us: u64, comptime T: type) T {
    return .{ .v = @as(f64, @floatFromInt(us)) / 1000.0 };
}

/// Nanoseconds to milliseconds.
pub fn msFromNs(ns: u64, comptime T: type) T {
    return .{ .v = @as(f64, @floatFromInt(ns)) / 1e6 };
}

const testing = std.testing;

test "the snapshot serializes in wire order at the documented precisions" {
    const snap = Snapshot{
        .uptimeSeconds = 42,
        .contention = .{
            .requests = 3,
            .totalWaitMs = .{ .v = 1.25 },
            .totalHandleMs = .{ .v = 10.0 },
            .meanWaitMs = .{ .v = 1.0 / 3.0 },
            .meanHandleMs = .{ .v = 2.0 },
            .waitFraction = .{ .v = 0.111111 },
            .maxWaiters = 2,
            .waitersNow = 0,
        },
        .phases = .{
            .analyzeMs = .{ .v = 5.0 },
            .analyzeCount = 1,
            .transformMs = .{ .v = 0.5 },
            .transformCount = 1,
            .sqliteMs = .{ .v = 2.0 },
            .sqlite = .{
                .prepareMs = .{ .v = 1.0 },
                .prepareCount = 1,
                .stepMs = .{ .v = 0.5 },
                .stepCount = 2,
                .execMs = .{ .v = 0.5 },
                .execCount = 1,
                .engineMs = .{ .v = 1.5 },
                .catalogMs = .{ .v = 0.5 },
                .metadataMs = .{ .v = 0.0 },
                .catalogPrepareMs = .{ .v = 0.25 },
                .catalogPrepareCount = 1,
                .catalogStepMs = .{ .v = 0.25 },
            },
            .preparedSqlBytes = 128,
            .codecMs = .{ .v = 0.0 },
            .codecCount = 0,
            .codec = .{
                .timersEnabled = false,
                .encodeMs = .{ .v = 0.0 },
                .encodeCount = 0,
                .decodeMs = .{ .v = 0.0 },
                .decodeCount = 0,
                .literalMs = .{ .v = 0.0 },
                .literalCount = 0,
            },
            .analysisFraction = .{ .v = 0.55 },
            .sqliteFraction = .{ .v = 0.2 },
        },
        .sqliteAlloc = .{
            .memoryUsedBytes = 1024,
            .memoryUsedPeakBytes = 2048,
            .mallocsOutstanding = 10,
            .mallocsOutstandingPeak = 20,
            .largestAllocBytes = 512,
            .schemaBytes = 64,
            .stmtBytes = 32,
            .pagerCacheBytes = 16,
            .lookaside = .{
                .hit = 100,
                .missSize = 1,
                .missFull = 0,
                .hitRate = .{ .v = 0.96755 },
                .slotsInUse = 3,
                .slotsPeak = 7,
            },
        },
        .routes = &.{.{
            .route = "jobs_query",
            .count = 3,
            .meanMs = .{ .v = 1.5 },
            .minMs = .{ .v = 1.0 },
            .p50Ms = .{ .v = 1.0 },
            .p90Ms = .{ .v = 2.0 },
            .p99Ms = .{ .v = 2.0 },
            .maxMs = .{ .v = 2.0 },
            .totalMs = .{ .v = 4.5 },
        }},
        .slowQueries = &.{.{ .ms = .{ .v = 2.0 }, .sql = "SELECT \"a\"" }},
    };

    const got = try std.json.Stringify.valueAlloc(testing.allocator, snap, .{});
    defer testing.allocator.free(got);

    try testing.expectEqualStrings(
        \\{"uptimeSeconds":42,"contention":{"requests":3,"totalWaitMs":1.3,"totalHandleMs":10.0,"meanWaitMs":0.333,"meanHandleMs":2.000,"waitFraction":0.111,"maxWaiters":2,"waitersNow":0},"phases":{"analyzeMs":5.0,"analyzeCount":1,"transformMs":0.5,"transformCount":1,"sqliteMs":2.0,"sqlite":{"prepareMs":1.0,"prepareCount":1,"stepMs":0.5,"stepCount":2,"execMs":0.5,"execCount":1,"engineMs":1.5,"catalogMs":0.5,"metadataMs":0.0,"catalogPrepareMs":0.3,"catalogPrepareCount":1,"catalogStepMs":0.3},"preparedSqlBytes":128,"codecMs":0.0,"codecCount":0,"codec":{"timersEnabled":false,"encodeMs":0.0,"encodeCount":0,"decodeMs":0.0,"decodeCount":0,"literalMs":0.0,"literalCount":0},"analysisFraction":0.550,"sqliteFraction":0.200},"sqliteAlloc":{"memoryUsedBytes":1024,"memoryUsedPeakBytes":2048,"mallocsOutstanding":10,"mallocsOutstandingPeak":20,"largestAllocBytes":512,"schemaBytes":64,"stmtBytes":32,"pagerCacheBytes":16,"lookaside":{"hit":100,"missSize":1,"missFull":0,"hitRate":0.9676,"slotsInUse":3,"slotsPeak":7}},"routes":[{"route":"jobs_query","count":3,"meanMs":1.500,"minMs":1.000,"p50Ms":1.000,"p90Ms":2.000,"p99Ms":2.000,"maxMs":2.000,"totalMs":4.5}],"slowQueries":[{"ms":2.000,"sql":"SELECT \"a\""}]}
    , got);
}
