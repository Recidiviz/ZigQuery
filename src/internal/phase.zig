//! Where a statement's time actually goes: analysis, transform, or SQLite.
//!
//! This exists to answer one question with a number instead of an argument:
//! *what fraction of a request could run in parallel?* Analysis and transform
//! touch no SQLite and hold no lock worth speaking of, so several of them can
//! overlap; SQLite on an in-memory database cannot overlap at all, because the
//! memdb VFS serializes every read and write behind one mutex (see
//! src/server/storage.zig). Wall time under N parallel analyzers is therefore
//! bounded by `(1 - f) + f/N`, where `f` is the analysis fraction — so `f` is
//! what decides whether restructuring the driver for concurrency is worth
//! anything. A connection pool was built on the guess that `f` was large; it
//! cost 833 s against 58 s serial.
//!
//! Totals and counts only, no histogram: `f` needs a ratio and a mean, and a
//! per-phase distribution would be extra machinery for a question it does not
//! answer. Per-request percentiles already exist in src/server/stats.zig.
//!
//! Counters are process-global and atomic so they stay meaningful if the
//! engine is ever driven from several threads.

const std = @import("std");
const build_options = @import("build_options");

/// Whether the codec phases are instrumented in this build (`-Dcodec-timers`).
/// Readers of `codec*` totals should surface this: with it false those numbers
/// are zero because nothing measured them, not because nothing happened.
pub const codec_timers_enabled = build_options.codec_timers;

pub const Phase = enum {
    /// GoogleSQL analysis: catalog delta render, the push into the C++
    /// catalog handle, and AnalyzeNextStatement itself.
    analyze,
    /// Resolved AST -> SQLite SQL text, including UDF inlining.
    transform,
    /// sqlite3_prepare_v2. Split out from stepping because SQL *compilation*
    /// and SQL *execution* are fixed by completely different things, and DDL
    /// bumps the schema cookie constantly here — which forces prepare_v2 to
    /// recompile, including from inside sqlite3_step on a cached statement.
    sqlite_prepare,
    /// sqlite3_step.
    sqlite_step,
    /// sqlite3_exec.
    sqlite_exec,
    /// Value codec, encode direction: Value -> SqliteRepr. Runs at every UDF
    /// boundary (result) and at the client boundary (bind).
    codec_encode,
    /// Value codec, decode direction: SqliteRepr -> Value. Runs at every UDF
    /// boundary (arguments) and at the client boundary (row read).
    codec_decode,
    /// Value -> SQL literal text for values embedded in generated SQL rather
    /// than bound. Once per call site at transform time, not once per row —
    /// counted apart because it is the only codec work whose cost does not
    /// scale with rows.
    codec_literal,
};

/// Who asked. "SQLite is slow" could mean the caller's query, or the
/// emulator's own bookkeeping — and those have very different fixes, so they
/// are counted apart.
pub const Source = enum {
    /// The statement the caller actually asked for.
    engine,
    /// The `zigquery_catalog` upserts and deletes behind every DDL.
    catalog,
    /// The datasets/tables/jobs tables, reached through the raw passthrough.
    metadata,
};

const n_phases = @typeInfo(Phase).@"enum".field_names.len;
const n_sources = @typeInfo(Source).@"enum".field_names.len;

/// Set for the duration of a raw/metadata call; see `Db.rawQuery`.
pub threadlocal var source: Source = .engine;

var total_ns: [n_phases][n_sources]std.atomic.Value(u64) = @splat(@splat(.init(0)));
var call_count: [n_phases][n_sources]std.atomic.Value(u64) = @splat(@splat(.init(0)));

/// Monotonic nanoseconds. Zig 0.16 moved clock reads behind `std.Io`, which
/// the engine has no source of, so read libc directly — the same thing
/// `catalog.nowTimestamps` does for wall time.
pub fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(u64, @intCast(ts.sec)) *% std.time.ns_per_s +% @as(u64, @intCast(ts.nsec));
}

/// Scoped accumulator: `var t = phase.Timer.begin(.sqlite); defer t.end();`
pub const Timer = struct {
    phase: Phase,
    start: u64,

    pub fn begin(p: Phase) Timer {
        return .{ .phase = p, .start = nowNs() };
    }

    pub fn end(t: Timer) void {
        const p = @backingInt(t.phase);
        const s = @backingInt(source);
        const now = nowNs();
        // A clock that went backwards (or failed, returning 0) contributes
        // nothing rather than a garbage-large sample.
        if (now > t.start) {
            _ = total_ns[p][s].fetchAdd(now - t.start, .monotonic);
        }
        _ = call_count[p][s].fetchAdd(1, .monotonic);
    }
};

/// A `Timer` for the codec phases, which compiles to nothing unless
/// `-Dcodec-timers`. Same shape as `Timer` so call sites read identically:
/// `var t = phase.CodecTimer.begin(.codec_encode); defer t.end();`
///
/// Separate from `Timer` rather than a flag inside it because only the codec
/// phases run often enough for the instrumentation to matter — an `.analyze`
/// span happens once per statement, a `.codec_decode` span happens millions of
/// times per query.
pub const CodecTimer = if (codec_timers_enabled) Timer else struct {
    pub fn begin(_: Phase) @This() {
        return .{};
    }
    pub fn end(_: @This()) void {}
};

/// Sets `source` for a scope and restores it, so a metadata call that reaches
/// the engine (or vice versa) still attributes its innermost work correctly.
pub const SourceScope = struct {
    prev: Source,

    pub fn begin(s: Source) SourceScope {
        const prev = source;
        source = s;
        return .{ .prev = prev };
    }

    pub fn end(sc: SourceScope) void {
        source = sc.prev;
    }
};

pub fn totalNs(p: Phase) u64 {
    var sum: u64 = 0;
    for (&total_ns[@backingInt(p)]) |*v| sum += v.load(.monotonic);
    return sum;
}

pub fn totalNsFrom(p: Phase, s: Source) u64 {
    return total_ns[@backingInt(p)][@backingInt(s)].load(.monotonic);
}

pub fn count(p: Phase) u64 {
    var sum: u64 = 0;
    for (&call_count[@backingInt(p)]) |*v| sum += v.load(.monotonic);
    return sum;
}

pub fn countFrom(p: Phase, s: Source) u64 {
    return call_count[@backingInt(p)][@backingInt(s)].load(.monotonic);
}

/// Every phase that reaches libsqlite3.
pub const sqlite_phases = [_]Phase{ .sqlite_prepare, .sqlite_step, .sqlite_exec };

pub fn sqliteTotalNs() u64 {
    var sum: u64 = 0;
    for (sqlite_phases) |p| sum += totalNs(p);
    return sum;
}

pub fn sqliteTotalNsFrom(s: Source) u64 {
    var sum: u64 = 0;
    for (sqlite_phases) |p| sum += totalNsFrom(p, s);
    return sum;
}

/// The codec phases that partition the work — disjoint, so they may be summed.
pub const codec_phases = [_]Phase{ .codec_encode, .codec_decode, .codec_literal };

pub fn codecTotalNs() u64 {
    var sum: u64 = 0;
    for (codec_phases) |p| sum += totalNs(p);
    return sum;
}

pub fn codecCount() u64 {
    var sum: u64 = 0;
    for (codec_phases) |p| sum += count(p);
    return sum;
}

/// Bytes of SQL handed to sqlite3_prepare_v2. The direct driver of compile
/// cost, and the thing the transformer controls: every redundant subquery
/// level the SQL builder emits is text SQLite has to parse and resolve before
/// its own flattener can decide to undo it.
var prepared_bytes: std.atomic.Value(u64) = .init(0);

/// Optional capture of the SQL text itself, for the snapshot harness
/// (`DUMP_SQL=` in harness/spec_runner.zig). Rewriting the SQL builder is
/// not reviewable from aggregate byte counts alone — you have to read the
/// diff — and this is the one place every engine statement passes through.
///
/// Off by default, and only `.engine` statements reach it: the catalog and
/// metadata upserts behind every DDL are not the builder's output. Process-
/// global and unsynchronized because the harness is single-threaded; do not
/// install a sink from a threaded driver.
pub const SqlSink = *const fn (sql: []const u8) void;
var sql_sink: ?SqlSink = null;

pub fn setPreparedSqlSink(sink: ?SqlSink) void {
    sql_sink = sink;
}

/// One statement handed to sqlite3_prepare_v2.
pub fn notePreparedSql(sql: []const u8) void {
    _ = prepared_bytes.fetchAdd(sql.len, .monotonic);
    if (source == .engine) {
        if (sql_sink) |sink| sink(sql);
    }
}

pub fn preparedBytes() u64 {
    return prepared_bytes.load(.monotonic);
}

pub fn reset() void {
    prepared_bytes.store(0, .monotonic);
    for (&total_ns, &call_count) |*tp, *cp| {
        for (tp, cp) |*t, *c| {
            t.store(0, .monotonic);
            c.store(0, .monotonic);
        }
    }
}

const testing = std.testing;

test "a timed span lands in its own phase and nowhere else" {
    reset();
    defer reset();

    var t = Timer.begin(.analyze);
    // Spin on the clock itself rather than on a counting loop: ReleaseFast
    // folds `for (0..n) |i| spin +%= i` to a closed form even behind
    // doNotOptimizeAway, and then the span genuinely takes zero nanoseconds
    // and the assertion below fails.
    while (nowNs() == t.start) {}
    t.end();

    try testing.expectEqual(@as(u64, 1), count(.analyze));
    try testing.expect(totalNs(.analyze) > 0);
    try testing.expectEqual(@as(u64, 0), count(.sqlite_step));
    try testing.expectEqual(@as(u64, 0), totalNs(.transform));
}

test "counts accumulate across spans" {
    reset();
    defer reset();
    for (0..3) |_| {
        var t = Timer.begin(.sqlite_step);
        t.end();
    }
    try testing.expectEqual(@as(u64, 3), count(.sqlite_step));
}

test "source attributes a span and is restored on scope exit" {
    reset();
    defer reset();
    try testing.expectEqual(Source.engine, source);
    {
        var sc = SourceScope.begin(.metadata);
        defer sc.end();
        var t = Timer.begin(.sqlite_prepare);
        t.end();
    }
    try testing.expectEqual(Source.engine, source);
    try testing.expectEqual(@as(u64, 1), countFrom(.sqlite_prepare, .metadata));
    try testing.expectEqual(@as(u64, 0), countFrom(.sqlite_prepare, .engine));
    try testing.expectEqual(@as(u64, 1), count(.sqlite_prepare));
}

test "codec totals span the disjoint codec phases" {
    reset();
    defer reset();
    for (codec_phases) |p| {
        var t = Timer.begin(p);
        t.end();
    }
    try testing.expectEqual(@as(u64, 3), codecCount());
}

test "CodecTimer records only when the build option is on" {
    reset();
    defer reset();
    var t = CodecTimer.begin(.codec_encode);
    while (nowNs() == @as(u64, if (codec_timers_enabled) t.start else 0)) {
        if (!codec_timers_enabled) break;
    }
    t.end();
    const expected: u64 = if (codec_timers_enabled) 1 else 0;
    try testing.expectEqual(expected, count(.codec_encode));
}

test "sqlite totals span every sqlite phase" {
    reset();
    defer reset();
    for (sqlite_phases) |p| {
        var t = Timer.begin(p);
        t.end();
    }
    try testing.expectEqual(
        @as(u64, 3),
        count(.sqlite_prepare) + count(.sqlite_step) + count(.sqlite_exec),
    );
}
