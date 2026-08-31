//! Browsable UI for the spec corpus: runs the (optionally filtered) corpus
//! once with full detail capture, then serves it as a filterable table with
//! a per-case drill-down — input SQL, analyzed AST, transformed SQL, and
//! expected vs. received values. See `src/internal/spec_run.zig`'s module
//! doc comment for why the actual run/classify logic lives there and not
//! here, and `src/driver.zig`'s `QueryOptions.capture` for why capturing
//! that detail costs nothing beyond what a normal query already computes.
//!
//! A read-only viewer over a run that already finished — there is no live
//! `Db`/query execution behind any endpoint, so no request-serialization
//! concern applies beyond the transport's own housekeeping.
//!
//! Usage: zig build spec-ui -- [--filter SUBSTR] [--dialect googlesql|bigquery] [--port N]

const std = @import("std");
const builtin = @import("builtin");
const zetasqlite = @import("zetasqlite");
const bqserver = @import("bqserver");

const spec_run = zetasqlite.spec_run;
const http_server = bqserver.http_server;
const errors = bqserver.errors;

const default_port: u16 = 8091;
const spec_ui_html = @embedFile("spec_ui.html");

const Options = struct {
    filter: ?[]const u8 = null,
    dialect: ?spec_run.Dialect = null,
    port: u16 = default_port,
};

const State = struct {
    records: []const spec_run.Record,
};

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    const opts = try parseArgs(init.minimal.args, out);

    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .Debug) {
        _ = gpa_state.deinit();
    };
    const gpa = if (builtin.mode == .Debug) gpa_state.allocator() else std.heap.smp_allocator;

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // Process-lifetime: server.serve() never returns, and every captured
    // Record must outlive the request that eventually reads it. No
    // `arena_state.deinit()` — matches src/server/main.zig's own `app`/
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
    }, .{ .ctx = &state, .func = dispatch });
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

fn renderResultsJson(arena: std.mem.Allocator, records: []const spec_run.Record) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.append(arena, '[');
    for (records, 0..) |r, i| {
        if (i > 0) try out.append(arena, ',');
        try out.print(arena, "{{\"index\":{d},\"spec\":", .{i});
        try errors.writeJsonString(arena, &out, r.spec);
        try out.appendSlice(arena, ",\"desc\":");
        try errors.writeJsonString(arena, &out, r.desc);
        try out.appendSlice(arena, ",\"outcome\":");
        try errors.writeJsonString(arena, &out, @tagName(spec_run.bucket(r)));
        try out.appendSlice(arena, ",\"detail\":");
        try errors.writeJsonString(arena, &out, r.detail);
        try out.appendSlice(arena, ",\"unsupported_in_bigquery\":");
        if (r.unsupported_in_bigquery) |reason| {
            try errors.writeJsonString(arena, &out, reason);
        } else {
            try out.appendSlice(arena, "null");
        }
        try out.print(arena, ",\"stale\":{s}", .{if (r.unsupported_stale) "true" else "false"});
        try out.append(arena, '}');
    }
    try out.append(arena, ']');
    return out.toOwnedSlice(arena);
}

fn renderCaseJson(arena: std.mem.Allocator, index: usize, r: spec_run.Record) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.print(arena, "{{\"index\":{d},\"spec\":", .{index});
    try errors.writeJsonString(arena, &out, r.spec);
    try out.appendSlice(arena, ",\"desc\":");
    try errors.writeJsonString(arena, &out, r.desc);
    try out.appendSlice(arena, ",\"outcome\":");
    try errors.writeJsonString(arena, &out, @tagName(spec_run.bucket(r)));
    try out.appendSlice(arena, ",\"detail\":");
    try errors.writeJsonString(arena, &out, r.detail);
    try out.appendSlice(arena, ",\"unsupported_in_bigquery\":");
    if (r.unsupported_in_bigquery) |reason| {
        try errors.writeJsonString(arena, &out, reason);
    } else {
        try out.appendSlice(arena, "null");
    }
    try out.print(arena, ",\"stale\":{s}", .{if (r.unsupported_stale) "true" else "false"});
    try out.appendSlice(arena, ",\"input_sql\":");
    try errors.writeJsonString(arena, &out, r.full.input_sql);
    try out.appendSlice(arena, ",\"setup_sql\":[");
    for (r.full.setup_sql, 0..) |s, i| {
        if (i > 0) try out.append(arena, ',');
        try errors.writeJsonString(arena, &out, s);
    }
    try out.appendSlice(arena, "],\"ast_text\":");
    try errors.writeJsonString(arena, &out, r.full.ast_text);
    try out.appendSlice(arena, ",\"transformed_sql\":");
    try errors.writeJsonString(arena, &out, r.full.transformed_sql);
    try out.appendSlice(arena, ",\"expected_text\":");
    try errors.writeJsonString(arena, &out, r.full.expected_text);
    try out.appendSlice(arena, ",\"received_text\":");
    try errors.writeJsonString(arena, &out, r.full.received_text);
    try out.append(arena, '}');
    return out.toOwnedSlice(arena);
}
