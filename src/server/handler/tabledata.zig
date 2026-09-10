//! tabledata.insertAll: the request rows, their validation against the table
//! schema, and the `insertErrors` response.
//! https://cloud.google.com/bigquery/docs/reference/rest/v2/tabledata/insertAll
//!
//! An invalid row rejects the whole batch: nothing is written, the response is
//! HTTP 200, and `insertErrors` lists the invalid rows as `invalid` and every
//! other row as `stopped`. With `skipInvalidRows` the other rows are written
//! and only the invalid ones are listed.
//!
//! A row is invalid when a top-level field is absent from the schema
//! (`validateAgainstSchema`, checked before anything is bound) or when a value
//! its column will not take (`contentdata.RowError`, found at bind time).
//! Engine failures are 500s: prepare, transaction control, and a step that
//! fails for any other reason.
//!
//! `insertId` is read off the wire and discarded: the emulator does no
//! deduplication. `ignoreUnknownValues`, `templateSuffix` and `traceId` are
//! parsed and ignored; an unknown field is rejected whatever
//! `ignoreUnknownValues` says.

const std = @import("std");
const errors = @import("../error.zig");
const contentdata = @import("../internal/contentdata/repository.zig");
const rowvalue = @import("../internal/types/rowvalue.zig");

pub const Error = error{
    /// Go's json.Decode into TableDataInsertAllRequest failed; the handler
    /// answers 400 invalid
    InvalidRequest,
} || std.mem.Allocator.Error;

/// One `insertErrors` entry: which row, which field, and why. Go
/// types.FieldValidationError (validation.go:36) plus the message, the same
/// record the bind path reports, so both sources share the writer.
pub const InsertError = contentdata.RowError;

/// The request's `skipInvalidRows`; absent is false, as in the API.
pub fn skipInvalidRows(root: std.json.Value) bool {
    if (root != .object) return false;
    const v = root.object.get("skipInvalidRows") orelse return false;
    return v == .bool and v.bool;
}

/// The `json` object of each posted row, in order.
///
/// Go decodes into `[]*TableDataInsertAllRequestRows`, so a row with no `json`
/// member carries a nil map — an empty object here, which inserts a row of
/// NULLs rather than failing.
pub fn rowsFromBody(
    arena: std.mem.Allocator,
    root: std.json.Value,
) Error![]const std.json.Value {
    if (root != .object) return error.InvalidRequest;
    const rows_node = root.object.get("rows") orelse return &.{};
    if (rows_node == .null) return &.{};
    if (rows_node != .array) return error.InvalidRequest;

    const items = rows_node.array.items;
    const out = try arena.alloc(std.json.Value, items.len);
    for (items, 0..) |row, i| {
        if (row != .object) return error.InvalidRequest;
        const json_node = row.object.get("json") orelse {
            out[i] = .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) };
            continue;
        };
        switch (json_node) {
            .object => out[i] = json_node,
            .null => out[i] = .{ .object = try std.json.ObjectMap.init(arena, &.{}, &.{}) },
            else => return error.InvalidRequest,
        }
    }
    return out;
}

/// Go ValidateDataAgainstSchema: every field of every row must be declared by
/// the schema. Top-level names only — nested RECORD members are not checked
/// here (and reaching one that is undeclared is a 500 later).
///
/// At most one error per row, matching BigQuery. Go picks an arbitrary one
/// because it ranges over a map; this reports the first in document order,
/// which is deterministic and is what the Python suite allows for.
pub fn validateAgainstSchema(
    arena: std.mem.Allocator,
    fields: []const std.json.Value,
    rows: []const std.json.Value,
) std.mem.Allocator.Error![]const InsertError {
    // Go builds the name set once (validation.go:45). Scanning the field list
    // per key instead is O(rows x keys x fields): on a 25-column, 18k-row
    // batch that is 5.7M string compares and 1.3 s, more than the insert.
    var declared: std.StringHashMapUnmanaged(void) = .empty;
    try declared.ensureTotalCapacity(arena, @intCast(fields.len));
    for (fields) |f| declared.putAssumeCapacity(rowvalue.stringOf(f, "name"), {});

    var out: std.ArrayList(InsertError) = .empty;
    for (rows, 0..) |row, row_index| {
        if (row != .object) continue;
        var it = row.object.iterator();
        while (it.next()) |kv| {
            const name = kv.key_ptr.*;
            if (declared.contains(name)) continue;
            try out.append(arena, .{
                .row_index = @intCast(row_index),
                .field_name = name,
                .message = try std.fmt.allocPrint(arena, "no such field: {s}.", .{name}),
            });
            break;
        }
    }
    return out.toOwnedSlice(arena);
}

/// Go buildInsertErrorsResponse. Every `invalid` entry first, in ascending row
/// index, then — unless `stopped` is null — a `stopped` entry for every row
/// under that count that was not itself invalid: nothing was inserted, so no
/// row succeeded. A `skipInvalidRows` request inserted the rest and passes
/// null.
///
/// Key order is alphabetical because the google-api-go-client structs carry
/// ForceSendFields, which routes them through gensupport.MarshalJSON's map;
/// that is also why `index`, `debugInfo`, `location` and `message` are all
/// emitted when empty.
pub fn writeInsertErrors(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    errs: []const InsertError,
    stopped: ?usize,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "{\"insertErrors\":[");

    for (errs, 0..) |e, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"errors\":[{\"debugInfo\":\"\",\"location\":");
        try errors.writeJsonString(arena, out, e.field_name);
        try out.appendSlice(arena, ",\"message\":");
        try errors.writeJsonString(arena, out, e.message);
        try out.appendSlice(arena, ",\"reason\":\"invalid\"}],\"index\":");
        try out.print(arena, "{d}", .{e.row_index});
        try out.append(arena, '}');
    }

    var wrote_any = errs.len > 0;
    for (0..(stopped orelse 0)) |i| {
        if (isInvalid(errs, i)) continue;
        if (wrote_any) try out.append(arena, ',');
        wrote_any = true;
        try out.appendSlice(
            arena,
            "{\"errors\":[{\"debugInfo\":\"\",\"location\":\"\",\"message\":\"\"," ++
                "\"reason\":\"stopped\"}],\"index\":",
        );
        try out.print(arena, "{d}", .{i});
        try out.append(arena, '}');
    }

    try out.appendSlice(arena, "]}");
}

fn isInvalid(errs: []const InsertError, row_index: usize) bool {
    for (errs) |e| {
        if (e.row_index == row_index) return true;
    }
    return false;
}

/// The `schema.fields` array of a stored table resource, or null when the
/// table has no schema — which Go reaches by dereferencing a nil and is
/// therefore a 500 there too.
pub fn schemaFieldsOf(table_meta: std.json.Value) ?[]const std.json.Value {
    if (table_meta != .object) return null;
    return fieldsOfSchema(table_meta.object.get("schema"));
}

/// The `fields` array of a `schema` node.
pub fn fieldsOfSchema(schema_node: ?std.json.Value) ?[]const std.json.Value {
    const schema = schema_node orelse return null;
    if (schema != .object) return null;
    const fields = schema.object.get("fields") orelse return null;
    if (fields != .array) return null;
    return fields.array.items;
}

const testing = std.testing;

fn parse(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

fn fieldsFrom(arena: std.mem.Allocator, text: []const u8) ![]const std.json.Value {
    return (try parse(arena, text)).array.items;
}

test "rows are unwrapped from their json member, insertId ignored" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const body = try parse(arena,
        \\{"kind":"bigquery#tableDataInsertAllRequest","rows":[
        \\  {"insertId":"1","json":{"a":1}},
        \\  {"json":{"a":2}},
        \\  {"insertId":"3"}
        \\]}
    );
    const rows = try rowsFromBody(arena, body);
    try testing.expectEqual(@as(usize, 3), rows.len);
    try testing.expectEqual(@as(i64, 1), rows[0].object.get("a").?.integer);
    try testing.expectEqual(@as(i64, 2), rows[1].object.get("a").?.integer);
    // A row with no `json` is Go's nil map: an empty row, not an error.
    try testing.expectEqual(@as(usize, 0), rows[2].object.count());
}

test "a body with no rows inserts nothing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(
        @as(usize, 0),
        (try rowsFromBody(arena, try parse(arena, "{}"))).len,
    );
    try testing.expectEqual(
        @as(usize, 0),
        (try rowsFromBody(arena, try parse(arena, "{\"rows\":[]}"))).len,
    );
}

test "a malformed rows member is a decode failure" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(
        error.InvalidRequest,
        rowsFromBody(arena, try parse(arena, "{\"rows\":\"nope\"}")),
    );
    try testing.expectError(
        error.InvalidRequest,
        rowsFromBody(arena, try parse(arena, "{\"rows\":[1,2]}")),
    );
    try testing.expectError(
        error.InvalidRequest,
        rowsFromBody(arena, try parse(arena, "{\"rows\":[{\"json\":5}]}")),
    );
}

test "validation flags one unknown field per row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fields = try fieldsFrom(arena,
        \\[{"name":"name","type":"STRING"},{"name":"age","type":"INTEGER"}]
    );

    // types_test.go TestValidateDataAgainstSchema: all valid.
    const ok = try rowsFromBody(arena, try parse(arena,
        \\{"rows":[{"json":{"name":"Alice","age":30}},{"json":{"name":"Bob"}}]}
    ));
    try testing.expectEqual(@as(usize, 0), (try validateAgainstSchema(arena, fields, ok)).len);

    // Three unknown fields in one row still produce exactly one error.
    const many = try rowsFromBody(arena, try parse(arena,
        \\{"rows":[{"json":{"name":"Bob","u1":1,"u2":2,"u3":3}}]}
    ));
    const errs = try validateAgainstSchema(arena, fields, many);
    try testing.expectEqual(@as(usize, 1), errs.len);
    try testing.expectEqual(@as(u32, 0), errs[0].row_index);
    try testing.expectEqualStrings("u1", errs[0].field_name);
    try testing.expectEqualStrings("no such field: u1.", errs[0].message);
}

test "validation reports rows 0 and 2 but not 1" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const fields = try fieldsFrom(arena, "[{\"name\":\"name\",\"type\":\"STRING\"}]");
    const rows = try rowsFromBody(arena, try parse(arena,
        \\{"rows":[
        \\  {"json":{"name":"a","bad":1}},
        \\  {"json":{"name":"b"}},
        \\  {"json":{"name":"c","worse":2}}
        \\]}
    ));
    const errs = try validateAgainstSchema(arena, fields, rows);
    try testing.expectEqual(@as(usize, 2), errs.len);
    try testing.expectEqual(@as(u32, 0), errs[0].row_index);
    try testing.expectEqual(@as(u32, 2), errs[1].row_index);
}

test "an empty schema makes every field unknown" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try rowsFromBody(arena, try parse(arena, "{\"rows\":[{\"json\":{\"a\":1}}]}"));
    try testing.expectEqual(
        @as(usize, 1),
        (try validateAgainstSchema(arena, &.{}, rows)).len,
    );
}

test "one bad field renders the Go emulator's insertErrors body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // emulator_test.py test_insert_unknown_fields_one_bad_field.
    var out: std.ArrayList(u8) = .empty;
    try writeInsertErrors(
        arena,
        &out,
        &.{.{
            .row_index = 0,
            .field_name = "unknown_field",
            .message = "no such field: unknown_field.",
        }},
        1,
    );
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"unknown_field","message":"no such field: unknown_field.","reason":"invalid"}],"index":0}]}
    , out.items);
}

test "mixed valid and invalid rows: invalid first, then stopped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // emulator_test.py test_insert_unknown_fields_mixed_valid_and_invalid
    // pins this exact list, ordering included: rows 1 and 3 are invalid, so
    // rows 0 and 2 come after them as `stopped`.
    var out: std.ArrayList(u8) = .empty;
    try writeInsertErrors(arena, &out, &.{
        .{ .row_index = 1, .field_name = "bad_field", .message = "no such field: bad_field." },
        .{ .row_index = 3, .field_name = "bad1", .message = "no such field: bad1." },
    }, 4);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"bad_field","message":"no such field: bad_field.","reason":"invalid"}],"index":1},{"errors":[{"debugInfo":"","location":"bad1","message":"no such field: bad1.","reason":"invalid"}],"index":3},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":0},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":2}]}
    , out.items);
}

test "a skipInvalidRows response lists only the invalid rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeInsertErrors(arena, &out, &.{.{
        .row_index = 1,
        .field_name = "dob",
        .message = "failed to convert 01-01-1980 to time.Time type",
    }}, null);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"dob","message":"failed to convert 01-01-1980 to time.Time type","reason":"invalid"}],"index":1}]}
    , out.items);
}

test "skipInvalidRows is read off the request and defaults to false" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expect(skipInvalidRows(try parse(arena, "{\"skipInvalidRows\":true,\"rows\":[]}")));
    try testing.expect(!skipInvalidRows(try parse(arena, "{\"skipInvalidRows\":false}")));
    try testing.expect(!skipInvalidRows(try parse(arena, "{\"rows\":[]}")));
    try testing.expect(!skipInvalidRows(try parse(arena, "{\"skipInvalidRows\":\"true\"}")));
}

test "schema fields come out of a stored table resource" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const meta = try parse(arena,
        \\{"kind":"bigquery#table","schema":{"fields":[{"name":"a","type":"INTEGER"}]}}
    );
    try testing.expectEqual(@as(usize, 1), schemaFieldsOf(meta).?.len);

    // A table stored without a schema: Go nil-derefs, we report absence.
    try testing.expectEqual(
        @as(?[]const std.json.Value, null),
        schemaFieldsOf(try parse(arena, "{\"kind\":\"bigquery#table\"}")),
    );
}
