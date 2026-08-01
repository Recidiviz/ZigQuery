//! Faithful port of go-zetasqlite internal/transformer_scan_aggregate.go.
//!
//! Converts an AggregateScan into a SELECT with GROUP BY:
//! - the input scan becomes the FROM item
//! - aggregate computed columns transform into zetasqlite_<agg>(...) calls
//!   (their trailing option markers were attached by the extractor)
//! - each GROUP BY expression is wrapped in zetasqlite_group_by(...) inside
//!   the GROUP BY clause, while the SELECT list references the *unwrapped*
//!   expression (SQLite permits bare columns functionally dependent on the
//!   grouped expression)
//! - output columns get ID-based aliases
//! HAVING never reaches this transformer: googlesql resolves it as a
//! FilterScan above the AggregateScan (Go has no HAVING code here either).
//!
//! GROUPING SETS/ROLLUP/CUBE (Go buildGroupingSetsQuery) is also ported:
//! each grouping set becomes a SELECT (NULL for the non-grouped columns)
//! UNION ALL'ed together and re-aliased. The extractor currently rejects
//! grouping sets with error.Unimplemented, so the path is dormant until the
//! grouping-set extraction lands.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const query_expr = @import("../sqlbuilder/query_expr.zig");

const Error = types_data.Error;
const SQLExpression = sqlbuilder.SQLExpression;

/// Go AggregateScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) Error!*sqlbuilder.SelectStatement {
    // Go: "expected aggregate scan data, got type %v"
    if (data.type != .aggregate) return error.UnsupportedNode;
    const agg_data = data.aggregate_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // GROUP BY must not see a projection, so it needs the input's select slot
    // still free; when it is not, spend a level.
    const input = try coord.transformScan(agg_data.input_scan, ctx);
    const q = if (query_expr.canSetGroupBy(input.query))
        input.query
    else
        try coord.wrapScan(input, ctx);

    // Process aggregate expressions.
    var aggregate_map = std.AutoHashMap(i64, *SQLExpression).init(alloc);
    for (agg_data.aggregate_list) |agg_expr| {
        const col = agg_expr.column orelse return error.InvalidAST;
        const sql_expr = try coord.transformExpression(agg_expr.expression, ctx);
        try aggregate_map.put(col.id, sql_expr);
    }

    // Process GROUP BY expressions. groupByMap keeps the *unwrapped*
    // expression (used in the SELECT list); the GROUP BY clause gets the
    // zetasqlite_group_by(...) wrapper for ZetaSQL grouping semantics.
    var group_by_map = std.AutoHashMap(i64, *SQLExpression).init(alloc);
    var group_by_exprs: std.ArrayList(*SQLExpression) = .empty;
    try group_by_exprs.ensureTotalCapacity(alloc, agg_data.group_by_list.len);
    for (agg_data.group_by_list) |group_by_expr| {
        const col = group_by_expr.column orelse return error.InvalidAST;
        const sql_expr = try coord.transformExpression(group_by_expr.expression, ctx);

        const args = try alloc.alloc(*SQLExpression, 1);
        args[0] = sql_expr;
        const wrapped = try sqlbuilder.newFunctionExpression(alloc, "zetasqlite_group_by", args);
        try group_by_exprs.append(alloc, wrapped);
        try group_by_map.put(col.id, sql_expr);
    }

    // Build the SELECT list from the output columns.
    var select_list: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
    try select_list.ensureTotalCapacity(alloc, data.column_list.len);
    for (data.column_list) |col| {
        const expr = aggregate_map.get(col.id) orelse
            group_by_map.get(col.id) orelse
            // Go: "column %s not found in aggregate or GROUP BY expressions"
            return error.ColumnNotFound;

        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{
            .expression = expr,
            .alias = try context.generateIDBasedAlias(alloc, col.name, col.id),
        };
        try select_list.append(alloc, item);
    }

    // Handle GROUPING SETS if present.
    if (agg_data.grouping_sets.len > 0) {
        return buildGroupingSetsQuery(
            alloc,
            agg_data,
            q.from_clause.?,
            data.column_list,
            select_list.items,
            &group_by_map,
        );
    }

    // Aggregation is a hard materialization boundary: the outputs are
    // projected here and never left pending, or a projection above would
    // inline an aggregate into an outer aggregate.
    q.select_list = try select_list.toOwnedSlice(alloc);
    q.group_by_list = try group_by_exprs.toOwnedSlice(alloc);
    for (data.column_list) |col| _ = ctx.fragmentContext().takePending(col.id);
    for (data.column_list) |col| {
        try ctx.fragmentContext().setPending(
            col.id,
            try sqlbuilder.newColumnExpression(
                alloc,
                try context.generateIDBasedAlias(alloc, col.name, col.id),
                null,
            ),
        );
    }

    return q;
}

/// Go buildGroupingSetsQuery: ROLLUP/GROUPING SETS as a UNION ALL of one
/// SELECT per grouping set, with NULL projected for the columns a set does
/// not group by, ordered by the grouping columns.
fn buildGroupingSetsQuery(
    alloc: std.mem.Allocator,
    agg_data: *const types_data.AggregateScanData,
    input_from_item: *sqlbuilder.FromItem,
    column_data: []const *types_data.ColumnData,
    output_columns: []const *sqlbuilder.SelectListItem,
    group_by_map: *std.AutoHashMap(i64, *SQLExpression),
) Error!*sqlbuilder.SelectStatement {
    var statements: std.ArrayList(*sqlbuilder.SelectStatement) = .empty;
    try statements.ensureTotalCapacity(alloc, agg_data.grouping_sets.len);

    for (agg_data.grouping_sets) |grouping_set| {
        // Columns grouped in this set (wrapped for the GROUP BY clause).
        var group_by_set_columns: std.ArrayList(*SQLExpression) = .empty;
        var set_column_ids = std.AutoHashMap(i64, void).init(alloc);
        for (grouping_set.group_by_columns) |set_col| {
            const col = set_col.column orelse return error.InvalidAST;
            const base = group_by_map.get(col.id) orelse return error.ColumnNotFound;
            const args = try alloc.alloc(*SQLExpression, 1);
            args[0] = base;
            try group_by_set_columns.append(
                alloc,
                try sqlbuilder.newFunctionExpression(alloc, "zetasqlite_group_by", args),
            );
            try set_column_ids.put(col.id, {});
        }

        // Grouping columns not in this set become NULL.
        var null_column_ids = std.AutoHashMap(i64, void).init(alloc);
        var key_it = group_by_map.keyIterator();
        while (key_it.next()) |id| {
            if (!set_column_ids.contains(id.*)) try null_column_ids.put(id.*, {});
        }

        const select_list = try alloc.alloc(*sqlbuilder.SelectListItem, output_columns.len);
        for (output_columns, 0..) |original_col, i| {
            if (null_column_ids.contains(column_data[i].id)) {
                const item = try alloc.create(sqlbuilder.SelectListItem);
                item.* = .{
                    .expression = try sqlbuilder.newLiteralExpression(alloc, "NULL"),
                    // Go uses the bare column name for the NULL slots.
                    .alias = column_data[i].name,
                };
                select_list[i] = item;
            } else {
                select_list[i] = original_col;
            }
        }

        const stmt = try alloc.create(sqlbuilder.SelectStatement);
        stmt.* = .{
            .select_list = select_list,
            .from_clause = input_from_item,
            .group_by_list = group_by_set_columns.items,
        };
        try statements.append(alloc, stmt);
    }

    if (statements.items.len == 1) return statements.items[0];

    const set_operation = try alloc.create(sqlbuilder.SetOperation);
    set_operation.* = .{
        .type = "UNION",
        .modifier = "ALL",
        .items = try statements.toOwnedSlice(alloc),
    };

    const union_stmt = try alloc.create(sqlbuilder.SelectStatement);
    union_stmt.* = .{ .set_operation = set_operation };

    // ORDER BY the grouping columns with the value-aware collation so the
    // grouping levels come out in a deterministic ZetaSQL-like order.
    if (group_by_map.count() > 0) {
        var order_by_items: std.ArrayList(*sqlbuilder.OrderByItem) = .empty;
        var val_it = group_by_map.valueIterator();
        while (val_it.next()) |group_by_col| {
            // Copy the SQLExpression, as Go does.
            const order_expr = try alloc.create(SQLExpression);
            order_expr.* = group_by_col.*.*;

            const item = try alloc.create(sqlbuilder.OrderByItem);
            item.* = .{ .expression = order_expr, .direction = "ASC" };
            try order_by_items.append(alloc, item);
        }
        union_stmt.order_by_list = try order_by_items.toOwnedSlice(alloc);
    }

    // Re-project through an inner subquery to introduce the new logical
    // columns (aliases from the first set's SELECT items).
    const statement = try alloc.create(sqlbuilder.SelectStatement);
    const outer_list = try alloc.alloc(*sqlbuilder.SelectListItem, column_data.len);
    for (column_data, 0..) |column, i| {
        const item_column = set_operation.items[0].select_list[i];
        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{
            .expression = try sqlbuilder.newColumnExpression(alloc, item_column.alias, null),
            .alias = try context.generateIDBasedAlias(alloc, column.name, column.id),
        };
        outer_list[i] = item;
    }
    statement.* = .{
        .select_list = outer_list,
        .from_clause = try sqlbuilder.newSubqueryFromItem(alloc, union_stmt, "set_op_scan_inner"),
    };

    return statement;
}

// ----------------------------------------------------------------------
// Tests: end-to-end through the driver (GoogleSQL -> SQLite -> rows).
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");
const Cell = driver.Cell;

test "aggregates over UNNEST without GROUP BY" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT SUM(x), COUNT(x), COUNT(*), MIN(x), MAX(x), AVG(x) FROM UNNEST([1, 2, 3, 4]) AS x",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 10 }, row[0]);
    try testing.expectEqual(Cell{ .int = 4 }, row[1]);
    try testing.expectEqual(Cell{ .int = 4 }, row[2]);
    try testing.expectEqual(Cell{ .int = 1 }, row[3]);
    try testing.expectEqual(Cell{ .int = 4 }, row[4]);
    try testing.expectEqual(Cell{ .float = 2.5 }, row[5]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "GROUP BY with COUNT(*) and SUM" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\SELECT g, COUNT(*) AS c, SUM(v) AS s
        \\FROM UNNEST([
        \\  STRUCT('a' AS g, 1 AS v),
        \\  STRUCT('a', 2),
        \\  STRUCT('b', 5)
        \\]) AS row
        \\GROUP BY g
        \\ORDER BY g
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const row1 = (try rows.next()).?;
    try testing.expectEqualStrings("a", row1[0].string);
    try testing.expectEqual(Cell{ .int = 2 }, row1[1]);
    try testing.expectEqual(Cell{ .int = 3 }, row1[2]);
    const row2 = (try rows.next()).?;
    try testing.expectEqualStrings("b", row2[0].string);
    try testing.expectEqual(Cell{ .int = 1 }, row2[1]);
    try testing.expectEqual(Cell{ .int = 5 }, row2[2]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "DISTINCT / IGNORE NULLS / ORDER BY / LIMIT modifiers" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // SUM(DISTINCT ...)
    {
        var rows = try db.query(
            "SELECT SUM(DISTINCT x) FROM UNNEST([1, 1, 2, 2, 3]) AS x",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(Cell{ .int = 6 }, row[0]);
    }

    // ARRAY_AGG with ORDER BY ... DESC LIMIT 2.
    {
        var rows = try db.query(
            "SELECT ARRAY_AGG(x ORDER BY x DESC LIMIT 2) FROM UNNEST([2, 3, 1]) AS x",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(@as(usize, 2), row[0].array.len);
        try testing.expectEqual(Cell{ .int = 3 }, row[0].array[0]);
        try testing.expectEqual(Cell{ .int = 2 }, row[0].array[1]);
    }

    // ARRAY_AGG(x IGNORE NULLS) drops NULL inputs instead of erroring.
    {
        var rows = try db.query(
            "SELECT ARRAY_AGG(x IGNORE NULLS) FROM UNNEST([1, NULL, 2]) AS x",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqual(@as(usize, 2), row[0].array.len);
    }

    // STRING_AGG with delimiter and ORDER BY.
    {
        var rows = try db.query(
            "SELECT STRING_AGG(s, '-' ORDER BY s) FROM UNNEST(['b', 'c', 'a']) AS s",
            &.{},
            .{},
        );
        defer rows.deinit();
        const row = (try rows.next()).?;
        try testing.expectEqualStrings("a-b-c", row[0].string);
    }
}

test "COUNTIF / LOGICAL_AND / LOGICAL_OR / bit aggregates" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\SELECT
        \\  COUNTIF(x > 1),
        \\  LOGICAL_AND(x > 0),
        \\  LOGICAL_OR(x > 2),
        \\  BIT_AND(x),
        \\  BIT_OR(x),
        \\  BIT_XOR(x)
        \\FROM UNNEST([1, 2, 3]) AS x
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(Cell{ .int = 2 }, row[0]);
    try testing.expectEqual(Cell{ .bool = true }, row[1]);
    try testing.expectEqual(Cell{ .bool = true }, row[2]);
    try testing.expectEqual(Cell{ .int = 0 }, row[3]);
    try testing.expectEqual(Cell{ .int = 3 }, row[4]);
    // 1^2^3 = 0. This returned 1 while BIT_XOR seeded its accumulator with an
    // in-band sentinel of 1 and treated a running value of 1 as "unset",
    // silently dropping the first input; BigQuery returns 0.
    try testing.expectEqual(Cell{ .int = 0 }, row[5]);
}

test "empty input: SUM -> NULL, COUNT -> 0" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT SUM(x), COUNT(x), MAX(x) FROM UNNEST(CAST([] AS ARRAY<INT64>)) AS x",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expect(row[0] == .null);
    try testing.expectEqual(Cell{ .int = 0 }, row[1]);
    try testing.expect(row[2] == .null);
}

test "ANY_VALUE with HAVING MAX / HAVING MIN" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\SELECT
        \\  ANY_VALUE(name HAVING MAX score),
        \\  ANY_VALUE(name HAVING MIN score)
        \\FROM UNNEST([
        \\  STRUCT('low' AS name, 10 AS score),
        \\  STRUCT('high', 30),
        \\  STRUCT('mid', 20)
        \\]) AS row
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqualStrings("high", row[0].string);
    try testing.expectEqualStrings("low", row[1].string);
}

test "HAVING clause filters aggregate groups (FilterScan above AggregateScan)" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\SELECT g, SUM(v) AS s
        \\FROM UNNEST([
        \\  STRUCT('a' AS g, 1 AS v),
        \\  STRUCT('a', 2),
        \\  STRUCT('b', 5)
        \\]) AS row
        \\GROUP BY g
        \\HAVING SUM(v) > 4
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqualStrings("b", row[0].string);
    try testing.expectEqual(Cell{ .int = 5 }, row[1]);
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

// GROUP BY GROUPING SETS / ROLLUP / CUBE. The analyzer hands these over as
// three different node kinds, all expanded to a flat set list by
// coordinator/extractor.zig before buildGroupingSetsQuery above sees them.
// Every expected result below was taken from BigQuery
// (recidiviz-bigquery-sandbox), row order included.

/// The three-row fixture the grouping tests share: two keys, three rows.
const grouping_rows =
    \\FROM UNNEST([
    \\  STRUCT('x' AS a, 'p' AS b, 1 AS v),
    \\  STRUCT('x', 'q', 2),
    \\  STRUCT('y', 'p', 4)
    \\])
;

/// Runs `select_and_group` over `grouping_rows` and checks (a, b, SUM(v))
/// against `want`, where an empty string stands for a NULL grouping column.
fn expectGrouping(
    select_and_group: []const u8,
    want: []const [3][]const u8,
) !void {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const sql = try std.fmt.allocPrint(
        testing.allocator,
        "SELECT a, b, SUM(v) AS s {s} {s} ORDER BY a NULLS LAST, b NULLS LAST",
        .{ grouping_rows, select_and_group },
    );
    defer testing.allocator.free(sql);

    var rows = try db.query(sql, &.{}, .{});
    defer rows.deinit();

    for (want) |w| {
        const row = (try rows.next()) orelse return error.TooFewRows;
        for (w[0..2], 0..) |cell, i| {
            if (cell.len == 0) {
                try testing.expect(row[i] == .null);
            } else {
                try testing.expectEqualStrings(cell, row[i].string);
            }
        }
        try testing.expectEqual(
            Cell{ .int = try std.fmt.parseInt(i64, w[2], 10) },
            row[2],
        );
    }
    try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
}

test "GROUP BY ROLLUP walks the prefixes of its grouping list" {
    // ROLLUP(a, b) is (a, b), (a), ().
    try expectGrouping("GROUP BY ROLLUP(a, b)", &.{
        .{ "x", "p", "1" },
        .{ "x", "q", "2" },
        .{ "x", "", "3" },
        .{ "y", "p", "4" },
        .{ "y", "", "4" },
        .{ "", "", "7" },
    });
}

test "GROUP BY CUBE takes every subset of its grouping list" {
    // CUBE(a, b) is (a, b), (a), (b), () — ROLLUP's sets plus (b).
    try expectGrouping("GROUP BY CUBE(a, b)", &.{
        .{ "x", "p", "1" },
        .{ "x", "q", "2" },
        .{ "x", "", "3" },
        .{ "y", "p", "4" },
        .{ "y", "", "4" },
        .{ "", "p", "5" },
        .{ "", "q", "2" },
        .{ "", "", "7" },
    });
}

test "GROUP BY CUBE over one column is GROUP BY ROLLUP over it" {
    // Both are (a), (), so the two queries agree — the single case where CUBE's
    // subsets and ROLLUP's prefixes coincide.
    for ([_][]const u8{ "CUBE(a)", "ROLLUP(a)" }) |grouping| {
        var db = try driver.Db.open(testing.allocator, ":memory:");
        defer db.close();

        const sql = try std.fmt.allocPrint(
            testing.allocator,
            "SELECT a, SUM(v) AS s " ++ grouping_rows ++ " GROUP BY {s} ORDER BY a NULLS LAST",
            .{grouping},
        );
        defer testing.allocator.free(sql);

        var rows = try db.query(sql, &.{}, .{});
        defer rows.deinit();

        var row = (try rows.next()).?;
        try testing.expectEqualStrings("x", row[0].string);
        try testing.expectEqual(Cell{ .int = 3 }, row[1]);
        row = (try rows.next()).?;
        try testing.expectEqualStrings("y", row[0].string);
        try testing.expectEqual(Cell{ .int = 4 }, row[1]);
        row = (try rows.next()).?;
        try testing.expect(row[0] == .null);
        try testing.expectEqual(Cell{ .int = 7 }, row[1]);
        try testing.expectEqual(@as(?[]const Cell, null), try rows.next());
    }
}

test "GROUP BY GROUPING SETS takes the sets as written" {
    // A parenthesised item groups by both its columns at once.
    try expectGrouping("GROUP BY GROUPING SETS (a, (a, b), ())", &.{
        .{ "x", "p", "1" },
        .{ "x", "q", "2" },
        .{ "x", "", "3" },
        .{ "y", "p", "4" },
        .{ "y", "", "4" },
        .{ "", "", "7" },
    });
}

test "GROUPING SETS expands a ROLLUP nested inside it" {
    // GROUPING SETS (a, ROLLUP(b)) is (a), (b), () — the analyzer leaves the
    // ROLLUP as a sibling node in one flat list and the extractor expands it
    // in place.
    try expectGrouping("GROUP BY GROUPING SETS (a, ROLLUP(b))", &.{
        .{ "x", "", "3" },
        .{ "y", "", "4" },
        .{ "", "p", "5" },
        .{ "", "q", "2" },
        .{ "", "", "7" },
    });
}

test "a grouping element beside ROLLUP is rejected, as BigQuery rejects it" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    // FEATURE_MULTI_GROUPING_SETS is off in shim/analyzer_shim.cc precisely so
    // that this fails here the way it fails in BigQuery.
    try testing.expectError(error.AnalyzeFailed, db.query(
        "SELECT a, SUM(v) AS s " ++ grouping_rows ++ " GROUP BY a, ROLLUP(b)",
        &.{},
        .{},
    ));
}
