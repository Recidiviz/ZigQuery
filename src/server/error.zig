//! Faithful port of bigquery-emulator server/error.go.
//!
//! The wire shape, verified byte-for-byte against the running Go emulator
//! (testdata/golden.json):
//!
//!   {"error":{"errors":[{"reason":"...","location":"","debugInfo":"",
//!             "message":"..."}],"code":404,"message":"..."}}
//!
//! Note `location` and `debugInfo` are always emitted even when empty, and
//! the message is repeated at both levels.
// ephor:ignore-file ZA302 ZA304 ZA701

const std = @import("std");
const http = std.http;
const pb = @import("proto/bigquery.zig");

/// Go server/error.go's reason -> status table. Only the reasons the M1
/// surface can produce are listed; the rest arrive with their handlers.
pub const Reason = enum {
    invalid,
    invalid_query,
    not_found,
    duplicate,
    internal_error,
    backend_error,

    /// The literal string BigQuery uses on the wire.
    pub fn text(r: Reason) []const u8 {
        return switch (r) {
            .invalid => "invalid",
            .invalid_query => "invalidQuery",
            .not_found => "notFound",
            .duplicate => "duplicate",
            .internal_error => "internalError",
            .backend_error => "backendError",
        };
    }

    pub fn status(r: Reason) http.Status {
        return switch (r) {
            .invalid, .invalid_query => .bad_request,
            .not_found => .not_found,
            .duplicate => .conflict,
            .internal_error, .backend_error => .internal_server_error,
        };
    }
};

/// The envelope around `ErrorProto`. Google's JSON error wrapper is not part of
/// the BigQuery protos, so it is spelled out here and serialized by the same
/// path as the generated messages.
const Envelope = struct {
    @"error": Detail,

    const Detail = struct {
        errors: []const pb.ErrorProto,
        code: u16,
        message: []const u8,
    };
};

/// Serializes the BigQuery error envelope. Returns the JSON body; the caller
/// pairs it with `reason.status()`.
pub fn body(arena: std.mem.Allocator, reason: Reason, message: []const u8) ![]const u8 {
    // `location` and `debugInfo` are set to empty rather than left absent:
    // presence is what puts a field on the wire, and these are always there.
    const errors = [_]pb.ErrorProto{.{
        .reason = reason.text(),
        .location = "",
        .debug_info = "",
        .message = message,
    }};
    return std.json.Stringify.valueAlloc(arena, Envelope{ .@"error" = .{
        .errors = &errors,
        .code = @backingInt(reason.status()),
        .message = message,
    } }, .{});
}

/// Minimal JSON string escaping, matching Go's encoding/json for the
/// characters that actually occur in these messages.
///
/// Every multi-byte sequence is validated before it is passed through: a
/// spec-corpus mismatch can legitimately embed a raw, non-UTF-8 "got" value
/// (a BYTES value, or an engine bug's wrong output) in a message, and one
/// invalid byte would otherwise emit an invalid JSON string — breaking the
/// whole bulk response it sits in, not just that one field. Each invalid
/// byte becomes U+FFFD; every existing (valid-UTF-8) caller is unaffected.
///
/// For a whole document, hand a typed value to `std.json.Stringify` instead.
/// This serves the paths that assemble JSON text directly.
pub fn writeJsonString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) std.mem.Allocator.Error!void {
    try out.append(arena, '"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        switch (ch) {
            '"' => try out.appendSlice(arena, "\\\""),
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\r' => try out.appendSlice(arena, "\\r"),
            '\t' => try out.appendSlice(arena, "\\t"),
            else => {
                if (ch < 0x20) {
                    try out.print(arena, "\\u{x:0>4}", .{ch});
                } else if (ch < 0x80) {
                    try out.append(arena, ch);
                } else {
                    const len = std.unicode.utf8ByteSequenceLength(ch) catch 0;
                    if (len != 0 and i + len <= s.len and std.unicode.utf8ValidateSlice(s[i .. i + len])) {
                        try out.appendSlice(arena, s[i .. i + len]);
                        // Increment to length - 1 (continue expression handles last 1)
                        i += len - 1;
                    } else {
                        try out.appendSlice(arena, "\u{FFFD}");
                    }
                }
            },
        }
    }
    try out.append(arena, '"');
}

const testing = std.testing;

test "error envelope matches the Go emulator byte for byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Captured from the running Go emulator (testdata/golden.json,
    // error_table_not_found).
    const got = try body(
        arena,
        .invalid_query,
        "failed to analyze: Table not found: nonexistent_table_xyz [at 1:15]",
    );
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"invalidQuery","location":"","debugInfo":"","message":"failed to analyze: Table not found: nonexistent_table_xyz [at 1:15]"}],"code":400,"message":"failed to analyze: Table not found: nonexistent_table_xyz [at 1:15]"}}
    ,
        got,
    );
}

test "not found carries 404 and the notFound reason" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try body(arena, .not_found, "job abc is not found");
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"notFound","location":"","debugInfo":"","message":"job abc is not found"}],"code":404,"message":"job abc is not found"}}
    ,
        got,
    );
    try testing.expectEqual(http.Status.not_found, Reason.not_found.status());
}

test "messages containing quotes and backslashes are escaped" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try body(arena, .invalid, "bad \"quoted\" \\ value\nline2");
    try testing.expectEqualStrings(
        \\{"error":{"errors":[{"reason":"invalid","location":"","debugInfo":"","message":"bad \"quoted\" \\ value\nline2"}],"code":400,"message":"bad \"quoted\" \\ value\nline2"}}
    ,
        got,
    );
}

test "valid UTF-8 passes through untouched, invalid bytes become U+FFFD" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeJsonString(arena, &out, "h\u{00e9}llo w\u{00f6}rld \u{1F600}");
    try testing.expectEqualStrings("\"h\u{00e9}llo w\u{00f6}rld \u{1F600}\"", out.items);

    // A lone UTF-8 continuation byte, e.g. from a wrongly byte-sliced
    // multi-byte string (the class of bug SUBSTRING can still produce) — not
    // valid UTF-8 on its own, so it must not reach the output raw.
    var out2: std.ArrayList(u8) = .empty;
    try writeJsonString(arena, &out2, "abc\xa2def");
    try testing.expectEqualStrings("\"abc\u{FFFD}def\"", out2.items);
}

test "the canned 500 matches what body() produces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();

    // http/server.zig answers a failed handler with a literal, because that
    // path must not allocate. Nothing else keeps the two in step.
    const http_server = @import("http/server.zig");
    try testing.expectEqualStrings(
        http_server.internal_error_body,
        try body(arena_state.allocator(), .internal_error, "internal error"),
    );
}
