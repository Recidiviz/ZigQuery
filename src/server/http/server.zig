//! Replaces bigquery-emulator's use of net/http + gorilla/mux — REDESIGNED,
//! not ported. Go gets an accept loop, routing, and middleware chaining from
//! the standard library; Zig 0.16's `std.http.Server` is explicitly only "a
//! single connection lifecycle", so the accept loop lives here.
//!
//! Differences from Go, by design:
//! - No middleware chain. Go threads request-scoped values through
//!   context.Context with eight keys (server/context.go) and eleven
//!   middlewares that populate them; here a `Request` carries what handlers
//!   need as plain fields.
//! - No sequentialAccessMiddleware. Go serializes every request behind one
//!   package-level mutex (server/middleware.go:19-28, added upstream in a
//!   commit titled only "improve performance"); this server does not, which
//!   is the point of the port.
//!
//! HTTP/1.1 only. Zig 0.16 std has no HTTP/2, no HPACK, and no TLS server;
//! the BigQuery REST clients speak cleartext HTTP/1.1 to an emulator.

const std = @import("std");
const http = std.http;

/// Request head buffer. `std.http.Server` sets max_head_len to the length of
/// the connection reader's buffer, so this is the hard cap on request line +
/// headers. Google's clients send long URLs and many headers; 16 KiB matches
/// the 8 KiB gRPC guidance with room to spare.
const head_buffer_len = 16 * 1024;
/// Body chunks and, when the client compresses, the decompression window.
const body_buffer_len = 64 * 1024;
const decompress_buffer_len = 64 * 1024;
/// Response bytes buffered before hitting the socket.
const write_buffer_len = 64 * 1024;

/// Largest request body accepted, matching no specific Go limit — Go has
/// none — but preventing a hostile client from exhausting the arena.
pub const max_body_len = 64 * 1024 * 1024;

pub const Request = struct {
    method: http.Method,
    /// Path with the query string removed, percent-decoding NOT applied.
    path: []const u8,
    /// Raw query string, without '?'. Empty when absent.
    query: []const u8,
    /// Decompressed request body. Empty when there is none.
    body: []const u8,
    /// Per-request arena. Everything a handler allocates comes from here and
    /// dies when the request completes.
    arena: std.mem.Allocator,

    /// Value of the first matching query parameter, or null.
    ///
    /// Values are returned raw; callers that need percent-decoding must do it
    /// themselves. The emulator's own parameters (maxResults, prettyPrint,
    /// alt) are never encoded in practice.
    pub fn queryParam(r: *const Request, name: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, r.query, '&');
        while (it.next()) |pair| {
            if (pair.len == 0) continue;
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse {
                if (std.mem.eql(u8, pair, name)) return "";
                continue;
            };
            if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
        }
        return null;
    }
};

pub const Response = struct {
    status: http.Status = .ok,
    /// Serialized body. Owned by the request arena.
    body: []const u8 = "",
    content_type: []const u8 = "application/json; charset=UTF-8",
};

/// A handler turns a request into a complete response. Returning an error
/// produces a 500 in the BigQuery error shape, mirroring Go's
/// recoveryMiddleware.
pub const HandlerFn = *const fn (ctx: *anyopaque, req: *const Request) anyerror!Response;

pub const Handler = struct {
    ctx: *anyopaque,
    func: HandlerFn,
};

pub const Options = struct {
    address: []const u8 = "0.0.0.0",
    port: u16 = 9050,
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    listener: std.Io.net.Server,
    handler: Handler,

    pub fn listen(
        gpa: std.mem.Allocator,
        io: std.Io,
        opts: Options,
        handler: Handler,
    ) !Server {
        const addr = try std.Io.net.IpAddress.parse(opts.address, opts.port);
        const listener = try std.Io.net.IpAddress.listen(&addr, io, .{
            .reuse_address = true,
        });
        return .{ .gpa = gpa, .io = io, .listener = listener, .handler = handler };
    }

    pub fn deinit(s: *Server) void {
        s.listener.deinit(s.io);
    }

    /// Accepts and serves connections until the listening socket is shut
    /// down. Single-threaded: one connection is served to completion before
    /// the next is accepted.
    ///
    /// This is M1's deliberate shape — it matches the Go server's observable
    /// behaviour exactly, since its global mutex made it serial anyway — and
    /// is replaced by a worker pool once the engine is confirmed safe to
    /// drive concurrently.
    pub fn serve(s: *Server) !void {
        while (true) {
            var stream = s.listener.accept(s.io) catch |err| switch (err) {
                // shutdown() on the listening socket is the documented
                // cancellation mechanism.
                error.SocketNotListening, error.Canceled => return,
                error.ConnectionAborted, error.BlockedByFirewall => continue,
                else => return err,
            };
            s.serveConnection(&stream) catch {};
            stream.close(s.io);
        }
    }

    fn serveConnection(s: *Server, stream: *std.Io.net.Stream) !void {
        const read_buf = try s.gpa.alloc(u8, head_buffer_len);
        defer s.gpa.free(read_buf);
        const write_buf = try s.gpa.alloc(u8, write_buffer_len);
        defer s.gpa.free(write_buf);

        var reader = stream.reader(s.io, read_buf);
        var writer = stream.writer(s.io, write_buf);
        var conn = http.Server.init(&reader.interface, &writer.interface);

        while (true) {
            var request = conn.receiveHead() catch |err| switch (err) {
                // Normal end of a kept-alive connection, not a failure.
                error.HttpConnectionClosing => return,
                else => return err,
            };

            var arena_state = std.heap.ArenaAllocator.init(s.gpa);
            defer arena_state.deinit();

            const keep_alive = s.serveRequest(&request, arena_state.allocator()) catch |err| blk: {
                // Mirrors Go's recoveryMiddleware: report, do not drop the
                // connection.
                std.log.err("request failed: {s} {s}: {t}", .{
                    @tagName(request.head.method),
                    request.head.target,
                    err,
                });
                request.respond(
                    \\{"error":{"errors":[{"reason":"internalError","location":"","debugInfo":"","message":"internal error"}],"code":500,"message":"internal error"}}
                , .{
                    .status = .internal_server_error,
                    .extra_headers = &.{
                        .{ .name = "content-type", .value = "application/json; charset=UTF-8" },
                    },
                }) catch return;
                break :blk true;
            };
            if (!keep_alive) return;
        }
    }

    /// Returns whether the connection may be reused.
    fn serveRequest(
        s: *Server,
        request: *http.Server.Request,
        arena: std.mem.Allocator,
    ) !bool {
        // Order matters: reading the body calls Head.invalidateStrings(), so
        // anything borrowed from `head` must be copied out first or it
        // becomes a dangling pointer.
        const target = try arena.dupe(u8, request.head.target);
        const method = request.head.method;

        const body = try readBody(request, arena);

        const q = std.mem.indexOfScalar(u8, target, '?');
        const req = Request{
            .method = method,
            .path = if (q) |i| target[0..i] else target,
            .query = if (q) |i| target[i + 1 ..] else "",
            .body = body,
            .arena = arena,
        };

        const res = try s.handler.func(s.handler.ctx, &req);

        try request.respond(res.body, .{
            .status = res.status,
            .extra_headers = &.{
                .{ .name = "content-type", .value = res.content_type },
            },
        });
        // respond() consumed the body already; discardBody reports whether
        // the connection survives.
        return request.head.keep_alive;
    }
};

/// Reads and, if the client compressed it, decompresses the request body.
///
/// Google's client libraries do send `Content-Encoding: gzip` on request
/// bodies — Go handles this in decompressMiddleware
/// (server/middleware.go:84-102).
fn readBody(request: *http.Server.Request, arena: std.mem.Allocator) ![]const u8 {
    if (request.head.content_length == null and
        request.head.transfer_encoding == .none) return "";

    const transfer_buf = try arena.alloc(u8, body_buffer_len);
    // readerExpectContinue also answers `Expect: 100-continue`, which the
    // Google clients send on larger uploads.
    const transfer_reader = try request.readerExpectContinue(transfer_buf);

    if (request.head.transfer_compression == .identity) {
        return transfer_reader.allocRemaining(arena, .limited(max_body_len));
    }

    // `decompress` owns the decoder state that `reader` borrows, so it has to
    // outlive the read below — hence the read happens here, not at the call
    // site.
    const decompress_buf = try arena.alloc(u8, decompress_buffer_len);
    var decompress: http.Decompress = undefined;
    const reader = decompress.init(
        transfer_reader,
        decompress_buf,
        request.head.transfer_compression,
    );
    return reader.allocRemaining(arena, .limited(max_body_len));
}

test "queryParam parses the forms the emulator actually receives" {
    const r = Request{
        .method = .GET,
        .path = "/projects/p/queries",
        .query = "maxResults=10&prettyPrint=false&flag&alt=json",
        .body = "",
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqualStrings("10", r.queryParam("maxResults").?);
    try std.testing.expectEqualStrings("false", r.queryParam("prettyPrint").?);
    try std.testing.expectEqualStrings("json", r.queryParam("alt").?);
    // Valueless parameter.
    try std.testing.expectEqualStrings("", r.queryParam("flag").?);
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("missing"));
    // Must not match on a prefix.
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("max"));
}

test "empty query string yields no parameters" {
    const r = Request{
        .method = .POST,
        .path = "/projects/p/queries",
        .query = "",
        .body = "",
        .arena = std.testing.allocator,
    };
    try std.testing.expectEqual(@as(?[]const u8, null), r.queryParam("maxResults"));
}
