//! Port of bigquery-emulator server/handler.go datasets{Insert,Get,List,Delete}.
//!
//! Response shapes captured from a running Go emulator. Note the emulator is
//! deliberately sparse here: datasets.get returns only `datasetReference`,
//! while insert and list also carry `id`.

const std = @import("std");
const errors = @import("../error.zig");

/// `{"datasetReference":{"datasetId":..,"projectId":..},"id":..}`
pub fn writeDataset(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_id: []const u8,
    dataset_id: []const u8,
    include_id: bool,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "{\"datasetReference\":{\"datasetId\":");
    try errors.writeJsonString(arena, out, dataset_id);
    try out.appendSlice(arena, ",\"projectId\":");
    try errors.writeJsonString(arena, out, project_id);
    try out.append(arena, '}');
    if (include_id) {
        try out.appendSlice(arena, ",\"id\":");
        try errors.writeJsonString(arena, out, dataset_id);
    }
    try out.append(arena, '}');
}

pub fn writeDatasetList(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    project_id: []const u8,
    dataset_ids: []const []const u8,
) std.mem.Allocator.Error!void {
    try out.appendSlice(arena, "{\"datasets\":[");
    for (dataset_ids, 0..) |id, i| {
        if (i > 0) try out.append(arena, ',');
        try writeDataset(arena, out, project_id, id, true);
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
    try writeDataset(arena, &out, "test", "ds1", true);
    try testing.expectEqualStrings(
        \\{"datasetReference":{"datasetId":"ds1","projectId":"test"},"id":"ds1"}
    , out.items);

    // datasets.get omits id.
    var got: std.ArrayList(u8) = .empty;
    try writeDataset(arena, &got, "test", "ds1", false);
    try testing.expectEqualStrings(
        \\{"datasetReference":{"datasetId":"ds1","projectId":"test"}}
    , got.items);
}

test "dataset list matches the Go emulator" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try writeDatasetList(arena, &out, "test", &.{"ds1"});
    try testing.expectEqualStrings(
        \\{"datasets":[{"datasetReference":{"datasetId":"ds1","projectId":"test"},"id":"ds1"}]}
    , out.items);

    var empty: std.ArrayList(u8) = .empty;
    try writeDatasetList(arena, &empty, "test", &.{});
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

    for ([_][]const u8{ "{}", \\{"datasetReference":{}}
    }) |body| {
        const bad = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
        try testing.expectEqual(@as(?[]const u8, null), datasetIdFromBody(bad));
    }
}
