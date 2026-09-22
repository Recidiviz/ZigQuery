//! Helpers more than one transformer needs:
//! - `createOrderByItems`, the ORDER BY item list with its collation and null ordering
//! - `newLiteralExpression`, a literal SQLExpression from an already-constructed Value
//! - the CURRENT_* function set, so a deterministic time can be injected at a call site. The
//!   extractor keeps its own copy for name normalization, which runs before any of this.

const std = @import("std");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const types_data = @import("../coordinator/types_data.zig");
const encoder = @import("../encoder.zig");
const value_mod = @import("../value.zig");

pub const Error = types_data.Error;

/// internal/function_register.go currentTimeFuncMap.
/// Only the prefixed names occur: the extractor rewrites the name before the transformer sees it.
pub const current_time_func_names = std.StaticStringMap(void).initComptime(.{
    .{"zigquery_current_date"},
    .{"zigquery_current_datetime"},
    .{"zigquery_current_time"},
    .{"zigquery_current_timestamp"},
});

/// A Value as a literal SQLExpression, through the codec's literal rendering.
pub fn newLiteralExpressionFromValue(
    alloc: std.mem.Allocator,
    v: value_mod.Value,
) Error!*sqlbuilder.SQLExpression {
    const literal = try encoder.LiteralFromValue(alloc, v);
    return sqlbuilder.newLiteralExpression(alloc, literal);
}

/// ORDER BY items, with the null ordering handled explicitly. A NULLS FIRST/LAST modifier
/// becomes an
/// extra `expr IS NOT NULL` term (ASC puts nulls first, DESC last); the main
/// term is emitted for an explicit NULLS FIRST/LAST.
pub fn createOrderByItems(
    alloc: std.mem.Allocator,
    expr: *sqlbuilder.SQLExpression,
    order_data: *const types_data.OrderByItemData,
) Error![]const *sqlbuilder.OrderByItem {
    var items: std.ArrayList(*sqlbuilder.OrderByItem) = .empty;

    // Only an explicit NULLS FIRST or NULLS LAST needs a term of its own; unspecified takes
    // SQLite's own ordering.
    if (order_data.null_order == .NULLS_FIRST or order_data.null_order == .NULLS_LAST) {
        const bin = try alloc.create(sqlbuilder.BinaryExpression);
        bin.* = .{
            .left = expr,
            .operator = "IS NOT",
            .right = try sqlbuilder.newLiteralExpression(alloc, "NULL"),
        };
        const null_expr = try alloc.create(sqlbuilder.SQLExpression);
        null_expr.* = .{ .type = .binary, .binary_expression = bin };

        // IS NOT NULL is 0 for nulls and 1 for non-nulls, so ASC puts nulls
        // first.
        const direction: []const u8 = if (order_data.null_order == .NULLS_LAST)
            "DESC"
        else
            "ASC";

        const item = try alloc.create(sqlbuilder.OrderByItem);
        item.* = .{ .expression = null_expr, .direction = direction };
        try items.append(alloc, item);
    }

    // Add the main ORDER BY item.
    const direction: []const u8 = if (order_data.is_descending) "DESC" else "ASC";
    const item = try alloc.create(sqlbuilder.OrderByItem);
    item.* = .{ .expression = expr, .direction = direction };
    try items.append(alloc, item);

    return items.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "createOrderByItems adds a NULLS FIRST/LAST term" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Unspecified: a single item.
    {
        const expr = try sqlbuilder.newColumnExpression(a, "x", null);
        const data = types_data.OrderByItemData{ .is_descending = true };
        const items = try createOrderByItems(a, expr, &data);
        try testing.expectEqual(@as(usize, 1), items.len);
        try testing.expectEqualStrings("DESC", items[0].direction);
        try testing.expectEqualStrings(
            "`x` DESC",
            try items[0].toString(a),
        );
    }

    // NULLS LAST: IS NOT NULL DESC term first, then main term ASC.
    {
        const expr = try sqlbuilder.newColumnExpression(a, "x", null);
        const data = types_data.OrderByItemData{ .null_order = .NULLS_LAST };
        const items = try createOrderByItems(a, expr, &data);
        try testing.expectEqual(@as(usize, 2), items.len);
        try testing.expectEqualStrings(
            "`x` IS NOT NULL DESC",
            try items[0].toString(a),
        );
        try testing.expectEqualStrings("ASC", items[1].direction);
    }
}

test "newLiteralExpressionFromValue encodes ints natively" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try newLiteralExpressionFromValue(a, .{ .int = 1136239445000000000 });
    try testing.expectEqual(sqlbuilder.ExpressionType.literal, expr.type);
    try testing.expectEqualStrings("1136239445000000000", expr.value);
}
