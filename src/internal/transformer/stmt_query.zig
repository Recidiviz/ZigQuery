//! Faithful port of go-zetasqlite internal/transformer_stmt_query.go.
//!
//! Transforms the main query scan into the FROM clause and each output
//! column into a SELECT list item carrying the user-visible alias.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const query_expr = @import("../sqlbuilder/query_expr.zig");

/// Go QueryStmtTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) interfaces.Error!sqlbuilder.SQLFragment {
    // Go: "expected select statement data for query stmt, got type %v"
    if (data.type != .select) return error.UnsupportedNode;
    const select_data = data.select orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Go dereferences *selectData.FromClause unconditionally.
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
