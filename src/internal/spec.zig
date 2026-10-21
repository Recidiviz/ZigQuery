//! What the catalog knows about each table, view, function and dataset, and the `Type` the
//! coordinator/extractor layer builds from the decoded `pb.TypeProto`.
//!
//! `catalog.zig` persists each spec as the JSON its `toJson` writes, in the `spec` column of
//! `zigquery_catalog`, and reads it back with the matching `*FromJson`.
// ephor:ignore-file ZA301 ZA302 ZA303 ZA304

const std = @import("std");
const pb = @import("../proto/resolved_ast.zig");

pub const Error = error{ OutOfMemory, Unimplemented, InvalidType };

/// A named entry of a composite type:
/// one field of a STRUCT's `field_types` or one argument of a FunctionSpec.
/// `is_not_null` is a STRUCT field declared `NOT NULL` (BigQuery's nested REQUIRED);
/// the DDL renderer turns it into a CHECK on the column.
///`description` is the field's OPTIONS(description). Both are serialised
/// only when set.
pub const NameWithType = struct {
    name: []const u8 = "",
    type: ?*Type = null,
    is_not_null: bool = false,
    description: []const u8 = "",
};

/// BigQuery's prefix for a REQUIRED field left NULL, as its streaming API reports it;
/// the table's row type is `Msg_0_CLOUD_QUERY_TABLE` for every table.
/// The full message appends `.<column>.<member>...` and a final `.`.
pub const missing_required_prefix = "Missing required field: Msg_0_CLOUD_QUERY_TABLE";

/// BigQuery's message when DML leaves a REQUIRED member NULL:
/// `Required field y.x cannot be null; error in writing field y`. `path` is
/// the dotted member path from the column down; `column` is its first segment.
pub fn requiredFieldMessage(
    alloc: std.mem.Allocator,
    column: []const u8,
    path: []const u8,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(
        alloc,
        "Required field {s} cannot be null; error in writing field {s}",
        .{ path, column },
    );
}

/// The `path` and `column` a `requiredFieldMessage` text names, or null for
/// any other text. The text may be embedded in a longer error.
pub const RequiredField = struct { path: []const u8, column: []const u8 };

pub fn requiredFieldFromMessage(text: []const u8) ?RequiredField {
    const head = "Required field ";
    const middle = " cannot be null; error in writing field ";
    const start = std.mem.indexOf(u8, text, head) orelse return null;
    const after_head = text[start + head.len ..];
    const mid = std.mem.indexOf(u8, after_head, middle) orelse return null;
    const path = after_head[0..mid];
    var column = after_head[mid + middle.len ..];
    if (std.mem.indexOf(u8, column, " (")) |paren| column = column[0..paren];
    if (path.len == 0 or column.len == 0) return null;
    return .{ .path = path, .column = column };
}

/// The column SQLite names in a NOT NULL constraint failure, or null for any other text.
/// The text may be embedded in a longer error i.e.:
/// `constraint failed: NOT NULL constraint failed: <table>.<column> (19)`.
pub fn notNullColumnFromMessage(text: []const u8) ?[]const u8 {
    const marker = "NOT NULL constraint failed: ";
    const start = std.mem.indexOf(u8, text, marker) orelse return null;
    var rest = text[start + marker.len ..];
    if (std.mem.lastIndexOf(u8, rest, " (")) |paren| rest = rest[0..paren];
    const dot = std.mem.lastIndexOfScalar(u8, rest, '.') orelse return null;
    const column = rest[dot + 1 ..];
    return if (column.len == 0) null else column;
}

/// A deep copy of `t` in `arena`, so it can outlive whatever produced it.
///
/// A statement's output column types live in that statement's arena and die
/// with it, which is a problem for anything that wants to keep them —
/// registering a `TableSpec` the catalog will hold by pointer, or retaining a
/// result set to render later. Both of those want the whole tree, not the root:
/// an ARRAY's element type and a STRUCT's fields are pointers into the same
/// doomed arena.
pub fn cloneType(arena: std.mem.Allocator, t: *const Type) std.mem.Allocator.Error!*Type {
    const out = try arena.create(Type);
    out.* = .{
        .kind = t.kind,
        .signature_kind = t.signature_kind,
        .element_type = if (t.element_type) |e| try cloneType(arena, e) else null,
        .field_types = &.{},
    };
    if (t.field_types.len == 0) return out;
    const fields = try arena.alloc(*NameWithType, t.field_types.len);
    for (t.field_types, fields) |src, *dst| {
        const f = try arena.create(NameWithType);
        f.* = .{
            .name = try arena.dupe(u8, src.name),
            .type = if (src.type) |ft| try cloneType(arena, ft) else null,
            .is_not_null = src.is_not_null,
            .description = try arena.dupe(u8, src.description),
        };
        dst.* = f;
    }
    out.field_types = fields;
    return out;
}

/// A column, field or function-argument type. `kind` holds the engine TypeKind int (pb.TypeKind);
/// `signature_kind` holds the SignatureArgumentKind int for templated function-argument types,
/// and is 0 otherwise.
pub const Type = struct {
    kind: i32 = 0,
    signature_kind: i32 = 0,
    element_type: ?*Type = null,
    field_types: []const *NameWithType = &.{},

    /// Go Type.kind().
    pub fn typeKind(self: *const Type) pb.TypeKind {
        return @fromBackingInt(@intCast(self.kind));
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
            .TYPE_RANGE => {
                const elem = self.element_type orelse return error.InvalidType;
                return std.fmt.allocPrint(alloc, "RANGE<{s}>", .{try elem.formatType(alloc)});
            },
            else => return bigQueryTypeName(self.typeKind()),
        }
    }
};

/// A Type built from the decoded TypeProto
/// (type_kind + array_type.element_type + struct_type.field recursion).
pub fn newTypeFromProto(alloc: std.mem.Allocator, tp: *const pb.TypeProto) Error!*Type {
    const t = try alloc.create(Type);
    t.* = .{ .kind = @backingInt(tp.type_kind orelse .TYPE_UNKNOWN) };
    switch (tp.type_kind orelse .TYPE_UNKNOWN) {
        .TYPE_ARRAY => {
            const at = tp.array_type orelse return error.InvalidType;
            const elem = at.element_type orelse return error.InvalidType;
            t.element_type = try newTypeFromProto(alloc, elem);
        },
        // RANGE reuses element_type, the same slot ARRAY uses. Without this
        // the element is dropped silently, and nothing downstream can tell a
        // RANGE<DATE> from a RANGE<TIMESTAMP> — including catalog.zig, which
        // then emits a TypeProto googlesql rejects outright.
        .TYPE_RANGE => {
            const rt = tp.range_type orelse return error.InvalidType;
            const elem = rt.element_type orelse return error.InvalidType;
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
        // Unparameterised: formatType above renders RANGE<elem>, and this
        // is only reached for a bare kind with no element in hand.
        .TYPE_RANGE => "RANGE",
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
        .TYPE_RANGE,
        => "TEXT",
        else => "UNKNOWN",
    };
}

// ----------------------------------------------------------------------
// TableSpec / ColumnSpec (Go spec.go TableSpec, ColumnSpec)
// ----------------------------------------------------------------------

/// Go name_path.go formatPath: "_"-joined (the canonical SQLite name).
pub fn formatPath(alloc: std.mem.Allocator, path: []const []const u8) error{OutOfMemory}![]u8 {
    return std.mem.join(alloc, "_", path);
}

/// Go spec.go ColumnSpec.
pub const ColumnSpec = struct {
    name: []const u8 = "",
    type: *Type,
    is_not_null: bool = false,
    /// OPTIONS(description), for the metadata API's schema. Serialised only when set.
    description: []const u8 = "",

    /// Go ColumnSpec.SQLiteSchema: "`name` TYPE[ NOT NULL]".
    pub fn sqliteSchema(self: *const ColumnSpec, alloc: std.mem.Allocator) Error![]u8 {
        const typ = sqliteTypeName(self.type.typeKind());
        if (self.is_not_null) {
            return std.fmt.allocPrint(alloc, "`{s}` {s} NOT NULL", .{ self.name, typ });
        }
        return std.fmt.allocPrint(alloc, "`{s}` {s}", .{ self.name, typ });
    }
};

/// A STRUCT member declared NOT NULL, located by position so the check walks
/// the stored value without comparing names: `1.[].0` is the first member of
/// every element of the array in the column's second member.
const RequiredMember = struct {
    position: []const u8,
    /// The `requiredFieldMessage` a NULL there raises, rendered once here so
    /// the check allocates nothing.
    message: []const u8,
};

/// CONSTRAINT `col` CHECK (zigquery_required(`col`, '<pos>', '<msg>', ...))`
/// for a column with NOT NULL members somewhere inside its type, else null.
fn requiredCheckConstraintSQL(alloc: std.mem.Allocator, col: *const ColumnSpec) Error!?[]u8 {
    var members: std.ArrayList(RequiredMember) = .empty;
    try collectRequiredMembers(alloc, col.type, "", col.name, &members);
    if (members.items.len == 0) return null;

    var out: std.ArrayList(u8) = .empty;
    try out.print(alloc, "CONSTRAINT `{s}` CHECK (zigquery_required(`{s}`", .{
        col.name, col.name,
    });
    for (members.items) |m| {
        try out.append(alloc, ',');
        try appendSqlStringLiteral(&out, alloc, m.position);
        try out.append(alloc, ',');
        try appendSqlStringLiteral(&out, alloc, m.message);
    }
    try out.appendSlice(alloc, "))");
    return try out.toOwnedSlice(alloc);
}

/// `'text'` with every `'` doubled: a member's name can carry one, and it
/// lands in the message.
fn appendSqlStringLiteral(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    text: []const u8,
) error{OutOfMemory}!void {
    try out.append(alloc, '\'');
    for (text) |c| {
        if (c == '\'') try out.append(alloc, '\'');
        try out.append(alloc, c);
    }
    try out.append(alloc, '\'');
}

fn hasNotNullMember(t: *const Type) bool {
    if (t.isArray()) return if (t.element_type) |elem| hasNotNullMember(elem) else false;
    if (!t.isStruct()) return false;
    for (t.field_types) |field| {
        if (field.is_not_null) return true;
        if (field.type) |ft| {
            if (hasNotNullMember(ft)) return true;
        }
    }
    return false;
}

fn collectRequiredMembers(
    alloc: std.mem.Allocator,
    t: *const Type,
    position: []const u8,
    names: []const u8,
    members: *std.ArrayList(RequiredMember),
) Error!void {
    return collectRequiredMembersOf(alloc, t, position, names, names, members);
}

/// `column` is the column's own name, carried down unchanged: a name may
/// contain a `.`, so it cannot be recovered from `names` by splitting.
fn collectRequiredMembersOf(
    alloc: std.mem.Allocator,
    t: *const Type,
    position: []const u8,
    names: []const u8,
    column: []const u8,
    members: *std.ArrayList(RequiredMember),
) Error!void {
    if (t.isArray()) {
        const elem = t.element_type orelse return;
        const inner = if (position.len == 0)
            "[]"
        else
            try std.fmt.allocPrint(alloc, "{s}.[]", .{position});
        return collectRequiredMembersOf(alloc, elem, inner, names, column, members);
    }
    if (!t.isStruct()) return;
    for (t.field_types, 0..) |field, i| {
        const pos = if (position.len == 0)
            try std.fmt.allocPrint(alloc, "{d}", .{i})
        else
            try std.fmt.allocPrint(alloc, "{s}.{d}", .{ position, i });
        const path = try std.fmt.allocPrint(alloc, "{s}.{s}", .{ names, field.name });
        if (field.is_not_null) {
            try members.append(alloc, .{
                .position = pos,
                .message = try requiredFieldMessage(alloc, column, path),
            });
        }
        if (field.type) |ft| try collectRequiredMembersOf(alloc, ft, pos, path, column, members);
    }
}

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

/// A CREATE TABLE's PARTITION BY, reduced to what the metadata API reports for it:
/// BigQuery's `timePartitioning` or `rangePartitioning` resource.
/// The engine does not partition anything; this is table metadata only.
pub const Partitioning = union(enum) {
    /// `PARTITION BY d`, `DATE(ts)`, `TIMESTAMP_TRUNC(ts, HOUR)`,
    /// `DATE_TRUNC(d, MONTH)`, `DATETIME_TRUNC(dt, YEAR)`.
    time: TimePartitioning,
    /// `PARTITION BY RANGE_BUCKET(n, GENERATE_ARRAY(start, end, interval))`.
    range: RangePartitioning,

    pub const TimePartitioning = struct {
        field: []const u8,
        unit: TimeUnit,
    };

    /// `timePartitioning.type`; the tag names are BigQuery's spellings.
    pub const TimeUnit = enum { HOUR, DAY, MONTH, YEAR };

    pub const RangePartitioning = struct {
        field: []const u8,
        start: i64,
        end: i64,
        interval: i64,
    };
};

/// A dataset the catalog has been told exists, independent of any table it
/// may or may not hold.
///
/// Go has no analogue: the reference emulator keeps datasets only in its
/// metadata store. Here the catalog is the single store for them, as it is
/// for tables since the metadata consolidation, so the REST resource rides
/// on the spec (`metadata`) and the spec persists as a `dataset` row in
/// `zigquery_catalog`.
pub const DatasetSpec = struct {
    /// `[project, dataset]`.
    name_path: []const []const u8 = &.{},
    updated_at: []const u8 = "", // RFC3339 timestamp
    created_at: []const u8 = "", // RFC3339 timestamp
    /// The metadata API's view of the dataset: the resource JSON a client
    /// posted or patched, echoed back by datasets.get. Empty for a dataset
    /// the catalog only inferred.
    metadata: []const u8 = "",
    /// Inferred from a table's path rather than declared by anyone: the
    /// catalog registers one for every dataset a table lands in, so
    /// INFORMATION_SCHEMA can report it. Memory-only, never persisted, and
    /// invisible to the metadata API; an explicit registration under the
    /// same name replaces it.
    is_synthetic: bool = false,

    /// The canonical "_"-joined name, which the `dataset` kind keys to the`zigquery_catalog` row.
    pub fn datasetName(self: *const DatasetSpec, alloc: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return formatPath(alloc, self.name_path);
    }

    pub fn toJson(self: *const DatasetSpec, alloc: std.mem.Allocator) Error![]u8 {
        return specToJson(alloc, self.*);
    }
};

pub fn datasetSpecFromJson(alloc: std.mem.Allocator, json_text: []const u8) Error!*DatasetSpec {
    return specFromJson(DatasetSpec, alloc, json_text);
}

/// A table or view that a view's query reads.
pub const ViewDependency = struct {
    /// Canonical ("_"-joined) name.
    name: []const u8,
    /// The dependency's `catalog.shapeFingerprint` when the view was last analyzed, or
    /// `missing_fingerprint` when it did not exist then.
    fingerprint: u64,
};

/// The fingerprint of a name the catalog does not hold.
pub const missing_fingerprint: u64 = 0;

/// A representation of a table in BigQuery
pub const TableSpec = struct {
    is_temp: bool = false,
    is_view: bool = false,
    name_path: []const []const u8 = &.{},
    columns: []const *ColumnSpec = &.{},
    primary_key: []const []const u8 = &.{},
    /// Persisted in TableSpec JSON (`createMode`) as the proto enum's number.
    create_mode: pb.ResolvedCreateStatementEnums_CreateMode = .CREATE_DEFAULT,
    query: []const u8 = "",
    updated_at: []const u8 = "", // RFC3339 timestamp
    created_at: []const u8 = "", // RFC3339 timestamp
    /// DDL OPTIONS. Serialised only when non-empty.
    options: []const *OptionSpec = &.{},
    /// DDL PARTITION BY, for the metadata API to report when no client posted
    /// a partitioning of its own. Serialised only when set, like `options`.
    partitioning: ?Partitioning = null,
    /// DDL CLUSTER BY column names, in order. Serialised only when non-empty.
    clustering: []const []const u8 = &.{},
    /// DDL OPTIONS(description), for the metadata API to report when no client posted one.
    /// Serialised only when set.
    description: []const u8 = "",
    /// The metadata API's view of the table: the resource keys a client
    /// posted (schema with nested modes and descriptions, clustering,
    /// partitioning, labels, description, view, ...), as one JSON object's
    /// text. Opaque to the engine and carried as a JSON string, so the bytes
    /// come back exactly as they went in. Empty for a table nobody posted.
    /// Serialised only when non-empty, like `options`.
    metadata: []const u8 = "",
    /// A view's defining query as the client wrote it, in GoogleSQL. `query`
    /// holds the SQLite translation the engine runs; the metadata API reports
    /// this one. Serialised only when non-empty.
    source_sql: []const u8 = "",
    /// A view whose CREATE VIEW listed its column names.
    /// `columns` holds those names, and a refresh lists them again. Serialised only when set.
    explicit_columns: bool = false,
    /// A view's columns as its query analyzes against the tables it reads today, once a refresh
    /// has re-analyzed it. BigQuery binds a view's query late, so a query through the view sees
    /// these, while the metadata API and INFORMATION_SCHEMA keep reporting `columns`, the schema
    /// the view was created with. Empty until a refresh changes them. Serialised only when set.
    analysis_columns: []const *ColumnSpec = &.{},
    /// Why a view's query no longer analyzes, worded as BigQuery reports it to a query that reads
    /// the view. Empty while it analyzes. Serialised only when set.
    invalid_reason: []const u8 = "",
    /// The tables and views a view's query read when it was last analyzed, each with the shape it
    /// had then. Empty for a table. Serialised only when non-empty.
    dependencies: []const ViewDependency = &.{},
    /// Registered for the analyzer only, never persisted: a job's result table
    /// or an INFORMATION_SCHEMA view. Runtime state, not part of the JSON.
    is_synthetic: bool = false,

    /// The columns the analyzer resolves this table or view against: `analysis_columns` once a
    /// refresh has set them, `columns` otherwise.
    pub fn analyzedColumns(self: *const TableSpec) []const *ColumnSpec {
        return if (self.analysis_columns.len > 0) self.analysis_columns else self.columns;
    }

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

    /// The CREATE TABLE or CREATE VIEW that makes the SQLite object this spec describes.
    pub fn sqliteSchema(self: *const TableSpec, alloc: std.mem.Allocator) Error![]u8 {
        if (self.is_view) return self.viewSqliteSchema(alloc);
        const table_name = try self.tableName(alloc);
        if (self.query.len != 0) {
            return std.fmt.allocPrint(alloc, "CREATE TABLE `{s}` AS {s}", .{ table_name, self.query });
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
        const stmt: []const u8 = switch (self.create_mode) {
            .CREATE_DEFAULT, .CREATE_OR_REPLACE => "CREATE TABLE",
            .CREATE_IF_NOT_EXISTS => "CREATE TABLE IF NOT EXISTS",
            _ => return error.InvalidType,
        };
        return std.fmt.allocPrint(alloc, "{s} `{s}` ({s})", .{
            stmt,
            table_name,
            try self.declaredColumnsSql(alloc),
        });
    }

    /// `CREATE TABLE `name` (<declared columns>)`: the declared shape under `name`, for a CTAS
    /// whose rows must pass its NOT NULL columns and members, which `CREATE TABLE ... AS` does not
    /// carry.
    pub fn declaredSchemaAs(
        self: *const TableSpec,
        alloc: std.mem.Allocator,
        name: []const u8,
    ) Error![]u8 {
        return std.fmt.allocPrint(alloc, "CREATE TABLE `{s}` ({s})", .{
            name,
            try self.declaredColumnsSql(alloc),
        });
    }

    /// The column definitions and the CHECK constraints for their NOT NULL STRUCT members,
    /// comma-joined for a `CREATE TABLE` column list.
    fn declaredColumnsSql(self: *const TableSpec, alloc: std.mem.Allocator) Error![]u8 {
        var columns: std.ArrayList([]const u8) = .empty;
        for (self.columns) |c| {
            try columns.append(alloc, try c.sqliteSchema(alloc));
        }
        for (self.columns) |c| {
            if (try requiredCheckConstraintSQL(alloc, c)) |check| try columns.append(alloc, check);
        }
        return std.mem.join(alloc, ",", columns.items);
    }

    /// Whether a column, or a STRUCT member anywhere inside one, is NOT NULL.
    pub fn hasNotNull(self: *const TableSpec) bool {
        for (self.columns) |c| {
            if (c.is_not_null or hasNotNullMember(c.type)) return true;
        }
        return false;
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

    fn viewSqliteSchema(self: *const TableSpec, alloc: std.mem.Allocator) Error![]u8 {
        const stmt: []const u8 = switch (self.create_mode) {
            .CREATE_DEFAULT, .CREATE_OR_REPLACE => "CREATE VIEW",
            .CREATE_IF_NOT_EXISTS => "CREATE VIEW IF NOT EXISTS",
            _ => return error.InvalidType,
        };
        return std.fmt.allocPrint(alloc, "{s} `{s}` AS {s}", .{
            stmt,
            try self.tableName(alloc),
            self.query,
        });
    }

    pub fn toJson(self: *const TableSpec, alloc: std.mem.Allocator) Error![]u8 {
        return specToJson(alloc, self.*);
    }
};

/// Minimal JSON string escaping (", \, control chars) for the identifier, timestamp and SQL-text
/// strings that appear in specs.
pub fn appendJsonString(
    out: *std.ArrayList(u8),
    alloc: std.mem.Allocator,
    s: []const u8,
) error{OutOfMemory}!void {
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

/// The catalog's persisted form of a spec: its fields, as std.json writes them.
fn specToJson(alloc: std.mem.Allocator, value: anytype) Error![]u8 {
    return std.json.Stringify.valueAlloc(alloc, value, .{});
}

/// The spec `specToJson` wrote. A missing key is the field's default; a key of the wrong type, or
/// one the struct has no field for, is `error.InvalidType`. All returned memory is from `alloc`.
fn specFromJson(comptime T: type, alloc: std.mem.Allocator, json_text: []const u8) Error!*T {
    const out = try alloc.create(T);
    const options: std.json.ParseOptions = .{ .allocate = .alloc_always };
    out.* = std.json.parseFromSliceLeaky(T, alloc, json_text, options) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidType,
    };
    return out;
}

pub fn tableSpecFromJson(alloc: std.mem.Allocator, json_text: []const u8) Error!*TableSpec {
    return specFromJson(TableSpec, alloc, json_text);
}

/// Convenience constructor for a scalar Type of the given kind.
pub fn newSimpleType(alloc: std.mem.Allocator, kind: pb.TypeKind) error{OutOfMemory}!*Type {
    const t = try alloc.create(Type);
    t.* = .{ .kind = @backingInt(kind) };
    return t;
}

/// Go isTemplatedSignatureKind, translated to the proto SignatureArgumentKind
/// values this port stores in `Type.signature_kind`: ARG_KIND_EXPR_FIXED is
/// the 0 value, so any nonzero kind denotes a templated argument.
pub fn isTemplatedSignatureKind(k: i32) bool {
    return k != 0;
}

// ----------------------------------------------------------------------
// FunctionSpec: SQL/JS user-defined functions plus the catalog-seeded
// MISSING_FUNCTIONS (contains_substr, min_by, max_by).
// ----------------------------------------------------------------------

/// Name -> spec map threaded into the transformer for CallSQL rewriting
/// (Go Catalog.funcMap / funcMapFromContext).
pub const FuncMap = std.StringHashMap(*FunctionSpec);

pub const FunctionSpec = struct {
    is_temp: bool = false,
    name_path: []const []const u8 = &.{},
    language: []const u8 = "",
    args: []const *NameWithType = &.{},
    return_type: ?*Type = null,
    /// Rendered SQL body with @argname placeholders; null for
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
    /// Bodyless specs are JS functions (Go inlines a zigquery_eval_javascript
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

    pub fn toJson(self: *const FunctionSpec, alloc: std.mem.Allocator) Error![]u8 {
        return specToJson(alloc, self.*);
    }
};

pub fn functionSpecFromJson(alloc: std.mem.Allocator, json_text: []const u8) Error!*FunctionSpec {
    return specFromJson(FunctionSpec, alloc, json_text);
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

fn makeTestSpec(alloc: std.mem.Allocator) !*TableSpec {
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
        .create_mode = .CREATE_DEFAULT,
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    return spec_ptr;
}

test "TableSpec JSON round-trips" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const encoded = try (try makeTestSpec(alloc)).toJson(alloc);
    const decoded = try tableSpecFromJson(alloc, encoded);
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
    try testing.expectEqualStrings("a", decoded.primary_key[0]);
    try testing.expectEqualStrings("2024-01-02T03:04:05Z", decoded.updated_at);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));

    // A key the spec does not have yet is its default.
    const bare = try tableSpecFromJson(alloc, "{\"name_path\":[\"t\"]}");
    try testing.expectEqualStrings("t", bare.name_path[0]);
    try testing.expectEqual(@as(usize, 0), bare.columns.len);
    try testing.expectEqual(
        pb.ResolvedCreateStatementEnums_CreateMode.CREATE_DEFAULT,
        bare.create_mode,
    );
}

test "a spec field of the wrong JSON type, or one the spec does not have, is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const refused = [_][]const u8{
        "{\"primary_key\":null}",
        "{\"primary_key\":{}}",
        "{\"is_temp\":\"true\"}",
        "{\"query\":1}",
        "{\"columns\":[{\"name\":\"a\"}]}",
        "{\"create_mode\":\"CREATE_SOMETHING\"}",
        "{\"namePath\":[\"t\"]}",
    };
    for (refused) |json| {
        try testing.expectError(error.InvalidType, tableSpecFromJson(alloc, json));
    }
    try testing.expectError(error.InvalidType, functionSpecFromJson(alloc, "{\"name\":[\"f\"]}"));
    try testing.expectError(error.InvalidType, datasetSpecFromJson(alloc, "{\"name_path\":1}"));
}

test "FunctionSpec JSON round-trips, templated argument kinds included" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const x = try alloc.create(NameWithType);
    x.* = .{ .name = "x", .type = try newSimpleType(alloc, .TYPE_INT64) };
    const y = try alloc.create(NameWithType);
    y.* = .{ .name = "y", .type = try alloc.create(Type) };
    y.type.?.* = .{ .signature_kind = 3 };
    const sql_fn: FunctionSpec = .{
        .is_temp = true,
        .name_path = &.{ "p", "d", "f" },
        .language = "SQL",
        .args = &.{ x, y },
        .return_type = try newSimpleType(alloc, .TYPE_INT64),
        .body = "@x + 1",
        .code = "x + 1",
        .is_aggregate = true,
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    const encoded = try sql_fn.toJson(alloc);
    const decoded = try functionSpecFromJson(alloc, encoded);
    try testing.expect(decoded.is_temp);
    try testing.expectEqualStrings("f", decoded.name_path[2]);
    try testing.expectEqualStrings("SQL", decoded.language);
    try testing.expectEqualStrings("y", decoded.args[1].name);
    try testing.expectEqual(@as(i32, 3), decoded.args[1].type.?.signature_kind);
    try testing.expectEqual(pb.TypeKind.TYPE_INT64, decoded.return_type.?.typeKind());
    try testing.expectEqualStrings("@x + 1", decoded.body.?);
    try testing.expectEqualStrings("x + 1", decoded.code);
    try testing.expect(decoded.is_aggregate);
    try testing.expectEqualStrings(sql_fn.updated_at, decoded.updated_at);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));

    // A missing body and an empty one stay apart.
    const bodyless: FunctionSpec = .{ .name_path = &.{"g"} };
    try testing.expect((try functionSpecFromJson(alloc, try bodyless.toJson(alloc))).body == null);
    const empty: FunctionSpec = .{ .name_path = &.{"g"}, .body = "" };
    const empty_back = try functionSpecFromJson(alloc, try empty.toJson(alloc));
    try testing.expectEqualStrings("", empty_back.body.?);
}

test "a table's flags, query and create mode round-trip through JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const table_spec = try makeTestSpec(alloc);
    table_spec.is_temp = true;
    table_spec.is_view = true;
    table_spec.query = "SELECT 1";
    table_spec.create_mode = .CREATE_IF_NOT_EXISTS;
    const decoded = try tableSpecFromJson(alloc, try table_spec.toJson(alloc));
    try testing.expect(decoded.is_temp);
    try testing.expect(decoded.is_view);
    try testing.expectEqualStrings("SELECT 1", decoded.query);
    try testing.expectEqual(
        pb.ResolvedCreateStatementEnums_CreateMode.CREATE_IF_NOT_EXISTS,
        decoded.create_mode,
    );
}

test "SQLiteSchema golden strings" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // A primary key changes nothing here: BigQuery keys are NOT ENFORCED, so
    // the table carries no constraint and the text matches the no-key case.
    // The key becomes an index instead — see pkIndexSchema and the tests below.
    const with_pk = try makeTestSpec(alloc);
    try testing.expectEqualStrings(
        "CREATE TABLE `t1` (`a` INT,`b` TEXT NOT NULL,`c` TEXT)",
        try with_pk.sqliteSchema(alloc),
    );

    const no_pk = try makeTestSpec(alloc);
    no_pk.primary_key = &.{};
    try testing.expectEqualStrings(
        "CREATE TABLE `t1` (`a` INT,`b` TEXT NOT NULL,`c` TEXT)",
        try no_pk.sqliteSchema(alloc),
    );

    // IF NOT EXISTS mode.
    no_pk.create_mode = .CREATE_IF_NOT_EXISTS;
    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `t1` (`a` INT,`b` TEXT NOT NULL,`c` TEXT)",
        try no_pk.sqliteSchema(alloc),
    );

    // View.
    const view = try alloc.create(TableSpec);
    view.* = .{
        .is_view = true,
        .name_path = &.{ "ds", "v1" },
        .create_mode = .CREATE_OR_REPLACE,
        .query = "SELECT 1",
    };
    try testing.expectEqualStrings("CREATE VIEW `ds_v1` AS SELECT 1", try view.sqliteSchema(alloc));

    // CREATE TABLE AS SELECT (non-view spec with a query).
    const ctas = try makeTestSpec(alloc);
    ctas.query = "SELECT 1 AS a";
    try testing.expectEqualStrings("CREATE TABLE `t1` AS SELECT 1 AS a", try ctas.sqliteSchema(alloc));
}

test "pkIndexSchema lowers a primary key to a non-unique index" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // Non-unique on purpose: BigQuery keys are NOT ENFORCED, so this is a
    // planner hint and must not reject duplicates or NULLs.
    const one = try makeTestSpec(alloc);
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS `t1.pk` ON `t1` (`a`)",
        (try one.pkIndexSchema(alloc)).?,
    );

    // Composite keys keep declaration order — an index on (a, b) does not
    // serve a lookup on b alone, so the order is load-bearing.
    const many = try makeTestSpec(alloc);
    many.primary_key = &.{ "a", "b" };
    try testing.expectEqualStrings(
        "CREATE INDEX IF NOT EXISTS `t1.pk` ON `t1` (`a`,`b`)",
        (try many.pkIndexSchema(alloc)).?,
    );

    const no_pk = try makeTestSpec(alloc);
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

test "a NOT NULL STRUCT member round-trips through the type JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const with = try makeTestSpec(alloc);
    const x = try alloc.create(NameWithType);
    x.* = .{ .name = "x", .type = try newSimpleType(alloc, .TYPE_INT64), .is_not_null = true };
    const y = try alloc.create(NameWithType);
    y.* = .{ .name = "y", .type = try newSimpleType(alloc, .TYPE_STRING) };
    const record = try alloc.create(Type);
    record.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = &.{ x, y } };
    const col = try alloc.create(ColumnSpec);
    col.* = .{ .name = "r", .type = record };
    with.columns = &.{col};

    const encoded = try with.toJson(alloc);
    const decoded = try tableSpecFromJson(alloc, encoded);
    try testing.expect(decoded.columns[0].type.field_types[0].is_not_null);
    try testing.expect(!decoded.columns[0].type.field_types[1].is_not_null);
    try testing.expect((try cloneType(alloc, record)).field_types[0].is_not_null);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));
}

test "SQLiteSchema adds one CHECK per column with NOT NULL members, positioned" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // r STRUCT<x INT64 NOT NULL, inner STRUCT<y STRING NOT NULL>>,
    // rs ARRAY<STRUCT<k INT64 NOT NULL>>, plain STRUCT<z INT64>
    const x = try alloc.create(NameWithType);
    x.* = .{ .name = "x", .type = try newSimpleType(alloc, .TYPE_INT64), .is_not_null = true };
    const y = try alloc.create(NameWithType);
    y.* = .{ .name = "y", .type = try newSimpleType(alloc, .TYPE_STRING), .is_not_null = true };
    const inner_t = try alloc.create(Type);
    inner_t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = &.{y} };
    const inner = try alloc.create(NameWithType);
    inner.* = .{ .name = "inner", .type = inner_t };
    const r_t = try alloc.create(Type);
    r_t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = &.{ x, inner } };

    const k = try alloc.create(NameWithType);
    k.* = .{ .name = "k", .type = try newSimpleType(alloc, .TYPE_INT64), .is_not_null = true };
    const elem_t = try alloc.create(Type);
    elem_t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = &.{k} };
    const rs_t = try alloc.create(Type);
    rs_t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_ARRAY), .element_type = elem_t };

    const z = try alloc.create(NameWithType);
    z.* = .{ .name = "z", .type = try newSimpleType(alloc, .TYPE_INT64) };
    const plain_t = try alloc.create(Type);
    plain_t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = &.{z} };

    const r = try alloc.create(ColumnSpec);
    r.* = .{ .name = "r", .type = r_t };
    const rs = try alloc.create(ColumnSpec);
    rs.* = .{ .name = "rs", .type = rs_t };
    const plain = try alloc.create(ColumnSpec);
    plain.* = .{ .name = "plain", .type = plain_t };
    const t = try alloc.create(TableSpec);
    t.* = .{
        .name_path = &.{"t"},
        .columns = &.{ r, rs, plain },
        .create_mode = .CREATE_DEFAULT,
    };

    try testing.expectEqualStrings(
        "CREATE TABLE `t` (`r` TEXT,`rs` TEXT,`plain` TEXT," ++
            "CONSTRAINT `r` CHECK (zigquery_required(`r`," ++
            "'0','Required field r.x cannot be null; error in writing field r'," ++
            "'1.0','Required field r.inner.y cannot be null; error in writing field r'))," ++
            "CONSTRAINT `rs` CHECK (zigquery_required(`rs`," ++
            "'[].0','Required field rs.k cannot be null; error in writing field rs')))",
        try t.sqliteSchema(alloc),
    );
}

test "SQLiteSchema quotes a member name's apostrophe and keeps a dotted column name whole" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const its = try alloc.create(NameWithType);
    its.* = .{ .name = "it's", .type = try newSimpleType(alloc, .TYPE_INT64), .is_not_null = true };
    const r_t = try alloc.create(Type);
    r_t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = &.{its} };
    const r = try alloc.create(ColumnSpec);
    r.* = .{ .name = "a.b", .type = r_t };
    const t = try alloc.create(TableSpec);
    t.* = .{ .name_path = &.{"t"}, .columns = &.{r}, .create_mode = .CREATE_DEFAULT };

    try testing.expectEqualStrings(
        "CREATE TABLE `t` (`a.b` TEXT,CONSTRAINT `a.b` CHECK (zigquery_required(`a.b`," ++
            "'0','Required field a.b.it''s cannot be null; error in writing field a.b')))",
        try t.sqliteSchema(alloc),
    );
}

test "declaredSchemaAs names the declared columns under the given name, whatever the CTAS mode" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const ctas = try makeTestSpec(alloc);
    ctas.query = "SELECT 1 AS a, 'x' AS b, [1] AS c";
    ctas.create_mode = .CREATE_IF_NOT_EXISTS;
    try testing.expectEqualStrings(
        "CREATE TABLE `scratch` (`a` INT,`b` TEXT NOT NULL,`c` TEXT)",
        try ctas.declaredSchemaAs(alloc, "scratch"),
    );

    // r STRUCT<x INT64 NOT NULL>
    const x = try alloc.create(NameWithType);
    x.* = .{ .name = "x", .type = try newSimpleType(alloc, .TYPE_INT64), .is_not_null = true };
    const r_t = try alloc.create(Type);
    r_t.* = .{ .kind = @backingInt(pb.TypeKind.TYPE_STRUCT), .field_types = &.{x} };
    const r = try alloc.create(ColumnSpec);
    r.* = .{ .name = "r", .type = r_t };
    const members = try alloc.create(TableSpec);
    members.* = .{
        .name_path = &.{"t"},
        .columns = &.{r},
        .create_mode = .CREATE_OR_REPLACE,
        .query = "SELECT STRUCT(1 AS x) AS r",
    };
    try testing.expectEqualStrings(
        "CREATE TABLE `t` (`r` TEXT,CONSTRAINT `r` CHECK (zigquery_required(`r`," ++
            "'0','Required field r.x cannot be null; error in writing field r')))",
        try members.declaredSchemaAs(alloc, "t"),
    );
}

test "requiredFieldFromMessage reads the path and column back, embedded or not" {
    const ui_text = "Required field y.x cannot be null; error in writing field y";
    const bare = requiredFieldFromMessage(ui_text).?;
    try testing.expectEqualStrings("y.x", bare.path);
    try testing.expectEqualStrings("y", bare.column);
    const wrapped = requiredFieldFromMessage(
        "constraint failed: Required field r.inner.y cannot be null; error in writing field r (19)",
    ).?;
    try testing.expectEqualStrings("r.inner.y", wrapped.path);
    try testing.expectEqualStrings("r", wrapped.column);
    const other = "NOT NULL constraint failed: t.a";
    try testing.expectEqual(@as(?RequiredField, null), requiredFieldFromMessage(other));
    const empty = "Required field  cannot be null; error in writing field ";
    try testing.expectEqual(@as(?RequiredField, null), requiredFieldFromMessage(empty));
}

test "metadata and source SQL round-trip through JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const with = try makeTestSpec(alloc);
    // The resource text is carried as a string: its own quotes and nesting
    // are escaped, never re-serialised.
    with.metadata =
        \\{"description":"he said \"hi\"","schema":{"fields":[{"name":"a","type":"INTEGER"}]}}
    ;
    with.source_sql = "SELECT a FROM `p.d.t`";
    with.explicit_columns = true;
    const encoded = try with.toJson(alloc);
    const decoded = try tableSpecFromJson(alloc, encoded);
    try testing.expectEqualStrings(with.metadata, decoded.metadata);
    try testing.expectEqualStrings(with.source_sql, decoded.source_sql);
    try testing.expect(decoded.explicit_columns);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));
}

test "TableSpec JSON round-trips a view's refresh state" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const with = try makeTestSpec(alloc);
    const col = try alloc.create(ColumnSpec);
    col.* = .{ .name = "a", .type = try newSimpleType(alloc, .TYPE_STRING) };
    const analysis_columns = [_]*ColumnSpec{col};
    with.analysis_columns = &analysis_columns;
    with.invalid_reason = "Unrecognized name: b; failed to parse view 'd.v'";
    const dependencies = [_]ViewDependency{
        .{ .name = "p_d_t", .fingerprint = std.math.maxInt(u64) },
        .{ .name = "p_d_gone", .fingerprint = missing_fingerprint },
    };
    with.dependencies = &dependencies;

    const encoded = try with.toJson(alloc);
    const decoded = try tableSpecFromJson(alloc, encoded);
    try testing.expectEqualStrings("a", decoded.analyzedColumns()[0].name);
    try testing.expectEqualStrings(with.invalid_reason, decoded.invalid_reason);
    try testing.expectEqual(@as(usize, 2), decoded.dependencies.len);
    try testing.expectEqualStrings("p_d_t", decoded.dependencies[0].name);
    try testing.expectEqual(std.math.maxInt(u64), decoded.dependencies[0].fingerprint);
    try testing.expectEqual(missing_fingerprint, decoded.dependencies[1].fingerprint);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));
}

test "a dataset spec round-trips through JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const bare = DatasetSpec{
        .name_path = &.{ "p", "ds" },
        .updated_at = "2024-01-02T03:04:05Z",
        .created_at = "2024-01-02T03:04:05Z",
    };
    try testing.expectEqualStrings("p_ds", try bare.datasetName(alloc));

    var with = bare;
    with.metadata =
        \\{"datasetReference":{"datasetId":"ds","projectId":"p"},"id":"ds","labels":{"k":"v"}}
    ;
    const encoded = try with.toJson(alloc);

    const decoded = try datasetSpecFromJson(alloc, encoded);
    try testing.expectEqualStrings("p", decoded.name_path[0]);
    try testing.expectEqualStrings("ds", decoded.name_path[1]);
    try testing.expectEqualStrings(with.metadata, decoded.metadata);
    try testing.expectEqualStrings(with.created_at, decoded.created_at);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));
}

test "partitioning and clustering round-trip through JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const timed = try makeTestSpec(alloc);
    timed.partitioning = .{ .time = .{ .field = "ts", .unit = .HOUR } };
    timed.clustering = try alloc.dupe([]const u8, &.{ "a", "n" });
    const timed_json = try timed.toJson(alloc);
    // addNewTableSpec stores the re-parsed spec, so the round trip is what
    // the catalog actually keeps.
    const timed_back = try tableSpecFromJson(alloc, timed_json);
    try testing.expectEqualStrings("ts", timed_back.partitioning.?.time.field);
    try testing.expectEqual(Partitioning.TimeUnit.HOUR, timed_back.partitioning.?.time.unit);
    try testing.expectEqual(@as(usize, 2), timed_back.clustering.len);
    try testing.expectEqualStrings("n", timed_back.clustering[1]);
    try testing.expectEqualStrings(timed_json, try timed_back.toJson(alloc));

    const ranged = try makeTestSpec(alloc);
    ranged.partitioning = .{ .range = .{ .field = "n", .start = -10, .end = 100, .interval = 10 } };
    const ranged_json = try ranged.toJson(alloc);
    const ranged_back = try tableSpecFromJson(alloc, ranged_json);
    try testing.expectEqual(@as(i64, -10), ranged_back.partitioning.?.range.start);
    try testing.expectEqual(@as(i64, 10), ranged_back.partitioning.?.range.interval);
    try testing.expectEqualStrings(ranged_json, try ranged_back.toJson(alloc));

    try testing.expectError(error.InvalidType, tableSpecFromJson(alloc,
        \\{"name_path":["p","d","t"],"partitioning":{"time":{"field":"d","unit":"WEEK"}}}
    ));
}

test "notNullColumnFromMessage reads the column out of SQLite's message" {
    try testing.expectEqualStrings("a", notNullColumnFromMessage(
        "constraint failed: NOT NULL constraint failed: test_ds1_req.a (19)",
    ).?);
    try testing.expectEqualStrings("col_1", notNullColumnFromMessage(
        "NOT NULL constraint failed: t.col_1",
    ).?);
    try testing.expectEqual(
        @as(?[]const u8, null),
        notNullColumnFromMessage("constraint failed: UNIQUE constraint failed: t.a (19)"),
    );
    try testing.expectEqual(
        @as(?[]const u8, null),
        notNullColumnFromMessage("NOT NULL constraint failed: nodot (19)"),
    );
}

test "descriptions round-trip through JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const x = try alloc.create(NameWithType);
    x.* = .{ .name = "x", .type = try newSimpleType(alloc, .TYPE_INT64), .description = "nested" };
    const record = try alloc.create(Type);
    record.* = .{
        .kind = @backingInt(pb.TypeKind.TYPE_STRUCT),
        .field_types = try alloc.dupe(*NameWithType, &.{x}),
    };
    const col = try alloc.create(ColumnSpec);
    col.* = .{ .name = "r", .type = record, .description = "a \"record\"" };
    const with = try makeTestSpec(alloc);
    with.columns = try alloc.dupe(*ColumnSpec, &.{col});
    with.description = "the table";

    const encoded = try with.toJson(alloc);
    const decoded = try tableSpecFromJson(alloc, encoded);
    try testing.expectEqualStrings("the table", decoded.description);
    try testing.expectEqualStrings("a \"record\"", decoded.columns[0].description);
    try testing.expectEqualStrings("nested", decoded.columns[0].type.field_types[0].description);
    const cloned = try cloneType(alloc, record);
    try testing.expectEqualStrings("nested", cloned.field_types[0].description);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));
}

test "options round-trip through JSON" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const with_opts = try makeTestSpec(alloc);
    const opt = try alloc.create(OptionSpec);
    opt.* = .{ .name = "description", .type_name = "STRING", .value = "\"demo table\"" };
    with_opts.options = try alloc.dupe(*OptionSpec, &.{opt});

    const encoded = try with_opts.toJson(alloc);

    // The round trip is load-bearing: addNewTableSpec stores the re-parsed
    // spec, so anything toJson writes and tableSpecFromJson drops is lost.
    const decoded = try tableSpecFromJson(alloc, encoded);
    try testing.expectEqual(@as(usize, 1), decoded.options.len);
    try testing.expectEqualStrings("description", decoded.options[0].name);
    try testing.expectEqualStrings("STRING", decoded.options[0].type_name);
    try testing.expectEqualStrings("\"demo table\"", decoded.options[0].value);
    try testing.expectEqualStrings(encoded, try decoded.toJson(alloc));
}
