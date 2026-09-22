//! One CTE definition: its subquery transforms, the position-based column mapping is registered
//! under the CTE name, and the result is wrapped in a WithClause. A recursive CTE registers its
//! mapping before the subquery transforms, so the self-reference can see the columns; a plain one
//! registers afterwards.
//!
//! The CTE body is the transformed subquery's SELECT directly, with no `SELECT * FROM (...)`
//! around it. See the comment at the branch below.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.WithClause {
    if (data.type != .with_entry) return error.UnsupportedNode;
    const with_entry_data = data.with_entry_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // For recursive CTEs, register column mappings BEFORE transforming the
    // subquery so that the recursive reference can see the CTE's columns.
    const is_recursive = std.mem.eql(
        u8,
        ctx.getRecursiveCTEName(),
        with_entry_data.with_query_name,
    );
    if (is_recursive) {
        try ctx.addWithEntryColumnMapping(
            alloc,
            with_entry_data.with_query_name,
            with_entry_data.column_list,
        );
    }

    // Transform the subquery.
    const subquery_from_item = try coord.materializeScan(
        try coord.transformScan(with_entry_data.with_subquery, ctx),
        ctx,
    );

    // For non-recursive CTEs, register column mappings AFTER transforming.
    if (!is_recursive) {
        try ctx.addWithEntryColumnMapping(
            alloc,
            with_entry_data.with_query_name,
            with_entry_data.column_list,
        );
    }

    // The transformed subquery's SELECT is the CTE body directly, with no `SELECT * FROM (...)`
    // around it: that wrapper would carry nothing, since the inner SELECT already is the body and
    // its id-based aliases are what the position mapping registered above refers to. One
    // subquery level per CTE is 3.0% of the corpus's prepared bytes.
    var query_statement: *sqlbuilder.SelectStatement = undefined;
    if (subquery_from_item.type == .subquery and subquery_from_item.subquery != null) {
        query_statement = subquery_from_item.subquery.?;
    } else {
        query_statement = try sqlbuilder.newSelectStarStatement(alloc, subquery_from_item);
    }

    const with_clause = try alloc.create(sqlbuilder.WithClause);
    with_clause.* = .{
        .name = with_entry_data.with_query_name,
        .query = query_statement,
    };
    return with_clause;
}
