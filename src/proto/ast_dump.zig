//! Human-readable dump of a decoded resolved AST, for harness `--verbose`
//! output. This is not ZetaSQL's `ResolvedNode::DebugString()`: it prints the
//! *proto* the shim hands back, which is what `coordinator/extractor.zig`
//! actually walks. When a case fails because the extractor took a branch you
//! did not expect, this is the tree it read, field names and all.
//!
//! Reflective rather than generated: `resolved_ast.zig` is 25k lines of
//! machine-written structs, and a printer emitted alongside them would have to
//! be regenerated in lockstep. Every field shape the generator emits is
//! covered — `?*Msg`, `[]*Msg`, `?[]const u8`, `?bool`/`?i32`/`?i64`/`?u64`/
//! `?f64`, `[][]const u8`, `[]i32`/`[]i64`, bare enums and the `union(enum)`
//! one-ofs.
//!
//! Absent fields are omitted. The generator makes every scalar optional, so
//! "omitted" means the proto carried no value — never a zero that was there.
// ephor:ignore-file ZA303

const std = @import("std");
const pb = @import("resolved_ast.zig");

pub const Options = struct {
    /// Bytes of a string/bytes field printed before the rest is elided. The
    /// encoded literals in a transformed AST run to hundreds of bytes and
    /// swamp the structure otherwise.
    max_string: usize = 96,
    /// Nesting levels printed. Past it a `...` stands in, so a pathological
    /// tree cannot fill the terminal.
    max_depth: u32 = 40,
    /// Columns of indent per level.
    indent: u32 = 2,
};

/// Writes `node` as an indented field tree. One trailing newline per line
/// written; nothing is written for an empty tree.
pub fn dump(
    w: *std.Io.Writer,
    node: *const pb.AnyResolvedNodeProto,
    opts: Options,
) std.Io.Writer.Error!void {
    try field(w, "node", null, ?pb.AnyResolvedNodeProto.NodeUnion, node.node, 0, opts);
}

/// `name` (plus `idx` for a repeated field) and its value, at `depth`.
///
/// Optionals and single-item pointers unwrap without consuming a level: the
/// generator's `?*ResolvedExprProto` is one field to a reader, not three.
fn field(
    w: *std.Io.Writer,
    name: []const u8,
    idx: ?usize,
    comptime T: type,
    v: T,
    depth: u32,
    opts: Options,
) std.Io.Writer.Error!void {
    switch (@typeInfo(T)) {
        .optional => if (v) |inner| try field(w, name, idx, @TypeOf(inner), inner, depth, opts),

        .pointer => |p| switch (p.size) {
            .one => try field(w, name, idx, p.child, v.*, depth, opts),
            .slice => {
                if (p.child == u8) {
                    if (v.len == 0) return;
                    try label(w, name, idx, depth, opts);
                    try w.writeByte(' ');
                    try string(w, v, opts);
                    try w.writeByte('\n');
                    return;
                }
                for (v, 0..) |elem, i| {
                    try field(w, name, i, @TypeOf(elem), elem, depth, opts);
                }
            },
            else => {},
        },

        .@"struct" => {
            try label(w, name, idx, depth, opts);
            if (depth + 1 > opts.max_depth) {
                try w.writeAll(" ...\n");
                return;
            }
            try w.writeByte('\n');
            const s = @typeInfo(T).@"struct";
            inline for (s.field_names, s.field_types) |field_name, field_type| {
                try field(w, field_name, null, field_type, @field(v, field_name), depth + 1, opts);
            }
        },

        // A one-of. The tag names the field that was set, so it replaces the
        // container's own name rather than nesting under it.
        .@"union" => switch (v) {
            inline else => |payload, tag| try field(
                w,
                @tagName(tag),
                idx,
                @TypeOf(payload),
                payload,
                depth,
                opts,
            ),
        },

        // Non-exhaustive, so an enum value the generator has no name for is
        // reachable whenever the shim outruns the checked-in proto. Print the
        // number rather than tripping `@tagName`'s illegal behaviour.
        .@"enum" => {
            try label(w, name, idx, depth, opts);
            if (std.enums.tagName(T, v)) |n| {
                try w.print(" {s}\n", .{n});
            } else {
                try w.print(" {d}\n", .{@backingInt(v)});
            }
        },

        .bool, .int, .float => {
            try label(w, name, idx, depth, opts);
            try w.print(" {}\n", .{v});
        },

        else => {},
    }
}

/// Indent, field name, and the colon — never the space after it, so a struct
/// header can end the line without leaving trailing whitespace behind.
fn label(
    w: *std.Io.Writer,
    name: []const u8,
    idx: ?usize,
    depth: u32,
    opts: Options,
) std.Io.Writer.Error!void {
    try w.splatByteAll(' ', depth * opts.indent);
    try w.writeAll(name);
    if (idx) |i| try w.print("[{d}]", .{i});
    try w.writeByte(':');
}

/// A string/bytes field. Printable ASCII goes out quoted; anything else is
/// hex, because the fields that matter here — encoded literals — are neither
/// text nor worth reading byte by byte.
fn string(w: *std.Io.Writer, s: []const u8, opts: Options) std.Io.Writer.Error!void {
    const printable = for (s) |ch| {
        if (ch < 0x20 or ch > 0x7e) break false;
    } else true;

    const shown = @min(s.len, opts.max_string);
    if (printable) {
        try w.print("\"{s}\"", .{s[0..shown]});
    } else {
        try w.print("0x{x}", .{s[0..shown]});
    }
    if (shown < s.len) try w.print("... ({d} bytes)", .{s.len});
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

// The dump has to survive the shapes the generator emits, so drive it with a
// real analyzed statement rather than a hand-built proto.
test "dump renders an analyzed SELECT" {
    const analyzer_ffi = @import("../analyzer_ffi.zig");

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const analyzed = try analyzer_ffi.analyzeNextStatement(arena, "SELECT 1 AS x", 0, "{}");

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    defer buf = w.toArrayList();
    try dump(&w.writer, analyzed.node, .{});

    const text = w.written();
    try testing.expect(std.mem.indexOf(u8, text, "resolved_query_stmt_node") != null);
    try testing.expect(std.mem.indexOf(u8, text, "resolved_literal_node") != null);
    try testing.expect(std.mem.indexOf(u8, text, "int64_value: 1") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"x\"") != null);
    // Absent fields stay out of the dump.
    try testing.expect(std.mem.indexOf(u8, text, "null") == null);
}

test "max_depth truncates rather than running away" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    defer buf = w.toArrayList();
    try dump(&w.writer, try dumpOf(arena, "SELECT 1 AS x"), .{ .max_depth = 2 });

    try testing.expect(std.mem.indexOf(u8, w.written(), "...") != null);
}

test "non-text bytes print as hex, long values elide" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    var w = std.Io.Writer.Allocating.fromArrayList(testing.allocator, &buf);
    defer buf = w.toArrayList();
    // A BYTES literal with a byte no terminal should be asked to render, and a
    // string past `max_string`.
    try dump(&w.writer, try dumpOf(arena, "SELECT b'\\x00\\xff', 'aaaaaaaaaa'"), .{
        .max_string = 4,
    });

    const text = w.written();
    try testing.expect(std.mem.indexOf(u8, text, "0x00ff") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\"aaaa\"... (10 bytes)") != null);
}

fn dumpOf(
    arena: std.mem.Allocator,
    sql: [:0]const u8,
) !*const pb.AnyResolvedNodeProto {
    const analyzer_ffi = @import("../analyzer_ffi.zig");
    const analyzed = try analyzer_ffi.analyzeNextStatement(arena, sql, 0, "{}");
    return analyzed.node;
}
