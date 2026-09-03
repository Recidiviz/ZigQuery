//! SQLite representation: Int/Float travel natively, Bool as INTEGER 0/1
//! NULL as NULL, Everything else is a BLOB, carrying one of two payload
//! shapes chosen by kind and told apart by tag range:
//!
//!   0x40+       the memcomparable encoding (codec_sortable.zig), for the kinds
//!               that can be ordered: DATE, TIME, DATETIME, TIMESTAMP, STRING,
//!               BYTES, NUMERIC, BIGNUMERIC, RANGE.
//!   0x00-0x3f   the self-delimiting codec (codec_binary.zig), for the kinds
//!               that cannot: ARRAY, STRUCT, JSON, INTERVAL. Its uvarint length
//!               prefixes would sort by length before content, which does not
//!               matter for a kind the analyzer refuses to ORDER BY. Tags run
//!               0x00-0x10 today; the rest of the range is growth room.
//!
//! RANGE appears in both lists on purpose: ordered at the top level, but
//! self-delimiting when nested inside an ARRAY or STRUCT.
//!
//! The first list is also the set the transformer may lower a comparison over;
//! see `isPrimitiveKind` in transformer/function.zig.

const std = @import("std");
const value_mod = @import("value.zig");
const codec = @import("codec_binary.zig");
const sortable = @import("codec_sortable.zig");
const phase = @import("phase.zig");

pub const Value = value_mod.Value;
pub const ValueError = value_mod.ValueError;

/// The value as it crosses the SQLite boundary
pub const SqliteRepr = union(enum) {
    null,
    int: i64,
    float: f64,
    /// The binary codec, in either payload shape; the tag byte says which.
    /// See the file header.
    blob: []const u8,
};

/// A reusable encode buffer, one per connection.
///
/// The engine encodes a value per result per row, and every sink it encodes
/// into copies the bytes before returning — `sqlite3_result_blob` is
/// SQLITE_TRANSIENT. So a single buffer, cleared before each value and freed
/// only with the connection, serves every value that connection will encode:
/// past the largest value yet seen, the encode path stops allocating.
pub const Scratch = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(gpa: std.mem.Allocator) Scratch {
        return .{ .gpa = gpa };
    }

    pub fn deinit(s: *Scratch) void {
        s.buf.deinit(s.gpa);
    }
};

/// scalar kinds pass through natively; see the file header for
/// how the rest divide between the two BLOB payload shapes.
///
/// `sink` is comptime-dispatched and implements `putNull`, `putInt`, `putFloat`
/// and `putBlob`. Encoding straight into the sink is what keeps the kind switch
/// to one: the old shape returned a `SqliteRepr` that every call site then
/// switched on again to pick its `sqlite3_result_*` call, five times over.
///
/// **`putBlob` must consume the bytes before it returns.** They belong to
/// `scratch` and the next value encoded through it overwrites them. Every sink
/// in the engine satisfies that because SQLite copies; a sink that needs to
/// keep the bytes wants `EncodeValue` below instead.
pub fn encodeTo(sink: anytype, scratch: *Scratch, v: Value) ValueError!void {
    var t = phase.CodecTimer.begin(.codec_encode);
    defer t.end();
    switch (v) {
        .null => sink.putNull(),
        .int => |i| sink.putInt(i),
        .float => |f| sink.putFloat(f),
        // Go returns ToBool() (a Go bool); the sqlite driver stores it as
        // INTEGER 0/1, so encode it as an int directly.
        .bool => |b| sink.putInt(@intFromBool(b)),
        .safe => |p| return encodeTo(sink, scratch, p.*),
        else => {
            // Cleared rather than trusted to be empty: an encode that failed
            // partway through leaves its half-written value behind, and the
            // next one must not inherit it.
            scratch.buf.clearRetainingCapacity();

            // Memcomparable kinds: a BLOB whose bytes order correctly, which is
            // what makes a BLOB safe here at all — SQLite never applies a
            // collation to one. See codec_sortable.zig.
            if (!try sortable.encodeAppend(&scratch.buf, scratch.gpa, v)) {
                // Kinds with no ordering to preserve keep the self-delimiting
                // codec, still as a BLOB. Its uvarint length prefixes sort by
                // length before content, which is only a problem for a kind that
                // can be ordered, and ARRAY/STRUCT/JSON/INTERVAL cannot be (the
                // analyzer rejects ORDER BY on all four).
                try codec.appendBinaryValue(&scratch.buf, scratch.gpa, v);
            }
            sink.putBlob(scratch.buf.items);
        },
    }
}

/// Captures an encoded value as a `SqliteRepr` instead of handing it to SQLite.
const ReprSink = struct {
    out: *SqliteRepr,

    fn putNull(s: ReprSink) void {
        s.out.* = .null;
    }
    fn putInt(s: ReprSink, i: i64) void {
        s.out.* = .{ .int = i };
    }
    fn putFloat(s: ReprSink, f: f64) void {
        s.out.* = .{ .float = f };
    }
    fn putBlob(s: ReprSink, b: []const u8) void {
        s.out.* = .{ .blob = b };
    }
};

/// `encodeTo` for callers that need to own the bytes rather than consume them
/// before the next value: the client bind path, where `bindBlobStatic` keeps
/// the pointer until the statement is done, and `LiteralFromValue` below. Both
/// run per statement rather than per row, which is why they can afford the
/// allocation the sink path exists to avoid.
pub fn EncodeValue(alloc: std.mem.Allocator, v: Value) ValueError!SqliteRepr {
    var out: SqliteRepr = .null;
    var scratch = Scratch.init(alloc);
    try encodeTo(ReprSink{ .out = &out }, &scratch, v);
    // Sized exactly to the value before it is handed over, because callers free
    // it and the buffer's capacity may exceed its length.
    if (out == .blob) out = .{ .blob = try scratch.buf.toOwnedSlice(alloc) };
    return out;
}

/// renders a Value as a SQL literal for embedded query text.
/// Every non-scalar value is a BLOB, represented as a X'..' literal.
pub fn LiteralFromValue(alloc: std.mem.Allocator, v: Value) ValueError![]u8 {
    var t = phase.CodecTimer.begin(.codec_literal);
    defer t.end();
    switch (v) {
        .null => return alloc.dupe(u8, "null"),
        .int => |i| return std.fmt.allocPrint(alloc, "{d}", .{i}),
        .float => |f| {
            // SQLite has no NaN/Inf literal syntax and scrubs any non-finite
            // arithmetic/math-function result to NULL, but a numeric literal that overflows a
            // double parses straight to +-Inf (`1e400`); NaN has no literal equivalent,
            // so it goes through zigquery_nan_literal() (fn_math.nanLiteral),
            // which sets the result value directly.
            if (std.math.isNan(f)) return alloc.dupe(u8, "zigquery_nan_literal()");
            if (std.math.isInf(f)) return alloc.dupe(u8, if (f > 0) "1e400" else "-1e400");
            var buf: [32]u8 = undefined;
            const s = value_mod.formatFloatGo(&buf, f);
            // Go: append ".0" to keep float context when the 'g' form has
            // neither '.' nor 'e' (e.g. "42" -> "42.0").
            if (std.mem.indexOfScalar(u8, s, '.') == null and
                std.mem.indexOfScalar(u8, s, 'e') == null)
            {
                return std.fmt.allocPrint(alloc, "{s}.0", .{s});
            }
            return alloc.dupe(u8, s);
        },
        .bool => |b| return alloc.dupe(u8, if (b) "true" else "false"),
        .safe => |p| return LiteralFromValue(alloc, p.*),
        // Delegating to EncodeValue is what guarantees a literal and a bound
        // parameter produce the same storage class — they used to be able to
        // disagree, since each decided the encoding for itself.
        else => switch (try EncodeValue(alloc, v)) {
            // An X'..' literal, which is also unambiguous SQL. The quoted form
            // below is a *string* only because SQLite tolerates double-quoted
            // identifiers that resolve to nothing, so a payload colliding with
            // a column name in scope would silently become that column.
            .blob => |b| {
                defer alloc.free(b);
                return hexLiteral(alloc, b);
            },
            // This arm is only reached for non-scalar kinds, which EncodeValue
            // always renders as a BLOB.
            else => unreachable,
        },
    }
}

fn hexLiteral(alloc: std.mem.Allocator, b: []const u8) ValueError![]u8 {
    // X, quote, two hex digits per byte, quote.
    const out = try alloc.alloc(u8, 2 + b.len * 2 + 1);
    out[0] = 'X';
    out[1] = '\'';
    const digits = "0123456789abcdef";
    for (b, 0..) |byte, i| {
        out[2 + i * 2] = digits[byte >> 4];
        out[3 + i * 2] = digits[byte & 0x0f];
    }
    out[out.len - 1] = '\'';
    return out;
}

/// The returned Value owns its bytes: they come from `alloc` and nothing in it
/// references `repr`. Use this whenever the Value outlives the call that
/// produced it — aggregate and window steps buffer decoded arguments across
/// rows in a per-group arena, so a Value pointing at SQLite's memory would
/// dangle on the next step.
pub fn DecodeValue(alloc: std.mem.Allocator, repr: SqliteRepr) ValueError!Value {
    return decodeRepr(alloc, repr, false);
}

/// As `DecodeValue`, but a `.blob` result aliases `repr.blob` rather than
/// copying out of it — saving a copy per argument per row on the hottest path
/// there is.
///
/// Only for callers that finish with the Value before returning, because
/// `repr.blob` is SQLite's memory and lives only as long as the current
/// statement step or UDF call. That holds for scalar UDF arguments (the
/// handler runs and returns) and for `Rows.next` (cellFromValue copies into
/// the rows arena immediately). It does **not** hold for aggregates.
pub fn DecodeValueBorrowing(alloc: std.mem.Allocator, repr: SqliteRepr) ValueError!Value {
    return decodeRepr(alloc, repr, true);
}

fn decodeRepr(
    alloc: std.mem.Allocator,
    repr: SqliteRepr,
    comptime borrow_blob: bool,
) ValueError!Value {
    var t = phase.CodecTimer.begin(.codec_decode);
    defer t.end();
    switch (repr) {
        .null => return Value.null,
        .int => |i| return Value{ .int = i },
        .float => |f| return Value{ .float = f },
        // Two payload shapes travel in a BLOB, told apart by tag range: the
        // self-delimiting codec owns everything below `sortable.tag_min`, the
        // memcomparable one everything from it up. This is a dispatch on
        // *kind*, not a compatibility fallback — which shape a kind uses is
        // fixed, and a database in an older format is refused at open (see
        // Db.storage_format_version) rather than sniffed for here.
        //
        // Borrows from `b`, which belongs to SQLite and stays valid for the
        // statement step or UDF call that produced it — long enough for every
        // caller, all of which consume the Value before returning (decodeArgs
        // into a handler, Rows.next into a Cell, and cellFromValue copies).
        .blob => |b| {
            if (b.len == 0) return error.CorruptData;
            // Copy first when the Value must outlive this call; the decode is
            // identical either way.
            const src = if (borrow_blob) b else try alloc.dupe(u8, b);
            if (src[0] < sortable.tag_min) return codec.decodeBinaryValueBorrowing(alloc, src);
            return sortable.decode(alloc, src);
        },
    }
}

// ----------------------------------------------------------------------
// castValue: stub only (the real CastValue port arrives with the spec/type
// milestone). Same-kind casts pass through; everything else is deferred.
// ----------------------------------------------------------------------

pub const TypeKind = enum {
    int64,
    bool,
    double,
    string,
    bytes,
    date,
    array,
    struct_,
    // Deferred kinds (present for completeness).
    numeric,
    bignumeric,
    json,
    datetime,
    time,
    timestamp,
    interval,
};

pub fn castValue(alloc: std.mem.Allocator, v: Value, to: TypeKind) ValueError!Value {
    _ = alloc;
    // Go CastValue: nil input stays nil regardless of target type.
    if (v == .null) return Value.null;
    const inner = if (v == .safe) v.safe.* else v;
    const same = switch (to) {
        .int64 => inner == .int,
        .bool => inner == .bool,
        .double => inner == .float,
        .string => inner == .string,
        .bytes => inner == .bytes,
        .date => inner == .date,
        .array => inner == .array,
        .struct_ => inner == .struct_,
        .json => inner == .json,
        else => false,
    };
    if (same) return v;
    return error.Unimplemented;
}

// ----------------------------------------------------------------------
// valueFromProto: port of encoder.go ValueFromZetaSQLValue + the
// *FromLiteral helpers, reading the decoded ValueProto/TypeProto instead of
// go-googlesql's Value accessors.
// ----------------------------------------------------------------------

const pb = @import("../proto/resolved_ast.zig");

const second_micros: i64 = 1_000_000;

// Packed civil bitfield layout shared by DATETIME/TIME (Go encoder.go). The
// packed-64-micros value is (seconds_bitfield << 20) | micros; within the
// seconds bitfield: sec@0(6), min@6(6), hour@12(5), day@17(5), month@22(4),
// year@26(14).
fn datetimeMicrosFromBitfield(bitfield: i64, nanos: i32) i64 {
    const sec = bitfield & 0b111111;
    const min = (bitfield >> 6) & 0b111111;
    const hour = (bitfield >> 12) & 0b11111;
    const day = (bitfield >> 17) & 0b11111;
    const month = (bitfield >> 22) & 0b1111;
    const year = (bitfield >> 26) & 0x3FFF;
    const micro = @divTrunc(@as(i64, nanos), 1000);
    const days = value_mod.daysFromCivil(year, month, day);
    return (days * 86400 + hour * 3600 + min * 60 + sec) * second_micros + micro;
}

// The proto's time_value is TimeValue::Packed64TimeNanos: the civil bitfield
// (hour@12(5), min@6(6), sec@0(6)) shifted left 30, with nanoseconds in the
// low 30 bits. (Go reaches the same value via the go-googlesql
// ToPacked64TimeMicros accessor, which rescales nanos->micros for it.)
fn timeMicrosFromPacked64(packed64: i64) i64 {
    const b = packed64 >> 30;
    const hour = (b >> 12) & 0b11111;
    const min = (b >> 6) & 0b111111;
    const sec = b & 0b111111;
    const nanos = packed64 & 0x3FFFFFFF;
    return (hour * 3600 + min * 60 + sec) * second_micros + @divTrunc(nanos, 1000);
}

/// googlesql NormalizeMode enum value -> name (public/functions/normalize_mode.proto).
fn normalizeModeName(idx: i32) ?[]const u8 {
    return switch (idx) {
        0 => "NFC",
        1 => "NFKC",
        2 => "NFD",
        3 => "NFKD",
        else => null,
    };
}

/// googlesql DateTimestampPart enum value -> name (public/functions/datetime.proto).
/// The only enums passed as function arguments are date-part enums.
fn datePartName(idx: i32) ?[]const u8 {
    return switch (idx) {
        1 => "YEAR",
        2 => "MONTH",
        3 => "DAY",
        4 => "DAYOFWEEK",
        5 => "DAYOFYEAR",
        6 => "QUARTER",
        7 => "HOUR",
        8 => "MINUTE",
        9 => "SECOND",
        10 => "MILLISECOND",
        11 => "MICROSECOND",
        12 => "NANOSECOND",
        13 => "DATE",
        14 => "WEEK",
        15 => "DATETIME",
        16 => "TIME",
        17 => "ISOYEAR",
        18 => "ISOWEEK",
        19 => "WEEK_MONDAY",
        20 => "WEEK_TUESDAY",
        21 => "WEEK_WEDNESDAY",
        22 => "WEEK_THURSDAY",
        23 => "WEEK_FRIDAY",
        24 => "WEEK_SATURDAY",
        25 => "PICOSECOND",
        else => null,
    };
}

/// Decodes googlesql's 16-byte IntervalValue binary layout (interval_value.cc
/// SerializeAndAppendToBytes): micros(int64 LE), days(int32 LE), months_nanos
/// (uint32 LE: sign@31, months@13..30, nano_fractions@0..9). An empty slice is
/// the zero interval.
fn intervalFromBinary(bytes: []const u8) !value_mod.Interval {
    if (bytes.len == 0) return value_mod.Interval{};
    if (bytes.len != 16) return error.CorruptData;
    const micros = std.mem.readInt(i64, bytes[0..8], .little);
    const days = std.mem.readInt(i32, bytes[8..12], .little);
    const months_nanos = std.mem.readInt(u32, bytes[12..16], .little);
    const nano_fractions: i32 = @intCast(months_nanos & 0x3FF);
    const months_mag: i64 = @intCast((months_nanos & 0x7FFFE000) >> 13);
    const months: i64 = if (months_nanos & 0x80000000 != 0) -months_mag else months_mag;
    // `micros` reaches googlesql's actual interval bound (~3.16e17), whose
    // nanosecond total would overflow i64 (interval_max_micros's own doc
    // comment on intervalFromMicros: "~3.2e20, well past i64"). Decompose in
    // microseconds instead and fold the leftover sub-microsecond nanosecond
    // fraction in afterward.
    var iv = value_mod.intervalFromMicros(micros);
    iv.sub_second_nanos += nano_fractions;
    iv.months = @intCast(months);
    iv.days = days;
    return iv;
}

/// Go ValueFromZetaSQLValue. A ValueProto with no oneof member set is the
/// NULL literal (Go: v.IsNull() -> nil Value).
pub fn valueFromProto(
    alloc: std.mem.Allocator,
    value_proto: *const pb.ValueProto,
    type_proto: *const pb.TypeProto,
) ValueError!Value {
    const v = value_proto.value orelse return Value.null;
    const kind = type_proto.type_kind orelse return error.Unimplemented;
    switch (kind) {
        // Go: intValueFromLiteral over the SQL literal; here the proto
        // carries the native value. Uint64 beyond int64 range would have
        // failed Go's ParseInt too.
        .TYPE_INT32 => return .{ .int = switch (v) {
            .int32_value => |x| @as(i64, x),
            else => return error.CorruptData,
        } },
        .TYPE_INT64 => return .{ .int = switch (v) {
            .int64_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_UINT32 => return .{ .int = switch (v) {
            .uint32_value => |x| @as(i64, x),
            else => return error.CorruptData,
        } },
        .TYPE_UINT64 => return .{ .int = switch (v) {
            .uint64_value => |x| std.math.cast(i64, x) orelse return error.FailedConversion,
            else => return error.CorruptData,
        } },
        .TYPE_BOOL => return .{ .bool = switch (v) {
            .bool_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_FLOAT => return .{ .float = switch (v) {
            .float_value => |x| @as(f64, x),
            else => return error.CorruptData,
        } },
        .TYPE_DOUBLE => return .{ .float = switch (v) {
            .double_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_STRING => return .{ .string = switch (v) {
            .string_value => |x| x,
            else => return error.CorruptData,
        } },
        .TYPE_BYTES => return .{ .bytes = switch (v) {
            .bytes_value => |x| x,
            else => return error.CorruptData,
        } },
        // Go dateValueFromLiteral: civil days since the Unix epoch.
        .TYPE_DATE => return .{ .date = switch (v) {
            .date_value => |days| @as(i64, days),
            else => return error.CorruptData,
        } },
        // Go timestampValueFromLiteral: the proto carries seconds + nanos;
        // TimestampValue stores unix micros (Go: time.Unix(sec, rem*1000)).
        .TYPE_TIMESTAMP => {
            const ts = switch (v) {
                .timestamp_value => |x| x,
                else => return error.CorruptData,
            };
            const seconds = ts.seconds orelse 0;
            const nanos = ts.nanos orelse 0;
            return .{ .timestamp = seconds *% second_micros + @divTrunc(@as(i64, nanos), 1000) };
        },
        // Go datetimeValueFromLiteral: unpack the packed civil bitfield. The
        // proto splits it as bit_field_datetime_seconds (Y/M/D/H/M/S) + nanos.
        .TYPE_DATETIME => {
            const dt = switch (v) {
                .datetime_value => |x| x,
                else => return error.CorruptData,
            };
            return .{ .datetime = datetimeMicrosFromBitfield(
                dt.bit_field_datetime_seconds orelse 0,
                dt.nanos orelse 0,
            ) };
        },
        // Go timeValueFromLiteral: the proto's time_value is the packed-64
        // time-micros value (bitfield << 20 | micros).
        .TYPE_TIME => {
            const packed64 = switch (v) {
                .time_value => |x| x,
                else => return error.CorruptData,
            };
            return .{ .time = timeMicrosFromPacked64(packed64) };
        },
        .TYPE_ARRAY => {
            // Go arrayValueFromLiteral. NULL arrays were handled by the
            // oneof-not-set case above; this is a present (possibly empty)
            // array.
            const arr = switch (v) {
                .array_value => |x| x,
                else => return error.CorruptData,
            };
            const arr_type = type_proto.array_type orelse return error.CorruptData;
            const elem_type = arr_type.element_type orelse return error.CorruptData;
            const values = try alloc.alloc(Value, arr.element.len);
            for (arr.element, 0..) |elem, i| {
                values[i] = try valueFromProto(alloc, elem, elem_type);
            }
            return value_mod.arrayValue(alloc, values);
        },
        .TYPE_STRUCT => {
            // Go structValueFromLiteral: field names from the struct type.
            const st = switch (v) {
                .struct_value => |x| x,
                else => return error.CorruptData,
            };
            const struct_type = type_proto.struct_type orelse return error.CorruptData;
            if (struct_type.field.len != st.field.len) return error.CorruptData;
            const keys = try alloc.alloc([]const u8, st.field.len);
            const values = try alloc.alloc(Value, st.field.len);
            for (st.field, 0..) |field, i| {
                const sf = struct_type.field[i];
                keys[i] = sf.field_name orelse "";
                const field_type = sf.field_type orelse return error.CorruptData;
                values[i] = try valueFromProto(alloc, field, field_type);
            }
            return value_mod.structValue(alloc, keys, values);
        },
        // RANGE literal: `range_value` holds the two bounds as nested
        // ValueProtos, so this recurses on the element type the way TYPE_ARRAY
        // does. googlesql always sets both fields and clears the one standing
        // for UNBOUNDED (value.proto: "Start and end values must always be
        // present"), so an absent field and a null one both mean unbounded.
        .TYPE_RANGE => {
            const rv = switch (v) {
                .range_value => |x| x,
                else => return error.CorruptData,
            };
            const range_type = type_proto.range_type orelse return error.CorruptData;
            const elem_type = range_type.element_type orelse return error.CorruptData;
            const elem_kind = elem_type.type_kind orelse .TYPE_UNKNOWN;
            const elem: value_mod.Range.ElemKind = switch (elem_kind) {
                .TYPE_DATE => .date,
                .TYPE_DATETIME => .datetime,
                .TYPE_TIMESTAMP => .timestamp,
                // range_type.cc IsSupportedElementTypeKind allows only these
                // three, so anything else means a proto we did not build.
                else => return error.Unimplemented,
            };
            const start = if (rv.start) |p| try valueFromProto(alloc, p, elem_type) else Value.null;
            const end = if (rv.end) |p| try valueFromProto(alloc, p, elem_type) else Value.null;
            return value_mod.rangeValue(
                elem,
                if (start == .null) null else try value_mod.rangeElementScalar(start),
                if (end == .null) null else try value_mod.rangeElementScalar(end),
            );
        },
        // INTERVAL literal: the proto carries interval_value as googlesql's
        // 16-byte binary interval encoding. Go reads the canonical string via
        // GetSQLLiteral; we decode the binary layout directly.
        .TYPE_INTERVAL => {
            const bytes = switch (v) {
                .interval_value => |x| x,
                else => return error.CorruptData,
            };
            return .{ .interval = intervalFromBinary(bytes) catch return error.CorruptData };
        },
        // Enum literal: Go reads GetSQLLiteral (the enum value's name) and
        // wraps it as a StringValue. The engine receives date-part enums
        // (googlesql DateTimestampPart) and the NORMALIZE mode enum; select
        // the name table by the enum type name.
        .TYPE_ENUM => {
            const idx = switch (v) {
                .enum_value => |x| x,
                else => return error.CorruptData,
            };
            const enum_name: []const u8 =
                if (type_proto.enum_type) |et| (et.enum_name orelse "") else "";
            const name = if (std.mem.indexOf(u8, enum_name, "NormalizeMode") != null)
                (normalizeModeName(idx) orelse return error.Unimplemented)
            else
                (datePartName(idx) orelse return error.Unimplemented);
            return .{ .string = name };
        },
        // Go jsonValueFromLiteral: the analyzer hands us the normalized JSON
        // string (zetasql sorts object keys when normalizing JSON literals).
        .TYPE_JSON => return .{ .json = switch (v) {
            .json_value => |s| s,
            else => return error.CorruptData,
        } },
        // NUMERIC/BIGNUMERIC literal: the proto carries the value as a
        // minimal-length little-endian two's-complement integer scaled by
        // 10^9 / 10^38 (verified empirically against the analyzer). Go goes
        // through GetSQLLiteral + numericValueFromLiteral instead; decoding
        // the proto directly yields the identical Rat.
        .TYPE_NUMERIC, .TYPE_BIGNUMERIC => {
            const bytes = switch (v) {
                .numeric_value => |b| b,
                .bignumeric_value => |b| b,
                else => return error.CorruptData,
            };
            const is_big = kind == .TYPE_BIGNUMERIC;
            const scale: usize = if (is_big) 38 else 9;
            return value_mod.numericFromTwosComplement(alloc, bytes, scale, is_big) catch |err|
                switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.CorruptData,
                };
        },
        // Remaining kinds (geography, proto, ...) stay deferred.
        else => return error.Unimplemented,
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "EncodeValue keeps scalars native" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(SqliteRepr.null, try EncodeValue(alloc, Value.null));
    try testing.expectEqual(SqliteRepr{ .int = -7 }, try EncodeValue(alloc, Value{ .int = -7 }));
    try testing.expectEqual(
        SqliteRepr{ .float = 1.5 },
        try EncodeValue(alloc, Value{ .float = 1.5 }),
    );
    // Bool travels as INTEGER 0/1 (Go bool bound by the sqlite driver).
    try testing.expectEqual(SqliteRepr{ .int = 1 }, try EncodeValue(alloc, Value{ .bool = true }));
    try testing.expectEqual(SqliteRepr{ .int = 0 }, try EncodeValue(alloc, Value{ .bool = false }));
    // SafeValue encodes as its inner value.
    const safe = try value_mod.safeValue(alloc, Value{ .int = 3 });
    try testing.expectEqual(SqliteRepr{ .int = 3 }, try EncodeValue(alloc, safe));
}

test "EncodeValue splits non-scalar kinds by storage format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Memcomparable: a BLOB whose payload is the raw bytes after the kind tag,
    // with no length prefix, which would sort by length before content.
    const repr = try EncodeValue(alloc, Value{ .string = "hello" });
    try testing.expect(repr == .blob);
    try testing.expectEqualSlices(u8, "\x60hello", repr.blob);

    // Kinds with no ordering also become BLOBs, carrying the self-delimiting
    // codec (tag 0x0e here) rather than the memcomparable one.
    const arr = try value_mod.arrayValue(alloc, &.{ Value{ .int = 1 }, Value.null });
    const arr_repr = try EncodeValue(alloc, arr);
    try testing.expect(arr_repr == .blob);
    try testing.expectEqual(@as(u8, 0x0e), arr_repr.blob[0]);
    try testing.expect((try EncodeValue(alloc, Value{ .json = "{}" })) == .blob);

    // NUMERIC was the last kind in TEXT. It is memcomparable now too, so
    // nothing is: no value reaches the boundary base64-wrapped.
    const num = try value_mod.numericFromString(alloc, "1.5", false);
    const num_repr = try EncodeValue(alloc, num);
    try testing.expect(num_repr == .blob);
    try testing.expectEqual(@as(u8, 0x70), num_repr.blob[0]);
    try testing.expectEqual(@as(usize, 17), num_repr.blob.len);
}

test "encodeTo reuses its scratch buffer instead of allocating per value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // One value of each shape the blob path takes — the memcomparable codec
    // (string, numeric) and the self-delimiting one (array, struct) — plus a
    // native scalar, which never touches the buffer at all.
    const values = [_]Value{
        Value{ .string = "hello" },
        try value_mod.numericFromString(alloc, "1.5", false),
        try value_mod.arrayValue(alloc, &.{ Value{ .int = 1 }, Value{ .string = "x" } }),
        try value_mod.structValue(alloc, &.{"k"}, &.{Value{ .bytes = "vv" }}),
        Value{ .int = 7 },
    };

    var counting = std.testing.FailingAllocator.init(testing.allocator, .{});
    var scratch = Scratch.init(counting.allocator());
    defer scratch.deinit();
    var out: SqliteRepr = .null;

    // Warming it to the largest value in the set is the only time it allocates.
    for (values) |v| try encodeTo(ReprSink{ .out = &out }, &scratch, v);
    const warm = counting.allocations;
    try testing.expect(warm > 0);

    // This is the property the scratch exists for. What it replaced was an
    // allocation from the call site's arena, and on the window and vtab paths
    // that arena is not reset per row — so every row's encoded bytes were
    // retained until the partition or scan ended.
    for (0..100) |_| {
        for (values) |v| try encodeTo(ReprSink{ .out = &out }, &scratch, v);
    }
    try testing.expectEqual(warm, counting.allocations);

    // A value longer than any seen so far still grows it...
    const long = try alloc.alloc(u8, 8192);
    @memset(long, 'x');
    try encodeTo(ReprSink{ .out = &out }, &scratch, Value{ .string = long });
    try testing.expect(counting.allocations > warm);
    try testing.expectEqual(@as(usize, 1 + long.len), out.blob.len);

    // ...and keeps the capacity, so the small values are free again after it.
    const grown = counting.allocations;
    for (values) |v| try encodeTo(ReprSink{ .out = &out }, &scratch, v);
    try testing.expectEqual(grown, counting.allocations);
}

test "EncodeValue hands back a blob sized exactly to the value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // It builds in a growable buffer whose capacity outruns its length, and
    // LiteralFromValue frees what it gets back — so the slice has to be shrunk
    // to the value before it is handed over, not merely point at it.
    const arr = try value_mod.arrayValue(alloc, &.{Value{ .string = "abc" }});
    const repr = try EncodeValue(alloc, arr);
    try testing.expectEqualSlices(u8, try codec.encodeBinaryValue(alloc, arr), repr.blob);
}

test "DecodeValue(EncodeValue(v)) round trips foundation kinds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const identity_cases = [_]Value{
        Value.null,
        Value{ .int = 42 },
        Value{ .int = std.math.minInt(i64) },
        Value{ .float = -1.5 },
        Value{ .float = std.math.nan(f64) },
        Value{ .string = "héllo" },
        Value{ .string = "" },
        Value{ .bytes = "\x00\xff" },
        Value{ .date = try value_mod.parseDateDays("2021-03-04") },
        try value_mod.arrayValue(alloc, &.{
            Value{ .int = 1 },
            Value.null,
            try value_mod.structValue(alloc, &.{"k"}, &.{Value{ .string = "v" }}),
        }),
        try value_mod.structValue(
            alloc,
            &.{ "a", "b" },
            &.{ Value{ .float = 2.5 }, Value{ .bytes = "zz" } },
        ),
    };
    for (identity_cases) |v| {
        const decoded = try DecodeValue(alloc, try EncodeValue(alloc, v));
        try value_mod.expectValueEqual(v, decoded);
    }

    // Bool round-trips as INTEGER (exactly like the Go driver stack).
    const bool_decoded = try DecodeValue(alloc, try EncodeValue(alloc, Value{ .bool = true }));
    try value_mod.expectValueEqual(Value{ .int = 1 }, bool_decoded);
}

test "EncodeValue/DecodeValue round-trips time kinds (CURRENT_TIMESTAMP path)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]Value{
        // The encoded-timestamp-literal arg the transformer injects for
        // QueryOptions.current_time_unix_micros travels through here.
        Value{ .timestamp = 1136239445_000000 },
        Value{ .timestamp = 1705314615_500000 },
        Value{ .datetime = try value_mod.parseDatetimeMicros("2024-01-15 10:30:15.123456") },
        Value{ .time = try value_mod.parseTimeMicros("10:30:15.5") },
        Value{ .interval = try value_mod.parseIntervalValue("1-2 3 4:5:6") },
    };
    for (cases) |v| {
        // All of these cross as BLOBs: the date/time kinds because they are
        // memcomparable, INTERVAL because it has no order to preserve.
        const repr = try EncodeValue(alloc, v);
        try testing.expect(repr == .blob);
        try value_mod.expectValueEqual(v, try DecodeValue(alloc, repr));
    }
}

test "DecodeValue rejects a BLOB with an unknown tag" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(error.CorruptData, DecodeValue(alloc, .{ .blob = "\x7b" }));
    try testing.expectError(error.CorruptData, DecodeValue(alloc, .{ .blob = "\x30" }));
    try testing.expectError(error.CorruptData, DecodeValue(alloc, .{ .blob = "" }));
}

test "LiteralFromValue formatting" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqualStrings("null", try LiteralFromValue(alloc, Value.null));
    try testing.expectEqualStrings("42", try LiteralFromValue(alloc, Value{ .int = 42 }));
    try testing.expectEqualStrings(
        "-9223372036854775808",
        try LiteralFromValue(alloc, Value{ .int = std.math.minInt(i64) }),
    );
    try testing.expectEqualStrings("true", try LiteralFromValue(alloc, Value{ .bool = true }));
    try testing.expectEqualStrings("false", try LiteralFromValue(alloc, Value{ .bool = false }));

    // Float cases: Go strconv 'g' plus the ".0" float-context suffix.
    try testing.expectEqualStrings("42.0", try LiteralFromValue(alloc, Value{ .float = 42.0 }));
    try testing.expectEqualStrings("1.5", try LiteralFromValue(alloc, Value{ .float = 1.5 }));
    try testing.expectEqualStrings("1e+20", try LiteralFromValue(alloc, Value{ .float = 1e20 }));
    try testing.expectEqualStrings("0.0001", try LiteralFromValue(alloc, Value{ .float = 0.0001 }));
    try testing.expectEqualStrings("1e-05", try LiteralFromValue(alloc, Value{ .float = 0.00001 }));
    try testing.expectEqualStrings("100000.0", try LiteralFromValue(alloc, Value{ .float = 100000.0 }));
    try testing.expectEqualStrings("1e+06", try LiteralFromValue(alloc, Value{ .float = 1e6 }));
    try testing.expectEqualStrings("-0.0", try LiteralFromValue(alloc, Value{ .float = -0.0 }));

    // Every non-scalar kind renders as an X'..' BLOB literal, so a literal and a bound
    // value produce the same storage class.
    try testing.expectEqualStrings("X'606869'", try LiteralFromValue(alloc, Value{ .string = "hi" }));
    // 0x40 is the DATE tag; the payload is 0 with its sign bit flipped, which is
    // what makes pre-epoch dates sort below the epoch under memcmp.
    try testing.expectEqualStrings("X'408000000000000000'", try LiteralFromValue(alloc, Value{ .date = 0 }));

    // Every non-scalar kind is a BLOB now, so every non-scalar literal is an
    // X'..' literal — the double-quoted base64 form has no remaining producer.
    const arr = try value_mod.arrayValue(alloc, &.{Value{ .int = 1 }});
    try testing.expect(std.mem.startsWith(u8, try LiteralFromValue(alloc, arr), "X'"));
    const num = try value_mod.numericFromString(alloc, "1.5", false);
    try testing.expect(std.mem.startsWith(u8, try LiteralFromValue(alloc, num), "X'"));
}

test "castValue stub passes same-kind values through" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try value_mod.expectValueEqual(
        Value{ .int = 5 },
        try castValue(alloc, Value{ .int = 5 }, .int64),
    );
    try value_mod.expectValueEqual(Value.null, try castValue(alloc, Value.null, .string));
    try testing.expectError(error.Unimplemented, castValue(alloc, Value{ .int = 5 }, .string));
    try testing.expectError(
        error.Unimplemented,
        castValue(alloc, Value{ .string = "1" }, .timestamp),
    );
}

// ----------------------------------------------------------------------
// valueFromProto tests: real analyzer round-trips.
// ----------------------------------------------------------------------

const analyzer_ffi = @import("../analyzer_ffi.zig");

/// Analyzes `SELECT <literal>` and converts the first projected literal.
fn literalValueOf(alloc: std.mem.Allocator, sql: [:0]const u8) !Value {
    const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, sql, 0, "{}");
    const query = analyzed.node.node.?.resolved_statement_node.node.?.resolved_query_stmt_node;
    const scan = query.query.?.node.?.resolved_project_scan_node;
    const literal = scan.expr_list[0].expr.?.node.?.resolved_literal_node;
    const vwt = literal.value.?;
    return valueFromProto(alloc, vwt.value.?, vwt.type.?);
}

test "valueFromProto numeric / bignumeric literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]struct { sql: [:0]const u8, text: []const u8, big: bool }{
        .{ .sql = "SELECT NUMERIC '1.5'", .text = "1.5", .big = false },
        .{ .sql = "SELECT NUMERIC '-1.5'", .text = "-1.5", .big = false },
        .{ .sql = "SELECT NUMERIC '0'", .text = "0", .big = false },
        .{ .sql = "SELECT NUMERIC '-0.000000001'", .text = "-0.000000001", .big = false },
        .{ .sql = "SELECT NUMERIC '99999999999999999999999999999.999999999'", .text = "99999999999999999999999999999.999999999", .big = false },
        .{ .sql = "SELECT BIGNUMERIC '1.5'", .text = "1.5", .big = true },
        .{
            .sql = "SELECT BIGNUMERIC '-578960446186580977117854925043439539266.34992332820282019728792003956564819967'",
            .text = "-578960446186580977117854925043439539266.34992332820282019728792003956564819967",
            .big = true,
        },
        .{
            .sql = "SELECT BIGNUMERIC '578960446186580977117854925043439539266.34992332820282019728792003956564819967'",
            .text = "578960446186580977117854925043439539266.34992332820282019728792003956564819967",
            .big = true,
        },
    };
    for (cases) |c| {
        const v = try literalValueOf(alloc, c.sql);
        try testing.expect(v == .numeric);
        try testing.expectEqual(c.big, v.numeric.is_bignumeric);
        try testing.expectEqualStrings(c.text, try v.toString(alloc));
    }
}

test "valueFromProto scalar literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try value_mod.expectValueEqual(Value{ .int = 42 }, try literalValueOf(alloc, "SELECT 42"));
    try value_mod.expectValueEqual(Value{ .bool = true }, try literalValueOf(alloc, "SELECT true"));
    try value_mod.expectValueEqual(Value{ .float = 1.5 }, try literalValueOf(alloc, "SELECT 1.5"));
    try value_mod.expectValueEqual(Value{ .string = "héllo" }, try literalValueOf(alloc, "SELECT 'héllo'"));
    try value_mod.expectValueEqual(Value{ .bytes = "ab\x00" }, try literalValueOf(alloc, "SELECT b'ab\\x00'"));
    // NULL literal: ValueProto with no oneof member set.
    try value_mod.expectValueEqual(Value.null, try literalValueOf(alloc, "SELECT NULL"));
}

test "valueFromProto date literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const expected_days = try value_mod.parseDateDays("2023-01-15");
    try value_mod.expectValueEqual(
        Value{ .date = expected_days },
        try literalValueOf(alloc, "SELECT DATE '2023-01-15'"),
    );
}

test "valueFromProto array literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try literalValueOf(alloc, "SELECT [1, 2, 3]");
    const expected = try value_mod.arrayValue(alloc, &.{
        Value{ .int = 1 }, Value{ .int = 2 }, Value{ .int = 3 },
    });
    try value_mod.expectValueEqual(expected, v);

    // Empty array is a present array with no elements, not NULL.
    const empty = try literalValueOf(alloc, "SELECT ARRAY<INT64>[]");
    try testing.expect(empty == .array);
    try testing.expectEqual(@as(usize, 0), empty.array.values.len);

    // NULL array is NULL.
    const null_array = try literalValueOf(alloc, "SELECT CAST(NULL AS ARRAY<INT64>)");
    try value_mod.expectValueEqual(Value.null, null_array);
}

test "valueFromProto struct literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const v = try literalValueOf(alloc, "SELECT STRUCT(1 AS a, 'x' AS b)");
    const expected = try value_mod.structValue(
        alloc,
        &.{ "a", "b" },
        &.{ Value{ .int = 1 }, Value{ .string = "x" } },
    );
    try value_mod.expectValueEqual(expected, v);
}

test "valueFromProto timestamp / datetime / time literals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // TIMESTAMP '2006-01-02 22:04:05+00' == unix 1136239445 => micros *1e6.
    const ts = try literalValueOf(alloc, "SELECT TIMESTAMP '2006-01-02 22:04:05+00'");
    try testing.expect(ts == .timestamp);
    try testing.expectEqual(@as(i64, 1136239445_000000), ts.timestamp);

    // Fractional-second timestamp.
    const tsf = try literalValueOf(alloc, "SELECT TIMESTAMP '2024-01-15 10:30:15.5+00'");
    try testing.expectEqual(@as(i64, 1705314615_500000), tsf.timestamp);

    // DATETIME round-trips through the packed civil bitfield.
    const dt = try literalValueOf(alloc, "SELECT DATETIME '2024-01-15 10:30:00'");
    try testing.expect(dt == .datetime);
    var buf: [40]u8 = undefined;
    try testing.expectEqualStrings("2024-01-15 10:30:00", value_mod.formatDatetimeString(&buf, dt.datetime));

    const dtf = try literalValueOf(alloc, "SELECT DATETIME '2024-01-15 10:30:15.123456'");
    try testing.expectEqualStrings("2024-01-15 10:30:15.123456", value_mod.formatDatetimeString(&buf, dtf.datetime));

    // TIME via the packed-64 time-micros value.
    const tv = try literalValueOf(alloc, "SELECT TIME '10:30:15'");
    try testing.expect(tv == .time);
    try testing.expectEqualStrings("10:30:15", value_mod.formatTimeString(&buf, tv.time));

    const tvf = try literalValueOf(alloc, "SELECT TIME '10:30:15.5'");
    try testing.expectEqualStrings("10:30:15.5", value_mod.formatTimeString(&buf, tvf.time));
}

test "valueFromProto decodes interval literal (googlesql binary layout)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // 16-byte layout: micros(i64 LE), days(i32 LE), months_nanos(u32 LE).
    // Encode INTERVAL "1-2 3 4:5:6" = 14 months, 3 days, 4:05:06 in micros.
    var buf: [16]u8 = undefined;
    const micros: i64 = ((4 * 3600 + 5 * 60 + 6)) * 1_000_000;
    std.mem.writeInt(i64, buf[0..8], micros, .little);
    std.mem.writeInt(i32, buf[8..12], 3, .little);
    std.mem.writeInt(u32, buf[12..16], @as(u32, 14) << 13, .little); // months=14
    var vp = pb.ValueProto{ .value = .{ .interval_value = &buf } };
    var tp = pb.TypeProto{ .type_kind = .TYPE_INTERVAL };
    const v = try valueFromProto(alloc, &vp, &tp);
    try testing.expect(v == .interval);
    var out: [96]u8 = undefined;
    try testing.expectEqualStrings("1-2 3 4:5:6", value_mod.formatInterval(&out, v.interval));

    // Empty slice -> zero interval.
    var vp0 = pb.ValueProto{ .value = .{ .interval_value = "" } };
    const z = try valueFromProto(alloc, &vp0, &tp);
    try testing.expectEqualStrings("0-0 0 0:0:0", value_mod.formatInterval(&out, z.interval));
}
