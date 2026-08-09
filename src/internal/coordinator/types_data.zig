//! Faithful port of go-zetasqlite internal/types_data.go: the pure data
//! structures the extractor produces and the transformers consume.
//!
//! Differences from Go, by design:
//! - Go keeps live `*googlesql.ResolvedColumn` handles inside ColumnRefData /
//!   ComputedColumnData; here they are eagerly-extracted `*ColumnData`
//!   (id/name/table_name) plus a `*spec.Type` where the live handle's Type()
//!   was consulted.
//! - Go `zType` fields become `?*spec.Type` (see src/internal/spec.zig).
//! - Optional embedded values (Go zero-value structs used as "absent", e.g.
//!   LimitScanData.Offset) become Zig optionals.
//! - Enums that Go borrows from googlesql use the generated pb enums.

const std = @import("std");
const value_mod = @import("../value.zig");
const spec = @import("../spec.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const pb = @import("../../proto/resolved_ast.zig");

pub const Value = value_mod.Value;

/// Go shares one ExpressionType between ExpressionData and SQLExpression
/// (sqlbuilder_sqlbuilder.go); mirror that by aliasing the sqlbuilder enum.
pub const ExpressionType = sqlbuilder.ExpressionType;

/// ExpressionData represents the pure data extracted from an expression node.
pub const ExpressionData = struct {
    type: ExpressionType = .column,
    parameter: ?*ParameterData = null,
    literal: ?*LiteralData = null,
    function: ?*FunctionCallData = null,
    cast: ?*CastData = null,
    column: ?*ColumnRefData = null,
    binary: ?*BinaryExpressionData = null,
    case: ?*CaseExpressionData = null,
    subquery: ?*SubqueryData = null,
};

/// LiteralData represents literal value data.
pub const LiteralData = struct {
    value: Value = .null,
    /// String representation of the type kind for reference.
    type_name: []const u8 = "",
    location: ?*ParseLocation = null,
};

/// ParameterData represents a parameter binding value.
pub const ParameterData = struct {
    identifier: []const u8 = "",
};

pub const WindowSpecificationData = struct {
    partition_by: []const *ExpressionData = &.{},
    order_by: []const *OrderByItemData = &.{},
    frame_clause: ?*FrameClauseData = null,
};

/// FunctionCallData represents function call data.
pub const FunctionCallData = struct {
    name: []const u8 = "",
    arguments: []ExpressionData = &.{},
    window_spec: ?*WindowSpecificationData = null,
    signature: ?*FunctionSignature = null,
    /// The call's resolved result type. A bare kind rather than a `*spec.Type`
    /// because its one consumer, the transformer's `isPrimitiveSQLiteType`,
    /// asks only whether the produced value may meet a native SQLite operator.
    ///
    /// TYPE_UNKNOWN carries "unknown": nodes the transformer synthesises leave
    /// it unset, and the transformer reads that as non-primitive.
    result_kind: pb.TypeKind = .TYPE_UNKNOWN,
};

/// Go NewFunctionCallExpressionData (variadic; here the args slice must be
/// arena-owned by the caller).
pub fn newFunctionCallExpressionData(
    alloc: std.mem.Allocator,
    name: []const u8,
    arguments: []ExpressionData,
) error{OutOfMemory}!ExpressionData {
    const fn_data = try alloc.create(FunctionCallData);
    fn_data.* = .{ .name = name, .arguments = arguments };
    return .{ .type = .function, .function = fn_data };
}

/// FrameClauseData represents window frame specifications.
pub const FrameClauseData = struct {
    /// ROWS, RANGE, GROUPS
    unit: []const u8 = "",
    start: ?*FrameBoundData = null,
    end: ?*FrameBoundData = null,
};

/// FrameBoundData represents frame boundary specifications.
pub const FrameBoundData = struct {
    /// UNBOUNDED, CURRENT, PRECEDING, FOLLOWING
    type: []const u8 = "",
    offset: ExpressionData = .{},
};

/// FunctionSignature represents function signature information.
pub const FunctionSignature = struct {
    arguments: []const *ArgumentInfo = &.{},
};

/// ArgumentInfo represents function argument metadata.
pub const ArgumentInfo = struct {
    name: []const u8 = "",
    type: ?*spec.Type = null,
};

/// CastData represents type casting data.
pub const CastData = struct {
    expression: ExpressionData = .{},
    from_type: ?*spec.Type = null,
    to_type: ?*spec.Type = null,
    safe_cast: bool = false,
    return_null_on_err: bool = false,
};

/// ColumnRefData represents column reference data.
pub const ColumnRefData = struct {
    /// Eagerly extracted column info (Go: live *googlesql.ResolvedColumn).
    column: ?*ColumnData = null,
    type: ?*spec.Type = null,
    table_alias: []const u8 = "",
    column_name: []const u8 = "",
    column_id: i64 = 0,
    /// Original table name from the AST.
    table_name: []const u8 = "",
};

/// ColumnData represents extracted column information.
pub const ColumnData = struct {
    id: i64 = 0,
    name: []const u8 = "",
    /// Type kind string (informational; Go uses TypeKind.String()).
    type: []const u8 = "",
    table_name: []const u8 = "",
};

/// BinaryExpressionData represents binary operation data.
pub const BinaryExpressionData = struct {
    left: ExpressionData = .{},
    operator: []const u8 = "",
    right: ExpressionData = .{},
};

/// CaseExpressionData represents CASE expression data.
pub const CaseExpressionData = struct {
    /// Optional - for CASE expr WHEN...
    case_expr: ?*ExpressionData = null,
    when_clauses: []const *WhenClauseData = &.{},
    else_clause: ?*ExpressionData = null,
};

/// WhenClauseData represents a WHEN clause in CASE expressions.
pub const WhenClauseData = struct {
    condition: ExpressionData = .{},
    result: ExpressionData = .{},
};

/// SubqueryData represents subquery expression data.
pub const SubqueryData = struct {
    query: ScanData = .{},
    subquery_type: pb.ResolvedSubqueryExprEnums_SubqueryType = .SCALAR,
    in_expr: ?*ExpressionData = null,
};

/// StatementData represents statement-level data.
pub const StatementData = struct {
    type: StatementType = .select,
    select: ?*SelectData = null,
    insert: ?*InsertData = null,
    update: ?*UpdateData = null,
    delete: ?*DeleteData = null,
    create: ?*CreateData = null,
    drop: ?*DropData = null,
    merge: ?*MergeData = null,
};

/// StatementType identifies the type of statement (same order as Go).
pub const StatementType = enum {
    select,
    insert,
    update,
    delete,
    create,
    drop,
    merge,
};

/// SelectData represents SELECT statement data.
pub const SelectData = struct {
    select_list: []const *SelectItemData = &.{},
    from_clause: ?*ScanData = null,
    where_clause: ?*ExpressionData = null,
    group_by: []const *ExpressionData = &.{},
    having: ?*ExpressionData = null,
    order_by: []const *OrderByItemData = &.{},
    limit: ?*LimitData = null,
    set_operation: ?*SetOperationData = null,
};

/// SelectItemData represents a SELECT list item.
pub const SelectItemData = struct {
    expression: ExpressionData = .{},
    alias: []const u8 = "",
};

/// ScanData represents scan operation data.
pub const ScanData = struct {
    type: ScanType = .table,
    /// Output columns from this scan.
    column_list: []const *ColumnData = &.{},

    table_scan: ?*TableScanData = null,
    join_scan: ?*JoinScanData = null,
    filter_scan: ?*FilterScanData = null,
    project_scan: ?*ProjectScanData = null,
    aggregate_scan: ?*AggregateScanData = null,
    order_by_scan: ?*OrderByScanData = null,
    limit_scan: ?*LimitScanData = null,
    set_operation_scan: ?*SetOperationData = null,
    with_scan: ?*WithScanData = null,
    with_ref_scan: ?*WithRefScanData = null,
    with_entry_scan: ?*WithEntryData = null,
    array_scan: ?*ArrayScanData = null,
    analytic_scan: ?*AnalyticScanData = null,
    recursive_scan: ?*RecursiveScanData = null,
    recursive_ref_scan: ?*RecursiveRefScanData = null,

    pub fn findColumnByID(self: *const ScanData, id: i64) ?*ColumnData {
        for (self.column_list) |col| {
            if (col.id == id) return col;
        }
        return null;
    }
};

/// ScanType identifies the type of scan operation (same order as Go).
pub const ScanType = enum {
    table,
    join,
    filter,
    project,
    aggregate,
    order_by,
    limit,
    set_op,
    single_row,
    with,
    with_ref,
    with_entry,
    array,
    analytic,
    recursive,
    recursive_ref,
};

/// TableScanData represents table scan data.
pub const TableScanData = struct {
    table_name: []const u8 = "",
    alias: []const u8 = "",
    columns: []const *ColumnData = &.{},
    synthetic_columns: []const *SelectItemData = &.{},
};

/// JoinScanData represents join operation data.
pub const JoinScanData = struct {
    join_type: pb.ResolvedJoinScanEnums_JoinType = .INNER,
    left_scan: ScanData = .{},
    right_scan: ScanData = .{},
    join_condition: ?*ExpressionData = null,
    using_columns: []const []const u8 = &.{},
};

/// FilterScanData represents filter operation data.
pub const FilterScanData = struct {
    input_scan: ScanData = .{},
    filter_expr: ExpressionData = .{},
};

/// ProjectScanData represents projection operation data.
pub const ProjectScanData = struct {
    input_scan: ScanData = .{},
    expr_list: []const *ComputedColumnData = &.{},
};

/// ComputedColumnData represents computed column data.
pub const ComputedColumnData = struct {
    /// Eagerly extracted column info (Go: live *googlesql.ResolvedColumn).
    column: ?*ColumnData = null,
    expression: ExpressionData = .{},
};

/// AggregateScanData represents aggregate operation data.
pub const AggregateScanData = struct {
    input_scan: ScanData = .{},
    group_by_list: []const *ComputedColumnData = &.{},
    aggregate_list: []const *ComputedColumnData = &.{},
    grouping_sets: []const *GroupingSetData = &.{},
    grouping_calls: []const *GroupingCallData = &.{},
};

/// One GROUPING(x) call: the column that receives the 0/1, and the group-by
/// column it asks about.
///
/// Apart from `aggregate_list` because the analyzer keeps it apart — GROUPING
/// is not an aggregate over rows, it is a question about which grouping set
/// produced the row, and the answer is therefore constant within one set.
pub const GroupingCallData = struct {
    output_column: ?*ColumnData = null,
    group_by_column: ?*ColumnData = null,
};

/// OrderByScanData represents ORDER BY operation data.
pub const OrderByScanData = struct {
    input_scan: ScanData = .{},
    order_by_columns: []const *OrderByItemData = &.{},
};

/// GroupingSetData represents a grouping set.
pub const GroupingSetData = struct {
    group_by_columns: []const *ComputedColumnData = &.{},
};

/// OrderByItemData represents ORDER BY item data.
pub const OrderByItemData = struct {
    expression: ExpressionData = .{},
    is_descending: bool = false,
    null_order: pb.ResolvedOrderByItemEnums_NullOrderMode = .ORDER_UNSPECIFIED,
};

/// LimitData represents LIMIT clause data.
pub const LimitData = struct {
    count: ExpressionData = .{},
    offset: ?*ExpressionData = null,
};

/// LimitScanData represents LIMIT/OFFSET scan operation data.
pub const LimitScanData = struct {
    /// The nested scan being limited.
    input_scan: ScanData = .{},
    /// LIMIT expression.
    count: ExpressionData = .{},
    /// OFFSET expression (Go: zero-value ExpressionData when absent).
    offset: ?ExpressionData = null,
};

/// ArrayScanData represents array scan (UNNEST) operation data.
pub const ArrayScanData = struct {
    /// Optional input scan for correlated arrays.
    input_scan: ?*ScanData = null,
    /// Array expression to UNNEST.
    array_expr: ExpressionData = .{},
    /// Column for array elements.
    element_column: ?*ColumnData = null,
    /// Optional column for array indices.
    array_offset_column: ?*ColumnData = null,
    /// Whether to use LEFT JOIN (true) or INNER JOIN (false).
    is_outer: bool = false,
    /// Optional join condition.
    join_expr: ?*ExpressionData = null,
};

/// AnalyticScanData represents analytic (window function) scan data.
pub const AnalyticScanData = struct {
    input_scan: ScanData = .{},
    function_list: []const *ComputedColumnData = &.{},
};

/// SetOperationData represents set operation data.
pub const SetOperationData = struct {
    /// UNION, INTERSECT, EXCEPT
    type: []const u8 = "",
    /// ALL, DISTINCT
    modifier: []const u8 = "",
    /// List of statements to combine.
    items: []const StatementData = &.{},
};

/// ParseLocation represents source location information.
pub const ParseLocation = struct {
    start_line: i64 = 0,
    start_column: i64 = 0,
    end_line: i64 = 0,
    end_column: i64 = 0,
    filename: []const u8 = "",
};

// Additional data types for other statements (extracted by later tasks but
// ported now so the shape is complete).

/// InsertData represents INSERT statement data.
pub const InsertData = struct {
    table_name: []const u8 = "",
    columns: []const []const u8 = &.{},
    values: []const []const ExpressionData = &.{},
    query: ?*SelectData = null,
};

/// UpdateData represents UPDATE statement data.
pub const UpdateData = struct {
    table_name: []const u8 = "",
    table_scan: ?*ScanData = null,
    set_items: []const *SetItemData = &.{},
    from_clause: ?*ScanData = null,
    where_clause: ?*ExpressionData = null,
};

/// SetItemData represents a SET item in UPDATE.
pub const SetItemData = struct {
    column: []const u8 = "",
    value: ExpressionData = .{},
};

/// DeleteData represents DELETE statement data.
pub const DeleteData = struct {
    table_name: []const u8 = "",
    table_scan: ?*ScanData = null,
    where_clause: ?*ExpressionData = null,
};

/// CreateData represents CREATE statement data.
pub const CreateData = struct {
    type: CreateType = .table,
    table: ?*CreateTableData = null,
    view: ?*CreateViewData = null,
    function: ?*CreateFunctionData = null,
};

/// CreateType identifies the type of CREATE statement (same order as Go).
pub const CreateType = enum {
    table,
    view,
};

/// CreateTableData represents CREATE TABLE data.
pub const CreateTableData = struct {
    table_name: []const u8 = "",
    columns: []const *ColumnDefinitionData = &.{},
    as_select: ?*SelectData = null,
    if_not_exists: bool = false,
};

/// ColumnDefinitionData represents column definition data.
pub const ColumnDefinitionData = struct {
    name: []const u8 = "",
    type: []const u8 = "",
    not_null: bool = false,
    is_primary_key: bool = false,
    default_value: ?*ExpressionData = null,
};

/// CreateViewData represents CREATE VIEW data.
pub const CreateViewData = struct {
    view_name: []const u8 = "",
    query: SelectData = .{},
};

/// FunctionOptionData mirrors Go's map[string]ExpressionData entry.
pub const FunctionOptionData = struct {
    name: []const u8 = "",
    value: ExpressionData = .{},
};

/// CreateFunctionData represents CREATE FUNCTION data.
pub const CreateFunctionData = struct {
    function_name: []const u8 = "",
    parameters: []const *ParameterDefinitionData = &.{},
    return_type: []const u8 = "",
    language: []const u8 = "",
    code: []const u8 = "",
    options: []const FunctionOptionData = &.{},
};

/// ParameterDefinitionData represents function parameter data.
pub const ParameterDefinitionData = struct {
    name: []const u8 = "",
    type: []const u8 = "",
};

/// DropData represents DROP statement data.
pub const DropData = struct {
    if_exists: bool = false,
    /// TABLE, VIEW, INDEX, SCHEMA, FUNCTION
    object_type: []const u8 = "",
    object_name: []const u8 = "",
};

/// WithScanData represents WITH scan data (complete WITH statements).
pub const WithScanData = struct {
    with_entry_list: []const *WithEntryData = &.{},
    query: ScanData = .{},
    column_list: []const *ColumnData = &.{},
    /// Whether this is a recursive CTE.
    recursive: bool = false,
};

/// WithRefScanData represents WITH reference scan data (references to CTEs).
pub const WithRefScanData = struct {
    with_query_name: []const u8 = "",
    column_list: []const *ColumnData = &.{},
};

/// WithEntryData represents individual WITH entry data (CTE definitions).
pub const WithEntryData = struct {
    with_query_name: []const u8 = "",
    with_subquery: ScanData = .{},
    column_list: []const *ColumnData = &.{},
};

/// RecursiveScanData represents recursive CTE scan data.
pub const RecursiveScanData = struct {
    /// Operation type (e.g. "UNION ALL").
    op_type: []const u8 = "",
    /// Base case of the recursion.
    non_recursive_term: StatementData = .{},
    /// Recursive case.
    recursive_term: StatementData = .{},
};

/// RecursiveRefScanData represents a reference to the recursive CTE being
/// defined.
pub const RecursiveRefScanData = struct {
    with_query_name: []const u8 = "",
    column_list: []const *ColumnData = &.{},
};

/// MergeData represents MERGE statement data.
pub const MergeData = struct {
    target_table: []const u8 = "",
    target_scan: ?*ScanData = null,
    source_scan: ?*ScanData = null,
    merge_expr: ExpressionData = .{},
    when_clauses: []const *MergeWhenClauseData = &.{},
};

/// MergeWhenClauseData represents a WHEN clause in MERGE statements.
pub const MergeWhenClauseData = struct {
    match_type: pb.ResolvedMergeWhenEnums_MatchType = .MATCHED,
    condition: ?*ExpressionData = null,
    action_type: pb.ResolvedMergeWhenEnums_ActionType = .INSERT,
    insert_columns: []const *ColumnData = &.{},
    insert_values: []const ExpressionData = &.{},
    set_items: []const *SetItemData = &.{},
};

/// Shared error set for extraction and transformation.
pub const Error = error{
    /// Node/statement/scan/expression kind not handled by the port yet
    Unimplemented,
    /// Node kind the Go original also rejects ("unsupported ... type").
    UnsupportedNode,
    /// Builtin function with no zetasqlite runtime mapping
    UnsupportedFunction,
    /// A proto field the Go accessors could always read is missing.
    InvalidAST,
    /// Go panics in GetQualifiedColumnRef; the port returns this instead.
    ColumnNotFound,
    /// validateColumnData mismatch (Go: "column validation failed ...").
    ValidationFailed,
} || value_mod.ValueError || sqlbuilder.Error || spec.Error;
