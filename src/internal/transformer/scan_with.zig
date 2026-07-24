//! Faithful port of go-zetasqlite internal/transformer_scan_with.go.
//!
//! Transforms every WITH entry into a WithClause, then transforms the main
//! query and returns SELECT * FROM (main query) carrying the WITH clauses.
//!
//! Recursive CTEs are excluded from the foundation port: the Go original
//! sets ctx.SetRecursiveCTEName(entry name) before each entry, marks the
//! produced WithClause recursive, and clears the name afterwards; the entry
//! and recursive-scan machinery it relies on (scan_recursive.zig /
//! scan_recursive_ref.zig) is still stubbed, so WithScanData.recursive
//! returns error.Unimplemented up front.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go WithScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.FromItem {
    // Go: "expected with scan data, got type %v"
    if (data.type != .with) return error.UnsupportedNode;
    const with_scan_data = data.with_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Recursive CTEs arrive with the recursive-scan task (see file comment).
    if (with_scan_data.recursive) return error.Unimplemented;

    // Process all WITH entries to create CTE definitions.
    var with_clauses: std.ArrayList(*sqlbuilder.WithClause) = .empty;
    for (with_scan_data.with_entry_list) |entry_data| {
        // Transform each WITH entry to a WithClause.
        const entry_scan_data = types_data.ScanData{
            .type = .with_entry,
            .with_entry_scan = entry_data,
        };
        const with_clause = try coord.transformWithEntry(entry_scan_data, ctx);
        try with_clauses.append(alloc, with_clause);
    }

    // Transform the main query that uses the CTEs.
    const query_from_item = try coord.transformScan(with_scan_data.query, ctx);

    // Create SELECT statement with WITH clauses.
    const select_statement = try sqlbuilder.newSelectStarStatement(alloc, query_from_item);
    select_statement.with_clauses = try with_clauses.toOwnedSlice(alloc);

    const from_item = try alloc.create(sqlbuilder.FromItem);
    from_item.* = .{ .type = .subquery, .subquery = select_statement };
    return from_item;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "WITH clause + reference" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "WITH t AS (SELECT 1 AS a, 2 AS b) SELECT b, a FROM t",
        &.{},
        .{},
    );
    defer rows.deinit();

    try testing.expectEqualStrings("b", rows.columns()[0]);
    try testing.expectEqualStrings("a", rows.columns()[1]);
    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[1]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "chained WITH entries referencing earlier CTEs" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "WITH a AS (SELECT 1 AS v), b AS (SELECT v + 1 AS w FROM a) SELECT w FROM b",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "recursive WITH is unimplemented in the foundation" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    try testing.expectError(
        error.Unimplemented,
        db.query(
            "WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r",
            &.{},
            .{},
        ),
    );
}
