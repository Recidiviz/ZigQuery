//! A table scan, the leaf of the scan transformation tree: a subquery selecting every scan output
//! column from the SQLite table under its ID-based alias (`name__id`), so a parent scan resolves
//! columns the same way whatever sits beneath it.
//!
//! Synthetic columns transform and append after the real ones. Wildcard tables are unsupported,
//! which is the only thing that puts a column in that list, so it is empty.
// ephor:ignore-file ZA301 ZA302

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const info_schema_vtab = @import("../function/info_schema_vtab.zig");

/// The canonical prefix out of `<prefix>_INFORMATION_SCHEMA_<VIEW>` — i.e. the
/// `_`-joined path of the dataset the view belongs to.
///
/// The prefix, not the bare dataset name: canonical names are `_`-joined and
/// dataset names legitimately contain underscores, so `demo_ds_INFORMATION_
/// SCHEMA_TABLES` cannot be split back into (dataset `demo_ds`) versus
/// (project `demo`, dataset `ds`). Comparing whole prefixes sidesteps that —
/// a table and its dataset's views always share one.
fn infoSchemaPrefix(canonical: []const u8) []const u8 {
    const marker = "_" ++ info_schema_vtab.info_schema_segment ++ "_";
    const at = std.mem.lastIndexOf(u8, canonical, marker) orelse return "";
    return canonical[0..at];
}

/// A SQL string literal, single quotes doubled.
fn quoteLiteral(alloc: std.mem.Allocator, s: []const u8) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    try buf.append(alloc, '\'');
    for (s) |ch| {
        if (ch == '\'') try buf.append(alloc, '\'');
        try buf.append(alloc, ch);
    }
    try buf.append(alloc, '\'');
    return buf.toOwnedSlice(alloc);
}

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SelectStatement {
    if (data.type != .table) return error.UnsupportedNode;
    const table_data = data.table_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;
    try ctx.scanned_tables.append(ctx.alloc, table_data.table_name);

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

    // The table FROM item. An INFORMATION_SCHEMA view has no backing SQLite
    // object — the catalog registers it so the analyzer resolves the path, and
    // the scan is rewritten here into a call on the matching virtual table,
    // with the dataset passed through its hidden `schema` column. Recognition
    // is lexical because the extractor hands us the catalog's canonical name
    // verbatim.
    const table_from_item = try alloc.create(sqlbuilder.FromItem);
    if (info_schema_vtab.viewForCanonicalName(table_data.table_name)) |view| {
        const prefix = infoSchemaPrefix(table_data.table_name);
        const arg = try alloc.create(sqlbuilder.SQLExpression);
        arg.* = .{ .type = .literal, .value = try quoteLiteral(alloc, prefix) };
        const args = try alloc.alloc(*sqlbuilder.SQLExpression, 1);
        args[0] = arg;
        const table_function = try alloc.create(sqlbuilder.TableFunction);
        table_function.* = .{ .name = view.module, .arguments = args };
        table_from_item.* = .{
            .type = .table_function,
            .table_function = table_function,
            .alias = table_data.alias,
        };
    } else {
        table_from_item.* = .{
            .type = .table,
            .table_name = table_data.table_name,
            .alias = table_data.alias,
        };
    }

    const select_statement = try sqlbuilder.newSelectStatement(alloc);
    select_statement.select_type = .standard;
    select_statement.from_clause = table_from_item;
    if (select_list.items.len > 0) {
        // Synthetic columns present: project the real ones alongside them.
        var full: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
        for (data.column_list) |col| {
            // Non-consuming, for the same reason as
            // coordinator.addSelectListIfNeeded: a column may be listed twice.
            const expr = ctx.fragmentContext().getPending(col.id) orelse continue;
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
