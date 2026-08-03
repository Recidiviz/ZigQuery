//! Replaces bigquery-emulator's use of gorilla/mux — REDESIGNED, not ported.
//!
//! Differences from Go, by design:
//! - Captures bind **positionally**, not by name. The BigQuery discovery
//!   document names the same path variable inconsistently — some routes use
//!   `{projectId}/{datasetId}/{tableId}`, others `{projectsId}/{datasetsId}/
//!   {tablesId}` (compare handler_gen.go:14 with :79) — which forces Go to
//!   carry six near-identical `xIDFromParams` helpers
//!   (server/middleware.go:115-167) that try both spellings. Matching on
//!   position makes the spelling irrelevant and those helpers unnecessary.
//! - Every route is registered under both `/` and `/bigquery/v2`, matching
//!   server.go:92-97.

const std = @import("std");
const http = std.http;

/// Path variables captured left to right. Four is the deepest the BigQuery
/// REST surface goes (project/dataset/table/row-policy).
pub const max_captures = 4;

pub const Captures = struct {
    items: [max_captures][]const u8 = @splat(""),
    len: usize = 0,

    pub fn get(c: *const Captures, i: usize) []const u8 {
        return if (i < c.len) c.items[i] else "";
    }
};

pub const Match = struct {
    route: Route.Id,
    captures: Captures,
};

pub const Route = struct {
    /// Stable identity for a (method, pattern) pair. Handlers switch on this.
    pub const Id = enum {
        discovery,
        jobs_query,
        jobs_get_query_results,
        jobs_insert,
        jobs_get,
        jobs_list,
        datasets_insert,
        datasets_list,
        datasets_get,
        datasets_delete,
        datasets_patch,
        tables_insert,
        tables_list,
        tables_get,
        tables_delete,
        tables_patch,
        tabledata_insert_all,
        debug_stats,
    };

    id: Id,
    method: http.Method,
    /// `*` marks a capture segment; every other segment matches literally.
    pattern: []const u8,
};

/// The implemented surface. tabledata.list is not here yet; insertAll is.
pub const routes = [_]Route{
    .{ .id = .discovery, .method = .GET, .pattern = "/discovery/v1/apis/bigquery/v2/rest" },
    .{ .id = .discovery, .method = .GET, .pattern = "/$discovery/rest" },
    // Not part of the BigQuery API: per-route timing for this process.
    .{ .id = .debug_stats, .method = .GET, .pattern = "/debug/stats" },
    .{ .id = .jobs_query, .method = .POST, .pattern = "/projects/*/queries" },
    .{ .id = .jobs_get_query_results, .method = .GET, .pattern = "/projects/*/queries/*" },
    .{ .id = .jobs_insert, .method = .POST, .pattern = "/projects/*/jobs" },
    .{ .id = .jobs_list, .method = .GET, .pattern = "/projects/*/jobs" },
    .{ .id = .jobs_get, .method = .GET, .pattern = "/projects/*/jobs/*" },

    .{ .id = .datasets_insert, .method = .POST, .pattern = "/projects/*/datasets" },
    .{ .id = .datasets_list, .method = .GET, .pattern = "/projects/*/datasets" },
    .{ .id = .datasets_get, .method = .GET, .pattern = "/projects/*/datasets/*" },
    .{ .id = .datasets_delete, .method = .DELETE, .pattern = "/projects/*/datasets/*" },
    .{ .id = .datasets_patch, .method = .PATCH, .pattern = "/projects/*/datasets/*" },

    .{ .id = .tables_insert, .method = .POST, .pattern = "/projects/*/datasets/*/tables" },
    .{ .id = .tables_list, .method = .GET, .pattern = "/projects/*/datasets/*/tables" },
    .{ .id = .tables_get, .method = .GET, .pattern = "/projects/*/datasets/*/tables/*" },
    .{ .id = .tables_delete, .method = .DELETE, .pattern = "/projects/*/datasets/*/tables/*" },
    .{ .id = .tables_patch, .method = .PATCH, .pattern = "/projects/*/datasets/*/tables/*" },

    .{
        .id = .tabledata_insert_all,
        .method = .POST,
        .pattern = "/projects/*/datasets/*/tables/*/insertAll",
    },
};

/// Go registers every handler twice: bare, and under `/bigquery/v2`
/// (server.go:92-97). Clients configured with an `api_endpoint` use the
/// prefixed form.
const api_prefix = "/bigquery/v2";

pub const Outcome = union(enum) {
    matched: Match,
    /// Path matched some route but not with this method.
    method_not_allowed,
    not_found,
};

pub fn match(method: http.Method, path: []const u8) Outcome {
    const p = if (std.mem.startsWith(u8, path, api_prefix))
        path[api_prefix.len..]
    else
        path;

    var path_matched = false;
    for (routes) |route| {
        var captures: Captures = .{};
        if (!matchPattern(route.pattern, p, &captures)) continue;
        path_matched = true;
        if (route.method == method) return .{
            .matched = .{ .route = route.id, .captures = captures },
        };
    }
    return if (path_matched) .method_not_allowed else .not_found;
}

fn matchPattern(pattern: []const u8, path: []const u8, captures: *Captures) bool {
    var pat_it = std.mem.splitScalar(u8, pattern, '/');
    var path_it = std.mem.splitScalar(u8, path, '/');

    while (true) {
        const pat = pat_it.next();
        const seg = path_it.next();
        if (pat == null and seg == null) return true;
        if (pat == null or seg == null) return false;

        if (pat.?.len == 1 and pat.?[0] == '*') {
            // A capture must not match an empty segment; `/projects//queries`
            // is not a valid project id.
            if (seg.?.len == 0) return false;
            if (captures.len >= max_captures) return false;
            captures.items[captures.len] = seg.?;
            captures.len += 1;
            continue;
        }
        if (!std.mem.eql(u8, pat.?, seg.?)) return false;
    }
}

const testing = std.testing;

test "captures bind positionally regardless of discovery-doc spelling" {
    const out = match(.POST, "/projects/my-project/queries");
    try testing.expectEqual(Route.Id.jobs_query, out.matched.route);
    try testing.expectEqual(@as(usize, 1), out.matched.captures.len);
    try testing.expectEqualStrings("my-project", out.matched.captures.get(0));
}

test "two captures in path order" {
    const out = match(.GET, "/projects/p1/queries/job-abc");
    try testing.expectEqual(Route.Id.jobs_get_query_results, out.matched.route);
    try testing.expectEqualStrings("p1", out.matched.captures.get(0));
    try testing.expectEqualStrings("job-abc", out.matched.captures.get(1));
}

test "every route is reachable under the /bigquery/v2 prefix too" {
    const bare = match(.POST, "/projects/p/queries");
    const prefixed = match(.POST, "/bigquery/v2/projects/p/queries");
    try testing.expectEqual(bare.matched.route, prefixed.matched.route);
    try testing.expectEqualStrings("p", prefixed.matched.captures.get(0));

    const d = match(.GET, "/bigquery/v2/discovery/v1/apis/bigquery/v2/rest");
    try testing.expectEqual(Route.Id.discovery, d.matched.route);
}

test "same path, different methods, different routes" {
    try testing.expectEqual(Route.Id.jobs_insert, match(.POST, "/projects/p/jobs").matched.route);
    try testing.expectEqual(Route.Id.jobs_list, match(.GET, "/projects/p/jobs").matched.route);
}

test "unmatched method on a known path is not a 404" {
    try testing.expectEqual(Outcome.method_not_allowed, match(.DELETE, "/projects/p/queries"));
    try testing.expectEqual(Outcome.not_found, match(.GET, "/no/such/path"));
}

test "captures reject empty segments and extra depth" {
    try testing.expectEqual(Outcome.not_found, match(.POST, "/projects//queries"));
    try testing.expectEqual(Outcome.not_found, match(.POST, "/projects/p"));
    try testing.expectEqual(Outcome.not_found, match(.GET, "/projects/p/queries/job/extra"));

    // Not a 404: /projects/*/queries/* is a real route, just a GET one.
    try testing.expectEqual(
        Outcome.method_not_allowed,
        match(.POST, "/projects/p/queries/extra"),
    );
}

test "trailing slash does not match" {
    // gorilla/mux is strict by default; a trailing slash is a different path.
    try testing.expectEqual(Outcome.not_found, match(.POST, "/projects/p/queries/"));
}

test "insertAll sits under the table path and captures three ids" {
    const out = match(.POST, "/projects/p/datasets/ds/tables/t/insertAll");
    try testing.expectEqual(Route.Id.tabledata_insert_all, out.matched.route);
    try testing.expectEqualStrings("p", out.matched.captures.get(0));
    try testing.expectEqualStrings("ds", out.matched.captures.get(1));
    try testing.expectEqualStrings("t", out.matched.captures.get(2));

    // A table literally named insertAll is still a table GET, not an insert.
    try testing.expectEqual(
        Route.Id.tables_get,
        match(.GET, "/projects/p/datasets/ds/tables/insertAll").matched.route,
    );
}

test "all declared routes match their own patterns" {
    // Guards against a pattern that can never be reached.
    for (routes) |route| {
        var buf: [128]u8 = undefined;
        var len: usize = 0;
        var it = std.mem.splitScalar(u8, route.pattern, '/');
        var first = true;
        while (it.next()) |seg| {
            if (first) {
                first = false;
                continue;
            }
            buf[len] = '/';
            len += 1;
            const concrete = if (seg.len == 1 and seg[0] == '*') "x" else seg;
            @memcpy(buf[len..][0..concrete.len], concrete);
            len += concrete.len;
        }
        const out = match(route.method, buf[0..len]);
        try testing.expect(out == .matched);
    }
}
