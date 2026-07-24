//! zetasqlite-zig: GoogleSQL -> SQLite translator, a faithful port of
//! Recidiviz/go-zetasqlite. Only the SQL driver interface is redesigned
//! (sqlite.zig + driver.zig); the internal pipeline mirrors the Go original.

pub const sqlite = @import("sqlite.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
