//! A column reference.
//!
//! Converts ColumnRefData to an SQLExpression: the expression that computes
//! the column if its defining scan has not projected it yet, otherwise the
//! qualified reference from the fragment context's ID-based lookup.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SQLExpression {
    if (data.type != .column) return error.UnsupportedNode;
    const column_data = data.column orelse return error.UnsupportedNode;

    // A column whose defining scan has not spent a subquery level on it yet is
    // referenced by the expression that computes it, not by a name that does
    // not exist. GoogleSQL VisitResolvedColumnRef (sql_builder.cc:1100).
    //
    // Hand out a shallow copy rather than the pending pointer itself: several
    // use sites would otherwise share one node, and ORDER BY construction
    // assigns `collation` in place (see transformer/common.zig), which would
    // reach every other use of the same column.
    if (ctx.fragmentContext().getPending(column_data.column_id)) |expr| {
        const copy = try coord.alloc.create(sqlbuilder.SQLExpression);
        copy.* = expr.*;
        return copy;
    }

    return ctx.fragmentContext().getQualifiedColumnExpression(column_data.column_id);
}
