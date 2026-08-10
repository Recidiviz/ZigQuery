//! Splitting a gRPC method path.
//!
//! `grpc_call_details.method` arrives as `/package.Service/Method` — gRPC core
//! hands back whatever the client put on the wire, verbatim, so this is where a
//! malformed path is rejected rather than propagated into a dispatch switch.
//!
//! Deliberately free of any C import: it makes this testable under
//! `zig build test-server` without a completion queue, and it gives S3's
//! dispatch one place to grow.

const std = @import("std");

pub const Method = struct {
    /// e.g. "google.cloud.bigquery.storage.v1.BigQueryRead"
    service: []const u8,
    /// e.g. "ReadRows"
    name: []const u8,
};

/// Null for anything that is not exactly `/service/method` with both parts
/// non-empty and no further separators.
pub fn parse(path: []const u8) ?Method {
    if (path.len == 0 or path[0] != '/') return null;
    const rest = path[1..];

    const sep = std.mem.indexOfScalar(u8, rest, '/') orelse return null;
    const service = rest[0..sep];
    const name = rest[sep + 1 ..];

    if (service.len == 0 or name.len == 0) return null;
    // A second separator means this is not a method path, whatever else it is.
    if (std.mem.indexOfScalar(u8, name, '/') != null) return null;

    return .{ .service = service, .name = name };
}

const testing = std.testing;

test "parse splits the BigQueryRead paths" {
    const read_rows = parse("/google.cloud.bigquery.storage.v1.BigQueryRead/ReadRows").?;
    try testing.expectEqualStrings(
        "google.cloud.bigquery.storage.v1.BigQueryRead",
        read_rows.service,
    );
    try testing.expectEqualStrings("ReadRows", read_rows.name);

    const create = parse("/google.cloud.bigquery.storage.v1.BigQueryRead/CreateReadSession").?;
    try testing.expectEqualStrings("CreateReadSession", create.name);

    const split = parse("/google.cloud.bigquery.storage.v1.BigQueryRead/SplitReadStream").?;
    try testing.expectEqualStrings("SplitReadStream", split.name);
}

test "parse rejects malformed paths" {
    // No leading slash — a relative-looking path is not a gRPC method.
    try testing.expectEqual(@as(?Method, null), parse("svc/Method"));
    // No separator after the service.
    try testing.expectEqual(@as(?Method, null), parse("/svc"));
    // Empty service, empty method, empty everything.
    try testing.expectEqual(@as(?Method, null), parse("//Method"));
    try testing.expectEqual(@as(?Method, null), parse("/svc/"));
    try testing.expectEqual(@as(?Method, null), parse("/"));
    try testing.expectEqual(@as(?Method, null), parse(""));
    // A third component: not a method name.
    try testing.expectEqual(@as(?Method, null), parse("/svc/Method/extra"));
}

test "parse keeps a service with no package qualifier" {
    // Legal gRPC: the package part is optional.
    const m = parse("/Health/Check").?;
    try testing.expectEqualStrings("Health", m.service);
    try testing.expectEqualStrings("Check", m.name);
}
