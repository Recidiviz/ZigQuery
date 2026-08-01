//! Does SQLite touch the disk, and with what?
//!
//! The emulator's database is memdb — an in-memory VFS — but that only
//! settles where the *main* database lives. Temp b-trees (materialized
//! subqueries, CTEs, `DISTINCT` and transient indexes), sorter spill files and
//! statement journals are opened as separate files through the connection's
//! VFS, and whether those reach a disk depends on a VFS the connection never
//! names in its DSN.
//!
//! This module answers it with numbers rather than with a reading of memdb.c:
//! it registers a VFS that wraps another one, forwards every call, and counts
//! opens/reads/writes/syncs by what SQLite said the file was for.
//! `SQLITE_OPEN_TEMP_DB`, `TRANSIENT_DB`, `TEMP_JOURNAL` and `SUBJOURNAL` are
//! the classes that answer the question; `MAIN_DB` is reported alongside them
//! so the memory path stays visible as a control.
//!
//! Measured answer, on this build (SQLite 3.53.3): memdb serves *every* class
//! from memory, not only `MAIN_DB` — a 1M-row `DISTINCT` moved 1.7 GiB through
//! `transientDb` at roughly 10 GB/s with no descriptor open, while the same
//! query over the OS VFS opened one unlinked file on a real device. So an
//! in-memory emulator writes no temp files, and the traffic it does generate
//! is a pager round trip rather than an I/O one. `harness/io_probe.zig` is
//! that experiment, including the OS-VFS control.
//!
//! And over the Staging view-graph test (54.9k requests): zero temp opens of
//! any class, but 29.1 M `MAIN_DB` reads moving 110 GiB against a 350 MiB
//! database — page-cache misses, not I/O, and 8.9 s of the 58.8 s of handle
//! time. What "SQLite is writing to disk" turned out to mean here was
//! `cache_size`; see the table in server/storage.zig.
//!
//! Counting is not proof of a *disk* file, since a wrapped VFS could still be
//! serving the bytes from memory. So the first temp-class write also walks the
//! process's own file descriptors and records any regular file with no
//! remaining links — which is exactly the shape of a SQLite temp file, created
//! and immediately unlinked (os_unix.c, `SQLITE_OPEN_DELETEONCLOSE`).
//!
//! Off unless `ZQL_IO_STATS` is set, because the timing calls around every
//! read and write would otherwise land in the measurements they exist to make
//! trustworthy.

const std = @import("std");
const sqlite = @import("../sqlite.zig");
const phase = @import("phase.zig");
const c = sqlite.c;

/// What SQLite opened the file for. The distinction is the whole point: a
/// `main_db` write on this server is a memcpy into memdb, while every other
/// class is a file the OS has to back.
pub const Kind = enum(u8) {
    main_db,
    /// The TEMP schema's b-tree: `CREATE TEMP TABLE`, and the ephemeral tables
    /// SQLite opens for materialized subqueries and CTEs. Honours
    /// `PRAGMA temp_store`.
    temp_db,
    /// Ephemeral b-trees with no schema: transient indexes, `DISTINCT`,
    /// `IN (...)` lookaside tables. Also honours `PRAGMA temp_store`.
    transient_db,
    main_journal,
    /// Rollback journal for a temp b-tree, *and* the sorter's spill files:
    /// vdbesort.c opens its PMA files with this flag, and stops creating them
    /// entirely when temp storage is in memory.
    temp_journal,
    /// Statement journal: the per-statement rollback record.
    subjournal,
    super_journal,
    wal,
    other,

    pub fn label(k: Kind) []const u8 {
        return switch (k) {
            .main_db => "mainDb",
            .temp_db => "tempDb",
            .transient_db => "transientDb",
            .main_journal => "mainJournal",
            .temp_journal => "tempJournal",
            .subjournal => "subJournal",
            .super_journal => "superJournal",
            .wal => "wal",
            .other => "other",
        };
    }

    /// True for the classes that are *not* the main database — the ones whose
    /// bytes are the answer to "is SQLite writing temporary files".
    pub fn isTemp(k: Kind) bool {
        return switch (k) {
            .temp_db, .transient_db, .temp_journal, .subjournal => true,
            else => false,
        };
    }
};

const n_kinds = @typeInfo(Kind).@"enum".fields.len;

const Atomic = std.atomic.Value(u64);

const Counters = struct {
    opens: Atomic = .init(0),
    closes: Atomic = .init(0),
    reads: Atomic = .init(0),
    read_bytes: Atomic = .init(0),
    read_ns: Atomic = .init(0),
    writes: Atomic = .init(0),
    write_bytes: Atomic = .init(0),
    write_ns: Atomic = .init(0),
    syncs: Atomic = .init(0),
    sync_ns: Atomic = .init(0),
    truncates: Atomic = .init(0),
    /// Highest byte offset written, over every file of this class. A file's
    /// size is not otherwise observable from here, and "how big did the
    /// biggest spill get" is what decides whether a cache-size change could
    /// have avoided it.
    max_offset: Atomic = .init(0),
};

var counters: [n_kinds]Counters = @splat(.{});

/// One class's totals, read out of the atomics.
pub const KindStats = struct {
    kind: Kind,
    opens: u64,
    closes: u64,
    reads: u64,
    read_bytes: u64,
    read_ms: f64,
    writes: u64,
    write_bytes: u64,
    write_ms: f64,
    syncs: u64,
    sync_ms: f64,
    truncates: u64,
    max_offset: u64,

    pub fn touched(s: KindStats) bool {
        return s.opens != 0 or s.reads != 0 or s.writes != 0;
    }
};

pub fn kindStats(k: Kind) KindStats {
    const cs = &counters[@intFromEnum(k)];
    return .{
        .kind = k,
        .opens = cs.opens.load(.monotonic),
        .closes = cs.closes.load(.monotonic),
        .reads = cs.reads.load(.monotonic),
        .read_bytes = cs.read_bytes.load(.monotonic),
        .read_ms = @as(f64, @floatFromInt(cs.read_ns.load(.monotonic))) / 1e6,
        .writes = cs.writes.load(.monotonic),
        .write_bytes = cs.write_bytes.load(.monotonic),
        .write_ms = @as(f64, @floatFromInt(cs.write_ns.load(.monotonic))) / 1e6,
        .syncs = cs.syncs.load(.monotonic),
        .sync_ms = @as(f64, @floatFromInt(cs.sync_ns.load(.monotonic))) / 1e6,
        .truncates = cs.truncates.load(.monotonic),
        .max_offset = cs.max_offset.load(.monotonic),
    };
}

/// Totals over every class that is not the main database.
pub fn tempTotals() KindStats {
    var t: KindStats = .{
        .kind = .other,
        .opens = 0,
        .closes = 0,
        .reads = 0,
        .read_bytes = 0,
        .read_ms = 0,
        .writes = 0,
        .write_bytes = 0,
        .write_ms = 0,
        .syncs = 0,
        .sync_ms = 0,
        .truncates = 0,
        .max_offset = 0,
    };
    for (std.enums.values(Kind)) |k| {
        if (!k.isTemp()) continue;
        const s = kindStats(k);
        t.opens += s.opens;
        t.closes += s.closes;
        t.reads += s.reads;
        t.read_bytes += s.read_bytes;
        t.read_ms += s.read_ms;
        t.writes += s.writes;
        t.write_bytes += s.write_bytes;
        t.write_ms += s.write_ms;
        t.syncs += s.syncs;
        t.sync_ms += s.sync_ms;
        t.truncates += s.truncates;
        t.max_offset = @max(t.max_offset, s.max_offset);
    }
    return t;
}

pub fn reset() void {
    for (&counters) |*cs| {
        inline for (@typeInfo(Counters).@"struct".fields) |f| {
            @field(cs, f.name).store(0, .monotonic);
        }
    }
}

// --- the descriptor probe -----------------------------------------------
//
// Evidence that a counted temp file is a *file*. SQLite's unix VFS creates a
// temp file and unlinks it immediately, so it never appears in a directory
// listing; what it leaves behind is an open descriptor on a regular file with
// st_nlink == 0. Run once, on the first temp-class write, because that is the
// moment such a file is guaranteed to exist.

/// Result of the one-shot descriptor walk.
pub const Probe = struct {
    ran: bool = false,
    /// Open regular files with no directory entry left: SQLite temp files.
    unlinked_files: u32 = 0,
    /// Bytes in the largest of them, at probe time.
    largest_bytes: u64 = 0,
    /// st_dev of one of them, so "which volume" is answerable.
    device: u64 = 0,
};

var probe: Probe = .{};
var probe_done: std.atomic.Value(bool) = .init(false);

pub fn probeResult() Probe {
    return probe;
}

fn runProbe() void {
    // Only the first caller probes; the flag is set before the walk so a
    // second thread mid-write does not queue up behind it.
    if (probe_done.swap(true, .acq_rel)) return;
    var p: Probe = .{ .ran = true };
    var fd: std.c.fd_t = 0;
    while (fd < 1024) : (fd += 1) {
        var st: std.c.Stat = undefined;
        if (std.c.fstat(fd, &st) != 0) continue;
        if (!std.c.S.ISREG(st.mode)) continue;
        if (st.nlink != 0) continue;
        p.unlinked_files += 1;
        const size: u64 = @intCast(st.size);
        if (size >= p.largest_bytes) {
            p.largest_bytes = size;
            p.device = @intCast(st.dev);
        }
    }
    probe = p;
}

// --- the wrapper VFS ---------------------------------------------------

pub const vfs_name = "iostat";

var shim: c.sqlite3_vfs = undefined;
var base: [*c]c.sqlite3_vfs = null;
var installed = false;

/// Reads `ZQL_IO_STATS`. Instrumentation is opt-in so that an ordinary run
/// measures the engine and not the measuring.
pub fn requested() bool {
    const v = env("ZQL_IO_STATS") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// Zig 0.16 dropped `std.posix.getenv`, and the engine has no `std.Io` to
/// reach an environment map through — the same reason phase.zig reads the
/// clock from libc.
fn env(name: [*:0]const u8) ?[]const u8 {
    return std.mem.span(std.c.getenv(name) orelse return null);
}

pub fn isInstalled() bool {
    return installed;
}

/// Reads `ZQL_MEM_STATS`: whether to leave SQLITE_CONFIG_MEMSTATUS on.
///
/// Off by default because the accounting is not free — every sqlite3_malloc
/// and free calls malloc_size() and takes the STATIC_MEM mutex, which sampling
/// put at 11% of a bulk insert's time in sqlite3_step's caller. Set it to read
/// the `memoryUsedBytes` / `mallocsOutstanding` / `largestAllocBytes` fields of
/// /debug/stats, which report zero otherwise. The lookaside, cache, schema and
/// stmt counters come from sqlite3_db_status and are unaffected either way.
pub fn memStatsRequested() bool {
    const v = env("ZQL_MEM_STATS") orelse return false;
    return v.len > 0 and !std.mem.eql(u8, v, "0");
}

/// `PRAGMA temp_store` for this process, from `ZQL_TEMP_STORE`
/// (`default` | `file` | `memory`), or null to leave SQLite's default alone.
///
/// The pragma's MEMORY value is **2**, not 3. `SQLITE_TEMP_STORE=3` is the
/// compile-time define that forces memory and disables the pragma; the pragma
/// parser reads a leading digit only in the range 0..2 and maps anything else
/// — including `3` — to 0, i.e. DEFAULT. So `PRAGMA temp_store = 3` is a
/// silent no-op, which is exactly the failure mode this helper exists to
/// avoid.
///
/// What it moves: temp b-trees (`TEMP_DB`, `TRANSIENT_DB` — materializations,
/// transient indexes, DISTINCT) stop being pager files and become page-cache
/// memory, and the sorter stops writing PMA spill files at all — vdbesort.c
/// checks the same `sqlite3TempInMemory` flag before deciding to spill. On an
/// in-memory database that is not a disk saving, since memdb was absorbing
/// those writes anyway; it is the removal of the pager and VFS round trip
/// underneath them.
pub fn tempStorePragma() ?[:0]const u8 {
    const v = env("ZQL_TEMP_STORE") orelse return null;
    if (std.ascii.eqlIgnoreCase(v, "memory") or std.mem.eql(u8, v, "2")) {
        return "PRAGMA temp_store = MEMORY";
    }
    if (std.ascii.eqlIgnoreCase(v, "file") or std.mem.eql(u8, v, "1")) {
        return "PRAGMA temp_store = FILE";
    }
    return null;
}

/// `PRAGMA cache_size` override, from `ZQL_CACHE_SIZE`, in SQLite's own units:
/// negative is KiB of memory, positive is a page count.
///
/// The knob the temp-file question turned out to actually be about. On an
/// in-memory database every page-cache miss is still a full VFS round trip
/// into memdb — 118 GiB of them over a view-graph run against a 350 MiB
/// database — so the cache size decides how much of that traffic exists at
/// all, in a place where "it is all in RAM anyway" suggests it cannot matter.
pub fn cacheSizePragma() ?[:0]const u8 {
    const v = env("ZQL_CACHE_SIZE") orelse return null;
    const n = std.fmt.parseInt(i64, v, 10) catch return null;
    return std.fmt.bufPrintSentinel(&cache_size_buf, "PRAGMA cache_size = {d}", .{n}, 0) catch null;
}

var cache_size_buf: [48]u8 = undefined;

/// Registers `iostat` in front of `base_name` (null = the current default
/// VFS). Callers reach it by naming it: `?vfs=iostat` in a URI DSN, since
/// registering it as the default would not intercept a connection that names
/// memdb explicitly.
pub fn install(base_name: ?[:0]const u8) !void {
    if (installed) return;
    base = c.sqlite3_vfs_find(if (base_name) |b| b.ptr else null);
    if (base == null) return error.NoSuchVfs;

    shim = .{
        .iVersion = base.*.iVersion,
        // Our header, then the wrapped VFS's file immediately after it.
        .szOsFile = @as(c_int, @intCast(@sizeOf(ShimFile))) + base.*.szOsFile,
        .mxPathname = base.*.mxPathname,
        .pNext = null,
        .zName = vfs_name,
        .pAppData = base,
        .xOpen = xOpen,
        // A method the wrapped VFS leaves null stays null here: memdb has no
        // xDelete, and forwarding into a null pointer would crash rather than
        // return the error SQLite expects.
        .xDelete = if (base.*.xDelete != null) xDelete else null,
        .xAccess = if (base.*.xAccess != null) xAccess else null,
        .xFullPathname = if (base.*.xFullPathname != null) xFullPathname else null,
        .xDlOpen = if (base.*.xDlOpen != null) xDlOpen else null,
        .xDlError = if (base.*.xDlError != null) xDlError else null,
        .xDlSym = if (base.*.xDlSym != null) xDlSym else null,
        .xDlClose = if (base.*.xDlClose != null) xDlClose else null,
        .xRandomness = if (base.*.xRandomness != null) xRandomness else null,
        .xSleep = if (base.*.xSleep != null) xSleep else null,
        .xCurrentTime = if (base.*.xCurrentTime != null) xCurrentTime else null,
        .xGetLastError = if (base.*.xGetLastError != null) xGetLastError else null,
        .xCurrentTimeInt64 = if (base.*.xCurrentTimeInt64 != null) xCurrentTimeInt64 else null,
        // System-call hooks are a test surface; nothing here uses them, and
        // forwarding them would mean answering for the wrapped VFS's names.
        .xSetSystemCall = null,
        .xGetSystemCall = null,
        .xNextSystemCall = null,
    };
    if (c.sqlite3_vfs_register(&shim, 0) != c.SQLITE_OK) return error.RegisterFailed;
    installed = true;
}

const ShimFile = extern struct {
    base: c.sqlite3_file,
    real: [*c]c.sqlite3_file,
    kind: u32,
    pad: u32 = 0,
};

fn classify(flags: c_int) Kind {
    if (flags & c.SQLITE_OPEN_MAIN_DB != 0) return .main_db;
    if (flags & c.SQLITE_OPEN_TEMP_DB != 0) return .temp_db;
    if (flags & c.SQLITE_OPEN_TRANSIENT_DB != 0) return .transient_db;
    if (flags & c.SQLITE_OPEN_MAIN_JOURNAL != 0) return .main_journal;
    if (flags & c.SQLITE_OPEN_TEMP_JOURNAL != 0) return .temp_journal;
    if (flags & c.SQLITE_OPEN_SUBJOURNAL != 0) return .subjournal;
    if (flags & c.SQLITE_OPEN_SUPER_JOURNAL != 0) return .super_journal;
    if (flags & c.SQLITE_OPEN_WAL != 0) return .wal;
    return .other;
}

fn subFile(f: [*c]c.sqlite3_file) [*c]c.sqlite3_file {
    return @ptrFromInt(@intFromPtr(f) + @sizeOf(ShimFile));
}

fn self(f: [*c]c.sqlite3_file) *ShimFile {
    return @ptrCast(@alignCast(f));
}

fn xOpen(
    vfs: [*c]c.sqlite3_vfs,
    name: [*c]const u8,
    file: [*c]c.sqlite3_file,
    flags: c_int,
    out_flags: [*c]c_int,
) callconv(.c) c_int {
    _ = vfs;
    const s = self(file);
    const sub = subFile(file);
    const rc = base.*.xOpen.?(base, name, sub, flags, out_flags);
    if (rc != c.SQLITE_OK) {
        // SQLite tests pMethods to decide whether a failed open left anything
        // to close.
        s.base.pMethods = null;
        return rc;
    }
    const kind = classify(flags);
    s.real = sub;
    s.kind = @intFromEnum(kind);
    // Advertise exactly the interface version the wrapped file implements:
    // claiming more would let SQLite call a shm or mmap method the file below
    // does not have.
    const version = sub.*.pMethods.*.iVersion;
    s.base.pMethods = switch (version) {
        1 => &methods_v1,
        2 => &methods_v2,
        else => &methods_v3,
    };
    _ = counters[@intFromEnum(kind)].opens.fetchAdd(1, .monotonic);
    return c.SQLITE_OK;
}

fn xDelete(vfs: [*c]c.sqlite3_vfs, name: [*c]const u8, sync_dir: c_int) callconv(.c) c_int {
    _ = vfs;
    return base.*.xDelete.?(base, name, sync_dir);
}

fn xAccess(vfs: [*c]c.sqlite3_vfs, name: [*c]const u8, flags: c_int, res: [*c]c_int) callconv(.c) c_int {
    _ = vfs;
    return base.*.xAccess.?(base, name, flags, res);
}

fn xFullPathname(vfs: [*c]c.sqlite3_vfs, name: [*c]const u8, n: c_int, out: [*c]u8) callconv(.c) c_int {
    _ = vfs;
    return base.*.xFullPathname.?(base, name, n, out);
}

fn xDlOpen(vfs: [*c]c.sqlite3_vfs, name: [*c]const u8) callconv(.c) ?*anyopaque {
    _ = vfs;
    return base.*.xDlOpen.?(base, name);
}

fn xDlError(vfs: [*c]c.sqlite3_vfs, n: c_int, msg: [*c]u8) callconv(.c) void {
    _ = vfs;
    base.*.xDlError.?(base, n, msg);
}

fn xDlSym(
    vfs: [*c]c.sqlite3_vfs,
    handle: ?*anyopaque,
    sym: [*c]const u8,
) callconv(.c) ?*const fn () callconv(.c) void {
    _ = vfs;
    return base.*.xDlSym.?(base, handle, sym);
}

fn xDlClose(vfs: [*c]c.sqlite3_vfs, handle: ?*anyopaque) callconv(.c) void {
    _ = vfs;
    base.*.xDlClose.?(base, handle);
}

fn xRandomness(vfs: [*c]c.sqlite3_vfs, n: c_int, out: [*c]u8) callconv(.c) c_int {
    _ = vfs;
    return base.*.xRandomness.?(base, n, out);
}

fn xSleep(vfs: [*c]c.sqlite3_vfs, micros: c_int) callconv(.c) c_int {
    _ = vfs;
    return base.*.xSleep.?(base, micros);
}

fn xCurrentTime(vfs: [*c]c.sqlite3_vfs, out: [*c]f64) callconv(.c) c_int {
    _ = vfs;
    return base.*.xCurrentTime.?(base, out);
}

fn xGetLastError(vfs: [*c]c.sqlite3_vfs, n: c_int, out: [*c]u8) callconv(.c) c_int {
    _ = vfs;
    return base.*.xGetLastError.?(base, n, out);
}

fn xCurrentTimeInt64(vfs: [*c]c.sqlite3_vfs, out: [*c]c.sqlite3_int64) callconv(.c) c_int {
    _ = vfs;
    return base.*.xCurrentTimeInt64.?(base, out);
}

// --- the wrapper file --------------------------------------------------

fn fClose(f: [*c]c.sqlite3_file) callconv(.c) c_int {
    const s = self(f);
    _ = counters[s.kind].closes.fetchAdd(1, .monotonic);
    const rc = s.real.*.pMethods.*.xClose.?(s.real);
    s.base.pMethods = null;
    return rc;
}

fn fRead(f: [*c]c.sqlite3_file, buf: ?*anyopaque, amt: c_int, ofst: c.sqlite3_int64) callconv(.c) c_int {
    const s = self(f);
    const t0 = phase.nowNs();
    const rc = s.real.*.pMethods.*.xRead.?(s.real, buf, amt, ofst);
    const cs = &counters[s.kind];
    _ = cs.reads.fetchAdd(1, .monotonic);
    _ = cs.read_bytes.fetchAdd(@intCast(amt), .monotonic);
    _ = cs.read_ns.fetchAdd(elapsed(t0), .monotonic);
    return rc;
}

fn fWrite(f: [*c]c.sqlite3_file, buf: ?*const anyopaque, amt: c_int, ofst: c.sqlite3_int64) callconv(.c) c_int {
    const s = self(f);
    const t0 = phase.nowNs();
    const rc = s.real.*.pMethods.*.xWrite.?(s.real, buf, amt, ofst);
    const cs = &counters[s.kind];
    _ = cs.writes.fetchAdd(1, .monotonic);
    _ = cs.write_bytes.fetchAdd(@intCast(amt), .monotonic);
    _ = cs.write_ns.fetchAdd(elapsed(t0), .monotonic);
    const end: u64 = @intCast(ofst + amt);
    _ = cs.max_offset.fetchMax(end, .monotonic);
    const kind: Kind = @enumFromInt(s.kind);
    if (kind.isTemp()) runProbe();
    return rc;
}

fn fTruncate(f: [*c]c.sqlite3_file, size: c.sqlite3_int64) callconv(.c) c_int {
    const s = self(f);
    _ = counters[s.kind].truncates.fetchAdd(1, .monotonic);
    return s.real.*.pMethods.*.xTruncate.?(s.real, size);
}

fn fSync(f: [*c]c.sqlite3_file, flags: c_int) callconv(.c) c_int {
    const s = self(f);
    const t0 = phase.nowNs();
    const rc = s.real.*.pMethods.*.xSync.?(s.real, flags);
    const cs = &counters[s.kind];
    _ = cs.syncs.fetchAdd(1, .monotonic);
    _ = cs.sync_ns.fetchAdd(elapsed(t0), .monotonic);
    return rc;
}

fn fFileSize(f: [*c]c.sqlite3_file, size: [*c]c.sqlite3_int64) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xFileSize.?(s.real, size);
}

fn fLock(f: [*c]c.sqlite3_file, level: c_int) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xLock.?(s.real, level);
}

fn fUnlock(f: [*c]c.sqlite3_file, level: c_int) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xUnlock.?(s.real, level);
}

fn fCheckReservedLock(f: [*c]c.sqlite3_file, res: [*c]c_int) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xCheckReservedLock.?(s.real, res);
}

fn fFileControl(f: [*c]c.sqlite3_file, op: c_int, arg: ?*anyopaque) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xFileControl.?(s.real, op, arg);
}

fn fSectorSize(f: [*c]c.sqlite3_file) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xSectorSize.?(s.real);
}

fn fDeviceCharacteristics(f: [*c]c.sqlite3_file) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xDeviceCharacteristics.?(s.real);
}

fn fShmMap(
    f: [*c]c.sqlite3_file,
    page: c_int,
    page_size: c_int,
    extend: c_int,
    out: [*c]?*volatile anyopaque,
) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xShmMap.?(s.real, page, page_size, extend, out);
}

fn fShmLock(f: [*c]c.sqlite3_file, offset: c_int, n: c_int, flags: c_int) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xShmLock.?(s.real, offset, n, flags);
}

fn fShmBarrier(f: [*c]c.sqlite3_file) callconv(.c) void {
    const s = self(f);
    s.real.*.pMethods.*.xShmBarrier.?(s.real);
}

fn fShmUnmap(f: [*c]c.sqlite3_file, delete_flag: c_int) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xShmUnmap.?(s.real, delete_flag);
}

fn fFetch(f: [*c]c.sqlite3_file, ofst: c.sqlite3_int64, amt: c_int, out: [*c]?*anyopaque) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xFetch.?(s.real, ofst, amt, out);
}

fn fUnfetch(f: [*c]c.sqlite3_file, ofst: c.sqlite3_int64, p: ?*anyopaque) callconv(.c) c_int {
    const s = self(f);
    return s.real.*.pMethods.*.xUnfetch.?(s.real, ofst, p);
}

fn elapsed(t0: u64) u64 {
    const now = phase.nowNs();
    return if (now > t0) now - t0 else 0;
}

fn methodsFor(version: c_int) c.sqlite3_io_methods {
    return .{
        .iVersion = version,
        .xClose = fClose,
        .xRead = fRead,
        .xWrite = fWrite,
        .xTruncate = fTruncate,
        .xSync = fSync,
        .xFileSize = fFileSize,
        .xLock = fLock,
        .xUnlock = fUnlock,
        .xCheckReservedLock = fCheckReservedLock,
        .xFileControl = fFileControl,
        .xSectorSize = fSectorSize,
        .xDeviceCharacteristics = fDeviceCharacteristics,
        .xShmMap = if (version >= 2) fShmMap else null,
        .xShmLock = if (version >= 2) fShmLock else null,
        .xShmBarrier = if (version >= 2) fShmBarrier else null,
        .xShmUnmap = if (version >= 2) fShmUnmap else null,
        .xFetch = if (version >= 3) fFetch else null,
        .xUnfetch = if (version >= 3) fUnfetch else null,
    };
}

const methods_v1: c.sqlite3_io_methods = methodsFor(1);
const methods_v2: c.sqlite3_io_methods = methodsFor(2);
const methods_v3: c.sqlite3_io_methods = methodsFor(3);

// --- reporting ---------------------------------------------------------

/// One line per class that saw any traffic, plus the descriptor probe.
pub fn writeText(w: anytype) !void {
    if (!installed) {
        try w.writeAll("io stats:     not installed (set ZQL_IO_STATS=1)\n");
        return;
    }
    try w.print("{s:>13} {s:>7} {s:>9} {s:>12} {s:>9} {s:>9} {s:>12} {s:>9}\n", .{
        "class", "opens", "writes", "write KiB", "write ms", "reads", "read KiB", "read ms",
    });
    for (std.enums.values(Kind)) |k| {
        const s = kindStats(k);
        if (!s.touched()) continue;
        try w.print("{s:>13} {d:>7} {d:>9} {d:>12.1} {d:>9.1} {d:>9} {d:>12.1} {d:>9.1}\n", .{
            k.label(),
            s.opens,
            s.writes,
            @as(f64, @floatFromInt(s.write_bytes)) / 1024.0,
            s.write_ms,
            s.reads,
            @as(f64, @floatFromInt(s.read_bytes)) / 1024.0,
            s.read_ms,
        });
    }
    const t = tempTotals();
    try w.print(
        "temp files:   {d} opened, {d:.1} MiB written in {d} writes ({d:.1} ms), " ++
            "largest reached {d:.1} MiB\n",
        .{
            t.opens,
            @as(f64, @floatFromInt(t.write_bytes)) / (1024.0 * 1024.0),
            t.writes,
            t.write_ms,
            @as(f64, @floatFromInt(t.max_offset)) / (1024.0 * 1024.0),
        },
    );
    const p = probeResult();
    if (p.ran) {
        try w.print(
            "fd probe:     {d} unlinked regular file(s) open during a temp write, " ++
                "largest {d:.1} MiB, dev {d}\n",
            .{ p.unlinked_files, @as(f64, @floatFromInt(p.largest_bytes)) / (1024.0 * 1024.0), p.device },
        );
    } else {
        try w.writeAll("fd probe:     never ran — nothing wrote to a temp file\n");
    }
}

const testing = std.testing;

test "classify maps every open flag to its class" {
    try testing.expectEqual(Kind.main_db, classify(c.SQLITE_OPEN_MAIN_DB | c.SQLITE_OPEN_READWRITE));
    try testing.expectEqual(Kind.temp_db, classify(c.SQLITE_OPEN_TEMP_DB));
    try testing.expectEqual(Kind.transient_db, classify(c.SQLITE_OPEN_TRANSIENT_DB));
    try testing.expectEqual(Kind.temp_journal, classify(c.SQLITE_OPEN_TEMP_JOURNAL));
    try testing.expectEqual(Kind.subjournal, classify(c.SQLITE_OPEN_SUBJOURNAL));
    try testing.expectEqual(Kind.wal, classify(c.SQLITE_OPEN_WAL));
    try testing.expectEqual(Kind.other, classify(c.SQLITE_OPEN_READONLY));
    // The main database is a class of its own even though the emulator's is
    // in memory: it is the control the temp classes are read against.
    try testing.expect(!Kind.main_db.isTemp());
    try testing.expect(Kind.temp_db.isTemp());
}
