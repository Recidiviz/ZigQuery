//! CAST, lowered to `zigquery_cast(expr, <from type JSON>, <to type JSON>, return_null_on_err)`.
//!
//! The cast expression is transformed recursively and both types are JSON-encoded into the call.
//! A cast cannot transform SQLite's native CAST, because the answer depends on GoogleSQL types
//! that SQLite has no notion of, so the types travel to the UDF as literals.
//!
//! See function/fn_misc.zig for the evaluation. conversion_rules.md
// ephor:ignore-file ZA302

const std = @import("std");
const coordinator = @import("../coordinator/coordinator.zig");
const context = @import("../coordinator/context.zig");
const types_data = @import("../coordinator/types_data.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const spec = @import("../spec.zig");
const common = @import("common.zig");

const Error = types_data.Error;

pub fn transform(
    coord: *coordinator.QueryCoordinator,
    data: types_data.ExpressionData,
    ctx: *context.TransformContext,
) Error!*sqlbuilder.SQLExpression {
    if (data.type != .cast) return error.UnsupportedNode;
    const cast = data.cast orelse return error.UnsupportedNode;
    const alloc = coord.alloc;

    // Transform the inner expression recursively.
    const inner_expr = try coord.transformExpression(cast.expression, ctx);

    // The two types travel as JSON string literals, alongside the safe-cast flag.
    const from_type = cast.from_type orelse return error.InvalidType;
    const to_type = cast.to_type orelse return error.InvalidType;
    const json_from_type = try marshalType(alloc, from_type);
    const json_to_type = try marshalType(alloc, to_type);

    const encoded_from = try common.newLiteralExpressionFromValue(
        alloc,
        .{ .string = json_from_type },
    );
    const encoded_to = try common.newLiteralExpressionFromValue(
        alloc,
        .{ .string = json_to_type },
    );

    const args = try alloc.alloc(*sqlbuilder.SQLExpression, 4);
    args[0] = inner_expr; // Expression to cast
    args[1] = encoded_from; // Source type
    args[2] = encoded_to; // Target type
    // SAFE_CAST turns a conversion failure into NULL.
    args[3] = try sqlbuilder.newLiteralExpression(
        alloc,
        if (cast.return_null_on_err) "true" else "false",
    );

    return sqlbuilder.newFunctionExpression(alloc, "zigquery_cast", args);
}

/// A type as the JSON the cast UDF reads back:
/// {
///   "name":"",
///   "kind":N,
///   "signatureKind":N,
///   "elementType":<Type|null>,
///   "fieldTypes":<[NameWithType]|null>
/// }
/// with NameWithType as {"name":"...","type":<Type|null>}.
/// `fieldTypes` is null for anything but a struct with fields.
pub fn marshalType(alloc: std.mem.Allocator, t: *const spec.Type) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeType(alloc, &out, t);
    return out.toOwnedSlice(alloc);
}

fn writeType(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    t: *const spec.Type,
) Error!void {
    try out.print(alloc, "{{\"name\":\"\",\"kind\":{d},\"signatureKind\":{d},\"elementType\":", .{
        t.kind,
        t.signature_kind,
    });
    if (t.element_type) |elem| {
        try writeType(alloc, out, elem);
    } else {
        try out.appendSlice(alloc, "null");
    }
    try out.appendSlice(alloc, ",\"fieldTypes\":");
    if (t.field_types.len == 0) {
        // An empty field list is null, not [].
        try out.appendSlice(alloc, "null");
    } else {
        try out.append(alloc, '[');
        for (t.field_types, 0..) |field, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"name\":");
            try writeJsonString(alloc, out, field.name);
            try out.appendSlice(alloc, ",\"type\":");
            if (field.type) |ft| {
                try writeType(alloc, out, ft);
            } else {
                try out.appendSlice(alloc, "null");
            }
            try out.append(alloc, '}');
        }
        try out.append(alloc, ']');
    }
    try out.append(alloc, '}');
}

fn writeJsonString(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(u8),
    s: []const u8,
) Error!void {
    try out.append(alloc, '"');
    for (s) |c| {
        switch (c) {
            '"' => try out.appendSlice(alloc, "\\\""),
            '\\' => try out.appendSlice(alloc, "\\\\"),
            '\n' => try out.appendSlice(alloc, "\\n"),
            '\r' => try out.appendSlice(alloc, "\\r"),
            '\t' => try out.appendSlice(alloc, "\\t"),
            else => {
                if (c < 0x20) {
                    try out.print(alloc, "\\u{x:0>4}", .{c});
                } else {
                    try out.append(alloc, c);
                }
            },
        }
    }
    try out.append(alloc, '"');
}

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const pb = @import("../../proto/resolved_ast.zig");

test "marshalType matches Go json.Marshal shapes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var int_tp = pb.TypeProto{ .type_kind = .TYPE_INT64 };
    const int_t = try spec.newTypeFromProto(a, &int_tp);
    try testing.expectEqualStrings(
        "{\"name\":\"\",\"kind\":2,\"signatureKind\":0,\"elementType\":null,\"fieldTypes\":null}",
        try marshalType(a, int_t),
    );

    var elem_tp = pb.TypeProto{ .type_kind = .TYPE_STRING };
    var arr_inner = pb.ArrayTypeProto{ .element_type = &elem_tp };
    var arr_tp = pb.TypeProto{ .type_kind = .TYPE_ARRAY, .array_type = &arr_inner };
    const arr_t = try spec.newTypeFromProto(a, &arr_tp);
    const arr_json = try marshalType(a, arr_t);
    try testing.expect(std.mem.indexOf(u8, arr_json, "\"elementType\":{\"name\":\"\",\"kind\":8,") != null);
}

test "cast transform emits zigquery_cast call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var coord = coordinator.QueryCoordinator.init(a);
    const config = try a.create(context.TransformConfig);
    config.* = .{};
    const ctx = try context.TransformContext.init(a, config);

    var int_tp = pb.TypeProto{ .type_kind = .TYPE_INT64 };
    var str_tp = pb.TypeProto{ .type_kind = .TYPE_STRING };

    const lit = try a.create(types_data.LiteralData);
    lit.* = .{ .value = .{ .int = 1 } };
    const cast_data = try a.create(types_data.CastData);
    cast_data.* = .{
        .expression = .{ .type = .literal, .literal = lit },
        .from_type = try spec.newTypeFromProto(a, &int_tp),
        .to_type = try spec.newTypeFromProto(a, &str_tp),
        .return_null_on_err = false,
    };

    const expr = try transform(&coord, .{ .type = .cast, .cast = cast_data }, ctx);
    try testing.expectEqual(sqlbuilder.ExpressionType.function, expr.type);
    const call = expr.function_call.?;
    try testing.expectEqualStrings("zigquery_cast", call.name);
    try testing.expectEqual(@as(usize, 4), call.arguments.len);
    try testing.expectEqualStrings("1", call.arguments[0].value);
    // Type args are JSON type documents, which are STRING values and so render
    // as X'..' BLOB literals; the flag is plain.
    try testing.expect(call.arguments[1].value[0] == 'X');
    try testing.expectEqualStrings("false", call.arguments[3].value);
}
