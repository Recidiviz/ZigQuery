//! One row with no table source, as `SELECT 1` has.
//!
//! The scan produces a single row from nowhere,
//! so the transform yields a FromItem the SELECT renderer omits entirely.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) types_data.Error!*sqlbuilder.SelectStatement {
    _ = ctx;
    if (data.type != .single_row) return error.UnsupportedNode;

    const item = try coord.alloc.create(sqlbuilder.FromItem);
    item.* = .{ .type = .single_row };
    const stmt = try sqlbuilder.newSelectStatement(coord.alloc);
    stmt.from_clause = item;
    return stmt;
}
