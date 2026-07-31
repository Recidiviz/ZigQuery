//! Faithful port of go-zetasqlite internal/transformer_stmt_dml.go.
//!
//! Converts INSERT / UPDATE / DELETE statement data to SQLite DML fragments.
//! Column names are the RAW SQLite column names: the fragment context's
//! addAvailableColumnsForDML registers the target table's columns without
//! ID-based aliases before WHERE/SET expressions are transformed.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go DMLStmtTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    switch (data.type) {
        .insert => return transformInsert(coord, data, ctx),
        .update => return transformUpdate(coord, data, ctx),
        .delete => return transformDelete(coord, data, ctx),
        // Go: "unsupported DML statement type: %v"
        else => return error.UnsupportedNode,
    }
}

/// Go transformInsert: INSERT ... VALUES vs INSERT ... SELECT.
fn transformInsert(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    // Go: "expected insert statement data, got nil"
    const insert_data = data.insert orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Format column names.
    const columns = try alloc.alloc([]const u8, insert_data.columns.len);
    for (insert_data.columns, 0..) |col, i| {
        columns[i] = try std.fmt.allocPrint(alloc, "`{s}`", .{col});
    }

    const insert_stmt = try alloc.create(sqlbuilder.InsertStatement);
    insert_stmt.* = .{
        .table_name = insert_data.table_name,
        .columns = columns,
    };

    if (insert_data.query) |query| {
        // INSERT ... SELECT.
        const from_clause = query.from_clause orelse return error.InvalidAST;
        const from_item = try coord.materializeScan(
            try coord.transformScan(from_clause.*, ctx),
            ctx,
        );

        const select_stmt = try sqlbuilder.newSelectStatement(alloc);
        select_stmt.from_clause = from_item;

        var select_list: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
        try select_list.ensureTotalCapacity(alloc, query.select_list.len);
        for (query.select_list) |item| {
            const expr = try coord.transformExpression(item.expression, ctx);
            const sel_item = try alloc.create(sqlbuilder.SelectListItem);
            sel_item.* = .{ .expression = expr, .alias = item.alias };
            try select_list.append(alloc, sel_item);
        }
        select_stmt.select_list = try select_list.toOwnedSlice(alloc);

        insert_stmt.query = select_stmt;
    } else {
        // INSERT ... VALUES: each row renders as one comma-joined literal
        // expression (Go joins the transformed value strings).
        const rows = try alloc.alloc(sqlbuilder.SQLFragment, insert_data.values.len);
        for (insert_data.values, 0..) |row_values, i| {
            var value_strings: std.ArrayList([]const u8) = .empty;
            try value_strings.ensureTotalCapacity(alloc, row_values.len);
            for (row_values) |value| {
                const expr = try coord.transformExpression(value, ctx);
                try value_strings.append(alloc, try expr.toString(alloc));
            }
            const row_expr = try alloc.create(sqlbuilder.SQLExpression);
            row_expr.* = .{
                .type = .literal,
                .value = try std.mem.join(alloc, ",", value_strings.items),
            };
            rows[i] = .{ .expression = row_expr };
        }
        insert_stmt.rows = rows;
    }

    return .{ .insert_statement = insert_stmt };
}

/// Go transformUpdate.
fn transformUpdate(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    // Go: "expected update statement data, got nil"
    const update_data = data.update orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Register the base table's raw column names before transforming the
    // SET items / WHERE clause.
    const table_scan = update_data.table_scan orelse return error.InvalidAST;
    try ctx.fragmentContext().addAvailableColumnsForDML(table_scan);

    const table = try alloc.create(sqlbuilder.FromItem);
    table.* = .{ .type = .table, .table_name = update_data.table_name };

    const update_stmt = try alloc.create(sqlbuilder.UpdateStatement);
    update_stmt.* = .{ .table = table };

    // FROM clause (for JOINs in UPDATE) first: makes its columns available
    // to the SetItems / WhereClause, like Go.
    if (update_data.from_clause) |from_clause| {
        update_stmt.from_clause = try coord.materializeScan(
            try coord.transformScan(from_clause.*, ctx),
            ctx,
        );
    }

    const set_items = try alloc.alloc(*sqlbuilder.SetItem, update_data.set_items.len);
    for (update_data.set_items, 0..) |item, i| {
        const value = try coord.transformExpression(item.value, ctx);
        const set_item = try alloc.create(sqlbuilder.SetItem);
        set_item.* = .{
            .column = try sqlbuilder.newLiteralExpression(alloc, item.column),
            .value = value,
        };
        set_items[i] = set_item;
    }
    update_stmt.set_items = set_items;

    if (update_data.where_clause) |where_clause| {
        update_stmt.where_clause = try coord.transformExpression(where_clause.*, ctx);
    }
    return .{ .update_statement = update_stmt };
}

/// Go transformDelete.
fn transformDelete(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    // Go: "expected delete statement data, got nil"
    const delete_data = data.delete orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const table = try alloc.create(sqlbuilder.FromItem);
    table.* = .{ .type = .table, .table_name = delete_data.table_name };

    const delete_stmt = try alloc.create(sqlbuilder.DeleteStatement);
    delete_stmt.* = .{ .table = .{ .from_item = table } };

    // Register raw column names before transforming the WHERE clause.
    const table_scan = delete_data.table_scan orelse return error.InvalidAST;
    try ctx.fragmentContext().addAvailableColumnsForDML(table_scan);

    if (delete_data.where_clause) |where_clause| {
        const where_expr = try coord.transformExpression(where_clause.*, ctx);
        delete_stmt.where_expr = .{ .expression = where_expr };
    }

    return .{ .delete_statement = delete_stmt };
}
