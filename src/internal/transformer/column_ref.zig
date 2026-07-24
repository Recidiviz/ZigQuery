//! Faithful port of go-zetasqlite internal/transformer_column_ref.go.
//!
//! Converts ColumnRefData to a qualified column SQLExpression via the
//! fragment context's ID-based lookup.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go ColumnRefTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SQLExpression {
    _ = coord;
    // Go: "expected column reference data, got type %v"
    if (data.type != .column) return error.UnsupportedNode;
    const column_data = data.column orelse return error.UnsupportedNode;

    return ctx.fragmentContext().getQualifiedColumnExpression(column_data.column_id);
}
