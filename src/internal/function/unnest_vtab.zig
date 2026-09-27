//! `zigquery_unnest(<encoded array>)`: a table-valued function that iterates
//! an encoded ARRAY in place.
//!
//! It replaces `json_each(zigquery_decode_array(<expr>))`, which round-tripped
//! every element through JSON: `decode_array` decoded the array, re-encoded each
//! element, and pasted the results into a JSON array text that SQLite then
//! re-parsed. That worked only because base64 happens to be JSON-safe — the
//! elements were written into the JSON with no escaping at all — so it was also
//! the reason the value codec could not move off base64.
//!
//! The column shape deliberately matches json_each's `key`/`value`, so the array
//! scan transformer substitutes one for the other without touching how columns
//! are bound (see transformer/scan_array.zig).
//!
//! The array expression is evaluated once per outer row, as a table-valued
//! function argument — the same place json_each took it. That matters: reaching
//! the elements through a scalar function instead would duplicate the expression
//! into the element column and re-evaluate it once per element, which turns
//! `UNNEST(GENERATE_ARRAY(1, n))` into n array constructions.
// ephor:ignore-file ZA303 ZA401

const std = @import("std");
const sqlite = @import("../../sqlite.zig");
const codec = @import("../codec_binary.zig");
const encoder = @import("../encoder.zig");
const value_mod = @import("../value.zig");

const c = sqlite.c;

/// Column indices in the declared schema below. The hidden `arr` column is how
/// SQLite passes the function argument.
const col_key = 0;
const col_value = 1;
const col_arr = 2;

const schema = "CREATE TABLE x(key,value,arr HIDDEN)";

/// Module-wide context, reachable from every callback: xConnect gets it as the
/// module aux pointer and hangs it off the vtab, which the cursor callbacks
/// then reach through their own vtab pointer.
const ModuleCtx = struct {
    gpa: std.mem.Allocator,
};

const Vtab = extern struct {
    base: c.sqlite3_vtab,
    ctx: *ModuleCtx,
};

const Cursor = extern struct {
    base: c.sqlite3_vtab_cursor,
    /// Boxed because SQLite owns the cursor struct; the Zig-side state hangs
    /// off it.
    state: *State,
};

const State = struct {
    gpa: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    /// Buffer each element is re-encoded in, reused for every row of the scan.
    /// The arena beside it is reset per `xFilter`, i.e. per scan, so encoding
    /// there retained one copy of every element until the scan ended.
    scratch: encoder.Scratch,
    /// Element slices, aliasing the decoded buffer in `arena`.
    elems: []const []const u8 = &.{},
    row: usize = 0,
};

/// One `sqlite3_module` per process: comptime-built, never mutated afterwards,
/// and only read by SQLite. `var` rather than `const` because
/// sqlite3_create_module_v2 takes a non-const pointer.
var module: c.sqlite3_module = blk: {
    var m = std.mem.zeroes(c.sqlite3_module);
    m.iVersion = 0;
    m.xConnect = xConnect;
    m.xDisconnect = xDisconnect;
    m.xBestIndex = xBestIndex;
    m.xOpen = xOpen;
    m.xClose = xClose;
    m.xFilter = xFilter;
    m.xNext = xNext;
    m.xEof = xEof;
    m.xColumn = xColumn;
    m.xRowid = xRowid;
    break :blk m;
};

/// `gpa` must outlive the connection. Registered as an eponymous-only module
/// (xCreate null, xConnect set), so it is usable as `FROM zigquery_unnest(x)`
/// with no CREATE VIRTUAL TABLE.
pub fn register(db: *sqlite.Db, gpa: std.mem.Allocator) !void {
    try db.createModule("zigquery_unnest", &module, ModuleCtx{ .gpa = gpa });
}

fn xConnect(
    db: ?*c.sqlite3,
    aux: ?*anyopaque,
    argc: c_int,
    argv: [*c]const [*c]const u8,
    vtab_out: [*c][*c]c.sqlite3_vtab,
    err: [*c][*c]u8,
) callconv(.c) c_int {
    _ = argc;
    _ = argv;
    _ = err;
    if (c.sqlite3_declare_vtab(db, schema) != c.SQLITE_OK) return c.SQLITE_ERROR;
    const ctx: *ModuleCtx = @ptrCast(@alignCast(aux.?));
    const v = ctx.gpa.create(Vtab) catch return c.SQLITE_NOMEM;
    v.* = .{ .base = std.mem.zeroes(c.sqlite3_vtab), .ctx = ctx };
    vtab_out.* = @ptrCast(v);
    return c.SQLITE_OK;
}

fn xDisconnect(vtab_ptr: [*c]c.sqlite3_vtab) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab_ptr));
    v.ctx.gpa.destroy(v);
    return c.SQLITE_OK;
}

/// Requires the hidden `arr` argument. Without it there is no array to scan, so
/// the plan is rejected rather than silently returning nothing.
fn xBestIndex(vtab: [*c]c.sqlite3_vtab, info: [*c]c.sqlite3_index_info) callconv(.c) c_int {
    _ = vtab;
    const n: usize = @intCast(info.*.nConstraint);
    const cons = info.*.aConstraint[0..n];
    const usage = info.*.aConstraintUsage[0..n];
    for (cons, usage) |con, *use| {
        if (con.iColumn == col_arr and con.op == c.SQLITE_INDEX_CONSTRAINT_EQ and con.usable != 0) {
            use.argvIndex = 1;
            use.omit = 1; // the value is consumed here, not re-checked by SQLite
            info.*.estimatedCost = 1.0;
            info.*.estimatedRows = 16;
            return c.SQLITE_OK;
        }
    }
    return c.SQLITE_CONSTRAINT;
}

fn xOpen(vtab_ptr: [*c]c.sqlite3_vtab, cur_out: [*c][*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const v: *Vtab = @ptrCast(@alignCast(vtab_ptr));
    const gpa = v.ctx.gpa;
    const state = gpa.create(State) catch return c.SQLITE_NOMEM;
    state.* = .{
        .gpa = gpa,
        .arena = std.heap.ArenaAllocator.init(gpa),
        .scratch = encoder.Scratch.init(gpa),
    };
    const cur = gpa.create(Cursor) catch {
        state.scratch.deinit();
        state.arena.deinit();
        gpa.destroy(state);
        return c.SQLITE_NOMEM;
    };
    cur.* = .{ .base = std.mem.zeroes(c.sqlite3_vtab_cursor), .state = state };
    cur_out.* = @ptrCast(cur);
    return c.SQLITE_OK;
}

fn xClose(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const gpa = cur.state.gpa;
    cur.state.scratch.deinit();
    cur.state.arena.deinit();
    gpa.destroy(cur.state);
    gpa.destroy(cur);
    return c.SQLITE_OK;
}

/// Decodes the array once per scan and records where each element starts. The
/// elements themselves are left encoded; xColumn decodes only what is read.
fn xFilter(
    cur_ptr: [*c]c.sqlite3_vtab_cursor,
    idx_num: c_int,
    idx_str: [*c]const u8,
    argc: c_int,
    argv: [*c]?*c.sqlite3_value,
) callconv(.c) c_int {
    _ = idx_num;
    _ = idx_str;
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const st = cur.state;
    _ = st.arena.reset(.retain_capacity);
    st.elems = &.{};
    st.row = 0;
    if (argc < 1) return c.SQLITE_OK;

    // A NULL array scans as zero rows, matching what UNNEST(NULL) produced when
    // decode_array returned "[]".
    if (sqlite.valueType(argv[0]) == .null) return c.SQLITE_OK;

    const alloc = st.arena.allocator();
    // An encoded ARRAY is always a BLOB. It used to be able to arrive as
    // base64 TEXT, which is why this branched; anything but a BLOB now means
    // the argument is not an encoded array at all.
    if (sqlite.valueType(argv[0]) != .blob) return c.SQLITE_ERROR;
    const decoded = sqlite.valueBlob(argv[0]);

    var walker = codec.ArrayWalker.init(decoded) catch return c.SQLITE_ERROR;
    var list: std.ArrayList([]const u8) = .empty;
    list.ensureTotalCapacity(alloc, @intCast(walker.count())) catch return c.SQLITE_NOMEM;
    while (walker.next() catch return c.SQLITE_ERROR) |slice| {
        list.appendAssumeCapacity(slice);
    }
    st.elems = list.items;
    return c.SQLITE_OK;
}

fn xNext(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    cur.state.row += 1;
    return c.SQLITE_OK;
}

fn xEof(cur_ptr: [*c]c.sqlite3_vtab_cursor) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    return @intFromBool(cur.state.row >= cur.state.elems.len);
}

fn xRowid(cur_ptr: [*c]c.sqlite3_vtab_cursor, rowid: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    rowid.* = @intCast(cur.state.row);
    return c.SQLITE_OK;
}

/// `value` is re-encoded rather than handed back raw, so an element keeps the
/// same SQLite storage class it had under json_each — INTEGER for an int, REAL
/// for a float, an encoded BLOB for the rest. Downstream generated SQL is typed
/// against that.
///
/// It is a transcode, not a copy: an element arrives in the self-delimiting
/// codec (it was nested in an ARRAY) and leaves in whichever codec its kind
/// uses at the top level.
fn xColumn(
    cur_ptr: [*c]c.sqlite3_vtab_cursor,
    ctx: ?*c.sqlite3_context,
    col: c_int,
) callconv(.c) c_int {
    const cur: *Cursor = @ptrCast(@alignCast(cur_ptr));
    const st = cur.state;
    if (st.row >= st.elems.len) return c.SQLITE_OK;
    switch (col) {
        col_key => sqlite.resultInt64(ctx, @intCast(st.row)),
        col_value => {
            const alloc = st.arena.allocator();
            const v = codec.decodeBinaryValueBorrowing(alloc, st.elems[st.row]) catch
                return c.SQLITE_ERROR;
            encoder.encodeTo(sqlite.ResultSink{ .ctx = ctx }, &st.scratch, v) catch
                return c.SQLITE_ERROR;
        },
        // The hidden argument column is never selected.
        else => sqlite.resultNull(ctx),
    }
    return c.SQLITE_OK;
}
