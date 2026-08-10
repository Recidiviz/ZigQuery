//! Round-trips a real gRPC call against the transport skeleton.
//!
//! Four checks, three of them controls. Without the controls a green run would prove only that some status came back:
//!
//!   1. A real BigQueryRead method returns UNIMPLEMENTED with the path in the details.
//!   2. A nonsense method returns UNIMPLEMENTED *too* — not UNKNOWN and not a transport error.
//!      This is what proves our handler ran, rather than core rejecting the connection before reaching it.
//!   3. Two sequential calls on one channel both answer, proving the loop
//!      re-arms `grpc_server_request_call` after each accepted call.
//!   4. After `stop()`, the same call fails UNAVAILABLE, proving the listener went away and the loop really exited.
//!
//! Exit status: nonzero if any check fails. Deadlines are finite, so a hang is a failure not a stalled process
//!
//! Usage: zig build grpc-smoke

const std = @import("std");
const bqserver = @import("bqserver");
const c = bqserver.grpc_c;
const grpc_server = bqserver.grpc_server;

const read_rows = "/google.cloud.bigquery.storage.v1.BigQueryRead/ReadRows";
const nonsense = "/nope.NoSuchService/NoSuchMethod";

/// Seconds. Long enough that a loaded machine does not flake, short enough that
/// a genuine hang is reported rather than waited out.
const call_timeout_s = 10;

pub fn main() !void {
    var debug_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = debug_state.deinit();
    const gpa = debug_state.allocator();

    var failures: usize = 0;

    const server = try grpc_server.Server.init(gpa, .{
        .address = "127.0.0.1",
        .port = 0,
    });
    defer server.deinit();
    try server.start();

    const target = try std.fmt.allocPrintSentinel(
        gpa,
        "127.0.0.1:{d}",
        .{server.bound_port},
        0,
    );
    defer gpa.free(target);
    std.debug.print("listening on {s}\n", .{target});

    {
        var client = try Client.connect(target);
        defer client.deinit();

        // 1. The real method.
        const first = client.call(gpa, read_rows);
        defer first.deinit(gpa);
        failures += check(
            "ReadRows answers UNIMPLEMENTED",
            first.status == .unimplemented,
            "got {s}",
            .{statusName(first.status)},
        );
        failures += check(
            "the status details name the method",
            std.mem.indexOf(u8, first.details, read_rows) != null,
            "details were \"{s}\"",
            .{first.details},
        );

        // 2. Control: an unknown service must reach our handler too. A
        //    transport-level rejection would show up as UNKNOWN or
        //    UNAVAILABLE here.
        const bogus = client.call(gpa, nonsense);
        defer bogus.deinit(gpa);
        failures += check(
            "an unknown service also answers UNIMPLEMENTED",
            bogus.status == .unimplemented,
            "got {s}",
            .{statusName(bogus.status)},
        );

        // 3. Control: the loop re-armed, so a second call on the same channel
        //    is answered rather than hanging until the deadline.
        const second = client.call(gpa, read_rows);
        defer second.deinit(gpa);
        failures += check(
            "a second call on the same channel is answered",
            second.status == .unimplemented,
            "got {s}",
            .{statusName(second.status)},
        );
    }

    // 4. Control: stopping really stops. Done on a fresh channel so this
    //    cannot pass on a cached connection.
    server.stop();
    {
        var client = try Client.connect(target);
        defer client.deinit();
        const after = client.call(gpa, read_rows);
        defer after.deinit(gpa);
        failures += check(
            "the listener is gone after stop()",
            after.status == .unavailable,
            "got {s}",
            .{statusName(after.status)},
        );
    }

    // 5. Control: a server that never had a loop thread must still tear down.
    //    `stop` drains on the calling thread in that case, and nothing else
    //    reaches that path — an un-drained teardown aborts inside gRPC core
    //    rather than returning an error, so simply getting past this line is
    //    the assertion.
    {
        const never_started = try grpc_server.Server.init(gpa, .{
            .address = "127.0.0.1",
            .port = 0,
        });
        never_started.deinit();
        failures += check("a never-started server tears down", true, "", .{});
    }

    if (failures != 0) {
        std.debug.print("\n{d} check(s) failed\n", .{failures});
        std.process.exit(1);
    }
    std.debug.print("\nall checks passed\n", .{});
}

/// `@tagName` panics on a non-exhaustive enum holding an unnamed value, which
/// is exactly the case a failure report needs to print.
fn statusName(s: c.Status) []const u8 {
    return switch (s) {
        .ok => "OK",
        .unavailable => "UNAVAILABLE",
        .unimplemented => "UNIMPLEMENTED",
        _ => "<other>",
    };
}

fn check(
    name: []const u8,
    ok: bool,
    comptime detail_fmt: []const u8,
    detail_args: anytype,
) usize {
    if (ok) {
        std.debug.print("  ok    {s}\n", .{name});
        return 0;
    }
    std.debug.print("  FAIL  {s}: " ++ detail_fmt ++ "\n", .{name} ++ detail_args);
    return 1;
}

const Outcome = struct {
    status: c.Status,
    /// Owned; empty when the server sent no details.
    details: []const u8,

    fn deinit(o: Outcome, gpa: std.mem.Allocator) void {
        gpa.free(o.details);
    }
};

/// A gRPC client over the raw core API. Enough to send an empty unary request
/// and read the status back — which is all an UNIMPLEMENTED server can answer.
const Client = struct {
    channel: *c.c.grpc_channel,
    cq: *c.c.grpc_completion_queue,

    fn connect(target: [:0]const u8) !Client {
        const creds = c.c.grpc_insecure_credentials_create() orelse
            return error.GrpcCredentials;
        defer c.c.grpc_channel_credentials_release(creds);

        const channel = c.c.grpc_channel_create(target.ptr, creds, null) orelse
            return error.GrpcChannel;
        errdefer c.c.grpc_channel_destroy(channel);

        const cq = c.c.grpc_completion_queue_create_for_next(null) orelse
            return error.GrpcQueueCreate;
        return .{ .channel = channel, .cq = cq };
    }

    fn deinit(cl: *Client) void {
        c.c.grpc_channel_destroy(cl.channel);
        c.c.grpc_completion_queue_shutdown(cl.cq);
        // Drain before destroying, the same rule the server side obeys.
        while (c.completion(c.c.grpc_completion_queue_next(
            cl.cq,
            c.infFuture(),
            null,
        )) != .shutdown) {}
        c.c.grpc_completion_queue_destroy(cl.cq);
    }

    fn call(cl: *Client, gpa: std.mem.Allocator, path: []const u8) Outcome {
        return cl.tryCall(gpa, path) catch |err| {
            std.debug.print("  (client error on {s}: {t})\n", .{ path, err });
            return .{ .status = @enumFromInt(0xffff), .details = gpa.dupe(u8, "") catch "" };
        };
    }

    fn tryCall(cl: *Client, gpa: std.mem.Allocator, path: []const u8) !Outcome {
        const deadline = c.c.gpr_time_add(
            c.c.gpr_now(c.c.GPR_CLOCK_MONOTONIC),
            c.c.gpr_time_from_seconds(call_timeout_s, c.c.GPR_TIMESPAN),
        );
        const method = c.c.grpc_slice_from_copied_buffer(path.ptr, path.len);
        defer c.c.grpc_slice_unref(method);

        const rpc = c.c.grpc_channel_create_call(
            cl.channel,
            null,
            c.c.GRPC_PROPAGATE_DEFAULTS,
            cl.cq,
            method,
            null,
            deadline,
            null,
        ) orelse return error.GrpcCreateCall;
        defer c.c.grpc_call_unref(rpc);

        var recv_initial: c.c.grpc_metadata_array = undefined;
        var recv_trailing: c.c.grpc_metadata_array = undefined;
        c.c.grpc_metadata_array_init(&recv_initial);
        c.c.grpc_metadata_array_init(&recv_trailing);
        defer c.c.grpc_metadata_array_destroy(&recv_initial);
        defer c.c.grpc_metadata_array_destroy(&recv_trailing);

        var status: c.c.grpc_status_code = 0;
        var details: c.c.grpc_slice = std.mem.zeroes(c.c.grpc_slice);
        defer c.c.grpc_slice_unref(details);
        var error_string: [*c]const u8 = null;

        // No SEND_MESSAGE: the server never reads one, and an UNIMPLEMENTED
        // answer does not depend on the request body.
        var ops: [4]c.c.grpc_op = std.mem.zeroes([4]c.c.grpc_op);
        ops[0].op = @intFromEnum(c.OpType.send_initial_metadata);
        ops[1].op = @intFromEnum(c.OpType.send_close_from_client);
        ops[2].op = @intFromEnum(c.OpType.recv_initial_metadata);
        ops[2].data.recv_initial_metadata = .{ .recv_initial_metadata = &recv_initial };
        ops[3].op = @intFromEnum(c.OpType.recv_status_on_client);
        ops[3].data.recv_status_on_client = .{
            .trailing_metadata = &recv_trailing,
            .status = &status,
            .status_details = &details,
            .error_string = &error_string,
        };

        var tag: u8 = 0;
        const err = c.c.grpc_call_start_batch(rpc, &ops, ops.len, &tag, null);
        if (!c.callOk(err)) return error.GrpcStartBatch;

        // Finite: a server that never answers must fail this harness, not
        // stall it. The call's own deadline bounds the RPC; this bounds the
        // wait on the queue.
        const ev = c.c.grpc_completion_queue_next(cl.cq, deadline, null);
        if (c.completion(ev) != .op_complete) {
            // Abandoning a pending batch here would corrupt every later call:
            // the ops write into locals of this frame, and the next call's
            // frame reuses the same stack addresses, so its `tag` compares
            // equal and it reads a dead status. Cancel and drain first.
            _ = c.c.grpc_call_cancel(rpc, null);
            while (true) {
                const drained = c.c.grpc_completion_queue_next(cl.cq, c.infFuture(), null);
                if (c.completion(drained) == .shutdown) break;
                if (drained.tag == @as(*anyopaque, @ptrCast(&tag))) break;
            }
            return error.GrpcNoCompletion;
        }

        return .{
            .status = @enumFromInt(status),
            .details = try gpa.dupe(u8, c.sliceBytes(&details)),
        };
    }
};
