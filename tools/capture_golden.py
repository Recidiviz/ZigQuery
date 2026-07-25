#!/usr/bin/env python3
"""Capture golden REST responses from the Go bigquery-emulator.

The Zig server must reproduce these bytes. Several are deliberate deviations
from the BigQuery Go structs that clients nonetheless depend on:

  - `"v": null` is emitted, never omitted
  - `totalRows` is a JSON *string*
  - every scalar is rendered as a string, via Go's fmt.Sprint
  - floats use strconv.FormatFloat(v, 'g', -1, 64): 1e+21, -0, 1e-07
  - a NULL ARRAY becomes [], not null
  - schema uses legacy type names: INTEGER/FLOAT/BOOLEAN, not INT64/FLOAT64/BOOL
  - ARRAY<T> is {"mode":"REPEATED", "type":<T>}; STRUCT is type RECORD + fields
  - TIMESTAMP renders as Go's "sec.rem" ApiString, e.g. "1704193445.0"
  - BYTES render base64

Usage:
    go build -o /tmp/bqemu ./cmd/bigquery-emulator   # in the Go repo
    /tmp/bqemu --project=test --database=:memory: --port=19050 \
        --grpc-port=19060 --log-level=error &
    python3 tools/capture_golden.py > testdata/golden.json
"""
import json
import sys
import urllib.request

BASE = "http://127.0.0.1:19050"
PROJECT = "test"

# name -> SQL. Chosen for response-shape coverage, not SQL coverage.
CASES = [
    ("scalar_int", "SELECT 1 AS i"),
    ("scalar_null", "SELECT NULL AS n"),
    ("scalar_bool", "SELECT TRUE AS b, FALSE AS b2"),
    ("scalar_string", "SELECT 'hello' AS s"),
    ("strings_escaping", "SELECT 'a\"b' AS q, 'tab\there' AS t, 'é' AS uni"),
    ("floats", "SELECT 1.5 AS f, 1e21 AS big, -0.0 AS negz, 1e-7 AS small"),
    ("numeric", "SELECT CAST('1.2345' AS NUMERIC) AS n, CAST(1 AS BIGNUMERIC) AS bn"),
    ("array_simple", "SELECT [1,2,3] AS arr"),
    ("array_null", "SELECT CAST(NULL AS ARRAY<INT64>) AS nullarr"),
    ("array_empty", "SELECT [] AS e"),
    ("struct_simple", "SELECT STRUCT(1 AS a, 'x' AS b) AS s"),
    ("struct_nested", "SELECT STRUCT(1 AS a, [STRUCT(2 AS c)] AS b) AS s"),
    ("struct_null_field", "SELECT STRUCT(NULL AS a, 'x' AS b) AS s, CAST(NULL AS STRING) AS ns"),
    ("types_mix", "SELECT DATE '2024-01-02' AS d, TIMESTAMP '2024-01-02 03:04:05' AS ts, b'ab' AS raw"),
    ("multirow", "SELECT x FROM UNNEST([1,2,3]) AS x ORDER BY x"),
    ("error_table_not_found", "SELECT * FROM nonexistent_table_xyz"),
    ("error_syntax", "SELECT 1 +"),
]


def post(path, payload):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req) as r:
            return r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        return e.code, json.loads(e.read())


def normalize(obj):
    """Blank out server-generated ids so responses compare stably."""
    if isinstance(obj, dict):
        out = {}
        for k, v in obj.items():
            if k == "jobId":
                out[k] = "<JOBID>"
            elif k in ("datasetId", "tableId") and isinstance(v, str) and len(v) == 27:
                out[k] = "<RANDOMID>"
            else:
                out[k] = normalize(v)
        return out
    if isinstance(obj, list):
        return [normalize(v) for v in obj]
    return obj


def main():
    cases = []
    for name, sql in CASES:
        status, body = post(
            f"/projects/{PROJECT}/queries",
            {"query": sql, "useLegacySql": False},
        )
        cases.append(
            {
                "name": name,
                "query": sql,
                "status": status,
                "response": normalize(body),
            }
        )

    # jobs.query does not persist a job, so getQueryResults 404s for its id.
    status, body = post(f"/projects/{PROJECT}/queries", {"query": "SELECT 1 AS i", "useLegacySql": False})
    job_id = body["jobReference"]["jobId"]
    req = urllib.request.Request(f"{BASE}/projects/{PROJECT}/queries/{job_id}")
    try:
        with urllib.request.urlopen(req) as r:
            gr_status, gr_body = r.status, json.loads(r.read())
    except urllib.error.HTTPError as e:
        gr_status, gr_body = e.code, json.loads(e.read())
    gr_body = normalize(gr_body)
    if gr_status == 404:
        # The message embeds the random id; blank it for stable comparison.
        gr_body = json.loads(json.dumps(gr_body).replace(job_id, "<JOBID>"))
    cases.append(
        {
            "name": "get_query_results_unpersisted_job",
            "note": "jobs.query never writes a job row; only jobs.insert does",
            "status": gr_status,
            "response": gr_body,
        }
    )

    json.dump(
        {
            "source": "Recidiviz/bigquery-emulator (Go), captured via tools/capture_golden.py",
            "cases": cases,
        },
        sys.stdout,
        indent=2,
        ensure_ascii=False,
    )
    sys.stdout.write("\n")


if __name__ == "__main__":
    main()
