//! Faithful port of go-zetasqlite internal/transformer_scan_single_row.go.
//!
//! A SingleRowScan produces one row with no table source (e.g. "SELECT 1"),
//! so the transform yields a FromItem the SELECT renderer omits entirely.

const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go SingleRowScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    _ = ctx;
    // Go: "expected single row scan data, got type %v"
    if (data.type != .single_row) return error.UnsupportedNode;

    const item = try coord.alloc.create(sqlbuilder.FromItem);
    item.* = .{ .type = .single_row };
    const stmt = try sqlbuilder.newSelectStatement(coord.alloc);
    stmt.from_clause = item;
    return stmt;
}
