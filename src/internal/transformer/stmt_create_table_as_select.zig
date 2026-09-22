//! CREATE TABLE ... AS SELECT. The query transforms through the statement pipeline and is wrapped
//! in a CreateTableStatement fragment; the driver pulls the AS SELECT text back out to persist it
//! in the table spec, then runs the schema that spec renders.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    if (data.type != .create) return error.UnsupportedNode;
    const create_data = data.create orelse return error.UnsupportedNode;
    const table = create_data.table orelse return error.UnsupportedNode;
    const as_select = table.as_select orelse return error.UnsupportedNode;

    const select_fragment = try coord.transformStatement(
        .{ .type = .select, .select = as_select },
        ctx,
    );
    const select_stmt = switch (select_fragment) {
        .select_statement => |s| s,
        else => return error.UnsupportedNode,
    };

    const create_table_stmt = try coord.alloc.create(sqlbuilder.CreateTableStatement);
    create_table_stmt.* = .{
        .if_not_exists = table.if_not_exists,
        .table_name = table.table_name,
        .as_select = @constCast(select_stmt),
    };
    return .{ .create_table_statement = create_table_stmt };
}
