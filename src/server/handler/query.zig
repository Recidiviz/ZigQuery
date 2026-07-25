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
};

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
    return req;
}

/// A completed query, retained so jobs.get and getQueryResults can replay it.
pub const Job = struct {
    project_id: []const u8,
    job_id: []const u8,
    /// Serialized getQueryResults body.
    body: []const u8,
    /// Serialized bigquery#job resource, for jobs.get.
    resource: []const u8,
};

/// Process-local job store. Go writes these to the `jobs` metadata table with
/// three columns (metadata / result / error); M2 replaces this.
pub const JobStore = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Job) = .empty,

    fn freeEntry(s: *JobStore, j: *Job) void {
        s.gpa.free(j.body);
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
        body: []const u8,
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
            .body = try s.gpa.dupe(u8, body),
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
) !struct { body: []const u8, ok: bool, total_bytes: usize = 0 } {
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

    var out: std.ArrayList(u8) = .empty;
    try response.writeQueryResponse(arena, &out, .{
        .project_id = project_id,
        .job_id = job_id,
        .cols = cols,
        .rows = collected.items,
        .total_rows = collected.items.len,
    });
    return .{
        .body = try out.toOwnedSlice(arena),
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

    try store.put("test", "job1", "{\"a\":1}", "{}");
    try testing.expectEqualStrings("{\"a\":1}", store.get("job1").?.body);
    try testing.expectEqualStrings("test", store.get("job1").?.project_id);

    try store.put("test", "job1", "{\"a\":2}", "{}");
    try testing.expectEqualStrings("{\"a\":2}", store.get("job1").?.body);
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
