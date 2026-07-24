//! FFI over the Bazel-built GoogleSQL analyzer shim
//! (googlesql repo: zig/analyzer_shim.cc -> libgooglesql_shim.dylib).

const std = @import("std");
const pb = @import("proto/resolved_ast.zig");

extern fn GoogleSQL_AnalyzeNextStatement(
    sql: [*:0]const u8,
    resume_offset: *usize,
    catalog_json: [*:0]const u8,
    options_json: [*:0]const u8,
    out_proto: *?[*]u8,
    out_len: *usize,
    out_is_end: *c_int,
    out_error: *?[*:0]u8,
) c_int;

extern fn GoogleSQL_Free(p: ?*anyopaque) void;

pub const AnalyzeError = error{
    AnalyzeFailed,
    OutOfMemory,
} || @import("proto/wire.zig").DecodeError;

pub const Analyzed = struct {
    /// Decoded resolved statement, arena-allocated.
    node: *pb.AnyResolvedNodeProto,
    /// True when the input has no further statements.
    at_end: bool,
    /// Byte offset to resume the next statement from.
    resume_offset: usize,
};

/// Diagnostic message from the last failed analyze call, arena-allocated.
pub threadlocal var last_error: []const u8 = "";

/// Analyzes the next statement of `sql` starting at `resume_offset`.
/// All returned memory (including the decoded tree and `last_error`) is
/// allocated from `arena`, which must be an arena covering the query.
pub fn analyzeNextStatement(
    arena: std.mem.Allocator,
    sql: [:0]const u8,
    resume_offset: usize,
    catalog_json: [:0]const u8,
) AnalyzeError!Analyzed {
    var offset = resume_offset;
    var out_proto: ?[*]u8 = null;
    var out_len: usize = 0;
    var out_is_end: c_int = 0;
    var out_error: ?[*:0]u8 = null;

    const rc = GoogleSQL_AnalyzeNextStatement(
        sql.ptr,
        &offset,
        catalog_json.ptr,
        "{}",
        &out_proto,
        &out_len,
        &out_is_end,
        &out_error,
    );
    if (rc != 0) {
        defer GoogleSQL_Free(out_error);
        const msg = if (out_error) |e| std.mem.sliceTo(e, 0) else "unknown analyzer error";
        last_error = try arena.dupe(u8, msg);
        return error.AnalyzeFailed;
    }
    defer GoogleSQL_Free(out_proto);

    // Copy into the arena: the decoded tree borrows string/bytes slices from
    // this buffer, so it must share the tree's lifetime.
    const bytes = try arena.dupe(u8, out_proto.?[0..out_len]);
    const node = try pb.AnyResolvedNodeProto.decode(arena, bytes);
    return .{
        .node = node,
        .at_end = out_is_end != 0,
        .resume_offset = offset,
    };
}

test "analyze SELECT 1 and decode resolved AST" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = try analyzeNextStatement(arena, "SELECT 1", 0, "{}");
    try std.testing.expect(result.at_end);

    // AnyResolvedNodeProto -> statement -> query_stmt.
    const stmt_union = result.node.node.?.resolved_statement_node;
    const query = stmt_union.node.?.resolved_query_stmt_node;
    const out_cols = query.output_column_list;
    try std.testing.expectEqual(@as(usize, 1), out_cols.len);

    // query -> project scan -> expr_list[0] literal int64 = 1.
    const scan = query.query.?.node.?.resolved_project_scan_node;
    try std.testing.expectEqual(@as(usize, 1), scan.expr_list.len);
    const computed = scan.expr_list[0];
    const expr = computed.expr.?.node.?.resolved_literal_node;
    const value = expr.value.?.value.?;
    try std.testing.expectEqual(@as(i64, 1), value.value.?.int64_value);
}

test "analyze error surfaces message" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const result = analyzeNextStatement(arena, "SELECT * FROM missing_table", 0, "{}");
    try std.testing.expectError(error.AnalyzeFailed, result);
    try std.testing.expect(std.mem.indexOf(u8, last_error, "missing_table") != null);
}

test "multi-statement resume" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sql = "SELECT 1; SELECT 2";
    const first = try analyzeNextStatement(arena, sql, 0, "{}");
    try std.testing.expect(!first.at_end);
    const second = try analyzeNextStatement(arena, sql, first.resume_offset, "{}");
    try std.testing.expect(second.at_end);

    const query = second.node.node.?.resolved_statement_node.node.?.resolved_query_stmt_node;
    const scan = query.query.?.node.?.resolved_project_scan_node;
    const expr = scan.expr_list[0].expr.?.node.?.resolved_literal_node;
    try std.testing.expectEqual(@as(i64, 2), expr.value.?.value.?.value.?.int64_value);
}
