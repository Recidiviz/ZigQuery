#!/usr/bin/env python3
"""Generates src/proto/resolved_ast.zig from proto/googlesql.fdset.

Reads a protoc FileDescriptorSet (see README for the protoc invocation) and
emits plain Zig structs plus per-message decode functions over the hand-written
wire reader in src/proto/wire.zig.

Representation choices (mirrored by the extractor):
- optional scalar field  -> ?T
- optional message field -> ?*T (arena-allocated; breaks recursion cycles)
- repeated field         -> []T / []*T slice (arena-allocated)
- oneof                  -> optional tagged union
- enum                   -> non-exhaustive enum(i32) so unknown future values
                            decode without error
- string/bytes           -> []const u8 borrowing from the input buffer (the
                            buffer must outlive the decoded tree; both are
                            arena-owned in practice)
- unknown fields are skipped; proto2 `required` is not enforced.

Run: tools/venv/bin/python tools/gen_proto.py
"""

import os
import sys
from collections import Counter

from google.protobuf import descriptor_pb2 as dpb

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FDSET = os.path.join(ROOT, "proto", "googlesql.fdset")
OUT = os.path.join(ROOT, "src", "proto", "resolved_ast.zig")

T = dpb.FieldDescriptorProto

ZIG_KEYWORDS = {
    "align", "allowzero", "and", "anyframe", "anytype", "asm", "async",
    "await", "break", "callconv", "catch", "comptime", "const", "continue",
    "defer", "else", "enum", "errdefer", "error", "export", "extern", "fn",
    "for", "if", "inline", "noalias", "noinline", "nosuspend", "opaque",
    "or", "orelse", "packed", "pub", "resume", "return", "linksection",
    "struct", "suspend", "switch", "test", "threadlocal", "try", "union",
    "unreachable", "usingnamespace", "var", "volatile", "while",
    # primitive-ish names that shadow builtins
    "type", "bool", "true", "false", "null", "undefined",
}


def zid(name: str) -> str:
    """Field/decl identifier, escaped if it collides with a Zig keyword."""
    if name in ZIG_KEYWORDS or name[0].isdigit():
        return f'@"{name}"'
    return name


class Msg:
    def __init__(self, fq, desc, parent_prefix):
        self.fq = fq                    # .googlesql.ResolvedLiteralProto
        self.desc = desc
        self.parent_prefix = parent_prefix  # nested-name prefix, e.g. "TypeProto_"


class Enum:
    def __init__(self, fq, desc, parent_prefix):
        self.fq = fq
        self.desc = desc
        self.parent_prefix = parent_prefix


def collect(fds):
    msgs, enums = {}, {}

    def walk_msg(pkg_fq, prefix, d):
        fq = f"{pkg_fq}.{d.name}"
        msgs[fq] = Msg(fq, d, prefix)
        for nested in d.nested_type:
            if nested.options.map_entry:
                # Map fields appear as repeated map-entry messages; we still
                # generate the entry struct so decode has a type to target.
                pass
            walk_msg(fq, prefix + d.name + "_", nested)
        for e in d.enum_type:
            enums[f"{fq}.{e.name}"] = Enum(f"{fq}.{e.name}", e, prefix + d.name + "_")

    for f in fds.file:
        pkg = f".{f.package}" if f.package else ""
        for d in f.message_type:
            walk_msg(pkg, "", d)
        for e in f.enum_type:
            enums[f"{pkg}.{e.name}"] = Enum(f"{pkg}.{e.name}", e, "")
    return msgs, enums


def zig_names(msgs, enums):
    """Maps fully-qualified proto names to flat Zig type names."""
    names = {}
    base_count = Counter()
    for fq, m in list(msgs.items()) + list(enums.items()):
        base_count[m.parent_prefix + fq.split(".")[-1]] += 1
    for fq, m in list(msgs.items()) + list(enums.items()):
        base = m.parent_prefix + fq.split(".")[-1]
        if base_count[base] > 1:
            # Qualify with the package (e.g. google.protobuf collisions).
            pkg = fq[1:].rsplit(".", 1)[0].replace(".", "_")
            base = f"{pkg}_{base}"
        names[fq] = base
    return names


SCALAR_ZIG = {
    T.TYPE_DOUBLE: "f64", T.TYPE_FLOAT: "f32",
    T.TYPE_INT64: "i64", T.TYPE_UINT64: "u64", T.TYPE_INT32: "i32",
    T.TYPE_FIXED64: "u64", T.TYPE_FIXED32: "u32",
    T.TYPE_BOOL: "bool", T.TYPE_STRING: "[]const u8",
    T.TYPE_BYTES: "[]const u8",
    T.TYPE_UINT32: "u32", T.TYPE_SFIXED32: "i32", T.TYPE_SFIXED64: "i64",
    T.TYPE_SINT32: "i32", T.TYPE_SINT64: "i64",
}

# wire.Reader method producing the raw value for each scalar type.
SCALAR_READ = {
    T.TYPE_DOUBLE: "try r.readDouble()",
    T.TYPE_FLOAT: "try r.readFloat()",
    T.TYPE_INT64: "try r.readInt64()",
    T.TYPE_UINT64: "try r.readVarint()",
    T.TYPE_INT32: "try r.readInt32()",
    T.TYPE_FIXED64: "try r.readFixed64()",
    T.TYPE_FIXED32: "try r.readFixed32()",
    T.TYPE_BOOL: "(try r.readVarint()) != 0",
    T.TYPE_STRING: "try r.readBytes()",
    T.TYPE_BYTES: "try r.readBytes()",
    T.TYPE_UINT32: "@truncate(try r.readVarint())",
    T.TYPE_SFIXED32: "@bitCast(try r.readFixed32())",
    T.TYPE_SFIXED64: "@bitCast(try r.readFixed64())",
    T.TYPE_SINT32: "try r.readSint32()",
    T.TYPE_SINT64: "try r.readSint64()",
}

PACKABLE = set(SCALAR_READ) - {T.TYPE_STRING, T.TYPE_BYTES}


def field_zig_type(f, names):
    if f.type == T.TYPE_MESSAGE:
        return names[f.type_name]
    if f.type == T.TYPE_ENUM:
        return names[f.type_name]
    if f.type == T.TYPE_GROUP:
        raise SystemExit(f"proto2 group field not supported: {f.name}")
    return SCALAR_ZIG[f.type]


def read_expr(f, names):
    if f.type == T.TYPE_MESSAGE:
        return f"try {names[f.type_name]}.decodeReader(a, &sub)"
    if f.type == T.TYPE_ENUM:
        return f"@as({names[f.type_name]}, @enumFromInt(try r.readInt32()))"
    return SCALAR_READ[f.type]


def gen_enum(out, e, names):
    zname = names[e.fq]
    out.append(f"pub const {zname} = enum(i32) {{")
    seen = set()
    for v in e.desc.value:
        if v.number in seen:
            continue  # allow_alias duplicates
        seen.add(v.number)
        out.append(f"    {zid(v.name)} = {v.number},")
    out.append("    _,")
    out.append("};")
    out.append("")


def gen_message(out, m, msgs, names):
    zname = names[m.fq]
    d = m.desc
    oneofs = [[] for _ in d.oneof_decl]
    plain = []
    for f in d.field:
        if f.HasField("oneof_index"):
            oneofs[f.oneof_index].append(f)
        else:
            plain.append(f)

    out.append(f"pub const {zname} = struct {{")

    # Oneof unions first.
    for oi, decl in enumerate(d.oneof_decl):
        fields = oneofs[oi]
        if not fields:
            continue
        uname = "".join(p.capitalize() for p in decl.name.split("_")) + "Union"
        out.append(f"    pub const {uname} = union(enum) {{")
        for f in fields:
            t = field_zig_type(f, names)
            if f.type == T.TYPE_MESSAGE:
                t = f"*{t}"
            out.append(f"        {zid(f.name)}: {t},")
        out.append("    };")

    # Fields.
    for f in plain:
        t = field_zig_type(f, names)
        if f.label == T.LABEL_REPEATED:
            elem = f"*{t}" if f.type == T.TYPE_MESSAGE else t
            out.append(f"    {zid(f.name)}: []{elem} = &.{{}},")
        elif f.type == T.TYPE_MESSAGE:
            out.append(f"    {zid(f.name)}: ?*{t} = null,")
        else:
            out.append(f"    {zid(f.name)}: ?{t} = null,")
    for oi, decl in enumerate(d.oneof_decl):
        if not oneofs[oi]:
            continue
        uname = "".join(p.capitalize() for p in decl.name.split("_")) + "Union"
        out.append(f"    {zid(decl.name)}: ?{uname} = null,")

    # decode() entry point and decodeReader().
    out.append("")
    out.append(f"    pub fn decode(a: std.mem.Allocator, buf: []const u8) wire.DecodeError!*{zname} {{")
    out.append("        var r = wire.Reader.init(buf);")
    out.append("        return decodeReader(a, &r);")
    out.append("    }")
    out.append("")
    out.append(f"    pub fn decodeReader(a: std.mem.Allocator, r: *wire.Reader) wire.DecodeError!*{zname} {{")
    out.append(f"        const msg = try a.create({zname});")
    out.append("        msg.* = .{};")

    rep_fields = [f for f in plain if f.label == T.LABEL_REPEATED]
    for f in rep_fields:
        t = field_zig_type(f, names)
        elem = f"*{t}" if f.type == T.TYPE_MESSAGE else t
        out.append(f"        var list_{f.name}: std.ArrayList({elem}) = .empty;")

    out.append("        while (try r.next()) |tag| {")
    out.append("            switch (tag.field) {")

    all_fields = list(d.field)
    for f in all_fields:
        fid = f.number
        line = f"                {fid} => {{"
        body = []
        is_oneof = f.HasField("oneof_index")
        if f.label == T.LABEL_REPEATED and not is_oneof:
            if f.type in PACKABLE:
                # Accept both packed and unpacked encodings.
                body.append("                    if (tag.wire == .len) {")
                body.append("                        var sub = try r.subReader();")
                body.append("                        while (!sub.atEnd()) {")
                inner = SCALAR_READ[f.type].replace("r.", "sub.")
                body.append(f"                            try list_{f.name}.append(a, {inner});")
                body.append("                        }")
                body.append("                    } else {")
                body.append(f"                        try list_{f.name}.append(a, {SCALAR_READ[f.type]});")
                body.append("                    }")
            elif f.type == T.TYPE_MESSAGE:
                body.append("                    var sub = try r.subReader();")
                body.append(f"                    try list_{f.name}.append(a, {read_expr(f, names)});")
            else:  # string/bytes
                body.append(f"                    try list_{f.name}.append(a, {read_expr(f, names)});")
        else:
            if f.type == T.TYPE_MESSAGE:
                pre = "var sub = try r.subReader();\n                    "
                val = read_expr(f, names)
            else:
                pre = ""
                val = read_expr(f, names)
            if is_oneof:
                decl = d.oneof_decl[f.oneof_index]
                uname_field = zid(decl.name)
                body.append(f"                    {pre}msg.{uname_field} = .{{ .{zid(f.name)} = {val} }};")
            else:
                body.append(f"                    {pre}msg.{zid(f.name)} = {val};")
        out.append(line)
        out.extend(body)
        out.append("                },")

    out.append("                else => try r.skip(tag.wire),")
    out.append("            }")
    out.append("        }")
    for f in rep_fields:
        out.append(f"        msg.{zid(f.name)} = try list_{f.name}.toOwnedSlice(a);")
    out.append("        return msg;")
    out.append("    }")
    out.append("};")
    out.append("")


def main():
    fds = dpb.FileDescriptorSet()
    with open(FDSET, "rb") as fh:
        fds.ParseFromString(fh.read())

    msgs, enums = collect(fds)
    names = zig_names(msgs, enums)

    out = [
        "//! GENERATED by tools/gen_proto.py from proto/googlesql.fdset — do not edit.",
        "//! Plain-struct decoders for the googlesql resolved AST protos.",
        "",
        'const std = @import("std");',
        'pub const wire = @import("wire.zig");',
        "",
    ]
    for fq in sorted(enums):
        gen_enum(out, enums[fq], names)
    for fq in sorted(msgs):
        gen_message(out, msgs[fq], msgs, names)

    with open(OUT, "w") as fh:
        fh.write("\n".join(out) + "\n")
    print(f"wrote {OUT}: {len(msgs)} messages, {len(enums)} enums")


if __name__ == "__main__":
    main()
