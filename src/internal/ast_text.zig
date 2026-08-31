//! Renders a decoded resolved-AST node (`src/proto/resolved_ast.zig`) as an indented,
//! human-readable tree, for the spec-corpus UI's AST view.
//!
//! A single comptime-reflection walk over whatever's already decoded, rather
//! than a per-node-kind formatter: every "Any*Proto" wrapper is a struct
//! holding one `?union(enum)` field (the resolved-node/expr/scan/statement
//! oneof), and every concrete message is a struct of `?bool`/`?i64`/`?f64`/
//! `?Enum` scalar leaves, `?[]const u8` string leaves, `?*T` nested messages
//! (including protobuf's "extends" pattern — a `parent: ?*T` field is
//! structurally just another optional message field, so inherited fields
//! surface with no special-casing), and `[]*T` repeated fields. `@typeInfo`
//! dispatch handles all of these uniformly.
//!
//! A wrapper struct with exactly one field (the common "Any*Proto{field:
//! ?Union}" shape) is rendered transparently — the field recurses under the
//! wrapper's own label instead of adding an empty nesting level — since that
//! shape carries no information of its own beyond "here is the oneof."
//!
//! Not as polished as ZetaSQL's own hand-crafted `ResolvedNode::DebugString()`
//! (that lives in C++ and isn't exported over the FFI boundary), but every
//! field is genuinely labeled and navigable, which is what a debugging view
//! needs. Depth and total-size caps bound the output regardless — this runs
//! once per spec case at UI startup, across the whole (large) corpus.

const std = @import("std");
const pb = @import("../proto/resolved_ast.zig");

const max_depth = 60;
const max_bytes = 200 * 1024;

const Writer = struct {
    buf: std.ArrayList(u8) = .empty,
    arena: std.mem.Allocator,
    truncated: bool = false,

    fn line(w: *Writer, depth: usize, comptime fmt: []const u8, args: anytype) std.mem.Allocator.Error!void {
        if (w.truncated) return;
        if (w.buf.items.len > max_bytes) {
            w.truncated = true;
            try w.buf.appendSlice(w.arena, "... [truncated]\n");
            return;
        }
        try w.buf.appendNTimes(w.arena, ' ', depth * 2);
        try w.buf.print(w.arena, fmt, args);
        try w.buf.append(w.arena, '\n');
    }
};

/// `node` and everything it points to must already be arena-allocated (as
/// `analyzer_ffi.Analyzed.node` always is); the returned text is allocated
/// from `arena` too.
pub fn render(arena: std.mem.Allocator, node: *const pb.AnyResolvedNodeProto) std.mem.Allocator.Error![]const u8 {
    var w: Writer = .{ .arena = arena };
    try renderValue(&w, node, 0, "root");
    return w.buf.toOwnedSlice(arena);
}

// Explicit error type, not inferred: the resolved-AST types are genuinely
// mutually recursive at the type level (an expr can hold a subquery scan,
// which holds exprs, ...), so a recursive `anytype` function relying on
// Zig's inferred-error-set mechanism hits a dependency cycle at comptime.
// The only error this ever produces is OutOfMemory (every `try` below is an
// arena append), matching `render`'s own declared return type.
fn renderValue(w: *Writer, value: anytype, depth: usize, name: []const u8) std.mem.Allocator.Error!void {
    if (depth > max_depth) {
        try w.line(depth, "{s}: ... [max depth]", .{name});
        return;
    }
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .optional => if (value) |v| try renderValue(w, v, depth, name),
        .pointer => |p| switch (p.size) {
            .one => try renderValue(w, value.*, depth, name),
            .slice => {
                if (p.child == u8) {
                    try w.line(depth, "{s}: \"{s}\"", .{ name, value });
                } else if (value.len > 0) {
                    try w.line(depth, "{s} ({d}):", .{ name, value.len });
                    for (value, 0..) |elem, i| {
                        var idx_buf: [24]u8 = undefined;
                        const idx_name = std.fmt.bufPrint(&idx_buf, "[{d}]", .{i}) catch "[]";
                        try renderValue(w, elem, depth + 1, idx_name);
                    }
                }
                // Empty repeated fields are omitted — a resolved node has
                // dozens of possible repeated fields and most are unset.
            },
            else => try w.line(depth, "{s}: <ptr>", .{name}),
        },
        .@"union" => switch (value) {
            inline else => |payload, tag| try renderValue(w, payload, depth, @tagName(tag)),
        },
        .@"struct" => |s| {
            if (s.fields.len == 1) {
                // Transparent wrapper (AnyResolvedNodeProto{node: ?Union} and
                // its siblings) — recurse under the same label rather than
                // adding a level that names nothing.
                try renderValue(w, @field(value, s.fields[0].name), depth, name);
                return;
            }
            try w.line(depth, "{s}:", .{name});
            inline for (s.fields) |f| {
                // Synthetic exhaustiveness placeholders (e.g.
                // `__ValueProto__switch_must_have_a_default`), never a real
                // decoded field.
                if (comptime std.mem.startsWith(u8, f.name, "__")) continue;
                try renderValue(w, @field(value, f.name), depth + 1, f.name);
            }
        },
        .bool => try w.line(depth, "{s}: {}", .{ name, value }),
        .int => try w.line(depth, "{s}: {d}", .{ name, value }),
        .float => try w.line(depth, "{s}: {d}", .{ name, value }),
        .@"enum" => try w.line(depth, "{s}: {s}", .{ name, std.enums.tagName(T, value) orelse "<unknown>" }),
        else => try w.line(depth, "{s}: <{s}>", .{ name, @typeName(T) }),
    }
}
