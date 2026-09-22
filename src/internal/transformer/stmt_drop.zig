//! DROP. A leaf: the extracted DropData maps straight to a DropStatement fragment, with nothing
//! to transform recursively.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    _ = ctx;
    if (data.type != .drop) return error.UnsupportedNode;
    const drop_data = data.drop orelse return error.UnsupportedNode;

    const drop_stmt = try coord.alloc.create(sqlbuilder.DropStatement);
    drop_stmt.* = .{
        .if_exists = drop_data.if_exists,
        .object_type = drop_data.object_type,
        .object_name = drop_data.object_name,
    };
    return .{ .drop_statement = drop_stmt };
}
