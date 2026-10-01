//! Reading the delimited text a CSV load job carries.
//!
//! Fields are sliced out of the input where they can be; only a field carrying an escaped
//! quote is copied, because only that one differs from its own bytes.
//!
//! Whether a field was quoted is kept, since an empty field means different things either
//! way: bare it is the default null marker, quoted it is an empty string.
//! loading-data-cloud-storage-csv

const std = @import("std");

pub const Options = struct {
    /// A single byte. loading-data-cloud-storage-csv
    field_delimiter: u8 = ',',
    /// Null when the job asked for no quote character.
    quote: ?u8 = '"',
    /// Whether a newline inside a quoted field continues the field or ends the row.
    allow_quoted_newlines: bool = false,
};

pub const Field = struct {
    text: []const u8,
    quoted: bool = false,
};

pub const Row = []const Field;

pub const Error = error{
    /// A quoted field ran to the end of the input without closing.
    UnterminatedQuote,
    /// A newline inside a quoted field, where the job did not allow one.
    QuotedNewline,
} || std.mem.Allocator.Error;

/// Every row of `input`. A trailing newline does not produce an empty final row; a blank line
/// in the middle does, as a single empty field.
pub fn parse(arena: std.mem.Allocator, input: []const u8, options: Options) Error![]const Row {
    var rows: std.ArrayList(Row) = .empty;
    var pos: usize = 0;
    while (pos < input.len) {
        const row = try parseRow(arena, input, &pos, options);
        try rows.append(arena, row);
    }
    return rows.toOwnedSlice(arena);
}

fn parseRow(
    arena: std.mem.Allocator,
    input: []const u8,
    pos: *usize,
    options: Options,
) Error!Row {
    var fields: std.ArrayList(Field) = .empty;
    while (true) {
        const field = try parseField(arena, input, pos, options);
        try fields.append(arena, field);

        if (pos.* >= input.len) break;
        const c = input[pos.*];
        if (c == options.field_delimiter) {
            pos.* += 1;
            continue;
        }
        // A row ends at LF, and a CR immediately before it belongs to the line ending.
        if (c == '\n') {
            pos.* += 1;
            break;
        }
        if (c == '\r') {
            pos.* += 1;
            if (pos.* < input.len and input[pos.*] == '\n') pos.* += 1;
            break;
        }
        unreachable; // parseField stops only at a delimiter, a line ending, or the end
    }
    return fields.toOwnedSlice(arena);
}

fn parseField(
    arena: std.mem.Allocator,
    input: []const u8,
    pos: *usize,
    options: Options,
) Error!Field {
    const quote = options.quote orelse return .{ .text = scanBare(input, pos, options) };
    if (pos.* >= input.len or input[pos.*] != quote) {
        return .{ .text = scanBare(input, pos, options) };
    }

    pos.* += 1; // the opening quote
    const start = pos.*;
    var escapes: u32 = 0;
    while (pos.* < input.len) {
        const c = input[pos.*];
        if (c == quote) {
            // A doubled quote is one quote within the field. loading-data-cloud-storage-csv
            if (pos.* + 1 < input.len and input[pos.* + 1] == quote) {
                escapes += 1;
                pos.* += 2;
                continue;
            }
            const raw = input[start..pos.*];
            pos.* += 1; // the closing quote
            return .{ .text = try unescape(arena, raw, quote, escapes), .quoted = true };
        }
        if ((c == '\n' or c == '\r') and !options.allow_quoted_newlines) {
            return error.QuotedNewline;
        }
        pos.* += 1;
    }
    return error.UnterminatedQuote;
}

/// Up to the next delimiter or line ending.
fn scanBare(input: []const u8, pos: *usize, options: Options) []const u8 {
    const start = pos.*;
    while (pos.* < input.len) {
        const c = input[pos.*];
        if (c == options.field_delimiter or c == '\n' or c == '\r') break;
        pos.* += 1;
    }
    return input[start..pos.*];
}

fn unescape(
    arena: std.mem.Allocator,
    raw: []const u8,
    quote: u8,
    escapes: u32,
) std.mem.Allocator.Error![]const u8 {
    if (escapes == 0) return raw;
    var out = try std.ArrayList(u8).initCapacity(arena, raw.len - escapes);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        out.appendAssumeCapacity(raw[i]);
        if (raw[i] == quote) i += 1; // skip the second of the pair
    }
    return out.items;
}

const testing = std.testing;

fn textsOf(arena: std.mem.Allocator, rows: []const Row) ![][]const []const u8 {
    const out = try arena.alloc([]const []const u8, rows.len);
    for (rows, out) |row, *dst| {
        const texts = try arena.alloc([]const u8, row.len);
        for (row, texts) |field, *t| t.* = field.text;
        dst.* = texts;
    }
    return out;
}

test "rows split on the delimiter and the line ending" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try parse(arena, "a,b\n1,2\n", .{});
    try testing.expectEqualDeep(
        @as([]const []const []const u8, &.{ &.{ "a", "b" }, &.{ "1", "2" } }),
        try textsOf(arena, rows),
    );
}

test "a trailing newline does not make an extra row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(usize, 1), (try parse(arena, "a,b\n", .{})).len);
    try testing.expectEqual(@as(usize, 1), (try parse(arena, "a,b", .{})).len);
}

test "CRLF ends a row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try parse(arena, "a,b\r\n1,2\r\n", .{});
    try testing.expectEqualDeep(
        @as([]const []const []const u8, &.{ &.{ "a", "b" }, &.{ "1", "2" } }),
        try textsOf(arena, rows),
    );
}

test "an empty field is empty, and knows whether it was quoted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try parse(arena, "1,,\"\"\n", .{});
    try testing.expectEqual(@as(usize, 3), rows[0].len);
    try testing.expectEqualStrings("", rows[0][1].text);
    try testing.expect(!rows[0][1].quoted);
    try testing.expectEqualStrings("", rows[0][2].text);
    try testing.expect(rows[0][2].quoted);
}

test "a quoted field carries the delimiter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try parse(arena, "\"a,b\",c\n", .{});
    try testing.expectEqualStrings("a,b", rows[0][0].text);
    try testing.expectEqualStrings("c", rows[0][1].text);
}

test "a doubled quote is one quote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try parse(arena, "\"she said \"\"hi\"\"\",x\n", .{});
    try testing.expectEqualStrings("she said \"hi\"", rows[0][0].text);
    try testing.expectEqualStrings("x", rows[0][1].text);
}

test "a newline inside quotes needs permission" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.QuotedNewline, parse(arena, "\"a\nb\"\n", .{}));

    const rows = try parse(arena, "\"a\nb\",c\n", .{ .allow_quoted_newlines = true });
    try testing.expectEqualStrings("a\nb", rows[0][0].text);
    try testing.expectEqual(@as(usize, 1), rows.len);
}

test "an unterminated quote is an error rather than a truncated field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.UnterminatedQuote, parse(arena, "\"abc", .{}));
}

test "a job can ask for another delimiter, or for no quoting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const piped = try parse(arena, "a|b\n", .{ .field_delimiter = '|' });
    try testing.expectEqualStrings("a", piped[0][0].text);
    try testing.expectEqualStrings("b", piped[0][1].text);

    const raw = try parse(arena, "\"a\",b\n", .{ .quote = null });
    try testing.expectEqualStrings("\"a\"", raw[0][0].text);
}

test "rows may carry different field counts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const rows = try parse(arena, "a,b,c\n1,2\n3,4,5,6\n", .{});
    try testing.expectEqual(@as(usize, 3), rows[0].len);
    try testing.expectEqual(@as(usize, 2), rows[1].len);
    try testing.expectEqual(@as(usize, 4), rows[2].len);
}
