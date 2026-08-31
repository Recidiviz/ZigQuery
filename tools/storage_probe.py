#!/usr/bin/env python3
"""Drive the BigQuery Storage Read API with the stock client library.

harness/grpc_smoke.zig already round-trips a call against the transport, but it
speaks gRPC core directly. This speaks the stack real callers use --
google-cloud-bigquery-storage on top of grpcio -- which is a meaningfully
different thing: a trailers-only UNIMPLEMENTED reply is something gRPC core
tolerates but a client posting RECV_INITIAL_METADATA hangs on. Compatibility
bugs live in that gap.

It points at the emulator by default and at real BigQuery with
`--endpoint=bigquery`, which is the point: the Avro schema the emulator returns
has to match the one BigQuery returns, and the only way to know what BigQuery
returns is to ask it.

Usage:
    # against the emulator
    zig build server -- --project=test --dataset=ds1 &
    uv run tools/storage_probe.py
    uv run tools/storage_probe.py --expect=ok --dump

    # against real BigQuery: create a one-row table with every type, read it,
    # print the Avro schema and the raw row bytes, then drop it again
    uv run tools/storage_probe.py --endpoint=bigquery \\
        --project=recidiviz-bigquery-sandbox --dataset=zigquery_probe \\
        --create-fixture --expect=ok --dump --drop-fixture
"""
import argparse
import json
import sys

import grpc
from google.api_core import exceptions as gexc
from google.cloud import bigquery_storage_v1
from google.cloud.bigquery_storage_v1.services.big_query_read.transports import (
    BigQueryReadGrpcTransport,
)

EXPECTED = {
    "unimplemented": gexc.MethodNotImplemented,
    "ok": None,
}

# One column per type the emulator might ever have to encode, plus a NOT NULL
# column: everything BigQuery creates is NULLABLE by default, and the difference
# between a bare Avro type and a ["null", T] union is exactly what needs seeing.
FIXTURE_DDL = """
CREATE OR REPLACE TABLE `{table}` (
  c_req_int64    INT64 NOT NULL,
  c_int64        INT64,
  c_float64      FLOAT64,
  c_numeric      NUMERIC,
  c_bignumeric   BIGNUMERIC,
  c_bool         BOOL,
  c_string       STRING,
  c_bytes        BYTES,
  c_date         DATE,
  c_datetime     DATETIME,
  c_time         TIME,
  c_timestamp    TIMESTAMP,
  c_json         JSON,
  c_geography    GEOGRAPHY,
  c_interval     INTERVAL,
  c_range_date   RANGE<DATE>,
  c_array        ARRAY<INT64>,
  c_struct       STRUCT<a INT64, b STRING>,
  c_array_struct ARRAY<STRUCT<x INT64, y STRING>>
)
"""

FIXTURE_ROW = """
INSERT INTO `{table}` (
  c_req_int64, c_int64, c_float64, c_numeric, c_bignumeric, c_bool, c_string,
  c_bytes, c_date, c_datetime, c_time, c_timestamp, c_json, c_geography,
  c_interval, c_range_date, c_array, c_struct, c_array_struct
)
SELECT
  7, -2, 1.5,
  NUMERIC '1.234500000', BIGNUMERIC '-1.5',
  TRUE, 'hello', b'\\x00\\xff',
  DATE '2026-01-01', DATETIME '2026-01-01 12:00:00.123456',
  TIME '12:00:00.123456', TIMESTAMP '2026-01-01 00:00:00.000123 UTC',
  JSON '{{"a":1}}', {geography},
  INTERVAL '1-2 3 4:5:6' YEAR TO SECOND,
  RANGE<DATE> '[2026-01-01, 2026-02-01)',
  [1, 2, 3], STRUCT(1 AS a, 'x' AS b),
  [STRUCT(1 AS x, 'y' AS y)]
"""

# GoogleSQL has no GEOGRAPHY literal -- a value has to come from a constructor
# -- and the emulator's engine implements none of them. The column still exists
# on both sides, so its schema is compared for real; only the value is NULL,
# which is the only GEOGRAPHY the engine can produce anyway (there is no such
# `Value` variant, as avro.zig's mapping table records).
GEOGRAPHY_VALUE = {
    "bigquery": "ST_GEOGPOINT(1, 2)",
    "emulator": "CAST(NULL AS GEOGRAPHY)",
}


def connect(endpoint: str) -> bigquery_storage_v1.BigQueryReadClient:
    """A client for the emulator, or for real BigQuery.

    For the emulator, `ClientOptions(api_endpoint=...)` alone is not enough: it
    redirects the address but leaves the channel on TLS, and the emulator
    answers a ClientHello with HTTP/2, so the handshake fails with
    WRONG_VERSION_NUMBER and the client retries for its full 600 s deadline.
    Handing the transport an explicit insecure channel is the documented
    emulator path, and it also sidesteps credentials entirely -- an insecure
    channel carries no call credentials, so no ADC lookup happens on a machine
    that has none.

    `--endpoint=bigquery` means the real thing: default construction, TLS, ADC.
    """
    if endpoint == "bigquery":
        return bigquery_storage_v1.BigQueryReadClient()
    transport = BigQueryReadGrpcTransport(channel=grpc.insecure_channel(endpoint))
    return bigquery_storage_v1.BigQueryReadClient(transport=transport)


def run_sql(project: str, dataset: str, sql: str, rest_endpoint: str | None) -> None:
    """One DDL/DML statement, waited on. Imported lazily so the emulator path
    does not need google-cloud-bigquery at all.

    `rest_endpoint` is None for real BigQuery -- default construction, TLS, ADC
    -- and an http:// base URL for the emulator, which needs anonymous
    credentials too: the client looks for ADC otherwise and fails on a machine
    that has none, having never been about to send them anywhere.
    """
    from google.cloud import bigquery

    if rest_endpoint is None:
        client = bigquery.Client(project=project)
    else:
        from google.api_core.client_options import ClientOptions
        from google.auth.credentials import AnonymousCredentials

        client = bigquery.Client(
            project=project,
            credentials=AnonymousCredentials(),
            client_options=ClientOptions(api_endpoint=rest_endpoint),
        )
    client.create_dataset(f"{project}.{dataset}", exists_ok=True)
    client.query(sql).result()


def dump(session, client, fmt: str) -> None:
    """The schema and the first response's raw rows, verbatim.

    This is the reference the emulator's encoder is written against, so it is
    printed rather than summarised -- a summary is where a wrong logical type or
    a wrong Arrow field flag would hide.
    """
    if fmt == "AVRO":
        print("\n--- avro_schema.schema ---")
        print(json.dumps(json.loads(session.avro_schema.schema), indent=2))
    else:
        raw = session.arrow_schema.serialized_schema
        print(f"\n--- arrow_schema.serialized_schema ({len(raw)} bytes) ---")
        print(raw.hex())
        print("\n--- decoded by pyarrow ---")
        print(arrow_schema(raw))

    if not session.streams:
        print("\n(no streams)")
        return
    print("\n--- ReadRows ---")
    for i, resp in enumerate(client.read_rows(session.streams[0].name)):
        if fmt == "AVRO":
            raw = resp.avro_rows.serialized_binary_rows
        else:
            raw = resp.arrow_record_batch.serialized_record_batch
            # Whether the first message repeats the schema is exactly what the
            # Python reader depends on when `rows()` is called without a session.
            which = resp._pb.WhichOneof("schema")
            print(f"response {i}: schema oneof = {which!r}")
        print(f"response {i}: row_count={resp.row_count} {len(raw)} bytes")
        print(raw.hex())
        if fmt == "ARROW":
            print("\n--- batch decoded by pyarrow ---")
            print(arrow_batch(session.arrow_schema.serialized_schema, raw))
        if i == 0:
            break


def client_read(project: str, dataset: str, table: str, endpoint: str,
                rest_endpoint: str | None) -> int:
    """The read a real caller does: `list_rows(...).to_arrow(bqstorage_client=)`.

    Worth its own mode because it exercises two things `probe` cannot. It asks
    for ARROW and LZ4_FRAME -- google-cloud-bigquery does so unconditionally
    on this path, `_pandas_helpers.py` -- and the emulator answers uncompressed,
    so this is the check that a conformant reader accepts uncompressed buffers
    whatever it requested. And it goes through the client's own reader rather
    than pyarrow directly, which is where a missing `arrow_schema` on the first
    message, or a batch that is not self-contained, would surface.
    """
    from google.cloud import bigquery

    if rest_endpoint is None:
        bq = bigquery.Client(project=project)
        bqs = bigquery_storage_v1.BigQueryReadClient()
    else:
        from google.api_core.client_options import ClientOptions
        from google.auth.credentials import AnonymousCredentials

        bq = bigquery.Client(
            project=project,
            credentials=AnonymousCredentials(),
            client_options=ClientOptions(api_endpoint=rest_endpoint),
        )
        bqs = bigquery_storage_v1.BigQueryReadClient(
            transport=BigQueryReadGrpcTransport(channel=grpc.insecure_channel(endpoint)),
        )

    ref = bq.get_table(f"{project}.{dataset}.{table}")
    got = bq.list_rows(ref).to_arrow(bqstorage_client=bqs)
    print(f"\nok   to_arrow(bqstorage_client=...) -> {got.num_rows} row(s)")
    print(got.schema)
    print(got.to_pylist())
    return 0


def arrow_schema(serialized: bytes):
    """The IPC schema message, as a pyarrow Schema.

    `read_message` wants an encapsulated message, which is exactly what the
    proto field carries -- schema and batches travel as separate standalone
    messages rather than as one stream.
    """
    import pyarrow as pa
    return pa.ipc.read_schema(pa.BufferReader(serialized))


def arrow_batch(serialized_schema: bytes, serialized_batch: bytes):
    import pyarrow as pa
    schema = arrow_schema(serialized_schema)
    msg = pa.ipc.read_message(pa.BufferReader(serialized_batch))
    batch = pa.ipc.read_record_batch(msg, schema)
    return batch.to_pylist()


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="localhost:9060",
                    help="host:port, or 'bigquery' for the real service")
    ap.add_argument("--project", default="test")
    ap.add_argument("--dataset", default="ds1")
    ap.add_argument("--table", default="t")
    ap.add_argument("--create-fixture", action="store_true",
                    help="create a one-row table with every type")
    ap.add_argument("--rest-endpoint", default="http://localhost:9050",
                    help="where --create-fixture sends its DDL; ignored for "
                         "--endpoint=bigquery, which uses the real service")
    ap.add_argument("--drop-fixture", action="store_true",
                    help="drop it again afterwards")
    ap.add_argument("--dump", action="store_true",
                    help="print the schema and the first rows as hex")
    ap.add_argument("--client-read", action="store_true",
                    help="also read the table through google-cloud-bigquery's "
                         "own Storage path, which asks for ARROW and LZ4_FRAME")
    ap.add_argument("--format", default="AVRO", choices=("AVRO", "ARROW"),
                    help="the data_format to ask the session for")
    ap.add_argument(
        "--expect",
        choices=sorted(EXPECTED),
        default="unimplemented",
        help="what a correct server does today",
    )
    args = ap.parse_args()

    fq = f"{args.project}.{args.dataset}.{args.table}"
    rest = None if args.endpoint == "bigquery" else args.rest_endpoint
    if args.create_fixture:
        print(f"creating {fq}")
        geography = GEOGRAPHY_VALUE["bigquery" if rest is None else "emulator"]
        run_sql(args.project, args.dataset, FIXTURE_DDL.format(table=fq), rest)
        run_sql(
            args.project,
            args.dataset,
            FIXTURE_ROW.format(table=fq, geography=geography),
            rest,
        )

    try:
        rc = probe(args)
        if rc == 0 and args.client_read:
            rc = client_read(
                args.project, args.dataset, args.table, args.endpoint, rest,
            )
        return rc
    finally:
        if args.drop_fixture:
            print(f"\ndropping {fq}")
            run_sql(args.project, args.dataset, f"DROP TABLE `{fq}`", rest)


def probe(args) -> int:
    client = connect(args.endpoint)
    parent = f"projects/{args.project}"
    table = f"projects/{args.project}/datasets/{args.dataset}/tables/{args.table}"

    want = EXPECTED[args.expect]
    try:
        session = client.create_read_session(
            parent=parent,
            read_session={"table": table, "data_format": args.format},
            max_stream_count=1,
        )
    except gexc.GoogleAPICallError as err:
        ok = want is not None and isinstance(err, want)
        print(f"{'ok  ' if ok else 'FAIL'} CreateReadSession -> "
              f"{type(err).__name__}: {err.message}")
        return 0 if ok else 1
    except Exception as err:  # noqa: BLE001 - a transport failure is a result
        print(f"FAIL CreateReadSession -> {type(err).__name__}: {err}")
        return 1

    if want is not None:
        print(f"FAIL CreateReadSession succeeded but {args.expect} was expected")
        return 1
    print(f"ok   CreateReadSession -> {len(session.streams)} stream(s)")
    if args.dump:
        dump(session, client, args.format)
    return 0


if __name__ == "__main__":
    sys.exit(main())
