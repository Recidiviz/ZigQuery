#!/usr/bin/env python3
"""Import goccy/googlesqlite's spec corpus as ZON.

Upstream (github.com/goccy/googlesqlite) keeps one YAML spec per GoogleSQL
function/syntax construct under `testdata/specs/`, mechanically extracted from
the **Examples** sections of the GoogleSQL reference docs by their `specctl
extract-testdata`. Each SQL block is paired with the ASCII result table printed
beside it, so the expected values are Google's own published output.

This converts them to ZON, which Zig 0.16 parses natively (`std.zon.parse` +
`std.zig.Zoir`) — the repo has no YAML parser and `build.zig.zon` has zero
dependencies, which we keep.

    uv run --with pyyaml tools/spec_import.py --src <checkout>
    uv run --with pyyaml tools/spec_import.py --src <checkout> --check

The Spanner dialect is skipped: this engine targets BigQuery.

Output is piped through `zig fmt --zon`, so re-running against the same upstream
commit is byte-identical and a re-sync is a reviewable diff.
"""

import argparse
import os
import re
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:
    sys.exit("PyYAML required: uv run --with pyyaml tools/spec_import.py ...")

SPEC_SUBDIR = os.path.join("testdata", "specs")
DOCS_SUBDIR = os.path.join("docs", "specs")

# Zig identifiers that can be written bare after a leading dot.
IDENT_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")

ZIG_KEYWORDS = {
    "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await",
    "break", "callconv", "catch", "comptime", "const", "continue", "defer",
    "else", "enum", "errdefer", "error", "export", "extern", "fn", "for", "if",
    "inline", "noalias", "noinline", "nosuspend", "opaque", "or", "orelse",
    "packed", "pub", "resume", "return", "struct", "suspend", "switch", "test",
    "threadlocal", "try", "union", "unreachable", "usingnamespace", "var",
    "volatile", "while",
}


def zig_string(s):
    """A double-quoted Zig string literal.

    Never single quotes: in ZON `'a'` is a *character literal* (u21) and `'ab'`
    is a parse error. Upstream YAML is single-quote heavy, so this is the one
    conversion mistake that would silently turn "a" into the integer 97.
    """
    out = ['"']
    for ch in s:
        if ch == "\\":
            out.append("\\\\")
        elif ch == '"':
            out.append('\\"')
        elif ch == "\n":
            out.append("\\n")
        elif ch == "\r":
            out.append("\\r")
        elif ch == "\t":
            out.append("\\t")
        elif ord(ch) < 0x20 or ord(ch) == 0x7F:
            out.append("\\x%02x" % ord(ch))
        else:
            out.append(ch)  # raw UTF-8 is valid in a Zig string literal
    out.append('"')
    return "".join(out)


def zig_multiline(s, indent):
    """A `\\\\` multiline literal, for SQL that spans lines."""
    pad = " " * indent
    lines = s.split("\n")
    while lines and lines[-1].strip() == "":
        lines.pop()
    body = "\n".join(pad + "\\\\" + ln for ln in lines)
    return "\n" + body + "\n" + pad


def zig_field(name):
    """`.foo` or `.@"foo-bar"` for a struct field name."""
    if IDENT_RE.match(name) and name not in ZIG_KEYWORDS:
        return "." + name
    return '.@"%s"' % name.replace("\\", "\\\\").replace('"', '\\"')


def zig_value(v):
    """One expected cell. ZON keeps the YAML scalar's type, which is the whole
    reason for choosing it over stringifying everything."""
    if v is None:
        return "null"
    if isinstance(v, bool):  # before int: bool is a subclass of int
        return "true" if v else "false"
    if isinstance(v, int):
        return str(v)
    if isinstance(v, float):
        if v != v:
            return "nan"
        if v == float("inf"):
            return "inf"
        if v == float("-inf"):
            return "-inf"
        return repr(v)
    if isinstance(v, str):
        return zig_string(v)
    if isinstance(v, (list, tuple)):
        return ".{ " + ", ".join(zig_value(x) for x in v) + " }"
    raise TypeError("unrepresentable expected value: %r" % (v,))


def sql_literal(sql, indent):
    return zig_multiline(sql, indent) if "\n" in sql else zig_string(sql)


def render_case(c, out):
    """One `.{ ... }` case entry, appended line-wise to `out`."""
    out.append("        .{")
    out.append("            .desc = %s," % zig_string(c.get("desc") or ""))

    if c.get("setup"):
        out.append("            .setup = .{")
        for stmt in c["setup"]:
            out.append("                %s," % sql_literal(stmt, 16))
        out.append("            },")

    out.append("            .sql = %s," % sql_literal(c["sql"], 12))

    if c.get("args"):
        out.append(
            "            .args = .{ %s },"
            % ", ".join(zig_value(a) for a in c["args"])
        )
    if c.get("named_args"):
        pairs = ", ".join(
            "%s = %s" % (zig_field(k), zig_value(v))
            for k, v in c["named_args"].items()
        )
        out.append("            .named_args = .{ %s }," % pairs)

    exp = c.get("expected") or {}
    err = exp.get("error")
    if err:
        # `contains` is the only sub-field upstream ever uses, and `.error`
        # would need `.@"error"` here, so flatten it to a bare substring.
        msg = err.get("contains") if isinstance(err, dict) else err
        out.append("            .expect_error = %s," % zig_string(msg))

    if exp.get("unordered"):
        out.append("            .unordered = true,")
    if c.get("nondeterministic"):
        out.append("            .nondeterministic = true,")

    if c.get("register_protos"):
        # Kept rather than dropped: the ledger should show what we cannot run.
        out.append(
            '            .skip = "register_protos: the driver has no RegisterProto",'
        )

    rows = exp.get("rows")
    if rows is not None:
        if not rows:
            out.append("            .rows = .{},")
        else:
            out.append("            .rows = .{")
            for row in rows:
                cells = row if isinstance(row, list) else [row]
                out.append(
                    "                .{ %s },"
                    % ", ".join(zig_value(x) for x in cells)
                )
            out.append("            },")

    out.append("        },")


def render_spec(rel, doc, upstream_url):
    out = []
    out.append("// Generated by tools/spec_import.py. Do not edit.")
    out.append("//")
    out.append("// Imported from goccy/googlesqlite (MIT), whose expected values are")
    out.append("// derived from the GoogleSQL reference docs (Apache-2.0).")
    out.append(".{")
    out.append("    .spec = %s," % zig_string(rel[: -len(".yaml")]))
    out.append("    .dialect = .%s," % doc["dialect"])
    if upstream_url:
        out.append("    .upstream = %s," % zig_string(upstream_url))
    out.append("    .cases = .{")
    for c in doc.get("cases") or []:
        render_case(c, out)
    out.append("    },")
    out.append("}")
    return "\n".join(out) + "\n"


def frontmatter(path):
    """`name:`/`upstream_url:` out of a spec markdown's YAML frontmatter."""
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            txt = fh.read()
    except OSError:
        return {}
    m = re.match(r"---\n(.*?)\n---", txt, re.S)
    if not m:
        return {}
    return dict(re.findall(r"^([a-z_]+):\s*(.*)$", m.group(1), re.M))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--src", required=True, help="goccy/googlesqlite checkout")
    ap.add_argument("--out", default=SPEC_SUBDIR, help="output root")
    ap.add_argument("--only", help="substring filter on the spec path")
    ap.add_argument("--check", action="store_true",
                    help="verify output matches what is on disk; write nothing")
    ap.add_argument("--commit", default="", help="upstream commit SHA to record")
    args = ap.parse_args()

    src_specs = os.path.join(args.src, SPEC_SUBDIR)
    if not os.path.isdir(src_specs):
        sys.exit("no %s under --src" % SPEC_SUBDIR)

    yamls = []
    for dirpath, _, files in os.walk(src_specs):
        for f in files:
            if f.endswith(".yaml"):
                yamls.append(
                    os.path.relpath(os.path.join(dirpath, f), src_specs)
                )
    yamls.sort()

    written, skipped_spanner, total_cases, proto_cases, setup_cases = 0, 0, 0, 0, 0
    manifest = []
    # Everything is staged in memory, formatted in one `zig fmt` pass, and only
    # then written or compared. Write and --check therefore run the identical
    # pipeline, which is what makes idempotency structural rather than hoped-for.
    staged = {}

    for rel in yamls:
        if args.only and args.only not in rel:
            continue
        with open(os.path.join(src_specs, rel), encoding="utf-8",
                  errors="replace") as fh:
            doc = yaml.safe_load(fh)
        if not doc or not doc.get("cases"):
            continue
        if doc.get("dialect") == "spanner":
            skipped_spanner += 1
            continue

        fm = frontmatter(os.path.join(args.src, DOCS_SUBDIR,
                                      rel[: -len(".yaml")] + ".md"))
        text = render_spec(rel, doc, fm.get("upstream_url"))

        cases = doc["cases"]
        total_cases += len(cases)
        proto_cases += sum(1 for c in cases if c.get("register_protos"))
        setup_cases += sum(1 for c in cases if c.get("setup"))

        out_rel = rel[: -len(".yaml")] + ".zon"
        manifest.append((out_rel, doc["dialect"], len(cases)))
        staged[out_rel] = text
        written += 1

    man = ["// Generated by tools/spec_import.py. Do not edit.", ".{"]
    man.append("    .generated_from = %s,"
               % zig_string("goccy/googlesqlite@" + (args.commit or "unknown")))
    man.append("    .files = .{")
    for path, dialect, n in manifest:
        man.append("        .{ .path = %s, .dialect = .%s, .cases = %d },"
                   % (zig_string(path), dialect, n))
    man.append("    },")
    man.append("}")
    staged["manifest.zon"] = "\n".join(man) + "\n"

    # One `zig fmt --zon` pass over a staging tree gives canonical, byte-stable
    # output. Doing it here rather than after writing is what lets --check
    # compare like with like.
    with tempfile.TemporaryDirectory() as tmp:
        for rel, text in staged.items():
            p = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(text)
        fmt = subprocess.run(["zig", "fmt", "--zon", tmp],
                             capture_output=True, text=True)
        if fmt.returncode != 0:
            print("zig fmt failed:\n" + fmt.stderr, file=sys.stderr)
            return 1
        for rel in staged:
            with open(os.path.join(tmp, rel), encoding="utf-8") as fh:
                staged[rel] = fh.read()

    print("specs: %d written, %d spanner skipped" % (written, skipped_spanner))
    print("cases: %d total, %d with setup, %d register_protos (marked skip)"
          % (total_cases, setup_cases, proto_cases))

    if args.check:
        mismatches = []
        for rel, text in sorted(staged.items()):
            try:
                with open(os.path.join(args.out, rel), encoding="utf-8") as fh:
                    if fh.read() != text:
                        mismatches.append(rel)
            except FileNotFoundError:
                mismatches.append(rel + " (missing)")
        # A file on disk that the converter no longer produces is drift too.
        for dirpath, _, files in os.walk(args.out):
            for f in files:
                if not f.endswith(".zon"):
                    continue
                rel = os.path.relpath(os.path.join(dirpath, f), args.out)
                if rel not in staged:
                    mismatches.append(rel + " (stale)")
        if mismatches:
            print("\nout of date (%d):" % len(mismatches))
            for m in mismatches[:20]:
                print("  " + m)
            return 1
        print("check: %d files match disk" % len(staged))
        return 0

    for rel, text in staged.items():
        dest = os.path.join(args.out, rel)
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        with open(dest, "w", encoding="utf-8") as fh:
            fh.write(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
