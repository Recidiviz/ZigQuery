//! A literal. A scalar renders natively; a complex value becomes the codec's binary BLOB
//! See codec_sortable.zig

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const encoder = @import("../encoder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SQLExpression {
    _ = ctx;
    // A literal with no payload is a broken extraction, not an empty literal.
    const literal = data.literal orelse return error.InvalidAST;
    const encoded = try encoder.LiteralFromValue(coord.alloc, literal.value);
    const expr = try coord.alloc.create(sqlbuilder.SQLExpression);
    expr.* = .{ .type = .literal, .value = encoded };
    return expr;
}
