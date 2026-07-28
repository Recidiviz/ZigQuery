//! Port of ERROR() (Go function_bind.go bindError) and CAST (Go bindCast +
//! function.go CAST + encoder.go CastValue, foundation type kinds only).

const std = @import("std");
const bind = @import("bind.zig");
const value_mod = bind.value_mod;
const pb = @import("../../proto/resolved_ast.zig");

const Value = bind.Value;
const Error = bind.Error;
const null_v = Value.@"null";

/// Go bindError: NULL message -> NULL, otherwise raise the message verbatim.
pub fn errorFn(alloc: std.mem.Allocator, args: []const Value) Error!Value {
    if (args[0] == .@"null") return null_v;
    const msg = try args[0].toString(alloc);
    return bind.failMsg(msg, error.UnsupportedOperation);
}

// ---------------------------------------------------------------------
// CAST. The transformer emits
//   zetasqlite_cast(expr, '<from Type JSON>', '<to Type JSON>', bool)
// where the Type JSON is spec.Type ({"kind": <TypeKind int>, "elementType":
// {...}, ...}). Go decodes both types and applies CastValue twice
// (from-type first, then to-type); safe casts turn errors into NULL.
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
// PARSE_NUMERIC / PARSE_BIGNUMERIC (Go function_numeric.go + bindParseNumeric):
// take the argument's string form and big.Rat.SetString it; a form Rat cannot
// parse is "unexpected numeric literal: <s>".
// ---------------------------------------------------------------------

fn parseNumericImpl(alloc: std.mem.Allocator, args: []const Value, is_big: bool) Error!Value {
    if (args[0] == .@"null") return null_v;
    const s = try args[0].toString(alloc);
    return value_mod.numericFromString(alloc, s, is_big) catch
        return bind.fail("unexpected numeric literal: {s}", .{s}, error.FailedConversion);
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
    return @enumFromInt(@as(i32, @intCast(kind.integer)));
}

/// Go encoder.go CastValue, foundation kinds. NULL input stays NULL.
fn castValue(alloc: std.mem.Allocator, t: std.json.Value, v: Value) Error!Value {
    if (v == .@"null") return null_v;
    const kind = try typeKindOf(t);
    switch (kind) {
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64 => {
            return Value{ .int = try v.toInt64() };
        },
        .TYPE_BOOL => return Value{ .bool = try v.toBool() },
        .TYPE_FLOAT, .TYPE_DOUBLE => return Value{ .float = try v.toFloat64() },
        .TYPE_STRING, .TYPE_ENUM => {
            // Go formats date/time kinds with dedicated layouts; for the
            // foundation set only DATE exists and its ToString already
            // yields the "2006-01-02" layout.
            return Value{ .string = try v.toString(alloc) };
        },
        .TYPE_BYTES => return Value{ .bytes = try v.toBytes(alloc) },
        // Go CastValue: JsonValue(v.ToJSON()).
        .TYPE_JSON => return Value{ .json = try v.toJson(alloc) },
        // Go CastValue: DATE(v.ToTime()) — the civil date of the instant.
        .TYPE_DATE => switch (v) {
            .date => return v,
            .string => |s| return Value{ .date = try value_mod.parseDateDays(s) },
            .bytes => |b| return Value{ .date = try value_mod.parseDateDays(b) },
            .timestamp, .datetime, .time => return Value{
                .date = @divFloor(try value_mod.toUnixMicros(v), value_mod.day_micros),
            },
            else => return bind.fail("CAST: unimplemented cast to DATE", .{}, error.Unimplemented),
        },
        // Go CastValue: TIMESTAMP/DATETIME/TIME(v.ToTime()). DATETIME shares
        // the unix-micros scale; TIME is the time-of-day remainder.
        .TYPE_TIMESTAMP => return Value{ .timestamp = try value_mod.toUnixMicros(v) },
        .TYPE_DATETIME => return Value{ .datetime = try value_mod.toUnixMicros(v) },
        .TYPE_TIME => {
            const micros = try value_mod.toUnixMicros(v);
            return Value{ .time = @mod(micros, value_mod.day_micros) };
        },
        // Go CastValue: parseInterval(v.ToString()).
        .TYPE_INTERVAL => switch (v) {
            .interval => return v,
            else => return Value{ .interval = try value_mod.parseIntervalValue(try v.toString(alloc)) },
        },
        // Go castValueInternal: NumericValue{Rat: v.ToRat()}, isBigNumeric per
        // the target kind (a numeric input is rewrapped under the new kind).
        .TYPE_NUMERIC => return value_mod.numericValue(alloc, try v.toRat(alloc), false),
        .TYPE_BIGNUMERIC => return value_mod.numericValue(alloc, try v.toRat(alloc), true),
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
        else => return bind.fail(
            "CAST: unimplemented cast to type kind {d}",
            .{@intFromEnum(kind)},
            error.Unimplemented,
        ),
    }
}
