//! MERGE, lowered to plain SQLite statements the driver runs in order:
//!   1. `CREATE TABLE zigquery_merged_table`, the pre-MERGE snapshot:
//!      `SELECT DISTINCT over (source LEFT JOIN target UNION ALL target LEFT JOIN source)`,
//!      with columns renamed merged_source_* / merged_target_*, the target's row id,
//!      and the WHEN clause each target row is assigned,
//!   2. one INSERT / UPDATE ... FROM / DELETE per WHEN clause, acting only on its own rows,
//!   3. DROP TABLE zigquery_merged_table.
//!
//! Only the first qualifying WHEN clause runs for a row
//! (data-manipulation-language.md#merge_statement).
//! A clause's writes never change which rows a later clause acts on.
// ephor:ignore-file ZA301 ZA302 ZA303

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");

const Error = types_data.Error;
const ColumnData = types_data.ColumnData;
const ExpressionData = types_data.ExpressionData;
const MergeWhenClauseData = types_data.MergeWhenClauseData;

const merged_table = "zigquery_merged_table";
/// The target row's SQLite row id; NULL on a source row with no match.
const target_rowid_column = "zigquery_merge_target_rowid";
/// Index into the WHEN clauses of the clause that acts on a target row; NULL for none.
const clause_column = "zigquery_merge_clause";

/// Original column -> merged-table column name, one map per side. Array maps, so iteration order
/// is the insertion order and the generated SQL is the same on every run.
const ColumnMapping = struct {
    source_column_map: std.AutoArrayHashMapUnmanaged(*ColumnData, []const u8) = .empty,
    target_column_map: std.AutoArrayHashMapUnmanaged(*ColumnData, []const u8) = .empty,
    all_column_map: std.AutoArrayHashMapUnmanaged(*ColumnData, []const u8) = .empty,

    fn lookupName(self: *const ColumnMapping, column: *ColumnData) ?[]const u8 {
        return self.all_column_map.get(column);
    }
};

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.StatementData,
    ctx: *context.TransformContext,
) Error!sqlbuilder.SQLFragment {
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
    const source_column = (try extractMergeColumns(merge_data)).source;

    // The target subquery carries its row id into the snapshot.
    const target_rowid = try targetRowidName(target_scan_data.column_list);
    const target_query = target_table.subquery orelse return error.UnsupportedNode;
    target_query.select_list = try appendSelectItem(
        alloc,
        target_query.select_list,
        try sqlbuilder.newColumnExpression(alloc, target_rowid, null),
        target_rowid_column,
    );

    var column_mapping = ColumnMapping{};
    const create_table_stmt = try createMergedTableStatement(
        coord,
        merged_table,
        source_table,
        target_table,
        source_scan_data,
        target_scan_data,
        merge_expr,
        &column_mapping,
        ctx,
    );
    const merged_source_key = column_mapping.lookupName(source_column) orelse
        return error.ValidationFailed;

    // The join key's name in the source scan's own scope. The merged table aliases exactly this
    // expression as `merged_source_<key>`, so it is what correlates an INSERT's source row back to
    // the snapshot.
    const source_key_ref = try alloc.create(types_data.ColumnRefData);
    source_key_ref.* = .{ .column_id = source_column.id };
    const source_key_sql = try (try coord.transformExpression(
        .{ .type = .column, .column = source_key_ref },
        ctx,
    )).toString(alloc);

    var lowering = Lowering{
        .coord = coord,
        .ctx = ctx,
        .when_clauses = merge_data.when_clauses,
        .target_table_name = merge_data.target_table,
        .target_rowid = target_rowid,
        .source_table = source_table,
        .source_key_sql = source_key_sql,
        .merged_source_key = merged_source_key,
        .column_mapping = &column_mapping,
    };
    lowering.insert_clause_case = try clauseCase(lowering, .source);

    const snapshot = create_table_stmt.as_select orelse return error.UnsupportedNode;
    snapshot.select_list = try appendSelectItem(
        alloc,
        snapshot.select_list,
        try sqlbuilder.newLiteralExpression(alloc, try clauseCase(lowering, .snapshot)),
        clause_column,
    );

    var statements: std.ArrayList(sqlbuilder.SQLFragment) = .empty;
    try statements.append(alloc, .{ .create_table_statement = create_table_stmt });
    if (try sourceKeyIndex(alloc, merge_data.when_clauses, merged_source_key)) |index| {
        try statements.append(alloc, .{ .create_index_statement = index });
    }
    for (merge_data.when_clauses, 0..) |when_clause, i| {
        try statements.append(alloc, try transformWhenClause(lowering, @intCast(i), when_clause));
    }
    try statements.append(alloc, .{ .drop_statement = try create(alloc, sqlbuilder.DropStatement{
        .object_type = "TABLE",
        .object_name = merged_table,
    }) });

    const compound = try sqlbuilder.newCompoundSQLFragment(
        alloc,
        try statements.toOwnedSlice(alloc),
    );
    return .{ .compound = compound };
}

/// The ON condition must be `zigquery_equal(col, col)`; anything else is unsupported.
fn validateMergeExpression(merge_expr: ExpressionData) Error!void {
    if (merge_expr.type != .function) return error.UnsupportedNode;
    const function = merge_expr.function orelse return error.UnsupportedNode;

    if (!std.mem.eql(u8, function.name, "zigquery_equal")) return error.UnsupportedNode;

    if (function.arguments.len != 2) return error.UnsupportedNode;

    for (function.arguments) |arg| {
        if (arg.type != .column) return error.UnsupportedNode;
    }
}

const MergeColumns = struct {
    source: *ColumnData,
    target: *ColumnData,
};

/// Which side of the ON equality is the target column and which the source.
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

    return error.ValidationFailed;
}

/// What every lowered WHEN clause needs.
const Lowering = struct {
    coord: *coordinator.QueryCoordinator,
    ctx: *context.TransformContext,
    when_clauses: []const *MergeWhenClauseData,
    target_table_name: []const u8,
    /// SQLite's name for the target's row id (targetRowidName).
    target_rowid: []const u8,
    source_table: *sqlbuilder.FromItem,
    /// The join key in the source scan's own scope.
    source_key_sql: []const u8,
    /// The join key's source column in the snapshot.
    merged_source_key: []const u8,
    column_mapping: *const ColumnMapping,
    /// clauseCase(.source): the INSERT clause each source row is assigned.
    insert_clause_case: []const u8 = "",
};

/// The rows a clause CASE is evaluated on: snapshot rows for the clauses that act on target rows,
/// source rows for the INSERT clauses.
const ClauseScope = enum { snapshot, source };

/// A CASE naming the first WHEN clause that qualifies a row, in WHEN order, or NULL when no clause
/// is evaluated in `scope`. CASE takes the first true branch, and a NULL search condition is not
/// true (data-manipulation-language.md#merge_statement).
fn clauseCase(lowering: Lowering, scope: ClauseScope) Error![]const u8 {
    const alloc = lowering.coord.alloc;
    var arms: std.ArrayList(u8) = .empty;
    for (lowering.when_clauses, 0..) |when_clause, i| {
        const match = try matchPredicate(lowering, when_clause, scope) orelse continue;
        const condition = if (when_clause.condition) |c|
            try conditionSql(lowering, c, scope)
        else
            "TRUE";
        try arms.print(alloc, " WHEN {s} AND ({s}) THEN {d}", .{ match, condition, i });
    }
    if (arms.items.len == 0) return "NULL";
    return std.fmt.allocPrint(alloc, "CASE{s} END", .{arms.items});
}

/// A WHEN clause's search condition, over snapshot columns or the source scan's own.
fn conditionSql(
    lowering: Lowering,
    condition: *const ExpressionData,
    scope: ClauseScope,
) Error![]const u8 {
    const expr = try lowering.coord.transformExpression(condition.*, lowering.ctx);
    const sql = try expr.toString(lowering.coord.alloc);
    return switch (scope) {
        .snapshot => remapToMergedColumns(
            lowering.coord,
            sql,
            lowering.column_mapping,
            lowering.ctx,
        ),
        .source => sql,
    };
}

/// The row test for a clause's match type, or null when the clause is not evaluated in `scope`.
/// A matched pair always has a non-NULL key: `zigquery_equal` is NULL when either side is.
fn matchPredicate(
    lowering: Lowering,
    when_clause: *const MergeWhenClauseData,
    scope: ClauseScope,
) Error!?[]const u8 {
    const alloc = lowering.coord.alloc;
    const on_target = scope == .snapshot;
    return switch (when_clause.match_type) {
        .MATCHED => if (on_target) try std.fmt.allocPrint(
            alloc,
            "`{s}` IS NOT NULL AND `{s}` IS NOT NULL",
            .{ target_rowid_column, lowering.merged_source_key },
        ) else null,
        .NOT_MATCHED_BY_SOURCE => if (on_target) try std.fmt.allocPrint(
            alloc,
            "`{s}` IS NOT NULL AND `{s}` IS NULL",
            .{ target_rowid_column, lowering.merged_source_key },
        ) else null,
        .NOT_MATCHED_BY_TARGET => if (on_target) null else "TRUE",
        else => error.UnsupportedNode,
    };
}

/// The statement for WHEN clause `index`, acting only on the rows assigned to it.
fn transformWhenClause(
    lowering: Lowering,
    index: u32,
    when_clause: *const MergeWhenClauseData,
) Error!sqlbuilder.SQLFragment {
    const inserts = when_clause.match_type == .NOT_MATCHED_BY_TARGET;
    switch (when_clause.action_type) {
        .INSERT => {
            if (!inserts) return error.UnsupportedNode;
            return .{ .insert_statement = try transformInsertAction(lowering, index, when_clause) };
        },
        .UPDATE => {
            if (inserts) return error.UnsupportedNode;
            return .{ .update_statement = try transformUpdateAction(lowering, index, when_clause) };
        },
        .DELETE => {
            if (inserts) return error.UnsupportedNode;
            return .{ .delete_statement = try transformDeleteAction(lowering, index) };
        },
        else => return error.UnsupportedNode,
    }
}

/// CREATE INDEX on the snapshot's source key, for an INSERT clause's per-source-row lookup of it;
/// null when no clause inserts.
fn sourceKeyIndex(
    alloc: std.mem.Allocator,
    when_clauses: []const *MergeWhenClauseData,
    merged_source_key: []const u8,
) Error!?*sqlbuilder.CreateIndexStatement {
    for (when_clauses) |when_clause| {
        if (when_clause.match_type != .NOT_MATCHED_BY_TARGET) continue;
        const columns = try alloc.alloc([]const u8, 1);
        columns[0] = merged_source_key;
        return try create(alloc, sqlbuilder.CreateIndexStatement{
            .index_name = merged_table ++ "_source_key",
            .table_name = merged_table,
            .columns = columns,
        });
    }
    return null;
}

/// SQLite's name for a target row's id: the first of its aliases no target column shadows.
fn targetRowidName(columns: []const *ColumnData) Error![]const u8 {
    for ([_][]const u8{ "rowid", "_rowid_", "oid" }) |name| {
        for (columns) |column| {
            if (std.ascii.eqlIgnoreCase(column.name, name)) break;
        } else return name;
    }
    return error.UnsupportedNode;
}

fn appendSelectItem(
    alloc: std.mem.Allocator,
    items: []const *sqlbuilder.SelectListItem,
    expression: *sqlbuilder.SQLExpression,
    alias: []const u8,
) Error![]const *sqlbuilder.SelectListItem {
    const out = try alloc.alloc(*sqlbuilder.SelectListItem, items.len + 1);
    @memcpy(out[0..items.len], items);
    out[items.len] = try create(alloc, sqlbuilder.SelectListItem{
        .expression = expression,
        .alias = alias,
    });
    return out;
}

/// Rewrites source- and target-scan column references into the merged table's
/// column names, so an expression written against `T`/`S` can be evaluated on a
/// row of `zigquery_merged_table`.
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

/// INSERT INTO target (cols) SELECT values FROM source, for the source rows assigned to clause
/// `index`.
fn transformInsertAction(
    lowering: Lowering,
    index: u32,
    when_clause: *const MergeWhenClauseData,
) Error!*sqlbuilder.InsertStatement {
    const alloc = lowering.coord.alloc;

    const columns = try alloc.alloc([]const u8, when_clause.insert_columns.len);
    const values = try alloc.alloc(*sqlbuilder.SelectListItem, when_clause.insert_columns.len);
    for (when_clause.insert_columns, columns, values, 0..) |col, *column, *value, i| {
        column.* = try std.fmt.allocPrint(alloc, "`{s}`", .{col.name});
        if (i >= when_clause.insert_values.len) return error.ValidationFailed;
        const value_data = when_clause.insert_values[i];
        value.* = try create(alloc, sqlbuilder.SelectListItem{
            .expression = try lowering.coord.transformExpression(value_data, lowering.ctx),
            .alias = col.name,
        });
    }

    const query = try sqlbuilder.newSelectStatement(alloc);
    query.select_list = values;
    query.from_clause = lowering.source_table;
    query.where_clause = try sqlbuilder.newBinaryExpression(
        alloc,
        try sqlbuilder.newNotExpression(alloc, try matchedInTarget(lowering)),
        "AND",
        try insertClauseIs(lowering, index),
    );

    return create(alloc, sqlbuilder.InsertStatement{
        .table_name = lowering.target_table_name,
        .columns = columns,
        .query = query,
    });
}

/// Whether the source row has a match in the target, read from the snapshot so rows an earlier
/// clause wrote cannot change the answer.
fn matchedInTarget(lowering: Lowering) Error!*sqlbuilder.SQLExpression {
    const alloc = lowering.coord.alloc;
    const matched = try sqlbuilder.newSelectStatement(alloc);
    matched.select_list = try appendSelectItem(
        alloc,
        &.{},
        try sqlbuilder.newLiteralExpression(alloc, "1"),
        "",
    );
    matched.from_clause = try tableItem(alloc, merged_table);
    matched.where_clause = try sqlbuilder.newBinaryExpression(
        alloc,
        try equals(
            alloc,
            try sqlbuilder.newColumnExpression(alloc, lowering.merged_source_key, null),
            try sqlbuilder.newLiteralExpression(alloc, lowering.source_key_sql),
        ),
        "AND",
        try sqlbuilder.newBinaryExpression(
            alloc,
            try sqlbuilder.newColumnExpression(alloc, target_rowid_column, null),
            "IS NOT",
            try sqlbuilder.newLiteralExpression(alloc, "NULL"),
        ),
    );
    return sqlbuilder.newExistsExpression(alloc, matched);
}

/// A source row assigned to INSERT clause `index`. Source rows have no row id, so the assignment
/// is evaluated on the source row itself.
fn insertClauseIs(lowering: Lowering, index: u32) Error!*sqlbuilder.SQLExpression {
    const alloc = lowering.coord.alloc;
    return equals(
        alloc,
        try sqlbuilder.newLiteralExpression(
            alloc,
            try std.fmt.allocPrint(alloc, "({s})", .{lowering.insert_clause_case}),
        ),
        try clauseNumber(alloc, index),
    );
}

/// UPDATE target SET ... FROM the snapshot, for the target rows assigned to clause `index`. The
/// merged table has a row id of its own, so the target's is qualified.
fn transformUpdateAction(
    lowering: Lowering,
    index: u32,
    when_clause: *const MergeWhenClauseData,
) Error!*sqlbuilder.UpdateStatement {
    const alloc = lowering.coord.alloc;

    const set_items = try alloc.alloc(*sqlbuilder.SetItem, when_clause.set_items.len);
    for (when_clause.set_items, set_items) |item, *set_item| {
        const value_expr = try lowering.coord.transformExpression(item.value, lowering.ctx);
        const value_sql = try remapToMergedColumns(
            lowering.coord,
            try value_expr.toString(alloc),
            lowering.column_mapping,
            lowering.ctx,
        );
        set_item.* = try create(alloc, sqlbuilder.SetItem{
            .column = try sqlbuilder.newColumnExpression(alloc, item.column, null),
            .value = try sqlbuilder.newLiteralExpression(alloc, value_sql),
        });
    }

    return create(alloc, sqlbuilder.UpdateStatement{
        .table = try tableItem(alloc, lowering.target_table_name),
        .set_items = set_items,
        .from_clause = try tableItem(alloc, merged_table),
        .where_clause = try sqlbuilder.newBinaryExpression(
            alloc,
            try equals(
                alloc,
                try sqlbuilder.newColumnExpression(
                    alloc,
                    lowering.target_rowid,
                    lowering.target_table_name,
                ),
                try sqlbuilder.newColumnExpression(alloc, target_rowid_column, null),
            ),
            "AND",
            try clauseIs(alloc, index),
        ),
    });
}

/// DELETE FROM target, for the target rows assigned to clause `index`.
fn transformDeleteAction(lowering: Lowering, index: u32) Error!*sqlbuilder.DeleteStatement {
    const alloc = lowering.coord.alloc;

    const assigned = try sqlbuilder.newSelectStatement(alloc);
    assigned.select_list = try appendSelectItem(
        alloc,
        &.{},
        try sqlbuilder.newColumnExpression(alloc, target_rowid_column, null),
        "",
    );
    assigned.from_clause = try tableItem(alloc, merged_table);
    assigned.where_clause = try clauseIs(alloc, index);

    const where = try sqlbuilder.newBinaryExpression(
        alloc,
        try sqlbuilder.newColumnExpression(alloc, lowering.target_rowid, null),
        "IN",
        try create(alloc, sqlbuilder.SQLExpression{ .type = .subquery, .subquery = assigned }),
    );
    return create(alloc, sqlbuilder.DeleteStatement{
        .table = .{ .from_item = try tableItem(alloc, lowering.target_table_name) },
        .where_expr = .{ .expression = where },
    });
}

fn tableItem(alloc: std.mem.Allocator, name: []const u8) Error!*sqlbuilder.FromItem {
    return create(alloc, sqlbuilder.FromItem{ .type = .table, .table_name = name });
}

fn equals(
    alloc: std.mem.Allocator,
    left: *sqlbuilder.SQLExpression,
    right: *sqlbuilder.SQLExpression,
) Error!*sqlbuilder.SQLExpression {
    return sqlbuilder.newBinaryExpression(alloc, left, "=", right);
}

fn clauseNumber(alloc: std.mem.Allocator, index: u32) Error!*sqlbuilder.SQLExpression {
    return sqlbuilder.newLiteralExpression(alloc, try std.fmt.allocPrint(alloc, "{d}", .{index}));
}

/// A snapshot row assigned to clause `index`.
fn clauseIs(alloc: std.mem.Allocator, index: u32) Error!*sqlbuilder.SQLExpression {
    return equals(
        alloc,
        try sqlbuilder.newColumnExpression(alloc, clause_column, null),
        try clauseNumber(alloc, index),
    );
}

/// CREATE TABLE <name> AS SELECT DISTINCT * FROM (
///     source LEFT JOIN target UNION ALL target LEFT JOIN source
/// )
/// with the column mapping applied to both select lists.
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

    // Both arms carry the target's row id, NULL on a source row with no match.
    const target_rowid = try sqlbuilder.newColumnExpression(
        alloc,
        target_rowid_column,
        if (target_table.alias.len > 0) target_table.alias else null,
    );
    for ([_]*sqlbuilder.SelectStatement{ left_join, right_join }) |arm| {
        arm.select_list = try appendSelectItem(
            alloc,
            arm.select_list,
            target_rowid,
            target_rowid_column,
        );
    }

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

/// Names the snapshot's columns merged_source_<name> and merged_target_<name>, with a numeric
/// suffix where that would collide.
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

/// A SELECT over the join, naming the mapped columns explicitly.
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

    // Source columns, then target columns.
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
        if (i + needle.len <= haystack.len and std.mem.eql(
            u8,
            haystack[i .. i + needle.len],
            needle,
        )) {
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
