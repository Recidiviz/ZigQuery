//! Binary value codec: each value is [tag byte][payload]; variable-length
//! payloads are uvarint-length-prefixed so every value is self-delimiting,
//! which is what lets it nest.
//!
//! JSON, INTERVAL, ARRAY and STRUCT — plus every value nested inside a
//! composite, including numerics and ranges. Carried as a raw BLOB; the tag
//! range (below codec_sortable.tag_min here, at or above it there) says which
//! shape a payload is.
//!
//! Started as a port of go-zetasqlite internal/codec_binary.go and no longer
//! is. Go stored DATE, DATETIME and TIME as their `ToString` renderings and
//! NUMERIC as `Rat.MarshalText`, so a value that was an integer in a register
//! was formatted to decimal text on the way out and parsed back on the way in,
//! once per nested value per row. They are fixed-width little-endian integers
//! here instead — the same shape the neighbouring INT64 and TIMESTAMP tags
//! always had.
//!
//! Nothing was owed to Go's bytes by then: the RANGE tag (0x10) has no Go
//! counterpart, storage format 3 had already replaced the NUMERIC payload with
//! a scaled integer in decimal, and a database in an older format is refused at
//! open rather than migrated (`Db.storage_format_version`). What the text form
//! cost is a format-and-parse pair per value; what it bought, by then, was
//! nothing.
// ephor:ignore-file ZA302 ZA303 ZA304 ZA701

const std = @import("std");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const ValueError = value_mod.ValueError;

// Tag bytes (complete set, all implemented).
pub const bin_tag_null: u8 = 0x00;
pub const bin_tag_int: u8 = 0x01;
pub const bin_tag_float: u8 = 0x02;
pub const bin_tag_bool: u8 = 0x03;
pub const bin_tag_string: u8 = 0x04;
pub const bin_tag_bytes: u8 = 0x05;
pub const bin_tag_numeric: u8 = 0x06;
pub const bin_tag_bignumeric: u8 = 0x07;
pub const bin_tag_json: u8 = 0x08;
pub const bin_tag_date: u8 = 0x09;
pub const bin_tag_datetime: u8 = 0x0a;
pub const bin_tag_time: u8 = 0x0b;
pub const bin_tag_timestamp: u8 = 0x0c;
pub const bin_tag_interval: u8 = 0x0d;
pub const bin_tag_array: u8 = 0x0e;
pub const bin_tag_struct: u8 = 0x0f;
/// RANGE. First tag past the sixteen go-zetasqlite inherited, which is why it
/// is also the first free to design: there is no Go RangeValue whose bytes
/// this has to match.
///
/// Components rather than the canonical string its date/datetime/interval
/// neighbours store, because the string is ambiguous —
/// `[UNBOUNDED, UNBOUNDED)` renders identically for all three element kinds,
/// so a text payload could not say which one it held.
pub const bin_tag_range: u8 = 0x10;

/// Which bounds follow the element byte. An absent bound writes no payload at
/// all, so `[UNBOUNDED, UNBOUNDED)` costs three bytes.
const range_flag_start: u8 = 1 << 0;
const range_flag_end: u8 = 1 << 1;

/// Payload widths for the two decimal kinds: the unscaled integer, two's
/// complement little-endian, at the width its scale needs. NUMERIC's 38 digits
/// need 127 bits and BIGNUMERIC's 76 need 255 — the same widths
/// codec_sortable.zig uses, minus the bias it needs and this does not, since
/// nothing compares these bytes.
///
/// Fixed rather than minimal-length: it makes both directions a memcpy, and a
/// length prefix would cost a byte of its own on most values anyway. The
/// tradeoff is real but small and one-directional — a NUMERIC below ~10^29
/// grows by a few bytes against the decimal text (`1.5` was 12 bytes, is 17),
/// while one at full precision drops from 40 to 17 and every BIGNUMERIC drops
/// from up to 41 to 33.
const numeric_bytes: usize = 16;
const bignumeric_bytes: usize = 32;

// Pre-sizing this list with a computed hint was tried and measured neutral
// (encode 137.9ms -> 136.0ms over 2.4M values, inside run-to-run noise): on an
// arena the list is the most recent allocation, so growth extends in place
// rather than copying, and for arrays the hint cost a second recursive walk.
pub fn encodeBinaryValue(alloc: std.mem.Allocator, v: Value) ValueError![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(alloc);
    try appendBinaryValue(&buf, alloc, v);
    return buf.toOwnedSlice(alloc);
}

fn appendUvarint(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, x_in: u64) ValueError!void {
    var x = x_in;
    while (x >= 0x80) {
        try buf.append(alloc, @as(u8, @truncate(x)) | 0x80);
        x >>= 7;
    }
    try buf.append(alloc, @truncate(x));
}

fn appendBinaryString(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    tag: u8,
    s: []const u8,
) ValueError!void {
    try buf.append(alloc, tag);
    try appendUvarint(buf, alloc, s.len);
    try buf.appendSlice(alloc, s);
}

/// A tag and its fixed-width little-endian payload. `T`'s width *is* the
/// payload's, so the tag alone says how many bytes to read back — which is what
/// keeps the format self-delimiting without a length prefix.
fn appendBinaryFixed(
    buf: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    tag: u8,
    comptime T: type,
    v: T,
) ValueError!void {
    try buf.append(alloc, tag);
    var le: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &le, v, .little);
    try buf.appendSlice(alloc, &le);
}

/// Appends `v` to `buf`. The primitive the owning `encodeBinaryValue` above and
/// the scratch-buffer encode path in `encoder.zig` share, so neither owns a
/// second copy of the format.
pub fn appendBinaryValue(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: Value) ValueError!void {
    switch (v) {
        .null => try buf.append(alloc, bin_tag_null),
        .safe => |p| try appendBinaryValue(buf, alloc, p.*),
        .int => |i| try appendBinaryFixed(buf, alloc, bin_tag_int, i64, i),
        .float => |f| try appendBinaryFixed(buf, alloc, bin_tag_float, u64, @bitCast(f)),
        .bool => |b| {
            try buf.append(alloc, bin_tag_bool);
            try buf.append(alloc, @intFromBool(b));
        },
        .string => |s| try appendBinaryString(buf, alloc, bin_tag_string, s),
        .bytes => |b| try appendBinaryString(buf, alloc, bin_tag_bytes, b),
        // Go stores JsonValue as a length-prefixed raw JSON string (tag 0x08).
        .json => |s| try appendBinaryString(buf, alloc, bin_tag_json, s),
        // The four time kinds are all one i64 in the units their Value variant
        // stores — civil days, civil micros, micros since midnight, unix
        // micros. Go rendered the first three as text and parsed them back; the
        // number was always right there.
        .date => |days| try appendBinaryFixed(buf, alloc, bin_tag_date, i64, days),
        .datetime => |m| try appendBinaryFixed(buf, alloc, bin_tag_datetime, i64, m),
        .time => |m| try appendBinaryFixed(buf, alloc, bin_tag_time, i64, m),
        .timestamp => |m| try appendBinaryFixed(buf, alloc, bin_tag_timestamp, i64, m),
        // tag, element kind, presence flags, then only the bounds present.
        .range => |r| {
            try buf.append(alloc, bin_tag_range);
            try buf.append(alloc, @backingInt(r.elem));
            var flags: u8 = 0;
            if (r.has_start) flags |= range_flag_start;
            if (r.has_end) flags |= range_flag_end;
            try buf.append(alloc, flags);
            var le: [8]u8 = undefined;
            if (r.startBound()) |n| {
                std.mem.writeInt(i64, &le, n, .little);
                try buf.appendSlice(alloc, &le);
            }
            if (r.endBound()) |n| {
                std.mem.writeInt(i64, &le, n, .little);
                try buf.appendSlice(alloc, &le);
            }
        },
        // Go stores *IntervalValue as its ToString string.
        .interval => |iv| {
            var tmp: [96]u8 = undefined;
            try appendBinaryString(
                buf,
                alloc,
                bin_tag_interval,
                value_mod.formatInterval(&tmp, iv),
            );
        },
        // The scaled integer googlesql stores, as an integer, tagged by kind —
        // the tag supplies both the scale and the width on the way back in.
        // Storage format 3 wrote the same integer in decimal (goccy wrote
        // Rat.MarshalText, "3/2" for 1.5); rendering a 256-bit value to decimal
        // is a chain of divisions, and parsing it back another.
        .numeric => |n| {
            if (n.is_bignumeric) {
                return appendBinaryFixed(buf, alloc, bin_tag_bignumeric, i256, n.unscaled);
            }
            // Narrowing is safe by the construction-time bound, but checked
            // rather than asserted: an unchecked cast would silently truncate
            // in release, and the value would decode as a different number.
            const narrow = std.math.cast(i128, n.unscaled) orelse
                return error.NumericOutOfRange;
            try appendBinaryFixed(buf, alloc, bin_tag_numeric, i128, narrow);
        },
        .array => |arr| {
            try buf.append(alloc, bin_tag_array);
            try appendUvarint(buf, alloc, arr.values.len);
            for (arr.values) |elem| try appendBinaryValue(buf, alloc, elem);
        },
        .struct_ => |st| {
            try buf.append(alloc, bin_tag_struct);
            try appendUvarint(buf, alloc, st.values.len);
            for (st.values, 0..) |elem, i| {
                // Go: key = keys[i] if present, else "".
                const key: []const u8 = if (i < st.keys.len) st.keys[i] else "";
                try appendUvarint(buf, alloc, key.len);
                try buf.appendSlice(alloc, key);
                try appendBinaryValue(buf, alloc, elem);
            }
        },
    }
}

/// Bounds-checked cursor over a binary value buffer (Go binReader).
const BinReader = struct {
    buf: []const u8,
    pos: usize = 0,

    fn byte(r: *BinReader) ValueError!u8 {
        if (r.pos >= r.buf.len) return error.CorruptData; // unexpected end of buffer
        const b = r.buf[r.pos];
        r.pos += 1;
        return b;
    }

    fn uvarint(r: *BinReader) ValueError!u64 {
        var x: u64 = 0;
        var shift: u6 = 0;
        var i: usize = 0;
        while (true) : (i += 1) {
            if (i >= 10 or r.pos >= r.buf.len) return error.CorruptData; // invalid varint
            const b = r.buf[r.pos];
            r.pos += 1;
            if (b < 0x80) {
                if (i == 9 and b > 1) return error.CorruptData; // overflows u64
                return x | (@as(u64, b) << shift);
            }
            x |= @as(u64, b & 0x7f) << shift;
            shift +%= 7;
        }
    }

    /// A fixed-width little-endian integer. The width comes from `T`, which the
    /// tag fixes, so there is nothing to read to find out how far to advance.
    fn fixed(r: *BinReader, comptime T: type) ValueError!T {
        const n = comptime @divExact(@typeInfo(T).int.bits, 8);
        if (r.pos + n > r.buf.len) return error.CorruptData; // truncated payload
        const v = std.mem.readInt(T, r.buf[r.pos..][0..n], .little);
        r.pos += n;
        return v;
    }

    /// How far `fixed` would advance for `tag`, or null if the tag's payload is
    /// not fixed-width. Keeping the widths in one place is what stops `value`
    /// and `skipValue` from disagreeing about a tag — a disagreement the
    /// compiler cannot see and that surfaces only as CorruptData somewhere far
    /// away, in a struct field read or an UNNEST.
    fn fixedWidth(tag: u8) ?usize {
        return switch (tag) {
            bin_tag_int, bin_tag_float, bin_tag_timestamp => 8,
            bin_tag_date, bin_tag_datetime, bin_tag_time => 8,
            bin_tag_numeric => numeric_bytes,
            bin_tag_bignumeric => bignumeric_bytes,
            else => null,
        };
    }

    /// Reads a varint length then that many bytes; the returned slice
    /// aliases the input buffer.
    fn lenBytes(r: *BinReader) ValueError![]const u8 {
        const n = try r.uvarint();
        if (n > r.buf.len - r.pos) return error.CorruptData; // truncated length-prefixed bytes
        const b = r.buf[r.pos .. r.pos + @as(usize, @intCast(n))];
        r.pos += @intCast(n);
        return b;
    }

    /// Reads a length-prefixed payload, copying it out of the buffer or
    /// aliasing it in place. `borrow` is comptime so only one arm compiles.
    fn payload(
        r: *BinReader,
        alloc: std.mem.Allocator,
        comptime borrow: bool,
    ) ValueError![]const u8 {
        const b = try r.lenBytes();
        return if (borrow) b else alloc.dupe(u8, b);
    }

    fn value(r: *BinReader, alloc: std.mem.Allocator, comptime borrow: bool) ValueError!Value {
        const tag = try r.byte();
        switch (tag) {
            bin_tag_null => return Value.null,
            bin_tag_int => return Value{ .int = try r.fixed(i64) },
            bin_tag_float => return Value{ .float = @bitCast(try r.fixed(u64)) },
            bin_tag_bool => return Value{ .bool = (try r.byte()) == 1 },
            bin_tag_string => return Value{ .string = try r.payload(alloc, borrow) },
            bin_tag_bytes => return Value{ .bytes = try r.payload(alloc, borrow) },
            bin_tag_date => return Value{ .date = try r.fixed(i64) },
            bin_tag_datetime => return Value{ .datetime = try r.fixed(i64) },
            bin_tag_time => return Value{ .time = try r.fixed(i64) },
            bin_tag_timestamp => return Value{ .timestamp = try r.fixed(i64) },
            bin_tag_interval => return Value{
                .interval = try value_mod.parseIntervalValue(try r.lenBytes()),
            },
            bin_tag_range => {
                const kind = std.enums.fromInt(value_mod.Range.ElemKind, try r.byte()) orelse
                    return error.CorruptData;
                const flags = try r.byte();
                // Any bit outside the two defined ones means these bytes were
                // not written by appendBinaryValue.
                if (flags & ~(range_flag_start | range_flag_end) != 0) return error.CorruptData;
                const start: ?i64 = if (flags & range_flag_start != 0)
                    try r.fixed(i64)
                else
                    null;
                const end: ?i64 = if (flags & range_flag_end != 0)
                    try r.fixed(i64)
                else
                    null;
                return value_mod.rangeValue(kind, start, end);
            },
            // Go: JsonValue(string(b)) — the raw JSON string.
            bin_tag_json => return Value{ .json = try r.payload(alloc, borrow) },
            // The unscaled integer written above, read back at the width and
            // scale the tag names.
            bin_tag_numeric, bin_tag_bignumeric => {
                const unscaled: i256 = if (tag == bin_tag_bignumeric)
                    try r.fixed(i256)
                else
                    try r.fixed(i128);
                return value_mod.numericFromUnscaled(
                    alloc,
                    unscaled,
                    tag == bin_tag_bignumeric,
                ) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.CorruptData,
                };
            },
            bin_tag_array => {
                const n = try r.uvarint();
                // Every element occupies at least one byte.
                if (n > r.buf.len - r.pos) return error.CorruptData;
                const values = try alloc.alloc(Value, @intCast(n));
                for (values) |*slot| slot.* = try r.value(alloc, borrow);
                const arr = try alloc.create(value_mod.ArrayValue);
                arr.* = .{ .values = values };
                return Value{ .array = arr };
            },
            bin_tag_struct => {
                const n = try r.uvarint();
                if (n > r.buf.len - r.pos) return error.CorruptData;
                const keys = try alloc.alloc([]const u8, @intCast(n));
                const values = try alloc.alloc(Value, @intCast(n));
                for (keys, values) |*key_slot, *val_slot| {
                    key_slot.* = try r.payload(alloc, borrow);
                    val_slot.* = try r.value(alloc, borrow);
                }
                const st = try alloc.create(value_mod.StructValue);
                st.* = .{ .keys = keys, .values = values };
                return Value{ .struct_ = st };
            },
            else => return error.CorruptData, // unexpected tag
        }
    }
};

/// Decoded strings/bytes/keys and nested values are allocated from `alloc`
/// (use an arena; there is no per-value deinit). The result owns its bytes and
/// does not reference `buf`.
pub fn decodeBinaryValue(alloc: std.mem.Allocator, buf: []const u8) ValueError!Value {
    var r = BinReader{ .buf = buf };
    return r.value(alloc, false);
}

/// As `decodeBinaryValue`, but strings, bytes, JSON payloads and struct keys
/// alias `buf` instead of being copied out of it — so `buf` must outlive the
/// returned Value.
///
/// Every non-scalar argument of every UDF call takes this path, and copying
/// each payload once per row is pure overhead whenever the buffer and the Value
/// already share a lifetime. They do at every production call site: the buffer
/// is itself allocated from `alloc`, which is an arena reset no earlier than
/// the Value dies. This also *lowers* peak memory, since the old path held the
/// buffer and its copies at the same time.
pub fn decodeBinaryValueBorrowing(alloc: std.mem.Allocator, buf: []const u8) ValueError!Value {
    var r = BinReader{ .buf = buf };
    return r.value(alloc, true);
}

/// Advances the cursor past exactly one encoded value without allocating or
/// materializing it. The format is self-delimiting, so skipping is a walk over
/// tags and length prefixes.
fn skipValue(r: *BinReader) ValueError!void {
    const tag = try r.byte();
    // Every fixed-width payload in one line, from the table `value` reads with,
    // so the two cannot drift apart.
    if (BinReader.fixedWidth(tag)) |n| {
        if (r.pos + n > r.buf.len) return error.CorruptData;
        r.pos += n;
        return;
    }
    switch (tag) {
        bin_tag_null => {},
        bin_tag_bool => _ = try r.byte(),
        bin_tag_string,
        bin_tag_bytes,
        bin_tag_json,
        bin_tag_interval,
        => _ = try r.lenBytes(),
        // Element byte, presence flags, then one i64 per bound present.
        // The compiler cannot see this omission — a missing arm here surfaces
        // only as CorruptData out of UNNEST over an ARRAY<RANGE<...>>.
        bin_tag_range => {
            _ = try r.byte(); // element kind
            const flags = try r.byte();
            if (flags & range_flag_start != 0) _ = try r.fixed(i64);
            if (flags & range_flag_end != 0) _ = try r.fixed(i64);
        },
        bin_tag_array => {
            const n = try r.uvarint();
            if (n > r.buf.len - r.pos) return error.CorruptData;
            for (0..@intCast(n)) |_| try skipValue(r);
        },
        bin_tag_struct => {
            const n = try r.uvarint();
            if (n > r.buf.len - r.pos) return error.CorruptData;
            for (0..@intCast(n)) |_| {
                _ = try r.lenBytes(); // key
                try skipValue(r);
            }
        },
        else => return error.CorruptData, // unexpected tag
    }
}

/// Whether a STRUCT member at `path` inside the encoded value `buf` is present.
/// `path` is positional: `.`-separated STRUCT field indices with `[]` for every element of an ARRAY
/// i.e. `1.[].0`.
/// A NULL value on the way passes: a member is required only if its parent exists
/// Walks the entries before the target without decoding any; allocates nothing.
pub fn requiredMemberPresent(buf: []const u8, path: []const u8) ValueError!bool {
    var r = BinReader{ .buf = buf };
    return memberPresent(&r, path);
}

/// One segment of `path` per call, recursing on the rest. The cursor sits on a
/// value's tag byte on entry:
///
/// - `0x00` (NULL) at any depth is a present-enough answer:
///    the member is required if its parent exists, and this one does not.
/// - A `[]` segment expects the ARRAY tag, reads the element count, and applies the remaining path
///   to each element from a copy of the cursor, then skips the original past that element.
///   Every element must pass.
/// - A numeric segment expects the STRUCT tag, reads the field count, steps over `index` entries.
///   An entry is a uvarint key length, the key, and one encoded value, so each step is two length
///   reads and a skip. Past the wanted entry's key, the last segment peeks its tag and answers; an
///   earlier segment recurses into it.
///
/// A segment that does not match the tag it meets, an index past the count, or a buffer that ends
/// early is `CorruptData`: the path was rendered from the column's type at DDL time,
/// so a mismatch is a broken value, never a value of another shape.
fn memberPresent(r: *BinReader, path: []const u8) ValueError!bool {
    const tag = try r.byte();
    if (tag == bin_tag_null) return true;
    if (path.len == 0) return true;

    const dot = std.mem.indexOfScalar(u8, path, '.');
    const segment = if (dot) |d| path[0..d] else path;
    const remaining_segments = if (dot) |d| path[d + 1 ..] else "";

    if (std.mem.eql(u8, segment, "[]")) {
        if (tag != bin_tag_array) return error.CorruptData;
        const n = try r.uvarint();
        if (n > r.buf.len - r.pos) return error.CorruptData;
        for (0..@intCast(n)) |_| {
            var element = r.*;
            if (!try memberPresent(&element, remaining_segments)) return false;
            try skipValue(r);
        }
        return true;
    }

    if (tag != bin_tag_struct) return error.CorruptData;
    const n = try r.uvarint();
    const index = std.fmt.parseInt(u64, segment, 10) catch return error.CorruptData;
    if (index >= n) return error.CorruptData;
    for (0..@intCast(index)) |_| {
        _ = try r.lenBytes();
        try skipValue(r);
    }
    _ = try r.lenBytes();
    if (remaining_segments.len == 0) return (try r.byte()) != bin_tag_null;
    return memberPresent(r, remaining_segments);
}

/// An encoded ARRAY or STRUCT, positioned for reading one entry out of it.
///
/// `ArrayWalker` below streams every element in order, which is what UNNEST
/// wants. This is the other access pattern, and the more common one: `x.field`
/// and `x[OFFSET(n)]` read a *single* entry, the analyzer has already resolved
/// the name to an index, and the generated SQL emits one call per referenced
/// field per row — three on one line of `testdata/sql_snapshot.txt`:
///
///     zigquery_lpad(zigquery_get_struct_field(`$array_4`.`value`, 0),
///                     zigquery_get_struct_field(`$array_4`.`value`, 1),
///                     zigquery_get_struct_field(`$array_4`.`value`, 2))
///
/// Decoding the whole composite for each of those cost fields x references per
/// row. Walking to the entry with `skipValue` and decoding only it costs the
/// walk, which allocates nothing.
pub const CompositeRef = struct {
    kind: Kind,
    /// Entries in the composite, whether or not the index asked for is one of
    /// them — the out-of-range messages quote it.
    count: u64,
    /// Positioned at the first entry.
    r: BinReader,

    pub const Kind = enum { array, struct_ };

    /// Fails with CorruptData if `buf` is not an encoded ARRAY or STRUCT.
    pub fn init(buf: []const u8) ValueError!CompositeRef {
        var r = BinReader{ .buf = buf };
        const kind: Kind = switch (try r.byte()) {
            bin_tag_array => .array,
            bin_tag_struct => .struct_,
            else => return error.CorruptData,
        };
        const n = try r.uvarint();
        // Every entry occupies at least its tag byte.
        if (n > r.buf.len - r.pos) return error.CorruptData;
        return .{ .kind = kind, .count = n, .r = r };
    }

    /// Entry `idx`, decoded on its own, or null when `idx` is past the end —
    /// which callers report differently (OFFSET, ORDINAL and struct fields all
    /// word it their own way) and so is not an error here.
    ///
    /// Strings, bytes, JSON and struct keys inside the result alias `buf`, as
    /// `decodeBinaryValueBorrowing` does and for the same reason: the caller is
    /// a UDF that consumes the value before returning.
    pub fn at(self: CompositeRef, alloc: std.mem.Allocator, idx: u64) ValueError!?Value {
        if (idx >= self.count) return null;
        var r = self.r;
        for (0..@intCast(idx)) |_| {
            if (self.kind == .struct_) _ = try r.lenBytes(); // key
            try skipValue(&r);
        }
        if (self.kind == .struct_) _ = try r.lenBytes(); // the wanted entry's key
        return try r.value(alloc, true);
    }
};

/// Walks an encoded ARRAY element by element, handing back each element's
/// slice of the buffer without decoding it.
///
/// UNNEST needs the element boundaries, not the elements: this lets a scan
/// find them in one pass with no allocation, and decode only the elements a
/// query actually reads.
pub const ArrayWalker = struct {
    r: BinReader,
    remaining: u64,

    /// Fails with CorruptData if `buf` is not an encoded ARRAY.
    pub fn init(buf: []const u8) ValueError!ArrayWalker {
        var r = BinReader{ .buf = buf };
        if ((try r.byte()) != bin_tag_array) return error.CorruptData;
        const n = try r.uvarint();
        // Every element occupies at least its tag byte.
        if (n > r.buf.len - r.pos) return error.CorruptData;
        return .{ .r = r, .remaining = n };
    }

    pub fn count(w: ArrayWalker) u64 {
        return w.remaining;
    }

    /// The next element's encoded bytes, aliasing the buffer, or null at the end.
    pub fn next(w: *ArrayWalker) ValueError!?[]const u8 {
        if (w.remaining == 0) return null;
        const start = w.r.pos;
        try skipValue(&w.r);
        w.remaining -= 1;
        return w.r.buf[start..w.r.pos];
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(alloc: std.mem.Allocator, v: Value) !Value {
    const encoded = try encodeBinaryValue(alloc, v);
    return decodeBinaryValue(alloc, encoded);
}

/// One value of every tag the codec writes. Shared by the tests below that
/// need to cover the whole format rather than one kind of it.
fn oneOfEveryKind(alloc: std.mem.Allocator) ![]const Value {
    const vals = [_]Value{
        Value.null,
        .{ .int = -2 },
        .{ .float = 1.5 },
        .{ .bool = true },
        .{ .string = "hello" },
        .{ .bytes = "\x00\xff" },
        .{ .json = "{\"a\":1}" },
        .{ .date = -719162 },
        .{ .datetime = try value_mod.parseDatetimeMicros("2024-01-15 10:30:15.123456") },
        .{ .time = try value_mod.parseTimeMicros("10:30:15.5") },
        .{ .timestamp = 1136239445_000000 },
        .{ .interval = try value_mod.parseIntervalValue("1-2 3 4:5:6") },
        value_mod.rangeValue(.date, 10, 20),
        value_mod.rangeValue(.timestamp, null, null),
        try value_mod.numericFromString(alloc, "1.5", false),
        try value_mod.numericFromString(alloc, "-1.5", true),
        try value_mod.arrayValue(alloc, &.{ .{ .int = 1 }, .{ .string = "x" } }),
        try value_mod.structValue(alloc, &.{ "k", "" }, &.{ .{ .int = 2 }, .{ .bytes = "b" } }),
    };
    return alloc.dupe(Value, &vals);
}

test "skipValue advances exactly as far as decoding does, for every kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The invariant the whole self-delimiting format rests on, and the one the
    // compiler cannot check: `value` and `skipValue` each decide how wide a
    // payload is, and if they ever disagree the walk desynchronises silently —
    // surfacing as CorruptData somewhere unrelated, in a struct field read or
    // an UNNEST, rather than here. Moving DATE/DATETIME/TIME/NUMERIC to
    // fixed-width payloads changed four of these widths at once.
    for (try oneOfEveryKind(alloc)) |v| {
        const enc = try encodeBinaryValue(alloc, v);

        var decoding = BinReader{ .buf = enc };
        _ = try decoding.value(alloc, true);

        var skipping = BinReader{ .buf = enc };
        try skipValue(&skipping);

        try testing.expectEqual(decoding.pos, skipping.pos);
        // And both consumed the whole value, with nothing left over.
        try testing.expectEqual(enc.len, skipping.pos);
    }
}

test "CompositeRef reads one entry without decoding the others" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const elems = try oneOfEveryKind(alloc);

    // As an ARRAY: every element reachable by index, in any order, and each
    // equal to what a full decode would have produced.
    const arr = try encodeBinaryValue(alloc, try value_mod.arrayValue(alloc, elems));
    const as_array = try CompositeRef.init(arr);
    try testing.expectEqual(elems.len, @as(usize, @intCast(as_array.count)));
    var i: usize = elems.len;
    while (i > 0) {
        i -= 1;
        try value_mod.expectValueEqual(elems[i], (try as_array.at(alloc, i)).?);
    }
    // Past the end is null, not an error — the callers word that differently.
    try testing.expectEqual(@as(?Value, null), try as_array.at(alloc, elems.len));

    // As a STRUCT, where each entry is preceded by its key, so the walk has an
    // extra length prefix to step over per entry.
    const keys = try alloc.alloc([]const u8, elems.len);
    for (keys, 0..) |*k, n| k.* = try std.fmt.allocPrint(alloc, "f{d}", .{n});
    const st = try encodeBinaryValue(alloc, try value_mod.structValue(alloc, keys, elems));
    const as_struct = try CompositeRef.init(st);
    try testing.expectEqual(CompositeRef.Kind.struct_, as_struct.kind);
    for (elems, 0..) |want, n| {
        try value_mod.expectValueEqual(want, (try as_struct.at(alloc, n)).?);
    }

    // Anything that is not a composite is refused rather than misread.
    try testing.expectError(
        error.CorruptData,
        CompositeRef.init(try encodeBinaryValue(alloc, .{ .int = 1 })),
    );
    try testing.expectError(error.CorruptData, CompositeRef.init(""));
    // A truncated element is caught by the walk, not returned as junk.
    var w = try CompositeRef.init(arr[0 .. arr.len - 2]);
    try testing.expectError(error.CorruptData, w.at(alloc, elems.len - 1));
}

test "requiredMemberPresent finds a NULL member by position, through structs and arrays" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const Build = struct {
        fn record(a: std.mem.Allocator, x: Value, inner: Value) ![]u8 {
            const st = try value_mod.structValue(a, &.{ "x", "inner" }, &.{ x, inner });
            return encodeBinaryValue(a, st);
        }
        fn elements(a: std.mem.Allocator, items: []const Value) ![]u8 {
            return encodeBinaryValue(a, try value_mod.arrayValue(a, items));
        }
    };

    // r = STRUCT(x, inner STRUCT(y))
    const inner = try value_mod.structValue(alloc, &.{"y"}, &.{.{ .string = "present" }});
    const inner_null = try value_mod.structValue(alloc, &.{"y"}, &.{Value.null});
    const full = try Build.record(alloc, .{ .int = 1 }, inner);
    try testing.expect(try requiredMemberPresent(full, "0"));
    try testing.expect(try requiredMemberPresent(full, "1.0"));

    const x_null = try Build.record(alloc, Value.null, inner);
    try testing.expect(!try requiredMemberPresent(x_null, "0"));
    try testing.expect(try requiredMemberPresent(x_null, "1.0"));

    const y_null = try Build.record(alloc, .{ .int = 1 }, inner_null);
    try testing.expect(!try requiredMemberPresent(y_null, "1.0"));

    // A NULL parent has no members to require.
    const inner_absent = try Build.record(alloc, .{ .int = 1 }, Value.null);
    try testing.expect(try requiredMemberPresent(inner_absent, "1.0"));
    try testing.expect(try requiredMemberPresent(try encodeBinaryValue(alloc, Value.null), "0"));

    // rs = ARRAY<STRUCT(k)>: every element is checked.
    const ok_elem = try value_mod.structValue(alloc, &.{"k"}, &.{.{ .int = 7 }});
    const bad_elem = try value_mod.structValue(alloc, &.{"k"}, &.{Value.null});
    const all_ok = try Build.elements(alloc, &.{ ok_elem, ok_elem });
    try testing.expect(try requiredMemberPresent(all_ok, "[].0"));
    const one_bad = try Build.elements(alloc, &.{ ok_elem, bad_elem });
    try testing.expect(!try requiredMemberPresent(one_bad, "[].0"));
    try testing.expect(try requiredMemberPresent(try Build.elements(alloc, &.{}), "[].0"));

    // Malformed input is reported, never misread.
    try testing.expectError(error.CorruptData, requiredMemberPresent(full, "5"));
    try testing.expectError(error.CorruptData, requiredMemberPresent(full, "[].0"));
    // Cut off y's value entirely, tag included, so the walk runs out of bytes.
    const truncated = full[0 .. full.len - 9];
    try testing.expectError(error.CorruptData, requiredMemberPresent(truncated, "1.0"));
    try testing.expectError(error.CorruptData, requiredMemberPresent(full, "x"));
}

test "ArrayWalker yields element slices that decode to the originals" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // One of every shape that skipValue has to step over, including a nested
    // array and struct, since those are the cases where a wrong skip silently
    // desynchronises the walk instead of erroring.
    const elems = [_]Value{
        .{ .int = 7 },
        .{ .string = "hello" },
        .{ .null = {} },
        .{ .bool = true },
        .{ .float = 1.5 },
        .{ .timestamp = 123 },
        .{ .date = 100 },
        try value_mod.arrayValue(alloc, &.{ .{ .int = 1 }, .{ .string = "x" } }),
        try value_mod.structValue(alloc, &.{ "k", "" }, &.{ .{ .int = 2 }, .{ .bytes = "b" } }),
        // A range's payload width depends on its presence byte, so all four
        // combinations are here: skipValue reads that byte to know how many
        // bounds follow, and a wrong count desynchronises the whole walk
        // rather than erroring where the mistake is. Nothing about this is
        // visible to the compiler — GENERATE_RANGE_ARRAY feeding UNNEST is
        // what would find it otherwise.
        value_mod.rangeValue(.date, 100, 200),
        value_mod.rangeValue(.date, null, 200),
        value_mod.rangeValue(.timestamp, 100, null),
        value_mod.rangeValue(.datetime, null, null),
    };
    const encoded = try encodeBinaryValue(alloc, try value_mod.arrayValue(alloc, &elems));

    var w = try ArrayWalker.init(encoded);
    try testing.expectEqual(@as(u64, elems.len), w.count());
    var i: usize = 0;
    while (try w.next()) |slice| : (i += 1) {
        try value_mod.expectValueEqual(elems[i], try decodeBinaryValue(alloc, slice));
    }
    try testing.expectEqual(elems.len, i);
    try testing.expectEqual(@as(?[]const u8, null), try w.next());
}

test "ArrayWalker rejects non-arrays and truncated buffers" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const not_array = try encodeBinaryValue(alloc, .{ .int = 1 });
    try testing.expectError(error.CorruptData, ArrayWalker.init(not_array));
    try testing.expectError(error.CorruptData, ArrayWalker.init(""));

    const arr = try encodeBinaryValue(
        alloc,
        try value_mod.arrayValue(alloc, &.{.{ .string = "abc" }}),
    );
    var w = try ArrayWalker.init(arr[0 .. arr.len - 2]); // element payload cut short
    try testing.expectError(error.CorruptData, w.next());
}

test "binary codec scalar round trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]Value{
        Value.null,
        Value{ .int = 0 },
        Value{ .int = 42 },
        Value{ .int = -42 },
        Value{ .int = std.math.minInt(i64) },
        Value{ .int = std.math.maxInt(i64) },
        Value{ .float = 1.5 },
        Value{ .float = -0.0 },
        Value{ .float = std.math.nan(f64) },
        Value{ .float = std.math.inf(f64) },
        Value{ .float = -std.math.inf(f64) },
        Value{ .bool = true },
        Value{ .bool = false },
        Value{ .string = "" },
        Value{ .string = "hello" },
        Value{ .string = "héllo wörld \u{1F600}" }, // non-ASCII
        Value{ .bytes = "" },
        Value{ .bytes = "\x00\x01\xfe\xff" },
        Value{ .date = 0 },
        Value{ .date = try value_mod.parseDateDays("2024-02-29") },
        Value{ .date = try value_mod.parseDateDays("1969-12-31") },
        Value{ .timestamp = 1136239445_000000 },
        Value{ .timestamp = 1705314615_500000 },
        Value{ .timestamp = -62135596800_000000 }, // pre-epoch
        Value{ .datetime = try value_mod.parseDatetimeMicros("2024-01-15 10:30:15.123456") },
        Value{ .datetime = try value_mod.parseDatetimeMicros("2024-01-15 10:30:00") },
        Value{ .time = try value_mod.parseTimeMicros("10:30:15.5") },
        Value{ .time = try value_mod.parseTimeMicros("00:00:00") },
        Value{ .interval = try value_mod.parseIntervalValue("1-2 3 4:5:6") },
        Value{ .interval = try value_mod.parseIntervalValue("0-0 0 1:2:3.123456") },
    };
    for (cases) |v| {
        try value_mod.expectValueEqual(v, try roundTrip(alloc, v));
    }
}

test "binary codec time-kind byte layout is tag + fixed64" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // All four time kinds are the tag and the i64 the Value holds, so each
    // encodes to exactly nine bytes whatever the value is. Go rendered the
    // first three as text (a DATETIME ran 21 bytes, and a variable 21) and
    // parsed them back on the way in.
    const cases = [_]struct { v: Value, tag: u8, n: i64 }{
        .{
            .v = Value{ .timestamp = 1136239445_000000 },
            .tag = bin_tag_timestamp,
            .n = 1136239445_000000,
        },
        .{
            .v = Value{ .datetime = try value_mod.parseDatetimeMicros("2024-01-15 10:30:00") },
            .tag = bin_tag_datetime,
            .n = try value_mod.parseDatetimeMicros("2024-01-15 10:30:00"),
        },
        .{
            .v = Value{ .time = try value_mod.parseTimeMicros("10:30:15") },
            .tag = bin_tag_time,
            .n = try value_mod.parseTimeMicros("10:30:15"),
        },
        // Pre-epoch, i.e. the case a sign-blind encoding would get wrong.
        .{ .v = Value{ .date = -719162 }, .tag = bin_tag_date, .n = -719162 },
    };
    for (cases) |tc| {
        var want: [9]u8 = undefined;
        want[0] = tc.tag;
        std.mem.writeInt(i64, want[1..9], tc.n, .little);
        try testing.expectEqualSlices(u8, &want, try encodeBinaryValue(alloc, tc.v));
    }

    // INTERVAL is still its canonical string: tag 0x0d + uvarint length + text.
    // Seven components rather than one integer, so it is a format of its own
    // rather than the same one-line change, and it was left alone.
    const iv = try encodeBinaryValue(
        alloc,
        Value{ .interval = try value_mod.parseIntervalValue("1-2 3 4:5:6") },
    );
    try testing.expectEqualSlices(u8, "\x0d\x0b1-2 3 4:5:6", iv);
}

test "binary codec tag bytes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(bin_tag_null, (try encodeBinaryValue(alloc, Value.null))[0]);
    try testing.expectEqual(bin_tag_int, (try encodeBinaryValue(alloc, Value{ .int = 7 }))[0]);
    try testing.expectEqual(bin_tag_float, (try encodeBinaryValue(alloc, Value{ .float = 7 }))[0]);
    try testing.expectEqual(bin_tag_bool, (try encodeBinaryValue(alloc, Value{ .bool = true }))[0]);
    try testing.expectEqual(
        bin_tag_string,
        (try encodeBinaryValue(alloc, Value{ .string = "s" }))[0],
    );
    try testing.expectEqual(bin_tag_bytes, (try encodeBinaryValue(alloc, Value{ .bytes = "b" }))[0]);
    try testing.expectEqual(bin_tag_date, (try encodeBinaryValue(alloc, Value{ .date = 0 }))[0]);

    // Int payload is fixed64 little-endian two's complement.
    const enc = try encodeBinaryValue(alloc, Value{ .int = -2 });
    try testing.expectEqualSlices(
        u8,
        &.{ 0x01, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff },
        enc,
    );

    // Date payload is the civil day count, same fixed64 shape. It was the
    // uvarint-length-prefixed "1970-01-01" through storage format 3.
    const denc = try encodeBinaryValue(alloc, Value{ .date = 0 });
    try testing.expectEqualSlices(u8, &.{ 0x09, 0, 0, 0, 0, 0, 0, 0, 0 }, denc);
}

test "binary codec array and struct round trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Empty array.
    const empty = try value_mod.arrayValue(alloc, &.{});
    try value_mod.expectValueEqual(empty, try roundTrip(alloc, empty));

    // Array with null elements and mixed scalars.
    const mixed = try value_mod.arrayValue(alloc, &.{
        Value{ .int = 1 },
        Value.null,
        Value{ .string = "x" },
        Value{ .float = std.math.nan(f64) },
    });
    try value_mod.expectValueEqual(mixed, try roundTrip(alloc, mixed));

    // Nested array-of-struct (with a nested array and null field inside).
    const inner_arr = try value_mod.arrayValue(alloc, &.{ Value{ .int = -1 }, Value{ .int = 2 } });
    const st1 = try value_mod.structValue(
        alloc,
        &.{ "id", "name", "tags", "missing" },
        &.{ Value{ .int = 1 }, Value{ .string = "héllo" }, inner_arr, Value.null },
    );
    const st2 = try value_mod.structValue(
        alloc,
        &.{ "id", "d" },
        &.{ Value{ .int = 2 }, Value{ .date = try value_mod.parseDateDays("2020-02-29") } },
    );
    const arr_of_struct = try value_mod.arrayValue(alloc, &.{ st1, st2 });
    try value_mod.expectValueEqual(arr_of_struct, try roundTrip(alloc, arr_of_struct));
}

test "binary codec safe values encode as their inner value" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const safe = try value_mod.safeValue(alloc, Value{ .int = 99 });
    const enc_safe = try encodeBinaryValue(alloc, safe);
    const enc_plain = try encodeBinaryValue(alloc, Value{ .int = 99 });
    try testing.expectEqualSlices(u8, enc_plain, enc_safe);
    try value_mod.expectValueEqual(Value{ .int = 99 }, try roundTrip(alloc, safe));
}

test "binary codec rejects truncated and corrupt input" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectError(error.CorruptData, decodeBinaryValue(alloc, &.{}));
    // truncated fixed64
    try testing.expectError(error.CorruptData, decodeBinaryValue(alloc, &.{ bin_tag_int, 0x01 }));
    // truncated bytes
    try testing.expectError(
        error.CorruptData,
        decodeBinaryValue(alloc, &.{ bin_tag_string, 0x05, 'a' }),
    );
    try testing.expectError(error.CorruptData, decodeBinaryValue(alloc, &.{0x7f})); // unknown tag
    // Invalid numeric payload text is corruption, not a parse fallback.
    try testing.expectError(
        error.CorruptData,
        decodeBinaryValue(alloc, &.{ bin_tag_numeric, 0x01, 'x' }),
    );
}

test "binary codec numeric round trips and byte layout" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Round trips: integer form ("n"), reduced fraction form ("n/d" — 1.5 is
    // stored as 3/2), negatives, both kinds, extremes.
    //
    // This list used to include "3/7" and "-999999999/7" to prove that the
    // fraction grammar round-tripped an arbitrary rational. It no longer can:
    // numericValue rounds to the kind's scale, so those inputs are on-grid
    // before they are ever encoded. Worse, the assertion still *passed* — both
    // sides of the comparison were rounded identically — so the test kept
    // claiming a property the engine had stopped having. The off-grid case is
    // now asserted for what actually happens, below.
    const literals = [_][]const u8{
        "1.5",   "-1.5",     "0",
        "42",    "-42",      "123.45",
        "1e-38", "12.34e27", "-0.000000001",
    };
    for (literals) |lit| {
        inline for ([_]bool{ false, true }) |is_big| {
            const v = try value_mod.numericFromString(alloc, lit, is_big);
            try value_mod.expectValueEqual(v, try roundTrip(alloc, v));
        }
    }

    // An off-grid input is rounded on the way in, so it round-trips as the
    // rounded value rather than as itself.
    {
        const third = try value_mod.numericFromString(alloc, "1/3", false);
        try value_mod.expectValueEqual(
            try value_mod.numericFromString(alloc, "0.333333333", false),
            try roundTrip(alloc, third),
        );
    }

    // Byte layout: tag + the scaled integer, two's complement little-endian, at
    // the width the tag names. The tag carries the scale too, so 1.5 is
    // 1500000000 as a NUMERIC and 1.5e38 as a BIGNUMERIC. Storage format 3
    // wrote the same integer in decimal text ("\x06\x0a1500000000"), and goccy
    // wrote Rat.MarshalText ("3/2") before that.
    const layout = [_]struct { lit: []const u8, big: bool, want: []const u8 }{
        .{
            .lit = "1.5",
            .big = false,
            .want = &(.{bin_tag_numeric} ++ leBytes(i128, 1_500_000_000)),
        },
        .{
            .lit = "42",
            .big = false,
            .want = &(.{bin_tag_numeric} ++ leBytes(i128, 42_000_000_000)),
        },
        // Negative: sign-extended, so every high byte is 0xff.
        .{
            .lit = "-42",
            .big = false,
            .want = &(.{bin_tag_numeric} ++ leBytes(i128, -42_000_000_000)),
        },
        .{
            .lit = "1.5",
            .big = true,
            .want = &(.{bin_tag_bignumeric} ++
                leBytes(i256, 150000000000000000000000000000000000000)),
        },
    };
    for (layout) |tc| {
        const v = try value_mod.numericFromString(alloc, tc.lit, tc.big);
        const enc = try encodeBinaryValue(alloc, v);
        try testing.expectEqualSlices(u8, tc.want, enc);
        // Width comes from the tag alone, which is what lets skipValue step
        // over one of these without reading a length.
        try testing.expectEqual(
            1 + if (tc.big) bignumeric_bytes else numeric_bytes,
            enc.len,
        );
    }
}

/// `v` as comptime little-endian bytes, for spelling an expected payload
/// without restating the encoder's own logic.
fn leBytes(comptime T: type, comptime v: T) [@divExact(@typeInfo(T).int.bits, 8)]u8 {
    var out: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
    std.mem.writeInt(T, &out, v, .little);
    return out;
}

test "binary codec json round trip" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();
    const cases = [_][]const u8{ "null", "\"purple\"", "{\"a\":1,\"b\":[2,3]}", "9.8" };
    for (cases) |raw| {
        const rt = try roundTrip(alloc, Value{ .json = raw });
        try testing.expectEqualStrings(raw, rt.json);
    }
}
