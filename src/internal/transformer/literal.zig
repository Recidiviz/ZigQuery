//! Faithful port of go-zetasqlite internal/transformer_literal.go.
//!
//! Converts LiteralData to a literal SQLExpression by encoding the value
//! with LiteralFromValue (scalars render natively; complex values become a
//! double-quoted base64 payload).

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const encoder = @import("../encoder.zig");

/// Go LiteralTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SQLExpression {
    _ = ctx;
    // Go dereferences data.Literal unconditionally; a missing payload is a
    // broken extraction ("failed to encode literal").
    const literal = data.literal orelse return error.InvalidAST;
    const encoded = try encoder.LiteralFromValue(coord.alloc, literal.value);
    const expr = try coord.alloc.create(sqlbuilder.SQLExpression);
    expr.* = .{ .type = .literal, .value = encoded };
    return expr;
}
