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
    columns: []const Column,
    /// The rows as they were read, turned into objects a batch at a time by `Batcher`.
    source: Source,
    /// Records rejected before any row was built.
    bad_records: u64,

    pub fn rowCount(r: Reading) usize {
        return switch (r.source) {
            .csv => |rows| rows.len,
            .json => |rows| rows.len,
        };
    }
};

/// Rows in the shape their format produced. A CSV row is cells to be named and typed; a JSON
/// line is already the object the content store takes.
pub const Source = union(enum) {
    csv: []const csv.Row,
    json: []const std.json.Value,
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
    if (spec.schema) |schema| return try schemaColumns(arena, schema);
    if (existing) |table| return try tableColumns(arena, table);
    return null;
}

fn schemaColumns(arena: std.mem.Allocator, schema: *const pb.TableSchema) ![]const Column {
    const out = try arena.alloc(Column, schema.fields.len);
    for (schema.fields, out) |field, *column| {
        column.* = .{
            .name = field.name orelse "",
            .type_name = field.type orelse "STRING",
        };
    }
    return out;
}

fn tableColumns(arena: std.mem.Allocator, table: *const spec_mod.TableSpec) ![]const Column {
    const out = try arena.alloc(Column, table.columns.len);
    for (table.columns, out) |source, *column| {
        column.* = .{
            .name = source.name,
            .type_name = schema_mod.legacyTypeName(source.type.typeKind()),
        };
    }
    return out;
}

fn detectedColumns(arena: std.mem.Allocator, detection: autodetect.Detection) ![]const Column {
    const out = try arena.alloc(Column, detection.columns.len);
    for (detection.columns, out) |detected, *column| {
        column.* = .{
            .name = detected.name,
            .type_name = detected.kind.legacyTypeName(),
        };
    }
    return out;
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

/// The cells of only the rows detection reads: it samples, so copying the cells of a whole file
/// to hand it the first few hundred would cost more than the detection.
fn sampleTexts(
    arena: std.mem.Allocator,
    parsed: []const csv.Row,
    spec: load_handler.LoadSpec,
) ![]const []const []const u8 {
    const examined = @min(
        parsed.len,
        (spec.skip_leading_rows orelse 0) + autodetect.sample_rows + 1,
    );
    const texts = try arena.alloc([]const []const u8, examined);
    for (parsed[0..examined], texts) |row, *dst| {
        const cells = try arena.alloc([]const u8, row.len);
        for (row, cells) |field, *cell| cell.* = field.text;
        dst.* = cells;
    }
    return texts;
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

    // Autodetect decides where the data starts even when the job supplied its own schema.
    const detection: ?autodetect.Detection = if (spec.autodetect)
        try autodetect.detect(arena, try sampleTexts(arena, parsed, spec), spec.skip_leading_rows)
    else
        null;
    const data_start: usize = if (detection) |d|
        d.data_start
    else if (spec.skip_leading_rows) |n| n else 0;

    const columns = (try declaredColumns(arena, spec, existing)) orelse
        try detectedColumns(arena, detection orelse return error.NoSchema);

    const schema_node = try schemaNodeFrom(arena, columns);
    const data = if (data_start < parsed.len) parsed[data_start..] else &.{};

    return .{
        .schema_node = schema_node,
        .schema_fields = fieldsOf(schema_node),
        .columns = columns,
        .source = .{ .csv = data },
        .bad_records = 0,
    };
}

/// Rows per call to the content store. Large enough that the per-call overhead disappears,
/// small enough that the objects held at once do not scale with the file.
pub const batch_size = 4096;

/// Hands out one batch of rows at a time, reusing the objects it built for the last one.
///
/// A row is a `std.json.ObjectMap`, which allocates its own storage: one per row costs several
/// hundred bytes whatever the row holds, and a file's worth of them is what made a load cost
/// tens of times its own size. The maps here are cleared and refilled instead, so a load
/// allocates `batch_size` of them however many rows it carries.
pub const Batcher = struct {
    arena: std.mem.Allocator,
    reading: Reading,
    spec: load_handler.LoadSpec,
    pos: usize = 0,
    /// Rows the engine was never asked to store, because they did not fit their columns.
    bad_records: u64 = 0,
    maps: []std.json.ObjectMap,
    values: []std.json.Value,

    pub fn init(
        arena: std.mem.Allocator,
        reading: Reading,
        spec: load_handler.LoadSpec,
    ) !Batcher {
        const maps = try arena.alloc(std.json.ObjectMap, batch_size);
        // `alloc` hands back uninitialised memory, and a map is cleared before it is filled.
        for (maps) |*map| map.* = .empty;
        return .{
            .arena = arena,
            .reading = reading,
            .spec = spec,
            .maps = maps,
            .values = try arena.alloc(std.json.Value, batch_size),
        };
    }

    /// The next batch, or null when the rows run out. The slice is valid until the next call.
    pub fn next(b: *Batcher) !?[]const std.json.Value {
        switch (b.reading.source) {
            // A JSON line is already the object, so a batch is a window onto what was parsed.
            .json => |rows| {
                if (b.pos >= rows.len) return null;
                const end = @min(b.pos + batch_size, rows.len);
                const batch = rows[b.pos..end];
                b.pos = end;
                return batch;
            },
            .csv => |rows| return b.nextCsv(rows),
        }
    }

    fn nextCsv(b: *Batcher, rows: []const csv.Row) !?[]const std.json.Value {
        var built: usize = 0;
        while (b.pos < rows.len and built < batch_size) : (b.pos += 1) {
            if (!try b.build(rows[b.pos], &b.maps[built])) continue;
            b.values[built] = .{ .object = b.maps[built] };
            built += 1;
        }
        return if (built == 0) null else b.values[0..built];
    }

    /// Fills one pooled map from one CSV row. False when the row is a bad record.
    fn build(b: *Batcher, row: csv.Row, into: *std.json.ObjectMap) !bool {
        const columns = b.reading.columns;
        // A row with fewer fields than the schema is short; with more it is long. Each is a
        // bad record unless the job asked for it to be tolerated.
        if (row.len < columns.len and !b.spec.allow_jagged_rows) {
            b.bad_records += 1;
            return false;
        }
        if (row.len > columns.len and !b.spec.ignore_unknown_values) {
            b.bad_records += 1;
            return false;
        }

        into.clearRetainingCapacity();
        // Sized once rather than grown a column at a time. The map reallocates without ever
        // trying to extend in place, so each growth step abandons its previous buffer in the
        // arena, and a map crossing eight entries also allocates a hash index mid-loop.
        try into.ensureTotalCapacity(b.arena, columns.len);
        for (columns, 0..) |column, i| {
            const cell: ?csv.Field = if (i < row.len) row[i] else null;
            const value = (try cellValue(b.arena, cell, column, b.spec)) orelse {
                b.bad_records += 1;
                return false;
            };
            try into.put(b.arena, column.name, value);
        }
        return true;
    }
};

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
        return .{ .bool = parseBool(text) orelse return null };
    }
    if (std.mem.eql(u8, column.type_name, "DATE")) {
        return .{ .string = try autodetect.normalizeDate(arena, text) };
    }
    // TIME, TIMESTAMP and STRING all reach the engine as text, which casts them.
    return .{ .string = text };
}

fn parseBool(text: []const u8) ?bool {
    const truths = [_][]const u8{ "true", "t", "yes", "y" };
    const falsehoods = [_][]const u8{ "false", "f", "no", "n" };
    for (truths) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return true;
    }
    for (falsehoods) |word| {
        if (std.ascii.eqlIgnoreCase(text, word)) return false;
    }
    return null;
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
        try requireFlat(value.object);
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
        .columns = columns,
        .source = .{ .json = objects.items },
        .bad_records = bad,
    };
}

/// Flat objects only: a nested object or an array would have to become a RECORD or a repeated
/// column.
fn requireFlat(object: std.json.ObjectMap) Error!void {
    for (object.values()) |value| {
        switch (value) {
            .object, .array => return error.NestedJson,
            else => {},
        }
    }
}

const SeenColumn = struct {
    name: []const u8,
    kind: autodetect.Kind,
};

/// Column names in the order they first appear, typed from the values under them.
fn jsonColumns(arena: std.mem.Allocator, rows: []const std.json.Value) ![]const Column {
    var seen: std.ArrayList(SeenColumn) = .empty;
    for (rows) |row| {
        var it = row.object.iterator();
        while (it.next()) |entry| {
            try noteColumn(arena, &seen, entry.key_ptr.*, jsonKind(entry.value_ptr.*));
        }
    }
    const out = try arena.alloc(Column, seen.items.len);
    for (out, seen.items) |*column, s| {
        column.* = .{ .name = s.name, .type_name = s.kind.legacyTypeName() };
    }
    return out;
}

/// Widens a column already seen to take `kind`, or adds it after the others.
fn noteColumn(
    arena: std.mem.Allocator,
    seen: *std.ArrayList(SeenColumn),
    name: []const u8,
    kind: autodetect.Kind,
) !void {
    for (seen.items) |*column| {
        if (!std.mem.eql(u8, column.name, name)) continue;
        column.kind = autodetect.merge(column.kind, kind);
        return;
    }
    try seen.append(arena, .{ .name = name, .kind = kind });
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

/// Every row the batcher yields, gathered so a test can look at them all at once. A deep copy,
/// because the batcher reuses its objects between batches.
const Collected = struct {
    rows: []const std.json.Value,
    bad_records: u64,
};

fn collect(
    arena: std.mem.Allocator,
    reading: Reading,
    spec: load_handler.LoadSpec,
) !Collected {
    var batcher = try Batcher.init(arena, reading, spec);
    var out = std.json.Array.init(arena);
    while (try batcher.next()) |batch| {
        for (batch) |row| try out.append(.{ .object = try row.object.clone(arena) });
    }
    return .{ .rows = out.items, .bad_records = reading.bad_records + batcher.bad_records };
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

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };
    const reading = try readFrom(arena, "name,age\nAlice,30\nBob,25\n", spec);
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "STRING", "INTEGER" }),
        try columnTypes(arena, reading),
    );
    const got = try collect(arena, reading, spec);
    try testing.expectEqual(@as(usize, 2), got.rows.len);
    try testing.expectEqualStrings("Alice", got.rows[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), got.rows[0].object.get("age").?.integer);
}

test "an empty cell is null, a quoted empty cell is a string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };
    const reading = try readFrom(arena, "a,b\nx,\ny,\"\"\n", spec);
    const got = try collect(arena, reading, spec);
    try testing.expectEqual(std.json.Value.null, got.rows[0].object.get("b").?);
    try testing.expectEqualStrings("", got.rows[1].object.get("b").?.string);
}

test "a short row is bad unless the job allows jagged rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const strict_spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
    };
    const strict = try readFrom(arena, "a,b\n1,2\n3\n", strict_spec);
    const strict_rows = try collect(arena, strict, strict_spec);
    try testing.expectEqual(@as(u64, 1), strict_rows.bad_records);
    try testing.expectEqual(@as(usize, 1), strict_rows.rows.len);

    const lenient_spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .autodetect = true,
        .allow_jagged_rows = true,
    };
    const lenient = try readFrom(arena, "a,b\n1,2\n3\n", lenient_spec);
    const lenient_rows = try collect(arena, lenient, lenient_spec);
    try testing.expectEqual(@as(u64, 0), lenient_rows.bad_records);
    try testing.expectEqual(@as(usize, 2), lenient_rows.rows.len);
}

test "a value that does not fit its column is a bad record" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var int_field = pb.TableFieldSchema{ .name = "a", .type = "INTEGER" };
    var fields = [_]*pb.TableFieldSchema{&int_field};
    const schema = pb.TableSchema{ .fields = &fields };

    const spec = load_handler.LoadSpec{
        .destination = .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        .schema = &schema,
        .skip_leading_rows = 0,
    };
    const reading = try readFrom(arena, "1\nnot a number\n3\n", spec);
    const got = try collect(arena, reading, spec);
    try testing.expectEqual(@as(u64, 1), got.bad_records);
    try testing.expectEqual(@as(usize, 2), got.rows.len);
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
    try testing.expectEqual(@as(usize, 2), reading.rowCount());
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

test "every read error has a message of its own" {
    const names = @typeInfo(Error).error_set.error_names.?;
    inline for (names, 0..) |a, i| {
        const message = readErrorMessage(@field(Error, a));
        try testing.expect(message.len > 0);
        inline for (names[i + 1 ..]) |b| {
            try testing.expect(!std.mem.eql(u8, message, readErrorMessage(@field(Error, b))));
        }
    }
}
