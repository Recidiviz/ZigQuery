//! A filter, written into the input scan's own WHERE slot. A subquery level is spent only when
//! that slot is already taken, which keeps the generated SQL one level flatter than wrapping
//! every filter in `SELECT * FROM (...)` would.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const query_expr = @import("../sqlbuilder/query_expr.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SelectStatement {
    if (data.type != .filter) return error.UnsupportedNode;
    const filter_data = data.filter_scan orelse return error.UnsupportedNode;
    const input = try coord.transformScan(filter_data.input_scan, ctx);

    // Write the WHERE into the input's own query when its select list is still
    // free; otherwise the filter would read as "after the projection", which
    // is not what the resolved AST said, so spend a level.
    const q = if (query_expr.canSetWhere(input.query))
        input.query
    else
        try coord.wrapScan(input, ctx);

    // After the wrap decision: the filter's column references have to resolve
    // against whichever scope the input ended up in.
    q.where_clause = try coord.transformExpression(filter_data.filter_expr, ctx);
    return q;
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
