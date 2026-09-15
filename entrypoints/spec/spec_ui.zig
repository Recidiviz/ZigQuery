//! Browsable UI for the .zon spec corpus: runs the (optionally filtered) corpus with all details
//! captured, then serves it as a filterable table with a per-case drill-down.
//!
//! Usage: zig build spec-ui -- [--filter SUBSTR] [--dialect googlesql|bigquery] [--port N]

const std = @import("std");
const builtin = @import("builtin");
const zigquery = @import("zigquery");
const http_server = @import("http_server");

const spec_run = zigquery.spec_run;

const default_port: u16 = 8091;
const spec_ui_html = @embedFile("spec_ui.html");

const Options = struct {
    filter: ?[]const u8 = null,
    dialect: ?spec_run.Dialect = null,
    port: u16 = default_port,
};

const State = struct {
    mutex: std.Io.Mutex = .init,
    records: []const spec_run.Record,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    const opts = try parseArgs(init.minimal.args, out);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (builtin.mode == .debug) gpa_state.allocator() else std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Process-lifetime: server.serve() never returns, and every captured
    // Record must outlive the request that eventually reads it. No
    // `arena_state.deinit()` — matches entrypoints/server.zig's own `app`/
    // `server` lifetime, which also only ever ends via process exit.
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    const arena = arena_state.allocator();

    const manifest = try spec_run.loadManifest(arena, io, out);

    try out.print("running spec corpus{s}{s}...\n", .{
        if (opts.filter != null) " --filter " else "",
        opts.filter orelse "",
    });
    try out.flush();

    var records: std.ArrayList(spec_run.Record) = .empty;
    try spec_run.run(gpa, arena, io, manifest, .{
        .dialect = opts.dialect,
        .filter = opts.filter,
        .capture_detail = true,
    }, &records);

    var state = State{ .records = records.items };

    var server = try http_server.Server.listen(gpa, io, .{
        .address = "127.0.0.1",
        .port = opts.port,
    }, .{ .ctx = &state, .func = dispatch, .mutex = &state.mutex, .io = io });
    defer server.deinit();

    try out.print(
        "{d} cases loaded. spec-ui listening at http://127.0.0.1:{d}/\n",
        .{ records.items.len, opts.port },
    );
    try out.flush();

    try server.serve();
}

fn parseArgs(argv: anytype, out: *std.Io.Writer) !Options {
    var opts: Options = .{};
    var it = std.process.Args.Iterator.init(argv);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--filter")) {
            opts.filter = it.next();
        } else if (std.mem.eql(u8, arg, "--dialect")) {
            const d = it.next() orelse "";
            opts.dialect = std.meta.stringToEnum(spec_run.Dialect, d) orelse {
                try out.print("error: unknown dialect {s}\n", .{d});
                try out.flush();
                std.process.exit(2);
            };
        } else if (std.mem.eql(u8, arg, "--port")) {
            const p = it.next() orelse "";
            opts.port = std.fmt.parseInt(u16, p, 10) catch {
                try out.print("error: invalid port {s}\n", .{p});
                try out.flush();
                std.process.exit(2);
            };
        } else {
            try out.print(
                "usage: zig build spec-ui -- [--filter SUBSTR] [--dialect D] [--port N]\n",
                .{},
            );
            try out.flush();
            std.process.exit(2);
        }
    }
    return opts;
}

fn dispatch(ctx: *anyopaque, req: *const http_server.Request) anyerror!http_server.Response {
    const state: *State = @ptrCast(@alignCast(ctx));

    if (req.method == .GET and std.mem.eql(u8, req.path, "/")) {
        return .{ .body = spec_ui_html, .content_type = "text/html; charset=UTF-8" };
    }
    if (req.method == .GET and std.mem.eql(u8, req.path, "/api/results")) {
        return .{ .body = try renderResultsJson(req.arena, state.records) };
    }
    if (req.method == .GET and std.mem.startsWith(u8, req.path, "/api/case/")) {
        const idx_str = req.path["/api/case/".len..];
        const idx = std.fmt.parseInt(usize, idx_str, 10) catch {
            return .{ .status = .bad_request, .body = "{\"error\":\"invalid index\"}" };
        };
        if (idx >= state.records.len) {
            return .{ .status = .not_found, .body = "{\"error\":\"index out of range\"}" };
        }
        return .{ .body = try renderCaseJson(req.arena, idx, state.records[idx]) };
    }
    return .{ .status = .not_found, .body = "{\"error\":\"not found\"}" };
}

/// One row of `/api/results`. Field names are the JSON keys `spec_ui.html` reads.
const Summary = struct {
    index: usize,
    spec: []const u8,
    desc: []const u8,
    outcome: spec_run.Bucket,
    detail: []const u8,
    unsupported_in_bigquery: ?[]const u8,
    stale: bool,
};

/// `/api/case/N`: the `Summary` row plus everything captured for the drill-down.
const Case = struct {
    index: usize,
    spec: []const u8,
    desc: []const u8,
    outcome: spec_run.Bucket,
    detail: []const u8,
    unsupported_in_bigquery: ?[]const u8,
    stale: bool,
    input_sql: []const u8,
    setup_sql: []const []const u8,
    ast_text: []const u8,
    transformed_sql: []const u8,
    expected_text: []const u8,
    received_text: []const u8,
};

fn renderResultsJson(arena: std.mem.Allocator, records: []const spec_run.Record) ![]const u8 {
    const rows = try arena.alloc(Summary, records.len);
    for (records, rows, 0..) |r, *row, i| {
        row.* = .{
            .index = i,
            .spec = r.spec,
            .desc = r.desc,
            .outcome = spec_run.bucket(r),
            .detail = r.detail,
            .unsupported_in_bigquery = r.unsupported_in_bigquery,
            .stale = r.unsupported_stale,
        };
    }
    return std.json.Stringify.valueAlloc(arena, rows, .{});
}

fn renderCaseJson(arena: std.mem.Allocator, index: usize, r: spec_run.Record) ![]const u8 {
    return std.json.Stringify.valueAlloc(arena, Case{
        .index = index,
        .spec = r.spec,
        .desc = r.desc,
        .outcome = spec_run.bucket(r),
        .detail = r.detail,
        .unsupported_in_bigquery = r.unsupported_in_bigquery,
        .stale = r.unsupported_stale,
        .input_sql = r.full.input_sql,
        .setup_sql = r.full.setup_sql,
        .ast_text = r.full.ast_text,
        .transformed_sql = r.full.transformed_sql,
        .expected_text = r.full.expected_text,
        .received_text = r.full.received_text,
    }, .{});
}
