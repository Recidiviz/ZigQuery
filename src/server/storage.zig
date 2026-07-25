//! Port of bigquery-emulator server/storage.go plus the DSN assembly in
//! server/server.go:50-58.
//!
//! Differences from Go, by design:
//! - `:memory:` maps to the **memdb VFS**, not Go's `cache=shared`.
//!   Shared-cache mode adds table-level locking that surfaces as
//!   SQLITE_LOCKED, which sqlite3_busy_timeout does NOT retry; Go got away
//!   with it only because its global request mutex serialized everything.
//!   memdb gives a genuinely shared in-memory database with normal locking.
//! - Pragmas are applied as statements via Db.openWith rather than through
//!   DSN `_pragma=` parameters, which are a modernc.org/sqlite extension the
//!   C API does not have.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

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
    pub fn pragmas(s: Storage) []const [:0]const u8 {
        return switch (s.kind) {
            .file => &.{
                "PRAGMA journal_mode = WAL",
                "PRAGMA synchronous = NORMAL",
                "PRAGMA foreign_keys = OFF",
                "PRAGMA cache_size = -16000",
            },
            .memory => &.{
                "PRAGMA synchronous = NORMAL",
                "PRAGMA foreign_keys = OFF",
                "PRAGMA cache_size = -16000",
            },
        };
    }
};

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
