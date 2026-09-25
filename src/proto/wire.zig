//! Protobuf wire format: a reader used by the generated decoders in
//! resolved_ast.zig, and a writer used by the generated encoders in
//! src/server/proto/storage.zig.
//!
//! Strings/bytes are returned as slices borrowing from the input buffer;
//! callers keep the buffer alive (arena-owned in practice).
//!
//! The reader came first and stood alone for as long as the only protobuf in
//! this repo was the analyzer's output, which is read and never produced.
//! Serving the Storage Read API needs the other direction.
// ephor:ignore-file ZT105

const std = @import("std");

pub const DecodeError = error{
    Truncated,
    Malformed,
    OutOfMemory,
};

pub const EncodeError = error{OutOfMemory};

pub const WireType = enum(u3) {
    varint = 0,
    fixed64 = 1,
    len = 2,
    start_group = 3,
    end_group = 4,
    fixed32 = 5,
};

pub const Tag = struct {
    field: u32,
    wire: WireType,
};

pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn atEnd(r: *const Reader) bool {
        return r.pos >= r.buf.len;
    }

    /// Reads the next field tag, or null at end of input.
    pub fn next(r: *Reader) DecodeError!?Tag {
        if (r.atEnd()) return null;
        const key = try r.readVarint();
        const wire: WireType = switch (@as(u3, @truncate(key))) {
            0 => .varint,
            1 => .fixed64,
            2 => .len,
            3 => .start_group,
            4 => .end_group,
            5 => .fixed32,
            else => return error.Malformed,
        };
        const field: u32 = @intCast(key >> 3);
        if (field == 0) return error.Malformed;
        return .{ .field = field, .wire = wire };
    }

    pub fn readVarint(r: *Reader) DecodeError!u64 {
        var result: u64 = 0;
        var shift: u6 = 0;
        while (true) {
            if (r.atEnd()) return error.Truncated;
            const b = r.buf[r.pos];
            r.pos += 1;
            result |= @as(u64, b & 0x7f) << shift;
            if (b & 0x80 == 0) return result;
            if (shift >= 63) return error.Malformed;
            shift += 7;
        }
    }

    pub fn readInt32(r: *Reader) DecodeError!i32 {
        const v: i64 = @bitCast(try r.readVarint());
        return @truncate(v);
    }

    pub fn readInt64(r: *Reader) DecodeError!i64 {
        return @bitCast(try r.readVarint());
    }

    pub fn readSint32(r: *Reader) DecodeError!i32 {
        const v: u32 = @truncate(try r.readVarint());
        return @bitCast((v >> 1) ^ (0 -% (v & 1)));
    }

    pub fn readSint64(r: *Reader) DecodeError!i64 {
        const v = try r.readVarint();
        return @bitCast((v >> 1) ^ (0 -% (v & 1)));
    }

    pub fn readFixed32(r: *Reader) DecodeError!u32 {
        if (r.pos + 4 > r.buf.len) return error.Truncated;
        const v = std.mem.readInt(u32, r.buf[r.pos..][0..4], .little);
        r.pos += 4;
        return v;
    }

    pub fn readFixed64(r: *Reader) DecodeError!u64 {
        if (r.pos + 8 > r.buf.len) return error.Truncated;
        const v = std.mem.readInt(u64, r.buf[r.pos..][0..8], .little);
        r.pos += 8;
        return v;
    }

    pub fn readFloat(r: *Reader) DecodeError!f32 {
        return @bitCast(try r.readFixed32());
    }

    pub fn readDouble(r: *Reader) DecodeError!f64 {
        return @bitCast(try r.readFixed64());
    }

    /// Length-delimited payload as a borrowed slice.
    pub fn readBytes(r: *Reader) DecodeError![]const u8 {
        const len = try r.readVarint();
        if (len > r.buf.len - r.pos) return error.Truncated;
        const out = r.buf[r.pos .. r.pos + @as(usize, @intCast(len))];
        r.pos += @intCast(len);
        return out;
    }

    /// Reader over a length-delimited payload (nested message / packed field).
    pub fn subReader(r: *Reader) DecodeError!Reader {
        return init(try r.readBytes());
    }

    pub fn skip(r: *Reader, wire: WireType) DecodeError!void {
        switch (wire) {
            .varint => _ = try r.readVarint(),
            .fixed64 => _ = try r.readFixed64(),
            .len => _ = try r.readBytes(),
            .fixed32 => _ = try r.readFixed32(),
            // proto2 groups: skip nested fields until the matching end tag.
            .start_group => {
                while (try r.next()) |tag| {
                    if (tag.wire == .end_group) return;
                    try r.skip(tag.wire);
                }
                return error.Truncated;
            },
            .end_group => {},
        }
    }
};

/// Appends protobuf to a caller-owned byte list.
///
/// Length-delimited payloads are written by encoding the body first and then
/// inserting the length varint in front of it (`beginLen`/`endLen`), rather
/// than by pre-computing sizes in a separate pass or reserving a fixed-width
/// varint. Pre-computing means every message needs a second generated function
/// that has to agree with the writer exactly; a fixed-width length is legal but
/// non-canonical, so the bytes would not match what protoc produces. The cost is
/// a memmove of the payload per nesting level, which is nothing at the message
/// sizes this serves.
pub const Writer = struct {
    a: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,

    pub fn init(a: std.mem.Allocator) Writer {
        return .{ .a = a };
    }

    pub fn deinit(w: *Writer) void {
        w.buf.deinit(w.a);
    }

    pub fn toOwnedSlice(w: *Writer) EncodeError![]u8 {
        return w.buf.toOwnedSlice(w.a);
    }

    pub fn bytes(w: *const Writer) []const u8 {
        return w.buf.items;
    }

    pub fn writeTag(w: *Writer, field: u32, wire: WireType) EncodeError!void {
        try w.writeVarint((@as(u64, field) << 3) | @backingInt(wire));
    }

    pub fn writeVarint(w: *Writer, v: u64) EncodeError!void {
        var rest = v;
        while (true) {
            const b: u8 = @truncate(rest & 0x7f);
            rest >>= 7;
            if (rest == 0) return w.buf.append(w.a, b);
            try w.buf.append(w.a, b | 0x80);
        }
    }

    /// Writes the tag for a length-delimited field and returns a mark to pass to
    /// `endLen` once the payload has been appended.
    pub fn beginLen(w: *Writer, field: u32) EncodeError!usize {
        try w.writeTag(field, .len);
        return w.buf.items.len;
    }

    pub fn endLen(w: *Writer, mark: usize) EncodeError!void {
        var tmp: [10]u8 = undefined;
        var n: usize = 0;
        var rest: u64 = w.buf.items.len - mark;
        while (true) {
            tmp[n] = @truncate(rest & 0x7f);
            rest >>= 7;
            if (rest == 0) break;
            tmp[n] |= 0x80;
            n += 1;
        }
        try w.buf.insertSlice(w.a, mark, tmp[0 .. n + 1]);
    }

    // Scalars come in pairs: a tagged form for a singular field, and a `Raw`
    // form for the inside of a packed run, where the tag is written once for the
    // whole run. The generated encoders pick one by field label, so both forms
    // exist for every packable type even where only one has a caller today.

    pub fn writeInt32Raw(w: *Writer, v: i32) EncodeError!void {
        // Negative int32 is sign-extended to 64 bits on the wire — 10 bytes, not
        // 5. protoc does the same; a truncated 5-byte form reads back positive.
        try w.writeVarint(@bitCast(@as(i64, v)));
    }

    pub fn writeInt64Raw(w: *Writer, v: i64) EncodeError!void {
        try w.writeVarint(@bitCast(v));
    }

    pub fn writeBoolRaw(w: *Writer, v: bool) EncodeError!void {
        try w.writeVarint(@intFromBool(v));
    }

    pub fn writeSint32Raw(w: *Writer, v: i32) EncodeError!void {
        const u: u32 = @bitCast(v);
        try w.writeVarint((u << 1) ^ @as(u32, @bitCast(v >> 31)));
    }

    pub fn writeSint64Raw(w: *Writer, v: i64) EncodeError!void {
        const u: u64 = @bitCast(v);
        try w.writeVarint((u << 1) ^ @as(u64, @bitCast(v >> 63)));
    }

    pub fn writeFixed32Raw(w: *Writer, v: u32) EncodeError!void {
        var tmp: [4]u8 = undefined;
        std.mem.writeInt(u32, &tmp, v, .little);
        try w.buf.appendSlice(w.a, &tmp);
    }

    pub fn writeFixed64Raw(w: *Writer, v: u64) EncodeError!void {
        var tmp: [8]u8 = undefined;
        std.mem.writeInt(u64, &tmp, v, .little);
        try w.buf.appendSlice(w.a, &tmp);
    }

    pub fn writeFloatRaw(w: *Writer, v: f32) EncodeError!void {
        try w.writeFixed32Raw(@bitCast(v));
    }

    pub fn writeDoubleRaw(w: *Writer, v: f64) EncodeError!void {
        try w.writeFixed64Raw(@bitCast(v));
    }

    pub fn writeInt32(w: *Writer, field: u32, v: i32) EncodeError!void {
        try w.writeTag(field, .varint);
        try w.writeInt32Raw(v);
    }

    pub fn writeInt64(w: *Writer, field: u32, v: i64) EncodeError!void {
        try w.writeTag(field, .varint);
        try w.writeInt64Raw(v);
    }

    pub fn writeUint(w: *Writer, field: u32, v: u64) EncodeError!void {
        try w.writeTag(field, .varint);
        try w.writeVarint(v);
    }

    pub fn writeBool(w: *Writer, field: u32, v: bool) EncodeError!void {
        try w.writeTag(field, .varint);
        try w.writeBoolRaw(v);
    }

    pub fn writeSint32(w: *Writer, field: u32, v: i32) EncodeError!void {
        try w.writeTag(field, .varint);
        try w.writeSint32Raw(v);
    }

    pub fn writeSint64(w: *Writer, field: u32, v: i64) EncodeError!void {
        try w.writeTag(field, .varint);
        try w.writeSint64Raw(v);
    }

    pub fn writeFixed32(w: *Writer, field: u32, v: u32) EncodeError!void {
        try w.writeTag(field, .fixed32);
        try w.writeFixed32Raw(v);
    }

    pub fn writeFixed64(w: *Writer, field: u32, v: u64) EncodeError!void {
        try w.writeTag(field, .fixed64);
        try w.writeFixed64Raw(v);
    }

    pub fn writeFloat(w: *Writer, field: u32, v: f32) EncodeError!void {
        try w.writeFixed32(field, @bitCast(v));
    }

    pub fn writeDouble(w: *Writer, field: u32, v: f64) EncodeError!void {
        try w.writeFixed64(field, @bitCast(v));
    }

    pub fn writeBytes(w: *Writer, field: u32, v: []const u8) EncodeError!void {
        try w.writeTag(field, .len);
        try w.writeVarint(v.len);
        try w.buf.appendSlice(w.a, v);
    }
};

test "varint and zigzag" {
    var r = Reader.init(&.{ 0x96, 0x01 });
    try std.testing.expectEqual(@as(u64, 150), try r.readVarint());

    var r2 = Reader.init(&.{0x03});
    try std.testing.expectEqual(@as(i32, -2), try r2.readSint32());
}

test "tag / bytes / skip" {
    // field 1 varint 42; field 2 len "hi"; field 99 fixed32.
    const buf = [_]u8{ 0x08, 42, 0x12, 2, 'h', 'i', 0x9d, 0x06, 1, 0, 0, 0 };
    var r = Reader.init(&buf);

    const t1 = (try r.next()).?;
    try std.testing.expectEqual(@as(u32, 1), t1.field);
    try std.testing.expectEqual(WireType.varint, t1.wire);
    try std.testing.expectEqual(@as(u64, 42), try r.readVarint());

    const t2 = (try r.next()).?;
    try std.testing.expectEqual(@as(u32, 2), t2.field);
    try std.testing.expectEqualStrings("hi", try r.readBytes());

    const t3 = (try r.next()).?;
    try std.testing.expectEqual(@as(u32, 99), t3.field);
    try r.skip(t3.wire);
    try std.testing.expect(r.atEnd());
    try std.testing.expectEqual(@as(?Tag, null), try r.next());
}

test "Writer produces the bytes the Reader tests already pin" {
    // Same buffer as "tag / bytes / skip", built rather than spelled out: if the
    // two ever disagree, one of them is wrong about the wire format.
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeUint(1, 42);
    try w.writeBytes(2, "hi");
    try w.writeFixed32(99, 1);
    try std.testing.expectEqualSlices(
        u8,
        &.{ 0x08, 42, 0x12, 2, 'h', 'i', 0x9d, 0x06, 1, 0, 0, 0 },
        w.bytes(),
    );
}

test "negative int32 is sign-extended to ten bytes, as protoc writes it" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeInt32(1, -2);

    // Truncating to five bytes would read back as 4294967294.
    try std.testing.expectEqual(@as(usize, 11), w.bytes().len);
    var r = Reader.init(w.bytes());
    _ = try r.next();
    try std.testing.expectEqual(@as(i32, -2), try r.readInt32());
}

test "every scalar survives a Writer -> Reader round trip" {
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    try w.writeInt64(1, -9007199254740993);
    try w.writeUint(2, std.math.maxInt(u64));
    try w.writeSint32(3, -2);
    try w.writeSint64(4, std.math.minInt(i64));
    try w.writeBool(5, true);
    try w.writeFixed32(6, 0xdeadbeef);
    try w.writeFixed64(7, 0xfeedfacecafebeef);
    try w.writeFloat(8, 0.5);
    try w.writeDouble(9, -3.25);
    try w.writeBytes(10, "bytes\x00with\x00nuls");

    var r = Reader.init(w.bytes());
    _ = try r.next();
    try std.testing.expectEqual(@as(i64, -9007199254740993), try r.readInt64());
    _ = try r.next();
    try std.testing.expectEqual(std.math.maxInt(u64), try r.readVarint());
    _ = try r.next();
    try std.testing.expectEqual(@as(i32, -2), try r.readSint32());
    _ = try r.next();
    try std.testing.expectEqual(std.math.minInt(i64), try r.readSint64());
    _ = try r.next();
    try std.testing.expectEqual(@as(u64, 1), try r.readVarint());
    _ = try r.next();
    try std.testing.expectEqual(@as(u32, 0xdeadbeef), try r.readFixed32());
    _ = try r.next();
    try std.testing.expectEqual(@as(u64, 0xfeedfacecafebeef), try r.readFixed64());
    _ = try r.next();
    try std.testing.expectEqual(@as(f32, 0.5), try r.readFloat());
    _ = try r.next();
    try std.testing.expectEqual(@as(f64, -3.25), try r.readDouble());
    _ = try r.next();
    try std.testing.expectEqualStrings("bytes\x00with\x00nuls", try r.readBytes());
    try std.testing.expect(r.atEnd());
}

test "endLen writes a canonical, minimal length varint" {
    // A payload of 128 bytes needs a two-byte length; 127 needs one. Getting
    // this wrong is invisible until a message crosses the boundary.
    for ([_]usize{ 0, 1, 127, 128, 300 }) |n| {
        var w = Writer.init(std.testing.allocator);
        defer w.deinit();
        const mark = try w.beginLen(1);
        for (0..n) |_| try w.buf.append(w.a, 'x');
        try w.endLen(mark);

        const want_len_bytes: usize = if (n < 128) 1 else 2;
        try std.testing.expectEqual(1 + want_len_bytes + n, w.bytes().len);

        var r = Reader.init(w.bytes());
        _ = try r.next();
        try std.testing.expectEqual(n, (try r.readBytes()).len);
    }
}

test "nested beginLen/endLen nests correctly" {
    // outer { inner { 7 } } — the inner length must be inserted before the
    // outer one is measured, or the outer length is short by the inner's bytes.
    var w = Writer.init(std.testing.allocator);
    defer w.deinit();
    const outer = try w.beginLen(1);
    const inner = try w.beginLen(2);
    try w.writeUint(3, 7);
    try w.endLen(inner);
    try w.endLen(outer);

    var r = Reader.init(w.bytes());
    _ = try r.next();
    var r1 = try r.subReader();
    _ = try r1.next();
    var r2 = try r1.subReader();
    const tag = (try r2.next()).?;
    try std.testing.expectEqual(@as(u32, 3), tag.field);
    try std.testing.expectEqual(@as(u64, 7), try r2.readVarint());
    try std.testing.expect(r2.atEnd());
    try std.testing.expect(r1.atEnd());
    try std.testing.expect(r.atEnd());
}
