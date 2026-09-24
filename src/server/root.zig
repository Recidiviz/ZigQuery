//! The server. BigQuery's REST and Storage Read APIs over the zigquery engine.
//!
//! A request is routed (router.zig), decoded into the BigQuery's wire types (internal/types),
//! turned into SQL run through the engine's driver, and encoded back as the API's JSON or,
//! for the Storage Read API, as Arrow or Avro batches (grpc/).
//!
//! Datasets, tables and jobs are the state it keeps; the engine holds the rows.
//!
//! Server tests run under `zig build test-server`.

pub const http_server = @import("http/server.zig");
pub const router = @import("router.zig");
pub const errors = @import("error.zig");
pub const json_pb = @import("json_pb.zig");
pub const debug_stats = @import("debug_stats.zig");
pub const schema = @import("internal/types/schema.zig");
pub const rowvalue = @import("internal/types/rowvalue.zig");
pub const queryparam = @import("internal/types/queryparam.zig");
pub const tablerow = @import("internal/types/tablerow.zig");
pub const response = @import("internal/types/response.zig");
pub const storage = @import("storage.zig");
pub const discovery = @import("discovery.zig");
pub const query_handler = @import("handler/query.zig");
pub const jobs_handler = @import("handler/jobs.zig");
pub const copy_handler = @import("handler/jobs.copy.zig");
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
pub const grpc_read_service = @import("grpc/read_service.zig");
pub const grpc_avro = @import("grpc/avro.zig");
pub const grpc_arrow = @import("grpc/arrow.zig");
pub const grpc_avro_test = @import("grpc/avro_test.zig");
pub const grpc_arrow_test = @import("grpc/arrow_test.zig");
pub const bigquery_pb = @import("proto/bigquery.zig");
pub const bigquery_pb_test = @import("proto/bigquery_test.zig");
pub const storage_pb = @import("proto/storage.zig");
pub const storage_pb_test = @import("proto/storage_test.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
