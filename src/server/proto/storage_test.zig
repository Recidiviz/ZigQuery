//! Round-trip tests for the generated Storage Read API codecs.
//!
//! Kept beside `storage.zig` rather than inside it because that file is
//! generated and any test written there would be erased by the next
//! `zig build gen-proto`.
//!
//! What these are actually checking is the *generator*, not the descriptors.
//! `decode(encode(x)) == x` fails the moment a field number, a wire type, a
//! packed/unpacked choice or a length prefix is wrong, and every message in
//! storage.zig is emitted by the same few code paths — so exercising one
//! message per shape covers all 113 of them.

const std = @import("std");
const pb = @import("storage.zig");

const testing = std.testing;

/// `decode(encode(x))`, arena-allocated so the borrowed string slices in the
/// result stay valid for the caller.
fn roundTrip(comptime T: type, a: std.mem.Allocator, msg: *const T) !*T {
    const bytes = try msg.encode(a);
    return T.decode(a, bytes);
}

test "a scalar-only message round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const in: pb.ReadStream = .{ .name = "projects/p/locations/l/sessions/s/streams/0" };
    const out = try roundTrip(pb.ReadStream, a, &in);
    try testing.expectEqualStrings(in.name.?, out.name.?);
}

test "an absent field stays absent through a round trip" {
    // The reason every singular field is `?T`: proto3 cannot distinguish an
    // unset field from one set to its default, but this codec can, and encode
    // writes nothing for null. A `0` here instead of null would mean the
    // emulator started echoing fields the client never sent.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const in: pb.ReadRowsRequest = .{ .read_stream = "s" };
    const out = try roundTrip(pb.ReadRowsRequest, a, &in);
    try testing.expectEqualStrings("s", out.read_stream.?);
    try testing.expectEqual(@as(?i64, null), out.offset);

    // And a field explicitly set to zero survives as zero, not as absent.
    const zeroed: pb.ReadRowsRequest = .{ .read_stream = "s", .offset = 0 };
    const zout = try roundTrip(pb.ReadRowsRequest, a, &zeroed);
    try testing.expectEqual(@as(?i64, 0), zout.offset);
}

test "nested messages and repeated messages round-trip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var f0: pb.TableFieldSchema = .{
        .name = "id",
        .type = .INT64,
        .mode = .REQUIRED,
    };
    var f1: pb.TableFieldSchema = .{
        .name = "tags",
        .type = .STRING,
        .mode = .REPEATED,
        .description = "a string with a \"quote\" and a \x00 nul",
    };
    // A `var` array, not `&.{…}`: the generator emits repeated fields as `[]T`
    // rather than `[]const T`, so a const literal will not coerce.
    var fields = [_]*pb.TableFieldSchema{ &f0, &f1 };
    var schema: pb.TableSchema = .{ .fields = &fields };

    const out = try roundTrip(pb.TableSchema, a, &schema);
    try testing.expectEqual(@as(usize, 2), out.fields.len);
    try testing.expectEqualStrings("id", out.fields[0].name.?);
    try testing.expectEqual(pb.TableFieldSchema_Type.INT64, out.fields[0].type.?);
    try testing.expectEqual(pb.TableFieldSchema_Mode.REQUIRED, out.fields[0].mode.?);
    try testing.expectEqualStrings("tags", out.fields[1].name.?);
    try testing.expectEqual(pb.TableFieldSchema_Mode.REPEATED, out.fields[1].mode.?);
    try testing.expectEqualStrings(f1.description.?, out.fields[1].description.?);
}

test "a oneof round-trips as the branch that was set" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // ReadRowsResponse carries its payload in a oneof: an AVRO branch and an
    // ARROW one. Picking the wrong branch back out is the single most likely
    // way for S5/S6 to go wrong, so pin both directions.
    var avro: pb.AvroRows = .{ .serialized_binary_rows = "\x00\x01\x02", .row_count = 3 };
    const in: pb.ReadRowsResponse = .{ .rows = .{ .avro_rows = &avro } };
    const out = try roundTrip(pb.ReadRowsResponse, a, &in);

    try testing.expect(out.rows != null);
    switch (out.rows.?) {
        .avro_rows => |v| {
            try testing.expectEqualSlices(u8, "\x00\x01\x02", v.serialized_binary_rows.?);
            try testing.expectEqual(@as(?i64, 3), v.row_count);
        },
        else => return error.WrongOneofBranch,
    }

    var batch: pb.ArrowRecordBatch = .{ .serialized_record_batch = "\xff\xfe" };
    const in2: pb.ReadRowsResponse = .{ .rows = .{ .arrow_record_batch = &batch } };
    const out2 = try roundTrip(pb.ReadRowsResponse, a, &in2);
    switch (out2.rows.?) {
        .arrow_record_batch => |v| {
            try testing.expectEqualSlices(u8, "\xff\xfe", v.serialized_record_batch.?);
        },
        else => return error.WrongOneofBranch,
    }
}

test "a fully-populated ReadSession round-trips" {
    // The plan's stated S2 gate: one big message with every shape at once —
    // scalars, an enum, nested messages, a repeated message, and a oneof.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var avro_schema: pb.AvroSchema = .{ .schema = "{\"type\":\"record\"}" };
    var stream0: pb.ReadStream = .{ .name = "…/streams/0" };
    var streams = [_]*pb.ReadStream{&stream0};
    var expire: pb.Timestamp = .{ .seconds = 1767268800, .nanos = 123456789 };
    var selected = [_][]const u8{ "a", "b" };
    var opts: pb.ReadSession_TableReadOptions = .{
        .selected_fields = &selected,
        .row_restriction = "id > 10",
    };

    const in: pb.ReadSession = .{
        .name = "projects/p/locations/us/sessions/abc",
        .expire_time = &expire,
        .data_format = .AVRO,
        .schema = .{ .avro_schema = &avro_schema },
        .table = "projects/p/datasets/d/tables/t",
        .read_options = &opts,
        .streams = &streams,
        .estimated_total_bytes_scanned = 4096,
        .trace_id = "zig",
    };

    const out = try roundTrip(pb.ReadSession, a, &in);

    try testing.expectEqualStrings(in.name.?, out.name.?);
    try testing.expectEqualStrings(in.table.?, out.table.?);
    try testing.expectEqualStrings(in.trace_id.?, out.trace_id.?);
    try testing.expectEqual(pb.DataFormat.AVRO, out.data_format.?);
    try testing.expectEqual(@as(?i64, 4096), out.estimated_total_bytes_scanned);

    // A well-known type from a different .proto file in the same fdset.
    try testing.expectEqual(@as(?i64, 1767268800), out.expire_time.?.seconds);
    try testing.expectEqual(@as(?i32, 123456789), out.expire_time.?.nanos);

    switch (out.schema.?) {
        .avro_schema => |v| try testing.expectEqualStrings(avro_schema.schema.?, v.schema.?),
        else => return error.WrongOneofBranch,
    }

    // Repeated string: the one repeated shape that is never packed.
    try testing.expectEqual(@as(usize, 2), out.read_options.?.selected_fields.len);
    try testing.expectEqualStrings("a", out.read_options.?.selected_fields[0]);
    try testing.expectEqualStrings("b", out.read_options.?.selected_fields[1]);
    try testing.expectEqualStrings("id > 10", out.read_options.?.row_restriction.?);

    try testing.expectEqual(@as(usize, 1), out.streams.len);
    try testing.expectEqualStrings(stream0.name.?, out.streams[0].name.?);
}

test "encoded bytes carry the field numbers the wire format specifies" {
    // The round trips above would still pass if encode and decode agreed on a
    // wrong field number. This checks the bytes against the .proto directly:
    // ReadStream.name is field 1, so the first tag byte is (1 << 3) | 2 = 0x0a.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const s: pb.ReadStream = .{ .name = "ab" };
    try testing.expectEqualSlices(u8, &.{ 0x0a, 0x02, 'a', 'b' }, try s.encode(a));

    // ReadRowsRequest.read_stream is 1 (len), offset is 2 (varint).
    const rr: pb.ReadRowsRequest = .{ .read_stream = "x", .offset = 300 };
    try testing.expectEqualSlices(
        u8,
        &.{ 0x0a, 0x01, 'x', 0x10, 0xac, 0x02 },
        try rr.encode(a),
    );
}

// Bytes produced by the reference implementation, not by this codec.
//
// Every test above is a round trip through *our* encoder and *our* decoder, so
// all of them would still pass if the two agreed on a wrong field number or a
// wrong wire type. This one cannot: it is what
// `google-cloud-bigquery-storage` actually put on the wire for
//
//     CreateReadSessionRequest(
//         parent="projects/test",
//         read_session=ReadSession(
//             table="projects/test/datasets/ds1/tables/t",
//             data_format=AVRO,
//             read_options=TableReadOptions(
//                 selected_fields=["a", "b"], row_restriction="id > 10"),
//         ),
//         max_stream_count=1)
//
// Regenerate with tools/storage_probe.py's dependency:
//     uv run python -c 'from google.cloud.bigquery_storage_v1.types import *; ...'
const reference_create_session_request =
    "\x0a\x0d\x70\x72\x6f\x6a\x65\x63\x74\x73\x2f\x74\x65\x73\x74" ++
    "\x12\x38\x18\x01\x32\x23\x70\x72\x6f\x6a\x65\x63\x74\x73\x2f" ++
    "\x74\x65\x73\x74\x2f\x64\x61\x74\x61\x73\x65\x74\x73\x2f\x64" ++
    "\x73\x31\x2f\x74\x61\x62\x6c\x65\x73\x2f\x74\x42\x0f\x0a\x01" ++
    "\x61\x0a\x01\x62\x12\x07\x69\x64\x20\x3e\x20\x31\x30\x18\x01";

test "bytes from the real client library decode correctly" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const req = try pb.CreateReadSessionRequest.decode(a, reference_create_session_request);

    try testing.expectEqualStrings("projects/test", req.parent.?);
    try testing.expectEqual(@as(?i32, 1), req.max_stream_count);

    const sess = req.read_session.?;
    try testing.expectEqualStrings("projects/test/datasets/ds1/tables/t", sess.table.?);
    try testing.expectEqual(pb.DataFormat.AVRO, sess.data_format.?);

    const opts = sess.read_options.?;
    try testing.expectEqual(@as(usize, 2), opts.selected_fields.len);
    try testing.expectEqualStrings("a", opts.selected_fields[0]);
    try testing.expectEqualStrings("b", opts.selected_fields[1]);
    try testing.expectEqualStrings("id > 10", opts.row_restriction.?);
}

test "re-encoding the reference bytes reproduces them exactly" {
    // Stronger than the round trips above: the output is compared against bytes
    // this codec did not produce. It holds only because encode writes fields in
    // declaration order and skips nulls, which is what protoc does here too --
    // protobuf permits any order, so a future field reordering could break this
    // without anything being wrong. If that happens, decode both sides and
    // compare values instead of deleting the test.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const req = try pb.CreateReadSessionRequest.decode(a, reference_create_session_request);
    try testing.expectEqualSlices(u8, reference_create_session_request, try req.encode(a));
}
