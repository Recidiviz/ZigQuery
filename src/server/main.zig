//! Port of bigquery-emulator cmd/bigquery-emulator/main.go.
//!
//! Differences from Go, by design:
//! - Flags are parsed by hand rather than via jessevdk/go-flags. Same names,
//!   same defaults, same required-ness.

const std = @import("std");
const bqserver = @import("bqserver");
const http_server = bqserver.http_server;

const default_host = "0.0.0.0";
const default_port: u16 = 9050;
const default_grpc_port: u16 = 9060;

const Options = struct {
    project: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    host: []const u8 = default_host,
    port: u16 = default_port,
    grpc_port: u16 = default_grpc_port,
    log_level: []const u8 = "error",
    database: ?[]const u8 = null,
};

pub fn main(init: std.process.Init) !void {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const gpa = gpa_state.allocator();

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const err_out = &stderr_writer.interface;

    var opts = Options{};
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (flagValue(arg, "--project")) |v| {
            opts.project = v;
        } else if (flagValue(arg, "--dataset")) |v| {
            opts.dataset = v;
        } else if (flagValue(arg, "--host")) |v| {
            opts.host = v;
        } else if (flagValue(arg, "--port")) |v| {
            opts.port = try std.fmt.parseInt(u16, v, 10);
        } else if (flagValue(arg, "--grpc-port")) |v| {
            opts.grpc_port = try std.fmt.parseInt(u16, v, 10);
        } else if (flagValue(arg, "--log-level")) |v| {
            opts.log_level = v;
        } else if (flagValue(arg, "--database")) |v| {
            opts.database = v;
        } else {
            try err_out.print("unknown flag: {s}\n", .{arg});
            try err_out.flush();
            std.process.exit(1);
        }
    }

    if (opts.project == null) {
        try err_out.print("the required flag `--project' was not specified\n", .{});
        try err_out.flush();
        std.process.exit(1);
    }

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var handler = SpikeHandler{};
    var server = try http_server.Server.listen(gpa, io, .{
        .address = opts.host,
        .port = opts.port,
    }, .{ .ctx = &handler, .func = SpikeHandler.handle });
    defer server.deinit();

    // The node and python test fixtures both gate readiness on this exact
    // line (LogMessageWaitStrategy / Wait.forLogMessage), so it must match
    // Go's cmd/bigquery-emulator/main.go byte for byte.
    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;
    try out.print(
        "[bigquery-emulator] REST server listening at {s}:{d}\n",
        .{ opts.host, opts.port },
    );
    try out.print(
        "[bigquery-emulator] gRPC server listening at {s}:{d}\n",
        .{ opts.host, opts.grpc_port },
    );
    try out.flush();

    try server.serve();
}

/// `--name=value` -> value; `--name` alone -> null.
fn flagValue(arg: []const u8, name: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, arg, name)) return null;
    const rest = arg[name.len..];
    if (rest.len == 0) return null;
    if (rest[0] != '=') return null;
    return rest[1..];
}

/// Placeholder until the router lands: answers every request with `{}` so the
/// transport can be exercised end to end.
const SpikeHandler = struct {
    fn handle(ctx: *anyopaque, req: *const http_server.Request) anyerror!http_server.Response {
        _ = ctx;
        return .{
            .body = try std.fmt.allocPrint(
                req.arena,
                "{{\"path\":\"{s}\",\"bodyLen\":{d}}}",
                .{ req.path, req.body.len },
            ),
        };
    }
};

test "flagValue accepts --name=value and rejects bare or foreign flags" {
    try std.testing.expectEqualStrings("test", flagValue("--project=test", "--project").?);
    try std.testing.expectEqualStrings("", flagValue("--project=", "--project").?);
    try std.testing.expectEqual(@as(?[]const u8, null), flagValue("--project", "--project"));
    try std.testing.expectEqual(@as(?[]const u8, null), flagValue("--other=1", "--project"));
}
