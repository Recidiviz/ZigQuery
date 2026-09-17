//! `google.cloud.bigquery.storage.v1.BigQueryRead`, above the transport.
//!
//! Deliberately free of any gRPC type: every method here takes a request as
//! bytes and returns a response as bytes, so it is testable under
//! `zig build test-server` without a completion queue, a socket or a thread.
//! `grpc/server.zig` owns the wire; this owns the service.
//!
//! Go counterpart: bigquery-emulator's server/storage_handler.go.

const std = @import("std");
const pb = @import("../proto/storage.zig");
const bqserver = @import("../server.zig");
const grpc_server = @import("server.zig");
const method_path = @import("method.zig");
const value_mod = @import("zigquery").value;
const avro = @import("avro.zig");
const arrow = @import("arrow.zig");
const driver = @import("zigquery").driver;

const log = std.log.scoped(.grpc);

/// Where a session claims to live. BigQuery puts a real region here; the
/// emulator has one location and the client only ever echoes it back in stream
/// names, so a constant is honest and matches what Go does.
const location = "us";

pub const Error = error{
    /// The request named something that is not `projects/…/datasets/…/tables/…`.
    MalformedTableName,
    /// `max_stream_count > 1`. Go rejects it outright and so does this; see
    /// docs/STORAGE_READ_PLAN.md, which explains why one stream is what makes
    /// the materialize-then-stream design safe.
    TooManyStreams,
    TableNotFound,
    /// `read_session` absent, or `read_session.table` absent.
    MissingTable,
    /// A `selected_fields` entry is not a name this server can quote safely.
    MalformedFieldName,
    /// `ReadRows` named a stream no live session owns.
    UnknownStream,
    /// The session's SQL would not analyse — almost always a `row_restriction`
    /// the client wrote.
    BadRestriction,
    /// The query failed at run time, having analysed cleanly.
    QueryFailed,
    /// A value did not fit the schema its column promised.
    EncodeFailed,
} || std.mem.Allocator.Error || wireError || avro.Error || arrow.Error;

const wireError = @import("zigquery").wire.DecodeError ||
    @import("zigquery").wire.EncodeError;

/// A table name split into its three parts.
pub const TableRef = struct {
    project: []const u8,
    dataset: []const u8,
    table: []const u8,

    /// `projects/{p}/datasets/{d}/tables/{t}`, which is the only spelling the
    /// Storage API accepts — unlike the REST API, there is no bare `d.t` form.
    pub fn parse(name: []const u8) ?TableRef {
        var it = std.mem.splitScalar(u8, name, '/');
        const p_lit = it.next() orelse return null;
        const project = it.next() orelse return null;
        const d_lit = it.next() orelse return null;
        const dataset = it.next() orelse return null;
        const t_lit = it.next() orelse return null;
        const table = it.next() orelse return null;
        if (it.next() != null) return null;
        if (!std.mem.eql(u8, p_lit, "projects")) return null;
        if (!std.mem.eql(u8, d_lit, "datasets")) return null;
        if (!std.mem.eql(u8, t_lit, "tables")) return null;
        if (project.len == 0 or dataset.len == 0 or table.len == 0) return null;
        return .{ .project = project, .dataset = dataset, .table = table };
    }
};

/// One live read session.
///
/// Modelled on `query_handler.JobStore`, and like it, everything is duped into
/// `gpa` because the arena a request was built in dies with the request.
pub const Session = struct {
    id: []const u8,
    /// Full resource name, `projects/…/locations/…/sessions/…`.
    name: []const u8,
    table: []const u8,
    /// The single stream's resource name.
    stream: []const u8,
    data_format: pb.DataFormat,
    /// `selected_fields`, empty for "whole table".
    selected_fields: []const []const u8,
    /// `row_restriction`, empty for none.
    row_restriction: []const u8,
    /// The schema the client was handed, echoed in the first
    /// `ReadRowsResponse`. Stored rather than rebuilt so the schema a client
    /// decodes against is byte-for-byte the one it was promised.
    ///
    /// Which schema it is follows `data_format`: Avro JSON, or an encapsulated
    /// Arrow IPC schema message. One field rather than two because a session
    /// has exactly one schema, and two fields would leave room for the wrong
    /// one to be sent.
    schema: []const u8,
};

pub const SessionStore = struct {
    gpa: std.mem.Allocator,
    map: std.StringHashMapUnmanaged(Session) = .empty,

    pub fn deinit(s: *SessionStore) void {
        var it = s.map.iterator();
        while (it.next()) |kv| {
            s.gpa.free(kv.key_ptr.*);
            s.freeEntry(kv.value_ptr);
        }
        s.map.deinit(s.gpa);
    }

    fn freeEntry(s: *SessionStore, sess: *Session) void {
        s.gpa.free(sess.id);
        s.gpa.free(sess.name);
        s.gpa.free(sess.table);
        s.gpa.free(sess.stream);
        for (sess.selected_fields) |f| s.gpa.free(f);
        s.gpa.free(sess.selected_fields);
        s.gpa.free(sess.row_restriction);
        s.gpa.free(sess.schema);
    }

    /// Takes a copy of everything in `sess`, which may point into a request
    /// arena.
    pub fn put(s: *SessionStore, sess: Session) !void {
        const fields = try s.gpa.alloc([]const u8, sess.selected_fields.len);
        errdefer s.gpa.free(fields);
        var n: usize = 0;
        errdefer for (fields[0..n]) |f| s.gpa.free(f);
        for (sess.selected_fields, 0..) |f, i| {
            fields[i] = try s.gpa.dupe(u8, f);
            n = i + 1;
        }

        const key = try s.gpa.dupe(u8, sess.id);
        errdefer s.gpa.free(key);
        const gop = try s.map.getOrPut(s.gpa, key);
        if (gop.found_existing) {
            s.gpa.free(key);
            s.freeEntry(gop.value_ptr);
        }
        gop.value_ptr.* = .{
            .id = try s.gpa.dupe(u8, sess.id),
            .name = try s.gpa.dupe(u8, sess.name),
            .table = try s.gpa.dupe(u8, sess.table),
            .stream = try s.gpa.dupe(u8, sess.stream),
            .data_format = sess.data_format,
            .selected_fields = fields,
            .row_restriction = try s.gpa.dupe(u8, sess.row_restriction),
            .schema = try s.gpa.dupe(u8, sess.schema),
        };
    }

    pub fn get(s: *SessionStore, id: []const u8) ?Session {
        return s.map.get(id);
    }

    /// The stream name a `ReadRows` request carries identifies the session:
    /// `…/sessions/{id}/streams/{n}`.
    pub fn getByStream(s: *SessionStore, stream: []const u8) ?Session {
        const marker = "/sessions/";
        const i = std.mem.indexOf(u8, stream, marker) orelse return null;
        const rest = stream[i + marker.len ..];
        const j = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
        return s.get(rest[0..j]);
    }
};

/// How much encoded Avro goes in one `ReadRowsResponse` before it is flushed.
///
/// gRPC's default client receive limit is 4 MB. The BigQuery Python client
/// raises it to unlimited, but nothing else has to, and real BigQuery batches
/// as well -- a whole table in one message is not a shape a client expects.
const max_batch_bytes: usize = 1 << 20;

/// One `ReadRowsResponse` worth of rows. `count` is load-bearing: the client
/// adds it to its own offset and reconnects with the total after a retryable
/// error, so a wrong count silently skips or repeats rows on a retry.
const Batch = struct {
    rows: []const u8,
    count: i64,
};

/// One message, with the rows and the schema in whichever oneof branch the
/// session's format calls for.
///
/// Both oneofs have to agree with `data_format`, and with each other. They used
/// not to: `encodeSession` consulted the format and this did not, so an ARROW
/// session came back labelled ARROW and was then served Avro rows under an Avro
/// schema. Passing the format in is what makes that unspellable.
fn encodeRowsResponse(
    arena: std.mem.Allocator,
    format: pb.DataFormat,
    batch: Batch,
    schema: ?[]const u8,
) ![]const u8 {
    var out: pb.ReadRowsResponse = .{ .row_count = batch.count };

    var avro_rows: pb.AvroRows = undefined;
    var arrow_batch: pb.ArrowRecordBatch = undefined;
    switch (format) {
        .ARROW => {
            arrow_batch = .{
                .serialized_record_batch = batch.rows,
                .row_count = batch.count,
            };
            out.rows = .{ .arrow_record_batch = &arrow_batch };
        },
        else => {
            avro_rows = .{
                .serialized_binary_rows = batch.rows,
                .row_count = batch.count,
            };
            out.rows = .{ .avro_rows = &avro_rows };
        },
    }

    // Only the first message carries the schema, which is where the client
    // looks when it was not given the session.
    var avro_schema: pb.AvroSchema = undefined;
    var arrow_schema: pb.ArrowSchema = undefined;
    if (schema) |bytes| switch (format) {
        .ARROW => {
            arrow_schema = .{ .serialized_schema = bytes };
            out.schema = .{ .arrow_schema = &arrow_schema };
        },
        else => {
            avro_schema = .{ .schema = bytes };
            out.schema = .{ .avro_schema = &avro_schema };
        },
    };
    return out.encode(arena);
}

pub const service_name = "google.cloud.bigquery.storage.v1.BigQueryRead";

pub const Service = struct {
    app: *bqserver.Server,
    sessions: SessionStore,
    /// Overridable so a test can force several messages without generating a
    /// megabyte of rows: the multi-message path is the one with the transport's
    /// send loop and per-message buffer lifetime behind it.
    batch_bytes: usize = max_batch_bytes,

    pub fn init(app: *bqserver.Server) Service {
        return .{ .app = app, .sessions = .{ .gpa = app.gpa } };
    }

    pub fn deinit(s: *Service) void {
        s.sessions.deinit();
    }

    /// The transport's `Dispatch`. Kept here rather than in grpc/server.zig so
    /// that file never has to know which methods exist.
    pub fn dispatch(s: *Service) grpc_server.Dispatch {
        return .{ .ctx = s, .func = call, .fault = fault };
    }

    /// What the caller sees when a method fails.
    ///
    /// The messages are prose because a client library puts them in front of a
    /// person; `@errorName` would surface "TooManyStreams" to someone who never
    /// wrote this code. Anything unlisted is INTERNAL — an error nothing here
    /// anticipated is this server's problem, and saying INVALID_ARGUMENT would
    /// send the caller looking for a mistake they did not make.
    fn fault(ctx: *anyopaque, err: anyerror) grpc_server.Fault {
        _ = ctx;
        return switch (err) {
            error.TooManyStreams => .{
                .status = .invalid_argument,
                .message = "max_stream_count must be 0 or 1: the emulator serves " ++
                    "a single stream per session",
            },
            error.TableNotFound => .{
                .status = .not_found,
                .message = "the requested table does not exist",
            },
            error.MalformedTableName => .{
                .status = .invalid_argument,
                .message = "read_session.table must be " ++
                    "projects/{project}/datasets/{dataset}/tables/{table}",
            },
            error.MalformedFieldName => .{
                .status = .invalid_argument,
                .message = "read_options.selected_fields entries must be " ++
                    "column names: letters, digits and underscores",
            },
            error.MissingTable => .{
                .status = .invalid_argument,
                .message = "read_session.table is required",
            },
            error.Truncated, error.Malformed => .{
                .status = .invalid_argument,
                .message = "the request could not be decoded as protobuf",
            },
            error.UnknownStream => .{
                .status = .not_found,
                .message = "no such stream: the session may have expired, or the " ++
                    "name did not come from CreateReadSession",
            },
            // The client wrote this expression, so it is theirs to fix; saying
            // INTERNAL would send them looking at the server instead.
            error.BadRestriction => .{
                .status = .invalid_argument,
                .message = "read_options.row_restriction is not a valid filter " ++
                    "expression over this table",
            },
            // These two analysed fine and then failed, so they are ours.
            error.QueryFailed => .{
                .status = .internal,
                .message = "the read failed while scanning the table",
            },
            error.EncodeFailed => .{
                .status = .internal,
                .message = "a value could not be encoded in the session's data format",
            },
            else => .{ .status = .internal, .message = "internal error" },
        };
    }

    /// Null means "no such method", which the transport turns into UNIMPLEMENTED.
    /// - `SplitReadStream` is deliberately in that bucket
    fn call(
        ctx: *anyopaque,
        arena: std.mem.Allocator,
        method: method_path.Method,
        request: []const u8,
    ) anyerror!?[]const []const u8 {
        const s: *Service = @ptrCast(@alignCast(ctx));
        if (!std.mem.eql(u8, method.service, service_name)) return null;
        if (std.mem.eql(u8, method.name, "CreateReadSession")) {
            // Unary: one message, then the status.
            const one = try arena.alloc([]const u8, 1);
            one[0] = try s.createReadSession(arena, request);
            return one;
        }
        if (std.mem.eql(u8, method.name, "ReadRows")) {
            return try s.readRows(arena, request);
        }
        // SplitReadStream lands here deliberately: Go answers UNIMPLEMENTED for
        // it too, and a session with one stream has nothing to split.
        return null;
    }

    /// Decodes a `CreateReadSessionRequest` and returns the encoded
    /// `ReadSession`, both allocated from `arena`.
    pub fn createReadSession(
        s: *Service,
        arena: std.mem.Allocator,
        request: []const u8,
    ) Error![]u8 {
        const req = try pb.CreateReadSessionRequest.decode(arena, request);

        // Reject more than one stream outright rather than silently serving one;
        // a client that asked for parallelism should find out.
        // Absent and 0 both mean "let the server decide", which is one.
        if ((req.max_stream_count orelse 0) > 1) return error.TooManyStreams;

        const in = req.read_session orelse return error.MissingTable;
        const table_name = in.table orelse return error.MissingTable;
        const ref = TableRef.parse(table_name) orelse return error.MalformedTableName;

        const schema_json = (try s.findTableJson(arena, ref)) orelse
            return error.TableNotFound;

        const names = try sessionNames(arena, ref.project, &s.app.rng);

        // See selectedFields: absent read_options is legal, not a crash.
        const selected = selectedFields(in.read_options);
        const restriction = rowRestriction(in.read_options);

        const format = agreedFormat(in.data_format);

        // The schema comes from the *query's* columns, not the stored metadata,
        // so it cannot disagree with the rows about type or order. The SELECT
        // list follows `selected_fields` in the order the client asked for
        // them; a schema built from the table would be in table order, and both
        // formats are positional, so every value would land in the wrong field.
        const sql = try buildQuery(arena, ref, selected, restriction);
        const schema = try s.schemaFor(arena, .{
            .format = format,
            .sql = sql,
            .table_json = schema_json,
        });

        // The stored session and the response are the same facts, so they are
        // the same value: a response built from its own copy of them is a
        // response that can disagree with what a later ReadRows will serve.
        const sess: Session = .{
            .id = names.id,
            .name = names.session,
            .table = table_name,
            .stream = names.stream,
            .data_format = format,
            .selected_fields = selected,
            .row_restriction = restriction,
            .schema = schema,
        };
        try s.sessions.put(sess);
        return encodeSession(arena, sess, in);
    }

    /// `ReadRows`: the session's rows, Avro-encoded, as a series of
    /// `ReadRowsResponse` messages.
    ///
    /// The engine lock is held for the query and the encode and dropped before
    /// any of this reaches the wire — docs/STORAGE_READ_PLAN.md §2. Streaming
    /// while holding it would let one slow reader stall every REST request in
    /// the process, and since the completion queue is a single thread, every
    /// other gRPC call too.
    ///
    /// The session is not a snapshot: the query runs again here, so a table
    /// changed since `CreateReadSession` yields the newer rows where BigQuery
    /// would serve what the session pinned. For an emulator reading fixtures
    /// that is a difference without a consequence.
    pub fn readRows(
        s: *Service,
        arena: std.mem.Allocator,
        request: []const u8,
    ) Error![]const []const u8 {
        const req = try pb.ReadRowsRequest.decode(arena, request);
        const stream = req.read_stream orelse return error.UnknownStream;
        const sess = s.sessions.getByStream(stream) orelse return error.UnknownStream;
        // `offset` is not optional to honour: the client tracks
        // `offset += row_count` and reconnects with it after a retryable error,
        // so ignoring it re-sends every row it already has.
        const offset: u64 = @intCast(@max(0, req.offset orelse 0));

        const ref = TableRef.parse(sess.table) orelse return error.MalformedTableName;
        const sql = try buildQuery(arena, ref, sess.selected_fields, sess.row_restriction);

        // The same metadata `CreateReadSession` read, for the same reason: a
        // column's REQUIRED-ness is not in its GoogleSQL type.
        const table_json = (try s.findTableJson(arena, ref)) orelse return error.TableNotFound;
        const required = try requiredColumns(arena, table_json);
        const batches = try s.encodeRows(arena, .{
            .sql = sql,
            .format = sess.data_format,
            .required = required,
            .offset = offset,
        });

        const out = try arena.alloc([]const u8, batches.len);
        for (batches, out, 0..) |batch, *dst, i| {
            dst.* = try encodeRowsResponse(
                arena,
                sess.data_format,
                batch,
                if (i == 0) sess.schema else null,
            );
        }
        return out;
    }

    /// Runs the query and encodes every row, under the engine lock.
    ///
    /// Returns whole batches rather than one buffer so a large table does not
    /// become a single protobuf message: the Python client raises its receive
    /// limit to unlimited, but a client on gRPC's 4 MB default would fail, and
    /// real BigQuery batches too.
    /// What one read needs to know, bundled so the walk into the engine carries
    /// one parameter rather than four.
    const Scan = struct {
        sql: []const u8,
        /// Which encoder the session promised its client.
        format: pb.DataFormat,
        /// Column names the table declared REQUIRED; everything else nullable.
        required: []const []const u8,
        /// Rows to skip, from `ReadRowsRequest.offset`.
        offset: u64,
    };

    fn encodeRows(
        s: *Service,
        arena: std.mem.Allocator,
        scan: Scan,
    ) Error![]const Batch {
        var batches: std.ArrayList(Batch) = .empty;

        s.app.engine_mutex.lockUncancelable(s.app.io);
        defer s.app.engine_mutex.unlock(s.app.io);

        var rows = s.app.db.query(scan.sql, &.{}, .{}) catch |err| {
            log.err("ReadRows query failed: {t} for {s}", .{ err, scan.sql });
            return error.QueryFailed;
        };
        // Every value `nextTyped` hands back lives in the statement's arena and
        // dies here, so the encoding below has to be finished by then -- it is,
        // because both encoders copy out before returning.
        defer rows.deinit();

        // Built by the same helper `schemaFor` used, so a column's nullability
        // is identical on both sides. When it was not -- `writeField` hardcoded
        // nullable while the schema honoured REQUIRED -- the datum carried a
        // branch index the schema had no union for, and every field after it
        // shifted by a byte.
        const sink: Sink = .{
            .arena = arena,
            .batches = &batches,
            .batch_bytes = s.batch_bytes,
            .cols = try outputColumns(arena, rows.columnTypes(), scan.required),
            .offset = scan.offset,
        };
        switch (scan.format) {
            .ARROW => try encodeArrowRows(sink, &rows),
            else => try encodeAvroRows(sink, &rows),
        }
        return batches.toOwnedSlice(arena);
    }

    /// The schema for `sql`, without running it.
    ///
    /// `Db.prepare` resolves the statement's output columns during analysis,
    /// before SQLite prepares anything, so this costs an analyze and no rows.
    /// It also means a bad `row_restriction` fails here — at session
    /// creation, where it can be INVALID_ARGUMENT — rather than mid-stream
    /// after the status has already gone out.
    ///
    /// `table_json` supplies the one thing `spec.Type` cannot: nullability.
    /// GoogleSQL types carry none, so REQUIRED comes from the table's declared
    /// modes, matched by column name.
    const SchemaRequest = struct {
        format: pb.DataFormat,
        sql: []const u8,
        /// The stored table resource, for its column modes.
        table_json: []const u8,
    };

    fn schemaFor(
        s: *Service,
        arena: std.mem.Allocator,
        req: SchemaRequest,
    ) Error![]const u8 {
        const required = try requiredColumns(arena, req.table_json);

        s.app.engine_mutex.lockUncancelable(s.app.io);
        defer s.app.engine_mutex.unlock(s.app.io);

        var stmt = s.app.db.prepare(req.sql, .{}) catch |err| {
            log.debug("prepare failed for {s}: {t}", .{ req.sql, err });
            return error.BadRestriction;
        };
        defer stmt.deinit();

        // The type lives in the statement's arena, which dies with it, so the
        // schema is rendered before that happens -- which is what both branches
        // below do.
        const cols = try outputColumns(arena, stmt.columns, required);
        return switch (req.format) {
            .ARROW => arrowSchemaBytes(arena, cols),
            else => avro.schemaJson(arena, cols),
        };
    }

    fn findTableJson(
        s: *Service,
        arena: std.mem.Allocator,
        ref: TableRef,
    ) !?[]const u8 {
        // The one place this service touches the engine. Held across the
        // lookup only; everything above and below runs unlocked.
        s.app.engine_mutex.lockUncancelable(s.app.io);
        defer s.app.engine_mutex.unlock(s.app.io);
        const app = s.app;
        const table_spec = (try app.db.catalogTable(
            arena,
            ref.project,
            ref.dataset,
            ref.table,
        )) orelse return null;
        return app.tableResource(arena, table_spec) catch |err| {
            log.err("rendering {s}.{s}.{s} failed: {t}", .{
                ref.project,
                ref.dataset,
                ref.table,
                err,
            });
            return null;
        };
    }
};

/// The `ReadSession` a client gets back: the stored session, plus the two
/// fields it echoes from the request.
fn encodeSession(arena: std.mem.Allocator, sess: Session, in: *pb.ReadSession) ![]u8 {
    var stream: pb.ReadStream = .{ .name = sess.stream };
    var streams = [_]*pb.ReadStream{&stream};

    var out: pb.ReadSession = .{
        .name = sess.name,
        .data_format = sess.data_format,
        .table = sess.table,
        .streams = &streams,
        .trace_id = in.trace_id,
        .read_options = in.read_options,
    };
    // The schema oneof has to match data_format, or a client decodes rows with
    // the wrong reader. `agreedFormat` has already narrowed the format to one
    // of these two, so there is no third case to leave schema-less.
    var avro_schema: pb.AvroSchema = undefined;
    var arrow_schema: pb.ArrowSchema = undefined;
    switch (sess.data_format) {
        .ARROW => {
            arrow_schema = .{ .serialized_schema = sess.schema };
            out.schema = .{ .arrow_schema = &arrow_schema };
        },
        else => {
            avro_schema = .{ .schema = sess.schema };
            out.schema = .{ .avro_schema = &avro_schema };
        },
    }
    return out.encode(arena);
}

/// Whether `name` is safe to interpolate into SQL as a quoted identifier.
///
/// `selected_fields` arrives from the client and ends up inside backticks in a
/// generated statement, so this is an injection surface. Rather than escape,
/// this rejects: BigQuery column names are letters, digits and underscores
/// starting with a letter or underscore, so anything else is not a column name
/// this server could serve regardless, and refusing is both safer and a better
/// error than a syntax failure from deep inside the analyzer.
pub fn isSafeIdentifier(name: []const u8) bool {
    if (name.len == 0 or name.len > 300) return false;
    if (!std.ascii.isAlphabetic(name[0]) and name[0] != '_') return false;
    for (name) |ch| {
        if (!std.ascii.isAlphanumeric(ch) and ch != '_') return false;
    }
    return true;
}

fn appendSelectList(
    arena: std.mem.Allocator,
    out: *std.ArrayList(u8),
    selected_fields: []const []const u8,
) !void {
    if (selected_fields.len == 0) return out.appendSlice(arena, "*");
    for (selected_fields, 0..) |f, i| {
        if (!isSafeIdentifier(f)) return error.MalformedFieldName;
        if (i != 0) try out.appendSlice(arena, ", ");
        try out.print(arena, "`{s}`", .{f});
    }
}

/// The SELECT a stream reads from.
///
/// Mirrors Go's storage_handler.go: the selected columns or `*`, the session's
/// table, and the row restriction as a WHERE clause.
///
/// `row_restriction` is passed through as SQL, deliberately: the field is
/// defined as a filter expression and a client sends one on purpose. So the
/// emulator runs whatever expression it is given, and is only ever as trusted
/// as the client. Real BigQuery restricts the grammar; matching that would
/// mean parsing it, which the analyzer already does downstream when the
/// statement fails to compile.
pub fn buildQuery(
    arena: std.mem.Allocator,
    ref: TableRef,
    selected_fields: []const []const u8,
    row_restriction: []const u8,
) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try out.appendSlice(arena, "SELECT ");
    try appendSelectList(arena, &out, selected_fields);
    // Dataset-qualified, not project-qualified: the engine's catalog is one
    // project, and the REST query path names tables the same way.
    if (!isSafeIdentifier(ref.dataset) or !isSafeIdentifier(ref.table)) {
        return error.MalformedTableName;
    }
    try out.print(arena, " FROM `{s}`.`{s}`", .{ ref.dataset, ref.table });
    if (row_restriction.len != 0) {
        try out.print(arena, " WHERE {s}", .{row_restriction});
    }
    return out.toOwnedSlice(arena);
}

/// The three names a session is known by, built together because the stream
/// name has to be the session name plus a suffix — that is the only thread
/// `ReadRows` has back to the session it belongs to.
const Names = struct { id: []const u8, session: []const u8, stream: []const u8 };

fn sessionNames(
    arena: std.mem.Allocator,
    project: []const u8,
    rng: *std.Random.DefaultPrng,
) !Names {
    const id = try randomSessionId(arena, rng);
    const session = try std.fmt.allocPrint(
        arena,
        "projects/{s}/locations/{s}/sessions/{s}",
        .{ project, location, id },
    );
    return .{
        .id = id,
        .session = session,
        .stream = try std.fmt.allocPrint(arena, "{s}/streams/0", .{session}),
    };
}

/// Go's randomID, as the REST handlers use for job ids.
fn randomSessionId(arena: std.mem.Allocator, rng: *std.Random.DefaultPrng) ![]const u8 {
    const alphabet = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789";
    const out = try arena.alloc(u8, 27);
    for (out) |*c| c.* = alphabet[rng.random().uintLessThan(usize, alphabet.len)];
    return out;
}

/// `read_options` absent means "the whole table", not a crash: a client that
/// wants every column sends no ReadOptions at all. Go carries a comment about
/// exactly this.
fn selectedFields(opts: ?*pb.ReadSession_TableReadOptions) []const []const u8 {
    return if (opts) |o| o.selected_fields else &.{};
}

fn rowRestriction(opts: ?*pb.ReadSession_TableReadOptions) []const u8 {
    return if (opts) |o| (o.row_restriction orelse "") else "";
}

/// The format a session will be served in.
///
/// Both are real; anything else — including the unset value — is the client
/// leaving the choice to the server, and AVRO is the answer, as it is in
/// BigQuery. Narrowing here rather than at each use is what lets everything
/// downstream treat the format as a two-way switch: a third value that reached
/// `encodeSession` would come back with no schema at all.
///
/// ARROW is not an exotic request. google-cloud-bigquery asks for it
/// unconditionally on its `to_dataframe`/`to_arrow` and DB-API paths, so it is
/// the common case for anything going through the Storage path at all.
fn agreedFormat(requested: ?pb.DataFormat) pb.DataFormat {
    return switch (requested orelse .DATA_FORMAT_UNSPECIFIED) {
        .ARROW => .ARROW,
        else => .AVRO,
    };
}

/// Where a scan's rows go, bundled because both loops below need all of it and
/// neither reads better with six parameters.
///
/// Every batch it produces carries at least one message, even for no rows: the
/// client takes the schema from the first message of the stream when it was not
/// handed the session, so a read with nothing in it still has to carry one. Each
/// encoder spells "empty" its own way, which is why neither can synthesise it
/// for the other.
const Sink = struct {
    arena: std.mem.Allocator,
    batches: *std.ArrayList(Batch),
    /// The flush threshold. Meaning it the same way for both formats is what
    /// lets one `batch_bytes` knob configure either.
    batch_bytes: usize,
    cols: []const avro.Column,
    /// Rows to skip, from `ReadRowsRequest.offset`.
    offset: u64,
};

fn encodeAvroRows(k: Sink, rows: *driver.Rows) Error!void {
    const arena = k.arena;
    var w = avro.Writer.init(arena);
    var count: i64 = 0;
    var skipped: u64 = 0;

    while (rows.nextTyped() catch return error.QueryFailed) |row| {
        if (skipped < k.offset) {
            skipped += 1;
            continue;
        }
        try writeRow(&w, k.cols, row);
        count += 1;
        if (w.bytes().len < k.batch_bytes) continue;
        const done = w.toOwnedSlice() catch return error.EncodeFailed;
        try k.batches.append(arena, .{ .rows = done, .count = count });
        w = avro.Writer.init(arena);
        count = 0;
    }
    // The empty Avro payload is the empty string -- `serialized_binary_rows` is
    // datums end to end, so zero rows is zero bytes.
    if (count != 0 or k.batches.items.len == 0) {
        const done = w.toOwnedSlice() catch return error.EncodeFailed;
        try k.batches.append(arena, .{ .rows = done, .count = count });
    }
}

/// The columnar counterpart, and the reason `Batch` carries bytes rather than a
/// writer: rows go into per-column builders and nothing is encoded until a
/// batch is flushed.
fn encodeArrowRows(k: Sink, rows: *driver.Rows) Error!void {
    // One schema for the whole scan, a fresh builder per batch: a builder is
    // spent once its buffers are sealed, but the schema it was built from is
    // read again for every batch, so it has to outlive all of them.
    var schema = try arrow.buildSchema(k.arena, k.cols);
    defer schema.deinit();

    var b = try arrow.Builder.init(schema, k.cols);
    // `flushArrowBatch` replaces `b`, so this frees whichever builder is live
    // at the end rather than the one it was written next to.
    defer b.deinit();

    var skipped: u64 = 0;
    while (rows.nextTyped() catch return error.QueryFailed) |row| {
        if (skipped < k.offset) {
            skipped += 1;
            continue;
        }
        b.appendRow(row) catch return error.EncodeFailed;
        if (b.byteCount() < k.batch_bytes) continue;
        try flushArrowBatch(k, &b, schema);
    }
    // An empty Arrow batch is a real message -- header, flatbuffer, buffer
    // offsets -- and not the empty string an Avro one can be. A client handed
    // "" here fails to parse it rather than reading zero rows.
    if (b.rowCount() != 0 or k.batches.items.len == 0) {
        try flushArrowBatch(k, &b, schema);
    }
}

/// Encodes what `b` holds, copies it out, and leaves `b` a fresh builder.
fn flushArrowBatch(k: Sink, b: *arrow.Builder, schema: arrow.Schema) Error!void {
    const count = b.rowCount();
    // The bytes belong to the builder, which is about to be freed.
    const owned = try k.arena.dupe(u8, b.encode() catch return error.EncodeFailed);
    // The replacement is built before the spent one is freed, so a failure here
    // still leaves `b` pointing at something the caller's defer can release.
    const next = try arrow.Builder.init(schema, k.cols);
    b.deinit();
    b.* = next;
    return k.batches.append(k.arena, .{ .rows = owned, .count = count });
}

/// One row's datums, concatenated. No framing: `serialized_binary_rows` is
/// exactly the rows' encodings end to end.
fn writeRow(
    w: *avro.Writer,
    cols: []const avro.Column,
    row: []const value_mod.Value,
) Error!void {
    if (row.len != cols.len) return error.QueryFailed;
    for (cols, row) |col, v| {
        avro.writeField(w, col.type, v, col.nullable) catch return error.EncodeFailed;
    }
}

/// The encapsulated IPC schema message, copied out of nanoarrow's own buffer —
/// which dies with the schema handle, where the session outlives both.
fn arrowSchemaBytes(arena: std.mem.Allocator, cols: []const arrow.Column) Error![]const u8 {
    var schema = try arrow.buildSchema(arena, cols);
    defer schema.deinit();
    return arena.dupe(u8, try schema.encode());
}

/// The output columns for a statement, with their modes.
///
/// The single place nullability is decided, called by both the schema side and
/// the row side, for both formats — they have to agree exactly, and a
/// `["null", T]` in one but not the other shifts every subsequent Avro field by
/// a byte. `arrow.Column` is `avro.Column`, so there is one answer and not two.
fn outputColumns(
    arena: std.mem.Allocator,
    columns: []const driver.OutputColumn,
    required: []const []const u8,
) ![]const avro.Column {
    const out = try arena.alloc(avro.Column, columns.len);
    for (columns, out) |src, *dst| {
        dst.* = .{
            .name = try arena.dupe(u8, src.name),
            .type = src.type,
            .nullable = !contains(required, src.name),
        };
    }
    return out;
}

/// The names of columns the table declared REQUIRED.
///
/// Everything else is nullable, which is the safe default: a client handed
/// `["null", T]` decodes a non-null value fine, where the reverse loses the
/// ability to say null at all. The REST path never writes `"mode":"NULLABLE"`
/// (see internal/types/schema.zig), so absence means nullable.
fn requiredColumns(arena: std.mem.Allocator, table_json: []const u8) ![]const []const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, arena, table_json, .{}) catch
        return &.{};
    const root = asObject(parsed.value) orelse return &.{};
    const schema = asObject(root.get("schema") orelse return &.{}) orelse return &.{};
    const fields = switch (schema.get("fields") orelse return &.{}) {
        .array => |arr| arr,
        else => return &.{},
    };
    var out: std.ArrayList([]const u8) = .empty;
    for (fields.items) |f| {
        const obj = asObject(f) orelse continue;
        const mode = asString(obj.get("mode") orelse continue) orelse continue;
        if (!std.mem.eql(u8, mode, "REQUIRED")) continue;
        try out.append(arena, asString(obj.get("name") orelse continue) orelse continue);
    }
    return out.toOwnedSlice(arena);
}

fn asObject(v: std.json.Value) ?std.json.ObjectMap {
    return switch (v) {
        .object => |o| o,
        else => null,
    };
}

fn asString(v: std.json.Value) ?[]const u8 {
    return switch (v) {
        .string, .number_string => |s| s,
        else => null,
    };
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |h| if (std.mem.eql(u8, h, needle)) return true;
    return false;
}

const testing = std.testing;

test "TableRef.parse accepts the Storage spelling and rejects the rest" {
    const ok = TableRef.parse("projects/p/datasets/d/tables/t").?;
    try testing.expectEqualStrings("p", ok.project);
    try testing.expectEqualStrings("d", ok.dataset);
    try testing.expectEqualStrings("t", ok.table);

    // A table id may contain characters the REST API allows.
    const dashed = TableRef.parse("projects/my-proj/datasets/ds_1/tables/t$20240101").?;
    try testing.expectEqualStrings("my-proj", dashed.project);
    try testing.expectEqualStrings("t$20240101", dashed.table);

    // The REST short form is not a Storage table name.
    try testing.expectEqual(@as(?TableRef, null), TableRef.parse("d.t"));
    try testing.expectEqual(@as(?TableRef, null), TableRef.parse(""));
    try testing.expectEqual(@as(?TableRef, null), TableRef.parse("projects/p/datasets/d"));
    try testing.expectEqual(@as(?TableRef, null), TableRef.parse("projects/p/datasets/d/tables/t/x"));
    try testing.expectEqual(@as(?TableRef, null), TableRef.parse("projects//datasets/d/tables/t"));
    // Right shape, wrong literals.
    try testing.expectEqual(@as(?TableRef, null), TableRef.parse("proj/p/datasets/d/tables/t"));
    try testing.expectEqual(@as(?TableRef, null), TableRef.parse("projects/p/sets/d/tables/t"));
}

test "SessionStore finds a session by its stream name" {
    var store: SessionStore = .{ .gpa = testing.allocator };
    defer store.deinit();

    try store.put(.{
        .id = "sess1",
        .name = "projects/p/locations/us/sessions/sess1",
        .table = "projects/p/datasets/d/tables/t",
        .stream = "projects/p/locations/us/sessions/sess1/streams/0",
        .data_format = .AVRO,
        .selected_fields = &.{ "a", "b" },
        .row_restriction = "id > 1",
        .schema = "{\"type\":\"record\",\"name\":\"__root__\",\"fields\":[]}",
    });

    const by_id = store.get("sess1").?;
    try testing.expectEqualStrings("projects/p/datasets/d/tables/t", by_id.table);
    try testing.expectEqual(@as(usize, 2), by_id.selected_fields.len);
    try testing.expectEqualStrings("id > 1", by_id.row_restriction);

    const by_stream = store.getByStream(
        "projects/p/locations/us/sessions/sess1/streams/0",
    ).?;
    try testing.expectEqualStrings("sess1", by_stream.id);

    try testing.expectEqual(@as(?Session, null), store.getByStream("garbage"));
    try testing.expectEqual(@as(?Session, null), store.getByStream("…/sessions/nope/streams/0"));
}

// ---- CreateReadSession, end to end against a real Server ----
//
// These build a table through the REST handler and then call the service
// directly: no completion queue, no socket, no thread. The transport is
// covered by harness/grpc_smoke.zig; what is worth pinning here is the
// request-to-response behaviour, which is where the interesting mistakes are.

const http_server = @import("../http/server.zig");

/// Same shape as the harness in server.zig: dispatch without a listener.
const Rest = struct {
    method: std.http.Method,
    path: []const u8,
    body: []const u8 = "",
};

fn restRequest(
    s: *bqserver.Server,
    arena: std.mem.Allocator,
    r: Rest,
) !http_server.Response {
    var req = http_server.Request{
        .method = r.method,
        .path = r.path,
        .query = "",
        .body = r.body,
        .arena = arena,
    };
    const h = s.handler();
    return h.func(h.ctx, &req);
}

fn newServerWithTable(arena: std.mem.Allocator) !*bqserver.Server {
    // `io` is never pumped: nothing here touches the filesystem, and the engine
    // mutex is uncontended in a single-threaded test, so it is never read.
    const io: std.Io = undefined;
    const s = try bqserver.Server.init(testing.allocator, io, .{
        .project = "test",
        .dataset = "ds1",
    });
    errdefer s.deinit();
    _ = try restRequest(s, arena, .{
        .method = .POST,
        .path = "/projects/test/datasets/ds1/tables",
        .body =
        \\{"tableReference":{"projectId":"test","datasetId":"ds1","tableId":"t"},
        \\ "schema":{"fields":[{"name":"id","type":"INTEGER","mode":"REQUIRED"},
        \\                     {"name":"name","type":"STRING"}]}}
        ,
    });
    return s;
}

/// Encodes a CreateReadSessionRequest the way a client would.
fn encodeRequest(
    arena: std.mem.Allocator,
    table: []const u8,
    max_streams: ?i32,
    opts: ?*pb.ReadSession_TableReadOptions,
) ![]u8 {
    return encodeRequestFormat(arena, .{
        .table = table,
        .max_streams = max_streams,
        .opts = opts,
    });
}

const Request = struct {
    table: []const u8,
    max_streams: ?i32 = null,
    opts: ?*pb.ReadSession_TableReadOptions = null,
    format: pb.DataFormat = .AVRO,
};

fn encodeRequestFormat(arena: std.mem.Allocator, r: Request) ![]u8 {
    var sess: pb.ReadSession = .{
        .table = r.table,
        .data_format = r.format,
        .read_options = r.opts,
    };
    const req: pb.CreateReadSessionRequest = .{
        .parent = "projects/test",
        .read_session = &sess,
        .max_stream_count = r.max_streams,
    };
    return req.encode(arena);
}

test "CreateReadSession returns one stream and a schema for the table" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const bytes = try svc.createReadSession(
        arena,
        try encodeRequest(arena, "projects/test/datasets/ds1/tables/t", 1, null),
    );
    const out = try pb.ReadSession.decode(arena, bytes);

    // Exactly one stream, always: more is what the materialize-then-stream
    // design in docs/STORAGE_READ_PLAN.md §2 is not safe for.
    try testing.expectEqual(@as(usize, 1), out.streams.len);
    try testing.expectEqualStrings("projects/test/datasets/ds1/tables/t", out.table.?);
    try testing.expectEqual(pb.DataFormat.AVRO, out.data_format.?);

    // The stream name has to be the session name plus /streams/N, because that
    // is the only thing ReadRows gets to identify the session with.
    try testing.expect(std.mem.startsWith(u8, out.streams[0].name.?, out.name.?));
    try testing.expect(std.mem.startsWith(u8, out.name.?, "projects/test/locations/us/sessions/"));
    try testing.expectEqualStrings(
        try std.fmt.allocPrint(arena, "{s}/streams/0", .{out.name.?}),
        out.streams[0].name.?,
    );

    // REQUIRED stays a bare type, NULLABLE becomes a union with null first.
    try testing.expectEqualStrings(
        "{\"type\":\"record\",\"name\":\"__root__\",\"fields\":[" ++
            "{\"name\":\"id\",\"type\":\"long\"}," ++
            "{\"name\":\"name\",\"type\":[\"null\",\"string\"]}]}",
        out.schema.?.avro_schema.schema.?,
    );

    // And the session is retrievable by the stream name ReadRows will send.
    try testing.expect(svc.sessions.getByStream(out.streams[0].name.?) != null);
}

test "CreateReadSession without read_options means the whole table" {
    // Absent ReadOptions is the common case — a client reading every column
    // sends none — and dereferencing it anyway is the crash Go carries a
    // comment about.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const bytes = try svc.createReadSession(
        arena,
        try encodeRequest(arena, "projects/test/datasets/ds1/tables/t", null, null),
    );
    const out = try pb.ReadSession.decode(arena, bytes);
    const sess = svc.sessions.getByStream(out.streams[0].name.?).?;
    try testing.expectEqual(@as(usize, 0), sess.selected_fields.len);
    try testing.expectEqualStrings("", sess.row_restriction);
    // Both columns survive into the schema.
    try testing.expect(std.mem.indexOf(u8, out.schema.?.avro_schema.schema.?, "\"id\"") != null);
    try testing.expect(std.mem.indexOf(u8, out.schema.?.avro_schema.schema.?, "\"name\"") != null);
}

test "CreateReadSession remembers read_options for the read that follows" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    var selected = [_][]const u8{"name"};
    var opts: pb.ReadSession_TableReadOptions = .{
        .selected_fields = &selected,
        .row_restriction = "id > 10",
    };
    const bytes = try svc.createReadSession(
        arena,
        try encodeRequest(arena, "projects/test/datasets/ds1/tables/t", 1, &opts),
    );
    const out = try pb.ReadSession.decode(arena, bytes);

    // S4 builds its SELECT from these, so they have to outlive the request
    // arena they arrived in — SessionStore copies them into the gpa.
    const sess = svc.sessions.getByStream(out.streams[0].name.?).?;
    try testing.expectEqual(@as(usize, 1), sess.selected_fields.len);
    try testing.expectEqualStrings("name", sess.selected_fields[0]);
    try testing.expectEqualStrings("id > 10", sess.row_restriction);

    // The schema follows the selection.
    try testing.expectEqual(
        @as(?usize, null),
        std.mem.indexOf(u8, out.schema.?.avro_schema.schema.?, "\"id\""),
    );
}

test "CreateReadSession rejects what it cannot serve" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const T = "projects/test/datasets/ds1/tables/t";
    try testing.expectError(
        error.TooManyStreams,
        svc.createReadSession(arena, try encodeRequest(arena, T, 2, null)),
    );
    try testing.expectError(
        error.TableNotFound,
        svc.createReadSession(
            arena,
            try encodeRequest(arena, "projects/test/datasets/ds1/tables/nope", 1, null),
        ),
    );
    try testing.expectError(
        error.MalformedTableName,
        svc.createReadSession(arena, try encodeRequest(arena, "ds1.t", 1, null)),
    );

    // An empty request body is legal protobuf, so this must be a clean error
    // rather than a decode failure or a null dereference.
    try testing.expectError(error.MissingTable, svc.createReadSession(arena, ""));

    // 0 means "let the server decide", not "no streams".
    const ok = try svc.createReadSession(arena, try encodeRequest(arena, T, 0, null));
    const out = try pb.ReadSession.decode(arena, ok);
    try testing.expectEqual(@as(usize, 1), out.streams.len);
}

test "every rejection maps to a status a caller can act on" {
    // A wrong status is worse than a wrong message: a client retries on
    // INTERNAL and gives up on INVALID_ARGUMENT.
    const S = @import("c.zig").Status;
    const cases = [_]struct { err: anyerror, want: S }{
        .{ .err = error.TooManyStreams, .want = .invalid_argument },
        .{ .err = error.TableNotFound, .want = .not_found },
        .{ .err = error.MalformedTableName, .want = .invalid_argument },
        .{ .err = error.MissingTable, .want = .invalid_argument },
        .{ .err = error.Malformed, .want = .invalid_argument },
        // Anything unanticipated is ours, not the caller's.
        .{ .err = error.OutOfMemory, .want = .internal },
    };
    for (cases) |case| {
        try testing.expectEqual(case.want, Service.fault(undefined, case.err).status);
    }

    // And the messages are prose, not error names: a client library shows them
    // to a person.
    for ([_]anyerror{
        error.TooManyStreams, error.TableNotFound, error.MalformedTableName,
        error.MissingTable,   error.Malformed,     error.OutOfMemory,
    }) |e| {
        const msg = Service.fault(undefined, e).message;
        try testing.expect(msg.len > 0);
        try testing.expect(!std.mem.eql(u8, msg, @errorName(e)));
    }
}

test "an unknown method is not this service's business" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const d = svc.dispatch();
    const none: ?[]const []const u8 = null;

    // SplitReadStream is deliberately absent: Go answers UNIMPLEMENTED for it
    // too, and a session with one stream has nothing to split.
    try testing.expectEqual(
        none,
        try d.func(d.ctx, arena, .{ .service = service_name, .name = "SplitReadStream" }, ""),
    );
    // Some other service entirely.
    try testing.expectEqual(
        none,
        try d.func(d.ctx, arena, .{ .service = "other.Service", .name = "CreateReadSession" }, ""),
    );
    // ReadRows, by contrast, is now this service's business -- it fails on the
    // stream name rather than falling through to UNIMPLEMENTED.
    try testing.expectError(
        error.UnknownStream,
        d.func(d.ctx, arena, .{ .service = service_name, .name = "ReadRows" }, ""),
    );
}

// ---- the SELECT a stream reads from ----

test "buildQuery produces the statement a stream reads" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ref = TableRef.parse("projects/p/datasets/ds1/tables/t").?;

    // No selection and no restriction: the whole table.
    try testing.expectEqualStrings(
        "SELECT * FROM `ds1`.`t`",
        try buildQuery(a, ref, &.{}, ""),
    );

    var two = [_][]const u8{ "a", "b" };
    try testing.expectEqualStrings(
        "SELECT `a`, `b` FROM `ds1`.`t`",
        try buildQuery(a, ref, &two, ""),
    );

    try testing.expectEqualStrings(
        "SELECT * FROM `ds1`.`t` WHERE id > 10",
        try buildQuery(a, ref, &.{}, "id > 10"),
    );

    var one = [_][]const u8{"a"};
    try testing.expectEqualStrings(
        "SELECT `a` FROM `ds1`.`t` WHERE id > 10 AND b IS NOT NULL",
        try buildQuery(a, ref, &one, "id > 10 AND b IS NOT NULL"),
    );
}

test "buildQuery refuses a field name it cannot quote safely" {
    // selected_fields comes off the wire and lands inside backticks. Escaping
    // is not attempted: a name that is not a column name is rejected, which is
    // both safer and a better error than a syntax failure inside the analyzer.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const ref = TableRef.parse("projects/p/datasets/ds1/tables/t").?;

    const hostile = [_][]const u8{
        "a` FROM `ds1`.`secrets` --",
        "a`, (SELECT 1) AS `b",
        "a\\`b",
        "a b",
        "a;DROP TABLE t",
        "1a",
        "",
        "a-b",
        "a.b",
    };
    for (hostile) |bad| {
        var fields = [_][]const u8{bad};
        try testing.expectError(
            error.MalformedFieldName,
            buildQuery(a, ref, &fields, ""),
        );
    }

    // And the shapes that are legitimately fine.
    for ([_][]const u8{ "a", "_a", "A1", "snake_case_99" }) |ok| {
        var fields = [_][]const u8{ok};
        _ = try buildQuery(a, ref, &fields, "");
    }
}

test "the query a session builds actually runs on the engine" {
    // The point of the builder is that the engine accepts what it emits — a
    // string test alone would not catch a wrong quoting style or a table
    // reference the catalog cannot resolve.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/datasets/ds1/tables/t/insertAll",
        .body =
        \\{"rows":[{"json":{"id":"1","name":"a"}},{"json":{"id":"2","name":"b"}}]}
        ,
    });

    const ref = TableRef.parse("projects/test/datasets/ds1/tables/t").?;
    var fields = [_][]const u8{"id"};
    const sql = try buildQuery(arena, ref, &fields, "id > 1");

    var rows = try app.db.query(sql, &.{}, .{});
    defer rows.deinit();

    // One column, because the selection asked for one.
    try testing.expectEqual(@as(usize, 1), rows.columnTypes().len);
    try testing.expectEqualStrings("id", rows.columnTypes()[0].name);

    // One row, because the restriction excluded the other — and typed, which
    // is what S5 will encode from.
    const row = (try rows.nextTyped()).?;
    try testing.expectEqual(@as(i64, 2), row[0].int);
    try testing.expectEqual(@as(?[]const @import("zigquery").value.Value, null), try rows.nextTyped());
}

test "a whole-table query runs and yields every column typed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/datasets/ds1/tables/t/insertAll",
        .body = "{\"rows\":[{\"json\":{\"id\":\"7\",\"name\":\"x\"}}]}",
    });

    const ref = TableRef.parse("projects/test/datasets/ds1/tables/t").?;
    var rows = try app.db.query(try buildQuery(arena, ref, &.{}, ""), &.{}, .{});
    defer rows.deinit();

    try testing.expectEqual(@as(usize, 2), rows.columnTypes().len);
    const row = (try rows.nextTyped()).?;
    try testing.expectEqual(@as(i64, 7), row[0].int);
    try testing.expectEqualStrings("x", row[1].string);
}

// ---- the query S5 will run ----

test "buildQuery guards the table reference, not only the field names" {
    // The field names are covered above; this is the other half of the same
    // interpolation. Both parts come out of a client-supplied resource name.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    try testing.expectError(error.MalformedTableName, buildQuery(
        a,
        .{ .project = "p", .dataset = "ds1`.`secrets", .table = "t" },
        &.{},
        "",
    ));
    try testing.expectError(error.MalformedTableName, buildQuery(
        a,
        .{ .project = "p", .dataset = "ds1", .table = "t` --" },
        &.{},
        "",
    ));
    // A table decorator is a legal REST table id but not a legal identifier
    // here, so a session over one is refused rather than mis-quoted.
    try testing.expectError(error.MalformedTableName, buildQuery(
        a,
        .{ .project = "p", .dataset = "ds1", .table = "t$20240101" },
        &.{},
        "",
    ));
}

test "the query a session builds actually runs and reads back typed" {
    // The S4 gate, end to end: session -> SQL -> nextTyped. A query the builder
    // produces but the engine rejects would be caught here and nowhere else,
    // because every test above only compares strings.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"INSERT INTO ds1.t (id, name) VALUES (1, 'a'), (2, NULL)"}
        ,
    });

    var selected = [_][]const u8{"id"};
    var opts: pb.ReadSession_TableReadOptions = .{
        .selected_fields = &selected,
        .row_restriction = "id > 1",
    };
    const bytes = try svc.createReadSession(
        arena,
        try encodeRequest(arena, "projects/test/datasets/ds1/tables/t", 1, &opts),
    );
    const out = try pb.ReadSession.decode(arena, bytes);
    const sess = svc.sessions.getByStream(out.streams[0].name.?).?;

    const ref = TableRef.parse(sess.table).?;
    const sql = try buildQuery(arena, ref, sess.selected_fields, sess.row_restriction);
    try testing.expectEqualStrings("SELECT `id` FROM `ds1`.`t` WHERE id > 1", sql);

    var rows = try app.db.query(sql, &.{}, .{});
    defer rows.deinit();

    // Typed, not rendered: an i64, where a REST cell would carry the text "2".
    const row = (try rows.nextTyped()).?;
    try testing.expectEqual(@as(usize, 1), row.len);
    try testing.expectEqual(@as(i64, 2), row[0].int);
    try testing.expectEqual(@as(?[]const value_mod.Value, null), try rows.nextTyped());
}

// ---- ReadRows ----

/// Creates a session over `ds1.t` and returns its stream name.
fn openSession(
    svc: *Service,
    arena: std.mem.Allocator,
    opts: ?*pb.ReadSession_TableReadOptions,
) ![]const u8 {
    const bytes = try svc.createReadSession(
        arena,
        try encodeRequest(arena, "projects/test/datasets/ds1/tables/t", 1, opts),
    );
    const out = try pb.ReadSession.decode(arena, bytes);
    return out.streams[0].name.?;
}

fn readRowsRequest(arena: std.mem.Allocator, stream: []const u8, offset: ?i64) ![]u8 {
    const req: pb.ReadRowsRequest = .{ .read_stream = stream, .offset = offset };
    return req.encode(arena);
}

test "ReadRows returns the rows, and only the first message carries the schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"INSERT INTO ds1.t (id, name) VALUES (1, 'a'), (2, NULL)"}
        ,
    });

    const stream = try openSession(&svc, arena, null);
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, stream, null));
    try testing.expectEqual(@as(usize, 1), msgs.len);

    const resp = try pb.ReadRowsResponse.decode(arena, msgs[0]);
    // row_count is not decoration: the client adds it to its own offset and
    // reconnects with the total after a retryable error.
    try testing.expectEqual(@as(?i64, 2), resp.row_count);
    try testing.expectEqual(@as(?i64, 2), resp.rows.?.avro_rows.row_count);

    // The schema rides on the first message because that is where a client
    // that was not handed the session looks for it.
    const schema = resp.schema.?.avro_schema.schema.?;
    try testing.expect(std.mem.indexOf(u8, schema, "\"__root__\"") != null);
    // `id` is REQUIRED in the fixture, so it is a bare long; `name` is not.
    try testing.expect(std.mem.indexOf(u8, schema, "{\"name\":\"id\",\"type\":\"long\"}") != null);
    try testing.expect(
        std.mem.indexOf(u8, schema, "{\"name\":\"name\",\"type\":[\"null\",\"string\"]}") != null,
    );

    // Two rows: (1, "a") then (2, null). `id` REQUIRED so no branch index;
    // `name` nullable so branch 1 + "a", then branch 0 alone.
    try testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x02, 0x02, 'a', 0x04, 0x00 },
        resp.rows.?.avro_rows.serialized_binary_rows.?,
    );
}

test "ReadRows honours offset, because a client retry depends on it" {
    // ReadRowsStream tracks `offset += row_count` and reconnects with the total
    // after a retryable error. A server that ignores it re-sends every row the
    // client already has.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"INSERT INTO ds1.t (id, name) VALUES (1, 'a'), (2, 'b'), (3, 'c')"}
        ,
    });

    const stream = try openSession(&svc, arena, null);
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, stream, 2));
    const resp = try pb.ReadRowsResponse.decode(arena, msgs[0]);

    try testing.expectEqual(@as(?i64, 1), resp.row_count);
    // Just the third row: id=3 (zigzag 6), then branch 1 and "c".
    try testing.expectEqualSlices(
        u8,
        &.{ 0x06, 0x02, 0x02, 'c' },
        resp.rows.?.avro_rows.serialized_binary_rows.?,
    );

    // An offset past the end is empty, not an error -- and still one message.
    const past = try svc.readRows(arena, try readRowsRequest(arena, stream, 99));
    try testing.expectEqual(@as(usize, 1), past.len);
    const empty = try pb.ReadRowsResponse.decode(arena, past[0]);
    try testing.expectEqual(@as(?i64, 0), empty.row_count);
}

test "a read with no rows still sends one message, carrying the schema" {
    // The client takes the Avro schema from the first message of the stream
    // when it was not handed the session. No message means no schema, and
    // `rows()` cannot decode anything -- including the emptiness.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const stream = try openSession(&svc, arena, null);
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, stream, null));

    try testing.expectEqual(@as(usize, 1), msgs.len);
    const resp = try pb.ReadRowsResponse.decode(arena, msgs[0]);
    try testing.expectEqual(@as(?i64, 0), resp.row_count);
    try testing.expectEqualStrings("", resp.rows.?.avro_rows.serialized_binary_rows.?);
    try testing.expect(resp.schema != null);
}

test "ReadRows reads the columns the session selected, in that order" {
    // The schema must follow the SELECT list's order, not the table's: Avro
    // records are positional, so a schema in table order puts every value in
    // the wrong field.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"INSERT INTO ds1.t (id, name) VALUES (7, 'g')"}
        ,
    });

    // Asked for in the opposite order to the table's.
    var selected = [_][]const u8{ "name", "id" };
    var opts: pb.ReadSession_TableReadOptions = .{ .selected_fields = &selected };
    const stream = try openSession(&svc, arena, &opts);
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, stream, null));
    const resp = try pb.ReadRowsResponse.decode(arena, msgs[0]);

    // The schema must say name-then-id, matching the SELECT.
    const schema = resp.schema.?.avro_schema.schema.?;
    try testing.expect(
        std.mem.indexOf(u8, schema, "\"name\"").? < std.mem.indexOf(u8, schema, "\"id\"").?,
    );
    // And the datum is "g" then 7, in that order. `id` keeps its REQUIRED-ness
    // through the projection, so it has no branch index.
    try testing.expectEqualSlices(
        u8,
        &.{ 0x02, 0x02, 'g', 0x0e },
        resp.rows.?.avro_rows.serialized_binary_rows.?,
    );
}

test "ReadRows rejects a stream nobody owns" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    try testing.expectError(error.UnknownStream, svc.readRows(
        arena,
        try readRowsRequest(arena, "projects/p/locations/us/sessions/nope/streams/0", null),
    ));
    // NOT_FOUND, not the INTERNAL everything unlisted falls to: the caller can
    // act on this one.
    try testing.expectEqual(
        @import("c.zig").Status.not_found,
        Service.fault(undefined, error.UnknownStream).status,
    );
}

test "a row_restriction that does not analyse fails at session creation" {
    // Better here than mid-stream: once ReadRows has sent its status there is
    // nowhere left to report a failure.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    var opts: pb.ReadSession_TableReadOptions = .{ .row_restriction = "no_such_column > 1" };
    try testing.expectError(error.BadRestriction, svc.createReadSession(
        arena,
        try encodeRequest(arena, "projects/test/datasets/ds1/tables/t", 1, &opts),
    ));
    try testing.expectEqual(
        @import("c.zig").Status.invalid_argument,
        Service.fault(undefined, error.BadRestriction).status,
    );
}

test "a large read is split across messages, each with its own row_count" {
    // The client sums `row_count` across messages to track its own offset, so
    // a batch boundary is exactly where that arithmetic could go wrong. Only
    // the first message carries the schema.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();
    // Small enough that every row starts a new batch.
    svc.batch_bytes = 4;

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"INSERT INTO ds1.t (id, name) VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d')"}
        ,
    });

    const stream = try openSession(&svc, arena, null);
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, stream, null));
    try testing.expect(msgs.len > 1);

    var total: i64 = 0;
    for (msgs, 0..) |m, i| {
        const resp = try pb.ReadRowsResponse.decode(arena, m);
        total += resp.row_count.?;
        try testing.expectEqual(resp.row_count, resp.rows.?.avro_rows.row_count);
        // Schema on the first message only: repeating it would be legal but
        // wasteful, and omitting it from the first breaks `rows()`.
        if (i == 0) {
            try testing.expect(resp.schema != null);
        } else {
            try testing.expect(resp.schema == null);
        }
    }
    try testing.expectEqual(@as(i64, 4), total);
}

// ---- ARROW ----

const arrow_table = "projects/test/datasets/ds1/tables/t";

/// The first four bytes of an encapsulated Arrow IPC message. Everything below
/// checks for it because a schema or a batch that is not encapsulated is one a
/// client rejects outright, and the proto's bytes field would carry it happily.
const ipc_marker = [_]u8{ 0xff, 0xff, 0xff, 0xff };

/// The session every test below opens, named so the request literal does not
/// have to be repeated at four call sites.
const arrow_session: Request = .{ .table = arrow_table, .max_streams = 1, .format = .ARROW };

test "an ARROW session comes back with an Arrow schema, in the Arrow oneof" {
    // `data_format` must be consulted consistently by `encodeSession`,
    // `readRows` and `encodeRowsResponse`: an ARROW session's schema and its
    // rows both belong in the Arrow oneof. google-cloud-bigquery asks for
    // ARROW unconditionally on its to_dataframe path, which makes this the
    // common case.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const bytes = try svc.createReadSession(
        arena,
        try encodeRequestFormat(arena, arrow_session),
    );
    const out = try pb.ReadSession.decode(arena, bytes);

    try testing.expectEqual(pb.DataFormat.ARROW, out.data_format.?);
    const schema = out.schema.?.arrow_schema.serialized_schema.?;
    try testing.expectEqualSlices(u8, &ipc_marker, schema[0..4]);
    try testing.expectEqual(@as(usize, 0), schema.len % 8);
}

test "ARROW rows arrive as record batches, and the format is not mixed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"INSERT INTO ds1.t (id, name) VALUES (1, 'a'), (2, NULL)"}
        ,
    });

    const sess = try pb.ReadSession.decode(arena, try svc.createReadSession(
        arena,
        try encodeRequestFormat(arena, arrow_session),
    ));
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, sess.streams[0].name.?, null));
    try testing.expectEqual(@as(usize, 1), msgs.len);

    const resp = try pb.ReadRowsResponse.decode(arena, msgs[0]);
    try testing.expectEqual(@as(?i64, 2), resp.row_count);
    const batch = resp.rows.?.arrow_record_batch;
    try testing.expectEqual(@as(?i64, 2), batch.row_count);
    try testing.expectEqualSlices(u8, &ipc_marker, batch.serialized_record_batch.?[0..4]);

    // The schema rides on the first message, in the Arrow branch, with no Avro
    // oneof set anywhere in an ARROW session's responses.
    const schema = resp.schema.?.arrow_schema.serialized_schema.?;
    try testing.expectEqualSlices(u8, &ipc_marker, schema[0..4]);
    // The oneofs are tagged unions, so asking for the wrong branch is a panic
    // rather than an assertion -- the tag itself is what is checked.
    try testing.expect(resp.rows.? == .arrow_record_batch);
    try testing.expect(resp.schema.? == .arrow_schema);
}

test "an empty ARROW read still sends a batch a reader can parse" {
    // Avro can answer no rows with no bytes -- `serialized_binary_rows` is
    // datums end to end. Arrow cannot: an empty batch is still a header, a
    // flatbuffer and a set of buffer offsets, and a client handed "" fails to
    // parse it rather than reading zero rows.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const sess = try pb.ReadSession.decode(arena, try svc.createReadSession(
        arena,
        try encodeRequestFormat(arena, arrow_session),
    ));
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, sess.streams[0].name.?, null));

    try testing.expectEqual(@as(usize, 1), msgs.len);
    const resp = try pb.ReadRowsResponse.decode(arena, msgs[0]);
    try testing.expectEqual(@as(?i64, 0), resp.row_count);
    const rows = resp.rows.?.arrow_record_batch.serialized_record_batch.?;
    try testing.expect(rows.len > 8);
    try testing.expectEqualSlices(u8, &ipc_marker, rows[0..4]);
    try testing.expect(resp.schema != null);
}

test "a large ARROW read is split across messages, each with its own row_count" {
    // The columnar counterpart of the Avro batching test. It is a different
    // mechanism -- `byteCount` over the builders rather than the length of a
    // byte writer -- and the arithmetic the client does on `row_count` is the
    // same either way.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();
    svc.batch_bytes = 4;

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"INSERT INTO ds1.t (id, name) VALUES (1,'a'),(2,'b'),(3,'c'),(4,'d')"}
        ,
    });

    const sess = try pb.ReadSession.decode(arena, try svc.createReadSession(
        arena,
        try encodeRequestFormat(arena, arrow_session),
    ));
    const msgs = try svc.readRows(arena, try readRowsRequest(arena, sess.streams[0].name.?, null));
    try testing.expect(msgs.len > 1);

    var total: i64 = 0;
    for (msgs, 0..) |m, i| {
        const resp = try pb.ReadRowsResponse.decode(arena, m);
        total += resp.row_count.?;
        const batch = resp.rows.?.arrow_record_batch;
        try testing.expectEqual(resp.row_count, batch.row_count);
        // Every message is a standalone encapsulated batch, not a continuation
        // of the one before -- the proto carries no stream framing.
        try testing.expectEqualSlices(u8, &ipc_marker, batch.serialized_record_batch.?[0..4]);
        if (i == 0) {
            try testing.expect(resp.schema != null);
        } else {
            try testing.expect(resp.schema == null);
        }
    }
    try testing.expectEqual(@as(i64, 4), total);
}

test "a table made by DDL is readable, and keeps its NOT NULL columns" {
    // A table created by `CREATE TABLE` lives in the engine's catalog and not in
    // the metadata store, so `CreateReadSession` has to fall back to it the way
    // `tables.get` does. The schema derived from that catalog must keep
    // `NOT NULL`, in both formats, since they share one nullability source.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    _ = try restRequest(app, arena, .{
        .method = .POST,
        .path = "/projects/test/queries",
        .body =
        \\{"query":"CREATE TABLE `test.ds1.ddl_t` (a INT64 NOT NULL, b STRING)"}
        ,
    });

    const out = try pb.ReadSession.decode(arena, try svc.createReadSession(
        arena,
        try encodeRequest(arena, "projects/test/datasets/ds1/tables/ddl_t", 1, null),
    ));
    const schema = out.schema.?.avro_schema.schema.?;
    try testing.expect(std.mem.indexOf(u8, schema, "{\"name\":\"a\",\"type\":\"long\"}") != null);
    try testing.expect(
        std.mem.indexOf(u8, schema, "{\"name\":\"b\",\"type\":[\"null\",\"string\"]}") != null,
    );
}

test "an unspecified data_format is served as Avro, not as nothing" {
    // UNSPECIFIED is what an unset `data_format` decodes to, so `encodeSession`
    // must treat it the same as `.AVRO` rather than leaving the schema oneof
    // unset.
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const app = try newServerWithTable(arena);
    defer app.deinit();
    var svc = Service.init(app);
    defer svc.deinit();

    const out = try pb.ReadSession.decode(arena, try svc.createReadSession(
        arena,
        try encodeRequestFormat(arena, .{
            .table = arrow_table,
            .max_streams = 1,
            .format = .DATA_FORMAT_UNSPECIFIED,
        }),
    ));
    try testing.expectEqual(pb.DataFormat.AVRO, out.data_format.?);
    try testing.expect(out.schema.? == .avro_schema);
}
