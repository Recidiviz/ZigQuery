//! Clause-slot rules over a partially-built `SelectStatement`.
//!
//! A port of GoogleSQL's QueryExpression::CanSet* predicates
//! (zetasql/resolved_ast/query_expression.cc). `SelectStatement` already *is*
//! the slot struct — every clause has an empty/null "free" state and the
//! renderer already handles every combination — so this file adds only the
//! rules, and keeps sqlbuilder.zig's byte-faithful-port character intact.
//!
//! The point of the rules: a resolved scan does not imply a SQLite subquery
//! level. It needs one only when the clause it wants to write is already
//! occupied. `SELECT x FROM t WHERE y > 1 LIMIT 10` is four scans and one
//! level, because the four scans claim four different slots.
//!
//! The ordering constraints are not arbitrary. `canSetWhere` requiring the
//! select list to still be *free* is what stops a WHERE from being written
//! against a projection it must not see:
//!
//!     SELECT f(x) AS c FROM t          -- select slot taken by the projection
//!     ... WHERE c > 0                  -- would mean "after f(x)", which is
//!                                      -- not what the resolved AST said
//!
//! so a filter above a projection wraps, and a filter above a bare table scan
//! does not.
// ephor:ignore-file ZA304 ZT105

const sb = @import("sqlbuilder.zig");

const Q = sb.SelectStatement;

pub fn hasWith(q: *const Q) bool {
    return q.with_clauses.len > 0;
}
pub fn hasSelect(q: *const Q) bool {
    return q.select_list.len > 0;
}
pub fn hasFrom(q: *const Q) bool {
    return q.from_clause != null;
}
pub fn hasWhere(q: *const Q) bool {
    return q.where_clause != null;
}
pub fn hasGroupBy(q: *const Q) bool {
    return q.group_by_list.len > 0;
}
pub fn hasHaving(q: *const Q) bool {
    return q.having_clause != null;
}
pub fn hasOrderBy(q: *const Q) bool {
    return q.order_by_list.len > 0;
}
pub fn hasLimit(q: *const Q) bool {
    return q.limit_clause != null;
}
pub fn hasSetOp(q: *const Q) bool {
    return q.set_operation != null;
}

pub fn canSetWith(q: *const Q) bool {
    return !hasWith(q);
}

pub fn canSetSelect(q: *const Q) bool {
    return !hasSelect(q) and !hasSetOp(q);
}

pub fn canSetFrom(q: *const Q) bool {
    return !hasFrom(q) and canSetSelect(q);
}

pub fn canSetWhere(q: *const Q) bool {
    return !hasWhere(q) and hasFrom(q) and canSetSelect(q);
}

pub fn canSetGroupBy(q: *const Q) bool {
    return !hasGroupBy(q) and hasFrom(q) and canSetSelect(q);
}

pub fn canSetOrderBy(q: *const Q) bool {
    return !hasOrderBy(q) and !hasLimit(q) and hasFrom(q);
}

pub fn canSetLimit(q: *const Q) bool {
    return !hasLimit(q);
}

/// Whether the statement is already a complete query. GoogleSQL
/// CanFormSQLQuery: a query needs either a select list or a set operation.
pub fn canFormQuery(q: *const Q) bool {
    return !canSetSelect(q);
}

/// Whether an expression can be written at several use sites instead of being
/// projected once and referenced by name.
///
/// This is the one place the port must diverge from GoogleSQL's SQLBuilder.
/// GoogleSQL inlines a pending expression at every use without a thought,
/// because its output goes back to the *analyzer*. Ours goes to SQLite to be
/// *executed*: projecting `zigquery_regexp_extract(...)` once and referencing
/// the alias three times is one evaluation per row, and inlining it three times
/// is three. A function call is also where non-determinism lives — `RAND`,
/// `GENERATE_UUID`, `CURRENT_TIMESTAMP` — and duplicating those changes results,
/// not just cost.
///
/// So: column references, literals and parameters duplicate freely (SQLite
/// re-reads a column or re-reads a constant for nothing), and operator trees
/// over them do too. Everything else gets a name.
///
/// A reference-count gate would be strictly better — a function call used
/// exactly once is safe to inline — but the count has to come from the
/// resolved AST, and the transformers synthesize column references of their
/// own that no AST walk sees. This rule needs no such bookkeeping and gives up
/// only the single-use function call.
pub fn isCheapToDuplicate(expr: *const sb.SQLExpression) bool {
    return switch (expr.type) {
        .column, .literal, .parameter, .star => true,
        .unary => if (expr.unary_expression) |u| isCheapToDuplicate(u.expression) else false,
        .binary => if (expr.binary_expression) |b|
            (b.left == null or isCheapToDuplicate(b.left.?)) and
                (b.right == null or isCheapToDuplicate(b.right.?))
        else
            false,
        // A list costs what its elements cost: an `IN (1,2,3)` right side, and
        // the parenthesised operands `grouped` builds in transformer/function.zig.
        .list => if (expr.list_expression) |l| blk: {
            for (l.expressions) |e| {
                if (!isCheapToDuplicate(e)) break :blk false;
            }
            break :blk true;
        } else false,
        // Function calls (every zigquery_* UDF), subqueries, EXISTS, CASE
        // and casts all get projected.
        .function, .subquery, .exists, .case, .cast => false,
    };
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const std = @import("std");
const testing = std.testing;

test "a bare row source can take any clause" {
    var from = sb.FromItem{ .type = .table, .table_name = "t" };
    var q = Q{ .from_clause = &from };

    try testing.expect(canSetSelect(&q));
    try testing.expect(canSetWhere(&q));
    try testing.expect(canSetGroupBy(&q));
    try testing.expect(canSetOrderBy(&q));
    try testing.expect(canSetLimit(&q));
    // FROM is spoken for, though.
    try testing.expect(!canSetFrom(&q));
    try testing.expect(!canFormQuery(&q));
}

test "a filled select list closes WHERE and GROUP BY but not ORDER BY or LIMIT" {
    var expr = sb.SQLExpression{ .type = .column, .value = "a" };
    var item = sb.SelectListItem{ .expression = &expr };
    var items = [_]*sb.SelectListItem{&item};
    var from = sb.FromItem{ .type = .table, .table_name = "t" };
    var q = Q{ .from_clause = &from, .select_list = &items };

    try testing.expect(!canSetSelect(&q));
    try testing.expect(!canSetWhere(&q));
    try testing.expect(!canSetGroupBy(&q));
    // ORDER BY and LIMIT apply after the projection, so they still fit.
    try testing.expect(canSetOrderBy(&q));
    try testing.expect(canSetLimit(&q));
    try testing.expect(canFormQuery(&q));
}

test "LIMIT closes ORDER BY, and a set operation closes the select list" {
    var from = sb.FromItem{ .type = .table, .table_name = "t" };
    var count = sb.SQLExpression{ .type = .literal, .value = "10" };
    var limit = sb.LimitClause{ .count = &count };
    var q = Q{ .from_clause = &from, .limit_clause = &limit };
    // Ordering after a LIMIT would order the truncated rows, not select them.
    try testing.expect(!canSetOrderBy(&q));
    try testing.expect(!canSetLimit(&q));

    var set_op = sb.SetOperation{ .type = "UNION", .modifier = "ALL" };
    var qs = Q{ .set_operation = &set_op };
    try testing.expect(!canSetSelect(&qs));
    try testing.expect(canFormQuery(&qs));
}
