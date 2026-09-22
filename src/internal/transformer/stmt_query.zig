//! A query statement: the main scan becomes the FROM clause and each output column a SELECT list
//! item under the alias the user wrote.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const query_expr = @import("../sqlbuilder/query_expr.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    if (data.type != .select) return error.UnsupportedNode;
    const select_data = data.select orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // A select statement with no FROM clause is a malformed AST.
    const from_clause = select_data.from_clause orelse return error.InvalidAST;
    const input = try coord.transformScan(from_clause.*, ctx);

    // The statement's own output list is a projection like any other: claim
    // the scan's select slot when it is free rather than always spending a
    // level to rename id-based aliases to the user's. This is the outermost
    // SELECT of every query, so it is one level per statement.
    const select_statement = if (query_expr.canSetSelect(input.query))
        input.query
    else
        try coord.wrapScan(input, ctx);

    // Transform each output column using pure data.
    var select_list: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
    try select_list.ensureTotalCapacity(alloc, select_data.select_list.len);
    for (select_data.select_list) |output_item| {
        const expr = try coord.transformExpression(output_item.expression, ctx);

        const item = try alloc.create(sqlbuilder.SelectListItem);
        item.* = .{ .expression = expr, .alias = output_item.alias };
        try select_list.append(alloc, item);
    }
    select_statement.select_list = try select_list.toOwnedSlice(alloc);

    return .{ .select_statement = select_statement };
}
