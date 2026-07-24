# zetasqlite-zig

A Zig rebuild of [Recidiviz/go-zetasqlite](https://github.com/Recidiviz/go-zetasqlite):
a GoogleSQL (BigQuery dialect) → SQLite query translator. The internal
architecture mirrors the Go original verbatim — extractor → coordinator →
transformers → SQL object model, the tagged-binary value codec, `zetasqlite_*`
UDFs and collation, and the `zetasqlite_catalog` table. Only the
`database/sql` driver layer is redesigned (`src/sqlite.zig` + `src/driver.zig`
over the SQLite C API).

## Prerequisites

- Zig 0.16
- Bazel 7.6 + the [googlesql](https://github.com/google/googlesql) checkout at
  `~/workspace/googlesql` (or pass `-Dgooglesql-root=...`), with the analyzer
  shim built: `bazel build -c opt //zig:libgooglesql_shim.dylib` (or pass
  `-Dbuild-shim=true` to have `zig build` run it)
- Homebrew sqlite (`brew install sqlite`)

## Build & test

```sh
zig build test      # unit tests
zig build corpus    # replay testdata/corpus.json (the go-zetasqlite query_test.go suite)
```

The corpus (748 cases) is exported from the Go repo's `query_test.go` by
`corpus_export_test.go` there:

```sh
CORPUS_OUT=$PWD/testdata/corpus.json \
  (cd ~/go/github.com/Recidiviz/go-zetasqlite && go test -run TestExportCorpus .)
```

`testdata/baseline.txt` lists the case names that must pass; `zig build corpus`
exits nonzero on any regression.
