# ⚡️ZigQuery - A BigQuery Emulator

<p style="text-align: center;">
  <strong>A BigQuery emulator server, built on a GoogleSQL and SQLite.</strong><br />
  Focused on query engine correctness, performance, throughput, and stability
</p>


<p style="text-align: center;">
<picture>
  <source type="image/svg+xml" media="(prefers-color-scheme: dark)" srcset="./docs/bench/emubench-dark.svg">
  <source type="image/svg+xml" media="(prefers-color-scheme: light)" srcset="./docs/bench/emubench-light.svg">
</picture>
<em>Measured on an M4 Macbook using Docker AMD64 emulation</em>
</p>

## Why Zig?

[GoogleSQL](https://github.com/google/googlesql)'s query analyzer powers the core of the emulator.
It is written in C++ and requires a complex build system configured in Bazel.
Zig can link C natively, so interop becomes nearly free.

Intentional, explicit control over memory allocation improves process stability.

## Usage
```
docker pull ghcr.io/recidiviz/zigquery:latest
```

```
Usage:
  zigquery-server --project=<name> [OPTIONS]

A local BigQuery emulator serving the REST API and the Storage Read API.

Flags take the form --name=value.

Options:
  --project=<name>        project ID to serve (required)
  --dataset=<name>        create an empty dataset with this ID at startup
  --host=<addr>           address both servers bind (default: 0.0.0.0)
  --port=<port>           REST API port (default: 9050)
  --grpc-port=<port>      Storage Read API gRPC port; 0 picks a free port (default: 9060)
  --database=<path>       SQLite file to store data in; :memory: or empty keeps data in memory (default: :memory:)
  --data-from-json=<path> load datasets and tables from a JSON file at startup; repeatable, files load in order
  --log-level=<level>     accepted for compatibility; currently ignored
  --log-format=<format>   accepted for compatibility; currently ignored
  -h, --help              show this help and exit
```

## Development Prerequisites

- Zig 0.17: the dev build specified by `minimum_zig_version` in `build.zig.zon`
  - `zig build ephor` also needs Zig 0.16, reached through a `zig` on PATH that
    honours `tools/ephor/build.zig.zon`, such as [anyzig](https://github.com/marler8997/anyzig)
- Bazel 7.6 + the [googlesql](https://github.com/google/googlesql) submodule
- `googlesql` analyzer shim, either downloaded or built
  - download: `googlesql-shim-<version>-<platform>.tar.gz` from a
    [release](https://github.com/Recidiviz/zigquery/releases), unpacked
    into `dist/shim/`, then pass `-Dshim-dylib=dist/shim/libgooglesql_shim.dylib`
    (`.so` on Linux). Neither Bazel nor the submodule is needed for this path.
  - macOS: `bazel build -c opt //shim:libgooglesql_shim.dylib`
  - Linux: `CC=clang CXX=clang++ bazel build -c opt //shim:libgooglesql_shim.so`
  - or `zig build -Dbuild-shim=true`, which picks the right target for the host
- `brew install kcov`, for `zig build coverage` only

A downloaded shim is only good for the commits that hash to the same shim
inputs. The tarball carries the `SHIM_KEY` that `.github/actions/shim` computed
for it, so when the analyzer starts behaving strangely — a bus error at the
first call, most likely — check that key against the one the action derives from
the working tree before looking anywhere else. Only the dylib is published: the
statically-linkable object that `zig build dist` consumes still comes from
Bazel, and so do the shipped binaries.

`//shim` has one `cc_binary` per platform because Mach-O and ELF need different
link lines (`@rpath` install names and `-exported_symbol` versus a soname and
`shim/shim.lds`), and a `cc_binary`'s output file is named after its target.
`zig build` follows the same split: `-Dshim-dylib` defaults to
`bazel-bin/shim/libgooglesql_shim.{dylib,so}` for the resolved `-Dtarget`.

On Linux, `.bazelrc` applies `--config=clang` unconditionally, so `CC`/`CXX`
have to point at clang or Bazel's default toolchain picks gcc and silently
ignores those flags.

## Build & test
See [BUILD.md](./docs/BUILD.md)

```sh
zig build test      # unit tests (engine)
zig build test-server  # unit tests (emulator)
zig build spec      # replay testdata/specs/**.zon (the conformance corpus)
zig build coverage  # line coverage -> zig-out/coverage/report/index.html
zig build ephor     # static analysis
zig build grpc-smoke   # round-trip a gRPC call against the Storage Read transport

zig build server -- --project=my-project   # run the emulator (--flag=value only)
zig build dist -Drelease=true              # release tree: zig-out/{bin,lib}

zig build gsql-bench -Drelease=true  # goccy/googlesqlite's bench corpus -> docs/BENCH_GSQL.md
```

`dist` is what a release ships: only `bigquery-emulator` and `zigquery`,
plus the shim in `lib/`. The binaries carry a second rpath
(`@loader_path/../lib`, `$ORIGIN/../lib` on ELF) so the tree keeps working
wherever it is unpacked — plain `install` writes eight harness and benchmark
binaries as well and only resolves the shim through its absolute build path.

`zig build gen-proto` regenerates the requisite protobuf codecs
— the engine's `src/proto/resolved_ast.zig` from `proto/googlesql.fdset`
- the server's `src/server/proto/storage.zig` from `proto/bigquery_storage.fdset`

`grpc-smoke` drives gRPC core in process. `uv run tools/storage_probe.py`
(against a running emulator) drives the same service through
`google-cloud-bigquery-storage` instead — a different client stack, and the two
disagree about enough that both are worth keeping.

`uv run tools/extreme_values.py` reads each type's boundary values back through
*both* APIs and checks they agree — the cases come from the Recidiviz
bigquery-emulator fork's `test/python/extreme_values_test.py`. Pointing it at
`--endpoint=bigquery` checks the expectations themselves against the real
service, which is where they came from.

`grpc-smoke` is not in `test-server` on purpose. gRPC's shutdown checks *abort*
rather than fail — destroying a server before its completion queue has drained
trips a `CHECK` inside core — and a mis-driven queue hangs. Either would take
down the gate CI runs on every PR, so it lives in its own step alongside
`analyzer-threads`, with positive controls and a nonzero exit.

`coverage` runs the engine and server unit tests under kcov and merges the two
runs. It builds at `-ODebug` whatever `-Doptimize` says, because optimized line
coverage measures inlining rather than tests. It covers `zig build test` and
`test-server` only — anything reached solely through `spec` reads as 0%.

### The spec corpus

`testdata/specs` holds three trees, each with its own `NOTICE`:

| Tree | Cases | Where its expectations come from |
|---|---:|---|
| `googlesql/`, `bigquery/` | 1012 | goccy/googlesqlite, whose values were scraped from the result tables printed in the GoogleSQL reference docs. Imported by `tools/spec_import.py`; do not hand-edit. |
| `zigquery/` | 748 | This engine's own regression suite, inherited from go-zetasqlite's `query_test.go`. Hand-maintained. |

Every `.zon` file under `testdata/specs` is a spec — the runner walks the tree,
so a new file needs no registration. `zigquery/` files declare `.typed = true`,
which asserts each expected value's *type* and not only its value; the imported
trees cannot, because a doc table does not say whether `42` was an INT64 or the
string `"42"`. See `src/internal/spec_expect.zig`.

`testdata/spec_baseline.txt` lists the `spec<TAB>desc` of every case that must
keep passing, and `zig build spec` exits nonzero on any regression. Regenerate
it with `zig build spec -- --update-baseline`.

`--strict`, which CI passes, is what makes this a real gate: without it the
runner gates only on regression against the baseline, so a case that has never
passed can start returning wrong answers and still exit 0. `UNSUPPORTED` and
`SKIP` stay non-fatal — they are the known-missing surface, catalogued in
[docs/SPEC_UNSUPPORTED.md](docs/SPEC_UNSUPPORTED.md), not wrong answers.

`DUMP_SQL=<path> zig build spec` writes every statement the engine hands to
SQLite, grouped by case, to that path. `testdata/sql_snapshot.txt` is the
committed one: diffing it is how a change to the SQL builder is reviewed as a
diff rather than as a delta in one aggregate byte count. `tools/sql_stats.py`
summarises one snapshot or the difference between two.

`zig build coverage` and `zig build coverage-spec` measure what the unit tests
and the corpus each execute. [docs/COVERAGE.md](docs/COVERAGE.md) has the
current figures and the two caveats worth knowing before quoting one: the runs
cannot be summed, and a line counts as covered once control reaches it.

## CI & releases

| Workflow | Trigger | What it does |
|---|---|---|
| `ci.yml` | PR, push | ephor + `zig fmt`, unit tests, the spec corpus under `--strict`, the concurrency harnesses, and a `gen-proto` drift check |
| `bench.yml` | push, `bench` label, manual | `gsql-bench --json` charted by github-action-benchmark on the `benchmarks` branch |
| `release.yml` | `v*.*.*` tag | four platform tarballs, a multi-arch GHCR image, and a GitHub release |

Runners are [RunsOn](https://runs-on.com) on EC2 (see `.github/runs-on.yml`).
Release builds for darwin run on GitHub-hosted larger runners:
`zigquery-mac-build` for arm64 and `zigquery-mac-build-x64` for x64, so each tarball is built and smoke-tested natively rather than
cross-compiled.

The shim is the expensive part of all of this and the least frequently changed,
so `.github/actions/shim` caches it against a hash of its real inputs — the
submodule pointer, `analyzer_shim.cc`, `shim.lds`, `shim/BUILD.bazel`,
`MODULE.bazel{,.lock}`, `.bazelrc` and `.bazelversion`. Ordinary PRs restore a
prebuilt library in seconds and never run bazel at all. The release job
publishes the dylib from that same cache entry as a per-platform asset, with
googlesql's Apache-2.0 license and the cache key alongside it.

Ephor is gated by a ceiling in `ephor_baseline.txt` rather than by its own
`fail_on`, for the reason recorded in that file.


# Sponsorship
The architecture comes from our work on the fork of [@goccy](https://github.com/goccy)'s original implementation.
We are very grateful for his contributions to open source software. Consider sponsoring goccy.