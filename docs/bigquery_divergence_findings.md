# BigQuery divergence findings

Where this engine answers differently from BigQuery, found by running the
`zigquery` spec corpus against the real service rather than against the
reference docs. That distinction is the point of this file: the docs are wrong
often enough that three entries below contradict what a careful reading of them
would predict, and two of them are pinned into spec expectations, so the suite
is green *because* it asserts the divergent answer.

Scope. `NUMERIC_FIDELITY.md` owns the two decimal types. `SPEC_UNSUPPORTED.md`
owns what the imported `googlesql/**` and `bigquery/**` trees ask for and this
engine does not answer. This file owns everything else the engine answers
*differently*, and only where a real BigQuery run says so.

## How to add an entry

`tools/vsbq.py` runs a spec file's queries both ways and diffs them, issuing the
BigQuery side concurrently through the Python client — 43 cases take ~7s:

```sh
zig build -Drelease=true
uv run tools/vsbq.py --jobs 12 testdata/specs/zigquery/functions/window/*.zon
uv run tools/vsbq.py --quiet  testdata/specs/zigquery/**/*.zon   # divergences only
```

It reports three kinds of difference separately from real ones, each a property
of the comparison rather than of the engine: an anonymous column is `$col1` here
and `f0_` there, a query with no top-level `ORDER BY` has no guaranteed row order
either side, and BigQuery renders TIMESTAMP as text where the CLI prints epoch
seconds. Exit status is 1 when a real divergence is found.

BigQuery's own result cache is asked for and its hits are reported, so a repeat
run says how much of itself it re-executed. It saves execution, not the round
trip.

Record the pair, and the project and date it was measured on — a service's
behaviour is dated in a way a doc is not.

## Open divergences

### Zoneless TIMESTAMP literals resolve in America/Los_Angeles, not UTC

*(recidiviz-rnd-planner, 2026-08-08)*

| | ours | BigQuery |
|---|---|---|
| `UNIX_SECONDS(TIMESTAMP '2016-10-18 2:51:45')` | 1476784305 | **1476759105** |
| `... '2016-10-18 2:51:45+00'` | 1476759105 | 1476759105 |
| `... '2016-10-18 2:51:45 UTC'` | 1476759105 | 1476759105 |

Exactly the PDT offset for that date. Only the zoneless form differs, and the
`TZ` environment variable does not move it, so the zone is coming from the
engine rather than the host.

**Pinned:** `zigquery/functions/window/dense_rank.zon` asserts `"1476784305.0"`,
the engine's answer. Reach is 10 zoneless literals across 2 spec files.

### DATETIME subtraction is not normalised into days

*(recidiviz-rnd-planner, 2026-08-08)*

`DATETIME "2021-06-01 12:34:56.789" - DATETIME "2021-05-31 00:00:00"` gives
`0-0 0 36:34:56.789` here and `0-0 1 12:34:56.789` there. The same elapsed time,
carried differently: BigQuery normalises a DATETIME difference into days, and a
TIMESTAMP difference into hours. The TIMESTAMP half of the same case agrees.

**Pinned:** `zigquery/types/interval.zon`.

### DATE and DATETIME are not peers under ORDER BY

*(recidiviz-rnd-planner, 2026-08-08)*

`DENSE_RANK() OVER (ORDER BY dt)` over `DATE '2024-01-01'` and
`DATETIME '2024-01-01'` ranks them 1 and 2; BigQuery coerces and ranks both 1.

**Already recorded:** the case is `.skip`ped in
`zigquery/functions/window/dense_rank.zon` with the upstream `go-googlesql`
cause in its comment. Listed here so the three date/time entries sit together.

## Over-acceptance

Queries BigQuery refuses and this engine answers. Harmless to a working query,
but it means a spec case can assert a value for SQL that would not run.

| query | BigQuery |
|---|---|
| `STRING_AGG(DISTINCT x) OVER ()` | `Analytic function string_agg does not support DISTINCT.` |
| `ARRAY_AGG(x IGNORE NULLS) OVER ()` | `Analytic function array_agg does not support IGNORE NULLS or RESPECT NULLS.` |

Per-function, not a blanket rule: `MIN`, `SUM` and `COUNT` all take
`DISTINCT ... OVER ()` and agree with this engine on the result.

## Coverage

What has actually been compared, so the next reader knows what a green suite
does and does not vouch for.

| tree | state |
|---|---|
| `zigquery/**`, all 944 cases | swept; 781 agree, 94 rejected by both, 21 differ only in client rendering, 5 row-order only, 13 one-sided errors, 30 flagged |
| `googlesql/**`, `bigquery/**` | not compared |

Of the 30 flagged, 8 are a clock or the environment (`CURRENT_*`, `SESSION_USER`,
`GENERATE_UUID`, HLL sketch bytes) and are not divergences. **The remaining 22 are
candidates, not findings.** Only the three recorded above have been confirmed
case by case; the rest have not been read individually and must not be quoted as
divergences until they are.

That caution is not boilerplate. The first sweep reported 110 differences and
every class examined turned out to be the comparator's, not the engine's:

| what the tool did | what it manufactured |
|---|---|
| rewrote ISO datetime text to epoch seconds | ~40, across `datetime/**` |
| guessed a container from `[...]`-shaped text, so `FORMAT("[%'d]", 1000)` read as a two-element array | 16, the whole `format` file, which in fact agrees exactly |
| sorted STRUCT fields on one side only | `group by struct values` |
| canonicalised `''` to NULL, split nested containers on commas | `split`, `to_json`, `parse_json` |

Each was found by checking a flagged case by hand and finding the engine right.
`ltrim` is still flagged and its CLI output is provably well-formed, so at least
one class remains. Treat a flag as a question.

## Corrected, for the record

Answers that were wrong and no longer are, so nobody re-derives them. All were
found by reading rather than by a BigQuery run, except where noted.

- `1 IN (1, NULL)` returned NULL; `5 BETWEEN 10 AND NULL` returned NULL.
- All four `IS [NOT] TRUE|FALSE` forms returned NULL for a NULL operand.
- `MIN`/`SUM` with `DISTINCT ... OVER ()` failed outright on a frame containing
  a NULL.
- `COUNT(DISTINCT x)` over `[0.0, -0.0]` answered 2, disagreeing with this
  engine's own `GROUP BY` and `SELECT DISTINCT`.
- `GROUP BY` over an ARRAY or STRUCT joined elements with `"||"`, so `['a||b']`
  and `['a', 'b']` shared a group. Confirmed against BigQuery before the fix.
