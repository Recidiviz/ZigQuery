//! Port of bigquery-emulator server/handler.go jobsInsertHandler and
//! jobsGetHandler.
//!
//! This is the path the Google client libraries actually take:
//! `Client.query()` issues jobs.insert, polls jobs.get until
//! status.state == "DONE", then reads getQueryResults. The jobs.query
//! endpoint is a separate, newer shortcut most clients do not use by default.
//!
//! Go runs the query synchronously inside jobs.insert and stores the result,
//! so the job is already DONE when it is returned; the same is done here.
//!
//! Key order in the emitted JSON is alphabetical, matching what
//! google-api-go-client's structs produce. Shapes were captured from a
//! running Go emulator.

const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const job_rows_vtab = zigquery.function.job_rows_vtab;
const queryparam = @import("../internal/types/queryparam.zig");
const json_pb = @import("../json_pb.zig");
const pb = @import("../proto/bigquery.zig");
const response = @import("../internal/types/response.zig");

/// Decodes a jobs.insert body. `google.api.http` names the body `job`
/// (job.proto JobService.InsertJob), so the resource is the whole body.
pub fn parseInsert(arena: std.mem.Allocator, body: []const u8) !*pb.Job {
    const parsed = json_pb.parseBody(arena, body) catch return error.InvalidRequest;
    return pb.Job.jsonDecode(arena, parsed, .{}) catch |err| switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.InvalidRequest,
    };
}

fn queryConfig(job: *const pb.Job) ?*const pb.JobConfigurationQuery {
    const cfg = job.configuration orelse return null;
    return cfg.query;
}

/// `configuration.query.query`.
pub fn queryFromJobConfig(job: *const pb.Job) ?[]const u8 {
    const q = queryConfig(job) orelse return null;
    return q.query;
}

/// `configuration.query.queryParameters`, reshaped for the driver.
///
/// Empty when the job carries none. As on jobs.query, `parameterMode` is not
/// read — the driver decides named vs positional from the SQL text.
pub fn parametersFromJobConfig(
    arena: std.mem.Allocator,
    job: *const pb.Job,
) queryparam.Error![]const driver.Param {
    const q = queryConfig(job) orelse return &.{};
    return queryparam.parseTyped(arena, q.query_parameters);
}

pub const JobResource = struct {
    project_id: []const u8,
    job_id: []const u8,
    sql: []const u8,
    endpoint: []const u8,
    /// Go accumulates len() of each rendered cell string.
    total_bytes: usize,
    unix_seconds: i64,
    /// `statistics.query.statementType`, `numDmlAffectedRows` and `dmlStats`.
    outcome: driver.StatementOutcome,
};

/// Serializes a bigquery#job resource.
pub fn writeJobResource(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    j: JobResource,
) !void {
    // One hidden dataset for every anonymous result, not one per job.
    var dest = pb.TableReference{
        .project_id = j.project_id,
        .dataset_id = job_rows_vtab.anon_segment,
        .table_id = j.job_id,
    };
    var use_legacy = pb.BoolValue{ .value = false };
    var cfg_query = pb.JobConfigurationQuery{
        .query = j.sql,
        .destination_table = &dest,
        .priority = "INTERACTIVE",
        .use_legacy_sql = &use_legacy,
    };
    var cfg = pb.JobConfiguration{ .job_type = "QUERY", .query = &cfg_query };
    var job_ref = pb.JobReference{ .project_id = j.project_id, .job_id = j.job_id };
    var bytes = pb.Int64Value{ .value = @intCast(j.total_bytes) };
    var stats_query = pb.JobStatistics2{
        .total_bytes_processed = &bytes,
        .total_bytes_billed = &bytes,
        .num_dml_affected_rows = try response.numDmlAffectedRows(arena, j.outcome),
        .dml_stats = try response.dmlStats(arena, j.outcome),
        .statement_type = j.outcome.statement_type.bigQueryName(),
    };
    var stats = pb.JobStatistics{
        .creation_time = j.unix_seconds,
        .start_time = j.unix_seconds,
        .end_time = j.unix_seconds,
        .total_bytes_processed = &bytes,
        .query = &stats_query,
    };
    var status = pb.JobStatus{ .state = "DONE" };

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

test "extracts the SQL from a client's jobs.insert body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseInsert(arena,
        \\{"configuration":{"query":{"query":"SELECT 1 AS col","useLegacySql":false}}}
    );
    try testing.expectEqualStrings("SELECT 1 AS col", queryFromJobConfig(v).?);
}

test "a body without a query configuration yields null" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "{}",
        \\{"configuration":{}}
        ,
        \\{"configuration":{"copy":{}}}
        ,
        \\{"configuration":{"query":{}}}
    }) |body| {
        const j = try parseInsert(arena, body);
        try testing.expectEqual(@as(?[]const u8, null), queryFromJobConfig(j));
    }
}

test "extracts queryParameters from a jobs.insert body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseInsert(arena,
        \\{"configuration":{"query":{"query":"SELECT @a","useLegacySql":false,
        \\  "parameterMode":"NAMED","queryParameters":[
        \\    {"name":"a","parameterType":{"type":"STRING"},
        \\     "parameterValue":{"value":"x"}}]}}}
    );
    const params = try parametersFromJobConfig(arena, v);
    try testing.expectEqual(@as(usize, 1), params.len);
    try testing.expectEqualStrings("a", params[0].name.?);
    try testing.expectEqualStrings("x", params[0].value.string);
    try testing.expectEqualStrings("STRING", params[0].type_text.?);
}

test "a job with no queryParameters yields none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        "{}",
        \\{"configuration":{"query":{"query":"SELECT 1"}}}
        ,
        \\{"configuration":{"copy":{}}}
    }) |body| {
        const j = try parseInsert(arena, body);
        try testing.expectEqual(@as(usize, 0), (try parametersFromJobConfig(arena, j)).len);
    }
}

test "job resource matches the Go emulator's shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeJobResource(arena, &out, .{
        .project_id = "test",
        .job_id = "JOBID",
        .sql = "SELECT 1 AS col",
        .endpoint = "0.0.0.0:19050",
        .total_bytes = 1,
        .unix_seconds = 1785011395,
        .outcome = .{ .statement_type = .select },
    });

    // Captured from the running Go emulator, with the random id replaced.
    // Compared by value: the resource's keys follow the proto's field order,
    // not the alphabetical order google-api-go-client's structs produced.
    try json_pb.expectJsonEqual(
        \\{"configuration":{"jobType":"QUERY","query":{"destinationTable":{"datasetId":"_anon","projectId":"test","tableId":"JOBID"},"priority":"INTERACTIVE","query":"SELECT 1 AS col","useLegacySql":false}},"jobReference":{"jobId":"JOBID","projectId":"test"},"kind":"bigquery#job","selfLink":"http://0.0.0.0:19050/bigquery/v2/projects/test/jobs/JOBID","statistics":{"creationTime":"1785011395","endTime":"1785011395","query":{"statementType":"SELECT","totalBytesBilled":"1","totalBytesProcessed":"1"},"startTime":"1785011395","totalBytesProcessed":"1"},"status":{"state":"DONE"}}
    , out.items);
}

test "the job resource parses and reports DONE" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeJobResource(arena, &out, .{
        .project_id = "p",
        .job_id = "j",
        .sql = "SELECT 1",
        .endpoint = "h:1",
        .total_bytes = 0,
        .unix_seconds = 0,
        .outcome = .{ .statement_type = .select },
    });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.items, .{});
    try testing.expectEqualStrings("DONE", v.object.get("status").?.object.get("state").?.string);
    try testing.expectEqualStrings("bigquery#job", v.object.get("kind").?.string);
}

test "a DML job reports its statement type, affected rows and DML stats" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const Case = struct { outcome: driver.StatementOutcome, query_stats: []const u8 };
    for ([_]Case{
        .{
            .outcome = .{ .statement_type = .delete, .dml = .{ .deleted = 2 } },
            .query_stats =
            \\{"dmlStats":{"deletedRowCount":"2"},"numDmlAffectedRows":"2",
            \\ "statementType":"DELETE","totalBytesBilled":"0","totalBytesProcessed":"0"}
            ,
        },
        .{
            .outcome = .{ .statement_type = .update, .dml = .{} },
            .query_stats =
            \\{"dmlStats":{"updatedRowCount":"0"},"numDmlAffectedRows":"0",
            \\ "statementType":"UPDATE","totalBytesBilled":"0","totalBytesProcessed":"0"}
            ,
        },
        .{
            .outcome = .{
                .statement_type = .merge,
                .dml = .{ .inserted = 2, .updated = 0, .deleted = 1 },
            },
            .query_stats =
            \\{"dmlStats":{"insertedRowCount":"2","updatedRowCount":"0","deletedRowCount":"1"},
            \\ "numDmlAffectedRows":"3",
            \\ "statementType":"MERGE","totalBytesBilled":"0","totalBytesProcessed":"0"}
            ,
        },
        .{
            .outcome = .{ .statement_type = .create_table_as_select },
            .query_stats =
            \\{"statementType":"CREATE_TABLE_AS_SELECT","totalBytesBilled":"0",
            \\ "totalBytesProcessed":"0"}
            ,
        },
    }) |case| {
        var out: std.ArrayList(u8) = .empty;
        try writeJobResource(arena, &out, .{
            .project_id = "p",
            .job_id = "j",
            .sql = "<statement>",
            .endpoint = "h:1",
            .total_bytes = 0,
            .unix_seconds = 0,
            .outcome = case.outcome,
        });
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.items, .{});
        const query_stats = v.object.get("statistics").?.object.get("query").?;
        try json_pb.expectJsonEqual(
            case.query_stats,
            try std.json.Stringify.valueAlloc(arena, query_stats, .{}),
        );
    }
}

// ---- query jobs that write to a destination table ----
//
// View materialization posts a jobs.insert whose configuration.query carries
// a destinationTable and a writeDisposition. Go runs the query and writes the
// result into that table; without this a materialized view silently produces
// nothing and every downstream view fails to resolve it.

pub const Destination = struct {
    project_id: []const u8,
    dataset_id: []const u8,
    table_id: []const u8,
    /// WRITE_TRUNCATE | WRITE_APPEND | WRITE_EMPTY. Absent means WRITE_EMPTY.
    write_disposition: []const u8 = "WRITE_EMPTY",
};

/// `configuration.query.destinationTable`, when present.
pub fn destinationFromJobConfig(job: *const pb.Job) ?Destination {
    const q = queryConfig(job) orelse return null;
    const dst = q.destination_table orelse return null;
    return .{
        .project_id = dst.project_id orelse return null,
        .dataset_id = dst.dataset_id orelse return null,
        .table_id = dst.table_id orelse return null,
        .write_disposition = q.write_disposition orelse "WRITE_EMPTY",
    };
}

/// The fields of `configuration.query` that shape a table the job creates: `timePartitioning`,
/// `rangePartitioning` and `clustering`, as the client posted them. Raw JSON, because a client
/// compares tables.get with its request field for field and pb.TimePartitioning has no
/// `requirePartitionFilter`. A null (the python client sends one beside `clustering`) asks for
/// nothing.
pub fn destinationLayoutFields(
    arena: std.mem.Allocator,
    body: []const u8,
) std.mem.Allocator.Error!std.json.ObjectMap {
    var out: std.json.ObjectMap = .empty;
    const v = json_pb.parseBody(arena, body) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return out,
    };
    if (v != .object) return out;
    const config = v.object.get("configuration") orelse return out;
    if (config != .object) return out;
    const query = config.object.get("query") orelse return out;
    if (query != .object) return out;
    for ([_][]const u8{ "timePartitioning", "rangePartitioning", "clustering" }) |key| {
        const node = query.object.get(key) orelse continue;
        if (node != .object) continue;
        try out.put(arena, key, node);
    }
    return out;
}

fn strOf(v: std.json.Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    return if (f == .string) f.string else null;
}

/// DDL that appends the query's rows to an existing destination.
pub fn appendDdl(
    arena: std.mem.Allocator,
    dst: Destination,
    sql: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "INSERT INTO `{s}.{s}.{s}` {s}", .{
        dst.project_id, dst.dataset_id, dst.table_id, sql,
    });
}

/// DDL that (re)creates the destination from the query's own shape.
///
/// This is what Go effectively does for every disposition. It never issues an
/// INSERT ... SELECT: it runs the query, derives a table definition from the
/// *result* schema (handler.go tableDefFromQueryResponse), creates the table
/// from that if absent, and writes the rows. So in Go the query defines the
/// destination's shape, and a schema the client declared earlier never
/// constrains it.
pub fn replaceDdl(
    arena: std.mem.Allocator,
    dst: Destination,
    sql: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "CREATE OR REPLACE TABLE `{s}.{s}.{s}` AS {s}", .{
        dst.project_id, dst.dataset_id, dst.table_id, sql,
    });
}

/// True when this disposition appends to whatever is already there.
pub fn isAppend(dst: Destination) bool {
    return std.mem.eql(u8, dst.write_disposition, "WRITE_APPEND");
}

test "reads a destination table and write disposition" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseInsert(arena,
        \\{"configuration":{"query":{"query":"SELECT 1",
        \\  "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"},
        \\  "writeDisposition":"WRITE_TRUNCATE"}}}
    );
    const dst = destinationFromJobConfig(v).?;
    try testing.expectEqualStrings("p", dst.project_id);
    try testing.expectEqualStrings("d", dst.dataset_id);
    try testing.expectEqualStrings("t", dst.table_id);
    try testing.expectEqualStrings("WRITE_TRUNCATE", dst.write_disposition);
}

test "a destination job's table layout fields come back as posted, nulls dropped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const layout = try destinationLayoutFields(arena,
        \\{"configuration":{"query":{"query":"SELECT 1",
        \\  "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"},
        \\  "clustering":{"fields":["a"]},
        \\  "timePartitioning":null,
        \\  "rangePartitioning":{"field":"n","range":{"start":"0","end":"100","interval":"10"}}}}}
    );
    try testing.expectEqual(@as(usize, 2), layout.count());
    try testing.expect(layout.get("timePartitioning") == null);
    try testing.expect(layout.get("destinationTable") == null);
    const fields = layout.get("clustering").?.object.get("fields").?.array.items;
    try testing.expectEqual(@as(usize, 1), fields.len);
    try testing.expectEqualStrings("a", fields[0].string);
    const range = layout.get("rangePartitioning").?.object.get("range").?.object;
    try testing.expectEqualStrings("100", range.get("end").?.string);

    // Not a job body at all: nothing, rather than an error.
    const none = try destinationLayoutFields(arena, "not json");
    try testing.expectEqual(@as(usize, 0), none.count());
}

test "a query job without a destination has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try parseInsert(arena,
        \\{"configuration":{"query":{"query":"SELECT 1"}}}
    );
    try testing.expectEqual(@as(?Destination, null), destinationFromJobConfig(v));
}

test "write disposition selects the DDL form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = Destination{ .project_id = "p", .dataset_id = "d", .table_id = "t" };
    try testing.expect(!isAppend(base));
    try testing.expectEqualStrings(
        "CREATE OR REPLACE TABLE `p.d.t` AS SELECT 1 AS a",
        try replaceDdl(arena, base, "SELECT 1 AS a"),
    );

    var append = base;
    append.write_disposition = "WRITE_APPEND";
    try testing.expect(isAppend(append));
    try testing.expectEqualStrings(
        "INSERT INTO `p.d.t` SELECT 1 AS a",
        try appendDdl(arena, append, "SELECT 1 AS a"),
    );
}

test "materialization actually creates a queryable table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const dst = Destination{
        .project_id = "p",
        .dataset_id = "d",
        .table_id = "mat",
        .write_disposition = "WRITE_TRUNCATE",
    };
    try db.exec(try replaceDdl(arena, dst, "SELECT 7 AS x"), &.{}, .{});

    var rows = try db.query("SELECT x FROM `p.d.mat`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 7), (try rows.next()).?[0].int);
}

test "appending a wider result than the destination falls back to replacing" {
    // Go never lets a previously declared schema constrain the query: it
    // derives the destination from the query's own result schema. Recidiviz
    // declares an archive table's schema and then appends a view that yields
    // one more column, which is fine there and must be fine here.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();
    try db.exec("CREATE TABLE `p.d.arch` (a INT64, b STRING)", &.{}, .{});

    const dst = Destination{
        .project_id = "p",
        .dataset_id = "d",
        .table_id = "arch",
        .write_disposition = "WRITE_APPEND",
    };
    const wider = "SELECT 1 AS a, 'x' AS b, DATE '2024-01-01' AS export_date";

    // The append itself cannot work against the narrower table.
    try testing.expectError(
        error.AnalyzeFailed,
        db.exec(try appendDdl(arena, dst, wider), &.{}, .{}),
    );
    // Replacing from the query does.
    try db.exec(try replaceDdl(arena, dst, wider), &.{}, .{});

    var rows = try db.query("SELECT export_date FROM `p.d.arch`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqualStrings("2024-01-01", (try rows.next()).?[0].date);
}
