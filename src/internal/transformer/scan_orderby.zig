//! Faithful port of go-zetasqlite internal/transformer_scan_orderby.go.
//!
//! Recursively transforms the input scan, transforms each ORDER BY
//! expression, and selects the scan's ColumnList explicitly (rather than
//! SELECT *) so used `$orderby` columns are dropped from the output.
//!
//! Fidelity note: the Go OrderByScanTransformer carries its own
//! createOrderByItems method whose rendered output is identical to the
//! package-level createOrderByItems already ported into common.zig (the
//! method assigns expr.Collation up-front, but the IS NOT NULL term's Left
//! side is the same pointer, so both orders render the same SQL; and its
//! `!= OrderUnspecified` gate combined with a switch over only
//! NULLS FIRST/LAST is equivalent to the explicit two-mode check). The port
//! therefore reuses common.createOrderByItems.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const common = @import("common.zig");

/// Go OrderByScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    // Go: "expected order by scan data, got type %v"
    if (data.type != .order_by) return error.UnsupportedNode;
    const order_by_data = data.order_by_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const inner_from_item = try coord.materializeScan(
        try coord.transformScan(order_by_data.input_scan, ctx),
        ctx,
    );

    // Transform ORDER BY expressions (Go transformOrderByItems).
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
