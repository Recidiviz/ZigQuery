//! Round-trip and shape tests for the generated BigQuery v2 JSON codecs.
//!
//! The generator rewrites `bigquery.zig` file whole, so we keep the tests separate
//!
//! These tests pin the proto3 JSON mapping expected for the REST API 64-bit integers as strings,
//! wrappers as bare values, json_name overrides, maps as objects, absent fields omitted.

const std = @import("std");
const pb = @import("bigquery.zig");
const json_pb = @import("../json_pb.zig");

const testing = std.testing;

fn render(a: std.mem.Allocator, v: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, v, .{});
}

test "the jobs.query envelope renders with totalRows as a string" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var job_ref = pb.JobReference{ .project_id = "test", .job_id = "job-1" };
    var total_rows = pb.UInt64Value{ .value = 3 };
    var job_complete = pb.BoolValue{ .value = true };
    var field = pb.TableFieldSchema{ .name = "i", .type = "INTEGER" };
    var fields = [_]*pb.TableFieldSchema{&field};
    var schema = pb.TableSchema{ .fields = &fields };

    const res = pb.QueryResponse{
        .job_reference = &job_ref,
        .schema = &schema,
        .total_rows = &total_rows,
        .job_complete = &job_complete,
    };

    // `kind`, `pageToken` and every other absent field are omitted; totalRows
    // is a string because UInt64Value is 64-bit; jobComplete is a bare bool.
    try json_pb.expectJsonEqual(
        \\{"schema":{"fields":[{"name":"i","type":"INTEGER"}]},
        \\ "jobReference":{"projectId":"test","jobId":"job-1"},
        \\ "totalRows":"3","jobComplete":true}
    , try render(a, res));
}

test "ErrorProto is the error envelope's inner object, debugInfo included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // location and debugInfo are set to "" rather than left absent, which is
    // what puts them on the wire.
    const err = pb.ErrorProto{
        .reason = "invalidQuery",
        .location = "",
        .debug_info = "",
        .message = "failed to analyze",
    };
    try testing.expectEqualStrings(
        \\{"reason":"invalidQuery","location":"","debugInfo":"","message":"failed to analyze"}
    , try render(a, err));

    // Absent is not empty.
    try testing.expectEqualStrings(
        \\{"reason":"notFound"}
    , try render(a, pb.ErrorProto{ .reason = "notFound" }));
}

test "a request renders wrappers bare, maps as objects and enums by name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var max_results = pb.UInt32Value{ .value = 10 };
    var use_legacy = pb.BoolValue{ .value = false };
    var max_bytes = pb.Int64Value{ .value = 1000000 };
    var label = pb.QueryRequest_LabelsEntry{ .key = "team", .value = "data" };
    var labels = [_]*pb.QueryRequest_LabelsEntry{&label};

    const req = pb.QueryRequest{
        .query = "SELECT 1",
        .max_results = &max_results,
        .dry_run = false,
        .use_legacy_sql = &use_legacy,
        .maximum_bytes_billed = &max_bytes,
        .labels = &labels,
        .job_creation_mode = .JOB_CREATION_REQUIRED,
    };

    // maxResults is a number (32-bit) while maximumBytesBilled is a string
    // (64-bit); labels is an object, not the array of entry messages the
    // generated representation carries.
    try json_pb.expectJsonEqual(
        \\{"query":"SELECT 1","maxResults":10,"dryRun":false,"useLegacySql":false,
        \\ "labels":{"team":"data"},"maximumBytesBilled":"1000000",
        \\ "jobCreationMode":"JOB_CREATION_REQUIRED"}
    , try render(a, req));
}

test "a proto3 optional scalar renders under its own name, not the union's" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The generator carries `optional int64 total_bytes_billed` as a
    // single-branch union field named `_total_bytes_billed`.
    const res = pb.QueryResponse{
        ._total_bytes_billed = .{ .total_bytes_billed = 42 },
    };
    try testing.expectEqualStrings(
        \\{"totalBytesBilled":"42"}
    , try render(a, res));
}

test "arbitrary JSON passes through where the proto says Struct" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // QueryParameterValue.alt_struct_values is repeated google.protobuf.Value,
    // carried as std.json.Value rather than as a generated message.
    const parsed = try json_pb.parseBody(a, "[{\"a\":1},\"x\"]");
    const v = pb.QueryParameterValue{ .alt_struct_values = parsed.array.items };
    try json_pb.expectJsonEqual(
        \\{"altStructValues":[{"a":1},"x"]}
    , try render(a, v));
}

// ---------------------------------------------------------------- round trip

/// Fills every field, so a serializer that skips one shows up as a missing key
/// rather than as a value nobody looked at.
///
/// `seed` varies per element so a repeated field's entries differ — two
/// identical map entries would collide into one JSON key and the document
/// would no longer parse.
///
/// Only compound fields bottom out at depth 0; scalars are always filled, which
/// keeps a map entry's key non-null however deep it sits. Depth is what
/// terminates the self-recursive shapes, TableFieldSchema.fields being
/// []*TableFieldSchema.
fn isCompound(comptime T: type) bool {
    if (T == std.json.Value) return false;
    return switch (@typeInfo(T)) {
        .@"struct", .@"union" => true,
        .pointer => |i| i.size == .one or i.child != u8,
        else => false,
    };
}

fn populate(
    comptime T: type,
    a: std.mem.Allocator,
    depth: u8,
    seed: u8,
) std.mem.Allocator.Error!T {
    if (T == std.json.Value) return .{ .string = "j" };
    switch (@typeInfo(T)) {
        .bool => return true,
        .int => return @intCast(seed % 90 + 7),
        .float => return 1.5,
        .optional => |i| {
            if (!isCompound(i.child)) return try populate(i.child, a, depth, seed);
            if (depth == 0) return null;
            return try populate(i.child, a, depth - 1, seed);
        },
        .pointer => |i| switch (i.size) {
            .one => {
                const p = try a.create(i.child);
                p.* = try populate(i.child, a, depth, seed);
                return p;
            },
            .slice => {
                if (i.child == u8) return try std.fmt.allocPrint(a, "s{d}", .{seed});
                if (depth == 0) return &.{};
                const items = try a.alloc(i.child, 2);
                for (items, 0..) |*it, k| {
                    it.* = try populate(i.child, a, depth - 1, seed *% 3 +% @as(u8, @intCast(k)) +% 1);
                }
                return items;
            },
            else => @compileError("unsupported pointer " ++ @typeName(T)),
        },
        .@"enum" => |i| return @field(T, i.fields[i.fields.len - 1].name),
        .@"union" => |i| {
            // One branch is all a oneof can carry.
            return @unionInit(T, i.fields[0].name, try populate(i.fields[0].type, a, depth, seed));
        },
        .@"struct" => |i| {
            var v: T = .{};
            inline for (i.fields, 0..) |f, k| {
                @field(v, f.name) = try populate(f.type, a, depth, seed +% @as(u8, @intCast(k)) +% 1);
            }
            return v;
        },
        else => @compileError("unsupported " ++ @typeName(T)),
    }
}

/// Re-serializing the decode has to reproduce the bytes exactly. A field the
/// encoder skips and the decoder ignores would survive that on its own, so the
/// key count is checked against the field count too.
fn roundTrip(comptime T: type, a: std.mem.Allocator) !void {
    const original = try populate(T, a, 4, 1);
    const first = try render(a, original);

    const parsed = json_pb.parseBody(a, first) catch |err| {
        std.debug.print("{s}: encoder produced invalid JSON: {s}\n", .{ @typeName(T), first });
        return err;
    };
    const decoded = T.jsonDecode(a, parsed, .{ .mode = .strict }) catch |err| {
        std.debug.print("{s}: strict decode failed on {s}\n", .{ @typeName(T), first });
        return err;
    };
    const second = try render(a, decoded.*);

    if (!std.mem.eql(u8, first, second)) {
        std.debug.print("{s} round trip\n  in:  {s}\n  out: {s}\n", .{
            @typeName(T),
            first,
            second,
        });
        return error.TestExpectedEqual;
    }

    // Wrappers render as a bare value, so there is no object to count.
    if (parsed != .object) return;
    const want = @typeInfo(T).@"struct".fields.len;
    if (parsed.object.count() != want) {
        std.debug.print("{s}: {d} keys for {d} fields — {s}\n", .{
            @typeName(T),
            parsed.object.count(),
            want,
            first,
        });
        return error.TestExpectedEqual;
    }
}

test "every message in the closure round-trips under strict mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var checked: usize = 0;
    inline for (@typeInfo(pb).@"struct".decls) |decl| {
        const T = @field(pb, decl.name);
        if (@TypeOf(T) == type and @typeInfo(T) == .@"struct" and @hasDecl(T, "jsonDecode")) {
            try roundTrip(T, a);
            checked += 1;
        }
    }
    // Every message the generator reported, so a pruning change that silently
    // drops one is a failure here rather than a smaller file nobody noticed.
    try testing.expectEqual(@as(usize, 166), checked);
}
