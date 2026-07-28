//! Faithful port of go-zetasqlite internal/transformer_scan_recursive.go.
//!
//! Transforms a RecursiveScan (the definition of a recursive CTE): the
//! non-recursive term (base case) and recursive term are transformed to
//! SELECT statements, combined with a set operation (UNION [ALL]), and
//! wrapped in a SELECT statement carrying the set operation directly so the
//! WithEntryTransformer can emit the recursive CTE body verbatim.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const flatten = @import("../sqlbuilder/flatten.zig");

/// Go RecursiveScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    // Go: "expected recursive scan data, got type %v"
    if (data.type != .recursive) return error.UnsupportedNode;
    const recursive_scan_data = data.recursive_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Transform the non-recursive term (base case).
    const non_recursive_fragment = try coord.transformStatement(recursive_scan_data.non_recursive_term, ctx);
    // Go: "non-recursive term is not a SELECT statement"
    const non_recursive_select: *sqlbuilder.SelectStatement = switch (non_recursive_fragment) {
        .select_statement => |stmt| @constCast(stmt),
        else => return error.UnsupportedNode,
    };

    // Transform the recursive term (recursive case).
    const recursive_fragment = try coord.transformStatement(recursive_scan_data.recursive_term, ctx);
    // Go: "recursive term is not a SELECT statement"
    var recursive_select: *sqlbuilder.SelectStatement = switch (recursive_fragment) {
        .select_statement => |stmt| @constCast(stmt),
        else => return error.UnsupportedNode,
    };

    // CRITICAL: Flatten the recursive term to expose the table reference at
    // the top level. SQLite requires the recursive CTE reference to be
    // directly in the FROM clause, not buried in nested subqueries.
    recursive_select = (try flatten.flattenSelectForRecursiveCTE(alloc, recursive_select)).?;

    // Parse the operation type to extract type and modifier.
    var op_type: []const u8 = undefined;
    var modifier: []const u8 = undefined;
    if (std.mem.eql(u8, recursive_scan_data.op_type, "UNION ALL")) {
        op_type = "UNION";
        modifier = "ALL";
    } else if (std.mem.eql(u8, recursive_scan_data.op_type, "UNION")) {
        op_type = "UNION";
        modifier = "";
    } else {
        // Go: "unsupported recursive operation type: %s"
        return error.UnsupportedNode;
    }

    // Ensure the final column names match data.column_list by adding proper
    // aliases to the SetOperation items.
    const items = [_]*sqlbuilder.SelectStatement{ non_recursive_select, recursive_select };
    for (items) |item| {
        for (data.column_list, 0..) |column, i| {
            if (i < item.select_list.len) {
                item.select_list[i].alias = try context.generateIDBasedAlias(alloc, column.name, column.id);
            }
        }
    }

    // Create the set operation combining non-recursive and recursive terms.
    const set_operation = try alloc.create(sqlbuilder.SetOperation);
    const set_items = try alloc.alloc(*sqlbuilder.SelectStatement, 2);
    set_items[0] = non_recursive_select;
    set_items[1] = recursive_select;
    set_operation.* = .{ .type = op_type, .modifier = modifier, .items = set_items };

    // Create a SELECT statement that contains the set operation directly.
    const set_statement = try sqlbuilder.newSelectStatement(alloc);
    set_statement.set_operation = set_operation;

    // Move all WITH clauses from items to top-level.
    var with_clauses: std.ArrayList(*sqlbuilder.WithClause) = .empty;
    for (set_operation.items) |item| {
        try with_clauses.appendSlice(alloc, item.with_clauses);
        item.with_clauses = &.{};
    }
    set_statement.with_clauses = try with_clauses.toOwnedSlice(alloc);

    return set_statement;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "recursive CTE fibonacci" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\WITH RECURSIVE fib AS (
        \\  SELECT 1 AS n, 0 AS a, 1 AS b
        \\  UNION ALL
        \\  SELECT n + 1, b, a + b FROM fib WHERE n < 8
        \\)
        \\SELECT a FROM fib ORDER BY n
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const want = [_]i64{ 0, 1, 1, 2, 3, 5, 8, 13 };
    for (want) |w| {
        try testing.expectEqual(driver.Cell{ .int = w }, (try rows.next()).?[0]);
    }
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "recursive CTE hierarchy walk with join (corpus 43 shape)" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE res (id STRING, parent STRING);
        \\INSERT INTO res (id, parent) VALUES ('m1', 't1'), ('t1', 'f1'), ('f1', NULL);
        \\WITH RECURSIVE walk AS (
        \\  SELECT id, parent, 1 AS hops FROM res
        \\  UNION ALL
        \\  SELECT w.id, r.parent, hops + 1
        \\  FROM res r INNER JOIN walk w ON w.parent = r.id
        \\  WHERE hops < 10
        \\)
        \\SELECT id, parent, hops FROM walk WHERE id = 'm1' ORDER BY hops
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqualStrings("m1", row[0].string);
    try testing.expectEqualStrings("t1", row[1].string);
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[2]);
    row = (try rows.next()).?;
    try testing.expectEqualStrings("f1", row[1].string);
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[2]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell.null, row[1]);
    try testing.expectEqual(driver.Cell{ .int = 3 }, row[2]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "INSERT INTO ... WITH RECURSIVE (corpus 44 verbatim)" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE numbers (num INT64);
        \\-- Insert rows 1-5
        \\INSERT INTO numbers (num)
        \\WITH RECURSIVE seq AS (
        \\  -- Base case
        \\  SELECT 1 AS num
        \\
        \\  UNION ALL
        \\
        \\  -- Recursive case
        \\  SELECT num + 1
        \\  FROM seq
        \\  WHERE num < 5
        \\)
        \\SELECT num FROM seq;
        \\
        \\-- Select remaining numbers
        \\SELECT * FROM numbers;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    var n: i64 = 1;
    while (n <= 5) : (n += 1) {
        try testing.expectEqual(driver.Cell{ .int = n }, (try rows.next()).?[0]);
    }
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}
