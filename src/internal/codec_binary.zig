//! Faithful port of go-zetasqlite internal/codec_binary.go.
//!
//! Binary value codec: each value is [tag byte][payload]; variable-length
//! payloads are uvarint-length-prefixed so every value is self-delimiting,
//! which is what lets it nest.
//!
//! JSON, INTERVAL, ARRAY and STRUCT — plus every value nested inside a
//! composite, including numerics. Carried as a raw BLOB; the tag range (0x00-
//! 0x0f here, 0x40+ in codec_sortable.zig) says which shape a payload is.

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

fn appendBinaryString(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, tag: u8, s: []const u8) ValueError!void {
    try buf.append(alloc, tag);
    try appendUvarint(buf, alloc, s.len);
    try buf.appendSlice(alloc, s);
}

fn appendBinaryValue(buf: *std.ArrayList(u8), alloc: std.mem.Allocator, v: Value) ValueError!void {
    switch (v) {
        .@"null" => try buf.append(alloc, bin_tag_null),
        .safe => |p| try appendBinaryValue(buf, alloc, p.*),
        .int => |i| {
            try buf.append(alloc, bin_tag_int);
            var le: [8]u8 = undefined;
            std.mem.writeInt(u64, &le, @bitCast(i), .little);
            try buf.appendSlice(alloc, &le);
        },
        .float => |f| {
            try buf.append(alloc, bin_tag_float);
            var le: [8]u8 = undefined;
            std.mem.writeInt(u64, &le, @bitCast(f), .little);
            try buf.appendSlice(alloc, &le);
        },
        .bool => |b| {
            try buf.append(alloc, bin_tag_bool);
            try buf.append(alloc, @intFromBool(b));
        },
        .string => |s| try appendBinaryString(buf, alloc, bin_tag_string, s),
        .bytes => |b| try appendBinaryString(buf, alloc, bin_tag_bytes, b),
        // Go stores JsonValue as a length-prefixed raw JSON string (tag 0x08).
        .json => |s| try appendBinaryString(buf, alloc, bin_tag_json, s),
        .date => |days| {
            // Go stores the DateValue.ToString() form ("YYYY-MM-DD").
            var tmp: [32]u8 = undefined;
            try appendBinaryString(buf, alloc, bin_tag_date, value_mod.formatDateDays(&tmp, days));
        },
        // Go stores DatetimeValue/TimeValue as their ToString strings.
        .datetime => |m| {
            var tmp: [40]u8 = undefined;
            try appendBinaryString(buf, alloc, bin_tag_datetime, value_mod.formatDatetimeString(&tmp, m));
        },
        .time => |m| {
            var tmp: [24]u8 = undefined;
            try appendBinaryString(buf, alloc, bin_tag_time, value_mod.formatTimeString(&tmp, m));
        },
        // Go stores TimestampValue as fixed64 little-endian UnixMicro.
        .timestamp => |m| {
            try buf.append(alloc, bin_tag_timestamp);
            var le: [8]u8 = undefined;
            std.mem.writeInt(u64, &le, @bitCast(m), .little);
            try buf.appendSlice(alloc, &le);
        },
        // Go stores *IntervalValue as its ToString string.
        .interval => |iv| {
            var tmp: [96]u8 = undefined;
            try appendBinaryString(buf, alloc, bin_tag_interval, value_mod.formatInterval(&tmp, iv));
        },
        // The scaled integer googlesql stores, in decimal, tagged by kind —
        // the tag supplies the scale on the way back in. goccy wrote
        // Rat.MarshalText here ("3/2" for 1.5), which only had a numerator and
        // denominator to write because the value was held as a fraction.
        .numeric => |n| {
            const tag: u8 = if (n.is_bignumeric) bin_tag_bignumeric else bin_tag_numeric;
            var tmp: [96]u8 = undefined;
            const s = std.fmt.bufPrint(&tmp, "{d}", .{n.unscaled}) catch
                return error.OutOfMemory;
            try appendBinaryString(buf, alloc, tag, s);
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

    fn fixed64(r: *BinReader) ValueError!u64 {
        if (r.pos + 8 > r.buf.len) return error.CorruptData; // truncated fixed64
        const u = std.mem.readInt(u64, r.buf[r.pos..][0..8], .little);
        r.pos += 8;
        return u;
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
    fn payload(r: *BinReader, alloc: std.mem.Allocator, comptime borrow: bool) ValueError![]const u8 {
        const b = try r.lenBytes();
        return if (borrow) b else alloc.dupe(u8, b);
    }

    fn value(r: *BinReader, alloc: std.mem.Allocator, comptime borrow: bool) ValueError!Value {
        const tag = try r.byte();
        switch (tag) {
            bin_tag_null => return Value.@"null",
            bin_tag_int => return Value{ .int = @bitCast(try r.fixed64()) },
            bin_tag_float => return Value{ .float = @bitCast(try r.fixed64()) },
            bin_tag_bool => return Value{ .bool = (try r.byte()) == 1 },
            bin_tag_string => return Value{ .string = try r.payload(alloc, borrow) },
            bin_tag_bytes => return Value{ .bytes = try r.payload(alloc, borrow) },
            bin_tag_date => return Value{ .date = try value_mod.parseDateDays(try r.lenBytes()) },
            // Go parses the stored ToString back into the civil value.
            bin_tag_datetime => return Value{ .datetime = try value_mod.parseDatetimeMicros(try r.lenBytes()) },
            bin_tag_time => return Value{ .time = try value_mod.parseTimeMicros(try r.lenBytes()) },
            bin_tag_timestamp => return Value{ .timestamp = @bitCast(try r.fixed64()) },
            bin_tag_interval => return Value{ .interval = try value_mod.parseIntervalValue(try r.lenBytes()) },
            // Go: JsonValue(string(b)) — the raw JSON string.
            bin_tag_json => return Value{ .json = try r.payload(alloc, borrow) },
            // The unscaled integer written above, read back at the scale the
            // tag names.
            bin_tag_numeric, bin_tag_bignumeric => {
                const b = try r.lenBytes();
                const unscaled = std.fmt.parseInt(i256, b, 10) catch
                    return error.CorruptData; // invalid numeric payload
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
    switch (tag) {
        bin_tag_null => {},
        bin_tag_bool => _ = try r.byte(),
        bin_tag_int, bin_tag_float, bin_tag_timestamp => _ = try r.fixed64(),
        bin_tag_string,
        bin_tag_bytes,
        bin_tag_json,
        bin_tag_date,
        bin_tag_datetime,
        bin_tag_time,
        bin_tag_interval,
        bin_tag_numeric,
        bin_tag_bignumeric,
        => _ = try r.lenBytes(),
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
        .{ .@"null" = {} },
        .{ .bool = true },
        .{ .float = 1.5 },
        .{ .timestamp = 123 },
        .{ .date = 100 },
        try value_mod.arrayValue(alloc, &.{ .{ .int = 1 }, .{ .string = "x" } }),
        try value_mod.structValue(alloc, &.{ "k", "" }, &.{ .{ .int = 2 }, .{ .bytes = "b" } }),
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

    const arr = try encodeBinaryValue(alloc, try value_mod.arrayValue(alloc, &.{.{ .string = "abc" }}));
    var w = try ArrayWalker.init(arr[0 .. arr.len - 2]); // element payload cut short
    try testing.expectError(error.CorruptData, w.next());
}

test "binary codec scalar round trips" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const cases = [_]Value{
        Value.@"null",
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

test "binary codec time-kind byte layout matches Go" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Timestamp: tag 0x0c + fixed64 LE UnixMicro.
    const ts = try encodeBinaryValue(alloc, Value{ .timestamp = 1136239445_000000 });
    var expected_ts: [9]u8 = undefined;
    expected_ts[0] = bin_tag_timestamp;
    std.mem.writeInt(u64, expected_ts[1..9], @as(u64, 1136239445_000000), .little);
    try testing.expectEqualSlices(u8, &expected_ts, ts);

    // Datetime: tag 0x0a + uvarint length + ToString ("space" form).
    const dt = try encodeBinaryValue(alloc, Value{
        .datetime = try value_mod.parseDatetimeMicros("2024-01-15 10:30:00"),
    });
    try testing.expectEqualSlices(u8, "\x0a\x132024-01-15 10:30:00", dt);

    // Time: tag 0x0b + uvarint length + ToString.
    const tv = try encodeBinaryValue(alloc, Value{ .time = try value_mod.parseTimeMicros("10:30:15") });
    try testing.expectEqualSlices(u8, "\x0b\x0810:30:15", tv);

    // Interval: tag 0x0d + uvarint length + canonical ToString.
    const iv = try encodeBinaryValue(alloc, Value{ .interval = try value_mod.parseIntervalValue("1-2 3 4:5:6") });
    try testing.expectEqualSlices(u8, "\x0d\x0b1-2 3 4:5:6", iv);
}

test "binary codec tag bytes match the Go format" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    try testing.expectEqual(bin_tag_null, (try encodeBinaryValue(alloc, Value.@"null"))[0]);
    try testing.expectEqual(bin_tag_int, (try encodeBinaryValue(alloc, Value{ .int = 7 }))[0]);
    try testing.expectEqual(bin_tag_float, (try encodeBinaryValue(alloc, Value{ .float = 7 }))[0]);
    try testing.expectEqual(bin_tag_bool, (try encodeBinaryValue(alloc, Value{ .bool = true }))[0]);
    try testing.expectEqual(bin_tag_string, (try encodeBinaryValue(alloc, Value{ .string = "s" }))[0]);
    try testing.expectEqual(bin_tag_bytes, (try encodeBinaryValue(alloc, Value{ .bytes = "b" }))[0]);
    try testing.expectEqual(bin_tag_date, (try encodeBinaryValue(alloc, Value{ .date = 0 }))[0]);

    // Int payload is fixed64 little-endian two's complement.
    const enc = try encodeBinaryValue(alloc, Value{ .int = -2 });
    try testing.expectEqualSlices(u8, &.{ 0x01, 0xfe, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff }, enc);

    // Date payload is the uvarint-length-prefixed "YYYY-MM-DD" string.
    const denc = try encodeBinaryValue(alloc, Value{ .date = 0 });
    try testing.expectEqualSlices(u8, "\x09\x0a1970-01-01", denc);
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
        Value.@"null",
        Value{ .string = "x" },
        Value{ .float = std.math.nan(f64) },
    });
    try value_mod.expectValueEqual(mixed, try roundTrip(alloc, mixed));

    // Nested array-of-struct (with a nested array and null field inside).
    const inner_arr = try value_mod.arrayValue(alloc, &.{ Value{ .int = -1 }, Value{ .int = 2 } });
    const st1 = try value_mod.structValue(
        alloc,
        &.{ "id", "name", "tags", "missing" },
        &.{ Value{ .int = 1 }, Value{ .string = "héllo" }, inner_arr, Value.@"null" },
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
    try testing.expectError(error.CorruptData, decodeBinaryValue(alloc, &.{ bin_tag_int, 0x01 })); // truncated fixed64
    try testing.expectError(error.CorruptData, decodeBinaryValue(alloc, &.{ bin_tag_string, 0x05, 'a' })); // truncated bytes
    try testing.expectError(error.CorruptData, decodeBinaryValue(alloc, &.{0x7f})); // unknown tag
    // Invalid numeric payload text is corruption, not a parse fallback.
    try testing.expectError(error.CorruptData, decodeBinaryValue(alloc, &.{ bin_tag_numeric, 0x01, 'x' }));
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

    // Byte layout: tag + uvarint length + the scaled integer in decimal. The
    // tag carries the scale, so 1.5 is 1500000000 as a NUMERIC and 38 digits
    // as a BIGNUMERIC. goccy wrote Rat.MarshalText ("3/2") here.
    const n15 = try value_mod.numericFromString(alloc, "1.5", false);
    try testing.expectEqualSlices(u8, "\x06\x0a1500000000", try encodeBinaryValue(alloc, n15));
    const b15 = try value_mod.numericFromString(alloc, "1.5", true);
    try testing.expectEqualSlices(
        u8,
        "\x07\x27150000000000000000000000000000000000000",
        try encodeBinaryValue(alloc, b15),
    );
    const n42 = try value_mod.numericFromString(alloc, "42", false);
    try testing.expectEqualSlices(u8, "\x06\x0b42000000000", try encodeBinaryValue(alloc, n42));
    const neg = try value_mod.numericFromString(alloc, "-42", false);
    try testing.expectEqualSlices(u8, "\x06\x0c-42000000000", try encodeBinaryValue(alloc, neg));
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
