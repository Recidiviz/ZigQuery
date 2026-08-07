# Coverage

Line coverage for the two suites that exercise this engine, measured with kcov. A snapshot
of the tree at the commit this was written against — regenerate before quoting a number:

```sh
CXX_FLAGS=-w zig build coverage        # unit tests   -> zig-out/coverage/report/index.html
CXX_FLAGS=-w zig build coverage-spec   # spec corpus  -> zig-out/coverage/spec-report/index.html
```

Both report into `zig-out/coverage/`, and the machine-readable form each run leaves behind
is `<report>/kcov-merged/coverage.json` (per-file totals) and `codecov.json` (per-line
hits). Every table below comes from those two files.

## Read this before quoting a number

**Merge the two runs, and regenerate both first.** `kcov --merge` over the two run
directories gives a sound union — no file comes back covering less than either part did:

```sh
kcov --merge zig-out/coverage/combined-report zig-out/coverage/runs zig-out/coverage/spec-runs
```

It is only sound when both runs were produced from the *same* source. Merging a fresh run
against a stale one silently drops or mis-attributes the difference, and the give-away is
a file whose merged figure is lower than one of its inputs — which a union cannot be. That
mistake produced an earlier revision of this document claiming kcov could not merge them
at all. Check the invariant before trusting a merged number:

```python
merged[f] >= max(unit[f], spec[f])   # for every file
```

**Line coverage overstates what was tested.** kcov marks a line executed once control
reaches it, so `if (eql(part, "X")) return v;` counts as covered when the comparison runs
and fails. `time_util.zig`'s `America/New_York` arm read as covered for as long as no case
named that zone. A chain of such lines reports full coverage while only its first arm has
ever been taken. Treat the number as *reachability*, and read `codecov.json`'s per-line
hits when you want to know what a suite actually ran.

**Instrumented-line totals move between runs.** The same file can report a different
denominator after an unrelated edit, because the DWARF line table changes with it —
`date_ops.zig` went from 234 instrumented lines to 185 across one commit. Percentages a
point or two apart are not a signal; compare the uncovered *lines*, not the ratio.

**Some residue is kcov noise, not missed code.** DWARF attributes entries to doc comments,
blank lines and closing braces. In the date/time family roughly two thirds of the
outstanding lines are of this kind; count them by eye before treating a percentage as a
backlog.

## Headline

| | covered | instrumented | |
|---|---|---|---|
| spec corpus | 13 943 | 23 057 | 60.5% |
| unit tests | 22 501 | 33 010 | 68.2% |
| both merged | 24 610 | 33 014 | **74.5%** |

All three are dominated by one generated file. `src/proto/resolved_ast.zig` is 8 700 lines
of googlesql AST bindings emitted from the proto descriptors, and only the node kinds this
engine handles are ever constructed. Excluding `src/proto/`:

| | covered | instrumented | |
|---|---|---|---|
| spec corpus | 12 092 | 14 251 | 84.9% |
| unit tests | 20 688 | 24 141 | 85.7% |
| both merged | 22 641 | 24 145 | **93.8%** |

**93.8%** is the number worth tracking. The two suites are close in size and far apart in
what they reach, which is the point of keeping them separate: the corpus exercises SQL
surface, the unit tests reach what no query can execute.

## By area

Each run instruments its own line set, so the percentages are over different denominators.

| area | spec corpus | unit tests | both |
|---|---|---|---|
| `src/internal/function` | 86.3% | 74.3% | **94.3%** |
| `src/proto` (generated) | 21.0% | 20.4% | **22.2%** |
| `src/internal` (other) | 79.5% | 91.1% | **93.4%** |
| `src/server` | — | 92.2% | **92.2%** |
| `src` (top level) | 80.4% | 93.9% | **94.1%** |
| `src/internal/transformer` | 96.0% | 96.9% | **97.7%** |
| `src/internal/coordinator` | 92.2% | 92.7% | **94.3%** |
| `src/internal/sqlbuilder` | 70.7% | 87.3% | **87.7%** |

`src/server` is 0% under the spec corpus by construction: the spec runner drives the engine
through `driver.zig` and never starts the HTTP server. Its 92.2% comes entirely from
`zig build test-server`, and the same holds for every file under `src/server/**` — the
lowest of them is `server.zig` at 76%.

The two suites disagree most on `sqlbuilder` (70.7% / 87.3%) and `src/internal` (79.5% /
91.1%). Both are engine internals with dedicated unit tests and no direct SQL surface, so
the unit column is the one that means something there. `src/internal/function` inverts it —
86.3% / 74.3% — because a UDF's natural exercise is a query, not a Zig test. Merging is
what shows the two are complementary rather than redundant: `src/internal/function` reaches
**94.3%** together, well above either alone.

## Lowest by file, spec corpus

Files with at least 40 instrumented lines.

| file | spec | uncovered | unit tests |
|---|---|---|---|
| `src/proto/ast_dump.zig` | **0.0%** | 45 | 99% |
| `src/proto/resolved_ast.zig` | **20.8%** | 6892 | 19% |
| `src/internal/function/fn_hash.zig` | **38.4%** | 85 | 41% |
| `src/internal/function/fn_hll.zig` | **42.1%** | 314 | 88% |
| `src/analyzer_ffi.zig` | **58.5%** | 34 | 93% |
| `src/internal/value.zig` | **67.0%** | 421 | 85% |
| `src/internal/sqlbuilder/flatten.zig` | **68.4%** | 89 | 67% |
| `src/internal/function/fn_misc.zig` | **69.3%** | 39 | 57% |
| `src/internal/transformer/scan_table.zig` | **70.3%** | 19 | 70% |
| `src/internal/sqlbuilder/sqlbuilder.zig` | **70.3%** | 179 | 92% |
| `src/proto/wire.zig` | **70.5%** | 18 | 88% |
| `src/internal/spec_expect.zig` | **74.3%** | 27 | 97% |
| `src/internal/function/register.zig` | **77.0%** | 26 | 96% |
| `src/internal/function/fn_range.zig` | **79.4%** | 29 | 84% |
| `src/driver.zig` | **80.0%** | 188 | 93% |

Read the last column before acting on the first. `fn_hll.zig` is 42% under the corpus and
88% under the unit tests — the sketch arithmetic is tested where it can be tested precisely,
and only the SQL entry points are thin. `ast_dump.zig` at 0% is a debugging aid the spec
runner reaches only under `--verbose`. The three genuinely under-tested by *both* are
**`fn_hash.zig`** (38% / 41%) and **`flatten.zig`** (68% / 67%).

## The date/time and FORMAT families, as a worked example

These had three rounds of coverage-directed work between them, and they are the clearest
illustration of what the numbers are and are not good for.

| file | spec | unit tests | uncovered under spec |
|---|---|---|---|
| `date_ops.zig` | **99.5%** | 63% | 1 |
| `fn_format.zig` | **99.7%** | 67% | 1 |
| `time_parser.zig` | **99.6%** | 42% | 2 |
| `time_util.zig` | **98.3%** | 79% | 3 |
| `fn_datetime.zig` | **98.2%** | 19% | 2 |
| `fn_time.zig` | **97.8%** | 24% | 2 |
| `fn_timestamp.zig` | **96.7%** | 25% | 6 |
| `fn_date.zig` | **95.2%** | 41% | 9 |

The low unit-test column is deliberate. `fn_date.zig` states the rule at the head of its
test block: everything a query can reach is asserted in
`testdata/specs/zigquery/functions/date`, and what stays in the file is only what no query
can execute — the wall-clock fallback, the `.safe` prong, arity guards the analyzer rejects
first, the error propagator. A rising unit-test percentage here would be a regression in
that discipline, not an improvement.

Pointing `coverage-spec` at these files is also what found the bugs. All three rounds are
recorded in `SPEC_UNSUPPORTED.md` §4-7: fifteen wrong `FORMAT_*` answers, the ISOWEEK and
ISOYEAR truncation errors, `EXTRACT(WEEK …)` returning the ISO week, a time-zone offset
parser that refused `+9:00` while accepting `+24:00`, and `FORMAT` refusing four flags
BigQuery accepts while spelling `inf` as `+Inf`. Every one was green for as long as nothing
ran the line. That is the argument for measuring coverage here at all — not the percentage,
but the list of lines no case has ever executed, read one at a time.

`fn_format.zig` is the sharpest case: 59.2% to 99.7%, and of the 117 lines the corpus had
never run, the `%g` renderer alone was 66 of them — a complete Go `strconv` port that no
query had ever called.

## Regenerating this document

The tables come from `coverage.json` in each report directory:

```python
import json
d = json.load(open('zig-out/coverage/spec-report/kcov-merged/coverage.json'))
d["percent_covered"], d["covered_lines"], d["total_lines"]
[(f["file"], f["covered_lines"], f["total_lines"]) for f in d["files"]]
```

For the per-line detail behind a single file, `codecov.json` in the same directory maps a
repo-relative path to `{line: hits}`; the zero-hit entries, grouped into runs, are the list
worth reading.
