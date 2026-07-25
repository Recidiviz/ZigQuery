# M0 findings — concurrency & foundations

Experiments gating the bigquery-emulator server port. Baseline commit `87cff5a`
(746 PASS / 0 FAIL / 2 SKIP, 288 unit tests).

## R1 — Is the analyzer stack safe to drive from N threads, one Db each?

**Result: yes, by the byte-equality gate. 10/10 clean runs at 14 threads × 500
iterations.** Run it with `zig build analyzer-threads -Drelease=true -- <iters> <threads>`.

`harness/analyzer_threads.zig` runs three tiers:

- **A — translate only.** Analyzer + extractor + transformer, no SQLite.
  13 statements chosen to reach the libraries most likely to hold process-wide
  state: RE2 (`REGEXP_*`), ICU (`NORMALIZE`, non-ASCII `UPPER`), the protobuf
  descriptor pool (STRUCT/ARRAY catalogs via `SimpleCatalog::Deserialize`), and
  absl status formatting (three deliberate analysis-error cases).
- **B — full stack.** Each thread owns a private `Db`, running 9 UDF-heavy
  queries. This is exactly the server's intended pool discipline.
- **C — positive control.** `GENERATE_UUID()` uniqueness. See below.

Both A and B compare a digest against a single-threaded oracle, so any
divergence — not just a crash — is caught.

### The positive control matters, and initially lied

Tier C exists to answer "can this harness detect a race at all?" `uuid_seed`
(`src/internal/function/fn_net.zig:21`) is a plain non-threadlocal global
mutated with a non-atomic `+%=`, so it is a known race.

The first version of tier C reported **0 duplicates** — the control silently
failed, which would have made tiers A/B meaningless. One UUID per query hides
the race behind the ~0.5 ms analyzer round trip. Generating many UUIDs inside
one statement fixed the sensitivity.

That change then reported **19996/20000 duplicates**, which was also wrong — it
turned out to be a *different* bug (below), not a race. Only after separating
"duplicate" from "never produced" counters, and fixing that bug, did the
control behave correctly:

| | duplicates |
|---|---|
| 1 thread | 0 / 5000 |
| 4 threads | 200 / 20000 |

Clean single-threaded, races under threads. The harness is provably sensitive.

> **Keep `uuid_seed` racy until M5.** Tier C's validity depends on it. When the
> race is fixed (moving the seed into the per-connection `function.State`),
> tier C must be replaced with another known-racy control or it silently stops
> validating anything.

## Bug found: every scalar UDF was registered `SQLITE_DETERMINISTIC`

`SELECT GENERATE_UUID() FROM UNNEST(GENERATE_ARRAY(1, 5000))` returned **one
UUID repeated 5000 times**, single-threaded. `SQLITE_DETERMINISTIC` lets SQLite
hoist a constant-argument call out of the row loop and evaluate it once per
query. BigQuery returns a distinct UUID per row.

The corpus never caught this — per its own source comment, it only asserts
`LENGTH()`.

Fixed: `sqlite.Db.createScalarFunction` takes a `deterministic` flag,
`bind.FuncInfo` carries `deterministic: bool = true`, and `generate_uuid` is
marked `false`. Regression test added in `driver.zig`, since the corpus cannot
catch it. Aggregates and window functions were already registered without the
flag.

## R2 — ThreadSanitizer

**Result: impractical, as anticipated.** `zig build analyzer-threads -Dtsan=true`
builds, then SIGSEGVs (exit 139) with no output at all — even at 1 thread and 1
iteration, i.e. before `main` prints its header. It is not detecting a race; it
cannot start. Instrumenting the Zig side while linking a 54 MB uninstrumented
C++ dylib that statically contains its own absl/protobuf/ICU/RE2 breaks TSan's
shadow-memory assumptions.

The `-Dtsan` option is kept for a future attempt paired with
`bazel build --features=tsan //zig:libgooglesql_shim.dylib`.

Mitigation, per plan: the byte-equality gate is the accepted weaker signal —
credible because it caught the `uuid_seed` race unaided — and `--workers=1`
stays a documented escape hatch, defaulted in CI.

## R4 — Catalog sync cursor can permanently lose another connection's DDL

**Result: confirmed, and wider than expected.**

`Catalog.sync` (`src/internal/catalog.zig`) stamps `last_synced_at` with
wall-clock time captured *before* it reads, then selects
`WHERE updatedAt >= cursor`. A commit stamped before that cursor but made
visible after the read is never loaded.

The window is not instantaneous: a writer stamps `updatedAt` at the *start* of
its DDL, before the ~0.5 ms analyzer round trip. So the window is milliseconds
wide.

Added `Catalog.invalidateSyncCursor()` and a deterministic regression test in
`driver.zig` that back-dates a catalog row behind an advanced cursor, shows the
table is unreachable, then shows a cursor reset recovers it.

## R8 — Binary is not relocatable

**Result: confirmed, and there are two baked absolute rpaths, not one.**

- `LC_RPATH` → `<googlesql>/bazel-bin/zig` (for `@rpath/libgooglesql_shim.dylib`)
- `LC_RPATH` → `/opt/homebrew/opt/sqlite/lib`, which is **vestigial**:
  `libsqlite3.dylib` is linked by absolute path, not `@rpath`.

Working recipe for `-Dserver-portable` (verified running from `/`):

```sh
install_name_tool -delete_rpath <googlesql>/bazel-bin/zig  exe
install_name_tool -add_rpath    @loader_path               exe
install_name_tool -change /opt/homebrew/opt/sqlite/lib/libsqlite3.dylib \
                          @rpath/libsqlite3.dylib          exe
codesign -f -s - exe    # REQUIRED on macOS after install_name_tool
```

plus copying `libgooglesql_shim.dylib` and `libsqlite3.dylib` next to the exe.
The `codesign` step was not in the plan and is mandatory.

## R12 — `vfs=memdb`

**Result: available and working.** Verified both via the sqlite3 CLI and a
two-`Db` Zig test (`driver.zig`, "memdb VFS shares one database across
connections"). The pool can use `file:/<name>?vfs=memdb` for `--database=:memory:`
and avoid shared-cache `SQLITE_LOCKED`, which `busy_timeout` does not retry.

## Driver additions landed (all behaviour-preserving)

`zig build test` and `zig build corpus` verified green after each.

| Addition | Notes |
|---|---|
| `pub OutputColumn` + `Rows.columnTypes()` | Result schema for the REST API |
| `Db.openWith(OpenOptions{pragmas, busy_timeout_ms})` | `open()` delegates; pragmas applied before UDF registration and catalog init so `journal_mode=WAL` precedes the first write |
| `sqlite.Db.busyTimeout`, `Stmt.clearBindings` | `Stmt.reset()` already existed with no callers; the raw cache is its first user |
| `Db.rawExec` / `rawQuery` + `RawArg`/`RawValue`/`RawRows` | Go's `WithQueryFormattingDisabled`. Per-Db statement cache with a reentrancy guard: a second concurrent `rawQuery` on the same SQL gets its own statement instead of resetting one an open cursor is stepping |
| `Catalog.invalidateSyncCursor()` | See R4 |

Test count 288 → 296.

One gotcha worth remembering: `StringHashMapUnmanaged` keys are `[]const u8`, so
a `dupeZ` key is freed one byte short of its allocation. Use `dupe`.
