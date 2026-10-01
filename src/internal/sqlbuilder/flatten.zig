//! Faithful port of go-zetasqlite internal/sqlbuilder_flatten.go.
//!
//! flattenSelectForRecursiveCTE flattens a SELECT statement to expose the
//! recursive table reference at the top level, as required by SQLite's
//! recursive CTE implementation. It collapses chains of subqueries that only
//! perform column aliasing without other operations (GROUP BY, HAVING, LIMIT,
//! ORDER BY, or SetOperations).
//!
//! All allocation uses the caller-supplied allocator (the coordinator arena).
// ephor:ignore-file ZA301 ZA302 ZA303 ZT105

const std = @import("std");
const sb = @import("sqlbuilder.zig");

const Error = sb.Error;
const SQLExpression = sb.SQLExpression;
const SelectStatement = sb.SelectStatement;
const SelectListItem = sb.SelectListItem;
const FromItem = sb.FromItem;
const JoinClause = sb.JoinClause;
const WithClause = sb.WithClause;
const BinaryExpression = sb.BinaryExpression;
const UnaryExpression = sb.UnaryExpression;
const FunctionCall = sb.FunctionCall;
const ListExpression = sb.ListExpression;
const CaseExpression = sb.CaseExpression;
const WhenClause = sb.WhenClause;
const ExistsExpression = sb.ExistsExpression;

/// Alias -> expression map used during flattening.
const AliasMap = std.StringHashMapUnmanaged(*SQLExpression);

fn create(alloc: std.mem.Allocator, value: anytype) Error!*@TypeOf(value) {
    const ptr = try alloc.create(@TypeOf(value));
    ptr.* = value;
    return ptr;
}

/// Go flattenSelectForRecursiveCTE.
pub fn flattenSelectForRecursiveCTE(
    alloc: std.mem.Allocator,
    stmt: ?*SelectStatement,
) Error!?*SelectStatement {
    const s = stmt orelse return stmt;

    // First, recursively flatten any JOINs in the FROM clause and collect
    // column mappings.
    if (s.from_clause) |from| {
        if (from.type == .join) {
            var join_alias_map: AliasMap = .empty;
            s.from_clause = try flattenJoinFromItem(alloc, from, &join_alias_map);

            if (join_alias_map.count() > 0) {
                const new_list = try alloc.alloc(*SelectListItem, s.select_list.len);
                for (s.select_list, 0..) |item, i| {
                    new_list[i] = try create(alloc, SelectListItem{
                        .expression = (try substituteColumnRefs(
                            alloc,
                            item.expression,
                            &join_alias_map,
                            "",
                        )).?,
                        .alias = item.alias,
                        .is_star_expansion = item.is_star_expansion,
                        .except_columns = item.except_columns,
                        .replace_columns = item.replace_columns,
                    });
                }
                s.select_list = new_list;
                s.where_clause = try substituteColumnRefs(
                    alloc,
                    s.where_clause,
                    &join_alias_map,
                    "",
                );

                try substituteInJoinConditions(alloc, s.from_clause, &join_alias_map);
            }
        }
    }

    // Base case: no FROM clause or it's not a subquery, nothing to flatten.
    const from_clause = s.from_clause orelse return s;
    if (from_clause.type != .subquery) return s;

    const inner_stmt = from_clause.subquery orelse return s;

    // Check if the inner statement can be flattened.
    if (!canFlattenSelect(inner_stmt)) return s;

    // Build a map of aliases to expressions from the inner SELECT list.
    var alias_map: AliasMap = .empty;
    try buildColumnAliasMap(alloc, &alias_map, inner_stmt.select_list);

    // Create the flattened statement.
    const flattened = try create(alloc, SelectStatement{
        .with_clauses = try mergeWithClauses(alloc, s.with_clauses, inner_stmt.with_clauses),
        .select_type = s.select_type,
        .from_clause = inner_stmt.from_clause,
        .group_by_list = s.group_by_list,
        .having_clause = s.having_clause,
        .order_by_list = s.order_by_list,
        .limit_clause = s.limit_clause,
    });

    // Rewrite the SELECT list: substitute column references with their
    // definitions.
    const new_select_list = try alloc.alloc(*SelectListItem, s.select_list.len);
    for (s.select_list, 0..) |item, i| {
        new_select_list[i] = try create(alloc, SelectListItem{
            .expression = (try substituteColumnRefs(
                alloc,
                item.expression,
                &alias_map,
                from_clause.alias,
            )).?,
            .alias = item.alias,
            .is_star_expansion = item.is_star_expansion,
            .except_columns = item.except_columns,
            .replace_columns = item.replace_columns,
        });
    }
    flattened.select_list = new_select_list;

    // Merge WHERE clauses from both levels.
    flattened.where_clause = try mergeWhereConditions(
        alloc,
        s.where_clause,
        inner_stmt.where_clause,
        &alias_map,
        from_clause.alias,
    );

    // Recursively flatten in case there are multiple levels of nesting.
    return flattenSelectForRecursiveCTE(alloc, flattened);
}

/// Go flattenJoinFromItem.
fn flattenJoinFromItem(
    alloc: std.mem.Allocator,
    from_item: ?*FromItem,
    alias_map: *AliasMap,
) Error!?*FromItem {
    const fi = from_item orelse return from_item;
    if (fi.type != .join) return fi;
    const join = fi.join orelse return fi;

    join.left = try flattenFromItemInJoin(alloc, join.left, alias_map);
    join.right = try flattenFromItemInJoin(alloc, join.right, alias_map);

    return fi;
}

/// Go flattenFromItemInJoin.
fn flattenFromItemInJoin(
    alloc: std.mem.Allocator,
    from_item: ?*FromItem,
    alias_map: *AliasMap,
) Error!?*FromItem {
    const fi = from_item orelse return null;

    // If this is a subquery, try to unwrap it if it's just a pass-through.
    if (fi.type == .subquery and fi.subquery != null) {
        const subquery = fi.subquery.?;
        if (canUnwrapSubquery(subquery)) {
            if (subquery.from_clause) |inner_from| {
                // Determine the final alias that will be used.
                var final_alias = fi.alias;
                if (final_alias.len == 0) {
                    final_alias = inner_from.alias;
                } else {
                    inner_from.alias = final_alias;
                }

                // Build column mappings from the subquery's SELECT list.
                for (subquery.select_list) |item| {
                    if (item.alias.len > 0) {
                        const mapped_expr = try copyExpression(alloc, item.expression);
                        updateTableAlias(mapped_expr, final_alias);
                        try alias_map.put(alloc, item.alias, mapped_expr.?);
                    }
                }

                return try flattenFromItemInJoin(alloc, inner_from, alias_map);
            }
        }
    }

    if (fi.type == .join) {
        return try flattenJoinFromItem(alloc, fi, alias_map);
    }

    return fi;
}

/// Go updateTableAlias.
fn updateTableAlias(expr: ?*SQLExpression, new_alias: []const u8) void {
    const e = expr orelse return;
    switch (e.type) {
        .column => e.table_alias = new_alias,
        .star => e.table_alias = new_alias,
        .function => {
            if (e.function_call) |fc| {
                for (fc.arguments) |arg| updateTableAlias(arg, new_alias);
            }
        },
        .binary => {
            if (e.binary_expression) |b| {
                updateTableAlias(b.left, new_alias);
                updateTableAlias(b.right, new_alias);
            }
        },
        .unary => {
            if (e.unary_expression) |u| updateTableAlias(u.expression, new_alias);
        },
        .list => {
            if (e.list_expression) |l| {
                for (l.expressions) |le| updateTableAlias(le, new_alias);
            }
        },
        .case => {
            if (e.case_expression) |c| {
                updateTableAlias(c.case_expr, new_alias);
                for (c.when_clauses) |w| {
                    updateTableAlias(w.condition, new_alias);
                    updateTableAlias(w.result, new_alias);
                }
                updateTableAlias(c.else_expr, new_alias);
            }
        },
        // Types with their own scope - don't traverse into them.
        .subquery, .exists => return,
        // Simple types with no nested expressions.
        .literal, .parameter, .cast => return,
    }
}

/// Go canUnwrapSubquery.
fn canUnwrapSubquery(stmt: ?*const SelectStatement) bool {
    const s = stmt orelse return false;

    if (s.group_by_list.len > 0 or s.having_clause != null or
        s.order_by_list.len > 0 or s.limit_clause != null or
        s.set_operation != null or s.where_clause != null) return false;

    if (s.select_list.len == 0) return false;

    for (s.select_list) |item| {
        if (item.is_star_expansion) continue;
        if (item.expression.type != .column) return false;
    }
    return true;
}

/// Go canFlattenSelect.
fn canFlattenSelect(stmt: ?*const SelectStatement) bool {
    const s = stmt orelse return false;
    return s.group_by_list.len == 0 and
        s.having_clause == null and
        s.order_by_list.len == 0 and
        s.limit_clause == null and
        s.set_operation == null;
}

/// Go mergeWithClauses: combines WITH clauses from outer and inner SELECT
/// statements, resolving name conflicts by preferring inner CTEs.
fn mergeWithClauses(
    alloc: std.mem.Allocator,
    outer_clauses: []const *WithClause,
    inner_clauses: []const *WithClause,
) Error![]const *WithClause {
    if (outer_clauses.len == 0) return inner_clauses;
    if (inner_clauses.len == 0) return outer_clauses;

    var inner_names: std.StringHashMapUnmanaged(void) = .empty;
    for (inner_clauses) |clause| try inner_names.put(alloc, clause.name, {});

    var result: std.ArrayList(*WithClause) = .empty;
    try result.appendSlice(alloc, inner_clauses);
    for (outer_clauses) |outer| {
        if (!inner_names.contains(outer.name)) try result.append(alloc, outer);
    }
    return try result.toOwnedSlice(alloc);
}

/// Go buildColumnAliasMap.
fn buildColumnAliasMap(
    alloc: std.mem.Allocator,
    map: *AliasMap,
    select_list: []const *SelectListItem,
) Error!void {
    for (select_list) |item| {
        if (item.alias.len > 0) try map.put(alloc, item.alias, item.expression);
    }
}

/// Go substituteColumnRefs.
fn substituteColumnRefs(
    alloc: std.mem.Allocator,
    expr: ?*SQLExpression,
    alias_map: *AliasMap,
    table_alias: []const u8,
) Error!?*SQLExpression {
    return substituteColumnRefsWithDepth(alloc, expr, alias_map, table_alias, 0);
}

fn substituteColumnRefsWithDepth(
    alloc: std.mem.Allocator,
    expr: ?*SQLExpression,
    alias_map: *AliasMap,
    table_alias: []const u8,
    depth: u32,
) Error!?*SQLExpression {
    const max_depth = 100;
    const e = expr orelse return null;
    if (depth > max_depth) return e;

    switch (e.type) {
        .column => {
            if (std.mem.eql(u8, e.table_alias, table_alias) or e.table_alias.len == 0) {
                if (alias_map.get(e.value)) |substitution| {
                    return try copyExpression(alloc, substitution);
                }
            }
            return e;
        },
        .function => {
            const fc = e.function_call orelse return e;
            const new_args = try alloc.alloc(*SQLExpression, fc.arguments.len);
            for (fc.arguments, 0..) |arg, i| {
                new_args[i] = (try substituteColumnRefsWithDepth(
                    alloc,
                    arg,
                    alias_map,
                    table_alias,
                    depth + 1,
                )).?;
            }
            return try create(alloc, SQLExpression{
                .type = .function,
                .function_call = try create(alloc, FunctionCall{
                    .name = fc.name,
                    .arguments = new_args,
                    .is_distinct = fc.is_distinct,
                    .window_spec = fc.window_spec,
                }),
                .collation = e.collation,
            });
        },
        .binary => {
            const b = e.binary_expression orelse return e;
            return try create(alloc, SQLExpression{
                .type = .binary,
                .binary_expression = try create(alloc, BinaryExpression{
                    .left = try substituteColumnRefsWithDepth(
                        alloc,
                        b.left,
                        alias_map,
                        table_alias,
                        depth + 1,
                    ),
                    .operator = b.operator,
                    .right = try substituteColumnRefsWithDepth(
                        alloc,
                        b.right,
                        alias_map,
                        table_alias,
                        depth + 1,
                    ),
                }),
                .collation = e.collation,
            });
        },
        .unary => {
            const u = e.unary_expression orelse return e;
            return try create(alloc, SQLExpression{
                .type = .unary,
                .unary_expression = try create(alloc, UnaryExpression{
                    .operator = u.operator,
                    .expression = (try substituteColumnRefsWithDepth(
                        alloc,
                        u.expression,
                        alias_map,
                        table_alias,
                        depth + 1,
                    )).?,
                }),
                .collation = e.collation,
            });
        },
        .list => {
            const l = e.list_expression orelse return e;
            const new_exprs = try alloc.alloc(*SQLExpression, l.expressions.len);
            for (l.expressions, 0..) |le, i| {
                new_exprs[i] = (try substituteColumnRefsWithDepth(
                    alloc,
                    le,
                    alias_map,
                    table_alias,
                    depth + 1,
                )).?;
            }
            return try create(alloc, SQLExpression{
                .type = .list,
                .list_expression = try create(alloc, ListExpression{ .expressions = new_exprs }),
                .collation = e.collation,
            });
        },
        .case => {
            const c = e.case_expression orelse return e;
            const new_when = try alloc.alloc(*WhenClause, c.when_clauses.len);
            for (c.when_clauses, 0..) |w, i| {
                new_when[i] = try create(alloc, WhenClause{
                    .condition = (try substituteColumnRefsWithDepth(
                        alloc,
                        w.condition,
                        alias_map,
                        table_alias,
                        depth + 1,
                    )).?,
                    .result = (try substituteColumnRefsWithDepth(
                        alloc,
                        w.result,
                        alias_map,
                        table_alias,
                        depth + 1,
                    )).?,
                });
            }
            return try create(alloc, SQLExpression{
                .type = .case,
                .case_expression = try create(alloc, CaseExpression{
                    .case_expr = try substituteColumnRefsWithDepth(
                        alloc,
                        c.case_expr,
                        alias_map,
                        table_alias,
                        depth + 1,
                    ),
                    .when_clauses = new_when,
                    .else_expr = try substituteColumnRefsWithDepth(
                        alloc,
                        c.else_expr,
                        alias_map,
                        table_alias,
                        depth + 1,
                    ),
                }),
                .collation = e.collation,
            });
        },
        // EXISTS, subquery, literal, parameter, star, cast: not substituted.
        else => return e,
    }
}

/// Go copyExpression: deep copy of an SQL expression.
fn copyExpression(alloc: std.mem.Allocator, expr: ?*SQLExpression) Error!?*SQLExpression {
    const e = expr orelse return null;
    const copied = try create(alloc, SQLExpression{
        .type = e.type,
        .value = e.value,
        .alias = e.alias,
        .table_alias = e.table_alias,
        .collation = e.collation,
    });

    if (e.binary_expression) |b| {
        copied.binary_expression = try create(alloc, BinaryExpression{
            .left = try copyExpression(alloc, b.left),
            .operator = b.operator,
            .right = try copyExpression(alloc, b.right),
        });
    }
    if (e.function_call) |fc| {
        const args = try alloc.alloc(*SQLExpression, fc.arguments.len);
        for (fc.arguments, 0..) |arg, i| {
            args[i] = (try copyExpression(alloc, arg)).?;
        }
        copied.function_call = try create(alloc, FunctionCall{
            .name = fc.name,
            .arguments = args,
            .is_distinct = fc.is_distinct,
            .window_spec = fc.window_spec,
        });
    }
    if (e.unary_expression) |u| {
        copied.unary_expression = try create(alloc, UnaryExpression{
            .operator = u.operator,
            .expression = (try copyExpression(alloc, u.expression)).?,
        });
    }
    if (e.list_expression) |l| {
        const exprs = try alloc.alloc(*SQLExpression, l.expressions.len);
        for (l.expressions, 0..) |le, i| {
            exprs[i] = (try copyExpression(alloc, le)).?;
        }
        copied.list_expression = try create(alloc, ListExpression{ .expressions = exprs });
    }
    if (e.case_expression) |c| {
        const when = try alloc.alloc(*WhenClause, c.when_clauses.len);
        for (c.when_clauses, 0..) |w, i| {
            when[i] = try create(alloc, WhenClause{
                .condition = (try copyExpression(alloc, w.condition)).?,
                .result = (try copyExpression(alloc, w.result)).?,
            });
        }
        copied.case_expression = try create(alloc, CaseExpression{
            .case_expr = try copyExpression(alloc, c.case_expr),
            .when_clauses = when,
            .else_expr = try copyExpression(alloc, c.else_expr),
        });
    }
    if (e.exists_expr) |ex| {
        copied.exists_expr = try create(alloc, ExistsExpression{ .subquery = ex.subquery });
    }
    if (e.subquery) |sq| {
        copied.subquery = sq; // Subqueries are not deep-copied.
    }

    return copied;
}

/// Go substituteInJoinConditions.
fn substituteInJoinConditions(
    alloc: std.mem.Allocator,
    from_item: ?*FromItem,
    alias_map: *AliasMap,
) Error!void {
    const fi = from_item orelse return;
    if (fi.type != .join) return;
    const join = fi.join orelse return;

    if (join.condition) |cond| {
        join.condition = try substituteColumnRefs(alloc, cond, alias_map, "");
    }
    if (join.left) |left| {
        if (left.type == .join) try substituteInJoinConditions(alloc, left, alias_map);
    }
    if (join.right) |right| {
        if (right.type == .join) try substituteInJoinConditions(alloc, right, alias_map);
    }
}

/// Go mergeWhereConditions.
fn mergeWhereConditions(
    alloc: std.mem.Allocator,
    outer_where: ?*SQLExpression,
    inner_where: ?*SQLExpression,
    alias_map: *AliasMap,
    table_alias: []const u8,
) Error!?*SQLExpression {
    var outer = outer_where;
    if (outer) |o| {
        outer = try substituteColumnRefs(alloc, o, alias_map, table_alias);
    }

    if (outer != null and inner_where != null) {
        return try create(alloc, SQLExpression{
            .type = .binary,
            .binary_expression = try create(alloc, BinaryExpression{
                .left = inner_where,
                .operator = "AND",
                .right = outer,
            }),
        });
    }
    if (outer) |o| return o;
    return inner_where;
}
