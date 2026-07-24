//! Faithful port of go-zetasqlite internal/transformer_with_entry.go.
//!
//! Transforms one CTE definition: transforms its subquery, registers the
//! position-based column mapping under the CTE name (before the subquery
//! for recursive CTEs so the recursive reference can see the columns, after
//! for non-recursive ones), and wraps the result in a WithClause. The
//! recursive branch is mirrored even though scan_with.zig currently gates
//! recursive WITH scans behind error.Unimplemented.

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
    const subquery_from_item = try coord.transformScan(with_entry_data.with_subquery, ctx);

    // For non-recursive CTEs, register column mappings AFTER transforming.
    if (!is_recursive) {
        try ctx.addWithEntryColumnMapping(
            alloc,
            with_entry_data.with_query_name,
            with_entry_data.column_list,
        );
    }

    // For recursive CTEs, use the subquery directly to preserve the
    // UNION ALL structure; for non-recursive CTEs, wrap in a SELECT *.
    var query_statement: *sqlbuilder.SelectStatement = undefined;
    if (is_recursive and subquery_from_item.type == .subquery and
        subquery_from_item.subquery != null)
    {
        // Use the inner SelectStatement directly.
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
