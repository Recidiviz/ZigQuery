#!/usr/bin/env python3
"""What real BigQuery detects from the CSVs test/python/csv_autodetect_test.py loads.

    uv run tools/load_autodetect_probe.py

Those tests were ported from the Go emulator's suite and have been xfail(strict=True) since,
so no assertion in them has ever run against anything. This loads the same bytes with the same
LoadJobConfig into the sandbox and reports the schema BigQuery detects, the values it stores,
and the load statistics -- so the emulator is built against measured behaviour rather than an
inherited claim.

Every request names the sandbox project explicitly: gcloud's default project is
recidiviz-dashboard-production, which this must never touch.
"""
import datetime
import io
import json
import sys

from google.cloud import bigquery

PROJECT = "recidiviz-bigquery-sandbox"
LOCATION = "US"

# Byte-for-byte the fixtures in test/python/csv_autodetect_test.py, keyed by that file's test.
CASES = {
    "basic_types": """name,age,score,active
Alice,30,95.5,true
Bob,25,88.0,false
""",
    "date_iso_format": """event,event_date
Birthday,2024-01-15
Anniversary,2024-12-31
""",
    "date_uk_format": """event,event_date
Birthday,15/01/2024
Anniversary,31/12/2024
""",
    "handles_nulls": """id,value,name
1,100,Alice
2,,Bob
3,null,Charlie
4,200,
""",
    "boolean_variants": """id,flag1,flag2,flag3
1,true,yes,Y
2,false,no,N
""",
    "mixed_types": """id,mixed_col
1,100
2,hello
3,200
""",
    "all_null_column": """id,empty_col
1,
2,null
3,
""",
}

# test_autodetect_with_existing_table loads into a table that already has a schema.
EXISTING_TABLE_CASE = ("existing_table", """name,value
Alice,100
Bob,200
""", [bigquery.SchemaField("name", "STRING"), bigquery.SchemaField("value", "INTEGER")])


def load(
    client,
    dataset,
    table_id,
    csv_data,
    schema=None,
    skip_leading_rows=0,
    config_schema=None,
    autodetect=True,
):
    """The gate tests' call. `skip_leading_rows=None` leaves the field off the request, which
    is what lets autodetect decide whether the first row is a header. `schema` pre-creates the
    destination; `config_schema` goes in the job configuration."""
    table_ref = bigquery.TableReference(
        bigquery.DatasetReference(PROJECT, dataset), table_id
    )
    if schema is not None:
        client.create_table(bigquery.Table(table_ref, schema=schema))

    job_config = bigquery.LoadJobConfig(
        source_format=bigquery.SourceFormat.CSV,
        autodetect=autodetect,
    )
    if config_schema is not None:
        job_config.schema = config_schema
    if skip_leading_rows is not None:
        job_config.skip_leading_rows = skip_leading_rows
    job = client.load_table_from_file(io.StringIO(csv_data), table_ref, job_config=job_config)
    try:
        job.result()
    except Exception as exc:  # a rejected load is itself a finding
        return {"failed": repr(exc), "error_result": job.error_result}

    table = client.get_table(table_ref)
    rows = [
        {name: _plain(row[name]) for name in (f.name for f in table.schema)}
        for row in client.query(
            f"SELECT * FROM `{PROJECT}.{dataset}.{table_id}`", location=LOCATION
        ).result()
    ]
    return {
        "schema": [
            {"name": f.name, "type": f.field_type, "mode": f.mode} for f in table.schema
        ],
        "rows": rows,
        "statistics": job._properties.get("statistics", {}).get("load"),
    }


def _plain(value):
    """Python objects the JSON dump can carry, with the type kept visible."""
    if value is None or isinstance(value, (bool, int, float, str)):
        return value
    return f"{type(value).__name__}:{value}"


# Which schema a load uses when more than one source offers one. The CSV autodetects to
# a:INTEGER, b:DATE, so any of the three is distinguishable in the result.
PRECEDENCE_CSV = """a,b
1,2024-01-15
2,2024-12-31
"""
STRINGS = [bigquery.SchemaField("a", "STRING"), bigquery.SchemaField("b", "STRING")]
EXISTING = [bigquery.SchemaField("a", "INTEGER"), bigquery.SchemaField("b", "STRING")]

PRECEDENCE = {
    # The undocumented case: a client that sends both.
    "config_schema_and_autodetect": {"config_schema": STRINGS, "autodetect": True},
    "config_schema_only": {"config_schema": STRINGS, "autodetect": False},
    "autodetect_only": {"autodetect": True},
    "all_three": {"config_schema": STRINGS, "autodetect": True, "schema": EXISTING},
    "config_schema_and_existing": {"config_schema": STRINGS, "autodetect": False, "schema": EXISTING},
}


def run_precedence(client, dataset):
    for name, kwargs in PRECEDENCE.items():
        print(f"# precedence/{name}", file=sys.stderr)
        try:
            result = load(
                client, dataset, name, PRECEDENCE_CSV, skip_leading_rows=None, **kwargs
            )
        except Exception as exc:
            result = {"harness_error": repr(exc)}
        print(json.dumps({f"precedence/{name}": result}, default=str))
        sys.stdout.flush()


def main():
    stamp = datetime.datetime.now().strftime("%Y%m%d_%H%M%S")
    dataset = f"zq_autodetect_{stamp}"

    client = bigquery.Client(project=PROJECT)
    ds = bigquery.Dataset(f"{PROJECT}.{dataset}")
    ds.location = LOCATION
    ds.default_table_expiration_ms = 60 * 60 * 1000
    client.create_dataset(ds)
    print(f"# dataset {dataset}", file=sys.stderr)

    results = {}
    # skipLeadingRows=0 says "no header row"; omitting it lets autodetect look for one. The
    # two are different requests, so every case runs both ways.
    variants = {"skip0": 0, "unset": None}
    try:
        if "--precedence" in sys.argv:
            run_precedence(client, dataset)
            return
        for name, csv_data in CASES.items():
            for variant, skip in variants.items():
                key = f"{name}/{variant}"
                print(f"# {key}", file=sys.stderr)
                try:
                    results[key] = load(
                        client, dataset, f"{name}_{variant}", csv_data, skip_leading_rows=skip
                    )
                except Exception as exc:
                    results[key] = {"harness_error": repr(exc)}
                print(json.dumps({key: results[key]}, default=str))
                sys.stdout.flush()

        name, csv_data, schema = EXISTING_TABLE_CASE
        for variant, skip in variants.items():
            key = f"{name}/{variant}"
            print(f"# {key}", file=sys.stderr)
            try:
                results[key] = load(
                    client,
                    dataset,
                    f"{name}_{variant}",
                    csv_data,
                    schema=schema,
                    skip_leading_rows=skip,
                )
            except Exception as exc:
                results[key] = {"harness_error": repr(exc)}
            print(json.dumps({key: results[key]}, default=str))
    finally:
        client.delete_dataset(f"{PROJECT}.{dataset}", delete_contents=True, not_found_ok=True)
        print(f"# deleted {dataset}", file=sys.stderr)


if __name__ == "__main__":
    main()
