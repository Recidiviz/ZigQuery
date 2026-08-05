# Unsupported specs

What the GoogleSQL spec corpus asks for that this engine does not yet answer, grouped by
what it would take to answer it.

The corpus lives in `testdata/specs/**.zon`, imported from
[goccy/googlesqlite](https://github.com/goccy/googlesqlite) by `tools/spec_import.py`;
the expected values are the GoogleSQL reference docs' own published output. Run it with:

```
zig build spec                 # summary + baseline gate
zig build spec -- --verbose    # every non-passing case with its detection signal
zig build spec -- --markdown   # per-category coverage table
```

`unsupported` is **detected, not declared** (`harness/spec_runner.zig`, `classify`).
A case that dies with `error.Unimplemented`, the analyzer's "Function not found", a
registered name with no UDF, or a disabled grammar is counted `unsupported` rather than
`fail`; anything that runs and returns the wrong value is a `fail`. Nothing in the corpus
marks a case as missing, so implementing a function flips its spec to PASS with no file
edited. That is what keeps this a live ledger instead of a document that rots — but it
also means **the numbers below are a snapshot** of the tree at the commit this was
written against. Re-run the two commands above to refresh them.

## Summary

`zig build spec` on the current tree: **581 PASS / 0 FAIL / 400 UNSUPPORTED / 31 SKIP** (of 1012).

| Detection signal | Cases | Specs | Meaning |
|---|---:|---:|---|
| `no such function in the transformer` | 149 | 111 | Analyzer resolves it; no implementation on our side |
| `analyzer: function not found` | 137 | 80 | Rejected upstream — never reaches our code |
| `analyzer: syntax/feature disabled` | 64 | 40 | Grammar switched off in `shim/analyzer_shim.cc` |
| `analyzer: feature not supported` | 35 | 19 | Analyzer refuses the construct outright |
| `analyzer: type not found (proto)` | 8 | 5 | Proto descriptor plumbing |
| `no such AST node in the extractor` | 5 | 1 | Resolved node kind the extractor has no case for |
| `Unimplemented` | 2 | 2 | `error.Unimplemented` raised explicitly |
| **total** | **400** | **254** | |

| Area | Unsupported cases |
|---|---:|
| `googlesql/functions/geography` | 82 |
| `googlesql/functions/json` | 47 |
| `googlesql/syntax/pipe` | 27 |
| `bigquery/functions/time_series` | 22 |
| `googlesql/functions/string` | 20 |
| `googlesql/functions/aggregate/differential_privacy` | 19 |
| `bigquery/functions/aead` | 16 |
| `googlesql/syntax/script` | 16 |
| `googlesql/functions/array` | 15 |
| `googlesql/types` | 15 |
| `googlesql/functions/net` | 12 |
| `bigquery/functions/kll` | 11 |
| `bigquery/functions/search` | 10 |
| `bigquery/functions/text_analysis` | 10 |
| `googlesql/functions/proto` | 10 |
| `bigquery/functions/json` | 7 |
| `googlesql/functions/debug` | 7 |
| `bigquery/functions/geography` | 5 |
| `googlesql/functions/bit` | 5 |
| `googlesql/syntax/dml` | 5 |
| `bigquery/functions/objectref` | 4 |
| `bigquery/functions/utility` | 4 |
| `googlesql/functions/conversion` | 4 |
| `googlesql/syntax/ddl` | 4 |
| `bigquery/functions/dlp` | 3 |
| `googlesql/functions/hash` | 3 |
| `googlesql/functions/range` | 3 |
| `googlesql/functions/timestamp` | 3 |
| `googlesql/syntax/dcl` | 3 |
| `googlesql/functions/aggregate` | 2 |
| `googlesql/functions/window` | 2 |
| `googlesql/syntax/io` | 2 |
| `bigquery/functions/aggregate` | 1 |
| `bigquery/functions/vector` | 1 |

**254 specs carry at least one unsupported case; 248 of them have zero passing
cases.** This is not a tail of edge cases — it is whole functions that do not exist. The
6 partially-supported specs are the only places where the surface exists and the corpus
finds a hole in it:

| Spec | unsupported | passing | Signal |
|---|---:|---:|---|
| `googlesql/types/struct` | 10 | 22 | analyzer: feature not supported |
| `googlesql/functions/debug/error` | 7 | 2 | analyzer: function not found; analyzer: syntax/feature disabled |
| `googlesql/syntax/dml/merge` | 5 | 9 | no such AST node in the extractor |
| `googlesql/functions/range/range_sessionize` | 3 | 1 | analyzer: feature not supported |
| `googlesql/functions/net/net_parse_ip` | 1 | 1 | no such function in the transformer |
| `googlesql/functions/string/collate` | 1 | 1 | analyzer: function not found |

### The flag experiment

The two large buckets — "the analyzer won't resolve it" and "we never built it" — are
separable by experiment. Candidate `LanguageFeature` flags were added to
`kEnabledFeatures` in `shim/analyzer_shim.cc`, the shim rebuilt, the suite rerun, and
the change reverted:

```
before   581 PASS /  0 FAIL / 400 UNSUPPORTED / 31 SKIP
after    618 PASS / 18 FAIL / 345 UNSUPPORTED / 31 SKIP   (0 regressions)
```

Flags tried: `PIPES`, `PIPE_IF`, `UUID_TYPE`, `TYPEOF_FUNCTION`,
`TIME_BUCKET_FUNCTIONS`, `ARRAY_ZIP`, `GROUPING_BUILTIN`, `JSON_MUTATOR_FUNCTIONS`,
`JSON_CONTAINS_FUNCTION`, `JSON_KEYS_FUNCTION`, `JSON_FLATTEN_FUNCTION`,
`DIFFERENTIAL_PRIVACY`, `TOKENIZED_SEARCH`, `ENUM_VALUE_DESCRIPTOR_PROTO`, `KLL_WEIGHTS`.

Three flags from earlier rounds of this experiment — `CBRT_FUNCTIONS`, `PI_FUNCTIONS`
and `RANGE_TYPE` — are no longer listed because they have since been enabled for real;
see the changelog at the end.

The tiers below partition all 400 cases by what that experiment revealed, ordered by
cost to fix. Each case is listed under exactly one tier.

| Tier | Cases | What it takes |
|---|---:|---|
| [1](#tier-1) | 37 | Flag flip only — passes with no implementation |
| [2](#tier-2) | 18 | Flag admits it, then it breaks somewhere real |
| [3](#tier-3) | 52 | Flag unblocks the analyzer, implementation still owed |
| [4](#tier-4) | 149 | Implementation backlog — analyzer already resolves them |
| [5](#tier-5) | 83 | Still analyzer-blocked after the experiment |
| [6](#tier-6) | 35 | Analyzer refuses the construct |
| [7](#tier-7) | 11 | Scripting grammar — needs the script parser, not a flag |
| [8](#tier-8) | 15 | Proto descriptors, extractor nodes, explicit stubs |
| **total** | **400** | |

---

<a id="tier-1"></a>

## Tier 1 — passes with a flag flip, no implementation (37 cases)

These moved straight to PASS under the experiment with no other change. Pipe operators
resolve into the ordinary `ResolvedScan` tree the extractor already walks, which is why
the entire `syntax/pipe` directory comes free.

Flags responsible: `FEATURE_PIPES`, `FEATURE_PIPE_IF`, `FEATURE_TYPEOF_FUNCTION`.

**`bigquery/functions/utility/typeof`**
- NULL collapses to INT64 supertype
- floating-point literal reports DOUBLE
- integer literal reports INT64
- string literal reports STRING

**`googlesql/functions/debug/error`**
- run_else
- run_elseif
- run_if_with_elses
- run_no_case
- typeof_error_function
- unselected_cases_dont_run

**`googlesql/syntax/pipe/aggregate`**
- aggregate with GROUP BY
- count rows with no GROUP BY

**`googlesql/syntax/pipe/as`**
- AS names the table; columns are qualifiable

**`googlesql/syntax/pipe/distinct`**
- distinct collapses duplicate rows

**`googlesql/syntax/pipe/drop`**
- drop multiple columns
- drop one column

**`googlesql/syntax/pipe/except`**
- except distinct

**`googlesql/syntax/pipe/extend`**
- extend with a doubled column
- extend with multiple expressions

**`googlesql/syntax/pipe/intersect`**
- intersect distinct

**`googlesql/syntax/pipe/join`**
- inner join on equality
- left outer join keeps left-side row when no match

**`googlesql/syntax/pipe/limit`**
- limit caps the row count
- limit with offset skips initial rows

**`googlesql/syntax/pipe/order_by`**
- order ASC by default
- order DESC

**`googlesql/syntax/pipe/rename`**
- rename multiple columns
- rename single column

**`googlesql/syntax/pipe/select`**
- arithmetic expression in pipe SELECT
- project two columns in declared order
- rename single column via pipe SELECT

**`googlesql/syntax/pipe/set`**
- set two columns in one operator
- set updates an existing column

**`googlesql/syntax/pipe/union`**
- union all retains duplicates
- union distinct deduplicates

**`googlesql/syntax/pipe/where`**
- chained WHERE acts as AND
- filter integers above threshold

---

<a id="tier-2"></a>

## Tier 2 — flag admits them, then they break somewhere real (18 cases)

These stopped being `unsupported` and became `fail`: the analyzer accepted the SQL and
something downstream gave a wrong or missing answer. Each is a contained, diagnosable
bug rather than an absent feature. The failure detail is quoted under each case.

**`googlesql/functions/aggregate/differential_privacy/anon_avg`**
- upstream example 1 — ANON_AVG with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`
- upstream example 2 — ANON_AVG without noise
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`

**`googlesql/functions/aggregate/differential_privacy/anon_count`**
- upstream example 1 — ANON_COUNT(*) with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`
- upstream example 2 — ANON_COUNT(*) without noise
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`
- upstream example 3 — ANON_COUNT(item CLAMPED) with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`
- upstream example 4 — ANON_COUNT(item CLAMPED) without noise
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`

**`googlesql/functions/aggregate/differential_privacy/anon_percentile_cont`**
- upstream example 1 — ANON_PERCENTILE_CONT with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`

**`googlesql/functions/aggregate/differential_privacy/anon_quantiles`**
- upstream example 1 — ANON_QUANTILES with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`

**`googlesql/functions/aggregate/differential_privacy/anon_stddev_pop`**
- upstream example 1 — ANON_STDDEV_POP with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`

**`googlesql/functions/aggregate/differential_privacy/anon_sum`**
- upstream example 1 — ANON_SUM with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`
- upstream example 2 — ANON_SUM without noise
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`

**`googlesql/functions/aggregate/differential_privacy/anon_var_pop`**
- upstream example 1 — ANON_VAR_POP with noise (eps=10)
  - `AnalyzeFailed: Invalid identifier after SELECT WITH; expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]`

**`googlesql/functions/aggregate/grouping`**
- upstream example 1
  - `TransformFailed: ColumnNotFound`
- upstream example 2
  - `TransformFailed: ColumnNotFound`

**`googlesql/functions/array/array_zip`**
- upstream example 1
  - `row 0: got ([{1, a}, {2, b}])`
- upstream example 2
  - `row 0: got ([{1 A1, a alias_inferred}, {2 A1, b alias_inferred}])`
- upstream example 5
  - `row 0: got ([{1, a, NULL}, {2, b, NULL}, {NULL, c, NULL}, {NULL, d, NULL}])`
- upstream example 6
  - `row 0: got ([{1, a}, {2, b}])`

### Reading of this tier

- **`differential_privacy` (12 cases)** — the corpus writes `SELECT WITH ANONYMIZATION`;
  this googlesql revision requires `SELECT WITH DIFFERENTIAL_PRIVACY`, and
  `FEATURE_ANONYMIZATION` is marked `in_development` upstream. These assert a dead
  spelling — corpus staleness, not an engine gap, the same class as commit `5c72f80`
  ("Restate two spec cases that asserted things BigQuery does not do"). The other 7
  cases in that directory land one tier down on `no such AST node in the extractor`,
  which is the genuine gap behind them.
- **`array_zip` (4 cases)** — runs end to end; output differs only in struct field
  naming and `STRICT`/`PAD` mode length handling. The closest thing to a finished
  function anywhere in the unsupported set.
- **`range_sessionize` (4 cases)** — fails in *our* type deserializer with
  `Invalid TypeProto provided for deserialization: type_kind: TYPE_RANGE`. RANGE needs
  catalog-level type support before any RANGE function is worth writing.
- **`grouping` (2 cases)** — `TransformFailed: ColumnNotFound`, a contained extractor gap.

---

<a id="tier-3"></a>

## Tier 3 — flag unblocks the analyzer, implementation still owed (52 cases)

Cases whose detection signal *moved* under the experiment. Enabling the flag does not
fix them; it converts an upstream refusal into an honest to-do the suite will then
track. The dominant shift is `analyzer: function not found` →
`no such function in the transformer`; seven differential-privacy cases go from
`syntax/feature disabled` to `no such AST node in the extractor`.

### `bigquery/functions/time_series` (17 cases)

**`bigquery/functions/time_series/date_bucket`**
- NULL input propagates
- custom origin, 7-day buckets — at origin
- custom origin, 7-day buckets — before origin
- default origin 1950-01-01, 2-day buckets — aligned just below
- default origin 1950-01-01, 2-day buckets — at origin
- default origin 1950-01-01, 2-day buckets — before origin
- default origin 1950-01-01, 2-day buckets — third bucket

**`bigquery/functions/time_series/datetime_bucket`**
- NULL input propagates
- custom origin, 7-day bucket — at origin
- custom origin, 7-day bucket — before origin
- default origin 1950-01-01 00:00:00, 12-hour bucket — afternoon half
- default origin 1950-01-01 00:00:00, 12-hour bucket — at origin
- default origin 1950-01-01 00:00:00, 12-hour bucket — earlier half

**`bigquery/functions/time_series/timestamp_bucket`**
- NULL input propagates
- default origin 1950-01-01 00:00:00 UTC, 12-hour bucket — afternoon
- default origin 1950-01-01 00:00:00 UTC, 12-hour bucket — at origin
- default origin 1950-01-01 00:00:00 UTC, 12-hour bucket — before origin

### `googlesql/functions/json` (17 cases)

**`googlesql/functions/json/json_array_append`**
- append to top-level array

**`googlesql/functions/json/json_array_insert`**
- upstream example 1
- upstream example 2
- upstream example 3
- upstream example 4
- upstream example 5
- upstream example 6
- upstream example 7
- upstream example 8
- upstream example 9

**`googlesql/functions/json/json_contains`**
- missing key returns false
- object contains itself
- partial match returns true

**`googlesql/functions/json/json_flatten`**
- flatten one level of nesting

**`googlesql/functions/json/json_remove`**
- json_remove basic behaviour

**`googlesql/functions/json/json_set`**
- json_set basic behaviour

**`googlesql/functions/json/json_strip_nulls`**
- json_strip_nulls basic behaviour

### `googlesql/functions/aggregate/differential_privacy` (7 cases)

**`googlesql/functions/aggregate/differential_privacy/avg`**
- DP AVG over clamped values is the clamp value (with small noise)

**`googlesql/functions/aggregate/differential_privacy/count`**
- high-epsilon DP COUNT lands within 5 of the true count

**`googlesql/functions/aggregate/differential_privacy/percentile_cont`**
- upstream example 1 — DP PERCENTILE_CONT (privacy_unit_column=id) with noise
- upstream example 2 — DP PERCENTILE_CONT (view-level privacy unit) with noise

**`googlesql/functions/aggregate/differential_privacy/sum`**
- high-epsilon DP SUM lands within 5 of the true total

**`googlesql/functions/aggregate/differential_privacy/var_pop`**
- upstream example 1 — DP VAR_POP (privacy_unit_column=id) with noise
- upstream example 2 — DP VAR_POP (view-level privacy unit) with noise

### `bigquery/functions/json` (4 cases)

**`bigquery/functions/json/json_keys`**
- max_depth caps recursion
- nested keys flattened via dot notation
- strict mode skips array-nested keys
- top-level object keys

### `googlesql/functions/array` (2 cases)

**`googlesql/functions/array/array_zip`**
- upstream example 3
- upstream example 4

### `googlesql/functions/window` (2 cases)

**`googlesql/functions/window/is_first`**
- IS_FIRST returns BOOL via numbering rewrite

**`googlesql/functions/window/is_last`**
- IS_LAST returns BOOL via numbering rewrite

### `googlesql/functions/debug` (1 case)

**`googlesql/functions/debug/error`**
- assertion_succeeded_with_multiple_payloads

### `googlesql/functions/string` (1 case)

**`googlesql/functions/string/regexp_extract_groups`**
- upstream example 10

### `googlesql/types` (1 case)

**`googlesql/types/uuid`**
- upstream example 1

---

<a id="tier-4"></a>

## Tier 4 — implementation backlog, analyzer already resolves them (149 cases)

`no such function in the transformer` on the current tree, no flag needed. The analyzer
hands us a resolved call and the dispatch map has no entry. This is the pure
"write the function" pile, and it is where the mass sits — geography alone is more than
half of it.

### `googlesql/functions/geography` (82 cases)

**`googlesql/functions/geography/s2_cellidfrompoint`**
- level-10 cell-id is non-zero

**`googlesql/functions/geography/s2_coveringcellids`**
- upstream example 1

**`googlesql/functions/geography/st_angle`**
- upstream example 1

**`googlesql/functions/geography/st_area`**
- 1x1 polygon area in km^2 around 12000

**`googlesql/functions/geography/st_asbinary`**
- WKB encoding of POINT(0 0)

**`googlesql/functions/geography/st_asgeojson`**
- Point GeoJSON

**`googlesql/functions/geography/st_askml`**
- Point KML

**`googlesql/functions/geography/st_astext`**
- format a point as WKT

**`googlesql/functions/geography/st_azimuth`**
- northward bearing is 0 radians

**`googlesql/functions/geography/st_boundary`**
- boundary of two-point linestring

**`googlesql/functions/geography/st_boundingbox`**
- upstream example 1

**`googlesql/functions/geography/st_buffer`**
- upstream example 1

**`googlesql/functions/geography/st_bufferwithtolerance`**
- upstream example 1

**`googlesql/functions/geography/st_centroid`**
- centroid of single point

**`googlesql/functions/geography/st_closestpoint`**
- closest point of single-point geometry

**`googlesql/functions/geography/st_clusterdbscan`**
- upstream example 1

**`googlesql/functions/geography/st_contains`**
- Polygon contains interior point

**`googlesql/functions/geography/st_convexhull`**
- triangle hull from 3 points

**`googlesql/functions/geography/st_coveredby`**
- Point is covered by polygon

**`googlesql/functions/geography/st_covers`**
- Polygon covers point

**`googlesql/functions/geography/st_difference`**
- upstream example 1

**`googlesql/functions/geography/st_dimension`**
- LineString -> 1
- Point -> 0
- Polygon -> 2

**`googlesql/functions/geography/st_disjoint`**
- Disjoint points

**`googlesql/functions/geography/st_distance`**
- distance between coincident points is 0

**`googlesql/functions/geography/st_dump`**
- upstream example 1
- upstream example 2

**`googlesql/functions/geography/st_dumppoints`**
- upstream example 1

**`googlesql/functions/geography/st_dwithin`**
- coincident points are within 1m

**`googlesql/functions/geography/st_endpoint`**
- Last vertex of linestring

**`googlesql/functions/geography/st_equals`**
- a point equals itself

**`googlesql/functions/geography/st_extent`**
- upstream example 1

**`googlesql/functions/geography/st_exteriorring`**
- polygon outer ring as linestring

**`googlesql/functions/geography/st_geogfrom`**
- dispatch to GeoJSON

**`googlesql/functions/geography/st_geogfromgeojson`**
- Roundtrip via GeoJSON

**`googlesql/functions/geography/st_geogfromkml`**
- KML Point round-trip to WKT POINT

**`googlesql/functions/geography/st_geogfromtext`**
- parse WKT and format back

**`googlesql/functions/geography/st_geogfromwkb`**
- upstream example 1

**`googlesql/functions/geography/st_geogpoint`**
- construct a POINT from lon/lat

**`googlesql/functions/geography/st_geogpointfromgeohash`**
- roundtrip via geohash

**`googlesql/functions/geography/st_geohash`**
- equator-origin precision-6 starts with 's' or '7'

**`googlesql/functions/geography/st_geometrytype`**
- Polygon type string

**`googlesql/functions/geography/st_hausdorffdistance`**
- upstream example 1
- upstream example 2
- upstream example 3

**`googlesql/functions/geography/st_hausdorffdwithin`**
- upstream example 1

**`googlesql/functions/geography/st_interiorrings`**
- upstream example 1

**`googlesql/functions/geography/st_intersection`**
- disjoint points -> NULL

**`googlesql/functions/geography/st_intersects`**
- coincident points intersect

**`googlesql/functions/geography/st_intersectsbox`**
- point inside box
- point outside box

**`googlesql/functions/geography/st_isclosed`**
- closed linestring
- open linestring

**`googlesql/functions/geography/st_iscollection`**
- MULTIPOINT is a collection
- POINT is not

**`googlesql/functions/geography/st_isempty`**
- Non-empty linestring

**`googlesql/functions/geography/st_isring`**
- simple ring

**`googlesql/functions/geography/st_length`**
- 1-degree linestring at equator

**`googlesql/functions/geography/st_lineinterpolatepoint`**
- midpoint of equator segment

**`googlesql/functions/geography/st_linelocatepoint`**
- upstream example 1

**`googlesql/functions/geography/st_linesubstring`**
- upstream example 1
- upstream example 2

**`googlesql/functions/geography/st_makeline`**
- Two points to LineString

**`googlesql/functions/geography/st_makepolygon`**
- Build polygon from outer ring

**`googlesql/functions/geography/st_makepolygonoriented`**
- simple ring constructs a polygon

**`googlesql/functions/geography/st_maxdistance`**
- max distance between two points

**`googlesql/functions/geography/st_npoints`**
- LineString npoints

**`googlesql/functions/geography/st_numgeometries`**
- Multi-point with 4 parts
- Single POINT returns 1

**`googlesql/functions/geography/st_numpoints`**
- 3-point linestring

**`googlesql/functions/geography/st_perimeter`**
- 1x1 polygon perimeter is roughly 4*111km

**`googlesql/functions/geography/st_pointn`**
- Middle vertex

**`googlesql/functions/geography/st_simplify`**
- collapse near-collinear midpoint

**`googlesql/functions/geography/st_snaptogrid`**
- snap to 0.1 grid

**`googlesql/functions/geography/st_startpoint`**
- First vertex of linestring

**`googlesql/functions/geography/st_touches`**
- line touches its endpoint

**`googlesql/functions/geography/st_union`**
- union of two distinct points

**`googlesql/functions/geography/st_union_agg`**
- upstream example 1

**`googlesql/functions/geography/st_within`**
- Point within polygon

**`googlesql/functions/geography/st_x`**
- ST_X returns the longitude component of a POINT

**`googlesql/functions/geography/st_y`**
- ST_Y returns the latitude component of a POINT

### `googlesql/functions/string` (18 cases)

**`googlesql/functions/string/edit_distance`**
- edit_distance basic behaviour

**`googlesql/functions/string/regexp_extract_groups`**
- upstream example 1
- upstream example 11
- upstream example 12
- upstream example 2
- upstream example 3
- upstream example 4
- upstream example 5
- upstream example 6
- upstream example 7
- upstream example 8
- upstream example 9

**`googlesql/functions/string/regexp_match`**
- no match
- null propagation
- simple match

**`googlesql/functions/string/split_substr`**
- take first part
- take last part with negative index
- take second part

### `googlesql/functions/net` (12 cases)

**`googlesql/functions/net/net_format_ip`**
- format 0 as 0.0.0.0
- format 16909060 as 1.2.3.4

**`googlesql/functions/net/net_format_packed_ip`**
- ipv4 high-bit address
- round-trip via IP_FROM_STRING

**`googlesql/functions/net/net_ip_in_net`**
- IP inside the network
- IP outside the network

**`googlesql/functions/net/net_make_net`**
- basic IPv4 prefix
- host-level IPv4
- zero-prefix anywhere-net

**`googlesql/functions/net/net_parse_ip`**
- null propagates through PARSE_IP

**`googlesql/functions/net/net_parse_packed_ip`**
- round-trip via IP_TO_STRING
- zero address round-trip

### `bigquery/functions/kll` (6 cases)

**`bigquery/functions/kll/kll_quantiles_extract_int64`**
- kll_quantiles_extract_int64 basic pipeline

**`bigquery/functions/kll/kll_quantiles_extract_point_int64`**
- kll_quantiles_extract_point_int64 basic pipeline

**`bigquery/functions/kll/kll_quantiles_init_int64`**
- kll_quantiles_init_int64 basic pipeline

**`bigquery/functions/kll/kll_quantiles_merge_int64`**
- merge_int64 returns ARRAY of quantiles

**`bigquery/functions/kll/kll_quantiles_merge_partial`**
- kll_quantiles_merge_partial runs end-to-end

**`bigquery/functions/kll/kll_quantiles_merge_point_int64`**
- kll_quantiles_merge_point_int64 runs end-to-end

### `googlesql/functions/json` (6 cases)

**`googlesql/functions/json/json_array`**
- build a heterogeneous JSON array

**`googlesql/functions/json/json_object`**
- build a single-key JSON object

**`googlesql/functions/json/lax_bool`**
- lax_bool basic behaviour

**`googlesql/functions/json/lax_double`**
- lax_double basic behaviour

**`googlesql/functions/json/lax_int64`**
- lax_int64 basic behaviour

**`googlesql/functions/json/lax_string`**
- lax_string basic behaviour

### `bigquery/functions/geography` (5 cases)

**`bigquery/functions/geography/st_centroid_agg`**
- NULLs in input are skipped
- centroid of three points
- centroid of two points
- linestring centroid is the length-weighted midpoint
- square polygon centroid is the area-weighted centre

### `googlesql/functions/bit` (5 cases)

**`googlesql/functions/bit/bit_cast_to_int32`**
- positive round-trip

**`googlesql/functions/bit/bit_cast_to_int64`**
- nested round-trip with UINT64
- positive round-trip

**`googlesql/functions/bit/bit_cast_to_uint32`**
- positive round-trip

**`googlesql/functions/bit/bit_cast_to_uint64`**
- positive value passes through

### `googlesql/functions/conversion` (4 cases)

**`googlesql/functions/conversion/bit_cast_to_int32`**
- bit-cast preserves int width 32 cycle

**`googlesql/functions/conversion/bit_cast_to_int64`**
- bit-cast a positive int64 is identity

**`googlesql/functions/conversion/bit_cast_to_uint32`**
- bit-cast unsigned 32 round-trip

**`googlesql/functions/conversion/bit_cast_to_uint64`**
- bit-cast unsigned 64 round-trip

### `bigquery/functions/json` (3 cases)

**`bigquery/functions/json/lax_float64`**
- integer string coerces to FLOAT64
- non-numeric input returns NULL (lax)
- numeric value passes through

### `googlesql/functions/timestamp` (3 cases)

**`googlesql/functions/timestamp/timestamp_from_unix_micros`**
- upstream example 1

**`googlesql/functions/timestamp/timestamp_from_unix_millis`**
- upstream example 1

**`googlesql/functions/timestamp/timestamp_from_unix_seconds`**
- round-trip via UNIX_SECONDS

### `googlesql/functions/array` (2 cases)

**`googlesql/functions/array/array_is_distinct`**
- distinct array returns true
- duplicate elements return false

### `googlesql/functions/proto` (2 cases)

**`googlesql/functions/proto/from_proto`**
- upstream example 2

**`googlesql/functions/proto/to_proto`**
- upstream example 1

### `googlesql/types` (1 case)

**`googlesql/types/geography`**
- round-trip point through WKT

---

<a id="tier-5"></a>

## Tier 5 — still analyzer-blocked after the experiment (83 cases)

`analyzer: function not found` persisted with the candidate flags on. Each needs a
different flag, a catalog registration, or is absent from this googlesql revision
entirely — establish which before estimating implementation cost.

### `googlesql/functions/json` (24 cases)

**`googlesql/functions/json/bool_array`**
- bool_array extracts a typed array

**`googlesql/functions/json/double_array`**
- double_array extracts a typed array

**`googlesql/functions/json/float`**
- float basic conversion

**`googlesql/functions/json/float_array`**
- float_array extracts a typed array

**`googlesql/functions/json/int32`**
- int32 basic conversion

**`googlesql/functions/json/int32_array`**
- int32_array extracts a typed array

**`googlesql/functions/json/int64_array`**
- int64_array extracts a typed array

**`googlesql/functions/json/lax_bool_array`**
- lax_bool_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/lax_double_array`**
- lax_double_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/lax_float`**
- lax_float basic conversion

**`googlesql/functions/json/lax_float_array`**
- lax_float_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/lax_int32`**
- lax_int32 basic conversion

**`googlesql/functions/json/lax_int32_array`**
- lax_int32_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/lax_int64_array`**
- lax_int64_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/lax_string_array`**
- lax_string_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/lax_uint32`**
- lax_uint32 basic conversion

**`googlesql/functions/json/lax_uint32_array`**
- lax_uint32_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/lax_uint64`**
- lax_uint64 basic conversion

**`googlesql/functions/json/lax_uint64_array`**
- lax_uint64_array extracts a typed array with NULLs on bad elements

**`googlesql/functions/json/string_array`**
- string_array extracts a typed array

**`googlesql/functions/json/uint32`**
- uint32 basic conversion

**`googlesql/functions/json/uint32_array`**
- uint32_array extracts a typed array

**`googlesql/functions/json/uint64`**
- uint64 basic conversion

**`googlesql/functions/json/uint64_array`**
- uint64_array extracts a typed array

### `bigquery/functions/aead` (16 cases)

**`bigquery/functions/aead/aead_decrypt_bytes`**
- AEAD round-trip recovers plaintext BYTES

**`bigquery/functions/aead/aead_decrypt_string`**
- AEAD round-trip recovers plaintext STRING

**`bigquery/functions/aead/aead_encrypt`**
- encrypt + decrypt round-trip

**`bigquery/functions/aead/deterministic_decrypt_bytes`**
- deterministic AEAD round-trip recovers plaintext BYTES

**`bigquery/functions/aead/deterministic_decrypt_string`**
- deterministic AEAD round-trip recovers plaintext STRING

**`bigquery/functions/aead/deterministic_encrypt`**
- deterministic encrypt is reproducible

**`bigquery/functions/aead/keys_add_key_from_raw_bytes`**
- appending a raw 16-byte AES_GCM key produces non-NULL keyset

**`bigquery/functions/aead/keys_keyset_chain`**
- chain with literal wrapped keyset is non-NULL

**`bigquery/functions/aead/keys_keyset_from_json`**
- JSON->keyset round-trip is non-NULL

**`bigquery/functions/aead/keys_keyset_length`**
- freshly created keyset has length 1

**`bigquery/functions/aead/keys_keyset_to_json`**
- JSON form mentions algorithm field

**`bigquery/functions/aead/keys_new_keyset`**
- returns a non-empty keyset BYTES payload

**`bigquery/functions/aead/keys_new_wrapped_keyset`**
- wrapped keyset is non-empty

**`bigquery/functions/aead/keys_rewrap_keyset`**
- rewrapped keyset is non-empty

**`bigquery/functions/aead/keys_rotate_keyset`**
- rotated keyset is non-NULL

**`bigquery/functions/aead/keys_rotate_wrapped_keyset`**
- rotated wrapped keyset is non-empty

### `bigquery/functions/search` (10 cases)

**`bigquery/functions/search/search`**
- ARRAY<STRING> input tokenises every element
- JSON input scans values by default
- NO_OP_ANALYZER keeps original case + spaces
- NULL data is treated as no tokens
- STRUCT input flattens every string field
- case-insensitive match via LOG_ANALYZER normalisation
- every query token present in data
- json_scope JSON_KEYS scans keys only
- missing query token
- partial match — one query term missing returns FALSE

### `bigquery/functions/text_analysis` (10 cases)

**`bigquery/functions/text_analysis/bag_of_words`**
- NULL input propagates
- counts each distinct term and sorts by term
- distinct terms preserved, count reflects multiplicity

**`bigquery/functions/text_analysis/text_analyze`**
- CJK characters become per-character tokens
- LOG_ANALYZER drops punctuation and keeps digits
- LOG_ANALYZER lowercases and splits on punctuation/whitespace
- NO_OP_ANALYZER preserves the entire input verbatim
- NULL input propagates
- mixed CJK and Latin

**`bigquery/functions/text_analysis/tf_idf`**
- three-document corpus emits per-row scores sorted by score desc

### `bigquery/functions/kll` (5 cases)

**`bigquery/functions/kll/kll_quantiles_extract_float64`**
- kll_quantiles_extract_float64 basic pipeline

**`bigquery/functions/kll/kll_quantiles_extract_point_float64`**
- kll_quantiles_extract_point_float64 basic pipeline

**`bigquery/functions/kll/kll_quantiles_init_float64`**
- kll_quantiles_init_float64 basic pipeline

**`bigquery/functions/kll/kll_quantiles_merge_float64`**
- merge_float64 returns ARRAY of quantiles

**`bigquery/functions/kll/kll_quantiles_merge_point_float64`**
- kll_quantiles_merge_point_float64 runs end-to-end

### `googlesql/functions/array` (5 cases)

**`googlesql/functions/array/array_avg`**
- array_avg basic input

**`googlesql/functions/array/array_sum`**
- array_sum basic input

**`googlesql/functions/array/flatten`**
- upstream example 1
- upstream example 2
- upstream example 3

### `bigquery/functions/objectref` (4 cases)

**`bigquery/functions/objectref/obj_fetch_metadata`**
- metadata JSON exposes content_type

**`bigquery/functions/objectref/obj_get_access_url`**
- stub access URL has expected prefix

**`bigquery/functions/objectref/obj_get_read_url`**
- stub read URL has expected prefix

**`bigquery/functions/objectref/obj_make_ref`**
- make ref from URI

### `bigquery/functions/dlp` (3 cases)

**`bigquery/functions/dlp/dlp_deterministic_decrypt`**
- round-trip recovers plaintext STRING

**`bigquery/functions/dlp/dlp_deterministic_encrypt`**
- DLP encrypt + decrypt round-trip

**`bigquery/functions/dlp/dlp_key_chain`**
- chain with literal wrapped keyset is non-NULL

### `googlesql/functions/hash` (3 cases)

**`googlesql/functions/hash/highway_fingerprint128`**
- deterministic for the same input
- distinct outputs for distinct inputs
- returns 16-byte BYTES

### `googlesql/functions/proto` (2 cases)

**`googlesql/functions/proto/proto_default_if_null`**
- PROTO_DEFAULT_IF_NULL returns the set field value
- PROTO_DEFAULT_IF_NULL with explicit field access for each component

### `googlesql/functions/string` (1 case)

**`googlesql/functions/string/collate`**
- upstream example 1

---

<a id="tier-6"></a>

## Tier 6 — analyzer refuses the construct (35 cases)

`analyzer: feature not supported`. The message is the analyzer's own — "RANGE type is
not supported", "Table-valued functions are not supported", "Statement not supported:
GrantStatement". These are language constructs rather than functions, so each is its
own project.

### `googlesql/types` (11 cases)

**`googlesql/types/graph_element`**
- upstream example 1

**`googlesql/types/struct`**
- struct field plus positional accessor mixed
- struct multiple anonymous fields positional
- struct multiple fields named and positional
- struct positional accessor double via WITH
- struct positional accessor offset 0 double
- struct positional accessor offset 1 bool
- struct positional accessor on null struct
- struct positional accessor ordinal 1 double
- struct positional accessor ordinal 2 bool
- struct same name fields positional access

### `bigquery/functions/time_series` (5 cases)

**`bigquery/functions/time_series/appends`**
- APPENDS lowers to an empty subquery

**`bigquery/functions/time_series/changes`**
- CHANGES lowers to an empty subquery

**`bigquery/functions/time_series/gap_fill`**
- LOCF carries the previous non-null value across a gap
- linear interpolation fills the gap with the midpoint
- null fill leaves the gap as NULL

### `googlesql/syntax/script` (4 cases)

**`googlesql/syntax/script/assert`**
- ASSERT TRUE executes silently
- ASSERT with AS message clause

**`googlesql/syntax/script/execute_immediate`**
- EXECUTE IMMEDIATE with a literal string is accepted

**`googlesql/syntax/script/set`**
- SET @@system_variable to a literal succeeds

### `googlesql/functions/range` (3 cases)

**`googlesql/functions/range/range_sessionize`**
- upstream example 2
- upstream example 3
- upstream example 4

### `googlesql/syntax/dcl` (3 cases)

**`googlesql/syntax/dcl/grant`**
- GRANT SELECT on a table to a user
- GRANT multiple privileges to a group

**`googlesql/syntax/dcl/revoke`**
- REVOKE SELECT removes a previously granted privilege

### `googlesql/syntax/ddl` (3 cases)

**`googlesql/syntax/ddl/alter_table`**
- ALTER TABLE ADD COLUMN is accepted by the analyzer

**`googlesql/syntax/ddl/create_schema`**
- CREATE SCHEMA executes without error
- CREATE SCHEMA with OPTIONS executes without error

### `googlesql/functions/array` (2 cases)

**`googlesql/functions/array/array_filter`**
- ARRAY_FILTER keeps elements matching the lambda

**`googlesql/functions/array/array_transform`**
- ARRAY_TRANSFORM doubles each element via lambda

### `googlesql/syntax/io` (2 cases)

**`googlesql/syntax/io/export_data`**
- EXPORT DATA OPTIONS(...) AS SELECT writes to the URI and yields no rows

**`googlesql/syntax/io/load_data`**
- LOAD DATA INTO ... FROM FILES (...) executes as a no-op

### `bigquery/functions/aggregate` (1 case)

**`bigquery/functions/aggregate/agg`**
- AGG over a SUM measure returns the underlying aggregate

### `bigquery/functions/vector` (1 case)

**`bigquery/functions/vector/vector_index_statistics`**
- VECTOR_INDEX.STATISTICS lowers to an empty subquery

---

<a id="tier-7"></a>

## Tier 7 — scripting grammar (11 cases)

`analyzer: syntax/feature disabled`, still disabled after the experiment. Procedural
GoogleSQL (`LOOP`/`WHILE`/`REPEAT`/`RETURN`/`DECLARE`/`FOR IN`) is not a bit on
`LanguageOptions`: it needs the script parser (`ParseScript`) rather than the
single-statement analyzer the shim calls. That is an architectural change to
`shim/analyzer_shim.cc`, not a feature flip.

**`googlesql/syntax/script/break`**
- BREAK exits the innermost LOOP

**`googlesql/syntax/script/case_stmt`**
- CASE statement chooses first matching WHEN

**`googlesql/syntax/script/continue`**
- CONTINUE returns to the top of the loop

**`googlesql/syntax/script/declare`**
- DECLARE with default value is visible in a SELECT

**`googlesql/syntax/script/for_in`**
- FOR ... IN over a subquery

**`googlesql/syntax/script/if_stmt`**
- IF without ELSE

**`googlesql/syntax/script/loop_stmt`**
- LOOP with immediate BREAK

**`googlesql/syntax/script/raise`**
- RAISE USING MESSAGE accepts a message

**`googlesql/syntax/script/repeat_stmt`**
- REPEAT body runs at least once

**`googlesql/syntax/script/return`**
- RETURN exits the current script

**`googlesql/syntax/script/while_stmt`**
- WHILE with immediate BREAK

---

<a id="tier-8"></a>

## Tier 8 — proto descriptors, extractor nodes, explicit stubs (15 cases)


### `analyzer: type not found (proto)` (8 cases)

The driver has no `RegisterProto`; see also the 11 skipped `register_protos` cases in the appendix.

**`googlesql/functions/proto/enum_value_descriptor_proto`**
- upstream example 1

**`googlesql/functions/proto/extract`**
- EXTRACT(FIELD(...) FROM proto) reads a primitive field
- EXTRACT(FIELD(...) FROM proto) returns each field independently
- EXTRACT(HAS(...) FROM proto) reports presence of a set field

**`googlesql/functions/proto/from_proto`**
- upstream example 1

**`googlesql/functions/proto/to_proto`**
- upstream example 2

**`googlesql/types/protocol_buffer`**
- upstream example 1
- upstream example 2

### `no such AST node in the extractor` (5 cases)

MERGE otherwise works — 9 cases in this spec pass. These five hit a sub-node the extractor has no arm for.

**`googlesql/syntax/dml/merge`**
- MERGE ON FALSE — REPLACE idiom (constant-false-predicate)
- MERGE ON FALSE — bulk INSERT leaves existing target rows intact
- MERGE ON TRUE — every target row updated against the single source row
- MERGE on a multi-equality ON predicate
- MERGE on a non-equality ON predicate

### `Unimplemented` (2 cases)

**`googlesql/syntax/ddl/create_procedure`**
- CREATE PROCEDURE accepts a procedure body

**`googlesql/syntax/script/call_stmt`**
- CALL invokes a registered procedure

---

## Appendix — the 31 declared skips

`skip` is declared in the corpus, unlike `unsupported`. These say the spec does not
describe this engine's surface, so they are not backlog.


**11 cases** — register_protos: the driver has no RegisterProto

- `googlesql/functions/proto/filter_fields` — upstream example 1 — read back two rows
- `googlesql/functions/proto/filter_fields` — upstream example 2 — keep year only
- `googlesql/functions/proto/filter_fields` — upstream example 3 — drop type
- `googlesql/functions/proto/filter_fields` — upstream example 4 — keep year + type.award_name
- `googlesql/functions/proto/filter_fields` — upstream example 5 — keep year + type but drop type.award_name
- `googlesql/functions/proto/filter_fields` — upstream example 6 — RESET_CLEARED_REQUIRED_FIELDS keeps month only
- `googlesql/functions/proto/proto_map_contains_key` — upstream example 1
- `googlesql/functions/proto/proto_modify_map` — upstream example 1
- `googlesql/functions/proto/replace_fields` — upstream example 1 — replace title + nested details.chapters
- `googlesql/functions/proto/replace_fields` — upstream example 2 — replace repeated reviews
- `googlesql/functions/proto/replace_fields` — upstream example 3 — clear details by setting NULL

**7 cases** — BigQuery has no IFERROR: "Function not found: IFERROR". These examples come from GoogleSQL's debugging_functions.md, which documents the language, not the BigQuery surface this engine emulates. ERROR() itself does exist and is supported.

- `googlesql/functions/debug/iferror` — upstream example 1
- `googlesql/functions/debug/iferror` — upstream example 2
- `googlesql/functions/debug/iferror` — upstream example 3
- `googlesql/functions/debug/iferror` — upstream example 4
- `googlesql/functions/debug/iferror` — upstream example 5
- `googlesql/functions/debug/iferror` — upstream example 6
- `googlesql/functions/debug/iferror` — upstream example 7

**7 cases** — BigQuery has no ISERROR: "Function not found: ISERROR". These examples come from GoogleSQL's debugging_functions.md, which documents the language, not the BigQuery surface this engine emulates. ERROR() itself does exist and is supported.

- `googlesql/functions/debug/iserror` — upstream example 1
- `googlesql/functions/debug/iserror` — upstream example 2
- `googlesql/functions/debug/iserror` — upstream example 3
- `googlesql/functions/debug/iserror` — upstream example 4
- `googlesql/functions/debug/iserror` — upstream example 5
- `googlesql/functions/debug/iserror` — upstream example 6
- `googlesql/functions/debug/iserror` — upstream example 7

**5 cases** — BigQuery has no NULLIFERROR: "Function not found: NULLIFERROR". These examples come from GoogleSQL's debugging_functions.md, which documents the language, not the BigQuery surface this engine emulates. ERROR() itself does exist and is supported.

- `googlesql/functions/debug/nulliferror` — upstream example 1
- `googlesql/functions/debug/nulliferror` — upstream example 2
- `googlesql/functions/debug/nulliferror` — upstream example 3
- `googlesql/functions/debug/nulliferror` — upstream example 4
- `googlesql/functions/debug/nulliferror` — upstream example 5

**1 case** — asserts the sketch's bytes, which are a different algorithm here: this engine ports go-zetasqlite's murmur3 + DataDog go-hll storage format, BigQuery emits a HyperLogLogPlusUniqueStateProto over its own hash. Both agree on what the sketch is for — see the cardinality case below, and note that GoogleSQL's own conformance suite (compliance/testdata/hll_count.test) only ever asserts IS NOT NULL or EXTRACT, never the bytes.

- `googlesql/functions/hll/hll_count_merge_partial` — upstream example 1

---

## Changelog

Newest first. Each entry is a block that left this ledger.

### The RANGE type, 26 cases

`googlesql/types/range` is 2/2 and `googlesql/functions/range` is 24/27; the three that
remain are `RANGE_SESSIONIZE` examples 2-4. RANGE landed as a real value kind rather than
a struct or string shim, following INTERVAL and NUMERIC:

- **`Value.range`** — `{elem, has_start, has_end, start, end}` in `value.zig`. The bounds
  are flags beside plain `i64`s rather than `?i64`, which is not a style choice: two
  optionals make `Range` 40 bytes, past `Interval`'s 28, and every `Value` in the engine
  would have grown from 32 bytes to 48. Accessors hand back `?i64` anyway.
- **Both codecs.** RANGE is orderable (`Type::SupportsOrdering` excludes only GEOGRAPHY
  and TOKENLIST), so it has a memcomparable encoding at tag `0x80`; it is also nested
  inside the `ARRAY<RANGE<T>>` that `GENERATE_RANGE_ARRAY` returns, so it has a
  self-delimiting one at `0x10`. It is the only kind that needs both. Taking `0x10` meant
  widening the codec discriminator from `0x10` to `codec_sortable.tag_min`.
- **`catalog.zig`** now emits `rangeType.elementType`. googlesql's `ValidateTypeProto`
  accepts a `TYPE_RANGE` only when the proto carries that submessage, and the bare kind we
  used to write failed on the statement *after* the `CREATE TABLE`, because the whole
  catalog is re-parsed per analyze.
- **`FEATURE_RANGE_TYPE` was enabled last, deliberately.** It gates the DDL, the literals
  and the builtins but not the deserializer, so turning it on before the catalog fix would
  have let a poisoned catalog row get written — strictly worse than the analyzer refusing
  the DDL outright.

Three things worth carrying forward:

- **An absent bound is an infinity, and which one depends on the end it sits at.** An
  unbounded start is -inf, an unbounded end is +inf. So the sortable encoding's two
  presence bytes are *inverted* relative to each other, and `IsEndLessThan` is not
  `IsStartLessThan` with the arguments swapped. Reading both as one "is present" flag
  silently mis-sorts `[x, UNBOUNDED)`; the all-pairs test in `codec_sortable.zig` is what
  holds the byte layout and `compareOp` to the same order.
- **A month step clamps, it does not normalise.** `GENERATE_RANGE_ARRAY` steps with
  `date_ops.dateAdd`, where Jan 31 + 1 month is Feb 28; `value.addCalendar`, which the `+`
  operator uses, would give Mar 3. googlesql also recomputes from the original start every
  iteration rather than accumulating. No spec case covers this — the corpus only steps by
  days — so it has a unit test instead.
- **`RANGE(NULL, NULL)` has no recoverable element type** and raises `Unimplemented`
  rather than guessing DATE. The analyzer rejects two NULL literals, so only two NULL
  columns can reach it.

### The math family, 25 cases

Every unsupported case under `googlesql/functions/math` is implemented; that directory
reports `78 PASS / 0 UNSUPPORTED`. The work split three ways:

- *Handler only* — `ACOS`, `ACOSH`, `ASIN`, `ASINH`, `ATANH`, `COSH`, `SINH`, `TANH`,
  `RAND`, `RANGE_BUCKET`. The names were already in the extractor's list.
- *Extractor name plus handler* — `COT`, `COTH`, `CSC`, `CSCH`, `SEC`, `SECH`,
  `COSINE_DISTANCE`, `EUCLIDEAN_DISTANCE`.
- *Flag* — `FEATURE_CBRT_FUNCTIONS` and `FEATURE_PI_FUNCTIONS`. `PI` needed no
  implementation at all: its signatures carry `SetDefinitionForInlining`, so the analyzer
  folds it to a literal.

Two lessons that generalise:

- The domain rules in the reference docs' per-function tables are one rule, not many.
  `googlesql/public/functions/math.h` applies `CheckFloatingPointError`: a non-finite
  result is an error only when the argument was finite. Read the header before
  hand-writing range checks from the tables.
- **NaN does not survive a function boundary here.** `sqlite3_result_double()` turns a NaN
  into SQL NULL, so any spec case whose expected value is NaN reads as NULL, and any
  handler branch testing a scalar argument for NaN is unreachable. Inf round-trips.

