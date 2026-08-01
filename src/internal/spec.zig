//! Partial port of go-zetasqlite internal/spec.go: the `Type` struct subset
//! used by the coordinator/extractor layer (Go `zType` fields become
//! `*spec.Type` built eagerly from the decoded `pb.TypeProto`).
//!
//! Also ports the catalog-milestone TableSpec/ColumnSpec with their
//! Go-compatible JSON encoding (the persisted `spec` column must
//! interoperate with DBs written by go-zetasqlite). FunctionSpec is
//! deferred to the CREATE FUNCTION milestone.

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

// ----------------------------------------------------------------------
// TableSpec / ColumnSpec (Go spec.go TableSpec, ColumnSpec)
// ----------------------------------------------------------------------

/// go-googlesql ResolvedCreateStatementEnums_CreateMode values as persisted
/// by Go in TableSpec JSON (`createMode`). NOTE: these are the Go binding's
/// 1-based values, NOT the googlesql fork's 0-based proto enum
/// (pb.ResolvedCreateStatementEnums_CreateMode); converting a resolved
/// CREATE statement's proto mode requires +1 (CREATE-statement task).
pub const create_mode_unspecified: i64 = 0;
pub const create_mode_create_default: i64 = 1;
pub const create_mode_create_or_replace: i64 = 2;
pub const create_mode_create_if_not_exists: i64 = 3;

/// Go name_path.go formatPath: "_"-joined (the canonical SQLite name).
pub fn formatPath(alloc: std.mem.Allocator, path: []const []const u8) error{OutOfMemory}![]u8 {
    return std.mem.join(alloc, "_", path);
}

/// Go spec.go ColumnSpec.
pub const ColumnSpec = struct {
    name: []const u8 = "",
    type: *Type,
    is_not_null: bool = false,

    /// Go ColumnSpec.SQLiteSchema: "`name` TYPE[ NOT NULL]".
    pub fn sqliteSchema(self: *const ColumnSpec, alloc: std.mem.Allocator) Error![]u8 {
        const typ = sqliteTypeName(self.type.typeKind());
        if (self.is_not_null) {
            return std.fmt.allocPrint(alloc, "`{s}` {s} NOT NULL", .{ self.name, typ });
        }
        return std.fmt.allocPrint(alloc, "`{s}` {s}", .{ self.name, typ });
    }
};

/// One `OPTIONS(name=value)` entry from CREATE TABLE / CREATE VIEW, as
/// INFORMATION_SCHEMA.TABLE_OPTIONS reports it.
///
/// `value` is the SQL *literal*, quotes included — BigQuery renders a STRING
/// option as `"demo table"`, double-quoted with `\"` escapes (verified against
/// a real table). It is stored rendered rather than as a typed value because
/// that is the only form the view ever needs.
pub const OptionSpec = struct {
    name: []const u8 = "",
    type_name: []const u8 = "",
    value: []const u8 = "",
};

/// Go spec.go TableSpec. `updated_at`/`created_at` hold the RFC3339 strings
/// Go's time.Time marshals to; they are round-tripped opaquely.
pub const TableSpec = struct {
    is_temp: bool = false,
    is_view: bool = false,
    name_path: []const []const u8 = &.{},
    columns: []const *ColumnSpec = &.{},
    primary_key: []const []const u8 = &.{},
    create_mode: i64 = create_mode_unspecified,
    query: []const u8 = "",
    updated_at: []const u8 = "",
    created_at: []const u8 = "",
    /// DDL OPTIONS. Go's TableSpec has no such field, so this is serialised
    /// only when non-empty — see toJson — keeping the JSON byte-identical to
    /// Go's for every spec that has none.
    options: []const *OptionSpec = &.{},

    /// Go TableSpec.Column.
    pub fn column(self: *const TableSpec, name: []const u8) ?*ColumnSpec {
        for (self.columns) |col| {
            if (std.mem.eql(u8, col.name, name)) return @constCast(col);
        }
        return null;
    }

    /// Go TableSpec.TableName: formatPath(NamePath).
    pub fn tableName(self: *const TableSpec, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return formatPath(alloc, self.name_path);
    }

    /// Go TableSpec.SQLiteSchema (exact text, including the trailing space
    /// Go's "%s `%s` (%s) %s" leaves when there is no clustering clause).
    pub fn sqliteSchema(self: *const TableSpec, alloc: std.mem.Allocator) Error![]u8 {
        if (self.is_view) return self.viewSqliteSchema(alloc);
        const table_name = try self.tableName(alloc);
        if (self.query.len != 0) {
            return std.fmt.allocPrint(alloc, "CREATE TABLE `{s}` AS {s}", .{ table_name, self.query });
        }
        var columns: std.ArrayList([]const u8) = .empty;
        for (self.columns) |c| {
            try columns.append(alloc, try c.sqliteSchema(alloc));
        }
        // No PRIMARY KEY clause, deliberately. BigQuery only accepts
        // `PRIMARY KEY ... NOT ENFORCED`: the key is optimizer metadata for
        // join elimination, never a uniqueness or non-null guarantee, and
        // duplicate and NULL keys are both legal there. Emitting a real SQLite
        // primary key would make the emulator reject rows production accepts,
        // which is the wrong direction for an emulator to be wrong in.
        //
        // The key is not discarded: it stays on the TableSpec, round-trips
        // through the catalog's `primaryKey` field, and becomes a non-unique
        // index (see pkIndexSchema) so SQLite's planner gets the same hint
        // BigQuery's does.
        const clustering: []const u8 = "";
        const stmt: []const u8 = switch (self.create_mode) {
            create_mode_create_default, create_mode_create_or_replace => "CREATE TABLE",
            create_mode_create_if_not_exists => "CREATE TABLE IF NOT EXISTS",
            else => "", // Go's switch has no default: stmt stays "".
        };
        return std.fmt.allocPrint(alloc, "{s} `{s}` ({s}) {s}", .{
            stmt,
            table_name,
            try std.mem.join(alloc, ",", columns.items),
            clustering,
        });
    }

    /// The declared primary key as a **non-unique** index, or null when there
    /// is none.
    ///
    /// This is the half of a BigQuery primary key that does carry over. The
    /// constraint half does not (see sqliteSchema), but the planner hint does:
    /// BigQuery uses the key for join elimination, and a plain index gives
    /// SQLite's query planner the same lookup path without enforcing
    /// uniqueness or non-nullness that BigQuery never promised.
    ///
    /// Named `<table>.pk`. Index names share one namespace per database, so the
    /// table name has to be in there; it is already unique and already contains
    /// dots (`project.dataset.table`), which the backticks cover.
    pub fn pkIndexSchema(self: *const TableSpec, alloc: std.mem.Allocator) Error!?[]u8 {
        if (self.is_view or self.primary_key.len == 0) return null;
        const table_name = try self.tableName(alloc);
        const quoted = try alloc.alloc([]const u8, self.primary_key.len);
        for (self.primary_key, 0..) |key, i| {
            quoted[i] = try std.fmt.allocPrint(alloc, "`{s}`", .{key});
        }
        return try std.fmt.allocPrint(
            alloc,
            "CREATE INDEX IF NOT EXISTS `{s}.pk` ON `{s}` ({s})",
            .{ table_name, table_name, try std.mem.join(alloc, ",", quoted) },
        );
    }

    /// Go viewSQLiteSchema.
    fn viewSqliteSchema(self: *const TableSpec, alloc: std.mem.Allocator) Error![]u8 {
        const stmt: []const u8 = switch (self.create_mode) {
            create_mode_create_default, create_mode_create_or_replace => "CREATE VIEW",
            create_mode_create_if_not_exists => "CREATE VIEW IF NOT EXISTS",
            else => "",
        };
        return std.fmt.allocPrint(alloc, "{s} `{s}` AS {s}", .{
            stmt,
            try self.tableName(alloc),
            self.query,
        });
    }

    /// json.Marshal(*TableSpec) equivalent: field order, casing and
    /// null-vs-[] conventions match what Go produces (nil PrimaryKey -> null,
    /// always-built Columns/NamePath -> arrays).
    pub fn toJson(self: *const TableSpec, alloc: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(alloc, "{\"isTemp\":");
        try out.appendSlice(alloc, if (self.is_temp) "true" else "false");
        try out.appendSlice(alloc, ",\"isView\":");
        try out.appendSlice(alloc, if (self.is_view) "true" else "false");
        try out.appendSlice(alloc, ",\"namePath\":");
        try appendJsonStringArray(&out, alloc, self.name_path);
        try out.appendSlice(alloc, ",\"columns\":[");
        for (self.columns, 0..) |col, i| {
            if (i > 0) try out.append(alloc, ',');
            try appendColumnSpecJson(&out, alloc, col);
        }
        try out.appendSlice(alloc, "],\"primaryKey\":");
        if (self.primary_key.len == 0) {
            try out.appendSlice(alloc, "null");
        } else {
            try appendJsonStringArray(&out, alloc, self.primary_key);
        }
        try out.appendSlice(alloc, ",\"createMode\":");
        try out.print(alloc, "{d}", .{self.create_mode});
        try out.appendSlice(alloc, ",\"query\":");
        try appendJsonString(&out, alloc, self.query);
        try out.appendSlice(alloc, ",\"updatedAt\":");
        try appendJsonString(&out, alloc, self.updated_at);
        try out.appendSlice(alloc, ",\"createdAt\":");
        try appendJsonString(&out, alloc, self.created_at);
        // Only when present, so a spec with no options marshals byte-for-byte
        // as Go does — Go's TableSpec has no such field. Same shape as upstream
        // googlesqlite's `json:"options,omitempty"`.
        if (self.options.len > 0) {
            try out.appendSlice(alloc, ",\"options\":[");
            for (self.options, 0..) |opt, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, "{\"name\":");
                try appendJsonString(&out, alloc, opt.name);
                try out.appendSlice(alloc, ",\"type\":");
                try appendJsonString(&out, alloc, opt.type_name);
                try out.appendSlice(alloc, ",\"value\":");
                try appendJsonString(&out, alloc, opt.value);
                try out.append(alloc, '}');
            }
            try out.append(alloc, ']');
        }
        try out.append(alloc, '}');
        return out.toOwnedSlice(alloc);
    }
};

fn appendColumnSpecJson(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    col: *const ColumnSpec,
) Error!void {
    try out.appendSlice(alloc, "{\"name\":");
    try appendJsonString(out, alloc, col.name);
    try out.appendSlice(alloc, ",\"type\":");
    try appendTypeJson(out, alloc, col.type);
    try out.appendSlice(alloc, ",\"isNotNull\":");
    try out.appendSlice(alloc, if (col.is_not_null) "true" else "false");
    try out.append(alloc, '}');
}

/// The Go spec.go Type JSON shape: {"name","kind","signatureKind",
/// "elementType","fieldTypes"} with null for absent pointers/nil slices.
fn appendTypeJson(out: *std.ArrayList(u8), alloc: std.mem.Allocator, t: *const Type) Error!void {
    try out.appendSlice(alloc, "{\"name\":");
    try appendJsonString(out, alloc, t.name);
    try out.print(alloc, ",\"kind\":{d},\"signatureKind\":{d},\"elementType\":", .{ t.kind, t.signature_kind });
    if (t.element_type) |elem| {
        try appendTypeJson(out, alloc, elem);
    } else {
        try out.appendSlice(alloc, "null");
    }
    try out.appendSlice(alloc, ",\"fieldTypes\":");
    if (t.field_types.len == 0) {
        try out.appendSlice(alloc, "null");
    } else {
        try out.append(alloc, '[');
        for (t.field_types, 0..) |field, i| {
            if (i > 0) try out.append(alloc, ',');
            try out.appendSlice(alloc, "{\"name\":");
            try appendJsonString(out, alloc, field.name);
            try out.appendSlice(alloc, ",\"type\":");
            if (field.type) |ft| {
                try appendTypeJson(out, alloc, ft);
            } else {
                try out.appendSlice(alloc, "null");
            }
            try out.append(alloc, '}');
        }
        try out.append(alloc, ']');
    }
    try out.append(alloc, '}');
}

fn appendJsonStringArray(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    items: []const []const u8,
) Error!void {
    try out.append(alloc, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(alloc, ',');
        try appendJsonString(out, alloc, item);
    }
    try out.append(alloc, ']');
}

/// Minimal JSON string escaping (", \, control chars) — matches what Go
/// emits for the identifier/timestamp/SQL-text strings that appear in specs.
pub fn appendJsonString(out: *std.ArrayList(u8), alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}!void {
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

/// json.Unmarshal into TableSpec: accepts the Go shape (missing fields,
/// null-vs-[] slices, any field order). All returned memory is from `alloc`.
pub fn tableSpecFromJson(alloc: std.mem.Allocator, json_text: []const u8) Error!*TableSpec {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, json_text, .{}) catch |err|
        switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidType,
    };
    if (parsed != .object) return error.InvalidType;
    const obj = parsed.object;

    const table_spec = try alloc.create(TableSpec);
    table_spec.* = .{};
    if (getBool(obj, "isTemp")) |b| table_spec.is_temp = b;
    if (getBool(obj, "isView")) |b| table_spec.is_view = b;
    table_spec.name_path = try stringSliceField(alloc, obj, "namePath");
    table_spec.primary_key = try stringSliceField(alloc, obj, "primaryKey");
    if (obj.get("createMode")) |v| {
        if (v == .integer) table_spec.create_mode = v.integer;
    }
    if (obj.get("query")) |v| {
        if (v == .string) table_spec.query = try alloc.dupe(u8, v.string);
    }
    if (obj.get("updatedAt")) |v| {
        if (v == .string) table_spec.updated_at = try alloc.dupe(u8, v.string);
    }
    if (obj.get("createdAt")) |v| {
        if (v == .string) table_spec.created_at = try alloc.dupe(u8, v.string);
    }
    if (obj.get("columns")) |v| {
        if (v == .array) {
            const cols = try alloc.alloc(*ColumnSpec, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                cols[i] = try columnSpecFromValue(alloc, item);
            }
            table_spec.columns = cols;
        }
    }
    // Mandatory counterpart to toJson's options block: addNewTableSpec
    // serialises a spec and stores the *re-parsed* one, so a key written but
    // not read here would vanish before the catalog ever saw it.
    if (obj.get("options")) |v| {
        if (v == .array) {
            const opts = try alloc.alloc(*OptionSpec, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                const o = try alloc.create(OptionSpec);
                o.* = .{};
                if (item == .object) {
                    if (item.object.get("name")) |x| {
                        if (x == .string) o.name = try alloc.dupe(u8, x.string);
                    }
                    if (item.object.get("type")) |x| {
                        if (x == .string) o.type_name = try alloc.dupe(u8, x.string);
                    }
                    if (item.object.get("value")) |x| {
                        if (x == .string) o.value = try alloc.dupe(u8, x.string);
                    }
                }
                opts[i] = o;
            }
            table_spec.options = opts;
        }
    }
    return table_spec;
}

fn getBool(obj: std.json.ObjectMap, key: []const u8) ?bool {
    const v = obj.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

fn stringSliceField(
    alloc: std.mem.Allocator,
    obj: std.json.ObjectMap,
    key: []const u8,
) Error![]const []const u8 {
    const v = obj.get(key) orelse return &.{};
    if (v != .array) return &.{};
    const out = try alloc.alloc([]const u8, v.array.items.len);
    for (v.array.items, 0..) |item, i| {
        if (item != .string) return error.InvalidType;
        out[i] = try alloc.dupe(u8, item.string);
    }
    return out;
}

fn columnSpecFromValue(alloc: std.mem.Allocator, v: std.json.Value) Error!*ColumnSpec {
    if (v != .object) return error.InvalidType;
    const obj = v.object;
    const col = try alloc.create(ColumnSpec);
    const typ = try alloc.create(Type);
    typ.* = .{};
    col.* = .{ .type = typ };
    if (obj.get("name")) |name| {
        if (name == .string) col.name = try alloc.dupe(u8, name.string);
    }
    if (getBool(obj, "isNotNull")) |b| col.is_not_null = b;
    if (obj.get("type")) |tv| {
        if (tv == .object) col.type = try typeFromValue(alloc, tv);
    }
    return col;
}

fn typeFromValue(alloc: std.mem.Allocator, v: std.json.Value) Error!*Type {
    if (v != .object) return error.InvalidType;
    const obj = v.object;
    const t = try alloc.create(Type);
    t.* = .{};
    if (obj.get("name")) |name| {
        if (name == .string) t.name = try alloc.dupe(u8, name.string);
    }
    if (obj.get("kind")) |kind| {
        if (kind == .integer) t.kind = @intCast(kind.integer);
    }
    if (obj.get("signatureKind")) |sk| {
        if (sk == .integer) t.signature_kind = @intCast(sk.integer);
    }
    if (obj.get("elementType")) |et| {
        if (et == .object) t.element_type = try typeFromValue(alloc, et);
    }
    if (obj.get("fieldTypes")) |fts| {
        if (fts == .array) {
            const fields = try alloc.alloc(*NameWithType, fts.array.items.len);
            for (fts.array.items, 0..) |item, i| {
                if (item != .object) return error.InvalidType;
                const nwt = try alloc.create(NameWithType);
                nwt.* = .{};
                if (item.object.get("name")) |name| {
                    if (name == .string) nwt.name = try alloc.dupe(u8, name.string);
                }
                if (item.object.get("type")) |tv| {
                    if (tv == .object) nwt.type = try typeFromValue(alloc, tv);
                }
                fields[i] = nwt;
            }
            t.field_types = fields;
        }
    }
    return t;
}

/// Convenience constructor for a scalar Type of the given kind.
pub fn newSimpleType(alloc: std.mem.Allocator, kind: pb.TypeKind) error{OutOfMemory}!*Type {
    const t = try alloc.create(Type);
    t.* = .{ .kind = @intFromEnum(kind) };
    return t;
}

/// Go isTemplatedSignatureKind, translated to the proto SignatureArgumentKind
/// values this port stores in `Type.signature_kind`: ARG_KIND_EXPR_FIXED is
/// the 0 value, so any nonzero kind denotes a templated argument.
pub fn isTemplatedSignatureKind(k: i32) bool {
    return k != 0;
}

// ----------------------------------------------------------------------
// FunctionSpec (Go spec.go FunctionSpec) — SQL/JS user-defined functions
// plus the catalog-seeded MISSING_FUNCTIONS (contains_substr, min_by,
// max_by). The persisted JSON keeps the Go field order and tags for
// args/return/type so a go-zetasqlite catalog round-trips; `body` deviates
// (Go stores a *SQLExpression object, this port stores the already-rendered
// SQL string, since the two SQLExpression trees are not byte-compatible).
// ----------------------------------------------------------------------

/// Name -> spec map threaded into the transformer for CallSQL rewriting
/// (Go Catalog.funcMap / funcMapFromContext).
pub const FuncMap = std.StringHashMap(*FunctionSpec);

pub const FunctionSpec = struct {
    is_temp: bool = false,
    /// Go NamePath (json "name").
    name_path: []const []const u8 = &.{},
    language: []const u8 = "",
    args: []const *NameWithType = &.{},
    /// Go Return (json "return").
    return_type: ?*Type = null,
    /// Rendered SQL body with @argname placeholders (json "body"); null for
    /// catalog-seeded builtins and JS functions.
    body: ?[]const u8 = null,
    code: []const u8 = "",
    is_aggregate: bool = false,
    updated_at: []const u8 = "",
    created_at: []const u8 = "",

    /// Go FunctionSpec.FuncName: formatPath(NamePath) ("_"-joined).
    pub fn funcName(self: *const FunctionSpec, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return formatPath(alloc, self.name_path);
    }

    /// Go FunctionSpec.CallSQL for a SQL-body function: substitute each
    /// "@argname" with the transformed argument SQL, then wrap "( body )".
    /// Bodyless specs are JS functions (Go inlines a zetasqlite_eval_javascript
    /// call evaluated by goja, which this port excludes) or templated SQL
    /// functions (Go's analyzeTemplatedFunctionWithRuntimeArgument); both
    /// report Unimplemented rather than emitting an undefined call.
    pub fn callSQL(
        self: *const FunctionSpec,
        alloc: std.mem.Allocator,
        arg_sql: []const []const u8,
    ) Error![]const u8 {
        const body = self.body orelse return error.Unimplemented;
        var cur: []const u8 = body;
        for (self.args, 0..) |arg, i| {
            if (i >= arg_sql.len) break;
            const ref = try std.fmt.allocPrint(alloc, "@{s}", .{arg.name});
            cur = try std.mem.replaceOwned(u8, alloc, cur, ref, arg_sql[i]);
        }
        return std.fmt.allocPrint(alloc, "( {s} )", .{cur});
    }

    /// json.Marshal(*FunctionSpec): Go field order/tags for the portable
    /// fields; body is a plain string (see the deviation note above).
    pub fn toJson(self: *const FunctionSpec, alloc: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(alloc, "{\"isTemp\":");
        try out.appendSlice(alloc, if (self.is_temp) "true" else "false");
        try out.appendSlice(alloc, ",\"name\":");
        try appendJsonStringArray(&out, alloc, self.name_path);
        try out.appendSlice(alloc, ",\"language\":");
        try appendJsonString(&out, alloc, self.language);
        try out.appendSlice(alloc, ",\"args\":");
        if (self.args.len == 0) {
            try out.appendSlice(alloc, "null");
        } else {
            try out.append(alloc, '[');
            for (self.args, 0..) |arg, i| {
                if (i > 0) try out.append(alloc, ',');
                try out.appendSlice(alloc, "{\"name\":");
                try appendJsonString(&out, alloc, arg.name);
                try out.appendSlice(alloc, ",\"type\":");
                if (arg.type) |t| try appendTypeJson(&out, alloc, t) else try out.appendSlice(alloc, "null");
                try out.append(alloc, '}');
            }
            try out.append(alloc, ']');
        }
        try out.appendSlice(alloc, ",\"return\":");
        if (self.return_type) |t| try appendTypeJson(&out, alloc, t) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"body\":");
        if (self.body) |b| try appendJsonString(&out, alloc, b) else try out.appendSlice(alloc, "null");
        try out.appendSlice(alloc, ",\"code\":");
        try appendJsonString(&out, alloc, self.code);
        try out.appendSlice(alloc, ",\"isAggregate\":");
        try out.appendSlice(alloc, if (self.is_aggregate) "true" else "false");
        try out.appendSlice(alloc, ",\"updatedAt\":");
        try appendJsonString(&out, alloc, self.updated_at);
        try out.appendSlice(alloc, ",\"createdAt\":");
        try appendJsonString(&out, alloc, self.created_at);
        try out.append(alloc, '}');
        return out.toOwnedSlice(alloc);
    }
};

/// json.Unmarshal into FunctionSpec (accepts the shape toJson produces; a
/// go-zetasqlite object with an object-valued "body" leaves body null).
pub fn functionSpecFromJson(alloc: std.mem.Allocator, json_text: []const u8) Error!*FunctionSpec {
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, alloc, json_text, .{}) catch |err|
        switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidType,
        };
    if (parsed != .object) return error.InvalidType;
    const obj = parsed.object;

    const fs = try alloc.create(FunctionSpec);
    fs.* = .{};
    if (getBool(obj, "isTemp")) |b| fs.is_temp = b;
    fs.name_path = try stringSliceField(alloc, obj, "name");
    if (obj.get("language")) |v| {
        if (v == .string) fs.language = try alloc.dupe(u8, v.string);
    }
    if (obj.get("code")) |v| {
        if (v == .string) fs.code = try alloc.dupe(u8, v.string);
    }
    if (getBool(obj, "isAggregate")) |b| fs.is_aggregate = b;
    if (obj.get("body")) |v| {
        if (v == .string) fs.body = try alloc.dupe(u8, v.string);
    }
    if (obj.get("return")) |v| {
        if (v == .object) fs.return_type = try typeFromValue(alloc, v);
    }
    if (obj.get("updatedAt")) |v| {
        if (v == .string) fs.updated_at = try alloc.dupe(u8, v.string);
    }
    if (obj.get("createdAt")) |v| {
        if (v == .string) fs.created_at = try alloc.dupe(u8, v.string);
    }
    if (obj.get("args")) |v| {
        if (v == .array) {
            const args = try alloc.alloc(*NameWithType, v.array.items.len);
            for (v.array.items, 0..) |item, i| {
                if (item != .object) return error.InvalidType;
                const nwt = try alloc.create(NameWithType);
                nwt.* = .{};
                if (item.object.get("name")) |name| {
                    if (name == .string) nwt.name = try alloc.dupe(u8, name.string);
                }
                if (item.object.get("type")) |tv| {
                    if (tv == .object) nwt.type = try typeFromValue(alloc, tv);
                }
                args[i] = nwt;
            }
            fs.args = args;
        }
    }
    return fs;
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

// Byte-for-byte what Go's json.Marshal produces for the equivalent spec
// (struct tags in internal/spec.go; goccy/go-json preserves field order).
const go_table_spec_json =
    "{\"isTemp\":false,\"isView\":false,\"namePath\":[\"t1\"]," ++
    "\"columns\":[" ++
    "{\"name\":\"a\",\"type\":{\"name\":\"\",\"kind\":2,\"signatureKind\":0,\"elementType\":null,\"fieldTypes\":null},\"isNotNull\":false}," ++
    "{\"name\":\"b\",\"type\":{\"name\":\"\",\"kind\":8,\"signatureKind\":0,\"elementType\":null,\"fieldTypes\":null},\"isNotNull\":true}," ++
    "{\"name\":\"c\",\"type\":{\"name\":\"\",\"kind\":16,\"signatureKind\":0,\"elementType\":{\"name\":\"\",\"kind\":2,\"signatureKind\":0,\"elementType\":null,\"fieldTypes\":null},\"fieldTypes\":null},\"isNotNull\":false}" ++
    "],\"primaryKey\":[\"a\"],\"createMode\":1,\"query\":\"\"," ++
    "\"updatedAt\":\"2024-01-02T03:04:05Z\",\"createdAt\":\"2024-01-02T03:04:05Z\"}";

fn makeGoShapeSpec(alloc: std.mem.Allocator) !*TableSpec {
    const col_a = try alloc.create(ColumnSpec);
    col_a.* = .{ .name = "a", .type = try newSimpleType(alloc, .TYPE_INT64) };
    const col_b = try alloc.create(ColumnSpec);
    col_b.* = .{ .name = "b", .type = try newSimpleType(alloc, .TYPE_STRING), .is_not_null = true };
    const arr_type = try newSimpleType(alloc, .TYPE_ARRAY);
    arr_type.element_type = try newSimpleType(alloc, .TYPE_INT64);
    const col_c = try alloc.create(ColumnSpec);
    col_c.* = .{ .name = "c", .type = arr_type };

    const spec_ptr = try alloc.create(TableSpec);
    spec_ptr.* = .{
        .name_path = &.{"t1"},
        .columns = try alloc.dupe(*ColumnSpec, &.{ col_a, col_b, col_c }),
        .primary_key = &.{"a"},
        .create_mode = create_mode_create_default,
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    return spec_ptr;
}

test "TableSpec JSON matches Go marshaling byte-for-byte" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const spec_ptr = try makeGoShapeSpec(alloc);
    try testing.expectEqualStrings(go_table_spec_json, try spec_ptr.toJson(alloc));
}

test "TableSpec JSON round-trips through the Go shape" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const decoded = try tableSpecFromJson(alloc, go_table_spec_json);
    try testing.expectEqual(false, decoded.is_temp);
    try testing.expectEqual(false, decoded.is_view);
    try testing.expectEqual(@as(usize, 1), decoded.name_path.len);
    try testing.expectEqualStrings("t1", decoded.name_path[0]);
    try testing.expectEqual(@as(usize, 3), decoded.columns.len);
    try testing.expectEqual(pb.TypeKind.TYPE_STRING, decoded.columns[1].type.typeKind());
    try testing.expect(decoded.columns[1].is_not_null);
    try testing.expect(decoded.columns[2].type.isArray());
    try testing.expectEqual(
        pb.TypeKind.TYPE_INT64,
        decoded.columns[2].type.element_type.?.typeKind(),
    );
    try testing.expectEqual(create_mode_create_default, decoded.create_mode);
    try testing.expectEqualStrings("2024-01-02T03:04:05Z", decoded.updated_at);

    // Re-encoding reproduces the Go bytes exactly.
    try testing.expectEqualStrings(go_table_spec_json, try decoded.toJson(alloc));
}

test "SQLiteSchema golden strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A primary key changes nothing here: BigQuery keys are NOT ENFORCED, so
    // the table carries no constraint and the text matches the no-key case
    // exactly, trailing space included. The key becomes an index instead —
    // see pkIndexSchema and the tests below.
    const with_pk = try makeGoShapeSpec(alloc);
    try testing.expectEqualStrings(
        "CREATE TABLE `t1` (`a` INT,`b` TEXT NOT NULL,`c` TEXT) ",
        try with_pk.sqliteSchema(alloc),
    );

    // Without PRIMARY KEY: Go's format string leaves a trailing space.
    const no_pk = try makeGoShapeSpec(alloc);
    no_pk.primary_key = &.{};
    try testing.expectEqualStrings(
        "CREATE TABLE `t1` (`a` INT,`b` TEXT NOT NULL,`c` TEXT) ",
        try no_pk.sqliteSchema(alloc),
    );

    // IF NOT EXISTS mode.
    no_pk.create_mode = create_mode_create_if_not_exists;
    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `t1` (`a` INT,`b` TEXT NOT NULL,`c` TEXT) ",
        try no_pk.sqliteSchema(alloc),
    );

    // View.
    const view = try alloc.create(TableSpec);
    view.* = .{
        .is_view = true,
        .name_path = &.{ "ds", "v1" },
        .create_mode = create_mode_create_or_replace,
        .query = "SELECT 1",
    };
    try testing.expectEqualStrings("CREATE VIEW `ds_v1` AS SELECT 1", try view.sqliteSchema(alloc));

    // CREATE TABLE AS SELECT (non-view spec with a query).
    const ctas = try makeGoShapeSpec(alloc);
    ctas.query = "SELECT 1 AS a";
    try testing.expectEqualStrings("CREATE TABLE `t1` AS SELECT 1 AS a", try ctas.sqliteSchema(alloc));
}

test "pkIndexSchema lowers a primary key to a non-unique index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Non-unique on purpose: BigQuery keys are NOT ENFORCED, so this is a
    // planner hint and must not reject duplicates or NULLs.
    const one = try makeGoShapeSpec(alloc);
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS `t1.pk` ON `t1` (`a`)",
        (try one.pkIndexSchema(alloc)).?,
    );

    // Composite keys keep declaration order — an index on (a, b) does not
    // serve a lookup on b alone, so the order is load-bearing.
    const many = try makeGoShapeSpec(alloc);
    many.primary_key = &.{ "a", "b" };
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS `t1.pk` ON `t1` (`a`,`b`)",
        (try many.pkIndexSchema(alloc)).?,
    );

    const no_pk = try makeGoShapeSpec(alloc);
    no_pk.primary_key = &.{};
    try testing.expectEqual(@as(?[]u8, null), try no_pk.pkIndexSchema(alloc));

    const view = try alloc.create(TableSpec);
    view.* = .{
        .is_view = true,
        .name_path = &.{ "ds", "v1" },
        .primary_key = &.{"a"},
        .query = "SELECT 1",
    };
    try testing.expectEqual(@as(?[]u8, null), try view.pkIndexSchema(alloc));
}

test "options round-trip through JSON and stay out of it when empty" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Absent when there are none — this is what keeps the Go byte-for-byte
    // golden above valid, since Go's TableSpec has no options field.
    const bare = try makeGoShapeSpec(alloc);
    try testing.expect(std.mem.indexOf(u8, try bare.toJson(alloc), "\"options\"") == null);

    const with_opts = try makeGoShapeSpec(alloc);
    const opt = try alloc.create(OptionSpec);
    opt.* = .{ .name = "description", .type_name = "STRING", .value = "\"demo table\"" };
    with_opts.options = try alloc.dupe(*OptionSpec, &.{opt});

    const encoded = try with_opts.toJson(alloc);
    try testing.expect(std.mem.indexOf(u8, encoded, "\"options\":[{\"name\":\"description\"") != null);

    // The round trip is load-bearing: addNewTableSpec stores the re-parsed
    // spec, so anything toJson writes and tableSpecFromJson drops is lost.
    const decoded = try tableSpecFromJson(alloc, encoded);
    try testing.expectEqual(@as(usize, 1), decoded.options.len);
    try testing.expectEqualStrings("description", decoded.options[0].name);
    try testing.expectEqualStrings("STRING", decoded.options[0].type_name);
    try testing.expectEqualStrings("\"demo table\"", decoded.options[0].value);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));
}
