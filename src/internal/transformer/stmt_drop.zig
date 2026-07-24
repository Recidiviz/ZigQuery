//! Faithful port of go-zetasqlite internal/transformer_stmt_drop.go.
//!
//! DROP statements are leaf-level: the extracted DropData maps directly to
//! a DropStatement fragment with no recursive transformation.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go DropStmtTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) interfaces.Error!sqlbuilder.SQLFragment {
    _ = ctx;
    // Go: "expected drop statement data for drop stmt, got type %v"
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
