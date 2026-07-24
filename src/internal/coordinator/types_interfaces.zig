//! Port of go-zetasqlite internal/types_interfaces.go, in spirit.
//!
//! Interface mapping (Go -> Zig):
//! - `Transformer[Input, Output]` / `ExpressionTransformer` /
//!   `StatementTransformer` / `ScanTransformer`: Go uses interfaces so the
//!   coordinator can hold heterogeneous transformer instances. The Zig port
//!   uses one stateless `transform` function per transformer module
//!   (src/internal/transformer/<name>.zig); the coordinator dispatches with
//!   a switch, exactly like Go's direct-dispatch QueryCoordinator does. The
//!   signatures mirror the Go interfaces:
//!     expressions: fn (*QueryCoordinator, ExpressionData, *TransformContext) Error!*sqlbuilder.SQLExpression
//!     statements:  fn (*QueryCoordinator, StatementData,  *TransformContext) Error!sqlbuilder.SQLFragment
//!     scans:       fn (*QueryCoordinator, ScanData,       *TransformContext) Error!*sqlbuilder.FromItem
//!     with entry:  fn (*QueryCoordinator, ScanData,       *TransformContext) Error!*sqlbuilder.WithClause
//! - `Coordinator`: concrete `QueryCoordinator` (coordinator.zig); there is
//!   only one implementation, so no vtable is needed.
//! - `TransformContext` / `FragmentContextProvider` / `ScopeToken`: concrete
//!   structs in context.zig (TransformContext, FragmentContext, ScopeToken).
//!   The Go `context.Context` member becomes context.zig's QueryContext.

const value_mod = @import("../value.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const spec = @import("../spec.zig");

/// Shared error set for extraction and transformation. Where Go returns
/// fmt.Errorf diagnostics, the Zig port returns a tagged error; the message
/// intent is preserved in comments at the return sites.
pub const Error = error{
    /// Node/statement/scan/expression kind not handled by the port yet
    /// (Go: "... not implemented" or foundation-deferred kinds).
    Unimplemented,
    /// Node kind the Go original also rejects ("unsupported ... type").
    UnsupportedNode,
    /// Builtin function with no zetasqlite runtime mapping
    /// (Go: "%s function is unimplemented" / "SAFE is not supported").
    UnsupportedFunction,
    /// A proto field the Go accessors could always read is missing.
    InvalidAST,
    /// Go panics in GetQualifiedColumnRef; the port returns this instead.
    ColumnNotFound,
    /// validateColumnData mismatch (Go: "column validation failed ...").
    ValidationFailed,
} || value_mod.ValueError || sqlbuilder.Error || spec.Error;
