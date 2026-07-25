//! Port of bigquery-emulator server/handler.go discoveryHandler (:80-101).
//!
//! Go embeds server/resources/discovery.json (535 KB), rewrites rootUrl /
//! baseUrl / mtlsRootUrl to point at the emulator, and caches the result
//! behind a sync.Once.
//!
//! M1 serves a minimal document instead of the full 535 KB one. The Google
//! client libraries fetch discovery but do not require the complete method
//! list to issue jobs.query — they use their compiled-in surface. The full
//! document is copied in when the handler surface grows to match it, at
//! which point the rewrite-once-and-cache shape above applies.

const std = @import("std");
const http_server = @import("http/server.zig");

pub fn handle(arena: std.mem.Allocator, endpoint: []const u8) !http_server.Response {
    const body = try std.fmt.allocPrint(arena,
        \\{{"kind":"discovery#restDescription","id":"bigquery:v2","name":"bigquery","version":"v2","title":"BigQuery API","rootUrl":"http://{s}/","baseUrl":"http://{s}/bigquery/v2/","mtlsRootUrl":"http://{s}/","servicePath":"bigquery/v2/","batchPath":"batch/bigquery/v2","protocol":"rest"}}
    , .{ endpoint, endpoint, endpoint });
    return .{ .body = body };
}

const testing = std.testing;

test "discovery advertises the emulator's own endpoint" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const res = try handle(arena, "127.0.0.1:9050");
    try testing.expectEqual(std.http.Status.ok, res.status);

    // Must parse, and must point clients back at us rather than at Google.
    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena, res.body, .{});
    try testing.expectEqualStrings("http://127.0.0.1:9050/", v.object.get("rootUrl").?.string);
    try testing.expectEqualStrings(
        "http://127.0.0.1:9050/bigquery/v2/",
        v.object.get("baseUrl").?.string,
    );
    try testing.expectEqualStrings("discovery#restDescription", v.object.get("kind").?.string);
}
