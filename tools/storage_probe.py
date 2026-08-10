#!/usr/bin/env python3
"""Drive the BigQuery Storage Read API with the stock client library.

harness/grpc_smoke.zig already round-trips a call against the transport, but it
speaks gRPC *core* directly. This speaks the stack real callers use --
google-cloud-bigquery-storage on top of grpcio -- which is a meaningfully
different thing: the first version of the emulator's UNIMPLEMENTED reply used a
trailers-only response, which gRPC core tolerates and a client posting
RECV_INITIAL_METADATA hangs on. Compatibility bugs live in that gap.

Until CreateReadSession is implemented (S3), a clean UNIMPLEMENTED *is* the
pass condition: it proves a stock client reached the service and got a status
it understands, rather than a connection error or a hang.

Usage:
    zig build server -- --project=test --dataset=ds1 &
    uv run tools/storage_probe.py
    uv run tools/storage_probe.py --endpoint=localhost:9060 --expect=unimplemented
"""
import argparse
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


def connect(endpoint: str) -> bigquery_storage_v1.BigQueryReadClient:
    """A cleartext client.

    `ClientOptions(api_endpoint=...)` alone is not enough: it redirects the
    address but leaves the channel on TLS, and the emulator answers a
    ClientHello with HTTP/2, so the handshake fails with WRONG_VERSION_NUMBER
    and the client retries for its full 600 s deadline. Handing the transport
    an explicit insecure channel is the documented emulator path, and it also
    sidesteps credentials entirely -- an insecure channel carries no call
    credentials, so no ADC lookup happens on a machine that has none.
    """
    transport = BigQueryReadGrpcTransport(channel=grpc.insecure_channel(endpoint))
    return bigquery_storage_v1.BigQueryReadClient(transport=transport)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--endpoint", default="localhost:9060")
    ap.add_argument("--project", default="test")
    ap.add_argument("--dataset", default="ds1")
    ap.add_argument("--table", default="t")
    ap.add_argument(
        "--expect",
        choices=sorted(EXPECTED),
        default="unimplemented",
        help="what a correct server does today; flip to 'ok' once S3 lands",
    )
    args = ap.parse_args()

    client = connect(args.endpoint)
    parent = f"projects/{args.project}"
    table = (
        f"projects/{args.project}/datasets/{args.dataset}/tables/{args.table}"
    )

    want = EXPECTED[args.expect]
    try:
        session = client.create_read_session(
            parent=parent,
            read_session={"table": table, "data_format": "AVRO"},
            max_stream_count=1,
        )
    except gexc.GoogleAPICallError as err:
        got = type(err)
        ok = want is not None and isinstance(err, want)
        print(f"{'ok  ' if ok else 'FAIL'} CreateReadSession -> {got.__name__}: {err.message}")
        return 0 if ok else 1
    except Exception as err:  # noqa: BLE001 - a transport failure is a result
        print(f"FAIL CreateReadSession -> {type(err).__name__}: {err}")
        return 1

    if want is not None:
        print(f"FAIL CreateReadSession succeeded but {args.expect} was expected")
        return 1
    print(f"ok   CreateReadSession -> {len(session.streams)} stream(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
