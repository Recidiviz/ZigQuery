//! BigQuery REST `queryParameters` reshaped into `driver.Param`.
//!
//! The REST surface hands every scalar over as JSON *text* — google-cloud-
//! bigquery sends INT64, NUMERIC and the date/time kinds as strings — and
//! names the type separately in `parameterType`. So a parameter arrives as
//! two parallel trees:
//!
//!   {"name":"ids",
//!    "parameterType":{"type":"ARRAY","arrayType":{"type":"STRING"}},
//!    "parameterValue":{"arrayValues":[{"value":"a"},{"value":"b"}]}}
//!
//! This mirrors `rowvalue.zig`'s Normalizer, which does the same job for the
//! TableFieldSchema shape that tabledata.insertAll posts. The shapes differ
//! enough — the type sits beside the value rather than in a schema, values are
//! wrapped in `{"value": …}` and always stringified, and nesting is
//! `arrayType` / `structTypes[].type` rather than `mode` / `fields` — that
//! this is a sibling of it rather than a caller.
//!
//! Values are handed over as text wherever possible and coerced by
//! `castParamValue` at bind time, which is the same path
//! `test "scalar parameters are cast to the column type"` (driver.zig) pins.
//! Pre-parsing "5" into an integer here would duplicate that logic and would
//! be wrong when the declared type is STRING and the text merely looks
//! numeric — `WHERE external_id = @id` with id "0012".
//!
//! The declared type is also carried through to `Param.type_text` as GoogleSQL
//! type text, so the analyzer can be told what `@ids` is. Without that an
//! undeclared parameter resolves to an untyped INT64 and `UNNEST(@ids)` fails
//! with "Values referenced in UNNEST must be arrays" — inference only reaches
//! parameters used as a function or operator argument.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const schema = @import("schema.zig");

pub const Error = error{
    /// `queryParameters` was not an array, or an element was not an object.
    InvalidParameter,
    /// A BYTES parameter whose value is not valid base64.
    InvalidBase64Value,
} || std.mem.Allocator.Error;

/// Converts a `queryParameters` array into driver parameters.
///
/// Element order is preserved, which is what positional binding needs; named
/// parameters are matched by name at bind time, so their order does not
/// matter.
pub fn parse(arena: std.mem.Allocator, v: std.json.Value) Error![]const driver.Param {
    if (v != .array) return error.InvalidParameter;
    const items = v.array.items;
    const out = try arena.alloc(driver.Param, items.len);
    for (items, 0..) |item, i| {
        if (item != .object) return error.InvalidParameter;
        const obj = item.object;
        const ptype = obj.get("parameterType");

        out[i] = .{
            // Stored without the `@` sigil: SQLite reports the placeholder as
            // "@name" and the driver strips it before looking the arg up.
            // An absent or empty name means a positional `?` parameter.
            .name = blk: {
                const n = obj.get("name") orelse break :blk null;
                if (n != .string or n.string.len == 0) break :blk null;
                break :blk n.string;
            },
            .value = try cellFor(arena, ptype, obj.get("parameterValue")),
            .type_text = try typeText(arena, ptype),
        };
    }
    return out;
}

/// GoogleSQL type text for a `parameterType` node: "STRING", "ARRAY<STRING>",
/// "STRUCT<`a` INT64, `b` STRING>".
///
/// Null when the type cannot be expressed — an unmapped type name, an ARRAY
/// with no element type. The parameter is then left to the analyzer's own
/// inference, which is exactly what every parameter got before declarations
/// existed, so an exotic type is never worse off than it was.
pub fn typeText(
    arena: std.mem.Allocator,
    ptype: ?std.json.Value,
) std.mem.Allocator.Error!?[]const u8 {
    const t = ptype orelse return null;
    const name = typeNameOf(t) orelse return null;

    if (std.mem.eql(u8, name, "ARRAY")) {
        const elem = t.object.get("arrayType") orelse return null;
        const inner = try typeText(arena, elem) orelse return null;
        const text: []const u8 = try std.fmt.allocPrint(arena, "ARRAY<{s}>", .{inner});
        return text;
    }

    if (std.mem.eql(u8, name, "STRUCT")) {
        const fields = structTypesOf(t);
        if (fields.len == 0) return null;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "STRUCT<");
        for (fields, 0..) |field, i| {
            if (i > 0) try out.appendSlice(arena, ", ");
            const inner = try typeText(arena, fieldTypeOf(field)) orelse return null;
            // An anonymous field is a legal STRUCT member; naming it with
            // empty backticks would not be.
            const fname = fieldNameOf(field);
            if (fname.len > 0) {
                try out.append(arena, '`');
                try out.appendSlice(arena, fname);
                try out.appendSlice(arena, "` ");
            }
            try out.appendSlice(arena, inner);
        }
        try out.append(arena, '>');
        const text: []const u8 = try out.toOwnedSlice(arena);
        return text;
    }

    // Reuse the legacy-name mapping the table schema path already uses. The
    // REST API spells INT64 six ways, so this is not a formality.
    return schema.googleSqlTypeName(name);
}

/// The value tree, shaped by the declared type.
fn cellFor(
    arena: std.mem.Allocator,
    ptype: ?std.json.Value,
    pvalue: ?std.json.Value,
) Error!driver.Cell {
    // No parameterValue at all is how a NULL parameter arrives.
    const val = pvalue orelse return .null;
    if (val != .object) return error.InvalidParameter;
    const name = if (ptype) |t| (typeNameOf(t) orelse "") else "";

    if (std.mem.eql(u8, name, "ARRAY")) {
        const elem = ptype.?.object.get("arrayType");
        // A present parameterValue with no arrayValues is an empty array, not
        // a NULL one — the same rule the insertAll path follows.
        const arr = val.object.get("arrayValues") orelse return .{ .array = &.{} };
        if (arr != .array) return error.InvalidParameter;
        const cells = try arena.alloc(driver.Cell, arr.array.items.len);
        for (arr.array.items, 0..) |item, i| {
            cells[i] = try cellFor(arena, elem, item);
        }
        return .{ .array = cells };
    }

    if (std.mem.eql(u8, name, "STRUCT")) {
        const fields = structTypesOf(ptype.?);
        const members = val.object.get("structValues");
        const out = try arena.alloc(driver.Cell.Field, fields.len);
        for (fields, 0..) |field, i| {
            const fname = fieldNameOf(field);
            // Fields follow structTypes order, not the value object's key
            // order: castParamValue matches struct fields against the
            // declared type *by position*, so taking the value's order would
            // silently transpose them.
            const sub = if (members) |m|
                (if (m == .object) m.object.get(fname) else null)
            else
                null;
            out[i] = .{
                .name = fname,
                .value = try cellFor(arena, fieldTypeOf(field), sub),
            };
        }
        return .{ .struct_ = out };
    }

    const scalar = val.object.get("value") orelse return .null;
    return scalarCell(arena, name, scalar);
}

/// A leaf `parameterValue.value` under its declared type.
fn scalarCell(
    arena: std.mem.Allocator,
    type_name: []const u8,
    v: std.json.Value,
) Error!driver.Cell {
    return switch (v) {
        .null => .null,
        // Clients that send raw JSON scalars rather than stringifying them.
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .string = s },
        .string => |s| blk: {
            // BYTES arrives base64-encoded. Binding the encoded text would
            // store the base64 itself: castParamValue's TYPE_BYTES arm takes
            // the bytes as they are, it does not decode.
            if (std.mem.eql(u8, type_name, "BYTES")) {
                const dec = std.base64.standard.Decoder;
                const n = dec.calcSizeForSlice(s) catch return error.InvalidBase64Value;
                const buf = try arena.alloc(u8, n);
                dec.decode(buf, s) catch return error.InvalidBase64Value;
                break :blk .{ .bytes = buf };
            }
            // Cell.json exists so a JSON payload is bound as JSON rather than
            // re-quoted by ToJSON, which is what binding it as a string does.
            if (std.mem.eql(u8, type_name, "JSON")) break :blk .{ .json = s };
            // Everything else stays text and is cast to the resolved type at
            // bind time, exactly as the REST surface intends.
            break :blk .{ .string = s };
        },
        // A scalar cannot be either of these; reject rather than guess.
        .array, .object => error.InvalidParameter,
    };
}

fn typeNameOf(ptype: std.json.Value) ?[]const u8 {
    if (ptype != .object) return null;
    const t = ptype.object.get("type") orelse return null;
    return if (t == .string) t.string else null;
}

fn structTypesOf(ptype: std.json.Value) []const std.json.Value {
    if (ptype != .object) return &.{};
    const f = ptype.object.get("structTypes") orelse return &.{};
    return if (f == .array) f.array.items else &.{};
}

fn fieldTypeOf(field: std.json.Value) ?std.json.Value {
    if (field != .object) return null;
    return field.object.get("type");
}

/// A struct field's declared name. BigQuery always sends one for a
/// StructQueryParameter; an anonymous field stays unnamed, which is a legal
/// STRUCT in GoogleSQL.
fn fieldNameOf(field: std.json.Value) []const u8 {
    if (field != .object) return "";
    const n = field.object.get("name") orelse return "";
    return if (n == .string) n.string else "";
}

const testing = std.testing;

fn parseJson(arena: std.mem.Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
}

test "named scalars keep their order, name and text value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The body google-cloud-bigquery sends for two ScalarQueryParameters.
    const v = try parseJson(arena,
        \\[{"name":"state_code","parameterType":{"type":"STRING"},
        \\  "parameterValue":{"value":"US_CO"}},
        \\ {"name":"limit","parameterType":{"type":"INT64"},
        \\  "parameterValue":{"value":"5"}}]
    );
    const params = try parse(arena, v);

    try testing.expectEqual(@as(usize, 2), params.len);
    try testing.expectEqualStrings("state_code", params[0].name.?);
    try testing.expectEqualStrings("US_CO", params[0].value.string);
    try testing.expectEqualStrings("STRING", params[0].type_text.?);
    // An INT64 arrives as text and is cast at bind time, not here.
    try testing.expectEqualStrings("5", params[1].value.string);
    try testing.expectEqualStrings("INT64", params[1].type_text.?);
}

test "a parameter with no name is positional" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseJson(arena,
        \\[{"parameterType":{"type":"STRING"},"parameterValue":{"value":"x"}},
        \\ {"name":"","parameterType":{"type":"INT64"},"parameterValue":{"value":"1"}}]
    );
    const params = try parse(arena, v);
    try testing.expectEqual(@as(?[]const u8, null), params[0].name);
    try testing.expectEqual(@as(?[]const u8, null), params[1].name);
}

test "an array parameter becomes an array cell and ARRAY<T> type text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // credit_calculator.py's ArrayQueryParameter, the IN UNNEST(@ids) case.
    const v = try parseJson(arena,
        \\[{"name":"ids","parameterType":{"type":"ARRAY","arrayType":{"type":"STRING"}},
        \\  "parameterValue":{"arrayValues":[{"value":"a"},{"value":"b"}]}}]
    );
    const params = try parse(arena, v);

    try testing.expectEqualStrings("ARRAY<STRING>", params[0].type_text.?);
    try testing.expectEqual(@as(usize, 2), params[0].value.array.len);
    try testing.expectEqualStrings("a", params[0].value.array[0].string);
    try testing.expectEqualStrings("b", params[0].value.array[1].string);
}

test "an empty array is an empty cell, not null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        \\[{"name":"ids","parameterType":{"type":"ARRAY","arrayType":{"type":"STRING"}},
        \\  "parameterValue":{"arrayValues":[]}}]
        ,
        // No arrayValues key at all, which is how an empty list can arrive.
        \\[{"name":"ids","parameterType":{"type":"ARRAY","arrayType":{"type":"STRING"}},
        \\  "parameterValue":{}}]
    }) |body| {
        const params = try parse(arena, try parseJson(arena, body));
        try testing.expectEqual(@as(usize, 0), params[0].value.array.len);
    }
}

test "a struct parameter orders fields by structTypes and nulls the missing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // structValues deliberately out of order, and missing "b".
    const v = try parseJson(arena,
        \\[{"name":"s","parameterType":{"type":"STRUCT","structTypes":[
        \\    {"name":"a","type":{"type":"INT64"}},
        \\    {"name":"b","type":{"type":"STRING"}},
        \\    {"name":"c","type":{"type":"STRING"}}]},
        \\  "parameterValue":{"structValues":{"c":{"value":"z"},"a":{"value":"1"}}}}]
    );
    const params = try parse(arena, v);

    try testing.expectEqualStrings(
        "STRUCT<`a` INT64, `b` STRING, `c` STRING>",
        params[0].type_text.?,
    );
    const fields = params[0].value.struct_;
    try testing.expectEqual(@as(usize, 3), fields.len);
    try testing.expectEqualStrings("1", fields[0].value.string);
    try testing.expectEqual(driver.Cell.null, fields[1].value);
    try testing.expectEqualStrings("z", fields[2].value.string);
}

test "nested ARRAY<STRUCT<...>> renders and converts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseJson(arena,
        \\[{"name":"rows","parameterType":{"type":"ARRAY","arrayType":{
        \\    "type":"STRUCT","structTypes":[{"name":"n","type":{"type":"INT64"}}]}},
        \\  "parameterValue":{"arrayValues":[{"structValues":{"n":{"value":"7"}}}]}}]
    );
    const params = try parse(arena, v);

    try testing.expectEqualStrings("ARRAY<STRUCT<`n` INT64>>", params[0].type_text.?);
    try testing.expectEqualStrings("7", params[0].value.array[0].struct_[0].value.string);
}

test "a missing parameterValue, and an explicit JSON null, are both NULL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseJson(arena,
        \\[{"name":"a","parameterType":{"type":"STRING"}},
        \\ {"name":"b","parameterType":{"type":"STRING"},"parameterValue":{}},
        \\ {"name":"c","parameterType":{"type":"STRING"},"parameterValue":{"value":null}}]
    );
    const params = try parse(arena, v);
    for (params) |p| try testing.expectEqual(driver.Cell.null, p.value);
}

test "BYTES is base64 decoded, JSON is bound as JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseJson(arena,
        \\[{"name":"b","parameterType":{"type":"BYTES"},"parameterValue":{"value":"aGk="}},
        \\ {"name":"j","parameterType":{"type":"JSON"},"parameterValue":{"value":"{\"k\":1}"}}]
    );
    const params = try parse(arena, v);
    try testing.expectEqualStrings("hi", params[0].value.bytes);
    try testing.expectEqualStrings("{\"k\":1}", params[1].value.json);

    const bad = try parseJson(arena,
        \\[{"name":"b","parameterType":{"type":"BYTES"},"parameterValue":{"value":"!!!"}}]
    );
    try testing.expectError(error.InvalidBase64Value, parse(arena, bad));
}

test "legacy type spellings map to their GoogleSQL names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // INTEGER/BOOLEAN/FLOAT are the legacy names the REST API uses.
    const v = try parseJson(arena,
        \\[{"name":"a","parameterType":{"type":"INTEGER"},"parameterValue":{"value":"1"}},
        \\ {"name":"b","parameterType":{"type":"BOOLEAN"},"parameterValue":{"value":"true"}}]
    );
    const params = try parse(arena, v);
    try testing.expectEqualStrings("INT64", params[0].type_text.?);
    try testing.expectEqualStrings("BOOL", params[1].type_text.?);
}

test "an unmapped type declares nothing but still binds its value" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Declaring nothing leaves the analyzer inferring, which is what every
    // parameter got before declarations existed — never worse than before.
    for ([_][]const u8{
        \\[{"name":"a","parameterType":{"type":"WIDGET"},"parameterValue":{"value":"1"}}]
        ,
        // No parameterType at all.
        \\[{"name":"a","parameterValue":{"value":"1"}}]
    }) |body| {
        const params = try parse(arena, try parseJson(arena, body));
        try testing.expectEqual(@as(?[]const u8, null), params[0].type_text);
        try testing.expectEqualStrings("1", params[0].value.string);
    }

    // An ARRAY with no element type still shapes the value as an array — the
    // type name is enough for that — it just cannot be declared.
    const arr = try parse(arena, try parseJson(arena,
        \\[{"name":"a","parameterType":{"type":"ARRAY"},
        \\  "parameterValue":{"arrayValues":[{"value":"1"}]}}]
    ));
    try testing.expectEqual(@as(?[]const u8, null), arr[0].type_text);
    try testing.expectEqualStrings("1", arr[0].value.array[0].string);
}

test "a non-array body is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "{}", "\"x\"", "5" }) |body| {
        try testing.expectError(
            error.InvalidParameter,
            parse(arena, try parseJson(arena, body)),
        );
    }
    // An element that is not an object.
    try testing.expectError(
        error.InvalidParameter,
        parse(arena, try parseJson(arena, "[1]")),
    );
}
