#!/usr/bin/env python3
"""Metrics over a SQL snapshot from harness/spec_runner.zig.

    DUMP_SQL=testdata/sql_snapshot.txt zig build spec -Drelease=true
    python3 tools/sql_stats.py testdata/sql_snapshot.txt
    python3 tools/sql_stats.py <before> <after>     # diff two snapshots

The number that matters is *levels*, not bytes: prepare cost is per subquery
level, and rendering compactly was measured at -13.2% bytes for +0.2% prepare
(see the header of src/internal/sqlbuilder/sqlbuilder.zig). Bytes are reported
because they are cheap and correlate; levels are the target.

"Pass-through" means a SELECT that carries no semantics of its own: no WHERE /
GROUP BY / ORDER BY / LIMIT / set-op / JOIN at its own paren depth, and a
select list of nothing but bare column-or-star renames. Those levels exist
only because a resolved scan existed, and are the addressable set.
"""
import re
import sys
from collections import Counter

# `### <spec path>\t<case desc>` -- the two halves of a spec_baseline.txt key,
# which is also what identifies a case in a diff between two snapshots.
CASE = re.compile(r"^### ([^\t]+)\t(.*)$")
KEYWORD = re.compile(
    r"\b(SELECT|FROM|WHERE|GROUP|ORDER|LIMIT|UNION|INTERSECT|EXCEPT|HAVING|JOIN)\b"
)
OWN_CLAUSE = {
    "WHERE", "GROUP", "ORDER", "LIMIT", "UNION", "INTERSECT", "EXCEPT",
    "HAVING", "JOIN",
}
PLAIN_ITEM = re.compile(r"^\s*(`[^`]+`|\*)\s*(AS\s+`[^`]+`)?\s*$", re.I)
SCAN_ALIAS = re.compile(r"AS `([a-z_]+_scan)_(?:\d+|inner|outer)`")


def tokenize(sql):
    """(start, end, depth, kind) per token, skipping string/identifier bodies.

    Quoted text is stepped over rather than scanned so that a `(` inside a
    string literal or a backquoted alias cannot desynchronize the depth count.
    """
    out, depth, i, n = [], 0, 0, len(sql)
    while i < n:
        ch = sql[i]
        if ch in '"\'`':
            j = sql.find(ch, i + 1)
            if j < 0:
                break
            i = j + 1
            continue
        if ch == "(":
            depth += 1
            i += 1
            continue
        if ch == ")":
            depth -= 1
            i += 1
            continue
        m = KEYWORD.match(sql, i)
        if m:
            out.append((m.start(), m.end(), depth, m.group(1).upper()))
            i = m.end()
            continue
        i += 1
    return out


def max_depth(sql):
    depth = mx = 0
    i, n = 0, len(sql)
    while i < n:
        ch = sql[i]
        if ch in '"\'`':
            j = sql.find(ch, i + 1)
            if j < 0:
                break
            i = j + 1
            continue
        if ch == "(":
            depth += 1
            mx = max(mx, depth)
        elif ch == ")":
            depth -= 1
        i += 1
    return mx


def classify(sql):
    """(total SELECT levels, pass-through levels)."""
    toks = tokenize(sql)
    total = passthru = 0
    for k, (_, e, dep, kind) in enumerate(toks):
        if kind != "SELECT":
            continue
        total += 1
        own, body_end = set(), None
        for s2, _, d2, t2 in toks[k + 1:]:
            if d2 < dep:
                break
            if d2 == dep:
                if t2 == "SELECT":
                    break
                if t2 in OWN_CLAUSE:
                    own.add(t2)
                elif t2 == "FROM" and body_end is None:
                    body_end = s2
        if own or body_end is None:
            continue
        if all(PLAIN_ITEM.match(x) for x in sql[e:body_end].split(",")):
            passthru += 1
    return total, passthru


def load(path):
    """`[(key, label, sql)]`, key being the case's `spec\\tdesc` identity --
    unique, unlike the spec path, which every case in a file shares."""
    cases, key, label, buf = [], None, None, []
    for line in open(path):
        m = CASE.match(line.rstrip("\n"))
        if m:
            if key is not None:
                cases.append((key, label, "".join(buf)))
            key = "%s\t%s" % (m.group(1), m.group(2))
            label = "%s :: %s" % (m.group(1), m.group(2))
            buf = []
        else:
            buf.append(line)
    if key is not None:
        cases.append((key, label, "".join(buf)))
    return cases


def stats(path):
    cases = load(path)
    per_case, kinds = {}, Counter()
    tot_b = tot_sel = tot_pt = tot_stmt = 0
    depths = []
    for idx, name, sql in cases:
        levels, passthru = classify(sql)
        stmts = sql.count(";\n")
        per_case[idx] = (name, len(sql), levels, passthru, stmts)
        tot_b += len(sql)
        tot_sel += levels
        tot_pt += passthru
        tot_stmt += stmts
        if sql.strip():
            depths.append(max_depth(sql))
        for m in SCAN_ALIAS.finditer(sql):
            kinds[m.group(1)] += 1
    return {
        "cases": len(cases),
        "bytes": tot_b,
        "statements": tot_stmt,
        "levels": tot_sel,
        "passthrough": tot_pt,
        "max_depth": max(depths) if depths else 0,
        "p90_depth": sorted(depths)[int(0.9 * len(depths))] if depths else 0,
        "kinds": kinds,
        "per_case": per_case,
    }


def show(s, label):
    pct = 100 * s["passthrough"] / s["levels"] if s["levels"] else 0
    print(f"--- {label} ---")
    print(f"  cases            {s['cases']}")
    print(f"  statements       {s['statements']}")
    print(f"  bytes            {s['bytes']:,}")
    print(f"  SELECT levels    {s['levels']:,}")
    print(f"  pass-through     {s['passthrough']:,}  ({pct:.0f}%)")
    print(f"  paren depth      p90 {s['p90_depth']}, max {s['max_depth']}")
    print("  scan levels by kind:")
    total_kinds = sum(s["kinds"].values()) or 1
    for k, v in s["kinds"].most_common():
        print(f"    {k:<22} {v:5d}  {100 * v / total_kinds:5.1f}%")


def delta(name, a, b, invert=True):
    d = b - a
    if a == 0:
        return f"  {name:<16} {a:>9,} -> {b:>9,}"
    pct = 100 * d / a
    arrow = "" if d == 0 else ("  ✓" if (d < 0) == invert else "  ✗")
    return f"  {name:<16} {a:>9,} -> {b:>9,}  ({pct:+.1f}%){arrow}"


def main():
    if len(sys.argv) == 2:
        show(stats(sys.argv[1]), sys.argv[1])
        return
    if len(sys.argv) == 3:
        a, b = stats(sys.argv[1]), stats(sys.argv[2])
        print(f"--- {sys.argv[1]} -> {sys.argv[2]} ---")
        for k in ("bytes", "statements", "levels", "passthrough", "max_depth"):
            print(delta(k, a[k], b[k]))
        moved = [
            (i, a["per_case"][i], b["per_case"][i])
            for i in a["per_case"]
            if i in b["per_case"] and a["per_case"][i][2] != b["per_case"][i][2]
        ]
        print(f"\n  {len(moved)} cases changed level count")
        moved.sort(key=lambda r: r[1][2] - r[2][2], reverse=True)
        for _, av, bv in moved[:15]:
            print(f"    {av[2]:>3} -> {bv[2]:<3} levels  {av[0][:70]}")
        gone = set(a["per_case"]) - set(b["per_case"])
        new = set(b["per_case"]) - set(a["per_case"])
        if gone or new:
            print(f"\n  !! {len(gone)} cases only in {sys.argv[1]}, "
                  f"{len(new)} only in {sys.argv[2]}")
            for k in sorted(gone)[:10]:
                print("    - " + k.replace("\t", " :: "))
            for k in sorted(new)[:10]:
                print("    + " + k.replace("\t", " :: "))
        return
    print(__doc__)
    sys.exit(2)


if __name__ == "__main__":
    main()
