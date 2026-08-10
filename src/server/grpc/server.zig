//! gRPC transport for the BigQuery Storage Read API.
//!
//! **Why the transport comes from C.** `http/server.zig:16-17` records the
//! constraint: Zig 0.16 std has no HTTP/2, no HPACK and no TLS server. gRPC is
//! HTTP/2 plus a framing over it, so the transport is gRPC's own core, driven
//! through its completion-queue API. There is no grpc++, no protoc and no
//! generated stub in this build — `grpc_server_request_call` hands back the
//! method path as a slice, so a service is a switch over a string.
//!
//! **Deliberately not on std.Io.** `grpc_completion_queue_next` blocks the OS
//! thread it is called on. It therefore gets a plain `std.Thread`, the same
//! choice `http/server.zig:161` makes for connections, rather than parking a
//! `std.Io.Threaded` worker that no scheduler can account for.
//!
//! **Scope at S1: every method answers UNIMPLEMENTED.** No sessions, no
//! protobuf, no engine access. Nothing here imports `server.zig` and nothing
//! here takes a lock.
//!
//! Two things this stage does *not* decide, both due at S3 when `ReadRows`
//! first touches the engine (see docs/STORAGE_READ_PLAN.md §2):
//!
//!   1. `handler_mutex` lives on `http_server.Server`, not on `bqserver.Server`,
//!      so a gRPC path that reaches the engine must either hoist it or be
//!      handed the HTTP server.
//!   2. It is a `std.Io.Mutex` taken as `lockUncancelable(io)`, and whether
//!      that may be taken from a raw `std.Thread` this file spawned is an open
//!      question.
//!
//! When `ReadRows` does arrive it must materialize the full result and release
//! the lock *before* writing any batch to the wire. Streaming while holding the
//! engine lets one slow reader stall every REST request in the process.

const std = @import("std");
const c = @import("c.zig");
const method_path = @import("method.zig");

const log = std.log.scoped(.grpc);

pub const Options = struct {
    address: []const u8 = "0.0.0.0",
    /// 0 asks the kernel to choose; the chosen port is reported as
    /// `Server.bound_port`. That is what makes tests collision-free.
    port: u16 = 9060,
    /// How many `grpc_server_request_call` tags are kept posted. One is
    /// correct; more only shortens the window between a call arriving and the
    /// next request being armed.
    outstanding_requests: u8 = 4,
};

pub const Error = error{
    GrpcBindFailed,
    GrpcCredentials,
    GrpcQueueCreate,
    GrpcServerCreate,
    GrpcRequestCall,
} || std.mem.Allocator.Error || std.Thread.SpawnError;

/// One in-flight call. Its *address* is the completion tag for both batches it
/// takes part in; `phase` says which one just finished. A call moves
/// `awaiting_call -> awaiting_close` strictly sequentially, so one allocation
/// is never ambiguous.
const Call = struct {
    server: *Server,
    phase: enum { awaiting_call, awaiting_close },
    call: ?*c.c.grpc_call,
    details: c.c.grpc_call_details,
    metadata: c.c.grpc_metadata_array,
    status_details: c.c.grpc_slice,
    cancelled: c_int,
    ops: [3]c.c.grpc_op,

    fn create(s: *Server) !*Call {
        const self = try s.gpa.create(Call);
        // The C members are zeroed rather than left undefined: gRPC reads
        // grpc_op.flags and requires grpc_op.reserved to be null, and a zeroed
        // grpc_slice is a valid empty one. Field by field rather than
        // `zeroes(Call)`, which cannot zero the non-nullable `server` pointer.
        self.* = .{
            .server = s,
            .phase = .awaiting_call,
            .call = null,
            .details = std.mem.zeroes(c.c.grpc_call_details),
            .metadata = std.mem.zeroes(c.c.grpc_metadata_array),
            .status_details = std.mem.zeroes(c.c.grpc_slice),
            .cancelled = 0,
            .ops = std.mem.zeroes([3]c.c.grpc_op),
        };
        c.c.grpc_call_details_init(&self.details);
        c.c.grpc_metadata_array_init(&self.metadata);
        return self;
    }

    fn destroy(self: *Call) void {
        const gpa = self.server.gpa;
        if (self.call) |call| c.c.grpc_call_unref(call);
        c.c.grpc_slice_unref(self.status_details);
        c.c.grpc_call_details_destroy(&self.details);
        c.c.grpc_metadata_array_destroy(&self.metadata);
        gpa.destroy(self);
    }

    /// An UNIMPLEMENTED answer.
    ///
    /// SEND_INITIAL_METADATA is sent even though the status alone would produce
    /// a Trailers-Only response. Measured, not assumed: with status as the only
    /// send op, a gRPC C-core client posting RECV_INITIAL_METADATA never
    /// completes its batch and sits until its deadline. Sending empty initial
    /// metadata first costs one HEADERS frame and answers immediately.
    ///
    /// No RECV_MESSAGE: the unregistered `grpc_server_request_call` never
    /// delivers a payload, which is exactly why S1 needs no protobuf.
    fn rejectUnimplemented(self: *Call, path: []const u8) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Method not implemented: {s}", .{path}) catch
            "Method not implemented";
        self.status_details = c.c.grpc_slice_from_copied_buffer(msg.ptr, msg.len);

        self.ops[0].op = @intFromEnum(c.OpType.send_initial_metadata);
        self.ops[0].data.send_initial_metadata = .{
            .count = 0,
            .metadata = null,
            .maybe_compression_level = .{ .is_set = 0, .level = 0 },
        };
        self.ops[1].op = @intFromEnum(c.OpType.send_status_from_server);
        self.ops[1].data.send_status_from_server = .{
            .trailing_metadata_count = 0,
            .trailing_metadata = null,
            .status = @intFromEnum(c.Status.unimplemented),
            .status_details = &self.status_details,
        };
        // Not needed to answer the call, but it is what turns "the status is
        // queued" into "the call is over", giving exactly one point at which
        // this allocation may be freed.
        self.ops[2].op = @intFromEnum(c.OpType.recv_close_on_server);
        self.ops[2].data.recv_close_on_server = .{ .cancelled = &self.cancelled };

        self.phase = .awaiting_close;
        const err = c.c.grpc_call_start_batch(self.call, &self.ops, self.ops.len, self, null);
        if (!c.callOk(err)) {
            log.err("start_batch rejecting {s} failed: {d}", .{ path, err });
            self.destroy();
        }
    }
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    cq: *c.c.grpc_completion_queue,
    server: *c.c.grpc_server,
    /// The port actually bound. Equals `Options.port` unless that was 0.
    bound_port: u16,
    outstanding_requests: u8,
    thread: ?std.Thread = null,
    /// Whether `shutdown_and_notify` has been issued. `stop` is idempotent and
    /// `deinit` calls it, so callers may do either or both.
    shut_down: bool = false,
    /// The completion tag for `grpc_server_shutdown_and_notify`. Its *address*
    /// is the tag, so it can never alias a `Call` allocation; the byte itself
    /// is unused.
    shutdown_marker: u8 = 0,

    /// Heap-allocated because `&shutdown_marker` is handed to C and must not
    /// move.
    pub fn init(gpa: std.mem.Allocator, opts: Options) Error!*Server {
        // Process-global and refcounted, so several servers may coexist; each
        // pairs its own grpc_shutdown in deinit.
        c.c.grpc_init();
        errdefer c.c.grpc_shutdown();

        const cq = c.c.grpc_completion_queue_create_for_next(null) orelse
            return error.GrpcQueueCreate;
        errdefer c.c.grpc_completion_queue_destroy(cq);

        const srv = createServer() orelse return error.GrpcServerCreate;
        errdefer c.c.grpc_server_destroy(srv);
        c.c.grpc_server_register_completion_queue(srv, cq, null);

        // Allocated before the bind, not after: nothing fallible may run
        // between adding a listener and starting the server, because the
        // errdefer above would then destroy a server holding a listener it
        // never started — the same un-drained destroy that aborts in `stop`.
        const s = try gpa.create(Server);
        errdefer gpa.destroy(s);

        const bound = try bindPort(gpa, srv, opts);
        s.* = .{
            .gpa = gpa,
            .cq = cq,
            .server = srv,
            .bound_port = bound,
            .outstanding_requests = @max(1, opts.outstanding_requests),
        };
        c.c.grpc_server_start(srv);
        return s;
    }

    /// Arms the first request calls and hands the completion queue its thread.
    pub fn start(s: *Server) Error!void {
        var armed: u8 = 0;
        while (armed < s.outstanding_requests) : (armed += 1) try s.postRequestCall();
        s.thread = try std.Thread.spawn(.{}, run, .{s});
    }

    /// Stops accepting, cancels anything in flight, and drains the queue.
    ///
    /// Draining is not optional: destroying the server before the queue has
    /// handed the shutdown tag back aborts inside gRPC core with
    /// `Check failed: listeners_destroyed_ == listener_states_.size()`.
    ///
    /// Idempotent, and correct whether or not a loop thread ever ran — `start`
    /// can fail after posting some request calls, and those have to be drained
    /// by someone or their `Call` allocations leak.
    pub fn stop(s: *Server) void {
        if (s.shut_down) {
            if (s.thread) |t| {
                t.join();
                s.thread = null;
            }
            return;
        }
        s.shut_down = true;
        c.c.grpc_server_shutdown_and_notify(s.server, s.cq, &s.shutdown_marker);
        // Nothing is long-lived at S1, but a ReadRows stream will be, and a
        // client that opens one and stops reading would otherwise wedge
        // shutdown for as long as it cared to.
        c.c.grpc_server_cancel_all_calls(s.server);

        if (s.thread) |t| {
            // The loop thread is the drain; joining it is waiting for the
            // drain to finish.
            t.join();
            s.thread = null;
        } else {
            // No loop thread: run the same drain on this one.
            s.run();
        }
    }

    pub fn deinit(s: *Server) void {
        s.stop();
        // Order is load-bearing: the server holds a ref on the queue, and the
        // queue must already be drained — `stop` having joined the loop is the
        // proof.
        c.c.grpc_server_destroy(s.server);
        c.c.grpc_completion_queue_destroy(s.cq);
        c.c.grpc_shutdown();
        s.gpa.destroy(s);
    }

    fn postRequestCall(s: *Server) Error!void {
        const call = Call.create(s) catch return error.OutOfMemory;
        errdefer call.destroy();
        const err = c.c.grpc_server_request_call(
            s.server,
            &call.call,
            &call.details,
            &call.metadata,
            s.cq,
            s.cq,
            call,
        );
        if (!c.callOk(err)) return error.GrpcRequestCall;
    }

    fn run(s: *Server) void {
        while (true) {
            const ev = c.c.grpc_completion_queue_next(s.cq, c.infFuture(), null);
            switch (c.completion(ev)) {
                // The deadline is infinite, so shutdown arrives as a tag rather
                // than as a timeout. A timeout here is not expected.
                .timeout => continue,
                .shutdown => return,
                .op_complete => s.dispatch(ev),
            }
        }
    }

    fn dispatch(s: *Server, ev: c.c.grpc_event) void {
        const tag = ev.tag orelse return;
        // Identity check before any cast: this tag is not a *Call.
        if (tag == @as(*anyopaque, @ptrCast(&s.shutdown_marker))) {
            // The server is down; tell the queue to drain. `run` returns when
            // it reports GRPC_QUEUE_SHUTDOWN.
            c.c.grpc_completion_queue_shutdown(s.cq);
            return;
        }
        const call: *Call = @ptrCast(@alignCast(tag));
        switch (call.phase) {
            .awaiting_call => s.onNewCall(call, ev.success != 0),
            .awaiting_close => call.destroy(),
        }
    }

    fn onNewCall(s: *Server, call: *Call, ok: bool) void {
        // success == 0 is core's way of saying this request_call is being
        // cancelled because the server is shutting down. Do not re-arm.
        if (!ok) {
            call.destroy();
            return;
        }
        s.postRequestCall() catch |err|
            log.err("cannot arm the next request_call: {t}", .{err});

        const path = c.sliceBytes(&call.details.method);
        if (method_path.parse(path)) |m| {
            log.debug("{s}/{s} -> UNIMPLEMENTED", .{ m.service, m.name });
        } else {
            log.debug("malformed method path {s} -> UNIMPLEMENTED", .{path});
        }
        // S3 grows a switch over `m` here. Until then every method is
        // unimplemented, which is the honest answer.
        call.rejectUnimplemented(path);
    }
};

/// A server with `SO_REUSEPORT` turned off.
///
/// gRPC core sets it on its listeners by default, so without this a second
/// emulator binds the same `--grpc-port` happily and the kernel load-balances
/// calls between two processes with different databases. Measured, not
/// theorised: two `bigquery-emulator` processes both appeared in
/// `lsof -nP -iTCP:19060 -sTCP:LISTEN`. Off, a taken port is an error — which
/// is what the REST listener already does, and what anyone who left a stale
/// emulator running expects.
fn createServer() ?*c.c.grpc_server {
    // Field by field rather than a nested literal: grpc_arg's value is a union,
    // and `[_]grpc_arg{.{ .value = .{ ... } }}` nests three deep for no gain.
    var reuseport_key = "grpc.so_reuseport".*;
    var arg: c.c.grpc_arg = std.mem.zeroes(c.c.grpc_arg);
    arg.type = @intCast(c.c.GRPC_ARG_INTEGER);
    arg.key = &reuseport_key;
    arg.value.integer = 0;
    // grpc_server_create copies the args, so these locals may die on return.
    const chan_args: c.c.grpc_channel_args = .{ .num_args = 1, .args = &arg };
    return c.c.grpc_server_create(&chan_args, null);
}

/// Split out of `init` so the null-terminated address has an obvious lifetime.
fn bindPort(gpa: std.mem.Allocator, srv: *c.c.grpc_server, opts: Options) Error!u16 {
    const addr = try std.fmt.allocPrintSentinel(gpa, "{s}:{d}", .{ opts.address, opts.port }, 0);
    defer gpa.free(addr);

    const creds = c.c.grpc_insecure_server_credentials_create() orelse
        return error.GrpcCredentials;
    // add_http2_port takes its own ref.
    defer c.c.grpc_server_credentials_release(creds);

    // "Returns bound port number on success, 0 on failure" (grpc.h:462). There
    // is no errno and no message; core logs its own line to stderr first.
    const bound = c.c.grpc_server_add_http2_port(srv, addr.ptr, creds);
    if (bound == 0) return error.GrpcBindFailed;
    return @intCast(bound);
}

// No test in this file constructs a Server. A wedged or aborting completion
// queue would take `zig build test-server` — the repo's main CI gate — down
// with it, and gRPC's shutdown checks abort rather than fail. The round trip
// lives in `harness/grpc_smoke.zig` behind `zig build grpc-smoke`, where a hang
// is a failed harness rather than a failed gate.
