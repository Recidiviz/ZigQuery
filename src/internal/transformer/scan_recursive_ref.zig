//! The self-reference inside a recursive CTE's recursive term.
//!
//! Becomes a subquery that selects the recursive CTE's columns,
//! aliased with the stored id-based column mapping so the enclosing query can
//! resolve them.
// ephor:ignore-file ZA701

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
    if (data.type != .recursive_ref) return error.UnsupportedNode;
    const recursive_ref_scan = data.recursive_ref_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Get the recursive CTE name from context.
    const recursive_cte_name = ctx.getRecursiveCTEName();
    if (recursive_cte_name.len == 0) return error.ValidationFailed;

    // Create a SELECT statement that references the recursive CTE by name.
    const table_alias = try std.fmt.allocPrint(alloc, "rrs{s}", .{ctx.fragmentContext().getID()});
    const select_statement = try sqlbuilder.newSelectStatement(alloc);
    const from_item = try alloc.create(sqlbuilder.FromItem);
    from_item.* = .{ .type = .table, .table_name = recursive_cte_name, .alias = table_alias };
    select_statement.from_clause = from_item;

    // Get stored column mappings from context for this recursive CTE.
    const mapping = ctx.getWithEntryMapping(recursive_cte_name) orelse return error.ValidationFailed;
    if (mapping.len != recursive_ref_scan.column_list.len) return error.ValidationFailed;

    // Leave each column pending, like scan_with_ref: the recursive CTE
    // reference is already a FROM item.
    for (recursive_ref_scan.column_list, 0..) |column, i| {
        try ctx.fragmentContext().setPending(
            column.id,
            try sqlbuilder.newColumnExpression(alloc, mapping[i], table_alias),
        );
    }

    return select_statement;
}
