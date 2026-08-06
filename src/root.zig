//! zetasqlite-zig: GoogleSQL -> SQLite translator, a faithful port of
//! Recidiviz/go-zetasqlite. Only the SQL driver interface is redesigned
//! (sqlite.zig + driver.zig); the internal pipeline mirrors the Go original.

pub const sqlite = @import("sqlite.zig");
pub const analyzer_ffi = @import("analyzer_ffi.zig");
pub const regexp_ffi = @import("regexp_ffi.zig");
pub const pb = @import("proto/resolved_ast.zig");
pub const wire = @import("proto/wire.zig");
pub const ast_dump = @import("proto/ast_dump.zig");
pub const driver = @import("driver.zig");
pub const value = @import("internal/value.zig");
pub const codec_binary = @import("internal/codec_binary.zig");
pub const codec_sortable = @import("internal/codec_sortable.zig");
pub const encoder = @import("internal/encoder.zig");
pub const sqlbuilder = @import("internal/sqlbuilder/sqlbuilder.zig");
pub const spec = @import("internal/spec.zig");
pub const catalog = @import("internal/catalog.zig");
pub const shared_catalog = @import("internal/shared_catalog.zig");
pub const phase = @import("internal/phase.zig");
pub const spec_expect = @import("internal/spec_expect.zig");
pub const coordinator_types = @import("internal/coordinator/types_data.zig");
pub const coordinator_context = @import("internal/coordinator/context.zig");
pub const extractor = @import("internal/coordinator/extractor.zig");
pub const coordinator = @import("internal/coordinator/coordinator.zig");
pub const function = @import("internal/function/register.zig");
pub const function_window = @import("internal/function/window.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
