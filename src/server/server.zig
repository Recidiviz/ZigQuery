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
const tabledata_handler = @import("handler/tabledata.zig");
const metadata = @import("internal/metadata/repository.zig");
const contentdata = @import("internal/contentdata/repository.zig");
const phase = zetasqlite.phase;
const io_stats = zetasqlite.io_stats;
const schema_mod = @import("internal/types/schema.zig");
const stats_mod = @import("stats.zig");
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
    /// The one engine connection. Single-threaded per Db, and deliberately
    /// not pooled — see the header.
    db: *driver.Db,
    jobs: query_handler.JobStore,
    /// Per-route timing, indexed by Route.Id.
    route_stats: std.enums.EnumArray(router.Route.Id, stats_mod.RouteStats) =
        std.enums.EnumArray(router.Route.Id, stats_mod.RouteStats).initFill(.{}),
    /// The slowest query jobs seen. A route percentile says the p99 is 33 ms;
    /// this says *which statement* that was, which is the difference between
    /// a number and a lead.
    slow_queries: stats_mod.SlowQueries(16, 400) = .{},
    started_ms: i64 = 0,
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
        // The connection's pragmas, when an environment override changed them.
        // A comparison run's whole claim rests on the knob having been
        // applied, and this is the only place that can say so.
        const applied = store.pragmas();
        if (io_stats.tempStorePragma() != null or io_stats.cacheSizePragma() != null) {
            for (applied) |p| std.log.info("connection pragma: {s}", .{p});
        }
        if (io_stats.isInstalled()) {
            std.log.info("io stats: '{s}' VFS installed, wrapping the {s} database", .{
                io_stats.vfs_name, @tagName(store.kind),
            });
        }
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
        // Startup loading is engine work but not request work, and counting it
        // would put analysis and SQLite time in the phase totals that never
        // appears in totalHandleMs — inflating both fractions past 1.0.
        phase.reset();
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
        // handler.go:2420-2424: the body's formatOptions OR the query string's.
        const int64_ts = q.use_int64_timestamp or useInt64TimestampParam(req);
        const res = try query_handler.runQueryFormatted(
            arena,
            s.db,
            project_id,
            job_id,
            q.query,
            int64_ts,
        );
        if (!res.ok) {
            return .{ .status = .bad_request, .body = res.body };
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
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(arena, "{\"uptimeSeconds\":");
        try out.print(arena, "{d}", .{
            @divFloor(@as(i64, @bitCast(nowSeed())), 1_000_000) - @divFloor(s.started_ms, 1000),
        });
        const reqs = http_server.stat_requests.load(.monotonic);
        const wait_ms = @as(f64, @floatFromInt(http_server.stat_wait_ns.load(.monotonic))) / 1e6;
        const handle_ms = @as(f64, @floatFromInt(http_server.stat_handle_ns.load(.monotonic))) / 1e6;
        try out.print(arena,
            ",\"contention\":{{\"requests\":{d},\"totalWaitMs\":{d:.1}," ++
                "\"totalHandleMs\":{d:.1},\"meanWaitMs\":{d:.3}," ++
                "\"meanHandleMs\":{d:.3},\"waitFraction\":{d:.3}," ++
                "\"maxWaiters\":{d},\"waitersNow\":{d}}}",
            .{
                reqs,
                wait_ms,
                handle_ms,
                if (reqs == 0) 0 else wait_ms / @as(f64, @floatFromInt(reqs)),
                if (reqs == 0) 0 else handle_ms / @as(f64, @floatFromInt(reqs)),
                if (wait_ms + handle_ms == 0) 0 else wait_ms / (wait_ms + handle_ms),
                http_server.stat_waiters_max.load(.monotonic),
                http_server.stat_waiters_now.load(.monotonic),
            });
        // Where engine time goes. `analysisFraction` is the number that
        // decides whether running analysis concurrently is worth anything:
        // wall time under N parallel analyzers is bounded by (1-f) + f/N, and
        // SQLite on an in-memory database cannot overlap at all (see
        // storage.zig). Measured against total handle time, so the remainder
        // is HTTP, JSON and glue.
        const ms = struct {
            fn of(ns: u64) f64 {
                return @as(f64, @floatFromInt(ns)) / 1e6;
            }
        }.of;
        const analyze_ms = ms(phase.totalNs(.analyze));
        const transform_ms = ms(phase.totalNs(.transform));
        const sqlite_ms = ms(phase.sqliteTotalNs());
        try out.print(arena,
            ",\"phases\":{{\"analyzeMs\":{d:.1},\"analyzeCount\":{d}," ++
                "\"transformMs\":{d:.1},\"transformCount\":{d}," ++
                "\"sqliteMs\":{d:.1}," ++
                "\"sqlite\":{{" ++
                "\"prepareMs\":{d:.1},\"prepareCount\":{d}," ++
                "\"stepMs\":{d:.1},\"stepCount\":{d}," ++
                "\"execMs\":{d:.1},\"execCount\":{d}," ++
                "\"engineMs\":{d:.1},\"catalogMs\":{d:.1},\"metadataMs\":{d:.1}," ++
                "\"catalogPrepareMs\":{d:.1},\"catalogPrepareCount\":{d}," ++
                "\"catalogStepMs\":{d:.1}}}," ++
                "\"preparedSqlBytes\":{d},\"codecMs\":{d:.1},\"codecCount\":{d},",
            .{
                analyze_ms,
                phase.count(.analyze),
                transform_ms,
                phase.count(.transform),
                sqlite_ms,
                ms(phase.totalNs(.sqlite_prepare)),
                phase.count(.sqlite_prepare),
                ms(phase.totalNs(.sqlite_step)),
                phase.count(.sqlite_step),
                ms(phase.totalNs(.sqlite_exec)),
                phase.count(.sqlite_exec),
                ms(phase.sqliteTotalNsFrom(.engine)),
                ms(phase.sqliteTotalNsFrom(.catalog)),
                ms(phase.sqliteTotalNsFrom(.metadata)),
                ms(phase.totalNsFrom(.sqlite_prepare, .catalog)),
                phase.countFrom(.sqlite_prepare, .catalog),
                ms(phase.totalNsFrom(.sqlite_step, .catalog)),
                phase.preparedBytes(),
                ms(phase.codecTotalNs()),
                phase.codecCount(),
            });
        // Split from the print above only because Zig caps a format call at 32
        // arguments. `codec.*` partitions `codecMs`.
        try out.print(arena,
            "\"codec\":{{\"timersEnabled\":{},\"encodeMs\":{d:.1},\"encodeCount\":{d}," ++
                "\"decodeMs\":{d:.1},\"decodeCount\":{d}," ++
                "\"literalMs\":{d:.1},\"literalCount\":{d}}}," ++
                "\"analysisFraction\":{d:.3},\"sqliteFraction\":{d:.3}}}",
            .{
                // Zeros below mean "not instrumented" when this is false, not
                // "no codec work happened". See -Dcodec-timers.
                phase.codec_timers_enabled,
                ms(phase.totalNs(.codec_encode)),
                phase.count(.codec_encode),
                ms(phase.totalNs(.codec_decode)),
                phase.count(.codec_decode),
                ms(phase.totalNs(.codec_literal)),
                phase.count(.codec_literal),
                if (handle_ms == 0) 0 else (analyze_ms + transform_ms) / handle_ms,
                if (handle_ms == 0) 0 else sqlite_ms / handle_ms,
            });
        // SQLite's own allocator accounting.
        //
        // `lookaside.hitRate` is the number that matters. Lookaside is a
        // per-connection pool of small fixed-size slots serving the many
        // short-lived allocations sqlite3_prepare_v2 makes for parse-tree and
        // VDBE structures — the phase measured at 22% of handle time. A rate
        // near 1.0 means allocation is already off the critical path; a rate
        // near 0 with `missFull` high means the pool is exhausted.
        //
        // Exhausted is not the same as costly: on the view graph the rate was
        // driven from 0.0000 to 0.9676 with no effect on prepare time outside
        // the noise floor (Options.lookaside records the table). These are
        // reported so that stays a measurement rather than a belief, in either
        // direction.
        const alloc = s.db.allocStats();
        try out.print(arena, ",\"sqliteAlloc\":{{" ++
            "\"memoryUsedBytes\":{d},\"memoryUsedPeakBytes\":{d}," ++
            "\"mallocsOutstanding\":{d},\"mallocsOutstandingPeak\":{d}," ++
            "\"largestAllocBytes\":{d}," ++
            "\"schemaBytes\":{d},\"stmtBytes\":{d},\"pagerCacheBytes\":{d}," ++
            "\"lookaside\":{{\"hit\":{d},\"missSize\":{d},\"missFull\":{d}," ++
            "\"hitRate\":{d:.4},\"slotsInUse\":{d},\"slotsPeak\":{d}}}}}", .{
            alloc.memory_used.current,
            alloc.memory_used.highwater,
            alloc.malloc_count.current,
            alloc.malloc_count.highwater,
            alloc.malloc_size_max,
            alloc.schema_used,
            alloc.stmt_used,
            alloc.cache_used,
            alloc.lookaside_hit,
            alloc.lookaside_miss_size,
            alloc.lookaside_miss_full,
            alloc.hitRate() orelse 0.0,
            alloc.lookaside_used.current,
            alloc.lookaside_used.highwater,
        });
        // What actually reached a filesystem. The main database is memdb, so
        // `mainDb` bytes are memcpy; everything else is a file the OS backs,
        // including on this in-memory server (see internal/io_stats.zig).
        // Present only with ZQL_IO_STATS set, since the wrapper times every
        // read and write it forwards.
        if (io_stats.isInstalled()) {
            try out.appendSlice(arena, ",\"sqliteIo\":{");
            var first_kind = true;
            for (std.enums.values(io_stats.Kind)) |k| {
                const st = io_stats.kindStats(k);
                if (!st.touched()) continue;
                if (!first_kind) try out.append(arena, ',');
                first_kind = false;
                try out.print(arena, "\"{s}\":{{\"opens\":{d},\"writes\":{d}," ++
                    "\"writeBytes\":{d},\"writeMs\":{d:.1},\"reads\":{d}," ++
                    "\"readBytes\":{d},\"readMs\":{d:.1},\"syncs\":{d}," ++
                    "\"syncMs\":{d:.1},\"maxOffsetBytes\":{d}}}", .{
                    k.label(),   st.opens,   st.writes,  st.write_bytes,
                    st.write_ms, st.reads,   st.read_bytes, st.read_ms,
                    st.syncs,    st.sync_ms, st.max_offset,
                });
            }
            const t = io_stats.tempTotals();
            const p = io_stats.probeResult();
            try out.print(arena, "{s}\"tempTotals\":{{\"opens\":{d},\"writes\":{d}," ++
                "\"writeBytes\":{d},\"writeMs\":{d:.1},\"reads\":{d}," ++
                "\"readBytes\":{d},\"readMs\":{d:.1},\"largestFileBytes\":{d}}}," ++
                "\"fdProbe\":{{\"ran\":{},\"unlinkedRegularFiles\":{d}," ++
                "\"largestBytes\":{d},\"device\":{d}}}}}", .{
                if (first_kind) "" else ",",
                t.opens,
                t.writes,
                t.write_bytes,
                t.write_ms,
                t.reads,
                t.read_bytes,
                t.read_ms,
                t.max_offset,
                p.ran,
                p.unlinked_files,
                p.largest_bytes,
                p.device,
            });
        }
        try out.appendSlice(arena, ",\"routes\":[");

        var first = true;
        var it = s.route_stats.iterator();
        while (it.next()) |entry| {
            const st = entry.value;
            if (st.count == 0) continue;
            if (!first) try out.append(arena, ',');
            first = false;
            try out.appendSlice(arena, "{\"route\":\"");
            try out.appendSlice(arena, @tagName(entry.key));
            try out.appendSlice(arena, "\",");
            try out.print(arena, "\"count\":{d},\"meanMs\":{d:.3},\"minMs\":{d:.3}," ++
                "\"p50Ms\":{d:.3},\"p90Ms\":{d:.3},\"p99Ms\":{d:.3},\"maxMs\":{d:.3}," ++
                "\"totalMs\":{d:.1}", .{
                st.count,
                st.meanUs() / 1000.0,
                @as(f64, @floatFromInt(st.min_us)) / 1000.0,
                @as(f64, @floatFromInt(st.percentileUs(0.50))) / 1000.0,
                @as(f64, @floatFromInt(st.percentileUs(0.90))) / 1000.0,
                @as(f64, @floatFromInt(st.percentileUs(0.99))) / 1000.0,
                @as(f64, @floatFromInt(st.max_us)) / 1000.0,
                @as(f64, @floatFromInt(st.total_us)) / 1000.0,
            });
            try out.append(arena, '}');
        }
        try out.appendSlice(arena, "],\"slowQueries\":[");
        var slow_buf: [16]*const @TypeOf(s.slow_queries).Entry = undefined;
        for (s.slow_queries.sorted(&slow_buf), 0..) |e, i| {
            if (i > 0) try out.append(arena, ',');
            try out.print(arena, "{{\"ms\":{d:.3},\"sql\":", .{
                @as(f64, @floatFromInt(e.us)) / 1000.0,
            });
            try errors.writeJsonString(arena, &out, e.sql());
            try out.append(arena, '}');
        }
        try out.appendSlice(arena, "]}");
        return .{ .body = out.items };
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
        const arena = req.arena;
        // deleteContents drops the tables too; without it Go errors when the
        // dataset is non-empty. The emulator is permissive here.
        //
        // They have to leave the content database as well, exactly as
        // tables.delete does: tables.get falls back to the engine catalog when
        // the metadata store misses, so a table dropped from metadata alone
        // stays visible and the next CREATE reports it already exists.
        //
        // The engine is asked rather than the metadata store, because it is
        // the one that knows about objects created by SQL — a CTAS or a
        // CREATE VIEW run as a query job never reaches tables.insert.
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
            s.db.exec(ddl, &.{}, .{}) catch {};
        }
        try s.repo.deleteTablesInDataset(project_id, dataset_id);
        try s.repo.deleteDataset(project_id, dataset_id);
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

        // A table only becomes queryable once the DDL runs; Go does the same
        // through its content repository.
        var kind: []const u8 = "TABLE";
        var effective_schema = schema_node;
        if (tables_handler.viewQueryFromBody(parsed)) |view_sql| {
            kind = "VIEW";
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
            // A client posts a view with no schema; the columns are whatever
            // the SELECT resolves to. Go returns them from CreateView and
            // assigns them to the resource (handler.go tablesInsertHandler),
            // which is what google-cloud-bigquery reads off create_table().
            if (try server.db.catalogTable(arena, project_id, dataset_id, table_id)) |view_spec| {
                if (try schemaJsonFromSpec(arena, view_spec)) |derived| {
                    effective_schema = derived;
                }
            }
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

        const meta = tables_handler.TableMeta{
            .project_id = project_id,
            .dataset_id = dataset_id,
            .table_id = table_id,
            .endpoint = server.endpoint,
            .created_millis = @divFloor(@as(i64, @bitCast(nowSeed())), 1000),
            .schema = effective_schema,
            .kind = kind,
            .posted = parsed,
        };
        var out: std.ArrayList(u8) = .empty;
        try tables_handler.writeTable(arena, &out, meta);
        try server.repo.addTable(project_id, dataset_id, table_id, out.items);

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
        if (try s.repo.findTable(arena, project_id, dataset_id, table_id)) |stored| {
            return .{ .body = stored };
        }

        // Not in the metadata store, which does not mean it does not exist:
        // anything created by SQL rather than by tables.insert — a
        // CREATE OR REPLACE VIEW run as a query job, a CTAS — lives in the
        // engine catalog only. Go reconciles these eagerly via
        // ChangedCatalog + syncCatalog (handler.go:2218-2320); here the
        // metadata store is treated as a cache over the engine, which is the
        // actual source of truth, and the row is filled in on first read.
        if (try s.tableResourceFromEngine(arena, project_id, dataset_id, table_id)) |resource| {
            try s.repo.addTable(project_id, dataset_id, table_id, resource);
            return .{ .body = resource };
        }

        return notFound(arena, try std.fmt.allocPrint(
            arena,
            "table {s} is not found",
            .{table_id},
        ));
    }

    /// Builds a table resource for something the engine knows about but the
    /// metadata store does not, deriving its schema from the engine. Returns
    /// null when the engine does not have it either.
    fn tableResourceFromEngine(
        s: *Server,
        arena: std.mem.Allocator,
        project_id: []const u8,
        dataset_id: []const u8,
        table_id: []const u8,
    ) !?[]const u8 {
        // Look the object up in the catalog rather than probing with a
        // SELECT. A probe answers "is this currently resolvable", not "does
        // this exist": while views are being materialized their dependencies
        // are dropped and recreated constantly, so a probe reports a
        // perfectly good view as missing whenever it happens to race one of
        // those windows.
        const table_spec = (try s.db.catalogTable(
            arena,
            project_id,
            dataset_id,
            table_id,
        )) orelse return null;

        const schema_json = try schemaJsonFromSpec(arena, table_spec);

        var out: std.ArrayList(u8) = .empty;
        try tables_handler.writeTable(arena, &out, .{
            .project_id = project_id,
            .dataset_id = dataset_id,
            .table_id = table_id,
            .endpoint = s.endpoint,
            .created_millis = @divFloor(@as(i64, @bitCast(nowSeed())), 1000),
            .schema = schema_json,
            .kind = if (table_spec.is_view) "VIEW" else "TABLE",
        });
        return out.items;
    }

    /// server/handler.go tablesPatchHandler: a key-level merge of the posted
    /// body over the stored resource (metadata.Table.Update is `maps.Copy`
    /// then override), answering with the merged resource. `schema` is
    /// rejected outright, as Go does.
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

        // Fall back to the engine for a table that was created by SQL and has
        // never been read, exactly as tables.get does.
        const stored = (try s.repo.findTable(arena, project_id, dataset_id, table_id)) orelse
            (try s.tableResourceFromEngine(arena, project_id, dataset_id, table_id)) orelse
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is not found",
                .{table_id},
            ));

        const current = std.json.parseFromSliceLeaky(std.json.Value, arena, stored, .{}) catch {
            return .{ .body = stored };
        };

        var merged: std.json.ObjectMap = .empty;
        if (current == .object) {
            var it = current.object.iterator();
            while (it.next()) |kv| try merged.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }
        if (patch == .object) {
            var it = patch.object.iterator();
            while (it.next()) |kv| try merged.put(arena, kv.key_ptr.*, kv.value_ptr.*);
        }

        var out: std.ArrayList(u8) = .empty;
        try tables_handler.writeTable(arena, &out, .{
            .project_id = project_id,
            .dataset_id = dataset_id,
            .table_id = table_id,
            .endpoint = s.endpoint,
            .created_millis = creationMillisOf(current),
            .schema = schemaOf(current),
            .kind = typeOf(current),
            .posted = .{ .object = merged },
        });
        try s.repo.addTable(project_id, dataset_id, table_id, out.items);
        return .{ .body = out.items };
    }

    /// A catalog spec's columns as the parsed `schema` node of a table
    /// resource. Null when the schema will not re-parse, which leaves the
    /// resource schema-less rather than failing the request.
    fn schemaJsonFromSpec(
        arena: std.mem.Allocator,
        table_spec: *const zetasqlite.spec.TableSpec,
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
                // Go's TableListTables echoes clustering, labels and the
                // partitioning fields off the stored resource.
                .posted = v,
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

    /// server/handler.go tabledataInsertAllHandler (:2969-3088).
    ///
    /// The batch is all-or-nothing: an unknown top-level field in any row
    /// rejects every row, answered 200 with per-row insertErrors, and no
    /// other failure produces insertErrors at all — Go maps them to 500
    /// internalError. See handler/tabledata.zig.
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

        // Go resolves the table in withTableMiddleware, before the handler
        // runs, and 404s from the metadata store alone.
        const stored = (try s.repo.findTable(arena, project_id, dataset_id, table_id)) orelse
            return notFound(arena, try std.fmt.allocPrint(
                arena,
                "table {s} is not found",
                .{table_id},
            ));
        const meta = std.json.parseFromSliceLeaky(std.json.Value, arena, stored, .{}) catch
            return internalError(arena, "failed to decode metadata to table");
        const fields = tabledata_handler.schemaFieldsOf(meta) orelse
            return internalError(arena, try std.fmt.allocPrint(
                arena,
                "table {s} has no schema",
                .{table_id},
            ));

        const rows = tabledata_handler.rowsFromBody(arena, parsed) catch
            return badRequest(arena, "failed to decode request body");

        const validation = try tabledata_handler.validateAgainstSchema(arena, fields, rows);
        if (validation.len > 0) {
            // Nothing is written, and the status stays 200: the errors are
            // the response body, not an HTTP failure.
            var out: std.ArrayList(u8) = .empty;
            try tabledata_handler.writeInsertErrors(arena, &out, validation, rows.len);
            return .{ .body = out.items };
        }

        var repo = contentdata.Repository{ .arena = arena, .db = s.db };
        repo.addTableData(project_id, dataset_id, table_id, fields, rows) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return internalError(arena, repo.message),
        };

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

        const parsed = std.json.parseFromSliceLeaky(std.json.Value, arena, req.body, .{}) catch {
            return badRequest(arena, "failed to decode request body");
        };
        const sql = jobs_handler.queryFromJobConfig(parsed) orelse {
            return badRequest(arena, "configuration.query.query is required");
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
        const int64_ts = useInt64TimestampParam(req);

        // A query job may carry a destination table: this is how view
        // materialization writes results. Run the DDL form instead of the
        // bare SELECT, then record the resulting table's metadata.
        const res = if (jobs_handler.destinationFromJobConfig(parsed)) |dst| blk: {
            s.materializeInto(arena, dst, sql) catch |err| switch (err) {
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
            try s.recordMaterializedTable(arena, dst);
            // Materialization returns no rows of its own.
            break :blk try query_handler.runQueryFormatted(
                arena,
                s.db,
                project_id,
                job_id,
                try std.fmt.allocPrint(arena, "SELECT * FROM `{s}.{s}.{s}` LIMIT 0", .{
                    dst.project_id, dst.dataset_id, dst.table_id,
                }),
                int64_ts,
            );
        } else try query_handler.runQueryFormatted(arena, s.db, project_id, job_id, sql, int64_ts);
        s.slow_queries.record(nowSeed() -| job_t0, sql);

        if (!res.ok) {
            // Log the statement alongside the failure: an analyzer message on
            // its own rarely identifies which query produced it.
            std.log.warn(
                "job failed: {s}\n  sql: {s}",
                .{ s.db.lastError(), sql[0..@min(sql.len, 600)] },
            );
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

        try s.jobs.put(project_id, job_id, res.set.?, resource.items);
        return .{ .body = resource.items };
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
    fn materializeInto(
        s: *Server,
        arena: std.mem.Allocator,
        dst: jobs_handler.Destination,
        sql: []const u8,
    ) !void {
        if (jobs_handler.isAppend(dst)) {
            const append = try jobs_handler.appendDdl(arena, dst, sql);
            if (s.db.exec(append, &.{}, .{})) |_| return else |_| {
                std.log.info(
                    "append into {s}.{s}.{s} did not fit the existing shape; " ++
                        "rebuilding from the query, as Go does ({s})",
                    .{ dst.project_id, dst.dataset_id, dst.table_id, s.db.lastError() },
                );
            }
        }
        const replace = try jobs_handler.replaceDdl(arena, dst, sql);
        s.db.exec(replace, &.{}, .{}) catch {
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
        const arena = req.arena;
        const job = s.jobs.get(job_id) orelse return notFoundJob(arena, job_id);
        // handler.go:1497-1498 takes both from the query string only, and Go
        // honours formatOptions here. We always render int64 microseconds
        // instead, whether or not the flag came through.
        //
        // Go can respect an absent flag because its maxResults=0 probe returns
        // no rows at all, so nothing unreadable reaches the client: it re-reads
        // through the Storage Read API over gRPC. We do not serve that API, so
        // the rows on that probe ARE what the client parses, and every branch
        // of _is_almost_completely_cached (table.py:1908-1935) that would make
        // it ask again also routes it to Storage. Since
        // CellDataParser.timestamp_to_py applies a bare int(value), a
        // "sec.microRemainder" cell is unreadable to any client at top level —
        // there is no format here that is both faithful and usable.
        //
        // Scoped deliberately to this endpoint. jobs.query is under no such
        // constraint and still honours the flag, which is what keeps
        // testdata/golden.json (captured from /queries) byte-exact. Revert to
        // useInt64TimestampParam(req) if the Storage Read API ever lands.
        var out: std.ArrayList(u8) = .empty;
        try query_handler.writeResultSet(
            arena,
            &out,
            project_id,
            job_id,
            job.set,
            maxResultsParam(req),
            true,
        );
        return .{ .body = out.items };
    }
};

/// `formatOptions.useInt64Timestamp` from the query string
/// (handler.go isFormatOptionsUseInt64Timestamp).
/// `maxResults` from the query string, defaulting to Go's -1 ("every row").
/// A value Go's ParseInt rejects also falls back to the default.
fn maxResultsParam(req: *const http_server.Request) i64 {
    const v = req.queryParam("maxResults") orelse return query_handler.max_results_default;
    return std.fmt.parseInt(i64, v, 10) catch query_handler.max_results_default;
}

fn useInt64TimestampParam(req: *const http_server.Request) bool {
    const v = req.queryParam("formatOptions.useInt64Timestamp") orelse return false;
    return query_handler.parseGoBool(v);
}

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

fn schemaOf(v: std.json.Value) ?std.json.Value {
    if (v != .object) return null;
    return v.object.get("schema");
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

/// Go errInternalError: what every non-validation failure of a handler
/// becomes, including ones a stricter API would call a 400.
fn internalError(arena: std.mem.Allocator, msg: []const u8) !http_server.Response {
    return .{
        .status = .internal_server_error,
        .body = try errors.body(arena, .internal_error, msg),
    };
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
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    return v.object.get("rows").?.array.items[0].object.get("f").?
        .array.items[0].object.get("v").?.string;
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

// Regression: the request sequence google-cloud-bigquery actually performs
// for QueryJob.result() has to hand back a TIMESTAMP the client can parse.
//
// The client posts jobs.insert, then probes getQueryResults with
// `maxResults=0` and NO formatOptions — client.py:2086 only adds
// `formatOptions.useInt64Timestamp` when page_size > 0. It nevertheless
// parses whatever rows that response carries: with the `rows` key present and
// no pageToken it considers the page complete (table.py:1924-1928) and never
// asks again. CellDataParser.timestamp_to_py then applies a bare int(value),
// so a "sec.rem" cell raises
//
//   ValueError: invalid literal for int() with base 10: '1767268800.0'
//
// which is what recidiviz's llm_extraction_results_persister_test
// ::test_at_least_once_re_persist_appends_duplicate_rows hits on
// result_datetime_utc — the timestamp used here is that test's own value.
//
// Go escapes this by returning no rows at all for maxResults=0, sending the
// client to the Storage Read API over gRPC. We do not serve that API, so the
// rows we return on this probe are the ones the client reads, and they have
// to be int64 microseconds.
test "getQueryResults maxResults=0 renders TIMESTAMP the client can parse" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test" });
    defer s.deinit();

    const insert = try request(s, arena, .POST, "/projects/test/jobs",
        \\{"configuration":{"query":{"query":
        \\"SELECT TIMESTAMP '2026-01-01 12:00:00+00' AS result_datetime_utc",
        \\"useLegacySql":false}}}
    );
    try testing.expectEqual(std.http.Status.ok, insert.status);
    const job_id = try jobIdOf(arena, insert.body);

    const path = try std.fmt.allocPrint(arena, "/projects/test/queries/{s}", .{job_id});
    const res = try requestQuery(s, arena, .GET, path, "maxResults=0&prettyPrint=false", "");
    try testing.expectEqual(std.http.Status.ok, res.status);

    const cell = try onlyCell(arena, res.body);
    // int(value) is what the client does, and it rejects "1767268800.0".
    _ = std.fmt.parseInt(i64, cell, 10) catch {
        std.debug.print(
            "TIMESTAMP cell {s} is not int64 micros; the BigQuery client cannot parse it\n",
            .{cell},
        );
        return error.TestExpectedEqual;
    };
    try testing.expectEqualStrings("1767268800000000", cell);
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

test "deleting a dataset takes its tables out of the engine too" {
    // The Python suite wipes the emulator between tests with
    // delete_dataset(delete_contents=True); leaving the tables in the content
    // database made every test after the first report "already exists",
    // because tables.get falls back to the engine catalog.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "streamed");

    // `age` arrives as a JSON string, which is what google-cloud-bigquery's
    // insert_rows sends for an INTEGER column.
    const res = try request(
        s,
        arena,
        .POST,
        "/projects/test/datasets/ds1/tables/streamed/insertAll",
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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

test "tables.patch refuses to change a schema, as Go does" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "prefixed");

    const res = try request(
        s,
        arena,
        .POST,
        "/bigquery/v2/projects/test/datasets/ds1/tables/prefixed/insertAll",
        \\{"rows":[{"json":{"name":"x","age":1}}]}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("{}", res.body);
}

test "insertAll into a missing table is a 404" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();

    const res = try request(
        s,
        arena,
        .POST,
        "/projects/test/datasets/ds1/tables/nope/insertAll",
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

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "rejected");

    // emulator_test.py test_insert_unknown_fields_mixed_valid_and_invalid:
    // rows 1 and 3 are invalid, and rows 0 and 2 report `stopped` after them.
    const res = try request(
        s,
        arena,
        .POST,
        "/projects/test/datasets/ds1/tables/rejected/insertAll",
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

test "insertAll surfaces a bad value as a 500, not as insertErrors" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "badvalue");

    // Go maps every storage-layer failure to errInternalError.
    const res = try request(
        s,
        arena,
        .POST,
        "/projects/test/datasets/ds1/tables/badvalue/insertAll",
        \\{"rows":[{"json":{"name":"a","age":"not a number"}}]}
    );
    try testing.expectEqual(std.http.Status.internal_server_error, res.status);
    try testing.expect(std.mem.indexOf(u8, res.body, "\"reason\":\"internalError\"") != null);
}

test "insertAll with no rows is a no-op" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
    defer s.deinit();
    try createStreamTable(s, arena, "empty");

    const res = try request(
        s,
        arena,
        .POST,
        "/projects/test/datasets/ds1/tables/empty/insertAll",
        \\{"kind":"bigquery#tableDataInsertAllRequest"}
    );
    try testing.expectEqual(std.http.Status.ok, res.status);
    try testing.expectEqualStrings("{}", res.body);
}

test "insertAll rejects a malformed body with 400" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var s = try Server.init(testing.allocator, testing_io, .{ .project = "test", .dataset = "ds1" });
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
