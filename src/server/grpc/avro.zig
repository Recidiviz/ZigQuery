//! Avro binary encoding of the engine's typed values, for the Storage Read API.
//!
//! `AvroRows.serialized_binary_rows` is the rows' datum encodings concatenated
//! — no container file, no header, no sync markers, and the schema travels
//! separately as JSON in `ReadSession.avro_schema`. So this file writes datums
//! and `schemaJson` writes the schema they must agree with; the two are next to
//! each other because a disagreement between them is invisible until a client
//! decodes garbage.
//!
//! Everything dispatches on the declared type, never on the value's own tag.
//! A top-level BOOL column comes back from `Rows.nextTyped` as `.int`, because
//! `encoder.encodeTo` stores it as a SQLite integer — while a BOOL nested in an
//! ARRAY or STRUCT round-trips through `codec_binary` and comes back as a real
//! `.bool`. INT32/UINT32/UINT64 collapse to `.int` the same way, 32-bit FLOAT to
//! `.float`, and `.null` carries no type at all. Switching on the value would
//! write bools as longs for exactly the columns a test with an `ARRAY<BOOL>` in
//! it would not catch.
//!
//! ## The mapping
//!
//! Recorded from real BigQuery: `testdata/storage/` holds an actual
//! `ReadSession.avro_schema` and a row of
//! `serialized_binary_rows` for a table with one column of every type.
//!
//! Written `avro + annotation`, where the annotation is a `logicalType` when
//! Avro has a notion of its own and a BigQuery `sqlType` when it does not.
//! Four entries contradict Google's published mapping, marked with a note.
//!
//! | GoogleSQL kind | Avro | from `Value` |
//! | --- | --- | --- |
//! | BOOL | `boolean` | `.bool`, or `.int` at top level |
//! | INT64/32, UINT64/32, ENUM | `long` | `.int` |
//! | FLOAT, DOUBLE | `double` | `.float` |
//! | STRING | `string` | `.string` |
//! | BYTES | `bytes` | `.bytes` |
//! | DATE | `int` + `date` | `.date`, civil days |
//! | TIME | `long` + `time-micros` | `.time`, micros since midnight |
//! | TIMESTAMP | `long` + `timestamp-micros` | `.timestamp`, unix micros |
//! | DATETIME ¹ | `string` + `datetime` | `.datetime`, via `formatDatetimeApi` |
//! | JSON | `string` + `sqlType JSON` | `.json`, verbatim |
//! | GEOGRAPHY | `string` + `sqlType GEOGRAPHY` | unreachable, no such `Value` |
//! | NUMERIC | `bytes` + `decimal(38,9)` | `.numeric.unscaled`, big-endian |
//! | BIGNUMERIC ² | `bytes` + `decimal(77,38)` | `.numeric`, `is_bignumeric` |
//! | INTERVAL ³ | record `google.sqlType.INTERVAL` | `.interval` |
//! | RANGE\<T\> ⁴ | record `google.sqlType.RANGE_<T>` | `.range` |
//! | STRUCT | record `__s_0`, `__s_1`, … in order | `.struct_` |
//! | ARRAY | `array` of the element schema | `.array` |
//!
//! INTERVAL's record is `{months: int, days: int, microseconds: long}`, with
//! years folded into months and everything under a day into microseconds.
//! RANGE's is `{start, end}`, both nullable, carrying `sqlType: "RANGE"`; null
//! is how UNBOUNDED is spelled. Every STRUCT field is nullable.
//!
//! ¹ Not a number — BigQuery sends a string, `T`-separated.
//! ² 77, not the 76 documented at
//!   cloud.google.com/bigquery/docs/reference/storage#avro_schema_details and
//!   in NUMERIC_FIDELITY.md.
//! ³ Not Avro's `duration` fixed(12), which cannot be negative.
//! ⁴ The name carries the element type: Avro forbids two records sharing a
//!   name, and a row can hold a RANGE\<DATE\> and a RANGE\<TIMESTAMP\>.
//!
//! Modes are a property of the column, not the type — GoogleSQL types carry
//! no nullability, so it comes from the table's metadata:
//!
//! | mode | schema | datum |
//! | --- | --- | --- |
//! | REQUIRED | the bare type | the datum; a null is `error.TypeMismatch` |
//! | NULLABLE | `["null", T]`, null first | branch 0, or 1 then the datum |
//! | REPEATED | `array`, no union | the block; a null array is an empty one |
//!
//! REPEATED is the row to be careful with: `schemaJson` and `writeField` must
//! agree that there is no union there, or a value shifts into the next field
//! and every field after it decodes wrong.
// ephor:ignore-file ZT105

const std = @import("std");
const zigquery = @import("zigquery");
const spec = zigquery.spec;
const value_mod = zigquery.value;
const pb = zigquery.pb;
const Value = value_mod.Value;

pub const Error = error{
    /// A type this encoder has no Avro mapping for. GEOGRAPHY cannot actually
    /// reach it — the engine has no such `Value` variant — but the schema side
    /// can name one, so the two must agree about what is unsupported.
    UnsupportedType,
    /// The declared type says one thing and the value is something else that is
    /// not one of the documented collapses.
    TypeMismatch,
} || std.mem.Allocator.Error;

/// Appends Avro datums to a caller-owned byte list.
///
/// Deliberately the same shape as `src/proto/wire.zig`'s `Writer`: an
/// `ArrayList(u8)` plus an allocator, methods that append and never seek. Avro
/// needs no length backfilling — an array is a count-prefixed block whose count
/// is known before the items are written — so there is no `beginLen`/`endLen`
/// equivalent here.
pub const Writer = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(a: std.mem.Allocator) Writer {
        return .{ .a = a };
    }

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.a);
    }

    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf.items;
    }

    pub fn toOwnedSlice(w: *Writer) Error![]u8 {
        return w.buf.toOwnedSlice(w.a);
    }

    /// Avro's only integer encoding: zigzag, then varint. `int` and `long`
    /// differ in the schema and in their range, not on the wire.
    pub fn writeLong(w: *Writer, v: i64) Error!void {
        var rest: u64 = @bitCast((v << 1) ^ (v >> 63));
        while (true) {
            const b: u8 = @truncate(rest & 0x7f);
            rest >>= 7;
            if (rest == 0) return w.buf.append(w.a, b);
            try w.buf.append(w.a, b | 0x80);
        }
    }

    pub fn writeInt(w: *Writer, v: i32) Error!void {
        return w.writeLong(v);
    }

    pub fn writeBool(w: *Writer, v: bool) Error!void {
        return w.buf.append(w.a, @intFromBool(v));
    }

    pub fn writeFloat(w: *Writer, v: f32) Error!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, @bitCast(v), .little);
        return w.buf.appendSlice(w.a, &tmp);
    }

    pub fn writeDouble(w: *Writer, v: f64) Error!void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, @bitCast(v), .little);
        return w.buf.appendSlice(w.a, &tmp);
    }

    /// `bytes` and `string` share an encoding; the schema says which it is.
    pub fn writeBytes(w: *Writer, v: []const u8) Error!void {
        try w.writeLong(@intCast(v.len));
        return w.buf.appendSlice(w.a, v);
    }

    /// The branch index of a union. Every nullable column here is `["null", T]`,
    /// so this is 0 for null and 1 for a value — and getting it backwards
    /// produces a buffer that decodes to wrong values rather than an error.
    pub fn writeUnionBranch(w: *Writer, index: i64) Error!void {
        return w.writeLong(index);
    }

    /// An array is a series of blocks: a count, that many items, and a final
    /// zero count. One block is enough for a materialized row.
    pub fn writeArrayHeader(w: *Writer, count: usize) Error!void {
        if (count == 0) return; // the terminator alone is a valid empty array
        return w.writeLong(@intCast(count));
    }

    pub fn writeArrayEnd(w: *Writer) Error!void {
        return w.writeLong(0);
    }
};

/// The minimal-length big-endian two's complement of `unscaled`, which is what
/// Avro `decimal` wants.
///
/// Neither stored form is reusable: `codec_binary` writes two's complement
/// little-endian at a fixed 16/32 bytes, and `codec_sortable` writes big-endian
/// but sign-bit-XORed so that memcmp orders correctly.
///
/// "Minimal length" means the leading byte is dropped while it is pure sign
/// extension of the next one — 0x00 followed by a clear top bit, or 0xff
/// followed by a set one. Zero is one byte, `0x00`, not zero bytes.
pub fn decimalBytes(out: *[32]u8, unscaled: i256) []const u8 {
    std.mem.writeInt(i256, out, unscaled, .big);
    var i: usize = 0;
    while (i < out.len - 1) : (i += 1) {
        const sign_byte = out[i] == 0x00 or out[i] == 0xff;
        if (!sign_byte) break;
        // Only redundant if the next byte's top bit agrees with this one.
        const next_top_set = (out[i + 1] & 0x80) != 0;
        if ((out[i] == 0xff) != next_top_set) break;
    }
    return out[i..];
}

/// One value of a column of type `typ`, including its nullability union.
///
/// `nullable` is the field's mode, not a property of the value: BigQuery's
/// REQUIRED columns are a bare type and everything else is `["null", T]`, so
/// the caller — which knows the mode — decides whether a branch index precedes
/// the datum.
pub fn writeField(w: *Writer, typ: *const spec.Type, v: Value, nullable: bool) Error!void {
    const inner = if (v == .safe) v.safe.* else v;

    // An ARRAY is never union-wrapped, whatever the column's mode, because
    // `writeFieldType` never puts a union in the schema for one — BigQuery
    // emits a bare `{"type":"array",…}` for a REPEATED field. Writing a branch
    // index here anyway desyncs the row by one byte and every field after it
    // decodes as garbage.
    if (typ.typeKind() == .TYPE_ARRAY) {
        // A NULL array has no spelling in that schema. BigQuery has the same
        // problem and answers it the same way: a REPEATED field that holds
        // nothing is an empty array, not an absent one.
        if (inner == .null) {
            try w.writeArrayHeader(0);
            return w.writeArrayEnd();
        }
        return writeValue(w, typ, inner);
    }

    if (nullable) {
        if (inner == .null) return w.writeUnionBranch(0);
        try w.writeUnionBranch(1);
    } else if (inner == .null) {
        // A NOT NULL column with a null in it has no encoding at all; the union
        // that would carry it is not in the schema.
        return error.TypeMismatch;
    }
    return writeValue(w, typ, inner);
}

/// One non-null value, with no union branch of its own.
pub fn writeValue(w: *Writer, typ: *const spec.Type, v: Value) Error!void {
    return switch (typ.typeKind()) {
        // The four kinds Avro spells as a record or an array; everything else
        // is one datum with no structure of its own.
        .TYPE_INTERVAL => writeInterval(w, v),
        .TYPE_RANGE => writeRange(w, typ, v),
        .TYPE_ARRAY => writeArray(w, typ, v),
        .TYPE_STRUCT => writeStruct(w, typ, v),
        else => writeScalar(w, typ, v),
    };
}

fn writeScalar(w: *Writer, typ: *const spec.Type, v: Value) Error!void {
    return switch (typ.typeKind()) {
        // Kinds Avro carries as they are; the rest need converting first.
        .TYPE_BOOL => w.writeBool(try asBool(v)),
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64, .TYPE_ENUM => w.writeLong(
            try asInt(v),
        ),
        .TYPE_FLOAT, .TYPE_DOUBLE => w.writeDouble(try asFloat(v)),
        .TYPE_STRING, .TYPE_JSON, .TYPE_GEOGRAPHY, .TYPE_BYTES => w.writeBytes(try asBytes(v)),
        else => writeConverted(w, typ, v),
    };
}

/// The kinds whose stored form is not what the Avro schema asks for:
///   - a temporal integer that must keep its own units
///   - a DATETIME that becomes text
///   - a decimal that must be re-laid-out big-endian.
fn writeConverted(w: *Writer, typ: *const spec.Type, v: Value) Error!void {
    return switch (typ.typeKind()) {
        // DATE is the one temporal kind Avro carries as a 32-bit int.
        .TYPE_DATE => w.writeInt(@intCast(try temporal(v, .date))),
        .TYPE_TIME => w.writeLong(try temporal(v, .time)),
        .TYPE_TIMESTAMP => w.writeLong(try temporal(v, .timestamp)),
        // Not a number: BigQuery sends DATETIME as a string, with the same `T`
        // separator `formatDatetimeApi` produces for the REST envelope.
        .TYPE_DATETIME => {
            if (v == .string) return w.writeBytes(v.string);
            var buf: [64]u8 = undefined;
            return w.writeBytes(value_mod.formatDatetimeApi(&buf, try temporal(v, .datetime)));
        },
        .TYPE_NUMERIC, .TYPE_BIGNUMERIC => {
            if (v != .numeric) return error.TypeMismatch;
            var buf: [32]u8 = undefined;
            return w.writeBytes(decimalBytes(&buf, v.numeric.unscaled));
        },
        else => error.UnsupportedType,
    };
}

/// `google.sqlType.INTERVAL` — a record of three non-null fields.
///
/// Recorded from BigQuery, which folds years into months and everything below
/// days into microseconds: `INTERVAL '1-2 3 4:5:6'` is
/// `{months: 14, days: 3, microseconds: 14706000000}`. Avro's own `duration`
/// logical type is a fixed(12) of unsigned little-endian fields and cannot
/// represent a negative interval.
fn writeInterval(w: *Writer, v: Value) Error!void {
    if (v != .interval) return error.TypeMismatch;
    const iv = v.interval;
    const months: i64 = @as(i64, iv.years) * 12 + iv.months;
    const micros: i64 = (@as(i64, iv.hours) * 3600 + @as(i64, iv.minutes) * 60 +
        iv.seconds) * std.time.us_per_s + @divTrunc(iv.sub_second_nanos, 1000);
    try w.writeInt(@intCast(months));
    try w.writeInt(iv.days);
    return w.writeLong(micros);
}

/// `google.sqlType.RANGE_<T>` — a record of two nullable fields, where null is
/// how UNBOUNDED is spelled.
fn writeRange(w: *Writer, typ: *const spec.Type, v: Value) Error!void {
    if (v != .range) return error.TypeMismatch;
    const elem = typ.element_type orelse return error.UnsupportedType;
    for ([_]?i64{ v.range.startBound(), v.range.endBound() }) |bound| {
        const raw = bound orelse {
            try w.writeUnionBranch(0);
            continue;
        };
        try w.writeUnionBranch(1);
        try writeValue(w, elem, rangeScalar(v.range.elem, raw));
    }
}

fn rangeScalar(elem: value_mod.Range.ElemKind, raw: i64) Value {
    return switch (elem) {
        .date => .{ .date = raw },
        .datetime => .{ .datetime = raw },
        .timestamp => .{ .timestamp = raw },
    };
}

/// One block, then the terminator. Elements are never union-wrapped: BigQuery
/// emits `{"type":"array","items":T}` with no null branch on either the array
/// or its items, so a null element has nowhere to go — matching a REPEATED
/// field's inability to hold NULL.
fn writeArray(w: *Writer, typ: *const spec.Type, v: Value) Error!void {
    if (v != .array) return error.TypeMismatch;
    const elem = typ.element_type orelse return error.UnsupportedType;
    const items = v.array.values;
    try w.writeArrayHeader(items.len);
    for (items) |item| {
        if (item == .null) return error.TypeMismatch;
        try writeValue(w, elem, item);
    }
    return w.writeArrayEnd();
}

/// Fields concatenated in declaration order. Every struct field is nullable in
/// BigQuery's schema, so each carries its own branch index.
fn writeStruct(w: *Writer, typ: *const spec.Type, v: Value) Error!void {
    if (v != .struct_) return error.TypeMismatch;
    const fields = typ.field_types;
    const values = v.struct_.values;
    if (fields.len != values.len) return error.TypeMismatch;
    for (fields, values) |f, fv| {
        const ft = f.type orelse return error.UnsupportedType;
        try writeField(w, ft, fv, true);
    }
}

// ---- the documented collapses ----
//
// `Rows.nextTyped` hands back what the codec stored, and several kinds lose
// their identity on the way. Each accessor below names the collapse it absorbs
// rather than pretending the value is self-describing.

fn asBool(v: Value) Error!bool {
    return switch (v) {
        // The collapse: a top-level BOOL column is stored as a SQLite integer
        // and comes back `.int`. Nested in an ARRAY or STRUCT it comes back
        // `.bool`, so both spellings are correct and reachable.
        .bool => |b| b,
        .int => |i| i != 0,
        else => error.TypeMismatch,
    };
}

fn asInt(v: Value) Error!i64 {
    return switch (v) {
        .int => |i| i,
        .bool => |b| @intFromBool(b),
        else => error.TypeMismatch,
    };
}

fn asFloat(v: Value) Error!f64 {
    return switch (v) {
        .float => |f| f,
        // A 32-bit FLOAT column is stored and returned as f64; the narrowness
        // lives only in the declared type.
        .int => |i| @floatFromInt(i),
        else => error.TypeMismatch,
    };
}

fn asBytes(v: Value) Error![]const u8 {
    return switch (v) {
        .string, .bytes, .json => |s| s,
        else => error.TypeMismatch,
    };
}

/// The raw integer payload of a temporal value, in the units its variant
/// documents: DATE civil days, TIME micros since midnight, DATETIME civil
/// micros, TIMESTAMP unix micros.
///
/// `Value.toInt64` is deliberately not used — it rescales `.date` to unix
/// seconds, where a `date` logical type wants civil days.
fn temporal(v: Value, want: enum { date, time, datetime, timestamp }) Error!i64 {
    return switch (v) {
        .date => |d| if (want == .date) d else error.TypeMismatch,
        .time => |t| if (want == .time) t else error.TypeMismatch,
        .datetime => |d| if (want == .datetime) d else error.TypeMismatch,
        .timestamp => |t| if (want == .timestamp) t else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

// ---- the schema those datums must agree with ----

const errors = @import("../error.zig");

/// One output column plus the one thing `spec.Type` cannot carry.
///
/// GoogleSQL types have no nullability — `SELECT a FROM t` yields the same
/// `*spec.Type` whether or not `a` was declared NOT NULL — so the mode has to
/// come from the table's own metadata, keyed by name. Everything else about the
/// schema comes from the type, which is what keeps it in step with the rows.
pub const Column = struct {
    name: []const u8,
    type: *const spec.Type,
    /// False only for a column the table declared REQUIRED. Defaulting to
    /// nullable is the safe direction: a client handed `["null", T]` decodes a
    /// non-null value fine, where the reverse loses the ability to say null.
    nullable: bool = true,
};

/// The `ReadSession.avro_schema.schema` for a set of columns.
///
/// Shapes are recorded from real BigQuery — `testdata/storage/` — not read off
/// the published mapping, which is wrong about INTERVAL, RANGE, BIGNUMERIC's
/// precision and DATETIME. The top-level record is `__root__`, as BigQuery
/// names it.
pub fn schemaJson(arena: std.mem.Allocator, columns: []const Column) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var c: Schema = .{ .arena = arena, .out = &out };
    try out.appendSlice(arena, "{\"type\":\"record\",\"name\":\"__root__\",\"fields\":[");
    for (columns, 0..) |col, i| {
        if (i != 0) try out.append(arena, ',');
        try out.appendSlice(arena, "{\"name\":");
        try errors.writeJsonString(arena, &out, col.name);
        try out.appendSlice(arena, ",\"type\":");
        try c.fieldType(col.type, col.nullable);
        try out.append(arena, '}');
    }
    try out.appendSlice(arena, "]}");
    return out.toOwnedSlice(arena);
}

/// The schema writer's running state, bundled so the recursion carries one
/// parameter rather than four.
const Schema = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    /// Avro requires every record schema to carry a unique name. BigQuery
    /// numbers anonymous struct records `__s_0`, `__s_1`, … in the order they
    /// appear, which is what this reproduces.
    next_struct: usize = 0,

    fn put(c: *Schema, text: []const u8) Error!void {
        return c.out.appendSlice(c.arena, text);
    }

    /// A field's type, including the union its mode implies.
    fn fieldType(c: *Schema, typ: *const spec.Type, nullable: bool) Error!void {
        // An ARRAY is never null-unioned, and neither are its items: BigQuery
        // emits a bare `{"type":"array",…}` for a REPEATED field, consistent
        // with a REPEATED column being unable to hold NULL. `writeField` has
        // the matching rule, and the two disagreeing is a desync of exactly one
        // byte that corrupts every field after it.
        if (typ.typeKind() == .TYPE_ARRAY) {
            const elem = typ.element_type orelse return error.UnsupportedType;
            try c.put("{\"type\":\"array\",\"items\":");
            try c.fieldType(elem, false);
            return c.out.append(c.arena, '}');
        }
        if (!nullable) return c.typeOnly(typ);
        // Null first. The branch index is what a datum leads with, so this
        // order is load-bearing rather than stylistic.
        try c.put("[\"null\",");
        try c.typeOnly(typ);
        return c.out.append(c.arena, ']');
    }

    fn typeOnly(c: *Schema, typ: *const spec.Type) Error!void {
        return switch (typ.typeKind()) {
            .TYPE_RANGE => c.rangeType(typ),
            .TYPE_STRUCT => c.structType(typ),
            else => c.put(try leafSchema(typ.typeKind())),
        };
    }

    /// `google.sqlType.RANGE_<ELEM>` — the name carries the element type
    /// because Avro forbids two different records sharing one name, and a row
    /// can hold both a RANGE<DATE> and a RANGE<TIMESTAMP>.
    fn rangeType(c: *Schema, typ: *const spec.Type) Error!void {
        const elem = typ.element_type orelse return error.UnsupportedType;
        const suffix = switch (elem.typeKind()) {
            .TYPE_DATE => "DATE",
            .TYPE_DATETIME => "DATETIME",
            .TYPE_TIMESTAMP => "TIMESTAMP",
            else => return error.UnsupportedType,
        };
        try c.out.print(
            c.arena,
            "{{\"type\":\"record\",\"namespace\":\"google.sqlType\",\"name\":\"RANGE_{s}\"," ++
                "\"sqlType\":\"RANGE\",\"fields\":[",
            .{suffix},
        );
        for ([_][]const u8{ "start", "end" }, 0..) |bound, i| {
            if (i != 0) try c.out.append(c.arena, ',');
            try c.out.print(c.arena, "{{\"name\":\"{s}\",\"type\":", .{bound});
            // Both bounds are unions whatever the column's own nullability:
            // null is how UNBOUNDED is spelled.
            try c.fieldType(elem, true);
            try c.out.append(c.arena, '}');
        }
        return c.put("]}");
    }

    fn structType(c: *Schema, typ: *const spec.Type) Error!void {
        try c.out.print(c.arena, "{{\"type\":\"record\",\"name\":\"__s_{d}\",\"fields\":[", .{
            c.next_struct,
        });
        c.next_struct += 1;
        for (typ.field_types, 0..) |f, i| {
            if (i != 0) try c.out.append(c.arena, ',');
            const ft = f.type orelse return error.UnsupportedType;
            try c.put("{\"name\":");
            // Struct field names reach here from a client's CREATE TABLE, so
            // they are escaped rather than interpolated.
            try errors.writeJsonString(c.arena, c.out, f.name);
            try c.put(",\"type\":");
            // Every struct field is nullable in BigQuery's schema.
            try c.fieldType(ft, true);
            try c.out.append(c.arena, '}');
        }
        return c.put("]}");
    }
};

/// The schema text for every kind that is a fixed string — which is all of them
/// except the two that recurse.
fn leafSchema(kind: zigquery.pb.TypeKind) Error![]const u8 {
    return primitiveSchema(kind) orelse annotatedSchema(kind);
}

/// The kinds Avro has a type for outright, needing no annotation.
fn primitiveSchema(kind: zigquery.pb.TypeKind) ?[]const u8 {
    return switch (kind) {
        .TYPE_BOOL => "\"boolean\"",
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64, .TYPE_ENUM => "\"long\"",
        .TYPE_FLOAT, .TYPE_DOUBLE => "\"double\"",
        .TYPE_STRING => "\"string\"",
        .TYPE_BYTES => "\"bytes\"",
        else => null,
    };
}

/// The kinds that need Avro told what they mean — a `logicalType` where Avro
/// has a notion of its own, a BigQuery `sqlType` where it does not.
fn annotatedSchema(kind: zigquery.pb.TypeKind) Error![]const u8 {
    return switch (kind) {
        .TYPE_DATE => "{\"type\":\"int\",\"logicalType\":\"date\"}",
        .TYPE_TIME => "{\"type\":\"long\",\"logicalType\":\"time-micros\"}",
        .TYPE_TIMESTAMP => "{\"type\":\"long\",\"logicalType\":\"timestamp-micros\"}",
        // Not a number. `datetime` is BigQuery's own logical type, not Avro's;
        // a generic reader sees a plain string, which is the intent.
        .TYPE_DATETIME => "{\"type\":\"string\",\"logicalType\":\"datetime\"}",
        // `sqlType` likewise is BigQuery's annotation and not part of Avro.
        .TYPE_JSON => "{\"type\":\"string\",\"sqlType\":\"JSON\"}",
        .TYPE_GEOGRAPHY => "{\"type\":\"string\",\"sqlType\":\"GEOGRAPHY\"}",
        .TYPE_NUMERIC => "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":38,\"scale\":9}",
        // 77, not the 76 both our own NUMERIC_FIDELITY notes and Google's
        // export page say — this is what the Storage API actually sends.
        .TYPE_BIGNUMERIC => "{\"type\":\"bytes\",\"logicalType\":\"decimal\",\"precision\":77,\"scale\":38}",
        .TYPE_INTERVAL => "{\"type\":\"record\",\"namespace\":\"google.sqlType\"," ++
            "\"name\":\"INTERVAL\",\"fields\":[{\"name\":\"months\",\"type\":\"int\"}," ++
            "{\"name\":\"days\",\"type\":\"int\"}," ++
            "{\"name\":\"microseconds\",\"type\":\"long\"}]}",
        else => error.UnsupportedType,
    };
}
