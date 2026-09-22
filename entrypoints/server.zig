const std = @import("std");
const builtin = @import("builtin");
const bqserver = @import("bqserver");
const http_server = bqserver.http_server;
const grpc_server = bqserver.grpc_server;
const grpc_read_service = bqserver.grpc_read_service;

const default_host = "0.0.0.0";
const default_port: u16 = 9050;
const default_grpc_port: u16 = 9060;

const usage =
    \\Usage:
    \\  zigquery-server --project=<name> [OPTIONS]
    \\
    \\A local BigQuery emulator serving the REST API and the Storage Read API.
    \\Flags take the form --name=value.
    \\
    \\Options:
    \\  --project=<name>        project ID to serve (required)
    \\  --dataset=<name>        create an empty dataset with this ID at startup
    \\  --host=<addr>           address both servers bind (default: 0.0.0.0)
    \\  --port=<port>           REST API port (default: 9050)
    \\  --grpc-port=<port>      Storage Read API gRPC port; 0 picks a free port
    \\                          (default: 9060)
    \\  --database=<path>       SQLite file to store data in; :memory: or empty
    \\                          keeps data in memory (default: :memory:)
    \\  --data-from-json=<path> load datasets and tables from a JSON file at
    \\                          startup; repeatable, files load in order
    \\  --log-level=<level>     accepted for compatibility; currently ignored
    \\  --log-format=<format>   accepted for compatibility; currently ignored
    \\  -h, --help              show this help and exit
;

const Options = struct {
    project: ?[]const u8 = null,
    dataset: ?[]const u8 = null,
    host: []const u8 = default_host,
    port: u16 = default_port,
    grpc_port: u16 = default_grpc_port,
    log_level: []const u8 = "error",
    database: ?[]const u8 = null,
    log_format: []const u8 = "console",
};

pub fn main(init: std.process.Init) !void {
    // DebugAllocator's bookkeeping is not free, and the server leans on the
    // allocator hard — a request arena refills from it on every request.
    // Release builds use c_allocator, which is what the Zig docs point to
    // when the program links libc, as this one does for SQLite and the
    // analyzer shim. Debug builds keep the checked allocator, where leak
    // detection is the point.
    var debug_state: std.heap.DebugAllocator(.{}) = .init;
    defer if (builtin.mode == .debug) {
        _ = debug_state.deinit();
    };
    const gpa = if (builtin.mode == .debug)
        debug_state.allocator()
    else
        std.heap.c_allocator;

    var stderr_buf: [4096]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writerStreaming(init.io, &stderr_buf);
    const err_out = &stderr_writer.interface;

    var opts = Options{};
    var json_paths: std.ArrayList([]const u8) = .empty;
    defer json_paths.deinit(gpa);
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program name
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var stdout_buf: [2048]u8 = undefined;
            var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
            try stdout_writer.interface.writeAll(usage);
            try stdout_writer.interface.flush();
            return;
        } else if (flagValue(arg, "--project")) |v| {
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
        } else if (flagValue(arg, "--data-from-json")) |v| {
            // Repeatable, unlike the other flags: each file loads in turn.
            try json_paths.append(gpa, v);
        } else if (flagValue(arg, "--log-format")) |v| {
            opts.log_format = v;
        } else {
            try err_out.print("unknown flag: {s}\n\n" ++ usage, .{arg});
            try err_out.flush();
            std.process.exit(1);
        }
    }

    if (opts.project == null) {
        try err_out.print("the required flag `--project' was not specified\n\n" ++ usage, .{});
        try err_out.flush();
        std.process.exit(1);
    }

    var threaded: std.Io.Threaded = .init(gpa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var app = try bqserver.Server.init(gpa, io, .{
        .project = opts.project.?,
        .database = opts.database,
        .host = opts.host,
        .port = opts.port,
        .data_from_json = json_paths.items,
        .dataset = opts.dataset,
    });
    defer app.deinit();

    var server = try http_server.Server.listen(gpa, io, .{
        .address = opts.host,
        .port = opts.port,
    }, app.handler());
    defer server.deinit();

    // The Storage API transport. Binds here and runs its completion queue on
    // its own thread; see grpc/server.zig.
    // Both binds happen before either readiness line below.
    const grpc = grpc_server.Server.init(gpa, .{
        .address = opts.host,
        .port = opts.grpc_port,
    }) catch |err| {
        try err_out.print(
            "gRPC server failed to bind {s}:{d}: {t}\n",
            .{ opts.host, opts.grpc_port, err },
        );
        try err_out.flush();
        std.process.exit(1);
    };
    defer grpc.deinit();

    // The service is registered before `start`, so no call can arrive while
    // `grpc.service` is still null and get a spurious UNIMPLEMENTED.
    var read_service = grpc_read_service.Service.init(app);
    defer read_service.deinit();
    grpc.service = read_service.dispatch();

    try grpc.start();

    // The node and python test fixtures both gate readiness on these exact
    // lines (LogMessageWaitStrategy / Wait.forLogMessage)
    var stdout_buf: [512]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;
    try out.print(
        "[bigquery-emulator] REST server listening at {s}:{d}\n",
        .{ opts.host, opts.port },
    );
    // grpc.bound_port rather than opts.grpc_port: may be a kernel-chosen port when 0 is passed as opts.grpc_port
    try out.print(
        "[bigquery-emulator] gRPC server listening at {s}:{d}\n",
        .{ opts.host, grpc.bound_port },
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

test "flagValue accepts --name=value and rejects bare or foreign flags" {
    try std.testing.expectEqualStrings("test", flagValue("--project=test", "--project").?);
    try std.testing.expectEqualStrings("", flagValue("--project=", "--project").?);
    try std.testing.expectEqual(@as(?[]const u8, null), flagValue("--project", "--project"));
    try std.testing.expectEqual(@as(?[]const u8, null), flagValue("--other=1", "--project"));
}
