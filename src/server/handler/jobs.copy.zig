//! Copy jobs: the `configuration.copy` half of jobs.insert.
//!
//! A copy job duplicates the rows of one or more source tables into a single destination
//! table. A query job takes its destination's shape from the query it ran; a copy job takes it
//! from the sources, which must agree with each other and with an existing destination before
//! anything is written.
//!
//! The shape of the request and the existence of each source are settled before a job exists,
//! and answer with an HTTP status; `parse` returns the first of those. Every later failure
//! completes the job and rides in `status.errorResult`. docs/adr/0001.

const std = @import("std");
const zigquery = @import("zigquery");
const spec = zigquery.spec;
/// The googlesql protos, where a column type's kind is defined. `pb` below is the BigQuery
/// REST wire types.
const gsql = zigquery.pb;
const pb = @import("../proto/bigquery.zig");
const schema = @import("../internal/types/schema.zig");

/// A fully-qualified table, as a copy job's configuration names it.
pub const TableRef = struct {
    project_id: []const u8,
    dataset_id: []const u8,
    table_id: []const u8,

    /// `project:dataset.table`, as an error message spells a table.
    pub fn display(self: TableRef, arena: std.mem.Allocator) ![]const u8 {
        return std.fmt.allocPrint(arena, "{s}:{s}.{s}", .{
            self.project_id, self.dataset_id, self.table_id,
        });
    }
};

/// What a job does when its destination table already exists. The member names are the wire
/// values. rest/v2/Job#jobconfigurationtablecopy
pub const WriteDisposition = enum {
    WRITE_TRUNCATE,
    WRITE_APPEND,
    /// What an absent field means.
    WRITE_EMPTY,
};

/// Whether a job may bring its destination table into existence. The member names are the wire
/// values. rest/v2/Job#jobconfigurationtablecopy
pub const CreateDisposition = enum {
    /// What an absent field means.
    CREATE_IF_NEEDED,
    CREATE_NEVER,
};

/// What a copy job was asked to do, once the wire form has been normalised.
pub const CopySpec = struct {
    /// At least one. The singular `sourceTable` arrives as a one-element list.
    sources: []const TableRef,
    destination: TableRef,
    write_disposition: WriteDisposition = .WRITE_EMPTY,
    create_disposition: CreateDisposition = .CREATE_IF_NEEDED,
    /// What the client sent, for the job resource to echo. The fields above are the effective
    /// values, which a resource must not report in place of an omitted one.
    submitted: Submitted = .{},

    /// A copy configuration as it arrived, to the degree the echo depends on it.
    pub const Submitted = struct {
        write_disposition: ?WriteDisposition = null,
        create_disposition: ?CreateDisposition = null,
        /// `sourceTables` rather than `sourceTable`.
        plural_sources: bool = false,
    };

    /// WRITE_EMPTY refuses a destination holding rows. An existing empty destination is
    /// accepted. rest/v2/Job#jobconfigurationtablecopy
    pub fn refusesOccupiedDestination(self: CopySpec) bool {
        return self.write_disposition == .WRITE_EMPTY;
    }

    pub fn mayCreateDestination(self: CopySpec) bool {
        return self.create_disposition != .CREATE_NEVER;
    }
};

/// A request that never becomes a job, answered with an HTTP status.
pub const ParseError = error{
    /// `sourceTable` and `sourceTables` both set. The reference marks the pair "[Pick one]"
    /// and leaves both-set undefined; refusing keeps a source the client did not choose from
    /// being copied. rest/v2/Job#jobconfigurationtablecopy
    BothSourceForms,
    NoSourceTable,
    NoDestinationTable,
    /// A TableReference missing one of its three parts.
    IncompleteTableReference,
    /// A disposition outside the documented set.
    InvalidWriteDisposition,
    InvalidCreateDisposition,
    /// SNAPSHOT, RESTORE and CLONE name a destination whose storage references the source
    /// rather than holding its own rows. rest/v2/Job#operationtype
    UnsupportedOperationType,
    OutOfMemory,
};

pub fn copyConfig(job: *const pb.Job) ?*const pb.JobConfigurationTableCopy {
    const cfg = job.configuration orelse return null;
    return cfg.copy;
}

fn refFrom(t: *const pb.TableReference) ParseError!TableRef {
    return .{
        .project_id = t.project_id orelse return error.IncompleteTableReference,
        .dataset_id = t.dataset_id orelse return error.IncompleteTableReference,
        .table_id = t.table_id orelse return error.IncompleteTableReference,
    };
}

/// Normalises `configuration.copy`. Null when the job is not a copy job, which is how the
/// caller tells a copy job from a query job.
pub fn parse(arena: std.mem.Allocator, job: *const pb.Job) ParseError!?CopySpec {
    const cfg = copyConfig(job) orelse return null;

    if (cfg.operation_type) |op| switch (op) {
        // Absent and COPY are the same request.
        .COPY, .OPERATION_TYPE_UNSPECIFIED => {},
        else => return error.UnsupportedOperationType,
    };

    const single = cfg.source_table;
    const many = cfg.source_tables;
    if (single != null and many.len != 0) return error.BothSourceForms;

    var sources: std.ArrayList(TableRef) = .empty;
    if (single) |t| {
        try sources.append(arena, try refFrom(t));
    } else {
        if (many.len == 0) return error.NoSourceTable;
        for (many) |t| try sources.append(arena, try refFrom(t));
    }

    const dest = cfg.destination_table orelse return error.NoDestinationTable;

    const write_disposition: ?WriteDisposition = if (cfg.write_disposition) |text|
        std.meta.stringToEnum(WriteDisposition, text) orelse return error.InvalidWriteDisposition
    else
        null;
    const create_disposition: ?CreateDisposition = if (cfg.create_disposition) |text|
        std.meta.stringToEnum(CreateDisposition, text) orelse return error.InvalidCreateDisposition
    else
        null;

    return .{
        .sources = try sources.toOwnedSlice(arena),
        .destination = try refFrom(dest),
        .write_disposition = write_disposition orelse .WRITE_EMPTY,
        .create_disposition = create_disposition orelse .CREATE_IF_NEEDED,
        .submitted = .{
            .write_disposition = write_disposition,
            .create_disposition = create_disposition,
            .plural_sources = single == null,
        },
    };
}

/// What the client is told about a configuration that never became a job. BigQuery documents
/// no wording for these, so they name the field at fault.
pub fn parseErrorMessage(err: ParseError) []const u8 {
    return switch (err) {
        error.BothSourceForms => "configuration.copy: set sourceTable or sourceTables, not both",
        error.NoSourceTable => "configuration.copy.sourceTable is required",
        error.NoDestinationTable => "configuration.copy.destinationTable is required",
        error.IncompleteTableReference => "configuration.copy: a table reference needs " ++
            "projectId, datasetId and tableId",
        error.InvalidWriteDisposition => "configuration.copy.writeDisposition must be " ++
            "WRITE_TRUNCATE, WRITE_APPEND or WRITE_EMPTY",
        error.InvalidCreateDisposition => "configuration.copy.createDisposition must be " ++
            "CREATE_IF_NEEDED or CREATE_NEVER",
        error.UnsupportedOperationType => "configuration.copy.operationType: only COPY is " ++
            "supported",
        error.OutOfMemory => "out of memory",
    };
}

// ---- schema relations ----
//
// Two predicates with two wordings. Sources must be identical to one another;
// a source appending into an existing destination need only be compatible with it.
//
// Both are structural, and both are looser than the service: BigQuery also compares an
// internal physical schema the API does not expose, so a copy accepted here can be rejected
// there. managing-tables#limitations_on_copying_tables

/// Structural type equality. STRUCT fields match by name, not by position.
pub fn typesEqual(a: *const spec.Type, b: *const spec.Type) bool {
    if (a.kind != b.kind) return false;

    if (a.element_type) |ae| {
        const be = b.element_type orelse return false;
        if (!typesEqual(ae, be)) return false;
    } else if (b.element_type != null) return false;

    if (a.field_types.len != b.field_types.len) return false;
    for (a.field_types) |af| {
        const bf = fieldNamed(b.field_types, af.name) orelse return false;
        const at = af.type orelse return bf.type == null;
        const bt = bf.type orelse return false;
        if (!typesEqual(at, bt)) return false;
    }
    return true;
}

fn fieldNamed(fields: []const *spec.NameWithType, name: []const u8) ?*const spec.NameWithType {
    for (fields) |f| {
        if (std.ascii.eqlIgnoreCase(f.name, name)) return f;
    }
    return null;
}

fn columnNamed(columns: []const *spec.ColumnSpec, name: []const u8) ?*const spec.ColumnSpec {
    for (columns) |c| {
        if (std.ascii.eqlIgnoreCase(c.name, name)) return c;
    }
    return null;
}

/// Every source of a multi-source copy against the others: the same columns by name ignoring
/// case, each with the same type and mode. Column order, description, partitioning and
/// clustering do not participate.
pub fn identicalSchemas(a: *const spec.TableSpec, b: *const spec.TableSpec) bool {
    if (a.columns.len != b.columns.len) return false;
    for (a.columns) |ac| {
        const bc = columnNamed(b.columns, ac.name) orelse return false;
        if (ac.is_not_null != bc.is_not_null) return false;
        if (!typesEqual(ac.type, bc.type)) return false;
    }
    return true;
}

/// Why a source cannot be appended to a particular destination.
pub const AppendMismatch = union(enum) {
    /// The destination has no column of this name.
    cannot_add_field: []const u8,
    /// A column exists on both sides with a different mode.
    mode_changed: Change,
    /// A column exists on both sides with a different type.
    type_changed: Change,

    /// `from` is the destination's, `to` the source's.
    pub const Change = struct { field: []const u8, from: []const u8, to: []const u8 };

    fn cannotAddField(field: []const u8) AppendMismatch {
        return .{ .cannot_add_field = field };
    }

    fn modeChanged(
        source: *const spec.ColumnSpec,
        destination: *const spec.ColumnSpec,
    ) AppendMismatch {
        const change: Change = .{
            .field = source.name,
            .from = modeName(destination.is_not_null),
            .to = modeName(source.is_not_null),
        };
        return .{ .mode_changed = change };
    }

    fn typeChanged(
        source: *const spec.ColumnSpec,
        destination: *const spec.ColumnSpec,
    ) AppendMismatch {
        const change: Change = .{
            .field = source.name,
            .from = schema.legacyTypeName(destination.type.typeKind()),
            .to = schema.legacyTypeName(source.type.typeKind()),
        };
        return .{ .type_changed = change };
    }
};

fn modeName(is_not_null: bool) []const u8 {
    return if (is_not_null) "REQUIRED" else "NULLABLE";
}

/// A source against an existing destination it appends to: every source column present in the
/// destination with the same type and mode. The destination may carry further columns, and the
/// two sides may order their columns differently. Null when the append may proceed.
pub fn appendMismatch(
    source: *const spec.TableSpec,
    destination: *const spec.TableSpec,
) ?AppendMismatch {
    for (source.columns) |sc| {
        const dc = columnNamed(destination.columns, sc.name) orelse
            return .cannotAddField(sc.name);
        if (sc.is_not_null != dc.is_not_null) return .modeChanged(sc, dc);
        if (!typesEqual(sc.type, dc.type)) return .typeChanged(sc, dc);
    }
    return null;
}

/// The wording when a copy names a view as its source. Ends with a period, and reports the
/// object's kind in the present tense.
pub fn viewSourceMessage(arena: std.mem.Allocator, source: TableRef) ![]const u8 {
    return std.fmt.allocPrint(
        arena,
        "{s} is not allowed for this operation because it is currently a VIEW.",
        .{try source.display(arena)},
    );
}

/// The wording for a rejected append. Names the destination, and reads destination-first for a
/// mode change or a type change. Type names are BigQuery's legacy spellings.
pub fn appendMismatchMessage(
    arena: std.mem.Allocator,
    destination: TableRef,
    mismatch: AppendMismatch,
) ![]const u8 {
    const table = try destination.display(arena);
    return switch (mismatch) {
        .cannot_add_field => |name| try std.fmt.allocPrint(
            arena,
            "Provided Schema does not match Table {s}. Cannot add fields (field: {s})",
            .{ table, name },
        ),
        .mode_changed => |m| try std.fmt.allocPrint(
            arena,
            "Provided Schema does not match Table {s}. Field {s} has changed mode from {s} to {s}",
            .{ table, m.field, m.from, m.to },
        ),
        .type_changed => |m| try std.fmt.allocPrint(
            arena,
            "Provided Schema does not match Table {s}. Field {s} has changed type from {s} to {s}",
            .{ table, m.field, m.from, m.to },
        ),
    };
}

/// The wording when the sources of a multi-source copy disagree. Names every source in request
/// order, and ends with a period.
pub fn incompatibleSourcesMessage(
    arena: std.mem.Allocator,
    sources: []const TableRef,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "Incompatible table schemata between tables: ");
    for (sources, 0..) |src, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.appendSlice(arena, try src.display(arena));
    }
    try out.append(arena, '.');
    return out.toOwnedSlice(arena);
}

// ---- the job resource ----

/// How a copy job ended, which decides what its resource carries.
pub const Outcome = union(enum) {
    /// Rows landed in the destination.
    copied: i64,
    /// The job ran and failed. `reason` is BigQuery's, not an HTTP status.
    failed: Failure,

    pub const Failure = struct { reason: []const u8, message: []const u8 };
};

pub const JobResource = struct {
    project_id: []const u8,
    job_id: []const u8,
    endpoint: []const u8,
    unix_seconds: i64,
    copy: CopySpec,
    outcome: Outcome,
};

/// Serializes a bigquery#job resource for a copy job.
///
/// `operationType` appears on a job that succeeded, and a disposition the client omitted stays
/// omitted. `statistics.copy` carries copiedRows; copiedLogicalBytes measures BigQuery's own
/// storage format.
pub fn writeJobResource(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    j: JobResource,
) !void {
    var cfg = pb.JobConfiguration{
        .job_type = "COPY",
        .copy = try copyConfiguration(arena, j.copy, j.outcome),
    };
    var job_ref = pb.JobReference{ .project_id = j.project_id, .job_id = j.job_id };
    const job = pb.Job{
        .kind = "bigquery#job",
        .self_link = try std.fmt.allocPrint(
            arena,
            "http://{s}/bigquery/v2/projects/{s}/jobs/{s}",
            .{ j.endpoint, j.project_id, j.job_id },
        ),
        .configuration = &cfg,
        .job_reference = &job_ref,
        .statistics = try statistics(arena, j.unix_seconds, j.outcome),
        .status = try status(arena, j.outcome),
    };
    try out.appendSlice(arena, try std.json.Stringify.valueAlloc(arena, job, .{}));
}

fn tableReference(arena: std.mem.Allocator, t: TableRef) !*pb.TableReference {
    const ref = try arena.create(pb.TableReference);
    ref.* = .{ .project_id = t.project_id, .dataset_id = t.dataset_id, .table_id = t.table_id };
    return ref;
}

/// `configuration.copy`: the sources in the form the client sent them.
fn copyConfiguration(
    arena: std.mem.Allocator,
    copy: CopySpec,
    outcome: Outcome,
) !*pb.JobConfigurationTableCopy {
    const sources = try arena.alloc(*pb.TableReference, copy.sources.len);
    for (copy.sources, sources) |src, *ref| ref.* = try tableReference(arena, src);

    const cfg = try arena.create(pb.JobConfigurationTableCopy);
    cfg.* = .{
        .destination_table = try tableReference(arena, copy.destination),
        .write_disposition = if (copy.submitted.write_disposition) |wd| @tagName(wd) else null,
        .create_disposition = if (copy.submitted.create_disposition) |cd| @tagName(cd) else null,
        .operation_type = switch (outcome) {
            .copied => .COPY,
            .failed => null,
        },
    };
    if (copy.submitted.plural_sources) {
        cfg.source_tables = sources;
    } else {
        cfg.source_table = sources[0];
    }
    return cfg;
}

/// `statistics`, with `statistics.copy` on a job that copied rows.
fn statistics(
    arena: std.mem.Allocator,
    unix_seconds: i64,
    outcome: Outcome,
) !*pb.JobStatistics {
    const stats = try arena.create(pb.JobStatistics);
    stats.* = .{
        .creation_time = unix_seconds,
        .start_time = unix_seconds,
        .end_time = unix_seconds,
    };
    const rows = switch (outcome) {
        .copied => |rows| rows,
        .failed => return stats,
    };
    const copied = try arena.create(pb.Int64Value);
    copied.* = .{ .value = rows };
    const stats_copy = try arena.create(pb.CopyJobStatistics);
    stats_copy.* = .{ .copied_rows = copied };
    stats.copy = stats_copy;
    return stats;
}

fn status(arena: std.mem.Allocator, outcome: Outcome) !*pb.JobStatus {
    const st = try arena.create(pb.JobStatus);
    st.* = .{ .state = "DONE" };
    const failure = switch (outcome) {
        .copied => return st,
        .failed => |failure| failure,
    };
    const err = try arena.create(pb.ErrorProto);
    err.* = .{ .reason = failure.reason, .message = failure.message };
    st.error_result = err;
    // `errors` repeats the errorResult verbatim.
    st.errors = try arena.dupe(*pb.ErrorProto, &.{err});
    return st;
}

const testing = std.testing;

test "a job with no copy configuration is not a copy job" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var cfg_query = pb.JobConfigurationQuery{ .query = "SELECT 1" };
    var cfg = pb.JobConfiguration{ .query = &cfg_query };
    const job = pb.Job{ .configuration = &cfg };

    try testing.expect(try parse(arena, &job) == null);
}

test "the singular source form normalises to a one-element list" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "s" };
    var dst = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "t" };
    var copy = pb.JobConfigurationTableCopy{ .source_table = &src, .destination_table = &dst };
    var cfg = pb.JobConfiguration{ .copy = &copy };
    const job = pb.Job{ .configuration = &cfg };

    const got = (try parse(arena, &job)).?;
    try testing.expectEqual(@as(usize, 1), got.sources.len);
    try testing.expectEqualStrings("s", got.sources[0].table_id);
    try testing.expectEqualStrings("t", got.destination.table_id);
    try testing.expectEqual(WriteDisposition.WRITE_EMPTY, got.write_disposition);
    try testing.expectEqual(CreateDisposition.CREATE_IF_NEEDED, got.create_disposition);
    // The effective value, not something the client sent.
    try testing.expectEqual(@as(?WriteDisposition, null), got.submitted.write_disposition);
    try testing.expectEqual(@as(?CreateDisposition, null), got.submitted.create_disposition);
}

test "a disposition outside the documented set is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "s" };
    var dst = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "t" };
    var copy = pb.JobConfigurationTableCopy{
        .source_table = &src,
        .destination_table = &dst,
        .write_disposition = "WRITE_SOMETIMES",
    };
    var cfg = pb.JobConfiguration{ .copy = &copy };
    const job = pb.Job{ .configuration = &cfg };

    try testing.expectError(error.InvalidWriteDisposition, parse(arena, &job));

    copy.write_disposition = null;
    copy.create_disposition = "CREATE_SOMETIMES";
    try testing.expectError(error.InvalidCreateDisposition, parse(arena, &job));
}

test "a submitted disposition survives the round trip by name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "s" };
    var dst = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "t" };
    var copy = pb.JobConfigurationTableCopy{
        .source_table = &src,
        .destination_table = &dst,
        .write_disposition = "WRITE_APPEND",
        .create_disposition = "CREATE_NEVER",
    };
    var cfg = pb.JobConfiguration{ .copy = &copy };
    const job = pb.Job{ .configuration = &cfg };

    const got = (try parse(arena, &job)).?;
    try testing.expectEqualStrings("WRITE_APPEND", @tagName(got.submitted.write_disposition.?));
    try testing.expectEqualStrings("CREATE_NEVER", @tagName(got.submitted.create_disposition.?));
}

test "both source forms at once is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var one = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "s1" };
    var two = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "s2" };
    var many = [_]*pb.TableReference{&two};
    var dst = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "t" };
    var copy = pb.JobConfigurationTableCopy{
        .source_table = &one,
        .source_tables = &many,
        .destination_table = &dst,
    };
    var cfg = pb.JobConfiguration{ .copy = &copy };
    const job = pb.Job{ .configuration = &cfg };

    try testing.expectError(error.BothSourceForms, parse(arena, &job));
}

test "an operation type other than COPY is refused" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var src = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "s" };
    var dst = pb.TableReference{ .project_id = "p", .dataset_id = "d", .table_id = "t" };
    var copy = pb.JobConfigurationTableCopy{
        .source_table = &src,
        .destination_table = &dst,
        .operation_type = .SNAPSHOT,
    };
    var cfg = pb.JobConfiguration{ .copy = &copy };
    const job = pb.Job{ .configuration = &cfg };

    try testing.expectError(error.UnsupportedOperationType, parse(arena, &job));
}

// The schema rules below are measured: a multi-source copy of tables differing only in the
// named way, run against recidiviz-bigquery-sandbox on 2026-09-21.

test "sources naming the same columns in a different order are identical" {
    var int_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_INT64) };
    var str_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_STRING) };

    var a_col = spec.ColumnSpec{ .name = "a", .type = &int_type };
    var b_col = spec.ColumnSpec{ .name = "b", .type = &str_type };
    var left = [_]*spec.ColumnSpec{ &a_col, &b_col };
    var right = [_]*spec.ColumnSpec{ &b_col, &a_col };

    const l = spec.TableSpec{ .columns = &left };
    const r = spec.TableSpec{ .columns = &right };
    try testing.expect(identicalSchemas(&l, &r));
}

test "a column name differing only by case does not make schemas differ" {
    var int_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_INT64) };
    var upper = spec.ColumnSpec{ .name = "Foo", .type = &int_type };
    var lower = spec.ColumnSpec{ .name = "foo", .type = &int_type };
    var left = [_]*spec.ColumnSpec{&upper};
    var right = [_]*spec.ColumnSpec{&lower};

    const l = spec.TableSpec{ .columns = &left };
    const r = spec.TableSpec{ .columns = &right };
    try testing.expect(identicalSchemas(&l, &r));
}

test "a mode difference makes two sources incompatible" {
    var int_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_INT64) };
    var required = spec.ColumnSpec{ .name = "a", .type = &int_type, .is_not_null = true };
    var nullable = spec.ColumnSpec{ .name = "a", .type = &int_type };
    var left = [_]*spec.ColumnSpec{&required};
    var right = [_]*spec.ColumnSpec{&nullable};

    const l = spec.TableSpec{ .columns = &left };
    const r = spec.TableSpec{ .columns = &right };
    try testing.expect(!identicalSchemas(&l, &r));
}

test "a destination may carry extra columns the source lacks" {
    var int_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_INT64) };
    var str_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_STRING) };

    var a_col = spec.ColumnSpec{ .name = "a", .type = &int_type };
    var b_col = spec.ColumnSpec{ .name = "b", .type = &str_type };
    var source_cols = [_]*spec.ColumnSpec{&a_col};
    var dest_cols = [_]*spec.ColumnSpec{ &a_col, &b_col };

    const source = spec.TableSpec{ .columns = &source_cols };
    const dest = spec.TableSpec{ .columns = &dest_cols };
    try testing.expect(appendMismatch(&source, &dest) == null);
}

test "a source column the destination lacks cannot be added by an append" {
    var int_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_INT64) };
    var str_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_STRING) };

    var a_col = spec.ColumnSpec{ .name = "a", .type = &int_type };
    var b_col = spec.ColumnSpec{ .name = "b", .type = &str_type };
    var source_cols = [_]*spec.ColumnSpec{ &a_col, &b_col };
    var dest_cols = [_]*spec.ColumnSpec{&a_col};

    const source = spec.TableSpec{ .columns = &source_cols };
    const dest = spec.TableSpec{ .columns = &dest_cols };

    const mismatch = appendMismatch(&source, &dest).?;
    try testing.expectEqualStrings("b", mismatch.cannot_add_field);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = try appendMismatchMessage(
        arena,
        .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        mismatch,
    );
    // (recidiviz-bigquery-sandbox, 2026-09-21)
    try testing.expectEqualStrings(
        "Provided Schema does not match Table p:d.t. Cannot add fields (field: b)",
        msg,
    );
}

test "a nullable source into a required destination reads destination-first" {
    var int_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_INT64) };
    var nullable = spec.ColumnSpec{ .name = "a", .type = &int_type };
    var required = spec.ColumnSpec{ .name = "a", .type = &int_type, .is_not_null = true };
    var source_cols = [_]*spec.ColumnSpec{&nullable};
    var dest_cols = [_]*spec.ColumnSpec{&required};

    const source = spec.TableSpec{ .columns = &source_cols };
    const dest = spec.TableSpec{ .columns = &dest_cols };

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = try appendMismatchMessage(
        arena,
        .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        appendMismatch(&source, &dest).?,
    );
    // (recidiviz-bigquery-sandbox, 2026-09-21)
    try testing.expectEqualStrings(
        "Provided Schema does not match Table p:d.t. " ++
            "Field a has changed mode from REQUIRED to NULLABLE",
        msg,
    );
}

test "a type difference reads destination-first in legacy type names" {
    var int_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_INT64) };
    var str_type = spec.Type{ .kind = @backingInt(gsql.TypeKind.TYPE_STRING) };
    var source_col = spec.ColumnSpec{ .name = "a", .type = &int_type };
    var dest_col = spec.ColumnSpec{ .name = "a", .type = &str_type };
    var source_cols = [_]*spec.ColumnSpec{&source_col};
    var dest_cols = [_]*spec.ColumnSpec{&dest_col};

    const source = spec.TableSpec{ .columns = &source_cols };
    const dest = spec.TableSpec{ .columns = &dest_cols };

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const msg = try appendMismatchMessage(
        arena,
        .{ .project_id = "p", .dataset_id = "d", .table_id = "t" },
        appendMismatch(&source, &dest).?,
    );
    // (recidiviz-bigquery-sandbox, 2026-09-24): an INT64 source appended to a STRING
    // destination. INTEGER rather than INT64: the REST API reports legacy type names.
    try testing.expectEqualStrings(
        "Provided Schema does not match Table p:d.t. " ++
            "Field a has changed type from STRING to INTEGER",
        msg,
    );
}

test "a view named as a source is refused by kind" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msg = try viewSourceMessage(
        arena,
        .{ .project_id = "p", .dataset_id = "d", .table_id = "v" },
    );
    // (recidiviz-bigquery-sandbox, 2026-09-24)
    try testing.expectEqualStrings(
        "p:d.v is not allowed for this operation because it is currently a VIEW.",
        msg,
    );
}

fn resourceFor(arena: std.mem.Allocator, body: []const u8, outcome: Outcome) ![]const u8 {
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, arena, body, .{});
    const job = try pb.Job.jsonDecode(arena, parsed, .{});
    const copy = (try parse(arena, job)).?;

    var out: std.ArrayList(u8) = .empty;
    try writeJobResource(arena, &out, .{
        .project_id = "p",
        .job_id = "j",
        .endpoint = "localhost:9050",
        .unix_seconds = 0,
        .copy = copy,
        .outcome = outcome,
    });
    return out.items;
}

test "a successful copy reports operationType and copiedRows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try resourceFor(arena,
        \\{"configuration":{"copy":{
        \\  "sourceTable":{"projectId":"p","datasetId":"d","tableId":"s"},
        \\  "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    , .{ .copied = 3 });

    // (recidiviz-bigquery-sandbox, 2026-09-21): the service fills operationType in on a job
    // that succeeds, and reports copiedRows as an int64-as-string.
    try testing.expect(std.mem.indexOf(u8, got, "\"operationType\":\"COPY\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"copiedRows\":\"3\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"jobType\":\"COPY\"") != null);
    // A disposition the client omitted is not filled in.
    try testing.expect(std.mem.indexOf(u8, got, "writeDisposition") == null);
    try testing.expect(std.mem.indexOf(u8, got, "createDisposition") == null);
}

test "a failed copy carries errorResult and no operationType" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const got = try resourceFor(arena,
        \\{"configuration":{"copy":{
        \\  "sourceTable":{"projectId":"p","datasetId":"d","tableId":"s"},
        \\  "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"},
        \\  "writeDisposition":"WRITE_EMPTY"}}}
    , .{ .failed = .{ .reason = "duplicate", .message = "Already Exists: Table p:d.t" } });

    // (recidiviz-bigquery-sandbox, 2026-09-21): a failed job is DONE with an errorResult, and
    // carries neither operationType nor statistics.copy.
    try testing.expect(std.mem.indexOf(u8, got, "\"state\":\"DONE\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "\"reason\":\"duplicate\"") != null);
    try testing.expect(std.mem.indexOf(u8, got, "Already Exists: Table p:d.t") != null);
    // (recidiviz-bigquery-sandbox, 2026-09-24): `errors` carries the same reason and message
    // as `errorResult`, so the message appears twice.
    try testing.expect(std.mem.indexOf(u8, got, "\"errors\":[") != null);
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, got, "Already Exists: Table p:d.t"),
    );
    try testing.expect(std.mem.indexOf(u8, got, "operationType") == null);
    try testing.expect(std.mem.indexOf(u8, got, "copiedRows") == null);
    // A disposition the client did send is echoed.
    try testing.expect(std.mem.indexOf(u8, got, "\"writeDisposition\":\"WRITE_EMPTY\"") != null);
}

test "the echoed source form matches the form the client sent" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const plural = try resourceFor(arena,
        \\{"configuration":{"copy":{
        \\  "sourceTables":[{"projectId":"p","datasetId":"d","tableId":"s0"},
        \\                  {"projectId":"p","datasetId":"d","tableId":"s1"}],
        \\  "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    , .{ .copied = 0 });
    try testing.expect(std.mem.indexOf(u8, plural, "\"sourceTables\":[") != null);
    try testing.expect(std.mem.indexOf(u8, plural, "\"sourceTable\":{") == null);

    const singular = try resourceFor(arena,
        \\{"configuration":{"copy":{
        \\  "sourceTable":{"projectId":"p","datasetId":"d","tableId":"s"},
        \\  "destinationTable":{"projectId":"p","datasetId":"d","tableId":"t"}}}}
    , .{ .copied = 0 });
    try testing.expect(std.mem.indexOf(u8, singular, "\"sourceTable\":{") != null);
    try testing.expect(std.mem.indexOf(u8, singular, "\"sourceTables\":[") == null);
}

test "the incompatible-sources message names every source and ends in a period" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const msg = try incompatibleSourcesMessage(arena, &.{
        .{ .project_id = "p", .dataset_id = "d", .table_id = "s0" },
        .{ .project_id = "p", .dataset_id = "d", .table_id = "s1" },
    });
    // (recidiviz-bigquery-sandbox, 2026-09-21)
    try testing.expectEqualStrings(
        "Incompatible table schemata between tables: p:d.s0, p:d.s1.",
        msg,
    );
}

test "refusesOccupiedDestination - only true for write_empty" {
    for (std.enums.values(WriteDisposition)) |disposition| {
        const refused = CopySpec.refusesOccupiedDestination(.{
            .sources = &[_]TableRef{},
            .destination = .{
                .project_id = "test",
                .dataset_id = "test",
                .table_id = "test",
            },
            .write_disposition = disposition,
        });
        try testing.expect(if (disposition == .WRITE_EMPTY) refused else !refused);
    }
}

test "mayCreateDestination - cannot create when never specified" {
    for (std.enums.values(CreateDisposition)) |disposition| {
        const mayCreate = CopySpec.mayCreateDestination(.{
            .sources = &[_]TableRef{},
            .destination = .{
                .project_id = "test",
                .dataset_id = "test",
                .table_id = "test",
            },
            .create_disposition = disposition,
        });
        try testing.expect(if (disposition == .CREATE_NEVER) !mayCreate else mayCreate);
    }
}

test "parseErrorMessage" {
    for (std.meta.tags(ParseError)) |err| {
        try testing.expect(!std.mem.eql(u8, parseErrorMessage(err), ""));
    }
}
