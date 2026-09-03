//! Does a shared catalog actually make a pool coherent?
//!
//! The previous connection-pool attempt failed with 530 errors across 594
//! view creations. The cause was not the pool: each `Db` owned a `Catalog`
//! and relied on re-reading SQLite `WHERE updatedAt >= cursor`, where the
//! cursor was wall-clock time stamped *before* the read — so a commit landing
//! just before another connection's stamp was skipped permanently.
//!
//! This harness runs the same shape deliberately, and pairs it with the
//! control that experiment lacked:
//!
//!   shared:  N connections over one `SharedCatalog`. Every table any
//!            connection creates must resolve from every other connection.
//!            Zero failures required.
//!   control: the identical run with per-connection catalogs. This MUST fail,
//!            because connections that do not share a catalog cannot see each
//!            other's DDL. A control that passes means the harness is not
//!            exercising cross-connection visibility at all, and the shared
//!            result proves nothing.
//!
//! Exit status: nonzero if the shared tier reports any failure, or if the
//! control tier reports none.
//!
//! Usage: zig build shared-catalog-threads -- [tables_per_thread] [threads]
const std = @import("std");
const builtin = @import("builtin");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const shared_catalog = zigquery.shared_catalog;

const Tier = struct {
    /// Reads of a table another connection created that did not resolve.
    invisible: usize,
    /// Creates that failed outright.
    create_errors: usize,
    /// Reads that failed for a reason other than the table being unknown.
    other_errors: usize,
    elapsed_ms: f64,
};

pub fn main(init: std.process.Init) !void {
    const gpa = std.heap.smp_allocator;

    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const per_thread: usize = if (args.next()) |a| try std.fmt.parseInt(usize, a, 10) else 40;
    const threads: usize = if (args.next()) |a|
        try std.fmt.parseInt(usize, a, 10)
    else
        @max(2, @min(8, std.Thread.getCpuCount() catch 4));

    try out.print(
        "shared-catalog-threads: {d} threads x {d} tables ({s})\n",
        .{ threads, per_thread, @tagName(builtin.mode) },
    );

    const shared = try run(gpa, init.io, threads, per_thread, true);
    try out.print(
        "shared:  {d} invisible, {d} create errors, {d} other errors in {d:.1} ms\n",
        .{ shared.invisible, shared.create_errors, shared.other_errors, shared.elapsed_ms },
    );

    const control = try run(gpa, init.io, threads, per_thread, false);
    try out.print(
        "control: {d} invisible, {d} create errors, {d} other errors in {d:.1} ms -- {s}\n",
        .{
            control.invisible,
            control.create_errors,
            control.other_errors,
            control.elapsed_ms,
            if (control.invisible > 0)
                "per-connection catalogs are blind to each other, as expected"
            else
                "NO BLINDNESS OBSERVED -- harness is not testing cross-connection visibility",
        },
    );

    const shared_ok = shared.invisible == 0 and shared.create_errors == 0 and
        shared.other_errors == 0;
    const control_ok = control.invisible > 0;
    try out.print("RESULT: {s}\n", .{if (shared_ok and control_ok) "PASS" else "FAIL"});
    try out.flush();
    if (!(shared_ok and control_ok)) std.process.exit(1);
}

const Worker = struct {
    gpa: std.mem.Allocator,
    dsn: [:0]const u8,
    shared: ?*shared_catalog.SharedCatalog,
    threads: usize,
    per_thread: usize,
    index: usize,
    barrier: *Barrier,

    invisible: usize = 0,
    create_errors: usize = 0,
    other_errors: usize = 0,

    fn run(w: *Worker) void {
        var db = driver.Db.openWith(w.gpa, w.dsn, .{
            .busy_timeout_ms = 30_000,
            .shared_catalog = w.shared,
        }) catch {
            w.create_errors += 1;
            w.barrier.arrive();
            return;
        };
        defer db.close();

        // Phase 1: every connection creates concurrently.
        var j: usize = 0;
        while (j < w.per_thread) : (j += 1) {
            var buf: [128]u8 = undefined;
            const sql = std.fmt.bufPrint(
                &buf,
                "CREATE TABLE `p.d.t{d}_{d}` (a INT64)",
                .{ w.index, j },
            ) catch unreachable;
            db.exec(sql, &.{}, .{}) catch {
                w.create_errors += 1;
            };
        }

        w.barrier.arrive();
        w.barrier.wait();

        // Phase 2: every connection reads every other connection's tables.
        // With a shared catalog all of them resolve; with per-connection
        // catalogs none of the other threads' tables do.
        var t: usize = 0;
        while (t < w.threads) : (t += 1) {
            if (t == w.index) continue;
            j = 0;
            while (j < w.per_thread) : (j += 1) {
                var buf: [128]u8 = undefined;
                const sql = std.fmt.bufPrint(
                    &buf,
                    "SELECT a FROM `p.d.t{d}_{d}`",
                    .{ t, j },
                ) catch unreachable;
                var rows = db.query(sql, &.{}, .{}) catch |err| {
                    if (err == error.AnalyzeFailed) w.invisible += 1 else w.other_errors += 1;
                    continue;
                };
                rows.deinit();
            }
        }
    }
};

/// Counts arrivals and releases everyone once all have arrived. Phase 2 must
/// not start until every create has committed, or a miss would mean "not
/// written yet" rather than "not visible".
const Barrier = struct {
    mutex: std.Io.Mutex = .init,
    cond: std.Io.Condition = .init,
    io: std.Io,
    remaining: usize,

    fn arrive(b: *Barrier) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        b.remaining -= 1;
        if (b.remaining == 0) b.cond.broadcast(b.io);
    }

    fn wait(b: *Barrier) void {
        b.mutex.lockUncancelable(b.io);
        defer b.mutex.unlock(b.io);
        while (b.remaining != 0) b.cond.waitUncancelable(b.io, &b.mutex);
    }
};

var dsn_counter: usize = 0;

fn run(
    gpa: std.mem.Allocator,
    io: std.Io,
    threads: usize,
    per_thread: usize,
    use_shared: bool,
) !Tier {
    // A fresh in-memory database per tier, so the control cannot see rows the
    // shared run left behind.
    dsn_counter += 1;
    var dsn_buf: [64]u8 = undefined;
    const dsn = try std.fmt.bufPrintZ(&dsn_buf, "file:/sc_threads_{d}?vfs=memdb", .{dsn_counter});

    const sc: ?*shared_catalog.SharedCatalog =
        if (use_shared) try shared_catalog.SharedCatalog.init(gpa, io) else null;
    defer if (sc) |s| s.deinit();

    var barrier = Barrier{ .io = io, .remaining = threads };
    const workers = try gpa.alloc(Worker, threads);
    defer gpa.free(workers);
    const handles = try gpa.alloc(std.Thread, threads);
    defer gpa.free(handles);

    const t0 = std.Io.Clock.awake.now(io);
    for (workers, 0..) |*w, i| {
        w.* = .{
            .gpa = gpa,
            .dsn = dsn,
            .shared = sc,
            .threads = threads,
            .per_thread = per_thread,
            .index = i,
            .barrier = &barrier,
        };
        handles[i] = try std.Thread.spawn(.{}, Worker.run, .{w});
    }
    for (handles) |h| h.join();
    const elapsed_ms = @as(f64, @floatFromInt(
        t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds,
    )) / std.time.ns_per_ms;

    var tier = Tier{ .invisible = 0, .create_errors = 0, .other_errors = 0, .elapsed_ms = elapsed_ms };
    for (workers) |w| {
        tier.invisible += w.invisible;
        tier.create_errors += w.create_errors;
        tier.other_errors += w.other_errors;
    }
    return tier;
}
