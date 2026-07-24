//! Faithful port of go-zetasqlite internal/transformer_scan_limit.go.
//!
//! Wraps the transformed input scan in SELECT * FROM (...) LIMIT count
//! [OFFSET offset]. Count and offset are full expressions (parameters,
//! function calls, ...), not just literals.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go LimitScanTransformer.Transform (wrapInSubqueryWithLimit +
/// addLimitToSelect inlined; they are only called in this sequence).
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.FromItem {
    // Go: "expected limit scan data, got type %v"
    if (data.type != .limit) return error.UnsupportedNode;
    const limit_data = data.limit_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const inner_from_item = try coord.transformScan(limit_data.input_scan, ctx);

    // Create SELECT * FROM (complex_query) LIMIT count OFFSET offset.
    const select_stmt = try sqlbuilder.newSelectStarStatement(alloc, inner_from_item);

    // Transform count expression.
    const count_expr = try coord.transformExpression(limit_data.count, ctx);
    const limit_clause = try alloc.create(sqlbuilder.LimitClause);
    limit_clause.* = .{ .count = count_expr };

    // Transform offset if present (Go: LimitScanData.Offset != zero value).
    if (limit_data.offset) |offset_data| {
        limit_clause.offset = try coord.transformExpression(offset_data, ctx);
    }

    select_stmt.limit_clause = limit_clause;

    const from_item = try alloc.create(sqlbuilder.FromItem);
    from_item.* = .{
        .type = .subquery,
        .subquery = select_stmt,
        // Go sets "limit_scan_<id>" here; the coordinator overwrites the
        // alias with its own scope id right after (mirrored for fidelity).
        .alias = try std.fmt.allocPrint(alloc, "limit_scan_{s}", .{ctx.fragmentContext().getID()}),
    };
    return from_item;
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
