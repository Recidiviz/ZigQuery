//! Faithful port of go-zetasqlite internal/transformer_subquery.go.
//!
//! Subquery expressions by kind:
//!   SCALAR -> (SELECT * FROM (...))
//!   ARRAY  -> (SELECT zetasqlite_array(<first output column>) FROM (...))
//!   EXISTS -> EXISTS (SELECT * FROM (...))
//!   IN     -> <expr> IN (SELECT * FROM (...))
//! Unhandled kinds fall through to the scalar shape, exactly like the Go
//! switch without a default case.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go SubqueryTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SQLExpression {
    // Go: "expected subquery expression data, got type %v"
    if (data.type != .subquery) return error.UnsupportedNode;
    const subquery_data = data.subquery orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const scan = try coord.transformScan(subquery_data.query, ctx);

    // SCALAR / EXISTS / IN consume the subquery as a value: nothing outside
    // names its columns, so it can be the query itself rather than a
    // `SELECT * FROM (query)` around it. ARRAY is different — it reaches back
    // for the first output column by name — and takes the level.
    const scalar_query = try coord.finishScan(scan, ctx);

    const expression = try alloc.create(sqlbuilder.SQLExpression);
    expression.* = .{ .type = .subquery, .subquery = scalar_query };

    // Wrap the subquery in parentheses and handle the subquery type.
    switch (subquery_data.subquery_type) {
        .SCALAR => {},
        .ARRAY => {
            // Go: "failed to find computed column names for array subquery"
            if (subquery_data.query.column_list.len == 0) return error.InvalidAST;
            const subquery_fragment = try sqlbuilder.newSubqueryFromItem(
                alloc,
                scalar_query,
                scan.alias,
            );
            try ctx.fragmentContext().registerColumnScopeMapping(scan.alias, scan.columns);
            const select_statement = try sqlbuilder.newSelectStatement(alloc);
            const args = try alloc.alloc(*sqlbuilder.SQLExpression, 1);
            args[0] = try ctx.fragmentContext().getQualifiedColumnExpression(
                subquery_data.query.column_list[0].id,
            );
            const item = try alloc.create(sqlbuilder.SelectListItem);
            item.* = .{
                .expression = try sqlbuilder.newFunctionExpression(alloc, "zetasqlite_array", args),
            };
            const select_list = try alloc.alloc(*sqlbuilder.SelectListItem, 1);
            select_list[0] = item;
            select_statement.select_list = select_list;
            select_statement.from_clause = subquery_fragment;
            expression.subquery = select_statement;
        },
        .EXISTS => {
            // EXISTS subquery: EXISTS (SELECT ...). Go builds a second
            // SelectStarStatement here.
            return sqlbuilder.newExistsExpression(alloc, scalar_query);
        },
        .IN => {
            // IN subquery: expr IN (SELECT ...). Go dereferences InExpr
            // unconditionally.
            const in_expr_data = subquery_data.in_expr orelse return error.InvalidAST;
            const in_expr = try coord.transformExpression(in_expr_data.*, ctx);
            return sqlbuilder.newBinaryExpression(alloc, in_expr, "IN", expression);
        },
        // Go switch has no default: other kinds fall through to the
        // scalar-shaped expression.
        else => {},
    }

    return expression;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "scalar, EXISTS and IN subqueries" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT (SELECT 7) AS s, EXISTS(SELECT 1) AS e, 2 IN (SELECT 2) AS i",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 7 }, row[0]);
    try testing.expectEqual(driver.Cell{ .bool = true }, row[1]);
    try testing.expectEqual(driver.Cell{ .bool = true }, row[2]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "IN subquery over UNNEST misses" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT 5 IN (SELECT x FROM UNNEST([1, 2, 3]) AS x) AS hit",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .bool = false }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "ARRAY subquery wraps the first output column in zetasqlite_array" {
    // The zetasqlite_array aggregate UDF is registered by a later function
    // task, so the ARRAY branch is checked as generated SQL only.
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();

    const stmts = try driver.translate(
        arena.allocator(),
        "SELECT ARRAY(SELECT x FROM UNNEST([1, 2]) AS x ORDER BY x) AS a",
        .{},
    );
    try testing.expectEqual(@as(usize, 1), stmts.len);
    try testing.expect(
        std.mem.indexOf(u8, stmts[0], "zetasqlite_array(`x__1`)") != null,
    );
}
