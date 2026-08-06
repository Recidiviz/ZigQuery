# Emitting the minimum SQL — transformer review vs. GoogleSQL's SQLBuilder

Baseline commit `1f95690` (746 PASS / 0 FAIL / 2 SKIP). All numbers below are
reproducible with `zig build corpus -Drelease=true` and
`./zig-out/bin/zetasqlite-zig --sql "<query>"`.

The existing note at the top of `src/internal/sqlbuilder/sqlbuilder.zig` already
establishes the shape of the problem: prepare cost is per *level*, not per byte,
and a post-hoc level-collapsing pass was built, measured (−3.2% bytes, −9.0%
prepare, ≈2% of request) and dropped as not worth a new rewriting pass. This
document takes the other route — not a pass over the output, but a change to the
*contract between the coordinator and the scan transformers*, which is where
GoogleSQL's own unanalyzer solves the same problem for free.

---

## 1. What the transformer emits today

The invariant is one SQLite `SELECT` level per resolved scan. It is not
incidental; it is enforced.

`QueryCoordinator.transformScan` (`src/internal/coordinator/coordinator.zig:145`)
dispatches to a transformer, then unconditionally:

1. assigns `<kind>_scan_<scope id>` as the FROM-item alias (`:220`),
2. calls `validateColumnData` (`:285`), which **requires** the returned FromItem
   to be a `.subquery` whose select list has exactly one item per scan output
   column, each carrying an ID-based alias,
3. re-registers every output column against the new alias (`:230`, `:237`).

Every scan transformer therefore ends the same way — build a `SelectStatement`,
wrap it in `FromItem{ .type = .subquery }`:

| transformer | emitted level |
| --- | --- |
| `scan_table.zig:68` | `SELECT col AS col__id, … FROM tbl` |
| `scan_project.zig:66` | `SELECT <expr> AS col__id, … FROM (…)` |
| `scan_filter.zig:30` | `SELECT * FROM (…) WHERE …` |
| `scan_join.zig:59` | `SELECT * FROM (L) JOIN (R) ON …` |
| `scan_orderby.zig:46` | `SELECT col__id, … FROM (…) ORDER BY …` |
| `scan_limit.zig:31` | `SELECT * FROM (…) LIMIT …` |
| `scan_setop.zig:68,83` | **two** levels: inner set-op + outer re-alias |
| `with_entry.zig:64` | one extra `SELECT * FROM (…)` around every non-recursive CTE body |

Column references never resolve to an expression — only to a name.
`FragmentContext.getQualifiedColumnExpression`
(`src/internal/coordinator/context.zig:199`) looks up the qualified ref and then
**discards the table alias**, returning a bare `` `name__id` ``. That detail is
important later: because every column alias is globally unique
(`generateIDBasedAlias`, `context.zig:64`), the emitted SQL has no name ambiguity
to protect, so levels can be collapsed without any renaming work. GoogleSQL's own
builder has to work much harder here (`UpdateColumnAlias`, `seen_aliases`,
`MakeNonconflictingAlias`).

`SELECT 1 AS x` becomes:

```sql
SELECT `x__1` AS `x`
FROM ( SELECT 1 AS `x__1` ) AS `project_scan_3`
```

## 2. How much of the output is structural noise

Over the 709 corpus queries that translate standalone:

```
input GoogleSQL      107,292 B
emitted SQLite       494,957 B      4.6x
SELECT levels          3,991        mean 5.6, median 2, p90 14, max 38
paren depth                         mean 3.5, p90 6, max 11
```

Classifying every emitted `SELECT` by whether it carries any semantics of its own
(WHERE / GROUP BY / ORDER BY / LIMIT / set-op / JOIN at that level, or a select
list containing anything but bare column-or-star renames):

**1,497 of 3,991 levels — 38% — are pure pass-throughs.** They exist only because
a scan existed.

By scan kind (2,540 levels carrying a `*_scan_N` alias):

```
project_scan       1542   60.7%
set_op_scan         269   10.6%
with_ref_scan       165    6.5%
array_scan          158    6.2%
with_scan           142    5.6%
aggregate_scan       90    3.5%
analytic_scan        68    2.7%
order_by_scan        46    1.8%
filter_scan          41    1.6%
join_scan            12    0.5%
```

**ProjectScan alone is 61% of all emitted levels** — and it is precisely the scan
GoogleSQL's builder emits *no* level for.

Full-corpus baseline through `corpus-runner` (833 prepared statements, including
the table-backed cases the CLI can't reach): **535,820 B, 643 B per statement.**

### A worked example

`WITH Roster AS (…5-way UNION ALL…), TeamMascot AS (…4-way…) SELECT * FROM Roster
INNER JOIN TeamMascot USING (SchoolID)` — 503 input bytes — emits 2,959 bytes and
28 `SELECT`s. The join tail alone is:

```sql
SELECT * FROM (
  SELECT `SchoolID__24`, `LastName__23`, `Mascot__26` FROM (
    SELECT * FROM (
      (…) AS `with_ref_scan_37` INNER JOIN (…) AS `with_ref_scan_38` ON …
    ) AS `join_scan_36`
  ) AS `project_scan_35`
) AS `with_scan_3`
```

Three levels above the join; all three are renames. Each `UNION ALL` branch of a
CTE costs two levels to emit one literal row, and each CTE body costs three to
express one compound select.

## 3. What GoogleSQL's SQLBuilder does instead

Sources read: `zetasql/resolved_ast/sql_builder.{h,cc}` (6,095 lines) and
`query_expression.{h,cc}`, from the vendored go-zetasql tree at
`~/go/pkg/mod/github.com/goccy/go-zetasql@v0.5.5/internal/ccall/zetasql/`.

Note this is the **unanalyzer** (ResolvedAST → SQL), not the unparser
(`parser/unparser.cc`, parse tree → SQL). The unparser is irrelevant to us: we
never hold a parse tree. The unanalyzer solves exactly our problem, and reaches
one level per *query block*, not one per scan.

Three mechanisms do the work, and we have none of them.

### 3.1 `QueryExpression` — a partial SELECT with slot occupancy

`query_expression.h:30` is a mutable bag of clause slots (`select_list_`, `from_`,
`where_`, `group_by_list_`, `order_by_list_`, `limit_`, …). Every visitor calls
`TrySetX`, gated on a `CanSetX` predicate that encodes SQL's clause-ordering
rules (`query_expression.cc:312`):

```cpp
bool CanSetSelectClause()  { return !HasSelectClause() && !HasSetOpScanList(); }
bool CanSetFromClause()    { return !HasFromClause() && CanSetSelectClause(); }
bool CanSetWhereClause()   { return !HasWhereClause() && HasFromClause() && CanSetSelectClause(); }
bool CanSetGroupByClause() { return !HasGroupByClause() && HasFromClause() && CanSetSelectClause(); }
bool CanSetOrderByClause() { return !HasOrderByClause() && !HasLimitClause() && HasFromClause(); }
bool CanSetLimitClause()   { return !HasLimitClause() && !HasOffsetClause(); }
```

A new subquery level appears **only when the slot a scan needs is already
occupied** — `WrapQueryExpression` (`sql_builder.cc:1619`) fills the select list,
renders the block into `from_ = "(<sql>) AS alias"`, clears everything else, and
re-points the columns. Look at `VisitResolvedLimitOffsetScan` (`:2524`) or
`ProcessAggregateScanBase` (`:2703`): `if (!CanSetX) Wrap()`. That single line is
the whole difference from our unconditional wrap.

Note `CanSetWhereClause` requires the select list to be *free*. That is
deliberate: WHERE must not see select-list computations. It is also why the
FilterScan visitor carries an explicit escape hatch — for a plain table scan it
calls `ResetSelectClause()` (`:2209`) so the ProjectScan above can install its
select list without wrapping.

### 3.2 `pending_columns_` — computed columns that are never materialized

`sql_builder.h` keeps two column maps:

- `column_paths_`: column_id → a path string (`alias.col`), set on wrap by
  `SetPathForColumnList` (`:2391`).
- `pending_columns_`: column_id → **SQL text of the expression that computes it**.

`VisitResolvedColumnRef` (`:1100`) consults `pending_columns_` first:

```cpp
if (ContainsKey(pending_columns_, column.column_id()))
  PushQueryFragment(node, FindOrDie(pending_columns_, column.column_id()));
else
  PushQueryFragment(node, GetColumnPath(node->column()));
```

So a computed column can be *inlined at its use site* rather than projected. This
is why `VisitResolvedProjectScan` (`:1915`) costs no level: it just fills the
select slot of whatever block it sits on top of, and `GetSelectList` (`:1628`)
drains `pending_columns_` into that list. Aggregate outputs go into
`pending_columns_` too (`:2727`), but `ProcessAggregateScanBase` immediately
calls `AddSelectListIfNeeded` — aggregates are a hard materialization boundary.

### 3.3 `AddSelectListIfNeeded` — a select list only where one is needed

`sql_builder.cc:1710`: fill the select slot only `if (!CanFormSQLQuery())`, i.e.
only when the block is about to be closed and still has no projection. Our
`scan_table`, `scan_project`, `scan_orderby` and `scan_setop` all build a select
list unconditionally.

## 4. The proposed change

Change the scan contract from

```zig
fn transformScan(…) Error!*sqlbuilder.FromItem
```

to

```zig
fn transformScan(…) Error!*QueryExpr
```

where `QueryExpr` is the slot-occupancy struct above, plus `wrap(alloc, alias)`.
This is not a new pass; it is the same recursion with a wider return type, so the
"~9% of prepare for a new rewriting pass" bar from `sqlbuilder.zig`'s header does
not apply — there is no second pass and no SQL-level rewriting. The correctness
surface is the transformers themselves, which already have per-transformer tests
and the 748-case corpus behind them.

Two supporting changes:

- **`FragmentContext.pending`**: `AutoHashMap(i64, *SQLExpression)`, drained into
  the select list when a level is materialized. `column_ref.zig:23` becomes a
  two-line lookup — `pending` first, then `getQualifiedColumnExpression` — which
  is exactly `VisitResolvedColumnRef`.
- **`validateColumnData` is replaced.** Its current job (assert one select item
  per scan column with an ID-based alias) is the codification of the invariant
  being removed. The replacement invariant is weaker and still checkable: after
  each `transformScan`, every column in `scan_data.column_list` must be
  resolvable — present in `pending`, or in the current select list, or mapped by
  `column_id_to_scope`.

Per transformer:

| scan | today | with slots |
| --- | --- | --- |
| table | always a level | `from = tbl`; columns → `pending` as bare refs. **No level.** |
| project | always a level | computed columns → `pending`; fills the select slot if free. **No level in the common case.** |
| filter | always a level | `canSetWhere` → set WHERE in place. **No level.** |
| array (UNNEST) | always a level | `from` gets the unnest item; element/offset → `pending`. **No level.** |
| with_ref | always a level | `from = cte AS wrsN`; mapping → `pending`. **No level.** |
| aggregate | a level | sets GROUP BY in place when free, then **always** materializes the select list (aggregates cannot stay pending). Often −1 level. |
| analytic | a level | same as aggregate — window functions are a materialization boundary. |
| join | a level | `from = join`, select slot left free; each *operand* wraps (a join operand must be a table or subquery). −1 level per join. |
| order_by | a level | keep the unconditional wrap — GoogleSQL does too (`:2680`, "to avoid losing columns only used by order-by items"), and our `$orderby` column dropping depends on it. |
| limit | a level | `canSetLimit` is almost always true → merges downward. |
| set_op | **two** levels | one. The outer level exists only to re-alias branch columns to `name__id`; push those aliases into each branch's own select list instead (GoogleSQL: `SetAliasForSelectColumn`). |

## 5. Constraints GoogleSQL does not have

Its output is fed back to the *analyzer*. Ours is fed to SQLite for *execution*.
Three consequences that must be designed in from the start, not discovered later:

**(a) Inlining duplicates work.** GoogleSQL inlines a pending expression at every
use site without a thought. For us, `SELECT zetasqlite_regexp_extract(…) AS c__5`
referenced three times is one evaluation per row today and three after inlining —
and our UDFs are not cheap. **Gate inlining on use count**: inline only when the
column is referenced exactly once, or the expression is trivially cheap (column
ref, literal, parameter). Use counts are one `ResolvedColumnRef` tally per
column_id, cheapest to collect in the extractor pass that already walks every
node. This gate also covers non-deterministic functions (`RAND`,
`GENERATE_UUID`), and it is the single most important divergence from the
GoogleSQL algorithm.

**(b) Wrapping must flush `pending`.** When a level is materialized, its pending
columns become real select items and their entries move to `column_id_to_scope`.
Getting this wrong across a LEFT/FULL JOIN boundary silently changes NULL
semantics — an expression computed below a left join is not the same as the same
expression computed above it. Join operands materialize, which is what makes this
safe; the flush is what makes the materialization real.

**(c) Aggregate/analytic outputs never stay pending.** Otherwise a projection
above them inlines an aggregate into an outer aggregate.

Also note `scan_aggregate.zig:59-68` deliberately keeps two forms of each GROUP BY
expression — wrapped in `zetasqlite_group_by(...)` for the GROUP BY clause,
unwrapped for the select list. Whatever fills the select slot must keep using the
unwrapped form.

`flatten.zig` (`flattenSelectForRecursiveCTE`) exists because SQLite requires the
recursive reference at the top level of the recursive arm. With far fewer levels
emitted, it will need re-testing and may become redundant; do not delete it
speculatively.

## 5a. Result

This was executed; see [SLOT_MODEL_PLAN.md](SLOT_MODEL_PLAN.md) §5–7 for the
stage-by-stage record. Against the baseline measured above, at 746 PASS:

```
prepared SQL   535,820 B -> 355,065 B   (-33.7%)   643 -> 426 B per statement
SELECT levels      4,265 ->     2,543   (-40.4%)
pass-through       1,640 ->       734   (-55.2%)   38% -> 29% of levels
max paren depth       11 ->         8
```

`SELECT 1 AS x` now emits `SELECT 1 AS \`x\``. The measured shortfall is the
inlining gate: it ships as "cheap to duplicate" rather than the planned
reference count, which costs the single-use function call. §6 of the plan
records what finishing it takes.

## 6. Staging

Ordered by yield per unit of risk. Each stage is independently shippable and
gated on 746 PASS.

1. **Two isolated wins, no architecture change.** Verified below; ~3% of bytes
   plus a real planner effect, for two edits.
2. **Slot model for the pass-through scans** — table, filter, with_ref, array,
   and project *without* expression inlining (project still fills the select slot
   but stops emitting a level when the slot is free). This is where the 61%
   lives, and it needs no use-count analysis.
3. **Expression inlining with the use-count gate.** The remaining project levels,
   plus join and limit merging.
4. **Set-op single level.** Independent of 2 and 3.

## 7. Two findings that don't need any of the above

Both verified against the corpus at `-Drelease=true`.

### 7.1 Every CTE is forced `AS MATERIALIZED`

`sqlbuilder.zig:765` always writes `" AS MATERIALIZED \t("`, ignoring the
`materialized` field (`:747`) — a faithfully-ported Go quirk. Since SQLite 3.35
the default is already the right heuristic: materialize a CTE referenced more than
once, inline it otherwise. Forcing it removes SQLite's ability to push predicates
into a single-use CTE:

```
-- WITH c AS MATERIALIZED (SELECT a AS a1, b AS b1 FROM t) SELECT * FROM c WHERE a1 = 5
|--MATERIALIZE c
|  `--SCAN t
`--SCAN c

-- same, with plain AS (
`--SEARCH t USING INDEX ta (a=?)
```

A full scan plus a materialization, against an index seek. Changing it to `AS (`
gives **746 PASS / 0 FAIL / 2 SKIP** and 533,610 B. Corpus *timing* is unchanged
(88.6 / 90.1 / 90.9 ms vs 90.7 / 92.7 / 116.1 ms — noise): the corpus uses tiny
unindexed in-memory tables and cannot show this. The evidence for it is the plan,
and the workload it matters for is the view graph against real tables.

### 7.2 Every non-recursive CTE body carries a redundant `SELECT *`

`with_entry.zig:57-65` uses the transformed subquery's inner `SelectStatement`
directly for recursive CTEs, but wraps non-recursive ones in
`newSelectStarStatement`. The wrapper adds nothing — the inner SELECT already is
the CTE body, and its ID-based aliases are what the position mapping refers to.
Dropping the `is_recursive` condition so both paths take the direct branch gives
**746 PASS / 0 FAIL / 2 SKIP** and **519,865 B — 3.0% fewer bytes than baseline**,
from one line.

---

## Appendix — reproducing the measurements

```sh
zig build corpus -Drelease=true          # PASS counts + prepared-SQL bytes
./zig-out/bin/zetasqlite-zig --sql "…"   # emitted SQLite for one query
```

> `zig build corpus` has since been retired. Its 748 cases are
> `testdata/specs/zigquery/**`, so the equivalent today is
> `zig build spec -Drelease=true -- --filter zigquery/`. The PASS counts quoted
> above are the old runner's and do not reproduce verbatim; the prepared-SQL
> byte figures do.

Level counting and pass-through classification were done by tokenising the
`--sql` output with paren-depth tracking and testing each `SELECT` block for
own-level clauses; scan-kind counts come from the `AS \`<kind>_scan_<n>\`` aliases
the coordinator assigns.
