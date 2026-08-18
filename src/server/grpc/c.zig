//! Adaptation layer over `cgrpc`, the translate-c of grpc/grpc.h,
//! grpc/credentials.h and grpc/byte_buffer_reader.h.
//!
//! Everything here exists because translate-c produces C, not Zig:
//!
//! - `GRPC_SLICE_START_PTR` and `GRPC_SLICE_LENGTH` are function-like macros
//!   over a `?:` on a member expression (include/grpc/impl/slice_type.h:98,
//!   101). translate-c drops macros, so the union is read by hand below. This
//!   is the one piece of C semantics this repo reimplements rather than calls,
//!   which is why it is the most heavily tested thing in the file.
//!
//! - The op/status/completion constants come out as `c_int` while the fields
//!   that take them are typedef'd to `c_uint`, so every use would need an
//!   `@intCast`. They are wrapped as real Zig enums once, here, rather than
//!   cast at thirty call sites.
//!
//! Nothing above this file should mention `cgrpc` directly.

const std = @import("std");

pub const c = @import("cgrpc");

/// The bytes a `grpc_slice` denotes.
///
/// Takes a pointer, not a value. A slice short enough to be inlined stores its
/// bytes in a fixed array *inside* the struct (23 of them on a 64-bit target),
/// so a by-value parameter would hand back a slice into the callee's copy of
/// that array — a dangling pointer the moment this function returns. Callers
/// pass `&details.method`, which lives in the per-call state for the life of
/// the call.
pub fn sliceBytes(s: *const c.grpc_slice) []const u8 {
    if (s.refcount != null) {
        return s.data.refcounted.bytes[0..s.data.refcounted.length];
    }
    return s.data.inlined.bytes[0..s.data.inlined.length];
}

/// The subset of grpc_op_type this server sends. Deliberately not exhaustive:
/// an op that is not listed is one nothing here knows how to fill in.
pub const OpType = enum(c.grpc_op_type) {
    send_initial_metadata = @intCast(c.GRPC_OP_SEND_INITIAL_METADATA),
    send_message = @intCast(c.GRPC_OP_SEND_MESSAGE),
    send_close_from_client = @intCast(c.GRPC_OP_SEND_CLOSE_FROM_CLIENT),
    send_status_from_server = @intCast(c.GRPC_OP_SEND_STATUS_FROM_SERVER),
    recv_initial_metadata = @intCast(c.GRPC_OP_RECV_INITIAL_METADATA),
    recv_message = @intCast(c.GRPC_OP_RECV_MESSAGE),
    recv_status_on_client = @intCast(c.GRPC_OP_RECV_STATUS_ON_CLIENT),
    recv_close_on_server = @intCast(c.GRPC_OP_RECV_CLOSE_ON_SERVER),
};

/// Non-exhaustive: a status this server never sends can still arrive on the
/// client side of the smoke harness.
pub const Status = enum(c.grpc_status_code) {
    ok = @intCast(c.GRPC_STATUS_OK),
    invalid_argument = @intCast(c.GRPC_STATUS_INVALID_ARGUMENT),
    not_found = @intCast(c.GRPC_STATUS_NOT_FOUND),
    unimplemented = @intCast(c.GRPC_STATUS_UNIMPLEMENTED),
    internal = @intCast(c.GRPC_STATUS_INTERNAL),
    unavailable = @intCast(c.GRPC_STATUS_UNAVAILABLE),
    _,
};

pub const Completion = enum { shutdown, timeout, op_complete };

pub fn completion(ev: c.grpc_event) Completion {
    if (ev.type == c.GRPC_QUEUE_SHUTDOWN) return .shutdown;
    if (ev.type == c.GRPC_QUEUE_TIMEOUT) return .timeout;
    return .op_complete;
}

/// `gpr_inf_future` is a real function, not a macro — this only hides the clock-type cast.
pub fn infFuture() c.gpr_timespec {
    return c.gpr_inf_future(c.GPR_CLOCK_REALTIME);
}

pub fn callOk(err: c.grpc_call_error) bool {
    return err == c.GRPC_CALL_OK;
}

const testing = std.testing;

// The two tests below are the whole reason this file is not just `@import`.
// `sliceBytes` replaces a C macro, so nothing but a test pins it, and the two
// branches are selected by a field the caller never sets explicitly.

test "sliceBytes reads a slice short enough to be inlined" {
    // 5 bytes: under the 23-byte inline threshold, so refcount stays null and
    // the bytes live in the struct itself.
    const s = c.grpc_slice_from_copied_buffer("short", 5);
    defer c.grpc_slice_unref(s);

    try testing.expect(s.refcount == null);
    try testing.expectEqualStrings("short", sliceBytes(&s));
}

test "sliceBytes reads a slice too long to be inlined" {
    // 40 bytes: over the threshold, so the bytes are refcounted and out of
    // line. Reading this through the inlined branch would return 23 bytes of
    // pointer-and-length reinterpreted as text, which is exactly the silent
    // corruption this test exists to catch.
    const src = "0123456789012345678901234567890123456789";
    const s = c.grpc_slice_from_copied_buffer(src, src.len);
    defer c.grpc_slice_unref(s);

    try testing.expect(s.refcount != null);
    try testing.expectEqualStrings(src, sliceBytes(&s));
}

test "sliceBytes reads a zeroed slice as empty" {
    // A zeroed grpc_slice has a null refcount and an inlined length of 0, so
    // it must read as "" rather than trapping. Every op struct this server
    // builds starts zeroed, so this is the state a never-filled-in status
    // detail is in.
    const s: c.grpc_slice = std.mem.zeroes(c.grpc_slice);
    try testing.expectEqualStrings("", sliceBytes(&s));
}

test "the wrapped enums carry gRPC's own values" {
    // Guards against a translate-c or gRPC version change silently renumbering
    // the wire-visible constants. The numbers are gRPC's, not ours.
    try testing.expectEqual(@as(c.grpc_op_type, 3), @intFromEnum(OpType.send_status_from_server));
    try testing.expectEqual(@as(c.grpc_op_type, 7), @intFromEnum(OpType.recv_close_on_server));
    try testing.expectEqual(@as(c.grpc_status_code, 12), @intFromEnum(Status.unimplemented));
}

test "completion maps all three event types" {
    var ev: c.grpc_event = std.mem.zeroes(c.grpc_event);

    ev.type = c.GRPC_QUEUE_SHUTDOWN;
    try testing.expectEqual(Completion.shutdown, completion(ev));
    ev.type = c.GRPC_QUEUE_TIMEOUT;
    try testing.expectEqual(Completion.timeout, completion(ev));
    ev.type = c.GRPC_OP_COMPLETE;
    try testing.expectEqual(Completion.op_complete, completion(ev));
}
