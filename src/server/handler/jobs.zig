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
pub fn destinationFromJobConfig(root: std.json.Value) ?Destination {
    if (root != .object) return null;
    const cfg = root.object.get("configuration") orelse return null;
    if (cfg != .object) return null;
    const q = cfg.object.get("query") orelse return null;
    if (q != .object) return null;
    const dst = q.object.get("destinationTable") orelse return null;
    if (dst != .object) return null;

    const p = strOf(dst, "projectId") orelse return null;
    const d = strOf(dst, "datasetId") orelse return null;
    const t = strOf(dst, "tableId") orelse return null;

    return .{
        .project_id = p,
        .dataset_id = d,
        .table_id = t,
        .write_disposition = strOf(q, "writeDisposition") orelse "WRITE_EMPTY",
    };
}

fn strOf(v: std.json.Value, name: []const u8) ?[]const u8 {
    if (v != .object) return null;
    const f = v.object.get(name) orelse return null;
    return if (f == .string) f.string else null;
}

/// DDL that materializes `sql` into the destination, honouring the write
/// disposition.
pub fn materializeDdl(
    arena: std.mem.Allocator,
    dst: Destination,
    sql: []const u8,
) std.mem.Allocator.Error![]const u8 {
    const path = try std.fmt.allocPrint(arena, "`{s}.{s}.{s}`", .{
        dst.project_id, dst.dataset_id, dst.table_id,
    });
    if (std.mem.eql(u8, dst.write_disposition, "WRITE_APPEND")) {
        return std.fmt.allocPrint(arena, "INSERT INTO {s} {s}", .{ path, sql });
    }
    // WRITE_TRUNCATE replaces the table outright; WRITE_EMPTY only differs
    // when the table already has rows, which the emulator does not enforce.
    return std.fmt.allocPrint(arena, "CREATE OR REPLACE TABLE {s} AS {s}", .{ path, sql });
}

test "reads a destination table and write disposition" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"configuration":{"query":{"query":"SELECT 1",
        \\  "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"},
        \\  "writeDisposition":"WRITE_TRUNCATE"}}}
    , .{});
    const dst = destinationFromJobConfig(v).?;
    try testing.expectEqualStrings("p", dst.project_id);
    try testing.expectEqualStrings("d", dst.dataset_id);
    try testing.expectEqualStrings("t", dst.table_id);
    try testing.expectEqualStrings("WRITE_TRUNCATE", dst.write_disposition);
}

test "a query job without a destination has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"configuration":{"query":{"query":"SELECT 1"}}}
    , .{});
    try testing.expectEqual(@as(?Destination, null), destinationFromJobConfig(v));
}

test "write disposition selects the DDL form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const base = Destination{ .project_id = "p", .dataset_id = "d", .table_id = "t" };
    try testing.expectEqualStrings(
        "CREATE OR REPLACE TABLE `p.d.t` AS SELECT 1 AS a",
        try materializeDdl(arena, base, "SELECT 1 AS a"),
    );

    var append = base;
    append.write_disposition = "WRITE_APPEND";
    try testing.expectEqualStrings(
        "INSERT INTO `p.d.t` SELECT 1 AS a",
        try materializeDdl(arena, append, "SELECT 1 AS a"),
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
    try db.exec(try materializeDdl(arena, dst, "SELECT 7 AS x"), &.{}, .{});

    var rows = try db.query("SELECT x FROM `p.d.mat`", &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 7), (try rows.next()).?[0].int);
}
