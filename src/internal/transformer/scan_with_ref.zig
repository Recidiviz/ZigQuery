//! Faithful port of go-zetasqlite internal/transformer_scan_with_ref.go.
//!
//! References a previously defined CTE by name: SELECT the stored
//! position-based column mapping (ctx.getWithEntryMapping) from the CTE
//! table under a fresh "wrs<scope id>" alias, re-aliasing each column with
//! its ID-based output name.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const interfaces = @import("../coordinator/types_interfaces.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

/// Go WithRefScanTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ScanData,
    ctx: *context.TransformContext,
) interfaces.Error!*sqlbuilder.SelectStatement {
    // Go: "expected with ref scan data, got type %v"
    if (data.type != .with_ref) return error.UnsupportedNode;
    const with_ref_data = data.with_ref_scan orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Create a SELECT statement that references the WITH query by name.
    const table_alias = try std.fmt.allocPrint(alloc, "wrs{s}", .{ctx.fragmentContext().getID()});
    const select_statement = try sqlbuilder.newSelectStatement(alloc);
    const table_from_item = try alloc.create(sqlbuilder.FromItem);
    table_from_item.* = .{
        .type = .table,
        .table_name = with_ref_data.with_query_name,
        .alias = table_alias,
    };
    select_statement.from_clause = table_from_item;

    // Get stored column mappings from context for this WITH query.
    // Go: "no entry mapping found for query %v"
    const mapping = ctx.getWithEntryMapping(with_ref_data.with_query_name) orelse
        return error.InvalidAST;
    // Go: "incorrect number of columns found for query %v"
    if (mapping.len != with_ref_data.column_list.len) return error.ValidationFailed;

    // Leave each column pending as `wrsN`.`<cte column>`: the CTE reference is
    // already a FROM item, so re-aliasing them here would cost a subquery
    // level to say nothing the consumer cannot say itself.
    for (with_ref_data.column_list, 0..) |column, i| {
        try ctx.fragmentContext().setPending(
            column.id,
            try sqlbuilder.newColumnExpression(alloc, mapping[i], table_alias),
        );
    }

    return select_statement;
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "CTE referenced twice resolves through position-based mapping" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        "WITH t AS (SELECT 3 AS v) SELECT a.v + b.v AS s FROM t AS a, t AS b",
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 6 }, row[0]);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}
