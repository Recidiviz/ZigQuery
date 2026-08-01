//! Port of bigquery-emulator internal/contentdata/repository.go AddTableData
//! (:452) — the row-write half of the content store, as used by
//! tabledata.insertAll.
//!
//! Go prepares one `INSERT <table> (cols) VALUES (?,...)` and Execs it per row
//! inside a transaction; `driver.Db.prepare` exists so this can do the same
//! rather than re-analyzing the statement for every row.
//!
//! Differences from Go, by design:
//! - `INSERT INTO`, not Go's `INSERT` — GoogleSQL accepts both and the rest of
//!   this port spells it with INTO.
//! - Go's `ContentRepoMode()` sets the analyzer's name path to
//!   [project, dataset] so an unqualified table id resolves. The table is
//!   named in full here instead, which needs no connection-wide state.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const value = zetasqlite.value;
const rowvalue = @import("../types/rowvalue.zig");

pub const Error = error{
    /// A row value could not be shaped to its column (see Normalizer).
    InvalidRowValue,
    /// Go: "failed to unmarshal json value [%s]: %w".
    InvalidJsonValue,
    /// Go: "failed to decode base64 bytes: %v - %w".
    InvalidBase64Value,
    /// The engine rejected the INSERT (prepare or exec).
    InsertFailed,
} || std.mem.Allocator.Error;

pub const Repository = struct {
    arena: std.mem.Allocator,
    db: *driver.Db,
    /// Error text for the failure, which the handler puts in its 500 body.
    /// Go returns these as plain errors and ServeHTTP wraps them in
    /// errInternalError.
    message: []const u8 = "",

    /// Appends `rows` to `project.dataset.table`. `fields` is the table's
    /// stored BigQuery schema; every one of them is bound for every row, so a
    /// row missing a key writes NULL there — Go AddTableData:535.
    pub fn addTableData(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
        fields: []const std.json.Value,
        rows: []const std.json.Value,
    ) Error!void {
        // Go returns before touching the connection at all.
        if (rows.len == 0) return;

        const sql = try r.insertSql(project_id, dataset_id, table_id, fields);
        var stmt = r.db.prepare(sql, .{}) catch return r.failEngine();
        defer stmt.deinit();

        // Go runs the whole batch in one transaction and rolls back on any
        // failure (conn.Begin + defer RollbackIfNotCommitted). It is also what
        // keeps this to a single fsync under WAL.
        r.db.rawExec("BEGIN", &.{}) catch return r.failEngine();
        errdefer r.db.rawExec("ROLLBACK", &.{}) catch {};

        const plans = try r.planFor(fields);
        const params = try r.arena.alloc(driver.Param, fields.len);
        var norm = rowvalue.Normalizer{ .arena = r.arena };
        for (rows) |row| {
            for (plans, 0..) |*plan, i| {
                params[i] = .{ .value = try r.cellFor(&norm, row, plan) };
            }
            stmt.exec(params) catch return r.failEngine();
        }

        r.db.rawExec("COMMIT", &.{}) catch return r.failEngine();
    }

    /// ``INSERT INTO `p.d.t` (`c1`,`c2`) VALUES (?,?)``.
    fn insertSql(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
        fields: []const std.json.Value,
    ) std.mem.Allocator.Error![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.print(r.arena, "INSERT INTO `{s}.{s}.{s}` (", .{
            project_id, dataset_id, table_id,
        });
        for (fields, 0..) |f, i| {
            if (i > 0) try out.append(r.arena, ',');
            try out.print(r.arena, "`{s}`", .{rowvalue.stringOf(f, "name")});
        }
        try out.appendSlice(r.arena, ") VALUES (");
        for (0..fields.len) |i| {
            if (i > 0) try out.append(r.arena, ',');
            try out.append(r.arena, '?');
        }
        try out.append(r.arena, ')');
        return out.toOwnedSlice(r.arena);
    }

    /// Everything `cellFor` needs from a column's schema node, read once per
    /// insert instead of once per cell.
    ///
    /// `name`, `type`, `mode` and `fields` are all constant for a column, yet
    /// resolving them inside the row loop meant four of the five hash lookups
    /// each cell performed were re-deriving the same answer — 1.8M redundant
    /// lookups on an 18k-row, 25-column batch, and 55% of cellFor's time.
    /// Only the row lookup itself genuinely varies. Same fix as the field-name
    /// set in tabledata.validateAgainstSchema.
    const ColumnPlan = struct {
        /// The key to read from each posted row.
        name: []const u8,
        /// Which of Go's three string coercions this column takes, if any.
        coercion: enum { none, timestamp, json, bytes },
        /// Normalizer inputs for everything the coercions do not claim.
        mode: []const u8,
        sub_fields: []const std.json.Value,
    };

    fn planFor(
        r: *Repository,
        fields: []const std.json.Value,
    ) std.mem.Allocator.Error![]const ColumnPlan {
        const plans = try r.arena.alloc(ColumnPlan, fields.len);
        for (fields, 0..) |field, i| {
            const type_name = rowvalue.stringOf(field, "type");
            plans[i] = .{
                .name = rowvalue.stringOf(field, "name"),
                .coercion = if (std.mem.eql(u8, type_name, "TIMESTAMP"))
                    .timestamp
                else if (std.mem.eql(u8, type_name, "JSON"))
                    .json
                else if (std.mem.eql(u8, type_name, "BYTES"))
                    .bytes
                else
                    .none,
                .mode = rowvalue.stringOf(field, "mode"),
                .sub_fields = rowvalue.fieldsOf(field),
            };
        }
        return plans;
    }

    /// One column's bound value: the three string coercions Go applies in
    /// AddTableData (:496-532), then normalizeData for everything else.
    ///
    /// Like Go, the coercions look only at the column's own type and only
    /// fire when the posted value is a string — so an ARRAY<BYTES> element or
    /// a BYTES field nested in a RECORD is *not* base64-decoded.
    fn cellFor(
        r: *Repository,
        norm: *rowvalue.Normalizer,
        row: std.json.Value,
        plan: *const ColumnPlan,
    ) Error!driver.Cell {
        if (row != .object) return .null;
        const v = row.object.get(plan.name) orelse return .null;

        if (v == .string) switch (plan.coercion) {
            .timestamp => {
                // Go: TimeFromTimestampValue, and on failure it binds the raw
                // string — CastValue's ToTime then handles the RFC3339 and
                // "YYYY-MM-DD HH:MM:SS" spellings that this one does not.
                if (timeFromTimestampValue(v.string)) |micros| {
                    var buf: [40]u8 = undefined;
                    return .{
                        .timestamp = try r.arena.dupe(
                            u8,
                            value.formatTimestampApi(&buf, micros),
                        ),
                    };
                } else |_| {}
            },
            .json => {
                _ = std.json.parseFromSliceLeaky(
                    std.json.Value,
                    r.arena,
                    v.string,
                    .{},
                ) catch {
                    r.message = try std.fmt.allocPrint(
                        r.arena,
                        "failed to unmarshal json value [{s}]",
                        .{v.string},
                    );
                    return error.InvalidJsonValue;
                };
                // The payload binds as JSON, not as a quoted string.
                return .{ .json = v.string };
            },
            .bytes => {
                // BigQuery's JSON API carries BYTES base64-encoded, so the
                // stored value is the decoded bytes; encoding them again is
                // the double-encoding bug PR #55 fixed.
                if (v.string.len == 0) return .{ .bytes = "" };
                const decoder = std.base64.standard.Decoder;
                const decoded = blk: {
                    const n = decoder.calcSizeForSlice(v.string) catch break :blk null;
                    const buf = try r.arena.alloc(u8, n);
                    decoder.decode(buf, v.string) catch break :blk null;
                    break :blk buf;
                };
                if (decoded) |b| return .{ .bytes = b };
                r.message = try std.fmt.allocPrint(
                    r.arena,
                    "failed to decode base64 bytes: {s}",
                    .{v.string},
                );
                return error.InvalidBase64Value;
            },
            .none => {},
        };

        return norm.cellForShape(v, plan.mode, plan.sub_fields) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => {
                r.message = norm.message;
                return error.InvalidRowValue;
            },
        };
    }

    fn failEngine(r: *Repository) Error {
        r.message = r.arena.dupe(u8, r.db.lastError()) catch "insert failed";
        return error.InsertFailed;
    }
};

/// Go zetasqlite.TimeFromTimestampValue (timestamp.go:12): epoch
/// "seconds[.micros]" text. Reproduces its quirk of computing a zero-padded
/// fraction and then parsing the *unpadded* one, so ".5" is 5 microseconds
/// rather than 500000 — the inverse of the "sec.rem" form the emulator emits.
fn timeFromTimestampValue(s: []const u8) !i64 {
    const dot = std.mem.indexOfScalar(u8, s, '.');
    const sec_text = if (dot) |i| s[0..i] else s;
    const seconds = try std.fmt.parseInt(i64, sec_text, 10);
    var micros: i64 = 0;
    if (dot) |i| {
        const frac = s[i + 1 ..];
        // Go's strings.Split gives more than two parts for a second '.'.
        if (std.mem.indexOfScalar(u8, frac, '.') != null) return error.InvalidTimestamp;
        micros = try std.fmt.parseInt(i64, frac, 10);
    }
    return seconds * value.second_micros + micros;
}

const testing = std.testing;

fn parse(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

fn rowsOf(arena: std.mem.Allocator, text: []const u8) ![]const std.json.Value {
    return (try parse(arena, text)).array.items;
}

fn fieldsOf(arena: std.mem.Allocator, text: []const u8) ![]const std.json.Value {
    return (try parse(arena, text)).array.items;
}

/// Creates `p.d.t` from a schema, inserts `rows`, and hands back the db.
fn insertInto(
    arena: std.mem.Allocator,
    db: *driver.Db,
    ddl: []const u8,
    fields_json: []const u8,
    rows_json: []const u8,
) !void {
    try db.exec(ddl, &.{}, .{});
    var repo = Repository{ .arena = arena, .db = db };
    repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, fields_json),
        try rowsOf(arena, rows_json),
    ) catch |err| {
        std.debug.print("addTableData failed: {t} — {s}\n", .{ err, repo.message });
        return err;
    };
}

test "a batch of rows lands, with absent keys as NULL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try insertInto(
        arena,
        db,
        "CREATE TABLE `p.d.t` (`i` INT64, `s` STRING)",
        \\[{"name":"i","type":"INTEGER"},{"name":"s","type":"STRING"}]
    ,
        // Row 2 omits `s` entirely — Go binds nil for it.
        \\[{"i":"1","s":"a"},{"i":"2"},{"i":"3","s":"c"}]
    );

    var rows = try db.query("SELECT i, s FROM `p.d.t` ORDER BY i", &.{}, .{});
    defer rows.deinit();
    const r1 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 1), r1[0].int);
    try testing.expectEqualStrings("a", r1[1].string);
    const r2 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 2), r2[0].int);
    try testing.expectEqual(driver.Cell.null, r2[1]);
    const r3 = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 3), r3[0].int);
}

test "an empty row list writes nothing and touches no connection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`i` INT64)", &.{}, .{});

    var repo = Repository{ .arena = arena, .db = db };
    try repo.addTableData("p", "d", "t", &.{}, &.{});

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "INT64 posted as JSON text stores as a number" {
    // What google-cloud-bigquery actually sends: _int_to_json stringifies.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try insertInto(
        arena,
        db,
        "CREATE TABLE `p.d.t` (`i` INT64)",
        \\[{"name":"i","type":"INTEGER"}]
    ,
        \\[{"i":"10"},{"i":"9"},{"i":"2"}]
    );

    var rows = try db.query("SELECT SUM(i), MAX(i) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 21), row[0].int);
    try testing.expectEqual(@as(i64, 10), row[1].int);
}

test "TIMESTAMP accepts both the epoch form and RFC3339" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // The first goes through Go's TimeFromTimestampValue; the second fails
    // that and falls through to CastValue's ToTime, as in Go.
    try insertInto(
        arena,
        db,
        "CREATE TABLE `p.d.t` (`k` INT64, `ts` TIMESTAMP)",
        \\[{"name":"k","type":"INTEGER"},{"name":"ts","type":"TIMESTAMP"}]
    ,
        \\[{"k":1,"ts":"1704164645.0"},{"k":2,"ts":"2024-01-02T03:04:05.000000"}]
    );

    var rows = try db.query("SELECT ts FROM `p.d.t` ORDER BY k", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("1704164645.0", (try rows.next()).?[0].timestamp);
    try testing.expectEqualStrings("1704164645.0", (try rows.next()).?[0].timestamp);
}

test "BYTES are base64-decoded exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // bytes_field_test.go: "Hello" -> SGVsbG8=, and reading it back must give
    // that same string, not base64(base64(...)).
    try insertInto(
        arena,
        db,
        "CREATE TABLE `p.d.t` (`k` INT64, `b` BYTES)",
        \\[{"name":"k","type":"INTEGER"},{"name":"b","type":"BYTES"}]
    ,
        \\[{"k":1,"b":"SGVsbG8="},{"k":2,"b":""},{"k":3,"b":null}]
    );

    var rows = try db.query("SELECT b, TO_BASE64(b) FROM `p.d.t` ORDER BY k", &.{}, .{});
    defer rows.deinit();
    const r1 = (try rows.next()).?;
    try testing.expectEqualStrings("SGVsbG8=", r1[0].string);
    try testing.expectEqualStrings("SGVsbG8=", r1[1].string);
    const r2 = (try rows.next()).?;
    try testing.expectEqualStrings("", r2[0].string);
    try testing.expectEqual(driver.Cell.null, (try rows.next()).?[0]);
}

test "a JSON column stores the document, not a quoted string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // server_test.go TestJson posts the column as a JSON *string*.
    try insertInto(
        arena,
        db,
        "CREATE TABLE `p.d.t` (`j` JSON)",
        \\[{"name":"j","type":"JSON"}]
    ,
        \\[{"j":"{\"a_date\":\"2024-01-01\",\"b_float\":1.2,\"c\":{\"test\":\"v\"}}"}]
    );

    var rows = try db.query(
        "SELECT JSON_VALUE(j, '$.a_date'), JSON_VALUE(j, '$.c.test') FROM `p.d.t`",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqualStrings("2024-01-01", row[0].string);
    try testing.expectEqualStrings("v", row[1].string);
}

test "unparseable JSON is Go's error, and nothing is written" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`j` JSON)", &.{}, .{});

    var repo = Repository{ .arena = arena, .db = db };
    try testing.expectError(error.InvalidJsonValue, repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, "[{\"name\":\"j\",\"type\":\"JSON\"}]"),
        try rowsOf(arena, "[{\"j\":\"{not json\"}]"),
    ));
    try testing.expectEqualStrings(
        "failed to unmarshal json value [{not json]",
        repo.message,
    );
}

test "bad base64 for a BYTES column is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`b` BYTES)", &.{}, .{});

    var repo = Repository{ .arena = arena, .db = db };
    try testing.expectError(error.InvalidBase64Value, repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, "[{\"name\":\"b\",\"type\":\"BYTES\"}]"),
        try rowsOf(arena, "[{\"b\":\"not base64!\"}]"),
    ));
    try testing.expect(std.mem.startsWith(u8, repo.message, "failed to decode base64 bytes:"));
}

test "ARRAY and STRUCT columns round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try insertInto(
        arena,
        db,
        "CREATE TABLE `p.d.t` (`xs` ARRAY<INT64>, `s` STRUCT<`a` INT64, `b` STRING>)",
        \\[{"name":"xs","type":"INTEGER","mode":"REPEATED"},
        \\ {"name":"s","type":"RECORD","fields":[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"}]}]
    ,
        // Struct keys deliberately reversed: the schema decides the order.
        \\[{"xs":[1,2,3],"s":{"b":"x","a":7}}]
    );

    var rows = try db.query(
        "SELECT ARRAY_LENGTH(xs), xs[OFFSET(2)], s.a, s.b FROM `p.d.t`",
        &.{},
        .{},
    );
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqual(@as(i64, 3), row[0].int);
    try testing.expectEqual(@as(i64, 3), row[1].int);
    try testing.expectEqual(@as(i64, 7), row[2].int);
    try testing.expectEqualStrings("x", row[3].string);
}

test "an empty REPEATED value stays empty" {
    // goccy #137, covered by the node suite's emptyArrayRepeated tests.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try insertInto(
        arena,
        db,
        "CREATE TABLE `p.d.t` (`items` ARRAY<STRING>)",
        \\[{"name":"items","type":"STRING","mode":"REPEATED"}]
    ,
        \\[{"items":[]}]
    );

    var rows = try db.query("SELECT ARRAY_LENGTH(items) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "a failed row rolls the whole batch back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`i` INT64)", &.{}, .{});

    // The second row's value cannot be cast to INT64, so it fails mid-batch.
    var repo = Repository{ .arena = arena, .db = db };
    try testing.expectError(error.InsertFailed, repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, "[{\"name\":\"i\",\"type\":\"INTEGER\"}]"),
        try rowsOf(arena, "[{\"i\":1},{\"i\":\"not a number\"}]"),
    ));

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "TimeFromTimestampValue keeps Go's unpadded fraction" {
    try testing.expectEqual(@as(i64, 1_704_164_645_000_000), try timeFromTimestampValue("1704164645.0"));
    // Go computes a padded string and then parses the unpadded one; ".5" is
    // therefore 5 microseconds, not 500000.
    try testing.expectEqual(@as(i64, 1_000_005), try timeFromTimestampValue("1.5"));
    try testing.expectEqual(@as(i64, 7_000_000), try timeFromTimestampValue("7"));
    try testing.expectError(error.InvalidCharacter, timeFromTimestampValue("2024-01-02T03:04:05Z"));
}
