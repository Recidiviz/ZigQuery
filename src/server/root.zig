//! bigquery-emulator server, ported to Zig on top of the zetasqlite engine.
//! Go counterpart: the `server/` and `internal/` trees of
//! Recidiviz/bigquery-emulator.
//!
//! Kept as a separate module from the engine (src/root.zig) so that
//! `zig build test` and `zig build spec` — the engine's regression gates —
//! stay untouched by server work. Server tests run under `zig build test-server`.

pub const http_server = @import("http/server.zig");
pub const router = @import("router.zig");
pub const errors = @import("error.zig");
pub const govalue = @import("internal/types/govalue.zig");
pub const schema = @import("internal/types/schema.zig");
pub const rowvalue = @import("internal/types/rowvalue.zig");
pub const queryparam = @import("internal/types/queryparam.zig");
pub const response = @import("internal/types/response.zig");
pub const storage = @import("storage.zig");
pub const discovery = @import("discovery.zig");
pub const query_handler = @import("handler/query.zig");
pub const jobs_handler = @import("handler/jobs.zig");
pub const metadata_repository = @import("internal/metadata/repository.zig");
pub const contentdata_repository = @import("internal/contentdata/repository.zig");
pub const datasets_handler = @import("handler/datasets.zig");
pub const tables_handler = @import("handler/tables.zig");
pub const tabledata_handler = @import("handler/tabledata.zig");
pub const source = @import("source.zig");
pub const stats = @import("stats.zig");
pub const Server = @import("server.zig").Server;
pub const server = @import("server.zig");
// The Storage Read/Write API transport.
pub const grpc_c = @import("grpc/c.zig");
pub const grpc_method = @import("grpc/method.zig");
pub const grpc_server = @import("grpc/server.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
