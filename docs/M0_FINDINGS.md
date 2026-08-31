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

**Since superseded, half of it.** SQLite is now the amalgamation compiled into
the binary, so the `/opt/homebrew` rpath and the `-change`/copy steps for
`libsqlite3.dylib` are gone — `otool -L` shows only `@rpath/libgooglesql_shim.dylib`
and `libSystem`. The shim lines and the mandatory `codesign` still stand.

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

---

# M1 findings — minimal end-to-end REST

## The client does not use the endpoint the plan assumed

`google.cloud.bigquery.Client.query()` does **not** call the `jobs.query`
endpoint. It posts `jobs.insert`, polls `jobs.get` until
`status.state == "DONE"`, then reads `getQueryResults`. Implementing only
`jobs.query` left the Python client spinning in a retry loop.

M1 therefore implements four endpoints, not two. The `bigquery#job` resource
shape was captured from the running Go emulator rather than guessed.

## Two more corrections found by observation

- **`maxResults` is ignored entirely by `jobs.query`** — in the body *and* the
  query string. The truncation (rows cut while `totalRows` still reports the
  full count) lives only in `getQueryResults`. The plan had this backwards.
- **`dryRun` does not suppress results**; the response still carries rows.

## Verification, and its limit

Passing:
- 63 server unit tests, every response assertion backed by captured Go bytes.
- All 17 golden cases byte-identical to the Go emulator **over the wire**,
  error bodies included.
- The real `google.cloud.bigquery` client (3.38.0): scalars, nulls, booleans,
  floats, arrays, structs, aggregates, empty arrays — correct values and
  correct Python types.

Not yet runnable, and why:
- **`extreme_values_test.py`** runs every query twice, once through the
  Storage Arrow API. Storage is deferred by decision, so this suite cannot
  pass before M6.
- **`emulator_test.py` — the entire file.** `BigQueryEmulatorTestCase.tearDown`
  calls `_wipe_emulator_data()`, which calls `list_datasets()` on *every*
  test. So the whole suite needs the datasets surface no matter what an
  individual test does. The plan's M1 line "`emulator_test.py -k 'simple or
  select'`" was optimistic for that reason; those tests unlock in M2, not by
  selecting a subset now.

## Deferred within M1, deliberately

**ChangedCatalog** was scheduled for M1 because `CREATE TABLE AS SELECT`
needs it. It turns out not to: the engine applies DDL itself, and
`ChangedCatalog` is only needed to mirror table metadata into the metadata
store — which does not exist until M2. DDL through `jobs.insert` works today
(there is a test for CREATE/INSERT/SELECT across requests). Moved to M2,
where it has a consumer.

**Discovery** serves a minimal document rather than the Go emulator's 535 KB
one. The clients fetch it but drive requests from their compiled-in surface;
the full document is worth copying in when the handler surface grows to match
it.

## Sharp edges in Zig 0.16 worth remembering

- `std.http.Server.Request.readerExpectNone` documents *"Invalidates the
  string memory inside Head"* — `head.target` must be copied out **before**
  the body is read, or it dangles. This segfaults rather than misbehaving.
- `std.http.Server` derives `max_head_len` from the connection reader's
  buffer length, so that buffer sizes the request head limit.
- `std.time.milliTimestamp` is gone; read `std.c.gettimeofday` as
  `internal/catalog.zig` already does.
- Mutually recursive JSON writers need explicit error sets
  (`std.mem.Allocator.Error!void`), or inference deadlocks.

# Static-linking the googlesql shim

Both release products shipped as a `bin/` + `lib/` pair, the shim dylib
dynamically loaded via rpath. Folding the shim into each executable so
`zig build` produces a single self-contained binary was tried two ways.

**Embed the dylib bytes and `dlopen` an extracted copy at process start**
worked end to end — a spike embedded a real 56MB dylib via `@embedFile`,
extracted it, and called a real ICU code path through it correctly, from a
directory unrelated to the build tree. Rejected anyway: writing a dylib to
a runtime-writable path and `dlopen`ing it from there is the exact pattern
endpoint security tooling on managed devices flags as suspicious, and the
extracted copy's code-signing provenance is a separate concern on managed
macOS fleets.

**True static linking** is what shipped. `-r` (the relocatable link a
static merge needs) cannot combine with `-dead_strip` — `ld` refuses with
"`-r and -dead_strip cannot be used together`" — and Zig's own
`link_gc_sections` does not recover the loss either: a binary built with it
on and one built with it off were byte-identical. Static linking therefore
ships the shim's full, undead-stripped closure — `exe`/`server_exe` each
carry their own copy rather than sharing one dylib, so `dist/` grew from
one shared ~53MB dylib to roughly ~77MB (CLI) and ~90MB (server) each.

## Mechanism

`shim/BUILD.bazel`: `cc_library` (`shim_lib`) → `cc_static_library`
(`shim_archive`, merges the transitive closure into one archive) → a
genrule per platform running `ld -r -Wl,-force_load,shim_archive
-Wl,-exported_symbols_list=<GoogleSQL_* glob>` (macOS) / `ld -r
-Wl,--whole-archive shim_archive -Wl,--no-whole-archive` then `objcopy
--wildcard --keep-global-symbol='GoogleSQL_*'` (Linux) — demoting every
symbol but the 13 `GoogleSQL_*` entry points to local binding, the same
isolation the dylib's export list already gave it, recreated at static-link
time instead of dynamic-load time. `rules_cc` needed no version bump:
`cc_static_library` was already resolved to 0.2.15 in this repo's module
graph, just not declared as a direct `bazel_dep` until now.

Two sharp edges found building this, both reproducible rather than
theoretical:

- `cc_static_library` merges only source-compiled deps. ICU is a
  `rules_foreign_cc` `configure_make` build, contributes no object files,
  and `bazel build //shim:shim_archive --output_groups=linkdeps` names it
  as the one dependency left out of the merge. Re-added via a `filegroup`
  per `out_static_libs` entry, selected by the `OutputGroupInfo` name
  `configure_make` registers each static lib under — `@icu//:icu`'s own
  `DefaultInfo` bundles the libs together with a propagated headers
  directory, which a linker cannot take as an input.
- `ld -r` with only an archive on the command line and nothing to
  reference it pulls in zero members: archives resolve on demand, and a
  bare archive has no root symbol asking for anything. `-Wl,-force_load`
  (macOS) / `--whole-archive`/`--no-whole-archive` (GNU ld) is required,
  not optional, for a relocatable object built this way.
- `-Wl,-x` (local-symbol-table stripping) is safe on the dylib's own final
  `-shared` link but corrupts thread-local-variable relocations when
  applied to a `-r` object destined for a further link: a binary built
  against a `-x`'d version of the static object crashed at dyld startup
  with "malformed thread-local, offset ... is larger than total size".
  Left off the static object for this reason, not for size.
