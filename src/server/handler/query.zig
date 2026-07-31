//! Port of bigquery-emulator server/handler.go jobsQueryHandler (:2411-2487)
//! and jobsGetQueryResultsHandler (:1488-1540), plus the query path of
//! internal/contentdata/repository.go (Query, :178-305).
//!
//! Differences from Go, by design:
//! - No flexible_rpc_marshalling.go. All 209 lines of it exist because Go's
//!   typed-struct encoding/json cannot distinguish absent from null and
//!   rejects JSON numbers for string-typed fields. Decoding into
//!   std.json.Value has both properties natively.
//! - Jobs live in a process-local map for M1. Go persists them to the
//!   `jobs` metadata table (metadata/repository.go); that arrives in M2.

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;
const http_server = @import("../http/server.zig");
const errors = @import("../error.zig");
const response = @import("../internal/types/response.zig");
const schema_mod = @import("../internal/types/schema.zig");

pub const Error = error{
    /// Body was not an object, or `query` was missing / not a string.
    InvalidRequest,
} || std.mem.Allocator.Error;

pub const QueryRequest = struct {
    query: []const u8,
    dry_run: bool = false,
    /// Present but unused: Go's jobs.query ignores maxResults entirely, in
    /// both the body and the query string. Only getQueryResults honours it.
    /// Verified against the running Go emulator.
    max_results: ?i64 = null,
    /// `formatOptions.useInt64Timestamp` from the body. jobs.query ORs this
    /// with the query-string form (handler.go:2420-2424); the other two
    /// endpoints read only the query string.
    use_int64_timestamp: bool = false,
};

/// Go strconv.ParseBool, which is what parseQueryValueAsBool applies to a
/// query-string value. The Python BigQuery client sends `True`.
pub fn parseGoBool(s: []const u8) bool {
    return std.mem.eql(u8, s, "1") or std.mem.eql(u8, s, "t") or
        std.mem.eql(u8, s, "T") or std.mem.eql(u8, s, "true") or
        std.mem.eql(u8, s, "TRUE") or std.mem.eql(u8, s, "True");
}

/// Parses a jobs.query body out of a std.json.Value tree.
pub fn parseQueryRequest(root: std.json.Value) Error!QueryRequest {
    if (root != .object) return error.InvalidRequest;
    const obj = root.object;

    const q = obj.get("query") orelse return error.InvalidRequest;
    if (q != .string) return error.InvalidRequest;

    var req = QueryRequest{ .query = q.string };

    if (obj.get("dryRun")) |v| {
        req.dry_run = switch (v) {
            .bool => |b| b,
            // Clients that stringify booleans, which the Go handler tolerates.
            .string => |s| std.mem.eql(u8, s, "true"),
            else => false,
        };
    }
    if (obj.get("maxResults")) |v| {
        req.max_results = switch (v) {
            .integer => |n| n,
            .string => |s| std.fmt.parseInt(i64, s, 10) catch null,
            .float => |f| @as(i64, @intFromFloat(f)),
            else => null,
        };
    }
    if (obj.get("formatOptions")) |fo| {
        if (fo == .object) {
            if (fo.object.get("useInt64Timestamp")) |v| {
                req.use_int64_timestamp = switch (v) {
                    .bool => |b| b,
                    .string => |s| parseGoBool(s),
                    else => false,
                };
            }
        }
    }
    return req;
}

/// A completed query, retained so jobs.get and getQueryResults can replay it.
pub const Job = struct {
    project_id: []const u8,
    job_id: []const u8,
    /// The rows and schema, kept rather than a finished body: getQueryResults
    /// picks maxResults and formatOptions per request, and the request that
    /// ran the query cannot know either.
    set: ResultSet,
    /// Serialized bigquery#job resource, for jobs.get.
    resource: []const u8,
};

/// Process-local job store. Go writes these to the `jobs` metadata table with
/// three columns (metadata / result / error); M2 replaces this.
pub const JobStore = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Job) = .empty,

    fn freeRows(s: *JobStore, rows: []const []const u8) void {
        for (rows) |r| s.gpa.free(r);
        s.gpa.free(rows);
    }

    fn dupeRows(s: *JobStore, rows: []const []const u8) ![]const []const u8 {
        const out = try s.gpa.alloc([]const u8, rows.len);
        var n: usize = 0;
        errdefer {
            for (out[0..n]) |r| s.gpa.free(r);
            s.gpa.free(out);
        }
        while (n < rows.len) : (n += 1) out[n] = try s.gpa.dupe(u8, rows[n]);
        return out;
    }

    fn freeEntry(s: *JobStore, j: *Job) void {
        s.gpa.free(j.set.schema_json);
        s.freeRows(j.set.rows);
        if (j.set.rows_int64_ts) |r| s.freeRows(r);
        s.gpa.free(j.resource);
        s.gpa.free(j.project_id);
        s.gpa.free(j.job_id);
    }

    pub fn deinit(s: *JobStore) void {
        var it = s.map.iterator();
        while (it.next()) |kv| {
            s.gpa.free(kv.key_ptr.*);
            s.freeEntry(kv.value_ptr);
        }
        s.map.deinit(s.gpa);
    }

    pub fn put(
        s: *JobStore,
        project_id: []const u8,
        job_id: []const u8,
        set: ResultSet,
        resource: []const u8,
    ) !void {
        const key = try s.gpa.dupe(u8, job_id);
        errdefer s.gpa.free(key);
        const gop = try s.map.getOrPut(s.gpa, key);
        if (gop.found_existing) {
            s.gpa.free(key);
            s.freeEntry(gop.value_ptr);
        }
        gop.value_ptr.* = .{
            .project_id = try s.gpa.dupe(u8, project_id),
            .job_id = try s.gpa.dupe(u8, job_id),
            .set = .{
                .schema_json = try s.gpa.dupe(u8, set.schema_json),
                .rows = try s.dupeRows(set.rows),
                .rows_int64_ts = if (set.rows_int64_ts) |r| try s.dupeRows(r) else null,
                .total_rows = set.total_rows,
            },
            .resource = try s.gpa.dupe(u8, resource),
        };
    }

    pub fn get(s: *JobStore, job_id: []const u8) ?Job {
        return s.map.get(job_id);
    }
};

/// Go server/util.go randomID: 27 alphanumeric characters.
pub fn randomId(arena: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const out = try arena.alloc(u8, 27);
    for (out) |*c| c.* = alphabet[rng.random().uintLessThan(usize, alphabet.len)];
    return out;
}

/// Wraps an engine error message the way Go's call stack does.
///
/// Go reaches the analyzer through two separate calls and wraps each with
/// fmt.Errorf, so the emulator's messages carry those prefixes:
///
///   parse:   "failed to parse statements: failed to parse statement: <msg>"
///   analyze: "failed to analyze: <msg>"
///
/// The Zig driver surfaces one `AnalyzeFailed` for both, but the underlying
/// GoogleSQL text is byte-identical, so the two are told apart by their
/// "Syntax error:" prefix. Go's parse path also drops the trailing
/// "[at L:C]" position that the analyze path keeps — it reports the parse
/// failure before position information is attached.
pub fn wrapEngineError(arena: std.mem.Allocator, msg: []const u8) ![]const u8 {
    if (std.mem.startsWith(u8, msg, "Syntax error:")) {
        const trimmed = if (std.mem.lastIndexOf(u8, msg, " [at ")) |i| msg[0..i] else msg;
        return std.fmt.allocPrint(
            arena,
            "failed to parse statements: failed to parse statement: {s}",
            .{trimmed},
        );
    }
    return std.fmt.allocPrint(arena, "failed to analyze: {s}", .{msg});
}

/// A completed query's results, kept in the form getQueryResults needs:
/// per-row JSON, so a later request can take a prefix of them without
/// re-running anything. Go keeps the rows themselves and slices those; the
/// difference is only where serialization happens.
pub const ResultSet = struct {
    /// The `schema` object, `{"fields":[...]}`.
    schema_json: []const u8,
    /// One `{"f":[...]}` per row, TIMESTAMP cells in the "sec.rem" form.
    rows: []const []const u8,
    /// The same rows under `useInt64Timestamp`, or null when no column
    /// renders differently and the default rows can be served as-is.
    rows_int64_ts: ?[]const []const u8 = null,
    /// Reported in full even when a response carries fewer rows, matching Go.
    total_rows: usize,
};

/// Go's `maxResultsDefaultValue`: absent means "every row".
pub const max_results_default: i64 = -1;

/// Serializes a getQueryResults / jobs.query envelope from a ResultSet.
///
/// `max_results` is accepted but deliberately NOT applied, so every response
/// carries the whole result. Go truncates here (jobsGetQueryResultsHandler
/// :1520-1528) and leans on two things we do not have: a `pageToken` for the
/// remainder, and the BigQuery Storage Read API over gRPC. Truncating without
/// either silently loses rows — the Python client sees a short page with no
/// token, decides the read is complete (table.py:1924-1928), and stops. The
/// parameter stays in the signature because honouring it is the right
/// behaviour once paging and the Storage API exist.
pub fn writeResultSet(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_id: []const u8,
    job_id: []const u8,
    set: ResultSet,
    max_results: i64,
    use_int64_timestamp: bool,
) !void {
    _ = max_results;
    const selected = if (use_int64_timestamp) (set.rows_int64_ts orelse set.rows) else set.rows;

    try out.appendSlice(arena, "{\"jobReference\":{\"jobId\":");
    try errors.writeJsonString(arena, out, job_id);
    try out.appendSlice(arena, ",\"projectId\":");
    try errors.writeJsonString(arena, out, project_id);
    try out.appendSlice(arena, "},\"schema\":");
    try out.appendSlice(arena, set.schema_json);
    try out.appendSlice(arena, ",\"rows\":[");
    for (selected, 0..) |row, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, row);
    }
    try out.appendSlice(arena, "],\"totalRows\":\"");
    try out.print(arena, "{d}", .{set.total_rows});
    try out.appendSlice(arena, "\",\"jobComplete\":true}");
}

/// Runs a query and serializes the full jobs.query response.
///
/// The Rows is drained and deinited before returning, because Rows.deinit
/// calls back into the Db (dropTempTables) and must not run after a commit.
pub fn runQuery(
    arena: std.mem.Allocator,
    db: *driver.Db,
    project_id: []const u8,
    job_id: []const u8,
    sql: []const u8,
) !RunResult {
    return runQueryFormatted(arena, db, project_id, job_id, sql, false);
}

pub const RunResult = struct {
    /// The jobs.query response: every row, under the caller's format options.
    body: []const u8,
    /// Both renderings of the rows, retained by jobs.insert so getQueryResults
    /// can pick under the formatOptions of the request that reads the job
    /// back — which this request cannot know. Null only when the query failed.
    set: ?ResultSet = null,
    ok: bool,
    total_bytes: usize = 0,
};

pub fn runQueryFormatted(
    arena: std.mem.Allocator,
    db: *driver.Db,
    project_id: []const u8,
    job_id: []const u8,
    sql: []const u8,
    /// Which rendering `body` uses. Both are built regardless whenever a
    /// top-level TIMESTAMP column exists, so a later reader can choose.
    want_int64_timestamps: bool,
) !RunResult {
    var rows = db.query(sql, &.{}, .{}) catch {
        const msg = try wrapEngineError(arena, db.lastError());
        return .{
            .body = try errors.body(arena, .invalid_query, msg),
            .ok = false,
        };
    };
    defer rows.deinit();

    const cols = rows.columnTypes();
    var collected: std.ArrayList([]const driver.Cell) = .empty;
    var total_bytes: usize = 0;
    while (rows.next() catch |err| {
        // A failure partway through iteration still carries a message.
        if (err == error.OutOfMemory) return err;
        return .{
            .body = try errors.body(
                arena,
                .invalid_query,
                try wrapEngineError(arena, db.lastError()),
            ),
            .ok = false,
        };
    }) |row| {
        const materialized = try response.materializeRow(arena, row, cols);
        // Go accumulates len() of each rendered cell string as
        // totalBytesProcessed/Billed (convertValueToCell).
        total_bytes += response.renderedByteLen(arena, materialized) catch 0;
        try collected.append(arena, materialized);
    }

    var schema_json: std.ArrayList(u8) = .empty;
    try schema_mod.writeSchema(arena, &schema_json, cols);

    const rendered = try arena.alloc([]const u8, collected.items.len);
    for (collected.items, 0..) |row, i| {
        var buf: std.ArrayList(u8) = .empty;
        try response.writeRow(arena, &buf, row);
        rendered[i] = try buf.toOwnedSlice(arena);
    }

    // A second rendering is only worth building when a top-level TIMESTAMP
    // column exists; otherwise the two are byte-identical.
    var rendered_int64: ?[]const []const u8 = null;
    if (response.hasInt64TimestampColumn(cols)) {
        const alt = try arena.alloc([]const u8, collected.items.len);
        for (collected.items, 0..) |row, i| {
            var buf: std.ArrayList(u8) = .empty;
            try response.writeRow(arena, &buf, try response.formatInt64Timestamps(arena, row));
            alt[i] = try buf.toOwnedSlice(arena);
        }
        rendered_int64 = alt;
    }

    const set = ResultSet{
        .schema_json = try schema_json.toOwnedSlice(arena),
        .rows = rendered,
        .rows_int64_ts = rendered_int64,
        .total_rows = rendered.len,
    };

    var out: std.ArrayList(u8) = .empty;
    try writeResultSet(
        arena,
        &out,
        project_id,
        job_id,
        set,
        max_results_default,
        want_int64_timestamps,
    );

    return .{
        .body = try out.toOwnedSlice(arena),
        .set = set,
        .ok = true,
        .total_bytes = total_bytes,
    };
}

const testing = std.testing;

test "parses the body shape the Go client sends" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(
        std.json.Value,
        arena,
        \\{"query":"SELECT 1","useLegacySql":false,"maxResults":10}
    ,
        .{},
    );
    const req = try parseQueryRequest(v);
    try testing.expectEqualStrings("SELECT 1", req.query);
    try testing.expectEqual(false, req.dry_run);
    try testing.expectEqual(@as(?i64, 10), req.max_results);
}

test "accepts maxResults as a JSON number or a string" {
    // Node clients stringify numeric fields; Go needs 209 lines of
    // flexible_rpc_marshalling.go to cope, std.json.Value needs none.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        \\{"query":"SELECT 1","maxResults":"25"}
        ,
        \\{"query":"SELECT 1","maxResults":25}
    }) |body| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        try testing.expectEqual(@as(?i64, 25), (try parseQueryRequest(v)).max_results);
    }
}

test "dryRun accepts both a bool and a stringified bool" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{
        \\{"query":"SELECT 1","dryRun":true}
        ,
        \\{"query":"SELECT 1","dryRun":"true"}
    }) |body| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        try testing.expectEqual(true, (try parseQueryRequest(v)).dry_run);
    }
}

test "a missing or non-string query is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "{}", "[]", "\"x\"", "{\"query\":123}" }) |body| {
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        try testing.expectError(error.InvalidRequest, parseQueryRequest(v));
    }
}

test "runQuery produces the Go emulator's response bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const res = try runQuery(arena, db, "test", "<JOBID>", "SELECT 1 AS i");
    try testing.expect(res.ok);
    try testing.expectEqualStrings(
        \\{"jobReference":{"jobId":"<JOBID>","projectId":"test"},"schema":{"fields":[{"name":"i","type":"INTEGER"}]},"rows":[{"f":[{"v":"1"}]}],"totalRows":"1","jobComplete":true}
    ,
        res.body,
    );
}

test "a failing query yields the BigQuery error envelope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const res = try runQuery(arena, db, "test", "j", "SELECT * FROM nonexistent_table_xyz");
    try testing.expect(!res.ok);
    try testing.expect(std.mem.startsWith(u8, res.body, "{\"error\":{\"errors\":[{\"reason\":\"invalidQuery\""));
    try testing.expect(std.mem.indexOf(u8, res.body, "failed to analyze: Table not found") != null);
}

test "job ids are 27 alphanumeric characters, like Go's randomID" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var rng = std.Random.DefaultPrng.init(1234);

    const a = try randomId(arena_state.allocator(), &rng);
    const b = try randomId(arena_state.allocator(), &rng);
    try testing.expectEqual(@as(usize, 27), a.len);
    try testing.expect(!std.mem.eql(u8, a, b));
    for (a) |c| try testing.expect(std.ascii.isAlphanumeric(c));
}

test "job store round-trips and replaces on duplicate id" {
    var store = JobStore{ .gpa = testing.allocator };
    defer store.deinit();

    try store.put("test", "job1", .{
        .schema_json = "{\"fields\":[]}",
        .rows = &.{"{\"f\":[{\"v\":\"1\"}]}"},
        .total_rows = 1,
    }, "{}");
    try testing.expectEqualStrings("{\"f\":[{\"v\":\"1\"}]}", store.get("job1").?.set.rows[0]);
    try testing.expectEqualStrings("test", store.get("job1").?.project_id);
    try testing.expectEqual(@as(?[]const []const u8, null), store.get("job1").?.set.rows_int64_ts);

    try store.put("test", "job1", .{
        .schema_json = "{\"fields\":[]}",
        .rows = &.{"{\"f\":[{\"v\":\"2\"}]}"},
        .rows_int64_ts = &.{"{\"f\":[{\"v\":\"3\"}]}"},
        .total_rows = 1,
    }, "{}");
    try testing.expectEqualStrings("{\"f\":[{\"v\":\"2\"}]}", store.get("job1").?.set.rows[0]);
    try testing.expectEqualStrings("{\"f\":[{\"v\":\"3\"}]}", store.get("job1").?.set.rows_int64_ts.?[0]);
    try testing.expectEqual(@as(u32, 1), store.map.count());

    try testing.expectEqual(@as(?Job, null), store.get("missing"));
}

test "engine errors get Go's wrapping prefixes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // testdata/golden.json: error_table_not_found
    try testing.expectEqualStrings(
        "failed to analyze: Table not found: nonexistent_table_xyz [at 1:15]",
        try wrapEngineError(arena, "Table not found: nonexistent_table_xyz [at 1:15]"),
    );
    // error_syntax: Go's parse path drops the position suffix.
    try testing.expectEqualStrings(
        "failed to parse statements: failed to parse statement: Syntax error: Unexpected end of statement",
        try wrapEngineError(arena, "Syntax error: Unexpected end of statement [at 1:11]"),
    );
}
