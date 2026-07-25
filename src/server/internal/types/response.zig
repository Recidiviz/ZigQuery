//! Port of bigquery-emulator internal/types/types.go — the wire shapes
//! TableRow/TableCell/QueryResponse and their JSON encoding.
//!
//! Three deviations from google-api-go-client's own structs are deliberate in
//! Go and load-bearing for clients, so they are reproduced exactly:
//!
//!   1. `"v": null` is EMITTED, never omitted. Go redefines TableCell purely
//!      for this (internal/types/types.go:50-51).
//!   2. `totalRows` is a JSON **string** (`json:"totalRows,string"`).
//!   3. Every scalar is rendered as a string via Go's fmt.Sprint
//!      (internal/contentdata/repository.go convertValueToCell) — see
//!      govalue.zig for the float rules that follow from this.
//!
//! Plus one from the query path: a NULL ARRAY is coerced to `[]`, because
//! "GoogleSQL for BigQuery translates a NULL array into an empty array"
//! (repository.go:271-274).
//!
//! All of it is verified byte-for-byte against a running Go emulator; see
//! testdata/golden.json and the tests below.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const govalue = @import("govalue.zig");
const schema = @import("schema.zig");
const spec = zetasqlite.spec;
const errors = @import("../../error.zig");

/// Writes one cell as `{"v":...}`.
pub fn writeCell(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cell: driver.Cell,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "{\"v\":");
    try writeCellValue(arena, out, cell);
    try out.append(arena, '}');
}

fn writeCellValue(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    cell: driver.Cell,
) std.mem.Allocator.Error!void {
    switch (cell) {
        .null => try out.appendSlice(arena, "null"),
        .int => |v| try errors.writeJsonString(arena, out, try govalue.formatInt(arena, v)),
        .float => |v| try errors.writeJsonString(arena, out, try govalue.formatFloat(arena, v)),
        .bool => |v| try errors.writeJsonString(arena, out, govalue.formatBool(v)),
        // BYTES arrive already base64-encoded and NUMERIC as decimal text,
        // both as .string from the driver — see driver.zig's Cell docs.
        .string,
        .bytes,
        .date,
        .timestamp,
        .datetime,
        .time,
        .interval,
        => |v| try errors.writeJsonString(arena, out, v),
        .array => |items| {
            try out.append(arena, '[');
            for (items, 0..) |item, i| {
                if (i > 0) try out.append(arena, ',');
                try writeCell(arena, out, item);
            }
            try out.append(arena, ']');
        },
        .struct_ => |fields| {
            try out.appendSlice(arena, "{\"f\":[");
            for (fields, 0..) |f, i| {
                if (i > 0) try out.append(arena, ',');
                try writeCell(arena, out, f.value);
            }
            try out.appendSlice(arena, "]}");
        },
    }
}

/// Writes one row as `{"f":[...]}`.
pub fn writeRow(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    row: []const driver.Cell,
) !void {
    try out.appendSlice(arena, "{\"f\":[");
    for (row, 0..) |cell, i| {
        if (i > 0) try out.append(arena, ',');
        try writeCell(arena, out, cell);
    }
    try out.appendSlice(arena, "]}");
}

/// Coerces a NULL whose declared type is ARRAY into an empty array.
///
/// Go does this while scanning rows, not while encoding: "GoogleSQL for
/// BigQuery translates a NULL array into an empty array"
/// (internal/contentdata/repository.go:271-274). It needs the column type, so
/// it cannot live in the cell encoder.
pub fn coerceNullArrays(
    arena: std.mem.Allocator,
    cell: driver.Cell,
    t: *const spec.Type,
) std.mem.Allocator.Error!driver.Cell {
    if (t.isArray()) {
        if (cell == .null) return .{ .array = &.{} };
        if (cell == .array) {
            const elem = t.element_type orelse return cell;
            const items = try arena.alloc(driver.Cell, cell.array.len);
            for (cell.array, 0..) |item, i| {
                items[i] = try coerceNullArrays(arena, item, elem);
            }
            return .{ .array = items };
        }
        return cell;
    }
    if (t.isStruct() and cell == .struct_) {
        const fields = try arena.alloc(driver.Cell.Field, cell.struct_.len);
        for (cell.struct_, 0..) |f, i| {
            const ft: *const spec.Type = if (i < t.field_types.len)
                (t.field_types[i].type orelse t)
            else
                t;
            fields[i] = .{ .name = f.name, .value = try coerceNullArrays(arena, f.value, ft) };
        }
        return .{ .struct_ = fields };
    }
    return cell;
}

/// Total length of a row's rendered cell strings.
///
/// Go accumulates this while converting values and reports it as
/// totalBytesProcessed / totalBytesBilled (contentdata/repository.go
/// convertValueToCell). NULLs and container brackets contribute nothing —
/// only the scalar text does.
pub fn renderedByteLen(
    arena: std.mem.Allocator,
    row: []const driver.Cell,
) std.mem.Allocator.Error!usize {
    var n: usize = 0;
    for (row) |cell| n += try cellByteLen(arena, cell);
    return n;
}

fn cellByteLen(arena: std.mem.Allocator, cell: driver.Cell) std.mem.Allocator.Error!usize {
    return switch (cell) {
        .null => 0,
        .int => |v| (try govalue.formatInt(arena, v)).len,
        .float => |v| (try govalue.formatFloat(arena, v)).len,
        .bool => |v| govalue.formatBool(v).len,
        .string, .bytes, .date, .timestamp, .datetime, .time, .interval => |v| v.len,
        .array => |items| blk: {
            var n: usize = 0;
            for (items) |it| n += try cellByteLen(arena, it);
            break :blk n;
        },
        .struct_ => |fields| blk: {
            var n: usize = 0;
            for (fields) |f| n += try cellByteLen(arena, f.value);
            break :blk n;
        },
    };
}

/// Applies coerceNullArrays across a whole row.
pub fn materializeRow(
    arena: std.mem.Allocator,
    row: []const driver.Cell,
    cols: []const driver.OutputColumn,
) std.mem.Allocator.Error![]const driver.Cell {
    const out = try arena.alloc(driver.Cell, row.len);
    for (row, 0..) |cell, i| {
        out[i] = if (i < cols.len)
            try coerceNullArrays(arena, cell, cols[i].type)
        else
            cell;
    }
    return out;
}

pub const QueryResponse = struct {
    project_id: []const u8,
    job_id: []const u8,
    cols: []const driver.OutputColumn,
    /// Materialized before serialization: the driver's Rows must be drained
    /// and deinited before the transaction commits.
    rows: []const []const driver.Cell,
    /// Always the full count, even when `rows` has been truncated by
    /// maxResults — matching Go, which reports totalRows independently.
    total_rows: usize,
};

/// Serializes the jobs.query / getQueryResults envelope.
///
/// Key order follows Go's struct declaration order in
/// internal/types/types.go: jobReference, schema, rows, totalRows,
/// jobComplete.
pub fn writeQueryResponse(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    res: QueryResponse,
) !void {
    try out.appendSlice(arena, "{\"jobReference\":{\"jobId\":");
    try errors.writeJsonString(arena, out, res.job_id);
    try out.appendSlice(arena, ",\"projectId\":");
    try errors.writeJsonString(arena, out, res.project_id);
    try out.appendSlice(arena, "},\"schema\":");
    try schema.writeSchema(arena, out, res.cols);

    try out.appendSlice(arena, ",\"rows\":[");
    for (res.rows, 0..) |row, i| {
        if (i > 0) try out.append(arena, ',');
        try writeRow(arena, out, row);
    }
    try out.appendSlice(arena, "]");

    // totalRows is a string on the wire.
    try out.appendSlice(arena, ",\"totalRows\":\"");
    try out.print(arena, "{d}", .{res.total_rows});
    try out.appendSlice(arena, "\",\"jobComplete\":true}");
}

const testing = std.testing;

/// Runs `sql` and serializes the full response, with a fixed job id so the
/// bytes are stable.
fn responseOf(arena: std.mem.Allocator, sql: []const u8) ![]const u8 {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(sql, &.{}, .{});
    defer rows.deinit();

    var collected: std.ArrayList([]const driver.Cell) = .empty;
    while (try rows.next()) |row| {
        try collected.append(arena, try materializeRow(arena, row, rows.columnTypes()));
    }

    var out: std.ArrayList(u8) = .empty;
    try writeQueryResponse(arena, &out, .{
        .project_id = "test",
        .job_id = "<JOBID>",
        .cols = rows.columnTypes(),
        .rows = collected.items,
        .total_rows = collected.items.len,
    });
    return out.toOwnedSlice(arena);
}

/// Each expectation below is the Go emulator's actual response with the
/// random jobId replaced by <JOBID> — see tools/capture_golden.py.
fn expectGolden(sql: []const u8, expected: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    try testing.expectEqualStrings(expected, try responseOf(arena_state.allocator(), sql));
}

test "scalar int matches the Go emulator byte for byte" {
    try expectGolden("SELECT 1 AS i",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"i","type":"INTEGER"}]},"rows":[{"f":[{"v":"1"}]}],"totalRows":"1","jobComplete":true}
    );
}

test "NULL emits \"v\":null rather than omitting the key" {
    try expectGolden("SELECT NULL AS n",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"n","type":"INTEGER"}]},"rows":[{"f":[{"v":null}]}],"totalRows":"1","jobComplete":true}
    );
}

test "booleans render as strings" {
    try expectGolden("SELECT TRUE AS b, FALSE AS b2",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"b","type":"BOOLEAN"},{"name":"b2","type":"BOOLEAN"}]},"rows":[{"f":[{"v":"true"},{"v":"false"}]}],"totalRows":"1","jobComplete":true}
    );
}

test "array elements are each wrapped in their own v" {
    try expectGolden("SELECT [1,2,3] AS arr",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"mode":"REPEATED","name":"arr","type":"INTEGER"}]},"rows":[{"f":[{"v":[{"v":"1"},{"v":"2"},{"v":"3"}]}]}],"totalRows":"1","jobComplete":true}
    );
}

test "a NULL array becomes an empty array" {
    try expectGolden("SELECT CAST(NULL AS ARRAY<INT64>) AS nullarr",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"mode":"REPEATED","name":"nullarr","type":"INTEGER"}]},"rows":[{"f":[{"v":[]}]}],"totalRows":"1","jobComplete":true}
    );
}

test "struct becomes a nested f array" {
    try expectGolden("SELECT STRUCT(1 AS a, 'x' AS b) AS s",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"fields":[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"}],"name":"s","type":"RECORD"}]},"rows":[{"f":[{"v":{"f":[{"v":"1"},{"v":"x"}]}}]}],"totalRows":"1","jobComplete":true}
    );
}

test "nested struct with a repeated struct field" {
    try expectGolden("SELECT STRUCT(1 AS a, [STRUCT(2 AS c)] AS b) AS s",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"fields":[{"name":"a","type":"INTEGER"},{"fields":[{"name":"c","type":"INTEGER"}],"mode":"REPEATED","name":"b","type":"RECORD"}],"name":"s","type":"RECORD"}]},"rows":[{"f":[{"v":{"f":[{"v":"1"},{"v":[{"v":{"f":[{"v":"2"}]}}]}]}}]}],"totalRows":"1","jobComplete":true}
    );
}

test "a NULL field inside a struct still emits null" {
    try expectGolden("SELECT STRUCT(NULL AS a, 'x' AS b) AS s, CAST(NULL AS STRING) AS ns",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"fields":[{"name":"a","type":"INTEGER"},{"name":"b","type":"STRING"}],"name":"s","type":"RECORD"},{"name":"ns","type":"STRING"}]},"rows":[{"f":[{"v":{"f":[{"v":null},{"v":"x"}]}},{"v":null}]}],"totalRows":"1","jobComplete":true}
    );
}

test "floats use Go's shortest-g formatting" {
    try expectGolden("SELECT 1.5 AS f, 1e21 AS big, -0.0 AS negz, 1e-7 AS small",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"f","type":"FLOAT"},{"name":"big","type":"FLOAT"},{"name":"negz","type":"FLOAT"},{"name":"small","type":"FLOAT"}]},"rows":[{"f":[{"v":"1.5"},{"v":"1e+21"},{"v":"-0"},{"v":"1e-07"}]}],"totalRows":"1","jobComplete":true}
    );
}

test "multiple rows and a string totalRows" {
    try expectGolden("SELECT x FROM UNNEST([1,2,3]) AS x ORDER BY x",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"x","type":"INTEGER"}]},"rows":[{"f":[{"v":"1"}]},{"f":[{"v":"2"}]},{"f":[{"v":"3"}]}],"totalRows":"3","jobComplete":true}
    );
}

test "date, timestamp and bytes use Go's renderings" {
    // TIMESTAMP is Go's "sec.rem" ApiString; BYTES are base64.
    try expectGolden("SELECT DATE '2024-01-02' AS d, TIMESTAMP '2024-01-02 03:04:05' AS ts, b'ab' AS raw",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"d","type":"DATE"},{"name":"ts","type":"TIMESTAMP"},{"name":"raw","type":"BYTES"}]},"rows":[{"f":[{"v":"2024-01-02"},{"v":"1704193445.0"},{"v":"YWI="}]}],"totalRows":"1","jobComplete":true}
    );
}

test "strings are JSON-escaped" {
    try expectGolden("SELECT 'a\"b' AS q, 'tab\there' AS t",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"q","type":"STRING"},{"name":"t","type":"STRING"}]},"rows":[{"f":[{"v":"a\"b"},{"v":"tab\there"}]}],"totalRows":"1","jobComplete":true}
    );
}

test "NUMERIC and BIGNUMERIC keep decimal text" {
    try expectGolden("SELECT CAST('1.2345' AS NUMERIC) AS n, CAST(1 AS BIGNUMERIC) AS bn",
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"n","type":"NUMERIC"},{"name":"bn","type":"BIGNUMERIC"}]},"rows":[{"f":[{"v":"1.2345"},{"v":"1"}]}],"totalRows":"1","jobComplete":true}
    );
}
