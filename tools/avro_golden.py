#!/usr/bin/env python3
"""Reference Avro datums, as Zig string literals, for src/server/grpc/avro.zig.

Round-tripping the emulator's encoder through the emulator's own decoder would
prove nothing -- and there is no decoder anyway. Every failure mode that matters
here is silent: a union branch index written backwards, a decimal in the wrong
byte order, an array missing its terminating zero block. All of them produce
plausible bytes that a reader turns into wrong values rather than an error.

So the expected bytes come from fastavro, which is not this project's code, and
are checked into the test verbatim.

Usage:
    uv run tools/avro_golden.py            # print the Zig literals
    uv run tools/avro_golden.py --check    # re-derive and diff against the test
"""
import argparse
import decimal
import json
import io
import sys

import fastavro


def datum(schema, value) -> bytes:
    buf = io.BytesIO()
    fastavro.schemaless_writer(buf, schema, value)
    return buf.getvalue()


def zig_literal(raw: bytes) -> str:
    return '"' + "".join(f"\\x{b:02x}" for b in raw) + '"'


# Each case is (zig_test_name, avro_schema, value). The schemas are the ones
# BigQuery really sends -- see testdata/storage/bigquery_avro_schema.json.
NULLABLE_LONG = ["null", "long"]
NUMERIC = {"type": "bytes", "logicalType": "decimal", "precision": 38, "scale": 9}
BIGNUMERIC = {"type": "bytes", "logicalType": "decimal", "precision": 77, "scale": 38}

CASES = [
    # --- integers: zigzag varint, the encoding everything else is built on ---
    ("long_zero", "long", 0),
    ("long_one", "long", 1),
    ("long_minus_one", "long", -1),
    ("long_64", "long", 64),
    ("long_min", "long", -(2**63)),
    ("long_max", "long", 2**63 - 1),
    ("int_date_epoch", {"type": "int", "logicalType": "date"}, 0),

    # --- the other primitives ---
    ("bool_true", "boolean", True),
    ("bool_false", "boolean", False),
    ("double_1_5", "double", 1.5),
    ("double_neg", "double", -3.25),
    ("string_hello", "string", "hello"),
    ("string_empty", "string", ""),
    ("string_utf8", "string", "héllo→"),
    ("bytes_nul", "bytes", b"\x00\xff"),

    # --- the branch index, which is the whole risk for nullable columns ---
    ("nullable_long_null", NULLABLE_LONG, None),
    ("nullable_long_value", NULLABLE_LONG, -2),

    # --- decimals: byte order and minimal length ---
    ("numeric_1_2345", NUMERIC, decimal.Decimal("1.234500000")),
    ("numeric_zero", NUMERIC, decimal.Decimal("0")),
    ("numeric_neg", NUMERIC, decimal.Decimal("-1.5")),
    ("numeric_max", NUMERIC, decimal.Decimal("99999999999999999999999999999.999999999")),
    ("bignumeric_neg_1_5", BIGNUMERIC, decimal.Decimal("-1.5")),

    # --- arrays: the terminating zero block ---
    ("array_empty", {"type": "array", "items": "long"}, []),
    ("array_one", {"type": "array", "items": "long"}, [7]),
    ("array_three", {"type": "array", "items": "long"}, [1, 2, 3]),
    ("array_bool", {"type": "array", "items": "boolean"}, [True, False]),

    # --- records ---
    (
        "struct_a_b",
        {
            "type": "record",
            "name": "__s_0",
            "fields": [
                {"name": "a", "type": NULLABLE_LONG},
                {"name": "b", "type": ["null", "string"]},
            ],
        },
        {"a": 1, "b": "x"},
    ),
    (
        "interval_1y2m3d",
        {
            "type": "record",
            "namespace": "google.sqlType",
            "name": "INTERVAL",
            "fields": [
                {"name": "months", "type": "int"},
                {"name": "days", "type": "int"},
                {"name": "microseconds", "type": "long"},
            ],
        },
        {"months": 14, "days": 3, "microseconds": 14706000000},
    ),
    (
        "range_date",
        {
            "type": "record",
            "namespace": "google.sqlType",
            "name": "RANGE_DATE",
            "fields": [
                {"name": "start", "type": ["null", {"type": "int", "logicalType": "date"}]},
                {"name": "end", "type": ["null", {"type": "int", "logicalType": "date"}]},
            ],
        },
        {"start": 20454, "end": 20485},
    ),
    (
        "range_date_unbounded",
        {
            "type": "record",
            "namespace": "google.sqlType",
            "name": "RANGE_DATE",
            "fields": [
                {"name": "start", "type": ["null", {"type": "int", "logicalType": "date"}]},
                {"name": "end", "type": ["null", {"type": "int", "logicalType": "date"}]},
            ],
        },
        {"start": None, "end": None},
    ),
    ("datetime_string", {"type": "string", "logicalType": "datetime"},
     "2026-01-01T12:00:00.123456"),
]


# A whole row against the schema the emulator itself emits. The per-type schema
# assertions in avro_test.zig pin that schema against the one BigQuery really
# sent; this pins the datums against a reader that is not ours. Between them, a
# schema and an encoder that disagree about whether a field carries a union
# cannot both pass.
FULL_SCHEMA = json.loads(r"""{"type": "record", "name": "__root__", "fields": [{"name": "c_req_int64", "type": "long"}, {"name": "c_int64", "type": ["null", "long"]}, {"name": "c_float64", "type": ["null", "double"]}, {"name": "c_numeric", "type": ["null", {"type": "bytes", "logicalType": "decimal", "precision": 38, "scale": 9}]}, {"name": "c_bignumeric", "type": ["null", {"type": "bytes", "logicalType": "decimal", "precision": 77, "scale": 38}]}, {"name": "c_bool", "type": ["null", "boolean"]}, {"name": "c_string", "type": ["null", "string"]}, {"name": "c_bytes", "type": ["null", "bytes"]}, {"name": "c_date", "type": ["null", {"type": "int", "logicalType": "date"}]}, {"name": "c_datetime", "type": ["null", {"type": "string", "logicalType": "datetime"}]}, {"name": "c_time", "type": ["null", {"type": "long", "logicalType": "time-micros"}]}, {"name": "c_timestamp", "type": ["null", {"type": "long", "logicalType": "timestamp-micros"}]}, {"name": "c_json", "type": ["null", {"type": "string", "sqlType": "JSON"}]}, {"name": "c_interval", "type": ["null", {"type": "record", "namespace": "google.sqlType", "name": "INTERVAL", "fields": [{"name": "months", "type": "int"}, {"name": "days", "type": "int"}, {"name": "microseconds", "type": "long"}]}]}, {"name": "c_range_date", "type": ["null", {"type": "record", "namespace": "google.sqlType", "name": "RANGE_DATE", "sqlType": "RANGE", "fields": [{"name": "start", "type": ["null", {"type": "int", "logicalType": "date"}]}, {"name": "end", "type": ["null", {"type": "int", "logicalType": "date"}]}]}]}, {"name": "c_array", "type": {"type": "array", "items": "long"}}, {"name": "c_struct", "type": ["null", {"type": "record", "name": "__s_0", "fields": [{"name": "a", "type": ["null", "long"]}, {"name": "b", "type": ["null", "string"]}]}]}]}""")

FULL_ROW = {
    "c_req_int64": 7,
    "c_int64": -2,
    "c_float64": 1.5,
    "c_numeric": decimal.Decimal("1.234500000"),
    "c_bignumeric": decimal.Decimal("-1.50000000000000000000000000000000000000"),
    "c_bool": True,
    "c_string": "hello",
    "c_bytes": b"\x00\xff",
    "c_date": 20454,
    "c_datetime": "2026-01-01T12:00:00.123456",
    "c_time": 43200123456,
    "c_timestamp": 1767225600000123,
    "c_json": '{"a":1}',
    "c_interval": {"months": 14, "days": 3, "microseconds": 14706000000},
    "c_range_date": {"start": 20454, "end": 20485},
    "c_array": [1, 2, 3],
    "c_struct": {"a": 1, "b": "x"},
}

CASES.append(("full_row", FULL_SCHEMA, FULL_ROW))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true",
                    help="verify the literals in the Zig test still match")
    args = ap.parse_args()

    produced = {name: datum(schema, value) for name, schema, value in CASES}

    if not args.check:
        print("/// GENERATED by tools/avro_golden.py -- bytes produced by fastavro,")
        print("/// not by this project. Regenerate with `uv run tools/avro_golden.py`.")
        print("const golden = struct {")
        for name, raw in produced.items():
            print(f"    const {name} = {zig_literal(raw)};")
        print("};")
        return 0

    src = open("src/server/grpc/avro_test.zig").read()
    missing = [n for n, raw in produced.items()
               if f"const {n} = {zig_literal(raw)};" not in src]
    if missing:
        print("stale or absent golden cases:", ", ".join(missing))
        return 1
    print(f"ok   all {len(produced)} golden cases match fastavro")
    return 0


if __name__ == "__main__":
    sys.exit(main())
