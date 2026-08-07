# Unsupported specs

What the GoogleSQL spec corpus asks for that this engine does not yet answer, grouped by
what it would take to answer it.

This ledger covers the two imported trees, `testdata/specs/googlesql/**` and
`testdata/specs/bigquery/**`, brought over from
[goccy/googlesqlite](https://github.com/goccy/googlesqlite) by `tools/spec_import.py`;
their expected values are the GoogleSQL reference docs' own published output, which is
what makes an unanswered case a statement about the *language* rather than about this
engine's own history. The third tree, `testdata/specs/zigquery/**`, is that history —
this engine's regression suite — and contributes no `unsupported` cases at all, so it is
out of scope here. Run it with:

```
zig build spec                                  # summary + baseline gate
zig build spec -- --verbose                     # every non-passing case with its signal
zig build spec -- --markdown                    # per-category coverage table
zig build spec -- --dialect googlesql --verbose # just the tree this ledger covers
```

`unsupported` is **detected, not declared** (`harness/spec_runner.zig`, `classify`).
A case that dies with `error.Unimplemented`, the analyzer's "Function not found", a
registered name with no UDF, or a disabled grammar is counted `unsupported` rather than
`fail`; anything that runs and returns the wrong value is a `fail`. Nothing in the corpus
marks a case as missing, so implementing a function flips its spec to PASS with no file
edited. That is what keeps this a live ledger instead of a document that rots — but it
also means **the numbers below are a snapshot** of the tree at the commit this was
written against. Re-run the two commands above to refresh them.

One thing the ledger cannot see is in the next section but one: a case that **passes on
a wrong answer** is invisible here by construction, because the corpus asserts what
GoogleSQL documents and this engine emulates BigQuery. Those have to be found by
measurement, not by running the suite.

## Summary

`zig build spec` over the imported trees when this was written: **730 PASS / 0 FAIL /
251 UNSUPPORTED / 31 SKIP** (of 1012). They stand at 749 / 0 / 232 / 31 today; the tier
tables below have not been re-derived since, so read them as the shape of the gap rather
than as a current count.

| Detection signal | Cases | Specs | Meaning |
|---|---:|---:|---|
| `no such function in the transformer` | 122 | 92 | Analyzer resolves it; no implementation on our side |
| `analyzer: function not found` | 60 | 39 | Rejected upstream — never reaches our code |
| `analyzer: syntax/feature disabled` | 30 | 23 | Grammar switched off in `shim/analyzer_shim.cc` |
| `analyzer: feature not supported` | 24 | 17 | Analyzer refuses the construct outright |
| `analyzer: type not found (proto)` | 8 | 5 | Proto descriptor plumbing |
| `no such AST node in the extractor` | 5 | 1 | Resolved node kind the extractor has no case for |
| `Unimplemented` | 2 | 2 | `error.Unimplemented` raised explicitly |
| **total** | **251** | **177** | |

| Area | Unsupported cases |
|---|---:|
| `googlesql/functions/geography` | 82 |
| `googlesql/functions/string` | 20 |
| `googlesql/functions/aggregate/differential_privacy` | 19 |
| `bigquery/functions/aead` | 16 |
| `googlesql/syntax/script` | 16 |
| `bigquery/functions/kll` | 11 |
| `bigquery/functions/search` | 10 |
| `bigquery/functions/text_analysis` | 10 |
| `googlesql/functions/proto` | 10 |
| `googlesql/functions/array` | 7 |
| `bigquery/functions/geography` | 5 |
| `bigquery/functions/time_series` | 5 |
| `googlesql/syntax/dml` | 5 |
| `googlesql/types` | 5 |
| `bigquery/functions/objectref` | 4 |
| `googlesql/syntax/ddl` | 4 |
| `bigquery/functions/dlp` | 3 |
| `googlesql/functions/hash` | 3 |
| `googlesql/functions/range` | 3 |
| `googlesql/functions/timestamp` | 3 |
| `googlesql/syntax/dcl` | 3 |
| `googlesql/functions/window` | 2 |
| `googlesql/syntax/io` | 2 |
| `bigquery/functions/aggregate` | 1 |
| `bigquery/functions/vector` | 1 |
| `googlesql/functions/debug` | 1 |

**177 specs carry at least one unsupported case; 173 of them have zero passing cases.**
This is not a tail of edge cases — it is whole functions that do not exist. The 4
partially-supported specs are the only places where the surface exists and the corpus
finds a hole in it:

| Spec | unsupported | passing | Signal |
|---|---:|---:|---|
| `googlesql/syntax/dml/merge` | 5 | 9 | no such AST node in the extractor |
| `googlesql/functions/range/range_sessionize` | 3 | 1 | analyzer: feature not supported |
| `googlesql/functions/debug/error` | 1 | 8 | analyzer: feature not supported |
| `googlesql/functions/string/collate` | 1 | 1 | analyzer: function not found |

`googlesql/types/struct` and `googlesql/functions/net/net_parse_ip` were on this list at
the last snapshot and have left it; see the changelog.

---

## Wrong answer, not a missing one

Three divergences that the suite cannot detect, all found by measuring against real
BigQuery (bq CLI, 2026-08-04) rather than by running the corpus. They are listed here
because they are the class that matters most for an emulator and they have no other home
in this document: every one of them is currently **green**.

**1. `TYPEOF` reports internal type names.** `SELECT TYPEOF(1.0)` answers `DOUBLE` here
and `FLOAT64` in BigQuery. The bigquery-dialect case
`bigquery/functions/utility/typeof :: floating-point literal reports DOUBLE` asserts
`DOUBLE`, so the suite is green on an answer BigQuery does not give.

**2. `PRODUCT_INTERNAL` leaks GoogleSQL-only aliases.** `DOUBLE` and `LAX_DOUBLE` are
PRODUCT_INTERNAL aliases of `FLOAT64` / `LAX_FLOAT64`
(`builtin_function_internal_3.cc:1659,1702`). BigQuery rejects both spellings; this
engine accepts them. The alias resolves to the same `Function`, so the extractor cannot
tell the two apart and no per-function fix exists.

The obvious remedy was measured rather than assumed: flipping `analyzer_shim.cc:256` to
`PRODUCT_EXTERNAL` and rebuilding takes the suite **730 → 650**. It does fix TYPEOF and
does drop `DOUBLE`/`LAX_DOUBLE` — and it also removes the entire `NET.*` namespace,
including `NET.IP_IN_NET`, which BigQuery has, plus `BIT_CAST_TO_INT64/UINT64`. Trading
over-acceptance for under-acceptance is the worse deal, so PRODUCT_INTERNAL stays and
the leak is recorded here instead.

**3. `PARSE_JSON` and `TO_JSON` preserve insertion order; BigQuery sorts object keys.**
`TO_JSON_STRING(PARSE_JSON('{"b":1,"a":2}'))` is `{"b":1,"a":2}` here and
`{"a":2,"b":1}` there. JSON *literals* already agree, because the analyzer normalizes
them before the engine sees them — which is why nothing caught this. Everything the JSON
family now *constructs* (the constructors, the mutators, `JSON_KEYS`) sorts its own
output, so those agree with BigQuery; the two entry points that copy a document through
do not. Fixing it means editing 6 goccy-derived corpus expectations (`to_json` /
`to_json_string`, `{"id":1,"coordinates":[10,20]}`), which is a policy change: the
corpus has never been edited away from goccy.

**4. Fifteen date/time behaviours that have since been fixed.** Found by pointing
`zig build coverage-spec` at the five date/time files and reading every line the suite
never executed. Thirteen `FORMAT_*` elements and one `_TRUNC` ladder were answering
something other than what `third_party/googlesql/docs/format-elements.md` documents,
none of them exercised by any case:

| | was | now |
|---|---|---|
| `%e` | `05` (zero-padded) | `" 5"` |
| `%j` | `5` | `005` |
| `%u` `%w` | the ISO **week** number | the weekday, Mon=1..7 and Sun=0..6 |
| `%U` `%W` | the ISO week number | weeks from the year's first Sunday / Monday |
| `%V` | `1` | `01` |
| `%g` | `2022` | `22` |
| `%I` `%l` | the raw hour, and `hour % 12` | the 12-hour clock, `12` at both 0 and 12 |
| `%Q` | day-of-year thresholds, so Q2 for 2024-03-30 | the quarter of the month |
| `%z` | `32400` | `+0900` |
| `TIME_TRUNC` / `DATETIME_TRUNC` / `TIMESTAMP_TRUNC` at MILLISECOND, SECOND | each dropped the unit it was named for, so MILLISECOND meant SECOND and SECOND meant MINUTE | keeps it |
| `LAST_DAY(d, WEEK(<day>))` | overshot by a week whenever the date fell on or before the start day | wraps |
| `LAST_DAY(d, ISOWEEK)` | Sunday-start weeks | Monday-start, as ISO defines |

They are recorded here rather than only in the changelog because they are the clearest
evidence for what this section is *for*: every one of them was green, and stayed green,
for as long as nothing ran the line. The cases that now pin them are in
`testdata/specs/zigquery/functions/{date,datetime,time,timestamp}`.

Still outstanding in the same area, all currently green on an answer BigQuery does not
give:

- **`CURRENT_DATE(zone)` ignores both the zone and the injected clock.**
  `src/internal/transformer/function.zig` appends the deterministic-now literal *after*
  the call's own arguments, so `fn_date.nowCiv` sees the zone string in `args[0]`, fails
  its `args[0] == .int` test, and reads the wall clock. Same for `CURRENT_TIME(zone)` and
  `CURRENT_DATETIME(zone)`. No spec case can pin this until it is fixed — the result is
  not reproducible — so it is covered by a unit test that asserts only the range.
- **`TIME(TIME)`, `DATETIME(DATETIME)`, `TIMESTAMP(TIMESTAMP)` raise.**
  `FEATURE_DATE_TIME_CONSTRUCTORS` is enabled, so the analyzer admits the identity forms;
  BigQuery returns the value unchanged and this engine answers "invalid first argument
  type". Pinned as `.expect_error` cases.
- **`STRING(JSON)` renders any scalar.** `STRING(JSON 'true')` is `"true"` here; BigQuery
  restricts the function to JSON strings and errors otherwise.
- **`%r` and the `%O*` elements are unimplemented**, and rejected with "unexpected format
  type". Documented; not built.
- **`parseSecondPrecision` ignores its precision argument**, so `%E1S`…`%E6S` all consume
  whatever fraction is present. `PARSE_DATETIME("…%E3S", "…30.123456")` reads six digits.
- **The FORMAT side does no per-type gating at all.** `formatElement` discards its `typ`
  parameter, so `FORMAT_TIME('%A', TIME '09:20:30')` answers `Thursday` — the weekday of
  the epoch — where `format-elements.md` lists `%A` as DATE/DATETIME/TIMESTAMP only. The
  PARSE side *does* gate, which is why `PARSE_DATE('%H', '10')` is an error. Same class
  of over-acceptance as `PRODUCT_INTERNAL` above.
- **`LAST_DAY(d, ISOYEAR)` returns the calendar year end.** It shares the `YEAR` arm, so
  2024 ends `2024-12-31` where the ISO year 2024 ends `2024-12-29`.
- **`tp.message` is never cleared.** `bind.clearDiagnostics()` resets `bind.message` but
  not `time_parser`'s threadlocal, so a stale parser message from an earlier query can be
  attached to a later unrelated error.

---

### The flag experiment

The two large buckets — "the analyzer won't resolve it" and "we never built it" — are
separable by experiment. Candidate `LanguageFeature` flags were added to
`kEnabledFeatures` in `shim/analyzer_shim.cc`, the shim rebuilt, the suite rerun, and the
change reverted:

```
before   730 PASS /  0 FAIL / 251 UNSUPPORTED / 31 SKIP
after    732 PASS / 12 FAIL / 237 UNSUPPORTED / 31 SKIP   (0 regressions)
```

Flags tried: `DIFFERENTIAL_PRIVACY`, `TOKENIZED_SEARCH`, `KLL_WEIGHTS`, `UUID_TYPE`,
`ENUM_VALUE_DESCRIPTOR_PROTO`, `PROTO_DEFAULT_IF_NULL`, `ARRAY_AGGREGATION_FUNCTIONS`,
`ARRAY_FIND_FUNCTIONS`, `ANNOTATION_FRAMEWORK`, `COLLATION_SUPPORT`.

**What moved nothing is as informative as what did.** `TOKENIZED_SEARCH` (SEARCH,
TEXT_ANALYZE, BAG_OF_WORDS, TF_IDF — 21 cases), `KLL_WEIGHTS` (the 5 FLOAT64 KLL cases)
and `ENUM_VALUE_DESCRIPTOR_PROTO` left every case exactly where it was: those names are
absent from this googlesql revision's catalog, not merely gated, so no flag reaches them.

Flags enabled for real since the last snapshot — `PIPES`, `TYPEOF_FUNCTION`,
`GROUPING_BUILTIN`, `TIME_BUCKET_FUNCTIONS`, `STRUCT_POSITIONAL_ACCESSOR`,
`JSON_MUTATOR_FUNCTIONS`, `JSON_KEYS_FUNCTION`, `JSON_FLATTEN_FUNCTION` — are no longer
in the candidate list; see the changelog. `ARRAY_ZIP`, `INLINE_LAMBDA_ARGUMENT`,
`PIPE_IF` and `JSON_CONTAINS_FUNCTION` are also gone from it, for the opposite reason:
they were tried, they worked, and they were reverted because BigQuery does not have what
they enable.

The tiers below partition all 251 cases by what that experiment revealed, ordered by cost
to fix. Each case is listed under exactly one tier.

| Tier | Cases | What it takes |
|---|---:|---|
| [1](#tier-1) | 6 | Nothing — GoogleSQL-only; restate as a refusal |
| [2](#tier-2) | 12 | Flag admits it, then the corpus itself is stale |
| [3](#tier-3) | 10 | Flag unblocks the analyzer, implementation still owed |
| [4](#tier-4) | 122 | Implementation backlog — analyzer already resolves them |
| [5](#tier-5) | 51 | Still analyzer-blocked after the experiment |
| [6](#tier-6) | 24 | Analyzer refuses the construct |
| [7](#tier-7) | 11 | Scripting grammar — needs the script parser, not a flag |
| [8](#tier-8) | 15 | Proto descriptors, extractor nodes, explicit stubs |
| **total** | **251** | |

---

<a id="tier-1"></a>

## Tier 1 — GoogleSQL-only; the work is to refuse them (6 cases)

These would pass, or nearly, on a flag flip. `ARRAY_AGGREGATION_FUNCTIONS` moves
`ARRAY_SUM` and `ARRAY_AVG` straight to PASS; `ARRAY_FIND_FUNCTIONS` reaches `FLATTEN`;
`UUID_TYPE` reaches `NEW_UUID`. Checked against real BigQuery, all four names are absent:

```
Function not found: ARRAY_SUM
Function not found: ARRAY_AVG; Did you mean array_agg?
Function not found: FLATTEN
Type not found: UUID                      -- and NEW_UUID with it; BigQuery's
                                             GENERATE_UUID() returns a STRING
```

So the work here is not implementation, it is the `.expect_error` restatement that
`array_zip`, `array_transform` and the json families already got — the cheapest six cases
in this document, and the ones that stop the ledger from reading them as backlog.

**`googlesql/functions/array/array_avg`**
- array_avg basic input

**`googlesql/functions/array/array_sum`**
- array_sum basic input

**`googlesql/functions/array/flatten`**
- upstream example 1
- upstream example 2
- upstream example 3

**`googlesql/types/uuid`**
- upstream example 1

---

<a id="tier-2"></a>

## Tier 2 — flag admits it, then the corpus itself is stale (12 cases)

These stopped being `unsupported` and became `fail` under the experiment, all with the
same message:

```
AnalyzeFailed: Invalid identifier after SELECT WITH;
               expected DIFFERENTIAL_PRIVACY but got: ANONYMIZATION [at 2:8]
```

The corpus writes `SELECT WITH ANONYMIZATION`; this googlesql revision requires
`SELECT WITH DIFFERENTIAL_PRIVACY`, and `FEATURE_ANONYMIZATION` is marked
`in_development` upstream. These assert a dead spelling — corpus staleness, not an engine
gap, the same class as commit `5c72f80` ("Restate two spec cases that asserted things
BigQuery does not do"). The genuine gap behind the directory is one tier down.

**`googlesql/functions/aggregate/differential_privacy/anon_avg`**
- upstream example 1 — ANON_AVG with noise (eps=10)
- upstream example 2 — ANON_AVG without noise

**`googlesql/functions/aggregate/differential_privacy/anon_count`**
- upstream example 1 — ANON_COUNT(*) with noise (eps=10)
- upstream example 2 — ANON_COUNT(*) without noise
- upstream example 3 — ANON_COUNT(item CLAMPED) with noise (eps=10)
- upstream example 4 — ANON_COUNT(item CLAMPED) without noise

**`googlesql/functions/aggregate/differential_privacy/anon_percentile_cont`**
- upstream example 1 — ANON_PERCENTILE_CONT with noise (eps=10)

**`googlesql/functions/aggregate/differential_privacy/anon_quantiles`**
- upstream example 1 — ANON_QUANTILES with noise (eps=10)

**`googlesql/functions/aggregate/differential_privacy/anon_stddev_pop`**
- upstream example 1 — ANON_STDDEV_POP with noise (eps=10)

**`googlesql/functions/aggregate/differential_privacy/anon_sum`**
- upstream example 1 — ANON_SUM with noise (eps=10)
- upstream example 2 — ANON_SUM without noise

**`googlesql/functions/aggregate/differential_privacy/anon_var_pop`**
- upstream example 1 — ANON_VAR_POP with noise (eps=10)

---

<a id="tier-3"></a>

## Tier 3 — flag unblocks the analyzer, implementation still owed (10 cases)

Cases whose detection signal *moved* under the experiment. Enabling the flag does not fix
them; it converts an upstream refusal into an honest to-do the suite will then track.

- **`differential_privacy`, 7 cases** — `syntax/feature disabled` becomes
  `no such AST node in the extractor`. `SELECT WITH DIFFERENTIAL_PRIVACY` resolves to a
  `ResolvedDifferentialPrivacyAggregateScan` the extractor has no arm for. This is the
  real gap the 12 stale ANON_* cases above sit on top of.
- **`proto_default_if_null`, 2 cases** — `function not found` becomes
  `type not found (proto)`, joining the descriptor-plumbing pile in tier 8.
- **`collate`, 1 case** — `function not found` becomes `registered name, no UDF`: the
  annotation framework resolves `COLLATE`, and then nothing answers it.

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

**`googlesql/functions/proto/proto_default_if_null`**
- PROTO_DEFAULT_IF_NULL returns the set field value
- PROTO_DEFAULT_IF_NULL with explicit field access for each component

**`googlesql/functions/string/collate`**
- upstream example 1

---

<a id="tier-4"></a>

## Tier 4 — implementation backlog, analyzer already resolves them (122 cases)

`no such function in the transformer` on the current tree, no flag needed. The analyzer
hands us a resolved call and the dispatch map has no entry. This is the pure
"write the function" pile, and it is where the mass sits — geography alone is more than
two thirds of it.

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

### `googlesql/functions/string` (19 cases)

**`googlesql/functions/string/edit_distance`**
- edit_distance basic behaviour

**`googlesql/functions/string/regexp_extract_groups`**
- upstream example 1
- upstream example 10
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

### `bigquery/functions/geography` (5 cases)

**`bigquery/functions/geography/st_centroid_agg`**
- NULLs in input are skipped
- centroid of three points
- centroid of two points
- linestring centroid is the length-weighted midpoint
- square polygon centroid is the area-weighted centre

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

### `googlesql/functions/window` (2 cases)

**`googlesql/functions/window/is_first`**
- IS_FIRST returns BOOL via numbering rewrite

**`googlesql/functions/window/is_last`**
- IS_LAST returns BOOL via numbering rewrite

### `googlesql/types` (1 case)

**`googlesql/types/geography`**
- round-trip point through WKT

---

<a id="tier-5"></a>

## Tier 5 — still analyzer-blocked after the experiment (51 cases)

`analyzer: function not found` persisted with the candidate flags on. Each needs a
different flag, a catalog registration, or is absent from this googlesql revision
entirely — establish which before estimating implementation cost. For `search`,
`text_analysis` and the FLOAT64 half of `kll`, the experiment already answers it: the
names are not in the catalog at all, so there is no flag to find.

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

---

<a id="tier-6"></a>

## Tier 6 — analyzer refuses the construct (24 cases)

`analyzer: feature not supported`. The message is the analyzer's own — "Table-valued
functions are not supported", "Statement not supported: GrantStatement". These are
language constructs rather than functions, so each is its own project.

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

### `googlesql/functions/debug` (1 case)

**`googlesql/functions/debug/error`**
- assertion_succeeded_with_multiple_payloads

### `googlesql/types` (1 case)

**`googlesql/types/graph_element`**
- upstream example 1

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

### The JSON family, 54 cases

`googlesql/functions/json` is 75/75 and `bigquery/functions/json` is 10/10. The whole
directory went green, and it went green two ways — which is the point of the entry.

**27 cases were built.** `LAX_BOOL` / `LAX_INT64` / `LAX_FLOAT64` / `LAX_STRING`,
`JSON_ARRAY`, `JSON_OBJECT`, the five mutators (`JSON_SET`, `JSON_REMOVE`,
`JSON_STRIP_NULLS`, `JSON_ARRAY_APPEND`, `JSON_ARRAY_INSERT`), `JSON_KEYS` and
`JSON_FLATTEN`. Every expected value in those twelve files was re-run against real
BigQuery before a line was written, including the nine doc-derived `JSON_ARRAY_INSERT`
examples; all 27 matched, so this was implementation only, with no restating.

**27 cases were refused.** `JSON_CONTAINS`, the typed-array accessors, and the
32-bit/unsigned accessors are all absent from BigQuery — the last group necessarily so,
since BigQuery has no INT32, UINT32, UINT64 or FLOAT type for an accessor to return.
Their fixtures now assert the analyzer's refusal.

Three things worth carrying forward:

- **A lax conversion is not a cast.** It answers NULL where a cast would raise, so it
  cannot ride the result-cell coercion the way `BOOL`/`INT64`/`FLOAT64` do. It also does
  not distribute evenly: `LAX_INT64(JSON 'true')` is 1 but `LAX_FLOAT64(JSON 'true')` is
  NULL, and `LAX_INT64(JSON '" 42 "')` trims where `LAX_BOOL(JSON '" true "')` does not.
- **Writing needs a slot, not a value.** The extract family's `navigate()` returns a
  value; every mutator needs a pointer into the tree plus BigQuery's vivification rules,
  and those rules differ per function — `JSON_SET` creates a missing key, `JSON_ARRAY_INSERT`
  never does, yet both turn an existing JSON null into an array.
- **The refusal is the cheapest thing in the corpus and the most exact.** These pins name
  the function, because the analyzer refuses at name resolution out of the same catalog
  BigQuery uses and reproduces its message word for word, hint included. The net pins one
  entry down could only say `UnsupportedFunction`.

### The net family, 12 cases

`googlesql/functions/net` is 23/23. `NET.IP_IN_NET` was implemented — BigQuery has it —
and the other five names were pinned: `NET.MAKE_NET` exists in neither dialect, and
`FORMAT_IP` / `PARSE_IP` / `FORMAT_PACKED_IP` / `PARSE_PACKED_IP` are BigQuery **legacy
SQL**, which is why they feel familiar (`bq query --use_legacy_sql=true "SELECT
FORMAT_IP(16909060)"` answers `1.2.3.4`) and why GoogleSQL's own docs mark all four
deprecated.

Two asymmetries in `IP_IN_NET` that reasoning would have got wrong: a *malformed* net
raises, but a net of a different address family is a plain `false`; and a net with no
prefix is a host net, while host bits inside a prefixed net are masked away rather than
rejected.

### Struct positional accessors, 10 cases

One flag, no engine code. `resolver_expr.cc` normalizes `s[OFFSET(n)]` / `s[ORDINAL(n)]`
to a 0-based index and emits the same `ResolvedGetStructField` that `s.a` produces, so
the extractor cannot tell the spellings apart and the `CompositeRef` walk already
answered it. `FEATURE_ANALYSIS_CONSTANT_STRUCT_POSITIONAL_ACCESSOR` stays off *because
BigQuery has it off*, which is what makes `s[OFFSET(1+1)]` answer "Field element access
is only supported for literal integer positions" — BigQuery's own words, for free.

### Time buckets and the INTERVAL part list, 20 cases

`DATE_BUCKET` / `DATETIME_BUCKET` / `TIMESTAMP_BUCKET`, plus the INTERVAL parts that had
to exist first: `WEEK`, `MICROSECOND`, `QUARTER`, `MILLISECOND`. `NANOSECOND` was
implemented and then reverted — the *part* is GoogleSQL-only even though BigQuery reads
nanosecond precision in an interval literal fine, so it is refused the way ARRAY_TRANSFORM
is. Finding that took a bq round-trip, not a doc.

### Pipe syntax, TYPEOF and GROUPING, 33 cases

`googlesql/syntax/pipe` is 27/27 on `FEATURE_PIPES` alone: pipe operators resolve into the
ordinary `ResolvedScan` tree the extractor already walks. `FEATURE_PIPE_IF` was enabled in
the same commit and then reverted — BigQuery answers "Pipe IF not supported", and shipping
it would have meant a green local run and a broken deploy.

`TYPEOF` needs no UDF: the analyzer's rewriter resolves it to a constant-true `CASE` whose
taken branch is the type name as a literal.

`GROUPING` could not be an aggregate UDF, because a NULL is ambiguous between "rolled up"
and "NULL in the data". The answer is constant per grouping set, so the transformer inlines
0 or 1 per UNION branch. Writing the test exposed a real pre-existing bug: an empty grouping
set emitted no GROUP BY at all and so returned one row per input row.


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
