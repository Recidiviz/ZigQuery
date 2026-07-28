# Plan — replacing one-`FromItem`-per-scan with a clause-slot model

Companion to [SQL_MINIMIZATION.md](SQL_MINIMIZATION.md), which establishes the
problem (38% of emitted `SELECT` levels are pure pass-throughs; `project_scan`
alone is 61% of levels) and the reference design (GoogleSQL's
`QueryExpression` + `pending_columns_` + `AddSelectListIfNeeded`).

This document is the migration. It is written to be executed one commit at a
time, with every commit green on 746 PASS and a reviewable SQL diff.

---

## 0. Objective and success criteria

**Objective.** A scan no longer implies a `SELECT` level. A level appears only
when a scan needs a clause slot that is already occupied.

Gate each stage on these, measured by the harness in S0:

| metric | baseline (`1f95690`) | target | **achieved** |
| --- | --- | --- | --- |
| corpus | 746 PASS / 0 FAIL / 2 SKIP | unchanged, every stage | **746 / 0 / 2** ✓ |
| unit tests | green | unchanged, every stage | **green** ✓ |
| prepared SQL | 535,820 B / 833 stmts / 643 B each | ≤ 340,000 B (−36%) | **355,065 B / 426 B each (−33.7%)** — near miss |
| `SELECT` levels | 4,265 | ≤ 2,500 | **2,543 (−40.4%)** — near miss |
| pass-through levels | 1,640 (38%) | ≤ 150 (<6%) | **734 (29%)** — missed, see §8 |
| max paren depth | 11 | ≤ 7 | **8** — near miss |

The byte target is the pass-through floor (38% of levels, and pass-through
levels are the cheapest ones textually) plus the two S1 wins. It is a gate, not
a promise: if S4 lands and the number is 380k, that is a finding to write down,
not a reason to keep going.

**Outcome: four of six gates met, two near-missed by a few percent, and the
pass-through gate missed outright.** §8 records why and what it would take.

**Explicit non-goal:** matching GoogleSQL's output. We are borrowing its
algorithm, not its formatting, its alias scheme, or its `ResetSelectClause`
escape hatches. Our globally-unique `name__id` aliases (`context.zig:64`) make
most of its alias machinery unnecessary.

---

## 1. The core design

### 1.1 `SelectStatement` is already the slot struct

No new type. `sqlbuilder.SelectStatement` (`sqlbuilder.zig`) already has exactly
the fields GoogleSQL's `QueryExpression` has — `with_clauses`, `select_type`,
`select_list`, `from_clause`, `where_clause`, `group_by_list`, `having_clause`,
`order_by_list`, `limit_clause`, `set_operation` — each with an empty/null "slot
free" state, and a `writeSql` that already renders every combination.

Add a **new file** `src/internal/sqlbuilder/query_expr.zig` holding free
functions over `*SelectStatement`. `sqlbuilder.zig` is a byte-faithful port of
the Go original and its header documents that; keep it untouched so that
property stays checkable.

```zig
// src/internal/sqlbuilder/query_expr.zig
const sb = @import("sqlbuilder.zig");

pub fn hasSelect(q: *const sb.SelectStatement) bool { return q.select_list.len > 0; }
pub fn hasFrom(q: *const sb.SelectStatement) bool   { return q.from_clause != null; }
// … hasWhere, hasGroupBy, hasOrderBy, hasLimit, hasSetOp

// Clause-ordering rules, transcribed from query_expression.cc:312.
pub fn canSetSelect(q: *const sb.SelectStatement) bool {
    return !hasSelect(q) and !hasSetOp(q);
}
pub fn canSetFrom(q: *const sb.SelectStatement) bool {
    return !hasFrom(q) and canSetSelect(q);
}
pub fn canSetWhere(q: *const sb.SelectStatement) bool {
    return !hasWhere(q) and hasFrom(q) and canSetSelect(q);
}
pub fn canSetGroupBy(q: *const sb.SelectStatement) bool {
    return !hasGroupBy(q) and hasFrom(q) and canSetSelect(q);
}
pub fn canSetOrderBy(q: *const sb.SelectStatement) bool {
    return !hasOrderBy(q) and !hasLimit(q) and hasFrom(q);
}
pub fn canSetLimit(q: *const sb.SelectStatement) bool { return !hasLimit(q); }

/// GoogleSQL QueryExpression::Wrap. Moves `q`'s current form into a subquery
/// FROM item and resets every other slot. Caller must have filled the select
/// list first (see coordinator.addSelectListIfNeeded).
pub fn wrap(alloc: std.mem.Allocator, q: *sb.SelectStatement, alias: []const u8) !void {
    const inner = try alloc.create(sb.SelectStatement);
    inner.* = q.*;
    q.* = .{ .from_clause = try sb.newSubqueryFromItem(alloc, inner, alias) };
}
```

`canSetWhere` requiring a *free* select list is not an oversight — WHERE must
not see select-list computations. It is what forces the wrap in
`… WHERE f(x) > 0` over a projected `f(x)`.

### 1.2 The scan contract

```zig
// before
fn transformScan(…) Error!*sqlbuilder.FromItem
// after
fn transformScan(…) Error!*sqlbuilder.SelectStatement   // partially filled
```

A scan that is "just a source" — table, `with_ref`, `array`/UNNEST,
`recursive_ref` — returns `SelectStatement{ .from_clause = <item>, … all else
empty }`, i.e. GoogleSQL's "`from_` set, `select_list_` free" state. It is
*not* a level until someone wraps it.

`single_row` already behaves this way today by accident: `scan_single_row.zig`
returns a bare `.single_row` FromItem, `FromItem.writeSql` renders nothing for
it, and `validateColumnData` returns early for non-subqueries. Under the new
contract it becomes explicit rather than accidental.

### 1.3 Two coordinator helpers

```zig
/// GoogleSQL AddSelectListIfNeeded (sql_builder.cc:1710). Fills the select
/// slot from `columns` only when it is free, draining `pending` as it goes.
fn addSelectListIfNeeded(self: *QueryCoordinator, q: *SelectStatement,
                         columns: []const *ColumnData, ctx: *TransformContext) Error!void;

/// GoogleSQL WrapQueryExpression (sql_builder.cc:1619) + the old
/// transformScan tail. Fills the select list, wraps, re-points the columns
/// at `alias`, and returns the FROM item consumers still want.
fn materializeScan(self: *QueryCoordinator, q: *SelectStatement, alias: []const u8,
                   columns: []const *ColumnData, ctx: *TransformContext) Error!*FromItem;
```

`materializeScan` is what makes the migration incremental: in S2 every call site
uses it and the output is byte-identical to today. Stages after that delete call
sites one at a time.

### 1.4 The `pending` map

`FragmentContext` (`context.zig:85`) gains:

```zig
/// Column ID -> the expression that computes it, not yet projected.
/// GoogleSQL SQLBuilder::pending_columns_ (sql_builder.h).
pending: std.AutoHashMap(i64, *sqlbuilder.SQLExpression),
```

and `column_ref.zig:23` becomes GoogleSQL's `VisitResolvedColumnRef`
(`sql_builder.cc:1100`):

```zig
if (ctx.fragmentContext().pending.get(column_data.column_id)) |expr| return expr;
return ctx.fragmentContext().getQualifiedColumnExpression(column_data.column_id);
```

**The one invariant that matters:** a column is in `pending` **xor** resolvable
through `column_id_to_scope`, never both, never neither.
`addSelectListIfNeeded` is the only place that moves a column from the first
state to the second, and it must do both halves atomically (emit the select item
*and* `pending.remove(id)` *and* `registerColumnScope(id, alias)`).

### 1.5 Use-count gating — the one place we must diverge

GoogleSQL inlines a pending expression at every use site without a thought,
because its output goes back to the *analyzer*. Ours goes to SQLite to
*execute*: `SELECT zetasqlite_regexp_extract(…) AS c__5` referenced three times
is one evaluation per row today and three after inlining.

So: **`pending` is only consulted for inlining when the column's reference count
is ≤ 1, or the expression is trivially cheap** (`.column`, `.literal`,
`.parameter`). Otherwise the column is projected normally.

Counts come from the extractor, not a new AST walk.
`newColumnExpressionData` (`extractor.zig:410`) is the single choke point
through which every `ResolvedColumnRef` passes; increment there into a map on
`TransformContext`. This depends on extraction being fully eager —
`ExtractStatementData` returns a complete `StatementData` tree before any
transformation starts (scan data holds `input_scan: ScanData` by value). **Verify
that assumption explicitly in S5** before relying on it; if any subtree turns
out to be extracted lazily, fall back to a dedicated pre-pass over
`AnyResolvedNodeProto`.

This gate also covers non-determinism (`RAND`, `GENERATE_UUID`,
`CURRENT_TIMESTAMP`) for free: count > 1 means project, so they are evaluated
once.

---

## 2. Staging

Each stage is one commit (or a short series), green on `zig build test` and
`zig build corpus -Drelease=true`, with the S0 snapshot diff attached to the
commit message.

### S0 — Snapshot harness *(no product change)*

`harness/corpus_runner.zig` already runs every case with its tables created and
already counts prepared bytes (`:95`). Add `DUMP_SQL=<path>`: write one record
per case — idx, name, emitted SQL, level count, byte count — plus a footer with
the six metrics from §0. There is no existing SQL-text golden
(`testdata/golden.json` is REST responses from the Go emulator; `baseline.txt`
is pass/fail only), and a rewrite this size is not reviewable without one.

Commit `testdata/sql_snapshot.txt` at baseline. Every later stage shows its diff.

**Exit:** snapshot committed; regenerating it twice is byte-stable.

### S1 — The two proven wins *(independent of everything else)*

Both already verified at 746 PASS / 0 FAIL / 2 SKIP; see SQL_MINIMIZATION §7.
They do not depend on the slot model and should not wait for it.

1. `with_entry.zig:57-65` — drop the `is_recursive` condition so non-recursive
   CTE bodies stop getting a redundant `SELECT * FROM (…)` wrapper.
   **535,820 → 519,865 B (−3.0%), one line.**
2. `sqlbuilder.zig:765` — `" AS MATERIALIZED \t("` → `" AS \t("`, honouring the
   `materialized` field the Go original ignores (`:747`). SQLite ≥3.35 already
   picks correctly; forcing it turns an index seek into a materialize-plus-scan.
   Corpus timing cannot show this (tiny unindexed in-memory tables); the
   evidence is `EXPLAIN QUERY PLAN` and the workload is the view graph.
   This one touches a file whose header promises byte-fidelity to Go — update
   that header in the same commit.

**Exit:** −3% bytes, 746 PASS, snapshot diff reviewed.

### S2 — Contract change, zero output diff

Mechanical. `transformScan` returns `*SelectStatement`; `materializeScan` at
every one of the 13 call sites (`scan_project:26`, `scan_filter:25`,
`scan_join:31,32`, `scan_aggregate:43`, `scan_orderby:35`, `scan_limit:26`,
`scan_analytic:36`, `scan_array:30`, `scan_with:61`, `with_entry:44`,
`stmt_query:26`, `subquery:30`, `stmt_dml:55,119`, `stmt_merge:50,51`).

Each scan transformer stops building its own `FromItem{.type = .subquery}` and
returns the `SelectStatement` it already built. `materializeScan` does the tail
that `transformScan` does today (`coordinator.zig:220-239`): alias, wrap,
validate, register.

Two details that keep the diff at zero:

- **Alias numbering must not move.** Aliases come from `getID()`, driven by
  `enterScope` in `transformScan`, not by the wrap. Leave the
  `enterScope`/`exitScope` bracketing exactly where it is.
- **`materializeScan` must pass through the "already just a source" case:** if
  the select list is empty and only `from_clause` is set, return `from_clause`
  directly instead of wrapping. At S2 only `single_row` hits this (everything
  else still fills its select list), which reproduces today's behaviour exactly.

Update `types_interfaces.zig:16` — it documents the scan signature.

**Exit:** snapshot diff is **empty**. If it is not, stop and find out why.

This stage also delivers the kill switch for free: a `materializeScan` at every
call site *is* the old architecture, so reverting any later stage is a local
change, not an unwind.

### S3 — Leaf scans stop projecting; `pending` goes in

The enabler. Four transformers stop building select lists and register their
columns in `pending` instead:

| file | today | after |
| --- | --- | --- |
| `scan_table.zig:30-71` | `SELECT col AS col__id, … FROM tbl` | `from = tbl`; each column → `pending` as `` `col` `` |
| `scan_with_ref.zig:44-57` | `SELECT wrsN.x__11 AS x__23, … FROM cte AS wrsN` | `from = cte AS wrsN`; mapping → `pending` |
| `scan_array.zig:83-99` | `SELECT $arrayN.value AS x__3, …` | `from = json_each(…)`; element/offset → `pending` |
| `scan_recursive_ref.zig:44-58` | `SELECT rrsN.x AS x__id, …` | `from = cte AS rrsN`; mapping → `pending` |

Plus `addSelectListIfNeeded` and the pending drain in `materializeScan`, and the
`column_ref.zig` lookup.

`scan_table`'s synthetic-column path (`:44-57`, wildcard `_TABLE_SUFFIX`) is
empty in practice but must keep working — it registers scopes directly, so route
it through `pending` too rather than leaving two mechanisms.

**Watch:** `addAvailableColumnsForDML` (`context.zig:134`) deliberately registers
*raw* SQLite column names for DML base tables, bypassing ID aliases. Nothing may
shadow those with `pending` entries.

**Exit:** 746 PASS. Levels drop where a leaf feeds a project/filter directly;
the snapshot diff should be large and boringly uniform.

### S4 — Clause scans set in place

`if (!canSetX) wrap()` — GoogleSQL's line, four times.

- **`scan_filter.zig`** — `canSetWhere` → set `where_clause` in place. Over an
  S3 leaf this is always true, so filters stop costing a level.
- **`scan_limit.zig`** — `canSetLimit` is almost always true; LIMIT merges down.
  Drop the dead alias built at `:47`.
- **`scan_aggregate.zig`** — `canSetGroupBy` → set `group_by_list` in place;
  aggregate outputs go to `pending`; then **always** `addSelectListIfNeeded`.
  Aggregates are a hard materialization boundary. Keep the existing two-form
  discipline: `zetasqlite_group_by(...)`-wrapped in GROUP BY, unwrapped in the
  select list (`scan_aggregate.zig:59-68`).
- **`scan_project.zig`** — computed columns go to `pending`; fill the select
  slot if free, else wrap. This is the 61%.
- **`scan_analytic.zig`** — always materialize, like aggregate. Window functions
  must not be inlined past their scan.
- **`scan_orderby.zig`** — **keep the unconditional wrap.** GoogleSQL does the
  same and says why (`sql_builder.cc:2680`: "to avoid losing columns only used
  by order-by items"), and our `$orderby` column dropping depends on it. 1.8% of
  levels; not worth the risk.
- **`scan_join.zig`** — `from = join`, select slot left free. Each *operand*
  materializes (a join operand must be a table or subquery), which is also what
  makes NULL semantics safe across LEFT/FULL joins: an expression computed below
  the join stays below it.

**Exit:** this is where the §0 targets should be met or the plan is wrong.
Expect the largest snapshot diff of the project. Review it in slices by scan
kind, not as one blob.

### S5 — Expression inlining with the use-count gate

Extractor ref counting (§1.5), then let `column_ref` inline pending expressions
that pass the gate. Removes the project levels that S4 still wraps.

Land the counter and the gate as **two commits**: counter first with the gate
hard-wired to "never inline" (zero output diff, proves the counting is correct
in isolation), then flip it on.

**Exit:** 746 PASS; verify by inspection that no `zetasqlite_*` call appears
more than once per select list in the snapshot.

### S6 — Set-op single level

`scan_setop.zig:68-86` emits two levels: the set operation, then an outer
re-alias to `name__id`. Push the output aliases into each branch's own select
list instead (GoogleSQL: `SetAliasForSelectColumn`, `query_expression.cc:359`).
269 levels, 10.6%. Independent of S3–S5.

### S7 — Cleanup and re-measure

- Replace `validateColumnData` (`coordinator.zig:285`). Its current job — assert
  one select item per scan column with an ID-based alias — *is* the invariant
  being removed, so it will have been progressively defanged through S3–S5.
  The replacement is weaker and still worth having: after each `transformScan`,
  every column in `scan_data.column_list` resolves — present in `pending`, in the
  select list, or mapped by `column_id_to_scope`.
- Re-test `flatten.zig`. `flattenSelectForRecursiveCTE` exists because SQLite
  needs the recursive reference at the top level of the recursive arm; with far
  fewer levels it may be redundant or may need re-tuning. Do not delete it
  speculatively — the recursive corpus cases are the canary and they are few.
- Rewrite the measurement note at `sqlbuilder.zig:14-32`. It currently tells the
  next reader that level-collapsing was tried and dropped; leaving that in place
  after doing it is worse than no note.
- Update SQL_MINIMIZATION.md §2 with the achieved numbers.

---

## 3. Risk register

| # | risk | why it bites | mitigation |
| --- | --- | --- | --- |
| R1 | Inlining duplicates UDF evaluation | our output is executed, not re-analyzed; `zetasqlite_*` calls are not cheap | use-count gate (§1.5), landed as its own verifiable commit |
| R2 | `pending` leaks past a materialization boundary | a column inlined after its defining level was wrapped → wrong scope, silently wrong results | the xor invariant (§1.4); `addSelectListIfNeeded` is the only transition point |
| R3 | LEFT/FULL JOIN NULL semantics | an expression computed below a join is not the same computed above it | join operands always materialize (S4) |
| R4 | Aggregate/analytic outputs inlined | nested aggregates | both always `addSelectListIfNeeded` (S4) |
| R5 | Recursive CTEs | SQLite requires the recursive ref at top level; `flatten.zig` assumes today's shape | recursive corpus cases as canary; S7 re-tests rather than assumes |
| R6 | DML / MERGE | `stmt_dml.zig:55,119` and `stmt_merge.zig:50,51` use the scan as a table | keep them on `materializeScan` permanently; never migrate them |
| R7 | Alias numbering drift | churns the whole snapshot and hides real diffs | S2 exit criterion is a *zero* diff; `enterScope` bracketing untouched |
| R8 | Extraction not fully eager | ref counts incomplete → wrong inlining decisions | verify explicitly in S5; fall back to a pre-pass |

**Not a risk:** `SELECT DISTINCT`. GoogleSQL resolves it as an AggregateScan
with every column a grouping key, so `select_type = .distinct` never appears in
the query path — the only use is `stmt_merge.zig:422`.

---

## 4. What we are not doing

- **Not matching GoogleSQL's output.** Its alias machinery
  (`UpdateColumnAlias`, `seen_aliases`, `MakeNonconflictingAlias`) exists to
  avoid collisions we cannot have; `generateIDBasedAlias` already gives every
  column a globally unique name.
- **Not touching the unparser path.** `parser/unparser.cc` is parse-tree → SQL;
  we never hold a parse tree.
- **Not adding a post-hoc SQL rewriting pass.** That was tried and dropped
  (`sqlbuilder.zig:23-32`): −3.2% bytes, −9.0% prepare, ≈2% of request, for a
  new pass and its correctness surface. This plan changes the contract instead,
  so there is no second pass to own.
- **Not reformatting.** Compact rendering was measured at −13.2% bytes and
  +0.2% prepare, i.e. nothing (`sqlbuilder.zig:19-22`). Whitespace is free to
  tokenize. Leave `use_newlines` alone; readable output is worth more during
  this project than at any other time.

---

## 5. What actually happened

Executed in order. Every row below is 746 PASS / 0 FAIL / 2 SKIP with unit
tests green in Debug *and* ReleaseFast; the byte column is
`phase.preparedBytes()` from `zig build corpus -Drelease=true`.

| stage | change | prepared B | levels |
| --- | --- | --- | --- |
| — | baseline | 535,820 | 4,265 |
| S1 | CTE `SELECT *` wrapper; `AS MATERIALIZED` honours its field | 517,655 | 4,119 |
| S2 | `transformScan` → `*SelectStatement` + `materializeScan` shim | 517,655 | 4,119 |
| S3 | leaf scans leave columns pending | 517,717 | 4,119 |
| S4 | filter / limit / project / aggregate / join / with claim slots | 484,047 | 3,648 |
| S6 | set operation renames branches in place | 465,212 | 3,508 |
| S5 | projections leave cheap expressions pending | 457,007 | 3,442 |
| S5 | the statement's own output list claims the slot | 358,427 | 2,595 |
| S7 | scalar/EXISTS/IN subqueries stop wrapping in `SELECT *` | 355,065 | 2,543 |

Two results worth keeping:

**S2's zero diff was worth the stage.** Changing the return type of every scan
transformer and re-wiring 15 call sites, with a byte-identical snapshot as the
exit criterion, meant that when S3 and S4 *did* move the output, nothing in the
diff was mechanical noise.

**The single biggest win was the last one anybody would have planned for.**
Having `stmt_query` claim the scan's select slot — one `if` — took 457k → 358k
bytes and 3,442 → 2,595 levels, more than S1 through S6 combined. It is the
outermost SELECT of every statement, and it had been unconditionally spending a
level to rename `x__1` to `x`. Nothing in the up-front analysis pointed at it,
because the per-scan-kind census counts scans and this level belongs to the
statement.

Verified by hand beyond the corpus, one query each: non-deterministic function
projected once rather than inlined twice (R1); LEFT JOIN null-extension, and an
expression computed below a LEFT JOIN staying below it (R3); recursive CTE;
correlated scalar subquery; window function over a projection; DISTINCT with
ORDER BY and LIMIT.

## 6. Where it did not reach the target, and why

The pass-through gate (<6%) was missed at 29%, and `project_scan` is still 56%
of remaining levels. One decision explains both.

§1.5 planned a **reference-count** gate on inlining. Building it needs a count
of how many places will reference a column during transformation, and the
obvious choke point — `newColumnExpressionData` in the extractor — does not see
the column references the *transformers* synthesize for pass-through columns.
Counting only what the AST holds would undercount and inline something used
twice, which is the one failure this gate exists to prevent.

So the shipped gate is **cost of duplication**, not use count
(`query_expr.isCheapToDuplicate`): column references, literals, parameters and
operator trees over them duplicate freely; function calls, subqueries, CASE and
casts get projected. It is decidable locally, needs no bookkeeping, and is
conservative in the safe direction. What it gives up is the single-use function
call — `SELECT (SELECT 7) AS s` and `SELECT f(x) AS y` still spend a level that
a use-count gate would not.

Recovering the rest means building the count properly: walk the extracted
`StatementData` tree (which *is* fully eager — verified, `ScanData` is held by
value) and add the synthesized pass-through references, which are derivable
from each scan's `column_list`. That is a self-contained follow-up with a clear
test: the remaining `project_scan` levels should fall and no `zetasqlite_*` call
should appear twice in one select list.

## 7. Left alone deliberately

- **`order_by_scan` (27 levels) still always wraps.** GoogleSQL does the same
  and says why (`sql_builder.cc:2680`); our `$orderby` column dropping depends
  on it.
- **`aggregate_scan` (91) and `analytic_scan` (67) always project.** They are
  materialization boundaries — R4.
- **DML and MERGE** stayed on `materializeScan` permanently — R6.
- **`flatten.zig` is still live**, called from `scan_recursive.zig:47`. The
  recursive-CTE corpus cases pass; it was not touched.
