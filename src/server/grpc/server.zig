//! gRPC transport for the BigQuery Storage Read API.
//!
//! The transport comes from C because Zig 0.16 std has no HTTP/2, no HPACK and
//! no TLS server. gRPC is HTTP/2 plus a framing over it, so the transport is
//! gRPC's own core. `grpc_server_request_call` hands back the method path; a
//! service is a switch over a string.
//!
//! It is deliberately not on `std.Io`: `grpc_completion_queue_next` blocks the
//! thread it is called on. It therefore gets a plain `std.Thread`, the same
//! choice `http/server.zig` makes for connections, rather than parking a
//! `std.Io.Threaded` worker that no scheduler can account for.

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

/// How a failed call is reported to the caller.
pub const Fault = struct {
    status: c.Status,
    /// Shown to whoever made the call, so it is prose, not an error name.
    message: []const u8,
};

/// What a service does with one unary call: request bytes in, response bytes out,
/// both borrowed from / allocated in the per-call arena.
///
/// Function pointers rather than a direct import so this file stays transport-only.
pub const Dispatch = struct {
    ctx: *anyopaque,
    /// Returns the response messages, in order.
    /// Null means "not this service's method", which the caller turns into UNIMPLEMENTED.
    ///
    /// Returns a slice rather than one message to support server-streaming;
    /// a unary method returns one element and its wire behaviour is unchanged.
    func: *const fn (
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        method: method_path.Method,
        request: []const u8,
    ) anyerror!?[]const []const u8,
    /// Turns an error from `func` into a status and a message.
    /// It belongs to the service, not here:
    /// only the service knows whether one of its errors is the caller's fault or its own
    fault: *const fn (ctx: *anyopaque, err: anyerror) Fault,
};

/// One in-flight call. Its address is the completion tag for every batch it
/// takes part in; `phase` says which one just finished. A call only ever moves
/// forwards through the phases, so one allocation is never ambiguous.
///
/// A unary call needs three round trips through the completion queue, not one:
/// `grpc_server_request_call` hands back the method and metadata but not the
/// payload — that is `grpc_server_request_registered_call`'s job — so the
/// request body has to be asked for with its own RECV_MESSAGE batch before the
/// service can be called.
const Call = struct {
    server: *Server,
    phase: enum { awaiting_call, awaiting_request, awaiting_send, awaiting_close },
    call: ?*c.c.grpc_call,
    details: c.c.grpc_call_details,
    metadata: c.c.grpc_metadata_array,
    status_details: c.c.grpc_slice,
    cancelled: c_int,
    ops: [3]c.c.grpc_op,
    /// The request payload, owned by gRPC until we destroy it. Null when the client sent no message
    request: ?*c.c.grpc_byte_buffer,
    /// The message currently in flight. One SEND_MESSAGE at a time:
    /// gRPC core allows at most one per batch, and each must complete before the next starts.
    /// Destroyed as its batch completes, before the next is created.
    response: ?*c.c.grpc_byte_buffer,
    /// The messages still to send, and how many have gone. Streaming fills many, a unary just one.
    responses: []const []const u8,
    sent: usize,
    /// Per-call scratch space: the decoded request, the encoded response, and anything else
    arena: std.heap.ArenaAllocator,

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
            .request = null,
            .response = null,
            .responses = &.{},
            .sent = 0,
            .arena = std.heap.ArenaAllocator.init(s.gpa),
        };
        c.c.grpc_call_details_init(&self.details);
        c.c.grpc_metadata_array_init(&self.metadata);
        return self;
    }

    fn destroy(self: *Call) void {
        const gpa = self.server.gpa;
        if (self.request) |bb| c.c.grpc_byte_buffer_destroy(bb);
        if (self.response) |bb| c.c.grpc_byte_buffer_destroy(bb);
        if (self.call) |call| c.c.grpc_call_unref(call);
        c.c.grpc_slice_unref(self.status_details);
        c.c.grpc_call_details_destroy(&self.details);
        c.c.grpc_metadata_array_destroy(&self.metadata);
        self.arena.deinit();
        gpa.destroy(self);
    }

    /// Asks for the request body. `grpc_server_request_call` did not deliver
    /// it, so a unary method cannot be answered until this completes.
    ///
    /// SEND_INITIAL_METADATA rides along: it costs nothing extra here and it is
    /// what a C-core client posting RECV_INITIAL_METADATA is waiting for.
    fn recvRequest(self: *Call) void {
        self.ops = std.mem.zeroes([3]c.c.grpc_op);
        self.ops[0].op = @intFromEnum(c.OpType.send_initial_metadata);
        self.ops[0].data.send_initial_metadata = .{
            .count = 0,
            .metadata = null,
            .maybe_compression_level = .{ .is_set = 0, .level = 0 },
        };
        self.ops[1].op = @intFromEnum(c.OpType.recv_message);
        self.ops[1].data.recv_message = .{ .recv_message = &self.request };

        self.phase = .awaiting_request;
        const err = c.c.grpc_call_start_batch(self.call, &self.ops, 2, self, null);
        if (!c.callOk(err)) {
            log.err("start_batch receiving a request failed: {d}", .{err});
            self.destroy();
        }
    }

    /// The request payload as a flat slice in the call arena.
    ///
    /// gRPC hands back a byte buffer whose slices may be non-contiguous, so
    /// `readall` is what turns it into something a decoder can walk. An absent
    /// buffer is an empty message, not an error: proto3 lets every field be
    /// omitted, so a zero-byte request is legal.
    fn requestBytes(self: *Call) ![]const u8 {
        const bb = self.request orelse return "";
        var reader: c.c.grpc_byte_buffer_reader = undefined;
        if (c.c.grpc_byte_buffer_reader_init(&reader, bb) == 0) return error.BadRequestBuffer;
        defer c.c.grpc_byte_buffer_reader_destroy(&reader);
        const slice = c.c.grpc_byte_buffer_reader_readall(&reader);
        defer c.c.grpc_slice_unref(slice);
        return self.arena.allocator().dupe(u8, c.sliceBytes(&slice));
    }

    /// Sends the next queued message, or the closing status once they are all
    /// gone.
    ///
    /// One message per batch: gRPC core permits at most one SEND_MESSAGE in a
    /// batch and will not accept a second while one is outstanding, so a
    /// streaming method is this function re-entered from the completion queue
    /// once per message. Unary is the same path with one element.
    fn sendNext(self: *Call) void {
        // The buffer for the message that just went out. gRPC owns it until its
        // batch completes, which is now, so this is the first moment it can go.
        if (self.response) |bb| {
            c.c.grpc_byte_buffer_destroy(bb);
            self.response = null;
        }
        if (self.sent == self.responses.len) return self.finish();

        const body = self.responses[self.sent];
        self.sent += 1;

        var payload = c.c.grpc_slice_from_copied_buffer(body.ptr, body.len);
        defer c.c.grpc_slice_unref(payload);
        self.response = c.c.grpc_raw_byte_buffer_create(&payload, 1);

        self.ops = std.mem.zeroes([3]c.c.grpc_op);
        // No SEND_INITIAL_METADATA: recvRequest already sent it, and sending it
        // twice is a use-after-send error inside core.
        self.ops[0].op = @intFromEnum(c.OpType.send_message);
        self.ops[0].data.send_message = .{ .send_message = self.response };

        self.phase = .awaiting_send;
        const err = c.c.grpc_call_start_batch(self.call, &self.ops, 1, self, null);
        if (!c.callOk(err)) {
            log.err("start_batch sending message {d} failed: {d}", .{ self.sent, err });
            self.destroy();
        }
    }

    /// Closes a successful call once every message has been acknowledged.
    fn finish(self: *Call) void {
        self.ops = std.mem.zeroes([3]c.c.grpc_op);
        self.ops[0].op = @intFromEnum(c.OpType.send_status_from_server);
        self.ops[0].data.send_status_from_server = .{
            .trailing_metadata_count = 0,
            .trailing_metadata = null,
            .status = @intFromEnum(c.Status.ok),
            .status_details = null,
        };
        // What turns "the status is queued" into "the call is over", giving
        // exactly one point at which this allocation may be freed.
        self.ops[1].op = @intFromEnum(c.OpType.recv_close_on_server);
        self.ops[1].data.recv_close_on_server = .{ .cancelled = &self.cancelled };

        self.phase = .awaiting_close;
        const err = c.c.grpc_call_start_batch(self.call, &self.ops, 2, self, null);
        if (!c.callOk(err)) {
            log.err("start_batch closing failed: {d}", .{err});
            self.destroy();
        }
    }

    /// Closes the call with a non-OK status. Initial metadata has already gone
    /// out by the time anything can fail this way, so it is not resent.
    fn fail(self: *Call, status: c.Status, message: []const u8) void {
        self.status_details = c.c.grpc_slice_from_copied_buffer(message.ptr, message.len);

        self.ops = std.mem.zeroes([3]c.c.grpc_op);
        self.ops[0].op = @intFromEnum(c.OpType.send_status_from_server);
        self.ops[0].data.send_status_from_server = .{
            .trailing_metadata_count = 0,
            .trailing_metadata = null,
            .status = @intFromEnum(status),
            .status_details = &self.status_details,
        };
        self.ops[1].op = @intFromEnum(c.OpType.recv_close_on_server);
        self.ops[1].data.recv_close_on_server = .{ .cancelled = &self.cancelled };

        self.phase = .awaiting_close;
        const err = c.c.grpc_call_start_batch(self.call, &self.ops, 2, self, null);
        if (!c.callOk(err)) {
            log.err("start_batch failing a call failed: {d}", .{err});
            self.destroy();
        }
    }

    /// An UNIMPLEMENTED answer, sent as the first batch of the call.
    ///
    /// SEND_INITIAL_METADATA is sent even though the status alone would produce
    /// a Trailers-Only response. Measured, not assumed: with status as the only
    /// send op, a gRPC C-core client posting RECV_INITIAL_METADATA never
    /// completes its batch and sits until its deadline. Sending empty initial
    /// metadata first costs one HEADERS frame and answers immediately.
    ///
    /// No RECV_MESSAGE: an unknown method's payload is never read, so there is
    /// nothing to decode and nothing to wait for.
    fn rejectUnimplemented(self: *Call, path: []const u8) void {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Method not implemented: {s}", .{path}) catch
            "Method not implemented";
        self.status_details = c.c.grpc_slice_from_copied_buffer(msg.ptr, msg.len);

        self.ops = std.mem.zeroes([3]c.c.grpc_op);
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

    /// The request has arrived: hand it to the service and answer.
    fn serve(self: *Call) void {
        const path = c.sliceBytes(&self.details.method);
        const m = method_path.parse(path) orelse {
            self.fail(.unimplemented, "Malformed method path");
            return;
        };
        const d = self.server.service orelse {
            self.fail(.unimplemented, "No service is registered");
            return;
        };

        const request = self.requestBytes() catch {
            self.fail(.internal, "Could not read the request payload");
            return;
        };

        const body = d.func(d.ctx, self.arena.allocator(), m, request) catch |err| {
            self.failService(d, m, err);
            return;
        } orelse {
            self.fail(.unimplemented, "Method not implemented");
            return;
        };
        self.responses = body;
        self.sendNext();
    }

    /// Reports an error the service returned, asking the service what it means.
    fn failService(
        self: *Call,
        d: Dispatch,
        m: method_path.Method,
        err: anyerror,
    ) void {
        const f = d.fault(d.ctx, err);
        // Logged at err only when it is ours: a caller sending a bad request is
        // not a server fault and a log full of them reads like one.
        if (f.status == .internal) {
            log.err("{s}/{s} failed: {t}", .{ m.service, m.name, err });
        } else {
            log.debug("{s}/{s} -> {t}: {s}", .{ m.service, m.name, f.status, f.message });
        }
        self.fail(f.status, f.message);
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
    /// The service calls are handed to. Null answers every method
    /// UNIMPLEMENTED, which is what this transport did on its own before there
    /// was a service to hand them to — and is still what `grpc-smoke` exercises.
    service: ?Dispatch = null,

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
            // success == 0 here means the client went away before sending a
            // body; there is nobody left to answer.
            .awaiting_request => if (ev.success != 0) call.serve() else call.destroy(),
            // The one phase that repeats. success == 0 means the client went
            // away mid-stream, or `stop` cancelled the call; either way there is
            // nobody left to send the rest to.
            .awaiting_send => if (ev.success != 0) call.sendNext() else call.destroy(),
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
        if (s.service == null) {
            log.debug("{s} -> UNIMPLEMENTED (no service)", .{path});
            call.rejectUnimplemented(path);
            return;
        }
        // Which method it is is the service's business; this only knows that a
        // unary call needs its body fetched before anyone can answer it.
        log.debug("{s}", .{path});
        call.recvRequest();
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
