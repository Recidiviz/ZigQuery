//! zetasqlite-zig: GoogleSQL -> SQLite translator, a faithful port of
//! Recidiviz/go-zetasqlite. Only the SQL driver interface is redesigned
//! (sqlite.zig + driver.zig); the internal pipeline mirrors the Go original.

pub const sqlite = @import("sqlite.zig");
pub const analyzer_ffi = @import("analyzer_ffi.zig");
pub const pb = @import("proto/resolved_ast.zig");
pub const wire = @import("proto/wire.zig");
pub const driver = @import("driver.zig");
pub const value = @import("internal/value.zig");
pub const codec_binary = @import("internal/codec_binary.zig");
pub const encoder = @import("internal/encoder.zig");
pub const sqlbuilder = @import("internal/sqlbuilder/sqlbuilder.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
