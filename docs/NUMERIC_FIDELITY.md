# NUMERIC / BIGNUMERIC fidelity gaps

Known divergences between this engine and BigQuery for the two decimal types,
recorded while moving them to storage format 3 (fixed-scale, memcomparable BLOB).
None is a regression from that change unless noted — most predate it and were
inherited from go-zetasqlite, which represents both types as an unbounded
`math/big.Rat` and enforces nothing.

Baseline for all of this: NUMERIC is `decimal(38,9)`, BIGNUMERIC is
`decimal(76,38)`. Since format 3, `numericValue` (`src/internal/value.zig`) is the
single construction point and rounds every value to its declared scale, half away
from zero, and rejects out-of-range magnitudes.

## Fixed by format 3, for the record

These *were* gaps and no longer are. Listed so nobody re-derives them.

| | was | now |
|---|---|---|
| Division kept an exact rational | `(NUMERIC '1'/'7')*'7'` = `1` | `1.000000001` |
| `PARSE_NUMERIC` did not round, a folded `CAST` did | inconsistent | both round |
| Values rendering alike compared unequal | `(1/3) != 0.333333333` | equal |
| `GROUP BY` keyed on the rendering while `=` used exact `Rat.cmp` | disagreed | agree |
| Mixed-kind arithmetic was LHS-wins | `BIGNUMERIC + NUMERIC` narrowed to scale 9 | widens to BIGNUMERIC |
| Out-of-range values were accepted silently | any magnitude | `NumericOutOfRange` |

## Open gaps

### 1. `AVG` over NUMERIC returns FLOAT64

BigQuery returns NUMERIC. Ours goes through `toFloat64` and yields `.float`
(`src/internal/function/fn_aggregate.zig`, pinned by the test at `:911`
asserting `.float = 1.5`). `WINDOW_AVG` does the same. This is now the largest
remaining precision leak in the numeric surface: every other arithmetic operator
stays exact at scale.

`SUM` is unaffected — it stays NUMERIC.

### 2. `ROUND` / `TRUNC` / `FLOOR` / `CEIL` / `ABS` / `MOD` / `SIGN` coerce to float

All go through `toFloat64` and return `.float` (`src/internal/function/fn_math.zig`).
A NUMERIC argument therefore loses precision beyond f64's 53 bits, and the result
type is wrong. `ROUND(NUMERIC '1.5')` happens to give `2`, but only because the
value is small.

### 3. `SAFE_ADD` / `SAFE_SUBTRACT` / `SAFE_MULTIPLY` / `SAFE_DIVIDE` / `SAFE_NEGATE` coerce to float

Same mechanism (`fn_math.zig:57-86`), so the `SAFE_` variants are *less* precise
than the bare operators, which stay exact. Surprising, and the opposite of what
the names suggest.

### 4. `PARSE_NUMERIC` accepts a fraction grammar BigQuery rejects

`Rat.setString` checks for `/` first and parses an `"n/d"` fraction
(`src/internal/value.zig`), so `PARSE_NUMERIC('1/3')` succeeds and now rounds to
`0.333333333`. BigQuery raises. The grammar cannot simply be deleted: it is
load-bearing for *nested* numerics, which stay on the format-1 self-delimiting
codec inside ARRAY and STRUCT and are stored as `ratString` — `"n/d"` when the
denominator is not 1. Fixing this means splitting the storage grammar from the
user-facing parse grammar.

### 5. `toInt64` and `toBool` on a numeric read the numerator, not the value

`Value.toInt64` returns `numLowInt64` — the low limb of the *numerator* with the
sign applied — kept bug-for-bug from Go. So `NUMERIC '1.5'` converts to `3`, not
`1`, because the reduced form is `3/2`. `toBool` switches on the same numerator.

Normalization changed the blast radius: previously off-grid values now round
first, so `(1/3).toInt64()` went from `1` to `333333333`. Analyzer-unreachable
(GoogleSQL inserts a cast), so this only bites `rawQuery` and any future path
that skips the analyzer.

### 6. Non-numeric-LHS arithmetic does not widen

The mixed-kind fix covers `.numeric` on the left. `INT64 + NUMERIC` still routes
through the `.int` arm and `toInt64`, so `1 + NUMERIC '1.5'` = `4` via gap 5.
Analyzer-unreachable for the same reason.

### 7. NUMERIC and BIGNUMERIC do not interleave under memcmp

**Introduced by format 3, deliberately.** `Rat.cmp` is kind-agnostic, so
`compareForCollation` calls `NUMERIC '1.5'` equal to `BIGNUMERIC '1.5'`, while the
leading kind tag makes memcmp put every NUMERIC below every BIGNUMERIC.

Accepted because a GoogleSQL column has one static type and the analyzer casts for
mixed-kind arithmetic, so the pair cannot arise in one column through analyzed
SQL. Closing it would mean one shared width at scale 38, doubling every NUMERIC
payload from 17 to 34 bytes to order a state the analyzer forbids. Pinned by
`test "NUMERIC and BIGNUMERIC do not interleave"` in `codec_sortable.zig` so it
stays a decision rather than drifting into a bug.

### 8. A large BIGNUMERIC cannot be string-compared

`coerceToStringForCmp` renders into a 64-byte stack buffer and returns
`FailedConversion` when the text does not fit (`src/internal/value.zig`). A
scale-38 BIGNUMERIC needs up to 78 bytes, so `string_col = bignumeric_expr` fails
for large magnitudes. Pre-existing and unaffected by format 3, but adjacent enough
to be misattributed to it.

### 9. Result rendering uses the column's precision, not the value's

`cellFromValue` (`src/driver.zig`) builds a `Numeric` with `is_bignumeric` taken
from the *column* type and calls `toText`, so a scale-38 value landing in a
NUMERIC output column is narrowed at render. It is also the one place Go's `"-0"`
rendering remains reachable, since it bypasses `numericValue`.

### 10. No resource bound before the range check

`Rat.setString` caps the decimal exponent at ±2²⁰, so `PARSE_NUMERIC('1e1000000')`
builds a ~435 KB bigint via `powTen` before anything rejects it. The range check
fires afterwards. A digit-count precheck in `setString` would be cheap hardening,
independent of any of the above.

### 11. corpus case 619 asserts a rejection, not a value

`PARSE_BIGNUMERIC("123.456E37")` is 1.23456e39 — 2.13× BIGNUMERIC's maximum, and
1.23e77 unscaled against 2²⁵⁵ ≈ 5.79e76. It fits no fixed-width encoding, and
BigQuery rejects the whole statement: `Invalid input to PARSE_BIGNUMERIC:
"123.456E37"`. The value the corpus originally expected captured go-zetasqlite's
lack of bounds checking, since those cases (now `testdata/specs/zigquery/**`,
then `testdata/corpus.json`) are exported from that project's `query_test.go`
rather than recorded from BigQuery.

The case now carries `expected_err` and passes. Its message is this engine's
wording rather than BigQuery's, which is the convention the corpus already
follows — all 36 of its `expected_err` cases carry Go's text. The two in-range
arguments moved to
`testdata/specs/googlesql/functions/conversion/parse_bignumeric.zon`, since the
39th-fractional-digit rounding they exercise is worth keeping and nothing else
covered it.

## Coverage note

`harness/codec_bench.zig` has no numeric stage, so none of the numeric encode or
decode cost is measured. `numericFromUnscaled` exists so the decode path does not
re-derive the scale invariant the stored bytes already satisfy, but that saving is
unquantified.
