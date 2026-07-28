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
const query_expr = @import("../sqlbuilder/query_expr.zig");

/// Go WithScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    // Go: "expected with scan data, got type %v"
    if (data.type != .with) return error.UnsupportedNode;
    const with_scan_data = data.with_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Process all WITH entries to create CTE definitions.
    var with_clauses: std.ArrayList(*sqlbuilder.WithClause) = .empty;
    for (with_scan_data.with_entry_list) |entry_data| {
        // If this is a recursive CTE, set the CTE name in context before
        // transforming so the recursive reference can resolve it.
        if (with_scan_data.recursive) {
            ctx.setRecursiveCTEName(entry_data.with_query_name);
        }

        // Transform each WITH entry to a WithClause.
        const entry_scan_data = types_data.ScanData{
            .type = .with_entry,
            .with_entry_scan = entry_data,
        };
        const with_clause = try coord.transformWithEntry(entry_scan_data, ctx);

        // Mark the WITH clause as recursive if needed.
        if (with_scan_data.recursive) {
            with_clause.recursive = true;
        }

        try with_clauses.append(alloc, with_clause);

        // Clear the recursive CTE name after processing.
        if (with_scan_data.recursive) {
            ctx.setRecursiveCTEName("");
        }
    }

    // Transform the main query that uses the CTEs, then hang the CTEs off it
    // rather than off a `SELECT * FROM (...)` wrapper around it.
    const input = try coord.transformScan(with_scan_data.query, ctx);
    const q = if (query_expr.canSetWith(input.query))
        input.query
    else
        try coord.wrapScan(input, ctx);

    q.with_clauses = try with_clauses.toOwnedSlice(alloc);
    return q;
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

test "recursive WITH counts up" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "WITH RECURSIVE r AS (SELECT 1 AS n UNION ALL SELECT n + 1 FROM r WHERE n < 3) SELECT n FROM r ORDER BY n",
        &.{},
        .{},
    );
    defer rows.deinit();

    try testing.expectEqual(driver.Cell{ .int = 1 }, (try rows.next()).?[0]);
    try testing.expectEqual(driver.Cell{ .int = 2 }, (try rows.next()).?[0]);
    try testing.expectEqual(driver.Cell{ .int = 3 }, (try rows.next()).?[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}
