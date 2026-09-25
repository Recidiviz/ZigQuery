//! Turning a load job's uploaded bytes into the schema and rows the content store writes.
//!
//! The rows come out in the shape `tabledata.insertAll` posts: one JSON object per row, keyed
//! by column name. That is what `contentdata.Repository.addTableData` already takes, so a load
//! and a streaming insert converge here rather than in two write paths.

const std = @import("std");
const zigquery = @import("zigquery");
const spec_mod = zigquery.spec;
const autodetect = @import("autodetect.zig");
const csv = @import("csv.zig");
const schema_mod = @import("types/schema.zig");
const load_handler = @import("../handler/jobs.load.zig");
const pb = @import("../proto/bigquery.zig");

pub const Error = error{
    /// Nothing said what the destination's columns are.
    NoSchema,
    /// A JSON line that is not an object, or a member this emulator does not read.
    NotAnObject,
    NestedJson,
    MalformedJson,
    MalformedCsv,
} || std.mem.Allocator.Error;

pub const Reading = struct {
    /// The destination's schema as a REST resource node, for the DDL and the metadata store.
    schema_node: std.json.Value,
    /// The same fields, as `addTableData` takes them.
    schema_fields: []const std.json.Value,
    /// One object per row, keyed by column name.
    rows: []const std.json.Value,
    bad_records: u64,
};

const Column = struct {
    name: []const u8,
    /// A legacy REST type name.
    type_name: []const u8,
};

pub fn readErrorMessage(err: Error) []const u8 {
    return switch (err) {
        error.NoSchema => "the load names no schema: supply one, enable autodetect, or " ++
            "load into an existing table",
        error.NotAnObject => "every line of a NEWLINE_DELIMITED_JSON upload must be an object",
        error.NestedJson => "nested and repeated fields are not read from " ++
            "NEWLINE_DELIMITED_JSON",
        error.MalformedJson => "the upload is not newline-delimited JSON",
        error.MalformedCsv => "the upload is not readable as CSV",
        error.OutOfMemory => "out of memory",
    };
}

pub fn read(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
    existing: ?*const spec_mod.TableSpec,
) Error!Reading {
    return switch (spec.source_format) {
        .CSV => readCsv(arena, media, spec, existing),
        .NEWLINE_DELIMITED_JSON => readJson(arena, media, spec, existing),
    };
}

/// The columns a job supplied, or the ones its destination already has. Null when neither did,
/// which leaves autodetect to decide.
fn declaredColumns(
    arena: std.mem.Allocator,
    spec: load_handler.LoadSpec,
    existing: ?*const spec_mod.TableSpec,
) !?[]const Column {
    if (spec.schema) |schema| {
        const out = try arena.alloc(Column, schema.fields.len);
        for (schema.fields, out) |field, *column| {
            column.* = .{
                .name = field.name orelse "",
                .type_name = field.type orelse "STRING",
            };
        }
        return out;
    }
    if (existing) |table| {
        const out = try arena.alloc(Column, table.columns.len);
        for (table.columns, out) |source, *column| {
            column.* = .{
                .name = source.name,
                .type_name = schema_mod.legacyTypeName(source.type.typeKind()),
            };
        }
        return out;
    }
    return null;
}

fn schemaNodeFrom(arena: std.mem.Allocator, columns: []const Column) !std.json.Value {
    var fields = std.json.Array.init(arena);
    for (columns) |column| {
        var object: std.json.ObjectMap = .empty;
        try object.put(arena, "name", .{ .string = column.name });
        try object.put(arena, "type", .{ .string = column.type_name });
        try fields.append(.{ .object = object });
    }
    var root: std.json.ObjectMap = .empty;
    try root.put(arena, "fields", .{ .array = fields });
    return .{ .object = root };
}

fn fieldsOf(schema_node: std.json.Value) []const std.json.Value {
    const fields = schema_node.object.get("fields") orelse return &.{};
    return if (fields == .array) fields.array.items else &.{};
}

fn readCsv(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
    existing: ?*const spec_mod.TableSpec,
) Error!Reading {
    const parsed = csv.parse(arena, media, .{
        .field_delimiter = spec.field_delimiter,
        .quote = spec.quote,
        .allow_quoted_newlines = spec.allow_quoted_newlines,
    }) catch return error.MalformedCsv;

    const texts = try arena.alloc([]const []const u8, parsed.len);
    for (parsed, texts) |row, *dst| {
        const cells = try arena.alloc([]const u8, row.len);
        for (row, cells) |field, *cell| cell.* = field.text;
        dst.* = cells;
    }

    // Autodetect decides where the data starts even when the job supplied its own schema.
    const detection: ?autodetect.Detection = if (spec.autodetect)
        try autodetect.detect(arena, texts, spec.skip_leading_rows)
    else
        null;
    const data_start: usize = if (detection) |d|
        d.data_start
    else if (spec.skip_leading_rows) |n| n else 0;

    const columns = (try declaredColumns(arena, spec, existing)) orelse blk: {
        const d = detection orelse return error.NoSchema;
        const out = try arena.alloc(Column, d.columns.len);
        for (d.columns, out) |detected, *column| {
            column.* = .{
                .name = detected.name,
                .type_name = detected.kind.legacyTypeName(),
            };
        }
        break :blk out;
    };

    const schema_node = try schemaNodeFrom(arena, columns);

    var rows = std.json.Array.init(arena);
    var bad: u64 = 0;
    const data = if (data_start < parsed.len) parsed[data_start..] else &.{};
    for (data) |row| {
        // A row with fewer fields than the schema is short; with more it is long. Each is a
        // bad record unless the job asked for it to be tolerated.
        if (row.len < columns.len and !spec.allow_jagged_rows) {
            bad += 1;
            continue;
        }
        if (row.len > columns.len and !spec.ignore_unknown_values) {
            bad += 1;
            continue;
        }
        var object: std.json.ObjectMap = .empty;
        var row_ok = true;
        for (columns, 0..) |column, i| {
            const cell: ?csv.Field = if (i < row.len) row[i] else null;
            const value = (try cellValue(arena, cell, column, spec)) orelse {
                row_ok = false;
                break;
            };
            try object.put(arena, column.name, value);
        }
        if (!row_ok) {
            bad += 1;
            continue;
        }
        try rows.append(.{ .object = object });
    }

    return .{
        .schema_node = schema_node,
        .schema_fields = fieldsOf(schema_node),
        .rows = rows.items,
        .bad_records = bad,
    };
}

/// One cell as the JSON the content store expects, or null when it does not fit its column.
fn cellValue(
    arena: std.mem.Allocator,
    cell: ?csv.Field,
    column: Column,
    spec: load_handler.LoadSpec,
) !?std.json.Value {
    const field = cell orelse return .null;
    // A bare field equal to the null marker is null; a quoted one is that text.
    if (!field.quoted and std.mem.eql(u8, field.text, spec.null_marker)) return .null;
    const text = field.text;

    if (std.mem.eql(u8, column.type_name, "INTEGER")) {
        const n = std.fmt.parseInt(i64, text, 10) catch return null;
        return .{ .integer = n };
    }
    if (std.mem.eql(u8, column.type_name, "FLOAT")) {
        const f = std.fmt.parseFloat(f64, text) catch return null;
        return .{ .float = f };
    }
    if (std.mem.eql(u8, column.type_name, "BOOLEAN")) {
        const truths = [_][]const u8{ "true", "t", "yes", "y" };
        const falsehoods = [_][]const u8{ "false", "f", "no", "n" };
        for (truths) |word| {
            if (std.ascii.eqlIgnoreCase(text, word)) return .{ .bool = true };
        }
        for (falsehoods) |word| {
            if (std.ascii.eqlIgnoreCase(text, word)) return .{ .bool = false };
        }
        return null;
    }
    if (std.mem.eql(u8, column.type_name, "DATE")) {
        return .{ .string = try autodetect.normalizeDate(arena, text) };
    }
    // TIME, TIMESTAMP and STRING all reach the engine as text, which casts them.
    return .{ .string = text };
}

fn readJson(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
    existing: ?*const spec_mod.TableSpec,
) Error!Reading {
    var objects = std.json.Array.init(arena);
    var bad: u64 = 0;
    var lines = std.mem.splitScalar(u8, media, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const value = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch {
            bad += 1;
            continue;
        };
        if (value != .object) return error.NotAnObject;
        var it = value.object.iterator();
        while (it.next()) |entry| {
            // Flat objects only: a nested object or an array would have to become a RECORD or
            // a repeated column.
            switch (entry.value_ptr.*) {
                .object, .array => return error.NestedJson,
                else => {},
            }
        }
        try objects.append(value);
    }

    const columns = (try declaredColumns(arena, spec, existing)) orelse blk: {
        if (!spec.autodetect) return error.NoSchema;
        break :blk try jsonColumns(arena, objects.items);
    };

    const schema_node = try schemaNodeFrom(arena, columns);
    return .{
        .schema_node = schema_node,
        .schema_fields = fieldsOf(schema_node),
        .rows = objects.items,
        .bad_records = bad,
    };
}

/// Column names in the order they first appear, typed from the values under them.
fn jsonColumns(arena: std.mem.Allocator, rows: []const std.json.Value) ![]const Column {
    var names: std.ArrayList([]const u8) = .empty;
    var kinds: std.ArrayList(autodetect.Kind) = .empty;
    for (rows) |row| {
        var it = row.object.iterator();
        while (it.next()) |entry| {
            const kind = jsonKind(entry.value_ptr.*);
            const at = indexOfName(names.items, entry.key_ptr.*) orelse {
                try names.append(arena, entry.key_ptr.*);
                try kinds.append(arena, kind);
                continue;
            };
            kinds.items[at] = autodetect.merge(kinds.items[at], kind);
        }
    }
    const out = try arena.alloc(Column, names.items.len);
    for (out, names.items, kinds.items) |*column, name, kind| {
        column.* = .{ .name = name, .type_name = kind.legacyTypeName() };
    }
    return out;
}

fn indexOfName(names: []const []const u8, name: []const u8) ?usize {
    for (names, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return i;
    }
    return null;
}

fn jsonKind(value: std.json.Value) autodetect.Kind {
    return switch (value) {
        .null => .unknown,
        .bool => .boolean,
        .integer, .number_string => .integer,
        .float => .float,
        // A string is read for a date or a number the way a CSV cell is. schema-detect
        .string => |text| autodetect.inferValue(text),
        else => .string,
    };
}

const testing = std.testing;

fn readFrom(
    arena: std.mem.Allocator,
    media: []const u8,
    spec: load_handler.LoadSpec,
) !Reading {
    return read(arena, media, spec, null);
}

fn columnTypes(arena: std.mem.Allocator, reading: Reading) ![]const []const u8 {
    const fields = reading.schema_fields;
    const out = try arena.alloc([]const u8, fields.len);
    for (fields, out) |field, *dst| dst.* = field.object.get("type").?.string;
    return out;
}

test "a detected CSV yields its columns and rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reading = try readFrom(arena, "name,age\nAlice,30\nBob,25\n", .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    });
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "STRING", "INTEGER" }),
        try columnTypes(arena, reading),
    );
    try testing.expectEqual(@as(usize, 2), reading.rows.len);
    try testing.expectEqualStrings("Alice", reading.rows[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), reading.rows[0].object.get("age").?.integer);
}

test "an empty cell is null, a quoted empty cell is a string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reading = try readFrom(arena, "a,b\nx,\ny,\"\"\n", .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    });
    try testing.expectEqual(std.json.Value.null, reading.rows[0].object.get("b").?);
    try testing.expectEqualStrings("", reading.rows[1].object.get("b").?.string);
}

test "a short row is bad unless the job allows jagged rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const strict = try readFrom(arena, "a,b\n1,2\n3\n", .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    });
    try testing.expectEqual(@as(u64, 1), strict.bad_records);
    try testing.expectEqual(@as(usize, 1), strict.rows.len);

    const lenient = try readFrom(arena, "a,b\n1,2\n3\n", .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
        .allow_jagged_rows = true,
    });
    try testing.expectEqual(@as(u64, 0), lenient.bad_records);
    try testing.expectEqual(@as(usize, 2), lenient.rows.len);
}

test "a value that does not fit its column is a bad record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var int_field = pb.TableFieldSchema{ .name = "a", .type = "INTEGER" };
    var fields = [_]*pb.TableFieldSchema{&int_field};
    const schema = pb.TableSchema{ .fields = &fields };

    const reading = try readFrom(arena, "1\nnot a number\n3\n", .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .schema = &schema,
        .skip_leading_rows = 0,
    });
    try testing.expectEqual(@as(u64, 1), reading.bad_records);
    try testing.expectEqual(@as(usize, 2), reading.rows.len);
}

test "newline-delimited JSON takes its columns from the values" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const reading = try readFrom(arena,
        \\{"name":"Alice","id":12}
        \\{"name":"Bob","id":13}
        \\
    , .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .source_format = .NEWLINE_DELIMITED_JSON,
        .autodetect = true,
    });
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "STRING", "INTEGER" }),
        try columnTypes(arena, reading),
    );
    try testing.expectEqual(@as(usize, 2), reading.rows.len);
}

test "a nested JSON value is refused rather than half read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.NestedJson, readFrom(arena,
        \\{"a":{"b":1}}
        \\
    , .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .source_format = .NEWLINE_DELIMITED_JSON,
        .autodetect = true,
    }));
}

test "a load that names no schema at all cannot proceed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectError(error.NoSchema, readFrom(arena, "1,2\n", .{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
    }));
}
