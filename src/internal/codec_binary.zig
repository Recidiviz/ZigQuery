//! Faithful port of go-zetasqlite internal/codec_binary.go.
//!
//! Binary value codec (format v1): each value is [tag byte][payload];
//! variable-length payloads are uvarint-length-prefixed so every value is
//! self-delimiting. Storage stays TEXT (the binary is base64-wrapped by
//! EncodeValue/LiteralFromValue in encoder.zig). A legacy payload is JSON and
//! begins with '{' (0x7B) after base64-decoding, whereas a binary payload
//! begins with a tag byte < 0x10; DecodeValue disambiguates on that byte.

const std = @import("std");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const ValueError = value_mod.ValueError;

// Tag bytes (complete set; Numeric/BigNumeric/JSON/Datetime/Time/Timestamp/
// Interval decode paths are deferred with error.Unimplemented).
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
        .date => |days| {
            // Go stores the DateValue.ToString() form ("YYYY-MM-DD").
            var tmp: [32]u8 = undefined;
            try appendBinaryString(buf, alloc, bin_tag_date, value_mod.formatDateDays(&tmp, days));
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

    fn value(r: *BinReader, alloc: std.mem.Allocator) ValueError!Value {
        const tag = try r.byte();
        switch (tag) {
            bin_tag_null => return Value.@"null",
            bin_tag_int => return Value{ .int = @bitCast(try r.fixed64()) },
            bin_tag_float => return Value{ .float = @bitCast(try r.fixed64()) },
            bin_tag_bool => return Value{ .bool = (try r.byte()) == 1 },
            bin_tag_string => return Value{ .string = try alloc.dupe(u8, try r.lenBytes()) },
            bin_tag_bytes => return Value{ .bytes = try alloc.dupe(u8, try r.lenBytes()) },
            bin_tag_date => return Value{ .date = try value_mod.parseDateDays(try r.lenBytes()) },
            // Deferred kinds: consume nothing further, surface Unimplemented.
            bin_tag_numeric,
            bin_tag_bignumeric,
            bin_tag_json,
            bin_tag_datetime,
            bin_tag_time,
            bin_tag_timestamp,
            bin_tag_interval,
            => return error.Unimplemented,
            bin_tag_array => {
                const n = try r.uvarint();
                // Every element occupies at least one byte.
                if (n > r.buf.len - r.pos) return error.CorruptData;
                const values = try alloc.alloc(Value, @intCast(n));
                for (values) |*slot| slot.* = try r.value(alloc);
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
                    key_slot.* = try alloc.dupe(u8, try r.lenBytes());
                    val_slot.* = try r.value(alloc);
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
/// (use an arena; there is no per-value deinit).
pub fn decodeBinaryValue(alloc: std.mem.Allocator, buf: []const u8) ValueError!Value {
    var r = BinReader{ .buf = buf };
    return r.value(alloc);
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

fn roundTrip(alloc: std.mem.Allocator, v: Value) !Value {
    const encoded = try encodeBinaryValue(alloc, v);
    return decodeBinaryValue(alloc, encoded);
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
    };
    for (cases) |v| {
        try value_mod.expectValueEqual(v, try roundTrip(alloc, v));
    }
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
    // Deferred kinds decode to Unimplemented, not corruption.
    try testing.expectError(error.Unimplemented, decodeBinaryValue(alloc, &.{ bin_tag_json, 0x02, '{', '}' }));
}
