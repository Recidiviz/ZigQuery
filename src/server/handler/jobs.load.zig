//! Load jobs: the `configuration.load` half of jobs.insert.
//!
//! A load job reads rows out of bytes the client uploaded and writes them into one destination
//! table. Its configuration and its data arrive together, so everything that can be settled
//! without writing a row is settled before a job exists. docs/adr/0002

const std = @import("std");
const pb = @import("../proto/bigquery.zig");

/// The formats this emulator reads. The member names are the wire values.
/// rest/v2/Job#jobconfigurationload
pub const SourceFormat = enum {
    /// What an absent field means.
    CSV,
    NEWLINE_DELIMITED_JSON,
};

/// What a job does when its destination already exists. Load's default differs from copy's.
/// rest/v2/Job#jobconfigurationload
pub const WriteDisposition = enum {
    WRITE_TRUNCATE,
    /// What an absent field means.
    WRITE_APPEND,
    WRITE_EMPTY,
};

pub const CreateDisposition = enum {
    /// What an absent field means.
    CREATE_IF_NEEDED,
    CREATE_NEVER,
};

pub const TableRef = struct {
    project_id: []const u8,
    dataset_id: []const u8,
    table_id: []const u8,

    pub fn display(self: TableRef, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}:{s}.{s}", .{
            self.project_id, self.dataset_id, self.table_id,
        });
    }
};

/// What a load job was asked to do, once the wire form has been normalised.
pub const LoadSpec = struct {
    destination: TableRef,
    source_format: SourceFormat = .CSV,
    write_disposition: WriteDisposition = .WRITE_APPEND,
    create_disposition: CreateDisposition = .CREATE_IF_NEEDED,
    autodetect: bool = false,
    /// Absent and zero are different requests, so the absence is kept.
    /// rest/v2/Job#jobconfigurationload
    skip_leading_rows: ?u32 = null,
    max_bad_records: u32 = 0,
    allow_jagged_rows: bool = false,
    allow_quoted_newlines: bool = false,
    ignore_unknown_values: bool = false,
    field_delimiter: u8 = ',',
    /// Null when the job asked for no quote character.
    quote: ?u8 = '"',
    /// The string a value must equal to be null. Empty by default, which makes an empty field
    /// null. rest/v2/Job#jobconfigurationload
    null_marker: []const u8 = "",
    /// `configuration.load.schema`, as the client sent it.
    schema: ?*const pb.TableSchema = null,

    pub fn mayCreateDestination(self: LoadSpec) bool {
        return self.create_disposition != .CREATE_NEVER;
    }

    pub fn refusesOccupiedDestination(self: LoadSpec) bool {
        return self.write_disposition == .WRITE_EMPTY;
    }

    pub fn replacesDestination(self: LoadSpec) bool {
        return self.write_disposition == .WRITE_TRUNCATE;
    }
};

/// A request that never becomes a job, answered with an HTTP status. docs/adr/0002
pub const ParseError = error{
    NoDestinationTable,
    IncompleteTableReference,
    UnsupportedSourceFormat,
    InvalidWriteDisposition,
    InvalidCreateDisposition,
    /// A delimiter or quote that is not one byte.
    InvalidDelimiter,
    InvalidQuote,
    /// `sourceUris` names data this emulator has nowhere to read from.
    SourceUrisUnsupported,
    /// WRITE_TRUNCATE_DATA, or a schema update option. Each changes an existing table's
    /// schema as a side effect.
    UnsupportedDisposition,
    SchemaUpdateUnsupported,
    OutOfMemory,
};

pub fn loadConfig(job: *const pb.Job) ?*const pb.JobConfigurationLoad {
    const cfg = job.configuration orelse return null;
    return cfg.load;
}

fn refFrom(t: *const pb.TableReference) ParseError!TableRef {
    return .{
        .project_id = t.project_id orelse return error.IncompleteTableReference,
        .dataset_id = t.dataset_id orelse return error.IncompleteTableReference,
        .table_id = t.table_id orelse return error.IncompleteTableReference,
    };
}

fn oneByte(text: []const u8) ?u8 {
    return if (text.len == 1) text[0] else null;
}

/// Normalises `configuration.load`. Null when the job is not a load job.
pub fn parse(job: *const pb.Job) ParseError!?LoadSpec {
    const cfg = loadConfig(job) orelse return null;
    if (cfg.source_uris.len != 0) return error.SourceUrisUnsupported;
    if (cfg.schema_update_options.len != 0) return error.SchemaUpdateUnsupported;

    const dest = cfg.destination_table orelse return error.NoDestinationTable;

    var spec = LoadSpec{ .destination = try refFrom(dest), .schema = cfg.schema };
    try readDispositions(cfg, &spec);
    readRowOptions(cfg, &spec);
    try readCsvSyntax(cfg, &spec);
    return spec;
}

/// The source format, and what the job does with its destination.
fn readDispositions(cfg: *const pb.JobConfigurationLoad, spec: *LoadSpec) ParseError!void {
    if (cfg.source_format) |text| {
        spec.source_format = std.meta.stringToEnum(SourceFormat, text) orelse
            return error.UnsupportedSourceFormat;
    }
    if (cfg.write_disposition) |text| {
        if (std.mem.eql(u8, text, "WRITE_TRUNCATE_DATA")) return error.UnsupportedDisposition;
        spec.write_disposition = std.meta.stringToEnum(WriteDisposition, text) orelse
            return error.InvalidWriteDisposition;
    }
    if (cfg.create_disposition) |text| {
        spec.create_disposition = std.meta.stringToEnum(CreateDisposition, text) orelse
            return error.InvalidCreateDisposition;
    }
}

/// Which rows are read, and how many may be bad.
fn readRowOptions(cfg: *const pb.JobConfigurationLoad, spec: *LoadSpec) void {
    if (cfg.autodetect) |v| spec.autodetect = v.value orelse false;
    if (cfg.skip_leading_rows) |v| {
        if (v.value) |n| spec.skip_leading_rows = @intCast(@max(n, 0));
    }
    if (cfg.max_bad_records) |v| {
        if (v.value) |n| spec.max_bad_records = @intCast(@max(n, 0));
    }
    if (cfg.allow_jagged_rows) |v| spec.allow_jagged_rows = v.value orelse false;
    if (cfg.allow_quoted_newlines) |v| spec.allow_quoted_newlines = v.value orelse false;
    if (cfg.ignore_unknown_values) |v| spec.ignore_unknown_values = v.value orelse false;
}

/// The delimiter, quote and null marker a CSV is read with.
fn readCsvSyntax(cfg: *const pb.JobConfigurationLoad, spec: *LoadSpec) ParseError!void {
    if (cfg.field_delimiter) |text| {
        spec.field_delimiter = oneByte(text) orelse return error.InvalidDelimiter;
    }
    if (cfg.quote) |v| {
        if (v.value) |text| {
            // An empty string asks for no quoting. rest/v2/Job#jobconfigurationload
            spec.quote = if (text.len == 0) null else oneByte(text) orelse
                return error.InvalidQuote;
        }
    }
    if (cfg.null_marker) |v| {
        if (v.value) |text| spec.null_marker = text;
    }
}

/// What the client is told about a configuration that never became a job.
pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.NoDestinationTable => "configuration.load.destinationTable is required",
        error.IncompleteTableReference => "configuration.load: a table reference needs " ++
            "projectId, datasetId and tableId",
        error.UnsupportedSourceFormat => "configuration.load.sourceFormat must be CSV or " ++
            "NEWLINE_DELIMITED_JSON",
        error.InvalidWriteDisposition => "configuration.load.writeDisposition must be " ++
            "WRITE_TRUNCATE, WRITE_APPEND or WRITE_EMPTY",
        error.InvalidCreateDisposition => "configuration.load.createDisposition must be " ++
            "CREATE_IF_NEEDED or CREATE_NEVER",
        error.InvalidDelimiter => "configuration.load.fieldDelimiter must be one byte",
        error.InvalidQuote => "configuration.load.quote must be one byte, or empty for none",
        error.SourceUrisUnsupported => "configuration.load.sourceUris is not supported: " ++
            "upload the data instead",
        error.UnsupportedDisposition => "configuration.load.writeDisposition: " ++
            "WRITE_TRUNCATE_DATA is not supported",
        error.SchemaUpdateUnsupported => "configuration.load.schemaUpdateOptions is not " ++
            "supported",
        error.OutOfMemory => "out of memory",
    };
}

// ---- the job resource ----

/// What a load job counts while it runs. rest/v2/Job#jobstatistics3
pub const Counts = struct {
    input_file_bytes: u64 = 0,
    output_rows: u64 = 0,
    bad_records: u64 = 0,
};

pub const Outcome = union(enum) {
    loaded: Counts,
    failed: Failure,

    pub const Failure = struct { reason: []const u8, message: []const u8 };
};

pub const JobResource = struct {
    project_id: []const u8,
    job_id: []const u8,
    endpoint: []const u8,
    unix_seconds: i64,
    load: LoadSpec,
    outcome: Outcome,
};

/// Serializes a bigquery#job resource for a load job.
///
/// `outputBytes` is absent: it measures BigQuery's own storage format, which has no analogue
/// here.
pub fn writeJobResource(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    j: JobResource,
) !void {
    var dest = pb.TableReference{
        .project_id = j.load.destination.project_id,
        .dataset_id = j.load.destination.dataset_id,
        .table_id = j.load.destination.table_id,
    };
    var cfg_load = pb.JobConfigurationLoad{
        .destination_table = &dest,
        .source_format = @tagName(j.load.source_format),
        .write_disposition = @tagName(j.load.write_disposition),
        .create_disposition = @tagName(j.load.create_disposition),
    };
    var cfg = pb.JobConfiguration{ .job_type = "LOAD", .load = &cfg_load };
    var job_ref = pb.JobReference{ .project_id = j.project_id, .job_id = j.job_id };

    var input_files = pb.Int64Value{ .value = 1 };
    var input_bytes = pb.Int64Value{ .value = 0 };
    var output_rows = pb.Int64Value{ .value = 0 };
    var bad_records = pb.Int64Value{ .value = 0 };
    var stats_load = pb.JobStatistics3{};
    switch (j.outcome) {
        .loaded => |counts| {
            input_bytes.value = @intCast(counts.input_file_bytes);
            output_rows.value = @intCast(counts.output_rows);
            bad_records.value = @intCast(counts.bad_records);
            stats_load = .{
                .input_files = &input_files,
                .input_file_bytes = &input_bytes,
                .output_rows = &output_rows,
                .bad_records = &bad_records,
            };
        },
        .failed => {},
    }
    var stats = pb.JobStatistics{
        .creation_time = j.unix_seconds,
        .start_time = j.unix_seconds,
        .end_time = j.unix_seconds,
        .load = switch (j.outcome) {
            .loaded => &stats_load,
            .failed => null,
        },
    };

    var err_proto = pb.ErrorProto{};
    var err_list = [_]*pb.ErrorProto{&err_proto};
    var status = pb.JobStatus{ .state = "DONE" };
    switch (j.outcome) {
        .loaded => {},
        .failed => |failure| {
            err_proto = .{ .reason = failure.reason, .message = failure.message };
            status.error_result = &err_proto;
            status.errors = &err_list;
        },
    }

    const job = pb.Job{
        .kind = "bigquery#job",
        .self_link = try std.fmt.allocPrint(
            arena,
            "http://{s}/bigquery/v2/projects/{s}/jobs/{s}",
            .{ j.endpoint, j.project_id, j.job_id },
        ),
        .configuration = &cfg,
        .job_reference = &job_ref,
        .statistics = &stats,
        .status = &status,
    };
    try out.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, job, .{}));
}

const testing = std.testing;

fn loadJob(arena: std.mem.Allocator, body: []const u8) !*pb.Job {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return pb.Job.jsonDecode(arena, parsed, .{});
}

test "a job with no load configuration is not a load job" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const job = try loadJob(arena, "{\"configuration\":{\"query\":{\"query\":\"SELECT 1\"}}}");
    try testing.expect(try parse(job) == null);
}

test "the documented defaults, which differ from a copy job's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const job = try loadJob(arena,
        \\{"configuration":{"load":{
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    const spec = (try parse(job)).?;
    try testing.expectEqual(SourceFormat.CSV, spec.source_format);
    try testing.expectEqual(WriteDisposition.WRITE_APPEND, spec.write_disposition);
    try testing.expectEqual(CreateDisposition.CREATE_IF_NEEDED, spec.create_disposition);
    try testing.expectEqual(@as(u32, 0), spec.max_bad_records);
    try testing.expectEqual(@as(u8, ','), spec.field_delimiter);
    try testing.expectEqual(@as(?u8, '"'), spec.quote);
    try testing.expect(!spec.autodetect);
}

test "an absent skipLeadingRows is not a zero" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const absent = try loadJob(arena,
        \\{"configuration":{"load":{
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    try testing.expectEqual(@as(?u32, null), (try parse(absent)).?.skip_leading_rows);

    const zero = try loadJob(arena,
        \\{"configuration":{"load":{"skipLeadingRows":0,
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    try testing.expectEqual(@as(?u32, 0), (try parse(zero)).?.skip_leading_rows);
}

test "a format this emulator cannot read is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const job = try loadJob(arena,
        \\{"configuration":{"load":{"sourceFormat":"PARQUET",
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    try testing.expectError(error.UnsupportedSourceFormat, parse(job));
}

test "sourceUris names data there is nowhere to read from" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const job = try loadJob(arena,
        \\{"configuration":{"load":{"sourceUris":["gs://bucket/object.csv"],
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    try testing.expectError(error.SourceUrisUnsupported, parse(job));
}

test "the dispositions that change an existing table's schema are refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const truncate_data = try loadJob(arena,
        \\{"configuration":{"load":{"writeDisposition":"WRITE_TRUNCATE_DATA",
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    try testing.expectError(error.UnsupportedDisposition, parse(truncate_data));

    const update = try loadJob(arena,
        \\{"configuration":{"load":{"schemaUpdateOptions":["ALLOW_FIELD_ADDITION"],
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    try testing.expectError(error.SchemaUpdateUnsupported, parse(update));
}

test "only WRITE_TRUNCATE replaces the destination's rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const truncate = try loadJob(arena,
        \\{"configuration":{"load":{"writeDisposition":"WRITE_TRUNCATE",
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    const truncate_spec = (try parse(truncate)).?;
    try testing.expect(truncate_spec.replacesDestination());
    try testing.expect(!truncate_spec.refusesOccupiedDestination());

    const absent = try loadJob(arena,
        \\{"configuration":{"load":{
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    const absent_spec = (try parse(absent)).?;
    try testing.expect(!absent_spec.replacesDestination());
    try testing.expect(!absent_spec.refusesOccupiedDestination());

    const empty = try loadJob(arena,
        \\{"configuration":{"load":{"writeDisposition":"WRITE_EMPTY",
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    const empty_spec = (try parse(empty)).?;
    try testing.expect(!empty_spec.replacesDestination());
    try testing.expect(empty_spec.refusesOccupiedDestination());
}

test "an empty quote asks for no quoting" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const job = try loadJob(arena,
        \\{"configuration":{"load":{"quote":"",
        \\ "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    );
    try testing.expectEqual(@as(?u8, null), (try parse(job)).?.quote);
}

test "a successful load reports what it read and wrote" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeJobResource(arena, &out, .{
        .project_id = "p",
        .job_id = "j",
        .endpoint = "localhost:9050",
        .unix_seconds = 0,
        .load = .{ .destination = .{
            .project_id = "p",
            .dataset_id = "d",
            .table_id = "t",
        } },
        .outcome = .{ .loaded = .{
            .input_file_bytes = 59,
            .output_rows = 2,
            .bad_records = 0,
        } },
    });

    try testing.expect(std.mem.indexOf(u8, out.items, "\"jobType\":\"LOAD\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"inputFiles\":\"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"inputFileBytes\":\"59\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"outputRows\":\"2\"") != null);
    // outputBytes measures a storage format this emulator does not have.
    try testing.expect(std.mem.indexOf(u8, out.items, "outputBytes") == null);
}

test "a failed load carries errorResult and no statistics" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeJobResource(arena, &out, .{
        .project_id = "p",
        .job_id = "j",
        .endpoint = "localhost:9050",
        .unix_seconds = 0,
        .load = .{ .destination = .{
            .project_id = "p",
            .dataset_id = "d",
            .table_id = "t",
        } },
        .outcome = .{ .failed = .{
            .reason = "invalid",
            .message = "too many bad records",
        } },
    });

    try testing.expect(std.mem.indexOf(u8, out.items, "\"reason\":\"invalid\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"state\":\"DONE\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "inputFiles") == null);
}
