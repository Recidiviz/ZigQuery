//! Port of bigquery-emulator server/handler.go jobsQueryHandler (:2411-2487)
//! and jobsGetQueryResultsHandler (:1488-1540), plus the query path of
//! internal/contentdata/repository.go (Query, :178-305).
//!
//! Differences from Go, by design:
//! - No flexible_rpc_marshalling.go. All 209 lines of it exist because Go's
//!   typed-struct encoding/json cannot distinguish absent from null and
//!   rejects JSON numbers for string-typed fields. Decoding into
//!   std.json.Value has both properties natively.

const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const spec = zigquery.spec;
const encoder = zigquery.encoder;
const job_rows_vtab = zigquery.function.job_rows_vtab;
const errors = @import("../error.zig");
const response = @import("../internal/types/response.zig");
const tablerow = @import("../internal/types/tablerow.zig");
const json_pb = @import("../json_pb.zig");
const schema_mod = @import("../internal/types/schema.zig");
const queryparam = @import("../internal/types/queryparam.zig");
const pb = @import("../proto/bigquery.zig");

pub const Error = error{
    /// Body was not an object, or `query` was missing / not a string.
    InvalidRequest,
} || queryparam.Error;

pub const QueryRequest = struct {
    query: []const u8,
    dry_run: bool = false,
    /// `queryParameters`, already reshaped for the driver. Empty when the
    /// request carries none.
    ///
    /// `parameterMode` is deliberately not read: the driver decides named vs
    /// positional by scanning the SQL text (driver.parameterMode), which is
    /// also what Go does, and the two cannot disagree without the query
    /// itself being malformed.
    params: []const driver.Param = &.{},
    /// Present but unused: Go's jobs.query ignores maxResults entirely, in
    /// both the body and the query string. Only getQueryResults honours it.
    /// Verified against the running Go emulator.
    max_results: ?i64 = null,
    /// `formatOptions.useInt64Timestamp` from the body. jobs.query ORs this
    /// with the query-string form (handler.go:2420-2424); the other two
    /// endpoints read only the query string.
    use_int64_timestamp: bool = false,
};

/// Reads a jobs.query request: the body, the query string, and the project id
/// the path bound.
///
/// `google.api.http` puts the body under `query_request`
/// (job.proto JobService.Query), so the two merge into one PostQueryRequest.
pub fn parseRequest(
    arena: std.mem.Allocator,
    body: []const u8,
    query: []const u8,
) Error!QueryRequest {
    const parsed = json_pb.parseBody(arena, body) catch return error.InvalidRequest;
    const merged = json_pb.requestValue(arena, .{
        .body = parsed,
        .body_field = "queryRequest",
        .query = query,
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };
    const post = pb.PostQueryRequest.jsonDecode(arena, merged, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRequest,
    };

    const q = post.query_request orelse return error.InvalidRequest;
    var req = QueryRequest{ .query = q.query orelse return error.InvalidRequest };
    req.dry_run = q.dry_run orelse false;
    if (q.max_results) |m| req.max_results = if (m.value) |n| @intCast(n) else null;
    // handler.go:2420-2424: the body's formatOptions OR the query string's. The
    // query string cannot reach the nested request through the http binding, so
    // it is read on its own.
    req.use_int64_timestamp = int64Timestamp(q.format_options) or
        int64TimestampFromQuery(arena, query);
    req.params = try queryparam.parseTyped(arena, q.query_parameters);
    return req;
}

fn int64Timestamp(opts: ?*const pb.DataFormatOptions) bool {
    const o = opts orelse return false;
    return o.use_int64_timestamp orelse false;
}

/// `formatOptions.useInt64Timestamp` as a query-string parameter, which the
/// dotted key nests back into a DataFormatOptions.
pub fn int64TimestampFromQuery(arena: std.mem.Allocator, query: []const u8) bool {
    const merged = json_pb.requestValue(arena, .{ .query = query }) catch return false;
    const q = pb.QueryRequest.jsonDecode(arena, merged, .{}) catch return false;
    return int64Timestamp(q.format_options);
}

/// `maxResults` and `pageToken` from a getQueryResults query string.
/// handler.go:1497-1498 takes both from the query string only.
pub fn parseResultsPage(arena: std.mem.Allocator, query: []const u8) Page {
    const merged = json_pb.requestValue(arena, .{ .query = query }) catch return .{};
    const r = pb.GetQueryResultsRequest.jsonDecode(arena, merged, .{}) catch return .{};
    return .{
        // Go's -1 default means "every row"; a value ParseInt rejects lands
        // here too, because the decoder leaves the field absent.
        .max_results = if (r.max_results) |m|
            (if (m.value) |n| @as(i64, @intCast(n)) else max_results_default)
        else
            max_results_default,
        .start = parsePageToken(r.page_token),
    };
}

/// A completed query, retained so jobs.get and getQueryResults can replay it.
pub const Job = struct {
    /// Owns everything below. See `JobStore`.
    ///
    /// Behind a pointer, not by value: an `ArenaAllocator`'s `allocator()`
    /// captures the address of the arena it was taken from, so a copy made
    /// before the allocations happen — which is what a struct literal does,
    /// its fields evaluating in source order — records none of them and frees
    /// nothing. A heap arena has one stable address and cannot go stale.
    arena: *std.heap.ArenaAllocator,
    project_id: []const u8,
    job_id: []const u8,
    /// The rows and schema, kept rather than a finished body: getQueryResults
    /// picks maxResults and formatOptions per request, and the request that
    /// ran the query cannot know either.
    set: ResultSet,
    /// Serialized bigquery#job resource, for jobs.get.
    resource: []const u8,
};

/// Process-local job store.
///
/// Every job owns an arena. The rows a job retains are storage-form values plus
/// a deep copy of the column types they were produced under, and a type tree is
/// not something to free a piece at a time — so each entry is allocated
/// together and released together.
pub const JobStore = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Job) = .empty,

    pub fn deinit(s: *JobStore) void {
        var it = s.map.iterator();
        while (it.next()) |kv| s.release(kv.value_ptr);
        s.map.deinit(s.gpa);
    }

    fn release(s: *JobStore, job: *Job) void {
        job.arena.deinit();
        s.gpa.destroy(job.arena);
    }

    pub fn put(
        s: *JobStore,
        project_id: []const u8,
        job_id: []const u8,
        set: ResultSet,
        resource: []const u8,
    ) !void {
        const arena_ptr = try s.gpa.create(std.heap.ArenaAllocator);
        arena_ptr.* = std.heap.ArenaAllocator.init(s.gpa);
        errdefer {
            arena_ptr.deinit();
            s.gpa.destroy(arena_ptr);
        }
        const arena = arena_ptr.allocator();

        const job = Job{
            .arena = arena_ptr,
            .project_id = try arena.dupe(u8, project_id),
            .job_id = try arena.dupe(u8, job_id),
            .set = try set.cloneInto(arena),
            .resource = try arena.dupe(u8, resource),
        };

        // The key points into the job's own arena, so removing an entry and
        // releasing its memory are one action rather than two that can disagree.
        const gop = try s.map.getOrPut(s.gpa, job.job_id);
        if (gop.found_existing) s.release(gop.value_ptr);
        gop.key_ptr.* = job.job_id;
        gop.value_ptr.* = job;
    }

    pub fn get(s: *JobStore, job_id: []const u8) ?Job {
        return s.map.get(job_id);
    }

    /// What `job_rows_vtab` calls to find a job's rows, with `s` as its context.
    ///
    /// Storage form on both sides, so this hands over a view of what the job
    /// already holds and copies nothing. A missing job is null, which the module
    /// reads as an empty table.
    pub fn lookupRows(ctx: *anyopaque, job_id: []const u8) ?job_rows_vtab.RowSet {
        const s: *JobStore = @ptrCast(@alignCast(ctx));
        const job = s.map.get(job_id) orelse return null;
        return .{ .names = job.set.names, .cells = job.set.cells };
    }
};

/// Go server/util.go randomID: 27 alphanumeric characters.
///
/// The first is a letter, where Go's may be a digit. A job id becomes a table
/// id — the destination table's — and `grpc/read_service.isSafeIdentifier`
/// requires a leading letter or underscore before it will quote a name into
/// SQL, so a digit there made Storage reads of the destination fail with
/// `MalformedTableName` for about one job in six. Narrowing the first character
/// is the cheap end of that fix: job ids are opaque to clients, where relaxing
/// the guard would weaken an injection check on a name the client supplies.
pub fn randomId(arena: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]const u8 {
    const letters = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const alphabet = letters ++ "0123456789";
    const out = try arena.alloc(u8, 27);
    out[0] = letters[rng.random().uintLessThan(usize, letters.len)];
    for (out[1..]) |*c| c.* = alphabet[rng.random().uintLessThan(usize, alphabet.len)];
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
/// A query's result, kept in the form it was stored in rather than the form it
/// is served in.
///
/// This used to hold the REST rendering — and a *second* full rendering
/// whenever a top-level TIMESTAMP column existed, since `useInt64Timestamp`
/// changes it. One copy of the storage-form values replaces both, and is also
/// exactly what `job_rows_vtab` serves, so the destination table and
/// `getQueryResults` read the same bytes instead of two renderings that could
/// disagree. Rendering moves to request time, where the format options
/// actually are.
pub const ResultSet = struct {
    /// Output column names, in order. Held apart from `columns` because the
    /// virtual table wants only these.
    names: []const []const u8,
    /// Column types, deep-copied: the originals live in the statement's arena
    /// and die with it, and rendering a cell needs the declared type — an
    /// integer is an INT64 or a DATE depending on it.
    types: []const *spec.Type,
    /// `total_rows * names.len` values, row-major.
    cells: []const encoder.SqliteRepr,
    /// Reported in full even when a response carries fewer rows, matching Go.
    total_rows: usize,

    fn cloneInto(set: ResultSet, arena: std.mem.Allocator) !ResultSet {
        const names = try arena.alloc([]const u8, set.names.len);
        for (set.names, names) |src, *dst| dst.* = try arena.dupe(u8, src);
        const types = try arena.alloc(*spec.Type, set.types.len);
        for (set.types, types) |src, *dst| dst.* = try spec.cloneType(arena, src);
        const cells = try arena.alloc(encoder.SqliteRepr, set.cells.len);
        for (set.cells, cells) |src, *dst| dst.* = switch (src) {
            .null, .int, .float => src,
            .blob => |b| .{ .blob = try arena.dupe(u8, b) },
        };
        return .{
            .names = names,
            .types = types,
            .cells = cells,
            .total_rows = set.total_rows,
        };
    }

    /// What one rendering pass needs, so it is derived once rather than per row.
    pub const Render = struct {
        set: ResultSet,
        arena: std.mem.Allocator,
        cols: []const driver.OutputColumn,
        use_int64_timestamp: bool,

        /// One row, decoded and rendered.
        ///
        /// `materializeRow` still runs even though `cellFrom` already applied
        /// the declared type: a NULL ARRAY decodes to a null cell, and BigQuery
        /// renders it as `[]`, which is what that pass is for.
        pub fn row(r: Render, i: usize) ![]const driver.Cell {
            const n = r.set.names.len;
            const out = try r.arena.alloc(driver.Cell, n);
            for (out, 0..) |*dst, col| {
                dst.* = try driver.cellFrom(r.arena, r.set.cells[i * n + col], r.set.types[col]);
            }
            const materialized = try response.materializeRow(r.arena, out, r.cols);
            if (!r.use_int64_timestamp) return materialized;
            return response.formatInt64Timestamps(r.arena, materialized);
        }
    };

    fn renderer(
        set: ResultSet,
        arena: std.mem.Allocator,
        use_int64_timestamp: bool,
    ) !Render {
        return .{
            .set = set,
            .arena = arena,
            .cols = try set.columns(arena),
            .use_int64_timestamp = use_int64_timestamp,
        };
    }

    /// The columns as the response helpers want them.
    fn columns(set: ResultSet, arena: std.mem.Allocator) ![]const driver.OutputColumn {
        const out = try arena.alloc(driver.OutputColumn, set.names.len);
        for (out, set.names, set.types) |*dst, name, t| dst.* = .{ .name = name, .type = t };
        return out;
    }
};

/// Go's `maxResultsDefaultValue`: absent means "every row".
pub const max_results_default: i64 = -1;

/// Which slice of a stored ResultSet one response carries.
///
/// Truncating without a token silently loses rows: the Python client sees a
/// short page with no `pageToken`, decides the read is complete
/// (table.py:1924-1928), and stops. So the two travel together — a page that
/// ends early always says where the next one starts, and that is what makes
/// honouring `maxResults` safe at all.
pub const Page = struct {
    /// `maxResults`, or -1 for "every row".
    max_results: i64 = max_results_default,
    /// The row this page starts at, decoded from `pageToken`. Past the end is
    /// an empty page rather than an error — the same answer as reading one row
    /// past a finished iterator.
    start: usize = 0,

    /// The half-open row range this page covers, of `total`.
    ///
    /// A range rather than a slice because the rows are no longer rendered
    /// until this is known — which is the point of rendering per request.
    pub fn range(p: Page, total: usize) struct { first: usize, next: usize } {
        const first = @min(p.start, total);
        if (p.max_results < 0) return .{ .first = first, .next = total };
        const take: usize = @intCast(p.max_results);
        return .{ .first = first, .next = @min(total, first +| take) };
    }
};

/// The token a client sends back to get the rest.
///
/// Real BigQuery's tokens are opaque; a row offset is the whole of what this
/// server needs to resume, because the ResultSet it is paging over is retained
/// whole by the job store.
pub fn parsePageToken(token: ?[]const u8) usize {
    const t = token orelse return 0;
    return std.fmt.parseInt(usize, t, 10) catch 0;
}

/// Serializes a getQueryResults / jobs.query envelope from a ResultSet.
pub fn writeResultSet(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_id: []const u8,
    job_id: []const u8,
    set: ResultSet,
    page: Page,
    use_int64_timestamp: bool,
) !void {
    // Rendered here rather than at insert, and only for the rows this page
    // carries: the format options belong to *this* request, and the job that
    // ran the query could not know them.
    const render = try set.renderer(arena, use_int64_timestamp);
    const window = page.range(set.total_rows);
    const first = window.first;
    const next = window.next;

    const rows = try arena.alloc(tablerow.TableRow, next - first);
    for (first..next) |row| rows[row - first] = .{ .cells = try render.row(row) };

    const body = try std.json.Stringify.valueAlloc(arena, response.Envelope{
        .jobReference = .{ .project_id = project_id, .job_id = job_id },
        .schema = try schema_mod.pbSchema(arena, render.cols),
        .rows = rows,
        // The full count even when this page is short, matching Go.
        .totalRows = try std.fmt.allocPrint(arena, "{d}", .{set.total_rows}),
        .pageToken = if (next < set.total_rows)
            try std.fmt.allocPrint(arena, "{d}", .{next})
        else
            null,
    }, response.envelope_options);
    try out.appendSlice(arena, body);
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
    return runQueryFormatted(arena, db, project_id, job_id, sql, &.{}, false);
}

pub const RunResult = struct {
    /// The jobs.query response: every row, under the caller's format options.
    body: []const u8,
    /// Both renderings of the rows, retained by jobs.insert so getQueryResults
    /// can pick under the formatOptions of the request that reads the job
    /// back — which this request cannot know. Null only when the query failed.
    set: ?ResultSet = null,
    ok: bool,
    /// The HTTP status a failed run should answer with. A query BigQuery
    /// refuses as malformed is 400; one that names a dataset that does not
    /// exist is 404, the same way the metadata API answers.
    status: std.http.Status = .ok,
    total_bytes: usize = 0,
};

pub fn runQueryFormatted(
    arena: std.mem.Allocator,
    db: *driver.Db,
    project_id: []const u8,
    job_id: []const u8,
    sql: []const u8,
    /// The request's `queryParameters`, or empty.
    params: []const driver.Param,
    /// Which rendering `body` uses. Both are built regardless whenever a
    /// top-level TIMESTAMP column exists, so a later reader can choose.
    want_int64_timestamps: bool,
) !RunResult {
    var rows = db.query(sql, params, .{}) catch |err| switch (err) {
        // The engine's message is BigQuery's own, verbatim: no "failed to
        // analyze" prefix, and the API's 404 rather than a query error.
        error.DatasetNotFound => return .{
            .body = try errors.body(arena, .not_found, db.lastError()),
            .ok = false,
            .status = .not_found,
        },
        else => {
            const msg = try wrapEngineError(arena, db.lastError());
            return .{
                .body = try errors.body(arena, .invalid_query, msg),
                .ok = false,
                .status = .bad_request,
            };
        },
    };
    defer rows.deinit();

    const cols = rows.columnTypes();
    // Copied out of the statement, not borrowed from it. A column's name and
    // type tree live in the statement's arena, and `defer rows.deinit()` above
    // releases it before this function returns -- so a `ResultSet` that pointed
    // at them would hand the job store freed memory to clone from, which is a
    // segfault one call later rather than an error here.
    const names = try arena.alloc([]const u8, cols.len);
    const types = try arena.alloc(*spec.Type, cols.len);
    for (cols, names, types) |col, *n, *t| {
        n.* = try arena.dupe(u8, col.name);
        t.* = try spec.cloneType(arena, col.type);
    }

    // Storage form, not the rendering. `nextRaw` hands back what SQLite holds,
    // which is both what the destination table's virtual table serves and what
    // a later render decodes from -- so there is one representation instead of
    // the two this used to build whenever a TIMESTAMP column existed.
    var cells: std.ArrayList(encoder.SqliteRepr) = .empty;
    var total_bytes: usize = 0;
    var total_rows: usize = 0;
    while (rows.nextRaw() catch |err| {
        // A failure partway through iteration still carries a message.
        if (err == error.OutOfMemory) return err;
        return .{
            .body = try errors.body(
                arena,
                .invalid_query,
                try wrapEngineError(arena, db.lastError()),
            ),
            .ok = false,
            .status = .bad_request,
        };
    }) |row| {
        for (row) |v| try cells.append(arena, switch (v) {
            .null => .null,
            .int => |x| .{ .int = x },
            .float => |x| .{ .float = x },
            // Borrowed from SQLite's row buffer, which dies at the next step.
            .blob => |b| .{ .blob = try arena.dupe(u8, b) },
            // The engine's own invariant: no stored value is TEXT.
            .text => return error.CorruptData,
        });
        total_rows += 1;
    }

    const set = ResultSet{
        .names = names,
        .types = types,
        .cells = try cells.toOwnedSlice(arena),
        .total_rows = total_rows,
    };

    // Go accumulates len() of each rendered cell string as
    // totalBytesProcessed/Billed (convertValueToCell), so it has to be counted
    // over the rendering rather than the storage form.
    const counter = try set.renderer(arena, false);
    for (0..total_rows) |row| {
        total_bytes += response.renderedByteLen(arena, try counter.row(row)) catch 0;
    }

    var out: std.ArrayList(u8) = .empty;
    try writeResultSet(
        arena,
        &out,
        project_id,
        job_id,
        set,
        // jobs.query ignores maxResults entirely, as Go's does -- the whole
        // result, in one response, with no token.
        .{},
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

    const req = try parseRequest(arena,
        \\{"query":"SELECT 1","useLegacySql":false,"maxResults":10}
    , "");
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
        try testing.expectEqual(@as(?i64, 25), (try parseRequest(arena, body, "")).max_results);
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
        try testing.expectEqual(true, (try parseRequest(arena, body, "")).dry_run);
    }
}

test "a missing query, or a body that is not an object, is rejected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    for ([_][]const u8{ "{}", "[]", "\"x\"" }) |body| {
        try testing.expectError(error.InvalidRequest, parseRequest(arena, body, ""));
    }
}

test "a number where query is declared a string is taken as its text" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Go tolerates this too — flexible_rpc_marshalling.go exists because typed
    // encoding/json would not. The SQL then fails analysis, which is a better
    // message than "query is required".
    const req = try parseRequest(arena, "{\"query\":123}", "");
    try testing.expectEqualStrings("123", req.query);
}

test "queryParameters reach the request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const req = try parseRequest(arena,
        \\{"query":"SELECT @a","queryParameters":[
        \\  {"name":"a","parameterType":{"type":"STRING"},
        \\   "parameterValue":{"value":"x"}}]}
    , "");
    try testing.expectEqual(@as(usize, 1), req.params.len);
    try testing.expectEqualStrings("a", req.params[0].name.?);
    try testing.expectEqualStrings("x", req.params[0].value.string);
}

test "a body with no queryParameters has none" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqual(@as(usize, 0), (try parseRequest(arena,
        \\{"query":"SELECT 1"}
    , "")).params.len);
}

test "runQuery produces the Go emulator's response bytes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var db = try driver.Db.open(testing.allocator, ":memory:");
    defer db.close();

    const res = try runQuery(arena, db, "test", "<JOBID>", "SELECT 1 AS i");
    try testing.expect(res.ok);
    // Compared by value: jobReference and TableFieldSchema put their keys in
    // proto field order, which is not the order Go's structs declared them in.
    try json_pb.expectJsonEqual(
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

    var int_t: spec.Type = .{ .kind = @backingInt(zigquery.pb.TypeKind.TYPE_INT64) };
    var types = [_]*spec.Type{&int_t};
    var names = [_][]const u8{"n"};

    try store.put("test", "job1", .{
        .names = &names,
        .types = &types,
        .cells = &.{.{ .int = 1 }},
        .total_rows = 1,
    }, "{}");
    try testing.expectEqual(@as(i64, 1), store.get("job1").?.set.cells[0].int);
    try testing.expectEqualStrings("test", store.get("job1").?.project_id);
    // The store owns its copy: the caller's values may be a request arena's.
    try testing.expectEqualStrings("n", store.get("job1").?.set.names[0]);
    try testing.expect(store.get("job1").?.set.types[0] != &int_t);

    try store.put("test", "job1", .{
        .names = &names,
        .types = &types,
        .cells = &.{.{ .int = 2 }},
        .total_rows = 1,
    }, "{}");
    try testing.expectEqual(@as(i64, 2), store.get("job1").?.set.cells[0].int);
    try testing.expectEqual(@as(u32, 1), store.map.count());
}

test "the job-rows lookup hands the virtual table what the job holds" {
    var store = JobStore{ .gpa = testing.allocator };
    defer store.deinit();

    var str_t: spec.Type = .{ .kind = @backingInt(zigquery.pb.TypeKind.TYPE_STRING) };
    var types = [_]*spec.Type{&str_t};
    var names = [_][]const u8{"s"};
    try store.put("test", "job2", .{
        .names = &names,
        .types = &types,
        .cells = &.{ .{ .blob = "ab" }, .null },
        .total_rows = 2,
    }, "{}");

    const rows = JobStore.lookupRows(&store, "job2").?;
    try testing.expectEqual(@as(usize, 2), rows.rowCount());
    try testing.expectEqualStrings("s", rows.names[0]);
    try testing.expectEqualStrings("ab", rows.cells[0].blob);
    // A job nobody has heard of is null, which the module reads as empty.
    try testing.expectEqual(
        @as(?job_rows_vtab.RowSet, null),
        JobStore.lookupRows(&store, "nope"),
    );
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

test "a hand-written body is accepted where the mapping is strict" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // maxResults is a UInt32Value, so a quoted decimal is an extension; dryRun
    // is a bool, so "True" and 1 are too; dry_run is the original proto name,
    // which the mapping does require a parser to accept.
    const req = try parseRequest(arena,
        \\{"query":"SELECT 1","maxResults":"10","dryRun":"True","bogusKey":1}
    , "");
    try testing.expectEqual(@as(?i64, 10), req.max_results);
    try testing.expectEqual(true, req.dry_run);

    const snake = try parseRequest(arena,
        \\{"query":"SELECT 1","dry_run":true}
    , "");
    try testing.expectEqual(true, snake.dry_run);

    for ([_][]const u8{ "1", "0" }) |n| {
        const body = try std.fmt.allocPrint(arena, "{{\"query\":\"q\",\"dryRun\":{s}}}", .{n});
        try testing.expectEqual(n[0] == '1', (try parseRequest(arena, body, "")).dry_run);
    }
}

test "useInt64Timestamp is the body's flag OR the query string's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plain =
        \\{"query":"SELECT 1"}
    ;
    const in_body =
        \\{"query":"SELECT 1","formatOptions":{"useInt64Timestamp":true}}
    ;
    try testing.expectEqual(false, (try parseRequest(arena, plain, "")).use_int64_timestamp);
    try testing.expectEqual(true, (try parseRequest(arena, in_body, "")).use_int64_timestamp);
    // The dotted query key nests back into a DataFormatOptions. "True" is in
    // Go's ParseBool set, which the Python client sends.
    try testing.expectEqual(true, (try parseRequest(
        arena,
        plain,
        "formatOptions.useInt64Timestamp=True",
    )).use_int64_timestamp);
    try testing.expectEqual(true, (try parseRequest(
        arena,
        in_body,
        "formatOptions.useInt64Timestamp=false",
    )).use_int64_timestamp);
}

test "a getQueryResults page comes off the query string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const p = parseResultsPage(arena, "maxResults=2&pageToken=4");
    try testing.expectEqual(@as(i64, 2), p.max_results);
    try testing.expectEqual(@as(usize, 4), p.start);

    // Absent, and unreadable, both mean "every row" from the top.
    for ([_][]const u8{ "", "maxResults=abc" }) |q| {
        const d = parseResultsPage(arena, q);
        try testing.expectEqual(max_results_default, d.max_results);
        try testing.expectEqual(@as(usize, 0), d.start);
    }

    // The Python client's completeness probe.
    try testing.expectEqual(@as(i64, 0), parseResultsPage(arena, "maxResults=0").max_results);
}
