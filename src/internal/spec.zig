//! Partial port of go-zetasqlite internal/spec.go: the `Type` struct subset
//! used by the coordinator/extractor layer (Go `zType` fields become
//! `*spec.Type` built eagerly from the decoded `pb.TypeProto`).
//!
//! FunctionSpec / TableSpec / CatalogSpec are deferred to the catalog
//! milestone; this file stays extensible for them.

const std = @import("std");
const pb = @import("../proto/resolved_ast.zig");

pub const Error = error{ OutOfMemory, Unimplemented, InvalidType };

/// Go spec.go NameWithType.
pub const NameWithType = struct {
    name: []const u8 = "",
    type: ?*Type = null,
};

/// Go spec.go Type. `kind` holds the engine TypeKind int (pb.TypeKind);
/// `signature_kind` holds the SignatureArgumentKind int for templated
/// function-argument types (0 otherwise, mirroring Go's zero value).
pub const Type = struct {
    name: []const u8 = "",
    kind: i32 = 0,
    signature_kind: i32 = 0,
    element_type: ?*Type = null,
    field_types: []const *NameWithType = &.{},

    /// Go Type.kind().
    pub fn typeKind(self: *const Type) pb.TypeKind {
        return @enumFromInt(self.kind);
    }

    /// Go Type.IsArray.
    pub fn isArray(self: *const Type) bool {
        return self.typeKind() == .TYPE_ARRAY;
    }

    /// Go Type.IsStruct.
    pub fn isStruct(self: *const Type) bool {
        return self.typeKind() == .TYPE_STRUCT;
    }

    /// Go Type.FormatType: BigQuery-style type text (feeds CREATE FUNCTION).
    pub fn formatType(self: *const Type, alloc: std.mem.Allocator) Error![]const u8 {
        switch (self.typeKind()) {
            .TYPE_STRUCT => {
                var out: std.ArrayList(u8) = .empty;
                try out.appendSlice(alloc, "STRUCT<");
                for (self.field_types, 0..) |field, i| {
                    if (i > 0) try out.appendSlice(alloc, ",");
                    try out.append(alloc, '`');
                    try out.appendSlice(alloc, field.name);
                    try out.appendSlice(alloc, "` ");
                    const t = field.type orelse return error.InvalidType;
                    try out.appendSlice(alloc, try t.formatType(alloc));
                }
                try out.appendSlice(alloc, ">");
                return out.toOwnedSlice(alloc);
            },
            .TYPE_ARRAY => {
                const elem = self.element_type orelse return error.InvalidType;
                return std.fmt.allocPrint(alloc, "ARRAY<{s}>", .{try elem.formatType(alloc)});
            },
            else => return bigQueryTypeName(self.typeKind()),
        }
    }
};

/// Go spec.go newType equivalent, building from the decoded TypeProto
/// (type_kind + array_type.element_type + struct_type.field recursion).
/// Like Go newType, `name` is left empty.
pub fn newTypeFromProto(alloc: std.mem.Allocator, tp: *const pb.TypeProto) Error!*Type {
    const t = try alloc.create(Type);
    t.* = .{ .kind = @intFromEnum(tp.type_kind orelse .TYPE_UNKNOWN) };
    switch (tp.type_kind orelse .TYPE_UNKNOWN) {
        .TYPE_ARRAY => {
            const at = tp.array_type orelse return error.InvalidType;
            const elem = at.element_type orelse return error.InvalidType;
            t.element_type = try newTypeFromProto(alloc, elem);
        },
        .TYPE_STRUCT => {
            const st = tp.struct_type orelse return error.InvalidType;
            const fields = try alloc.alloc(*NameWithType, st.field.len);
            for (st.field, 0..) |field, i| {
                const ft = field.field_type orelse return error.InvalidType;
                const nwt = try alloc.create(NameWithType);
                nwt.* = .{
                    .name = field.field_name orelse "",
                    .type = try newTypeFromProto(alloc, ft),
                };
                fields[i] = nwt;
            }
            t.field_types = fields;
        },
        else => {},
    }
    return t;
}

/// Go spec.go bigQueryTypeName: go-zetasql-style short names.
pub fn bigQueryTypeName(k: pb.TypeKind) []const u8 {
    return switch (k) {
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64 => "INT64",
        .TYPE_BOOL => "BOOL",
        .TYPE_FLOAT, .TYPE_DOUBLE => "FLOAT64",
        .TYPE_STRING => "STRING",
        .TYPE_BYTES => "BYTES",
        .TYPE_DATE => "DATE",
        .TYPE_DATETIME => "DATETIME",
        .TYPE_TIME => "TIME",
        .TYPE_TIMESTAMP => "TIMESTAMP",
        .TYPE_NUMERIC => "NUMERIC",
        .TYPE_BIGNUMERIC => "BIGNUMERIC",
        .TYPE_JSON => "JSON",
        .TYPE_INTERVAL => "INTERVAL",
        .TYPE_GEOGRAPHY => "GEOGRAPHY",
        // Go falls back to TypeKind.String(); we use the proto tag name.
        else => @tagName(k),
    };
}

/// Go spec.go ColumnSpec.SQLiteSchema type mapping (the column-type text
/// only; full ColumnSpec arrives with the catalog milestone).
pub fn sqliteTypeName(k: pb.TypeKind) []const u8 {
    return switch (k) {
        .TYPE_INT32, .TYPE_INT64, .TYPE_UINT32, .TYPE_UINT64, .TYPE_ENUM => "INT",
        .TYPE_BOOL => "BOOLEAN",
        .TYPE_FLOAT => "FLOAT",
        .TYPE_BYTES => "BLOB",
        .TYPE_DOUBLE => "DOUBLE",
        .TYPE_JSON => "JSON",
        .TYPE_STRING => "TEXT",
        .TYPE_DATE,
        .TYPE_TIMESTAMP,
        .TYPE_ARRAY,
        .TYPE_STRUCT,
        .TYPE_PROTO,
        .TYPE_TIME,
        .TYPE_DATETIME,
        .TYPE_GEOGRAPHY,
        .TYPE_NUMERIC,
        .TYPE_BIGNUMERIC,
        .TYPE_EXTENDED,
        .TYPE_INTERVAL,
        => "TEXT",
        else => "UNKNOWN",
    };
}

const testing = std.testing;

test "newTypeFromProto builds scalar, array and struct types" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var int_tp = pb.TypeProto{ .type_kind = .TYPE_INT64 };
    const int_t = try newTypeFromProto(alloc, &int_tp);
    try testing.expectEqual(pb.TypeKind.TYPE_INT64, int_t.typeKind());
    try testing.expectEqualStrings("INT64", try int_t.formatType(alloc));

    var arr_elem = pb.TypeProto{ .type_kind = .TYPE_STRING };
    var arr_inner = pb.ArrayTypeProto{ .element_type = &arr_elem };
    var arr_tp = pb.TypeProto{ .type_kind = .TYPE_ARRAY, .array_type = &arr_inner };
    const arr_t = try newTypeFromProto(alloc, &arr_tp);
    try testing.expect(arr_t.isArray());
    try testing.expectEqualStrings("ARRAY<STRING>", try arr_t.formatType(alloc));

    var f1_tp = pb.TypeProto{ .type_kind = .TYPE_INT64 };
    var f1 = pb.StructFieldProto{ .field_name = "a", .field_type = &f1_tp };
    var fields = [_]*pb.StructFieldProto{&f1};
    var st_inner = pb.StructTypeProto{ .field = &fields };
    var st_tp = pb.TypeProto{ .type_kind = .TYPE_STRUCT, .struct_type = &st_inner };
    const st_t = try newTypeFromProto(alloc, &st_tp);
    try testing.expect(st_t.isStruct());
    try testing.expectEqualStrings("STRUCT<`a` INT64>", try st_t.formatType(alloc));
}
