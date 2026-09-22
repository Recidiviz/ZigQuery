# Build commands

Everything is driven by `zig build`. `zig build --help` prints the step list
with one-line descriptions; this file explains what each step is for, what it
accepts, and which ones CI runs.

Run a step as `zig build <step>`. Build options (`-D...`) go before `--`;
anything after `--` is passed to the program the step launches:

```sh
zig build spec -Drelease=true -- --filter zigquery/ --verbose
```

## Prerequisites

1. [Install `anyzig` version manager](https://marler8997.github.io/anyzig/):

```bash
brew tap anyzig/tap && brew install anyzig
```

### MacOS

#### Quickstart (skip googlesql compliation)

1. [Download the
   `googlesql` shim dylib from the latest release](https://github.com/Recidiviz/zigquery/releases/)
2. Move the dylib to `./bazel-bin/shim/libgooglesql_shim.dylib`
3. [Run something!](./BUILD.md) - be sure to pass the dylib option

```bash
zig build spec -Dshim-dylib=./bazel-bin/shim/libgooglesql_shim.dylib
```

#### Full Build

1. [Install bazelisk version manager](https://bazel.build/install/bazelisk)

```bash
brew install bazelisk
```

2. Build the statically-linked shim and the dynamically-linked dylib

```bash
# build directly with bazel
bazel build -c opt //shim:libgooglesql_shim_static_macos
bazel build -c opt //shim:libgooglesql_shim.dylib

# or let zig build it for you
zig build -Dbuild-shim=true
```

3. [Run something!](./BUILD.md)

```bash
zig build server -Dbuild-shim=true
```

The first `zig build` compiles gRPC and its dependencies from source, which takes a few minutes;
relinks afterward take seconds.
SQLite and nanoarrow are compiled from the amalgamation and tarball pinned in `build.zig.zon`.
Those three are always built ReleaseFast whatever `-Drelease` says.

## Build options

| Option                       | Default                                                   | What it does                                                                                                                                                                            |
|------------------------------|-----------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `-Drelease=[bool]`           | `false` (Debug)                                           | `true` selects ReleaseFast. This build declares `-Drelease`, not `-Doptimize`.                                                                                                          |
| `-Dtarget=`, `-Dcpu=`        | host                                                      | Standard Zig target selection. Release builds pass `-Dcpu=baseline` so the vendored C/C++ does not assume the build machine's CPU.                                                      |
| `-Dshim-dylib=<path>`        | `bazel-bin/shim/libgooglesql_shim.{dylib,so}`             | The shim shared library, relative to the repo root. The file name follows the target OS. Linked by every dev, test and harness binary.                                                  |
| `-Dbuild-shim=[bool]`        | `false`                                                   | Run `bazel build -c opt //shim:<platform dylib>` before any step that links the dylib.                                                                                                  |
| `-Dshim-static-obj=<path>`   | `bazel-bin/shim/libgooglesql_shim_static_{macos,linux}.o` | The statically linkable shim object. Only `zigquery-cli` and `zigquery-server` link it, so they run without a sibling `lib/`.                                                           |
| `-Dbuild-shim-static=[bool]` | `false`                                                   | Run Bazel for the static object before building `cli` / `bigquery-emulator`.                                                                                                            |
| `-Dcodec-timers=[bool]`      | `false`                                                   | Instrument the value codec phases. Required by `codec-bench`. Off otherwise: each span costs ~18 ns and a real workload takes millions of them, which distorts the path being measured. |
| `-Dtsan=[bool]`              | `false`                                                   | Build `analyzer-threads` and `shared-catalog-threads` with ThreadSanitizer. Zig side only; the C++ shim needs its own `bazel build --features=tsan`.                                    |

Generic `zig build` flags worth knowing:

* `--prefix <dir>` changes where `install` and `dist` write (release.yml stages into `stage/`)
* `--verbose` prints every command
* `-j<N>` limits parallelism
* `--watch` rebuilds on change

## Steps

### Everyday

| Step                | What it does                                                                                                                                                                                                                                                                         |
|---------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `install` (default) | Build and copy all ten installable binaries to `zig-out/bin`: `zigquery-cli`, `zigquery-server`, `spec-runner`, `spec-ui`, `analyzer-threads`, `shared-catalog-threads`, `codec-bench`, `tz-bench`, `bench-engine`, `gsql-bench`. Most are harnesses; use `dist` for a release tree. |
| `uninstall`         | Remove what `install` copied to the prefix.                                                                                                                                                                                                                                          |
| `test`              | Engine unit tests (the `src/root.zig` module).                                                                                                                                                                                                                                       |
| `test-server`       | Emulator unit tests (the `src/server/root.zig` module).                                                                                                                                                                                                                              |
| `spec`              | Replay the conformance corpus under `testdata/specs/**/*.zon`. Exits nonzero on a regression against `testdata/spec_baseline.txt`; with `--strict`, on any failure.                                                                                                                  |
| `run`               | Run the CLI (`cli`) with the arguments after `--`.                                                                                                                                                                                                                                   |
| `server`            | Run the emulator (`bigquery-emulator`) with the arguments after `--`.                                                                                                                                                                                                                |

**`spec`** accepts:

```
zig build spec -- [--filter SUBSTR] [--case SUBSTR]
                  [--dialect googlesql|bigquery|zigquery]
                  [--verbose] [--markdown] [--update-baseline] [--strict]
```

- `--filter` selects spec files by path substring;
- `--case` selects cases by description within them.
  Together they narrow the run to one query.
- `--strict` is what CI passes. Without it the runner only gates on regression
  against the baseline, so a case that never passed can start returning wrong
  answers and still exit 0. `UNSUPPORTED` and `SKIP` stay non-fatal either way.
- `--update-baseline` rewrites `testdata/spec_baseline.txt` from the current run.
- `--markdown` prints a per-category table. It replays every case, so CI
  reuses the log of the plain run instead of invoking it.
- `DUMP_SQL=<path> zig build spec` writes every statement the engine hands to
  SQLite, grouped by case, to that path. Diff it against
  `testdata/sql_snapshot.txt` to review an SQL-builder change as a diff rather
  than as a delta in one byte count.

The runner resolves `testdata/specs` against the repo root;
the step sets the working directory for you.

**`run`** is the CLI:

```
zig build run -- [--sql] [--file <path>] [--stats] [--explain] ["SELECT ..."]
```

- `--sql` prints the generated SQLite SQL instead of executing.
- `--file F` runs every statement in `F` first, against the same in-memory database.
  With no query of its own it runs (or explains) the script's last statement.
- `--explain` prints SQLite's `EXPLAIN QUERY PLAN` for the final statement's translated SQL.
- `--stats` prints where the statement's time went, phase by phase.

**`server`** runs the emulator server and accepts flags in `--flag=value` form only:

```
zig build server -- --project=my-project [--dataset=D] [--host=0.0.0.0] [--port=9050]
                    [--grpc-port=9060] [--database=<path>] [--data-from-json=<file>]...
                    [--log-level=error] [--log-format=console]
```

`--project` is required. `--data-from-json` may be repeated.

### Debugging

| Step           | What it does                                                                                                                                                                                                                         |
|----------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `install-spec` | Install only `zig-out/bin/spec-runner`. Faster than `install` when you want a debug target for one spec case.                                                                                                                        |
| `install-test` | Install the `test` and `test-server` binaries to `zig-out/tests/engine-tests` and `zig-out/tests/server-tests`, so a debugger has a stable path to attach to. These are the same artifacts the test steps run, not a second compile. |
| `spec-ui`      | Run the corpus and browse the results in a local web UI. `zig build spec-ui -- [--filter SUBSTR] [--dialect D] [--port N]`; the default port is 8091.                                                                                |

The checked-in ZigBrains run configurations in `.run/` use `install-spec` and
`install-test` with `-Drelease=false`. Pass that explicitly from anything that
might inherit a release flag: under ReleaseFast a breakpoint resolves into
inlined code and the enclosing function's arguments are gone.

### Release

| Step   | What it does                                                                                                                                                                                         |
|--------|------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `dist` | Install only the two shipped products, `cli` and `bigquery-emulator`, each statically linked against the shim. A tarball of `zig-out/bin` is the release tree and runs from wherever it is unpacked. |

CI builds it as:

```sh
zig build dist -Drelease=true -Dcpu=baseline \
  -Dshim-dylib=<path> -Dshim-static-obj=<path> --prefix "$PWD/stage"
```

### Code generation and static analysis

| Step            | What it does                                                                                                                                                                                                               |
|-----------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `gen-proto`     | Regenerate the protobuf codecs from the committed `.fdset` files, then `zig fmt` them. Run when the googlesql submodule or a descriptor moves; never part of `test`. CI fails if the outputs drift from what is committed. |
| `ephor`         | Run ephor static analysis over the tree. Arguments after `--` go to ephor; `-- --summary` prints the TOTAL. CI fails when TOTAL exceeds the ceiling in `ephor_baseline.txt`, so lower the ceiling when you fix findings.   |
| `ephor-upgrade` | Upgrade the ephor tool to its latest version.                                                                                                                                                                              |

`gen-proto` writes three files:

| Input                          | Output                                                                                                       |
|--------------------------------|--------------------------------------------------------------------------------------------------------------|
| `proto/googlesql.fdset`        | `src/proto/resolved_ast.zig` (engine; also the generator's own decoder, so the generator is self-hosting)    |
| `proto/bigquery_storage.fdset` | `src/server/proto/storage.zig` (Storage Read API, wire codecs)                                               |
| `proto/bigquery_v2.fdset`      | `src/server/proto/bigquery.zig` (REST surface, JSON codecs only, pruned to the RPCs the emulator implements) |

`gen-proto` and `ephor` are host tools that never link the engine, so neither needs the shim.

### Coverage
#### Prerequisites

Both steps need kcov. To install on MacOS: `brew install kcov`. [To install on Linux, follow these instructions.](https://github.com/SimonKagstrom/kcov/blob/master/INSTALL.md)

#### Steps
They build the module tree a second time at Debug
whatever `-Drelease` says, because optimized line coverage measures the inliner
rather than the tests.

| Step            | Report                                    | What it measures                                                                          |
|-----------------|-------------------------------------------|-------------------------------------------------------------------------------------------|
| `coverage`      | `zig-out/coverage/report/index.html`      | The engine and server unit tests (`test` + `test-server`), run under kcov and merged.     |
| `coverage-spec` | `zig-out/coverage/spec-report/index.html` | The spec corpus. Accepts the same `--` arguments as `spec`, e.g. `-- --filter zigquery/`. |

The two reports are kept separate on purpose:
a line the corpus reaches is asserted against a published expected value,
while a line a unit test reaches is asserted against whatever that test says.

See `docs/COVERAGE.md` before quoting a number.

### Harnesses with positive controls

Not benchmarks, and not part of `test`: each carries a control that must fail,
and exits nonzero when it does not, so a broken build cannot quietly pass. CI
runs all three at `-Drelease=true`.

| Step                     | Arguments                                                       | What it checks                                                                                                                                                                                                                                    |
|--------------------------|-----------------------------------------------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `analyzer-threads`       | `[iterations] [threads]` (default 2000, CPU count)              | Can N threads each drive their own `Db` safely through the analyzer, SQLite and the UDFs. The control is `GENERATE_UUID` uniqueness.                                                                                                              |
| `shared-catalog-threads` | `[tables_per_thread] [threads]` (default 40, min(8, CPU count)) | Does one `SharedCatalog` make a connection pool coherent. The control run with per-connection catalogs must fail.                                                                                                                                 |
| `grpc-smoke`             | none                                                            | Round-trips real gRPC calls against the Storage Read transport: UNIMPLEMENTED from our handler, a second call on one channel, UNAVAILABLE after `stop()`. Kept out of `test-server` because gRPC core aborts rather than fails on a bad shutdown. |

`-Dtsan=true` applies to the first two. `grpc-smoke` is run-only and is not
installed by `install`.

### Benchmarks

Run these with `-Drelease=true`; a Debug build prints a warning and the numbers
are not comparable.

| Step           | Arguments                                                                                   | What it measures                                                                                                                                                                                                                  |
|----------------|---------------------------------------------------------------------------------------------|-----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `bench`        | `[queries_per_size] [catalog_sizes...]` (default 2000 over 1, 50, 500)                      | Per-query cost as a function of catalog size, with a fresh `CREATE TABLE` between timed queries so the catalog delta is never empty.                                                                                              |
| `gsql-bench`   | `[--time MS] [--iters N] [--filter SUBSTR] [--corpus DIR] [--phases] [--markdown] [--json]` | The googlesqlite corpus vendored under `testdata/bench_corpus`, reported in the same shape as upstream's RESULTS.md. `--json` is what `bench.yml` charts; `--markdown` goes to the run summary. Default budget 1000 ms per query. |
| `codec-bench`  | `[rows]` (default 200000)                                                                   | Value codec cost with real rows. Needs `-Dcodec-timers=true`.                                                                                                                                                                     |
| `tz-bench`     | `[rows]` (default 200000)                                                                   | Per-row cost of named-timezone resolution, the A/B point for the ICU tzdata integration.                                                                                                                                          |
| `load-bench`   | none                                                                                        | Whether a delete forces work proportional to catalog size. Run-only, not installed.                                                                                                                                               |
| `insert-bench` | `<body.json> <schema.json>`                                                                 | Phase timing of a captured `tabledata.insertAll` request body. Run-only, not installed.                                                                                                                                           |
