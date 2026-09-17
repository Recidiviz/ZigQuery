//! Port of bigquery-emulator server/handler.go datasets{Insert,Get,List,Delete}.
//!
//! Response shapes captured from a running Go emulator. A dataset's resource is what was posted
//! to insert with patches merged over it (`writeDatasetResource`), stored on its catalog spec and
//! reported back verbatim by get and list; `writeDataset` builds the minimal resource for a
//! dataset declared without one (the `--dataset` flag, a loader fixture).

const std = @import("std");
const errors = @import("../error.zig");
const tables = @import("tables.zig");

/// `{"datasetReference":{"datasetId":..,"projectId":..},"id":..}`
pub fn writeDataset(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_id: []const u8,
    dataset_id: []const u8,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "{\"datasetReference\":{\"datasetId\":");
    try errors.writeJsonString(arena, out, dataset_id);
    try out.appendSlice(arena, ",\"projectId\":");
    try errors.writeJsonString(arena, out, project_id);
    try out.appendSlice(arena, "},\"id\":");
    try errors.writeJsonString(arena, out, dataset_id);
    try out.append(arena, '}');
}

/// The resource `fields` describe, with `datasetReference` and `id` set from the request path
/// whatever `fields` says. Keys come out sorted, as `tables.writeJsonValue` writes them.
pub fn writeDatasetResource(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_id: []const u8,
    dataset_id: []const u8,
    fields: std.json.ObjectMap,
) std.mem.Allocator.Error!void {
    var resource = try fields.clone(arena);
    var ref: std.json.ObjectMap = .empty;
    try ref.put(arena, "datasetId", .{ .string = dataset_id });
    try ref.put(arena, "projectId", .{ .string = project_id });
    try resource.put(arena, "datasetReference", .{ .object = ref });
    try resource.put(arena, "id", .{ .string = dataset_id });
    try tables.writeJsonValue(arena, out, .{ .object = resource });
}

/// `{"datasets":[<resource>,...]}`, each resource appended as stored.
pub fn writeDatasetList(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    resources: []const []const u8,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "{\"datasets\":[");
    for (resources, 0..) |resource, i| {
        if (i > 0) try out.append(arena, ',');
        try out.appendSlice(arena, resource);
    }
    try out.appendSlice(arena, "]}");
}

/// Pulls `datasetReference.datasetId` out of a datasets.insert body.
pub fn datasetIdFromBody(root: std.json.Value) ?[]const u8 {
    if (root != .object) return null;
    const ref = root.object.get("datasetReference") orelse return null;
    if (ref != .object) return null;
    const id = ref.object.get("datasetId") orelse return null;
    if (id != .string) return null;
    return id.string;
}

const testing = std.testing;

test "dataset resource matches the Go emulator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeDataset(arena, &out, "test", "ds1");
    try testing.expectEqualStrings(
        \\{"datasetReference":{"datasetId":"ds1","projectId":"test"},"id":"ds1"}
    , out.items);
}

test "dataset list matches the Go emulator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ds1: std.ArrayList(u8) = .empty;
    try writeDataset(arena, &ds1, "test", "ds1");
    var out: std.ArrayList(u8) = .empty;
    try writeDatasetList(arena, &out, &.{ds1.items});
    try testing.expectEqualStrings(
        \\{"datasets":[{"datasetReference":{"datasetId":"ds1","projectId":"test"},"id":"ds1"}]}
    , out.items);

    var empty: std.ArrayList(u8) = .empty;
    try writeDatasetList(arena, &empty, &.{});
    try testing.expectEqualStrings("{\"datasets\":[]}", empty.items);
}

test "extracts datasetId from an insert body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const v = try std.json.parseFromSliceLeaky(std.json.Value, arena,
        \\{"datasetReference":{"datasetId":"ds1","projectId":"test"}}
    , .{});
    try testing.expectEqualStrings("ds1", datasetIdFromBody(v).?);

    for ([_][]const u8{
        "{}",
        \\{"datasetReference":{}}
    }) |body| {
        const bad = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        try testing.expectEqual(@as(?[]const u8, null), datasetIdFromBody(bad));
    }
}
