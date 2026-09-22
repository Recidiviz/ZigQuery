//! A query parameter, emitted as the placeholder itself:
//! - `?` positionally
//! - `@name` by name.
//! Both are SQLite's placeholder syntax for the driver to bind.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SQLExpression {
    _ = ctx;
    const param = data.parameter orelse return error.UnsupportedNode;
    const expr = try coord.alloc.create(sqlbuilder.SQLExpression);
    expr.* = .{ .type = .literal, .value = param.identifier };
    return expr;
}
