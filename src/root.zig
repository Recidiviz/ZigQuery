//! zigquery: the engine. GoogleSQL in, SQLite out.
//!
//! A statement is analyzed by GoogleSQL's own analyzer through the C++ shim,
//! the resolved AST is extracted into plain data (internal/coordinator),
//! that data is transformed into SQLite SQL (internal/transformer, internal/sqlbuilder),
//! and result cells are decoded back into GoogleSQL values (internal/value, internal/codec_*).
//!
//! SQLite supplies storage and the relational operators;
//! everything BigQuery has and SQLite does not — type system, builtins, value encodings — live here
//!
//! sqlite.zig wraps the SQLite C API and driver.zig is the public surface over this pipeline.
//!
//! The server (src/server/root.zig) depends on this module and not the reverse,
//! so `zig build test` and `zig build spec` gate the engine on its own.

pub const sqlite = @import("sqlite.zig");
pub const analyzer_ffi = @import("analyzer_ffi.zig");
pub const shim_ffi = @import("shim_ffi.zig");
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
pub const spec_run = @import("internal/spec_run.zig");
pub const ast_text = @import("internal/ast_text.zig");
pub const coordinator_types = @import("internal/coordinator/types_data.zig");
pub const coordinator_context = @import("internal/coordinator/context.zig");
pub const extractor = @import("internal/coordinator/extractor.zig");
pub const coordinator = @import("internal/coordinator/coordinator.zig");
pub const function = @import("internal/function/register.zig");
pub const function_window = @import("internal/function/window.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
