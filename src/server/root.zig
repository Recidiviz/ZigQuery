//! bigquery-emulator server, ported to Zig on top of the zetasqlite engine.
//! Go counterpart: the `server/` and `internal/` trees of
//! Recidiviz/bigquery-emulator.
//!
//! Kept as a separate module from the engine (src/root.zig) so that
//! `zig build test` and `zig build corpus` — the engine's regression gates —
//! stay untouched by server work. Server tests run under `zig build test-server`.

pub const http_server = @import("http/server.zig");
pub const router = @import("router.zig");
pub const errors = @import("error.zig");
pub const govalue = @import("internal/types/govalue.zig");
pub const schema = @import("internal/types/schema.zig");
pub const response = @import("internal/types/response.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
