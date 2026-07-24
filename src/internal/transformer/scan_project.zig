//! Faithful port of go-zetasqlite internal/transformer_scan_project.go.
//!
//! Recursively transforms the input scan, resolves each output column either
//! through its computed expression or as a qualified column reference, gives
//! every SELECT item an ID-based alias, and wraps the result in a subquery
//! FROM item (the coordinator assigns the scan alias).

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go ProjectScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.FromItem {
    // Go: "expected project scan data, got type %v"
    if (data.type != .project) return error.UnsupportedNode;
    const project_data = data.project_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const inner_from_item = try coord.transformScan(project_data.input_scan, ctx);

    // Build a map of computed expressions by column ID for efficient lookup.
    var computed_expr_map = std.AutoHashMap(i64, types_data.ExpressionData).init(alloc);
    for (project_data.expr_list) |computed_col| {
        const id = if (computed_col.column) |col| col.id else 0;
        try computed_expr_map.put(id, computed_col.expression);
    }

    // Now build the projection - expressions can resolve column references.
    const select_list = try alloc.alloc(*sqlbuilder.SelectListItem, data.column_list.len);
    for (data.column_list, 0..) |col, i| {
        // ID-based alias for disambiguation.
        const alias = try context.generateIDBasedAlias(alloc, col.name, col.id);

        var expr: *sqlbuilder.SQLExpression = undefined;
        if (computed_expr_map.get(col.id)) |computed_expr_data| {
            // Transform the computed expression.
            expr = try coord.transformExpression(computed_expr_data, ctx);
        } else {
            // No computed expression - create a column reference resolved by
            // the ColumnRef transformer through the FragmentContext.
            const ref = try alloc.create(types_data.ColumnRefData);
            ref.* = .{
                .column_name = col.name,
                .column_id = col.id,
                .table_name = col.table_name,
            };
            expr = try coord.transformExpression(
                .{ .type = .column, .column = ref },
                ctx,
            );
        }

        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{ .expression = expr, .alias = alias };
        select_list[i] = item;
    }

    // Create the SELECT statement.
    const select_stmt = try alloc.create(sqlbuilder.SelectStatement);
    select_stmt.* = .{
        .select_list = select_list,
        .from_clause = inner_from_item,
    };

    // Return as a subquery FROM item - alias will be set by the coordinator.
    const from_item = try alloc.create(sqlbuilder.FromItem);
    from_item.* = .{ .type = .subquery, .subquery = select_stmt };
    return from_item;
}
