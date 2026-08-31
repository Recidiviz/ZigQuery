#!/usr/bin/env python3
"""Run spec corpus queries against this engine and against real BigQuery, and diff.

    zig build -Drelease=true
    uv run tools/vsbq.py testdata/specs/zigquery/functions/window/*.zon
    uv run tools/vsbq.py --jobs 16 --quiet testdata/specs/zigquery/**/*.zon

The spec corpus is the arbiter of what this engine answers, but its expected
values come from two places: the imported trees carry the GoogleSQL reference
docs' published output, and `zigquery/**` carries whatever this engine was
measured to do. Neither is BigQuery. This asks BigQuery, so a case that pins a
divergence stops looking like a passing case.

Findings go in `docs/bigquery_divergence_findings.md`, with the project and date
they were measured on — a service's behaviour is dated in a way a doc is not.

Three differences are reported apart from real ones, because each is a property
of the comparison rather than of the engine:

  - an anonymous column is `$col1` here and `f0_` there
  - a query with no top-level ORDER BY has no guaranteed row order either side
  - BigQuery renders TIMESTAMP as text where the CLI prints epoch seconds

The BigQuery client rather than the `bq` CLI: the CLI pays ~1s of Python startup
per query, which dominates a run of small queries. It also hands back native
Python values instead of strings, so `canon` maps both sides onto one spelling.

BigQuery's own result cache is asked for explicitly and its hits are reported. It
saves execution but not the round trip, so it shows up as a modest win. There is
no etag to lean on here: etags condition a read of a job or table resource, and
issuing a query is neither.

Exit status is 1 when a real divergence is found, so this can gate.
"""
import argparse
import base64
import concurrent.futures
import datetime
import decimal
import math
import re
import subprocess
import sys
import threading

from google.cloud import bigquery

ENGINE = "./zig-out/bin/zetasqlite-zig"

# `.sql = "..."` on one line, or a `\\`-prefixed multiline block.
DESC = re.compile(r'\s*\.desc = "((?:[^"\\]|\\.)*)"')
SPEC = re.compile(r'\s*\.spec = "([^"]*)"')
SQL_INLINE = re.compile(r'\s*\.sql = "((?:[^"\\]|\\.)*)",?\s*$')
SQL_BLOCK = re.compile(r"\s*\.sql =\s*$")
ESCAPES = {"n": "\n", "t": "\t", "r": "\r", '"': '"', "\\": "\\"}


def unquote(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == "\\" and i + 1 < len(s):
            out.append(ESCAPES.get(s[i + 1], s[i + 1]))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return "".join(out)


def cases(path):
    """(spec, desc, sql) for every case in a .zon spec file."""
    lines = open(path).read().split("\n")
    spec, desc, out, i = None, None, [], 0
    while i < len(lines):
        ln = lines[i]
        if m := SPEC.match(ln):
            spec = m.group(1)
        if m := DESC.match(ln):
            desc = unquote(m.group(1))
        if SQL_BLOCK.match(ln):
            body, i = [], i + 1
            while i < len(lines) and re.match(r"\s*\\\\", lines[i]):
                body.append(re.sub(r"^\s*\\\\", "", lines[i]))
                i += 1
            out.append((spec, desc, "\n".join(body).strip()))
            continue
        if m := SQL_INLINE.match(ln):
            out.append((spec, desc, unquote(m.group(1)).strip()))
        i += 1
    return out


def canon(v):
    """One canonical string for a cell, from either side.

    The client returns native Python values and the CLI returns text, so each
    kind is mapped onto whichever spelling the other already uses: a TIMESTAMP
    onto the CLI's epoch seconds, BYTES onto its base64, and DATE / DATETIME /
    TIME onto their ISO forms.
    """
    if v is None:
        return "NULL"
    if isinstance(v, list):
        return "[" + ",".join(canon(e) for e in v) + "]"
    if isinstance(v, dict):
        return "{" + ",".join(f"{k}:{canon(x)}" for k, x in v.items()) + "}"
    if isinstance(v, bool):
        return "true" if v else "false"
    if isinstance(v, bytes):
        return base64.b64encode(v).decode()
    if isinstance(v, datetime.datetime):
        # Aware is a TIMESTAMP, naive a DATETIME; only the first is an instant.
        if v.tzinfo is not None:
            return canon(v.timestamp())
        return v.isoformat()
    if isinstance(v, (datetime.date, datetime.time)):
        return v.isoformat()
    if isinstance(v, decimal.Decimal):
        v = str(v)
    s = str(v).strip()
    if s in ("NULL", "None"):
        return "NULL"
    if s.lower() in ("true", "false"):
        return s.lower()
    try:
        f = float(s)
    except ValueError:
        return s
    # int(inf) raises, so this precedes the magnitude test rather than joining
    # it. Both sides spell these the same way, modulo case and "infinity".
    if not math.isfinite(f):
        return {"infinity": "inf", "-infinity": "-inf"}.get(s.lower(), s.lower())
    if f == int(f) and abs(f) < 1e15:
        return str(int(f))
    return f"{f:.6f}".rstrip("0").rstrip(".")


def canon_engine_cell(s, container=False):
    """The CLI prints containers as `[a, b]` and `{k: v}`; canon() emits them
    without the spaces.

    Whether a cell *is* a container has to be told, not guessed: the CLI's TSV
    carries no types, and `FORMAT("[%\'d]", 1000)` produces `[1,000]`, which
    guessing reads as a two-element array. BigQuery's side knows the schema, so
    its value decides.
    """
    s = s.strip()
    if not container:
        return canon(s)
    if s[:1] == "[" and s[-1:] == "]" and not re.search(r"[\[{]", s[1:-1]):
        inner = s[1:-1].strip()
        return "[]" if not inner else "[" + ",".join(canon(p) for p in inner.split(",")) + "]"
    # Nested: normalise the spacing rather than splitting, which a comma inside
    # an element would break.
    return re.sub(r"([,:])\s+", r"\1", s)


def run_engine(sql):
    p = subprocess.run([ENGINE, sql], capture_output=True, text=True, timeout=180)
    out = (p.stdout or "") + (p.stderr or "")
    if "error:" in out:
        return None, out.strip().splitlines()[-1][:200]
    lines = [l for l in out.split("\n") if l.strip()]
    if not lines:
        return [], None
    header = lines[0].split("\t")
    # Raw: the cells are canonicalised in compare(), where BigQuery's schema
    # says which of them are containers.
    return [dict(zip(header, l.split("\t"))) for l in lines[1:]], None


_local = threading.local()


def client(project):
    """One client per thread. Sharing one is documented as safe, but a client
    is cheap to hold and this leaves nothing to reason about."""
    c = getattr(_local, "client", None)
    if c is None:
        c = _local.client = bigquery.Client(project=project)
    return c


def run_bq(sql, project):
    """(rows, error, cache_hit). A query error is a result, not a crash: the
    engine accepting SQL BigQuery rejects is one of the things being looked
    for."""
    try:
        job = client(project).query(
            sql, job_config=bigquery.QueryJobConfig(use_query_cache=True))
        # Native values: their Python types are the only thing that says which
        # engine cells are containers.
        rows = [dict(row.items()) for row in job.result()]
        return rows, None, bool(job.cache_hit)
    except Exception as e:  # google.api_core.exceptions.*, mostly BadRequest
        first = str(e).strip().split("\n")[0]
        return None, first[:240], False


def render_artifact(a, b):
    """Whether two cells differ only in how BigQuery's client renders a value.

    A NULL ARRAY comes back as `[]` rather than None -- the REST surface has no
    other spelling for it, which `tools/capture_golden.py` records as well. And
    an INTERVAL arrives as a dateutil relativedelta, whose repr has nothing to
    do with the canonical `Y-M D H:M:S` text.
    """
    if (a == "NULL" and b == "[]") or (a == "[]" and b == "NULL"):
        return True
    if a.startswith("relativedelta(") or b.startswith("relativedelta("):
        return True
    # A JSON column arrives parsed, so it has lost the quoting the engine
    # prints around keys and strings. Same value, two renderings.
    return a.replace('"', "") == b.replace('"', "") and a != b


def classify(ours, theirs):
    """agree | render | name | order | diff, given two canonicalised row lists."""
    if ours == theirs:
        return "agree"
    if (len(ours) == len(theirs)
            and all(sorted(x) == sorted(y) for x, y in zip(
                (list(r) for r in ours), (list(r) for r in theirs)))
            and all(render_artifact(str(x), str(y))
                    for ro, rt in zip(ours, theirs)
                    for x, y in zip(ro.values(), rt.values()) if x != y)
            and any(x != y for ro, rt in zip(ours, theirs)
                    for x, y in zip(ro.values(), rt.values()))):
        return "render"
    ovals = [sorted(r.values()) for r in ours]
    bvals = [sorted(r.values()) for r in theirs]
    if ovals == bvals:
        return "name"
    key = lambda rows: sorted(tuple(sorted(r.items())) for r in rows)
    if key(ours) == key(theirs) or sorted(map(tuple, ovals)) == sorted(map(tuple, bvals)):
        return "order"
    return "diff"


def compare(case, project):
    """Never raises: a run of a thousand cases should not be lost to one of
    them, and a tool bug should read as a result rather than as a traceback."""
    try:
        return _compare(case, project)
    except Exception as e:
        spec, desc, sql = case
        return "error", spec, desc, sql, f"{type(e).__name__}: {e}"[:240], None, None, None, False


def align(ours, theirs):
    """Canonicalise both sides, pairing columns by name where the two agree on
    them and by position otherwise (an anonymous column is `$col1` here and
    `f0_` there)."""
    out_o, out_t = [], []
    for ro, rt in zip(ours, theirs):
        keys_t = list(rt)
        by_name = set(ro) == set(keys_t)
        co, ct = {}, {}
        for i, ko in enumerate(ro):
            kt = ko if by_name else (keys_t[i] if i < len(keys_t) else None)
            tval = rt.get(kt) if kt is not None else None
            name = ko if by_name else f"c{i}"
            co[name] = canon_engine_cell(ro[ko], isinstance(tval, (list, dict)))
            ct[name] = canon(tval)
        out_o.append(co)
        out_t.append(ct)
    return out_o, out_t


def _compare(case, project):
    spec, desc, sql = case
    ours, oerr = run_engine(sql)
    theirs, berr, cached = run_bq(sql, project)
    if not (oerr or berr):
        if len(ours) != len(theirs):
            ours = [{k: canon_engine_cell(v) for k, v in r.items()} for r in ours]
            theirs = [{k: canon(v) for k, v in r.items()} for r in theirs]
        else:
            ours, theirs = align(ours, theirs)
    if oerr or berr:
        # Both refusing is agreement about the language, not a divergence.
        verdict = "both-reject" if (oerr and berr) else "error"
        return verdict, spec, desc, sql, oerr, berr, ours, theirs, cached
    return classify(ours, theirs), spec, desc, sql, None, None, ours, theirs, cached


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("paths", nargs="+", help=".zon spec files")
    ap.add_argument("--project", default="recidiviz-bigquery-sandbox")
    ap.add_argument("--jobs", type=int, default=8,
                    help="concurrent BigQuery queries (default 8)")
    ap.add_argument("--quiet", action="store_true",
                    help="report real divergences only")
    args = ap.parse_args()

    todo = [c for p in args.paths for c in cases(p)]
    print(f"-- {len(todo)} cases, {args.jobs} at a time, project {args.project}\n")

    # Each unit shells out twice and spends nearly all of it waiting, so the
    # pool is bounded by BigQuery's appetite rather than by cores. Results are
    # collected by index so the report reads in corpus order whatever the
    # completion order was.
    results = [None] * len(todo)
    with concurrent.futures.ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(compare, c, args.project): i for i, c in enumerate(todo)}
        for done in concurrent.futures.as_completed(futures):
            results[futures[done]] = done.result()

    tally, cache_hits = {}, 0
    for verdict, spec, desc, sql, oerr, berr, ours, theirs, cached in results:
        tally[verdict] = tally.get(verdict, 0) + 1
        cache_hits += cached
        label = f"{spec} :: {desc}"
        if verdict == "diff":
            print(f"[DIFF] {label}")
            print(f"       sql : {' '.join(sql.split())[:160]}")
            print(f"       ours: {ours}")
            print(f"       bq  : {theirs}")
        elif args.quiet:
            continue
        elif verdict == "error":
            print(f"[ERR ] {label}\n       ours: {oerr or 'ok'}\n       bq  : {berr or 'ok'}")
        elif verdict == "both-reject":
            print(f"[both] {label}  (rejected by both)")
        elif verdict == "render":
            print(f"[rndr] {label}  (differs only in how the client renders it)")
        elif verdict == "name":
            print(f"[name] {label}  (values agree; column names differ)")
        elif verdict == "order":
            print(f"[ordr] {label}  (same rows, different order; no top-level ORDER BY)")

    print("\n-- " + "  ".join(f"{k}={v}" for k, v in sorted(tally.items()))
          + f"  (bigquery cache hits {cache_hits}/{len(todo)})")
    return 1 if tally.get("diff") or tally.get("error") else 0


if __name__ == "__main__":
    sys.exit(main())
