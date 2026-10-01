//! FFI over the Bazel-built GoogleSQL analyzer shim
//! (googlesql repo: zig/analyzer_shim.cc -> libgooglesql_shim.dylib).
// ephor:ignore-file ZA303 ZT105

const std = @import("std");
const pb = @import("proto/resolved_ast.zig");

extern fn GoogleSQL_AnalyzeNextStatementParams(
    sql: [*:0]const u8,
    resume_offset: *usize,
    catalog_json: [*:0]const u8,
    options_json: [*:0]const u8,
    param_names: ?[*]const ?[*:0]const u8,
    param_types: ?[*]const ?[*:0]const u8,
    param_count: usize,
    out_proto: *?[*]u8,
    out_len: *usize,
    out_is_end: *c_int,
    out_error: *?[*:0]u8,
) c_int;

extern fn GoogleSQL_Free(p: ?*anyopaque) void;

/// Query-parameter type declarations for the analyzer, as the parallel arrays
/// the C boundary takes. `names[i]` is null for a positional declaration;
/// `types[i]` is GoogleSQL type text ("STRING", "ARRAY<STRING>").
///
/// Declaring nothing — which is every caller that has no type information —
/// leaves the analyzer inferring, exactly as it did before this existed.
pub const ParamDecls = struct {
    names: []const ?[*:0]const u8,
    types: []const ?[*:0]const u8,
};

fn declPtrs(decls: ?ParamDecls) struct {
    names: ?[*]const ?[*:0]const u8,
    types: ?[*]const ?[*:0]const u8,
    count: usize,
} {
    const d = decls orelse return .{ .names = null, .types = null, .count = 0 };
    std.debug.assert(d.names.len == d.types.len);
    if (d.types.len == 0) return .{ .names = null, .types = null, .count = 0 };
    return .{ .names = d.names.ptr, .types = d.types.ptr, .count = d.types.len };
}

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

/// Optional capture of each analyzed statement, for the harnesses' verbose
/// output (`--verbose` in harness/spec_runner.zig). The sibling of
/// `phase.setPreparedSqlSink`: that one sees what the transformer produced,
/// this one sees what it was given, and a case is only diagnosable with both.
///
/// The node and everything it points at belong to the caller's query arena, so
/// a sink must consume — not retain — what it is handed. Process-global and
/// unsynchronized; do not install one from a threaded driver.
pub const AstSink = *const fn (node: *const pb.AnyResolvedNodeProto) void;
var ast_sink: ?AstSink = null;

pub fn setAstSink(sink: ?AstSink) void {
    ast_sink = sink;
}

/// One statement decoded off the shim. Both analyze paths funnel through here
/// so installing a sink cannot miss the catalog-handle one.
fn noteAnalyzed(node: *const pb.AnyResolvedNodeProto) void {
    if (ast_sink) |sink| sink(node);
}

/// Analyzes the next statement of `sql` starting at `resume_offset`.
/// All returned memory (including the decoded tree and `last_error`) is
/// allocated from `arena`, which must be an arena covering the query.
pub fn analyzeNextStatement(
    arena: std.mem.Allocator,
    sql: [:0]const u8,
    resume_offset: usize,
    catalog_json: [:0]const u8,
) AnalyzeError!Analyzed {
    return analyzeNextStatementOpts(arena, sql, resume_offset, catalog_json, "{}", null);
}

/// Like analyzeNextStatement but forwards `options_json` to the shim.
/// options_json selects the parameter mode:
/// `{"parameter_mode":"positional"}` for positional (`?`) parameters;
/// anything else keeps named (`@name`) mode.
///
/// `decls` declares parameter types to the analyzer; null infers them.
pub fn analyzeNextStatementOpts(
    arena: std.mem.Allocator,
    sql: [:0]const u8,
    resume_offset: usize,
    catalog_json: [:0]const u8,
    options_json: [:0]const u8,
    decls: ?ParamDecls,
) AnalyzeError!Analyzed {
    var offset = resume_offset;
    var out_proto: ?[*]u8 = null;
    var out_len: usize = 0;
    var out_is_end: c_int = 0;
    var out_error: ?[*:0]u8 = null;

    const d = declPtrs(decls);
    const rc = GoogleSQL_AnalyzeNextStatementParams(
        sql.ptr,
        &offset,
        catalog_json.ptr,
        options_json.ptr,
        d.names,
        d.types,
        d.count,
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
    noteAnalyzed(node);
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

// ---- persistent catalog handle ----
//
// The stateless entry point above rebuilds a TypeFactory, a SimpleCatalog and
// the whole builtin function set on every call, so analysis costs O(catalog)
// per statement. A handle keeps all three alive across calls and takes table
// additions as deltas.
//
// A handle is mutable, unsynchronized state: one per connection, used from
// one thread at a time. The stateless path remains available and reentrant.

extern fn GoogleSQL_CatalogCreate(out_error: *?[*:0]u8) ?*anyopaque;
extern fn GoogleSQL_CatalogDestroy(handle: ?*anyopaque) void;
extern fn GoogleSQL_CatalogAddTables(
    handle: ?*anyopaque,
    catalog_json: [*:0]const u8,
    out_error: *?[*:0]u8,
) c_int;
extern fn GoogleSQL_CatalogRemoveTable(
    handle: ?*anyopaque,
    name: [*:0]const u8,
    out_error: *?[*:0]u8,
) c_int;
extern fn GoogleSQL_AnalyzeNextStatementWithCatalogParams(
    handle: ?*anyopaque,
    sql: [*:0]const u8,
    resume_offset: *usize,
    options_json: [*:0]const u8,
    param_names: ?[*]const ?[*:0]const u8,
    param_types: ?[*]const ?[*:0]const u8,
    param_count: usize,
    out_proto: *?[*]u8,
    out_len: *usize,
    out_is_end: *c_int,
    out_error: *?[*:0]u8,
) c_int;

pub const CatalogHandle = opaque {};

/// Creates a catalog handle preloaded with the builtin functions.
pub fn catalogCreate(gpa: std.mem.Allocator) AnalyzeError!*CatalogHandle {
    var err: ?[*:0]u8 = null;
    const h = GoogleSQL_CatalogCreate(&err) orelse {
        setLastErrorFromC(gpa, err);
        return error.AnalyzeFailed;
    };
    return @ptrCast(h);
}

pub fn catalogDestroy(handle: *CatalogHandle) void {
    GoogleSQL_CatalogDestroy(@ptrCast(handle));
}

/// Merges a SimpleCatalogProto (protobuf JSON) into the handle. Entries
/// already present are ignored, so this accepts a delta or the whole catalog.
pub fn catalogAddTables(
    gpa: std.mem.Allocator,
    handle: *CatalogHandle,
    catalog_json: [:0]const u8,
) AnalyzeError!void {
    var err: ?[*:0]u8 = null;
    if (GoogleSQL_CatalogAddTables(@ptrCast(handle), catalog_json.ptr, &err) != 0) {
        setLastErrorFromC(gpa, err);
        return error.AnalyzeFailed;
    }
}

/// Removes a table from the handle's catalog by canonical name.
///
/// Removing something absent is not an error. This exists so a DROP costs
/// O(1) rather than forcing the whole catalog to be re-pushed.
pub fn catalogRemoveTable(
    gpa: std.mem.Allocator,
    handle: *CatalogHandle,
    name: [:0]const u8,
) AnalyzeError!void {
    var err: ?[*:0]u8 = null;
    if (GoogleSQL_CatalogRemoveTable(@ptrCast(handle), name.ptr, &err) != 0) {
        setLastErrorFromC(gpa, err);
        return error.AnalyzeFailed;
    }
}

/// analyzeNextStatementOpts against a handle's persistent catalog.
pub fn analyzeNextStatementWithCatalog(
    arena: std.mem.Allocator,
    handle: *CatalogHandle,
    sql: [:0]const u8,
    resume_offset: usize,
    options_json: [:0]const u8,
    decls: ?ParamDecls,
) AnalyzeError!Analyzed {
    var offset = resume_offset;
    var out_proto: ?[*]u8 = null;
    var out_len: usize = 0;
    var out_is_end: c_int = 0;
    var err: ?[*:0]u8 = null;

    const d = declPtrs(decls);
    if (GoogleSQL_AnalyzeNextStatementWithCatalogParams(
        @ptrCast(handle),
        sql.ptr,
        &offset,
        options_json.ptr,
        d.names,
        d.types,
        d.count,
        &out_proto,
        &out_len,
        &out_is_end,
        &err,
    ) != 0) {
        setLastErrorArena(arena, err);
        return error.AnalyzeFailed;
    }

    const raw = out_proto orelse return error.AnalyzeFailed;
    defer GoogleSQL_Free(raw);
    // Copy before decoding: the decoded tree borrows slices from this buffer.
    const owned = try arena.dupe(u8, raw[0..out_len]);
    const node = try pb.AnyResolvedNodeProto.decode(arena, owned);
    noteAnalyzed(node);

    return .{ .node = node, .at_end = out_is_end != 0, .resume_offset = offset };
}

/// Copies a C error string into `last_error` using a long-lived allocator.
fn setLastErrorFromC(gpa: std.mem.Allocator, err: ?[*:0]u8) void {
    if (err) |e| {
        defer GoogleSQL_Free(e);
        last_error = gpa.dupe(u8, std.mem.sliceTo(e, 0)) catch "analyzer error";
    } else {
        last_error = "analyzer error";
    }
}

fn setLastErrorArena(arena: std.mem.Allocator, err: ?[*:0]u8) void {
    if (err) |e| {
        defer GoogleSQL_Free(e);
        last_error = arena.dupe(u8, std.mem.sliceTo(e, 0)) catch "analyzer error";
    } else {
        last_error = "analyzer error";
    }
}
