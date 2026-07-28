//! Port of go-zetasqlite internal/transformer_with_entry.go.
//!
//! Transforms one CTE definition: transforms its subquery, registers the
//! position-based column mapping under the CTE name (before the subquery
//! for recursive CTEs so the recursive reference can see the columns, after
//! for non-recursive ones), and wraps the result in a WithClause.
//!
//! Deliberate divergence from Go: the CTE body is the transformed subquery's
//! SELECT, not a `SELECT * FROM (...)` around it. See the comment at the
//! branch below.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go WithEntryTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.WithClause {
    // Go: "expected with entry data, got type %v"
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

    // Use the transformed subquery's SELECT directly as the CTE body. Go
    // does this only for recursive CTEs (to preserve the UNION ALL structure
    // SQLite's recursive CTE support requires) and wraps every other body in
    // a `SELECT * FROM (...)`. That wrapper carries nothing: the inner SELECT
    // already is the body, and its id-based aliases are exactly what the
    // position mapping registered above refers to. Dropping it removes one
    // subquery level per CTE — 3.0% of the corpus's prepared bytes.
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
