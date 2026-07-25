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

const std = @import("std");
const http = std.http;

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

/// Serializes the BigQuery error envelope. Returns the JSON body; the caller
/// pairs it with `reason.status()`.
pub fn body(arena: std.mem.Allocator, reason: Reason, message: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    const w = &out;

    try w.appendSlice(arena, "{\"error\":{\"errors\":[{\"reason\":");
    try writeJsonString(arena, w, reason.text());
    try w.appendSlice(arena, ",\"location\":\"\",\"debugInfo\":\"\",\"message\":");
    try writeJsonString(arena, w, message);
    try w.appendSlice(arena, "}],\"code\":");
    try w.print(arena, "{d}", .{@intFromEnum(reason.status())});
    try w.appendSlice(arena, ",\"message\":");
    try writeJsonString(arena, w, message);
    try w.appendSlice(arena, "}}");

    return out.toOwnedSlice(arena);
}

/// Minimal JSON string escaping, matching Go's encoding/json for the
/// characters that actually occur in these messages.
pub fn writeJsonString(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) std.mem.Allocator.Error!void {
    try out.append(arena, '"');
    for (s) |ch| switch (ch) {
        '"' => try out.appendSlice(arena, "\\\""),
        '\\' => try out.appendSlice(arena, "\\\\"),
        '\n' => try out.appendSlice(arena, "\\n"),
        '\r' => try out.appendSlice(arena, "\\r"),
        '\t' => try out.appendSlice(arena, "\\t"),
        else => {
            if (ch < 0x20) {
                try out.print(arena, "\\u{x:0>4}", .{ch});
            } else {
                try out.append(arena, ch);
            }
        },
    };
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
