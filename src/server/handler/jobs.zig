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
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const errors = @import("../error.zig");
const query_handler = @import("query.zig");

/// Pulls `configuration.query.query` out of a jobs.insert body.
pub fn queryFromJobConfig(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const cfg = root.object.get("configuration") orelse return null;
    if (cfg != .object) return null;
    const q = cfg.object.get("query") orelse return null;
    if (q != .object) return null;
    const sql = q.object.get("query") orelse return null;
    if (sql != .string) return null;
    return sql.string;
}

pub const JobResource = struct {
    project_id: []const u8,
    job_id: []const u8,
    sql: []const u8,
    endpoint: []const u8,
    /// Go accumulates len() of each rendered cell string.
    total_bytes: usize,
    unix_seconds: i64,
    /// Go derives this from the resolved statement kind; SELECT covers the
    /// M1 surface.
    statement_type: []const u8 = "SELECT",
};

/// Serializes a bigquery#job resource.
pub fn writeJobResource(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    j: JobResource,
) !void {
    try out.appendSlice(arena, "{\"configuration\":{\"jobType\":\"QUERY\",\"query\":{\"destinationTable\":{\"datasetId\":");
    try errors.writeJsonString(arena, out, try std.fmt.allocPrint(arena, "ds_{s}", .{j.job_id}));
    try out.appendSlice(arena, ",\"projectId\":");
    try errors.writeJsonString(arena, out, j.project_id);
    try out.appendSlice(arena, ",\"tableId\":");
    try errors.writeJsonString(arena, out, j.job_id);
    try out.appendSlice(arena, "},\"priority\":\"INTERACTIVE\",\"query\":");
    try errors.writeJsonString(arena, out, j.sql);
    try out.appendSlice(arena, ",\"useLegacySql\":false}},\"jobReference\":{\"jobId\":");
    try errors.writeJsonString(arena, out, j.job_id);
    try out.appendSlice(arena, ",\"projectId\":");
    try errors.writeJsonString(arena, out, j.project_id);
    try out.appendSlice(arena, "},\"kind\":\"bigquery#job\",\"selfLink\":");
    try errors.writeJsonString(arena, out, try std.fmt.allocPrint(
        arena,
        "http://{s}/bigquery/v2/projects/{s}/jobs/{s}",
        .{ j.endpoint, j.project_id, j.job_id },
    ));

    const ts = try std.fmt.allocPrint(arena, "{d}", .{j.unix_seconds});
    const bytes = try std.fmt.allocPrint(arena, "{d}", .{j.total_bytes});
    try out.appendSlice(arena, ",\"statistics\":{\"creationTime\":");
    try errors.writeJsonString(arena, out, ts);
    try out.appendSlice(arena, ",\"endTime\":");
    try errors.writeJsonString(arena, out, ts);
    try out.appendSlice(arena, ",\"query\":{\"statementType\":");
    try errors.writeJsonString(arena, out, j.statement_type);
    try out.appendSlice(arena, ",\"totalBytesBilled\":");
    try errors.writeJsonString(arena, out, bytes);
    try out.appendSlice(arena, ",\"totalBytesProcessed\":");
    try errors.writeJsonString(arena, out, bytes);
    try out.appendSlice(arena, "},\"startTime\":");
    try errors.writeJsonString(arena, out, ts);
    try out.appendSlice(arena, ",\"totalBytesProcessed\":");
    try errors.writeJsonString(arena, out, bytes);
    try out.appendSlice(arena, "},\"status\":{\"state\":\"DONE\"}}");
}

const testing = std.testing;

test "extracts the SQL from a client's jobs.insert body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"configuration":{"query":{"query":"SELECT 1 AS col","useLegacySql":false}}}
    , .{});
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
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        try testing.expectEqual(@as(?[]const u8, null), queryFromJobConfig(v));
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
    });

    // Captured from the running Go emulator, with the random id replaced.
    try testing.expectEqualStrings(
        \\{"configuration":{"jobType":"QUERY","query":{"destinationTable":{"datasetId":"ds_JOBID","projectId":"test","tableId":"JOBID"},"priority":"INTERACTIVE","query":"SELECT 1 AS col","useLegacySql":false}},"jobReference":{"jobId":"JOBID","projectId":"test"},"kind":"bigquery#job","selfLink":"http://0.0.0.0:19050/bigquery/v2/projects/test/jobs/JOBID","statistics":{"creationTime":"1785011395","endTime":"1785011395","query":{"statementType":"SELECT","totalBytesBilled":"1","totalBytesProcessed":"1"},"startTime":"1785011395","totalBytesProcessed":"1"},"status":{"state":"DONE"}}
    ,
        out.items,
    );
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
    });
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, out.items, .{});
    try testing.expectEqualStrings("DONE", v.object.get("status").?.object.get("state").?.string);
    try testing.expectEqualStrings("bigquery#job", v.object.get("kind").?.string);
}
