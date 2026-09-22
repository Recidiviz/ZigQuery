//! LIMIT and OFFSET: the transformed input scan wrapped in `SELECT * FROM (...) LIMIT count
//! [OFFSET offset]`.
//!
//! Count and offset transform as expressions rather than being read as literal values, because
//! GoogleSQL admits a parameter or a function call in either position.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const query_expr = @import("../sqlbuilder/query_expr.zig");

/// One subquery wrap plus the LIMIT clause. Kept as one function because the wrap is never
/// applied without the clause.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SelectStatement {
    if (data.type != .limit) return error.UnsupportedNode;
    const limit_data = data.limit_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const input = try coord.transformScan(limit_data.input_scan, ctx);

    // LIMIT applies after everything else on its level, so it fits onto the
    // input's query unless that already carries one.
    const select_stmt = if (query_expr.canSetLimit(input.query))
        input.query
    else
        try coord.wrapScan(input, ctx);

    // Transform count expression.
    const count_expr = try coord.transformExpression(limit_data.count, ctx);
    const limit_clause = try alloc.create(sqlbuilder.LimitClause);
    limit_clause.* = .{ .count = count_expr };

    // OFFSET is optional.
    if (limit_data.offset) |offset_data| {
        limit_clause.offset = try coord.transformExpression(offset_data, ctx);
    }

    select_stmt.limit_clause = limit_clause;

    return select_stmt;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "LIMIT without OFFSET" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT x FROM UNNEST([1, 2, 3, 4]) AS x ORDER BY x LIMIT 2",
        &.{},
        .{},
    );
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "LIMIT with OFFSET" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT x FROM UNNEST([1, 2, 3, 4]) AS x ORDER BY x LIMIT 2 OFFSET 1",
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
