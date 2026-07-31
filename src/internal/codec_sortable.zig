//! A memcomparable encoding for the kinds that can have one.
//!
//! `memcmp` over two of these, of the same kind, gives the same answer as
//! `value.compareForCollation`. That matters because SQLite ignores collating
//! sequences on BLOBs — it always compares them byte by byte — so a BLOB column
//! can only be ordered correctly if the bytes themselves are ordered correctly.
//! Getting that right is what lets values leave base64 behind: the alternative
//! is a BLOB column whose ORDER BY is silently wrong, since zetasqlite_collate
//! is never consulted and nothing raises an error.
//!
//! Layout is `[tag][payload]`, and the payload simply runs to the end of the
//! buffer. No length prefixes, no terminators, no escaping — and that is not a
//! simplification, it is the point: a uvarint length prefix would sort by
//! *length* before content, which is exactly the bug this format exists to
//! avoid.
//!
//! It gets away with having no framing because only *top-level* values are
//! encoded here, so a variable-length payload can run to the buffer's end.
//! Nested values must be self-delimiting, so ARRAY and STRUCT carry their
//! elements in the self-delimiting codec instead — as do JSON and INTERVAL,
//! which have no order to preserve (`compareOp` errors on every operator).
//!
//! One known divergence, in NUMERIC vs BIGNUMERIC. `Rat.cmp` is kind-agnostic,
//! so `compareForCollation` calls `NUMERIC '1.5'` and `BIGNUMERIC '1.5'` equal,
//! while memcmp here puts every NUMERIC below every BIGNUMERIC because the tag
//! leads. That is accepted rather than fixed: a GoogleSQL column has one static
//! type and the analyzer inserts a cast for mixed-kind arithmetic, so the two
//! cannot meet in one column through analyzed SQL. Making them compare equal
//! would mean one shared width at scale 38 — doubling every NUMERIC to 34 bytes
//! to order a state the analyzer forbids. `test "NUMERIC and BIGNUMERIC do not
//! interleave"` pins the divergence so it stays deliberate.

const std = @import("std");
const value_mod = @import("value.zig");

pub const Value = value_mod.Value;
pub const ValueError = value_mod.ValueError;

/// Tags are ordered so that, if two kinds ever did meet in one column, the
/// byte order would at least be stable. Within a column only one occurs.
pub const tag_date: u8 = 0x40;
pub const tag_time: u8 = 0x48;
pub const tag_datetime: u8 = 0x50;
pub const tag_timestamp: u8 = 0x58;
pub const tag_string: u8 = 0x60;
pub const tag_bytes: u8 = 0x68;
pub const tag_numeric: u8 = 0x70;
pub const tag_bignumeric: u8 = 0x78;

/// Payload widths for the two decimal kinds: the unscaled integer, biased into
/// unsigned space, big-endian. NUMERIC's 38 digits need 127 bits, BIGNUMERIC's
/// 76 need 255 — and BIGNUMERIC's unscaled domain *is* i256's, exactly.
const numeric_bytes = 16;
const bignumeric_bytes = 32;

/// Flips the sign bit so that two's-complement integers compare correctly as
/// unsigned big-endian bytes: negatives (sign bit 1) must sort below
/// non-negatives, which is the opposite of what the raw bit pattern does.
fn orderable(v: i64) u64 {
    return @as(u64, @bitCast(v)) ^ (@as(u64, 1) << 63);
}

fn unorderable(u: u64) i64 {
    return @bitCast(u ^ (@as(u64, 1) << 63));
}

/// Encodes `v`, or returns null for a kind with no order to preserve, which
/// keeps the self-delimiting codec in codec_binary.zig instead.
pub fn encode(alloc: std.mem.Allocator, v: Value) ValueError!?[]u8 {
    switch (v) {
        .safe => |p| return encode(alloc, p.*),
        .string, .bytes => |s| {
            // The payload is the raw bytes: compareOp compares strings and
            // bytes with std.mem.order (value.zig:658,668), and memcmp over
            // equal tags is exactly that, including the shorter-is-less rule
            // for a common prefix.
            const out = try alloc.alloc(u8, 1 + s.len);
            out[0] = if (v == .string) tag_string else tag_bytes;
            @memcpy(out[1..], s);
            return out;
        },
        .date, .time, .datetime, .timestamp => {
            const tag: u8, const n: i64 = switch (v) {
                .date => |d| .{ tag_date, d },
                .time => |t| .{ tag_time, t },
                .datetime => |d| .{ tag_datetime, d },
                .timestamp => |t| .{ tag_timestamp, t },
                else => unreachable,
            };
            const out = try alloc.alloc(u8, 9);
            out[0] = tag;
            std.mem.writeInt(u64, out[1..9], orderable(n), .big);
            return out;
        },
        // NUMERIC is decimal(38,9) and BIGNUMERIC decimal(76,38), so each value
        // is an integer at its scale — value.zig's numericValue guarantees it.
        // Bias that integer into unsigned space and write it big-endian and
        // memcmp is numeric order.
        //
        // The biased form is written rather than the signed one on purpose:
        // writePackedTwosComplement checks a *positive* value against unsigned
        // width, so a signed export would have to reserve the sign bit itself.
        // Biasing first makes the value non-negative and exactly `w` bits.
        .numeric => |n| {
            const scale = value_mod.scaleFor(n.is_bignumeric);
            const unscaled = try n.rat.unscaledInt(alloc, scale);
            if (n.is_bignumeric) {
                const out = try alloc.alloc(u8, 1 + bignumeric_bytes);
                out[0] = tag_bignumeric;
                std.mem.writeInt(u256, out[1..][0..bignumeric_bytes], bias(u256, unscaled), .big);
                return out;
            }
            // Narrowing is safe by the construction-time bound, but checked
            // rather than asserted: an unchecked cast would truncate silently
            // in release and land the value wherever the wrapped bits sort.
            const narrow = std.math.cast(i128, unscaled) orelse
                return error.NumericOutOfRange;
            const out = try alloc.alloc(u8, 1 + numeric_bytes);
            out[0] = tag_numeric;
            std.mem.writeInt(u128, out[1..][0..numeric_bytes], bias(u128, narrow), .big);
            return out;
        },
        else => return null,
    }
}

/// Maps a signed integer onto unsigned space order-preservingly, by flipping
/// the sign bit — the same transform as `orderable`, at an arbitrary width.
fn bias(comptime U: type, v: anytype) U {
    const bits = @typeInfo(U).int.bits;
    return @as(U, @bitCast(v)) ^ (@as(U, 1) << (bits - 1));
}

fn unbias(comptime I: type, u: anytype) I {
    const bits = @typeInfo(@TypeOf(u)).int.bits;
    return @bitCast(u ^ (@as(@TypeOf(u), 1) << (bits - 1)));
}

/// Decodes a memcomparable buffer. Strings and bytes alias `buf` — no copy and no
/// allocation — so `buf` must outlive the returned Value. (NUMERIC is the one
/// kind that must allocate, for its bigint.) That holds at
/// every call site: the buffer is SQLite's, valid for the statement step or UDF
/// call that produced it, and every caller consumes the Value before returning.
pub fn decode(alloc: std.mem.Allocator, buf: []const u8) ValueError!Value {
    if (buf.len == 0) return error.CorruptData;
    const payload = buf[1..];
    switch (buf[0]) {
        tag_string => return Value{ .string = payload },
        tag_bytes => return Value{ .bytes = payload },
        tag_date, tag_time, tag_datetime, tag_timestamp => {
            if (payload.len != 8) return error.CorruptData;
            const n = unorderable(std.mem.readInt(u64, payload[0..8], .big));
            return switch (buf[0]) {
                tag_date => Value{ .date = n },
                tag_time => Value{ .time = n },
                tag_datetime => Value{ .datetime = n },
                else => Value{ .timestamp = n },
            };
        },
        // The unscaled integer, unbiased and divided back by 10^scale. Built
        // directly rather than through numericValue: the bytes already satisfy
        // the scale invariant, and re-deriving it would cost a bigint multiply
        // and divide per numeric per row.
        tag_numeric => {
            if (payload.len != numeric_bytes) return error.CorruptData;
            const u = std.mem.readInt(u128, payload[0..numeric_bytes], .big);
            return value_mod.numericFromUnscaled(alloc, unbias(i128, u), false);
        },
        tag_bignumeric => {
            if (payload.len != bignumeric_bytes) return error.CorruptData;
            const u = std.mem.readInt(u256, payload[0..bignumeric_bytes], .big);
            return value_mod.numericFromUnscaled(alloc, unbias(i256, u), true);
        },
        else => return error.CorruptData, // unexpected tag
    }
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "round trips every eligible kind" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const vals = [_]Value{
        .{ .string = "" },
        .{ .string = "hello" },
        .{ .string = "\x00\xff" },
        .{ .bytes = "" },
        .{ .bytes = "\x00\x01\xff" },
        .{ .date = 0 },
        .{ .date = -719162 },
        .{ .date = 100000 },
        .{ .time = 0 },
        .{ .datetime = -1 },
        .{ .timestamp = std.math.minInt(i64) },
        .{ .timestamp = std.math.maxInt(i64) },
    };
    for (vals) |v| {
        const enc = (try encode(alloc, v)).?;
        try value_mod.expectValueEqual(v, try decode(alloc, enc));
    }
}


test "BIGNUMERIC encodes to the biased big-endian test vectors" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The whole construction in six values. min maps to all-zero and max to
    // all-ones because BIGNUMERIC's unscaled domain is exactly i256's, so the
    // bias is a bijection onto u256 with nothing left over.
    const ten38: i256 = 100000000000000000000000000000000000000;
    const cases = [_]struct { unscaled: i256, hex: []const u8 }{
        .{ .unscaled = std.math.minInt(i256), .hex = "00" ++ "00" ** 31 },
        .{ .unscaled = -1, .hex = "7f" ++ "ff" ** 31 },
        .{ .unscaled = 0, .hex = "80" ++ "00" ** 31 },
        .{ .unscaled = 1, .hex = "80" ++ "00" ** 30 ++ "01" },
        .{ .unscaled = ten38, .hex = "80" ++ "00" ** 15 ++ "4b3b4ca85a86c47a098a224000000000" },
        .{ .unscaled = std.math.maxInt(i256), .hex = "ff" ** 32 },
    };
    for (cases) |tc| {
        const v = try value_mod.numericFromUnscaled(alloc, tc.unscaled, true);
        const enc = (try encode(alloc, v)).?;
        try testing.expectEqual(tag_bignumeric, enc[0]);
        const hex = try std.fmt.allocPrint(alloc, "{x}", .{enc[1..]});
        try testing.expectEqualStrings(tc.hex, hex);
        // And back, so the vectors pin decode too.
        try value_mod.expectValueEqual(v, try decode(alloc, enc));
    }
}

test "numeric round trips at both scales, including the range bounds" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const num_max: i256 = value_mod.numeric_unscaled_max;
    const unscaled = [_]struct { u: i256, big: bool }{
        .{ .u = 0, .big = false },              .{ .u = 1, .big = false },
        .{ .u = -1, .big = false },             .{ .u = num_max, .big = false },
        .{ .u = -num_max, .big = false },       .{ .u = 0, .big = true },
        .{ .u = 1, .big = true },               .{ .u = -1, .big = true },
        .{ .u = std.math.maxInt(i256), .big = true },
        .{ .u = std.math.minInt(i256), .big = true },
    };
    for (unscaled) |tc| {
        const v = try value_mod.numericFromUnscaled(alloc, tc.u, tc.big);
        const enc = (try encode(alloc, v)).?;
        try testing.expectEqual(@as(usize, if (tc.big) 33 else 17), enc.len);
        try value_mod.expectValueEqual(v, try decode(alloc, enc));
    }

    // Past NUMERIC's 38 digits is rejected rather than truncated into whatever
    // the low 128 bits happen to be.
    try testing.expectError(
        error.NumericOutOfRange,
        value_mod.numericFromUnscaled(alloc, num_max + 1, false),
    );
}

test "NUMERIC and BIGNUMERIC do not interleave" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // A documented divergence, not an oversight. Rat.cmp ignores the kind, so
    // compareForCollation calls these two equal; the leading tag makes memcmp
    // put every NUMERIC below every BIGNUMERIC. Accepted because a GoogleSQL
    // column has one static type and the analyzer casts for mixed-kind
    // arithmetic, so the pair cannot arise in one column through analyzed SQL —
    // and closing it would mean one shared width at scale 38, doubling every
    // NUMERIC to 34 bytes to order a state that cannot occur.
    const small_big = try value_mod.numericFromString(alloc, "1", true);
    const large_num = try value_mod.numericFromString(alloc, "1e28", false);
    try testing.expectEqual(std.math.Order.lt, try value_mod.compareForCollation(small_big, large_num));
    // ...but the bytes say otherwise, because the tag leads.
    try testing.expectEqual(std.math.Order.gt, std.mem.order(
        u8,
        (try encode(alloc, small_big)).?,
        (try encode(alloc, large_num)).?,
    ));
}

test "memcmp over encodings matches compareForCollation" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // This is the invariant the whole format exists for. If it ever fails,
    // BLOB columns of that kind sort wrongly with no error anywhere.
    const groups = [_][]const Value{
        &.{
            .{ .string = "" },   .{ .string = "a" },  .{ .string = "aa" },
            .{ .string = "ab" }, .{ .string = "b" },  .{ .string = "\xff" },
        },
        &.{ .{ .bytes = "" }, .{ .bytes = "\x00" }, .{ .bytes = "\x00\x00" }, .{ .bytes = "\xff" } },
        // Pre-epoch values are the ones a naive big-endian encoding gets wrong:
        // the sign bit makes them sort above everything unless it is flipped.
        &.{ .{ .date = -719162 }, .{ .date = -1 }, .{ .date = 0 }, .{ .date = 1 }, .{ .date = 100000 } },
        &.{
            .{ .timestamp = std.math.minInt(i64) }, .{ .timestamp = -1 },
            .{ .timestamp = 0 },                    .{ .timestamp = 1 },
            .{ .timestamp = std.math.maxInt(i64) },
        },
        &.{ .{ .datetime = -5 }, .{ .datetime = 0 }, .{ .datetime = 5 } },
        &.{ .{ .time = 0 }, .{ .time = 1 }, .{ .time = 86_399_999_999 } },
    };
    // Numerics need their own groups because they must be constructed, not
    // written as literals. Same-kind only: cross-kind is a known divergence,
    // pinned by test "NUMERIC and BIGNUMERIC do not interleave".
    const numeric_groups = [_][]const Value{
        &.{
            try value_mod.numericFromUnscaled(alloc, -value_mod.numeric_unscaled_max, false),
            try value_mod.numericFromUnscaled(alloc, -1, false),
            try value_mod.numericFromUnscaled(alloc, 0, false),
            try value_mod.numericFromUnscaled(alloc, 1, false),
            try value_mod.numericFromUnscaled(alloc, value_mod.numeric_unscaled_max, false),
        },
        &.{
            try value_mod.numericFromUnscaled(alloc, std.math.minInt(i256), true),
            try value_mod.numericFromUnscaled(alloc, -1, true),
            try value_mod.numericFromUnscaled(alloc, 0, true),
            try value_mod.numericFromUnscaled(alloc, 1, true),
            try value_mod.numericFromUnscaled(alloc, std.math.maxInt(i256), true),
        },
    };

    var checked: usize = 0;
    for (groups ++ numeric_groups) |group| {
        for (group) |a| {
            for (group) |b| {
                const ea = (try encode(alloc, a)).?;
                const eb = (try encode(alloc, b)).?;
                const want = value_mod.compareForCollation(a, b) catch .lt;
                try testing.expectEqual(want, std.mem.order(u8, ea, eb));
                checked += 1;
            }
        }
    }
    try testing.expect(checked > 100);
}
