//! Stub for go-zetasqlite internal/transformer_literal.go — ported by a later task.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SQLExpression {
    _ = coord;
    _ = data;
    _ = ctx;
    return error.Unimplemented;
}
