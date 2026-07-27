//! One catalog shared by several connections, with the lock that makes it
//! safe to touch.
//!
//! bigquery-emulator serves every request through one engine connection
//! because the catalog cannot be shared: each `Db` owning its own meant
//! cross-connection visibility had to come from re-reading SQLite, which is
//! both slow and — with a wall-clock cursor — lossy. Measured on the view
//! graph, 98% of request latency was queueing behind that one connection.
//!
//! The fix is to share the catalog rather than to synchronise copies of it.
//! Catalog operations are in-memory and fast; the expensive part of a
//! statement is the GoogleSQL analyze, which stays outside the lock and
//! therefore stays parallel. Each connection keeps its own analyzer catalog
//! handle and replays the shared change log at its own `Cursor`.
const std = @import("std");
const catalog_mod = @import("catalog.zig");

pub const SharedCatalog = struct {
    gpa: std.mem.Allocator,
    /// `std.Io.Mutex` needs an `Io` to lock and unlock, and the engine has no
    /// source of one — so it is supplied here, by whoever builds the pool.
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    catalog: *catalog_mod.Catalog,
    /// Whether anything already persisted has been read in. The first
    /// connection to attach does it, under the mutex, so callers do not have
    /// to sequence a bootstrap connection ahead of the pool.
    loaded: bool = false,

    pub fn init(gpa: std.mem.Allocator, io: std.Io) error{OutOfMemory}!*SharedCatalog {
        const sc = try gpa.create(SharedCatalog);
        errdefer gpa.destroy(sc);
        sc.* = .{ .gpa = gpa, .io = io, .catalog = try catalog_mod.Catalog.init(gpa) };
        return sc;
    }

    pub fn deinit(sc: *SharedCatalog) void {
        sc.catalog.deinit();
        sc.gpa.destroy(sc);
    }
};

/// Exclusive access to a catalog, held for as long as the token is.
///
/// The `*Catalog` is reachable only through a `Guard`, so "did this call site
/// take the lock?" is answered by whether it could name the catalog at all
/// rather than by reading every path. A guard over an unshared catalog holds
/// no lock and unlocking it is a no-op, which is what keeps single-connection
/// use — every unit test, the corpus runner, the CLI — free of locking.
///
/// Invariant: never acquire this while a SQLite transaction is open on the
/// connection. Catalog writes do SQLite I/O inside the guard, so the reverse
/// order on another connection would deadlock. Nothing does today (BEGIN and
/// COMMIT are analyzer no-ops, so every catalog write runs in autocommit).
pub const Guard = struct {
    catalog: *catalog_mod.Catalog,
    shared: ?*SharedCatalog = null,

    pub fn unlock(g: Guard) void {
        if (g.shared) |sc| sc.mutex.unlock(sc.io);
    }
};

/// Takes the lock and hands back the catalog it protects.
pub fn lockShared(sc: *SharedCatalog) Guard {
    sc.mutex.lockUncancelable(sc.io);
    return .{ .catalog = sc.catalog, .shared = sc };
}
