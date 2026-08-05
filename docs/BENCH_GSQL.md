# Benchmark — zetasqlite-zig on the googlesqlite corpus

The 22-query benchmark corpus from
[goccy/googlesqlite](https://github.com/goccy/googlesqlite/tree/main/bench),
run against this engine.

```sh
zig build gsql-bench -Drelease=true                          # the table below
zig build gsql-bench -Drelease=true -- --phases              # + where each query's time went
zig build gsql-bench -Drelease=true -- --markdown --phases   # this document's tables
```

The `.sql` files under `testdata/bench_corpus/` are vendored verbatim from
upstream, so both suites analyze and execute the same GoogleSQL. The runner is
`harness/gsql_bench.zig`.

## What the two columns mean

Upstream prepares each query once and re-runs it, scanning every row per
iteration. Neither of this driver's entry points is exactly that, so the run
reports both and upstream's number sits between them:

| column | what runs per iteration | vs upstream |
|--------|-------------------------|-------------|
| `full` | `Db.query()` — analyze, transform, `sqlite3_prepare`, step, decode | more work: upstream re-analyzes nothing |
| `prep` | `PreparedStmt.exec()` — bind and step, statement compiled once | less work: `exec` discards rows, upstream scans them |

So `prep ≤ upstream-equivalent ≤ full`, and the gap between the columns is what
statement caching is worth on this engine.

`allocs/op` and `B/op` count calls into and bytes requested from the allocator
handed to the driver. They are **not** upstream's Go figures: a query here is
served from an arena, so one op is a few large chunk requests where Go's
allocator sees every object. Compare them against another run of this harness,
never against upstream's `B/op`.

## Results

Apple M4 Pro, macOS 26.5.2, Zig 0.16.0, SQLite 3.51.0, `-Drelease=true`
(ReleaseFast), 2026-07-30. One-time analyzer/shim initialisation, measured as
open + first query: **28.5 ms**, paid once per process before the corpus runs
and excluded from every number below.

### Window

| Query | full ns/op | prep ns/op | rows | B/op | allocs/op |
|-------|-----------|-----------|------|------|-----------|
| array_agg_window | 275,774 | 158,151 | 200 | 197,938 | 39 |
| lag_lead | 1,335,756 | 1,056,132 | 1000 | 973,036 | 98 |
| rank_dense_rank | 6,523,234 | 6,154,037 | 1000 | 25,612,276 | 5074 |
| row_number_partition | 636,264 | 465,925 | 1000 | 149,260 | 47 |
| sum_running_total | 4,792,493 | 4,249,856 | 2000 | 10,413,072 | 129 |

### Aggregate

| Query | full ns/op | prep ns/op | rows | B/op | allocs/op |
|-------|-----------|-----------|------|------|-----------|
| group_by_partition | 229,612 | 150,002 | 10 | 209,230 | 135 |
| sum_1k | 191,504 | 115,245 | 1 | 465,368 | 36 |

### Scalar

| Query | full ns/op | prep ns/op | rows | B/op | allocs/op |
|-------|-----------|-----------|------|------|-----------|
| concat_strings | 41,431 | 418 | 1 | 11,140 | 5 |
| select_constant | 25,020 | 128 | 1 | 6,078 | 5 |
| upper_string | 35,300 | 421 | 1 | 11,242 | 5 |

### Mixed

| Query | full ns/op | prep ns/op | rows | B/op | allocs/op |
|-------|-----------|-----------|------|------|-----------|
| cte_session_funnel | 1,582,741 | 1,149,663 | 1 | 2,721,396 | 1435 |
| filtered_lookup | 641,333 | 543,625 | 100 | 47,610 | 6 |
| information_schema_columns | — | — | — | — | — |
| json_extract_pipeline | 1,736,809 | 1,467,012 | 6 | 207,864 | 84 |
| priced_orders_report | 624,336 | 271,789 | 0 | 187,304 | 6 |
| struct_array_unnest | 1,104,668 | 952,878 | 50 | 426,846 | 1511 |
| wildcard_table_scan | — | — | — | — | — |

### Tpch_like

| Query | full ns/op | prep ns/op | rows | B/op | allocs/op |
|-------|-----------|-----------|------|------|-----------|
| q1_lineitem_pricing_summary | 4,543,742 | 4,099,357 | 6 | 4,640,138 | 480 |
| q14_promo_revenue | 882,135 | 584,752 | 1 | 135,346 | 21 |
| q3_shipping_priority | 3,288,220 | 2,940,654 | 10 | 179,716 | 425 |
| q5_local_supplier | 1,870,650 | 1,433,854 | 0 | 164,342 | 6 |
| q6_forecast_revenue | 1,002,944 | 864,892 | 1 | 93,156 | 14 |

`priced_orders_report` and `q5_local_supplier` return no rows. That is a
property of upstream's generated data, not a defect: every `orders.placed_at`
in the first falls before the query's `2024-02-01` cutoff, and in the second no
`lineitem` row satisfies `s.s_nationkey = c.c_nationkey` for any of the 3,000
generated rows. Both still do the full join and aggregate work.

## Not run

Two queries need catalog objects the engine does not synthesize on its own.
Both are BigQuery surface features that live in the emulator layer upstream, so
this is a scope boundary rather than a missing translation:

- `mixed/information_schema_columns` — `Table not found: ds.INFORMATION_SCHEMA.COLUMNS`.
  The engine has no INFORMATION_SCHEMA views.
- `mixed/wildcard_table_scan` — ``Table not found: `proj.ds.events_*` ``. The
  transformer handles `_TABLE_SUFFIX` synthetic columns
  (`src/internal/transformer/scan_table.zig`), but nothing registers a wildcard
  table in the catalog for the pattern to resolve against.

They are kept in the corpus and reported as not-run rather than deleted, so the
suite doubles as a coverage signal against upstream.

## Where `full` goes

Milliseconds per op, from the counters in `src/internal/phase.zig`. They do not
sum to `full`: decoding rows and the driver's own bookkeeping sit outside every
phase, in `other`.

| Query | analyze | transform | sqlite-prepare | step | other | full |
|-------|--------:|----------:|---------------:|-----:|------:|-----:|
| window/array_agg_window | 0.0677 | 0.0023 | 0.0137 | 0.1567 | 0.0353 | 0.2758 |
| window/lag_lead | 0.1025 | 0.0043 | 0.0251 | 1.0596 | 0.1442 | 1.3358 |
| window/rank_dense_rank | 0.1563 | 0.0087 | 0.0362 | 6.1707 | 0.1513 | 6.5232 |
| window/row_number_partition | 0.0605 | 0.0026 | 0.0139 | 0.4580 | 0.1014 | 0.6363 |
| window/sum_running_total | 0.1367 | 0.0066 | 0.0248 | 4.3740 | 0.2505 | 4.7925 |
| aggregate/group_by_partition | 0.0670 | 0.0023 | 0.0084 | 0.1495 | 0.0025 | 0.2296 |
| aggregate/sum_1k | 0.0729 | 0.0019 | 0.0051 | 0.1103 | 0.0012 | 0.1915 |
| scalar/concat_strings | 0.0362 | 0.0009 | 0.0031 | 0.0005 | 0.0008 | 0.0414 |
| scalar/select_constant | 0.0229 | 0.0005 | 0.0010 | 0.0001 | 0.0004 | 0.0250 |
| scalar/upper_string | 0.0305 | 0.0008 | 0.0028 | 0.0006 | 0.0007 | 0.0353 |
| mixed/cte_session_funnel | 0.3631 | 0.0154 | 0.0296 | 1.1635 | 0.0112 | 1.5827 |
| mixed/filtered_lookup | 0.0762 | 0.0027 | 0.0101 | 0.5322 | 0.0202 | 0.6413 |
| mixed/json_extract_pipeline | 0.1916 | 0.0108 | 0.0239 | 1.4941 | 0.0163 | 1.7368 |
| mixed/priced_orders_report | 0.2785 | 0.0191 | 0.0482 | 0.2676 | 0.0109 | 0.6243 |
| mixed/struct_array_unnest | 0.1112 | 0.0082 | 0.0199 | 0.9543 | 0.0111 | 1.1047 |
| tpch_like/q1_lineitem_pricing_summary | 0.3595 | 0.0155 | 0.0323 | 4.1226 | 0.0139 | 4.5437 |
| tpch_like/q14_promo_revenue | 0.2711 | 0.0065 | 0.0190 | 0.5794 | 0.0061 | 0.8821 |
| tpch_like/q3_shipping_priority | 0.2598 | 0.0121 | 0.0381 | 2.9674 | 0.0109 | 3.2882 |
| tpch_like/q5_local_supplier | 0.3155 | 0.0218 | 0.0701 | 1.4511 | 0.0122 | 1.8707 |
| tpch_like/q6_forecast_revenue | 0.1302 | 0.0026 | 0.0071 | 0.8612 | 0.0018 | 1.0029 |

`step` is nearly all of `full` for anything that touches rows; analysis is a
fixed ~0.02–0.36 ms floor per statement. That is the argument for statement
caching in the server: analysis is the only phase a cache removes, and it is
decisive for scalar-shaped queries and noise for anything that scans.

## Cross-engine comparison

A consolidated view against goccy/bigquery-emulator v0.6.6, recidiviz/
bigquery-emulator (cgo), goccy/bigquery-emulator v0.7.0 (wasm) and
goccy/googlesqlite v0.3.1 lives in `docs/bench_report.html` — open it in a
browser, or read the published copy at
<https://claude.ai/code/artifact/fe09c294-1f5a-4369-b58c-064ba06598ab>.

It pools this harness's output with the January 2026 emulator survey and
upstream's own published RESULTS.md. Those are **three different measurement
contexts** — different machines, harnesses and layers of the stack — so the
report is an order-of-magnitude signal, not a controlled head-to-head. Read
its methodology panel before quoting any ratio.
