# Python integration tests

End-to-end tests that drive the emulator through the official
`google-cloud-bigquery` and `google-cloud-bigquery-storage` clients.

Ported from `test/python` in
[Recidiviz/bigquery-emulator](https://github.com/Recidiviz/bigquery-emulator)
at `bc199f3796a9` (branch `candidate/rb20251028`). The file layout is kept the
same as upstream's so a re-sync is a plain diff; the changes made here are
listed under [Differences from upstream](#differences-from-upstream).

## Running

Needs [uv](https://docs.astral.sh/uv/). uv installs the Python version in
`.python-version` itself.

### Against a local build (no Docker)

```bash
# from the repo root
zig build dist -Drelease=true \
    -Dshim-dylib=bazel-bin/shim/libgooglesql_shim.dylib \
    -Dshim-static-obj=bazel-bin/shim/libgooglesql_shim_static_macos.o \
    --prefix zig-out/dist

cd test/python
BIGQUERY_EMULATOR_BINARY=$PWD/../../zig-out/dist/bin/zigquery-server uv run pytest -n 4
```

### Against the Docker image (what CI runs)

```bash
cd test/python
uv run pytest -n 4                   # ghcr.io/recidiviz/zigquery-emulator:latest

# a locally built image
BIGQUERY_EMULATOR_REPOSITORY=zigquery-emulator BIGQUERY_EMULATOR_VERSION=ci \
    uv run pytest -n 4
```

CI's `python integration` job builds the image from the same static `dist`
binary a release ships and runs the suite against it.

### Environment variables

| Variable | Default | |
|---|---|---|
| `BIGQUERY_EMULATOR_BINARY` | unset | Path to a `zigquery-server`. When set, the emulator runs as a subprocess and Docker is not used. |
| `BIGQUERY_EMULATOR_REPOSITORY` | `ghcr.io/recidiviz/zigquery-emulator` | Image repository. |
| `BIGQUERY_EMULATOR_VERSION` | `latest` | Image tag. |

Each test class starts its own emulator on REST port `60050 + N` and gRPC port
`61050 + N`, where `N` is the pytest-xdist worker number.

## Known failures

`KNOWN_FAILURES` in `conftest.py` marks the tests this emulator does not pass
yet as `xfail(strict=True)`. Strict means a test that starts passing fails the
run: when a change fixes one, remove its entry.

## Differences from upstream

- **Launching.** `utils/big_query_emulator_container.py` gains
  `BigQueryEmulatorProcess` and a `create_emulator()` factory, which the
  fixtures and `BigQueryEmulatorTestCase` use instead of constructing the
  container directly. The container passes only flags as its command, since
  this image's `ENTRYPOINT` is already the server, and defaults to
  `ghcr.io/recidiviz/zigquery-emulator`.
- **Fail fast on upload 500s.** `load_table_from_file` retries through
  `google-resumable-media`, which upstream's `_should_retry` patch does not
  reach, so every 500 there cost about 65 seconds of backoff. The fixtures now
  also drop 500 from `google.resumable_media.common.RETRYABLE`.
- **Tests that asserted Go-emulator bugs** now assert BigQuery's behaviour:
  - `test_integer_type_alias`: `CAST(NULL AS INTEGER)` succeeds. Upstream
    asserted that it raises, marking that as a bug to fix.
  - `test_array_agg_ignore_nulls`, `test_array_agg_with_nulls`: column `a` is
    `NULLABLE`. BigQuery rejects the whole `insertAll` request when one row
    leaves a `REQUIRED` field null, so the null row upstream relies on never
    loads.
  - `test_invalid_data_load_fails`: a value that does not convert comes back
    as a per-row `insertErrors` entry and nothing is stored, rather than as a
    500.

## Writing tests

Subclass `BigQueryEmulatorTestCase` for per-class emulator setup and teardown
and helpers such as `create_mock_table`, `load_rows_into_table` and
`run_query_test`:

```python
from google.cloud import bigquery
from utils.big_query_emulator_test_case import BigQueryAddress, BigQueryEmulatorTestCase


class TestMyQueries(BigQueryEmulatorTestCase):
    def test_with_table(self) -> None:
        address = BigQueryAddress(dataset_id="test_ds", table_id="test_table")
        self.create_mock_table(
            address,
            schema=[
                bigquery.SchemaField("name", "STRING"),
                bigquery.SchemaField("age", "INTEGER"),
            ],
        )
        self.load_rows_into_table(
            address, data=[{"name": "Alice", "age": 30}, {"name": "Bob", "age": 25}]
        )
        self.run_query_test(
            f"SELECT name FROM `{self.project_id}.{address.to_str()}` WHERE age > 26",
            expected_result=[{"name": "Alice"}],
        )
```

Plain pytest classes can use the fixtures in `conftest.py` instead:
`bq_emulator`, `bq_client`, `bq_storage_client` and `clean_emulator_data`.
