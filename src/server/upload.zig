//! The media upload endpoint a load job's bytes arrive through.
//!
//! Two protocols reach the same job. A multipart request carries the configuration and the
//! data as two MIME parts of one body. A resumable upload opens a session, receives the bytes
//! across as many requests as the client chooses, and runs the job when the last of them
//! lands. api-uploads

const std = @import("std");

/// Total bytes one session may accumulate. A load larger than this would not fit the
/// destination either, since the database is in memory unless a file was asked for.
pub const max_session_bytes = 256 * 1024 * 1024;

/// How long a session outlives its last request.
pub const session_ttl_ms = 60 * 60 * 1000;

pub const UploadType = enum {
    multipart,
    resumable,

    /// The `uploadType` query parameter. A request without one is multipart when it carries a
    /// multipart body, which the caller decides.
    pub fn parse(text: []const u8) ?UploadType {
        if (std.mem.eql(u8, text, "multipart")) return .multipart;
        if (std.mem.eql(u8, text, "resumable")) return .resumable;
        return null;
    }
};

pub const Error = error{
    /// The Content-Type carried no boundary, so the parts cannot be found.
    MissingBoundary,
    /// Fewer than the two parts a media upload is defined to have.
    MissingPart,
    MalformedContentRange,
    /// More bytes than `max_session_bytes`.
    TooLarge,
    /// A chunk that does not continue from what the session already holds.
    RangeMismatch,
} || std.mem.Allocator.Error;

/// The configuration and the data, in the order the parts are defined to arrive.
pub const Multipart = struct {
    metadata: []const u8,
    media: []const u8,
};

/// `multipart/related; boundary=foo_bar_baz`, quoted or bare.
pub fn boundaryFrom(content_type: []const u8) ?[]const u8 {
    const marker = "boundary=";
    const at = std.ascii.findIgnoreCase(content_type, marker) orelse return null;
    var rest = content_type[at + marker.len ..];
    if (rest.len != 0 and rest[0] == '"') {
        rest = rest[1..];
        const close = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        return rest[0..close];
    }
    const end = std.mem.indexOfAny(u8, rest, ";, \t\r\n") orelse rest.len;
    return rest[0..end];
}

/// The two parts of a multipart/related body.
pub fn parseMultipart(body: []const u8, boundary: []const u8) Error!Multipart {
    var buf: [128]u8 = undefined;
    if (boundary.len + 2 > buf.len) return error.MissingBoundary;
    const delimiter = std.fmt.bufPrint(&buf, "--{s}", .{boundary}) catch
        return error.MissingBoundary;

    var parts: [2][]const u8 = .{ "", "" };
    var found: u8 = 0;
    var pos = std.mem.indexOf(u8, body, delimiter) orelse return error.MissingPart;
    while (found < 2) {
        pos += delimiter.len;
        // The closing delimiter carries two more hyphens and ends the body.
        if (std.mem.startsWith(u8, body[pos..], "--")) break;
        const content_start = headerEnd(body, pos) orelse return error.MissingPart;
        const next = std.mem.indexOfPos(u8, body, content_start, delimiter) orelse
            return error.MissingPart;
        parts[found] = trimTrailingNewline(body[content_start..next]);
        found += 1;
        pos = next;
    }
    if (found < 2) return error.MissingPart;
    return .{ .metadata = parts[0], .media = parts[1] };
}

/// Past a part's headers, to the first byte of its content.
fn headerEnd(body: []const u8, from: usize) ?usize {
    if (std.mem.indexOfPos(u8, body, from, "\r\n\r\n")) |at| return at + 4;
    if (std.mem.indexOfPos(u8, body, from, "\n\n")) |at| return at + 2;
    return null;
}

/// The line ending that separates a part's content from the delimiter after it.
fn trimTrailingNewline(text: []const u8) []const u8 {
    var out = text;
    if (std.mem.endsWith(u8, out, "\n")) out = out[0 .. out.len - 1];
    if (std.mem.endsWith(u8, out, "\r")) out = out[0 .. out.len - 1];
    return out;
}

/// `bytes 0-524287/2000000`, or `bytes */2000000` when the client is asking how far the
/// upload got rather than adding to it. api-uploads
pub const ContentRange = struct {
    /// Null on a status query, which names no bytes.
    first: ?u64 = null,
    last: ?u64 = null,
    /// Null when the client does not yet know the total.
    total: ?u64 = null,

    pub fn isStatusQuery(r: ContentRange) bool {
        return r.first == null;
    }
};

pub fn parseContentRange(text: []const u8) Error!ContentRange {
    const prefix = "bytes ";
    if (!std.mem.startsWith(u8, text, prefix)) return error.MalformedContentRange;
    const body = std.mem.trim(u8, text[prefix.len..], " ");

    const slash = std.mem.indexOfScalar(u8, body, '/') orelse return error.MalformedContentRange;
    const span = body[0..slash];
    const total_text = body[slash + 1 ..];

    var out: ContentRange = .{};
    if (!std.mem.eql(u8, total_text, "*")) {
        out.total = std.fmt.parseInt(u64, total_text, 10) catch
            return error.MalformedContentRange;
    }
    if (std.mem.eql(u8, span, "*")) return out;

    const dash = std.mem.indexOfScalar(u8, span, '-') orelse return error.MalformedContentRange;
    out.first = std.fmt.parseInt(u64, span[0..dash], 10) catch
        return error.MalformedContentRange;
    out.last = std.fmt.parseInt(u64, span[dash + 1 ..], 10) catch
        return error.MalformedContentRange;
    return out;
}

/// A resumable upload between its requests.
pub const Session = struct {
    project_id: []const u8,
    /// The job configuration the initiating request carried.
    metadata: []const u8,
    bytes: std.ArrayList(u8),
    /// What `X-Upload-Content-Length` promised, when it was sent.
    declared_total: ?u64 = null,
    expires_at_ms: i64,

    pub fn received(s: *const Session) u64 {
        return s.bytes.items.len;
    }

    /// Whether every byte the client promised has landed.
    pub fn isComplete(s: *const Session, range: ContentRange) bool {
        const total = range.total orelse s.declared_total orelse return false;
        return s.received() >= total;
    }
};

/// What the initiating request says about the upload it opens.
pub const Opening = struct {
    project_id: []const u8,
    /// The job configuration the initiating request carried.
    metadata: []const u8,
    /// What `X-Upload-Content-Length` promised, when it was sent.
    declared_total: ?u64 = null,
};

/// One request's bytes, and where the client says they sit in the upload.
pub const Chunk = struct {
    range: ContentRange = .{},
    bytes: []const u8,
};

/// The sessions this process is part way through.
///
/// A session's bytes are freed as soon as its job runs, rather than waiting for the sweep: a
/// completed upload has no reason to hold its copy while the rows it produced live in the
/// database.
pub const SessionStore = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(*Session) = .empty,

    pub fn deinit(store: *SessionStore) void {
        var it = store.map.iterator();
        while (it.next()) |entry| store.destroy(entry.key_ptr.*, entry.value_ptr.*);
        store.map.deinit(store.gpa);
    }

    fn destroy(store: *SessionStore, id: []const u8, session: *Session) void {
        session.bytes.deinit(store.gpa);
        store.gpa.free(session.project_id);
        store.gpa.free(session.metadata);
        store.gpa.free(id);
        store.gpa.destroy(session);
    }

    pub fn create(
        store: *SessionStore,
        id: []const u8,
        opening: Opening,
        now_ms: i64,
    ) !*Session {
        const owned_id = try store.gpa.dupe(u8, id);
        errdefer store.gpa.free(owned_id);
        const session = try store.gpa.create(Session);
        errdefer store.gpa.destroy(session);
        session.* = .{
            .project_id = try store.gpa.dupe(u8, opening.project_id),
            .metadata = try store.gpa.dupe(u8, opening.metadata),
            .bytes = .empty,
            .declared_total = opening.declared_total,
            .expires_at_ms = now_ms + session_ttl_ms,
        };
        try store.map.put(store.gpa, owned_id, session);
        return session;
    }

    pub fn get(store: *SessionStore, id: []const u8) ?*Session {
        return store.map.get(id);
    }

    /// Adds a chunk, which must continue from what is already held.
    pub fn append(
        store: *SessionStore,
        session: *Session,
        chunk: Chunk,
        now_ms: i64,
    ) Error!void {
        if (chunk.range.first) |first| {
            if (first != session.received()) return error.RangeMismatch;
        }
        if (session.received() + chunk.bytes.len > max_session_bytes) return error.TooLarge;
        try session.bytes.appendSlice(store.gpa, chunk.bytes);
        session.expires_at_ms = now_ms + session_ttl_ms;
    }

    /// Releases a session once its job has run.
    pub fn finish(store: *SessionStore, id: []const u8) void {
        if (store.map.fetchRemove(id)) |entry| store.destroy(entry.key, entry.value);
    }

    /// Drops sessions a client opened and abandoned.
    pub fn sweep(store: *SessionStore, now_ms: i64) void {
        var stale: std.ArrayList([]const u8) = .empty;
        defer stale.deinit(store.gpa);
        var it = store.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.expires_at_ms <= now_ms) {
                stale.append(store.gpa, entry.key_ptr.*) catch return;
            }
        }
        for (stale.items) |id| store.finish(id);
    }
};

const testing = std.testing;

test "the boundary comes off the content type, quoted or bare" {
    try testing.expectEqualStrings(
        "foo_bar_baz",
        boundaryFrom("multipart/related; boundary=foo_bar_baz").?,
    );
    try testing.expectEqualStrings(
        "foo_bar_baz",
        boundaryFrom("multipart/related; boundary=\"foo_bar_baz\"").?,
    );
    try testing.expectEqualStrings(
        "abc",
        boundaryFrom("multipart/related; boundary=abc; charset=utf-8").?,
    );
    try testing.expect(boundaryFrom("application/json") == null);
}

test "a multipart body yields the configuration then the data" {
    const body =
        "--foo\r\n" ++
        "Content-Type: application/json; charset=UTF-8\r\n" ++
        "\r\n" ++
        "{\"configuration\":{}}\r\n" ++
        "--foo\r\n" ++
        "Content-Type: */*\r\n" ++
        "\r\n" ++
        "a,b\n1,2\n" ++
        "\r\n--foo--";

    const parts = try parseMultipart(body, "foo");
    try testing.expectEqualStrings("{\"configuration\":{}}", parts.metadata);
    try testing.expectEqualStrings("a,b\n1,2\n", parts.media);
}

test "a body with one part is not a media upload" {
    const body = "--foo\r\nContent-Type: application/json\r\n\r\n{}\r\n--foo--";
    try testing.expectError(error.MissingPart, parseMultipart(body, "foo"));
}

test "content ranges, including the status query" {
    const chunk = try parseContentRange("bytes 0-524287/2000000");
    try testing.expectEqual(@as(?u64, 0), chunk.first);
    try testing.expectEqual(@as(?u64, 524287), chunk.last);
    try testing.expectEqual(@as(?u64, 2000000), chunk.total);
    try testing.expect(!chunk.isStatusQuery());

    const unknown_total = try parseContentRange("bytes 0-99/*");
    try testing.expectEqual(@as(?u64, null), unknown_total.total);

    const query = try parseContentRange("bytes */2000000");
    try testing.expect(query.isStatusQuery());
    try testing.expectEqual(@as(?u64, 2000000), query.total);

    try testing.expectError(error.MalformedContentRange, parseContentRange("0-10/20"));
    try testing.expectError(error.MalformedContentRange, parseContentRange("bytes 0-10"));
}

const six_bytes: Opening = .{ .project_id = "p", .metadata = "{}", .declared_total = 6 };

test "a session accumulates chunks in order" {
    var store = SessionStore{ .gpa = testing.allocator };
    defer store.deinit();

    const session = try store.create("abc", six_bytes, 0);
    const first: Chunk = .{ .range = try parseContentRange("bytes 0-2/6"), .bytes = "abc" };
    try store.append(session, first, 0);
    try testing.expectEqual(@as(u64, 3), session.received());
    try testing.expect(!session.isComplete(try parseContentRange("bytes 0-2/6")));

    const second: Chunk = .{ .range = try parseContentRange("bytes 3-5/6"), .bytes = "def" };
    try store.append(session, second, 0);
    try testing.expectEqualStrings("abcdef", session.bytes.items);
    try testing.expect(session.isComplete(try parseContentRange("bytes 3-5/6")));
}

test "a chunk that does not continue the session is refused" {
    var store = SessionStore{ .gpa = testing.allocator };
    defer store.deinit();

    const session = try store.create("abc", six_bytes, 0);
    const ahead: Chunk = .{ .range = try parseContentRange("bytes 3-5/6"), .bytes = "def" };
    try testing.expectError(error.RangeMismatch, store.append(session, ahead, 0));
}

test "finishing a session releases it" {
    var store = SessionStore{ .gpa = testing.allocator };
    defer store.deinit();

    _ = try store.create("abc", .{ .project_id = "p", .metadata = "{}" }, 0);
    try testing.expect(store.get("abc") != null);
    store.finish("abc");
    try testing.expect(store.get("abc") == null);
}

test "an abandoned session is swept" {
    var store = SessionStore{ .gpa = testing.allocator };
    defer store.deinit();

    _ = try store.create("old", .{ .project_id = "p", .metadata = "{}" }, 0);
    _ = try store.create("new", .{ .project_id = "p", .metadata = "{}" }, session_ttl_ms);
    store.sweep(session_ttl_ms + 1);
    try testing.expect(store.get("old") == null);
    try testing.expect(store.get("new") != null);
}
