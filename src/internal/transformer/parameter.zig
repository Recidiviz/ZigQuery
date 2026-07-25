//! Faithful port of go-zetasqlite internal/transformer_parameter.go.
//!
//! Emits the parameter identifier as a literal SQLite expression: positional
//! parameters arrive as "?" and named parameters as "@name" (both are valid
//! SQLite parameter placeholders), preserving the reference for runtime
//! substitution during binding.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go ParameterTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SQLExpression {
    _ = ctx;
    const param = data.parameter orelse return error.UnsupportedNode;
    const expr = try coord.alloc.create(sqlbuilder.SQLExpression);
    expr.* = .{ .type = .literal, .value = param.identifier };
    return expr;
}
