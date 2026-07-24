//! Protobuf wire-format reader used by the generated decoders in
//! resolved_ast.zig. Strings/bytes are returned as slices borrowing from the
//! input buffer; callers keep the buffer alive (arena-owned in practice).

const std = @import("std");

pub const DecodeError = error{
    Truncated,
    Malformed,
    OutOfMemory,
};

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
