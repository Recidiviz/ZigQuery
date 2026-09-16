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
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const govalue = @import("govalue.zig");
const schema = @import("schema.zig");
const spec = zigquery.spec;
const value_mod = zigquery.value;
const bqpb = @import("../../proto/bigquery.zig");
const tablerow = @import("tablerow.zig");
const json_pb = @import("../../json_pb.zig");

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
        .string, .bytes, .json, .date, .timestamp, .datetime, .time, .interval, .range => |v| v.len,
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

/// Go internal/types.Format: under `formatOptions.useInt64Timestamp`, a
/// TIMESTAMP cell is re-rendered as int64 microseconds instead of the
/// "sec.microRemainder" form.
///
/// Every depth, not just the top level. google-cloud-bigquery asks for this
/// format on every read and parses a TIMESTAMP cell with `int()`, so a cell
/// left in the float-seconds form inside a STRUCT or an ARRAY raises
/// ValueError on the client rather than producing a wrong value.
pub fn formatInt64Timestamps(
    arena: std.mem.Allocator,
    row: []const driver.Cell,
) std.mem.Allocator.Error![]const driver.Cell {
    var converted: ?[]driver.Cell = null;
    for (row, 0..) |cell, i| {
        const replacement = try int64Timestamp(arena, cell) orelse continue;
        if (converted == null) {
            const dup = try arena.alloc(driver.Cell, row.len);
            @memcpy(dup, row);
            converted = dup;
        }
        converted.?[i] = replacement;
    }
    return converted orelse row;
}

/// The cell re-rendered, or null when it carries no timestamp and the original
/// can be shared. Copying only the containers that change keeps a row of
/// ordinary columns allocation-free.
fn int64Timestamp(
    arena: std.mem.Allocator,
    cell: driver.Cell,
) std.mem.Allocator.Error!?driver.Cell {
    switch (cell) {
        .timestamp => |text| {
            const micros = value_mod.parseTimestampApi(text) catch return null;
            return .{ .int = micros };
        },
        .array => |items| {
            var out: ?[]driver.Cell = null;
            for (items, 0..) |item, i| {
                const replacement = try int64Timestamp(arena, item) orelse continue;
                if (out == null) {
                    const dup = try arena.alloc(driver.Cell, items.len);
                    @memcpy(dup, items);
                    out = dup;
                }
                out.?[i] = replacement;
            }
            return if (out) |o| .{ .array = o } else null;
        },
        .struct_ => |fields| {
            var out: ?[]driver.Cell.Field = null;
            for (fields, 0..) |f, i| {
                const replacement = try int64Timestamp(arena, f.value) orelse continue;
                if (out == null) {
                    const dup = try arena.alloc(driver.Cell.Field, fields.len);
                    @memcpy(dup, fields);
                    out = dup;
                }
                out.?[i].value = replacement;
            }
            return if (out) |o| .{ .struct_ = o } else null;
        },
        else => return null,
    }
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

/// The jobs.query / getQueryResults envelope.
///
/// Spelled out rather than taken from `pb.QueryResponse`: the proto types
/// `rows` as `repeated google.protobuf.Struct`, which carries no row shape and
/// would cost a Value tree per cell. The parts that are real messages —
/// `jobReference`, `schema` — are the generated ones.
pub const Envelope = struct {
    jobReference: bqpb.JobReference,
    schema: *const bqpb.TableSchema,
    rows: []const tablerow.TableRow,
    /// A string on the wire. Absent for a statement with no result set, such as DML or DDL.
    totalRows: ?[]const u8,
    /// Absent unless this page is short of the total.
    pageToken: ?[]const u8 = null,
    jobComplete: bool = true,
    /// A string on the wire. Present only for INSERT, UPDATE, DELETE and MERGE.
    numDmlAffectedRows: ?[]const u8 = null,
};

/// `pageToken` is absent when null rather than present and null, which is what
/// every optional on this envelope means.
pub const envelope_options: std.json.Stringify.Options = .{
    .emit_null_optional_fields = false,
};

/// Serializes the jobs.query / getQueryResults envelope.
pub fn writeQueryResponse(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    res: QueryResponse,
) !void {
    const rows = try arena.alloc(tablerow.TableRow, res.rows.len);
    for (res.rows, 0..) |row, i| rows[i] = .{ .cells = row };

    const body = try std.json.Stringify.valueAlloc(arena, Envelope{
        .jobReference = .{ .project_id = res.project_id, .job_id = res.job_id },
        .schema = try schema.pbSchema(arena, res.cols),
        .rows = rows,
        .totalRows = try std.fmt.allocPrint(arena, "{d}", .{res.total_rows}),
    }, envelope_options);
    try out.appendSlice(arena, body);
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
    // Compared by value: a TableFieldSchema's keys follow the proto's field
    // order, which is not the order Go's struct declaration produced.
    try json_pb.expectJsonEqual(expected, try responseOf(arena_state.allocator(), sql));
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

test "useInt64Timestamp reaches a TIMESTAMP inside a STRUCT" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The python client asks for this format on every read and parses a
    // TIMESTAMP cell with int(), so a float-seconds cell nested in a record is
    // a ValueError on the client rather than a wrong value.
    var fields = [_]driver.Cell.Field{
        .{ .name = "ts", .value = .{ .timestamp = "1768003200.0" } },
    };
    const row = try formatInt64Timestamps(arena, &.{.{ .struct_ = &fields }});
    try testing.expectEqual(@as(i64, 1768003200000000), row[0].struct_[0].value.int);
}

test "useInt64Timestamp reaches a TIMESTAMP inside an ARRAY<STRUCT>" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The shape entity resolution's entry_source_map has: a repeated record
    // whose fields include a timestamp.
    var fields = [_]driver.Cell.Field{
        .{ .name = "ts", .value = .{ .timestamp = "1768003200.0" } },
    };
    var items = [_]driver.Cell{.{ .struct_ = &fields }};
    const row = try formatInt64Timestamps(arena, &.{.{ .array = &items }});
    try testing.expectEqual(
        @as(i64, 1768003200000000),
        row[0].array[0].struct_[0].value.int,
    );
}

test "useInt64Timestamp reaches a TIMESTAMP inside a bare ARRAY" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The text is Go's `sec.microRemainder`, so the part after the dot is a
    // count of microseconds rather than a decimal fraction: ".5" is 5µs.
    var items = [_]driver.Cell{
        .{ .timestamp = "1768003200.0" },
        .{ .timestamp = "1768003200.5" },
        .{ .timestamp = "1768003200.500000" },
    };
    const row = try formatInt64Timestamps(arena, &.{.{ .array = &items }});
    try testing.expectEqual(@as(i64, 1768003200000000), row[0].array[0].int);
    try testing.expectEqual(@as(i64, 1768003200000005), row[0].array[1].int);
    try testing.expectEqual(@as(i64, 1768003200500000), row[0].array[2].int);
}

test "a TIMESTAMP nested two containers deep is still converted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var inner = [_]driver.Cell.Field{
        .{ .name = "ts", .value = .{ .timestamp = "1768003200.0" } },
    };
    var mid = [_]driver.Cell{.{ .struct_ = &inner }};
    var outer = [_]driver.Cell.Field{
        .{ .name = "rows", .value = .{ .array = &mid } },
    };
    const row = try formatInt64Timestamps(arena, &.{.{ .struct_ = &outer }});
    try testing.expectEqual(
        @as(i64, 1768003200000000),
        row[0].struct_[0].value.array[0].struct_[0].value.int,
    );
}

test "cells that are not timestamps are left alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var fields = [_]driver.Cell.Field{
        .{ .name = "d", .value = .{ .date = "2026-01-10" } },
        .{ .name = "s", .value = .{ .string = "1768003200.0" } },
        .{ .name = "n", .value = .null },
    };
    const row = try formatInt64Timestamps(arena, &.{ .{ .struct_ = &fields }, .{ .int = 7 } });
    try testing.expectEqualStrings("2026-01-10", row[0].struct_[0].value.date);
    // A string that merely looks like a timestamp is a string.
    try testing.expectEqualStrings("1768003200.0", row[0].struct_[1].value.string);
    try testing.expectEqual(driver.Cell.null, row[0].struct_[2].value);
    try testing.expectEqual(@as(i64, 7), row[1].int);
}

test "a row with no timestamp anywhere is returned unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const original: []const driver.Cell = &.{ .{ .int = 1 }, .{ .string = "x" } };
    const row = try formatInt64Timestamps(arena, original);
    try testing.expectEqual(original.ptr, row.ptr);
}
