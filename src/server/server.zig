//! Port of bigquery-emulator server/server.go: assembles storage, the
//! connection, and request dispatch.
//!
//! Differences from Go, by design:
//! - No middleware chain, and in particular no sequentialAccessMiddleware.
//!   Go serializes every request behind one package-level mutex; the
//!   equivalent here is one engine connection, with connections accepted
//!   concurrently and dispatched serially.
//!
//!   A connection pool was built on a shared catalog and measured: it is
//!   correct, but on the view-graph workload it cost 833 s and 35 failed views
//!   against 58 s and none serially, because SQLite's in-memory VFS cannot
//!   execute concurrently (see storage.zig). /debug/stats reports a `phases`
//!   block so the analysis-versus-SQLite split is a number rather than a
//!   guess before that is attempted again.
//! - Route dispatch is a switch over Route.Id rather than one http.Handler
//!   type per route (server/handler_gen.go's 39 empty structs).
// ephor:ignore-file ZA301 ZA302 ZA303 ZA304 ZC103

const std = @import("std");
const zigquery = @import("zigquery");
const job_rows_vtab = zigquery.function.job_rows_vtab;
const driver = zigquery.driver;

const http_server = @import("http/server.zig");
const router = @import("router.zig");
const errors = @import("error.zig");
const json_pb = @import("json_pb.zig");
const storage_mod = @import("storage.zig");
const query_handler = @import("handler/query.zig");
const discovery = @import("discovery.zig");
const jobs_handler = @import("handler/jobs.zig");
const copy_handler = @import("handler/jobs.copy.zig");
const pb = @import("proto/bigquery.zig");
const upload = @import("upload.zig");
const load_handler = @import("handler/jobs.load.zig");
const load_rows = @import("internal/load_rows.zig");
const datasets_handler = @import("handler/datasets.zig");
const tables_handler = @import("handler/tables.zig");
const tabledata_handler = @import("handler/tabledata.zig");
const contentdata = @import("internal/contentdata/repository.zig");
const phase = zigquery.phase;
const schema_mod = @import("internal/types/schema.zig");
const stats_mod = @import("stats.zig");
const debug_stats = @import("debug_stats.zig");
const source_mod = @import("source.zig");

/// Microsecond wall clock via libc, since std.time's timestamp helpers are
/// gone in Zig 0.16 and std.Io is not available at construction time.
fn nowSeed() u64 {
    var tv: std.c.timeval = undefined;
    _ = std.c.gettimeofday(&tv, null);
    return @bitCast(@as(i64, @intCast(tv.sec)) *% 1_000_000 +% @as(i64, @intCast(tv.usec)));
}

/// Wall clock in milliseconds, for the deadlines an upload session carries.
fn nowMillis() i64 {
    return @divFloor(@as(i64, @bitCast(nowSeed())), 1_000);
}

pub const Options = struct {
    project: []const u8,
    database: ?[]const u8 = null,
    host: []const u8 = "0.0.0.0",
    port: u16 = 9050,
    /// Go's --data-from-json: source tables loaded at startup. Repeatable —
    /// the flag may be given more than once and the files load in order, so a
    /// later one can add datasets or tables to what an earlier one defined.
    data_from_json: []const []const u8 = &.{},
    /// Go's --dataset: one empty dataset created at startup.
    dataset: ?[]const u8 = null,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    /// Owns the DSN string and anything else with process lifetime.
    arena_state: std.heap.ArenaAllocator,
    project: []const u8,
    /// The one engine connection. Single-threaded per Db, and deliberately
    /// not pooled — see the header.
    db: *driver.Db,
    /// Serializes every reader of `db`, across transports.
    /// REST transport takes it through `handler()`, and the gRPC services take it directly.
    /// Two locks would serialize each transport against itself and neither against the other.
    ///
    /// Held only for the duration of one dispatch.
    engine_mutex: std.Io.Mutex = .init,
    /// The Io `engine_mutex` is taken with. Read only under contention.
    io: std.Io,
    jobs: query_handler.JobStore,
    /// Resumable uploads this process is part way through.
    uploads: upload.SessionStore,
    /// Per-route timing, indexed by Route.Id.
    route_stats: std.enums.EnumArray(router.Route.Id, stats_mod.RouteStats) =
        std.enums.EnumArray(router.Route.Id, stats_mod.RouteStats).initFill(.{}),
    /// The slowest query jobs seen. A route percentile says the p99 is 33 ms;
    /// this says *which statement* that was, which is the difference between
    /// a number and a lead.
    slow_queries: stats_mod.SlowQueries(16, 400) = .{},
    started_ms: i64 = 0,
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
            .uploads = .{ .gpa = gpa },
            // Seeded from the clock: job ids only need to be unique within a
            // run, and Go's randomID is likewise not cryptographic. Zig 0.16
            // moved wall-clock reads behind std.Io, so read libc directly —
            // the same thing internal/catalog.zig does.
            .rng = std.Random.DefaultPrng.init(nowSeed()),
            .io = io,
            .endpoint = undefined,
            .started_ms = @divFloor(@as(i64, @bitCast(nowSeed())), 1000),
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
        // Until a job runs, DDL that names only `dataset.table` means this
        // project; each job then sets its own.
        s.db.default_project = s.project;
        // The connection's pragmas, when an environment override changed them.
        // A comparison run's whole claim rests on the knob having been
        // applied, and this is the only place that can say so.
        const applied = store.pragmas();
        if (storage_mod.hasEnvOverride()) {
            for (applied) |p| std.log.info("connection pragma: {s}", .{p});
        }
        // Where the job-results virtual tables read their rows. Set once, and
        // cleared in deinit before the store goes away.
        s.db.udf_state.job_rows = .{
            .ctx = &s.jobs,
            .lookup = query_handler.JobStore.lookupRows,
        };
        try s.dropStaleJobTables(arena);

        // Clients declare datasets through the metadata API, so a CREATE into
        // one nobody declared is BigQuery's "Not found: Dataset" rather than
        // the engine library's quiet inference.
        s.db.require_dataset = true;

        if (opts.dataset) |dataset_id| {
            var meta: std.ArrayList(u8) = .empty;
            try datasets_handler.writeDataset(arena, &meta, s.project, dataset_id);
            // A file-backed database that already declares it keeps the stored resource.
            s.db.insertDataset(arena, s.project, dataset_id, meta.items) catch |err| switch (err) {
                error.DatasetAlreadyExists => {},
                else => |e| return e,
            };
        }

        for (opts.data_from_json) |path| {
            // ephor:ignore ZA101 — the allocator is `arena`, in third position.
            const bytes = try std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                arena,
                .limited(1 << 30),
            );
            const stats = source_mod.loadJson(
                arena,
                s.db,
                bytes,
            ) catch |err| {
                std.log.err(
                    "--data-from-json {s} failed to load: {t}",
                    .{ path, err },
                );
                return err;
            };
            std.log.info(
                "loaded {d} projects, {d} datasets, {d} tables ({d} failed), " ++
                    "{d} rows ({d} failed, across {d} tables) from {s}",
                .{
                    stats.projects,                stats.datasets,
                    stats.tables,                  stats.failed_tables,
                    stats.rows,                    stats.failed_rows,
                    stats.tables_with_failed_rows, path,
                },
            );
            if (stats.failed_rows > 0) {
                std.log.warn(
                    "{d} rows in {d} tables of {s} were not loaded; each is named above",
                    .{ stats.failed_rows, stats.tables_with_failed_rows, path },
                );
            }
        }
        // Startup loading is engine work but not request work, and counting it
        // would put analysis and SQLite time in the phase totals that never
        // appears in totalHandleMs — inflating both fractions past 1.0.
        phase.reset();
        return s;
    }

    pub fn deinit(s: *Server) void {
        // Order matters. Closing the connection runs `xDisconnect` for every
        // job-results virtual table, and those reach the job store through
        // `udf_state.job_rows` -- so the store may not be freed first, and the
        // pointer to it is dropped before it is.
        s.db.udf_state.job_rows = .{};
        s.db.close();
        s.jobs.deinit();
        s.uploads.deinit();
        s.arena_state.deinit();
        s.gpa.destroy(s);
    }

    pub fn handler(s: *Server) http_server.Handler {
        return .{ .ctx = s, .func = dispatch, .mutex = &s.engine_mutex, .io = s.io };
    }

    /// Runs `f` with the engine lock held.
    ///
    /// The gRPC path's equivalent of what `http/server.zig:serveRequest` does
    /// around `handler.func`. Callers outside a transport should use this
    /// rather than touching `engine_mutex`, so the unlock cannot be forgotten.
    pub fn withEngine(s: *Server, ctx: anytype, comptime f: anytype) @TypeOf(f(ctx, s)) {
        s.engine_mutex.lockUncancelable(s.io);
        defer s.engine_mutex.unlock(s.io);
        return f(ctx, s);
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
            .matched => |m| {
                const t0 = nowSeed();
                const res = try s.route(req, m);
                s.route_stats.getPtr(m.route).record(nowSeed() -| t0);
                return res;
            },
        }
    }

    fn route(
        s: *Server,
        req: *const http_server.Request,
        m: router.Match,
    ) !http_server.Response {
        return switch (m.route) {
            .discovery => discovery.handle(req.arena, s.endpoint),
            .debug_stats => s.handleDebugStats(req),
            .jobs_query => s.handleQuery(req, m.captures.get(0)),
            .jobs_get_query_results => s.handleGetQueryResults(
                req,
                m.captures.get(0),
                m.captures.get(1),
            ),
            .jobs_insert => s.handleJobsInsert(req, m.captures.get(0)),
            .upload_jobs_insert => s.handleUploadInsert(req, m.captures.get(0)),
            .upload_jobs_resume => s.handleUploadResume(req, m.captures.get(0)),
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
            .tables_get => s.handleTablesGet(
                req,
                m.captures.get(0),
                m.captures.get(1),
                m.captures.get(2),
            ),
            .tables_patch => s.handleTablesPatch(
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

            .tabledata_insert_all => s.handleTabledataInsertAll(
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
        // DDL in this job resolves `dataset.table` against the job's project;
        // outside a job it is the server's, whatever ran last.
        s.db.default_project = project_id;
        defer s.db.default_project = s.project;

        const q = query_handler.parseRequest(arena, req.body, req.query) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidParameter,
            error.InvalidBase64Value,
            => return badRequest(arena, "invalid query parameter"),
            error.InvalidRequest => return badRequest(arena, "query is required"),
        };

        const job_id = try query_handler.randomId(arena, &s.rng);
        const int64_ts = q.use_int64_timestamp;
        const res = try query_handler.runQueryFormatted(
            arena,
            s.db,
            project_id,
            job_id,
            q.query,
            q.params,
            int64_ts,
        );
        if (!res.ok) {
            return .{ .status = res.status, .body = res.body };
        }

        // Go's jobs.query does NOT persist a job — only jobs.insert does, so
        // getQueryResults 404s for a jobs.query id. Verified against the Go
        // emulator; reproduced here deliberately.
        return .{ .body = res.body };
    }

    /// Per-route timing for this process. Not a BigQuery endpoint; it exists
    /// because the emulator is the only place that can measure server-side
    /// request cost, and the recidiviz harness's own stats only work against
    /// the Docker image.
    fn handleDebugStats(s: *Server, req: *const http_server.Request) !http_server.Response {
        const arena = req.arena;
        const handle_ns = http_server.stat_handle_ns.load(.monotonic);
        const handle_ms = @as(f64, @floatFromInt(handle_ns)) / 1e6;

        const snap = debug_stats.Snapshot{
            .uptimeSeconds = @divFloor(@as(i64, @bitCast(nowSeed())), 1_000_000) -
                @divFloor(s.started_ms, 1000),
            .contention = contentionSnapshot(handle_ms),
            .phases = phaseSnapshot(handle_ms),
            .sqliteAlloc = allocSnapshot(s.db.allocStats()),
            .routes = try routeSnapshot(s, arena),
            .slowQueries = try slowQuerySnapshot(s, arena),
        };
        return .{ .body = try std.json.Stringify.valueAlloc(arena, snap, .{}) };
    }

    fn contentionSnapshot(handle_ms: f64) debug_stats.Contention {
        const reqs = http_server.stat_requests.load(.monotonic);
        const per = @as(f64, @floatFromInt(if (reqs == 0) 1 else reqs));
        const wait_ms = @as(f64, @floatFromInt(http_server.stat_wait_ns.load(.monotonic))) / 1e6;
        const busy = wait_ms + handle_ms;
        return .{
            .requests = reqs,
            .totalWaitMs = .{ .v = wait_ms },
            .totalHandleMs = .{ .v = handle_ms },
            .meanWaitMs = .{ .v = if (reqs == 0) 0 else wait_ms / per },
            .meanHandleMs = .{ .v = if (reqs == 0) 0 else handle_ms / per },
            .waitFraction = .{ .v = if (busy == 0) 0 else wait_ms / busy },
            .maxWaiters = http_server.stat_waiters_max.load(.monotonic),
            .waitersNow = http_server.stat_waiters_now.load(.monotonic),
        };
    }

    /// `analysisFraction` is what decides whether running analysis concurrently
    /// is worth anything: wall time under N parallel analyzers is bounded by
    /// (1-f) + f/N, and SQLite on an in-memory database cannot overlap at all
    /// (see storage.zig). Measured against total handle time, so the remainder
    /// is HTTP, JSON and glue.
    fn phaseSnapshot(handle_ms: f64) debug_stats.Phases {
        const ms1 = debug_stats.Ms1;
        const analyze_ms = @as(f64, @floatFromInt(phase.totalNs(.analyze))) / 1e6;
        const transform_ms = @as(f64, @floatFromInt(phase.totalNs(.transform))) / 1e6;
        const sqlite_ms = @as(f64, @floatFromInt(phase.sqliteTotalNs())) / 1e6;
        return .{
            .analyzeMs = .{ .v = analyze_ms },
            .analyzeCount = phase.count(.analyze),
            .transformMs = .{ .v = transform_ms },
            .transformCount = phase.count(.transform),
            .sqliteMs = .{ .v = sqlite_ms },
            .sqlite = .{
                .prepareMs = debug_stats.msFromNs(phase.totalNs(.sqlite_prepare), ms1),
                .prepareCount = phase.count(.sqlite_prepare),
                .stepMs = debug_stats.msFromNs(phase.totalNs(.sqlite_step), ms1),
                .stepCount = phase.count(.sqlite_step),
                .execMs = debug_stats.msFromNs(phase.totalNs(.sqlite_exec), ms1),
                .execCount = phase.count(.sqlite_exec),
                .engineMs = debug_stats.msFromNs(phase.sqliteTotalNsFrom(.engine), ms1),
                .catalogMs = debug_stats.msFromNs(phase.sqliteTotalNsFrom(.catalog), ms1),
                .metadataMs = debug_stats.msFromNs(phase.sqliteTotalNsFrom(.metadata), ms1),
                .catalogPrepareMs = debug_stats.msFromNs(
                    phase.totalNsFrom(.sqlite_prepare, .catalog),
                    ms1,
                ),
                .catalogPrepareCount = phase.countFrom(.sqlite_prepare, .catalog),
                .catalogStepMs = debug_stats.msFromNs(
                    phase.totalNsFrom(.sqlite_step, .catalog),
                    ms1,
                ),
            },
            .preparedSqlBytes = phase.preparedBytes(),
            .codecMs = debug_stats.msFromNs(phase.codecTotalNs(), ms1),
            .codecCount = phase.codecCount(),
            .codec = .{
                .timersEnabled = phase.codec_timers_enabled,
                .encodeMs = debug_stats.msFromNs(phase.totalNs(.codec_encode), ms1),
                .encodeCount = phase.count(.codec_encode),
                .decodeMs = debug_stats.msFromNs(phase.totalNs(.codec_decode), ms1),
                .decodeCount = phase.count(.codec_decode),
                .literalMs = debug_stats.msFromNs(phase.totalNs(.codec_literal), ms1),
                .literalCount = phase.count(.codec_literal),
            },
            .analysisFraction = .{
                .v = if (handle_ms == 0) 0 else (analyze_ms + transform_ms) / handle_ms,
            },
            .sqliteFraction = .{ .v = if (handle_ms == 0) 0 else sqlite_ms / handle_ms },
        };
    }

    /// SQLite's own allocator accounting. `lookaside.hitRate` is the number that
    /// matters: lookaside is a per-connection pool of small fixed-size slots
    /// serving the many short-lived allocations sqlite3_prepare_v2 makes.
    ///
    /// Exhausted is not the same as costly. On the view graph the rate was
    /// driven from 0.0000 to 0.9676 with no effect on prepare time outside the
    /// noise floor (Options.lookaside records the table). These are reported so
    /// that stays a measurement rather than a belief, in either direction.
    fn allocSnapshot(alloc: driver.AllocStats) debug_stats.SqliteAlloc {
        return .{
            .memoryUsedBytes = alloc.memory_used.current,
            .memoryUsedPeakBytes = alloc.memory_used.highwater,
            .mallocsOutstanding = alloc.malloc_count.current,
            .mallocsOutstandingPeak = alloc.malloc_count.highwater,
            .largestAllocBytes = alloc.malloc_size_max,
            .schemaBytes = alloc.schema_used,
            .stmtBytes = alloc.stmt_used,
            .pagerCacheBytes = alloc.cache_used,
            .lookaside = lookasideSnapshot(alloc),
        };
    }

    fn lookasideSnapshot(alloc: driver.AllocStats) debug_stats.Lookaside {
        return .{
            .hit = alloc.lookaside_hit,
            .missSize = alloc.lookaside_miss_size,
            .missFull = alloc.lookaside_miss_full,
            .hitRate = .{ .v = alloc.hitRate() orelse 0.0 },
            .slotsInUse = alloc.lookaside_used.current,
            .slotsPeak = alloc.lookaside_used.highwater,
        };
    }

    fn routeSnapshot(s: *Server, arena: std.mem.Allocator) ![]const debug_stats.Route {
        var routes: std.ArrayList(debug_stats.Route) = .empty;
        var it = s.route_stats.iterator();
        while (it.next()) |entry| {
            if (entry.value.count == 0) continue;
            try routes.append(arena, routeEntry(@tagName(entry.key), entry.value));
        }
        return routes.items;
    }

    fn routeEntry(name: []const u8, st: *const stats_mod.RouteStats) debug_stats.Route {
        const ms1 = debug_stats.Ms1;
        const ms3 = debug_stats.Ms3;
        return .{
            .route = name,
            .count = st.count,
            .meanMs = .{ .v = st.meanUs() / 1000.0 },
            .minMs = debug_stats.msFromUs(st.min_us, ms3),
            .p50Ms = debug_stats.msFromUs(st.percentileUs(0.50), ms3),
            .p90Ms = debug_stats.msFromUs(st.percentileUs(0.90), ms3),
            .p99Ms = debug_stats.msFromUs(st.percentileUs(0.99), ms3),
            .maxMs = debug_stats.msFromUs(st.max_us, ms3),
            .totalMs = debug_stats.msFromUs(st.total_us, ms1),
        };
    }

    fn slowQuerySnapshot(s: *Server, arena: std.mem.Allocator) ![]const debug_stats.SlowQuery {
        var slow: std.ArrayList(debug_stats.SlowQuery) = .empty;
        var slow_buf: [16]*const @TypeOf(s.slow_queries).Entry = undefined;
        for (s.slow_queries.sorted(&slow_buf)) |e| {
            try slow.append(arena, .{
                .ms = debug_stats.msFromUs(e.us, debug_stats.Ms3),
                .sql = e.sql(),
            });
        }
        return slow.items;
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

        // `datasetIdFromBody` only finds an id in an object.
        var resource: std.ArrayList(u8) = .empty;
        try datasets_handler.writeDatasetResource(
            arena,
            &resource,
            project_id,
            dataset_id,
            parsed.object,
        );
        s.db.insertDataset(arena, project_id, dataset_id, resource.items) catch |err| switch (err) {
            error.DatasetAlreadyExists => return .{
                .status = .conflict,
                .body = try errors.body(arena, .duplicate, try std.fmt.allocPrint(
                    arena,
                    "Already Exists: Dataset {s}:{s}",
                    .{ project_id, dataset_id },
                )),
            },
            else => |e| return e,
        };
        return .{ .body = resource.items };
    }

    fn handleDatasetsList(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const specs = try s.db.catalogDatasetsIn(arena, project_id);
        // The catalog holds declaration order; the API lists by id.
        std.mem.sort(*const zigquery.spec.DatasetSpec, specs, {}, datasetIdLessThan);
        const resources = try arena.alloc([]const u8, specs.len);
        for (specs, resources) |ds, *resource| resource.* = try datasetResource(arena, ds);
        var out: std.ArrayList(u8) = .empty;
        try datasets_handler.writeDatasetList(arena, &out, resources);
        return .{ .body = out.items };
    }

    fn datasetIdLessThan(
        _: void,
        a: *const zigquery.spec.DatasetSpec,
        b: *const zigquery.spec.DatasetSpec,
    ) bool {
        return std.mem.lessThan(u8, a.name_path[1], b.name_path[1]);
    }

    /// The resource a declared dataset reports: what was posted or patched,
    /// verbatim. A declaration that carried none (the `--dataset` flag, a
    /// loader fixture) reports the bare reference.
    fn datasetResource(arena: std.mem.Allocator, ds: *const zigquery.spec.DatasetSpec) ![]const u8 {
        if (ds.metadata.len > 0) return ds.metadata;
        var out: std.ArrayList(u8) = .empty;
        try datasets_handler.writeDataset(arena, &out, ds.name_path[0], ds.name_path[1]);
        return out.items;
    }

    fn handleDatasetsGet(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const ds = (try s.db.catalogDataset(arena, project_id, dataset_id)) orelse
            return datasetNotFound(arena, project_id, dataset_id);
        return .{ .body = try datasetResource(arena, ds) };
    }

    /// Merges the posted fields over the stored resource key by key, as tables.patch does: a field
    /// the patch names is replaced whole and the rest are kept
    /// (https://cloud.google.com/bigquery/docs/reference/rest/v2/datasets/patch). The reference
    /// stays the request path's. datasets.get and datasets.list report the result.
    fn handleDatasetsPatch(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const current = (try s.db.catalogDataset(arena, project_id, dataset_id)) orelse
            return datasetNotFound(arena, project_id, dataset_id);
        const patch = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch {
            return badRequest(arena, "failed to decode request body");
        };
        const stored = std.json.parseFromSliceLeaky(
            std.json.Value,
            arena,
            try datasetResource(arena, current),
            .{},
        ) catch return internalError(arena, "stored dataset resource is not JSON");

        var merged: std.json.ObjectMap = .empty;
        if (stored == .object) {
            var it = stored.object.iterator();
            while (it.next()) |kv| try merged.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        if (patch == .object) {
            var it = patch.object.iterator();
            while (it.next()) |kv| try merged.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }

        var resource: std.ArrayList(u8) = .empty;
        try datasets_handler.writeDatasetResource(arena, &resource, project_id, dataset_id, merged);
        try s.db.updateDataset(arena, project_id, dataset_id, resource.items);
        return .{ .body = resource.items };
    }

    fn handleDatasetsDelete(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        if (try s.db.catalogDataset(arena, project_id, dataset_id) == null) {
            return datasetNotFound(arena, project_id, dataset_id);
        }
        // deleteContents drops the tables too; without it Go errors when the
        // dataset is non-empty. The emulator is permissive here.
        //
        // The engine is asked for them because it is the one store of tables,
        // SQL-made ones included — a CTAS or a CREATE VIEW run as a query job
        // never reaches tables.insert.
        for (try s.db.catalogTablesIn(arena, project_id, dataset_id)) |table_spec| {
            const ddl = try std.fmt.allocPrint(
                arena,
                "DROP {s} IF EXISTS `{s}.{s}.{s}`",
                .{
                    if (table_spec.is_view) "VIEW" else "TABLE",
                    project_id,
                    dataset_id,
                    table_spec.name_path[2],
                },
            );
            s.db.exec(ddl, &.{}, .{}) catch |err|
                std.log.warn("dataset delete left {s} behind: {t}", .{ ddl, err });
        }
        try s.db.deleteDataset(arena, project_id, dataset_id);
        return .{ .body = "" };
    }

    // ---- tables ----

    fn handleTablesInsert(
        server: *Server,
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

        if (!try server.db.datasetExists(arena, project_id, dataset_id)) {
            return datasetNotFound(arena, project_id, dataset_id);
        }
        if (try server.db.catalogTable(arena, project_id, dataset_id, table_id)) |_| {
            return .{
                .status = .conflict,
                .body = try errors.body(arena, .duplicate, try std.fmt.allocPrint(
                    arena,
                    "Already Exists: Table {s}:{s}.{s}",
                    .{ project_id, dataset_id, table_id },
                )),
            };
        }

        const columns = try tables_handler.schemaColumnNames(arena, schema_node);
        if (try tableLayoutRejection(arena, parsed, columns)) |rejection| return rejection;

        // A table only becomes queryable once the DDL runs
        if (tables_handler.viewQueryFromBody(parsed)) |view_sql| {
            const ddl = try std.fmt.allocPrint(
                arena,
                "CREATE OR REPLACE VIEW `{s}.{s}.{s}` AS {s}",
                .{ project_id, dataset_id, table_id, view_sql },
            );
            server.db.exec(ddl, &.{}, .{}) catch {
                return .{
                    .status = .bad_request,
                    .body = try errors.body(
                        arena,
                        .invalid_query,
                        try query_handler.wrapEngineError(arena, server.db.lastError()),
                    ),
                };
            };
        } else {
            const ddl = schema_mod.createTableDdl(
                arena,
                project_id,
                dataset_id,
                table_id,
                schema_node,
            ) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                // Go writes the empty string into the DDL and lets the CREATE
                // fail; either way the client sees a 400 rather than a column
                // silently typed STRING.
                error.UnknownFieldType => return badRequest(
                    arena,
                    "schema contains a field with an unsupported type",
                ),
            };
            server.db.exec(ddl, &.{}, .{}) catch {
                return .{
                    .status = .bad_request,
                    .body = try errors.body(
                        arena,
                        .invalid_query,
                        try query_handler.wrapEngineError(arena, server.db.lastError()),
                    ),
                };
            };
        }

        // The posted body is the table's resource from here on; the DDL just
        // made the spec it hangs off.
        var metadata_json: std.ArrayList(u8) = .empty;
        try tables_handler.writeMetadata(arena, &metadata_json, parsed);
        const db = server.db;
        db.setTableMetadata(arena, project_id, dataset_id, table_id, metadata_json.items) catch
            return internalError(arena, "table was created but its metadata was not recorded");

        const table_spec = (try db.catalogTable(arena, project_id, dataset_id, table_id)) orelse
            return internalError(arena, "table was created but is not in the catalog");
        return .{ .body = try server.tableResource(arena, table_spec) };
    }

    fn handleTablesGet(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const table_spec = (try s.db.catalogTable(arena, project_id, dataset_id, table_id)) orelse
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is not found",
                .{table_id},
            ));
        return .{ .body = try s.tableResource(arena, table_spec) };
    }

    /// The metadata API's resource for a catalog spec: what the client posted
    /// (`TableSpec.metadata`) under the keys the server computes. A spec
    /// nobody posted — created by DDL — renders its schema from its columns
    /// and, for a view, its query from the SQL it was written with.
    ///
    /// Public because the Storage Read API renders the same resource for a
    /// session's table.
    pub fn tableResource(
        s: *Server,
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) ![]const u8 {
        var out: std.ArrayList(u8) = .empty;
        try tables_handler.writeTable(arena, &out, try s.tableMeta(arena, table_spec));
        return out.items;
    }

    /// The parsed `metadata` of a spec, or null when nothing was posted.
    fn postedOf(
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) !?std.json.Value {
        const text = table_spec.metadata;
        if (text.len == 0) return null;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{}) catch return null;
        return if (v == .object) v else null;
    }

    /// The resource fields a spec carries beyond the ones the server computes: what the DDL that
    /// made the table implies (a view's query, PARTITION BY, CLUSTER BY, OPTIONS(description)),
    /// with what a client posted (`TableSpec.metadata`) over it. A posted field always wins: it is
    /// what the client said, and a later patch may have changed it. Null when there is neither.
    fn resourceFields(
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) !?std.json.Value {
        var obj: std.json.ObjectMap = .empty;
        // A view made by DDL has no posted `view`; the resource still reports
        // the query, as BigQuery does.
        if (table_spec.is_view and table_spec.source_sql.len > 0) {
            var view: std.json.ObjectMap = .empty;
            try view.put(arena, "query", .{ .string = table_spec.source_sql });
            try view.put(arena, "useLegacySql", .{ .bool = false });
            try obj.put(arena, "view", .{ .object = view });
        }
        try putPartitioningFields(arena, &obj, table_spec);
        if (table_spec.clustering.len > 0) {
            var fields: std.json.Array = .init(arena);
            for (table_spec.clustering) |name| try fields.append(.{ .string = name });
            var clustering: std.json.ObjectMap = .empty;
            try clustering.put(arena, "fields", .{ .array = fields });
            try obj.put(arena, "clustering", .{ .object = clustering });
        }
        if (table_spec.description.len > 0) {
            try obj.put(arena, "description", .{ .string = table_spec.description });
        }
        if (try postedOf(arena, table_spec)) |p| {
            var it = p.object.iterator();
            while (it.next()) |kv| try obj.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        if (obj.count() == 0) return null;
        return .{ .object = obj };
    }

    /// DDL PARTITION BY and the OPTIONS that configure it, as the Table resource's
    /// `timePartitioning`, `rangePartitioning` and `requirePartitionFilter`.
    /// https://cloud.google.com/bigquery/docs/reference/rest/v2/tables#Table
    fn putPartitioningFields(
        arena: std.mem.Allocator,
        obj: *std.json.ObjectMap,
        table_spec: *const zigquery.spec.TableSpec,
    ) !void {
        const partitioning = table_spec.partitioning orelse return;
        const require_filter = if (optionValue(table_spec, "require_partition_filter")) |v|
            std.mem.eql(u8, v, "true")
        else
            false;
        switch (partitioning) {
            .time => |t| {
                var tp: std.json.ObjectMap = .empty;
                try tp.put(arena, "type", .{ .string = @tagName(t.unit) });
                try tp.put(arena, "field", .{ .string = t.field });
                if (try partitionExpirationMs(arena, table_spec)) |ms| {
                    try tp.put(arena, "expirationMs", .{ .string = ms });
                }
                if (require_filter) try tp.put(arena, "requirePartitionFilter", .{ .bool = true });
                try obj.put(arena, "timePartitioning", .{ .object = tp });
            },
            .range => |r| {
                var range: std.json.ObjectMap = .empty;
                try range.put(arena, "start", .{
                    .string = try std.fmt.allocPrint(arena, "{d}", .{r.start}),
                });
                try range.put(arena, "end", .{
                    .string = try std.fmt.allocPrint(arena, "{d}", .{r.end}),
                });
                try range.put(arena, "interval", .{
                    .string = try std.fmt.allocPrint(arena, "{d}", .{r.interval}),
                });
                var rp: std.json.ObjectMap = .empty;
                try rp.put(arena, "field", .{ .string = r.field });
                try rp.put(arena, "range", .{ .object = range });
                try obj.put(arena, "rangePartitioning", .{ .object = rp });
            },
        }
        if (require_filter) try obj.put(arena, "requirePartitionFilter", .{ .bool = true });
    }

    /// The rendered value of a DDL option, or null when it was not set.
    fn optionValue(table_spec: *const zigquery.spec.TableSpec, name: []const u8) ?[]const u8 {
        for (table_spec.options) |opt| {
            if (std.ascii.eqlIgnoreCase(opt.name, name)) return opt.value;
        }
        return null;
    }

    /// `partition_expiration_days` in milliseconds, as the decimal string the
    /// REST resource carries INT64s as. Null when unset or not a usable
    /// number of days.
    fn partitionExpirationMs(
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) !?[]const u8 {
        const text = optionValue(table_spec, "partition_expiration_days") orelse return null;
        const days = std.fmt.parseFloat(f64, text) catch return null;
        // Guards the float-to-int conversion; BigQuery rejects negative days.
        if (!(days >= 0 and days < 1e9)) return null;
        const ms: i64 = @intFromFloat(@round(days * std.time.ms_per_day));
        return try std.fmt.allocPrint(arena, "{d}", .{ms});
    }

    /// The `schema` node a resource for this spec carries: the posted one
    /// when there is one, since only it knows nested modes and field
    /// descriptions, else the columns.
    fn schemaNode(
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) !?std.json.Value {
        if (try postedOf(arena, table_spec)) |posted| {
            if (posted.object.get("schema")) |schema| return schema;
        }
        return schemaJsonFromSpec(arena, table_spec);
    }

    fn tableMeta(
        s: *Server,
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) !tables_handler.TableMeta {
        const path = table_spec.name_path;
        const posted = try resourceFields(arena, table_spec);
        // A synthetic spec (a job's result table) carries no creation time.
        const created_micros = zigquery.catalog.epochMicrosFromRfc3339(table_spec.created_at);
        const created_millis: i64 = if (created_micros) |us|
            @divFloor(us, std.time.us_per_ms)
        else
            s.started_ms;
        return .{
            .project_id = path[0],
            .dataset_id = path[1],
            .table_id = path[2],
            .endpoint = s.endpoint,
            .created_millis = created_millis,
            .schema = try schemaNode(arena, table_spec),
            .kind = if (table_spec.is_view) "VIEW" else "TABLE",
            .posted = posted,
        };
    }

    fn handleTablesPatch(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const patch = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch {
            return badRequest(arena, "failed to decode request body");
        };
        if (patch == .object and patch.object.contains("schema")) {
            return badRequest(arena, "schema updates unsupported");
        }
        const table_spec = (try s.db.catalogTable(arena, project_id, dataset_id, table_id)) orelse
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is not found",
                .{table_id},
            ));
        const columns = try specColumnNames(arena, table_spec);
        if (try tableLayoutRejection(arena, patch, columns)) |rejection| return rejection;

        var merged: std.json.ObjectMap = .empty;
        if (try postedOf(arena, table_spec)) |current| {
            var it = current.object.iterator();
            while (it.next()) |kv| try merged.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        if (patch == .object) {
            var it = patch.object.iterator();
            while (it.next()) |kv| try merged.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }

        var metadata_json: std.ArrayList(u8) = .empty;
        try tables_handler.writeMetadata(arena, &metadata_json, .{ .object = merged });
        const json = metadata_json.items;
        const outcome = s.db.setTableMetadata(arena, project_id, dataset_id, table_id, json);
        outcome catch |err| switch (err) {
            // A query's result table exists for the analyzer only; there
            // is nothing to keep an update on.
            error.NotPersistent => return badRequest(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is a query result and cannot be updated",
                .{table_id},
            )),
            else => return internalError(arena, "table metadata was not recorded"),
        };
        const updated = (try s.db.catalogTable(arena, project_id, dataset_id, table_id)) orelse
            return internalError(arena, "table vanished while being patched");
        return .{ .body = try s.tableResource(arena, updated) };
    }

    /// A tables request's 400 when the layout fields of `resource` name none of `columns`.
    fn tableLayoutRejection(
        arena: std.mem.Allocator,
        resource: std.json.Value,
        columns: []const []const u8,
    ) !?http_server.Response {
        if (resource != .object) return null;
        const layout_error =
            tables_handler.layoutError(resource.object, columns) orelse return null;
        return try badRequest(arena, try layout_error.message(arena, .table));
    }

    /// A catalog spec's top-level column names.
    fn specColumnNames(
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) ![]const []const u8 {
        const names = try arena.alloc([]const u8, table_spec.columns.len);
        for (table_spec.columns, names) |column, *name| name.* = column.name;
        return names;
    }

    /// A catalog spec's columns as the parsed `schema` node of a table
    /// resource. Null when the schema will not re-parse, which leaves the
    /// resource schema-less rather than failing the request.
    fn schemaJsonFromSpec(
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) !?std.json.Value {
        var sbuf: std.ArrayList(u8) = .empty;
        try schema_mod.writeSchemaFromSpec(arena, &sbuf, table_spec);
        return std.json.parseFromSliceLeaky(std.json.Value, arena, sbuf.items, .{}) catch null;
    }

    fn handleTablesList(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        if (!try s.db.datasetExists(arena, project_id, dataset_id)) {
            return datasetNotFound(arena, project_id, dataset_id);
        }
        const specs = try s.db.catalogTablesIn(arena, project_id, dataset_id);
        // The catalog holds registration order; the API lists by id.
        std.mem.sort(*const zigquery.spec.TableSpec, @constCast(specs), {}, tableIdLessThan);

        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "{\"tables\":[");
        for (specs, 0..) |table_spec, i| {
            if (i > 0) try out.append(arena, ',');
            try tables_handler.writeTableListEntry(arena, &out, try s.tableMeta(arena, table_spec));
        }
        try out.appendSlice(arena, "],\"totalItems\":");
        try out.print(arena, "{d}", .{specs.len});
        try out.append(arena, '}');
        return .{ .body = out.items };
    }

    fn tableIdLessThan(
        _: void,
        a: *const zigquery.spec.TableSpec,
        b: *const zigquery.spec.TableSpec,
    ) bool {
        return std.mem.lessThan(u8, a.name_path[2], b.name_path[2]);
    }

    fn handleTablesDelete(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const table_spec = (try s.db.catalogTable(arena, project_id, dataset_id, table_id)) orelse
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is not found",
                .{table_id},
            ));
        // IF EXISTS: the spec is what is being removed; the SQLite object may
        // already be gone, and the spec must not outlive this request either way.
        const ddl = try std.fmt.allocPrint(
            arena,
            "DROP {s} IF EXISTS `{s}.{s}.{s}`",
            .{ if (table_spec.is_view) "VIEW" else "TABLE", project_id, dataset_id, table_id },
        );
        s.db.exec(ddl, &.{}, .{}) catch {
            return internalError(arena, try query_handler.wrapEngineError(arena, s.db.lastError()));
        };
        return .{ .body = "" };
    }

    /// /table/<table>/insertAll handler
    ///
    /// Responds:
    /// 200 OK: batch was written; per-row errors may appear in `inserErrors`
    /// 500: internal engine failure
    fn handleTabledataInsertAll(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch {
            return badRequest(arena, "failed to decode request body");
        };

        const table_spec = (try s.db.catalogTable(arena, project_id, dataset_id, table_id)) orelse
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is not found",
                .{table_id},
            ));
        const fields = tabledata_handler.fieldsOfSchema(try schemaNode(arena, table_spec)) orelse
            return internalError(arena, try std.fmt.allocPrint(
                arena,
                "table {s} has no schema",
                .{table_id},
            ));

        var rows = tabledata_handler.rowsFromBody(arena, parsed) catch
            return badRequest(arena, "failed to decode request body");
        const skip_invalid = tabledata_handler.skipInvalidRows(parsed);
        const ignore_unknown = tabledata_handler.ignoreUnknownValues(parsed);

        // An undeclared field is dropped or makes its row invalid, and an
        // invalid row stops the batch unless the rest may be written.
        var unknown: []const tabledata_handler.InsertError = &.{};
        if (ignore_unknown) {
            rows = try tabledata_handler.stripUnknownFields(arena, fields, rows);
        } else {
            unknown = try tabledata_handler.validateAgainstSchema(arena, fields, rows);
            if (unknown.len > 0 and !skip_invalid) {
                // Nothing is written, and the status stays 200: the errors
                // are the response body, not an HTTP failure.
                var out: std.ArrayList(u8) = .empty;
                try tabledata_handler.writeInsertErrors(arena, &out, unknown, rows.len);
                return .{ .body = out.items };
            }
        }

        const write_set = try tabledata_handler.rowsToWrite(arena, rows, unknown);
        var repo = contentdata.Repository{ .arena = arena, .db = s.db };
        const result = repo.addTableData(
            project_id,
            dataset_id,
            table_id,
            fields,
            write_set.rows,
            .{ .skip_invalid_rows = skip_invalid, .ignore_unknown_values = ignore_unknown },
        ) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return internalError(arena, repo.message),
        };
        // The writer numbered the rows it was given; report the posted ones.
        if (write_set.posted_index) |posted| {
            for (result.invalid) |*e| e.row_index = posted[e.row_index];
        }

        const invalid = try tabledata_handler.mergeInsertErrorsByRow(
            arena,
            unknown,
            result.invalid,
        );
        if (invalid.len > 0) {
            var out: std.ArrayList(u8) = .empty;
            try tabledata_handler.writeInsertErrors(
                arena,
                &out,
                invalid,
                if (skip_invalid) null else rows.len,
            );
            return .{ .body = out.items };
        }

        return .{ .body = "{}" };
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
        // DDL in this job resolves `dataset.table` against the job's project;
        // outside a job it is the server's, whatever ran last.
        s.db.default_project = project_id;
        defer s.db.default_project = s.project;

        const job = jobs_handler.parseInsert(arena, req.body) catch {
            return badRequest(arena, "failed to decode request body");
        };

        return switch (jobConfigKind(job)) {
            .query => s.handleQueryJob(arena, req, project_id, job),
            .copy => s.handleCopyConfig(arena, project_id, job),
            .load => s.handleLoadConfig(arena, req, project_id, job),
            .extract => badRequest(arena, "configuration.extract is not supported"),
            .none => badRequest(
                arena,
                "configuration must carry one of query, copy or load",
            ),
        };
    }

    /// Which `configuration.*` member a jobs.insert body carries. `jobType` is output only, so
    /// the kind is whichever member is set.
    const JobConfigKind = enum { query, copy, load, extract, none };

    fn jobConfigKind(job: *const pb.Job) JobConfigKind {
        const cfg = job.configuration orelse return .none;
        if (cfg.copy != null) return .copy;
        if (cfg.load != null) return .load;
        if (cfg.extract != null) return .extract;
        if (cfg.query != null) return .query;
        return .none;
    }

    fn handleCopyConfig(
        s: *Server,
        arena: std.mem.Allocator,
        project_id: []const u8,
        job: *const pb.Job,
    ) !http_server.Response {
        const parsed = copy_handler.parse(arena, job) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return badRequest(arena, copy_handler.parseErrorMessage(err)),
        };
        const copy = parsed orelse return badRequest(arena, "configuration.copy is required");
        return s.handleCopyJob(arena, project_id, copy);
    }

    /// A load job posted to `/jobs` rather than to the upload endpoint, so it names its data
    /// rather than carrying it.
    fn handleLoadConfig(
        s: *Server,
        arena: std.mem.Allocator,
        req: *const http_server.Request,
        project_id: []const u8,
        job: *const pb.Job,
    ) !http_server.Response {
        _ = s;
        _ = req;
        _ = project_id;
        const cfg = job.configuration.?.load.?;
        if (cfg.source_uris.len != 0) {
            return badRequest(
                arena,
                "configuration.load.sourceUris is not supported: upload the data instead",
            );
        }
        return badRequest(arena, "configuration.load requires the upload endpoint");
    }

    // ---- the media upload endpoint ----

    /// `POST /upload/...`, which either carries the whole job or opens a resumable session.
    fn handleUploadInsert(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        s.db.default_project = project_id;
        defer s.db.default_project = s.project;

        const upload_type = if (req.queryParam("uploadType")) |text|
            upload.UploadType.parse(text)
        else
            null;

        if (upload_type == .resumable) return s.openUploadSession(req, project_id);

        const content_type = req.headers.content_type orelse "";
        const boundary = upload.boundaryFrom(content_type) orelse {
            return badRequest(arena, "a multipart upload needs a boundary in its Content-Type");
        };
        const parts = upload.parseMultipart(req.body, boundary) catch {
            return badRequest(arena, "the upload body is not two multipart/related parts");
        };
        return s.runLoadJob(arena, project_id, parts.metadata, parts.media);
    }

    /// The initiating request of a resumable upload. Answers with the session URI the bytes
    /// are sent to. api-uploads
    fn openUploadSession(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        const now = nowMillis();
        s.uploads.sweep(now);

        const declared: ?u64 = if (req.headers.x_upload_content_length) |text|
            std.fmt.parseInt(u64, text, 10) catch null
        else
            null;

        const id = try query_handler.randomId(arena, &s.rng);
        _ = s.uploads.create(id, project_id, req.body, declared, now) catch |err| switch (err) {
            error.OutOfMemory => return err,
        };

        return .{
            .status = .ok,
            .body = "",
            .extra_headers = try arena.dupe(std.http.Header, &.{.{
                .name = "location",
                .value = try std.fmt.allocPrint(
                    arena,
                    "http://{s}/upload/bigquery/v2/projects/{s}/jobs" ++
                        "?uploadType=resumable&upload_id={s}",
                    .{ s.endpoint, project_id, id },
                ),
            }}),
        };
    }

    /// `PUT` to a session URI: another chunk, or a question about how many bytes landed.
    fn handleUploadResume(
        s: *Server,
        req: *const http_server.Request,
        project_id: []const u8,
    ) !http_server.Response {
        const arena = req.arena;
        s.db.default_project = project_id;
        defer s.db.default_project = s.project;

        const id = req.queryParam("upload_id") orelse {
            return badRequest(arena, "a resumable upload needs its upload_id");
        };
        // A session the server no longer holds cannot be resumed, and the client is expected
        // to start again. api-uploads
        const session = s.uploads.get(id) orelse return .{
            .status = .not_found,
            .body = try errors.body(arena, .not_found, "upload session not found"),
        };

        const range: ?upload.ContentRange = if (req.headers.content_range) |text|
            upload.parseContentRange(text) catch {
                return badRequest(arena, "malformed Content-Range");
            }
        else
            null;

        if (range) |r| {
            if (r.isStatusQuery()) return incompleteUpload(arena, session.received());
            s.uploads.append(session, r, req.body, nowMillis()) catch |err| switch (err) {
                error.OutOfMemory => return err,
                error.TooLarge => return badRequest(arena, "upload exceeds the size this " ++
                    "emulator accepts"),
                error.RangeMismatch => return badRequest(
                    arena,
                    "Content-Range does not continue this upload",
                ),
                else => return badRequest(arena, "malformed Content-Range"),
            };
            if (!session.isComplete(r)) return incompleteUpload(arena, session.received());
        } else {
            // No Content-Range: the whole body in one request.
            s.uploads.append(session, .{}, req.body, nowMillis()) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return badRequest(arena, "upload could not be accepted"),
            };
        }

        const metadata = try arena.dupe(u8, session.metadata);
        const media = try arena.dupe(u8, session.bytes.items);
        // The bytes have been read out; the session has no further use for its copy.
        s.uploads.finish(id);

        // 200 with the job resource, which is what the client accepts from a completed
        // resumable upload alongside the 308 it takes between chunks.
        return s.runLoadJob(arena, project_id, metadata, media);
    }

    /// Reads `media` under the configuration in `metadata` and writes the rows it yields.
    ///
    /// Everything settled without writing a row answers the upload request; a failure found
    /// while reading rows completes the job and rides in status.errorResult. docs/adr/0002
    fn runLoadJob(
        s: *Server,
        arena: std.mem.Allocator,
        project_id: []const u8,
        metadata: []const u8,
        media: []const u8,
    ) !http_server.Response {
        const job = jobs_handler.parseInsert(arena, metadata) catch {
            return badRequest(arena, "failed to decode the upload's job configuration");
        };
        const parsed = load_handler.parse(job) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return badRequest(arena, load_handler.parseErrorMessage(err)),
        };
        const spec = parsed orelse
            return badRequest(arena, "the upload carries no configuration.load");

        const dst = spec.destination;
        if (!try s.db.datasetExists(arena, dst.project_id, dst.dataset_id)) {
            return datasetNotFound(arena, dst.project_id, dst.dataset_id);
        }

        const existing = try s.db.catalogTable(
            arena,
            dst.project_id,
            dst.dataset_id,
            dst.table_id,
        );

        const job_id = try query_handler.randomId(arena, &s.rng);
        const unix_seconds = @divFloor(@as(i64, @bitCast(nowSeed())), 1_000_000);

        // CREATE_NEVER reports a missing destination in the job result.
        // rest/v2/Job#jobconfigurationload
        if (existing == null and !spec.mayCreateDestination()) {
            return s.storeLoadJob(arena, project_id, job_id, spec, unix_seconds, .{
                .failed = .{
                    .reason = "notFound",
                    .message = try std.fmt.allocPrint(
                        arena,
                        "Not found: Table {s}",
                        .{try dst.display(arena)},
                    ),
                },
            });
        }
        if (existing != null and spec.refusesOccupiedDestination()) {
            if (try s.tableRowCount(arena, existing.?) > 0) {
                return s.storeLoadJob(arena, project_id, job_id, spec, unix_seconds, .{
                    .failed = .{
                        .reason = "duplicate",
                        .message = try std.fmt.allocPrint(
                            arena,
                            "Already Exists: Table {s}",
                            .{try dst.display(arena)},
                        ),
                    },
                });
            }
        }

        const read = load_rows.read(arena, media, spec, existing) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return badRequest(arena, load_rows.readErrorMessage(err)),
        };

        const tooManyBadRecords = struct {
            fn response(
                server: *Server,
                a: std.mem.Allocator,
                p: []const u8,
                id: []const u8,
                sp: load_handler.LoadSpec,
                seconds: i64,
            ) !http_server.Response {
                return server.storeLoadJob(a, p, id, sp, seconds, .{
                    .failed = .{
                        .reason = "invalid",
                        .message = "Error while reading data, error message: " ++
                            "CSV processing encountered too many errors, giving up.",
                    },
                });
            }
        }.response;

        if (read.bad_records > spec.max_bad_records) {
            return tooManyBadRecords(s, arena, project_id, job_id, spec, unix_seconds);
        }

        // One transaction: a load that turns out to carry too many bad records leaves the
        // destination as it was. rest/v2/Job#jobconfigurationload
        try s.db.rawExec("BEGIN", &.{});
        var committed = false;
        defer if (!committed) s.db.rawExec("ROLLBACK", &.{}) catch {};

        const rejected = s.writeLoadedRows(arena, spec, read, existing != null) catch |err| {
            if (err == error.OutOfMemory) return err;
            return internalError(arena, s.db.lastError());
        };

        // A row the reader accepted can still be one the engine will not store.
        const bad_records = read.bad_records + rejected;
        if (bad_records > spec.max_bad_records) {
            s.db.rawExec("ROLLBACK", &.{}) catch {};
            committed = true; // the deferred rollback has nothing left to undo
            // The rollback returns SQLite to where it was, but a table the load created is
            // also in the analyzer's catalog, which the transaction does not cover. A job
            // that wrote nothing must not leave a destination behind.
            if (existing == null) {
                s.db.exec(try std.fmt.allocPrint(
                    arena,
                    "DROP TABLE IF EXISTS `{s}.{s}.{s}`",
                    .{ dst.project_id, dst.dataset_id, dst.table_id },
                ), &.{}, .{}) catch {};
            }
            return tooManyBadRecords(s, arena, project_id, job_id, spec, unix_seconds);
        }

        try s.db.rawExec("COMMIT", &.{});
        committed = true;

        return s.storeLoadJob(arena, project_id, job_id, spec, unix_seconds, .{
            .loaded = .{
                .input_file_bytes = media.len,
                .output_rows = read.rowCount() - rejected,
                .bad_records = bad_records,
            },
        });
    }

    /// Brings the destination into the shape the load decided on, writes the rows, and answers
    /// with how many of them the engine would not store.
    fn writeLoadedRows(
        s: *Server,
        arena: std.mem.Allocator,
        spec: load_handler.LoadSpec,
        read: load_rows.Reading,
        destination_exists: bool,
    ) !u64 {
        const dst = spec.destination;
        if (!destination_exists or spec.replacesDestination()) {
            const ddl = try schema_mod.createTableDdl(
                arena,
                dst.project_id,
                dst.dataset_id,
                dst.table_id,
                read.schema_node,
            );
            if (spec.replacesDestination() and destination_exists) {
                try s.db.exec(try std.fmt.allocPrint(
                    arena,
                    "DROP TABLE IF EXISTS `{s}.{s}.{s}`",
                    .{ dst.project_id, dst.dataset_id, dst.table_id },
                ), &.{}, .{});
            }
            try s.db.exec(ddl, &.{}, .{});
            var metadata_json: std.ArrayList(u8) = .empty;
            try tables_handler.writeMetadata(arena, &metadata_json, read.schema_node);
            s.db.setTableMetadata(
                arena,
                dst.project_id,
                dst.dataset_id,
                dst.table_id,
                metadata_json.items,
            ) catch {};
        }

        if (read.rowCount() == 0) return 0;
        var repo = contentdata.Repository{ .arena = arena, .db = s.db };
        var batcher = try load_rows.Batcher.init(arena, read, spec);
        var rejected: u64 = 0;
        while (try batcher.next()) |batch| {
            // Rows are skipped rather than rolled back, so the ones that failed can be
            // counted against maxBadRecords.
            const result = try repo.addTableData(
                dst.project_id,
                dst.dataset_id,
                dst.table_id,
                read.schema_fields,
                batch,
                .{
                    .skip_invalid_rows = true,
                    .ignore_unknown_values = spec.ignore_unknown_values,
                    .manage_transaction = false,
                },
            );
            rejected += result.invalid.len;
        }
        return rejected + batcher.bad_records;
    }

    fn storeLoadJob(
        s: *Server,
        arena: std.mem.Allocator,
        project_id: []const u8,
        job_id: []const u8,
        spec: load_handler.LoadSpec,
        unix_seconds: i64,
        outcome: load_handler.Outcome,
    ) !http_server.Response {
        var resource: std.ArrayList(u8) = .empty;
        try load_handler.writeJobResource(arena, &resource, .{
            .project_id = project_id,
            .job_id = job_id,
            .endpoint = s.endpoint,
            .unix_seconds = unix_seconds,
            .load = spec,
            .outcome = outcome,
        });
        try s.jobs.put(project_id, job_id, .load, .{
            .names = &.{},
            .types = &.{},
            .cells = &.{},
            .total_rows = 0,
        }, resource.items);
        return .{ .body = resource.items };
    }

    /// 308 with what the session holds so far, which is how a resumable upload reports both a
    /// partial chunk and a status query. api-uploads
    fn incompleteUpload(arena: std.mem.Allocator, received: u64) !http_server.Response {
        return .{
            .status = .permanent_redirect,
            .body = "",
            .extra_headers = try arena.dupe(std.http.Header, &.{.{
                .name = "range",
                .value = if (received == 0)
                    "bytes=0-0"
                else
                    try std.fmt.allocPrint(arena, "bytes=0-{d}", .{received - 1}),
            }}),
        };
    }

    fn handleQueryJob(
        s: *Server,
        arena: std.mem.Allocator,
        req: *const http_server.Request,
        project_id: []const u8,
        job: *const pb.Job,
    ) !http_server.Response {
        const sql = jobs_handler.queryFromJobConfig(job) orelse {
            return badRequest(arena, "configuration.query.query is required");
        };
        const params = jobs_handler.parametersFromJobConfig(arena, job) catch |err| switch (err) {
            error.OutOfMemory => return err,
            error.InvalidParameter,
            error.InvalidBase64Value,
            => return badRequest(arena, "invalid query parameter"),
        };

        const job_id = try query_handler.randomId(arena, &s.rng);
        const job_t0 = nowSeed();

        // Go's jobsInsertHandler never calls internaltypes.Format — only
        // jobs.query, getQueryResults and tabledata.list do. The rendering
        // chosen here only reaches `res.body`, which jobs.insert discards in
        // favour of the job resource, so it follows the request rather than
        // being forced on. Both renderings still land in the stored ResultSet,
        // because the flag that decides between them rides on the later
        // getQueryResults call, long after this request's arena is gone.
        const int64_ts = query_handler.int64TimestampFromQuery(arena, req.query);

        // A query job may carry a destination table: this is how view
        // materialization writes results. Run the DDL form instead of the
        // bare SELECT, then record the resulting table's metadata.
        const res = if (jobs_handler.destinationFromJobConfig(job)) |dst| blk: {
            // BigQuery refuses the job before running anything when the
            // destination's dataset does not exist; so does the engine's own
            // check inside the DDL below, but this one names the dataset in
            // the API's own wording and skips the query entirely.
            if (!try s.db.datasetExists(arena, dst.project_id, dst.dataset_id)) {
                return notFound(arena, try std.fmt.allocPrint(
                    arena,
                    "Not found: Dataset {s}:{s} was not found in location US",
                    .{ dst.project_id, dst.dataset_id },
                ));
            }
            const layout_fields = try jobs_handler.destinationLayoutFields(arena, req.body);
            if (try s.queryLayoutRejection(arena, sql, layout_fields)) |rejection| return rejection;
            const prior_metadata: []const u8 = if (try s.db.catalogTable(
                arena,
                dst.project_id,
                dst.dataset_id,
                dst.table_id,
            )) |existing| existing.metadata else "";
            const materialization_method = s.materializeInto(
                arena,
                dst,
                sql,
                params,
            ) catch |err| switch (err) {
                error.MaterializeFailed => return .{
                    .status = .bad_request,
                    .body = try errors.body(
                        arena,
                        .invalid_query,
                        try query_handler.wrapEngineError(arena, s.db.lastError()),
                    ),
                },
                else => return err,
            };
            try s.recordMaterializedTable(
                arena,
                dst,
                materialization_method,
                prior_metadata,
                layout_fields,
            );
            // The job's own result mirrors the query's SELECT output, the same
            // rows just written to the destination table — not the table's
            // full contents, which for WRITE_APPEND can hold more than this
            // query contributed. Re-running `sql` is safe: both DDL forms
            // above wrap it rather than consume it, so its placeholders are
            // still there for `params` to fill again (see materializeInto).
            break :blk try query_handler.runQueryFormatted(
                arena,
                s.db,
                project_id,
                job_id,
                sql,
                params,
                int64_ts,
            );
        } else try query_handler.runQueryFormatted(
            arena,
            s.db,
            project_id,
            job_id,
            sql,
            params,
            int64_ts,
        );
        s.slow_queries.record(nowSeed() -| job_t0, sql);

        if (!res.ok) {
            // Log the statement alongside the failure: an analyzer message on
            // its own rarely identifies which query produced it.
            std.log.warn(
                "job failed: {s}\n  sql: {s}",
                .{ s.db.lastError(), sql[0..@min(sql.len, 600)] },
            );
            return .{ .status = res.status, .body = res.body };
        }

        var resource: std.ArrayList(u8) = .empty;
        try jobs_handler.writeJobResource(arena, &resource, .{
            .project_id = project_id,
            .job_id = job_id,
            .sql = sql,
            .endpoint = s.endpoint,
            .total_bytes = res.total_bytes,
            .unix_seconds = @divFloor(@as(i64, @bitCast(nowSeed())), 1_000_000),
            .outcome = res.set.?.outcome,
        });

        try s.jobs.put(project_id, job_id, .query, res.set.?, resource.items);
        // The destination table the resource above advertises. Registered now,
        // eagerly, because it costs nothing to: the rows are already in the
        // store and the table is a view onto them rather than a copy
        // (docs/MATERIALIZE_COST.md §4d).
        const stored = s.jobs.get(job_id) orelse return error.JobMissing;
        s.registerJobDestination(arena, project_id, stored) catch |err| {
            // Not fatal to the job, which has already run and been stored: the
            // client's result is unaffected and only a read of the destination
            // would notice.
            std.log.warn("job {s}: destination table unavailable: {t}", .{ job_id, err });
        };
        return .{ .body = resource.items };
    }

    /// Clears job-results tables a previous process left behind.
    ///
    /// They are virtual tables in `main`, so a file-backed database keeps them
    /// in `sqlite_master` across a restart — and their rows lived in the job
    /// store of the process that made them, which is gone. Every one found here
    /// is stale by definition. An in-memory database never has any.
    fn dropStaleJobTables(s: *Server, arena: std.mem.Allocator) !void {
        // Collected before dropping: the drops invalidate the scan.
        const names = try s.staleJobTableNames(arena);
        for (names) |name| {
            const sql = try std.fmt.allocPrintSentinel(arena, "DROP TABLE `{s}`", .{name}, 0);
            s.db.rawExec(sql, &.{}) catch |err| {
                std.log.warn("stale job table {s} could not be dropped: {t}", .{ name, err });
            };
        }
        if (names.len != 0) {
            std.log.info("dropped {d} stale job result table(s)", .{names.len});
        }
    }

    fn staleJobTableNames(s: *Server, arena: std.mem.Allocator) ![]const []const u8 {
        var names: std.ArrayList([]const u8) = .empty;
        var rows = try s.db.rawQuery(job_rows_vtab.find_stale_sql, &.{});
        defer rows.deinit();
        while (try rows.next()) |row| try names.append(arena, try arena.dupe(u8, row[0].text));
        return names.toOwnedSlice(arena);
    }

    /// Makes a finished job's result readable as `<project>._anon.<job_id>`.
    ///
    /// Two halves, and neither copies a row. A synthetic `TableSpec` so the
    /// GoogleSQL analyzer resolves the name — memory-only, because the rows
    /// live in the job store for the length of a process and a persisted spec
    /// would come back on reopen naming a table with nothing behind it. And a
    /// virtual table of the same canonical name so SQLite resolves it, which is
    /// what lets an ordinary table reference reach it with no transformer rule.
    ///
    /// A result with no columns is skipped: DDL and DML jobs have none, and a
    /// zero-column table is not a thing SQLite will declare. Go skips on
    /// `TotalRows > 0`, which also drops a SELECT that legitimately returned
    /// nothing — this keeps that one, as an empty table, which is what BigQuery
    /// has.
    fn registerJobDestination(
        s: *Server,
        arena: std.mem.Allocator,
        project_id: []const u8,
        job: query_handler.Job,
    ) !void {
        if (job.set.names.len == 0) return;
        // The catalog holds the spec by pointer and the job store outlives it,
        // so both live in the job's own arena rather than this request's.
        const job_id = job.job_id;
        const job_arena = job.arena.allocator();

        const columns = try job_arena.alloc(*zigquery.spec.ColumnSpec, job.set.names.len);
        for (columns, job.set.names, job.set.types) |*dst, name, t| {
            const col = try job_arena.create(zigquery.spec.ColumnSpec);
            col.* = .{ .name = name, .type = t };
            dst.* = col;
        }
        const name_path = try job_arena.alloc([]const u8, 3);
        name_path[0] = try job_arena.dupe(u8, project_id);
        name_path[1] = job_rows_vtab.anon_segment;
        name_path[2] = job.job_id;
        const table_spec = try job_arena.create(zigquery.spec.TableSpec);
        table_spec.* = .{ .name_path = name_path, .columns = columns };

        {
            var g = s.db.lockCatalog();
            defer g.unlock();
            try g.catalog.addSyntheticTableSpec(table_spec);
        }

        const sqlite_name = try table_spec.tableName(arena);
        const create = try job_rows_vtab.createSql(arena, sqlite_name, job_id, job.set.names);
        try s.db.rawExec(create, &.{});
    }

    /// A query job's 400 when the destination layout it asks for names a column the query does
    /// not output. Null when every field resolves, and when the query does not prepare, which
    /// leaves that failure to the run that reports it.
    fn queryLayoutRejection(
        s: *Server,
        arena: std.mem.Allocator,
        sql: []const u8,
        layout_fields: std.json.ObjectMap,
    ) !?http_server.Response {
        if (layout_fields.count() == 0) return null;
        var prepared = s.db.prepare(sql, .{}) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return null,
        };
        defer prepared.deinit();
        if (prepared.columns.len == 0) return null;
        const columns = try arena.alloc([]const u8, prepared.columns.len);
        for (prepared.columns, columns) |column, *name| name.* = column.name;
        const layout_error = tables_handler.layoutError(layout_fields, columns) orelse return null;
        return try badRequest(arena, try layout_error.message(arena, .query_job));
    }

    /// Writes a query's results into its destination table.
    ///
    /// Go never issues INSERT ... SELECT here: it runs the query, derives a
    /// table definition from the result schema, and writes the rows — so the
    /// query defines the destination's shape and a previously declared schema
    /// never constrains it (handler.go jobsInsertHandler). An append is tried
    /// first to preserve existing rows, but if the destination's shape does
    /// not admit the result, the table is rebuilt from the query, which is
    /// what Go effectively does.
    ///
    /// Shape is the analyzer's verdict. A row the destination's constraints
    /// reject, such as NULL in a REQUIRED column, fails the job with the
    /// engine's message and leaves the table as it was.
    ///
    /// Reports which form ran, because the two leave the destination's
    /// declared resource in different states (see recordMaterializedTable).
    // ---- copy jobs ----

    /// jobs.insert carrying a `configuration.copy`.
    ///
    /// Existence is settled first and answered with an HTTP status. A failure found after that
    /// completes the job and rides in `status.errorResult`. docs/adr/0001.
    fn handleCopyJob(
        s: *Server,
        arena: std.mem.Allocator,
        project_id: []const u8,
        copy: copy_handler.CopySpec,
    ) !http_server.Response {
        for (copy.sources) |src| {
            if (!try s.db.datasetExists(arena, src.project_id, src.dataset_id)) {
                return datasetNotFound(arena, src.project_id, src.dataset_id);
            }
        }
        const dst = copy.destination;
        if (!try s.db.datasetExists(arena, dst.project_id, dst.dataset_id)) {
            return datasetNotFound(arena, dst.project_id, dst.dataset_id);
        }

        const source_specs = try arena.alloc(*const zigquery.spec.TableSpec, copy.sources.len);
        for (copy.sources, source_specs) |src, *slot| {
            slot.* = try s.db.catalogTable(
                arena,
                src.project_id,
                src.dataset_id,
                src.table_id,
            ) orelse return notFound(arena, try tableNotFound(arena, src));
        }

        const job_id = try query_handler.randomId(arena, &s.rng);
        const unix_seconds = @divFloor(@as(i64, @bitCast(nowSeed())), 1_000_000);

        const prior_metadata: []const u8 = if (try s.db.catalogTable(
            arena,
            dst.project_id,
            dst.dataset_id,
            dst.table_id,
        )) |existing| existing.metadata else "";

        const outcome: copy_handler.Outcome =
            if (try s.copyFailure(arena, copy, source_specs)) |failure|
                .{ .failed = failure }
            else blk: {
                const copied = s.runCopy(arena, copy, source_specs) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return internalError(arena, s.db.lastError()),
                };
                // A rebuilt destination keeps the resource fields it had, schema aside, as a
                // truncating query job's does. A copy job declares no layout of its own.
                if (copy.write_disposition != .WRITE_APPEND) {
                    try s.recordMaterializedTable(arena, .{
                        .project_id = dst.project_id,
                        .dataset_id = dst.dataset_id,
                        .table_id = dst.table_id,
                    }, .replaced, prior_metadata, .empty);
                }
                break :blk .{ .copied = copied };
            };

        var resource: std.ArrayList(u8) = .empty;
        try copy_handler.writeJobResource(arena, &resource, .{
            .project_id = project_id,
            .job_id = job_id,
            .endpoint = s.endpoint,
            .unix_seconds = unix_seconds,
            .copy = copy,
            .outcome = outcome,
        });
        // No result set: a copy job's rows are in the destination, and getQueryResults refuses
        // a job that is not a query job.
        try s.jobs.put(project_id, job_id, .copy, .{
            .names = &.{},
            .types = &.{},
            .cells = &.{},
            .total_rows = 0,
        }, resource.items);
        return .{ .body = resource.items };
    }

    /// The first reason this copy cannot run, in the order BigQuery reports them.
    fn copyFailure(
        s: *Server,
        arena: std.mem.Allocator,
        copy: copy_handler.CopySpec,
        source_specs: []const *const zigquery.spec.TableSpec,
    ) !?copy_handler.Outcome.Failure {
        for (copy.sources, source_specs) |src, src_spec| {
            if (src_spec.is_view) return .{
                .reason = "invalid",
                .message = try copy_handler.viewSourceMessage(arena, src),
            };
        }

        // The sources agree with one another before any of them is read, so a mismatch on the
        // last one leaves the destination untouched.
        for (source_specs[1..]) |other| {
            if (!copy_handler.identicalSchemas(source_specs[0], other)) return .{
                .reason = "invalid",
                .message = try copy_handler.incompatibleSourcesMessage(arena, copy.sources),
            };
        }

        const dst = copy.destination;
        const existing = try s.db.catalogTable(
            arena,
            dst.project_id,
            dst.dataset_id,
            dst.table_id,
        );
        if (existing) |dest_spec| {
            if (copy.refusesOccupiedDestination() and try s.tableRowCount(arena, dest_spec) > 0) {
                return .{
                    .reason = "duplicate",
                    .message = try std.fmt.allocPrint(
                        arena,
                        "Already Exists: Table {s}",
                        .{try dst.display(arena)},
                    ),
                };
            }
            if (copy.write_disposition == .WRITE_APPEND) {
                if (copy_handler.appendMismatch(source_specs[0], dest_spec)) |mismatch| return .{
                    .reason = "invalid",
                    .message = try copy_handler.appendMismatchMessage(arena, dst, mismatch),
                };
            }
        } else if (!copy.mayCreateDestination()) return .{
            .reason = "notFound",
            .message = try tableNotFound(arena, dst),
        };
        return null;
    }

    /// Copies every source into the destination under one transaction, and answers with the
    /// number of rows copied.
    ///
    /// Counting the sources rather than the statements: `CREATE TABLE AS SELECT` leaves
    /// SQLite's change counter alone, so a truncating copy would otherwise report nothing.
    fn runCopy(
        s: *Server,
        arena: std.mem.Allocator,
        copy: copy_handler.CopySpec,
        source_specs: []const *const zigquery.spec.TableSpec,
    ) !i64 {
        var copied: i64 = 0;
        for (source_specs) |src_spec| copied += try s.tableRowCount(arena, src_spec);

        const dst = copy.destination;
        const destination: jobs_handler.Destination = .{
            .project_id = dst.project_id,
            .dataset_id = dst.dataset_id,
            .table_id = dst.table_id,
        };

        try s.db.rawExec("BEGIN", &.{});
        errdefer s.db.rawExec("ROLLBACK", &.{}) catch {};

        for (copy.sources, 0..) |src, i| {
            const select = try std.fmt.allocPrint(arena, "SELECT * FROM `{s}.{s}.{s}`", .{
                src.project_id, src.dataset_id, src.table_id,
            });
            // The first source defines the destination unless the job appends to it. Every
            // source after the first appends, whatever the disposition.
            const defines_destination = i == 0 and copy.write_disposition != .WRITE_APPEND;
            const ddl = if (defines_destination)
                try jobs_handler.replaceDdl(arena, destination, select)
            else
                try jobs_handler.appendDdl(arena, destination, select);
            try s.db.exec(ddl, &.{}, .{});
        }

        try s.db.rawExec("COMMIT", &.{});
        return copied;
    }

    fn tableRowCount(
        s: *Server,
        arena: std.mem.Allocator,
        table_spec: *const zigquery.spec.TableSpec,
    ) !i64 {
        const sql = try std.fmt.allocPrintSentinel(
            arena,
            "SELECT COUNT(*) FROM `{s}`",
            .{try table_spec.tableName(arena)},
            0,
        );
        var rows = try s.db.rawQuery(sql, &.{});
        defer rows.deinit();
        const row = try rows.next() orelse return 0;
        return switch (row[0]) {
            .int => |n| n,
            else => 0,
        };
    }

    const MaterializationMethod = enum {
        /// The rows were appended; the table's shape is as declared.
        appended,
        /// The table was rebuilt from the query; its shape is the query's.
        replaced,
    };

    fn materializeInto(
        s: *Server,
        arena: std.mem.Allocator,
        dst: jobs_handler.Destination,
        sql: []const u8,
        /// The job's queryParameters. Both DDL forms below *wrap* the user's
        /// SQL, so its placeholders are still in there and still need values.
        /// Neither wrapper prepends a placeholder of its own, so positional
        /// ordinals are unchanged; and running the SQL twice (append, then
        /// replace) is safe because each exec re-slices from `params`.
        params: []const driver.Param,
    ) !MaterializationMethod {
        if (jobs_handler.isAppend(dst)) {
            const append = try jobs_handler.appendDdl(arena, dst, sql);
            if (s.db.exec(append, params, .{})) |_| return .appended else |err| switch (err) {
                error.ExecFailed => return error.MaterializeFailed,
                else => std.log.info(
                    "append into {s}.{s}.{s} did not fit the existing shape; rebuilding ({s})",
                    .{ dst.project_id, dst.dataset_id, dst.table_id, s.db.lastError() },
                ),
            }
        }
        const replace = try jobs_handler.replaceDdl(arena, dst, sql);
        s.db.exec(replace, params, .{}) catch {
            std.log.warn(
                "materialize failed for {s}.{s}.{s} ({s}): {s}\n  ddl: {s}",
                .{
                    dst.project_id,   dst.dataset_id,
                    dst.table_id,     dst.write_disposition,
                    s.db.lastError(), replace[0..@min(replace.len, 400)],
                },
            );
            return error.MaterializeFailed;
        };
        return .replaced;
    }

    /// After a materialization job. A rebuilt destination keeps the resource
    /// fields it had before the job, schema aside — BigQuery keeps a truncated
    /// table's description, labels and clustering — and takes the layout the
    /// job itself asked for (`layout_fields`, from
    /// jobs_handler.destinationLayoutFields) over them. That is how a table a
    /// query job creates gets its partitioning and clustering, and recidiviz
    /// materializes by deleting the table and letting the job create it. An
    /// append changed nothing the catalog does not already hold.
    fn recordMaterializedTable(
        s: *Server,
        arena: std.mem.Allocator,
        dst: jobs_handler.Destination,
        materialization_method: MaterializationMethod,
        prior_metadata: []const u8,
        layout_fields: std.json.ObjectMap,
    ) !void {
        if (materialization_method != .replaced) return;
        var kept = try fieldsKeptOverRebuild(arena, prior_metadata);
        var it = layout_fields.iterator();
        while (it.next()) |kv| try kept.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        if (kept.count() == 0) return;
        var metadata_json: std.ArrayList(u8) = .empty;
        try tables_handler.writeMetadata(arena, &metadata_json, .{ .object = kept });
        s.db.setTableMetadata(
            arena,
            dst.project_id,
            dst.dataset_id,
            dst.table_id,
            metadata_json.items,
        ) catch |err| std.log.warn(
            "metadata for {s}.{s}.{s} not recorded over the rebuild: {t}",
            .{ dst.project_id, dst.dataset_id, dst.table_id, err },
        );
    }

    /// A rebuilt destination's posted fields, minus `schema`, which the query
    /// now defines.
    fn fieldsKeptOverRebuild(
        arena: std.mem.Allocator,
        prior_metadata: []const u8,
    ) !std.json.ObjectMap {
        var kept: std.json.ObjectMap = .empty;
        if (prior_metadata.len == 0) return kept;
        const prior = std.json.parseFromSliceLeaky(std.json.Value, arena, prior_metadata, .{}) catch
            return kept;
        if (prior != .object) return kept;
        var it = prior.object.iterator();
        while (it.next()) |kv| {
            if (std.mem.eql(u8, kv.key_ptr.*, "schema")) continue;
            try kept.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        return kept;
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
        const arena = req.arena;
        const job = s.jobs.get(job_id) orelse return notFoundJob(arena, job_id);
        if (job.kind != .query) {
            return badRequest(arena, try std.fmt.allocPrint(
                arena,
                "Job {s}:US.{s} is not a query job",
                .{ project_id, job_id },
            ));
        }
        // handler.go:1497-1498 takes both from the query string only.
        //
        // `maxResults=0` — the Python client's completeness probe — returns no
        // rows, matching Go: the client is sent to the Storage Read API for the
        // actual data instead. Rows a later page does carry are rendered under
        // the `formatOptions` the request asked for.
        var out: std.ArrayList(u8) = .empty;
        try query_handler.writeResultSet(
            arena,
            &out,
            .get_query_results,
            project_id,
            job_id,
            job.set,
            query_handler.parseResultsPage(arena, req.query),
            query_handler.int64TimestampFromQuery(arena, req.query),
        );
        return .{ .body = out.items };
    }
};

fn notFound(arena: std.mem.Allocator, msg: []const u8) !http_server.Response {
    return .{ .status = .not_found, .body = try errors.body(arena, .not_found, msg) };
}

/// BigQuery's answer when a metadata call names a dataset that does not
/// exist: datasets.get, tables.list and tables.insert all use this form. A
/// query job into one adds "was not found in location US" — see
/// `driver.Db.requireDataset`.
fn datasetNotFound(
    arena: std.mem.Allocator,
    project_id: []const u8,
    dataset_id: []const u8,
) !http_server.Response {
    return notFound(arena, try std.fmt.allocPrint(
        arena,
        "Not found: Dataset {s}:{s}",
        .{ project_id, dataset_id },
    ));
}

/// Error message when a copy job specifies a table that is not there.
fn tableNotFound(arena: std.mem.Allocator, table: copy_handler.TableRef) ![]const u8 {
    return std.fmt.allocPrint(arena, "Not found: Table {s}", .{try table.display(arena)});
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

/// Go errInternalError: what every non-validation failure of a handler
/// becomes, including ones a stricter API would call a 400.
fn internalError(arena: std.mem.Allocator, msg: []const u8) !http_server.Response {
    return .{
        .status = .internal_server_error,
        .body = try errors.body(arena, .internal_error, msg),
    };
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
    return requestQuery(s, arena, method, path, "", body);
}

/// request(), with a query string — the format options and maxResults that
/// clients pass there change the response, so tests need to set them.
fn requestQuery(
    s: *Server,
    arena: std.mem.Allocator,
    method: std.http.Method,
    path: []const u8,
    query: []const u8,
    body: []const u8,
) !http_server.Response {
    const req = http_server.Request{
        .method = method,
        .path = path,
        .query = query,
        .body = body,
        .arena = arena,
    };
    return s.handler().func(s.handler().ctx, &req);
}

/// `jobReference.jobId` out of a jobs.insert response.
fn jobIdOf(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return v.object.get("jobReference").?.object.get("jobId").?.string;
}

/// The single cell of a one-row, one-column response.
fn onlyCell(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const cells = try cellsOf(arena, body);
    return cells[0];
}

/// The first cell of every row, for a single-column result.
fn cellsOf(arena: std.mem.Allocator, body: []const u8) ![]const []const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const rows = v.object.get("rows").?.array.items;
    const out = try arena.alloc([]const u8, rows.len);
    for (rows, out) |row, *dst| {
        dst.* = row.object.get("f").?.array.items[0].object.get("v").?.string;
    }
    return out;
}

test "jobs.query returns the Go emulator's response bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
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

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/bigquery/v2/projects/test/queries",
        \\{"query":"SELECT 1 AS i"}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
}

// ---- query parameters ----
//
// The REST `queryParameters` field was parsed and silently dropped before
// these existed, so every parameterized query failed with "not enough query
// arguments" no matter how it was written.

test "jobs.query binds a named scalar parameter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT CONCAT(@a, 'x') AS s","parameterMode":"NAMED",
        \\ "queryParameters":[{"name":"a","parameterType":{"type":"STRING"},
        \\   "parameterValue":{"value":"hi"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("hix", try onlyCell(arena, res.body));
}

test "jobs.insert binds a positional parameter" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT ? + 1 AS n","useLegacySql":false,
        \\ "parameterMode":"POSITIONAL",
        \\ "queryParameters":[{"parameterType":{"type":"INT64"},
        \\   "parameterValue":{"value":"5"}}]}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);

    // jobs.insert answers with the job resource; the rows come back from
    // getQueryResults, which replays the stored ResultSet.
    const job_id = try jobIdOf(arena, res.body);
    const got = try request(s, arena, .GET, try std.fmt.allocPrint(
        arena,
        "/projects/test/queries/{s}",
        .{job_id},
    ), "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expectEqualStrings("6", try onlyCell(arena, got.body));
}

test "a parameterized query with a value missing still reports the arity error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT CONCAT(@a, @b) AS s",
        \\ "queryParameters":[{"name":"a","parameterType":{"type":"STRING"},
        \\   "parameterValue":{"value":"hi"}}]}
    );
    try testing.expectEqual(std.http.Status.bad_request, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "not enough query arguments") != null);
}

test "a malformed queryParameters entry is a 400, not a crash" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT @a AS s","queryParameters":"nope"}
    );
    try testing.expectEqual(std.http.Status.bad_request, res.status);
}

test "a bare SELECT @x returns the client's declared type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    // `@x` is in no function argument, so inference alone would stamp it
    // INT64 and the cast of "abc" would fail. The declared type is what
    // makes both the value and the column type come out right.
    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT @x AS a",
        \\ "queryParameters":[{"name":"x","parameterType":{"type":"STRING"},
        \\   "parameterValue":{"value":"abc"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(std.mem.indexOf(
        u8,
        res.body,
        "\"fields\":[{\"name\":\"a\",\"type\":\"STRING\"}]",
    ) != null);
    try testing.expectEqualStrings("abc", try onlyCell(arena, res.body));
}

test "a bare positional SELECT ? returns the declared type" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT ? AS a","parameterMode":"POSITIONAL",
        \\ "queryParameters":[{"parameterType":{"type":"STRING"},
        \\   "parameterValue":{"value":"abc"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("abc", try onlyCell(arena, res.body));
}

test "jobs.query binds an array parameter through IN UNNEST" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    // The credit_calculator.py shape. This is the case inference cannot
    // reach: UNNEST checks the parameter's type directly, so an undeclared
    // one fails with "Values referenced in UNNEST must be arrays".
    const res = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM UNNEST(['a','b','c']) x WHERE x IN UNNEST(@ids)",
        \\ "queryParameters":[{"name":"ids",
        \\   "parameterType":{"type":"ARRAY","arrayType":{"type":"STRING"}},
        \\   "parameterValue":{"arrayValues":[{"value":"a"},{"value":"c"}]}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("2", try onlyCell(arena, res.body));
}

test "a materialization job binds its query parameters" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    _ = try request(s, arena, .POST, "/projects/test/datasets",
        \\{"datasetReference":{"projectId":"test","datasetId":"d"}}
    );

    // The DDL forms wrap the SELECT, so the placeholder is still in the
    // statement that actually runs.
    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT CONCAT(@v, '!') AS x",
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"mat"},
        \\ "writeDisposition":"WRITE_TRUNCATE",
        \\ "queryParameters":[{"name":"v","parameterType":{"type":"STRING"},
        \\   "parameterValue":{"value":"ok"}}]}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);

    const read = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT x FROM `test.d.mat`"}
    );
    try testing.expectEqual(std.http.Status.ok, read.status);
    try testing.expectEqualStrings("ok!", try onlyCell(arena, read.body));
}

test "a bad query returns 400 in the BigQuery error shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
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

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/queries", "{not json");
    try testing.expectEqual(std.http.Status.bad_request, res.status);
}

test "getQueryResults 404s for an unpersisted jobs.query id" {
    // Matches Go: jobs.query never writes a job row.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .GET, "/projects/test/queries/nosuchjob", "");
    try testing.expectEqual(std.http.Status.not_found, res.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"notFound","location":"","debugInfo":"","message":"job nosuchjob is not found"}],"code":404,"message":"job nosuchjob is not found"}}
    ,
        res.body,
    );
}

// The request sequence google-cloud-bigquery actually performs for
// QueryJob.result(): jobs.insert, then a getQueryResults probe with
// `maxResults=0` and NO formatOptions -- client.py:2086 only adds
// `formatOptions.useInt64Timestamp` when page_size > 0.
//
// The probe must carry no rows. The client parses whatever rows the response
// carries -- with the `rows` key present and no pageToken it considers the
// page complete (table.py:1924-1928) and never asks again -- and
// `CellDataParser.timestamp_to_py` applies a bare `int(value)`, so a
// decimal-seconds cell raises
//
//   ValueError: invalid literal for int() with base 10: '1767268800.0'
//
// which is what recidiviz's llm_extraction_results_persister_test
// ::test_at_least_once_re_persist_appends_duplicate_rows hits on
// result_datetime_utc -- the timestamp used here is that test's own value.
//
// Go answers this by returning no rows at all for maxResults=0, sending the
// client to the Storage Read API over gRPC instead. This server answers the
// same way.
test "the maxResults=0 probe carries no rows, and says where the rest starts" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"SELECT TIMESTAMP '2026-01-01 12:00:00+00' AS result_datetime_utc",
        \\"useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, insert.status);
    const job_id = try jobIdOf(arena, insert.body);
    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});

    const probe = try requestQuery(s, arena, .GET, path, "maxResults=0&prettyPrint=false", "");
    try testing.expectEqual(std.http.Status.ok, probe.status);
    // No rows to misparse, which is the whole point -- and a token, because a
    // short page with none is how truncation loses rows silently.
    try testing.expect(std.mem.indexOf(u8, probe.body, "\"rows\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, probe.body, "\"pageToken\":\"0\"") != null);
    // totalRows still reports the whole result, matching Go.
    try testing.expect(std.mem.indexOf(u8, probe.body, "\"totalRows\":\"1\"") != null);
}

test "getQueryResults honours formatOptions again, both ways" {
    // `formatOptions.useInt64Timestamp` governs the rendering on every page:
    // with the `maxResults=0` probe carrying no rows, there is no unreadable
    // cell left to protect a client from, so the flag means what it says.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"SELECT TIMESTAMP '2026-01-01 12:00:00+00' AS result_datetime_utc",
        \\"useLegacySql":false}}}
    );
    const job_id = try jobIdOf(arena, insert.body);
    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});

    // Asked for: int64 microseconds, which `int(value)` parses.
    const as_int = try requestQuery(
        s,
        arena,
        .GET,
        path,
        "formatOptions.useInt64Timestamp=true&prettyPrint=false",
        "",
    );
    try testing.expectEqualStrings("1767268800000000", try onlyCell(arena, as_int.body));

    // Not asked for: the float-seconds form, which is what BigQuery sends by
    // default and what jobs.query has always sent.
    const as_float = try requestQuery(s, arena, .GET, path, "prettyPrint=false", "");
    try testing.expectEqualStrings("1767268800.0", try onlyCell(arena, as_float.body));
}

test "maxResults pages through a result, and the token resumes it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"SELECT n FROM UNNEST([1,2,3,4,5]) AS n ORDER BY n","useLegacySql":false}}}
    );
    const job_id = try jobIdOf(arena, insert.body);
    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});

    // Two at a time, following the token until it stops coming.
    var token: []const u8 = "0";
    var seen: std.ArrayList(u8) = .empty;
    var pages: usize = 0;
    // Bounded so a token that never stops coming fails the assertion below
    // rather than hanging the suite.
    while (pages < 10) {
        const q = try std.fmt.allocPrint(
            arena,
            "maxResults=2&pageToken={s}&prettyPrint=false",
            .{token},
        );
        const res = try requestQuery(s, arena, .GET, path, q, "");
        try testing.expectEqual(std.http.Status.ok, res.status);
        pages += 1;
        for (try cellsOf(arena, res.body)) |cell| {
            if (seen.items.len != 0) try seen.append(arena, ',');
            try seen.appendSlice(arena, cell);
        }
        token = pageTokenOf(res.body) orelse break;
    }
    // Every row, once, in order -- which is what a token that is wrong by one
    // in either direction would break.
    try testing.expectEqualStrings("1,2,3,4,5", seen.items);
    // 2 + 2 + 1: the last page is short and carries no token, which is how the
    // client knows to stop.
    try testing.expectEqual(@as(usize, 3), pages);

    // A token past the end is an empty page, not an error: it is the same
    // answer as reading one row past a finished iterator.
    const past = try requestQuery(s, arena, .GET, path, "pageToken=99&prettyPrint=false", "");
    try testing.expectEqual(std.http.Status.ok, past.status);
    try testing.expect(std.mem.indexOf(u8, past.body, "\"rows\":[]") != null);
    try testing.expectEqual(@as(?[]const u8, null), pageTokenOf(past.body));
}

/// The `pageToken` of a getQueryResults body, or null when it carries none.
fn pageTokenOf(body: []const u8) ?[]const u8 {
    const key = "\"pageToken\":\"";
    const i = std.mem.indexOf(u8, body, key) orelse return null;
    const rest = body[i + key.len ..];
    const j = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
    return rest[0..j];
}

test "a query job's destination table is readable the moment the job returns" {
    // The gap docs/bigquery_divergence_findings.md records: the job resource
    // has always advertised a destination table and nothing created it, so a
    // client that followed the pointer got a 404.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"SELECT n, CAST(n AS STRING) AS t FROM UNNEST([1,2,3]) AS n ORDER BY n",
        \\"useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, insert.status);
    const job_id = try jobIdOf(arena, insert.body);

    // The resource names it, and tables.get now answers on it.
    try testing.expect(std.mem.indexOf(u8, insert.body, "\"datasetId\":\"_anon\"") != null);
    const path = try std.fmt.allocPrint(arena, "/projects/test/datasets/_anon/tables/{s}", .{job_id});
    const got = try request(s, arena, .GET, path, "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"name\":\"n\"") != null);

    // And it holds the job's rows -- read back through the engine, which is
    // the path CreateReadSession and ReadRows take.
    const sql = try std.fmt.allocPrint(arena, "SELECT n, t FROM `_anon`.`{s}`", .{job_id});
    var rows = try s.db.query(sql, &.{}, .{});
    defer rows.deinit();
    var seen: usize = 0;
    while (try rows.next()) |row| : (seen += 1) {
        try testing.expectEqual(@as(i64, @intCast(seen + 1)), row[0].int);
    }
    try testing.expectEqual(@as(usize, 3), seen);
}

test "the destination table and getQueryResults agree, because they share one copy" {
    // The invariant the storage-form ResultSet buys: the rows a reader gets
    // from the destination table and the rows getQueryResults renders come from
    // the same values, so they cannot drift.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"SELECT TIMESTAMP '2026-01-01 12:00:00+00' AS ts, CAST(NULL AS STRING) AS s",
        \\"useLegacySql":false}}}
    );
    const job_id = try jobIdOf(arena, insert.body);

    const results = try request(
        s,
        arena,
        .GET,
        try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id}),
        "",
    );
    try testing.expectEqualStrings("1767268800.0", try onlyCell(arena, results.body));

    const sql = try std.fmt.allocPrint(arena, "SELECT ts, s FROM `_anon`.`{s}`", .{job_id});
    var rows = try s.db.query(sql, &.{}, .{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try testing.expectEqualStrings("1767268800.0", row[0].timestamp);
    try testing.expectEqual(driver.Cell.null, row[1]);
}

/// A response body's top-level object.
fn objectOf(arena: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return v.object;
}

/// `statistics.query` of a job resource.
fn queryStatisticsOf(arena: std.mem.Allocator, body: []const u8) !std.json.ObjectMap {
    const job = try objectOf(arena, body);
    return job.get("statistics").?.object.get("query").?.object;
}

// google-cloud-bigquery reads `QueryJob.result().num_dml_affected_rows` from getQueryResults'
// `numDmlAffectedRows` and `QueryJob.num_dml_affected_rows` from the job's statistics; a body with
// no `totalRows` makes `result()` an `_EmptyRowIterator` (OBT-19455).
test "a DML job reports its statement type and affected rows on every surface" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    _ = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"CREATE TABLE dml_t (file_id INT64, v STRING)"}
    );
    _ = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"INSERT INTO dml_t (file_id, v) VALUES (1, 'a'), (1, 'b'), (2, 'c')"}
    );

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"DELETE FROM dml_t WHERE file_id = 1",
        \\"useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, insert.status);
    const job_id = try jobIdOf(arena, insert.body);

    const got = try request(
        s,
        arena,
        .GET,
        try std.fmt.allocPrint(arena, "/projects/test/jobs/{s}", .{job_id}),
        "",
    );
    for ([_][]const u8{ insert.body, got.body }) |resource| {
        const stats = try queryStatisticsOf(arena, resource);
        try testing.expectEqualStrings("DELETE", stats.get("statementType").?.string);
        try testing.expectEqualStrings("2", stats.get("numDmlAffectedRows").?.string);
        const dml_stats = stats.get("dmlStats").?.object;
        try testing.expectEqualStrings("2", dml_stats.get("deletedRowCount").?.string);
    }

    // The client's maxResults=0 probe, then a full read.
    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});
    for ([_][]const u8{ "maxResults=0", "" }) |query| {
        const results = try requestQuery(s, arena, .GET, path, query, "");
        try testing.expectEqual(std.http.Status.ok, results.status);
        const body = try objectOf(arena, results.body);
        try testing.expectEqualStrings("2", body.get("numDmlAffectedRows").?.string);
        try testing.expect(body.get("totalRows") == null);
        try testing.expect(body.get("dmlStats") == null);
    }

    const Case = struct { sql: []const u8, affected: []const u8, dml_stats_field: []const u8 };
    for ([_]Case{
        .{
            .sql = "UPDATE dml_t SET v = 'z' WHERE file_id = 2",
            .affected = "1",
            .dml_stats_field = "updatedRowCount",
        },
        .{
            .sql = "DELETE FROM dml_t WHERE file_id = 1",
            .affected = "0",
            .dml_stats_field = "deletedRowCount",
        },
    }) |case| {
        const request_body = try std.json.Stringify.valueAlloc(arena, .{ .query = case.sql }, .{});
        const res = try request(s, arena, .POST, "/projects/test/queries", request_body);
        try testing.expectEqual(std.http.Status.ok, res.status);
        const body = try objectOf(arena, res.body);
        try testing.expectEqualStrings(case.affected, body.get("numDmlAffectedRows").?.string);
        const dml_stats = body.get("dmlStats").?.object;
        try testing.expectEqualStrings(case.affected, dml_stats.get(case.dml_stats_field).?.string);
        try testing.expect(body.get("totalRows") == null);
    }
}

test "a MERGE reports the rows it inserted, updated and deleted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const merge_sql = "MERGE merge_t T USING merge_s S ON T.id = S.id " ++
        "WHEN MATCHED THEN UPDATE SET v = S.v " ++
        "WHEN NOT MATCHED THEN INSERT (id, v) VALUES (S.id, S.v) " ++
        "WHEN NOT MATCHED BY SOURCE THEN DELETE";

    // Row 1 has no source row and is deleted, row 2 is updated, rows 3 and 4 are inserted.
    for ([_]enum { jobs_insert, jobs_query }{ .jobs_insert, .jobs_query }) |surface| {
        for ([_][]const u8{
            "CREATE OR REPLACE TABLE merge_t (id INT64, v STRING)",
            "CREATE OR REPLACE TABLE merge_s (id INT64, v STRING)",
            "INSERT INTO merge_t (id, v) VALUES (1, 'a'), (2, 'b')",
            "INSERT INTO merge_s (id, v) VALUES (2, 'B'), (3, 'C'), (4, 'D')",
        }) |sql| {
            const body = try std.json.Stringify.valueAlloc(arena, .{ .query = sql }, .{});
            const res = try request(s, arena, .POST, "/projects/test/queries", body);
            try testing.expectEqual(std.http.Status.ok, res.status);
        }

        const dml_stats = switch (surface) {
            .jobs_insert => blk: {
                const body = try std.json.Stringify.valueAlloc(arena, .{
                    .configuration = .{ .query = .{ .query = merge_sql, .useLegacySql = false } },
                }, .{});
                const res = try request(s, arena, .POST, "/projects/test/jobs", body);
                try testing.expectEqual(std.http.Status.ok, res.status);
                const stats = try queryStatisticsOf(arena, res.body);
                try testing.expectEqualStrings("4", stats.get("numDmlAffectedRows").?.string);
                break :blk stats.get("dmlStats").?.object;
            },
            .jobs_query => blk: {
                const body = try std.json.Stringify.valueAlloc(arena, .{ .query = merge_sql }, .{});
                const res = try request(s, arena, .POST, "/projects/test/queries", body);
                try testing.expectEqual(std.http.Status.ok, res.status);
                const envelope = try objectOf(arena, res.body);
                try testing.expectEqualStrings("4", envelope.get("numDmlAffectedRows").?.string);
                break :blk envelope.get("dmlStats").?.object;
            },
        };
        try testing.expectEqualStrings("2", dml_stats.get("insertedRowCount").?.string);
        try testing.expectEqualStrings("1", dml_stats.get("updatedRowCount").?.string);
        try testing.expectEqualStrings("1", dml_stats.get("deletedRowCount").?.string);
    }
}

test "a DDL job reports its statement type, with no row total or affected rows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE ddl_type_t (a INT64)",
        \\"useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, insert.status);
    const stats = try queryStatisticsOf(arena, insert.body);
    try testing.expectEqualStrings("CREATE_TABLE", stats.get("statementType").?.string);
    try testing.expect(stats.get("numDmlAffectedRows") == null);
    try testing.expect(stats.get("dmlStats") == null);

    const job_id = try jobIdOf(arena, insert.body);
    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});
    const results = try request(s, arena, .GET, path, "");
    const body = try objectOf(arena, results.body);
    try testing.expect(body.get("totalRows") == null);
    try testing.expect(body.get("numDmlAffectedRows") == null);
}

test "a query reports its row total even when it returns no rows or ends a script" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const empty = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT n FROM UNNEST(GENERATE_ARRAY(1, 0)) AS n"}
    );
    const empty_body = try objectOf(arena, empty.body);
    try testing.expectEqualStrings("0", empty_body.get("totalRows").?.string);

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"CREATE TEMP TABLE script_t AS SELECT 1 AS a; SELECT a FROM script_t",
        \\"useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, insert.status);
    const stats = try queryStatisticsOf(arena, insert.body);
    try testing.expectEqualStrings("SCRIPT", stats.get("statementType").?.string);
    try testing.expect(stats.get("numDmlAffectedRows") == null);

    const job_id = try jobIdOf(arena, insert.body);
    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});
    const results = try request(s, arena, .GET, path, "");
    const body = try objectOf(arena, results.body);
    try testing.expectEqualStrings("1", body.get("totalRows").?.string);
    try testing.expectEqualStrings("1", try onlyCell(arena, results.body));
}

test "a DDL job registers no destination table" {
    // A statement with no result columns has nothing to declare, and a
    // zero-column table is not something SQLite will accept.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE ddl_t (a INT64)",
        \\"useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, insert.status);
    const job_id = try jobIdOf(arena, insert.body);

    const path = try std.fmt.allocPrint(arena, "/projects/test/datasets/_anon/tables/{s}", .{job_id});
    const got = try request(s, arena, .GET, path, "");
    try testing.expectEqual(std.http.Status.not_found, got.status);
}

test "a zero-row SELECT still gets an empty destination table" {
    // Go skips materializing when the result has no rows, which loses this
    // case; BigQuery has an empty anonymous table for it and so does this.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"SELECT n FROM UNNEST(GENERATE_ARRAY(1, 0)) AS n","useLegacySql":false}}}
    );
    const job_id = try jobIdOf(arena, insert.body);

    const sql = try std.fmt.allocPrint(arena, "SELECT n FROM `_anon`.`{s}`", .{job_id});
    var rows = try s.db.query(sql, &.{}, .{});
    defer rows.deinit();
    try testing.expectEqual(@as(?[]const driver.Cell, null), try rows.next());
}

test "two jobs' destination tables do not collide in the shared dataset" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const a = try jobIdOf(arena, (try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 1 AS v","useLegacySql":false}}}
    )).body);
    const b = try jobIdOf(arena, (try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 2 AS v","useLegacySql":false}}}
    )).body);
    try testing.expect(!std.mem.eql(u8, a, b));

    for ([_][]const u8{ a, b }, [_]i64{ 1, 2 }) |id, want| {
        const sql = try std.fmt.allocPrint(arena, "SELECT v FROM `_anon`.`{s}`", .{id});
        var rows = try s.db.query(sql, &.{}, .{});
        defer rows.deinit();
        try testing.expectEqual(want, (try rows.next()).?[0].int);
    }
}

test "an unknown path is a 500, matching Go's defaultHandler" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const res = try request(s, arena, .GET, "/no/such/path", "");
    try testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "unexpected request path") != null);
}

test "state persists across requests on the same connection" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
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

test "deleting a dataset takes its tables out of the engine too" {
    // The Python suite wipes the emulator between tests with
    // delete_dataset(delete_contents=True); leaving the tables in the content
    // database made every test after the first report "already exists",
    // because tables.get falls back to the engine catalog.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "gone");
    _ = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"CREATE OR REPLACE VIEW `test.ds1.gone_view` AS SELECT 1 AS a"}
    );

    // The query string is split off before dispatch, and deleteContents is
    // implied: the emulator always drops the contents.
    _ = try request(s, arena, .DELETE, "/projects/test/datasets/ds1", "");

    for ([_][]const u8{ "gone", "gone_view" }) |table_id| {
        const res = try request(s, arena, .GET, try std.fmt.allocPrint(
            arena,
            "/projects/test/datasets/ds1/tables/{s}",
            .{table_id},
        ), "");
        try testing.expectEqual(std.http.Status.not_found, res.status);
    }
}

test "a CREATE or a destination table in an undeclared dataset is BigQuery's 404" {
    // Probed against BigQuery 2026-09-11: a query job into a dataset that
    // does not exist fails before anything runs, with `notFound` and this
    // exact message. The engine's own inference of datasets from table
    // paths is for the library; the emulator's clients declare them.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const expected =
        \\{"error":{"errors":[{"reason":"notFound","location":"","debugInfo":"","message":"Not found: Dataset test:nope was not found in location US"}],"code":404,"message":"Not found: Dataset test:nope was not found in location US"}}
    ;
    const via_query = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"CREATE TABLE `test.nope.t` (a INT64)"}
    );
    try testing.expectEqual(std.http.Status.not_found, via_query.status);
    try testing.expectEqualStrings(expected, via_query.body);

    const via_job = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE `test.nope.t` (a INT64)"}}}
    );
    try testing.expectEqual(std.http.Status.not_found, via_job.status);
    try testing.expectEqualStrings(expected, via_job.body);

    // A `dataset.function` name resolves against the request's project, as a table's does.
    const via_function = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"CREATE FUNCTION nope.f(x INT64) AS (x + 1)"}
    );
    try testing.expectEqual(std.http.Status.not_found, via_function.status);
    try testing.expectEqualStrings(expected, via_function.body);

    const materialized = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 1 AS x",
        \\ "destinationTable":{"projectId":"test","datasetId":"nope","tableId":"mat"}}}}
    );
    try testing.expectEqual(std.http.Status.not_found, materialized.status);
    try testing.expectEqualStrings(expected, materialized.body);

    // Nothing was invented along the way: the metadata API answers as
    // BigQuery does for a dataset that never existed.
    const got = try request(s, arena, .GET, "/projects/test/datasets/nope", "");
    try testing.expectEqual(std.http.Status.not_found, got.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"notFound","location":"","debugInfo":"","message":"Not found: Dataset test:nope"}],"code":404,"message":"Not found: Dataset test:nope"}}
    , got.body);
    const tables = try request(s, arena, .GET, "/projects/test/datasets/nope/tables", "");
    try testing.expectEqual(std.http.Status.not_found, tables.status);
    const listed = try request(s, arena, .GET, "/projects/test/datasets", "");
    try testing.expectEqualStrings("{\"datasets\":[]}", listed.body);

    // Once declared, the same statements go through.
    _ = try request(s, arena, .POST, "/projects/test/datasets",
        \\{"datasetReference":{"projectId":"test","datasetId":"nope"}}
    );
    const ok = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE `test.nope.t` (a INT64)"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ok.status);
}

test "deleting a dataset takes it out of the metadata API and INFORMATION_SCHEMA alike" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "t");

    const schemata_sql =
        \\{"query":"SELECT schema_name FROM `test`.INFORMATION_SCHEMA.SCHEMATA ORDER BY schema_name"}
    ;
    const before = try request(s, arena, .POST, "/projects/test/queries", schemata_sql);
    try testing.expectEqual(std.http.Status.ok, before.status);
    try testing.expect(std.mem.indexOf(u8, before.body, "\"ds1\"") != null);

    const deleted = try request(s, arena, .DELETE, "/projects/test/datasets/ds1", "");
    try testing.expectEqual(std.http.Status.ok, deleted.status);

    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1", "");
    try testing.expectEqual(std.http.Status.not_found, got.status);
    const tables = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables", "");
    try testing.expectEqual(std.http.Status.not_found, tables.status);
    const listed = try request(s, arena, .GET, "/projects/test/datasets", "");
    try testing.expectEqualStrings("{\"datasets\":[]}", listed.body);
    // A second delete is a miss, not a no-op.
    const again = try request(s, arena, .DELETE, "/projects/test/datasets/ds1", "");
    try testing.expectEqual(std.http.Status.not_found, again.status);

    // SCHEMATA reads the same store, so the dataset is gone there too.
    const after = try request(s, arena, .POST, "/projects/test/queries", schemata_sql);
    try testing.expectEqual(std.http.Status.ok, after.status);
    for (try cellsOf(arena, after.body)) |name| {
        if (std.mem.eql(u8, name, "ds1")) return error.TestUnexpectedResult;
    }
}

test "patched dataset fields round-trip through get and list, which is ordered by id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    for ([_][]const u8{ "b_ds", "a_ds" }) |id| {
        const res = try request(s, arena, .POST, "/projects/test/datasets", try std.fmt.allocPrint(
            arena,
            \\{{"datasetReference":{{"projectId":"test","datasetId":"{s}"}}}}
        ,
            .{id},
        ));
        try testing.expectEqual(std.http.Status.ok, res.status);
    }

    const patched = try request(s, arena, .PATCH, "/projects/test/datasets/b_ds",
        \\{"labels":{"team":"data"},"description":"kept"}
    );
    try testing.expectEqual(std.http.Status.ok, patched.status);

    // datasets.get reports what was stored, reference included.
    const got = try request(s, arena, .GET, "/projects/test/datasets/b_ds", "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expectEqualStrings(patched.body, got.body);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"description\":\"kept\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"datasetId\":\"b_ds\"") != null);

    // datasets.list carries the same resources, in id order regardless of
    // declaration order.
    const listed = try request(s, arena, .GET, "/projects/test/datasets", "");
    const a_at = std.mem.indexOf(u8, listed.body, "\"datasetId\":\"a_ds\"") orelse
        return error.TestUnexpectedResult;
    const b_at = std.mem.indexOf(u8, listed.body, "\"datasetId\":\"b_ds\"") orelse
        return error.TestUnexpectedResult;
    try testing.expect(a_at < b_at);
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"team\":\"data\"") != null);

    // Patching an undeclared dataset is a miss.
    const missing = try request(s, arena, .PATCH, "/projects/test/datasets/c_ds", "{}");
    try testing.expectEqual(std.http.Status.not_found, missing.status);
}

test "declared datasets survive a restart on a file-backed database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // tmpDir lives at .zig-cache/tmp/<sub_path> relative to the test cwd;
    // sqlite resolves the same relative path against the same cwd.
    const db_path = try std.fmt.allocPrint(arena, ".zig-cache/tmp/{s}/datasets.db", .{tmp.sub_path});

    {
        var s = try Server.init(testing.allocator, testing.io, .{
            .project = "test",
            .database = db_path,
            .dataset = "ds1",
        });
        defer s.deinit();
        const patched = try request(s, arena, .PATCH, "/projects/test/datasets/ds1",
            \\{"description":"kept"}
        );
        try testing.expectEqual(std.http.Status.ok, patched.status);
    }
    {
        // Restarted with the same flag, the dataset keeps its patched resource.
        var s = try Server.init(testing.allocator, testing.io, .{
            .project = "test",
            .database = db_path,
            .dataset = "ds1",
        });
        defer s.deinit();
        const got = try request(s, arena, .GET, "/projects/test/datasets/ds1", "");
        try testing.expectEqual(std.http.Status.ok, got.status);
        try testing.expect(std.mem.indexOf(u8, got.body, "\"description\":\"kept\"") != null);
        const listed = try request(s, arena, .GET, "/projects/test/datasets", "");
        try testing.expect(std.mem.indexOf(u8, listed.body, "\"datasetId\":\"ds1\"") != null);

        // It lives in the catalog table under its own kind: no metadata
        // store beside it.
        var rows = try s.db.rawQuery(
            "SELECT kind FROM zigquery_catalog WHERE name = 'test_ds1'",
            &.{},
        );
        defer rows.deinit();
        const row = (try rows.next()) orelse return error.TestUnexpectedResult;
        try testing.expectEqualStrings("dataset", row[0].text);
    }
}

test "inserting a declared dataset is 409 and leaves it as it was" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    const body =
        \\{"datasetReference":{"projectId":"test","datasetId":"ds1"}}
    ;
    const first = try request(s, arena, .POST, "/projects/test/datasets", body);
    try testing.expectEqual(std.http.Status.ok, first.status);
    _ = try request(s, arena, .PATCH, "/projects/test/datasets/ds1",
        \\{"description":"kept"}
    );

    const again = try request(s, arena, .POST, "/projects/test/datasets", body);
    try testing.expectEqual(std.http.Status.conflict, again.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"duplicate","location":"","debugInfo":"","message":"Already Exists: Dataset test:ds1"}],"code":409,"message":"Already Exists: Dataset test:ds1"}}
    , again.body);
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1", "");
    try testing.expect(std.mem.indexOf(u8, got.body, "\"description\":\"kept\"") != null);
}

test "fields posted to datasets.insert round-trip through get and list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    const inserted = try request(s, arena, .POST, "/projects/test/datasets",
        \\{"datasetReference":{"projectId":"test","datasetId":"ds1"},"description":"posted","labels":{"team":"data"}}
    );
    try testing.expectEqual(std.http.Status.ok, inserted.status);
    try testing.expectEqualStrings(
        \\{"datasetReference":{"datasetId":"ds1","projectId":"test"},"description":"posted","id":"ds1","labels":{"team":"data"}}
    , inserted.body);

    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1", "");
    try testing.expectEqualStrings(inserted.body, got.body);
    const listed = try request(s, arena, .GET, "/projects/test/datasets", "");
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"team\":\"data\"") != null);
}

test "datasets.patch merges into the stored resource key by key" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    _ = try request(s, arena, .POST, "/projects/test/datasets",
        \\{"datasetReference":{"projectId":"test","datasetId":"ds1"},"description":"posted"}
    );
    _ = try request(s, arena, .PATCH, "/projects/test/datasets/ds1",
        \\{"labels":{"team":"data"}}
    );
    const last = try request(s, arena, .PATCH, "/projects/test/datasets/ds1",
        \\{"friendlyName":"One","labels":{"tier":"gold"},"datasetReference":{"projectId":"test","datasetId":"moved"}}
    );
    try testing.expectEqual(std.http.Status.ok, last.status);
    // A patch keeps the fields it does not name and replaces whole the ones it does, `labels`
    // included; the reference stays the request path's.
    try testing.expectEqualStrings(
        \\{"datasetReference":{"datasetId":"ds1","projectId":"test"},"description":"posted","friendlyName":"One","id":"ds1","labels":{"tier":"gold"}}
    , last.body);
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1", "");
    try testing.expectEqualStrings(last.body, got.body);

    // An empty patch changes nothing, and a body that is not JSON is refused.
    const empty = try request(s, arena, .PATCH, "/projects/test/datasets/ds1", "{}");
    try testing.expectEqualStrings(last.body, empty.body);
    const bad = try request(s, arena, .PATCH, "/projects/test/datasets/ds1", "{not json");
    try testing.expectEqual(std.http.Status.bad_request, bad.status);
    const after = try request(s, arena, .GET, "/projects/test/datasets/ds1", "");
    try testing.expectEqualStrings(last.body, after.body);
}

// ---- tabledata.insertAll ----

/// tables.insert with a two-column schema, the shape a client creates before
/// it streams into a table.
fn createStreamTable(s: *Server, arena: std.mem.Allocator, table_id: []const u8) !void {
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables", try std.fmt.allocPrint(
        arena,
        \\{{"tableReference":{{"projectId":"test","datasetId":"ds1","tableId":"{s}"}},
        \\ "schema":{{"fields":[{{"name":"name","type":"STRING"}},{{"name":"age","type":"INTEGER"}}]}}}}
    ,
        .{table_id},
    ));
}

test "insertAll writes rows that a later query can read" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "streamed");

    // `age` arrives as a JSON string, which is what google-cloud-bigquery's
    // insert_rows sends for an INTEGER column.
    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/streamed/insertAll",
        \\{"kind":"bigquery#tableDataInsertAllRequest","rows":[
        \\  {"insertId":"a","json":{"name":"Alice","age":"30"}},
        \\  {"insertId":"b","json":{"name":"Bob","age":"25"}}
        \\]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("{}", res.body);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT name FROM `test.ds1.streamed` WHERE age > 27"}
    );
    try testing.expectEqual(std.http.Status.ok, q.status);
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"Alice\"}") != null);
    try testing.expect(std.mem.indexOf(u8, q.body, "Bob") == null);
}

test "posted table fields survive a round trip, and patch merges over them" {
    // source_table_update_manager_test compares clustering_fields between the
    // table it posted and the table it reads back. The resource used to be
    // rebuilt from a fixed struct, so clustering never came back and the diff
    // saw no change; tables.patch was aliased to tables.get, so an update was
    // silently discarded too. Go stores the posted map and merges into it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    const created = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"clustered"},
        \\ "schema":{"fields":[{"name":"name","type":"STRING"},{"name":"age","type":"INTEGER"}]},
        \\ "clustering":{"fields":["name"]},
        \\ "labels":{"team":"platform"},
        \\ "description":"raw data table"}
    );
    try testing.expectEqual(std.http.Status.ok, created.status);
    try testing.expect(std.mem.indexOf(u8, created.body, "\"clustering\":{\"fields\":[\"name\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, created.body, "\"description\":\"raw data table\"") != null);

    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/clustered", "");
    try testing.expectEqualStrings(created.body, got.body);

    // tables.list keeps Go's TableListTables subset: clustering and labels
    // ride along, schema and selfLink do not.
    const listed = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables", "");
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"clustering\":{\"fields\":[\"name\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"labels\":{\"team\":\"platform\"}") != null);
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"schema\"") == null);
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"description\"") == null);

    // PATCH is a key-level merge: clustering changes, description survives.
    const patched = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/clustered",
        \\{"clustering":{"fields":["age"]}}
    );
    try testing.expectEqual(std.http.Status.ok, patched.status);
    try testing.expect(std.mem.indexOf(u8, patched.body, "\"clustering\":{\"fields\":[\"age\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, patched.body, "\"description\":\"raw data table\"") != null);
    // The schema the table was created with is untouched by a patch.
    try testing.expect(std.mem.indexOf(u8, patched.body, "\"name\":\"age\",\"type\":\"INTEGER\"") != null);

    const after = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/clustered", "");
    try testing.expectEqualStrings(patched.body, after.body);
}

test "a table made by a CTAS job is listed, streams rows, and a replace shows through" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    const ctas = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE `test.ds1.made` AS SELECT 1 AS n, 'x' AS s"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ctas.status);

    // tables.list and insertAll see it without anyone calling tables.get.
    const listed = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables", "");
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"tableId\":\"made\"") != null);
    const streamed = try request(
        s,
        arena,
        .POST,
        "/projects/test/datasets/ds1/tables/made/insertAll",
        \\{"rows":[{"json":{"n":2,"s":"y"}}]}
        ,
    );
    try testing.expectEqual(std.http.Status.ok, streamed.status);
    try testing.expectEqualStrings("{}", streamed.body);

    // A replace through DDL is what tables.get reports next.
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/made", "");
    try testing.expect(std.mem.indexOf(u8, got.body, "\"name\":\"s\"") != null);
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE OR REPLACE TABLE `test.ds1.made` AS SELECT DATE '2026-01-01' AS d"}}}
    );
    const after = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/made", "");
    try testing.expect(std.mem.indexOf(u8, after.body, "\"name\":\"d\",\"type\":\"DATE\"") != null);
    try testing.expect(std.mem.indexOf(u8, after.body, "\"name\":\"s\"") == null);
}

/// A jobs.insert body running `sql`. `sql` must not hold a double quote or backslash: it is
/// spliced into the JSON as is.
fn queryJobBody(arena: std.mem.Allocator, sql: []const u8) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{{\"configuration\":{{\"query\":{{\"query\":\"{s}\"}}}}}}",
        .{sql},
    );
}

/// Runs `sql` as a query job and expects it to succeed.
fn runQueryJob(s: *Server, arena: std.mem.Allocator, sql: []const u8) !void {
    const res = try request(s, arena, .POST, "/projects/test/jobs", try queryJobBody(arena, sql));
    if (res.status != .ok) {
        std.debug.print("job failed ({t}): {s}\n  sql: {s}\n", .{ res.status, res.body, sql });
        return error.TestUnexpectedResult;
    }
}

test "DDL PARTITION BY and CLUSTER BY are what tables.get reports, in BigQuery's shapes" {
    // OBT-19799. Each expected fragment is what BigQuery itself reports for the
    // same DDL (captured 2026-09-14). The python client compares a table's
    // time_partitioning field for field with what it would post, so an extra or
    // a missing field reads as a change and recidiviz refuses to write.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try runQueryJob(s, arena, "CREATE TABLE `ds1.src` (x TIMESTAMP, dt DATETIME)");

    const cases = [_]struct { table: []const u8, ddl: []const u8, want: []const u8 }{
        .{
            .table = "col",
            .ddl = "CREATE TABLE `ds1.col` (d DATE, a STRING, n INT64) PARTITION BY d CLUSTER BY a, n",
            .want = "\"clustering\":{\"fields\":[\"a\",\"n\"]},",
        },
        .{
            .table = "col",
            .ddl = "",
            .want = "\"timePartitioning\":{\"field\":\"d\",\"type\":\"DAY\"},",
        },
        .{
            .table = "day_of_datetime",
            .ddl = "CREATE TABLE `ds1.day_of_datetime` (dt DATETIME) PARTITION BY DATE(dt)",
            .want = "\"timePartitioning\":{\"field\":\"dt\",\"type\":\"DAY\"},",
        },
        .{
            // The CTAS reference points at the query's column `x`; the table
            // calls it `ts`, and that is the field BigQuery reports.
            .table = "hourly",
            .ddl = "CREATE TABLE `ds1.hourly` PARTITION BY TIMESTAMP_TRUNC(ts, HOUR) AS SELECT x AS ts FROM `ds1.src`",
            .want = "\"timePartitioning\":{\"field\":\"ts\",\"type\":\"HOUR\"},",
        },
        .{
            .table = "monthly",
            .ddl = "CREATE TABLE `ds1.monthly` (d DATE) PARTITION BY DATE_TRUNC(d, MONTH)",
            .want = "\"timePartitioning\":{\"field\":\"d\",\"type\":\"MONTH\"},",
        },
        .{
            .table = "yearly",
            .ddl = "CREATE TABLE `ds1.yearly` PARTITION BY DATETIME_TRUNC(dt, YEAR) AS SELECT dt FROM `ds1.src`",
            .want = "\"timePartitioning\":{\"field\":\"dt\",\"type\":\"YEAR\"},",
        },
        .{
            .table = "ranged",
            .ddl = "CREATE TABLE `ds1.ranged` (n INT64) PARTITION BY RANGE_BUCKET(n, GENERATE_ARRAY(0, 100, 10))",
            .want = "\"rangePartitioning\":{\"field\":\"n\",\"range\":{\"end\":\"100\",\"interval\":\"10\",\"start\":\"0\"}},",
        },
        .{
            .table = "opts",
            .ddl = "CREATE TABLE `ds1.opts` (d DATE) PARTITION BY d OPTIONS(partition_expiration_days=3, require_partition_filter=true)",
            .want = "\"requirePartitionFilter\":true,",
        },
        .{
            .table = "opts",
            .ddl = "",
            .want = "\"timePartitioning\":{\"expirationMs\":\"259200000\",\"field\":\"d\",\"requirePartitionFilter\":true,\"type\":\"DAY\"},",
        },
    };
    for (cases) |c| {
        if (c.ddl.len > 0) try runQueryJob(s, arena, c.ddl);
        const path = try std.fmt.allocPrint(arena, "/projects/test/datasets/ds1/tables/{s}", .{c.table});
        const got = try request(s, arena, .GET, path, "");
        try testing.expectEqual(std.http.Status.ok, got.status);
        if (std.mem.indexOf(u8, got.body, c.want) == null) {
            std.debug.print("{s}: want {s}\n  in {s}\n", .{ c.table, c.want, got.body });
            return error.TestUnexpectedResult;
        }
    }

    // An unpartitioned table reports neither.
    const plain = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/src", "");
    try testing.expect(std.mem.indexOf(u8, plain.body, "Partitioning") == null);
    try testing.expect(std.mem.indexOf(u8, plain.body, "\"clustering\"") == null);

    // tables.list carries both, as it does for posted tables.
    const listed = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables", "");
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"clustering\":{\"fields\":[\"a\",\"n\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"timePartitioning\":{\"field\":\"ts\",\"type\":\"HOUR\"}") != null);
}

test "a patch wins over DDL partitioning, and CREATE OR REPLACE without it clears it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try runQueryJob(s, arena, "CREATE TABLE `ds1.t` (d DATE, a STRING) PARTITION BY d CLUSTER BY a");

    // A patched field is what the client said last; the DDL's other field stays.
    const patched = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/t",
        \\{"clustering":{"fields":["d"]}}
    );
    try testing.expectEqual(std.http.Status.ok, patched.status);
    try testing.expect(std.mem.indexOf(u8, patched.body, "\"clustering\":{\"fields\":[\"d\"]}") != null);
    try testing.expect(std.mem.indexOf(u8, patched.body, "\"timePartitioning\":{\"field\":\"d\",\"type\":\"DAY\"}") != null);

    // A replace is a new table: nothing of the old one's layout survives.
    try runQueryJob(s, arena, "CREATE OR REPLACE TABLE `ds1.t` (d DATE, a STRING)");
    const replaced = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/t", "");
    try testing.expect(std.mem.indexOf(u8, replaced.body, "\"timePartitioning\"") == null);
    try testing.expect(std.mem.indexOf(u8, replaced.body, "\"clustering\"") == null);
}

test "DDL partitioning and descriptions survive a restart on a file-backed database" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const db_path = try std.fmt.allocPrint(
        arena,
        ".zig-cache/tmp/{s}/partitioned.db",
        .{tmp.sub_path},
    );

    var before: []const u8 = "";
    {
        var s = try Server.init(testing.allocator, testing.io, .{
            .project = "test",
            .database = db_path,
            .dataset = "ds1",
        });
        defer s.deinit();
        try runQueryJob(
            s,
            arena,
            "CREATE TABLE `ds1.t` (d DATE, a STRING OPTIONS(description='col a')) " ++
                "PARTITION BY d CLUSTER BY a OPTIONS(description='kept')",
        );
        before = (try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/t", "")).body;
        try testing.expect(std.mem.indexOf(u8, before, "\"timePartitioning\"") != null);
        try testing.expect(std.mem.indexOf(u8, before, "\"description\":\"kept\"") != null);
        try testing.expect(std.mem.indexOf(u8, before, "\"description\":\"col a\"") != null);
    }
    {
        var s = try Server.init(testing.allocator, testing.io, .{
            .project = "test",
            .database = db_path,
            .dataset = "ds1",
        });
        defer s.deinit();
        const after = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/t", "");
        try testing.expectEqualStrings(before, after.body);
    }
}

test "a query job's destination reports the partitioning and clustering it asked for" {
    // OBT-19799, the materialization path: recidiviz deletes the table, lets
    // a WRITE_TRUNCATE job carrying timePartitioning and clustering create
    // it, and later compares tables.get with what it would post. BigQuery
    // echoes the job's fields unchanged (captured 2026-09-14), including
    // `requirePartitionFilter`, which pb.TimePartitioning has no field for.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    const tp = "\"timePartitioning\":{\"expirationMs\":\"259200000\",\"field\":\"d\",\"requirePartitionFilter\":false,\"type\":\"DAY\"}";
    const cl = "\"clustering\":{\"fields\":[\"a\"]}";

    const created = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT DATE '2026-01-01' AS d, 'x' AS a",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"m"},
        \\  "writeDisposition":"WRITE_TRUNCATE",
        \\  "timePartitioning":{"type":"DAY","field":"d","expirationMs":"259200000","requirePartitionFilter":false},
        \\  "clustering":{"fields":["a"]}}}}
    );
    try testing.expectEqual(std.http.Status.ok, created.status);
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/m", "");
    try testing.expect(std.mem.indexOf(u8, got.body, tp) != null);
    try testing.expect(std.mem.indexOf(u8, got.body, cl) != null);

    // A description patched on meanwhile, then a truncate that asks for no
    // layout — the python client posts `"timePartitioning": null` whenever it
    // sets clustering alone. The table keeps all three, as BigQuery keeps a
    // truncated table's metadata.
    const patched = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/m",
        \\{"description":"kept"}
    );
    try testing.expectEqual(std.http.Status.ok, patched.status);
    const truncated = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT DATE '2026-01-02' AS d, 'y' AS a",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"m"},
        \\  "writeDisposition":"WRITE_TRUNCATE",
        \\  "timePartitioning":null}}}
    );
    try testing.expectEqual(std.http.Status.ok, truncated.status);
    const after_truncate = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/m", "");
    try testing.expect(std.mem.indexOf(u8, after_truncate.body, tp) != null);
    try testing.expect(std.mem.indexOf(u8, after_truncate.body, cl) != null);
    try testing.expect(std.mem.indexOf(u8, after_truncate.body, "\"description\":\"kept\"") != null);

    // An append leaves the resource alone, whatever layout it names.
    const appended = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT DATE '2026-01-03' AS d, 'z' AS a",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"m"},
        \\  "writeDisposition":"WRITE_APPEND",
        \\  "clustering":{"fields":["d"]}}}}
    );
    try testing.expectEqual(std.http.Status.ok, appended.status);
    const after_append = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/m", "");
    try testing.expectEqualStrings(after_truncate.body, after_append.body);

    // rangePartitioning, on a table the job creates.
    const ranged = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 5 AS n",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"ranged"},
        \\  "rangePartitioning":{"field":"n","range":{"start":"0","end":"100","interval":"10"}}}}}
    );
    try testing.expectEqual(std.http.Status.ok, ranged.status);
    const got_ranged = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/ranged", "");
    try testing.expect(std.mem.indexOf(
        u8,
        got_ranged.body,
        "\"rangePartitioning\":{\"field\":\"n\",\"range\":{\"end\":\"100\",\"interval\":\"10\",\"start\":\"0\"}}",
    ) != null);
}

test "a query job fails, writing nothing, when its layout names a column the query lacks" {
    // OBT-23081. Messages from recidiviz-bigquery-sandbox, 2026-09-16, where the job ends DONE
    // with this errorResult and getQueryResults answers 400 with it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{
        .project = "test",
        .dataset = "ds1",
    });
    defer s.deinit();

    // The first missing clustering field, in posted order.
    const clustered = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 1 AS person_id, 'US_XX' AS state_code",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"m"},
        \\  "writeDisposition":"WRITE_TRUNCATE",
        \\  "clustering":{"fields":["person_id","does_not_exist","also_missing"]}}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, clustered.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"The field specified for clustering cannot be found in the schema. Invalid field: does_not_exist"}],"code":400,"message":"The field specified for clustering cannot be found in the schema. Invalid field: does_not_exist"}}
    , clustered.body);
    const absent = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/m", "");
    try testing.expectEqual(std.http.Status.not_found, absent.status);

    // Any disposition; partitioning is checked before clustering.
    const partitioned = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 1 AS person_id, DATE '2026-01-01' AS d",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"m"},
        \\  "writeDisposition":"WRITE_APPEND",
        \\  "timePartitioning":{"type":"DAY","field":"does_not_exist"},
        \\  "clustering":{"fields":["also_missing"]}}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, partitioned.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"The field specified for partitioning cannot be found in the schema."}],"code":400,"message":"The field specified for partitioning cannot be found in the schema."}}
    , partitioned.body);

    // Names match whatever their case, and the table reports them as posted.
    const cased = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 1 AS person_id, 'US_XX' AS state_code",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"m"},
        \\  "writeDisposition":"WRITE_TRUNCATE",
        \\  "clustering":{"fields":["PERSON_ID"]}}}}
    );
    try testing.expectEqual(std.http.Status.ok, cased.status);
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/m", "");
    try testing.expect(
        std.mem.indexOf(u8, got.body, "\"clustering\":{\"fields\":[\"PERSON_ID\"]}") != null,
    );

    // A rejected job leaves an existing destination's rows in place.
    const rejected = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 2 AS person_id, 'US_YY' AS state_code",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"m"},
        \\  "writeDisposition":"WRITE_TRUNCATE",
        \\  "clustering":{"fields":["does_not_exist"]}}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, rejected.status);
    const rows = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT STRING_AGG(state_code) FROM ds1.m","useLegacySql":false}
    );
    try testing.expectEqual(std.http.Status.ok, rows.status);
    try testing.expectEqualStrings("US_XX", try onlyCell(arena, rows.body));
}

test "tables.insert and tables.patch reject a layout that names no column" {
    // OBT-23081. Messages from recidiviz-bigquery-sandbox, 2026-09-16.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{
        .project = "test",
        .dataset = "ds1",
    });
    defer s.deinit();

    const clustered = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"t"},
        \\ "schema":{"fields":[{"name":"person_id","type":"INTEGER"}]},
        \\ "clustering":{"fields":["does_not_exist"]}}
    );
    try testing.expectEqual(std.http.Status.bad_request, clustered.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"The field specified for clustering cannot be found in the schema. Invalid field: does_not_exist."}],"code":400,"message":"The field specified for clustering cannot be found in the schema. Invalid field: does_not_exist."}}
    , clustered.body);
    const absent = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/t", "");
    try testing.expectEqual(std.http.Status.not_found, absent.status);

    const Rejection = struct { body: []const u8, message: []const u8 };
    const rejections = [_]Rejection{
        .{
            .body =
            \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"t"},
            \\ "schema":{"fields":[{"name":"person_id","type":"INTEGER"}]},
            \\ "timePartitioning":{"type":"DAY","field":"does_not_exist"},
            \\ "clustering":{"fields":["also_missing"]}}
            ,
            .message = "The field specified for partitioning cannot be found in the schema.",
        },
        .{
            .body =
            \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"t"},
            \\ "timePartitioning":{"type":"DAY","field":"does_not_exist"}}
            ,
            .message = "Table with field based partitioning must have a schema.",
        },
        .{
            .body =
            \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"v"},
            \\ "view":{"query":"SELECT 1 AS person_id","useLegacySql":false},
            \\ "clustering":{"fields":["person_id"]}}
            ,
            .message = "Table with clustering must have a schema.",
        },
    };
    for (rejections) |rejection| {
        const res =
            try request(s, arena, .POST, "/projects/test/datasets/ds1/tables", rejection.body);
        try testing.expectEqual(std.http.Status.bad_request, res.status);
        const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, res.body, .{});
        try testing.expectEqualStrings(
            rejection.message,
            v.object.get("error").?.object.get("message").?.string,
        );
    }

    const created = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"t"},
        \\ "schema":{"fields":[{"name":"person_id","type":"INTEGER"},{"name":"d","type":"DATE"}]},
        \\ "clustering":{"fields":["person_id"]}}
    );
    try testing.expectEqual(std.http.Status.ok, created.status);

    const patched = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/t",
        \\{"clustering":{"fields":["does_not_exist"]}}
    );
    try testing.expectEqual(std.http.Status.bad_request, patched.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"The field specified for clustering cannot be found in the schema. Invalid field: does_not_exist."}],"code":400,"message":"The field specified for clustering cannot be found in the schema. Invalid field: does_not_exist."}}
    , patched.body);
    const repartitioned = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/t",
        \\{"timePartitioning":{"type":"DAY","field":"does_not_exist"}}
    );
    try testing.expectEqual(std.http.Status.bad_request, repartitioned.status);
    const kept = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/t", "");
    try testing.expect(
        std.mem.indexOf(u8, kept.body, "\"clustering\":{\"fields\":[\"person_id\"]}") != null,
    );
    try testing.expect(std.mem.indexOf(u8, kept.body, "timePartitioning") == null);

    const cleared = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/t",
        \\{"clustering":null,"description":"x"}
    );
    try testing.expectEqual(std.http.Status.ok, cleared.status);
}

/// The schema BigQuery reports for `described_columns`, then the `trailing` fields
/// (recidiviz-bigquery-sandbox, 2026-09-14).
fn describedSchema(comptime trailing: []const u8) []const u8 {
    return "\"schema\":{\"fields\":[" ++
        "{\"description\":\"the id\",\"mode\":\"REQUIRED\"," ++
        "\"name\":\"id\",\"type\":\"INTEGER\"}," ++
        "{\"description\":\"a struct\",\"fields\":[" ++
        "{\"description\":\"nested a\",\"name\":\"a\",\"type\":\"INTEGER\"}," ++
        "{\"mode\":\"REQUIRED\",\"name\":\"b\",\"type\":\"STRING\"}]," ++
        "\"name\":\"s\",\"type\":\"RECORD\"}," ++
        "{\"description\":\"tags\",\"mode\":\"REPEATED\",\"name\":\"tags\",\"type\":\"STRING\"}" ++
        trailing ++ "]}";
}

const described_columns =
    "id INT64 NOT NULL OPTIONS(description='the id'), " ++
    "s STRUCT<a INT64 OPTIONS(description='nested a'), b STRING NOT NULL> " ++
    "OPTIONS(description='a struct'), tags ARRAY<STRING> OPTIONS(description='tags')";

test "table and column OPTIONS(description) are what tables.get reports" {
    // OBT-44683. The schema and description BigQuery reports for the same DDL
    // (recidiviz-bigquery-sandbox, 2026-09-14).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try runQueryJob(
        s,
        arena,
        "CREATE TABLE `ds1.described` (" ++ described_columns ++ ") OPTIONS(description='plain')",
    );
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/described", "");
    try testing.expect(std.mem.indexOf(u8, got.body, describedSchema("")) != null);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"description\":\"plain\"") != null);

    // A patched description is what the client said last; the columns keep theirs.
    const patched = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/described",
        \\{"description":"patched"}
    );
    try testing.expectEqual(std.http.Status.ok, patched.status);
    try testing.expect(std.mem.indexOf(u8, patched.body, "\"description\":\"patched\"") != null);
    try testing.expect(std.mem.indexOf(u8, patched.body, describedSchema("")) != null);

    try runQueryJob(s, arena, "CREATE VIEW `ds1.v` OPTIONS(description='a view') AS SELECT 1 AS n");
    const view = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/v", "");
    try testing.expect(std.mem.indexOf(u8, view.body, "\"description\":\"a view\"") != null);
}

test "a column list with AS SELECT declares the table's columns and checks their NOT NULL" {
    // OBT-44683, the statement view materialization replaces a table with. The schema, messages
    // and surviving original are BigQuery's for the same statements
    // (recidiviz-bigquery-sandbox, 2026-09-14).
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    const replace_mat = "CREATE OR REPLACE TABLE `ds1.mat` (" ++ described_columns ++
        ", d DATE) PARTITION BY d CLUSTER BY id OPTIONS(description='materialized') AS SELECT ";
    const rows_tail = "STRUCT(2 AS a, 'b' AS b) AS z, ['t'] AS w, DATE '2026-01-01' AS y";
    try runQueryJob(s, arena, replace_mat ++ "1 AS x, " ++ rows_tail);

    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/mat", "");
    const d_last = describedSchema(",{\"name\":\"d\",\"type\":\"DATE\"}");
    try testing.expect(std.mem.indexOf(u8, got.body, d_last) != null);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"description\":\"materialized\"") != null);
    const partitioned = "\"timePartitioning\":{\"field\":\"d\",\"type\":\"DAY\"}";
    try testing.expect(std.mem.indexOf(u8, got.body, partitioned) != null);
    const clustered = "\"clustering\":{\"fields\":[\"id\"]}";
    try testing.expect(std.mem.indexOf(u8, got.body, clustered) != null);

    const read_body =
        \\{"query":"SELECT FORMAT('%d:%d:%s', id, s.a, tags[OFFSET(0)]) AS v FROM `ds1.mat`"}
    ;
    const read = try request(s, arena, .POST, "/projects/test/queries", read_body);
    try testing.expectEqualStrings("1:2:t", try onlyCell(arena, read.body));

    // A NULL for the NOT NULL `id` fails the replace, and the table keeps its row.
    const null_id = try request(
        s,
        arena,
        .POST,
        "/projects/test/jobs",
        try queryJobBody(arena, replace_mat ++ "CAST(NULL AS INT64) AS x, " ++ rows_tail),
    );
    try testing.expectEqual(std.http.Status.bad_request, null_id.status);
    try testing.expect(
        std.mem.indexOf(u8, null_id.body, "Required field id cannot be null") != null,
    );
    const reread = try request(s, arena, .POST, "/projects/test/queries", read_body);
    try testing.expectEqualStrings("1:2:t", try onlyCell(arena, reread.body));

    // A NULL for a NOT NULL member fails, and nothing is created.
    const null_member = try request(s, arena, .POST, "/projects/test/jobs", try queryJobBody(
        arena,
        "CREATE TABLE `ds1.nn` (s STRUCT<a INT64 NOT NULL>) " ++
            "AS SELECT STRUCT(CAST(NULL AS INT64) AS a) AS s",
    ));
    try testing.expectEqual(std.http.Status.bad_request, null_member.status);
    try testing.expect(std.mem.indexOf(
        u8,
        null_member.body,
        "Required field s.a cannot be null; error in writing field s",
    ) != null);
    const absent = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/nn", "");
    try testing.expectEqual(std.http.Status.not_found, absent.status);

    // A declared primary key keeps one index, named for the table, across replaces.
    const replace_pk = "CREATE OR REPLACE TABLE `ds1.pk` " ++
        "(id INT64, PRIMARY KEY (id) NOT ENFORCED) AS SELECT 1 AS id";
    try runQueryJob(s, arena, replace_pk);
    try runQueryJob(s, arena, replace_pk);
    var rows = try s.db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'test_ds1_pk'",
        &.{},
    );
    defer rows.deinit();
    const index = (try rows.next()) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("test_ds1_pk.pk", index[0].text);
    try testing.expect((try rows.next()) == null);
}

test "DDL that omits the project lands in the server's project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "mat");

    // The table recidiviz's materialization writes: no project in the name.
    const ddl = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE ds1.short (a STRING)"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ddl.status);
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/short", "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    const listed = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables", "");
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"tableId\":\"short\"") != null);
    const streamed = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/short/insertAll",
        \\{"rows":[{"json":{"a":"x"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, streamed.status);

    // A replace over a table made through tables.insert replaces it.
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE OR REPLACE TABLE ds1.mat AS SELECT 2 AS id"}}}
    );
    const mat = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/mat", "");
    try testing.expect(std.mem.indexOf(u8, mat.body, "\"name\":\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, mat.body, "\"name\":\"age\"") == null);
    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT id FROM `test.ds1.mat`"}
    );
    try testing.expectEqualStrings("2", try onlyCell(arena, q.body));

    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"DROP TABLE ds1.short"}}}
    );
    const gone = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/short", "");
    try testing.expectEqual(std.http.Status.not_found, gone.status);
}

test "a one-part table whose name reads like a path does not answer for it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "foo" });
    defer s.deinit();
    _ = try request(s, arena, .POST, "/projects/foo/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE foo_bar_baz (x INT64)"}}}
    );
    const got = try request(s, arena, .GET, "/projects/foo/datasets/bar/tables/baz", "");
    try testing.expectEqual(std.http.Status.not_found, got.status);
    const patched = try request(s, arena, .PATCH, "/projects/foo/datasets/bar/tables/baz", "{}");
    try testing.expectEqual(std.http.Status.not_found, patched.status);
    const deleted = try request(s, arena, .DELETE, "/projects/foo/datasets/bar/tables/baz", "");
    try testing.expectEqual(std.http.Status.not_found, deleted.status);
}

test "a query's result table cannot be patched into the catalog" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 1 AS n"}}}
    );
    const job_id = try jobIdOf(arena, insert.body);
    const path = try std.fmt.allocPrint(
        arena,
        "/projects/test/datasets/_anon/tables/{s}",
        .{job_id},
    );

    const patched = try request(s, arena, .PATCH, path, "{\"description\":\"phantom\"}");
    try testing.expectEqual(std.http.Status.bad_request, patched.status);

    var rows = try s.db.rawQuery(
        "SELECT COUNT(*) FROM zigquery_catalog WHERE name LIKE 'test__anon_%'",
        &.{},
    );
    defer rows.deinit();
    try testing.expectEqual(@as(i64, 0), (try rows.next()).?[0].int);
}

test "tables.delete removes a spec whose SQLite object is already gone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "dangling");
    // Pull the object out from under the spec, as an interrupted rebuild would.
    try s.db.rawExec("DROP TABLE test_ds1_dangling", &.{});

    const deleted = try request(s, arena, .DELETE, "/projects/test/datasets/ds1/tables/dangling", "");
    try testing.expectEqual(std.http.Status.ok, deleted.status);
    const gone = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/dangling", "");
    try testing.expectEqual(std.http.Status.not_found, gone.status);
    // And the name is free again.
    try createStreamTable(s, arena, "dangling");
    const back = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/dangling", "");
    try testing.expectEqual(std.http.Status.ok, back.status);
}

test "tables.insert over an existing table is a conflict, and the table is untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "dup");

    const again = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"dup"},
        \\ "schema":{"fields":[{"name":"b","type":"INTEGER"}]}}
    );
    try testing.expectEqual(std.http.Status.conflict, again.status);
    try testing.expect(std.mem.indexOf(u8, again.body, "\"reason\":\"duplicate\"") != null);
    try testing.expect(
        std.mem.indexOf(u8, again.body, "Already Exists: Table test:ds1.dup") != null,
    );

    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/dup", "");
    try testing.expect(std.mem.indexOf(u8, got.body, "\"name\":\"age\"") != null);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"name\":\"b\"") == null);
}

test "DDL in a job resolves dataset.table against the job's project" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    // The name resolves against `other`, where nobody has declared ds1 yet —
    // and BigQuery does not invent datasets.
    const refused = try request(s, arena, .POST, "/projects/other/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE ds1.t (a STRING)"}}}
    );
    try testing.expectEqual(std.http.Status.not_found, refused.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"notFound","location":"","debugInfo":"","message":"Not found: Dataset other:ds1 was not found in location US"}],"code":404,"message":"Not found: Dataset other:ds1 was not found in location US"}}
    , refused.body);
    _ = try request(s, arena, .POST, "/projects/other/datasets",
        \\{"datasetReference":{"projectId":"other","datasetId":"ds1"}}
    );

    const ddl = try request(s, arena, .POST, "/projects/other/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE ds1.t (a STRING)"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ddl.status);
    const theirs = try request(s, arena, .GET, "/projects/other/datasets/ds1/tables/t", "");
    try testing.expectEqual(std.http.Status.ok, theirs.status);
    const ours = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/t", "");
    try testing.expectEqual(std.http.Status.not_found, ours.status);

    // jobs.query takes the same path.
    const q = try request(s, arena, .POST, "/projects/other/queries",
        \\{"query":"DROP TABLE IF EXISTS ds1.t"}
    );
    try testing.expectEqual(std.http.Status.ok, q.status);
    const dropped = try request(s, arena, .GET, "/projects/other/datasets/ds1/tables/t", "");
    try testing.expectEqual(std.http.Status.not_found, dropped.status);

    // The job's project does not outlive the job.
    try testing.expectEqualStrings("test", s.db.default_project.?);
}

test "a view made by DDL reports the query it was written with" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "base");
    const ddl = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE VIEW `test.ds1.v` AS SELECT name FROM `test.ds1.base` WHERE age > 1"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ddl.status);

    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/v", "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"type\":\"VIEW\"") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        got.body,
        \\"view":{"query":"SELECT name FROM `test.ds1.base` WHERE age > 1","useLegacySql":false}
        ,
    ) != null);
    try testing.expect(
        std.mem.indexOf(u8, got.body, "\"name\":\"name\",\"type\":\"STRING\"") != null,
    );
}

test "nested modes and field descriptions come back exactly as posted" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    const created = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"nested"},
        \\ "schema":{"fields":[
        \\   {"name":"id","type":"INTEGER","mode":"REQUIRED","description":"the id"},
        \\   {"name":"r","type":"RECORD","mode":"REPEATED","fields":[
        \\     {"name":"x","type":"STRING","mode":"REQUIRED"},{"name":"y","type":"BOOLEAN"}]}]}}
    );
    try testing.expectEqual(std.http.Status.ok, created.status);
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/nested", "");
    try testing.expectEqualStrings(created.body, got.body);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"description\":\"the id\"") != null);
    try testing.expect(std.mem.indexOf(
        u8,
        got.body,
        \\{"mode":"REQUIRED","name":"x","type":"STRING"}
        ,
    ) != null);
}

test "a nested REQUIRED posted through tables.insert is enforced by DML and by insertAll" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"nested_req"},
        \\ "schema":{"fields":[{"name":"id","type":"INTEGER"},
        \\   {"name":"r","type":"RECORD","fields":[
        \\     {"name":"x","type":"INTEGER","mode":"REQUIRED"},{"name":"y","type":"STRING"}]}]}}
    );

    const dml = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"INSERT INTO `test.ds1.nested_req` VALUES (1, STRUCT(NULL AS x, 'a' AS y))"}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, dml.status);
    try testing.expect(std.mem.indexOf(
        u8,
        dml.body,
        "Required field r.x cannot be null; error in writing field r",
    ) != null);

    const stream_path = "/projects/test/datasets/ds1/tables/nested_req/insertAll";
    const streamed = try request(s, arena, .POST, stream_path,
        \\{"rows":[{"json":{"id":2,"r":{"y":"no x"}}}]}
    );
    try testing.expectEqual(std.http.Status.ok, streamed.status);
    try testing.expect(std.mem.indexOf(
        u8,
        streamed.body,
        "Missing required field: Msg_0_CLOUD_QUERY_TABLE.r.x.",
    ) != null);

    const ok = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"INSERT INTO `test.ds1.nested_req` VALUES (3, STRUCT(3 AS x, 'c' AS y))"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ok.status);
    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.nested_req`"}
    );
    try testing.expectEqualStrings("1", try onlyCell(arena, q.body));

    // A posted schema is what tables.get answers with here.
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/nested_req", "");
    try testing.expect(
        std.mem.indexOf(u8, got.body, "\"mode\":\"REQUIRED\",\"name\":\"x\"") != null,
    );
}

test "a DDL-made table reports its nested NOT NULL members as REQUIRED" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    const ddl = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"CREATE TABLE `test.ds1.ddl_req` (r STRUCT<x INT64 NOT NULL, y STRING>, rs ARRAY<STRUCT<k INT64 NOT NULL>>)"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ddl.status);

    // No posted schema exists, so the spec renders the modes.
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/ddl_req", "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expect(std.mem.indexOf(
        u8,
        got.body,
        \\"fields":[{"mode":"REQUIRED","name":"x","type":"INTEGER"},{"name":"y","type":"STRING"}],"name":"r"
        ,
    ) != null);
    try testing.expect(std.mem.indexOf(
        u8,
        got.body,
        \\"fields":[{"mode":"REQUIRED","name":"k","type":"INTEGER"}],"mode":"REPEATED","name":"rs"
        ,
    ) != null);
}

test "deleting a view drops it from the engine, and tables are listed by id" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "zulu");
    try createStreamTable(s, arena, "alpha");
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"mid_view"},
        \\ "view":{"query":"SELECT name FROM `test.ds1.alpha`","useLegacySql":false}}
    );

    const listed = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables", "");
    const alpha = std.mem.indexOf(u8, listed.body, "\"tableId\":\"alpha\"").?;
    const mid = std.mem.indexOf(u8, listed.body, "\"tableId\":\"mid_view\"").?;
    const zulu = std.mem.indexOf(u8, listed.body, "\"tableId\":\"zulu\"").?;
    try testing.expect(alpha < mid and mid < zulu);
    try testing.expect(std.mem.indexOf(u8, listed.body, "\"totalItems\":3") != null);

    const view_path = "/projects/test/datasets/ds1/tables/mid_view";
    const deleted = try request(s, arena, .DELETE, view_path, "");
    try testing.expectEqual(std.http.Status.ok, deleted.status);
    const gone = try request(s, arena, .GET, view_path, "");
    try testing.expectEqual(std.http.Status.not_found, gone.status);
    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT * FROM `test.ds1.mid_view`"}
    );
    try testing.expectEqual(std.http.Status.bad_request, q.status);

    const again = try request(s, arena, .DELETE, view_path, "");
    try testing.expectEqual(std.http.Status.not_found, again.status);
}

test "tables.patch refuses to change a schema, as Go does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "fixed");

    const res = try request(s, arena, .PATCH, "/projects/test/datasets/ds1/tables/fixed",
        \\{"schema":{"fields":[{"name":"other","type":"STRING"}]}}
    );
    try testing.expectEqual(std.http.Status.bad_request, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "schema updates unsupported") != null);
}

test "creating a view answers with the schema the view resolves to" {
    // emulator_test.py test_view_schema: a client posts a view with no schema
    // and reads the resolved columns straight off create_table(). Go returns
    // them from CreateView; this used to echo the posted (absent) schema, and
    // persisting that empty resource also poisoned the tables.get fallback
    // that would otherwise have derived it.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"example_table"},
        \\ "schema":{"fields":[{"name":"string_field","type":"STRING"}]}}
    );

    const created = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"example_view"},
        \\ "view":{"query":"SELECT * FROM `test.ds1.example_table`","useLegacySql":false}}
    );
    try testing.expectEqual(std.http.Status.ok, created.status);
    try testing.expect(std.mem.indexOf(
        u8,
        created.body,
        \\"schema":{"fields":[{"name":"string_field","type":"STRING"}]}
        ,
    ) != null);
    try testing.expect(std.mem.indexOf(u8, created.body, "\"type\":\"VIEW\"") != null);

    // And the stored resource carries it, so tables.get agrees.
    const got = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/example_view", "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expectEqualStrings(created.body, got.body);
}

test "a WRITE_TRUNCATE job may read the table it is replacing" {
    // recidiviz's dataflow metric pruning entrypoint replaces each metric
    // table with a filtered read of itself. The old CREATE OR REPLACE dropped
    // the destination before preparing the SELECT, so the job died with
    // "no such table: <project>_<dataset>_<table>".
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"metrics"},
        \\ "schema":{"fields":[{"name":"job_id","type":"STRING"},{"name":"n","type":"INTEGER"}]}}
    );
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/metrics/insertAll",
        \\{"rows":[{"json":{"job_id":"keep","n":"1"}},
        \\         {"json":{"job_id":"drop","n":"2"}},
        \\         {"json":{"job_id":"keep","n":"3"}}]}
    );

    const job = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{
        \\  "query":"SELECT job_id, n FROM `test.ds1.metrics` WHERE job_id = 'keep'",
        \\  "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"metrics"},
        \\  "writeDisposition":"WRITE_TRUNCATE","useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, job.status);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT SUM(n) AS total, COUNT(*) AS kept FROM `test.ds1.metrics`"}
    );
    try testing.expectEqual(std.http.Status.ok, q.status);
    // 1 + 3 over two surviving rows: the read happened before the truncate.
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"4\"}") != null);
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"2\"}") != null);
}

test "an INT column is an INT64 column, not a STRING one" {
    // sentence_inferred_group_projected_dates_mismatch_test declares
    // SchemaField("person_id", "INT") and SchemaField("sentence_inferred_
    // group_id", "INTEGER"). Only the second used to survive: "INT" missed the
    // alias map, fell through to STRING, and the client read back '123'
    // instead of 123. The response schema is the whole bug — REST always sends
    // values as strings and the client casts from the reported type.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    const created = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"aliased"},
        \\ "schema":{"fields":[{"name":"person_id","type":"INT"},
        \\                     {"name":"sentence_inferred_group_id","type":"INTEGER"}]}}
    );
    try testing.expectEqual(std.http.Status.ok, created.status);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT person_id, sentence_inferred_group_id FROM `test.ds1.aliased`"}
    );
    try testing.expectEqual(std.http.Status.ok, q.status);
    try testing.expect(std.mem.indexOf(
        u8,
        q.body,
        \\{"fields":[{"name":"person_id","type":"INTEGER"},{"name":"sentence_inferred_group_id","type":"INTEGER"}]}
        ,
    ) != null);
}

test "a schema naming an unusable type is a 400, not a STRING column" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"bogus"},
        \\ "schema":{"fields":[{"name":"a","type":"WIDGET"}]}}
    );
    try testing.expectEqual(std.http.Status.bad_request, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "unsupported type") != null);
}

test "insertAll under the /bigquery/v2 prefix reaches the same handler" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "prefixed");

    const res = try request(s, arena, .POST, "/bigquery/v2/projects/test/datasets/ds1/tables/prefixed/insertAll",
        \\{"rows":[{"json":{"name":"x","age":1}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("{}", res.body);
}

test "insertAll into a missing table is a 404" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/nope/insertAll",
        \\{"rows":[{"json":{"a":1}}]}
    );
    try testing.expectEqual(std.http.Status.not_found, res.status);
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"notFound","location":"","debugInfo":"","message":"table nope is not found"}],"code":404,"message":"table nope is not found"}}
    , res.body);
}

test "an unknown field rejects the whole batch with 200 and insertErrors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "rejected");

    // emulator_test.py test_insert_unknown_fields_mixed_valid_and_invalid:
    // rows 1 and 3 are invalid, and rows 0 and 2 report `stopped` after them.
    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/rejected/insertAll",
        \\{"rows":[
        \\  {"json":{"name":"ok1","age":1}},
        \\  {"json":{"name":"bad1","bad_field":"x"}},
        \\  {"json":{"name":"ok2","age":2}},
        \\  {"json":{"name":"bad2","bad1":"y"}}
        \\]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"bad_field","message":"no such field: bad_field.","reason":"invalid"}],"index":1},{"errors":[{"debugInfo":"","location":"bad1","message":"no such field: bad1.","reason":"invalid"}],"index":3},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":0},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":2}]}
    , res.body);

    // Nothing was written, including the rows that were themselves valid.
    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.rejected`"}
    );
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"0\"}") != null);
}

test "insertAll reports a value the column will not take as an invalid row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "badvalue");

    // 200 with insertErrors, as BigQuery answers. Go answers 500, which the
    // python client retries until its ten-minute deadline (OBT-26715).
    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/badvalue/insertAll",
        \\{"rows":[{"json":{"name":"ok","age":"1"}},{"json":{"name":"a","age":"not a number"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"age","message":"Bad int64 value: not a number","reason":"invalid"}],"index":1},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":0}]}
    , res.body);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.badvalue`"}
    );
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"0\"}") != null);
}

test "insertAll keeps the engine's conversion message for a bad DATE" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"dated"},
        \\ "schema":{"fields":[{"name":"a","type":"DATE","mode":"REQUIRED"}]}}
    );

    // big_query_emulator_test.py test_invalid_data_load_fails matches the
    // message text in the error the client raises.
    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/dated/insertAll",
        \\{"rows":[{"json":{"a":"202-06-06"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"a","message":"failed to convert 202-06-06 to time.Time type","reason":"invalid"}],"index":0}]}
    , res.body);
}

test "a REQUIRED column declared through tables.insert rejects NULL on every write path" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"source"},
        \\ "schema":{"fields":[{"name":"col_1","type":"STRING"},{"name":"col_2","type":"STRING"}]}}
    );
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"destination"},
        \\ "schema":{"fields":[{"name":"col_1","type":"STRING","mode":"REQUIRED"},
        \\                     {"name":"col_2","type":"STRING","mode":"REQUIRED"}]}}
    );
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/source/insertAll",
        \\{"rows":[{"json":{"col_1":"val_3","col_2":"val_4"}},{"json":{"col_1":null,"col_2":"val_2"}}]}
    );

    // insertAll: the null row is invalid and the batch stops.
    const streamed = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/destination/insertAll",
        \\{"rows":[{"json":{"col_1":"a","col_2":"b"}},{"json":{"col_1":null,"col_2":"c"}},{"json":{"col_2":"d"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, streamed.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"col_1","message":"Missing required field: Msg_0_CLOUD_QUERY_TABLE.col_1.","reason":"invalid"}],"index":1},{"errors":[{"debugInfo":"","location":"col_1","message":"Missing required field: Msg_0_CLOUD_QUERY_TABLE.col_1.","reason":"invalid"}],"index":2},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":0}]}
    , streamed.body);

    // INSERT ... SELECT from a source holding a NULL: the statement fails and
    // writes nothing (OBT-19493).
    const dml = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"INSERT INTO `test.ds1.destination` (col_1, col_2) SELECT col_1, col_2 FROM `test.ds1.source`"}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, dml.status);
    try testing.expect(std.mem.indexOf(u8, dml.body, "NOT NULL constraint failed") != null);

    // A query job appending into the declared table: the same INSERT, and the
    // constraint failure is the job's error, leaving the table and its
    // declared schema alone.
    const append = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT col_1, col_2 FROM `test.ds1.source`",
        \\ "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"destination"},
        \\ "writeDisposition":"WRITE_APPEND"}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, append.status);
    try testing.expect(std.mem.indexOf(u8, append.body, "NOT NULL constraint failed") != null);

    // INSERT ... VALUES with an explicit NULL.
    const values = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"INSERT INTO `test.ds1.destination` (col_1, col_2) VALUES (NULL, 'x')"}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, values.status);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.destination`"}
    );
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"0\"}") != null);

    // And tables.get still reports the mode.
    const meta = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/destination", "");
    try testing.expect(std.mem.indexOf(u8, meta.body, "\"mode\":\"REQUIRED\"") != null);
}

test "a WRITE_APPEND job keeps the destination's declared resource" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"declared"},
        \\ "description":"declared up front",
        \\ "clustering":{"fields":["a"]},
        \\ "schema":{"fields":[{"name":"a","type":"STRING","mode":"REQUIRED"},{"name":"b","type":"STRING"}]}}
    );

    const append = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 'x' AS a, 'y' AS b",
        \\ "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"declared"},
        \\ "writeDisposition":"WRITE_APPEND"}}}
    );
    try testing.expectEqual(std.http.Status.ok, append.status);

    const meta = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/declared", "");
    try testing.expect(std.mem.indexOf(u8, meta.body, "\"mode\":\"REQUIRED\"") != null);
    try testing.expect(
        std.mem.indexOf(u8, meta.body, "\"clustering\":{\"fields\":[\"a\"]}") != null,
    );
    try testing.expect(std.mem.indexOf(u8, meta.body, "declared up front") != null);

    // The mode still guards insertAll, before anything is bound.
    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/declared/insertAll",
        \\{"rows":[{"json":{"a":null,"b":"z"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "Missing required field") != null);
    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.declared`"}
    );
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"1\"}") != null);

    // A truncate rebuilds the table from the query, and the resource follows.
    const truncate = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 1 AS n",
        \\ "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"declared"},
        \\ "writeDisposition":"WRITE_TRUNCATE"}}}
    );
    try testing.expectEqual(std.http.Status.ok, truncate.status);
    const after = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/declared", "");
    try testing.expect(std.mem.indexOf(u8, after.body, "\"name\":\"n\"") != null);
    try testing.expect(std.mem.indexOf(u8, after.body, "REQUIRED") == null);
}

test "a WRITE_APPEND into a DDL-created NOT NULL table records it as REQUIRED" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    const ddl = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE `test.ds1.ddl` (a STRING NOT NULL, b STRING)"}}}
    );
    try testing.expectEqual(std.http.Status.ok, ddl.status);

    const append = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 'x' AS a, 'y' AS b",
        \\ "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"ddl"},
        \\ "writeDisposition":"WRITE_APPEND"}}}
    );
    try testing.expectEqual(std.http.Status.ok, append.status);

    const meta = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/ddl", "");
    try testing.expectEqual(std.http.Status.ok, meta.status);
    try testing.expect(std.mem.indexOf(u8, meta.body, "\"mode\":\"REQUIRED\"") != null);
}

test "insertAll answers a NULL the engine rejects as an invalid row, not a 500" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    _ = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"appended"},
        \\ "schema":{"fields":[{"name":"a","type":"STRING","mode":"REQUIRED"},{"name":"b","type":"STRING"}]}}
    );
    // A query job appending into the table re-records its schema from the
    // query, which carries no modes; the column stays NOT NULL in storage.
    const append = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"SELECT 'z' AS a, CAST(NULL AS STRING) AS b",
        \\ "destinationTable":{"projectId":"test","datasetId":"ds1","tableId":"appended"},
        \\ "writeDisposition":"WRITE_APPEND"}}}
    );
    try testing.expectEqual(std.http.Status.ok, append.status);

    // The declared resource survives the append, so the pre-bind check is
    // what catches the NULL below.
    const meta = try request(s, arena, .GET, "/projects/test/datasets/ds1/tables/appended", "");
    try testing.expect(std.mem.indexOf(u8, meta.body, "\"mode\":\"REQUIRED\"") != null);

    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/appended/insertAll",
        \\{"rows":[{"json":{"a":"ok","b":"1"}},{"json":{"a":null,"b":"2"}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"a","message":"Missing required field: Msg_0_CLOUD_QUERY_TABLE.a.","reason":"invalid"}],"index":1},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":0}]}
    , res.body);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.appended`"}
    );
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"1\"}") != null);
}

test "skipInvalidRows sets unknown-field rows aside and writes the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "mixed");

    // Row 0 has an undeclared field, row 2 a value its column will not take;
    // both are reported at their posted positions, row 1 lands, and nothing
    // is `stopped`.
    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/mixed/insertAll",
        \\{"skipInvalidRows":true,"rows":[
        \\  {"json":{"name":"a","zzz":1}},
        \\  {"json":{"name":"b","age":"2"}},
        \\  {"json":{"name":"c","age":"x"}}
        \\]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"zzz","message":"no such field: zzz.","reason":"invalid"}],"index":0},{"errors":[{"debugInfo":"","location":"age","message":"Bad int64 value: x","reason":"invalid"}],"index":2}]}
    , res.body);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT name FROM `test.ds1.mixed`"}
    );
    try testing.expectEqualStrings("b", try onlyCell(arena, q.body));
}

test "ignoreUnknownValues drops undeclared fields and writes the row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "loose");

    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/loose/insertAll",
        \\{"ignoreUnknownValues":true,"rows":[{"json":{"name":"a","age":"1","zzz":{"deep":true}}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("{}", res.body);
    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.loose`"}
    );
    try testing.expectEqualStrings("1", try onlyCell(arena, q.body));

    // Ignoring unknown values does not soften a bad value: without
    // skipInvalidRows the batch still stops.
    const bad = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/loose/insertAll",
        \\{"ignoreUnknownValues":true,"rows":[{"json":{"name":"ok","age":"2"}},{"json":{"name":"no","age":"x","zzz":1}}]}
    );
    try testing.expectEqual(std.http.Status.ok, bad.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"age","message":"Bad int64 value: x","reason":"invalid"}],"index":1},{"errors":[{"debugInfo":"","location":"","message":"","reason":"stopped"}],"index":0}]}
    , bad.body);
    const after = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.loose`"}
    );
    try testing.expectEqualStrings("1", try onlyCell(arena, after.body));
}

test "insertAll with skipInvalidRows writes the fine rows and lists the rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "skipping");

    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/skipping/insertAll",
        \\{"skipInvalidRows":true,"rows":[
        \\  {"json":{"name":"ok1","age":"1"}},
        \\  {"json":{"name":"bad","age":"x"}},
        \\  {"json":{"name":"ok2","age":"2"}}
        \\]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        \\{"insertErrors":[{"errors":[{"debugInfo":"","location":"age","message":"Bad int64 value: x","reason":"invalid"}],"index":1}]}
    , res.body);

    const q = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT COUNT(*) AS n FROM `test.ds1.skipping`"}
    );
    try testing.expect(std.mem.indexOf(u8, q.body, "{\"v\":\"2\"}") != null);
}

test "insertAll with no rows is a no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "empty");

    const res = try request(s, arena, .POST, "/projects/test/datasets/ds1/tables/empty/insertAll",
        \\{"kind":"bigquery#tableDataInsertAllRequest"}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("{}", res.body);
}

test "insertAll rejects a malformed body with 400" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "malformed");

    const res = try request(
        s,
        arena,
        .POST,
        "/projects/test/datasets/ds1/tables/malformed/insertAll",
        "{not json",
    );
    try testing.expectEqual(std.http.Status.bad_request, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"reason\":\"invalid\"") != null);
}

test "useInt64Timestamp reaches TIMESTAMPs nested in a STRUCT or ARRAY" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    // google-cloud-bigquery asks for this format on every read and parses a
    // TIMESTAMP cell with int(). A cell still carrying the float-seconds form
    // is a ValueError on the client, not a wrong value, so the three shapes
    // below have to agree.
    const cases = [_]struct { sql: []const u8, want: []const u8 }{
        .{
            .sql = "SELECT TIMESTAMP '2026-01-10 00:00:00+00' AS ts",
            .want =
            \\[{"f":[{"v":"1768003200000000"}]}]
            ,
        },
        .{
            .sql = "SELECT STRUCT(TIMESTAMP '2026-01-10 00:00:00+00' AS ts) AS s",
            .want =
            \\[{"f":[{"v":{"f":[{"v":"1768003200000000"}]}}]}]
            ,
        },
        .{
            .sql = "SELECT [STRUCT(TIMESTAMP '2026-01-10 00:00:00+00' AS ts)] AS arr",
            .want =
            \\[{"f":[{"v":[{"v":{"f":[{"v":"1768003200000000"}]}}]}]}]
            ,
        },
    };

    for (cases) |case| {
        const body = try std.fmt.allocPrint(
            arena,
            "{{\"configuration\":{{\"query\":{{\"query\":{f}}}}}}}",
            .{std.json.fmt(case.sql, .{})},
        );
        const job = try requestQuery(s, arena, .POST, "/projects/test/jobs", "", body);
        const job_id = try jobIdOf(arena, job.body);
        const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});
        const got = try requestQuery(
            s,
            arena,
            .GET,
            path,
            "formatOptions.useInt64Timestamp=true",
            "",
        );
        const rows = try std.json.parseFromSliceLeaky(std.json.Value, arena, got.body, .{});
        const actual = try std.json.Stringify.valueAlloc(arena, rows.object.get("rows").?, .{});
        try json_pb.expectJsonEqual(case.want, actual);
    }
}

test "without useInt64Timestamp every TIMESTAMP keeps the float-seconds form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();

    const body =
        \\{"configuration":{"query":{"query":"SELECT STRUCT(TIMESTAMP '2026-01-10 00:00:00+00' AS ts) AS s"}}}
    ;
    const job = try requestQuery(s, arena, .POST, "/projects/test/jobs", "", body);
    const job_id = try jobIdOf(arena, job.body);
    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});
    const got = try requestQuery(s, arena, .GET, path, "", "");
    const rows = try std.json.parseFromSliceLeaky(std.json.Value, arena, got.body, .{});
    const actual = try std.json.Stringify.valueAlloc(arena, rows.object.get("rows").?, .{});
    try json_pb.expectJsonEqual(
        \\[{"f":[{"v":{"f":[{"v":"1768003200.0"}]}}]}]
    , actual);
}

// ---- copy jobs ----
//
// The wording and the HTTP-or-job-resource split are measured: recidiviz-bigquery-sandbox,
// 2026-09-21 and 2026-09-24. docs/adr/0001.

/// A dataset `d` holding `src` with two rows, which the copy tests start from.
fn copyFixture(s: *Server, arena: std.mem.Allocator) !void {
    _ = try request(s, arena, .POST, "/projects/test/datasets",
        \\{"datasetReference":{"projectId":"test","datasetId":"d"}}
    );
    const made = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\ "CREATE TABLE `test.d.src` AS SELECT 1 AS a UNION ALL SELECT 2 AS a"}}}
    );
    try testing.expectEqual(std.http.Status.ok, made.status);
}

/// `status.errorResult.message` of a job resource.
fn errorResultMessage(arena: std.mem.Allocator, body: []const u8) ![]const u8 {
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return v.object.get("status").?.object.get("errorResult").?.object.get("message").?.string;
}

test "a copy job creates the destination and reports the rows it copied" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"}}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"jobType\":\"COPY\"") != null);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"copiedRows\":\"2\"") != null);

    const rows = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT a FROM `test.d.dst` ORDER BY a"}
    );
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "1", "2" }),
        try cellsOf(arena, rows.body),
    );
}

test "a copy job is replayable through jobs.get and refused by getQueryResults" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"}}}}
    );
    const job_id = try jobIdOf(arena, res.body);

    const got = try request(s, arena, .GET, try std.fmt.allocPrint(
        arena,
        "/projects/test/jobs/{s}",
        .{job_id},
    ), "");
    try testing.expectEqual(std.http.Status.ok, got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "\"jobType\":\"COPY\"") != null);

    // The Python client polls jobs.get, never this endpoint, for a copy job.
    const results = try request(s, arena, .GET, try std.fmt.allocPrint(
        arena,
        "/projects/test/queries/{s}",
        .{job_id},
    ), "");
    try testing.expectEqual(std.http.Status.bad_request, results.status);
    try testing.expect(std.mem.indexOf(u8, results.body, "is not a query job") != null);
}

test "WRITE_EMPTY refuses a destination holding rows and leaves it alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\ "CREATE TABLE `test.d.dst` AS SELECT 9 AS a"}}}
    );

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"},
        \\ "writeDisposition":"WRITE_EMPTY"}}}
    );
    // The failure rides in the job, not in the HTTP status.
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        "Already Exists: Table test:d.dst",
        try errorResultMessage(arena, res.body),
    );

    const rows = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT a FROM `test.d.dst`"}
    );
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{"9"}),
        try cellsOf(arena, rows.body),
    );
}

test "WRITE_EMPTY accepts a destination that exists and is empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":"CREATE TABLE `test.d.dst` (a INT64)"}}}
    );

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"},
        \\ "writeDisposition":"WRITE_EMPTY"}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "errorResult") == null);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"copiedRows\":\"2\"") != null);
}

test "CREATE_NEVER will not bring a destination into existence" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"gone"},
        \\ "createDisposition":"CREATE_NEVER"}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        "Not found: Table test:d.gone",
        try errorResultMessage(arena, res.body),
    );
}

test "a source table that is not there is refused before a job exists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"absent"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"}}}}
    );
    try testing.expectEqual(std.http.Status.not_found, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "Not found: Table test:d.absent") != null);
}

test "a dataset that is not there is refused before a job exists" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"nope","tableId":"dst"}}}}
    );
    try testing.expectEqual(std.http.Status.not_found, res.status);
    // A copy job's dataset message carries no location suffix, where a query job into a
    // missing dataset adds one.
    try testing.expect(std.mem.indexOf(u8, res.body, "Not found: Dataset test:nope") != null);
    try testing.expect(std.mem.indexOf(u8, res.body, "was not found in location") == null);
}

test "WRITE_APPEND adds to the destination rather than rebuilding it" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\ "CREATE TABLE `test.d.dst` AS SELECT 9 AS a"}}}
    );

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"},
        \\ "writeDisposition":"WRITE_APPEND"}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);

    const rows = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT a FROM `test.d.dst` ORDER BY a"}
    );
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "1", "2", "9" }),
        try cellsOf(arena, rows.body),
    );
}

test "sources whose schemas disagree are refused before the destination is touched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\ "CREATE TABLE `test.d.other` AS SELECT 'x' AS a"}}}
    );

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTables":[{"projectId":"test","datasetId":"d","tableId":"src"},
        \\                 {"projectId":"test","datasetId":"d","tableId":"other"}],
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"}}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        "Incompatible table schemata between tables: test:d.src, test:d.other.",
        try errorResultMessage(arena, res.body),
    );

    // Nothing was written: the destination never came into existence.
    const missing = try request(s, arena, .GET, "/projects/test/datasets/d/tables/dst", "");
    try testing.expectEqual(std.http.Status.not_found, missing.status);
}

test "several sources concatenate into one destination" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\ "CREATE TABLE `test.d.more` AS SELECT 3 AS a"}}}
    );

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTables":[{"projectId":"test","datasetId":"d","tableId":"src"},
        \\                 {"projectId":"test","datasetId":"d","tableId":"more"}],
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"}}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"copiedRows\":\"3\"") != null);

    const rows = try request(s, arena, .POST, "/projects/test/queries",
        \\{"query":"SELECT a FROM `test.d.dst` ORDER BY a"}
    );
    try testing.expectEqualDeep(
        @as([]const []const u8, &.{ "1", "2", "3" }),
        try cellsOf(arena, rows.body),
    );
}

test "a view named as a source is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);
    _ = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\ "CREATE VIEW `test.d.v` AS SELECT a FROM `test.d.src`"}}}
    );

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"v"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"}}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings(
        "test:d.v is not allowed for this operation because it is currently a VIEW.",
        try errorResultMessage(arena, res.body),
    );
}

test "an unsupported operation type never becomes a job" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"},
        \\ "operationType":"SNAPSHOT"}}}
    );
    try testing.expectEqual(std.http.Status.bad_request, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "only COPY is supported") != null);
}

test "a truncating copy keeps the destination's description" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing.io, .{ .project = "test" });
    defer s.deinit();
    try copyFixture(s, arena);

    _ = try request(s, arena, .POST, "/projects/test/datasets/d/tables",
        \\{"tableReference":{"projectId":"test","datasetId":"d","tableId":"dst"},
        \\ "description":"kept across a rebuild",
        \\ "schema":{"fields":[{"name":"a","type":"INTEGER"}]}}
    );

    const res = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"copy":{
        \\ "sourceTable":{"projectId":"test","datasetId":"d","tableId":"src"},
        \\ "destinationTable":{"projectId":"test","datasetId":"d","tableId":"dst"},
        \\ "writeDisposition":"WRITE_TRUNCATE"}}}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);

    const meta = try request(s, arena, .GET, "/projects/test/datasets/d/tables/dst", "");
    try testing.expect(std.mem.indexOf(u8, meta.body, "kept across a rebuild") != null);
}
