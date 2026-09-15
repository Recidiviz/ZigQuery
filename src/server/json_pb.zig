//! Coercion primitives for the proto3 JSON mapping.
//!
//! The generated codecs call these for every scalar; hand-written response types
//! call the same ones, so one table of rules covers both. Reference:
//! https://protobuf.dev/programming-guides/json/
//!
//! Two things the mapping already gives us, which is why request decoding does
//! not need a permissive layer bolted on top:
//!
//! - 64-bit ints go out as JSON strings and come back from either strings or
//!   numbers.
//! - A parser accepts both the lowerCamelCase name and the original proto field
//!   name.
//!
//! `.lax` adds what a hand-rolled client body needs beyond that, and `.strict`
//! rejects every addition so a round-trip test proves the canonical encoding
//! rather than a tolerated one. The per-rule split is in the tests.
//!
//! `writeBytes` streams base64 rather than allocating, because the
//! `jsonStringify` hook takes no allocator.

const std = @import("std");

pub const Mode = enum { lax, strict };

pub const Options = struct {
    mode: Mode = .lax,
};

pub const Error = error{
    /// The JSON value's kind cannot produce the target type.
    TypeMismatch,
    /// The right kind, unreadable contents: "abc" for an int, bad base64.
    Malformed,
    /// Readable and outside the target type's range.
    OutOfRange,
} || std.mem.Allocator.Error;

/// Where a fault happened, for the `invalid` error envelope. Zig errors carry no
/// payload, so a decoder threads one of these out by pointer.
pub const Fault = struct {
    path: []const u8 = "",
    kind: Kind = .type_mismatch,

    pub const Kind = enum { type_mismatch, malformed, out_of_range };

    pub fn of(err: Error) Kind {
        return switch (err) {
            error.TypeMismatch => .type_mismatch,
            error.Malformed => .malformed,
            error.OutOfRange => .out_of_range,
            error.OutOfMemory => .malformed,
        };
    }
};

/// Parses a request body with numbers left as source text.
///
/// A JSON number bound for a string field keeps its exact spelling, and a value
/// wider than i64 survives; std.json's default parses both away.
pub fn parseBody(a: std.mem.Allocator, body: []const u8) !std.json.Value {
    return std.json.parseFromSliceLeaky(std.json.Value, a, body, .{ .parse_numbers = false });
}

// ---------------------------------------------------------------- writers

/// 64-bit ints are JSON strings.
pub fn writeI64(jw: anytype, v: i64) !void {
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
}

pub fn writeU64(jw: anytype, v: u64) !void {
    var buf: [24]u8 = undefined;
    try jw.write(std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable);
}

/// A float rendered with a fixed number of decimals.
///
/// `Stringify.print` exists for exactly this: the punctuation and structure stay
/// the serializer's, only the number's spelling is ours.
pub fn Fixed(comptime decimals: comptime_int) type {
    return struct {
        v: f64,

        const fmt = std.fmt.comptimePrint("{{d:.{d}}}", .{decimals});

        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.print(fmt, .{self.v});
        }
    };
}

/// Base64, streamed rather than buffered, because `jsonStringify` has no
/// allocator. The alphabet needs no JSON escaping, so raw is safe here.
pub fn writeBytes(jw: anytype, v: []const u8) !void {
    const enc = std.base64.standard.Encoder;
    try jw.beginWriteRaw();
    try jw.writer.writeByte('"');
    // A multiple of three, so every chunk but the last encodes without padding
    // and the concatenation stays valid base64.
    var window: [768]u8 = undefined;
    var i: usize = 0;
    while (i < v.len) : (i += window.len / 4 * 3) {
        const chunk = v[i..@min(i + window.len / 4 * 3, v.len)];
        try jw.writer.writeAll(enc.encode(&window, chunk));
    }
    try jw.writer.writeByte('"');
    jw.endWriteRaw();
}

// ---------------------------------------------------------------- readers

/// The source text of a JSON number, whichever representation it arrived in.
fn numText(src: std.json.Value, buf: []u8) ?[]const u8 {
    return switch (src) {
        .number_string => |s| s,
        .integer => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch null,
        else => null,
    };
}

fn parseIntText(comptime T: type, text: []const u8) Error!T {
    return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
        error.Overflow => error.OutOfRange,
        error.InvalidCharacter => error.Malformed,
    };
}

/// A signed or unsigned integer of any width.
///
/// A string is accepted unconditionally for 64-bit targets, which the mapping
/// requires, and under `.lax` for narrower ones, which it does not.
pub fn asInt(comptime T: type, src: std.json.Value, o: Options) Error!T {
    const bits = @typeInfo(T).int.bits;
    var buf: [24]u8 = undefined;
    switch (src) {
        .integer => |i| return std.math.cast(T, i) orelse error.OutOfRange,
        .number_string => |s| return parseIntText(T, s),
        .string => |s| {
            if (bits < 64 and o.mode == .strict) return error.TypeMismatch;
            return parseIntText(T, s);
        },
        .float => |f| {
            if (o.mode == .strict) return error.TypeMismatch;
            if (@floor(f) != f) return error.Malformed;
            if (f < -9.2233720368547758e18 or f > 1.8446744073709552e19) return error.OutOfRange;
            return std.math.cast(T, @as(i128, @intFromFloat(f))) orelse error.OutOfRange;
        },
        else => {
            _ = numText(src, &buf);
            return error.TypeMismatch;
        },
    }
}

pub fn asI64(src: std.json.Value, o: Options) Error!i64 {
    return asInt(i64, src, o);
}

pub fn asU64(src: std.json.Value, o: Options) Error!u64 {
    return asInt(u64, src, o);
}

pub fn asI32(src: std.json.Value, o: Options) Error!i32 {
    return asInt(i32, src, o);
}

pub fn asU32(src: std.json.Value, o: Options) Error!u32 {
    return asInt(u32, src, o);
}

pub fn asF64(src: std.json.Value, o: Options) Error!f64 {
    switch (src) {
        .float => |f| return f,
        .integer => |i| return @floatFromInt(i),
        .number_string, .string => |s| {
            // The mapping names "NaN", "Infinity" and "-Infinity" as the string
            // spellings, alongside a quoted decimal.
            if (std.mem.eql(u8, s, "NaN")) return std.math.nan(f64);
            if (std.mem.eql(u8, s, "Infinity")) return std.math.inf(f64);
            if (std.mem.eql(u8, s, "-Infinity")) return -std.math.inf(f64);
            if (src == .string and o.mode == .strict) return error.TypeMismatch;
            return std.fmt.parseFloat(f64, s) catch error.Malformed;
        },
        else => return error.TypeMismatch,
    }
}

/// Go's strconv.ParseBool set, which is what the REST surface has always taken
/// for a string-spelled bool. https://pkg.go.dev/strconv#ParseBool
const go_bool = std.StaticStringMap(bool).initComptime(.{
    .{ "1", true },    .{ "t", true },      .{ "T", true },      .{ "TRUE", true },
    .{ "true", true }, .{ "True", true },   .{ "0", false },     .{ "f", false },
    .{ "F", false },   .{ "FALSE", false }, .{ "false", false }, .{ "False", false },
});

pub fn asBool(src: std.json.Value, o: Options) Error!bool {
    switch (src) {
        .bool => |b| return b,
        .string => |s| {
            if (o.mode == .strict) return error.TypeMismatch;
            return go_bool.get(s) orelse error.Malformed;
        },
        .integer, .number_string => {
            if (o.mode == .strict) return error.TypeMismatch;
            return (try asInt(i64, src, o)) != 0;
        },
        else => return error.TypeMismatch,
    }
}

/// A string field. Under `.lax` a scalar is rendered rather than rejected, which
/// is what `QueryParameterValue.value` needs from a client that sent `{"value": 5}`.
pub fn asString(a: std.mem.Allocator, src: std.json.Value, o: Options) Error![]const u8 {
    switch (src) {
        .string => |s| return s,
        // Numbers reach here as source text, so the spelling is the client's.
        .number_string => |s| {
            if (o.mode == .strict) return error.TypeMismatch;
            return s;
        },
        .integer => |i| {
            if (o.mode == .strict) return error.TypeMismatch;
            return std.fmt.allocPrint(a, "{d}", .{i});
        },
        .bool => |b| {
            if (o.mode == .strict) return error.TypeMismatch;
            return if (b) "true" else "false";
        },
        // Only reachable from a body parsed with std.json's own number
        // handling; `parseBody` keeps the client's spelling instead.
        .float => |f| {
            if (o.mode == .strict) return error.TypeMismatch;
            return std.fmt.allocPrint(a, "{d}", .{f});
        },
        else => return error.TypeMismatch,
    }
}

pub fn asF32(src: std.json.Value, o: Options) Error!f32 {
    return @floatCast(try asF64(src, o));
}

/// A repeated field's elements. Under `.lax` a lone value stands in for a
/// one-element list, which is what a hand-written body tends to send.
pub fn asArray(
    a: std.mem.Allocator,
    src: std.json.Value,
    o: Options,
) Error![]const std.json.Value {
    if (src == .array) return src.array.items;
    if (o.mode == .strict) return error.TypeMismatch;
    const one = try a.alloc(std.json.Value, 1);
    one[0] = src;
    return one;
}

/// The payload of a wrapper message. The mapping puts the bare value on the
/// wire; `{"value": x}` is the shape a client writing the proto by hand sends.
pub fn wrapperInner(src: std.json.Value) std.json.Value {
    if (src == .object) {
        if (src.object.get("value")) |v| return v;
    }
    return src;
}

/// Both base64 alphabets, with or without padding, are named by the mapping, so
/// all four are accepted in either mode.
pub fn asBytes(a: std.mem.Allocator, src: std.json.Value, o: Options) Error![]const u8 {
    _ = o;
    const s = switch (src) {
        .string => |v| v,
        else => return error.TypeMismatch,
    };
    const decoders = [_]std.base64.Base64Decoder{
        std.base64.standard.Decoder,
        std.base64.standard_no_pad.Decoder,
        std.base64.url_safe.Decoder,
        std.base64.url_safe_no_pad.Decoder,
    };
    for (decoders) |dec| {
        const n = dec.calcSizeForSlice(s) catch continue;
        const out = try a.alloc(u8, n);
        dec.decode(out, s) catch {
            a.free(out);
            continue;
        };
        return out;
    }
    return error.Malformed;
}

/// An enum from its name or its number.
///
/// An unrecognised name is the zero value under `.lax`: the generated enums are
/// non-exhaustive so a future server value decodes rather than fails, and a
/// client sending a name this build has never heard of is the same situation.
pub fn asEnum(comptime E: type, src: std.json.Value, o: Options) Error!E {
    const info = @typeInfo(E).@"enum";
    switch (src) {
        .string => |s| {
            inline for (info.field_names) |field_name| {
                if (std.mem.eql(u8, field_name, s)) return @field(E, field_name);
            }
            if (o.mode == .strict) return error.Malformed;
            inline for (info.field_names) |field_name| {
                if (std.ascii.eqlIgnoreCase(field_name, s)) return @field(E, field_name);
            }
            return @fromBackingInt(0);
        },
        .integer, .number_string => return @fromBackingInt(@intCast(try asInt(i32, src, o))),
        else => return error.TypeMismatch,
    }
}

// ---------------------------------------------------------------- requests

/// One path variable, named by the field it binds to.
pub const Binding = struct { field: []const u8, value: []const u8 };

pub const Source = struct {
    /// The parsed request body, if there is one.
    body: ?std.json.Value = null,
    /// The `google.api.http` annotation's `body:` target, as a field name.
    /// Null puts the body at the top level, which is what `body: "*"` means.
    body_field: ?[]const u8 = null,
    /// The raw query string, without the leading `?`.
    query: []const u8 = "",
    /// Path variables, applied last: the URL is what actually addressed this
    /// resource.
    path: []const Binding = &.{},
};

/// Merges body, query string and path variables into one JSON value, so a
/// generated `jsonDecode` reads all three.
///
/// A dotted query key nests — `formatOptions.useInt64Timestamp` reaches the
/// `DataFormatOptions` inside the request — and a repeated key becomes an
/// array. Every query value is text, which is why the readers accept text for
/// every scalar.
pub fn requestValue(a: std.mem.Allocator, src: Source) Error!std.json.Value {
    var root: std.json.ObjectMap = .empty;
    if (src.body) |body| {
        if (src.body_field) |field| {
            try root.put(a, field, body);
        } else if (body == .object) {
            root = body.object;
        }
    }
    var it = std.mem.splitScalar(u8, src.query, '&');
    while (it.next()) |pair| {
        if (pair.len == 0) continue;
        const split = std.mem.indexOfScalar(u8, pair, '=') orelse pair.len;
        const key = try percentDecode(a, pair[0..split]);
        const value = try percentDecode(a, if (split < pair.len) pair[split + 1 ..] else "");
        try putPath(a, &root, key, .{ .string = value });
    }
    for (src.path) |b| try root.put(a, b.field, .{ .string = b.value });
    return .{ .object = root };
}

/// Sets `a.b.c`, creating the objects along the way. A key seen twice collects
/// into an array, which is how a repeated field arrives in a query string.
fn putPath(
    a: std.mem.Allocator,
    root: *std.json.ObjectMap,
    key: []const u8,
    value: std.json.Value,
) Error!void {
    var obj = root;
    var it = std.mem.splitScalar(u8, key, '.');
    var seg = it.next() orelse return;
    while (it.next()) |next| {
        const gop = try obj.getOrPut(a, seg);
        if (!gop.found_existing or gop.value_ptr.* != .object) {
            gop.value_ptr.* = .{ .object = .empty };
        }
        obj = &gop.value_ptr.object;
        seg = next;
    }
    const gop = try obj.getOrPut(a, seg);
    if (!gop.found_existing) {
        gop.value_ptr.* = value;
        return;
    }
    if (gop.value_ptr.* == .array) {
        try gop.value_ptr.array.append(value);
        return;
    }
    var list: std.json.Array = .init(a);
    try list.append(gop.value_ptr.*);
    try list.append(value);
    gop.value_ptr.* = .{ .array = list };
}

/// Go's url.ParseQuery: `+` is a space and `%XX` is a byte. An escape that is
/// not two hex digits stays literal rather than failing the request.
fn percentDecode(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfAny(u8, s, "%+") == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        switch (s[i]) {
            '+' => try out.append(a, ' '),
            '%' => {
                if (i + 2 < s.len) {
                    const hi = std.fmt.charToDigit(s[i + 1], 16) catch {
                        try out.append(a, s[i]);
                        continue;
                    };
                    const lo = std.fmt.charToDigit(s[i + 2], 16) catch {
                        try out.append(a, s[i]);
                        continue;
                    };
                    try out.append(a, hi * 16 + lo);
                    i += 2;
                } else try out.append(a, s[i]);
            },
            else => try out.append(a, s[i]),
        }
    }
    return out.toOwnedSlice(a);
}

// ---------------------------------------------------------------- test helper

/// Compares two JSON documents by value, so an object's key order is free.
///
/// Numbers compare as source text: `1e+21` and `1e21` are the same number and a
/// different answer, and the goldens are captured bytes.
pub fn expectJsonEqual(expected: []const u8, actual: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var note: std.ArrayList(u8) = .empty;
    compare(a, expected, actual, &note) catch |err| {
        std.debug.print("JSON mismatch {s}\nexpected: {s}\nactual:   {s}\n", .{
            note.items, expected, actual,
        });
        return err;
    };
}

/// The same comparison without the diagnostic, for tests that assert a mismatch.
pub fn jsonEqual(expected: []const u8, actual: []const u8) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    return compare(arena_state.allocator(), expected, actual, null);
}

fn compare(
    a: std.mem.Allocator,
    expected: []const u8,
    actual: []const u8,
    note: ?*std.ArrayList(u8),
) !void {
    const want = try parseBody(a, expected);
    const got = parseBody(a, actual) catch {
        if (note) |n| try n.appendSlice(a, "at (root): actual is not JSON");
        return error.TestExpectedEqual;
    };
    var d = Diag{ .a = a, .note = note };
    try eq(&d, want, got);
}

/// The path walked so far, and whether anyone asked for the detail.
const Diag = struct {
    a: std.mem.Allocator,
    path: std.ArrayList(u8) = .empty,
    note: ?*std.ArrayList(u8) = null,

    fn say(d: *Diag, comptime fmt: []const u8, args: anytype) !void {
        const n = d.note orelse return;
        const where = if (d.path.items.len == 0) "(root)" else d.path.items;
        try n.print(d.a, "at {s}: ", .{where});
        try n.print(d.a, fmt, args);
    }

    fn enter(d: *Diag, comptime fmt: []const u8, args: anytype) !usize {
        const mark = d.path.items.len;
        try d.path.print(d.a, fmt, args);
        return mark;
    }

    fn leave(d: *Diag, mark: usize) void {
        d.path.shrinkRetainingCapacity(mark);
    }

    fn missing(d: *Diag, key: []const u8) EqError!void {
        try d.say("missing key {s}", .{key});
        return error.TestExpectedEqual;
    }
};

/// Explicit, because eq and eqArray/eqObject are mutually recursive.
const EqError = error{ TestExpectedEqual, OutOfMemory };

fn eq(d: *Diag, want: std.json.Value, got: std.json.Value) EqError!void {
    if (@as(std.meta.Tag(std.json.Value), want) != @as(std.meta.Tag(std.json.Value), got)) {
        try d.say("kind {s} vs {s}", .{ @tagName(want), @tagName(got) });
        return error.TestExpectedEqual;
    }
    switch (want) {
        .null => {},
        .bool => |w| if (w != got.bool) {
            try d.say("{} vs {}", .{ w, got.bool });
            return error.TestExpectedEqual;
        },
        .integer => |w| if (w != got.integer) {
            try d.say("{d} vs {d}", .{ w, got.integer });
            return error.TestExpectedEqual;
        },
        .float => |w| if (w != got.float) {
            try d.say("{d} vs {d}", .{ w, got.float });
            return error.TestExpectedEqual;
        },
        .number_string, .string => |w| {
            const g = switch (got) {
                .number_string, .string => |v| v,
                else => unreachable,
            };
            if (!std.mem.eql(u8, w, g)) {
                try d.say("{s} vs {s}", .{ w, g });
                return error.TestExpectedEqual;
            }
        },
        .array => |w| try eqArray(d, w, got.array),
        .object => |w| try eqObject(d, w, got.object),
    }
}

fn eqArray(d: *Diag, want: std.json.Array, got: std.json.Array) EqError!void {
    if (want.items.len != got.items.len) {
        try d.say("array len {d} vs {d}", .{ want.items.len, got.items.len });
        return error.TestExpectedEqual;
    }
    for (want.items, got.items, 0..) |wi, gi, i| {
        const mark = try d.enter("[{d}]", .{i});
        try eq(d, wi, gi);
        d.leave(mark);
    }
}

fn listKeys(d: *Diag, sign: []const u8, m: std.json.ObjectMap) !void {
    const n = d.note orelse return;
    var it = m.iterator();
    while (it.next()) |e| try n.print(d.a, " {s}{s}", .{ sign, e.key_ptr.* });
}

fn eqObject(d: *Diag, want: std.json.ObjectMap, got: std.json.ObjectMap) EqError!void {
    if (want.count() != got.count()) {
        try d.say("keys", .{});
        try listKeys(d, "-", want);
        try listKeys(d, "+", got);
        return error.TestExpectedEqual;
    }
    var it = want.iterator();
    while (it.next()) |entry| {
        const g = got.get(entry.key_ptr.*) orelse return d.missing(entry.key_ptr.*);
        const mark = try d.enter(".{s}", .{entry.key_ptr.*});
        try eq(d, entry.value_ptr.*, g);
        d.leave(mark);
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn val(a: std.mem.Allocator, text: []const u8) !std.json.Value {
    return parseBody(a, text);
}

test "an integer arrives as a number, and as a string for 64-bit targets" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // A 64-bit target takes a quoted decimal in either mode: the mapping emits
    // one and therefore has to read one back.
    for ([_]Mode{ .lax, .strict }) |m| {
        const o = Options{ .mode = m };
        try testing.expectEqual(@as(i64, 7), try asI64(try val(a, "7"), o));
        try testing.expectEqual(@as(i64, 7), try asI64(try val(a, "\"7\""), o));
        try testing.expectEqual(@as(u64, 7), try asU64(try val(a, "\"7\""), o));
        try testing.expectEqual(@as(i64, -7), try asI64(try val(a, "-7"), o));
    }

    // A value wider than i64 survives, because the body keeps number text.
    try testing.expectEqual(
        @as(u64, 18446744073709551615),
        try asU64(try val(a, "18446744073709551615"), .{}),
    );
}

test "a string for a 32-bit int is lax only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqual(@as(u32, 10), try asU32(try val(a, "\"10\""), .{ .mode = .lax }));
    try testing.expectEqual(@as(u32, 10), try asU32(try val(a, "10"), .{ .mode = .strict }));
    try testing.expectEqual(@as(i32, -10), try asI32(try val(a, "-10"), .{ .mode = .strict }));
    try testing.expectError(
        error.TypeMismatch,
        asU32(try val(a, "\"10\""), .{ .mode = .strict }),
    );
}

test "an unreadable or out-of-range integer is told apart from a wrong kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.Malformed, asI64(try val(a, "\"abc\""), .{}));
    try testing.expectError(error.OutOfRange, asU32(try val(a, "4294967296"), .{}));
    try testing.expectError(error.OutOfRange, asU64(try val(a, "-1"), .{}));
    try testing.expectError(error.TypeMismatch, asI64(try val(a, "true"), .{}));
    try testing.expectError(error.TypeMismatch, asI64(try val(a, "[]"), .{}));
    try testing.expectError(error.TypeMismatch, asI64(try val(a, "null"), .{}));
}

test "a float for an int is lax, and must be integral" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // parseBody keeps number text, so a float reaches asInt only when the caller
    // parsed with std.json's defaults.
    const one_point_five = std.json.Value{ .float = 1.5 };
    const three = std.json.Value{ .float = 3.0 };
    try testing.expectEqual(@as(i64, 3), try asI64(three, .{ .mode = .lax }));
    try testing.expectError(error.Malformed, asI64(one_point_five, .{ .mode = .lax }));
    try testing.expectError(error.TypeMismatch, asI64(three, .{ .mode = .strict }));
    _ = a;
}

test "a bool takes Go's ParseBool spellings and 0/1 under lax" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for ([_]Mode{ .lax, .strict }) |m| {
        try testing.expectEqual(true, try asBool(try val(a, "true"), .{ .mode = m }));
        try testing.expectEqual(false, try asBool(try val(a, "false"), .{ .mode = m }));
    }
    for ([_][]const u8{ "\"1\"", "\"t\"", "\"T\"", "\"TRUE\"", "\"true\"", "\"True\"" }) |text| {
        try testing.expectEqual(true, try asBool(try val(a, text), .{ .mode = .lax }));
    }
    for ([_][]const u8{ "\"0\"", "\"f\"", "\"F\"", "\"FALSE\"", "\"false\"", "\"False\"" }) |text| {
        try testing.expectEqual(false, try asBool(try val(a, text), .{ .mode = .lax }));
    }
    try testing.expectEqual(true, try asBool(try val(a, "1"), .{ .mode = .lax }));
    try testing.expectEqual(false, try asBool(try val(a, "0"), .{ .mode = .lax }));

    // Not in Go's set.
    try testing.expectError(error.Malformed, asBool(try val(a, "\"yes\""), .{ .mode = .lax }));
    try testing.expectError(
        error.TypeMismatch,
        asBool(try val(a, "\"true\""), .{ .mode = .strict }),
    );
    try testing.expectError(error.TypeMismatch, asBool(try val(a, "1"), .{ .mode = .strict }));
}

test "a string field renders a scalar under lax and refuses it under strict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("x", try asString(a, try val(a, "\"x\""), .{ .mode = .strict }));
    // The client's own spelling, not a reformatting of it.
    try testing.expectEqualStrings("5", try asString(a, try val(a, "5"), .{ .mode = .lax }));
    try testing.expectEqualStrings("1e21", try asString(a, try val(a, "1e21"), .{ .mode = .lax }));
    try testing.expectEqualStrings("true", try asString(a, try val(a, "true"), .{ .mode = .lax }));
    try testing.expectError(error.TypeMismatch, asString(a, try val(a, "5"), .{ .mode = .strict }));
    try testing.expectError(error.TypeMismatch, asString(a, try val(a, "[]"), .{ .mode = .lax }));
}

test "bytes take either base64 alphabet, padded or not" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqualStrings("hi", try asBytes(a, try val(a, "\"aGk=\""), .{}));
    try testing.expectEqualStrings("hi", try asBytes(a, try val(a, "\"aGk\""), .{}));
    // 0xfb 0xff encodes as "+/8=" standard, "-_8=" url-safe.
    try testing.expectEqualStrings("\xfb\xff", try asBytes(a, try val(a, "\"+/8=\""), .{}));
    try testing.expectEqualStrings("\xfb\xff", try asBytes(a, try val(a, "\"-_8=\""), .{}));
    try testing.expectError(error.Malformed, asBytes(a, try val(a, "\"!!!\""), .{}));
    try testing.expectError(error.TypeMismatch, asBytes(a, try val(a, "5"), .{}));
}

const Projection = enum(i32) { minimal = 0, full = 1, _ };

test "an enum takes its name or its number" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    for ([_]Mode{ .lax, .strict }) |m| {
        const o = Options{ .mode = m };
        try testing.expectEqual(Projection.full, try asEnum(Projection, try val(a, "\"full\""), o));
        try testing.expectEqual(Projection.full, try asEnum(Projection, try val(a, "1"), o));
    }
    // A number this build has no name for still decodes: the enums are
    // non-exhaustive.
    try testing.expectEqual(@as(i32, 99), @backingInt(
        try asEnum(Projection, try val(a, "99"), .{}),
    ));
    try testing.expectEqual(Projection.full, try asEnum(Projection, try val(a, "\"FULL\""), .{}));
    try testing.expectEqual(
        Projection.minimal,
        try asEnum(Projection, try val(a, "\"nope\""), .{}),
    );
    try testing.expectError(
        error.Malformed,
        asEnum(Projection, try val(a, "\"FULL\""), .{ .mode = .strict }),
    );
}

test "a double takes the mapping's three named strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqual(@as(f64, 1.5), try asF64(try val(a, "1.5"), .{}));
    try testing.expect(std.math.isNan(try asF64(try val(a, "\"NaN\""), .{ .mode = .strict })));
    try testing.expectEqual(std.math.inf(f64), try asF64(try val(a, "\"Infinity\""), .{}));
    try testing.expectEqual(-std.math.inf(f64), try asF64(try val(a, "\"-Infinity\""), .{}));
    try testing.expectEqual(@as(f64, 2.5), try asF64(try val(a, "\"2.5\""), .{ .mode = .lax }));
    try testing.expectError(
        error.TypeMismatch,
        asF64(try val(a, "\"2.5\""), .{ .mode = .strict }),
    );
}

test "64-bit integers are written as JSON strings" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("totalRows");
    try writeU64(&jw, 3);
    try jw.objectField("bytes");
    try writeI64(&jw, -9223372036854775808);
    try jw.endObject();

    try testing.expectEqualStrings(
        \\{"totalRows":"3","bytes":"-9223372036854775808"}
    , aw.writer.buffered());
}

test "expectJsonEqual ignores key order" {
    try expectJsonEqual(
        \\{"a":1,"b":{"c":"x","d":null}}
    ,
        \\{"b":{"d":null,"c":"x"},"a":1}
    );
}

test "jsonEqual rejects a differing key set, value, or array order" {
    // Without these the helper silently blesses every golden it is given.
    try testing.expectError(error.TestExpectedEqual, jsonEqual(
        \\{"a":1}
    ,
        \\{"a":1,"b":2}
    ));
    try testing.expectError(error.TestExpectedEqual, jsonEqual(
        \\{"a":1,"b":2}
    ,
        \\{"a":1}
    ));
    // Same count, different names.
    try testing.expectError(error.TestExpectedEqual, jsonEqual(
        \\{"a":1}
    ,
        \\{"b":1}
    ));
    try testing.expectError(error.TestExpectedEqual, jsonEqual(
        \\{"a":1}
    ,
        \\{"a":2}
    ));
    try testing.expectError(error.TestExpectedEqual, jsonEqual("[1,2]", "[2,1]"));
    // A present null is not an absent key.
    try testing.expectError(error.TestExpectedEqual, jsonEqual(
        \\{"a":null}
    ,
        \\{}
    ));
    // Nor is a string the number that spells it.
    try testing.expectError(error.TestExpectedEqual, jsonEqual(
        \\{"a":"1"}
    ,
        \\{"a":1}
    ));
}

test "numbers compare by source text" {
    try expectJsonEqual("{\"f\":1e+21}", "{\"f\":1e+21}");
    try testing.expectError(
        error.TestExpectedEqual,
        jsonEqual("{\"f\":1e+21}", "{\"f\":1e21}"),
    );
}

test "Fixed keeps a chosen precision without hand-writing the number" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    try jw.beginObject();
    try jw.objectField("meanMs");
    try jw.write(Fixed(3){ .v = 1.0 / 3.0 });
    try jw.objectField("totalMs");
    try jw.write(Fixed(1){ .v = 12.0 });
    try jw.objectField("hitRate");
    try jw.write(Fixed(4){ .v = 0.96755 });
    try jw.endObject();

    try testing.expectEqualStrings(
        \\{"meanMs":0.333,"totalMs":12.0,"hitRate":0.9676}
    , aw.writer.buffered());
}

test "bytes are written as base64, across the chunking boundary" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    var jw: std.json.Stringify = .{ .writer = &aw.writer, .options = .{} };

    // 600 bytes crosses the 576-byte encode window, where a per-chunk padding
    // bug would show up as an embedded '='.
    const long = try testing.allocator.alloc(u8, 600);
    defer testing.allocator.free(long);
    for (long, 0..) |*b, i| b.* = @intCast(i % 251);

    try jw.beginArray();
    try writeBytes(&jw, "hi");
    try writeBytes(&jw, "");
    try writeBytes(&jw, long);
    try jw.endArray();

    const out = aw.writer.buffered();
    try testing.expect(std.mem.startsWith(u8, out, "[\"aGk=\",\"\","));
    // Round-trips through the reader, and pads only at the very end.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const parsed = try parseBody(a, out);
    try testing.expectEqualStrings(long, try asBytes(a, parsed.array.items[2], .{}));
    const b64 = parsed.array.items[2].string;
    const body = b64[0 .. b64.len - 2];
    try testing.expectEqual(@as(?usize, null), std.mem.indexOfScalar(u8, body, '='));
}

test "a lone value stands in for a one-element list only under lax" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const arr = try asArray(a, try val(a, "[1,2]"), .{ .mode = .strict });
    try testing.expectEqual(@as(usize, 2), arr.len);

    const one = try asArray(a, try val(a, "\"x\""), .{ .mode = .lax });
    try testing.expectEqual(@as(usize, 1), one.len);
    try testing.expectEqualStrings("x", one[0].string);

    try testing.expectError(
        error.TypeMismatch,
        asArray(a, try val(a, "\"x\""), .{ .mode = .strict }),
    );
}

test "a wrapper reads the bare value and the spelled-out object alike" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectEqual(@as(u64, 3), try asU64(wrapperInner(try val(a, "\"3\"")), .{}));
    try testing.expectEqual(
        @as(u64, 3),
        try asU64(wrapperInner(try val(a, "{\"value\":\"3\"}")), .{}),
    );
    // An object without `value` is passed through, so the reader reports the
    // kind mismatch rather than this silently reading as absent.
    try testing.expectError(
        error.TypeMismatch,
        asU64(wrapperInner(try val(a, "{\"other\":1}")), .{}),
    );
}

test "a request merges body, query string and path variables" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestValue(a, .{
        .body = try parseBody(a, "{\"query\":\"SELECT 1\"}"),
        .body_field = "queryRequest",
        .query = "maxResults=10&formatOptions.useInt64Timestamp=true",
        .path = &.{.{ .field = "projectId", .value = "p1" }},
    });
    try expectJsonEqual(
        \\{"queryRequest":{"query":"SELECT 1"},"maxResults":"10",
        \\ "formatOptions":{"useInt64Timestamp":"true"},"projectId":"p1"}
    , try std.json.Stringify.valueAlloc(a, v, .{}));
}

test "a body with no field target sits at the top level" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestValue(a, .{
        .body = try parseBody(a, "{\"datasetId\":\"ds\"}"),
        .path = &.{.{ .field = "projectId", .value = "p1" }},
    });
    try expectJsonEqual(
        \\{"datasetId":"ds","projectId":"p1"}
    , try std.json.Stringify.valueAlloc(a, v, .{}));
}

test "a repeated query key collects into an array" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestValue(a, .{ .query = "stateFilter=done&stateFilter=running&all=" });
    try expectJsonEqual(
        \\{"stateFilter":["done","running"],"all":""}
    , try std.json.Stringify.valueAlloc(a, v, .{}));
}

test "query values are percent-decoded, Go's url.ParseQuery way" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const v = try requestValue(a, .{ .query = "pageToken=a%2Fb+c&x=100%25&bad=%zz" });
    try expectJsonEqual(
        \\{"pageToken":"a/b c","x":"100%","bad":"%zz"}
    , try std.json.Stringify.valueAlloc(a, v, .{}));
}

test "a path variable wins over the same name in the body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The URL is what addressed the resource.
    const v = try requestValue(a, .{
        .body = try parseBody(a, "{\"projectId\":\"from-body\"}"),
        .query = "projectId=from-query",
        .path = &.{.{ .field = "projectId", .value = "from-path" }},
    });
    try expectJsonEqual(
        \\{"projectId":"from-path"}
    , try std.json.Stringify.valueAlloc(a, v, .{}));
}

test "a float reaches a string field when the body was parsed by std.json" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const f = try std.json.parseFromSliceLeaky(std.json.Value, a, "1.5", .{});
    try testing.expectEqualStrings("1.5", try asString(a, f, .{ .mode = .lax }));
    try testing.expectError(error.TypeMismatch, asString(a, f, .{ .mode = .strict }));
}
