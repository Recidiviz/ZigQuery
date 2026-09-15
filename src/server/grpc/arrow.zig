//! Arrow IPC encoding of the engine's typed values, for the Storage Read API.
//!
//! `ArrowSchema.serialized_schema` and `ArrowRecordBatch.serialized_record_batch` are separate
//! bytes fields, so what goes in each is a single encapsulated IPC message:
//!  - continuation
//!  - marker
//!  - header length
//!  - flatbuffer header
//!  - padding
//!  and not a stream with a schema at the front.
//!
//! `ArrowIpcEncoderFinalizeBuffer(encoder, 1, &out)` is exactly that.
//!
//! Arrow needs whole columns — a validity bitmap, an offsets buffer, a data
//! buffer — before anything can be framed, so rows are appended into
//! per-column builders as they arrive and only encoded once a batch is
//! flushed.
//!
//! ## The mapping
//!
//! Recorded from BigQuery: `testdata/storage/bigquery_arrow_schema.txt`
//!
//! | GoogleSQL kind            | Arrow                       | annotation                |
//! | ---                       | ---                         | ---                       |
//! | BOOL                      | `bool`                      |                           |
//! | INT64/32, UINT64/32, ENUM | `int64`                     |                           |
//! | FLOAT, DOUBLE             | `double`                    |                           |
//! | STRING                    | `string`                    |                           |
//! | BYTES                     | `binary`                    |                           |
//! | NUMERIC                   | `decimal128(38, 9)`         |                           |
//! | BIGNUMERIC ¹              | `decimal256(76, 38)`        |                           |
//! | DATE                      | `date32[day]`               |                           |
//! | TIME                      | `time64[us]`                |                           |
//! | TIMESTAMP                 | `timestamp[us, tz=UTC]`     |                           |
//! | DATETIME ²                | `timestamp[us]`, no zone    | `google:sqlType:datetime` |
//! | JSON                      | `string`                    | `google:sqlType:json`     |
//! | GEOGRAPHY ⁴               | `string`                    | `google:sqlType:geography` |
//! | INTERVAL                  | `month_day_nano_interval`   | `google:sqlType:interval` |
//! | RANGE\<T\> ³              | `struct<start: T, end: T>`  | `google:sqlType = range`  |
//! | STRUCT                    | `struct<…>`                 |                           |
//! | ARRAY\<T\>                | `list<item: T>`, never null |                           |
//!
//! Nullability rides in the Arrow field flags — a REQUIRED column is `int64 not null`.
//!
//! ¹ `decimal(77, 38)` in Avro — see `avro.zig`'s note on the same field, and
//!   docs/NUMERIC_FIDELITY.md.
//! ² The extension name separates from a real TIMESTAMP, which carries `tz=UTC`.
//! ⁴ Also carries `ARROW:extension:metadata` = `{"encoding": "WKT"}`, the
//!   only annotation with parameters.
//! ³ Marked with a plain `google:sqlType` key rather than the `ARROW:extension:name`
//!   the other three annotated kinds use.

const std = @import("std");
const zigquery = @import("zigquery");
const spec = zigquery.spec;
const value_mod = zigquery.value;
const Value = value_mod.Value;

/// The shim, not nanoarrow itself: translate-c cannot read nanoarrow's headers.
/// See nanoarrow_shim.h.
pub const c = @import("nanoarrow_c");

const avro = @import("avro.zig");

const log = std.log.scoped(.grpc);

pub const Error = error{
    /// A type this encoder has no Arrow mapping for.
    UnsupportedType,
    /// The value is not the declared type or one of the documented type collapses.
    TypeMismatch,
    /// A type nested deeper than `max_depth`. BigQuery's own limit is 15.
    NestingTooDeep,
    /// nanoarrow refused something. Its own message goes to the log; the caller gets this.
    ArrowFailed,
} || std.mem.Allocator.Error;

/// One output column plus the one thing `spec.Type` cannot carry.
///
/// Deliberately `avro.Column` itself and not a second struct with the same
/// fields: nullability is decided in exactly one place (`read_service`'s
/// `outputColumns`), and sharing the type is what makes it impossible for the
/// two encoders to be handed different answers. Where Avro spends nullability
/// on a `["null", T]` union, Arrow spends it on a field flag — same input,
/// different spelling.
pub const Column = avro.Column;

/// Turns a shim return code into a Zig error, logging nanoarrow's own message.
///
/// Every shim entry point returns errno-style: 0 for success, and stashes the
/// detail where `zq_arrow_last_error` can read it. Wrapping that once here keeps
/// the call sites from each inventing their own check -- and keeps the detail,
/// which is the only thing that says which of a schema's fields nanoarrow
/// objected to, from being dropped on the floor.
fn check(code: c_int, what: []const u8) Error!void {
    if (code == 0) return;
    return fail(what);
}

/// The same report for the entry points that answer with a null pointer rather
/// than a code.
fn fail(what: []const u8) Error {
    const msg: [*:0]const u8 = @ptrCast(c.zq_arrow_last_error());
    log.err("nanoarrow {s} failed: {s}", .{ what, msg });
    return error.ArrowFailed;
}

/// Where in the tree an operation applies, as child indices from the root.
///
/// The shim addresses nodes by path rather than by cursor because both walks
/// below — over a `spec.Type` and over a row's `Value`s — already know where
/// they are; handing that knowledge to C is cheaper than teaching C to keep its
/// own position, and it makes every shim call independently checkable.
const max_depth = 32;

const Path = struct {
    buf: [max_depth]i32 = undefined,
    n: usize = 0,

    fn push(p: *Path, i: usize) Error!void {
        if (p.n == max_depth) return error.NestingTooDeep;
        p.buf[p.n] = @intCast(i);
        p.n += 1;
    }

    fn pop(p: *Path) void {
        p.n -= 1;
    }

    fn ptr(p: *const Path) [*c]const i32 {
        return p.buf[0..].ptr;
    }

    fn len(p: *const Path) i32 {
        return @intCast(p.n);
    }
};

// ---- the schema ----

/// An `ArrowSchema` and the IPC message it encodes to.
///
/// Owns C memory, so it is a handle rather than a value: nanoarrow allocates the
/// tree with its own allocator and releases it through the schema's `release`
/// callback.
pub const Schema = struct {
    handle: *c.ZqArrowSchema,

    pub fn deinit(s: *Schema) void {
        c.zq_arrow_schema_free(s.handle);
    }

    /// The encapsulated IPC schema message — what
    /// `ReadSession.arrow_schema.serialized_schema` carries.
    ///
    /// The bytes belong to the handle and die with it, so a caller that outlives
    /// this copies them. `read_service` does, into the session.
    pub fn encode(s: *Schema) Error![]const u8 {
        var bytes: [*c]const u8 = undefined;
        var n: i64 = 0;
        try check(c.zq_arrow_encode_schema(s.handle, &bytes, &n), "encode_schema");
        return bytes[0..@intCast(n)];
    }
};

/// The Arrow schema for a set of columns, as a root struct of one field each.
///
/// Shapes are recorded from real BigQuery — `testdata/storage/
/// bigquery_arrow_schema.txt` — and differ from the Avro mapping in the four
/// places listed at the top of this file. `arena` is only for NUL-terminating
/// names on the way into C; the schema tree itself is nanoarrow's.
pub fn buildSchema(arena: std.mem.Allocator, columns: []const Column) Error!Schema {
    const handle = c.zq_arrow_schema_new(@intCast(columns.len)) orelse
        return fail("schema_new");
    errdefer c.zq_arrow_schema_free(handle);

    var b: SchemaBuilder = .{ .arena = arena, .handle = handle };
    for (columns, 0..) |col, i| {
        try b.path.push(i);
        defer b.path.pop();
        try b.setName(col.name);
        try b.field(col.type, col.nullable);
    }
    return .{ .handle = handle };
}

/// BigQuery's key for the four types it annotates as Arrow extensions. RANGE is
/// the exception and uses a plain `google:sqlType`, which is recorded, not
/// chosen.
const ext_name = "ARROW:extension:name";
const ext_metadata = "ARROW:extension:metadata";

const SchemaBuilder = struct {
    arena: std.mem.Allocator,
    handle: *c.ZqArrowSchema,
    /// Where the walk currently is, and so which node every call below applies
    /// to. State rather than a parameter: the walk is the only thing that moves
    /// it, and threading it through a dozen signatures buys nothing.
    path: Path = .{},

    /// A field's type and its nullability.
    fn field(b: *SchemaBuilder, typ: *const spec.Type, nullable: bool) Error!void {
        switch (typ.typeKind()) {
            // An ARRAY sets its own nullability and returns: BigQuery marks a
            // repeated field NOT NULL whatever the column's mode, which is the
            // same rule `avro.zig` spells as "no union here". Each encoder has
            // to agree with its own row writer, and both do.
            .TYPE_ARRAY => return b.list(typ),
            .TYPE_STRUCT => try b.structFields(typ),
            .TYPE_RANGE => try b.range(typ),
            else => try b.leaf(typ),
        }
        return b.setNullable(nullable);
    }

    /// `list<item: T> not null`, where `item` is the name nanoarrow gives the
    /// child for us and BigQuery happens to use too.
    fn list(b: *SchemaBuilder, typ: *const spec.Type) Error!void {
        const elem = typ.element_type orelse return error.UnsupportedType;
        try b.setType(c.ZQ_ARROW_LIST, 0);
        // Not null, because a REPEATED column that holds nothing is an empty
        // array rather than an absent one -- there is no null to spell.
        try b.setNullable(false);
        try b.path.push(0);
        defer b.path.pop();
        // The item is nullable even though a REPEATED column cannot hold NULL:
        // that is what BigQuery sends, and it costs a validity bitmap nobody
        // has to populate.
        return b.field(elem, true);
    }

    fn structFields(b: *SchemaBuilder, typ: *const spec.Type) Error!void {
        try b.setType(c.ZQ_ARROW_STRUCT, @intCast(typ.field_types.len));
        for (typ.field_types, 0..) |f, i| {
            const ft = f.type orelse return error.UnsupportedType;
            try b.path.push(i);
            defer b.path.pop();
            try b.setName(f.name);
            // Every struct field is nullable in BigQuery's schema.
            try b.field(ft, true);
        }
    }

    /// `struct<start: T, end: T>` carrying `google:sqlType = range`.
    ///
    /// Unlike Avro, nothing in the type's name says which T it is — Arrow has no
    /// rule against two structs looking alike, so the element type lives only in
    /// the children.
    fn range(b: *SchemaBuilder, typ: *const spec.Type) Error!void {
        const elem = typ.element_type orelse return error.UnsupportedType;
        switch (elem.typeKind()) {
            .TYPE_DATE, .TYPE_DATETIME, .TYPE_TIMESTAMP => {},
            else => return error.UnsupportedType,
        }
        try b.setType(c.ZQ_ARROW_STRUCT, 2);
        // A plain key, not the ARROW:extension:name the other annotated types
        // use, and lowercase where Avro's sqlType is "RANGE". Recorded, both.
        try b.addMetadata(.{ .key = "google:sqlType", .value = "range" });
        for ([_][]const u8{ "start", "end" }, 0..) |bound, i| {
            try b.path.push(i);
            defer b.path.pop();
            try b.setName(bound);
            // Both bounds are nullable whatever the column's mode: null is how
            // UNBOUNDED is spelled.
            try b.field(elem, true);
        }
    }

    /// The kinds Arrow has a type for outright, needing no annotation.
    fn leaf(b: *SchemaBuilder, typ: *const spec.Type) Error!void {
        return switch (typ.typeKind()) {
            .TYPE_BOOL => b.setType(c.ZQ_ARROW_BOOL, 0),
            .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64, .TYPE_ENUM => b.setType(
                c.ZQ_ARROW_INT64,
                0,
            ),
            .TYPE_FLOAT, .TYPE_DOUBLE => b.setType(c.ZQ_ARROW_DOUBLE, 0),
            .TYPE_STRING => b.setType(c.ZQ_ARROW_STRING, 0),
            .TYPE_BYTES => b.setType(c.ZQ_ARROW_BINARY, 0),
            .TYPE_DATE => b.setType(c.ZQ_ARROW_DATE32, 0),
            .TYPE_TIME => b.setType(c.ZQ_ARROW_TIME64_US, 0),
            // With tz=UTC. That zone is the only thing separating this from
            // DATETIME, which is the same Arrow type without one.
            .TYPE_TIMESTAMP => b.setType(c.ZQ_ARROW_TIMESTAMP_US_UTC, 0),
            .TYPE_NUMERIC => b.setDecimal(c.ZQ_ARROW_DECIMAL128, .{ 38, 9 }),
            // 76, where the same column is decimal(77, 38) in Avro. Arrow's
            // precision is the documented one; Avro's is not.
            .TYPE_BIGNUMERIC => b.setDecimal(c.ZQ_ARROW_DECIMAL256, .{ 76, 38 }),
            else => b.annotatedLeaf(typ),
        };
    }

    /// The kinds Arrow has no type for, which BigQuery spells as an extension
    /// over a storage type that would otherwise be ambiguous — a DATETIME is a
    /// zone-less timestamp and a JSON column is a string, and only the name
    /// says which.
    fn annotatedLeaf(b: *SchemaBuilder, typ: *const spec.Type) Error!void {
        return switch (typ.typeKind()) {
            .TYPE_DATETIME => b.annotated(c.ZQ_ARROW_TIMESTAMP_US, "google:sqlType:datetime"),
            .TYPE_JSON => b.annotated(c.ZQ_ARROW_STRING, "google:sqlType:json"),
            .TYPE_GEOGRAPHY => {
                try b.annotated(c.ZQ_ARROW_STRING, "google:sqlType:geography");
                // The only extension carrying parameters, and the encoding is
                // the one thing a reader needs to know about the string.
                return b.addMetadata(.{
                    .key = ext_metadata,
                    .value = "{\"encoding\": \"WKT\"}",
                });
            },
            .TYPE_INTERVAL => b.annotated(
                c.ZQ_ARROW_INTERVAL_MONTH_DAY_NANO,
                "google:sqlType:interval",
            ),
            else => error.UnsupportedType,
        };
    }

    fn annotated(b: *SchemaBuilder, typ: c_int, name: [:0]const u8) Error!void {
        try b.setType(typ, 0);
        return b.addMetadata(.{ .key = ext_name, .value = name });
    }

    // ---- the shim calls, each applying at `path` ----

    fn setType(b: *SchemaBuilder, typ: c_int, n_children: i64) Error!void {
        return check(
            c.zq_arrow_schema_set_type(b.handle, b.path.ptr(), b.path.len(), typ, n_children),
            "schema_set_type",
        );
    }

    /// `digits` is `.{ precision, scale }`, together because neither means
    /// anything without the other.
    fn setDecimal(b: *SchemaBuilder, typ: c_int, digits: [2]i32) Error!void {
        return check(
            c.zq_arrow_schema_set_decimal(
                b.handle,
                b.path.ptr(),
                b.path.len(),
                typ,
                digits[0],
                digits[1],
            ),
            "schema_set_decimal",
        );
    }

    /// Column and struct-field names reach here from a client's CREATE TABLE, so
    /// they are arbitrary bytes with no terminator; C needs one.
    fn setName(b: *SchemaBuilder, name: []const u8) Error!void {
        const z = try b.arena.dupeSentinel(u8, name, 0);
        return check(
            c.zq_arrow_schema_set_name(b.handle, b.path.ptr(), b.path.len(), z.ptr),
            "schema_set_name",
        );
    }

    fn setNullable(b: *SchemaBuilder, nullable: bool) Error!void {
        return check(
            c.zq_arrow_schema_set_nullable(
                b.handle,
                b.path.ptr(),
                b.path.len(),
                @intFromBool(nullable),
            ),
            "schema_set_nullable",
        );
    }

    /// One key/value pair of field metadata. NUL-terminated because C wants
    /// that, and every key and value this encoder writes is a literal recorded
    /// from BigQuery rather than anything a client supplied.
    const Metadata = struct { key: [:0]const u8, value: [:0]const u8 };

    fn addMetadata(b: *SchemaBuilder, kv: Metadata) Error!void {
        return check(
            c.zq_arrow_schema_add_metadata(
                b.handle,
                b.path.ptr(),
                b.path.len(),
                kv.key.ptr,
                kv.value.ptr,
            ),
            "schema_add_metadata",
        );
    }
};

// ---- the rows those columns hold ----

/// Rows appended into per-column builders, encoded once as a record batch.
///
/// The turn from row-wise to columnar happens here and nowhere else: a caller
/// hands whole rows in the order `nextTyped` produces them, and nothing is
/// encoded until `encode`. A builder is spent afterwards — the next batch needs
/// a new one — because `ArrowArrayFinishBuildingDefault` seals the buffers.
pub const Builder = struct {
    handle: *c.ZqArrowBuilder,
    columns: []const Column,
    /// Where the walk currently is, and so which node every append below
    /// applies to. `appendRow` resets it per column, so it is scratch rather
    /// than state that outlives a call.
    path: Path = .{},

    /// `schema` must outlive the builder: nanoarrow reads the types back out of
    /// it when the batch is encoded, not only when the builder is made.
    pub fn init(schema: Schema, columns: []const Column) Error!Builder {
        const handle = c.zq_arrow_builder_new(schema.handle) orelse return fail("builder_new");
        return .{ .handle = handle, .columns = columns };
    }

    pub fn deinit(b: *Builder) void {
        c.zq_arrow_builder_free(b.handle);
    }

    pub fn rowCount(b: *const Builder) i64 {
        return c.zq_arrow_builder_len(b.handle);
    }

    /// What the rows so far occupy, for deciding when a batch is full. Not the
    /// encoded size — no header, no padding — but it tracks it closely enough,
    /// and a columnar builder offers nothing cheaper.
    pub fn byteCount(b: *const Builder) i64 {
        return c.zq_arrow_builder_bytes(b.handle);
    }

    pub fn appendRow(b: *Builder, row: []const Value) Error!void {
        if (row.len != b.columns.len) return error.TypeMismatch;
        for (b.columns, row, 0..) |col, v, i| {
            b.path = .{};
            try b.path.push(i);
            try b.field(col.type, v, col.nullable);
        }
        // The root is a struct array like any other: its element is complete
        // only once every child has one, and closing it is what advances the
        // row count. Skipping this leaves a batch reporting no rows while
        // carrying every value in it.
        b.path = .{};
        return b.finishElement();
    }

    /// The encapsulated IPC record batch — what
    /// `ArrowRecordBatch.serialized_record_batch` carries. The bytes belong to
    /// the builder and die with it.
    pub fn encode(b: *Builder) Error![]const u8 {
        var out: [*c]const u8 = undefined;
        var n: i64 = 0;
        try check(c.zq_arrow_encode_batch(b.handle, &out, &n), "encode_batch");
        return out[0..@intCast(n)];
    }

    /// One value of a column of type `typ`, including its nullability.
    ///
    /// Everything dispatches on the declared type, never on the value's own tag
    /// — the same rule `avro.zig` opens with, and for the same reason: a
    /// top-level BOOL arrives as `.int` and one inside an ARRAY as `.bool`.
    fn field(b: *Builder, typ: *const spec.Type, v: Value, nullable: bool) Error!void {
        const inner = if (v == .safe) v.safe.* else v;
        if (typ.typeKind() == .TYPE_ARRAY) return b.list(typ, inner);
        if (inner == .null) {
            // A NOT NULL column with a null in it would need a validity bit the
            // schema says is not there -- the Arrow spelling of the union Avro
            // would be missing.
            if (!nullable) return error.TypeMismatch;
            // For a struct or a list this appends a null element and an empty
            // one to every child, so the children stay the same length as their
            // parent -- which is the invariant the encoder validates.
            return b.appendNull();
        }
        return b.value(typ, inner);
    }

    fn value(b: *Builder, typ: *const spec.Type, v: Value) Error!void {
        return switch (typ.typeKind()) {
            .TYPE_STRUCT => b.structFields(typ, v),
            .TYPE_RANGE => b.range(typ, v),
            .TYPE_INTERVAL => b.interval(v),
            .TYPE_NUMERIC => b.decimal(128, v),
            .TYPE_BIGNUMERIC => b.decimal(256, v),
            else => b.scalar(typ, v),
        };
    }

    /// The items, then the offset that closes the element.
    ///
    /// A null array is an empty one, not a null: the schema marked the field NOT
    /// NULL, so there is nowhere to put a null — the same answer `avro.zig`
    /// gives for the same reason.
    fn list(b: *Builder, typ: *const spec.Type, v: Value) Error!void {
        const elem = typ.element_type orelse return error.UnsupportedType;
        if (v != .null) {
            if (v != .array) return error.TypeMismatch;
            try b.path.push(0);
            defer b.path.pop();
            // A null item is representable here where Avro has to refuse one:
            // BigQuery marks the item field nullable. Nothing should produce
            // one -- a REPEATED column cannot hold NULL -- but writing it
            // faithfully beats failing a read over a value Arrow can carry.
            for (v.array.values) |item| try b.field(elem, item, true);
        }
        return b.finishElement();
    }

    fn structFields(b: *Builder, typ: *const spec.Type, v: Value) Error!void {
        if (v != .struct_) return error.TypeMismatch;
        const fields = typ.field_types;
        const values = v.struct_.values;
        if (fields.len != values.len) return error.TypeMismatch;
        for (fields, values, 0..) |f, fv, i| {
            const ft = f.type orelse return error.UnsupportedType;
            try b.path.push(i);
            defer b.path.pop();
            try b.field(ft, fv, true);
        }
        return b.finishElement();
    }

    /// `{start, end}`, where an UNBOUNDED bound is a null child.
    fn range(b: *Builder, typ: *const spec.Type, v: Value) Error!void {
        if (v != .range) return error.TypeMismatch;
        const elem = typ.element_type orelse return error.UnsupportedType;
        for ([_]?i64{ v.range.startBound(), v.range.endBound() }, 0..) |bound, i| {
            try b.path.push(i);
            defer b.path.pop();
            const raw = bound orelse {
                try b.appendNull();
                continue;
            };
            try b.value(elem, rangeScalar(v.range.elem, raw));
        }
        return b.finishElement();
    }

    fn scalar(b: *Builder, typ: *const spec.Type, v: Value) Error!void {
        return switch (typ.typeKind()) {
            // nanoarrow's AppendInt covers every integer-shaped storage there is
            // here, bool and date32 included, so the width lives in the schema
            // rather than in a per-type entry point.
            .TYPE_BOOL => b.int(@intFromBool(try asBool(v))),
            .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64, .TYPE_ENUM => b.int(
                try asInt(v),
            ),
            .TYPE_FLOAT, .TYPE_DOUBLE => b.double(try asFloat(v)),
            .TYPE_STRING, .TYPE_JSON, .TYPE_GEOGRAPHY, .TYPE_BYTES => b.bytes(try asBytes(v)),
            .TYPE_DATE => b.int(try temporal(v, .date)),
            .TYPE_TIME => b.int(try temporal(v, .time)),
            .TYPE_TIMESTAMP => b.int(try temporal(v, .timestamp)),
            // A number, where Avro sends a `T`-separated string. Same column,
            // same service.
            .TYPE_DATETIME => b.int(try datetimeMicros(v)),
            else => error.UnsupportedType,
        };
    }

    /// The unscaled value as little-endian two's complement at the full width —
    /// nanoarrow's own in-memory form, and the exact opposite of the
    /// minimal-length big-endian Avro asks for.
    ///
    /// BIGNUMERIC's extremes are written out of precision, deliberately.
    /// The largest BIGNUMERIC is 2^255-1 unscaled, which is 77 digits, and the
    /// field says `decimal256(76, 38)` because Arrow has no 77 to say — 76 is
    /// the format's maximum for 256 bits. The value still fits the buffer
    /// exactly, so it goes in raw: pyarrow's reader applies the scale to the
    /// 256-bit words without checking them against the declared precision and
    /// hands back the right Decimal. A strict consumer disagrees —
    /// `validate(full=True)` reports "does not fit in precision of
    /// decimal256(76, 38)" — but the alternative is refusing to serve a value
    /// BigQuery accepts, and BigQuery declares the same 76. Rejecting here
    /// would make `SELECT BIGNUMERIC '578960446186580977117854925043439539266
    /// .34992332820282019728792003956564819967'` unreadable over Storage.
    fn decimal(b: *Builder, bits: c_int, v: Value) Error!void {
        if (v != .numeric) return error.TypeMismatch;
        const unscaled = v.numeric.unscaled;
        // The 128-bit case has a real bound to check, unlike the 256-bit one:
        // decimal128 holds up to 10^38-1, so an in-range NUMERIC always fits,
        // and one that does not would be silently truncated by the write below
        // rather than merely exceeding a declared precision. BIGNUMERIC needs
        // no such check -- its range is i256.
        if (bits == 128 and
            (unscaled > std.math.maxInt(i128) or unscaled < std.math.minInt(i128)))
        {
            return error.TypeMismatch;
        }
        var buf: [32]u8 = undefined;
        std.mem.writeInt(i256, &buf, unscaled, .little);
        return check(
            c.zq_arrow_append_decimal(b.handle, b.path.ptr(), b.path.len(), bits, &buf),
            "append_decimal",
        );
    }

    /// Months, days and nanoseconds — where Avro's record carries
    /// microseconds. Years fold into months and everything under a day into
    /// nanos, which is how BigQuery sends it.
    fn interval(b: *Builder, v: Value) Error!void {
        if (v != .interval) return error.TypeMismatch;
        const iv = v.interval;
        const months: i64 = @as(i64, iv.years) * 12 + iv.months;
        const nanos: i64 = (@as(i64, iv.hours) * 3600 + @as(i64, iv.minutes) * 60 +
            iv.seconds) * std.time.ns_per_s + iv.sub_second_nanos;
        return check(
            c.zq_arrow_append_interval(
                b.handle,
                b.path.ptr(),
                b.path.len(),
                @intCast(months),
                iv.days,
                nanos,
            ),
            "append_interval",
        );
    }

    // ---- the shim calls, each applying at `path` ----

    fn appendNull(b: *Builder) Error!void {
        return check(
            c.zq_arrow_append_null(b.handle, b.path.ptr(), b.path.len()),
            "append_null",
        );
    }

    /// Closes a struct or list element once its children have been appended.
    fn finishElement(b: *Builder) Error!void {
        return check(
            c.zq_arrow_append_finish_element(b.handle, b.path.ptr(), b.path.len()),
            "finish_element",
        );
    }

    fn int(b: *Builder, v: i64) Error!void {
        return check(
            c.zq_arrow_append_int(b.handle, b.path.ptr(), b.path.len(), v),
            "append_int",
        );
    }

    fn double(b: *Builder, v: f64) Error!void {
        return check(
            c.zq_arrow_append_double(b.handle, b.path.ptr(), b.path.len(), v),
            "append_double",
        );
    }

    fn bytes(b: *Builder, v: []const u8) Error!void {
        return check(
            c.zq_arrow_append_bytes(b.handle, b.path.ptr(), b.path.len(), v.ptr, @intCast(v.len)),
            "append_bytes",
        );
    }
};

fn rangeScalar(elem: value_mod.Range.ElemKind, raw: i64) Value {
    return switch (elem) {
        .date => .{ .date = raw },
        .datetime => .{ .datetime = raw },
        .timestamp => .{ .timestamp = raw },
    };
}

// ---- the documented collapses ----
//
// `Rows.nextTyped` hands back what the codec stored, and several kinds lose
// their identity on the way. These restate `avro.zig`'s accessors rather than
// importing them: they belong to the reading of a `Value`, not to either wire
// format, and DATETIME already needs a different answer here.

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
/// documents: DATE civil days, TIME micros since midnight, TIMESTAMP unix
/// micros. Arrow's `date32`, `time64[us]` and `timestamp[us, tz=UTC]` want
/// exactly those, so nothing is rescaled anywhere here.
fn temporal(v: Value, want: enum { date, time, timestamp }) Error!i64 {
    return switch (v) {
        .date => |d| if (want == .date) d else error.TypeMismatch,
        .time => |t| if (want == .time) t else error.TypeMismatch,
        .timestamp => |t| if (want == .timestamp) t else error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

/// DATETIME as civil microseconds.
///
/// Text is accepted because `avro.zig` accepts it — a DATETIME that made a round
/// trip through a rendered cell comes back `.string` — but Arrow cannot pass it
/// through the way Avro can, so it is parsed here instead of forwarded.
fn datetimeMicros(v: Value) Error!i64 {
    return switch (v) {
        .datetime => |d| d,
        .string => |s| value_mod.parseDatetimeMicros(s) catch error.TypeMismatch,
        else => error.TypeMismatch,
    };
}

const testing = std.testing;

test "nanoarrow is linked and its IPC encoder runs" {
    // The linking proof, before any encoder logic exists: if the library did
    // not build, or the generated config header is wrong, or flatcc's runtime
    // is missing, this is where it shows -- not inside a half-written schema
    // builder where the cause would be ambiguous.
    const schema = c.zq_arrow_schema_new(1) orelse return error.ArrowFailed;
    defer c.zq_arrow_schema_free(schema);

    // The root is already a struct of one field; only the field needs typing.
    const col: []const i32 = &.{0};
    try check(
        c.zq_arrow_schema_set_type(schema, col.ptr, 1, c.ZQ_ARROW_INT64, 0),
        "set_type",
    );
    try check(c.zq_arrow_schema_set_name(schema, col.ptr, 1, "id"), "set_name");

    var bytes: [*c]const u8 = undefined;
    var len: i64 = 0;
    try check(c.zq_arrow_encode_schema(schema, &bytes, &len), "encode_schema");

    // An encapsulated message leads with the 0xFFFFFFFF continuation marker and
    // is padded to 8 bytes. Anything else is not a message a reader accepts.
    try testing.expect(len > 8);
    try testing.expectEqual(@as(u64, 0), @as(u64, @intCast(len)) % 8);
    try testing.expectEqualSlices(u8, &.{ 0xff, 0xff, 0xff, 0xff }, bytes[0..4]);
}
