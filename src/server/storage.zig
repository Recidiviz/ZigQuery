//! Port of bigquery-emulator server/storage.go plus the DSN assembly in
//! server/server.go:50-58.
//!
//! Differences from Go, by design:
//! - `:memory:` maps to the **memdb VFS**, not Go's `cache=shared`.
//!   Shared-cache mode adds table-level locking that surfaces as
//!   SQLITE_LOCKED, which sqlite3_busy_timeout does NOT retry; Go got away
//!   with it only because its global request mutex serialized everything.
//!   memdb gives a genuinely shared in-memory database with normal locking.
//!
//!   memdb does, however, guard each database with a single mutex that every
//!   read and write must hold, and its file-lock layer turns two concurrent
//!   writers into SQLITE_BUSY. So SQLite work on an in-memory database cannot
//!   run in parallel no matter how many connections exist.
//!
//!   That is why the server serves on one engine connection. A connection pool
//!   was built and measured: at 4 connections the view-graph test took 833 s
//!   and failed 35 views (15 x SQLITE_BUSY) against 58 s and none serially,
//!   with sampling showing the threads stacked in sqlite3LockAndPrepare at
//!   roughly one core. Extra connections bought contention, not throughput.
//!
//!   How much is there to win by running analysis concurrently instead? The
//!   `phases` block in /debug/stats answers it. Over a Staging view-graph run
//!   (22.4k requests, 15.0 s of handle time):
//!
//!     sqlite3_step         5.50 s  36.6%   38.0k calls  0.145 ms each
//!     GoogleSQL analyze    4.70 s  31.3%   10.5k calls  0.450 ms each
//!     sqlite3_prepare_v2   3.30 s  22.0%   19.1k calls  0.173 ms each
//!     transform            0.64 s   4.3%    9.1k calls  0.071 ms each
//!     HTTP/JSON/glue       0.87 s   5.8%
//!
//!   By caller, SQLite splits 56.6% the caller's own SQL, 0.9% the
//!   `zetasqlite_catalog` upserts and 1.1% the metadata tables — so the cost
//!   is real query work, not the emulator's bookkeeping. Re-preparing the
//!   fixed upsert SQL on every catalog write, which looks wasteful, measures
//!   0.011 ms a call and 0.4% of handle: not worth caching.
//!
//!   Note prepare is nearly as expensive as analysis. Compiling the SQL the
//!   transformer emits costs 0.17 ms a statement against 0.011 ms for a small
//!   one, which says the generated SQL is large; shrinking it would pay off in
//!   both phases at once.
//!
//!   Only the 35.6% that is analyze+transform can overlap, so `(1-f) + f/N`
//!   caps a parallel-analysis design at 1.21x on 2 threads, 1.35x on 4 and
//!   1.43x on 8 — before any of the contention the pool experiment ran into.
//!   Worth revisiting only alongside a storage layer that admits concurrency
//!   (file + WAL, or sharding), which is what would move the other 58%.
//! - Pragmas are applied as statements via Db.openWith rather than through
//!   DSN `_pragma=` parameters, which are a modernc.org/sqlite extension the
//!   C API does not have.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

/// Zig 0.16 dropped `std.posix.getenv` and this layer has no `std.Io` to reach
/// an environment map through — the same reason phase.zig reads the clock from
/// libc.
fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name) orelse return null);
}

/// `PRAGMA temp_store` for this process, from `ZQL_TEMP_STORE`
/// (`default` | `file` | `memory`), or null to leave SQLite's default alone.
///
/// The pragma's MEMORY value is **2**, not 3. `SQLITE_TEMP_STORE=3` is the
/// compile-time define that forces memory and disables the pragma; the pragma
/// parser reads a leading digit only in the range 0..2 and maps anything else
/// — including `3` — to 0, i.e. DEFAULT. So `PRAGMA temp_store = 3` is a
/// silent no-op, which is exactly the failure mode this helper exists to
/// avoid.
fn tempStorePragma() ?[:0]const u8 {
    const v = env("ZQL_TEMP_STORE") orelse return null;
    if (std.ascii.eqlIgnoreCase(v, "memory") or std.mem.eql(u8, v, "2")) {
        return "PRAGMA temp_store = MEMORY";
    }
    if (std.ascii.eqlIgnoreCase(v, "file") or std.mem.eql(u8, v, "1")) {
        return "PRAGMA temp_store = FILE";
    }
    return null;
}

/// `PRAGMA cache_size` override, from `ZQL_CACHE_SIZE`, in SQLite's own units:
/// negative is KiB of memory, positive is a page count. See the measurements
/// on `pragmas` below for why this is the knob that mattered.
fn cacheSizePragma() ?[:0]const u8 {
    const v = env("ZQL_CACHE_SIZE") orelse return null;
    const n = std.fmt.parseInt(i64, v, 10) catch return null;
    return std.fmt.bufPrintSentinel(&cache_size_buf, "PRAGMA cache_size = {d}", .{n}, 0) catch null;
}

var cache_size_buf: [48]u8 = undefined;

/// Whether either environment knob above is set, so startup can log the
/// pragmas it actually applied. A comparison run's whole claim rests on the
/// knob having been applied.
pub fn hasEnvOverride() bool {
    return tempStorePragma() != null or cacheSizePragma() != null;
}

pub const Kind = enum { memory, file };

pub const Storage = struct {
    kind: Kind,
    /// NUL-terminated DSN handed to sqlite3_open.
    dsn: [:0]const u8,

    /// `--database` semantics: ":memory:" or empty for in-memory, otherwise a
    /// path. Go additionally supports an unset flag meaning "temp file"; that
    /// arrives with the loader in M3.
    pub fn resolve(arena: std.mem.Allocator, database: ?[]const u8) !Storage {
        const db = database orelse ":memory:";

        if (db.len == 0 or std.mem.eql(u8, db, ":memory:")) {
            // A named memdb database is shared by every connection that opens
            // the same name, which is what a pool needs. The pid keeps
            // concurrently running emulators from colliding.
            const dsn = try std.fmt.allocPrintSentinel(
                arena,
                "file:/bqemu-{d}?vfs=memdb",
                .{std.c.getpid()},
                0,
            );
            return .{ .kind = .memory, .dsn = dsn };
        }
        return .{
            .kind = .file,
            .dsn = try std.fmt.allocPrintSentinel(arena, "file:{s}", .{db}, 0),
        };
    }

    /// Connection pragmas.
    ///
    /// journal_mode=WAL applies to file databases only — memdb has no
    /// journal. synchronous=NORMAL carries Go's rationale verbatim
    /// (server.go:50-58): the default DELETE+FULL fsyncs on every COMMIT and
    /// a single request issues several independent transactions, so fsync
    /// latency dominated on slow volumes.
    ///
    /// cache_size is the one worth revisiting. A page-cache miss on an
    /// in-memory database still costs a full pager + VFS round trip into
    /// memdb, and the view graph builds a 350 MiB database behind a 16 MiB
    /// cache. Measured over the Staging view-graph test with a counting VFS
    /// (since removed) over 7 runs, ZQL_CACHE_SIZE to vary it:
    ///
    ///     cache_size   handle    step   cache held | memdb reads
    ///     -16000        53.4 s  25.9 s     16 MiB  | 29.1 M / 110 GiB, 8.88 s
    ///     -262144       50.1 s  22.3 s    263 MiB  | -
    ///     -1048576      48.2 s  20.9 s    372 MiB  | 0.12 M /   0 GiB, 0.01 s
    ///     -4194304      48.7 s  21.4 s    372 MiB  | 0.13 M /   0 GiB, 0.01 s
    ///
    /// (handle/step are means of uninstrumented runs — three at -16000, two at
    /// -1048576, one each otherwise; the read columns come from runs carrying
    /// the counting VFS, which costs about 5 s at -16000 and nothing after.
    /// Spread between repeats of one setting is around 1.5 s, so the -262144
    /// row is a real improvement on -16000 and the last two rows are a tie.)
    ///
    /// A 1 GiB cache holds the whole database and the 110 GiB of re-reads
    /// disappear: 19% off sqlite3_step, 10% off server handle time, 7% off the
    /// test's wall clock. Past that the knob stops doing anything — the cache
    /// saturates at the size of the database, not at its own limit, so 4 GiB
    /// holds the same 372 MiB and measures the same. It is a ceiling, not a
    /// reservation, and the useful setting is therefore "somewhat above the
    /// largest database expected" rather than "as large as affordable".
    ///
    /// Not changed here: 356 MiB of the win is resident memory the emulator
    /// does not otherwise need, and the graph a caller loads decides both the
    /// database size and where saturation lands.
    ///
    /// temp_store is *not* worth setting: the same measurement recorded zero
    /// temp-file opens of any class over the whole run, and `= MEMORY` came
    /// out 5% slower over two runs each.
    pub fn pragmas(s: Storage) []const [:0]const u8 {
        const base: []const [:0]const u8 = switch (s.kind) {
            .file => &file_pragmas,
            .memory => &memory_pragmas,
        };
        // ZQL_TEMP_STORE and ZQL_CACHE_SIZE append to the list, so a
        // comparison run can move where temp b-trees live, or how much of the
        // database the pager keeps, without a rebuild. A later pragma of the
        // same name wins, which is why the overrides go last.
        var n = base.len;
        @memcpy(overridden[0..n], base);
        for ([_]?[:0]const u8{
            tempStorePragma(),
            cacheSizePragma(),
        }) |maybe| {
            if (maybe) |p| {
                overridden[n] = p;
                n += 1;
            }
        }
        return if (n == base.len) base else overridden[0..n];
    }
};

const file_pragmas = [_][:0]const u8{
    "PRAGMA journal_mode = WAL",
    "PRAGMA synchronous = NORMAL",
    "PRAGMA foreign_keys = OFF",
    "PRAGMA cache_size = -16000",
};

const memory_pragmas = [_][:0]const u8{
    "PRAGMA synchronous = NORMAL",
    "PRAGMA foreign_keys = OFF",
    "PRAGMA cache_size = -16000",
};

/// Scratch for the env-override variant. One setting per process, read at
/// startup, so a single static buffer is enough — do not call `pragmas` from
/// several threads at once.
var overridden: [file_pragmas.len + 2][:0]const u8 = undefined;

const testing = std.testing;

test "in-memory database uses the memdb VFS, not cache=shared" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_]?[]const u8{ null, ":memory:", "" }) |input| {
        const s = try Storage.resolve(arena, input);
        try testing.expectEqual(Kind.memory, s.kind);
        try testing.expect(std.mem.startsWith(u8, s.dsn, "file:/bqemu-"));
        try testing.expect(std.mem.endsWith(u8, s.dsn, "?vfs=memdb"));
        // cache=shared would raise SQLITE_LOCKED under a pool.
        try testing.expectEqual(
            @as(?usize, null),
            std.mem.indexOf(u8, s.dsn, "cache=shared"),
        );
    }
}

test "a path becomes a file DSN and gets WAL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const s = try Storage.resolve(arena, "/tmp/x.db");
    try testing.expectEqual(Kind.file, s.kind);
    try testing.expectEqualStrings("file:/tmp/x.db", s.dsn);

    var saw_wal = false;
    for (s.pragmas()) |p| {
        if (std.mem.indexOf(u8, p, "journal_mode") != null) saw_wal = true;
    }
    try testing.expect(saw_wal);
}

test "memdb gets no journal_mode pragma" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const s = try Storage.resolve(arena_state.allocator(), ":memory:");
    for (s.pragmas()) |p| {
        try testing.expectEqual(
            @as(?usize, null),
            std.mem.indexOf(u8, p, "journal_mode"),
        );
    }
}

test "a resolved DSN actually opens and is shared across connections" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const s = try Storage.resolve(arena, ":memory:");

    var a = try driver.Db.openWith(testing.allocator, s.dsn, .{
        .pragmas = s.pragmas(),
        .busy_timeout_ms = 5000,
    });
    defer a.close();
    try a.exec("CREATE TABLE dsn_t (x INT64); INSERT INTO dsn_t (x) VALUES (1)", &.{}, .{});

    var b = try driver.Db.openWith(testing.allocator, s.dsn, .{ .pragmas = s.pragmas() });
    defer b.close();
    var rows = try b.query("SELECT x FROM dsn_t", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?[0].int);
}
