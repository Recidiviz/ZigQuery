//! The row-write half of the content store: tabledata.insertAll's rows into a table's storage.
//! https://cloud.google.com/bigquery/docs/reference/rest/v2/tabledata/insertAll
//!
//! A prepared `INSERT INTO <table> (cols) VALUES (?, ...)` runs once per row inside a single
//! transaction: the statement is analyzed once per batch, and the batch costs one fsync under WAL.
//!  The table is named in full, so resolution needs no connection-wide default project or dataset.
//!
//! Every schema column is bound for every row; a row missing a key writes NULL there.
//! A value its column will not take marks the row invalid (`RowError`, carrying the column name and
//!  the engine's message). That includes a NULL the engine's own NOT NULL rejects at step time, so
//!  a column that is NOT NULL in storage but not REQUIRED in the stored schema still yields an
//!  invalid row rather than an engine failure.
//! The batch rolls back when any row is invalid, unless `skip_invalid_rows` is true. WHen true, the
//! only the valid rows will commit.

const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const value = zigquery.value;
const rowvalue = @import("../types/rowvalue.zig");

pub const Error = error{
    /// The engine rejected the INSERT (prepare, transaction control, or a step
    /// that failed for a reason other than a value conversion).
    InsertFailed,
} || std.mem.Allocator.Error;

/// tabledata.insertAll's two switches, both false by default.
pub const Options = struct {
    /// Write the rows that are valid (known field and valid encoding);
    /// Otherwise one invalid row will roll the batch back.
    skip_invalid_rows: bool = false,
    /// Drop a member the schema does not declare; without it the row is marked invalid.
    ignore_unknown_values: bool = false,
};

/// What `addTableData` reports back.
pub const AddTableDataResult = struct {
    /// One entry per row whose values the columns would not take, in row
    /// order. Empty when every row landed. Mutable so a caller that wrote a
    /// subset of a posted batch can restore the posted indices.
    invalid: []RowError = &.{},
};

/// A value the column would not take, and which row and column it sat in.
pub const RowError = struct {
    row_index: u32,
    field_name: []const u8,
    /// The engine's text, e.g. "failed to convert 202-06-06".
    message: []const u8,
};

/// A row value that could not be shaped to its column before binding.
const CellError = error{
    /// See Normalizer.
    InvalidRowValue,
    /// Go: "failed to unmarshal json value [%s]: %w".
    InvalidJsonValue,
    /// Go: "failed to decode base64 bytes: %v - %w".
    InvalidBase64Value,
} || std.mem.Allocator.Error;

pub const Repository = struct {
    arena: std.mem.Allocator,
    db: *driver.Db,
    /// Error text for the failure, which the handler puts in its 500 body.
    message: []const u8 = "",

    /// Appends `rows` to `project.dataset.table`.
    ///`fields` is the table's stored BigQuery schema; every one of them is bound for every row,
    /// so a row missing a key writes NULL there
    ///
    pub fn addTableData(
        r: *Repository,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
        fields: []const std.json.Value,
        rows: []const std.json.Value,
        options: Options,
    ) Error!AddTableDataResult {
        // Go returns before touching the connection at all.
        if (rows.len == 0) return .{};

        const sql = try r.insertSql(project_id, dataset_id, table_id, fields);
        var stmt = r.db.prepare(sql, .{}) catch return r.failEngine();
        defer stmt.deinit();

        // Go runs the whole batch in one transaction and rolls back on any
        // failure (conn.Begin + defer RollbackIfNotCommitted). It is also what
        // keeps this to a single fsync under WAL.
        r.db.rawExec("BEGIN", &.{}) catch return r.failEngine();
        errdefer r.db.rawExec("ROLLBACK", &.{}) catch {};

        var batch = Batch{
            .repo = r,
            .stmt = &stmt,
            .plans = try r.planFor(fields),
            .params = try r.arena.alloc(driver.Param, fields.len),
            .normalizer = .{ .arena = r.arena, .ignore_unknown = options.ignore_unknown_values },
        };
        for (rows, 0..) |row, row_index| try batch.add(row, @intCast(row_index));

        if (batch.invalid.items.len > 0 and !options.skip_invalid_rows) {
            r.db.rawExec("ROLLBACK", &.{}) catch return r.failEngine();
        } else {
            r.db.rawExec("COMMIT", &.{}) catch return r.failEngine();
        }
        return .{ .invalid = batch.invalid.items };
    }

    /// The prepared INSERT and everything one row's bind needs.
    const Batch = struct {
        repo: *Repository,
        stmt: *driver.PreparedStmt,
        plans: []const ColumnPlan,
        /// One slot per column, rebound for every row.
        params: []driver.Param,
        normalizer: rowvalue.Normalizer,
        invalid: std.ArrayList(RowError) = .empty,

        /// Binds and executes one row, or records why it could not be.
        fn add(batch: *Batch, row: std.json.Value, row_index: u32) Error!void {
            for (batch.plans, 0..) |*plan, i| {
                const repo = batch.repo;
                const cell = repo.cellFor(&batch.normalizer, row, plan) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return batch.reject(row_index, plan.name, repo.message),
                };
                // An absent key and an explicit null are the same NULL.
                if (plan.required and cell == .null) {
                    const message = try rowvalue.missingRequiredMessage(repo.arena, &.{plan.name});
                    return batch.reject(row_index, plan.name, message);
                }
                batch.params[i] = .{ .value = cell };
            }
            batch.stmt.exec(batch.params) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // The bind cast rejected a value. The statement binds one placeholder per column in
                // schema order, so the placeholder names the column.
                error.DecodeFailed => {
                    const ordinal = batch.repo.db.lastErrorParam() orelse return batch.repo.failEngine();
                    const message = try batch.repo.arena.dupe(u8, batch.repo.db.lastError());
                    return batch.reject(row_index, batch.plans[@intCast(ordinal - 1)].name, message);
                },
                error.ExecFailed => switch (batch.stepFailure()) {
                    .not_null => |plan| {
                        const arena = batch.repo.arena;
                        const message = try rowvalue.missingRequiredMessage(arena, &.{plan.name});
                        return batch.reject(row_index, plan.name, message);
                    },
                    .missing_required => |found| {
                        const arena = batch.repo.arena;
                        const column = found.plan.name;
                        const segments = try streamingPathSegments(arena, column, found.path);
                        const message = try rowvalue.missingRequiredMessage(arena, segments);
                        return batch.reject(row_index, found.plan.name, message);
                    },
                    .engine => return batch.repo.failEngine(),
                },
                else => return batch.repo.failEngine(),
            };
        }

        /// Why the step failed.
        const StepFailure = union(enum) {
            /// SQLite's NOT NULL rejected the row; the column it names.
            not_null: *const ColumnPlan,
            /// The CHECK behind a NOT NULL STRUCT member rejected the row;
            /// contains the column it names, and the dotted path of the member.
            missing_required: struct { plan: *const ColumnPlan, path: []const u8 },
            /// Anything else, which is the engine's failure, not the row's.
            engine,
        };

        fn stepFailure(batch: *Batch) StepFailure {
            const err_text = batch.repo.db.lastError();
            if (zigquery.spec.requiredFieldFromMessage(err_text)) |found| {
                const plan = batch.planNamed(found.column) orelse return .engine;
                return .{ .missing_required = .{ .plan = plan, .path = found.path } };
            }
            const column = zigquery.spec.notNullColumnFromMessage(err_text) orelse return .engine;
            const plan = batch.planNamed(column) orelse return .engine;
            return .{ .not_null = plan };
        }

        fn planNamed(batch: *Batch, name: []const u8) ?*const ColumnPlan {
            for (batch.plans) |*plan| {
                if (std.mem.eql(u8, plan.name, name)) return plan;
            }
            return null;
        }

        fn reject(
            batch: *Batch,
            row_index: u32,
            field_name: []const u8,
            message: []const u8,
        ) Error!void {
            try batch.invalid.append(batch.repo.arena, .{
                .row_index = row_index,
                .field_name = field_name,
                .message = message,
            });
        }
    };

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
        /// REQUIRED: NULL is an invalid row.
        required: bool,
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
                .required = std.mem.eql(u8, rowvalue.stringOf(field, "mode"), "REQUIRED"),
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
    ) CellError!driver.Cell {
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

        // The column heads the path a nested failure reports.
        try norm.path.append(r.arena, plan.name);
        defer _ = norm.path.pop();
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

/// The column, then each member of the dotted `path` below it. The column is
/// taken whole, since its own name may contain a `.`.
fn streamingPathSegments(
    arena: std.mem.Allocator,
    column: []const u8,
    path: []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var segments: std.ArrayList([]const u8) = .empty;
    try segments.append(arena, column);
    const below = if (path.len > column.len and std.mem.startsWith(u8, path, column) and
        path[column.len] == '.')
        path[column.len + 1 ..]
    else
        path;
    var it = std.mem.splitScalar(u8, below, '.');
    while (it.next()) |segment| try segments.append(arena, segment);
    return segments.toOwnedSlice(arena);
}

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
    const result = repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, fields_json),
        try rowsOf(arena, rows_json),
        .{},
    ) catch |err| {
        std.debug.print("addTableData failed: {t} — {s}\n", .{ err, repo.message });
        return err;
    };
    const invalid = result.invalid;
    if (invalid.len > 0) {
        std.debug.print("row {d} rejected at {s}: {s}\n", .{
            invalid[0].row_index, invalid[0].field_name, invalid[0].message,
        });
        return error.InvalidRow;
    }
}

test "a batch of rows lands, with absent keys as NULL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try insertInto(arena, db, "CREATE TABLE `p.d.t` (`i` INT64, `s` STRING)",
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
    const result = try repo.addTableData("p", "d", "t", &.{}, &.{}, .{});
    try testing.expectEqual(@as(usize, 0), result.invalid.len);

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

    try insertInto(arena, db, "CREATE TABLE `p.d.t` (`i` INT64)",
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
    try insertInto(arena, db, "CREATE TABLE `p.d.t` (`k` INT64, `ts` TIMESTAMP)",
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
    try insertInto(arena, db, "CREATE TABLE `p.d.t` (`k` INT64, `b` BYTES)",
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
    try insertInto(arena, db, "CREATE TABLE `p.d.t` (`j` JSON)",
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
    const result = try repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, "[{\"name\":\"j\",\"type\":\"JSON\"}]"),
        try rowsOf(arena, "[{\"j\":\"{not json\"}]"),
        .{},
    );
    const invalid = result.invalid;
    try testing.expectEqual(@as(usize, 1), invalid.len);
    try testing.expectEqual(@as(u32, 0), invalid[0].row_index);
    try testing.expectEqualStrings("j", invalid[0].field_name);
    try testing.expectEqualStrings(
        "failed to unmarshal json value [{not json]",
        invalid[0].message,
    );

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "bad base64 for a BYTES column is an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`b` BYTES)", &.{}, .{});

    var repo = Repository{ .arena = arena, .db = db };
    const result = try repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, "[{\"name\":\"b\",\"type\":\"BYTES\"}]"),
        try rowsOf(arena, "[{\"b\":\"not base64!\"}]"),
        .{},
    );
    const invalid = result.invalid;
    try testing.expectEqual(@as(usize, 1), invalid.len);
    try testing.expectEqualStrings("b", invalid[0].field_name);
    try testing.expect(std.mem.startsWith(u8, invalid[0].message, "failed to decode base64 bytes:"));
}

test "ARRAY and STRUCT columns round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try insertInto(arena, db, "CREATE TABLE `p.d.t` (`xs` ARRAY<INT64>, `s` STRUCT<`a` INT64, `b` STRING>)",
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

    try insertInto(arena, db, "CREATE TABLE `p.d.t` (`items` ARRAY<STRING>)",
        \\[{"name":"items","type":"STRING","mode":"REPEATED"}]
    ,
        \\[{"items":[]}]
    );

    var rows = try db.query("SELECT ARRAY_LENGTH(items) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "a value the column will not take names its row and column, and rolls the batch back" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`i` INT64, `d` DATE)", &.{}, .{});

    const fields = try fieldsOf(arena,
        \\[{"name":"i","type":"INTEGER"},{"name":"d","type":"DATE"}]
    );
    // Row 1 fails at the bind cast of the second column; row 2 at the first.
    // Every invalid row is reported, not just the first one hit.
    var repo = Repository{ .arena = arena, .db = db };
    const result = try repo.addTableData("p", "d", "t", fields, try rowsOf(arena,
        \\[{"i":1,"d":"2024-01-02"},{"i":2,"d":"202-06-06"},{"i":"not a number"},{"i":4}]
    ), .{});
    const invalid = result.invalid;
    try testing.expectEqual(@as(usize, 2), invalid.len);
    try testing.expectEqual(@as(u32, 1), invalid[0].row_index);
    try testing.expectEqualStrings("d", invalid[0].field_name);
    // big_query_emulator_test.py test_invalid_data_load_fails matches this text.
    try testing.expectEqualStrings("failed to convert 202-06-06 to time.Time type", invalid[0].message);
    try testing.expectEqual(@as(u32, 2), invalid[1].row_index);
    try testing.expectEqualStrings("i", invalid[1].field_name);
    try testing.expectEqualStrings("Bad int64 value: not a number", invalid[1].message);

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "NULL in a REQUIRED column is an invalid row, key absent or explicit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`a` STRING NOT NULL, `b` STRING)", &.{}, .{});

    const fields = try fieldsOf(arena,
        \\[{"name":"a","type":"STRING","mode":"REQUIRED"},{"name":"b","type":"STRING"}]
    );
    var repo = Repository{ .arena = arena, .db = db };
    const result = try repo.addTableData("p", "d", "t", fields, try rowsOf(arena,
        \\[{"a":"ok","b":null},{"a":null,"b":"x"},{"b":"y"}]
    ), .{});
    const invalid = result.invalid;
    try testing.expectEqual(@as(usize, 2), invalid.len);
    try testing.expectEqual(@as(u32, 1), invalid[0].row_index);
    try testing.expectEqualStrings("a", invalid[0].field_name);
    try testing.expectEqualStrings(
        "Missing required field: Msg_0_CLOUD_QUERY_TABLE.a.",
        invalid[0].message,
    );
    try testing.expectEqual(@as(u32, 2), invalid[1].row_index);
    try testing.expectEqualStrings("a", invalid[1].field_name);

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "a REQUIRED member of a RECORD is checked inside the value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`r` STRUCT<`x` INT64, `y` STRING>)", &.{}, .{});

    const fields = try fieldsOf(arena,
        \\[{"name":"r","type":"RECORD","fields":[
        \\  {"name":"x","type":"INTEGER","mode":"REQUIRED"},{"name":"y","type":"STRING"}]}]
    );
    var repo = Repository{ .arena = arena, .db = db };
    const result = try repo.addTableData("p", "d", "t", fields, try rowsOf(arena,
        \\[{"r":{"x":1}},{"r":{"y":"no x"}},{"r":{"x":null,"y":"z"}}]
    ), .{ .skip_invalid_rows = true });
    const invalid = result.invalid;
    try testing.expectEqual(@as(usize, 2), invalid.len);
    try testing.expectEqual(@as(u32, 1), invalid[0].row_index);
    try testing.expectEqualStrings("r", invalid[0].field_name);
    try testing.expectEqualStrings(
        "Missing required field: Msg_0_CLOUD_QUERY_TABLE.r.x.",
        invalid[0].message,
    );
    try testing.expectEqual(@as(u32, 2), invalid[1].row_index);

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?[0].int);
}

test "a NOT NULL the stored schema does not declare is still an invalid row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    // The table says NOT NULL; the schema the rows are checked against does
    // not, as after a materialization job re-derived it from a query.
    try db.exec("CREATE TABLE `p.d.t` (`a` STRING NOT NULL, `b` STRING)", &.{}, .{});

    const fields = try fieldsOf(arena,
        \\[{"name":"a","type":"STRING"},{"name":"b","type":"STRING"}]
    );
    var repo = Repository{ .arena = arena, .db = db };
    const rows = try rowsOf(arena,
        \\[{"a":"ok","b":null},{"a":null,"b":"x"},{"b":"y"},{"a":"also ok"}]
    );

    const all = try repo.addTableData("p", "d", "t", fields, rows, .{});
    try testing.expectEqual(@as(usize, 2), all.invalid.len);
    try testing.expectEqual(@as(u32, 1), all.invalid[0].row_index);
    try testing.expectEqualStrings("a", all.invalid[0].field_name);
    try testing.expectEqualStrings(
        "Missing required field: Msg_0_CLOUD_QUERY_TABLE.a.",
        all.invalid[0].message,
    );
    try testing.expectEqual(@as(u32, 2), all.invalid[1].row_index);
    try testing.expectEqualStrings("a", all.invalid[1].field_name);
    {
        var count = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
        defer count.deinit();
        try testing.expectEqual(@as(i64, 0), (try count.next()).?[0].int);
    }

    // The statement-level ABORT leaves the transaction open, so with
    // skip_invalid_rows the rows after a rejected one still land.
    const skipping: Options = .{ .skip_invalid_rows = true };
    const skipped = try repo.addTableData("p", "d", "t", fields, rows, skipping);
    try testing.expectEqual(@as(usize, 2), skipped.invalid.len);
    var kept = try db.query("SELECT a FROM `p.d.t` ORDER BY a", &.{}, .{});
    defer kept.deinit();
    try testing.expectEqualStrings("also ok", (try kept.next()).?[0].string);
    try testing.expectEqualStrings("ok", (try kept.next()).?[0].string);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try kept.next());
}

test "a NOT NULL STRUCT member the stored schema does not declare is still an invalid row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    // A registered table whose SQLite object carries the CHECK spec.zig renders
    // for `r STRUCT<x INT64 NOT NULL>`, while the posted schema says nothing
    // about it.
    try db.exec("CREATE TABLE `p.d.t` (`r` STRUCT<`x` INT64, `y` STRING>)", &.{}, .{});
    try db.rawExec("DROP TABLE `p_d_t`", &.{});
    try db.rawExec(
        "CREATE TABLE `p_d_t` (`r` TEXT, CONSTRAINT `r` CHECK (zigquery_required(`r`," ++
            "'0','Required field r.x cannot be null; error in writing field r')))",
        &.{},
    );

    const fields = try fieldsOf(arena,
        \\[{"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"},{"name":"y","type":"STRING"}]}]
    );
    var repo = Repository{ .arena = arena, .db = db };
    const result = try repo.addTableData("p", "d", "t", fields, try rowsOf(arena,
        \\[{"r":{"x":1,"y":"a"}},{"r":{"y":"no x"}},{"r":null}]
    ), .{ .skip_invalid_rows = true });
    try testing.expectEqual(@as(usize, 1), result.invalid.len);
    try testing.expectEqual(@as(u32, 1), result.invalid[0].row_index);
    try testing.expectEqualStrings("r", result.invalid[0].field_name);
    try testing.expectEqualStrings(
        "Missing required field: Msg_0_CLOUD_QUERY_TABLE.r.x.",
        result.invalid[0].message,
    );

    var rows = try db.query("SELECT COUNT(*) FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 2), (try rows.next()).?[0].int);
}

test "streamingPathSegments keeps a dotted column name as one segment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain = try streamingPathSegments(arena, "r", "r.inner.y");
    try testing.expectEqual(@as(usize, 3), plain.len);
    try testing.expectEqualStrings("r", plain[0]);
    try testing.expectEqualStrings("inner", plain[1]);
    try testing.expectEqualStrings("y", plain[2]);
    const dotted = try streamingPathSegments(arena, "a.b", "a.b.x");
    try testing.expectEqual(@as(usize, 2), dotted.len);
    try testing.expectEqualStrings("a.b", dotted[0]);
    try testing.expectEqualStrings("x", dotted[1]);
}

test "ignore_unknown_values drops an undeclared RECORD member; without it the row is invalid" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`r` STRUCT<`x` INT64>)", &.{}, .{});

    const fields = try fieldsOf(arena,
        \\[{"name":"r","type":"RECORD","fields":[{"name":"x","type":"INTEGER"}]}]
    );
    var repo = Repository{ .arena = arena, .db = db };
    const rejected = try repo.addTableData("p", "d", "t", fields, try rowsOf(arena,
        \\[{"r":{"x":1,"zzz":2}}]
    ), .{});
    try testing.expectEqual(@as(usize, 1), rejected.invalid.len);
    try testing.expectEqualStrings("failed to find value from zzz", rejected.invalid[0].message);

    const kept = try repo.addTableData("p", "d", "t", fields, try rowsOf(arena,
        \\[{"r":{"x":1,"zzz":2}}]
    ), .{ .ignore_unknown_values = true });
    try testing.expectEqual(@as(usize, 0), kept.invalid.len);

    var rows = try db.query("SELECT r.x FROM `p.d.t`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?[0].int);
}

test "skip_invalid_rows commits the rows that were fine" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.t` (`i` INT64)", &.{}, .{});

    var repo = Repository{ .arena = arena, .db = db };
    const result = try repo.addTableData(
        "p",
        "d",
        "t",
        try fieldsOf(arena, "[{\"name\":\"i\",\"type\":\"INTEGER\"}]"),
        try rowsOf(arena, "[{\"i\":1},{\"i\":\"x\"},{\"i\":3}]"),
        .{ .skip_invalid_rows = true },
    );
    const invalid = result.invalid;
    try testing.expectEqual(@as(usize, 1), invalid.len);
    try testing.expectEqual(@as(u32, 1), invalid[0].row_index);

    var rows = try db.query("SELECT i FROM `p.d.t` ORDER BY i", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 1), (try rows.next()).?[0].int);
    try testing.expectEqual(@as(i64, 3), (try rows.next()).?[0].int);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "TimeFromTimestampValue keeps Go's unpadded fraction" {
    try testing.expectEqual(@as(i64, 1_704_164_645_000_000), try timeFromTimestampValue("1704164645.0"));
    // Go computes a padded string and then parses the unpadded one; ".5" is
    // therefore 5 microseconds, not 500000.
    try testing.expectEqual(@as(i64, 1_000_005), try timeFromTimestampValue("1.5"));
    try testing.expectEqual(@as(i64, 7_000_000), try timeFromTimestampValue("7"));
    try testing.expectError(error.InvalidCharacter, timeFromTimestampValue("2024-01-02T03:04:05Z"));
}
