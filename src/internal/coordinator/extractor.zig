//! Faithful port of go-zetasqlite internal/coordinator_extractor.go
//! (foundation subset) over the decoded resolved-AST protobuf.
//!
//! Go reads the AST through go-googlesql's fallible accessors and threads an
//! `ev` error accumulator; proto access here is infallible, so that
//! machinery disappears. Where the analyzer guarantees a field but the proto
//! type makes it optional, a missing field is error.InvalidAST.
//!
//! Foundation subset (everything else returns error.Unimplemented, matching
//! the plan in the port handoff):
//! - statements: ResolvedQueryStmt
//! - scans: SingleRow, Project, Filter, Join, Aggregate (no grouping sets),
//!   OrderBy, LimitOffset, SetOperation, With/WithRef/WithEntry, Array
//! - expressions: Literal, ColumnRef, FunctionCall, AggregateFunctionCall,
//!   Cast, SubqueryExpr, ComputedColumn, OutputColumn, GetStructField,
//!   MakeStruct

const std = @import("std");
const pb = @import("../../proto/resolved_ast.zig");
const value_mod = @import("../value.zig");
const encoder = @import("../encoder.zig");
const spec = @import("../spec.zig");
const types_data = @import("types_data.zig");
const context = @import("context.zig");
const interfaces = @import("types_interfaces.zig");

pub const Error = interfaces.Error;

const ExpressionData = types_data.ExpressionData;
const StatementData = types_data.StatementData;
const ScanData = types_data.ScanData;
const ColumnData = types_data.ColumnData;
const TransformContext = context.TransformContext;

// ----------------------------------------------------------------------
// Function-name normalization (Go: getZetasqliteFuncName + function maps)
// ----------------------------------------------------------------------

/// Names of internal/function_register.go normalFuncs. Go additionally
/// registers a "safe_<name>" map key for each entry (setupNormalFuncMap);
/// `existsNormalFunc` below reproduces that without duplicating the table.
const normal_func_names = std.StaticStringMap(void).initComptime(.{
    .{"add"},           .{"subtract"},            .{"multiply"},
    .{"divide"},        .{"equal"},               .{"not_equal"},
    .{"greater"},       .{"greater_or_equal"},    .{"less"},
    .{"less_or_equal"}, .{"bitwise_not"},         .{"bitwise_left_shift"},
    .{"bitwise_right_shift"}, .{"bitwise_and"},   .{"bitwise_or"},
    .{"bitwise_xor"},   .{"in_array"},            .{"get_struct_field"},
    .{"get_json_field"}, .{"subscript"},          .{"array_at_offset"},
    .{"array_at_ordinal"}, .{"safe_negate"},      .{"is_distinct_from"},
    .{"is_not_distinct_from"}, .{"session_user"}, .{"generate_uuid"},
    .{"error"},         .{"current_date"},        .{"extract"},
    .{"extract_date"},  .{"date"},                .{"date_add"},
    .{"date_sub"},      .{"date_diff"},           .{"date_trunc"},
    .{"date_from_unix_date"}, .{"format_date"},   .{"last_day"},
    .{"parse_date"},    .{"unix_date"},           .{"current_datetime"},
    .{"datetime"},      .{"datetime_add"},        .{"datetime_sub"},
    .{"datetime_diff"}, .{"datetime_trunc"},      .{"format_datetime"},
    .{"parse_datetime"}, .{"current_time"},       .{"time"},
    .{"time_add"},      .{"time_sub"},            .{"time_diff"},
    .{"time_trunc"},    .{"format_time"},         .{"parse_time"},
    .{"current_timestamp"}, .{"string"},          .{"timestamp"},
    .{"timestamp_add"}, .{"timestamp_sub"},       .{"timestamp_diff"},
    .{"timestamp_trunc"}, .{"format_timestamp"},  .{"parse_timestamp"},
    .{"timestamp_seconds"}, .{"timestamp_millis"}, .{"timestamp_micros"},
    .{"unix_seconds"},  .{"unix_millis"},         .{"unix_micros"},
    .{"like"},          .{"between"},             .{"in"},
    .{"is_null"},       .{"is_true"},             .{"is_false"},
    .{"not"},           .{"and"},                 .{"or"},
    .{"coalesce"},      .{"if"},                  .{"ifnull"},
    .{"nullif"},        .{"length"},              .{"cast"},
    .{"interval"},      .{"make_interval"},       .{"justify_days"},
    .{"justify_hours"}, .{"justify_interval"},    .{"parse_numeric"},
    .{"parse_bignumeric"}, .{"farm_fingerprint"}, .{"md5"},
    .{"sha1"},          .{"sha256"},              .{"sha512"},
    .{"ascii"},         .{"byte_length"},         .{"char_length"},
    .{"chr"},           .{"code_points_to_bytes"}, .{"code_points_to_string"},
    .{"collate"},       .{"concat"},              .{"contains_substr"},
    .{"ends_with"},     .{"format"},              .{"from_base32"},
    .{"from_base64"},   .{"from_hex"},            .{"initcap"},
    .{"instr"},         .{"left"},                .{"lpad"},
    .{"lower"},         .{"ltrim"},               .{"normalize"},
    .{"normalize_and_casefold"}, .{"regexp_contains"}, .{"regexp_extract"},
    .{"regexp_extract_all"}, .{"regexp_instr"},   .{"regexp_replace"},
    .{"replace"},       .{"repeat"},              .{"reverse"},
    .{"right"},         .{"rpad"},                .{"rtrim"},
    .{"safe_convert_bytes_to_string"}, .{"soundex"}, .{"split"},
    .{"starts_with"},   .{"strpos"},              .{"substr"},
    .{"to_base32"},     .{"to_base64"},           .{"to_code_points"},
    .{"to_hex"},        .{"translate"},           .{"trim"},
    .{"unicode"},       .{"upper"},               .{"json_extract"},
    .{"json_extract_scalar"}, .{"json_extract_array"}, .{"json_extract_string_array"},
    .{"json_query"},    .{"json_value"},          .{"json_query_array"},
    .{"json_value_array"}, .{"parse_json"},       .{"to_json"},
    .{"to_json_string"}, .{"bool"},               .{"int64"},
    .{"double"},        .{"float64"},             .{"json_type"},
    .{"abs"},           .{"sign"},                .{"is_inf"},
    .{"is_nan"},        .{"ieee_divide"},         .{"rand"},
    .{"sqrt"},          .{"pow"},                 .{"power"},
    .{"exp"},           .{"ln"},                  .{"log"},
    .{"log10"},         .{"greatest"},            .{"least"},
    .{"div"},           .{"mod"},                 .{"round"},
    .{"trunc"},         .{"ceil"},                .{"ceiling"},
    .{"floor"},         .{"cos"},                 .{"cosh"},
    .{"acos"},          .{"acosh"},               .{"sin"},
    .{"sinh"},          .{"asin"},                .{"asinh"},
    .{"tan"},           .{"tanh"},                .{"atan"},
    .{"atanh"},         .{"atan2"},               .{"range_bucket"},
    .{"array_concat"},  .{"array_first"},         .{"array_last"},
    .{"array_slice"},   .{"array_length"},        .{"array_to_string"},
    .{"generate_array"}, .{"generate_date_array"}, .{"generate_timestamp_array"},
    .{"array_reverse"}, .{"make_array"},          .{"make_struct"},
    .{"hll_count_extract"}, .{"bit_count"},       .{"distinct"},
    .{"limit"},         .{"order_by"},            .{"ignore_nulls"},
    .{"having_max"},    .{"having_min"},          .{"eval_javascript"},
    .{"net_host"},      .{"net_ip_from_string"},  .{"net_ip_net_mask"},
    .{"net_ip_to_string"}, .{"net_ip_trunc"},     .{"net_ipv4_from_int64"},
    .{"net_ipv4_to_int64"}, .{"net_public_suffix"}, .{"net_reg_domain"},
    .{"net_safe_ip_from_string"},
});

/// internal/function_register.go aggregateFuncs names.
const aggregate_func_names = std.StaticStringMap(void).initComptime(.{
    .{"array"},        .{"any_value"},    .{"array_agg"},
    .{"array_concat_agg"}, .{"avg"},      .{"count"},
    .{"count_star"},   .{"bit_and"},      .{"bit_or"},
    .{"bit_xor"},      .{"countif"},      .{"logical_and"},
    .{"logical_or"},   .{"max"},          .{"min"},
    .{"string_agg"},   .{"sum"},          .{"corr"},
    .{"covar_pop"},    .{"covar_samp"},   .{"stddev_pop"},
    .{"stddev_samp"},  .{"stddev"},       .{"var_pop"},
    .{"var_samp"},     .{"variance"},     .{"approx_count_distinct"},
    .{"approx_quantiles"}, .{"approx_top_count"}, .{"approx_top_sum"},
    .{"hll_count_init"}, .{"hll_count_merge"}, .{"hll_count_merge_partial"},
});

/// internal/function_register.go windowFuncs names.
const window_func_names = std.StaticStringMap(void).initComptime(.{
    .{"any_value"},   .{"array_agg"},   .{"avg"},
    .{"count"},       .{"count_star"},  .{"countif"},
    .{"logical_and"}, .{"logical_or"},  .{"max"},
    .{"min"},         .{"string_agg"},  .{"sum"},
    .{"corr"},        .{"covar_pop"},   .{"covar_samp"},
    .{"stddev_pop"},  .{"stddev_samp"}, .{"stddev"},
    .{"var_pop"},     .{"var_samp"},    .{"variance"},
    .{"first_value"}, .{"last_value"},  .{"nth_value"},
    .{"lead"},        .{"lag"},         .{"percentile_cont"},
    .{"percentile_disc"}, .{"rank"},    .{"dense_rank"},
    .{"percent_rank"}, .{"cume_dist"},  .{"ntile"},
    .{"row_number"},
});

/// internal/function_register.go currentTimeFuncMap.
const current_time_func_names = std.StaticStringMap(void).initComptime(.{
    .{"current_date"},
    .{"current_datetime"},
    .{"current_time"},
    .{"current_timestamp"},
    .{"zetasqlite_current_date"},
    .{"zetasqlite_current_datetime"},
    .{"zetasqlite_current_time"},
    .{"zetasqlite_current_timestamp"},
});

/// Go: normalFuncMap membership, which contains every normalFuncs name plus
/// its "safe_"-prefixed alias (see setupNormalFuncMap).
fn existsNormalFunc(name: []const u8) bool {
    if (normal_func_names.has(name)) return true;
    if (std.mem.startsWith(u8, name, "safe_") and normal_func_names.has(name["safe_".len..]))
        return true;
    return false;
}

/// The builtin function group prefix carried by FunctionRefProto.name.
/// The googlesql fork emits "GoogleSQL:"; upstream zetasql emits "ZetaSQL:".
fn builtinGroupOf(raw_name: []const u8) ?[]const u8 {
    if (std.mem.startsWith(u8, raw_name, "GoogleSQL:")) return raw_name["GoogleSQL:".len..];
    if (std.mem.startsWith(u8, raw_name, "ZetaSQL:")) return raw_name["ZetaSQL:".len..];
    return null;
}

/// Go getZetasqliteFuncName. `fcb` carries the FunctionRefProto name
/// (e.g. "GoogleSQL:$add"); Go's fn.FullName(false) /
/// fn.IsGoogleSQLBuiltin() map to stripping / detecting the builtin group
/// prefix here.
fn getZetasqliteFuncName(
    alloc: std.mem.Allocator,
    fcb: *const pb.ResolvedFunctionCallBaseProto,
    is_window_func: bool,
) Error![]const u8 {
    const raw_name = (fcb.function orelse return error.InvalidAST).name orelse
        return error.InvalidAST;
    const stripped = builtinGroupOf(raw_name);
    const is_builtin = stripped != null;
    const full_name = stripped orelse raw_name;

    // funcName := strings.ReplaceAll(fullName, ".", "_")
    const func_name = try replaceDots(alloc, full_name);

    const exists_current_time = current_time_func_names.has(func_name);
    const exists_normal = existsNormalFunc(func_name);
    const exists_aggregate = aggregate_func_names.has(func_name);
    const exists_window = window_func_names.has(func_name);

    var func_prefix: []const u8 = "zetasqlite";
    const error_mode = fcb.error_mode orelse .DEFAULT_ERROR_MODE;
    if (error_mode == .SAFE_ERROR_MODE) {
        // Go: "SAFE is not supported for function %s"
        if (!exists_normal) return error.UnsupportedFunction;
        func_prefix = "zetasqlite_safe";
    }

    if (std.mem.startsWith(u8, func_name, "$")) {
        if (is_window_func) {
            return std.fmt.allocPrint(alloc, "{s}_window_{s}", .{ func_prefix, func_name[1..] });
        }
        return std.fmt.allocPrint(alloc, "{s}_{s}", .{ func_prefix, func_name[1..] });
    } else if (exists_current_time) {
        return std.fmt.allocPrint(alloc, "{s}_{s}", .{ func_prefix, func_name });
    } else if (exists_normal) {
        return std.fmt.allocPrint(alloc, "{s}_{s}", .{ func_prefix, func_name });
    } else if (!is_window_func and exists_aggregate) {
        return std.fmt.allocPrint(alloc, "{s}_{s}", .{ func_prefix, func_name });
    } else if (is_window_func and exists_window) {
        return std.fmt.allocPrint(alloc, "{s}_window_{s}", .{ func_prefix, func_name });
    } else {
        // Go: builtins with no runtime mapping -> "%s function is
        // unimplemented"; otherwise getFuncName recovers the registered UDF
        // name from FunctionNamePath (formatPath joins with "_", which the
        // "."->"_" replacement above already produced).
        if (is_builtin) return error.UnsupportedFunction;
        return func_name;
    }
}

fn replaceDots(alloc: std.mem.Allocator, s: []const u8) error{OutOfMemory}![]u8 {
    const out = try alloc.dupe(u8, s);
    for (out) |*c| {
        if (c.* == '.') c.* = '_';
    }
    return out;
}

// ----------------------------------------------------------------------
// Shared helpers (Go: extractColumnData / scanColumnList / ...)
// ----------------------------------------------------------------------

/// Go extractColumnData: ResolvedColumn -> ColumnData. The Type string is
/// the type-kind tag name (informational; Go uses TypeKind.String()).
pub fn extractColumnData(
    alloc: std.mem.Allocator,
    col: ?*const pb.ResolvedColumnProto,
) Error!*ColumnData {
    const data = try alloc.create(ColumnData);
    data.* = .{};
    const c = col orelse return data;
    var kind_str: []const u8 = "";
    if (c.@"type") |tp| {
        kind_str = @tagName(tp.type_kind orelse .TYPE_UNKNOWN);
    }
    data.* = .{
        .id = c.column_id orelse 0,
        .name = c.name orelse "",
        .type = kind_str,
        .table_name = c.table_name orelse "",
    };
    return data;
}

/// Go extractColumnDataList.
pub fn extractColumnDataList(
    alloc: std.mem.Allocator,
    columns: []const *pb.ResolvedColumnProto,
) Error![]const *ColumnData {
    const out = try alloc.alloc(*ColumnData, columns.len);
    for (columns, 0..) |col, i| {
        out[i] = try extractColumnData(alloc, col);
    }
    return out;
}

/// Go NewColumnExpressionData (types_data.go): column-reference
/// ExpressionData from a resolved column.
pub fn newColumnExpressionData(
    alloc: std.mem.Allocator,
    column: *const pb.ResolvedColumnProto,
) Error!ExpressionData {
    const ref = try alloc.create(types_data.ColumnRefData);
    ref.* = .{
        .column = try extractColumnData(alloc, column),
        .column_name = column.name orelse "",
        .column_id = column.column_id orelse 0,
        .table_name = column.table_name orelse "",
        .type = if (column.@"type") |tp| try spec.newTypeFromProto(alloc, tp) else null,
    };
    return .{ .type = .column, .column = ref };
}

/// Go scanColumnList: output column list of any resolved scan (the promoted
/// ResolvedScan base field). Only foundation scan kinds are reachable.
fn scanColumnListOf(scan: *const pb.AnyResolvedScanProto) Error![]const *pb.ResolvedColumnProto {
    const node = scan.node orelse return error.InvalidAST;
    const parent: ?*pb.ResolvedScanProto = switch (node) {
        .resolved_single_row_scan_node => |n| n.parent,
        .resolved_table_scan_node => |n| n.parent,
        .resolved_join_scan_node => |n| n.parent,
        .resolved_array_scan_node => |n| n.parent,
        .resolved_filter_scan_node => |n| n.parent,
        .resolved_set_operation_scan_node => |n| n.parent,
        .resolved_order_by_scan_node => |n| n.parent,
        .resolved_limit_offset_scan_node => |n| n.parent,
        .resolved_with_ref_scan_node => |n| n.parent,
        .resolved_analytic_scan_node => |n| n.parent,
        .resolved_project_scan_node => |n| n.parent,
        .resolved_with_scan_node => |n| n.parent,
        .resolved_recursive_ref_scan_node => |n| n.parent,
        .resolved_recursive_scan_node => |n| n.parent,
        .resolved_aggregate_scan_base_node => |n| blk: {
            const agg_node = n.node orelse return error.InvalidAST;
            switch (agg_node) {
                .resolved_aggregate_scan_node => |a| {
                    const base = a.parent orelse return error.InvalidAST;
                    break :blk base.parent;
                },
                else => return error.Unimplemented,
            }
        },
        else => return error.Unimplemented,
    };
    return (parent orelse return error.InvalidAST).column_list;
}

/// Result type of an expression node (Go: expr.Type() on the ResolvedExpr
/// base). Covers the foundation expression kinds.
fn exprTypeProto(expr: *const pb.AnyResolvedExprProto) Error!*pb.TypeProto {
    const node = expr.node orelse return error.InvalidAST;
    const parent: ?*pb.ResolvedExprProto = switch (node) {
        .resolved_literal_node => |n| n.parent,
        .resolved_parameter_node => |n| n.parent,
        .resolved_column_ref_node => |n| n.parent,
        .resolved_cast_node => |n| n.parent,
        .resolved_make_struct_node => |n| n.parent,
        .resolved_get_struct_field_node => |n| n.parent,
        .resolved_subquery_expr_node => |n| n.parent,
        .resolved_argument_ref_node => |n| n.parent,
        .resolved_get_json_field_node => |n| n.parent,
        .resolved_function_call_base_node => |n| blk: {
            const fcb = try functionCallBaseOf(n);
            break :blk fcb.parent;
        },
        else => return error.Unimplemented,
    };
    const p = parent orelse return error.InvalidAST;
    return p.@"type" orelse error.InvalidAST;
}

/// Unwraps AnyResolvedFunctionCallBaseProto down to the shared
/// ResolvedFunctionCallBaseProto parent.
fn functionCallBaseOf(
    any: *const pb.AnyResolvedFunctionCallBaseProto,
) Error!*pb.ResolvedFunctionCallBaseProto {
    const node = any.node orelse return error.InvalidAST;
    switch (node) {
        .resolved_function_call_node => |fc| return fc.parent orelse error.InvalidAST,
        .resolved_non_scalar_function_call_base_node => |ns| {
            const ns_node = ns.node orelse return error.InvalidAST;
            const non_scalar: *pb.ResolvedNonScalarFunctionCallBaseProto = switch (ns_node) {
                .resolved_aggregate_function_call_node => |agg| agg.parent orelse return error.InvalidAST,
                .resolved_analytic_function_call_node => |an| an.parent orelse return error.InvalidAST,
            };
            return non_scalar.parent orelse error.InvalidAST;
        },
    }
}

// ----------------------------------------------------------------------
// NodeExtractor
// ----------------------------------------------------------------------

/// Go NodeExtractor: extracts pure data from AST nodes, separating AST
/// traversal from data extraction.
pub const NodeExtractor = struct {
    /// Go ExtractStatementData. Entry point takes the decoded statement
    /// node; only ResolvedQueryStmt is in the foundation subset.
    pub fn ExtractStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.AnyResolvedNodeProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const any = node.node orelse return error.InvalidAST;
        const stmt = switch (any) {
            .resolved_statement_node => |s| s,
            else => return error.UnsupportedNode, // Go: "unsupported statement node type"
        };
        const stmt_node = stmt.node orelse return error.InvalidAST;
        switch (stmt_node) {
            .resolved_query_stmt_node => |q| return self.extractQueryStatementData(alloc, q, ctx),
            // CreateTable/CreateTableAsSelect/CreateView/Insert/Update/
            // Delete/Merge/Drop/DropFunction: extracted by later tasks.
            .resolved_create_statement_node,
            .resolved_insert_stmt_node,
            .resolved_update_stmt_node,
            .resolved_delete_stmt_node,
            .resolved_merge_stmt_node,
            .resolved_drop_stmt_node,
            .resolved_drop_function_stmt_node,
            => return error.Unimplemented,
            else => return error.UnsupportedNode,
        }
    }

    /// Go extractQueryStatementData: the main query scan becomes the
    /// FromClause; the statement's output columns become the SelectList
    /// (column refs aliased by output name).
    fn extractQueryStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedQueryStmtProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const query = node.query orelse return error.InvalidAST;
        const scan_data = try self.ExtractScanData(alloc, query, ctx);

        const select_items = try alloc.alloc(*types_data.SelectItemData, node.output_column_list.len);
        for (node.output_column_list, 0..) |col, i| {
            // Go routes ResolvedOutputColumn through ExtractExpressionData,
            // which resolves to NewColumnExpressionData(col.Column()).
            const column = col.column orelse return error.InvalidAST;
            const item = try alloc.create(types_data.SelectItemData);
            item.* = .{
                .expression = try newColumnExpressionData(alloc, column),
                .alias = col.name orelse "",
            };
            select_items[i] = item;
        }

        const from_clause = try alloc.create(ScanData);
        from_clause.* = scan_data;
        const select = try alloc.create(types_data.SelectData);
        select.* = .{ .select_list = select_items, .from_clause = from_clause };
        return .{ .type = .select, .select = select };
    }

    /// Go ExtractScanData.
    pub fn ExtractScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        scan: *const pb.AnyResolvedScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const node = scan.node orelse return error.InvalidAST;
        switch (node) {
            .resolved_single_row_scan_node => return self.extractSingleRowScanData(),
            .resolved_project_scan_node => |n| return self.extractProjectScanData(alloc, n, ctx),
            .resolved_filter_scan_node => |n| return self.extractFilterScanData(alloc, n, ctx),
            .resolved_join_scan_node => |n| return self.extractJoinScanData(alloc, n, ctx),
            .resolved_aggregate_scan_base_node => |n| {
                const agg_node = n.node orelse return error.InvalidAST;
                switch (agg_node) {
                    .resolved_aggregate_scan_node => |a| return self.extractAggregateScanData(alloc, a, ctx),
                    // Anonymized/DifferentialPrivacy/AggregationThreshold:
                    // Go has no case for them either.
                    else => return error.UnsupportedNode,
                }
            },
            .resolved_order_by_scan_node => |n| return self.extractOrderByScanData(alloc, n, ctx),
            .resolved_limit_offset_scan_node => |n| return self.extractLimitScanData(alloc, n, ctx),
            .resolved_set_operation_scan_node => |n| return self.extractSetOperationScanData(alloc, n, ctx),
            .resolved_with_scan_node => |n| return self.extractWithScanNode(alloc, n, ctx),
            .resolved_with_ref_scan_node => |n| return self.extractWithRefScanNode(alloc, n, ctx),
            .resolved_array_scan_node => |n| return self.extractArrayScanData(alloc, n, ctx),
            // Deferred foundation gaps:
            .resolved_table_scan_node => return error.Unimplemented, // needs catalog (later task)
            .resolved_analytic_scan_node => return error.Unimplemented,
            .resolved_recursive_scan_node => return error.Unimplemented,
            .resolved_recursive_ref_scan_node => return error.Unimplemented,
            else => return error.UnsupportedNode, // Go: "unsupported scan node type"
        }
    }

    fn extractSingleRowScanData(self: *const NodeExtractor) ScanData {
        _ = self;
        // Go: ScanData{Type: ScanTypeSingleRow} (no column list).
        return .{ .type = .single_row };
    }

    fn extractProjectScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedProjectScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const input_scan = node.input_scan orelse return error.InvalidAST;
        const input_scan_data = try self.ExtractScanData(alloc, input_scan, ctx);

        const computed_columns = try alloc.alloc(*types_data.ComputedColumnData, node.expr_list.len);
        for (node.expr_list, 0..) |expr, i| {
            computed_columns[i] = try self.extractComputedColumnData(alloc, expr, ctx);
        }

        const parent = node.parent orelse return error.InvalidAST;
        const project = try alloc.create(types_data.ProjectScanData);
        project.* = .{
            .input_scan = input_scan_data, // The nested scan structure!
            .expr_list = computed_columns,
        };
        return .{
            .type = .project,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .project_scan = project,
        };
    }

    /// Extracts a ResolvedComputedColumn into ComputedColumnData (Go keeps
    /// the live resolved column; here it becomes *ColumnData).
    fn extractComputedColumnData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        cc: *const pb.ResolvedComputedColumnProto,
        ctx: *TransformContext,
    ) Error!*types_data.ComputedColumnData {
        const expr = cc.expr orelse return error.InvalidAST;
        const out = try alloc.create(types_data.ComputedColumnData);
        out.* = .{
            .column = try extractColumnData(alloc, cc.column),
            .expression = try self.ExtractExpressionData(alloc, expr, ctx),
        };
        return out;
    }

    fn extractFilterScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedFilterScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const input_scan = node.input_scan orelse return error.InvalidAST;
        const input_scan_data = try self.ExtractScanData(alloc, input_scan, ctx);

        const filter_expr = node.filter_expr orelse return error.InvalidAST;
        const filter_expr_data = try self.ExtractExpressionData(alloc, filter_expr, ctx);

        const parent = node.parent orelse return error.InvalidAST;
        const filter = try alloc.create(types_data.FilterScanData);
        filter.* = .{ .input_scan = input_scan_data, .filter_expr = filter_expr_data };
        return .{
            .type = .filter,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .filter_scan = filter,
        };
    }

    fn extractJoinScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedJoinScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const left_scan_node = node.left_scan orelse return error.InvalidAST;
        const left_scan = try self.ExtractScanData(alloc, left_scan_node, ctx);
        const right_scan_node = node.right_scan orelse return error.InvalidAST;
        const right_scan = try self.ExtractScanData(alloc, right_scan_node, ctx);

        var join_condition: ?*ExpressionData = null;
        if (node.join_expr) |join_expr| {
            const cond = try alloc.create(ExpressionData);
            cond.* = try self.ExtractExpressionData(alloc, join_expr, ctx);
            join_condition = cond;
        }

        const parent = node.parent orelse return error.InvalidAST;
        const join = try alloc.create(types_data.JoinScanData);
        join.* = .{
            .join_type = node.join_type orelse .INNER,
            .left_scan = left_scan,
            .right_scan = right_scan,
            .join_condition = join_condition,
        };
        return .{
            .type = .join,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .join_scan = join,
        };
    }

    fn extractAggregateScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedAggregateScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const base = node.parent orelse return error.InvalidAST;
        const input_scan = base.input_scan orelse return error.InvalidAST;
        const input_scan_data = try self.ExtractScanData(alloc, input_scan, ctx);

        // Grouping sets (GROUP BY GROUPING SETS/ROLLUP/CUBE): deferred.
        if (base.grouping_set_list.len > 0) return error.Unimplemented;

        var aggregate_list: std.ArrayList(*types_data.ComputedColumnData) = .empty;
        for (base.aggregate_list) |agg_any| {
            const cc = try computedColumnOf(agg_any);
            try aggregate_list.append(alloc, try self.extractComputedColumnData(alloc, cc, ctx));
        }

        var group_by_list: std.ArrayList(*types_data.ComputedColumnData) = .empty;
        for (base.group_by_list) |group_by| {
            try group_by_list.append(alloc, try self.extractComputedColumnData(alloc, group_by, ctx));
        }

        const parent = base.parent orelse return error.InvalidAST;
        const aggregate = try alloc.create(types_data.AggregateScanData);
        aggregate.* = .{
            .input_scan = input_scan_data,
            .group_by_list = try group_by_list.toOwnedSlice(alloc),
            .aggregate_list = try aggregate_list.toOwnedSlice(alloc),
            .grouping_sets = &.{},
        };
        return .{
            .type = .aggregate,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .aggregate_scan = aggregate,
        };
    }

    fn extractOrderByScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedOrderByScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const input_scan = node.input_scan orelse return error.InvalidAST;
        const input_scan_data = try self.ExtractScanData(alloc, input_scan, ctx);

        const order_by_items = try alloc.alloc(*types_data.OrderByItemData, node.order_by_item_list.len);
        for (node.order_by_item_list, 0..) |item_node, i| {
            const column_ref = item_node.column_ref orelse return error.InvalidAST;
            const column = column_ref.column orelse return error.InvalidAST;
            const item = try alloc.create(types_data.OrderByItemData);
            item.* = .{
                .expression = try newColumnExpressionData(alloc, column),
                .is_descending = item_node.is_descending orelse false,
                .null_order = item_node.null_order orelse .ORDER_UNSPECIFIED,
            };
            order_by_items[i] = item;
        }

        const parent = node.parent orelse return error.InvalidAST;
        const order_by = try alloc.create(types_data.OrderByScanData);
        order_by.* = .{ .input_scan = input_scan_data, .order_by_columns = order_by_items };
        return .{
            .type = .order_by,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .order_by_scan = order_by,
        };
    }

    fn extractLimitScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedLimitOffsetScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const input_scan = node.input_scan orelse return error.InvalidAST;
        const input_scan_data = try self.ExtractScanData(alloc, input_scan, ctx);

        var limit_expr_data = ExpressionData{};
        if (node.limit) |limit| {
            limit_expr_data = try self.ExtractExpressionData(alloc, limit, ctx);
        }

        var offset_expr_data: ?ExpressionData = null;
        if (node.offset) |offset| {
            offset_expr_data = try self.ExtractExpressionData(alloc, offset, ctx);
        }

        const parent = node.parent orelse return error.InvalidAST;
        const limit_scan = try alloc.create(types_data.LimitScanData);
        limit_scan.* = .{
            .input_scan = input_scan_data, // The nested scan structure!
            .count = limit_expr_data,
            .offset = offset_expr_data,
        };
        return .{
            .type = .limit,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .limit_scan = limit_scan,
        };
    }

    fn extractSetOperationScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedSetOperationScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        // Map ZetaSQL set operation types to SQLite equivalents.
        var op_type: []const u8 = "UNKNOWN";
        var modifier: []const u8 = "";
        switch (node.op_type orelse .UNION_ALL) {
            .UNION_ALL => {
                op_type = "UNION";
                modifier = "ALL";
            },
            .UNION_DISTINCT => op_type = "UNION",
            .INTERSECT_ALL => {
                op_type = "INTERSECT";
                modifier = "ALL";
            },
            .INTERSECT_DISTINCT => op_type = "INTERSECT",
            .EXCEPT_ALL => {
                op_type = "EXCEPT";
                modifier = "ALL";
            },
            .EXCEPT_DISTINCT => op_type = "EXCEPT",
            else => op_type = "UNKNOWN",
        }

        const parent = node.parent orelse return error.InvalidAST;
        const column_list = parent.column_list;

        const items = try alloc.alloc(types_data.StatementData, node.input_item_list.len);
        for (node.input_item_list, 0..) |item, i| {
            const item_scan = item.scan orelse return error.InvalidAST;
            const scan_data = try self.ExtractScanData(alloc, item_scan, ctx);

            const select_items = try alloc.alloc(*types_data.SelectItemData, item.output_column_list.len);
            for (item.output_column_list, 0..) |column, j| {
                // Use the final output column name (from the outer scan's
                // ColumnList) instead of the item's internal column name.
                const alias_name = if (j < column_list.len)
                    column_list[j].name orelse ""
                else
                    column.name orelse ""; // fallback

                const select_item = try alloc.create(types_data.SelectItemData);
                select_item.* = .{
                    .expression = try newColumnExpressionData(alloc, column),
                    .alias = alias_name,
                };
                select_items[j] = select_item;
            }

            const from_clause = try alloc.create(ScanData);
            from_clause.* = scan_data;
            const select = try alloc.create(types_data.SelectData);
            select.* = .{ .select_list = select_items, .from_clause = from_clause };
            items[i] = .{ .type = .select, .select = select };
        }

        const set_op = try alloc.create(types_data.SetOperationData);
        set_op.* = .{ .type = op_type, .modifier = modifier, .items = items };
        return .{
            .type = .set_op,
            .column_list = try extractColumnDataList(alloc, column_list),
            .set_operation_scan = set_op,
        };
    }

    fn extractWithScanNode(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedWithScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const query_node = node.query orelse return error.InvalidAST;
        const query = try self.ExtractScanData(alloc, query_node, ctx);

        const with_entry_list = try alloc.alloc(*types_data.WithEntryData, node.with_entry_list.len);
        for (node.with_entry_list, 0..) |entry, i| {
            with_entry_list[i] = try self.extractWithEntryData(alloc, entry, ctx);
        }

        const parent = node.parent orelse return error.InvalidAST;
        const with_scan = try alloc.create(types_data.WithScanData);
        with_scan.* = .{
            .with_entry_list = with_entry_list,
            .query = query,
            .recursive = node.recursive orelse false,
        };
        return .{
            .type = .with,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .with_scan = with_scan,
        };
    }

    /// Go extractWithEntryData: the entry's column list comes from the
    /// subquery scan's own output columns.
    pub fn extractWithEntryData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedWithEntryProto,
        ctx: *TransformContext,
    ) Error!*types_data.WithEntryData {
        const with_subquery = node.with_subquery orelse return error.InvalidAST;
        const subquery = try self.ExtractScanData(alloc, with_subquery, ctx);
        const subquery_column_list = try scanColumnListOf(with_subquery);

        const entry = try alloc.create(types_data.WithEntryData);
        entry.* = .{
            .with_query_name = node.with_query_name orelse "",
            .with_subquery = subquery,
            .column_list = try extractColumnDataList(alloc, subquery_column_list),
        };
        return entry;
    }

    fn extractWithRefScanNode(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedWithRefScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        _ = self;
        _ = ctx;
        const parent = node.parent orelse return error.InvalidAST;
        const column_data = try extractColumnDataList(alloc, parent.column_list);
        const with_ref = try alloc.create(types_data.WithRefScanData);
        with_ref.* = .{
            .with_query_name = node.with_query_name orelse "",
            .column_list = column_data,
        };
        return .{
            .type = .with_ref,
            .column_list = column_data,
            .with_ref_scan = with_ref,
        };
    }

    fn extractArrayScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedArrayScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        // Go reads the single ArrayExpr()/ElementColumn() accessors; the
        // proto carries repeated array_expr_list/element_column_list (multi-
        // array zip UNNEST). The Go fork's accessors yield the first entry;
        // more than one is beyond the Go original -> Unimplemented.
        if (node.array_expr_list.len == 0) return error.InvalidAST;
        if (node.array_expr_list.len > 1) return error.Unimplemented;
        const array_expr_data = try self.ExtractExpressionData(alloc, node.array_expr_list[0], ctx);

        var input_scan_data: ?*ScanData = null;
        if (node.input_scan) |input_scan| {
            const input = try alloc.create(ScanData);
            input.* = try self.ExtractScanData(alloc, input_scan, ctx);
            input_scan_data = input;
        }

        if (node.element_column_list.len > 1) return error.Unimplemented;
        var element_column_data: ?*ColumnData = null;
        if (node.element_column_list.len == 1) {
            element_column_data = try extractColumnData(alloc, node.element_column_list[0]);
        }

        var array_offset_column_data: ?*ColumnData = null;
        if (node.array_offset_column) |holder| {
            const offset_column = holder.column orelse return error.InvalidAST;
            array_offset_column_data = try extractColumnData(alloc, offset_column);
        }

        var join_expr_data: ?*ExpressionData = null;
        if (node.join_expr) |join_expr| {
            const join_data = try alloc.create(ExpressionData);
            join_data.* = try self.ExtractExpressionData(alloc, join_expr, ctx);
            join_expr_data = join_data;
        }

        const parent = node.parent orelse return error.InvalidAST;
        const array_scan = try alloc.create(types_data.ArrayScanData);
        array_scan.* = .{
            .input_scan = input_scan_data,
            .array_expr = array_expr_data,
            .element_column = element_column_data,
            .array_offset_column = array_offset_column_data,
            .is_outer = node.is_outer orelse false,
            .join_expr = join_expr_data,
        };
        return .{
            .type = .array,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .array_scan = array_scan,
        };
    }

    // ------------------------------------------------------------------
    // Expressions
    // ------------------------------------------------------------------

    /// Go ExtractExpressionData.
    pub fn ExtractExpressionData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        expr: *const pb.AnyResolvedExprProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const node = expr.node orelse return error.InvalidAST;
        switch (node) {
            .resolved_literal_node => |n| return self.extractLiteralData(alloc, n),
            .resolved_column_ref_node => |n| {
                const column = n.column orelse return error.InvalidAST;
                return newColumnExpressionData(alloc, column);
            },
            .resolved_function_call_base_node => |n| {
                const fc_node = n.node orelse return error.InvalidAST;
                switch (fc_node) {
                    .resolved_function_call_node => |fc| {
                        const base = fc.parent orelse return error.InvalidAST;
                        return self.extractFunctionCallData(alloc, base, ctx, false);
                    },
                    .resolved_non_scalar_function_call_base_node => |ns| {
                        const ns_node = ns.node orelse return error.InvalidAST;
                        switch (ns_node) {
                            .resolved_aggregate_function_call_node => |agg| return self.extractAggregateFunctionCallData(alloc, agg, ctx),
                            // Analytic function calls: deferred with the
                            // analytic scan.
                            .resolved_analytic_function_call_node => return error.Unimplemented,
                        }
                    },
                }
            },
            .resolved_cast_node => |n| return self.extractCastData(alloc, n, ctx),
            .resolved_subquery_expr_node => |n| return self.extractSubqueryData(alloc, n, ctx),
            .resolved_get_struct_field_node => |n| return self.extractGetStructFieldData(alloc, n, ctx),
            .resolved_make_struct_node => |n| return self.extractMakeStructData(alloc, n, ctx),
            // Parameter / ArgumentRef / DMLDefault / GetJsonField /
            // analytic: deferred to later tasks.
            .resolved_parameter_node,
            .resolved_argument_ref_node,
            .resolved_dmldefault_node,
            .resolved_get_json_field_node,
            => return error.Unimplemented,
            else => return error.UnsupportedNode, // Go: "unsupported expression node type"
        }
    }

    /// Go extractLiteralData.
    fn extractLiteralData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedLiteralProto,
    ) Error!ExpressionData {
        _ = self;
        const vwt = node.value orelse return error.InvalidAST;
        const type_proto = vwt.@"type" orelse return error.InvalidAST;
        const value_proto = vwt.value orelse return error.InvalidAST;

        const zetasqlite_value = try encoder.valueFromProto(alloc, value_proto, type_proto);

        const literal = try alloc.create(types_data.LiteralData);
        literal.* = .{
            .value = zetasqlite_value,
            .type_name = @tagName(type_proto.type_kind orelse .TYPE_UNKNOWN),
        };
        return .{ .type = .literal, .literal = literal };
    }

    /// Go extractFunctionCallData.
    fn extractFunctionCallData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedFunctionCallBaseProto,
        ctx: *TransformContext,
        is_window_func: bool,
    ) Error!ExpressionData {
        const raw_name = (node.function orelse return error.InvalidAST).name orelse
            return error.InvalidAST;
        const stripped = builtinGroupOf(raw_name);
        const is_builtin = stripped != null;
        // Go: fn.FullName(false).
        const original_func_name = stripped orelse raw_name;

        const func_name = try getZetasqliteFuncName(alloc, node, is_window_func);

        // Extract arguments.
        var arguments: std.ArrayList(ExpressionData) = .empty;
        for (node.argument_list) |arg| {
            try arguments.append(alloc, try self.ExtractExpressionData(alloc, arg, ctx));
        }

        // The argument-type/name signature is only consumed when
        // transforming user-defined (templated) function calls; builtins
        // skip it (the common case), exactly like Go.
        const signature = try alloc.create(types_data.FunctionSignature);
        signature.* = .{};
        if (!is_builtin) {
            const sig = node.signature orelse return error.InvalidAST;
            const args_info = try alloc.alloc(*types_data.ArgumentInfo, sig.argument.len);
            for (sig.argument, 0..) |arg, i| {
                const info = try alloc.create(types_data.ArgumentInfo);
                info.* = .{};
                if (arg.@"type") |tp| {
                    info.type = try spec.newTypeFromProto(alloc, tp);
                } else {
                    // Templated argument: carry the SignatureArgumentKind.
                    const t = try alloc.create(spec.Type);
                    t.* = .{ .signature_kind = @intFromEnum(arg.kind orelse .ARG_KIND_EXPR_FIXED) };
                    info.type = t;
                }
                if (arg.options) |opts| {
                    if (opts.argument_name) |name| info.name = name;
                }
                args_info[i] = info;
            }
            signature.arguments = args_info;
        }

        // Translate MIN_BY/MAX_BY to ANY_VALUE with HAVING MIN/MAX:
        // MIN_BY(x, y) -> ANY_VALUE(x HAVING MIN y).
        if (std.mem.eql(u8, original_func_name, "min_by") or
            std.mem.eql(u8, original_func_name, "max_by"))
        {
            if (arguments.items.len != 2) return error.UnsupportedFunction; // requires exactly 2 arguments
            const having_func: []const u8 = if (std.mem.eql(u8, original_func_name, "min_by"))
                "zetasqlite_having_min"
            else
                "zetasqlite_having_max";

            const having_args = try alloc.alloc(ExpressionData, 1);
            having_args[0] = arguments.items[1];
            const wrapped_args = try alloc.alloc(ExpressionData, 2);
            wrapped_args[0] = arguments.items[0]; // x - the value to return
            wrapped_args[1] = try types_data.newFunctionCallExpressionData(alloc, having_func, having_args);

            const fn_data = try alloc.create(types_data.FunctionCallData);
            fn_data.* = .{
                .name = "zetasqlite_any_value",
                .arguments = wrapped_args,
                .signature = signature,
            };
            return .{ .type = .function, .function = fn_data };
        }

        const fn_data = try alloc.create(types_data.FunctionCallData);
        fn_data.* = .{
            .name = func_name,
            .arguments = try arguments.toOwnedSlice(alloc),
            .signature = signature,
        };
        return .{ .type = .function, .function = fn_data };
    }

    /// Go extractAggregateFunctionCallData: base function call plus the
    /// aggregate modifiers encoded as trailing pseudo-function arguments
    /// (order matches Go: ORDER BY, DISTINCT, LIMIT, HAVING, IGNORE NULLS).
    fn extractAggregateFunctionCallData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedAggregateFunctionCallProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const non_scalar = node.parent orelse return error.InvalidAST;
        const base = non_scalar.parent orelse return error.InvalidAST;

        const base_data = try self.extractFunctionCallData(alloc, base, ctx, false);
        const function = base_data.function orelse return error.InvalidAST;

        var arguments: std.ArrayList(ExpressionData) = .empty;
        try arguments.appendSlice(alloc, function.arguments);

        for (node.order_by_item_list) |item| {
            const column_ref = item.column_ref orelse return error.InvalidAST;
            const column = column_ref.column orelse return error.InvalidAST;
            const order_item = try newColumnExpressionData(alloc, column);
            const is_descending = item.is_descending orelse false;

            const asc_literal = try alloc.create(types_data.LiteralData);
            asc_literal.* = .{ .value = .{ .bool = !is_descending } };
            const order_by_args = try alloc.alloc(ExpressionData, 2);
            order_by_args[0] = order_item;
            order_by_args[1] = .{ .type = .literal, .literal = asc_literal };
            try arguments.append(alloc, try types_data.newFunctionCallExpressionData(
                alloc,
                "zetasqlite_order_by",
                order_by_args,
            ));
        }

        if (non_scalar.distinct orelse false) {
            try arguments.append(alloc, try types_data.newFunctionCallExpressionData(
                alloc,
                "zetasqlite_distinct",
                &.{},
            ));
        }

        if (node.limit) |limit_expr| {
            const limit = try self.ExtractExpressionData(alloc, limit_expr, ctx);
            const limit_args = try alloc.alloc(ExpressionData, 1);
            limit_args[0] = limit;
            try arguments.append(alloc, try types_data.newFunctionCallExpressionData(
                alloc,
                "zetasqlite_limit",
                limit_args,
            ));
        }

        // Extract HAVING MAX/MIN modifier if present.
        if (node.having_modifier) |having_modifier| {
            const having_expr = having_modifier.having_expr orelse return error.InvalidAST;
            const having_expr_data = try self.ExtractExpressionData(alloc, having_expr, ctx);

            const having_func: []const u8 = switch (having_modifier.kind orelse .INVALID) {
                .MAX => "zetasqlite_having_max",
                .MIN => "zetasqlite_having_min",
                else => return error.UnsupportedNode, // Go: "unsupported having modifier kind"
            };
            const having_args = try alloc.alloc(ExpressionData, 1);
            having_args[0] = having_expr_data;
            try arguments.append(alloc, try types_data.newFunctionCallExpressionData(
                alloc,
                having_func,
                having_args,
            ));
        }

        switch (non_scalar.null_handling_modifier orelse .DEFAULT_NULL_HANDLING) {
            .IGNORE_NULLS => try arguments.append(alloc, try types_data.newFunctionCallExpressionData(
                alloc,
                "zetasqlite_ignore_nulls",
                &.{},
            )),
            else => {},
        }

        function.arguments = try arguments.toOwnedSlice(alloc);
        return base_data;
    }

    /// Go extractCastData.
    fn extractCastData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedCastProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const expr = node.expr orelse return error.InvalidAST;
        const expr_data = try self.ExtractExpressionData(alloc, expr, ctx);

        const parent = node.parent orelse return error.InvalidAST;
        const to_type_proto = parent.@"type" orelse return error.InvalidAST;

        const cast = try alloc.create(types_data.CastData);
        cast.* = .{
            .expression = expr_data,
            .from_type = try spec.newTypeFromProto(alloc, try exprTypeProto(expr)),
            .to_type = try spec.newTypeFromProto(alloc, to_type_proto),
            .return_null_on_err = node.return_null_on_error orelse false,
        };
        return .{ .type = .cast, .cast = cast };
    }

    /// Go extractSubqueryData.
    fn extractSubqueryData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedSubqueryExprProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const subquery_scan = node.subquery orelse return error.InvalidAST;
        const stmt_data = try self.ExtractScanData(alloc, subquery_scan, ctx);

        const subquery_data = try alloc.create(types_data.SubqueryData);
        subquery_data.* = .{
            .query = stmt_data,
            .subquery_type = node.subquery_type orelse .SCALAR,
        };

        if (node.in_expr) |in_expr| {
            const in_expr_data = try alloc.create(ExpressionData);
            in_expr_data.* = try self.ExtractExpressionData(alloc, in_expr, ctx);
            subquery_data.in_expr = in_expr_data;
        }

        return .{ .type = .subquery, .subquery = subquery_data };
    }

    /// Go extractGetStructFieldData: becomes
    /// zetasqlite_get_struct_field(expr, <field index literal>).
    fn extractGetStructFieldData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedGetStructFieldProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const expr = node.expr orelse return error.InvalidAST;
        const expr_data = try self.ExtractExpressionData(alloc, expr, ctx);

        const field_idx = node.field_idx orelse return error.InvalidAST;
        const idx_literal = try alloc.create(types_data.LiteralData);
        idx_literal.* = .{ .value = .{ .int = field_idx }, .type_name = "INT64" };

        const args = try alloc.alloc(ExpressionData, 2);
        args[0] = expr_data;
        args[1] = .{ .type = .literal, .literal = idx_literal };
        return types_data.newFunctionCallExpressionData(alloc, "zetasqlite_get_struct_field", args);
    }

    /// Go extractMakeStructData: becomes zetasqlite_make_struct(name1,
    /// value1, name2, value2, ...), field names from the struct type.
    fn extractMakeStructData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedMakeStructProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const parent = node.parent orelse return error.InvalidAST;
        const type_proto = parent.@"type" orelse return error.InvalidAST;
        const struct_type = type_proto.struct_type orelse return error.InvalidAST;
        if (struct_type.field.len != node.field_list.len) return error.InvalidAST;

        const field_args = try alloc.alloc(ExpressionData, node.field_list.len * 2);
        for (node.field_list, 0..) |field, i| {
            const field_name = struct_type.field[i].field_name orelse "";
            const name_literal = try alloc.create(types_data.LiteralData);
            name_literal.* = .{ .value = .{ .string = field_name }, .type_name = "STRING" };
            field_args[i * 2] = .{ .type = .literal, .literal = name_literal };
            field_args[i * 2 + 1] = try self.ExtractExpressionData(alloc, field, ctx);
        }

        return types_data.newFunctionCallExpressionData(alloc, "zetasqlite_make_struct", field_args);
    }
};

/// Unwraps AnyResolvedComputedColumnBaseProto down to the plain
/// ResolvedComputedColumnProto (deferred computed columns are not part of
/// the Go original's switch either).
fn computedColumnOf(
    any: *const pb.AnyResolvedComputedColumnBaseProto,
) Error!*pb.ResolvedComputedColumnProto {
    const node = any.node orelse return error.InvalidAST;
    switch (node) {
        .resolved_computed_column_impl_node => |impl| {
            const impl_node = impl.node orelse return error.InvalidAST;
            switch (impl_node) {
                .resolved_computed_column_node => |cc| return cc,
                .resolved_deferred_computed_column_node => return error.Unimplemented,
            }
        },
    }
}

// ----------------------------------------------------------------------
// Tests: golden extraction over the real analyzer.
// ----------------------------------------------------------------------

const testing = std.testing;
const analyzer_ffi = @import("../../analyzer_ffi.zig");

const TestHarness = struct {
    config: context.TransformConfig = .{},
    ctx: *TransformContext,
    extractor: NodeExtractor = .{},

    fn statementData(alloc: std.mem.Allocator, sql: [:0]const u8) !StatementData {
        const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, sql, 0, "{}");
        const config = try alloc.create(context.TransformConfig);
        config.* = .{};
        const ctx = try TransformContext.init(alloc, config);
        const extractor = NodeExtractor{};
        return extractor.ExtractStatementData(alloc, analyzed.node, ctx);
    }
};

test "extract SELECT 1 AS x" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc, "SELECT 1 AS x");
    try testing.expectEqual(types_data.StatementType.select, stmt.type);

    const select = stmt.select.?;
    // Go extractQueryStatementData: ProjectScan in FromClause, output
    // columns in SelectList.
    const from = select.from_clause.?;
    try testing.expectEqual(types_data.ScanType.project, from.type);
    const project = from.project_scan.?;
    try testing.expectEqual(types_data.ScanType.single_row, project.input_scan.type);

    // One computed column whose expression is the literal 1.
    try testing.expectEqual(@as(usize, 1), project.expr_list.len);
    const computed = project.expr_list[0];
    try testing.expectEqual(types_data.ExpressionType.literal, computed.expression.type);
    const literal = computed.expression.literal.?;
    try value_mod.expectValueEqual(.{ .int = 1 }, literal.value);
    try testing.expectEqualStrings("TYPE_INT64", literal.type_name);

    // The scan's output column and the statement's select list agree on "x".
    try testing.expectEqual(@as(usize, 1), from.column_list.len);
    try testing.expectEqualStrings("x", from.column_list[0].name);
    try testing.expectEqual(computed.column.?.id, from.column_list[0].id);

    try testing.expectEqual(@as(usize, 1), select.select_list.len);
    const item = select.select_list[0];
    try testing.expectEqualStrings("x", item.alias);
    try testing.expectEqual(types_data.ExpressionType.column, item.expression.type);
    try testing.expectEqualStrings("x", item.expression.column.?.column_name);
    try testing.expectEqual(from.column_list[0].id, item.expression.column.?.column_id);
}

test "extract SELECT 1 + 2 normalizes ZetaSQL:$add" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc, "SELECT 1 + 2");
    const project = stmt.select.?.from_clause.?.project_scan.?;
    try testing.expectEqual(@as(usize, 1), project.expr_list.len);

    const expr = project.expr_list[0].expression;
    try testing.expectEqual(types_data.ExpressionType.function, expr.type);
    const function = expr.function.?;
    try testing.expectEqualStrings("zetasqlite_add", function.name);
    try testing.expectEqual(@as(usize, 2), function.arguments.len);
    try value_mod.expectValueEqual(.{ .int = 1 }, function.arguments[0].literal.?.value);
    try value_mod.expectValueEqual(.{ .int = 2 }, function.arguments[1].literal.?.value);
    // Builtin: signature present but empty (Go skips arguments for builtins).
    try testing.expectEqual(@as(usize, 0), function.signature.?.arguments.len);
}

test "extract SELECT ABS(-3) normalizes ZetaSQL:abs" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc, "SELECT ABS(-3)");
    const expr = stmt.select.?.from_clause.?.project_scan.?.expr_list[0].expression;
    try testing.expectEqual(types_data.ExpressionType.function, expr.type);
    try testing.expectEqualStrings("zetasqlite_abs", expr.function.?.name);
}

test "extract SAFE.-prefixed call uses zetasqlite_safe prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc, "SELECT SAFE.ABS(-3)");
    const expr = stmt.select.?.from_clause.?.project_scan.?.expr_list[0].expression;
    try testing.expectEqual(types_data.ExpressionType.function, expr.type);
    try testing.expectEqualStrings("zetasqlite_safe_abs", expr.function.?.name);
}

test "extract COUNT(*) aggregate scan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(
        alloc,
        "SELECT COUNT(*) AS c FROM UNNEST([1, 2, 3]) AS x",
    );
    var from: *const ScanData = stmt.select.?.from_clause.?;
    while (from.type == .project) from = &from.project_scan.?.input_scan;
    try testing.expectEqual(types_data.ScanType.aggregate, from.type);
    const aggregate = from.aggregate_scan.?;
    try testing.expectEqual(types_data.ScanType.array, aggregate.input_scan.type);
    try testing.expectEqual(@as(usize, 1), aggregate.aggregate_list.len);
    const agg_expr = aggregate.aggregate_list[0].expression;
    try testing.expectEqual(types_data.ExpressionType.function, agg_expr.type);
    try testing.expectEqualStrings("zetasqlite_count_star", agg_expr.function.?.name);
}

test "extract aggregate modifiers as trailing pseudo-arguments" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(
        alloc,
        "SELECT ARRAY_AGG(DISTINCT x ORDER BY x DESC LIMIT 2) FROM UNNEST([1, 2, 3]) AS x",
    );
    var from: *const ScanData = stmt.select.?.from_clause.?;
    while (from.type == .project) from = &from.project_scan.?.input_scan;
    try testing.expectEqual(types_data.ScanType.aggregate, from.type);
    const function = from.aggregate_scan.?.aggregate_list[0].expression.function.?;
    try testing.expectEqualStrings("zetasqlite_array_agg", function.name);

    // Go order: base args, then ORDER BY, DISTINCT, LIMIT.
    try testing.expectEqual(@as(usize, 4), function.arguments.len);
    const order_by = function.arguments[1].function.?;
    try testing.expectEqualStrings("zetasqlite_order_by", order_by.name);
    try testing.expectEqual(@as(usize, 2), order_by.arguments.len);
    // Second arg is the ascending flag (!IsDescending -> false for DESC).
    try value_mod.expectValueEqual(.{ .bool = false }, order_by.arguments[1].literal.?.value);
    try testing.expectEqualStrings("zetasqlite_distinct", function.arguments[2].function.?.name);
    const limit = function.arguments[3].function.?;
    try testing.expectEqualStrings("zetasqlite_limit", limit.name);
    try value_mod.expectValueEqual(.{ .int = 2 }, limit.arguments[0].literal.?.value);
}

test "extract set operation UNION ALL" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc, "SELECT 1 AS a UNION ALL SELECT 2");
    const from = stmt.select.?.from_clause.?;
    try testing.expectEqual(types_data.ScanType.set_op, from.type);
    const set_op = from.set_operation_scan.?;
    try testing.expectEqualStrings("UNION", set_op.type);
    try testing.expectEqualStrings("ALL", set_op.modifier);
    try testing.expectEqual(@as(usize, 2), set_op.items.len);
    // Item select-list aliases use the outer scan's output column names.
    const first = set_op.items[0].select.?;
    try testing.expectEqual(@as(usize, 1), first.select_list.len);
    try testing.expectEqualStrings("a", first.select_list[0].alias);
    const second = set_op.items[1].select.?;
    try testing.expectEqualStrings("a", second.select_list[0].alias);
}

test "extract WITH scan and WITH ref" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(
        alloc,
        "WITH t AS (SELECT 1 AS a) SELECT a FROM t",
    );
    const from = stmt.select.?.from_clause.?;
    try testing.expectEqual(types_data.ScanType.with, from.type);
    const with_scan = from.with_scan.?;
    try testing.expect(!with_scan.recursive);
    try testing.expectEqual(@as(usize, 1), with_scan.with_entry_list.len);
    const entry = with_scan.with_entry_list[0];
    try testing.expectEqualStrings("t", entry.with_query_name);
    try testing.expectEqual(types_data.ScanType.project, entry.with_subquery.type);
    try testing.expectEqual(@as(usize, 1), entry.column_list.len);
    try testing.expectEqualStrings("a", entry.column_list[0].name);

    // The main query references the CTE through a with-ref scan.
    var scan: *const ScanData = &with_scan.query;
    while (scan.type == .project) scan = &scan.project_scan.?.input_scan;
    try testing.expectEqual(types_data.ScanType.with_ref, scan.type);
    try testing.expectEqualStrings("t", scan.with_ref_scan.?.with_query_name);
}

test "extract UNNEST array scan" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(
        alloc,
        "SELECT x FROM UNNEST([1, 2, 3]) AS x WITH OFFSET off",
    );
    var from: *const ScanData = stmt.select.?.from_clause.?;
    while (from.type == .project) from = &from.project_scan.?.input_scan;
    try testing.expectEqual(types_data.ScanType.array, from.type);
    const array_scan = from.array_scan.?;
    try testing.expectEqual(types_data.ExpressionType.literal, array_scan.array_expr.type);
    try testing.expectEqualStrings("x", array_scan.element_column.?.name);
    try testing.expectEqualStrings("off", array_scan.array_offset_column.?.name);
    try testing.expect(!array_scan.is_outer);
}

test "extract filter, order by and limit scans" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(
        alloc,
        "SELECT x FROM UNNEST([3, 1, 2]) AS x WHERE x > 1 ORDER BY x DESC LIMIT 1 OFFSET 1",
    );
    var scan: *const ScanData = stmt.select.?.from_clause.?;
    try testing.expectEqual(types_data.ScanType.limit, scan.type);
    const limit = scan.limit_scan.?;
    try value_mod.expectValueEqual(.{ .int = 1 }, limit.count.literal.?.value);
    try value_mod.expectValueEqual(.{ .int = 1 }, limit.offset.?.literal.?.value);

    scan = &limit.input_scan;
    try testing.expectEqual(types_data.ScanType.order_by, scan.type);
    const order_by = scan.order_by_scan.?;
    try testing.expectEqual(@as(usize, 1), order_by.order_by_columns.len);
    try testing.expect(order_by.order_by_columns[0].is_descending);

    scan = &order_by.input_scan;
    while (scan.type == .project) scan = &scan.project_scan.?.input_scan;
    try testing.expectEqual(types_data.ScanType.filter, scan.type);
    const filter = scan.filter_scan.?;
    try testing.expectEqual(types_data.ExpressionType.function, filter.filter_expr.type);
    try testing.expectEqualStrings("zetasqlite_greater", filter.filter_expr.function.?.name);
}

test "extract scalar subquery and cast" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc, "SELECT (SELECT 1)");
    const exprs = stmt.select.?.from_clause.?.project_scan.?.expr_list;
    try testing.expectEqual(@as(usize, 1), exprs.len);

    const sub = exprs[0].expression;
    try testing.expectEqual(types_data.ExpressionType.subquery, sub.type);
    try testing.expectEqual(pb.ResolvedSubqueryExprEnums_SubqueryType.SCALAR, sub.subquery.?.subquery_type);
    try testing.expectEqual(types_data.ScanType.project, sub.subquery.?.query.type);

    // CAST over a literal is constant-folded by the analyzer, so cast a
    // column instead.
    const cast_stmt = try TestHarness.statementData(
        alloc,
        "SELECT CAST(x AS STRING) FROM UNNEST([1, 2, 3]) AS x",
    );
    const cast_exprs = cast_stmt.select.?.from_clause.?.project_scan.?.expr_list;
    const cast_expr = cast_exprs[0].expression;
    try testing.expectEqual(types_data.ExpressionType.cast, cast_expr.type);
    const cast = cast_expr.cast.?;
    try testing.expectEqual(pb.TypeKind.TYPE_INT64, cast.from_type.?.typeKind());
    try testing.expectEqual(pb.TypeKind.TYPE_STRING, cast.to_type.?.typeKind());
    try testing.expectEqual(types_data.ExpressionType.column, cast.expression.type);
    try testing.expectEqualStrings("x", cast.expression.column.?.column_name);
}

test "extract STRUCT field access becomes zetasqlite_get_struct_field" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc, "SELECT STRUCT(1 AS a, 'x' AS b).b");
    const expr = stmt.select.?.from_clause.?.project_scan.?.expr_list[0].expression;
    try testing.expectEqual(types_data.ExpressionType.function, expr.type);
    const function = expr.function.?;
    try testing.expectEqualStrings("zetasqlite_get_struct_field", function.name);
    try testing.expectEqual(@as(usize, 2), function.arguments.len);
    try value_mod.expectValueEqual(.{ .int = 1 }, function.arguments[1].literal.?.value);
}
