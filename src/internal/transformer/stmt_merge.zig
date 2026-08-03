//! Faithful port of go-zetasqlite internal/transformer_stmt_merge.go.
//!
//! SQLite has no native MERGE, so the statement is lowered to a sequence of
//! plain statements executed in order by the driver's MergeStmtAction:
//!   1. CREATE TABLE zetasqlite_merged_table AS SELECT DISTINCT * FROM
//!      (source LEFT JOIN target UNION ALL target LEFT JOIN source) with
//!      renamed columns (merged_source_*/merged_target_*),
//!   2. one INSERT / UPDATE ... FROM / DELETE per WHEN clause, filtered via
//!      EXISTS over the merged table,
//!   3. DROP TABLE zetasqlite_merged_table.

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

const Error = types_data.Error;
const ColumnData = types_data.ColumnData;
const ExpressionData = types_data.ExpressionData;

/// Go ColumnMapping: original column -> merged-table column name. Array maps
/// keep Go's per-map grouping but with deterministic iteration order.
const ColumnMapping = struct {
    source_column_map: std.AutoArrayHashMapUnmanaged(*ColumnData, []const u8) = .empty,
    target_column_map: std.AutoArrayHashMapUnmanaged(*ColumnData, []const u8) = .empty,
    all_column_map: std.AutoArrayHashMapUnmanaged(*ColumnData, []const u8) = .empty,

    fn lookupName(self: *const ColumnMapping, column: *ColumnData) ?[]const u8 {
        return self.all_column_map.get(column);
    }
};

/// Go MergeStmtTransformer.Transform.
pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) Error!sqlbuilder.SQLFragment {
    // Go: "expected MERGE statement data, got %v"
    if (data.type != .merge) return error.UnsupportedNode;
    const merge_data = data.merge orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    const target_scan_data = merge_data.target_scan orelse return error.UnsupportedNode;
    const source_scan_data = merge_data.source_scan orelse return error.UnsupportedNode;

    // Transform target and source scans.
    const target_table = try coord.materializeScan(
        try coord.transformScan(target_scan_data.*, ctx),
        ctx,
    );
    const source_table = try coord.materializeScan(
        try coord.transformScan(source_scan_data.*, ctx),
        ctx,
    );

    // Transform merge expression (join condition).
    const merge_expr = try coord.transformExpression(merge_data.merge_expr, ctx);

    // Validate merge expression is an equality of two column references.
    try validateMergeExpression(merge_data.merge_expr);

    // Extract source and target column references from the merge expression.
    const merge_columns = try extractMergeColumns(merge_data);
    const source_column = merge_columns.source;
    const target_column = merge_columns.target;

    // Create temporary merged table with the two-way LEFT JOIN union.
    var column_mapping = ColumnMapping{};
    const create_table_stmt = try createMergedTableStatement(
        coord,
        "zetasqlite_merged_table",
        source_table,
        target_table,
        source_scan_data,
        target_scan_data,
        merge_expr,
        &column_mapping,
        ctx,
    );

    // Go: "failed to lookup merged source column name"
    const merged_source_column_name = column_mapping.lookupName(source_column) orelse
        return error.ValidationFailed;
    // Go: "failed to lookup merged target column name"
    const merged_target_column_name = column_mapping.lookupName(target_column) orelse
        return error.ValidationFailed;

    // The join key's name in the source scan's own scope. The merged table
    // aliases exactly this expression as `merged_source_<key>`, so it is what
    // correlates an INSERT's source row back to the snapshot.
    const source_key_ref = try alloc.create(types_data.ColumnRefData);
    source_key_ref.* = .{ .column_id = source_column.id };
    const source_key_sql = try (try coord.transformExpression(
        .{ .type = .column, .column = source_key_ref },
        ctx,
    )).toString(alloc);

    // Build the list of SQL statements.
    var statements: std.ArrayList([]const u8) = .empty;

    // 1. Create temporary merged table.
    try statements.append(alloc, try create_table_stmt.toString(alloc));

    // 2. Conditional statements per WHEN clause.
    for (merge_data.when_clauses) |when_clause| {
        const stmt = try transformWhenClause(
            coord,
            when_clause,
            merge_data.target_table,
            target_column.name,
            source_table,
            source_key_sql,
            merged_source_column_name,
            merged_target_column_name,
            &column_mapping,
            ctx,
        );
        if (stmt.len > 0) try statements.append(alloc, stmt);
    }

    // 3. Drop temporary table.
    try statements.append(alloc, "DROP TABLE zetasqlite_merged_table");

    const compound = try sqlbuilder.newCompoundSQLFragment(
        alloc,
        try statements.toOwnedSlice(alloc),
    );
    return .{ .compound = compound };
}

/// Go validateMergeExpression: only `zetasqlite_equal(col, col)` supported.
fn validateMergeExpression(merge_expr: ExpressionData) Error!void {
    // Go: "merge expression must be a function call"
    if (merge_expr.type != .function) return error.UnsupportedNode;
    const function = merge_expr.function orelse return error.UnsupportedNode;

    // Go: "currently MERGE expression is supported equal expression only"
    if (!std.mem.eql(u8, function.name, "zetasqlite_equal")) return error.UnsupportedNode;

    // Go: "unexpected MERGE expression column num ..."
    if (function.arguments.len != 2) return error.UnsupportedNode;

    // Go: "unexpected MERGE expression. expected column reference ..."
    for (function.arguments) |arg| {
        if (arg.type != .column) return error.UnsupportedNode;
    }
}

const MergeColumns = struct {
    source: *ColumnData,
    target: *ColumnData,
};

/// Go extractMergeColumns: determine which side of the equality belongs to
/// the target table and which to the source.
fn extractMergeColumns(merge_data: *const types_data.MergeData) Error!MergeColumns {
    const function = merge_data.merge_expr.function orelse return error.UnsupportedNode;
    if (function.arguments.len != 2) return error.UnsupportedNode;

    const col_a = function.arguments[0];
    const col_b = function.arguments[1];
    const target_scan = merge_data.target_scan orelse return error.UnsupportedNode;
    const source_scan = merge_data.source_scan orelse return error.UnsupportedNode;

    if (col_a.type == .column) {
        if (col_a.column) |a| {
            if (std.mem.eql(u8, a.table_name, merge_data.target_table)) {
                const b = col_b.column orelse return error.UnsupportedNode;
                const source = source_scan.findColumnByID(b.column_id) orelse
                    return error.ValidationFailed;
                const target = target_scan.findColumnByID(a.column_id) orelse
                    return error.ValidationFailed;
                return .{ .source = source, .target = target };
            }
        }
    }

    if (col_b.type == .column) {
        if (col_b.column) |b| {
            if (std.mem.eql(u8, b.table_name, merge_data.target_table)) {
                const a = col_a.column orelse return error.UnsupportedNode;
                const source = source_scan.findColumnByID(a.column_id) orelse
                    return error.ValidationFailed;
                const target = target_scan.findColumnByID(b.column_id) orelse
                    return error.ValidationFailed;
                return .{ .source = source, .target = target };
            }
        }
    }

    // Go: "could not determine source and target columns"
    return error.ValidationFailed;
}

/// Go transformWhenClause.
fn transformWhenClause(
    coord: *coordinator.QueryCoordinator,
    when_clause: *const types_data.MergeWhenClauseData,
    target_table_name: []const u8,
    target_column_name: []const u8,
    source_table: *sqlbuilder.FromItem,
    source_key_sql: []const u8,
    merged_source_column_name: []const u8,
    merged_target_column_name: []const u8,
    column_mapping: *const ColumnMapping,
    ctx: *context.TransformContext,
) Error![]const u8 {
    const alloc = coord.alloc;

    // FROM-filter for this match type. Each branch has to correlate the merged
    // row back to the target row being acted on: an uncorrelated predicate is a
    // property of the merged table as a whole, so it holds for every target row
    // as soon as it holds for one of them.
    const from_filter = switch (when_clause.match_type) {
        // Both target and source table have matching records.
        .MATCHED => try sqlbuilder.newBinaryExpression(
            alloc,
            try sqlbuilder.newBinaryExpression(
                alloc,
                try sqlbuilder.newColumnExpression(alloc, merged_source_column_name, null),
                "=",
                try sqlbuilder.newColumnExpression(alloc, target_column_name, null),
            ),
            "AND",
            try sqlbuilder.newBinaryExpression(
                alloc,
                try sqlbuilder.newColumnExpression(alloc, merged_target_column_name, null),
                "=",
                try sqlbuilder.newColumnExpression(alloc, target_column_name, null),
            ),
        ),
        // Target table has a record but the source table doesn't. `IS` rather
        // than `=` on the key so that a target row whose key is NULL — which
        // can never satisfy the ON condition, and so is always unmatched — is
        // still selected.
        .NOT_MATCHED_BY_SOURCE => try sqlbuilder.newBinaryExpression(
            alloc,
            try sqlbuilder.newBinaryExpression(
                alloc,
                try sqlbuilder.newColumnExpression(alloc, merged_target_column_name, null),
                "IS",
                try sqlbuilder.newColumnExpression(alloc, target_column_name, null),
            ),
            "AND",
            try sqlbuilder.newBinaryExpression(
                alloc,
                try sqlbuilder.newColumnExpression(alloc, merged_source_column_name, null),
                "IS",
                try sqlbuilder.newLiteralExpression(alloc, "NULL"),
            ),
        ),
        // Source table has a record but the target table doesn't. Only INSERT
        // is legal here, and it filters source rows rather than target rows, so
        // this filter is unused — it stays for the match-type validation below.
        .NOT_MATCHED_BY_TARGET => try sqlbuilder.newBinaryExpression(
            alloc,
            try sqlbuilder.newBinaryExpression(
                alloc,
                try sqlbuilder.newColumnExpression(alloc, merged_target_column_name, null),
                "IS",
                try sqlbuilder.newLiteralExpression(alloc, "NULL"),
            ),
            "AND",
            try sqlbuilder.newBinaryExpression(
                alloc,
                try sqlbuilder.newColumnExpression(alloc, merged_source_column_name, null),
                "IS NOT",
                try sqlbuilder.newLiteralExpression(alloc, "NULL"),
            ),
        ),
        // Go: "unsupported match type: %v"
        else => return error.UnsupportedNode,
    };

    // `WHEN <match_type> AND <search_condition>`: the resolved AST hangs the
    // extra predicate off the WHEN clause rather than folding it into the ON
    // expression, so each lowered statement has to re-apply it itself.
    const condition_sql: ?[]const u8 = if (when_clause.condition) |cond|
        try (try coord.transformExpression(cond.*, ctx)).toString(alloc)
    else
        null;

    switch (when_clause.action_type) {
        .INSERT => return transformInsertAction(
            coord,
            when_clause,
            target_table_name,
            source_table,
            source_key_sql,
            merged_source_column_name,
            merged_target_column_name,
            condition_sql,
            ctx,
        ),
        .UPDATE => {
            var where_sql = try from_filter.toString(alloc);
            if (condition_sql) |cond| {
                where_sql = try std.fmt.allocPrint(alloc, "{s} AND ({s})", .{
                    where_sql,
                    try remapToMergedColumns(coord, cond, column_mapping, ctx),
                });
            }
            return transformUpdateAction(
                coord,
                when_clause,
                target_table_name,
                where_sql,
                column_mapping,
                ctx,
            );
        },
        .DELETE => {
            // WHERE clause with existence check over the merged table.
            const subq = try sqlbuilder.newSelectStatement(alloc);
            const subq_from = try alloc.create(sqlbuilder.FromItem);
            subq_from.* = .{ .type = .table, .table_name = "zetasqlite_merged_table" };
            subq.from_clause = subq_from;
            const subq_list = try alloc.alloc(*sqlbuilder.SelectListItem, 2);
            subq_list[0] = try create(alloc, sqlbuilder.SelectListItem{
                .expression = try sqlbuilder.newColumnExpression(
                    alloc,
                    merged_source_column_name,
                    null,
                ),
            });
            subq_list[1] = try create(alloc, sqlbuilder.SelectListItem{
                .expression = try sqlbuilder.newColumnExpression(
                    alloc,
                    merged_target_column_name,
                    null,
                ),
            });
            subq.select_list = subq_list;
            subq.where_clause = from_filter;
            if (condition_sql) |cond| {
                subq.where_clause = try sqlbuilder.newBinaryExpression(
                    alloc,
                    from_filter,
                    "AND",
                    try sqlbuilder.newLiteralExpression(alloc, try std.fmt.allocPrint(alloc, "({s})", .{
                        try remapToMergedColumns(coord, cond, column_mapping, ctx),
                    })),
                );
            }

            const target_from = try alloc.create(sqlbuilder.FromItem);
            target_from.* = .{ .type = .table, .table_name = target_table_name };
            const delete_stmt = try create(alloc, sqlbuilder.DeleteStatement{
                .table = .{ .from_item = target_from },
                .where_expr = .{ .expression = try sqlbuilder.newExistsExpression(alloc, subq) },
            });
            return delete_stmt.toString(alloc);
        },
        // Go: "unsupported action type: %v"
        else => return error.UnsupportedNode,
    }
}

/// Rewrites source- and target-scan column references into the merged table's
/// column names, so an expression written against `T`/`S` can be evaluated on a
/// row of `zetasqlite_merged_table`. Go does this inline for UPDATE's SET items
/// only; the WHEN search condition needs the same treatment.
fn remapToMergedColumns(
    coord: *coordinator.QueryCoordinator,
    sql: []const u8,
    column_mapping: *const ColumnMapping,
    ctx: *context.TransformContext,
) Error![]const u8 {
    const alloc = coord.alloc;
    var out = sql;
    var it = column_mapping.all_column_map.iterator();
    while (it.next()) |entry| {
        const column = entry.key_ptr.*;
        const mapped = entry.value_ptr.*;
        const ref = try alloc.create(types_data.ColumnRefData);
        ref.* = .{ .column_id = column.id };
        const expr = try coord.transformExpression(.{ .type = .column, .column = ref }, ctx);
        const needle = try expr.toString(alloc);
        const replacement = try std.fmt.allocPrint(alloc, "`{s}`", .{mapped});
        out = try replaceAll(alloc, out, needle, replacement);
    }
    return out;
}

/// Go transformInsertAction: INSERT INTO target (cols) SELECT values FROM source.
fn transformInsertAction(
    coord: *coordinator.QueryCoordinator,
    when_clause: *const types_data.MergeWhenClauseData,
    target_table_name: []const u8,
    source_table: *sqlbuilder.FromItem,
    source_key_sql: []const u8,
    merged_source_column_name: []const u8,
    merged_target_column_name: []const u8,
    condition_sql: ?[]const u8,
    ctx: *context.TransformContext,
) Error![]const u8 {
    const alloc = coord.alloc;

    var columns: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const u8) = .empty;
    for (when_clause.insert_columns, 0..) |col, i| {
        try columns.append(alloc, try std.fmt.allocPrint(alloc, "`{s}`", .{col.name}));
        // Transform INSERT values.
        if (i >= when_clause.insert_values.len) return error.ValidationFailed;
        const value_expr = try coord.transformExpression(when_clause.insert_values[i], ctx);
        value_expr.alias = col.name;
        try values.append(alloc, try value_expr.toString(alloc));
    }

    // INSERT is only reachable under NOT MATCHED BY TARGET, so a source row
    // that already has a match in the target must be skipped — without this the
    // statement copies the whole source across and an upsert duplicates every
    // matched row. The test reads the merged table rather than the target so
    // that a preceding WHEN clause which has already written to the target
    // cannot change the answer: MERGE decides against the pre-MERGE snapshot.
    var predicates: std.ArrayList([]const u8) = .empty;
    try predicates.append(alloc, try std.fmt.allocPrint(
        alloc,
        "NOT EXISTS (SELECT 1 FROM zetasqlite_merged_table WHERE `{s}` = {s} AND `{s}` IS NOT NULL)",
        .{ merged_source_column_name, source_key_sql, merged_target_column_name },
    ));
    // The search condition is evaluated in the source scan's own scope here, so
    // unlike UPDATE/DELETE it needs no remapping onto the merged table.
    if (condition_sql) |cond| {
        try predicates.append(alloc, try std.fmt.allocPrint(alloc, "({s})", .{cond}));
    }

    return std.fmt.allocPrint(alloc, "INSERT INTO `{s}` ({s}) SELECT {s} FROM {s} WHERE {s}", .{
        target_table_name,
        try joinStrings(alloc, columns.items, ","),
        try joinStrings(alloc, values.items, ","),
        try source_table.toString(alloc),
        try joinStrings(alloc, predicates.items, " AND "),
    });
}

/// Go transformUpdateAction: UPDATE target SET ... FROM zetasqlite_merged_table WHERE filter.
fn transformUpdateAction(
    coord: *coordinator.QueryCoordinator,
    when_clause: *const types_data.MergeWhenClauseData,
    target_table_name: []const u8,
    where_stmt: []const u8,
    column_mapping: *const ColumnMapping,
    ctx: *context.TransformContext,
) Error![]const u8 {
    const alloc = coord.alloc;

    var set_items: std.ArrayList([]const u8) = .empty;
    for (when_clause.set_items) |item| {
        const value_expr = try coord.transformExpression(item.value, ctx);

        // Replace column references with mapped names from the temp table.
        const value_string = try remapToMergedColumns(
            coord,
            try value_expr.toString(alloc),
            column_mapping,
            ctx,
        );

        try set_items.append(alloc, try std.fmt.allocPrint(alloc, "`{s}`= {s}", .{
            item.column,
            value_string,
        }));
    }

    return std.fmt.allocPrint(alloc, "UPDATE `{s}` SET {s} FROM zetasqlite_merged_table WHERE {s}", .{
        target_table_name,
        try joinStrings(alloc, set_items.items, ","),
        where_stmt,
    });
}

/// Go createMergedTableStatement: CREATE TABLE <name> AS SELECT DISTINCT *
/// FROM (source LEFT JOIN target UNION ALL target LEFT JOIN source) with the
/// column mapping applied to both select lists.
fn createMergedTableStatement(
    coord: *coordinator.QueryCoordinator,
    table_name: []const u8,
    source_table: *sqlbuilder.FromItem,
    target_table: *sqlbuilder.FromItem,
    source_table_data: *const types_data.ScanData,
    target_table_data: *const types_data.ScanData,
    join_condition: *sqlbuilder.SQLExpression,
    column_mapping: *ColumnMapping,
    ctx: *context.TransformContext,
) Error!*sqlbuilder.CreateTableStatement {
    const alloc = coord.alloc;

    // Distinct column mappings.
    try createColumnMapping(
        alloc,
        source_table_data.column_list,
        target_table_data.column_list,
        column_mapping,
    );

    // source LEFT JOIN target.
    const left_join = try createJoinWithColumnMapping(coord, try create(alloc, sqlbuilder.FromItem{
        .type = .join,
        .join = try create(alloc, sqlbuilder.JoinClause{
            .type = .left,
            .left = source_table,
            .right = target_table,
            .condition = join_condition,
        }),
    }), column_mapping, ctx);

    // target LEFT JOIN source.
    const right_join = try createJoinWithColumnMapping(coord, try create(alloc, sqlbuilder.FromItem{
        .type = .join,
        .join = try create(alloc, sqlbuilder.JoinClause{
            .type = .left,
            .left = target_table,
            .right = source_table,
            .condition = join_condition,
        }),
    }), column_mapping, ctx);

    // UNION ALL of the two joins.
    const union_items = try alloc.alloc(*sqlbuilder.SelectStatement, 2);
    union_items[0] = left_join;
    union_items[1] = right_join;
    const union_operation = try create(alloc, sqlbuilder.SetOperation{
        .type = "UNION",
        .modifier = "ALL",
        .items = union_items,
    });
    const union_statement = try sqlbuilder.newSelectStatement(alloc);
    union_statement.set_operation = union_operation;

    // SELECT DISTINCT * over the union.
    const distinct_list = try alloc.alloc(*sqlbuilder.SelectListItem, 1);
    distinct_list[0] = try create(alloc, sqlbuilder.SelectListItem{
        .expression = try sqlbuilder.newStarExpression(alloc, null),
    });
    const distinct_query = try create(alloc, sqlbuilder.SelectStatement{
        .select_type = .distinct,
        .select_list = distinct_list,
        .from_clause = try sqlbuilder.newSubqueryFromItem(alloc, union_statement, "merged_union"),
    });

    return create(alloc, sqlbuilder.CreateTableStatement{
        .table_name = table_name,
        .as_select = distinct_query,
    });
}

/// Go createColumnMapping: merged_source_<name>/merged_target_<name>, with
/// numeric suffixes for uniqueness.
fn createColumnMapping(
    alloc: std.mem.Allocator,
    source_columns: []const *ColumnData,
    target_columns: []const *ColumnData,
    mapping: *ColumnMapping,
) Error!void {
    var used_names: std.StringHashMapUnmanaged(void) = .empty;

    for (source_columns) |col| {
        const name = try uniqueName(alloc, &used_names, "merged_source_", col.name);
        try mapping.source_column_map.put(alloc, col, name);
        try mapping.all_column_map.put(alloc, col, name);
    }
    for (target_columns) |col| {
        const name = try uniqueName(alloc, &used_names, "merged_target_", col.name);
        try mapping.target_column_map.put(alloc, col, name);
        try mapping.all_column_map.put(alloc, col, name);
    }
}

fn uniqueName(
    alloc: std.mem.Allocator,
    used_names: *std.StringHashMapUnmanaged(void),
    prefix: []const u8,
    column_name: []const u8,
) Error![]const u8 {
    const original = try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, column_name });
    var name = original;
    var counter: usize = 1;
    while (used_names.contains(name)) : (counter += 1) {
        name = try std.fmt.allocPrint(alloc, "{s}_{d}", .{ original, counter });
    }
    try used_names.put(alloc, name, {});
    return name;
}

/// Go createJoinWithColumnMapping: SELECT with an explicit mapped column list
/// over the join.
fn createJoinWithColumnMapping(
    coord: *coordinator.QueryCoordinator,
    join_from_item: *sqlbuilder.FromItem,
    mapping: *const ColumnMapping,
    ctx: *context.TransformContext,
) Error!*sqlbuilder.SelectStatement {
    const alloc = coord.alloc;
    const stmt = try sqlbuilder.newSelectStatement(alloc);
    stmt.from_clause = join_from_item;

    var select_list: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;

    // Source columns, then target columns (Go iterates the two maps).
    const maps = [_]*const std.AutoArrayHashMapUnmanaged(*ColumnData, []const u8){
        &mapping.source_column_map,
        &mapping.target_column_map,
    };
    for (maps) |map| {
        var it = map.iterator();
        while (it.next()) |entry| {
            const col = entry.key_ptr.*;
            const new_name = entry.value_ptr.*;
            const ref = try alloc.create(types_data.ColumnRefData);
            ref.* = .{ .column_id = col.id };
            const expr = try coord.transformExpression(
                .{ .type = .column, .column = ref },
                ctx,
            );
            try select_list.append(alloc, try create(alloc, sqlbuilder.SelectListItem{
                .expression = expr,
                .alias = new_name,
            }));
        }
    }

    stmt.select_list = try select_list.toOwnedSlice(alloc);
    return stmt;
}

fn create(alloc: std.mem.Allocator, value: anytype) Error!*@TypeOf(value) {
    const ptr = try alloc.create(@TypeOf(value));
    ptr.* = value;
    return ptr;
}

fn joinStrings(
    alloc: std.mem.Allocator,
    items: []const []const u8,
    sep: []const u8,
) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (items, 0..) |item, i| {
        if (i > 0) try out.appendSlice(alloc, sep);
        try out.appendSlice(alloc, item);
    }
    return out.toOwnedSlice(alloc);
}

fn replaceAll(
    alloc: std.mem.Allocator,
    haystack: []const u8,
    needle: []const u8,
    replacement: []const u8,
) Error![]const u8 {
    if (needle.len == 0) return haystack;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < haystack.len) {
        if (i + needle.len <= haystack.len and std.mem.eql(u8, haystack[i .. i + needle.len], needle)) {
            try out.appendSlice(alloc, replacement);
            i += needle.len;
        } else {
            try out.append(alloc, haystack[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(alloc);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const driver = @import("../../driver.zig");

test "MERGE not-matched INSERT populates target from source" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(id INT64, name STRING);
        \\CREATE TEMP TABLE source(id INT64, name STRING);
        \\INSERT INTO source(id, name) VALUES (1, "test");
        \\MERGE target T USING source S ON T.id = S.id
        \\WHEN MATCHED THEN UPDATE SET id = S.id, name = S.name
        \\WHEN NOT MATCHED THEN INSERT (id, name) VALUES (id, name);
        \\SELECT * FROM target;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqualStrings("test", row[1].string);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "MERGE matched DELETE removes matching rows" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(id INT64, name STRING);
        \\CREATE TEMP TABLE source(id INT64, name STRING);
        \\INSERT INTO target(id, name) VALUES (1, "test");
        \\INSERT INTO target(id, name) VALUES (2, "test2");
        \\INSERT INTO source(id, name) VALUES (1, "test");
        \\MERGE target T USING (SELECT * FROM source) S ON T.id = S.id
        \\WHEN MATCHED THEN DELETE;
        \\SELECT * FROM target;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 2 }, row[0]);
    try testing.expectEqualStrings("test2", row[1].string);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "MERGE with empty source leaves target empty" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(id INT64, name STRING);
        \\CREATE TEMP TABLE source(id INT64, name STRING);
        \\MERGE target T USING source S ON T.id = S.id
        \\WHEN MATCHED THEN UPDATE SET id = S.id, name = S.name
        \\WHEN NOT MATCHED THEN INSERT (id, name) VALUES (id, name);
        \\SELECT * FROM target;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

// An upsert is the shape MERGE exists for, and it is the one that catches an
// unfiltered INSERT: the source row that the UPDATE just handled must not also
// be inserted. Verified against BigQuery (recidiviz-bigquery-sandbox).
test "MERGE upsert does not re-insert the rows it just updated" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(k STRING, v INT64);
        \\CREATE TEMP TABLE source(k STRING, v INT64);
        \\INSERT INTO target(k, v) VALUES ("a", 1), ("b", 2);
        \\INSERT INTO source(k, v) VALUES ("a", 10), ("c", 30);
        \\MERGE target T USING source S ON T.k = S.k
        \\WHEN MATCHED THEN UPDATE SET v = S.v
        \\WHEN NOT MATCHED THEN INSERT (k, v) VALUES (k, v);
        \\SELECT k, v FROM target ORDER BY k;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const want = [_]struct { k: []const u8, v: i64 }{
        .{ .k = "a", .v = 10 },
        .{ .k = "b", .v = 2 },
        .{ .k = "c", .v = 30 },
    };
    for (want) |w| {
        const row = (try rows.next()).?;
        try testing.expectEqualStrings(w.k, row[0].string);
        try testing.expectEqual(driver.Cell{ .int = w.v }, row[1]);
    }
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

// NOT MATCHED BY SOURCE picks out target rows with no source match. Its filter
// has to name the target row; an uncorrelated one rewrites the whole table the
// moment a single orphan exists.
test "MERGE NOT MATCHED BY SOURCE touches only the unmatched target rows" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(k INT64, status STRING);
        \\CREATE TEMP TABLE source(k INT64);
        \\INSERT INTO target(k, status) VALUES (1, "A"), (2, "A"), (3, "A");
        \\INSERT INTO source(k) VALUES (1), (2);
        \\MERGE target T USING source S ON T.k = S.k
        \\WHEN NOT MATCHED BY SOURCE THEN UPDATE SET status = "ORPHAN";
        \\SELECT k, status FROM target ORDER BY k;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const want = [_]struct { k: i64, status: []const u8 }{
        .{ .k = 1, .status = "A" },
        .{ .k = 2, .status = "A" },
        .{ .k = 3, .status = "ORPHAN" },
    };
    for (want) |w| {
        const row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = w.k }, row[0]);
        try testing.expectEqualStrings(w.status, row[1].string);
    }
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

// The per-WHEN `AND <search_condition>` narrows the match, once per action
// kind: UPDATE and DELETE evaluate it on a merged-table row (so its column
// references need remapping), INSERT on a source row (so they do not).
test "MERGE WHEN search conditions narrow each action" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(k INT64, v INT64);
        \\CREATE TEMP TABLE source(k INT64, w INT64);
        \\INSERT INTO target(k, v) VALUES (1, 10), (2, 20), (3, 30);
        \\INSERT INTO source(k, w) VALUES (1, 100), (2, 5), (4, 999);
        \\MERGE target T USING source S ON T.k = S.k
        \\WHEN MATCHED AND S.w > 50 THEN UPDATE SET v = S.w
        \\WHEN NOT MATCHED BY TARGET AND S.w > 500 THEN INSERT (k, v) VALUES (k, w)
        \\WHEN NOT MATCHED BY SOURCE AND T.v > 25 THEN DELETE;
        \\SELECT k, v FROM target ORDER BY k;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    // k=1 matched and w>50 so it updates; k=2 matched but w=5 so it does not;
    // k=3 is unmatched by source with v=30>25 so it is deleted; k=4 is
    // unmatched by target with w=999>500 so it is inserted.
    const want = [_][2]i64{ .{ 1, 100 }, .{ 2, 20 }, .{ 4, 999 } };
    for (want) |w| {
        const row = (try rows.next()).?;
        try testing.expectEqual(driver.Cell{ .int = w[0] }, row[0]);
        try testing.expectEqual(driver.Cell{ .int = w[1] }, row[1]);
    }
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

// A NULL key satisfies no ON condition, so such a target row is always
// unmatched by source. That is why the filter compares with `IS`, not `=`.
test "MERGE NOT MATCHED BY SOURCE reaches a NULL-keyed target row" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(k INT64, status STRING);
        \\CREATE TEMP TABLE source(k INT64);
        \\INSERT INTO target(k, status) VALUES (1, "A"), (NULL, "A");
        \\INSERT INTO source(k) VALUES (1);
        \\MERGE target T USING source S ON T.k = S.k
        \\WHEN NOT MATCHED BY SOURCE THEN UPDATE SET status = "ORPHAN";
        \\SELECT status FROM target ORDER BY k NULLS LAST;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    try testing.expectEqualStrings("A", (try rows.next()).?[0].string);
    try testing.expectEqualStrings("ORPHAN", (try rows.next()).?[0].string);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "MERGE INSERT ROW without column list" {
    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    var rows = try db.query(
        \\CREATE TEMP TABLE target(id INT64, name STRING);
        \\CREATE TEMP TABLE source(id INT64, name STRING);
        \\INSERT INTO source(id, name) VALUES (1, "test");
        \\MERGE target T USING (SELECT * FROM source) S ON T.id = S.id
        \\WHEN NOT MATCHED THEN INSERT ROW;
        \\SELECT * FROM target;
    ,
        &.{},
        .{},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try testing.expectEqual(driver.Cell{ .int = 1 }, row[0]);
    try testing.expectEqualStrings("test", row[1].string);
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}
