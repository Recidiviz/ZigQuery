//! Faithful port of go-zetasqlite internal/transformer_stmt_create_view.go.
//!
//! Transforms the view's SELECT query through the statement pipeline and
//! wraps it in a CreateViewStatement fragment.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go CreateViewStmtTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) types_data.Error!sqlbuilder.SQLFragment {
    // Go: "expected CREATE VIEW statement data for CREATE VIEW"
    if (data.type != .create) return error.UnsupportedNode;
    const create_data = data.create orelse return error.UnsupportedNode;
    const view = create_data.view orelse return error.UnsupportedNode;

    const select_fragment = try coord.transformStatement(
        .{ .type = .select, .select = &view.query },
        ctx,
    );

    const create_view_stmt = try coord.alloc.create(sqlbuilder.CreateViewStatement);
    create_view_stmt.* = .{
        .view_name = view.view_name,
        .query = select_fragment,
    };
    return .{ .create_view_statement = create_view_stmt };
}
