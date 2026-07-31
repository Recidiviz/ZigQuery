//! Port of bigquery-emulator server/handler.go tables{Insert,Get,List,Delete,Patch}.
//!
//! Go stores the posted table body as a raw map so unknown fields survive a
//! round trip, then decorates it with server-side fields (kind, id, selfLink,
//! creationTime, lastModifiedTime, type). The same approach is used here: the
//! client's JSON is re-emitted with those fields merged in, rather than being
//! parsed into a fixed struct.
//!
//! Response shapes captured from a running Go emulator.

const std = @import("std");
const errors = @import("../error.zig");

pub const TableMeta = struct {
    project_id: []const u8,
    dataset_id: []const u8,
    table_id: []const u8,
    endpoint: []const u8,
    /// Milliseconds, as Go reports them.
    created_millis: i64,
    /// Client-supplied `schema` node, re-emitted verbatim when present.
    schema: ?std.json.Value = null,
    /// "TABLE" or "VIEW".
    kind: []const u8 = "TABLE",
    /// The body the client posted. Every key it carries that the server does
    /// not compute — `clustering`, `labels`, `timePartitioning`, `view`, and
    /// whatever a future client sends — survives into the resource, because Go
    /// stores the posted map rather than a struct.
    posted: ?std.json.Value = null,
};

/// The keys tables.list echoes, from Go's TableListTables. Everything else in
/// the stored resource (schema, selfLink, view, ...) is dropped.
const list_entry_keys = [_][]const u8{
    "clustering",
    "expirationTime",
    "friendlyName",
    "labels",
    "rangePartitioning",
    "timePartitioning",
};

/// Full table resource, as returned by tables.insert and tables.get.
///
/// Key order is alphabetical: Go stores this as a map and encoding/json sorts
/// map keys, so `creationTime, id, kind, lastModifiedTime, schema, selfLink,
/// tableReference, type` is what a client sees — and any posted key lands in
/// its alphabetical place among them.
pub fn writeTable(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    m: TableMeta,
) !void {
    var obj = try baseResource(arena, m, null);

    const ts = try std.fmt.allocPrint(arena, "{d}", .{m.created_millis});
    try obj.put(arena, "lastModifiedTime", .{ .string = ts });
    try obj.put(arena, "selfLink", .{ .string = try std.fmt.allocPrint(
        arena,
        "http://{s}/bigquery/v2/projects/{s}/datasets/{s}/tables/{s}",
        .{ m.endpoint, m.project_id, m.dataset_id, m.table_id },
    ) });
    if (m.schema) |s| try obj.put(arena, "schema", s);

    try writeJsonValue(arena, out, .{ .object = obj });
}

/// The abbreviated form tables.list returns: no schema, no selfLink,
/// no lastModifiedTime.
pub fn writeTableListEntry(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    m: TableMeta,
) !void {
    const obj = try baseResource(arena, m, &list_entry_keys);
    try writeJsonValue(arena, out, .{ .object = obj });
}

/// Keys the emulator always computes, whatever the client posted.
fn isServerComputedKey(k: []const u8) bool {
    const computed = [_][]const u8{
        "creationTime",   "id",         "kind",   "lastModifiedTime",
        "selfLink",       "schema",     "type",   "tableReference",
    };
    for (computed) |c| {
        if (std.mem.eql(u8, k, c)) return true;
    }
    return false;
}

/// The posted body with the fields the server owns written over it. When
/// `keep` is non-null, only those posted keys are carried through — that is
/// how tables.list narrows the resource to Go's TableListTables.
fn baseResource(
    arena: std.mem.Allocator,
    m: TableMeta,
    keep: ?[]const []const u8,
) !std.json.ObjectMap {
    var obj: std.json.ObjectMap = .empty;
    if (m.posted) |p| {
        if (p == .object) {
            var it = p.object.iterator();
            while (it.next()) |kv| {
                const k = kv.key_ptr.*;
                // tableReference is re-derived, and a stale creationTime or
                // selfLink read back out of storage must not win.
                if (isServerComputedKey(k)) continue;
                if (keep) |allowed| {
                    for (allowed) |a| {
                        if (std.mem.eql(u8, k, a)) break;
                    } else continue;
                }
                try obj.put(arena, k, kv.value_ptr.*);
            }
        }
    }

    const ts = try std.fmt.allocPrint(arena, "{d}", .{m.created_millis});
    try obj.put(arena, "creationTime", .{ .string = ts });
    try obj.put(arena, "id", .{ .string = try std.fmt.allocPrint(
        arena,
        "{s}:{s}.{s}",
        .{ m.project_id, m.dataset_id, m.table_id },
    ) });
    try obj.put(arena, "kind", .{ .string = "bigquery#table" });

    var ref: std.json.ObjectMap = .empty;
    try ref.put(arena, "datasetId", .{ .string = m.dataset_id });
    try ref.put(arena, "projectId", .{ .string = m.project_id });
    try ref.put(arena, "tableId", .{ .string = m.table_id });
    try obj.put(arena, "tableReference", .{ .object = ref });

    try obj.put(arena, "type", .{ .string = m.kind });
    return obj;
}

/// Re-emits a parsed JSON value. Object keys are sorted, matching Go's
/// encoding/json for maps — which is what the emulator stores table metadata
/// as.
pub fn writeJsonValue(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    v: std.json.Value,
) std.mem.Allocator.Error!void {
    switch (v) {
        .null => try out.appendSlice(arena, "null"),
        .bool => |b| try out.appendSlice(arena, if (b) "true" else "false"),
        .integer => |i| try out.print(arena, "{d}", .{i}),
        .float => |f| try out.print(arena, "{d}", .{f}),
        .number_string => |s| try out.appendSlice(arena, s),
        .string => |s| try errors.writeJsonString(arena, out, s),
        .array => |items| {
            try out.append(arena, '[');
            for (items.items, 0..) |item, i| {
                if (i > 0) try out.append(arena, ',');
                try writeJsonValue(arena, out, item);
            }
            try out.append(arena, ']');
        },
        .object => |obj| {
            const keys = try arena.alloc([]const u8, obj.count());
            var it = obj.iterator();
            var n: usize = 0;
            while (it.next()) |kv| : (n += 1) keys[n] = kv.key_ptr.*;
            std.mem.sort([]const u8, keys, {}, struct {
                fn lt(_: void, a: []const u8, b: []const u8) bool {
                    return std.mem.order(u8, a, b) == .lt;
                }
            }.lt);

            try out.append(arena, '{');
            for (keys, 0..) |k, i| {
                if (i > 0) try out.append(arena, ',');
                try errors.writeJsonString(arena, out, k);
                try out.append(arena, ':');
                try writeJsonValue(arena, out, obj.get(k).?);
            }
            try out.append(arena, '}');
        },
    }
}

/// Pulls `tableReference.tableId` out of a tables.insert body.
pub fn tableIdFromBody(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const ref = root.object.get("tableReference") orelse return null;
    if (ref != .object) return null;
    const id = ref.object.get("tableId") orelse return null;
    if (id != .string) return null;
    return id.string;
}

/// The `view.query` of a view definition, when the body describes one.
pub fn viewQueryFromBody(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const view = root.object.get("view") orelse return null;
    if (view != .object) return null;
    const q = view.object.get("query") orelse return null;
    if (q != .string) return null;
    return q.string;
}

const testing = std.testing;

test "table resource matches the Go emulator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const schema = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"fields":[{"name":"a","type":"INTEGER"},{"mode":"REPEATED","name":"b","type":"STRING"}]}
    , .{});

    var out: std.ArrayList(u8) = .empty;
    try writeTable(arena, &out, .{
        .project_id = "test",
        .dataset_id = "ds1",
        .table_id = "t1",
        .endpoint = "0.0.0.0:19051",
        .created_millis = 1785016140253,
        .schema = schema,
    });

    try testing.expectEqualStrings(
        \\{"creationTime":"1785016140253","id":"test:ds1.t1","kind":"bigquery#table","lastModifiedTime":"1785016140253","schema":{"fields":[{"name":"a","type":"INTEGER"},{"mode":"REPEATED","name":"b","type":"STRING"}]},"selfLink":"http://0.0.0.0:19051/bigquery/v2/projects/test/datasets/ds1/tables/t1","tableReference":{"datasetId":"ds1","projectId":"test","tableId":"t1"},"type":"TABLE"}
    , out.items);
}

test "table list entry is the abbreviated form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeTableListEntry(arena, &out, .{
        .project_id = "test",
        .dataset_id = "ds1",
        .table_id = "t1",
        .endpoint = "h:1",
        .created_millis = 1785016140253,
    });
    try testing.expectEqualStrings(
        \\{"creationTime":"1785016140253","id":"test:ds1.t1","kind":"bigquery#table","tableReference":{"datasetId":"ds1","projectId":"test","tableId":"t1"},"type":"TABLE"}
    , out.items);
}

test "json re-emission sorts object keys, as Go does for maps" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"z":1,"a":{"y":[true,null,"s"],"b":2.5}}
    , .{});
    var out: std.ArrayList(u8) = .empty;
    try writeJsonValue(arena, &out, v);
    try testing.expectEqualStrings(
        \\{"a":{"b":2.5,"y":[true,null,"s"]},"z":1}
    , out.items);
}

test "extracts table id and view query from bodies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const t = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"tableReference":{"projectId":"p","datasetId":"d","tableId":"t1"}}
    , .{});
    try testing.expectEqualStrings("t1", tableIdFromBody(t).?);
    try testing.expectEqual(@as(?[]const u8, null), viewQueryFromBody(t));

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"tableReference":{"tableId":"v1"},"view":{"query":"SELECT 1","useLegacySql":false}}
    , .{});
    try testing.expectEqualStrings("SELECT 1", viewQueryFromBody(v).?);
}
