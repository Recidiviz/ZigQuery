//! Round-trips a real gRPC call against the transport skeleton.
//!
//! Five checks, four of them controls. Without the controls a green run would prove only that some status came back:
//!
//!   1. A real BigQueryRead method returns UNIMPLEMENTED with the path in the details.
//!   2. A nonsense method returns UNIMPLEMENTED *too* — not UNKNOWN and not a transport error.
//!      This is what proves our handler ran, rather than core rejecting the connection before reaching it.
//!   3. Two sequential calls on one channel both answer, proving the loop
//!      re-arms `grpc_server_request_call` after each accepted call.
//!   4. After `stop()`, the same call fails UNAVAILABLE, proving the listener went away and the loop really exited.
//!   5. A server that never had a loop thread still tears down — `stop` drains on the calling thread
//!      in that case, and an un-drained teardown aborts inside gRPC core rather than returning an error.
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

/// A service that answers with a fixed number of messages.
///
/// The transport's streaming path — the `awaiting_send` phase, the cursor, and
/// the per-message byte buffer that has to outlive its batch and no longer —
/// has nothing to do with rows or Avro, so it is worth exercising without an
/// engine, a table or a query behind it.
const Echo = struct {
    /// How many messages each call answers with.
    count: usize,

    fn dispatch(e: *Echo) grpc_server.Dispatch {
        return .{ .ctx = e, .func = call, .fault = fault };
    }

    fn call(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        method: bqserver.grpc_method.Method,
        request: []const u8,
    ) anyerror!?[]const []const u8 {
        _ = method;
        _ = request;
        const e: *Echo = @ptrCast(@alignCast(ctx));
        const out = try arena.alloc([]const u8, e.count);
        for (out, 0..) |*m, i| {
            m.* = try std.fmt.allocPrint(arena, "message-{d}", .{i});
        }
        return out;
    }

    fn fault(ctx: *anyopaque, err: anyerror) grpc_server.Fault {
        _ = ctx;
        return .{ .status = .internal, .message = @errorName(err) };
    }
};

/// Counts the messages a server-streaming call delivers, and checks the last.
fn countStreamed(gpa: std.mem.Allocator, target: [:0]const u8) !usize {
    var client = try Client.connect(target);
    defer client.deinit();
    return client.streamCount(gpa, read_rows);
}

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

    // 5. The streaming path: N messages then a status, on a server whose only
    //    service is the stub above. A transport that destroyed a byte buffer
    //    before its batch completed, or that stopped after the first message,
    //    fails here rather than somewhere inside a row decoder.
    {
        var echo: Echo = .{ .count = 5 };
        const streamer = try grpc_server.Server.init(gpa, .{
            .address = "127.0.0.1",
            .port = 0,
        });
        defer streamer.deinit();
        streamer.service = echo.dispatch();
        try streamer.start();

        const target2 = try std.fmt.allocPrintSentinel(
            gpa,
            "127.0.0.1:{d}",
            .{streamer.bound_port},
            0,
        );
        defer gpa.free(target2);

        const got = countStreamed(gpa, target2) catch |err| {
            std.debug.print("  (stream error: {t})\n", .{err});
            return err;
        };
        failures += check(
            "a streaming call delivers every message",
            got == 5,
            "got {d} of 5",
            .{got},
        );

        // Zero messages is a legal stream: just the status. It is also what a
        // read of an empty result would be if the service did not insist on
        // sending one, so the transport had better not hang on it.
        echo.count = 0;
        const none = countStreamed(gpa, target2) catch |err| {
            std.debug.print("  (empty stream error: {t})\n", .{err});
            return err;
        };
        failures += check("an empty stream still completes", none == 0, "got {d}", .{none});
    }

    // 6. Control: a server that never had a loop thread must still tear down.
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
        .invalid_argument => "INVALID_ARGUMENT",
        .not_found => "NOT_FOUND",
        .unimplemented => "UNIMPLEMENTED",
        .internal => "INTERNAL",
        .unavailable => "UNAVAILABLE",
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

    /// Drives a server-streaming call to completion and returns how many
    /// messages arrived.
    ///
    /// Written out longhand rather than reusing `tryCall` because the shape is
    /// genuinely different: the status is not fused with the first message, so
    /// the client posts RECV_MESSAGE repeatedly until one completes empty, and
    /// only then reads the status.
    fn streamCount(cl: *Client, gpa: std.mem.Allocator, path: []const u8) !usize {
        _ = gpa;
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
        c.c.grpc_metadata_array_init(&recv_initial);
        defer c.c.grpc_metadata_array_destroy(&recv_initial);

        var tag: u8 = 0;
        var ops: [3]c.c.grpc_op = std.mem.zeroes([3]c.c.grpc_op);
        ops[0].op = @intFromEnum(c.OpType.send_initial_metadata);
        ops[1].op = @intFromEnum(c.OpType.send_close_from_client);
        ops[2].op = @intFromEnum(c.OpType.recv_initial_metadata);
        ops[2].data.recv_initial_metadata = .{ .recv_initial_metadata = &recv_initial };
        if (!c.callOk(c.c.grpc_call_start_batch(rpc, &ops, 3, &tag, null))) {
            return error.GrpcStartBatch;
        }
        if (c.completion(c.c.grpc_completion_queue_next(cl.cq, deadline, null)) != .op_complete) {
            return error.GrpcNoCompletion;
        }

        // Each RECV_MESSAGE completes with a null payload once the server has
        // sent the status, which is how a stream ends.
        var count: usize = 0;
        while (true) {
            var payload: ?*c.c.grpc_byte_buffer = null;
            var recv: [1]c.c.grpc_op = std.mem.zeroes([1]c.c.grpc_op);
            recv[0].op = @intFromEnum(c.OpType.recv_message);
            recv[0].data.recv_message = .{ .recv_message = &payload };
            if (!c.callOk(c.c.grpc_call_start_batch(rpc, &recv, 1, &tag, null))) {
                return error.GrpcStartBatch;
            }
            const ev = c.c.grpc_completion_queue_next(cl.cq, deadline, null);
            if (c.completion(ev) != .op_complete) return error.GrpcNoCompletion;
            const bb = payload orelse break;
            c.c.grpc_byte_buffer_destroy(bb);
            count += 1;
        }

        var status: c.c.grpc_status_code = 0;
        var details: c.c.grpc_slice = std.mem.zeroes(c.c.grpc_slice);
        defer c.c.grpc_slice_unref(details);
        var recv_trailing: c.c.grpc_metadata_array = undefined;
        c.c.grpc_metadata_array_init(&recv_trailing);
        defer c.c.grpc_metadata_array_destroy(&recv_trailing);
        var error_string: [*c]const u8 = null;

        var last: [1]c.c.grpc_op = std.mem.zeroes([1]c.c.grpc_op);
        last[0].op = @intFromEnum(c.OpType.recv_status_on_client);
        last[0].data.recv_status_on_client = .{
            .trailing_metadata = &recv_trailing,
            .status = &status,
            .status_details = &details,
            .error_string = &error_string,
        };
        if (!c.callOk(c.c.grpc_call_start_batch(rpc, &last, 1, &tag, null))) {
            return error.GrpcStartBatch;
        }
        if (c.completion(c.c.grpc_completion_queue_next(cl.cq, deadline, null)) != .op_complete) {
            return error.GrpcNoCompletion;
        }
        if (@as(c.Status, @enumFromInt(status)) != .ok) return error.StreamNotOk;
        return count;
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
