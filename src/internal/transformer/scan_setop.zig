//! Faithful port of go-zetasqlite internal/transformer_scan_setop.go.
//!
//! Transforms each operand statement, combines them with the set operation
//! (UNION/INTERSECT/EXCEPT + optional ALL), hoists operand WITH clauses to
//! the top level, and wraps everything in a subquery that re-exposes the set
//! operation's output columns under ID-based aliases.
//!
//! DISTINCT dedup note: the extractor (coordinator_extractor.go
//! extractSetOperationScanData) maps UNION_DISTINCT / INTERSECT_DISTINCT /
//! EXCEPT_DISTINCT to modifier "" — plain UNION/INTERSECT/EXCEPT in SQLite
//! already deduplicate — and only the *_ALL variants get modifier "ALL".
//! No collation or GROUP BY trick is involved here.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go SetOperationScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.FromItem {
    // Go: "expected set operation scan data, got type %v"
    if (data.type != .set_op) return error.UnsupportedNode;
    const set_op_data = data.set_operation_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Transform all statement items to SelectStatements.
    const select_statements = try alloc.alloc(*sqlbuilder.SelectStatement, set_op_data.items.len);
    for (set_op_data.items, 0..) |stmt_data, i| {
        const fragment = try coord.transformStatement(stmt_data, ctx);
        // Ensure it's a SELECT statement (Go type assertion:
        // "set operation item %d is not a SELECT statement"). The fragment
        // union stores a const pointer; the statement was freshly built by
        // the statement transformer, so casting mutability back is safe
        // (Go mutates the same object through its interface value).
        select_statements[i] = switch (fragment) {
            .select_statement => |stmt| @constCast(stmt),
            else => return error.UnsupportedNode,
        };
    }

    // Create the set operation.
    const set_operation = try alloc.create(sqlbuilder.SetOperation);
    set_operation.* = .{
        .type = set_op_data.type,
        .modifier = set_op_data.modifier,
        .items = select_statements,
    };

    // Create a SELECT statement that contains the set operation.
    const set_statement = try sqlbuilder.newSelectStatement(alloc);
    set_statement.set_operation = set_operation;

    // Move all WITH queries from items to top-level.
    var with_clauses: std.ArrayList(*sqlbuilder.WithClause) = .empty;
    for (select_statements) |item| {
        try with_clauses.appendSlice(alloc, item.with_clauses);
        item.with_clauses = &.{}; // Clear the WITH clauses from the items.
    }
    set_statement.with_clauses = try with_clauses.toOwnedSlice(alloc);

    // Create a subquery to introduce the new logical columns into the query.
    const statement = try sqlbuilder.newSelectStatement(alloc);
    const select_list = try alloc.alloc(*sqlbuilder.SelectListItem, data.column_list.len);
    for (data.column_list, 0..) |column, i| {
        // Retrieve column name from the first item (Go indexes without a
        // bounds check and would panic; the port errors instead).
        if (i >= select_statements[0].select_list.len) return error.ValidationFailed;
        const item_column = select_statements[0].select_list[i];
        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{
            .expression = try sqlbuilder.newColumnExpression(alloc, item_column.alias, null),
            .alias = try context.generateIDBasedAlias(alloc, column.name, column.id),
        };
        select_list[i] = item;
    }
    statement.select_list = select_list;
    statement.from_clause = try sqlbuilder.newSubqueryFromItem(alloc, set_statement, "set_op_scan_inner");

    // Wrap in a subquery FromItem (alias overwritten by the coordinator).
    return sqlbuilder.newSubqueryFromItem(alloc, statement, "set_op_scan_outer");
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "UNION ALL keeps duplicates" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1 AS v UNION ALL SELECT 1", &.{}, .{});
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "UNION DISTINCT deduplicates" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1 AS v UNION DISTINCT SELECT 1", &.{}, .{});
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "INTERSECT DISTINCT and EXCEPT DISTINCT" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    {
        var rows = try db.query("SELECT 1 AS v INTERSECT DISTINCT SELECT 1", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
    {
        var rows = try db.query("SELECT 1 AS v EXCEPT DISTINCT SELECT 1", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
}
