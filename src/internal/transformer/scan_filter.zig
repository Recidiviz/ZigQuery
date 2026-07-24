//! Faithful port of go-zetasqlite internal/transformer_scan_filter.go.
//!
//! Recursively transforms the input scan, transforms the filter expression,
//! and wraps the result in SELECT * FROM (...) WHERE <condition>. The
//! coordinator assigns the scan alias afterwards.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go FilterScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.FromItem {
    // Go: "expected filter scan data, got type %v"
    if (data.type != .filter) return error.UnsupportedNode;
    const filter_data = data.filter_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const inner_from_item = try coord.transformScan(filter_data.input_scan, ctx);

    // Transform the filter expression.
    const filter_expr = try coord.transformExpression(filter_data.filter_expr, ctx);

    const select_stmt = try sqlbuilder.newSelectStarStatement(alloc, inner_from_item);
    select_stmt.where_clause = filter_expr;

    const from_item = try alloc.create(sqlbuilder.FromItem);
    from_item.* = .{ .type = .subquery, .subquery = select_stmt };
    return from_item;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "WHERE filter over UNNEST" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT x FROM UNNEST([1, 2, 3]) AS x WHERE x >= 2 ORDER BY x",
        &.{},
        .{},
    );
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 3 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "WHERE filter with compound condition" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT x FROM UNNEST([1, 2, 3, 4]) AS x WHERE x > 1 AND x < 4 ORDER BY x",
        &.{},
        .{},
    );
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 3 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}
