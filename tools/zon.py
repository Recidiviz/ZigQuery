"""Emitting ZON, shared by the spec generators under tools/.

Zig 0.16 parses ZON natively (`std.zon.parse` + `std.zig.Zoir`), which is why
the spec corpus is ZON and not YAML or JSON: the repo has no YAML parser and
`build.zig.zon` has zero dependencies, which we keep.

Everything here is about producing text a Zig ZON parser reads back as the value
we meant. The one rule worth stating twice is in `zig_string`.
"""

import os
import re
import subprocess
import sys
import tempfile

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
    is a parse error. Sources are single-quote heavy, so this is the one
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


def sql_literal(sql, indent):
    return zig_multiline(sql, indent) if "\n" in sql else zig_string(sql)


def zig_float(v):
    """A float literal that ZonGen reads back as `.float_literal`.

    `repr` always leaves a `.` or an `e` in the text, which is what keeps an
    integral value like 5.0 from parsing as the *integer* 5 and matching an
    INT64 cell under `.typed`.
    """
    f = float(v)
    if f != f:
        return "nan"
    if f == float("inf"):
        return "inf"
    if f == float("-inf"):
        return "-inf"
    return repr(f)


def format_tree(staged):
    """Runs one `zig fmt --zon` pass over `{relpath: text}`, returning the same
    mapping formatted.

    One pass over a whole staging tree, rather than per file after writing, is
    what gives canonical byte-stable output and lets a `--check` mode compare
    like with like.
    """
    with tempfile.TemporaryDirectory() as tmp:
        for rel, text in staged.items():
            p = os.path.join(tmp, rel)
            os.makedirs(os.path.dirname(p), exist_ok=True)
            with open(p, "w", encoding="utf-8") as fh:
                fh.write(text)
        fmt = subprocess.run(["zig", "fmt", "--zon", tmp],
                             capture_output=True, text=True)
        if fmt.returncode != 0:
            sys.exit("zig fmt failed:\n" + fmt.stderr)
        out = {}
        for rel in staged:
            with open(os.path.join(tmp, rel), encoding="utf-8") as fh:
                out[rel] = fh.read()
        return out
