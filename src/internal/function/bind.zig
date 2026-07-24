//! Port of go-zetasqlite internal/function_bind.go (foundation scope): the
//! FuncInfo table mapping GoogleSQL function names to bind handlers.
//!
//! Go's setupNormalFuncMap registers each entry twice:
//!   zetasqlite_<name>       -> BindFunc (errors surface as SQL errors)
//!   zetasqlite_safe_<name>  -> SafeFunc orelse BindFunc (errors -> NULL)
//! register.zig mirrors that; this file only owns the table + shared helpers.

const std = @import("std");

pub const value_mod = @import("../value.zig");
pub const Value = value_mod.Value;
pub const Error = value_mod.ValueError;

pub const Handler = *const fn (alloc: std.mem.Allocator, args: []const Value) Error!Value;

pub const FuncInfo = struct {
    name: [:0]const u8,
    /// Arguments the handler indexes without checking (Go would panic below
    /// this count; we surface an error instead of UB).
    min_args: u8 = 0,
    handler: Handler,
    /// Go FuncInfo.SafeFunc: replaces handler for the safe_ variant.
    safe_handler: ?Handler = null,
};

// ----------------------------------------------------------------------
// Error message plumbing. Go returns fmt.Errorf strings through the sqlite
// driver; we format into a threadlocal buffer that register.zig hands to
// sqlite3_result_error. value.zig keeps its own (static-string) diagnostic.
// ----------------------------------------------------------------------

threadlocal var msg_buf: [512]u8 = undefined;
pub threadlocal var message: ?[]const u8 = null;

pub fn clearDiagnostics() void {
    message = null;
    value_mod.diagnostic = null;
}

/// Formats a Go-style error message and returns `err`.
pub fn fail(comptime fmt: []const u8, args: anytype, err: Error) Error {
    message = std.fmt.bufPrint(&msg_buf, fmt, args) catch fmt;
    return err;
}

/// Copies a runtime message (e.g. the argument of ERROR()) and returns `err`.
pub fn failMsg(msg: []const u8, err: Error) Error {
    const n = @min(msg.len, msg_buf.len);
    @memcpy(msg_buf[0..n], msg[0..n]);
    message = msg_buf[0..n];
    return err;
}

/// Go function.go existsNull: any SQL NULL among the arguments.
pub fn existsNull(args: []const Value) bool {
    for (args) |v| {
        if (v == .@"null") return true;
    }
    return false;
}

// ----------------------------------------------------------------------
// The table (Go: normalFuncs, foundation subset). Names are exactly the Go
// map keys; the extractor normalizes $add/$subtract/... to these.
// ----------------------------------------------------------------------

const math = @import("fn_math.zig");
const cmp = @import("fn_compare.zig");
const str = @import("fn_string.zig");
const arr = @import("fn_array.zig");
const misc = @import("fn_misc.zig");

pub const func_table = [_]FuncInfo{
    // arithmetic (Go: bindAdd/bindSub/bindMul/bindOpDiv + SAFE_* funcs)
    .{ .name = "add", .min_args = 2, .handler = math.add, .safe_handler = math.safeAdd },
    .{ .name = "subtract", .min_args = 2, .handler = math.sub, .safe_handler = math.safeSubtract },
    .{ .name = "multiply", .min_args = 2, .handler = math.mul, .safe_handler = math.safeMultiply },
    .{ .name = "divide", .min_args = 2, .handler = math.opDiv, .safe_handler = math.safeDivide },

    // comparisons
    .{ .name = "equal", .min_args = 2, .handler = cmp.equal },
    .{ .name = "not_equal", .min_args = 2, .handler = cmp.notEqual },
    .{ .name = "greater", .min_args = 2, .handler = cmp.greater },
    .{ .name = "greater_or_equal", .min_args = 2, .handler = cmp.greaterOrEqual },
    .{ .name = "less", .min_args = 2, .handler = cmp.less },
    .{ .name = "less_or_equal", .min_args = 2, .handler = cmp.lessOrEqual },

    // bit operations
    .{ .name = "bitwise_not", .min_args = 1, .handler = math.bitNot },
    .{ .name = "bitwise_left_shift", .min_args = 2, .handler = math.bitLeftShift },
    .{ .name = "bitwise_right_shift", .min_args = 2, .handler = math.bitRightShift },
    .{ .name = "bitwise_and", .min_args = 2, .handler = math.bitAnd },
    .{ .name = "bitwise_or", .min_args = 2, .handler = math.bitOr },
    .{ .name = "bitwise_xor", .min_args = 2, .handler = math.bitXor },

    // array / struct access
    .{ .name = "in_array", .min_args = 2, .handler = arr.inArray },
    .{ .name = "get_struct_field", .min_args = 2, .handler = arr.structField },
    .{ .name = "array_at_offset", .min_args = 2, .handler = arr.arrayAtOffset, .safe_handler = arr.safeArrayAtOffset },
    .{ .name = "array_at_ordinal", .min_args = 2, .handler = arr.arrayAtOrdinal, .safe_handler = arr.safeArrayAtOrdinal },
    .{ .name = "safe_negate", .min_args = 1, .handler = math.safeNegate },
    .{ .name = "is_distinct_from", .min_args = 2, .handler = cmp.isDistinctFrom },
    .{ .name = "is_not_distinct_from", .min_args = 2, .handler = cmp.isNotDistinctFrom },

    // debugging
    .{ .name = "error", .min_args = 1, .handler = misc.errorFn },

    // predicates / conditionals
    .{ .name = "like", .min_args = 2, .handler = cmp.like },
    .{ .name = "between", .min_args = 3, .handler = cmp.between },
    .{ .name = "in", .min_args = 1, .handler = cmp.in },
    .{ .name = "is_null", .min_args = 1, .handler = cmp.isNull },
    .{ .name = "is_true", .min_args = 1, .handler = cmp.isTrue },
    .{ .name = "is_false", .min_args = 1, .handler = cmp.isFalse },
    .{ .name = "not", .min_args = 1, .handler = cmp.not },
    .{ .name = "and", .handler = cmp.@"and" },
    .{ .name = "or", .handler = cmp.@"or" },
    .{ .name = "coalesce", .handler = cmp.coalesce },
    .{ .name = "if", .handler = cmp.@"if" },
    .{ .name = "ifnull", .handler = cmp.ifnull },
    .{ .name = "nullif", .handler = cmp.nullif },
    .{ .name = "length", .handler = str.length },
    .{ .name = "cast", .handler = misc.cast },

    // string functions
    .{ .name = "concat", .handler = str.concat },
    .{ .name = "left", .handler = str.left },
    .{ .name = "lower", .handler = str.lower },
    .{ .name = "right", .min_args = 2, .handler = str.right },
    .{ .name = "substr", .handler = str.substr },
    .{ .name = "upper", .handler = str.upper },

    // math functions
    .{ .name = "abs", .min_args = 1, .handler = math.abs },
    .{ .name = "round", .handler = math.round },

    // array functions
    .{ .name = "array_concat", .handler = arr.arrayConcat },
    .{ .name = "array_length", .handler = arr.arrayLength },
    .{ .name = "make_array", .handler = arr.makeArray },
    .{ .name = "make_struct", .handler = arr.makeStruct },
};
