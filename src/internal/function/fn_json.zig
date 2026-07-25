//! Port of go-zetasqlite internal/function_json.go plus the JSON bind handlers
//! in function_bind.go.
//!
//! JSONPath: a faithful port of goccy/go-json's decoder/path.go builder (the
//! library go-zetasqlite uses). It accepts BigQuery-style paths:
//!   $               root
//!   .member         child selector (unquoted)
//!   ."member"       double-quote escaped selector (standard syntax)
//!   ['member']      single-quote escaped selector (legacy syntax)
//!   [index]         array subscript
//! and records whether single-quote / double-quote selectors were used, so the
//! JSON_EXTRACT* family (legacy) can reject double quotes and JSON_QUERY/VALUE*
//! (standard) can reject single quotes, exactly like Go.
//!
//! Values are parsed with std.json (parse_numbers = false) so numbers survive
//! as their exact source text, and re-serialized minified — object key order is
//! preserved (ObjectMap is insertion-ordered), matching goccy's Extract+Compact.

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

// ----------------------------------------------------------------------
// JSONPath parser (goccy decoder.PathBuilder port)
// ----------------------------------------------------------------------

const PathNode = union(enum) {
    selector: []const u8,
    index: i64,
};

const Path = struct {
    nodes: []const PathNode,
    root_only: bool,
    single_quote: bool,
    double_quote: bool,
};

const PathError = error{InvalidPath} || std.mem.Allocator.Error;

const PathParser = struct {
    alloc: std.mem.Allocator,
    nodes: std.ArrayList(PathNode) = .empty,
    single_quote: bool = false,
    double_quote: bool = false,

    fn add(self: *PathParser, node: PathNode) PathError!void {
        try self.nodes.append(self.alloc, node);
    }

    /// Build the whole path; buf is the full "$..." string.
    fn build(self: *PathParser, buf: []const u8) PathError!bool {
        if (buf.len == 0) return error.InvalidPath;
        if (buf[0] != '$') return error.InvalidPath;
        if (buf.len == 1) return true; // root only
        const off = try self.buildNext(buf[1..]);
        if (buf[1..].len > off) return error.InvalidPath;
        return false;
    }

    fn buildNextCharIfExists(self: *PathParser, buf: []const u8, cursor: usize) PathError!usize {
        if (buf.len > cursor) {
            const off = try self.buildNext(buf[cursor..]);
            return cursor + 1 + off;
        }
        return cursor;
    }

    fn buildNext(self: *PathParser, buf: []const u8) PathError!usize {
        switch (buf[0]) {
            '.' => {
                if (buf.len == 1) return error.InvalidPath;
                const off = try self.buildSelector(buf[1..]);
                return off + 1;
            },
            '[' => {
                if (buf.len == 1) return error.InvalidPath;
                const off = try self.buildIndex(buf[1..]);
                return off + 1;
            },
            else => return error.InvalidPath,
        }
    }

    fn buildSelector(self: *PathParser, buf: []const u8) PathError!usize {
        switch (buf[0]) {
            // Recursive descent (`..`) and wildcards are unsupported.
            '.', '[', ']', '$', '*' => return error.InvalidPath,
            else => {},
        }
        var cursor: usize = 0;
        while (cursor < buf.len) : (cursor += 1) {
            switch (buf[cursor]) {
                '$', '*', ']' => return error.InvalidPath,
                '.' => {
                    if (cursor + 1 >= buf.len) return error.InvalidPath;
                    try self.add(.{ .selector = buf[0..cursor] });
                    const off = try self.buildSelector(buf[cursor + 1 ..]);
                    return cursor + 1 + off;
                },
                '[' => {
                    if (cursor + 1 >= buf.len) return error.InvalidPath;
                    try self.add(.{ .selector = buf[0..cursor] });
                    const off = try self.buildIndex(buf[cursor + 1 ..]);
                    return cursor + 1 + off;
                },
                '"' => {
                    if (cursor + 1 >= buf.len) return error.InvalidPath;
                    const off = try self.buildQuoteSelector(buf[cursor + 1 ..], .double);
                    return cursor + 1 + off;
                },
                else => {},
            }
        }
        try self.add(.{ .selector = buf });
        return buf.len;
    }

    const Quote = enum { single, double };

    fn buildQuoteSelector(self: *PathParser, buf: []const u8, sel: Quote) PathError!usize {
        switch (buf[0]) {
            '[', ']', '$', '.', '*', '\'', '"' => return error.InvalidPath,
            else => {},
        }
        var cursor: usize = 0;
        while (cursor < buf.len) : (cursor += 1) {
            switch (buf[cursor]) {
                '\'' => {
                    if (sel != .single) return error.InvalidPath;
                    if (buf.len <= cursor + 1) return error.InvalidPath;
                    if (buf[cursor + 1] != ']') return error.InvalidPath;
                    try self.add(.{ .selector = buf[0..cursor] });
                    self.single_quote = true;
                    return self.buildNextCharIfExists(buf, cursor + 2);
                },
                '"' => {
                    if (sel != .double) return error.InvalidPath;
                    try self.add(.{ .selector = buf[0..cursor] });
                    self.double_quote = true;
                    return self.buildNextCharIfExists(buf, cursor + 1);
                },
                else => {},
            }
        }
        return error.InvalidPath;
    }

    fn buildIndex(self: *PathParser, buf: []const u8) PathError!usize {
        switch (buf[0]) {
            '.', '[', ']', '$' => return error.InvalidPath,
            '\'' => {
                if (buf.len == 1) return error.InvalidPath;
                const off = try self.buildQuoteSelector(buf[1..], .single);
                return 1 + off;
            },
            '*' => return error.InvalidPath, // `[*]` unsupported
            else => {},
        }
        var cursor: usize = 0;
        while (cursor < buf.len) : (cursor += 1) {
            if (buf[cursor] == ']') {
                const idx = std.fmt.parseInt(i64, buf[0..cursor], 10) catch return error.InvalidPath;
                try self.add(.{ .index = idx });
                return self.buildNextCharIfExists(buf, cursor + 1);
            }
        }
        return error.InvalidPath;
    }
};

fn parsePath(alloc: std.mem.Allocator, s: []const u8) PathError!Path {
    var p = PathParser{ .alloc = alloc };
    const root_only = try p.build(s);
    return .{
        .nodes = p.nodes.items,
        .root_only = root_only,
        .single_quote = p.single_quote,
        .double_quote = p.double_quote,
    };
}

// ----------------------------------------------------------------------
// JSON parse / navigate / serialize helpers (std.json)
// ----------------------------------------------------------------------

/// Parse JSON keeping numbers as exact source text; null on invalid input.
fn parseJson(alloc: std.mem.Allocator, s: []const u8) ?std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, s, .{ .parse_numbers = false }) catch null;
}

/// Navigate the parsed path over a value tree. Returns the matched sub-value,
/// or null when a selector/index does not resolve.
fn navigate(root: std.json.Value, path: Path) ?std.json.Value {
    var cur = root;
    for (path.nodes) |node| {
        switch (node) {
            .selector => |name| {
                if (cur != .object) return null;
                cur = cur.object.get(name) orelse return null;
            },
            .index => |idx| {
                if (cur != .array) return null;
                if (idx < 0) return null;
                const u: usize = @intCast(idx);
                if (u >= cur.array.items.len) return null;
                cur = cur.array.items[u];
            },
        }
    }
    return cur;
}

/// Minified JSON serialization (verbatim numbers, preserved key order).
fn stringifyCompact(alloc: std.mem.Allocator, v: std.json.Value) Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, v, .{});
}

/// fmt.Sprint of a JSON scalar: strings/numbers/bools become their bare text.
fn scalarText(alloc: std.mem.Allocator, v: std.json.Value) Error![]const u8 {
    return switch (v) {
        .string => |s| s,
        .number_string => |s| s,
        .integer => |i| try std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| blk: {
            var buf: [32]u8 = undefined;
            break :blk try alloc.dupe(u8, value_mod.formatFloatGo(&buf, f));
        },
        .bool => |b| if (b) "true" else "false",
        .null => "null",
        else => "",
    };
}

fn isContainer(v: std.json.Value) bool {
    return v == .object or v == .array;
}

// ----------------------------------------------------------------------
// JSON_EXTRACT family (legacy path) vs JSON_QUERY family (standard path)
// ----------------------------------------------------------------------

/// legacy = JSON_EXTRACT* (rejects double-quote selectors);
/// standard = JSON_QUERY/VALUE* (rejects single-quote selectors).
const PathMode = enum { legacy, standard };

const Doc = struct { root: std.json.Value, path: Path };

fn extractDoc(alloc: std.mem.Allocator, args: []const Value, mode: PathMode) Error!Doc {
    const path_str = try args[1].toString(alloc);
    const path = parsePath(alloc, path_str) catch
        return bind.fail("JSON path: invalid path {s}", .{path_str}, error.FailedConversion);
    switch (mode) {
        .legacy => if (path.double_quote)
            return bind.fail("JSON legacy path: doesn't use double quote path selector", .{}, error.FailedConversion),
        .standard => if (path.single_quote)
            return bind.fail("JSON standard path: doesn't use single quote path selector", .{}, error.FailedConversion),
    }
    const v = try args[0].toString(alloc);
    const root = parseJson(alloc, v) orelse return bind.fail("invalid json: {s}", .{v}, error.FailedConversion);
    return .{ .root = root, .path = path };
}

/// Shared body of JSON_EXTRACT / JSON_QUERY: returns the matched sub-tree as a
/// JsonValue (compacted), or NULL for a miss / a JSON `null` match.
fn extractJson(alloc: std.mem.Allocator, args: []const Value, mode: PathMode) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const doc = try extractDoc(alloc, args, mode);
    const matched = navigate(doc.root, doc.path) orelse return null_v;
    const s = try stringifyCompact(alloc, matched);
    if (std.mem.eql(u8, s, "null")) return null_v;
    return Value{ .json = s };
}

/// Shared body of JSON_EXTRACT_SCALAR / JSON_VALUE: returns the matched scalar
/// as a StringValue, or NULL for a miss / container / JSON null.
fn extractScalar(alloc: std.mem.Allocator, args: []const Value, mode: PathMode) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const doc = try extractDoc(alloc, args, mode);
    const matched = navigate(doc.root, doc.path) orelse return null_v;
    if (isContainer(matched) or matched == .null) return null_v;
    return Value{ .string = try alloc.dupe(u8, try scalarText(alloc, matched)) };
}

/// Shared body of JSON_EXTRACT_ARRAY / JSON_QUERY_ARRAY: each element becomes a
/// JsonValue (compacted). Non-array match -> NULL.
fn extractArray(alloc: std.mem.Allocator, args: []const Value, mode: PathMode) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const doc = try extractDoc(alloc, args, mode);
    const matched = navigate(doc.root, doc.path) orelse return null_v;
    if (matched != .array) return null_v;
    const items = matched.array.items;
    const out = try alloc.alloc(Value, items.len);
    for (items, 0..) |elem, i| {
        if (elem == .null) {
            out[i] = null_v;
        } else {
            out[i] = Value{ .json = try stringifyCompact(alloc, elem) };
        }
    }
    return value_mod.arrayValue(alloc, out);
}

/// Shared body of JSON_EXTRACT_STRING_ARRAY / JSON_VALUE_ARRAY: each scalar
/// element becomes a StringValue. Invalid JSON, non-array match, or any
/// container element -> NULL (whole result).
fn extractStringArray(alloc: std.mem.Allocator, args: []const Value, mode: PathMode) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const path_str = try args[1].toString(alloc);
    const path = parsePath(alloc, path_str) catch return null_v;
    switch (mode) {
        .legacy => if (path.double_quote) return null_v,
        .standard => if (path.single_quote) return null_v,
    }
    const v = try args[0].toString(alloc);
    // Invalid JSON is ignored (Go: return nil, nil).
    const root = parseJson(alloc, v) orelse return null_v;
    const matched = navigate(root, path) orelse return null_v;
    if (matched != .array) return null_v;
    const items = matched.array.items;
    const out = try alloc.alloc(Value, items.len);
    for (items, 0..) |elem, i| {
        if (isContainer(elem)) return null_v;
        if (elem == .null) {
            out[i] = null_v;
        } else {
            out[i] = Value{ .string = try alloc.dupe(u8, try scalarText(alloc, elem)) };
        }
    }
    return value_mod.arrayValue(alloc, out);
}

// Public bind entry points ------------------------------------------------

pub fn jsonExtract(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractJson(alloc, args, .legacy);
}
pub fn jsonQuery(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractJson(alloc, args, .standard);
}
pub fn jsonExtractScalar(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractScalar(alloc, args, .legacy);
}
pub fn jsonValue(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractScalar(alloc, args, .standard);
}
pub fn jsonExtractArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractArray(alloc, args, .legacy);
}
pub fn jsonQueryArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractArray(alloc, args, .standard);
}
pub fn jsonExtractStringArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractStringArray(alloc, args, .legacy);
}
pub fn jsonValueArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return extractStringArray(alloc, args, .standard);
}

// ----------------------------------------------------------------------
// GET_JSON_FIELD ("$.<name>") and SUBSCRIPT ("$[i]" / "$.<name>")
// ----------------------------------------------------------------------

/// Extract a single field/element from a JSON value; returns raw JsonValue
/// (Go JSON_FIELD / JSON_SUBSCRIPT return the extracted bytes verbatim).
fn jsonSingle(alloc: std.mem.Allocator, v: []const u8, node: PathNode) Error!Value {
    const root = parseJson(alloc, v) orelse return null_v;
    const path = Path{ .nodes = &.{node}, .root_only = false, .single_quote = false, .double_quote = false };
    const matched = navigate(root, path) orelse return null_v;
    return Value{ .json = try stringifyCompact(alloc, matched) };
}

pub fn getJsonField(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const v = try args[0].toString(alloc);
    const field = try args[1].toString(alloc);
    return jsonSingle(alloc, v, .{ .selector = field });
}

pub fn subscript(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const v = try args[0].toString(alloc);
    const inner = if (args[1] == .safe) args[1].safe.* else args[1];
    const node: PathNode = switch (inner) {
        .int => |i| .{ .index = i },
        else => .{ .selector = try args[1].toString(alloc) },
    };
    return jsonSingle(alloc, v, node);
}

// ----------------------------------------------------------------------
// PARSE_JSON / TO_JSON / TO_JSON_STRING / JSON_TYPE + scalar accessors
// ----------------------------------------------------------------------

pub fn parseJsonFn(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (bind.existsNull(args)) return null_v;
    const s = try args[0].toString(alloc);
    // Validate, but return the original text (Go PARSE_JSON returns the input
    // verbatim; object key order is preserved).
    if (parseJson(alloc, s) == null) return bind.fail("PARSE_JSON: invalid json {s}", .{s}, error.FailedConversion);
    return Value{ .json = try alloc.dupe(u8, s) };
}

pub fn toJson(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1 and args.len != 2)
        return bind.fail("TO_JSON: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    return Value{ .json = try args[0].toJson(alloc) };
}

pub fn toJsonString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1 and args.len != 2)
        return bind.fail("TO_JSON_STRING: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    // Go: a NULL second arg (pretty-print) yields NULL; a NULL first arg
    // yields the string "null".
    if (args.len == 2 and args[1] == .@"null") return null_v;
    if (args[0] == .@"null") return Value{ .string = try alloc.dupe(u8, "null") };
    return Value{ .string = try args[0].toJson(alloc) };
}

pub fn jsonType(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1)
        return bind.fail("JSON_TYPE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    const inner = if (args[0] == .safe) args[0].safe.* else args[0];
    const raw = switch (inner) {
        .json => |s| s,
        else => return bind.fail("JSON_TYPE: failed to convert to JSON value", .{}, error.FailedConversion),
    };
    if (std.mem.eql(u8, raw, "null")) return Value{ .string = try alloc.dupe(u8, "null") };
    const parsed = parseJson(alloc, raw) orelse return bind.fail("JSON_TYPE: invalid json {s}", .{raw}, error.FailedConversion);
    const t: []const u8 = switch (parsed) {
        .null => "null",
        .bool => "boolean",
        .integer, .float, .number_string => "number",
        .string => "string",
        .array => "array",
        .object => "object",
    };
    return Value{ .string = try alloc.dupe(u8, t) };
}

/// BOOL / INT64 / FLOAT64 (1-arg) JSON accessors: pass the JSON value through;
/// the output column type drives the ToBool/ToInt64/ToFloat64 coercion in the
/// result-cell renderer (mirrors Go's bindBool/bindInt64/bindFloat64).
pub fn jsonBool(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("BOOL: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    return args[0];
}

pub fn jsonInt64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    _ = alloc;
    if (args.len != 1) return bind.fail("INT64: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    return args[0];
}

/// FLOAT64: the one-arg form is a passthrough; the two-arg form (wide_number
/// _mode) resolves to DOUBLE in go-googlesql and delegates to jsonDouble.
pub fn jsonFloat64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return switch (args.len) {
        1 => args[0],
        2 => jsonDouble(alloc, args),
        else => bind.fail("FLOAT64: invalid argument num {d}", .{args.len}, error.UnsupportedOperation),
    };
}

pub fn jsonDouble(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 2) return bind.fail("FLOAT64: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    const mode = try args[1].toString(alloc);
    if (std.mem.eql(u8, mode, "exact") or std.mem.eql(u8, mode, "round")) return args[0];
    return bind.fail("unexpected wide_number_mode: {s}", .{mode}, error.UnsupportedOperation);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn testPath(s: []const u8) !Path {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    return parsePath(arena.allocator(), s);
}

test "parsePath basic member and index" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parsePath(arena.allocator(), "$.class.students[0].name");
    try testing.expectEqual(@as(usize, 4), p.nodes.len);
    try testing.expectEqualStrings("class", p.nodes[0].selector);
    try testing.expectEqualStrings("students", p.nodes[1].selector);
    try testing.expectEqual(@as(i64, 0), p.nodes[2].index);
    try testing.expectEqualStrings("name", p.nodes[3].selector);
    try testing.expect(!p.single_quote and !p.double_quote);
}

test "parsePath quote selectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const single = try parsePath(arena.allocator(), "$['a.b'].c");
    try testing.expect(single.single_quote and !single.double_quote);
    try testing.expectEqualStrings("a.b", single.nodes[0].selector);
    try testing.expectEqualStrings("c", single.nodes[1].selector);

    const dbl = try parsePath(arena.allocator(), "$.\"a.b\".c");
    try testing.expect(dbl.double_quote and !dbl.single_quote);
    try testing.expectEqualStrings("a.b", dbl.nodes[0].selector);
}

test "parsePath root only" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try parsePath(arena.allocator(), "$");
    try testing.expect(p.root_only);
    try testing.expectEqual(@as(usize, 0), p.nodes.len);
}

fn jsonArg(s: []const u8) Value {
    return Value{ .json = s };
}
fn strArg(s: []const u8) Value {
    return Value{ .string = s };
}

test "jsonExtract compacts and navigates" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{
        jsonArg("{\"class\":{\"students\":[{\"id\":5},{\"id\":12}]}}"),
        strArg("$.class"),
    };
    const r = try jsonExtract(a, &args);
    try testing.expectEqualStrings("{\"students\":[{\"id\":5},{\"id\":12}]}", r.json);
}

test "jsonExtract whitespace input compacts" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{
        strArg("{\"class\" : {\"students\" : [{\"name\" : \"Jane\"}]}}"),
        strArg("$"),
    };
    const r = try jsonExtract(a, &args);
    try testing.expectEqualStrings("{\"class\":{\"students\":[{\"name\":\"Jane\"}]}}", r.json);
}

test "jsonExtract null result is NULL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{ strArg("{\"a\":null}"), strArg("$.a") };
    try testing.expect((try jsonExtract(a, &args)) == .@"null");
    const args2 = [_]Value{ strArg("{\"a\":null}"), strArg("$.b") };
    try testing.expect((try jsonExtract(a, &args2)) == .@"null");
}

test "jsonExtractScalar" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{ jsonArg("{\"name\":\"Jakob\",\"age\":\"6\"}"), strArg("$.age") };
    const r = try jsonExtractScalar(a, &args);
    try testing.expectEqualStrings("6", r.string);
    // array target -> NULL
    const args2 = [_]Value{ strArg("{\"fruits\":[\"apple\",\"banana\"]}"), strArg("$.fruits") };
    try testing.expect((try jsonExtractScalar(a, &args2)) == .@"null");
}

test "jsonExtractArray produces JsonValue elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{ jsonArg("{\"fruits\":[\"apples\",\"oranges\"]}"), strArg("$.fruits") };
    const r = try jsonExtractArray(a, &args);
    try testing.expectEqual(@as(usize, 2), r.array.values.len);
    try testing.expectEqualStrings("\"apples\"", r.array.values[0].json);
}

test "jsonExtractStringArray unquotes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{ jsonArg("{\"fruits\":[\"apples\",\"oranges\"]}"), strArg("$.fruits") };
    const r = try jsonExtractStringArray(a, &args);
    try testing.expectEqualStrings("apples", r.array.values[0].string);
    // invalid json -> NULL
    const bad = [_]Value{ strArg("}}"), strArg("$") };
    try testing.expect((try jsonExtractStringArray(a, &bad)) == .@"null");
    // nested object element -> NULL
    const nested = [_]Value{ strArg("{\"a\":[{\"b\":1}]}"), strArg("$.a") };
    try testing.expect((try jsonExtractStringArray(a, &nested)) == .@"null");
}

test "parseJsonFn preserves order" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const args = [_]Value{strArg("{\"coordinates\":[10,20],\"id\":1}")};
    const r = try parseJsonFn(a, &args);
    try testing.expectEqualStrings("{\"coordinates\":[10,20],\"id\":1}", r.json);
}

test "toJson and toJsonString of struct" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const st = try value_mod.structValue(a, &.{ "id", "coordinates" }, &.{
        Value{ .int = 1 },
        try value_mod.arrayValue(a, &.{ Value{ .int = 10 }, Value{ .int = 20 } }),
    });
    const j = try toJson(a, &.{st});
    try testing.expectEqualStrings("{\"id\":1,\"coordinates\":[10,20]}", j.json);
    const s = try toJsonString(a, &.{st});
    try testing.expectEqualStrings("{\"id\":1,\"coordinates\":[10,20]}", s.string);
    // NULL -> "null"
    const n = try toJsonString(a, &.{null_v});
    try testing.expectEqualStrings("null", n.string);
}

test "jsonType" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("string", (try jsonType(a, &.{jsonArg("\"apple\"")})).string);
    try testing.expectEqualStrings("number", (try jsonType(a, &.{jsonArg("10")})).string);
    try testing.expectEqualStrings("null", (try jsonType(a, &.{jsonArg("null")})).string);
    try testing.expectEqualStrings("object", (try jsonType(a, &.{jsonArg("{\"a\":1}")})).string);
    try testing.expectEqualStrings("array", (try jsonType(a, &.{jsonArg("[1,2]")})).string);
    try testing.expectEqualStrings("boolean", (try jsonType(a, &.{jsonArg("false")})).string);
}

test "getJsonField and subscript" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = "{\"class\":{\"students\":[{\"name\":\"Jane\"}]}}";
    const f1 = try getJsonField(a, &.{ jsonArg(doc), strArg("class") });
    try testing.expectEqualStrings("{\"students\":[{\"name\":\"Jane\"}]}", f1.json);
    const students = try getJsonField(a, &.{ f1, strArg("students") });
    const first = try subscript(a, &.{ students, Value{ .int = 0 } });
    const name = try subscript(a, &.{ first, strArg("name") });
    try testing.expectEqualStrings("\"Jane\"", name.json);
}
