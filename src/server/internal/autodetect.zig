//! Deriving a destination's columns from the data a load job carries.
//!
//! Two jobs behind one flag. A load job that asks for autodetection gets its column types
//! inferred from the values, and gets the first row read as column names when it looks like a
//! header. A job that supplies its own schema still gets the second. schema-detect
//!
//! Every rule here is measured; tools/load_autodetect_probe.py is what measured it, and the
//! tests carry the dates.

const std = @import("std");

/// The types a load job infers. NUMERIC is absent: telling it from FLOAT by inspection is a
/// judgement the reference does not describe.
pub const Kind = enum {
    /// No value yet, so nothing decided. Every empty field leaves a column here.
    unknown,
    boolean,
    integer,
    float,
    date,
    time,
    timestamp,
    string,

    /// The REST API's spelling. schema.zig renders a stored type the same way.
    pub fn legacyTypeName(k: Kind) []const u8 {
        return switch (k) {
            .boolean => "BOOLEAN",
            .integer => "INTEGER",
            .float => "FLOAT",
            .date => "DATE",
            .time => "TIME",
            .timestamp => "TIMESTAMP",
            // A column nothing was ever seen for is a string.
            .unknown, .string => "STRING",
        };
    }
};

/// The most specific type a single value can carry.
pub fn inferValue(text: []const u8) Kind {
    if (text.len == 0) return .unknown;
    if (isBoolean(text)) return .boolean;
    if (isInteger(text)) return .integer;
    if (isFloat(text)) return .float;
    if (isDate(text)) return .date;
    if (isTime(text)) return .time;
    if (isTimestamp(text)) return .timestamp;
    return .string;
}

/// The type a column holding both must have. Anything that disagrees is a string, which is
/// what makes a column of `100`, `hello`, `200` a string rather than an error.
pub fn merge(a: Kind, b: Kind) Kind {
    if (a == .unknown) return b;
    if (b == .unknown) return a;
    if (a == b) return a;
    // A column of whole and fractional numbers is fractional. Not measured: no probe case
    // mixed them.
    if ((a == .integer and b == .float) or (a == .float and b == .integer)) return .float;
    return .string;
}

/// The type of a whole column, given every value in it.
pub fn inferColumn(values: []const []const u8) Kind {
    var kind: Kind = .unknown;
    for (values) |value| kind = merge(kind, inferValue(value));
    return kind;
}

fn isBoolean(text: []const u8) bool {
    // `0` and `1` are excluded: the reference says autodetect takes every one of these
    // except those two. schema-detect
    const words = [_][]const u8{ "true", "false", "t", "f", "yes", "no", "y", "n" };
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    return false;
}

fn isInteger(text: []const u8) bool {
    return std.fmt.parseInt(i64, text, 10) catch null != null;
}

fn isFloat(text: []const u8) bool {
    // Rejecting the words parseFloat accepts: a column of `nan` is a column of strings.
    for (text) |c| {
        if (std.ascii.isAlphabetic(c) and c != 'e' and c != 'E') return false;
    }
    return std.fmt.parseFloat(f64, text) catch null != null;
}

fn allDigits(text: []const u8) bool {
    if (text.len == 0) return false;
    for (text) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn numberIn(text: []const u8, low: u16, high: u16) bool {
    if (!allDigits(text)) return false;
    const n = std.fmt.parseInt(u16, text, 10) catch return false;
    return n >= low and n <= high;
}

/// `YYYY-MM-DD`, and the day-first form BigQuery also takes. A `15/01/2024` loads as
/// `2024-01-15`, so the separator decides which part is the year rather than the order being
/// fixed.
pub fn isDate(text: []const u8) bool {
    if (std.mem.indexOfScalar(u8, text, '-') != null) {
        var it = std.mem.splitScalar(u8, text, '-');
        const year = it.next() orelse return false;
        const month = it.next() orelse return false;
        const day = it.next() orelse return false;
        if (it.next() != null) return false;
        return year.len == 4 and numberIn(year, 1, 9999) and
            numberIn(month, 1, 12) and numberIn(day, 1, 31);
    }
    if (std.mem.indexOfScalar(u8, text, '/') != null) {
        var it = std.mem.splitScalar(u8, text, '/');
        const day = it.next() orelse return false;
        const month = it.next() orelse return false;
        const year = it.next() orelse return false;
        if (it.next() != null) return false;
        // Day first. An ambiguous `01/02/2024` reads as the 1st of February; the probe only
        // settles the unambiguous case, where the day exceeds twelve.
        return year.len == 4 and numberIn(year, 1, 9999) and
            numberIn(month, 1, 12) and numberIn(day, 1, 31);
    }
    return false;
}

/// A detected date as `YYYY-MM-DD`. A day-first date is stored normalised, so `15/01/2024`
/// reads back as `2024-01-15`.
pub fn normalizeDate(arena: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, text, '/') == null) return text;
    var it = std.mem.splitScalar(u8, text, '/');
    const day = it.next() orelse return text;
    const month = it.next() orelse return text;
    const year = it.next() orelse return text;
    return std.fmt.allocPrint(arena, "{s}-{s:0>2}-{s:0>2}", .{ year, month, day });
}

/// `HH:MM:SS`, with an optional fractional part.
pub fn isTime(text: []const u8) bool {
    var rest = text;
    if (std.mem.indexOfScalar(u8, rest, '.')) |dot| {
        if (!allDigits(rest[dot + 1 ..])) return false;
        rest = rest[0..dot];
    }
    var it = std.mem.splitScalar(u8, rest, ':');
    const hour = it.next() orelse return false;
    const minute = it.next() orelse return false;
    const second = it.next() orelse return false;
    if (it.next() != null) return false;
    return numberIn(hour, 0, 23) and numberIn(minute, 0, 59) and numberIn(second, 0, 60);
}

/// A date and a time, separated by a space or a `T`, with an optional zone.
pub fn isTimestamp(text: []const u8) bool {
    const sep = std.mem.indexOfAny(u8, text, " T") orelse return false;
    if (!isDate(text[0..sep])) return false;

    var clock = text[sep + 1 ..];
    if (std.mem.endsWith(u8, clock, "Z")) {
        clock = clock[0 .. clock.len - 1];
    } else if (std.mem.lastIndexOfAny(u8, clock, "+-")) |offset| {
        // An offset only counts after the clock, which a bare `HH:MM` has no sign in.
        if (offset > 0) {
            if (!isOffset(clock[offset..])) return false;
            clock = clock[0..offset];
        }
    }
    if (isTime(clock)) return true;
    // `YYYY-MM-DD HH:MM` is a timestamp too. schema-detect
    var it = std.mem.splitScalar(u8, clock, ':');
    const hour = it.next() orelse return false;
    const minute = it.next() orelse return false;
    if (it.next() != null) return false;
    return numberIn(hour, 0, 23) and numberIn(minute, 0, 59);
}

fn isOffset(text: []const u8) bool {
    if (text.len == 0) return false;
    const body = text[1..];
    var it = std.mem.splitScalar(u8, body, ':');
    const hour = it.next() orelse return false;
    // `+01` is an offset as much as `+01:00`.
    const minute = it.next() orelse "00";
    if (it.next() != null) return false;
    return numberIn(hour, 0, 23) and numberIn(minute, 0, 59);
}

/// Whether the first row names the columns.
///
/// The reference's rule: a first row of nothing but strings, over rows that hold other types,
/// is a header. A file whose every column is a string has no detectable header, and the first
/// row loads as data. schema-detect
pub fn looksLikeHeader(first: []const []const u8, rest: []const []const []const u8) bool {
    if (first.len == 0 or rest.len == 0) return false;
    for (first) |cell| {
        if (inferValue(cell) != .string) return false;
    }
    for (rest) |row| {
        for (row) |cell| {
            const kind = inferValue(cell);
            if (kind != .string and kind != .unknown) return true;
        }
    }
    return false;
}

/// What a column is called when no header named it. schema-detect
pub fn generatedName(arena: std.mem.Allocator, index: u32) ![]const u8 {
    return std.fmt.allocPrint(arena, "string_field_{d}", .{index});
}

/// A header cell as a column name. Characters a column name cannot hold become underscores.
pub fn columnName(arena: std.mem.Allocator, header: []const u8) ![]const u8 {
    const out = try arena.dupe(u8, header);
    for (out) |*c| {
        if (!std.ascii.isAlphanumeric(c.*) and c.* != '_') c.* = '_';
    }
    return out;
}

/// Rows read to decide the columns. The reference samples up to this many and types the
/// columns from them, so a value further down the file does not widen a column. schema-detect
pub const sample_rows = 500;

pub const Column = struct {
    name: []const u8,
    kind: Kind,
};

pub const Detection = struct {
    columns: []const Column,
    /// The first row holding data rather than names or skipped leading rows.
    data_start: u32,
};

/// The columns a delimited file describes, and where its data begins.
///
/// `skip_leading_rows` distinguishes absent from zero, because the two are different requests:
/// absent asks autodetect to look for a header, zero states there is none, and N asks it to
/// look in row N having skipped the N-1 before it. rest/v2/Job#jobconfigurationload
pub fn detect(
    arena: std.mem.Allocator,
    rows: []const []const []const u8,
    skip_leading_rows: ?u32,
) !Detection {
    if (rows.len == 0) return .{ .columns = &.{}, .data_start = 0 };

    const start = locateData(rows, skip_leading_rows);
    const all_data = if (start.data_start < rows.len) rows[start.data_start..] else &.{};
    const data = all_data[0..@min(all_data.len, sample_rows)];
    return .{
        .columns = try detectColumns(arena, start.header, data),
        .data_start = start.data_start,
    };
}

const DataStart = struct {
    /// The row naming the columns, when the row before the data reads as one.
    header: ?[]const []const u8 = null,
    data_start: u32,
};

fn locateData(rows: []const []const []const u8, skip_leading_rows: ?u32) DataStart {
    const candidate: ?u32 = switch (skip_leading_rows orelse 0) {
        0 => if (skip_leading_rows == null) 0 else null,
        else => |n| n - 1,
    };
    const unread: DataStart = .{ .data_start = skip_leading_rows orelse 0 };
    const row_index = candidate orelse return unread;
    if (row_index >= rows.len) return unread;

    const rest = rows[row_index + 1 ..];
    const is_header = looksLikeHeader(rows[row_index], rest[0..@min(rest.len, sample_rows)]);
    return .{
        .header = if (is_header) rows[row_index] else null,
        .data_start = row_index + 1,
    };
}

fn detectColumns(
    arena: std.mem.Allocator,
    header: ?[]const []const u8,
    data: []const []const []const u8,
) ![]const Column {
    // The reference takes the column count from the rows having the most fields, so a jagged
    // row does not shorten the schema. schema-detect
    var width: u32 = 0;
    if (header) |names| width = @intCast(names.len);
    for (data) |row| width = @max(width, @as(u32, @intCast(row.len)));

    const columns = try arena.alloc(Column, width);
    for (columns, 0..) |*column, i| {
        // A header shorter than the widest row leaves the trailing columns unnamed.
        const named = if (header) |names|
            if (i < names.len) names[i] else null
        else
            null;
        column.* = .{
            .name = if (named) |text|
                try columnName(arena, text)
            else
                try generatedName(arena, @intCast(i)),
            .kind = columnKind(data, i),
        };
    }
    return columns;
}

fn columnKind(data: []const []const []const u8, i: usize) Kind {
    var kind: Kind = .unknown;
    for (data) |row| {
        if (i < row.len) kind = merge(kind, inferValue(row[i]));
    }
    return kind;
}

const testing = std.testing;

// The expectations below were read back from real BigQuery by
// tools/load_autodetect_probe.py (recidiviz-bigquery-sandbox, 2026-09-24), loading the CSVs
// that test/python/csv_autodetect_test.py carries.

test "a column of whole numbers is an integer, of fractions a float" {
    try testing.expectEqual(Kind.integer, inferColumn(&.{ "30", "25" }));
    try testing.expectEqual(Kind.float, inferColumn(&.{ "95.5", "88.0" }));
}

test "the boolean words, and the two digits that are not" {
    for ([_][]const u8{ "true", "false", "TRUE", "t", "f", "yes", "no", "Y", "N" }) |word| {
        try testing.expectEqual(Kind.boolean, inferValue(word));
    }
    try testing.expectEqual(Kind.integer, inferValue("0"));
    try testing.expectEqual(Kind.integer, inferValue("1"));
}

test "a day-first date is a date" {
    try testing.expectEqual(Kind.date, inferColumn(&.{ "2024-01-15", "2024-12-31" }));
    try testing.expectEqual(Kind.date, inferColumn(&.{ "15/01/2024", "31/12/2024" }));
}

test "the literal text null is a string, which drags its column to string" {
    try testing.expectEqual(Kind.string, inferValue("null"));
    // `100`, empty, `null`, `200`: the empty cell contributes nothing and `null` is a string.
    try testing.expectEqual(Kind.string, inferColumn(&.{ "100", "", "null", "200" }));
}

test "a column of nothing but empty cells is a string" {
    try testing.expectEqual(Kind.unknown, inferColumn(&.{ "", "" }));
    try testing.expectEqualStrings("STRING", Kind.unknown.legacyTypeName());
}

test "values that disagree make a string" {
    try testing.expectEqual(Kind.string, inferColumn(&.{ "100", "hello", "200" }));
    try testing.expectEqual(Kind.string, inferColumn(&.{ "true", "5" }));
}

test "timestamps and times" {
    try testing.expectEqual(Kind.timestamp, inferValue("2024-01-15 10:30:00"));
    try testing.expectEqual(Kind.timestamp, inferValue("2024-01-15T10:30:00Z"));
    try testing.expectEqual(Kind.timestamp, inferValue("2024-01-15 10:30"));
    try testing.expectEqual(Kind.timestamp, inferValue("2024-01-15T10:30:00+01:00"));
    try testing.expectEqual(Kind.time, inferValue("10:30:00"));
    try testing.expectEqual(Kind.time, inferValue("10:30:00.123456"));
}

test "a first row of strings over typed rows is a header" {
    try testing.expect(looksLikeHeader(
        &.{ "name", "age" },
        &.{ &.{ "Alice", "30" }, &.{ "Bob", "25" } },
    ));
}

test "a file that is strings throughout has no detectable header" {
    try testing.expect(!looksLikeHeader(
        &.{ "name", "city" },
        &.{ &.{ "Alice", "Leeds" }, &.{ "Bob", "Hull" } },
    ));
}

test "a first row carrying a number is data" {
    try testing.expect(!looksLikeHeader(&.{ "1", "x" }, &.{&.{ "2", "y" }}));
}

test "column names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("string_field_0", try generatedName(arena, 0));
    try testing.expectEqualStrings("string_field_3", try generatedName(arena, 3));
    try testing.expectEqualStrings("total_count", try columnName(arena, "total count"));
    try testing.expectEqualStrings("a_b", try columnName(arena, "a.b"));
}

const csv = @import("csv.zig");

/// The fixtures test/python/csv_autodetect_test.py loads, run through the CSV reader and this
/// module, checked against what real BigQuery detected from the same bytes
/// (recidiviz-bigquery-sandbox, 2026-09-24).
fn detectFrom(
    arena: std.mem.Allocator,
    input: []const u8,
    skip_leading_rows: ?u32,
) !Detection {
    const rows = try csv.parse(arena, input, .{});
    const texts = try arena.alloc([]const []const u8, rows.len);
    for (rows, texts) |row, *dst| {
        const cells = try arena.alloc([]const u8, row.len);
        for (row, cells) |field, *cell| cell.* = field.text;
        dst.* = cells;
    }
    return detect(arena, texts, skip_leading_rows);
}

fn expectColumns(detection: Detection, want: []const []const u8) !void {
    try testing.expectEqual(want.len, detection.columns.len);
    for (detection.columns, want) |column, spec| {
        var it = std.mem.splitScalar(u8, spec, ':');
        try testing.expectEqualStrings(it.next().?, column.name);
        try testing.expectEqualStrings(it.next().?, column.kind.legacyTypeName());
    }
}

test "the gate fixtures, with skipLeadingRows left off" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try expectColumns(
        try detectFrom(
            arena,
            "name,age,score,active\nAlice,30,95.5,true\nBob,25,88.0,false\n",
            null,
        ),
        &.{ "name:STRING", "age:INTEGER", "score:FLOAT", "active:BOOLEAN" },
    );
    try expectColumns(
        try detectFrom(
            arena,
            "event,event_date\nBirthday,2024-01-15\nAnniversary,2024-12-31\n",
            null,
        ),
        &.{ "event:STRING", "event_date:DATE" },
    );
    try expectColumns(
        try detectFrom(
            arena,
            "event,event_date\nBirthday,15/01/2024\nAnniversary,31/12/2024\n",
            null,
        ),
        &.{ "event:STRING", "event_date:DATE" },
    );
    try expectColumns(
        try detectFrom(arena, "id,value,name\n1,100,Alice\n2,,Bob\n3,null,Charlie\n4,200,\n", null),
        &.{ "id:INTEGER", "value:STRING", "name:STRING" },
    );
    try expectColumns(
        try detectFrom(arena, "id,flag1,flag2,flag3\n1,true,yes,Y\n2,false,no,N\n", null),
        &.{ "id:INTEGER", "flag1:BOOLEAN", "flag2:BOOLEAN", "flag3:BOOLEAN" },
    );
    try expectColumns(
        try detectFrom(arena, "id,mixed_col\n1,100\n2,hello\n3,200\n", null),
        &.{ "id:INTEGER", "mixed_col:STRING" },
    );
    try expectColumns(
        try detectFrom(arena, "id,empty_col\n1,\n2,null\n3,\n", null),
        &.{ "id:INTEGER", "empty_col:STRING" },
    );
}

test "skipLeadingRows of zero states there is no header" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The same bytes as the first fixture. With no header to name them the columns are
    // generated, and the header row's own strings drag every column to STRING.
    const detection = try detectFrom(
        arena,
        "name,age,score,active\nAlice,30,95.5,true\nBob,25,88.0,false\n",
        0,
    );
    try expectColumns(detection, &.{
        "string_field_0:STRING",
        "string_field_1:STRING",
        "string_field_2:STRING",
        "string_field_3:STRING",
    });
    try testing.expectEqual(@as(u32, 0), detection.data_start);
}

test "skipLeadingRows of N looks for a header in row N" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const detection = try detectFrom(arena, "junk\nname,age\nAlice,30\n", 2);
    try expectColumns(detection, &.{ "name:STRING", "age:INTEGER" });
    try testing.expectEqual(@as(u32, 2), detection.data_start);
}

test "the column count comes from the widest row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const detection = try detectFrom(arena, "1,2\n3,4,5\n", 0);
    try testing.expectEqual(@as(usize, 3), detection.columns.len);
}

test "a value past the sample does not widen a column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Integers for the whole sample, then text. BigQuery reads up to 500 rows and types the
    // column from those, so the row after them does not make it a string.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    // Not `n`: that is one of the boolean words, so a header row holding it is data.
    try body.appendSlice(testing.allocator, "num\n");
    for (0..sample_rows) |i| try body.print(testing.allocator, "{d}\n", .{i});
    try body.appendSlice(testing.allocator, "not a number\n");

    const detection = try detectFrom(arena, body.items, null);
    try expectColumns(detection, &.{"num:INTEGER"});
}

test "the column count comes from the sample, not the whole file" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(testing.allocator);
    for (0..sample_rows) |i| try body.print(testing.allocator, "{d},{d}\n", .{ i, i });
    try body.appendSlice(testing.allocator, "1,2,3\n");

    const detection = try detectFrom(arena, body.items, 0);
    try testing.expectEqual(@as(usize, 2), detection.columns.len);
}
