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
        .TYPE_DATE => switch (v) {
            .date => return v,
            .string => |s| return Value{ .date = try value_mod.parseDateDays(s) },
            .bytes => |b| return Value{ .date = try value_mod.parseDateDays(b) },
            // Go casts via ToTime (timestamps etc.): deferred kinds here.
            else => return bind.fail("CAST: unimplemented cast to DATE", .{}, error.Unimplemented),
        },
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
