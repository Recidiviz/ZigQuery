//! ERROR(), CAST and the PARSE_NUMERIC/PARSE_BIGNUMERIC pair.
//!
//! ERROR() raises its argument as the query's message, so it reaches the caller as the failure
//! rather than as a row.
//!
//! CAST arrives as `zigquery_cast(expr, '<from type JSON>', '<to type JSON>', is_safe)`: the
//! transformer cannot lower a cast to SQLite's own, because the answer depends on GoogleSQL types
//! SQLite has no notion of. Both type documents are applied in turn, the source type first, and
//! `is_safe` turns a failure into NULL rather than raising. conversion_rules.md
//!
//! The two type documents are SQL literals, identical on every row of a scan, so the parsed form
//! is cached against the call site; parsing them per row dominated the cost of a cast.
// ephor:ignore-file ZA302

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = bind.value_mod;
const pb = @import("../../proto/resolved_ast.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.null;

/// NULL message -> NULL, otherwise raise the message verbatim.
pub fn errorFn(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .null) return null_v;
    const msg = try args[0].toString(alloc);
    return bind.failMsg(msg, error.UnsupportedOperation);
}

// ---------------------------------------------------------------------
// CAST. The transformer emits
//   zigquery_cast(expr, '<from Type JSON>', '<to Type JSON>', bool)
// where the Type JSON is spec.Type. Safe casts turn errors into NULL.
// ---------------------------------------------------------------------

pub fn cast(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args.len != 4)
        return bind.fail("CAST: invalid argument num {d}", .{args.len}, error.UnsupportedOperation);
    const is_safe = try args[3].toBool();

    // The two type documents are SQL literals: the same bytes on every row of
    // the scan. Parsing them per row dominated the cost of a cast — see the
    // CachedType docs — so the parsed form is cached against the call site.
    const from_type = try cachedTypeJson(alloc, args[1], 1, "base");
    const to_type = try cachedTypeJson(alloc, args[2], 2, "target");

    const from_value = castValue(alloc, from_type, args[0]) catch |err| {
        if (is_safe) return null_v;
        return err;
    };
    const casted = castValue(alloc, to_type, from_value) catch |err| {
        if (is_safe) return null_v;
        return err;
    };
    return casted;
}

/// A parsed type document, owned by an arena of its own so SQLite can free the
/// whole thing through one destructor.
///
/// Everything the cast needs is reachable from `value`; the arena exists only
/// to be torn down with it.
const CachedType = struct {
    arena: std.heap.ArenaAllocator,
    value: std.json.Value,

    fn destroy(p: ?*anyopaque) callconv(.c) void {
        const self: *CachedType = @ptrCast(@alignCast(p.?));
        const gpa = self.arena.child_allocator;
        self.arena.deinit();
        gpa.destroy(self);
    }
};

/// The parsed form of a type argument, reusing the one cached against this
/// call site when SQLite still has it.
///
/// A miss is always safe: SQLite may discard the entry at any point, and only
/// promises to keep it for arguments that are compile-time constants. When
/// there is no context at all — a direct unit-test call — this is just a parse.
fn cachedTypeJson(
    alloc: std.mem.Allocator,
    arg: Value,
    index: i32,
    comptime what: []const u8,
) Error!std.json.Value {
    if (bind.auxGet(CachedType, index)) |hit| return hit.value;

    const json = try arg.toString(alloc);
    // No call site to cache against — a handler called directly, as the unit
    // tests do. Anything allocated here would have no owner to free it.
    if (bind.current_ctx == null) {
        return parseTypeJson(alloc, json) catch
            return bind.fail("CAST: failed to parse cast " ++ what ++ " type", .{}, error.CorruptData);
    }

    const gpa = std.heap.c_allocator;
    const cached = gpa.create(CachedType) catch
        return parseTypeJson(alloc, json) catch
            return bind.fail("CAST: failed to parse cast " ++ what ++ " type", .{}, error.CorruptData);
    cached.* = .{ .arena = std.heap.ArenaAllocator.init(gpa), .value = undefined };
    cached.value = parseTypeJson(cached.arena.allocator(), json) catch {
        cached.arena.deinit();
        gpa.destroy(cached);
        return bind.fail("CAST: failed to parse cast " ++ what ++ " type", .{}, error.CorruptData);
    };

    // Read the value out first: the destructor may run before auxSet returns.
    const parsed = cached.value;
    bind.auxSet(index, cached, CachedType.destroy);
    return parsed;
}

fn parseTypeJson(alloc: std.mem.Allocator, s: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, alloc, s, .{});
}

// ---------------------------------------------------------------------
// PARSE_NUMERIC / PARSE_BIGNUMERIC:
// take the argument's string form and parses it;
// a form cannot parse raises the error "unexpected numeric literal: <s>".
// ---------------------------------------------------------------------

fn parseNumericImpl(alloc: std.mem.Allocator, args: []const Value, is_big: bool) Error!Value {
    if (args[0] == .null) return null_v;
    const s = try args[0].toString(alloc);
    return value_mod.numericFromString(alloc, s, is_big) catch |err| switch (err) {
        error.NumericOutOfRange => bind.fail(
            "{s} value out of range: {s}",
            .{ if (is_big) "BIGNUMERIC" else "NUMERIC", s },
            error.FailedConversion,
        ),
        else => bind.fail("unexpected numeric literal: {s}", .{s}, error.FailedConversion),
    };
}

pub fn parseNumeric(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return parseNumericImpl(alloc, args, false);
}

pub fn parseBignumeric(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    return parseNumericImpl(alloc, args, true);
}

fn typeKindOf(t: std.json.Value) Error!pb.TypeKind {
    if (t != .object) return error.CorruptData;
    const kind = t.object.get("kind") orelse return error.CorruptData;
    if (kind != .integer) return error.CorruptData;
    return @fromBackingInt(@intCast(kind.integer));
}

/// CAST(STRING AS BOOL): only 'true'/'false', case-insensitively; every other
/// string is an error rather than a value. This is stricter than toBool's
/// other callers (query-parameter coercion, driver value assignment), which
/// also accept "1"/"0"/"t"/"f" and NULL-string-as-false
/// conversion_functions.md#cast_bool.
fn boolForCast(v: Value) Error!bool {
    return switch (v) {
        .string => |s| strictBool(s),
        .bytes => |b| strictBool(b),
        else => v.toBool(),
    };
}

fn strictBool(s: []const u8) Error!bool {
    if (std.ascii.eqlIgnoreCase(s, "true")) return true;
    if (std.ascii.eqlIgnoreCase(s, "false")) return false;
    return bind.fail("failed to parse bool from string", .{}, error.FailedConversion);
}

/// CAST(STRING AS NUMERIC/BIGNUMERIC): unlike numericValue's other callers
/// (query-parameter coercion, arithmetic operand coercion, where an
/// unparseable operand silently contributes zero — see toUnscaled), an
/// unparseable string is an error here. conversion_functions.md#cast_numeric.
fn numericForCast(alloc: std.mem.Allocator, v: Value, is_bignumeric: bool) Error!Value {
    return switch (v) {
        .string => |s| value_mod.numericFromString(alloc, s, is_bignumeric),
        .bytes => |b| value_mod.numericFromString(alloc, b, is_bignumeric),
        else => value_mod.numericValue(alloc, v, is_bignumeric),
    };
}

/// CastValue, foundation kinds. NULL input stays NULL.
fn castValue(alloc: std.mem.Allocator, t: std.json.Value, v: Value) Error!Value {
    if (v == .null) return null_v;
    const kind = try typeKindOf(t);
    switch (kind) {
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64 => {
            return Value{ .int = try v.toInt64() };
        },
        .TYPE_BOOL => return Value{ .bool = try boolForCast(v) },
        .TYPE_FLOAT, .TYPE_DOUBLE => return Value{ .float = try v.toFloat64() },
        .TYPE_STRING, .TYPE_ENUM => {
            return Value{ .string = try v.toString(alloc) };
        },
        .TYPE_BYTES => return Value{ .bytes = try v.toBytes(alloc) },
        .TYPE_JSON => return Value{ .json = try v.toJson(alloc) },
        .TYPE_DATE => switch (v) {
            .date => return v,
            .string => |s| return Value{ .date = try value_mod.parseDateDays(s) },
            .bytes => |b| return Value{ .date = try value_mod.parseDateDays(b) },
            .timestamp, .datetime, .time => return Value{
                .date = @divFloor(try value_mod.toUnixMicros(v), value_mod.day_micros),
            },
            else => return bind.fail("CAST: unimplemented cast to DATE", .{}, error.Unimplemented),
        },
        .TYPE_TIMESTAMP => return Value{ .timestamp = try value_mod.toUnixMicros(v) },
        .TYPE_DATETIME => return Value{ .datetime = try value_mod.toUnixMicros(v) },
        .TYPE_TIME => {
            const micros = try value_mod.toUnixMicros(v);
            return Value{ .time = @mod(micros, value_mod.day_micros) };
        },
        .TYPE_INTERVAL => switch (v) {
            .interval => return v,
            else => return Value{
                .interval = try value_mod.parseIntervalValue(try v.toString(alloc)),
            },
        },
        .TYPE_NUMERIC => return numericForCast(alloc, v, false),
        .TYPE_BIGNUMERIC => return numericForCast(alloc, v, true),
        .TYPE_ARRAY => {
            const arr = try v.toArray();
            const elem_type = if (t == .object)
                (t.object.get("elementType") orelse std.json.Value.null)
            else
                std.json.Value.null;
            const out = try alloc.alloc(Value, arr.values.len);
            for (arr.values, 0..) |elem, i| {
                out[i] = try castValue(alloc, elem_type, elem);
            }
            return value_mod.arrayValue(alloc, out);
        },
        .TYPE_STRUCT => return castToStruct(alloc, t, v),
        else => return bind.fail(
            "CAST: unimplemented cast to type kind {d}",
            .{@backingInt(kind)},
            error.Unimplemented,
        ),
    }
}


/// An ARRAY input flattens into one struct by concatenating each element's fields;
/// anything else is read as a struct and its fields are cast field-by-field,
/// in the target type's field order.
//
/// A field the source does not reach becomes NULL.
fn castToStruct(alloc: std.mem.Allocator, t: std.json.Value, v: Value) Error!Value {
    if (v == .array) {
        const arr = try v.toArray();
        var keys: std.ArrayList([]const u8) = .empty;
        var values: std.ArrayList(Value) = .empty;
        for (arr.values) |elem| {
            const st = try elem.toStruct();
            try keys.appendSlice(alloc, st.keys);
            try values.appendSlice(alloc, st.values);
        }
        return value_mod.structValue(alloc, keys.items, values.items);
    }

    const src = try v.toStruct();
    const field_types: []const std.json.Value = blk: {
        if (t != .object) break :blk &.{};
        const fts = t.object.get("fieldTypes") orelse break :blk &.{};
        if (fts != .array) break :blk &.{};
        break :blk fts.array.items;
    };

    var keys: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList(Value) = .empty;
    for (field_types, 0..) |field, i| {
        var key: []const u8 = "";
        var ftype: std.json.Value = std.json.Value.null;
        if (field == .object) {
            if (field.object.get("name")) |n| {
                if (n == .string) key = n.string;
            }
            ftype = field.object.get("type") orelse std.json.Value.null;
        }
        try keys.append(alloc, key);
        // Field-by-position: the target type supplies the names, the source
        // supplies the values, and the two need not agree.
        // BigQuery says `CAST(STRUCT(1 AS x) AS STRUCT<y INT64>).y` is 1.
        if (i >= src.values.len) {
            try values.append(alloc, null_v);
            continue;
        }
        try values.append(alloc, try castValue(alloc, ftype, src.values[i]));
    }
    return value_mod.structValue(alloc, keys.items, values.items);
}
