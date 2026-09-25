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
// ephor:ignore-file ZA101 ZA302 ZA303 ZA304 ZA701

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = @import("../value.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

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
                const idx = std.fmt.parseInt(i64, buf[0..cursor], 10) catch
                    return error.InvalidPath;
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
    return std.json.parseFromSliceLeaky(
        std.json.Value,
        alloc,
        s,
        .{ .parse_numbers = false },
    ) catch null;
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

/// Minified JSON with object keys in **byte order**, which is what BigQuery's
/// JSON type stores: `JSON_OBJECT('B',1,'a',2)` answers `{"B":1,"a":2}` and
/// `JSON_OBJECT('_x',1,'A',2,'a',3)` answers `{"A":2,"_x":1,"a":3}` — 'A' (65)
/// before '_' (95) before 'a' (97), so it is a plain memcmp, not a collation.
///
/// `stringifyCompact` above preserves insertion order (Go's ObjectMap is
/// insertion-ordered, and go-zetasqlite matches it). Everything this file
/// *constructs* goes through here instead; the extract family keeps the
/// verbatim ordering of the document it was handed.
fn stringifySorted(alloc: std.mem.Allocator, v: std.json.Value) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeSorted(alloc, &out, v);
    return out.toOwnedSlice(alloc);
}

fn writeSorted(alloc: std.mem.Allocator, out: *std.ArrayList(u8), v: std.json.Value) Error!void {
    switch (v) {
        .object => |o| {
            const keys = try alloc.dupe([]const u8, o.keys());
            std.mem.sort([]const u8, keys, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lt);
            try out.append(alloc, '{');
            for (keys, 0..) |k, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, try stringifyCompact(alloc, .{ .string = k }));
                try out.append(alloc, ':');
                try writeSorted(alloc, out, o.get(k).?);
            }
            try out.append(alloc, '}');
        },
        .array => |a| {
            try out.append(alloc, '[');
            for (a.items, 0..) |elem, i| {
                if (i > 0) try out.append(alloc, ',');
                try writeSorted(alloc, out, elem);
            }
            try out.append(alloc, ']');
        },
        else => try out.appendSlice(alloc, try stringifyCompact(alloc, v)),
    }
}

/// Re-serialize JSON text with sorted keys. The constructors and mutators build
/// their result as text and normalize it here in one pass, so nested objects
/// coming in from arguments get sorted too.
fn canonicalJson(alloc: std.mem.Allocator, text: []const u8) Error!Value {
    const parsed = parseJson(alloc, text) orelse
        return bind.fail("invalid json: {s}", .{text}, error.FailedConversion);
    return Value{ .json = try stringifySorted(alloc, parsed) };
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
    const path = Path{
        .nodes = &.{node},
        .root_only = false,
        .single_quote = false,
        .double_quote = false,
    };
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
    if (args.len == 2 and args[1] == .null) return null_v;
    if (args[0] == .null) return Value{ .string = try alloc.dupe(u8, "null") };
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
    const parsed = parseJson(alloc, raw) orelse return bind.fail(
        "JSON_TYPE: invalid json {s}",
        .{raw},
        error.FailedConversion,
    );
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
// LAX_BOOL / LAX_INT64 / LAX_FLOAT64 / LAX_STRING
//
// Unlike BOOL/INT64/FLOAT64 above, these cannot be pass-throughs: a lax
// conversion that does not apply yields SQL NULL rather than an error, and the
// result-cell coercion has no way to express that. Rules ported from
// googlesql/public/functions/json.cc:652-751 (LaxConvertJsonTo*), every row
// below checked against BigQuery.
// ----------------------------------------------------------------------

/// The five shapes every lax conversion switches on. `parseJson` keeps numbers
/// as their exact source text (`parse_numbers = false`), so "integer or not" is
/// a question about the text; `.other` covers JSON null, arrays and objects,
/// none of which any lax conversion accepts.
const LaxScalar = union(enum) {
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    other,
};

/// Decimal text -> number, preferring an exact i64 so that
/// LAX_STRING(JSON '9223372036854775807') keeps all its digits.
fn laxNumber(text: []const u8) LaxScalar {
    if (std.fmt.parseInt(i64, text, 10)) |i| return .{ .int = i } else |_| {}
    if (std.fmt.parseFloat(f64, text)) |f| return .{ .float = f } else |_| {}
    return .other;
}

fn laxScalarOf(v: std.json.Value) LaxScalar {
    return switch (v) {
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |t| laxNumber(t),
        .string => |s| .{ .string = s },
        else => .other,
    };
}

/// BigQuery rounds half away from zero on the way to INT64
/// (LAX_INT64(JSON '2.5') -> 3, LAX_INT64(JSON '-2.5') -> -3) and answers NULL
/// rather than erroring when the value will not fit.
fn laxFloatToInt(f: f64) ?i64 {
    if (std.math.isNan(f) or std.math.isInf(f)) return null;
    const r = @round(f);
    if (r < -9223372036854775808.0 or r >= 9223372036854775808.0) return null;
    return @intFromFloat(r);
}

/// A numeric string: whitespace-tolerant (`LAX_INT64(JSON '" 42 "')` -> 42),
/// unlike the boolean spelling (`LAX_BOOL(JSON '" true "')` -> NULL).
///
/// Zig's parseFloat also accepts hex-float syntax, so "0x10" would come back as
/// 16; BigQuery answers NULL. Screen the spelling rather than the value —
/// numbers arriving from the document itself are JSON syntax and never hex.
fn laxParseNumeric(s: []const u8) LaxScalar {
    const t = std.mem.trim(u8, s, &std.ascii.whitespace);
    const body = if (t.len > 0 and (t[0] == '+' or t[0] == '-')) t[1..] else t;
    if (body.len > 1 and body[0] == '0' and (body[1] == 'x' or body[1] == 'X')) return .other;
    return laxNumber(t);
}

/// Unwraps a JSON-typed argument. `null` means SQL NULL in, SQL NULL out.
fn jsonDoc(alloc: std.mem.Allocator, v: Value, comptime name: []const u8) Error!?std.json.Value {
    const inner = if (v == .safe) v.safe.* else v;
    if (inner == .null) return null;
    const raw = switch (inner) {
        .json => |s| s,
        else => return bind.fail(name ++ ": failed to convert to JSON value", .{}, error.FailedConversion),
    };
    return parseJson(alloc, raw) orelse
        bind.fail(name ++ ": invalid json {s}", .{raw}, error.FailedConversion);
}

fn laxInput(
    alloc: std.mem.Allocator,
    args: []const Value,
    comptime name: []const u8,
) Error!?std.json.Value {
    if (args.len != 1)
        return bind.fail(name ++ ": invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    return jsonDoc(alloc, args[0], name);
}

pub fn laxBool(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    const v = try laxInput(alloc, args, "LAX_BOOL") orelse return null_v;
    return switch (laxScalarOf(v)) {
        .bool => |b| Value{ .bool = b },
        .int => |i| Value{ .bool = i != 0 },
        .float => |f| Value{ .bool = f != 0 },
        // Only the two literal spellings, case-insensitively: "1", "0" and
        // " true " are all NULL.
        .string => |s| if (std.ascii.eqlIgnoreCase(s, "true"))
            Value{ .bool = true }
        else if (std.ascii.eqlIgnoreCase(s, "false"))
            Value{ .bool = false }
        else
            null_v,
        .other => null_v,
    };
}

pub fn laxInt64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    const v = try laxInput(alloc, args, "LAX_INT64") orelse return null_v;
    return switch (laxScalarOf(v)) {
        .bool => |b| Value{ .int = if (b) 1 else 0 },
        .int => |i| Value{ .int = i },
        .float => |f| if (laxFloatToInt(f)) |i| Value{ .int = i } else null_v,
        .string => |s| switch (laxParseNumeric(s)) {
            .int => |i| Value{ .int = i },
            .float => |f| if (laxFloatToInt(f)) |i| Value{ .int = i } else null_v,
            else => null_v,
        },
        .other => null_v,
    };
}

pub fn laxFloat64(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    const v = try laxInput(alloc, args, "LAX_FLOAT64") orelse return null_v;
    return switch (laxScalarOf(v)) {
        // "Note that unlike integers, we don't convert booleans into floats"
        // (json.cc:714) — LAX_FLOAT64(JSON 'true') is NULL, LAX_INT64 is 1.
        .bool => null_v,
        .int => |i| Value{ .float = @floatFromInt(i) },
        .float => |f| Value{ .float = f },
        .string => |s| switch (laxParseNumeric(s)) {
            .int => |i| Value{ .float = @floatFromInt(i) },
            .float => |f| Value{ .float = f },
            else => null_v,
        },
        .other => null_v,
    };
}

pub fn laxString(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    const v = try laxInput(alloc, args, "LAX_STRING") orelse return null_v;
    return switch (laxScalarOf(v)) {
        .bool => |b| Value{ .string = try alloc.dupe(u8, if (b) "true" else "false") },
        .int => |i| Value{ .string = try std.fmt.allocPrint(alloc, "{d}", .{i}) },
        .float => |f| blk: {
            var buf: [32]u8 = undefined;
            // Canonicalize negative zero: LAX_STRING(JSON '-0.0') is "0", even
            // though the document keeps the sign (TO_JSON_STRING(JSON '-0.0')
            // is "-0.0" and LAX_FLOAT64 of it is -0.0).
            const c = if (f == 0) 0.0 else f;
            break :blk Value{ .string = try alloc.dupe(u8, value_mod.formatFloatGo(&buf, c)) };
        },
        .string => |s| Value{ .string = try alloc.dupe(u8, s) },
        .other => null_v,
    };
}

// ----------------------------------------------------------------------
// JSON_ARRAY / JSON_OBJECT
// ----------------------------------------------------------------------

/// JSON_ARRAY(v, ...): each argument converted with the same Value.toJson the
/// TO_JSON family uses. A NULL argument is the JSON null, not a NULL result.
pub fn jsonArray(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '[');
    for (args, 0..) |a, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try a.toJson(alloc));
    }
    try out.append(alloc, ']');
    return canonicalJson(alloc, out.items);
}

/// JSON_OBJECT has two signatures (builtin_function_internal_3.cc:2265):
/// repeated `(key, value)` pairs, and a pair of parallel arrays. The extractor
/// hands us the name only, so they are told apart by the arguments — the paired
/// form's keys are STRING, so an ARRAY in the first slot means the array form.
pub fn jsonObject(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len == 2 and args[0] == .array) return jsonObjectArrays(alloc, args);
    if (args.len % 2 != 0)
        return bind.fail("The number of keys and values must match", .{}, error.UnsupportedOperation);
    var keys: std.ArrayList([]const u8) = .empty;
    var vals: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 2) {
        try appendMember(alloc, &keys, &vals, args[i], args[i + 1]);
    }
    return buildObject(alloc, keys.items, vals.items);
}

fn jsonObjectArrays(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[1] != .array)
        return bind.fail("The number of keys and values must match", .{}, error.UnsupportedOperation);
    const ks = args[0].array.values;
    const vs = args[1].array.values;
    if (ks.len != vs.len)
        return bind.fail("The number of keys and values must match", .{}, error.UnsupportedOperation);
    var keys: std.ArrayList([]const u8) = .empty;
    var vals: std.ArrayList([]const u8) = .empty;
    for (ks, vs) |k, v| try appendMember(alloc, &keys, &vals, k, v);
    return buildObject(alloc, keys.items, vals.items);
}

/// BigQuery keeps the first occurrence of a repeated key:
/// JSON_OBJECT('a',1,'a',2) is `{"a":1}`.
fn appendMember(
    alloc: std.mem.Allocator,
    keys: *std.ArrayList([]const u8),
    vals: *std.ArrayList([]const u8),
    key: Value,
    val: Value,
) Error!void {
    if (key == .null)
        return bind.fail("The JSON key must not be NULL", .{}, error.FailedConversion);
    const k = try key.toString(alloc);
    for (keys.items) |seen| {
        if (std.mem.eql(u8, seen, k)) return;
    }
    try keys.append(alloc, k);
    try vals.append(alloc, try val.toJson(alloc));
}

fn buildObject(alloc: std.mem.Allocator, keys: []const []const u8, vals: []const []const u8) Error!Value {
    var out: std.ArrayList(u8) = .empty;
    try out.append(alloc, '{');
    for (keys, vals, 0..) |k, v, i| {
        if (i > 0) try out.append(alloc, ',');
        try out.appendSlice(alloc, try stringifyCompact(alloc, .{ .string = k }));
        try out.append(alloc, ':');
        try out.appendSlice(alloc, v);
    }
    try out.append(alloc, '}');
    return canonicalJson(alloc, out.items);
}

// ----------------------------------------------------------------------
// JSON_SET / JSON_REMOVE / JSON_STRIP_NULLS / JSON_ARRAY_APPEND /
// JSON_ARRAY_INSERT
//
// The extract family above only reads, so `navigate` hands back a value. These
// write, so they need a *slot*: a pointer into the tree that a new value can be
// stored through, plus the auto-vivification BigQuery does on the way down.
// Every rule below was measured against BigQuery, and the recurring one is that
// a path that does not resolve is a **no-op, not an error** — JSON_ARRAY_APPEND
// on a missing key, on a non-array, or JSON_REMOVE of an absent member all hand
// the document back untouched.
//
// The analyzer fills each function's trailing named-only argument with its
// default, so the handlers always see it (checked with --sql):
//   JSON_SET(doc, path, value [, path, value]..., create_if_missing)
//   JSON_REMOVE(doc, path [, path]...)
//   JSON_STRIP_NULLS(doc, path, include_arrays, remove_empty)
//   JSON_ARRAY_APPEND(doc, path, value [, path, value]..., append_each_element)
//   JSON_ARRAY_INSERT(doc, path, value [, path, value]..., insert_each_element)
// ----------------------------------------------------------------------

/// The mutators take standard-syntax paths, so a legacy single-quote selector
/// is refused — BigQuery answers "Invalid token in JSONPath at: ['a']", and it
/// says the same for the negative subscript our parser would otherwise accept.
fn mutatorPath(alloc: std.mem.Allocator, s: []const u8) Error!Path {
    const p = parsePath(alloc, s) catch
        return bind.fail("Invalid token in JSONPath at: {s}", .{s}, error.FailedConversion);
    if (p.single_quote)
        return bind.fail("Invalid token in JSONPath at: {s}", .{s}, error.FailedConversion);
    for (p.nodes) |n| {
        if (n == .index and n.index < 0)
            return bind.fail("Invalid token in JSONPath at: {s}", .{s}, error.FailedConversion);
    }
    return p;
}

/// A SQL value as a JSON tree. SQL NULL becomes the JSON null, which is why
/// JSON_SET(JSON '{"a":1}', '$.a', NULL) is `{"a":null}` and not a NULL result.
fn jsonValueOf(alloc: std.mem.Allocator, v: Value) Error!std.json.Value {
    const text = try v.toJson(alloc);
    return parseJson(alloc, text) orelse
        bind.fail("failed to convert to JSON value: {s}", .{text}, error.FailedConversion);
}

/// Walks `cur` down `nodes` and returns a pointer to the slot the last step
/// names, or null when the path does not resolve.
///
/// With `create`, a missing member is added and an array is padded with nulls
/// to reach the index — JSON_SET(JSON '{}', '$.a[2]', 9) builds
/// `{"a":[null,null,9]}`. Without it, a miss is simply a miss:
/// JSON_SET(JSON '{"a":[1]}', '$.a[3]', 9, create_if_missing=>FALSE) changes
/// nothing. Descending *through* a scalar never resolves either way, which is
/// why JSON_SET(JSON '{"a":1}', '$.a.b', 2) leaves the document alone.
fn slotFor(
    alloc: std.mem.Allocator,
    cur: *std.json.Value,
    nodes: []const PathNode,
    create: bool,
) Error!?*std.json.Value {
    if (nodes.len == 0) return cur;
    switch (nodes[0]) {
        .selector => |name| {
            if (cur.* == .null and create) cur.* = .{ .object = std.json.ObjectMap.empty };
            if (cur.* != .object) return null;
            if (cur.object.getPtr(name) == null) {
                if (!create) return null;
                try cur.object.put(alloc, name, .null);
            }
            return slotFor(alloc, cur.object.getPtr(name).?, nodes[1..], create);
        },
        .index => |idx| {
            if (cur.* == .null and create) cur.* = .{ .array = std.json.Array.init(alloc) };
            if (cur.* != .array) return null;
            const u: usize = @intCast(idx);
            if (u >= cur.array.items.len) {
                if (!create) return null;
                while (cur.array.items.len <= u) try cur.array.append(.null);
            }
            return slotFor(alloc, &cur.array.items[u], nodes[1..], create);
        },
    }
}

/// `append_each_element` / `insert_each_element` spread a **SQL ARRAY** value
/// and nothing else: JSON_ARRAY_APPEND(JSON '[1]', '$', [2,3]) is `[1,2,3]`,
/// but the same call with JSON '[2,3]' is `[1,[2,3]]`.
fn eachElements(alloc: std.mem.Allocator, v: Value, each: bool) Error![]std.json.Value {
    if (each and v == .array) {
        const out = try alloc.alloc(std.json.Value, v.array.values.len);
        for (v.array.values, out) |elem, *dst| dst.* = try jsonValueOf(alloc, elem);
        return out;
    }
    const one = try alloc.alloc(std.json.Value, 1);
    one[0] = try jsonValueOf(alloc, v);
    return one;
}

/// Shared preamble: the document plus the (path, value) pair count, for the
/// three functions built as `doc, pairs..., flag`.
fn pairedArgs(args: []const Value, comptime name: []const u8) Error!void {
    if (args.len < 4 or args.len % 2 != 0)
        return bind.fail(name ++ ": invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
}

pub fn jsonSet(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    try pairedArgs(args, "JSON_SET");
    var root = try jsonDoc(alloc, args[0], "JSON_SET") orelse return null_v;
    const create = try args[args.len - 1].toBool();
    var i: usize = 1;
    while (i + 1 < args.len - 1) : (i += 2) {
        const path = try mutatorPath(alloc, try args[i].toString(alloc));
        if (try slotFor(alloc, &root, path.nodes, create)) |slot|
            slot.* = try jsonValueOf(alloc, args[i + 1]);
    }
    return Value{ .json = try stringifySorted(alloc, root) };
}

pub fn jsonRemove(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len < 2)
        return bind.fail("JSON_REMOVE: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    var root = try jsonDoc(alloc, args[0], "JSON_REMOVE") orelse return null_v;
    for (args[1..]) |p| {
        const path = try mutatorPath(alloc, try p.toString(alloc));
        // The one path JSON_REMOVE refuses, unlike JSON_SET, which happily
        // replaces the whole document through it.
        if (path.nodes.len == 0)
            return bind.fail("The JSONPath cannot be '$'", .{}, error.UnsupportedOperation);
        const last = path.nodes[path.nodes.len - 1];
        const parent = try slotFor(alloc, &root, path.nodes[0 .. path.nodes.len - 1], false) orelse continue;
        switch (last) {
            .selector => |name| if (parent.* == .object) {
                _ = parent.object.orderedRemove(name);
            },
            .index => |idx| if (parent.* == .array) {
                const u: usize = @intCast(idx);
                if (u < parent.array.items.len) _ = parent.array.orderedRemove(u);
            },
        }
    }
    return Value{ .json = try stringifySorted(alloc, root) };
}

const StripOpts = struct { include_arrays: bool, remove_empty: bool };

/// Rebuilds `v` without its JSON nulls. Returns false when the value itself
/// should go: it was a null, or `remove_empty` emptied it. That is how the
/// removal cascades — JSON_STRIP_NULLS(JSON '{"a":{"b":null}}',
/// remove_empty=>TRUE) collapses all the way to a bare `null`.
fn stripNulls(alloc: std.mem.Allocator, v: *std.json.Value, o: StripOpts) Error!bool {
    switch (v.*) {
        .null => return false,
        .object => {
            var kept = std.json.ObjectMap.empty;
            var it = v.object.iterator();
            while (it.next()) |e| {
                var child = e.value_ptr.*;
                if (try stripNulls(alloc, &child, o)) try kept.put(alloc, e.key_ptr.*, child);
            }
            v.* = .{ .object = kept };
            return !(o.remove_empty and kept.count() == 0);
        },
        .array => {
            var kept = std.json.Array.init(alloc);
            for (v.array.items) |item| {
                var child = item;
                const keep = try stripNulls(alloc, &child, o);
                // include_arrays governs only whether a null *element* is
                // dropped. The walk descends either way, so an object nested in
                // an array is still stripped with include_arrays => FALSE:
                // {"a":[{"b":null}]} becomes {"a":[{}]}.
                if (keep or !o.include_arrays) try kept.append(child);
            }
            v.* = .{ .array = kept };
            return !(o.remove_empty and kept.items.len == 0);
        },
        else => return true,
    }
}

pub fn jsonStripNulls(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 4)
        return bind.fail("JSON_STRIP_NULLS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    var root = try jsonDoc(alloc, args[0], "JSON_STRIP_NULLS") orelse return null_v;
    const path = try mutatorPath(alloc, try args[1].toString(alloc));
    const opts = StripOpts{
        .include_arrays = try args[2].toBool(),
        .remove_empty = try args[3].toBool(),
    };
    if (try slotFor(alloc, &root, path.nodes, false)) |slot| {
        // A subtree that strips away entirely becomes the JSON null rather than
        // vanishing from its parent, which is what makes the whole-document
        // case answer `null` instead of SQL NULL.
        if (!try stripNulls(alloc, slot, opts)) slot.* = .null;
    }
    return Value{ .json = try stringifySorted(alloc, root) };
}

pub fn jsonArrayAppend(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    try pairedArgs(args, "JSON_ARRAY_APPEND");
    var root = try jsonDoc(alloc, args[0], "JSON_ARRAY_APPEND") orelse return null_v;
    const each = try args[args.len - 1].toBool();
    var i: usize = 1;
    while (i + 1 < args.len - 1) : (i += 2) {
        const path = try mutatorPath(alloc, try args[i].toString(alloc));
        // No creation: appending at a missing key leaves `{}` as it was. An
        // existing JSON null does become an array, though.
        const slot = try slotFor(alloc, &root, path.nodes, false) orelse continue;
        if (slot.* == .null) slot.* = .{ .array = std.json.Array.init(alloc) };
        if (slot.* != .array) continue;
        for (try eachElements(alloc, args[i + 1], each)) |e| try slot.array.append(e);
    }
    return Value{ .json = try stringifySorted(alloc, root) };
}

pub fn jsonArrayInsert(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    try pairedArgs(args, "JSON_ARRAY_INSERT");
    var root = try jsonDoc(alloc, args[0], "JSON_ARRAY_INSERT") orelse return null_v;
    const each = try args[args.len - 1].toBool();
    var i: usize = 1;
    while (i + 1 < args.len - 1) : (i += 2) {
        const path = try mutatorPath(alloc, try args[i].toString(alloc));
        // The last step has to name a position: '$' and a member selector are
        // both no-ops (JSON_ARRAY_INSERT(JSON '[1,2]', '$', 3) is `[1,2]`).
        if (path.nodes.len == 0) continue;
        const at = switch (path.nodes[path.nodes.len - 1]) {
            .index => |idx| @as(usize, @intCast(idx)),
            .selector => continue,
        };
        const slot = try slotFor(alloc, &root, path.nodes[0 .. path.nodes.len - 1], false) orelse continue;
        if (slot.* == .null) slot.* = .{ .array = std.json.Array.init(alloc) };
        if (slot.* != .array) continue;
        // Past the end pads rather than refuses: '$[7]' on a four-element array
        // fills indices 4..6 with nulls and lands the value at 7.
        while (slot.array.items.len < at) try slot.array.append(.null);
        for (try eachElements(alloc, args[i + 1], each), 0..) |e, k| {
            try slot.array.insert(at + k, e);
        }
    }
    return Value{ .json = try stringifySorted(alloc, root) };
}

// ----------------------------------------------------------------------
// JSON_KEYS / JSON_FLATTEN
// ----------------------------------------------------------------------

/// `strict` never descends into arrays; `lax` unwraps one level; `lax
/// recursive` unwraps until a non-array. Spelled with a space, not an
/// underscore — 'lax_recursive' is "Invalid JSON mode specified" in BigQuery.
const KeysMode = enum { strict, lax, lax_recursive };

/// A key joins the dotted path bare unless it would need JSON escaping, or
/// holds a '.' that the path itself uses as a separator: JSON_KEYS(JSON
/// '{"a.b":1}') answers ["\"a.b\""]. Predicate from common/json_util.cc:101
/// plus the '.' rule from public/functions/json.cc EscapeKey.
fn keyNeedsQuoting(k: []const u8) bool {
    for (k) |c| {
        if (c < 0x20 or c == '"' or c == '\\' or c == '.') return true;
    }
    return std.mem.indexOf(u8, k, "\u{2028}") != null or
        std.mem.indexOf(u8, k, "\u{2029}") != null;
}

const KeyWalk = struct {
    alloc: std.mem.Allocator,
    mode: KeysMode,
    /// A sorted set, which is where JSON_KEYS' dedup and ordering come from
    /// (the C++ walker collects into an absl::btree_set).
    keys: *std.StringArrayHashMapUnmanaged(void),

    fn walk(self: KeyWalk, v: std.json.Value, depth: i64, prefix: []const u8) Error!void {
        switch (v) {
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |e| {
                    const k = e.key_ptr.*;
                    const esc = if (keyNeedsQuoting(k))
                        try stringifyCompact(self.alloc, .{ .string = k })
                    else
                        k;
                    const full = if (prefix.len == 0)
                        esc
                    else
                        try std.fmt.allocPrint(self.alloc, "{s}.{s}", .{ prefix, esc });
                    try self.keys.put(self.alloc, full, {});
                    // Only object descents spend depth, which is why
                    // JSON_KEYS(JSON '{"a":[{"b":1}]}', 2, mode=>'lax') still
                    // reaches "a.b".
                    if (depth - 1 > 0) try self.walk(e.value_ptr.*, depth - 1, full);
                }
            },
            .array => |arr| {
                if (self.mode == .strict) return;
                for (arr.items) |elem| {
                    const descend = elem == .object or
                        (elem == .array and self.mode == .lax_recursive);
                    if (descend) try self.walk(elem, depth, prefix);
                }
            },
            else => {},
        }
    }
};

pub fn jsonKeys(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 3)
        return bind.fail("JSON_KEYS: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    if (bind.existsNull(args)) return null_v;
    const max_depth = try args[1].toInt64();
    if (max_depth <= 0)
        return bind.fail("max_depth must be positive. provided value: {d}", .{max_depth}, error.UnsupportedOperation);
    const mode_s = try args[2].toString(alloc);
    const mode: KeysMode = if (std.ascii.eqlIgnoreCase(mode_s, "strict"))
        .strict
    else if (std.ascii.eqlIgnoreCase(mode_s, "lax"))
        .lax
    else if (std.ascii.eqlIgnoreCase(mode_s, "lax recursive"))
        .lax_recursive
    else
        return bind.fail("Invalid JSON mode specified: {s}", .{mode_s}, error.UnsupportedOperation);

    const root = try jsonDoc(alloc, args[0], "JSON_KEYS") orelse return null_v;
    var keys: std.StringArrayHashMapUnmanaged(void) = .empty;
    try (KeyWalk{ .alloc = alloc, .mode = mode, .keys = &keys }).walk(root, max_depth, "");

    const sorted = try alloc.dupe([]const u8, keys.keys());
    std.mem.sort([]const u8, sorted, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    const out = try alloc.alloc(Value, sorted.len);
    for (sorted, out) |k, *dst| dst.* = Value{ .string = k };
    return value_mod.arrayValue(alloc, out);
}

fn flattenInto(alloc: std.mem.Allocator, v: std.json.Value, out: *std.ArrayList(Value)) Error!void {
    if (v == .array) {
        for (v.array.items) |elem| try flattenInto(alloc, elem, out);
        return;
    }
    // A JSON null becomes a NULL element, the same way the extract family
    // renders one; everything else keeps its own JSON text.
    try out.append(alloc, if (v == .null) null_v else Value{ .json = try stringifyCompact(alloc, v) });
}

/// Recursion stops at the first non-array, so `[[{"a":[1]}],2]` flattens to
/// `[{"a":[1]},2]` — the object is an element, not another level. A non-array
/// document is a one-element array, and an empty array contributes nothing.
pub fn jsonFlatten(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 1)
        return bind.fail("JSON_FLATTEN: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    const root = try jsonDoc(alloc, args[0], "JSON_FLATTEN") orelse return null_v;
    var out: std.ArrayList(Value) = .empty;
    try flattenInto(alloc, root, &out);
    return value_mod.arrayValue(alloc, out.items);
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
    try testing.expect((try jsonExtract(a, &args)) == .null);
    const args2 = [_]Value{ strArg("{\"a\":null}"), strArg("$.b") };
    try testing.expect((try jsonExtract(a, &args2)) == .null);
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
    try testing.expect((try jsonExtractScalar(a, &args2)) == .null);
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
    try testing.expect((try jsonExtractStringArray(a, &bad)) == .null);
    // nested object element -> NULL
    const nested = [_]Value{ strArg("{\"a\":[{\"b\":1}]}"), strArg("$.a") };
    try testing.expect((try jsonExtractStringArray(a, &nested)) == .null);
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

// Every expectation below is BigQuery's answer, collected with the bq CLI.

test "laxBool: the two literal spellings, any nonzero number, nothing else" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expect((try laxBool(a, &.{jsonArg("true")})).bool);
    try testing.expect(!(try laxBool(a, &.{jsonArg("false")})).bool);
    try testing.expect((try laxBool(a, &.{jsonArg("2")})).bool);
    try testing.expect(!(try laxBool(a, &.{jsonArg("0")})).bool);
    try testing.expect((try laxBool(a, &.{jsonArg("\"TRUE\"")})).bool);
    try testing.expect((try laxBool(a, &.{jsonArg("\"true\"")})).bool);
    // "1"/"0" are numbers only as JSON numbers, never as JSON strings, and a
    // padded spelling is not trimmed the way a numeric one is.
    try testing.expect(try laxBool(a, &.{jsonArg("\"1\"")}) == .null);
    try testing.expect(try laxBool(a, &.{jsonArg("\" true \"")}) == .null);
    try testing.expect(try laxBool(a, &.{jsonArg("\"abc\"")}) == .null);
    try testing.expect(try laxBool(a, &.{jsonArg("null")}) == .null);
    try testing.expect(try laxBool(a, &.{jsonArg("[]")}) == .null);
    try testing.expect(try laxBool(a, &.{null_v}) == .null);
}

test "laxInt64 rounds half away from zero and NULLs what will not fit" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(i64, 42), (try laxInt64(a, &.{jsonArg("42")})).int);
    try testing.expectEqual(@as(i64, 3), (try laxInt64(a, &.{jsonArg("2.5")})).int);
    try testing.expectEqual(@as(i64, -3), (try laxInt64(a, &.{jsonArg("-2.5")})).int);
    try testing.expectEqual(@as(i64, 4), (try laxInt64(a, &.{jsonArg("\"3.9\"")})).int);
    try testing.expectEqual(@as(i64, 1000), (try laxInt64(a, &.{jsonArg("\"1e3\"")})).int);
    try testing.expectEqual(@as(i64, 42), (try laxInt64(a, &.{jsonArg("\" 42 \"")})).int);
    // A bool converts to INT64 (but not to FLOAT64 — see below).
    try testing.expectEqual(@as(i64, 1), (try laxInt64(a, &.{jsonArg("true")})).int);
    // Exact past the f64 mantissa, because the i64 spelling is tried first.
    try testing.expectEqual(
        @as(i64, 9223372036854775807),
        (try laxInt64(a, &.{jsonArg("\"9223372036854775807\"")})).int,
    );
    try testing.expect(try laxInt64(a, &.{jsonArg("1e100")}) == .null);
    try testing.expect(try laxInt64(a, &.{jsonArg("\"abc\"")}) == .null);
    try testing.expect(try laxInt64(a, &.{jsonArg("\"0x10\"")}) == .null);
}

test "laxFloat64 refuses booleans; laxString renders them" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqual(@as(f64, 3.5), (try laxFloat64(a, &.{jsonArg("3.5")})).float);
    try testing.expectEqual(@as(f64, 42), (try laxFloat64(a, &.{jsonArg("\"42\"")})).float);
    try testing.expectEqual(@as(f64, 1000), (try laxFloat64(a, &.{jsonArg("\"1e3\"")})).float);
    try testing.expect(try laxFloat64(a, &.{jsonArg("true")}) == .null);
    try testing.expect(try laxFloat64(a, &.{jsonArg("\"abc\"")}) == .null);
    try testing.expect(try laxFloat64(a, &.{jsonArg("\"0x10\"")}) == .null);

    try testing.expectEqualStrings("hello", (try laxString(a, &.{jsonArg("\"hello\"")})).string);
    try testing.expectEqualStrings("true", (try laxString(a, &.{jsonArg("true")})).string);
    try testing.expectEqualStrings("42", (try laxString(a, &.{jsonArg("42")})).string);
    try testing.expectEqualStrings("3.14", (try laxString(a, &.{jsonArg("3.14")})).string);
    // A round-trip through the number, not the source text: "3.0" -> "3".
    try testing.expectEqualStrings("3", (try laxString(a, &.{jsonArg("3.0")})).string);
    try testing.expectEqualStrings("1e+100", (try laxString(a, &.{jsonArg("1e100")})).string);
    // Negative zero is canonicalized here, though the document keeps its sign.
    try testing.expectEqualStrings("0", (try laxString(a, &.{jsonArg("-0.0")})).string);
    try testing.expect(try laxString(a, &.{jsonArg("[1]")}) == .null);
}

test "jsonArray and jsonObject build key-sorted documents" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings("[]", (try jsonArray(a, &.{})).json);
    try testing.expectEqualStrings(
        "[1,null,\"x\"]",
        (try jsonArray(a, &.{ Value{ .int = 1 }, null_v, strArg("x") })).json,
    );
    // Byte order, so 'A' (65) < '_' (95) < 'a' (97) — not a collation.
    try testing.expectEqualStrings(
        "{\"A\":2,\"_x\":1,\"a\":3}",
        (try jsonObject(a, &.{
            strArg("_x"), Value{ .int = 1 },
            strArg("A"),  Value{ .int = 2 },
            strArg("a"),  Value{ .int = 3 },
        })).json,
    );
    // A repeated key keeps its first value.
    try testing.expectEqualStrings(
        "{\"a\":1}",
        (try jsonObject(a, &.{ strArg("a"), Value{ .int = 1 }, strArg("a"), Value{ .int = 2 } })).json,
    );
    // The parallel-array signature.
    const ks = try value_mod.arrayValue(a, &.{ strArg("b"), strArg("a") });
    const vs = try value_mod.arrayValue(a, &.{ Value{ .int = 1 }, Value{ .int = 2 } });
    try testing.expectEqualStrings("{\"a\":2,\"b\":1}", (try jsonObject(a, &.{ ks, vs })).json);
    // Nested objects are sorted too, since the result is re-serialized whole.
    try testing.expectEqualStrings(
        "{\"k\":{\"a\":2,\"b\":1}}",
        (try jsonObject(a, &.{ strArg("k"), jsonArg("{\"b\":1,\"a\":2}") })).json,
    );
    try testing.expectError(
        error.UnsupportedOperation,
        jsonObject(a, &.{ try value_mod.arrayValue(a, &.{strArg("a")}), vs }),
    );
}

fn boolArg(b: bool) Value {
    return Value{ .bool = b };
}

test "jsonSet creates, pads and stops at scalars" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct {
        fn set(al: std.mem.Allocator, doc: []const u8, p: []const u8, v: Value, create: bool) ![]const u8 {
            return (try jsonSet(al, &.{ jsonArg(doc), strArg(p), v, boolArg(create) })).json;
        }
    };
    const nine = Value{ .int = 9 };
    // Intermediate objects appear on the way down...
    try testing.expectEqualStrings(
        "{\"a\":1,\"b\":{\"c\":9}}",
        try T.set(a, "{\"a\":1}", "$.b.c", nine, true),
    );
    // ...and a missing key whose next step is an index becomes an array.
    try testing.expectEqualStrings("{\"a\":[null,null,9]}", try T.set(a, "{}", "$.a[2]", nine, true));
    try testing.expectEqualStrings(
        "{\"a\":[1,2,null,null,null,9]}",
        try T.set(a, "{\"a\":[1,2]}", "$.a[5]", nine, true),
    );
    // Descending through a scalar never resolves, create or not.
    try testing.expectEqualStrings("{\"a\":1}", try T.set(a, "{\"a\":1}", "$.a.b", nine, true));
    // create_if_missing => FALSE stops both the key and the padding.
    try testing.expectEqualStrings("{\"a\":1}", try T.set(a, "{\"a\":1}", "$.b", nine, false));
    try testing.expectEqualStrings("{\"a\":[1]}", try T.set(a, "{\"a\":[1]}", "$.a[3]", nine, false));
    try testing.expectEqualStrings("{\"a\":[9]}", try T.set(a, "{\"a\":[1]}", "$.a[0]", nine, false));
    // '$' replaces the whole document, and a SQL NULL is the JSON null.
    try testing.expectEqualStrings("9", try T.set(a, "{\"a\":1}", "$", nine, true));
    try testing.expectEqualStrings("{\"a\":null}", try T.set(a, "{\"a\":1}", "$.a", null_v, true));
    // NULL document in, NULL out.
    try testing.expect(try jsonSet(a, &.{ null_v, strArg("$.a"), nine, boolArg(true) }) == .null);
}

test "jsonRemove shifts array elements and refuses only the root path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try testing.expectEqualStrings(
        "{\"b\":2}",
        (try jsonRemove(a, &.{ jsonArg("{\"a\":1,\"b\":2}"), strArg("$.a") })).json,
    );
    try testing.expectEqualStrings("[1,3]", (try jsonRemove(a, &.{ jsonArg("[1,2,3]"), strArg("$[1]") })).json);
    // A miss is a no-op, not an error — for members and for indices alike.
    try testing.expectEqualStrings("{\"a\":1}", (try jsonRemove(a, &.{ jsonArg("{\"a\":1}"), strArg("$.b") })).json);
    try testing.expectEqualStrings("[1,2,3]", (try jsonRemove(a, &.{ jsonArg("[1,2,3]"), strArg("$[5]") })).json);
    // JSON_SET happily writes through '$'; JSON_REMOVE will not.
    try testing.expectError(
        error.UnsupportedOperation,
        jsonRemove(a, &.{ jsonArg("{\"a\":1}"), strArg("$") }),
    );
    // Standard-syntax paths only, and no negative subscript.
    try testing.expectError(
        error.FailedConversion,
        jsonRemove(a, &.{ jsonArg("{\"a\":1}"), strArg("$['a']") }),
    );
    try testing.expectError(
        error.FailedConversion,
        jsonRemove(a, &.{ jsonArg("[1]"), strArg("$[-1]") }),
    );
}

test "jsonStripNulls cascades, and include_arrays only governs elements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct {
        fn strip(al: std.mem.Allocator, doc: []const u8, p: []const u8, arrays: bool, empty: bool) ![]const u8 {
            return (try jsonStripNulls(al, &.{ jsonArg(doc), strArg(p), boolArg(arrays), boolArg(empty) })).json;
        }
    };
    try testing.expectEqualStrings("{\"b\":1}", try T.strip(a, "{\"a\":null,\"b\":1}", "$", true, false));
    try testing.expectEqualStrings("{\"a\":[1],\"b\":{}}", try T.strip(a, "{\"a\":[null,1],\"b\":{}}", "$", true, false));
    // remove_empty cascades all the way out, so the document becomes JSON null.
    try testing.expectEqualStrings("null", try T.strip(a, "{\"a\":{\"b\":null}}", "$", true, true));
    try testing.expectEqualStrings("null", try T.strip(a, "{\"a\":[]}", "$", true, true));
    // include_arrays => FALSE keeps null *elements*, but still strips objects
    // nested inside the array.
    try testing.expectEqualStrings("{\"a\":[null,1]}", try T.strip(a, "{\"a\":[null,1]}", "$", false, false));
    try testing.expectEqualStrings("{\"a\":[{}]}", try T.strip(a, "{\"a\":[{\"b\":null}]}", "$", false, false));
    // A path confines the work to that subtree.
    try testing.expectEqualStrings(
        "{\"a\":null,\"b\":{}}",
        try T.strip(a, "{\"a\":null,\"b\":{\"c\":null}}", "$.b", true, false),
    );
}

test "jsonArrayAppend and jsonArrayInsert: vivify nulls, never create keys" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const two = Value{ .int = 2 };
    const pair = try value_mod.arrayValue(a, &.{ Value{ .int = 3 }, Value{ .int = 4 } });

    // append_each_element spreads a SQL ARRAY...
    try testing.expectEqualStrings(
        "[1,2,3,4]",
        (try jsonArrayAppend(a, &.{ jsonArg("[1,2]"), strArg("$"), pair, boolArg(true) })).json,
    );
    try testing.expectEqualStrings(
        "[1,2,[3,4]]",
        (try jsonArrayAppend(a, &.{ jsonArg("[1,2]"), strArg("$"), pair, boolArg(false) })).json,
    );
    // ...but never a JSON array, which goes in whole either way.
    try testing.expectEqualStrings(
        "[1,[2,3]]",
        (try jsonArrayAppend(a, &.{ jsonArg("[1]"), strArg("$"), jsonArg("[2,3]"), boolArg(true) })).json,
    );
    // An existing JSON null becomes an array; a missing key does not.
    try testing.expectEqualStrings(
        "{\"a\":[1]}",
        (try jsonArrayAppend(a, &.{ jsonArg("{\"a\":null}"), strArg("$.a"), Value{ .int = 1 }, boolArg(true) })).json,
    );
    try testing.expectEqualStrings(
        "{}",
        (try jsonArrayAppend(a, &.{ jsonArg("{}"), strArg("$.a"), two, boolArg(true) })).json,
    );
    try testing.expectEqualStrings(
        "{\"a\":1}",
        (try jsonArrayAppend(a, &.{ jsonArg("{\"a\":1}"), strArg("$.a"), two, boolArg(true) })).json,
    );

    // Insert pads up to the index rather than refusing it.
    try testing.expectEqualStrings(
        "[1,2,null,null,null,null,null,9]",
        (try jsonArrayInsert(a, &.{ jsonArg("[1,2]"), strArg("$[7]"), Value{ .int = 9 }, boolArg(true) })).json,
    );
    try testing.expectEqualStrings(
        "{\"a\":[null,null,10]}",
        (try jsonArrayInsert(a, &.{ jsonArg("{\"a\":null}"), strArg("$.a[2]"), Value{ .int = 10 }, boolArg(true) })).json,
    );
    // The last step has to name a position: '$' and a selector are no-ops.
    try testing.expectEqualStrings(
        "[1,2]",
        (try jsonArrayInsert(a, &.{ jsonArg("[1,2]"), strArg("$"), Value{ .int = 3 }, boolArg(true) })).json,
    );
    try testing.expectEqualStrings(
        "{\"a\":[1]}",
        (try jsonArrayInsert(a, &.{ jsonArg("{\"a\":[1]}"), strArg("$.a"), Value{ .int = 3 }, boolArg(true) })).json,
    );
    // Nothing is created on the way down, and a scalar root is left alone.
    try testing.expectEqualStrings(
        "{}",
        (try jsonArrayInsert(a, &.{ jsonArg("{}"), strArg("$.a[0]"), Value{ .int = 1 }, boolArg(true) })).json,
    );
    try testing.expectEqualStrings(
        "1",
        (try jsonArrayInsert(a, &.{ jsonArg("1"), strArg("$[0]"), strArg("r1"), boolArg(true) })).json,
    );
}

fn keysOf(alloc: std.mem.Allocator, doc: []const u8, depth: i64, mode: []const u8) ![]const u8 {
    const v = try jsonKeys(alloc, &.{ jsonArg(doc), Value{ .int = depth }, strArg(mode) });
    return (try v.toJson(alloc));
}

test "jsonKeys: dotted paths, sorted and deduplicated" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const deep = std.math.maxInt(i64);
    try testing.expectEqualStrings("[\"a\",\"a.b\",\"a.b.c\"]", try keysOf(a, "{\"a\":{\"b\":{\"c\":1}}}", deep, "strict"));
    // Sorted on the whole path, not per level.
    try testing.expectEqualStrings("[\"a\",\"a.c\",\"a.d\",\"b\"]", try keysOf(a, "{\"b\":1,\"a\":{\"d\":1,\"c\":2}}", deep, "strict"));
    try testing.expectEqualStrings("[]", try keysOf(a, "[1,2]", deep, "strict"));
    // A key holding the separator comes back quoted.
    try testing.expectEqualStrings("[\"\\\"a.b\\\"\"]", try keysOf(a, "{\"a.b\":1}", deep, "strict"));

    // strict stops at arrays; lax unwraps one level; lax recursive keeps going.
    try testing.expectEqualStrings("[\"a\"]", try keysOf(a, "{\"a\":[{\"b\":1}]}", deep, "strict"));
    try testing.expectEqualStrings("[\"a\",\"a.b\",\"a.c\"]", try keysOf(a, "{\"a\":[{\"b\":1},{\"c\":2}]}", deep, "lax"));
    try testing.expectEqualStrings("[\"a\"]", try keysOf(a, "{\"a\":[[{\"b\":1}]]}", deep, "lax"));
    try testing.expectEqualStrings("[\"a\",\"a.b\"]", try keysOf(a, "{\"a\":[[{\"b\":1}]]}", deep, "lax recursive"));

    // Only object descents spend depth, so an array hop is free.
    try testing.expectEqualStrings("[\"a\",\"a.b\"]", try keysOf(a, "{\"a\":{\"b\":{\"c\":1}}}", 2, "strict"));
    try testing.expectEqualStrings("[\"a\",\"a.b\"]", try keysOf(a, "{\"a\":[{\"b\":1}]}", 2, "lax"));

    try testing.expectError(error.UnsupportedOperation, keysOf(a, "{\"a\":1}", 0, "strict"));
    // A space, not an underscore.
    try testing.expectError(error.UnsupportedOperation, keysOf(a, "{\"a\":1}", deep, "lax_recursive"));
}

test "jsonFlatten stops at the first non-array" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const T = struct {
        fn flat(al: std.mem.Allocator, doc: []const u8) ![]const u8 {
            return (try jsonFlatten(al, &.{jsonArg(doc)})).toJson(al);
        }
    };
    try testing.expectEqualStrings("[1,2,3]", try T.flat(a, "[[1],[2,3]]"));
    try testing.expectEqualStrings("[1,2,3,4]", try T.flat(a, "[[[1,2],3],4]"));
    // An object is an element, not another level.
    try testing.expectEqualStrings("[{\"a\":[1]},2]", try T.flat(a, "[[{\"a\":[1]}],2]"));
    try testing.expectEqualStrings("[{\"a\":[1,2]}]", try T.flat(a, "{\"a\":[1,2]}"));
    try testing.expectEqualStrings("[1]", try T.flat(a, "1"));
    // An empty array contributes nothing; a JSON null is a NULL element.
    try testing.expectEqualStrings("[1]", try T.flat(a, "[[],1]"));
    try testing.expectEqualStrings("[null]", try T.flat(a, "null"));
}
