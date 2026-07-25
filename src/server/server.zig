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
const datasets_handler = @import("handler/datasets.zig");
const tables_handler = @import("handler/tables.zig");
const metadata = @import("internal/metadata/repository.zig");
const schema_mod = @import("internal/types/schema.zig");
const source_mod = @import("source.zig");

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
    /// Go's --data-from-json: source tables loaded at startup.
    data_from_json: ?[]const u8 = null,
    /// Go's --dataset: one empty dataset created at startup.
    dataset: ?[]const u8 = null,
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
    repo: metadata.Repository,
    rng: std.Random.DefaultPrng,
    /// Host:port, for the selfLink-style URLs handlers build.
    endpoint: []const u8,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, opts: Options) !*Server {
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);
        s.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .project = undefined,
            .db = undefined,
            .jobs = .{ .gpa = gpa },
            .repo = undefined,
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
        s.repo = try metadata.Repository.init(s.db);
        try s.repo.addProjectIfNotExists(s.project);

        if (opts.dataset) |dataset_id| {
            var meta: std.ArrayList(u8) = .empty;
            try datasets_handler.writeDataset(arena, &meta, s.project, dataset_id, true);
            try s.repo.addDataset(s.project, dataset_id, meta.items);
        }

        if (opts.data_from_json) |path| {
            const bytes = try std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                arena,
                .limited(1 << 30),
            );
            const stats = source_mod.loadJson(
                arena,
                s.db,
                &s.repo,
                s.endpoint,
                @divFloor(@as(i64, @bitCast(nowSeed())), 1000),
                bytes,
            ) catch |err| {
                std.log.err(
                    "--data-from-json {s} failed to load: {t}",
                    .{ path, err },
                );
                return err;
            };
            std.log.info(
                "loaded {d} projects, {d} datasets, {d} tables ({d} failed) from {s}",
                .{ stats.projects, stats.datasets, stats.tables, stats.failed_tables, path },
            );
        }
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
            // Listing needs the jobs metadata table; deferred.
            .jobs_list => .{
                .status = .internal_server_error,
                .body = try errors.body(
                    req.arena,
                    .internal_error,
                    "unsupported in this milestone: jobs.list",
                ),
            },

            .datasets_insert => s.handleDatasetsInsert(req, m.captures.get(0)),
            .datasets_list => s.handleDatasetsList(req, m.captures.get(0)),
            .datasets_get => s.handleDatasetsGet(req, m.captures.get(0), m.captures.get(1)),
            .datasets_delete => s.handleDatasetsDelete(req, m.captures.get(0), m.captures.get(1)),
            .datasets_patch => s.handleDatasetsPatch(req, m.captures.get(0), m.captures.get(1)),

            .tables_insert => s.handleTablesInsert(req, m.captures.get(0), m.captures.get(1)),
            .tables_list => s.handleTablesList(req, m.captures.get(0), m.captures.get(1)),
            .tables_get, .tables_patch => s.handleTablesGet(
                req,
                m.captures.get(0),
                m.captures.get(1),
                m.captures.get(2),
            ),
            .tables_delete => s.handleTablesDelete(
                req,
                m.captures.get(0),
                m.captures.get(1),
                m.captures.get(2),
            ),
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

    // ---- datasets ----

    fn handleDatasetsInsert(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch {
            return badRequest(arena, "failed to decode request body");
        };
        const dataset_id = datasets_handler.datasetIdFromBody(parsed) orelse {
            return badRequest(arena, "datasetReference.datasetId is required");
        };

        var meta: std.ArrayList(u8) = .empty;
        try datasets_handler.writeDataset(arena, &meta, project_id, dataset_id, true);
        try s.repo.addDataset(project_id, dataset_id, meta.items);

        return .{ .body = meta.items };
    }

    fn handleDatasetsList(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const ids = try s.repo.listDatasets(arena, project_id);
        var out: std.ArrayList(u8) = .empty;
        try datasets_handler.writeDatasetList(arena, &out, project_id, ids);
        return .{ .body = out.items };
    }

    fn handleDatasetsGet(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        if (!try s.repo.datasetExists(project_id, dataset_id)) {
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "dataset {s} is not found",
                .{dataset_id},
            ));
        }
        var out: std.ArrayList(u8) = .empty;
        try datasets_handler.writeDataset(arena, &out, project_id, dataset_id, false);
        return .{ .body = out.items };
    }

    /// server/handler.go datasetsPatchHandler.
    ///
    /// Clients patch datasets to set things like defaultTableExpirationMs.
    /// The posted body is stored and echoed back with the reference filled
    /// in, so a field the emulator does not otherwise model still round-trips.
    fn handleDatasetsPatch(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        if (!try s.repo.datasetExists(project_id, dataset_id)) {
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "dataset {s} is not found",
                .{dataset_id},
            ));
        }

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch
            std.json.Value{ .null = {} };

        var out: std.ArrayList(u8) = .empty;
        if (parsed == .object and parsed.object.count() > 0) {
            // Re-emit the patch with datasetReference/id guaranteed present.
            var merged = try std.json.ObjectMap.init(arena, &.{}, &.{});
            var it = parsed.object.iterator();
            while (it.next()) |kv| try merged.put(arena, kv.key_ptr.*, kv.value_ptr.*);

            var ref = try std.json.ObjectMap.init(arena, &.{}, &.{});
            try ref.put(arena, "datasetId", .{ .string = dataset_id });
            try ref.put(arena, "projectId", .{ .string = project_id });
            try merged.put(arena, "datasetReference", .{ .object = ref });
            try merged.put(arena, "id", .{ .string = dataset_id });

            try tables_handler.writeJsonValue(arena, &out, .{ .object = merged });
        } else {
            try datasets_handler.writeDataset(arena, &out, project_id, dataset_id, true);
        }

        try s.repo.addDataset(project_id, dataset_id, out.items);
        return .{ .body = out.items };
    }

    fn handleDatasetsDelete(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        // deleteContents drops the tables too; without it Go errors when the
        // dataset is non-empty. The emulator is permissive here.
        try s.repo.deleteTablesInDataset(project_id, dataset_id);
        try s.repo.deleteDataset(project_id, dataset_id);
        _ = req;
        return .{ .body = "" };
    }

    // ---- tables ----

    fn handleTablesInsert(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch {
            return badRequest(arena, "failed to decode request body");
        };
        const table_id = tables_handler.tableIdFromBody(parsed) orelse {
            return badRequest(arena, "tableReference.tableId is required");
        };

        const schema_node: ?std.json.Value =
            if (parsed == .object) parsed.object.get("schema") else null;

        // A table only becomes queryable once the DDL runs; Go does the same
        // through its content repository.
        var kind: []const u8 = "TABLE";
        if (tables_handler.viewQueryFromBody(parsed)) |view_sql| {
            kind = "VIEW";
            const ddl = try std.fmt.allocPrint(
                arena,
                "CREATE OR REPLACE VIEW `{s}.{s}.{s}` AS {s}",
                .{ project_id, dataset_id, table_id, view_sql },
            );
            s.db.exec(ddl, &.{}, .{}) catch {
                return .{
                    .status = .bad_request,
                    .body = try errors.body(
                        arena,
                        .invalid_query,
                        try query_handler.wrapEngineError(arena, s.db.lastError()),
                    ),
                };
            };
        } else {
            const ddl = try schema_mod.createTableDdl(
                arena,
                project_id,
                dataset_id,
                table_id,
                schema_node,
            );
            s.db.exec(ddl, &.{}, .{}) catch {
                return .{
                    .status = .bad_request,
                    .body = try errors.body(
                        arena,
                        .invalid_query,
                        try query_handler.wrapEngineError(arena, s.db.lastError()),
                    ),
                };
            };
        }

        const meta = tables_handler.TableMeta{
            .project_id = project_id,
            .dataset_id = dataset_id,
            .table_id = table_id,
            .endpoint = s.endpoint,
            .created_millis = @divFloor(@as(i64, @bitCast(nowSeed())), 1000),
            .schema = schema_node,
            .kind = kind,
        };
        var out: std.ArrayList(u8) = .empty;
        try tables_handler.writeTable(arena, &out, meta);
        try s.repo.addTable(project_id, dataset_id, table_id, out.items);

        return .{ .body = out.items };
    }

    fn handleTablesGet(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const stored = try s.repo.findTable(arena, project_id, dataset_id, table_id) orelse {
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is not found",
                .{table_id},
            ));
        };
        return .{ .body = stored };
    }

    fn handleTablesList(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const metas = try s.repo.listTables(arena, project_id, dataset_id);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "{\"tables\":[");
        for (metas, 0..) |meta_json, i| {
            if (i > 0) try out.append(arena, ',');
            // Stored metadata is the full resource; list returns the
            // abbreviated form, so re-render from the parsed value.
            const v = std.json.parseFromSliceLeaky(std.json.Value, arena, meta_json, .{}) catch {
                try out.appendSlice(arena, meta_json);
                continue;
            };
            try tables_handler.writeTableListEntry(arena, &out, .{
                .project_id = project_id,
                .dataset_id = dataset_id,
                .table_id = tableIdOf(v) orelse "",
                .endpoint = s.endpoint,
                .created_millis = creationMillisOf(v),
                .kind = typeOf(v),
            });
        }
        try out.appendSlice(arena, "],\"totalItems\":");
        try out.print(arena, "{d}", .{metas.len});
        try out.append(arena, '}');
        return .{ .body = out.items };
    }

    fn handleTablesDelete(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        // Drop from the content database too, so a later CREATE succeeds.
        const ddl = try std.fmt.allocPrint(
            arena,
            "DROP TABLE IF EXISTS `{s}.{s}.{s}`",
            .{ project_id, dataset_id, table_id },
        );
        s.db.exec(ddl, &.{}, .{}) catch {};
        try s.repo.deleteTable(project_id, dataset_id, table_id);
        return .{ .body = "" };
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

        // A query job may carry a destination table: this is how view
        // materialization writes results. Run the DDL form instead of the
        // bare SELECT, then record the resulting table's metadata.
        const res = if (jobs_handler.destinationFromJobConfig(parsed)) |dst| blk: {
            const ddl = try jobs_handler.materializeDdl(arena, dst, sql);
            s.db.exec(ddl, &.{}, .{}) catch {
                return .{
                    .status = .bad_request,
                    .body = try errors.body(
                        arena,
                        .invalid_query,
                        try query_handler.wrapEngineError(arena, s.db.lastError()),
                    ),
                };
            };
            try s.recordMaterializedTable(arena, dst);
            // Materialization returns no rows of its own.
            break :blk try query_handler.runQuery(
                arena,
                s.db,
                project_id,
                job_id,
                try std.fmt.allocPrint(arena, "SELECT * FROM `{s}.{s}.{s}` LIMIT 0", .{
                    dst.project_id, dst.dataset_id, dst.table_id,
                }),
            );
        } else try query_handler.runQuery(arena, s.db, project_id, job_id, sql);

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

    /// Registers a table produced by a materialization job, deriving its
    /// schema from the table the DDL just created.
    fn recordMaterializedTable(
        s: *Server,
        arena: std.mem.Allocator,
        dst: jobs_handler.Destination,
    ) !void {
        const probe = try std.fmt.allocPrint(
            arena,
            "SELECT * FROM `{s}.{s}.{s}` LIMIT 0",
            .{ dst.project_id, dst.dataset_id, dst.table_id },
        );
        var schema_json: ?std.json.Value = null;
        if (s.db.query(probe, &.{}, .{})) |r| {
            var rows = r;
            defer rows.deinit();
            var sbuf: std.ArrayList(u8) = .empty;
            try schema_mod.writeSchema(arena, &sbuf, rows.columnTypes());
            schema_json = std.json.parseFromSliceLeaky(
                std.json.Value,
                arena,
                sbuf.items,
                .{},
            ) catch null;
        } else |_| {}

        var meta: std.ArrayList(u8) = .empty;
        try tables_handler.writeTable(arena, &meta, .{
            .project_id = dst.project_id,
            .dataset_id = dst.dataset_id,
            .table_id = dst.table_id,
            .endpoint = s.endpoint,
            .created_millis = @divFloor(@as(i64, @bitCast(nowSeed())), 1000),
            .schema = schema_json,
        });
        // The destination dataset may not have been created explicitly.
        if (!try s.repo.datasetExists(dst.project_id, dst.dataset_id)) {
            var ds_meta: std.ArrayList(u8) = .empty;
            try datasets_handler.writeDataset(
                arena,
                &ds_meta,
                dst.project_id,
                dst.dataset_id,
                true,
            );
            try s.repo.addDataset(dst.project_id, dst.dataset_id, ds_meta.items);
        }
        try s.repo.addTable(dst.project_id, dst.dataset_id, dst.table_id, meta.items);
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

fn tableIdOf(v: std.json.Value) ?[]const u8 {
    if (v != .object) return null;
    const ref = v.object.get("tableReference") orelse return null;
    if (ref != .object) return null;
    const id = ref.object.get("tableId") orelse return null;
    return if (id == .string) id.string else null;
}

fn creationMillisOf(v: std.json.Value) i64 {
    if (v != .object) return 0;
    const c = v.object.get("creationTime") orelse return 0;
    if (c != .string) return 0;
    return std.fmt.parseInt(i64, c.string, 10) catch 0;
}

fn typeOf(v: std.json.Value) []const u8 {
    if (v != .object) return "TABLE";
    const t = v.object.get("type") orelse return "TABLE";
    return if (t == .string) t.string else "TABLE";
}

fn notFound(arena: std.mem.Allocator, msg: []const u8) !http_server.Response {
    return .{ .status = .not_found, .body = try errors.body(arena, .not_found, msg) };
}

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

/// Tests never touch the filesystem through this, so a threaded Io that is
/// never pumped is sufficient.
var testing_threaded: std.Io.Threaded = undefined;
const testing_io: std.Io = blk: {
    break :blk undefined;
};

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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries", "{not json");
    try testing.expectEqual(std.http.Status.bad_request, res.status);
}

test "getQueryResults 404s for an unpersisted jobs.query id" {
    // Matches Go: jobs.query never writes a job row.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .GET, "/no/such/path", "");
    try testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "unexpected request path") != null);
}

test "state persists across requests on the same connection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
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
