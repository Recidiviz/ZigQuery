//! A set operation. Each operand transforms, they combine under UNION/INTERSECT/EXCEPT with an
//! optional ALL, operand WITH clauses hoist to the top level, and the whole thing is wrapped in a
//! subquery re-exposing the output columns under ID-based aliases.
//!
//! The DISTINCT forms carry no modifier: plain UNION, INTERSECT and EXCEPT already deduplicate in
//! SQLite, so only the *_ALL forms need `ALL`. Nothing here needs a collation or a GROUP BY to
//! get the dedup.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SelectStatement {
    if (data.type != .set_op) return error.UnsupportedNode;
    const set_op_data = data.set_operation_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Transform all statement items to SelectStatements.
    const select_statements = try alloc.alloc(*sqlbuilder.SelectStatement, set_op_data.items.len);
    for (set_op_data.items, 0..) |stmt_data, i| {
        const fragment = try coord.transformStatement(stmt_data, ctx);
        // An operand must be a SELECT. The fragment union stores a const pointer, and the
        // statement was freshly built by the statement transformer, so casting mutability back
        // is safe: nothing else holds it.
        select_statements[i] = switch (fragment) {
            .select_statement => |stmt| @constCast(stmt),
            else => return error.UnsupportedNode,
        };
    }

    // Create the set operation.
    const set_operation = try alloc.create(sqlbuilder.SetOperation);
    set_operation.* = .{
        .type = set_op_data.type,
        .modifier = set_op_data.modifier,
        .items = select_statements,
    };

    // Create a SELECT statement that contains the set operation.
    const set_statement = try sqlbuilder.newSelectStatement(alloc);
    set_statement.set_operation = set_operation;

    // Move all WITH queries from items to top-level.
    var with_clauses: std.ArrayList(*sqlbuilder.WithClause) = .empty;
    for (select_statements) |item| {
        try with_clauses.appendSlice(alloc, item.with_clauses);
        item.with_clauses = &.{}; // Clear the WITH clauses from the items.
    }
    set_statement.with_clauses = try with_clauses.toOwnedSlice(alloc);

    // The set operation's output columns are introduced by renaming each branch's SELECT items
    // in place, rather than by projecting the whole set operation through another level.
    //
    // SQLite takes a compound SELECT's column names from its first branch, so
    // only branch 0's aliases are load-bearing; the rest are renamed to match
    // because a compound arm that disagrees with its siblings about what a
    // column is called is a trap for the next reader.
    for (data.column_list, 0..) |column, i| {
        const alias = try context.generateIDBasedAlias(alloc, column.name, column.id);
        for (select_statements) |branch| {
            // A branch with fewer items than the output column list is a malformed AST.
            if (i >= branch.select_list.len) return error.ValidationFailed;
            const item = branch.select_list[i];
            // A `SELECT *` arm has no alias to rename; leave it and let the
            // star's own names carry through.
            if (item.is_star_expansion) continue;
            item.alias = alias;
        }
    }

    return set_statement;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "UNION ALL keeps duplicates" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1 AS v UNION ALL SELECT 1", &.{}, .{});
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "UNION DISTINCT deduplicates" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT 1 AS v UNION DISTINCT SELECT 1", &.{}, .{});
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "INTERSECT DISTINCT and EXCEPT DISTINCT" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    {
        var rows = try db.query("SELECT 1 AS v INTERSECT DISTINCT SELECT 1", &.{}, .{});
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
    {
        var rows = try db.query("SELECT 1 AS v EXCEPT DISTINCT SELECT 1", &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
    }
}
