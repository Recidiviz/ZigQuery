# Value codec performance findings

An experiment log for the work that produced storage format 3, in the style of
`M0_FINDINGS.md`: what was measured, what it changed, and — the part with the
longest shelf life — **what was tried and reverted, with the number that killed
it**. Four optimizations in here look obviously good on paper and are not.

Semantics are the other document's job: `NUMERIC_FIDELITY.md` records where the
engine diverges from BigQuery. This one is only about cost.

Reproduce any figure with:

```sh
zig build codec-bench -Drelease=true -Dcodec-timers=true -- 200000
```

## 0. Read this before quoting a number

`-Dcodec-timers` is **off by default** and costs **~18 ns per span**. A real
workload makes millions of spans — commit `a3bb4e3` measured 11.9 M over ~19 k
rows — so left always-on the instrumentation distorts the very path it exists to
measure. That is why it is a build option.

The `INT64 control` stage exists to calibrate it: every value in it is a native
INT64, so `EncodeValue` is a switch and a return, and whatever time it records is
the timer measuring itself. `codec_bench` divides that by the span count and
subtracts it from every stage, which is what the `codec adj` column means.

**Apply that correction before drawing a conclusion.** It was skipped once during
this work and turned a ~3% opportunity into an apparent ~19% one; see §3.4. When
timers are off there is no 18 ns to reclaim at all, because the span does not
exist.

## 1. Where the time actually was

Baseline, before any change (200 k rows, overhead-adjusted):

| stage | total | codec | % | base64 | collate | alloc/row |
|---|---|---|---|---|---|---|
| INSERT (encode-heavy) | 317 ms | 119 ms | 37% | ~5% | — | 0.00 |
| SELECT * (decode-heavy) | 104 ms | 37 ms | 35% | ~5% | — | 0.00 |
| nested UDFs over strings | 243 ms | 95 ms | 39% | ~7% | — | 0.00 |
| **scalar UDF volume** | 742 ms | **309 ms** | **41%** | ~3% | — | 0.00 |
| INT64 control | 184 ms | 0 ms | 0% | — | — | 0.00 |
| **ORDER BY string** | 502 ms | 242 ms | 48% | ~3% | **401 ms / 1.97 M** | **9.83** |
| ORDER BY int | 41 ms | 0 ms | 0% | — | — | 0.00 |

Two findings reframed the work, and both contradicted the starting assumption
that base64 was the problem:

- **base64 was only ~3–7% of wall time.** The codec cost 35–48%, but almost none
  of it was the wrapper. Removing base64 alone would have bought single digits.
- **Sorting an encoded STRING column cost 12× the same sort over native INT64**
  (502 ms vs 41 ms), at 9.83 allocations per row against ~0 everywhere else.
  `zetasqlite_collate` constructed and destroyed an `ArenaAllocator` per
  comparison and decoded *both* operands, ~n log n times per sort.

## 2. What storage format 3 achieved

Every non-scalar value is now a BLOB. Orderable kinds carry a memcomparable
encoding so SQLite's own byte comparison *is* GoogleSQL's ordering; the rest
carry the self-delimiting codec. There is no base64 and no collation anywhere in
the engine. See `src/internal/codec_sortable.zig` for the format itself.

| stage | before | after | |
|---|---|---|---|
| scalar UDF volume | 742 ms | **~395 ms** | −47% |
| ORDER BY string | 502 ms | **~56 ms** | −89% |
| INSERT (encode-heavy) | 317 ms | **~175 ms** | −45% |
| nested UDFs over strings | 243 ms | **~127 ms** | −48% |
| SELECT * (decode-heavy) | 104 ms | **~71 ms** | −32% |
| base64, every stage | 3–7% | **0.00 ms** | gone |

`ORDER BY` on a string column is now ~56 ms against ~36 ms for the same sort over
native INT64 — from 12× down to about 1.6×.

The result substantially exceeded the ~20–25% projected from removing base64,
because the flip removed the pipeline around it rather than just the wrapper: a
STRING now decodes to a pointer and a length with no allocation and no copy.

## 3. Tried and reverted

### 3.1 Retained arena in the collation — no measurable effect

`collateCmp` built and destroyed an `ArenaAllocator` per comparison. Replacing it
with a retained arena reset per call removed **all 1.97 M allocations** (9.83 →
0.00 per row) and moved wall time **within noise**.

Allocation was never the cost. A warm malloc/free pair is ~25 ns against a 203 ns
comparison; the decoding on either side was the expense. Worth remembering before
optimizing another allocation count.

### 3.2 Pre-sized encode buffer — neutral

`encodeBinaryValue` grows an `ArrayList` from `.empty` per value. Computing the
encoded size first and pre-allocating measured **137.9 → 136.0 ms over 2.4 M
values**, inside run-to-run noise.

On an arena the list is the most recent allocation, so growth extends in place
rather than copying — there was nothing to save. For arrays the size hint also
cost a second recursive walk, so it could have been a small regression. A comment
in `codec_binary.zig` records this so it is not retried.

### 3.3 Structural comparator — right answer, then obsolete

Comparing two encoded buffers in place, without materializing `Value`s, cut the
string sort **3.2×** (502 → 171 ms). It was the single largest win of the
compat-preserving phase.

It was then **deleted**. Once the encoding became memcomparable, SQLite compares
the bytes itself and the collation is never consulted, so `compareEncoded`
handled only kinds that could no longer reach it. Removing it cost nothing
measurable (392 vs 388 ms scalar UDF; the sort unchanged within noise).

Not a wasted effort — it was the correct fix for the format that existed at the
time — but a reminder that an optimization can be fully subsumed by a later
change to the thing underneath it.

### 3.4 Caching constant aggregate arguments — rejected twice over

**The observation is real.** SQLite hoists option markers with constant
arguments out of the row loop: adding `DISTINCT`, `IGNORE NULLS` and `LIMIT` to a
10 k-row aggregate added **3 encode spans, not 30 000**, because they are
`DETERMINISTIC` with constant arguments. But hoisting only means the marker is
*built* once — it is still **passed as an argument on every step**, so the
aggregate's `decodeArgs` decodes the same constant BLOB per row (+3 decodes per
row, measured).

`ORDER BY` and `HAVING MAX|MIN` are not in this set: they carry a per-row column
(`zetasqlite_order_by(\`wrs15\`.\`y__6\`, true)`), so their markers genuinely vary
and nothing about them is cacheable.

It was rejected for two independent reasons.

**The size was wrong.** The 22 ns/decode it rested on was measured with timers
on, and ~18 ns of that is the timer (§0). Real work is ~4 ns. Three markers × ~4
ns × 200 k rows ≈ 2.4 ms of a ~68 ms stage — **~3–4%**, not the ~19% first
claimed. The correction in §0 is there because this is exactly how it gets
missed.

Part of why it is so small is §3 of this document in miniature: the marker
rewrite had already taken the win. A JSON+base64 marker cost a parse and a base64
decode per row; a BYTES marker decodes by borrowing. Measured A/B on a 200 k-row
`ARRAY_AGG(x ORDER BY y)`: **76.7 / 75.0 ms** before, **67.4 / 67.7 / 68.4 /
68.2 ms** after — ~7.5 ms, ~37 ns/row.

**And it covers less than it looks.** `decodeArgs` reads `.integer` and `.float`
straight off `sqlite3_value` — no codec span, no allocation — so a constant
number is already free. Only BLOB-shaped constants cost anything: the option
markers, `STRING_AGG`'s delimiter (5 sites), and `LEAD`/`LAG`'s default value (2
sites) — about 28 of ~192 aggregate and window call sites in
`testdata/sql_snapshot.txt`. Every `PERCENTILE_CONT(x, 0.5)`,
`APPROX_QUANTILES(x, n)` and `NTILE(n)` in the corpus was never paying. One count
the other way: on the window path `xInverse` decodes too, so a sliding frame pays
twice per row.

**And the mechanism is not available.** `sqlite3_set_auxdata`'s documentation
opens: *"These functions may be used by **(non-aggregate)** SQL functions"*, and
the source says why. The property that makes auxdata safe — SQLite dropping the
entry when the argument is not constant — lives in a single call,
`sqlite3VdbeDeleteAuxData(db, &p->pAuxData, pCtx->iOp, pOp->p1)`, where `p1` is
the compile-time constant mask. `OP_Function` is the only opcode that makes it.
`OP_AggStep1` clears `pCtx->isError` after the call but never invalidates, so
from a step there is no mask and no filtering: an entry set against a varying
argument survives until statement reset and returns a stale value on every later
row — **silent wrong answers, not a slow path**. `xValue`/`xFinal` cannot use it
at all; they build a stack-local `sqlite3_context` via `memset(&ctx, 0,
sizeof(ctx))`, so `pCtx->pVdbe == 0`, and `sqlite3_get_auxdata` only returns 0
for that under `SQLITE_ENABLE_STAT4` — the `#else` is a bare `assert`, i.e. a
NULL dereference in a release build without it. STAT4 is on in this build — it
was inherited from the Homebrew keg and is now set explicitly in
`sqlite_cflags` — so failing safe here is a build flag, not a guarantee.

This codebase confirms it from the other side — the aggregate and window
trampolines never set `bind.current_ctx` and pass no `cached_args` mask, so
`auxGet`/`auxSet` are inert there by construction.

There *is* a sound fallback — cache the constant options in the per-group struct
on first step, justified by GoogleSQL semantics (an aggregate has one `DISTINCT`
by definition) rather than by SQLite's constant analysis. It was not built: ~3–4%
does not pay for new correctness surface in the step path. If it is revisited,
the reason will be §4.2 rather than the CPU time.

## 4. Known weaknesses

### 4.1 `cached_args`, the one live auxdata user

`cached_args` (`bind.zig`) caches `CAST`'s two type documents. On a cache hit
`decodeArgs` substitutes `Value.@"null"` for the argument rather than decoding
it, which is sound **only** because the mask's bit set exactly equals the set of
indices the handler reads via `auxGet`. Nothing checks that; a mismatch is a
silent SQL NULL.

The commit that added it names the alternative: cache the raw bytes beside the
derived form and `memcmp` before reuse, which would drop the mask entirely and be
sound for any argument. Also unresolved: the cache allocates from
`std.heap.c_allocator` where the engine otherwise threads allocators as
parameters, and no test asserts the cached path is ever taken.

### 4.2 Aggregate arguments are re-decoded *and retained* per row

This is the part of §3.4 that the ~3–4% figure does not cover, and it is a memory
characteristic rather than a speed one.

Aggregate and window `decodeArgs` use `encoder.DecodeValue` — the **owning**
form, which dupes the blob before decoding — because a step buffers values across
rows and borrowing SQLite's memory would dangle (`encoder.zig`). It allocates
from `group.arena`, which is created on the group's first `xStep` and only
released in `xFinal`. **Nothing resets it between rows.**

So a constant marker is not merely re-decoded per row, it is re-*copied* per row
and held until the group ends. Markers run 14 bytes (`DISTINCT`,
`IGNORE NULLS`) and 22 (`LIMIT`), so a 1 M-row group carrying all three retains
~50 MB of byte-identical copies — before the per-row `[]Value` and
`AggregatorOption`, which are arena-allocated too and equally permanent.

A per-group cache would fix the retention and the decode together, which is the
stronger case for building it.

### 4.3 `STRING_AGG` re-materializes its delimiter on every row

`STRING_AGG.step` (`fn_aggregate.zig:498`) calls `values[1].toString(alloc)`
before the `f.once` guard, and `toString` on a `.string` is an `alloc.dupe`. Only
the first row's result is ever stored (`:503`); every later row's copy is dead on
arrival and, per §4.2, retained anyway. Moving the call inside the `!f.once`
branch is a two-line fix — unmeasured, and it is 5 call sites in the corpus, so
it is listed as a known wart rather than a pending optimization.

## 5. Unmeasured

- **Numerics have no bench stage.** Fixed-scale rounding was added to every
  numeric construction, including every decode. `numericFromUnscaled` exists so
  the decode path does not re-derive an invariant the stored bytes already
  satisfy, but that saving was never quantified — and neither was the cost of the
  rounding itself.
- **`ARRAY_AGG(... ORDER BY)`** is the only aggregate stage. `HAVING MAX|MIN`,
  window functions and the grouping-sets path are unmeasured.
- **The bench is single-connection and in-memory.** Nothing here says anything
  about the server's concurrency behaviour; see `M0_FINDINGS.md` for that.

## 6. The encode scratch buffer — kept on memory, not on speed

`EncodeValue` returned an owned `SqliteRepr` allocated from whatever allocator
the call site happened to hold, and every call site then switched on that repr a
second time to pick its `sqlite3_result_*` call — the same six lines in five
places. It now encodes through `encoder.encodeTo(sink, scratch, v)`, into one
buffer per connection that is cleared per value and freed with the connection.

**The reason is retention, and it is the encode-side twin of §4.2.** Three paths
encoded into an arena that is not reset per row:

| path | arena released | what it retained |
|---|---|---|
| `window.xValue` | end of the partition | every row's encoded result |
| `unnest_vtab.xColumn` | end of the scan (`xFilter`) | every element, re-encoded |
| `info_schema_vtab.xColumn` | end of the cursor | every cell |

Same arithmetic as §4.2: a 1 M-row window partition returning 24-byte strings
retained ~25 MB of encoded bytes that were copied into SQLite the moment they
were produced and never read again. It is now one buffer sized to the largest
value in the partition. `test "encodeTo reuses its scratch buffer instead of
allocating per value"` (`encoder.zig`) pins it — after warmup, 500 encodes make
zero allocations.

Note that **`alloc/row` could never have shown this.** It counts allocations
reaching the allocator handed to the driver, and these landed in arenas built on
top of it, so they were invisible there at 0.00/row — as §3.1 found from the
other direction.

**The CPU is a non-result, and deliberately recorded as one.** Adjusted encode
cost was ~3 ns/value before (§0's correction applied) and there was never much to
win. Over one baseline run and three after:

| stage | before | after (3 runs) |
|---|---|---|
| scalar UDF volume | 402.0ms | 382.0 / 380.5 / 378.9 |
| INSERT (encode-heavy) | 177.0ms | 175.2 / 167.3 / 165.4 |
| **INT64 control (no codec at all)** | **177.4ms** | **174.7 / 171.8 / 174.5** |

The control stage does no codec work and moved ~2% across the same runs, which
is the floor on what any of the other rows mean. The scalar UDF stage's ~5% is
the largest move and the only one clearly above it, but with a single baseline
run it cannot be separated from machine state, so **treat this change as
CPU-neutral**. The timer-overhead calibration itself ranged 17.8–18.7 ns between
runs, which moves every `codec adj` figure with it — one more reason not to quote
that column across runs.

The bench also has no window-function stage (§5), so the path with the largest
retention win is not represented in the table above at all.

## 7. Composite access: fixed-width payloads and one-entry decode

Two changes to the self-delimiting codec, storage format **3 -> 4**.

**Fixed-width payloads.** DATE, DATETIME, TIME and NUMERIC/BIGNUMERIC were
stored as text — `"1970-01-01"`, `"10:30:15.5"`, the unscaled integer in decimal
— and formatted on the way out and parsed on the way back, once per nested value
per row. They are now the i64 (or i128/i256) the Value already holds, little
endian, the shape INT64 and TIMESTAMP always had. Nothing was owed to Go's bytes
by then: format 3 had already replaced the NUMERIC payload and added a tag with
no Go counterpart, and older databases are refused rather than migrated.

Bytes mostly shrink — a DATE 12 -> 9, a DATETIME up to 28 -> 9, a full-precision
NUMERIC 40 -> 17 — with one honest exception: a *small* NUMERIC grows, because
16 bytes is wider than `"1500000000"`. Fixed beat minimal-length anyway: it makes
both directions a memcpy and lets `skipValue` step over a value from the tag
alone.

**One-entry decode.** `zetasqlite_get_struct_field(x, n)` and the two array
indexers took a fully decoded composite, read one entry, and dropped the rest —
every field of every struct, on every reference, on every row, with three
references to one struct on a single line of `testdata/sql_snapshot.txt`. They
now take the argument encoded (`bind.FuncInfo.raw_args`) and walk to the entry
with `skipValue` via `codec_binary.CompositeRef`, decoding only what was asked
for. An argument that is not the composite it should be falls back to a full
decode, so the error messages are the ones `toStruct`/`toArray` always gave.

**Measured**, on 200 k rows of `STRUCT<INT64, DATE, STRING, NUMERIC, TIMESTAMP>`
with two field reads per row (`zetasqlite-zig --file`, `-Drelease=true`):

| | before | after |
|---|---|---|
| wall clock, timers off (4 warm runs each) | 0.27s x4 | 0.19 / 0.19 / 0.19 / 0.20 |
| decode spans | 1,000,008 total, 600,003 decode | 600,008 total, **200,003** decode |
| decode time (timers on) | 37.0 / 37.1 / 37.8 ms | **5.4 / 5.5 / 5.4 ms** |
| encode time (timers on) | 6.2 / 6.7 / 7.0 ms | 7.1 / 7.0 / 7.0 ms |

**~30% off the query.** The 400 k vanished decode spans are the second change:
two field reads per row over 200 k rows that no longer decode anything but the
field. Applying §0's correction, real decode work went from ~26 ms to ~2 ms.

Two honest notes. **Encode is flat** — the numeric `bufPrint` this removed does
not show above the noise at one numeric per row, so the fixed-width change is
carried here by its decode half and by the bytes. And the *split* between the two
changes is not measurable from this table, because the second one removes the
decodes the first one would have sped up.

`codec-bench` shows none of this: it has no STRUCT column and no field access,
and its DATE/TIMESTAMP columns are top-level, so they take the memcomparable
codec and never touch these bytes at all. That is a gap in the bench (§5), not a
sign the paths are cold — `sql_snapshot.txt` has 94 `get_struct_field` calls.

`ARRAY_LENGTH` went the same way afterwards, and is the cleanest case of the
lot: the count is a uvarint sitting behind the array's tag, so a length now
reads a byte or two where it used to materialize every element to take `.len` of
them. On 100 k rows of 50-element arrays, `SUM(ARRAY_LENGTH(a))` goes **0.08s ->
0.05s** (3 warm runs each, timers off).

The invariant to protect here is `test "skipValue advances exactly as far as
decoding does, for every kind"`. `value` and `skipValue` each decide how wide a
payload is; if they disagree the walk desynchronises silently and surfaces as
CorruptData somewhere unrelated. This change moved four widths at once, and both
now read them from one table (`BinReader.fixedWidth`).

## 8. Predicates: the fast path catches up with the codec

The largest remaining consumer of the codec was not the codec's fault. Every
`WHERE` predicate over a DATE, TIMESTAMP, BYTES or NUMERIC column still went
through a `zetasqlite_*` UDF that decoded both operands and encoded a BOOL, once
per row — because `isPrimitiveSQLiteType` (`transformer/function.zig`) had never
been widened past the kinds Go could lower, and Go could only lower the ones
SQLite stored natively. Storage format 3 had made nine kinds memcomparable two
sections ago; the predicate list was still the base64 era's.

Three things were wrong at once, and the smallest was the type list:

- **The type list.** DATE, TIME, DATETIME, TIMESTAMP, BYTES, NUMERIC,
  BIGNUMERIC and RANGE now lower. The licence is `test "memcmp over encodings
  matches compareForCollation"` in `codec_sortable.zig`: `compareForCollation`
  is defined via `Value.eq`/`gt`, which *are* what `zetasqlite_equal` and
  `zetasqlite_less` call, so SQLite's byte comparison is the UDF's own answer.
- **Operand shape, which blocked more than type did.** A `.function` operand
  counted as primitive only if it was itself an operator — so
  `get_struct_field(s, 0) = 1`, `array_length(a) = 0` and `EXTRACT(YEAR FROM d)
  = 2025` all stayed UDFs despite returning INT64. Function calls now carry
  their resolved result kind (`FunctionCallData.result_kind`, one i32 off the
  ResolvedExpr base) and qualify on it.
- **`IN` never lowered past one list element.** `canOptimizeFunction` funnelled
  it into the comparison operators' `!= 2` arity check, so `x IN (a, b, c)` was
  rejected — while `optimizeFunctionToSQL` had always rendered N arguments
  correctly. A pure bug, inherited whole.

Four operators were also added to the table: `IS NULL` (97 call sites in
`sql_snapshot.txt`, the largest single group, and type-independent — it lowers
over ARRAY and STRUCT too), `BETWEEN`, and `IS [NOT] DISTINCT FROM` onto
SQLite's NULL-safe `IS` / `IS NOT`. `LIKE` is deliberately absent: SQLite's is
ASCII-case-insensitive and coerces BLOBs to text.

**Measured**, 200 k rows of `(INT64, DATE, TIMESTAMP, STRING)`, `-Drelease=true`,
timers off. The load statement is timed separately and is byte-identical work in
both builds, so the difference is the query and nothing else:

| | before | after | |
|---|---|---|---|
| load 200 k rows | 0.13s | 0.13s | unchanged, as it must be |
| `d BETWEEN … AND …` | 13.5 ms/query | **4.0 ms** | −70% |
| that `AND ts < …` `AND s IN (…4)` | 44.0 ms/query | **6.0 ms** | −86% |

Per-query figures are `(20 queries + load − load) / 20`; three interleaved runs
agreed to 0.01s. The composite predicate is the better number *and* the less
representative one — it lowers five UDF calls per row (three comparisons and two
`AND`s), so it is close to the best case. The single `BETWEEN` is the honest
floor at ~3.4×.

Corpus-wide, the 273 lowerable calls in `sql_snapshot.txt` became 32, and every
survivor is blocked for a real reason: a STRUCT operand, a correlated subquery
operand, or a NULL literal (deliberately excluded — see
`isPrimitiveSQLiteType`).

### 8.1 Two things this uncovered

**A latent precedence bug.** `BinaryExpression.writeSql` renders `left OP right`
with no parentheses, which is fine while every nesting binds tighter than its
parent — `a = b AND c = d` — and silently wrong when it does not: `(a OR b) AND
c` rendered as `a OR b AND c`, which SQLite reads as `a OR (b AND c)`. The
corpus never exercised it, and widening the fast path would have made it
reachable. Operands that are themselves binary are now wrapped (`grouped`), and
`test "or nested inside and keeps its grouping"` fails without it.

**`isCheapToDuplicate` treated every list as expensive**, so each parenthesised
operand put a subquery level back around expressions that had just been
simplified — two cases in the corpus gained a level before this was fixed. A
list costs exactly what its elements cost. With that corrected the change
*removes* 18 levels net and adds none.

### 8.2 Two UDFs were wrong, and lowering exposed it

Both `fn_compare.in` and `fn_compare.between` opened with a blanket
`existsNull(args) -> NULL`, which is not three-valued logic:

| | UDF, before | BigQuery / SQLite |
|---|---|---|
| `1 IN (1, NULL)` | NULL | **TRUE** |
| `5 BETWEEN 10 AND NULL` | NULL | **FALSE** |

A NULL in an `IN` list blocks a FALSE but never a TRUE; a FALSE from one side of
a `BETWEEN` wins over a NULL from the other. Both are fixed, so the lowered and
UDF paths give one answer — which matters more now that which path runs depends
on whether the operands happen to be literals.

`zetasqlite_is_true` / `_is_false` had the same shape of bug and were fixed with
them, though for a different reason — neither lowers, so no two paths were
disagreeing; they were simply wrong. `IS TRUE` and `IS FALSE` are *total*
predicates that answer TRUE or FALSE and never NULL, which is the entire reason
the syntax exists: it tests a possibly-NULL boolean without NULL propagation,
and `x IS TRUE` would be indistinguishable from plain `x` otherwise. All four
forms returned NULL for a NULL operand, because `IS NOT TRUE` is
`$not($is_true(x))` and `not` propagates what it is given:

| | before | BigQuery |
|---|---|---|
| `NULL IS TRUE` / `NULL IS FALSE` | NULL | **FALSE** |
| `NULL IS NOT TRUE` / `NULL IS NOT FALSE` | NULL | **TRUE** |

The four spec cases that existed all used non-NULL operands, so they never
exercised the only input where the predicate differs from `x` itself. That is
the general lesson of this section: each of these three bugs sat behind a test
that passed because it tested the uninteresting half of the domain.
