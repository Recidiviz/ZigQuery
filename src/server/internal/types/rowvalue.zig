//! Port of bigquery-emulator types/types.go normalizeData (:634) and the row
//! shaping of NewTableWithSchema (:546) — a posted JSON row value reshaped to
//! match the column's schema before it is bound.
//!
//! Differences from Go, by design:
//! - Go's intermediate `interface{}` is skipped: normalizeData's output feeds
//!   straight into the driver's `Cell`. In particular a STRUCT becomes a
//!   `Cell.struct_` directly, where Go builds a `[]map[string]interface{}`
//!   (one single-key map per field) that CastValue's ArrayValue arm then
//!   merges back into one struct. Same result, one hop instead of three.
//! - Go decodes every JSON number as `float64`, so an INT64 past 2^53 loses
//!   precision on the way in. std.json keeps integers exact, so this does not.

const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;

pub const Error = error{
    /// Go: "invalid value type %T for ARRAY column".
    InvalidArrayValue,
    /// Go: "failed to find value from %v by %s" — a struct value carrying a
    /// key the schema does not declare. Go dereferences a nil field there and
    /// panics; recoveryMiddleware turns that into the same 500 this does.
    UnknownStructField,
} || std.mem.Allocator.Error;

/// Reshapes posted row values, carrying Go's error text for the 500 body.
pub const Normalizer = struct {
    arena: std.mem.Allocator,
    /// Set when a call fails; empty otherwise.
    message: []const u8 = "",

    /// `field` is a TableFieldSchema node from the table's stored schema.
    pub fn cellForField(
        n: *Normalizer,
        json: std.json.Value,
        field: std.json.Value,
    ) Error!driver.Cell {
        return n.cellForShape(json, stringOf(field, "mode"), fieldsOf(field));
    }

    /// `cellForField` with the schema node's `mode` and `fields` already read.
    /// Both are constant for a column, so the insert path resolves them once
    /// per column instead of paying two hash lookups on every cell.
    pub fn cellForShape(
        n: *Normalizer,
        json: std.json.Value,
        mode: []const u8,
        fields: []const std.json.Value,
    ) Error!driver.Cell {
        return n.cell(json, mode, fields);
    }

    fn cell(
        n: *Normalizer,
        json: std.json.Value,
        mode: []const u8,
        fields: []const std.json.Value,
    ) Error!driver.Cell {
        if (std.mem.eql(u8, mode, "REPEATED")) {
            if (json != .array) {
                n.message = try std.fmt.allocPrint(
                    n.arena,
                    "invalid value type {s} for ARRAY column",
                    .{jsonTypeName(json)},
                );
                return error.InvalidArrayValue;
            }
            const items = json.array.items;
            const cells = try n.arena.alloc(driver.Cell, items.len);
            for (items, 0..) |item, i| {
                // Go recurses with &TableFieldSchema{Fields: field.Fields}:
                // the element inherits the record fields and *nothing else*,
                // so its own type and mode are deliberately dropped.
                cells[i] = try n.cell(item, "", fields);
            }
            return .{ .array = cells };
        }

        if (json == .object) {
            const out = try n.arena.alloc(driver.Cell.Field, fields.len);
            for (fields, 0..) |sub, i| {
                const name = stringOf(sub, "name");
                out[i] = .{
                    .name = name,
                    // Go pre-seeds every schema field to nil, so a value
                    // missing a key yields NULL rather than an error.
                    .value = if (json.object.get(name)) |v|
                        try n.cellForField(v, sub)
                    else
                        .null,
                };
            }
            // Go looks the *value's* keys up in the schema and nil-derefs on a
            // miss; report it instead. Checked after the fields are built so
            // the common path does no extra work.
            var it = json.object.iterator();
            while (it.next()) |kv| {
                if (!hasField(fields, kv.key_ptr.*)) {
                    n.message = try std.fmt.allocPrint(
                        n.arena,
                        "failed to find value from {s}",
                        .{kv.key_ptr.*},
                    );
                    return error.UnknownStructField;
                }
            }
            return .{ .struct_ = out };
        }

        return switch (json) {
            .null => .null,
            .bool => |b| .{ .bool = b },
            .integer => |i| .{ .int = i },
            .float => |f| .{ .float = f },
            // std.json only produces number_string for values that overflow
            // i64/f64; the engine casts the text to the column type.
            .number_string => |s| .{ .string = s },
            .string => |s| .{ .string = s },
            // Handled above; listed so a new json kind is a compile error.
            .array, .object => unreachable,
        };
    }
};

/// The `fields` array of a TableFieldSchema node, or empty.
pub fn fieldsOf(field: std.json.Value) []const std.json.Value {
    if (field != .object) return &.{};
    const f = field.object.get("fields") orelse return &.{};
    return if (f == .array) f.array.items else &.{};
}

/// A string member of a JSON object, or "".
pub fn stringOf(v: std.json.Value, name: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(name) orelse return "";
    return if (f == .string) f.string else "";
}

fn hasField(fields: []const std.json.Value, name: []const u8) bool {
    for (fields) |f| {
        if (std.mem.eql(u8, stringOf(f, "name"), name)) return true;
    }
    return false;
}

/// Stands in for Go's %T in the ARRAY error message.
fn jsonTypeName(v: std.json.Value) []const u8 {
    return switch (v) {
        .null => "<nil>",
        .bool => "bool",
        .integer, .float, .number_string => "float64",
        .string => "string",
        .array => "[]interface {}",
        .object => "map[string]interface {}",
    };
}

const testing = std.testing;

fn parse(arena: std.mem.Allocator, text: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
}

test "scalars pass through unchanged" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    const field = try parse(arena, "{\"name\":\"a\",\"type\":\"INTEGER\"}");
    try testing.expectEqual(
        driver.Cell{ .int = 5 },
        try n.cellForField(try parse(arena, "5"), field),
    );
    try testing.expectEqual(
        driver.Cell.null,
        try n.cellForField(try parse(arena, "null"), field),
    );
    // An INT64 the JSON client sent as text stays text here; the engine's
    // CastValue coerces it against the column type at bind time.
    try testing.expectEqualStrings(
        "5",
        (try n.cellForField(try parse(arena, "\"5\""), field)).string,
    );
}

test "REPEATED becomes an array, and an empty one stays empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    const field = try parse(arena,
        \\{"name":"xs","type":"STRING","mode":"REPEATED"}
    );
    const cell = try n.cellForField(try parse(arena, "[\"a\",\"b\"]"), field);
    try testing.expectEqual(@as(usize, 2), cell.array.len);
    try testing.expectEqualStrings("a", cell.array[0].string);
    try testing.expectEqualStrings("b", cell.array[1].string);

    // goccy #137: an empty REPEATED value must survive as [], not null.
    const empty = try n.cellForField(try parse(arena, "[]"), field);
    try testing.expectEqual(@as(usize, 0), empty.array.len);
}

test "a non-array for a REPEATED column is Go's error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    const field = try parse(arena,
        \\{"name":"xs","type":"STRING","mode":"REPEATED"}
    );
    try testing.expectError(
        error.InvalidArrayValue,
        n.cellForField(try parse(arena, "\"nope\""), field),
    );
    try testing.expectEqualStrings("invalid value type string for ARRAY column", n.message);

    // Go's reflect.ValueOf(nil).Kind() is Invalid, so an explicit null is an
    // error too — only an *absent* key becomes NULL.
    try testing.expectError(
        error.InvalidArrayValue,
        n.cellForField(try parse(arena, "null"), field),
    );
}

test "RECORD fields come out in schema order, with missing keys NULL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    const field = try parse(arena,
        \\{"name":"s","type":"RECORD","fields":[
        \\  {"name":"a","type":"INTEGER"},
        \\  {"name":"b","type":"STRING"},
        \\  {"name":"c","type":"BOOLEAN"}
        \\]}
    );
    // Keys deliberately out of order, and `b` omitted entirely.
    const cell = try n.cellForField(try parse(arena, "{\"c\":true,\"a\":1}"), field);
    const fields = cell.struct_;
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqualStrings("a", fields[0].name);
    try testing.expectEqual(driver.Cell{ .int = 1 }, fields[0].value);
    try testing.expectEqualStrings("b", fields[1].name);
    try testing.expectEqual(driver.Cell.null, fields[1].value);
    try testing.expectEqualStrings("c", fields[2].name);
    try testing.expectEqual(driver.Cell{ .bool = true }, fields[2].value);
}

test "an empty struct yields every declared field as NULL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    const field = try parse(arena,
        \\{"name":"s","type":"RECORD","fields":[{"name":"a","type":"INTEGER"}]}
    );
    const cell = try n.cellForField(try parse(arena, "{}"), field);
    try testing.expectEqual(@as(usize, 1), cell.struct_.len);
    try testing.expectEqual(driver.Cell.null, cell.struct_[0].value);
}

test "a struct key the schema does not declare is an error, not a panic" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    // Only top-level fields are validated before the insert, so this is the
    // one place a nested unknown field can surface. Go nil-derefs here.
    const field = try parse(arena,
        \\{"name":"s","type":"RECORD","fields":[{"name":"a","type":"INTEGER"}]}
    );
    try testing.expectError(
        error.UnknownStructField,
        n.cellForField(try parse(arena, "{\"a\":1,\"nope\":2}"), field),
    );
    try testing.expectEqualStrings("failed to find value from nope", n.message);
}

test "REPEATED RECORD keeps the element fields and drops the element mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    const field = try parse(arena,
        \\{"name":"rs","type":"RECORD","mode":"REPEATED","fields":[
        \\  {"name":"a","type":"INTEGER"},
        \\  {"name":"b","type":"STRING"}
        \\]}
    );
    const cell = try n.cellForField(
        try parse(arena, "[{\"a\":1,\"b\":\"x\"},{\"a\":2,\"b\":\"y\"}]"),
        field,
    );
    try testing.expectEqual(@as(usize, 2), cell.array.len);
    try testing.expectEqual(driver.Cell{ .int = 1 }, cell.array[0].struct_[0].value);
    try testing.expectEqualStrings("y", cell.array[1].struct_[1].value.string);
}

test "nested RECORD inside a RECORD" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var n = Normalizer{ .arena = arena };

    const field = try parse(arena,
        \\{"name":"s","type":"RECORD","fields":[
        \\  {"name":"a","type":"INTEGER"},
        \\  {"name":"inner","type":"RECORD","fields":[{"name":"c","type":"STRING"}]}
        \\]}
    );
    const cell = try n.cellForField(
        try parse(arena, "{\"a\":1,\"inner\":{\"c\":\"deep\"}}"),
        field,
    );
    try testing.expectEqualStrings(
        "deep",
        cell.struct_[1].value.struct_[0].value.string,
    );
}
