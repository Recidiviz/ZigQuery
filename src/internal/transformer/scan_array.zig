//! Faithful port of go-zetasqlite internal/transformer_scan_array.go.
//!
//! UNNEST via SQLite's json_each table-valued function over
//! zetasqlite_decode_array(<array expr>): json_each's `value` column is the
//! array element and `key` the zero-based offset. Correlated arrays join the
//! transformed input scan against json_each (LEFT when is_outer, INNER with
//! an ON condition, CROSS when there is no join expression).

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go ArrayScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    // Go: "expected array scan data, got type %v"
    if (data.type != .array) return error.UnsupportedNode;
    const array_data = data.array_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Handle input scan for correlated arrays.
    var inner_from_item: ?*sqlbuilder.FromItem = null;
    if (array_data.input_scan) |input_scan| {
        inner_from_item = try coord.materializeScan(
            try coord.transformScan(input_scan.*, ctx),
            ctx,
        );
    }

    // Transform the array expression to UNNEST.
    const array_expr = try coord.transformExpression(array_data.array_expr, ctx);

    // Create the json_each table function call with zetasqlite_decode_array.
    const decode_args = try alloc.alloc(*sqlbuilder.SQLExpression, 1);
    decode_args[0] = array_expr;
    const table_fn_args = try alloc.alloc(*sqlbuilder.SQLExpression, 1);
    table_fn_args[0] = try sqlbuilder.newFunctionExpression(
        alloc,
        "zetasqlite_decode_array",
        decode_args,
    );
    const table_function = try alloc.create(sqlbuilder.TableFunction);
    table_function.* = .{ .name = "json_each", .arguments = table_fn_args };
    const json_each_from_item = try alloc.create(sqlbuilder.FromItem);
    json_each_from_item.* = .{
        .type = .table_function,
        .table_function = table_function,
        .alias = try std.fmt.allocPrint(alloc, "$array_{s}", .{ctx.fragmentContext().getID()}),
    };

    // The element / key columns must be made available prior to the JoinExpr
    // being transformed since they reference return values from SQLite's
    // json_each which do not exist in ZetaSQL. (Go dereferences
    // arrayData.ElementColumn unconditionally.)
    const element_column = array_data.element_column orelse return error.InvalidAST;
    const element_info = try alloc.create(context.ColumnInfo);
    element_info.* = .{
        .id = element_column.id,
        .name = "value",
        // This column name comes from SQLite's table-valued function
        // json_each (our json_each_from_item).
        .expression = try sqlbuilder.newColumnExpression(alloc, "value", json_each_from_item.alias),
    };
    try ctx.fragmentContext().addAvailableColumn(element_column.id, element_info);
    try ctx.fragmentContext().registerColumnScope(element_column.id, json_each_from_item.alias);

    if (array_data.array_offset_column) |offset_column| {
        const offset_info = try alloc.create(context.ColumnInfo);
        offset_info.* = .{
            .id = offset_column.id,
            .name = "key",
            // This column name comes from SQLite's table-valued function
            // json_each (our json_each_from_item).
            .expression = try sqlbuilder.newColumnExpression(alloc, "key", json_each_from_item.alias),
        };
        try ctx.fragmentContext().addAvailableColumn(offset_column.id, offset_info);
        try ctx.fragmentContext().registerColumnScope(offset_column.id, json_each_from_item.alias);
    }

    const unnest_select = try sqlbuilder.newSelectStatement(alloc);
    unnest_select.from_clause = json_each_from_item;

    // json_each's `value`/`key` are already qualified by the $array_N alias;
    // leave them pending rather than spending a level to re-alias them.
    for (data.column_list) |col| {
        const ref = try ctx.fragmentContext().getQualifiedColumnRef(col.id);
        try ctx.fragmentContext().setPending(
            col.id,
            try sqlbuilder.newColumnExpression(alloc, ref.column_name, ref.table_alias),
        );
    }

    // If there's no InputScan we can return the select directly.
    if (array_data.input_scan == null) return unnest_select;

    // Determine join type based on the is_outer flag.
    var join_type: sqlbuilder.JoinType = if (array_data.is_outer) .left else .inner;

    // Handle join condition if present.
    var join_condition: ?*sqlbuilder.SQLExpression = null;
    if (array_data.join_expr) |join_expr| {
        join_condition = try coord.transformExpression(join_expr.*, ctx);
    } else {
        // If there is no join expression use a CROSS JOIN.
        join_type = .cross;
    }

    // Set the FROM clause to be a JOIN between input and UNNEST.
    const join_clause = try alloc.create(sqlbuilder.JoinClause);
    join_clause.* = .{
        .type = join_type,
        .left = inner_from_item,
        .right = json_each_from_item,
        .condition = join_condition,
    };
    const join_from_item = try alloc.create(sqlbuilder.FromItem);
    join_from_item.* = .{ .type = .join, .join = join_clause };
    unnest_select.from_clause = join_from_item;
    return unnest_select;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "UNNEST array literal" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query("SELECT x FROM UNNEST([10, 20]) AS x ORDER BY x", &.{}, .{});
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 10 }, row[0]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 20 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "UNNEST WITH OFFSET exposes json_each key" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT x, o FROM UNNEST([10, 20]) AS x WITH OFFSET AS o ORDER BY o",
        &.{},
        .{},
    );
    defer rows.deinit();

    var row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 10 }, row[0]);
    try testing.expectEqual(driver.Cell{ .int = 0 }, row[1]);
    row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 20 }, row[0]);
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[1]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "correlated UNNEST over an input scan" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "SELECT v FROM (SELECT [1, 2] AS arr), UNNEST(arr) AS v ORDER BY v",
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
