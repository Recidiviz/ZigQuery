//! Port of bigquery-emulator server/server.go: assembles storage, the
//! connection, and request dispatch.
//!
//! Differences from Go, by design:
//! - No middleware chain, and in particular no sequentialAccessMiddleware.
//!   Go serializes every request behind one package-level mutex; the
//!   equivalent here is that M1 holds a single connection, which is replaced
//!   by a pool rather than by a lock.
//! - Route dispatch is a switch over Route.Id rather than one http.Handler
//!   type per route (server/handler_gen.go's 39 empty structs).

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

const http_server = @import("http/server.zig");
const router = @import("router.zig");
const errors = @import("error.zig");
const storage_mod = @import("storage.zig");
const query_handler = @import("handler/query.zig");
const discovery = @import("discovery.zig");
const jobs_handler = @import("handler/jobs.zig");

/// Microsecond wall clock via libc, since std.time's timestamp helpers are
/// gone in Zig 0.16 and std.Io is not available at construction time.
fn nowSeed() u64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @bitCast(@as(i64, @intCast(tv.sec)) *% 1_000_000 +% @as(i64, @intCast(tv.usec)));
}

pub const Options = struct {
    project: []const u8,
    database: ?[]const u8 = null,
    host: []const u8 = "0.0.0.0",
    port: u16 = 9050,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    /// Owns the DSN string and anything else with process lifetime.
    arena_state: std.heap.ArenaAllocator,
    project: []const u8,
    /// M1 runs one connection. The pool arrives with the concurrency
    /// milestone; the engine is single-threaded per Db either way.
    db: *driver.Db,
    jobs: query_handler.JobStore,
    rng: std.Random.DefaultPrng,
    /// Host:port, for the selfLink-style URLs handlers build.
    endpoint: []const u8,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .project = undefined,
            .db = undefined,
            .jobs = .{ .gpa = gpa },
            // Seeded from the clock: job ids only need to be unique within a
            // run, and Go's randomID is likewise not cryptographic. Zig 0.16
            // moved wall-clock reads behind std.Io, so read libc directly —
            // the same thing internal/catalog.zig does.
            .rng = std.Random.DefaultPrng.init(nowSeed()),
            .endpoint = undefined,
        };
        errdefer s.arena_state.deinit();
        const arena = s.arena_state.allocator();

        s.project = try arena.dupe(u8, opts.project);
        s.endpoint = try std.fmt.allocPrint(arena, "{s}:{d}", .{ opts.host, opts.port });

        const store = try storage_mod.Storage.resolve(arena, opts.database);
        s.db = try driver.Db.openWith(gpa, store.dsn, .{
            .pragmas = store.pragmas(),
            .busy_timeout_ms = 5000,
        });
        return s;
    }

    pub fn deinit(s: *Server) void {
        s.jobs.deinit();
        s.db.close();
        s.arena_state.deinit();
        s.gpa.destroy(s);
    }

    pub fn handler(s: *Server) http_server.Handler {
        return .{ .ctx = s, .func = dispatch };
    }

    fn dispatch(ctx: *anyopaque, req: *const http_server.Request) anyerror!http_server.Response {
        const s: *Server = @ptrCast(@alignCast(ctx));
        const arena = req.arena;

        switch (router.match(req.method, req.path)) {
            .not_found, .method_not_allowed => {
                // Go has no 404: unmatched paths fall through to
                // defaultHandler, which returns 500 internalError
                // "unexpected request path: ..." (handler.go:3598-3603).
                return .{
                    .status = .internal_server_error,
                    .body = try errors.body(
                        arena,
                        .internal_error,
                        try std.fmt.allocPrint(
                            arena,
                            "unexpected request path: {s}",
                            .{req.path},
                        ),
                    ),
                };
            },
            .matched => |m| return s.route(req, m),
        }
    }

    fn route(
        s: *Server,
        req: *const http_server.Request,
        m: router.Match,
    ) !http_server.Response {
        return switch (m.route) {
            .discovery => discovery.handle(req.arena, s.endpoint),
            .jobs_query => s.handleQuery(req, m.captures.get(0)),
            .jobs_get_query_results => s.handleGetQueryResults(
                req,
                m.captures.get(0),
                m.captures.get(1),
            ),
            .jobs_insert => s.handleJobsInsert(req, m.captures.get(0)),
            .jobs_get => s.handleJobsGet(req, m.captures.get(0), m.captures.get(1)),
            // Listing needs the jobs metadata table; M2.
            .jobs_list => .{
                .status = .internal_server_error,
                .body = try errors.body(
                    req.arena,
                    .internal_error,
                    "unsupported in this milestone: jobs.list",
                ),
            },
        };
    }

    /// server/handler.go jobsQueryHandler.
    fn handleQuery(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;

        const parsed = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            req.body,
            .{},
        ) catch {
            return badRequest(arena, "failed to decode request body");
        };
        const q = query_handler.parseQueryRequest(parsed) catch {
            return badRequest(arena, "query is required");
        };

        const job_id = try query_handler.randomId(arena, &s.rng);
        const res = try query_handler.runQuery(arena, s.db, project_id, job_id, q.query);
        if (!res.ok) {
            return .{ .status = .bad_request, .body = res.body };
        }

        // Go's jobs.query does NOT persist a job — only jobs.insert does, so
        // getQueryResults 404s for a jobs.query id. Verified against the Go
        // emulator; reproduced here deliberately.
        return .{ .body = res.body };
    }

    /// server/handler.go jobsInsertHandler.
    ///
    /// This is the path real clients take: Client.query() posts here, polls
    /// jobs.get until DONE, then reads getQueryResults. Go runs the query
    /// synchronously so the job is DONE on return; same here.
    fn handleJobsInsert(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch {
            return badRequest(arena, "failed to decode request body");
        };
        const sql = jobs_handler.queryFromJobConfig(parsed) orelse {
            return badRequest(arena, "configuration.query.query is required");
        };

        const job_id = try query_handler.randomId(arena, &s.rng);
        const res = try query_handler.runQuery(arena, s.db, project_id, job_id, sql);
        if (!res.ok) {
            return .{ .status = .bad_request, .body = res.body };
        }

        var resource: std.ArrayList(u8) = .empty;
        try jobs_handler.writeJobResource(arena, &resource, .{
            .project_id = project_id,
            .job_id = job_id,
            .sql = sql,
            .endpoint = s.endpoint,
            .total_bytes = res.total_bytes,
            .unix_seconds = @divFloor(@as(i64, @bitCast(nowSeed())), 1_000_000),
        });

        try s.jobs.put(project_id, job_id, res.body, resource.items);
        return .{ .body = resource.items };
    }

    /// server/handler.go jobsGetHandler.
    fn handleJobsGet(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        job_id: []const u8,
    ) !http_server.Response {
        _ = project_id;
        const job = s.jobs.get(job_id) orelse return notFoundJob(req.arena, job_id);
        return .{ .body = try req.arena.dupe(u8, job.resource) };
    }

    /// server/handler.go jobsGetQueryResultsHandler.
    fn handleGetQueryResults(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        job_id: []const u8,
    ) !http_server.Response {
        _ = project_id;
        const arena = req.arena;
        const job = s.jobs.get(job_id) orelse return notFoundJob(arena, job_id);
        return .{ .body = try arena.dupe(u8, job.body) };
    }
};

fn notFoundJob(arena: std.mem.Allocator, job_id: []const u8) !http_server.Response {
    return .{
        .status = .not_found,
        .body = try errors.body(
            arena,
            .not_found,
            try std.fmt.allocPrint(arena, "job {s} is not found", .{job_id}),
        ),
    };
}

fn badRequest(arena: std.mem.Allocator, msg: []const u8) !http_server.Response {
    return .{ .status = .bad_request, .body = try errors.body(arena, .invalid, msg) };
}

const testing = std.testing;

/// Drives dispatch directly, without a socket.
fn request(
    s: *Server,
    arena: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    body: []const u8,
) !http_server.Response {
    const req = http_server.Request{
        .method = method,
        .path = path,
        .query = "",
        .body = body,
        .arena = arena,
    };
    return s.handler().func(s.handler().ctx, &req);
}

test "jobs.query returns the Go emulator's response bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT 1 AS i","useLegacySql":false}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    // Only the random job id differs from the captured golden bytes.
    try testing.expect(std.mem.indexOf(u8, res.body, "\"projectId\":\"test\"") != null);
    try testing.expect(std.mem.endsWith(
        u8,
        res.body,
        "\"schema\":{\"fields\":[{\"name\":\"i\",\"type\":\"INTEGER\"}]},\"rows\":[{\"f\":[{\"v\":\"1\"}]}],\"totalRows\":\"1\",\"jobComplete\":true}",
    ));
}

test "the /bigquery/v2 prefix reaches the same handler" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/bigquery/v2/projects/test/queries",
        \\{"query":"SELECT 1 AS i"}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
}

test "a bad query returns 400 in the BigQuery error shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT * FROM nonexistent_table_xyz"}
    );
    try testing.expectEqual(std.http.Status.bad_request, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"reason\":\"invalidQuery\"") != null);
}

test "malformed JSON is a 400, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries", "{not json");
    try testing.expectEqual(std.http.Status.bad_request, res.status);
}

test "getQueryResults 404s for an unpersisted jobs.query id" {
    // Matches Go: jobs.query never writes a job row.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .GET, "/projects/test/queries/nosuchjob", "");
    try testing.expectEqual(std.http.Status.not_found, res.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"notFound","location":"","debugInfo":"","message":"job nosuchjob is not found"}],"code":404,"message":"job nosuchjob is not found"}}
    ,
        res.body,
    );
}

test "an unknown path is a 500, matching Go's defaultHandler" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .GET, "/no/such/path", "");
    try testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "unexpected request path") != null);
}

test "state persists across requests on the same connection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, .{ .project = "test" });
    defer s.deinit();

    _ = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"CREATE TABLE t_persist (a INT64)"}
    );
    _ = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"INSERT INTO t_persist (a) VALUES (7)"}
    );
    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT a FROM t_persist"}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "{\"v\":\"7\"}") != null);
}
