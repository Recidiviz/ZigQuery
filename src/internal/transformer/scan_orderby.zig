//! ORDER BY. The input scan transforms, each ORDER BY expression transforms, and the SELECT list
//! names the scan's column list explicitly rather than using `SELECT *`, which is what drops the
//! `$orderby` columns the analyzer added for the sort from the visible output.
//!
//! Item rendering, with its collation and null ordering, is `common.createOrderByItems`.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const common = @import("common.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SelectStatement {
    if (data.type != .order_by) return error.UnsupportedNode;
    const order_by_data = data.order_by_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const inner_from_item = try coord.materializeScan(
        try coord.transformScan(order_by_data.input_scan, ctx),
        ctx,
    );

    // Each ORDER BY expression transforms in turn.
    var order_by_items: std.ArrayList(*sqlbuilder.OrderByItem) = .empty;
    for (order_by_data.order_by_columns) |item_data| {
        const expr = try coord.transformExpression(item_data.expression, ctx);
        // Handle potential multiple items for NULL ordering.
        const items = try common.createOrderByItems(alloc, expr, item_data);
        try order_by_items.appendSlice(alloc, items);
    }

    const select_statement = try sqlbuilder.newSelectStatement(alloc);
    select_statement.from_clause = inner_from_item;
    select_statement.order_by_list = try order_by_items.toOwnedSlice(alloc);

    // Select the ColumnList explicitly (rather than SELECT *), as this scan
    // should drop used `$orderby` columns from the output columns.
    const select_list = try alloc.alloc(*sqlbuilder.SelectListItem, data.column_list.len);
    for (data.column_list, 0..) |col, i| {
        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{
            .expression = try ctx.fragmentContext().getQualifiedColumnExpression(col.id),
            .alias = try context.generateIDBasedAlias(alloc, col.name, col.id),
        };
        select_list[i] = item;
    }
    select_statement.select_list = select_list;

    return select_statement;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "ORDER BY ascending and descending without explicit null order" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    {
        var rows = try db.query("SELECT x FROM UNNEST([3, 1, 2]) AS x ORDER BY x", &.{}, .{});
        defer rows.deinit();
        var row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
        row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
        row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 3 }, row[0]);
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
    {
        var rows = try db.query("SELECT x FROM UNNEST([3, 1, 2]) AS x ORDER BY x DESC", &.{}, .{});
        defer rows.deinit();
        var row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 3 }, row[0]);
        row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
        row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
}

test "ORDER BY with explicit NULLS FIRST/LAST" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    {
        var rows = try db.query(
            "SELECT x FROM UNNEST([2, NULL, 1]) AS x ORDER BY x ASC NULLS LAST",
            &.{},
            .{},
        );
        defer rows.deinit();
        var row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
        row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
        row = (try rows.next()).?;
        try testing.expect(row[0] == .null);
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
    {
        var rows = try db.query(
            "SELECT x FROM UNNEST([2, NULL, 1]) AS x ORDER BY x DESC NULLS FIRST",
            &.{},
            .{},
        );
        defer rows.deinit();
        var row = (try rows.next()).?;
        try testing.expect(row[0] == .null);
        row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
        row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
}
