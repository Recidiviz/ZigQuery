#!/usr/bin/env python3
"""Boundary values for every BigQuery type, read back through both APIs.

Imported from the Recidiviz bigquery-emulator fork's
`test/python/extreme_values_test.py`. The cases and their expectations are that
file's; the harness is not — upstream's `BigQueryEmulatorTestCase` brings
testcontainers, Docker, pandas and pandas_gbq, none of which this repo has. So
this keeps the cases and drops the scaffolding, in the shape `storage_probe.py`
already uses: point it at a running emulator, or at real BigQuery.

A value can survive one path and not the other, which is what this checks for.
The REST path renders every cell to text through Go's `fmt.Sprint` and parses
it back; the Storage path writes an Arrow buffer with a declared type. A
TIMESTAMP of year 1 is the case that separates them — it is nowhere near the
int64 micros range a naive encoder assumes, and it round-trips through text
differently than through a fixed-width buffer.

Upstream reads the Storage side with `to_dataframe(bqstorage_client=...)`; this
uses `to_arrow`, which needs no pandas and is stricter: pandas coerces a
`datetime.date` to a `Timestamp` and cannot represent year 1 or 9999 in
`datetime64[ns]` at all, so a dataframe comparison quietly comes down to
whatever pandas chose. `to_arrow().to_pylist()` hands back the
`datetime`/`date`/`Decimal` objects the expectations are written in.

Usage:
    zig build server -- --project=test --dataset=ds1 &
    uv run tools/extreme_values.py

    # check the expectations themselves against the real service
    uv run tools/extreme_values.py --endpoint=bigquery \\
        --project=recidiviz-bigquery-sandbox
"""
import argparse
import datetime
import sys
from decimal import Decimal
from typing import Any

import grpc
from google.api_core.client_options import ClientOptions
from google.api_core.exceptions import NotFound
from google.auth.credentials import AnonymousCredentials
from google.cloud import bigquery, bigquery_storage_v1
from google.cloud.bigquery_storage_v1.services.big_query_read.transports import (
    BigQueryReadGrpcTransport,
)

UTC = datetime.timezone.utc

# (name, sql, expected single row). Verbatim from upstream, including the issue
# links, which are the reason several of these exist at all.
CASES: list[tuple[str, str, dict[str, Any]]] = [
    (
        # goccy/go-zetasqlite#132 and goccy/bigquery-emulator#262.
        "timestamp_min_max",
        "SELECT TIMESTAMP '0001-01-01 00:00:00.000000+00' AS min_ts, "
        "TIMESTAMP '9999-12-31 23:59:59.999999+00' AS max_ts",
        {
            "min_ts": datetime.datetime(1, 1, 1, 0, 0, tzinfo=UTC),
            "max_ts": datetime.datetime(9999, 12, 31, 23, 59, 59, 999999, tzinfo=UTC),
        },
    ),
    (
        "int64_min_max",
        "SELECT -9223372036854775808 AS min_int64, 9223372036854775807 AS max_int64",
        {"min_int64": -9223372036854775808, "max_int64": 9223372036854775807},
    ),
    (
        # 38 digits, 9 after the point.
        "numeric_min_max",
        "SELECT NUMERIC '-99999999999999999999999999999.999999999' AS min_numeric, "
        "NUMERIC '99999999999999999999999999999.999999999' AS max_numeric",
        {
            "min_numeric": Decimal("-99999999999999999999999999999.999999999"),
            "max_numeric": Decimal("99999999999999999999999999999.999999999"),
        },
    ),
    (
        "bignumeric_min_max",
        "SELECT BIGNUMERIC "
        "'-578960446186580977117854925043439539266.34992332820282019728792003956564819968'"
        " AS min_bignumeric, BIGNUMERIC "
        "'578960446186580977117854925043439539266.34992332820282019728792003956564819967'"
        " AS max_bignumeric",
        {
            "min_bignumeric": Decimal(
                "-578960446186580977117854925043439539266"
                ".34992332820282019728792003956564819968"
            ),
            "max_bignumeric": Decimal(
                "578960446186580977117854925043439539266"
                ".34992332820282019728792003956564819967"
            ),
        },
    ),
    (
        "date_min_max",
        "SELECT DATE '0001-01-01' AS min_date, DATE '9999-12-31' AS max_date",
        {"min_date": datetime.date(1, 1, 1), "max_date": datetime.date(9999, 12, 31)},
    ),
    (
        "datetime_min_max",
        "SELECT DATETIME '0001-01-01 00:00:00' AS min_datetime, "
        "DATETIME '9999-12-31 23:59:59.999999' AS max_datetime",
        {
            "min_datetime": datetime.datetime(1, 1, 1, 0, 0, 0),
            "max_datetime": datetime.datetime(9999, 12, 31, 23, 59, 59, 999999),
        },
    ),
    (
        "time_min_max",
        "SELECT TIME '00:00:00' AS min_time, TIME '23:59:59.999999' AS max_time",
        {"min_time": datetime.time(0, 0, 0), "max_time": datetime.time(23, 59, 59, 999999)},
    ),
]


def connect(rest_endpoint: str | None, grpc_endpoint: str, project: str):
    """A REST client and a Storage client, for the emulator or the real thing.

    The emulator needs an explicit insecure channel rather than only an
    `api_endpoint`: that redirects the address but leaves the channel on TLS,
    and the emulator answers a ClientHello with HTTP/2. It also sidesteps
    credentials, since an insecure channel carries none.
    """
    if rest_endpoint is None:
        return bigquery.Client(project=project), bigquery_storage_v1.BigQueryReadClient()
    bq = bigquery.Client(
        project=project,
        credentials=AnonymousCredentials(),
        client_options=ClientOptions(api_endpoint=rest_endpoint),
    )
    bqs = bigquery_storage_v1.BigQueryReadClient(
        transport=BigQueryReadGrpcTransport(channel=grpc.insecure_channel(grpc_endpoint)),
    )
    return bq, bqs


def read_rest(bq, sql: str) -> list[dict[str, Any]]:
    """`QueryJob.result()` — the REST path, one cell at a time as text."""
    return [{k: row.get(k) for k in row.keys()} for row in bq.query(sql).result()]


def read_arrow(bq, bqs, sql: str) -> list[dict[str, Any]]:
    """`result().to_arrow(bqstorage_client=...)` — the Storage path.

    This is what a caller actually does, and it works: a query job's destination
    table is registered when the job runs, as a virtual table over the rows the
    job already holds. It used to raise `NotFound`, which is why
    `--storage-via=table` exists — that flag is now a way to test the Arrow
    encoder against a plain table, not a way around a gap.
    """
    return bq.query(sql).result().to_arrow(bqstorage_client=bqs).to_pylist()


def read_arrow_via_table(bq, bqs, sql: str, project: str, dataset: str, name: str):
    """The same values over Storage, but materialized into a table first.

    What the test can do while the query path's destination table is missing:
    it exercises the same Arrow encoder over the same values, so it still
    answers "does Arrow carry this type's extremes", which is what these cases
    are for. It cannot answer "does the query path work", which is the
    recorded gap.
    """
    fq = f"{project}.{dataset}.{name}"
    bq.query(f"CREATE OR REPLACE TABLE `{fq}` AS {sql}").result()
    try:
        table = bq.get_table(fq)
        return bq.list_rows(table).to_arrow(bqstorage_client=bqs).to_pylist()
    finally:
        bq.query(f"DROP TABLE `{fq}`").result()


def compare(name: str, api: str, want: dict[str, Any], got: list[dict[str, Any]]) -> bool:
    if got == [want]:
        print(f"ok    {name:<20} {api}")
        return True
    print(f"FAIL  {name:<20} {api}")
    if len(got) != 1:
        print(f"        expected 1 row, got {len(got)}")
        return False
    for key, expected in want.items():
        actual = got[0].get(key, "<missing>")
        if actual != expected:
            print(f"        {key}:")
            print(f"          want {expected!r}")
            print(f"          got  {actual!r}")
    return False


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="localhost:9060",
                    help="Storage host:port, or 'bigquery' for the real service")
    ap.add_argument("--rest-endpoint", default="http://localhost:9050",
                    help="REST base URL; ignored for --endpoint=bigquery")
    ap.add_argument("--project", default="test")
    ap.add_argument("--dataset", default="ds1",
                    help="where --storage-via=table puts its scratch table")
    ap.add_argument("--api", default="both", choices=("both", "rest", "arrow"))
    ap.add_argument("--storage-via", default="query", choices=("query", "table"),
                    help="'query' is what a caller does; 'table' materializes "
                         "first, to test Arrow while the query path's "
                         "destination table is missing")
    ap.add_argument("--case", action="append",
                    help="run only these cases (repeatable)")
    args = ap.parse_args()

    rest = None if args.endpoint == "bigquery" else args.rest_endpoint
    bq, bqs = connect(rest, args.endpoint, args.project)

    cases = CASES
    if args.case:
        wanted = set(args.case)
        cases = [c for c in CASES if c[0] in wanted]
        missing = wanted - {c[0] for c in cases}
        if missing:
            print(f"no such case: {', '.join(sorted(missing))}", file=sys.stderr)
            return 2

    failures = 0
    for name, sql, want in cases:
        if args.api in ("both", "rest"):
            try:
                failures += not compare(name, "REST ", want, read_rest(bq, sql))
            except Exception as err:  # noqa: BLE001 - a failure is a result
                print(f"FAIL  {name:<20} REST  {type(err).__name__}: {err}")
                failures += 1
        if args.api in ("both", "arrow"):
            try:
                if args.storage_via == "table":
                    got = read_arrow_via_table(
                        bq, bqs, sql, args.project, args.dataset, f"extreme_{name}",
                    )
                else:
                    got = read_arrow(bq, bqs, sql)
                failures += not compare(name, "ARROW", want, got)
            except NotFound as err:
                print(f"FAIL  {name:<20} ARROW {err}")
                print("        the query path's destination table is missing — "
                      "it should be registered when the job runs; "
                      "--storage-via=table isolates whether Arrow itself is at "
                      "fault")
                failures += 1
            except Exception as err:  # noqa: BLE001 - a failure is a result
                print(f"FAIL  {name:<20} ARROW {type(err).__name__}: {err}")
                failures += 1

    print(f"\n{failures} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
