//! A join. Both scans transform, the join type maps to SQLite's INNER/LEFT/RIGHT/FULL OUTER, the
//! ON condition transforms when there is one, and the result is wrapped in a `SELECT *` subquery.
//! An unrecognized join kind is INNER.
//!
//! `JoinScanData.using_columns` is extracted and never emitted: the analyzer lowers USING into an
//! ON condition over the resolved columns, so there is nothing left to render.

const std = @import("std");
const pb = @import("../../proto/resolved_ast.zig");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SelectStatement {
    if (data.type != .join) return error.UnsupportedNode;
    const join_scan_data = data.join_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const left_from_item = try coord.materializeScan(
        try coord.transformScan(join_scan_data.left_scan, ctx),
        ctx,
    );
    const right_from_item = try coord.materializeScan(
        try coord.transformScan(join_scan_data.right_scan, ctx),
        ctx,
    );

    // Transform the join condition if present.
    var join_condition: ?*sqlbuilder.SQLExpression = null;
    if (join_scan_data.join_condition) |condition_data| {
        join_condition = try coord.transformExpression(condition_data.*, ctx);
    }

    // Convert ZetaSQL join type to the sqlbuilder join type.
    const join_type = convertJoinType(join_scan_data.join_type);

    const join_clause = try alloc.create(sqlbuilder.JoinClause);
    join_clause.* = .{
        .type = join_type,
        .left = left_from_item,
        .right = right_from_item,
        .condition = join_condition,
    };
    const join_from_item = try alloc.create(sqlbuilder.FromItem);
    join_from_item.* = .{ .type = .join, .join = join_clause };

    // The join is a row source, not a query: leaving the select slot free lets the projection
    // above it land here rather than one level up.
    const select_statement = try alloc.create(sqlbuilder.SelectStatement);
    select_statement.* = .{ .from_clause = join_from_item };
    return select_statement;
}

/// The SQLite join type for a resolved join kind. An unrecognized kind is INNER.
fn convertJoinType(join_type: pb.ResolvedJoinScanEnums_JoinType) sqlbuilder.JoinType {
    return switch (join_type) {
        .INNER => .inner,
        .LEFT => .left,
        .RIGHT => .right,
        .FULL => .full,
        else => .inner,
    };
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "INNER JOIN with ON condition" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT t1.a, t2.b FROM (SELECT 1 AS a) AS t1 JOIN (SELECT 1 AS b) AS t2 ON t1.a = t2.b",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[1]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "LEFT JOIN keeps unmatched left rows" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT a, b FROM (SELECT x AS a FROM UNNEST([1, 2]) AS x) " ++
            "LEFT JOIN (SELECT y AS b FROM UNNEST([2, 3]) AS y) ON a = b ORDER BY a",
        &.{},
        .{},
    );
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expect(row[1] == .null);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[1]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "CROSS JOIN via comma" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT a, b FROM (SELECT 1 AS a), (SELECT 2 AS b)",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[1]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}
