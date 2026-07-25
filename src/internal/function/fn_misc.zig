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
    const from_json = try args[1].toString(alloc);
    const to_json = try args[2].toString(alloc);
    const is_safe = try args[3].toBool();
    const from_type = parseTypeJson(alloc, from_json) catch
        return bind.fail("CAST: failed to parse cast base type", .{}, error.CorruptData);
    const to_type = parseTypeJson(alloc, to_json) catch
        return bind.fail("CAST: failed to parse cast target type", .{}, error.CorruptData);

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
