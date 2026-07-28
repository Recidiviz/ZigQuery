//! Faithful port of go-zetasqlite internal/transformer_scan_table.go.
//!
//! The TableScan is the leaf of the scan transformation tree: a subquery
//! that SELECTs every scan output column from the SQLite table under its
//! ID-based alias (name__id), so parent scans resolve columns uniformly.
//! Synthetic columns (wildcard-table _TABLE_SUFFIX expressions in Go) are
//! transformed and appended after the real columns; the wildcard catalog
//! itself is not ported yet, so the list is empty in practice.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go TableScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    // Go: "expected table scan data, got type %v"
    if (data.type != .table) return error.UnsupportedNode;
    const table_data = data.table_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Each output column is the raw SQLite column, left pending: whoever
    // consumes this scan either references it in place or projects it under
    // its id-based alias when it materializes. Projecting here unconditionally
    // is what used to make every table scan cost a subquery level.
    for (data.column_list) |col| {
        const column_expr = try alloc.create(sqlbuilder.SQLExpression);
        column_expr.* = .{ .type = .column, .value = col.name };
        try ctx.fragmentContext().setPending(col.id, column_expr);
    }

    // Synthetic columns (wildcard tables): expression stands in for a
    // column the matched table lacks. These carry their own alias rather than
    // an id-based one, so they are projected here and the scan takes a level.
    var select_list: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
    for (table_data.synthetic_columns) |item_data| {
        if (item_data.expression.type == .column) {
            if (item_data.expression.column) |column| {
                try ctx.fragmentContext().registerColumnScope(column.column_id, "");
                const info = try alloc.create(context.ColumnInfo);
                info.* = .{ .name = column.column_name };
                try ctx.fragmentContext().addAvailableColumn(column.column_id, info);
            }
        }
        const expr = try coord.transformExpression(item_data.expression, ctx);
        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{ .expression = expr, .alias = item_data.alias };
        try select_list.append(alloc, item);
    }

    // The table FROM item.
    const table_from_item = try alloc.create(sqlbuilder.FromItem);
    table_from_item.* = .{
        .type = .table,
        .table_name = table_data.table_name,
        .alias = table_data.alias,
    };

    const select_statement = try sqlbuilder.newSelectStatement(alloc);
    select_statement.select_type = .standard;
    select_statement.from_clause = table_from_item;
    if (select_list.items.len > 0) {
        // Synthetic columns present: project the real ones alongside them.
        var full: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
        for (data.column_list) |col| {
            const expr = ctx.fragmentContext().takePending(col.id) orelse continue;
            const item = try alloc.create(sqlbuilder.SelectListItem);
            item.* = .{
                .expression = expr,
                .alias = try context.generateIDBasedAlias(alloc, col.name, col.id),
            };
            try full.append(alloc, item);
        }
        try full.appendSlice(alloc, select_list.items);
        select_statement.select_list = try full.toOwnedSlice(alloc);
    }

    return select_statement;
}
