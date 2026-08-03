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
//! - statements: ResolvedQueryStmt, Insert/Update/Delete, CreateTableAsSelect,
//!   CreateView, Drop/DropFunction (Merge deferred; plain CreateTable is
//!   handled by the driver action via spec.SQLiteSchema, like Go)
//! - scans: SingleRow, Project, Filter, Join, Aggregate (no grouping sets),
//!   OrderBy, LimitOffset, SetOperation, With/WithRef/WithEntry, Array,
//!   Analytic
//! - expressions: Literal, ColumnRef, FunctionCall, AggregateFunctionCall,
//!   AnalyticFunctionCall, Cast, SubqueryExpr, ComputedColumn, OutputColumn,
//!   GetStructField, MakeStruct

const std = @import("std");
const pb = @import("../../proto/resolved_ast.zig");
const value_mod = @import("../value.zig");
const encoder = @import("../encoder.zig");
const spec = @import("../spec.zig");
const types_data = @import("types_data.zig");
const context = @import("context.zig");

pub const Error = types_data.Error;

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
    .{"add"},                          .{"subtract"},             .{"multiply"},
    .{"divide"},                       .{"equal"},                .{"not_equal"},
    .{"greater"},                      .{"greater_or_equal"},     .{"less"},
    .{"less_or_equal"},                .{"bitwise_not"},          .{"bitwise_left_shift"},
    .{"bitwise_right_shift"},          .{"bitwise_and"},          .{"bitwise_or"},
    .{"bitwise_xor"},                  .{"in_array"},             .{"get_struct_field"},
    .{"get_json_field"},               .{"subscript"},            .{"array_at_offset"},
    .{"array_at_ordinal"},             .{"safe_negate"},          .{"is_distinct_from"},
    .{"is_not_distinct_from"},         .{"session_user"},         .{"generate_uuid"},
    .{"error"},                        .{"current_date"},         .{"extract"},
    .{"extract_date"},                 .{"date"},                 .{"date_add"},
    .{"date_sub"},                     .{"date_diff"},            .{"date_trunc"},
    .{"date_from_unix_date"},          .{"format_date"},          .{"last_day"},
    .{"parse_date"},                   .{"unix_date"},            .{"current_datetime"},
    .{"datetime"},                     .{"datetime_add"},         .{"datetime_sub"},
    .{"datetime_diff"},                .{"datetime_trunc"},       .{"format_datetime"},
    .{"parse_datetime"},               .{"current_time"},         .{"time"},
    .{"time_add"},                     .{"time_sub"},             .{"time_diff"},
    .{"time_trunc"},                   .{"format_time"},          .{"parse_time"},
    .{"current_timestamp"},            .{"string"},               .{"timestamp"},
    .{"timestamp_add"},                .{"timestamp_sub"},        .{"timestamp_diff"},
    .{"timestamp_trunc"},              .{"format_timestamp"},     .{"parse_timestamp"},
    .{"timestamp_seconds"},            .{"timestamp_millis"},     .{"timestamp_micros"},
    .{"unix_seconds"},                 .{"unix_millis"},          .{"unix_micros"},
    .{"like"},                         .{"between"},              .{"in"},
    .{"is_null"},                      .{"is_true"},              .{"is_false"},
    .{"not"},                          .{"and"},                  .{"or"},
    .{"coalesce"},                     .{"if"},                   .{"ifnull"},
    .{"nullif"},                       .{"length"},               .{"cast"},
    .{"interval"},                     .{"make_interval"},        .{"justify_days"},
    .{"justify_hours"},                .{"justify_interval"},     .{"parse_numeric"},
    .{"parse_bignumeric"},             .{"farm_fingerprint"},     .{"md5"},
    .{"sha1"},                         .{"sha256"},               .{"sha512"},
    .{"ascii"},                        .{"byte_length"},          .{"char_length"},
    .{"chr"},                          .{"code_points_to_bytes"}, .{"code_points_to_string"},
    .{"collate"},                      .{"concat"},               .{"contains_substr"},
    .{"ends_with"},                    .{"format"},               .{"from_base32"},
    .{"from_base64"},                  .{"from_hex"},             .{"initcap"},
    .{"instr"},                        .{"left"},                 .{"lpad"},
    .{"lower"},                        .{"ltrim"},                .{"normalize"},
    .{"normalize_and_casefold"},       .{"regexp_contains"},      .{"regexp_extract"},
    .{"regexp_extract_all"},           .{"regexp_instr"},         .{"regexp_replace"},
    .{"replace"},                      .{"repeat"},               .{"reverse"},
    .{"right"},                        .{"rpad"},                 .{"rtrim"},
    .{"safe_convert_bytes_to_string"}, .{"soundex"},              .{"split"},
    .{"starts_with"},                  .{"strpos"},               .{"substr"},
    .{"to_base32"},                    .{"to_base64"},            .{"to_code_points"},
    .{"to_hex"},                       .{"translate"},            .{"trim"},
    .{"unicode"},                      .{"upper"},                .{"json_extract"},
    .{"json_extract_scalar"},          .{"json_extract_array"},   .{"json_extract_string_array"},
    .{"json_query"},                   .{"json_value"},           .{"json_query_array"},
    .{"json_value_array"},             .{"parse_json"},           .{"to_json"},
    .{"to_json_string"},               .{"bool"},                 .{"int64"},
    .{"double"},                       .{"float64"},              .{"json_type"},
    .{"abs"},                          .{"sign"},                 .{"is_inf"},
    .{"is_nan"},                       .{"ieee_divide"},          .{"rand"},
    .{"sqrt"},                         .{"pow"},                  .{"power"},
    .{"exp"},                          .{"ln"},                   .{"log"},
    .{"log10"},                        .{"greatest"},             .{"least"},
    .{"div"},                          .{"mod"},                  .{"round"},
    .{"trunc"},                        .{"ceil"},                 .{"ceiling"},
    .{"floor"},                        .{"cos"},                  .{"cosh"},
    .{"acos"},                         .{"acosh"},                .{"sin"},
    .{"sinh"},                         .{"asin"},                 .{"asinh"},
    .{"tan"},                          .{"tanh"},                 .{"atan"},
    .{"atanh"},                        .{"atan2"},                .{"range_bucket"},
    .{"array_concat"},                 .{"array_first"},          .{"array_last"},
    .{"array_slice"},                  .{"array_length"},         .{"array_to_string"},
    .{"generate_array"},               .{"generate_date_array"},  .{"generate_timestamp_array"},
    .{"array_reverse"},                .{"make_array"},           .{"make_struct"},
    .{"hll_count_extract"},            .{"bit_count"},            .{"distinct"},
    .{"limit"},                        .{"order_by"},             .{"ignore_nulls"},
    .{"having_max"},                   .{"having_min"},           .{"eval_javascript"},
    .{"net_host"},                     .{"net_ip_from_string"},   .{"net_ip_net_mask"},
    .{"net_ip_to_string"},             .{"net_ip_trunc"},         .{"net_ipv4_from_int64"},
    .{"net_ipv4_to_int64"},            .{"net_public_suffix"},    .{"net_reg_domain"},
    .{"net_safe_ip_from_string"},
});

/// internal/function_register.go aggregateFuncs names.
const aggregate_func_names = std.StaticStringMap(void).initComptime(.{
    .{"array"},            .{"any_value"},        .{"array_agg"},
    .{"array_concat_agg"}, .{"avg"},              .{"count"},
    .{"count_star"},       .{"bit_and"},          .{"bit_or"},
    .{"bit_xor"},          .{"countif"},          .{"logical_and"},
    .{"logical_or"},       .{"max"},              .{"min"},
    .{"string_agg"},       .{"sum"},              .{"corr"},
    .{"covar_pop"},        .{"covar_samp"},       .{"stddev_pop"},
    .{"stddev_samp"},      .{"stddev"},           .{"var_pop"},
    .{"var_samp"},         .{"variance"},         .{"approx_count_distinct"},
    .{"approx_quantiles"}, .{"approx_top_count"}, .{"approx_top_sum"},
    .{"hll_count_init"},   .{"hll_count_merge"},  .{"hll_count_merge_partial"},
});

/// internal/function_register.go windowFuncs names.
const window_func_names = std.StaticStringMap(void).initComptime(.{
    .{"any_value"},       .{"array_agg"},   .{"avg"},
    .{"count"},           .{"count_star"},  .{"countif"},
    .{"logical_and"},     .{"logical_or"},  .{"max"},
    .{"min"},             .{"string_agg"},  .{"sum"},
    .{"corr"},            .{"covar_pop"},   .{"covar_samp"},
    .{"stddev_pop"},      .{"stddev_samp"}, .{"stddev"},
    .{"var_pop"},         .{"var_samp"},    .{"variance"},
    .{"first_value"},     .{"last_value"},  .{"nth_value"},
    .{"lead"},            .{"lag"},         .{"percentile_cont"},
    .{"percentile_disc"}, .{"rank"},        .{"dense_rank"},
    .{"percent_rank"},    .{"cume_dist"},   .{"ntile"},
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

/// Go fn.FullName(false): strips the "<group>:" prefix regardless of group.
/// Catalog-registered UDFs carry an empty group, so FunctionRefProto.name is
/// ":customfunc" — the colon must go or the SQL is unparseable.
fn stripFunctionGroup(raw_name: []const u8) []const u8 {
    if (builtinGroupOf(raw_name)) |rest| return rest;
    if (std.mem.indexOfScalar(u8, raw_name, ':')) |i| return raw_name[i + 1 ..];
    return raw_name;
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
    const is_builtin = builtinGroupOf(raw_name) != null;
    const full_name = stripFunctionGroup(raw_name);

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

/// Go NamePath.format with an empty base path (the driver holds no
/// WithNamePath state): normalizePath (split each segment on ".") then
/// formatPath ("_"-join) — equivalent to joining with "_" and replacing
/// any remaining dots.
pub fn formatNamePath(alloc: std.mem.Allocator, path: []const []const u8) error{OutOfMemory}![]u8 {
    const joined = try std.mem.join(alloc, "_", path);
    for (joined) |*c| {
        if (c.* == '.') c.* = '_';
    }
    return joined;
}

// ----------------------------------------------------------------------
// Window-frame helpers (Go: getWindowBoundaryTypeData / windowFuncFixedRanges)
// ----------------------------------------------------------------------

/// Go getWindowBoundaryTypeData: boundary enum + optional offset literal ->
/// FrameBoundData (allocated; Go returns it by value).
fn getWindowBoundaryTypeData(
    alloc: std.mem.Allocator,
    boundary_type: pb.ResolvedWindowFrameExprEnums_BoundaryType,
    literal: ExpressionData,
) Error!*types_data.FrameBoundData {
    const bound = try alloc.create(types_data.FrameBoundData);
    bound.* = switch (boundary_type) {
        .UNBOUNDED_PRECEDING => .{ .type = "UNBOUNDED PRECEDING" },
        .OFFSET_PRECEDING => .{ .type = "PRECEDING", .offset = literal },
        .CURRENT_ROW => .{ .type = "CURRENT ROW" },
        .OFFSET_FOLLOWING => .{ .type = "FOLLOWING", .offset = literal },
        .UNBOUNDED_FOLLOWING => .{ .type = "UNBOUNDED FOLLOWING" },
        else => .{}, // Go: falls through to FrameBoundData{}
    };
    return bound;
}

/// One entry of Go's windowFuncFixedRanges map (comptime-friendly shape; the
/// cume_dist offset literal is materialized in windowFuncFixedRange).
const FixedRange = struct {
    unit: []const u8,
    start: []const u8,
    start_offset_int: ?i64 = null,
    end: []const u8,
};

/// Go windowFuncFixedRanges: window functions whose SQLite frame is fixed by
/// the runtime UDF's semantics; a user-supplied framing clause is an error.
const window_func_fixed_ranges = std.StaticStringMap(FixedRange).initComptime(.{
    .{ "zetasqlite_window_ntile", FixedRange{
        .unit = "ROWS",
        .start = "CURRENT ROW",
        .end = "UNBOUNDED FOLLOWING",
    } },
    .{ "zetasqlite_window_cume_dist", FixedRange{
        .unit = "GROUPS",
        .start = "FOLLOWING",
        .start_offset_int = 1,
        .end = "UNBOUNDED FOLLOWING",
    } },
    .{ "zetasqlite_window_dense_rank", FixedRange{
        .unit = "RANGE",
        .start = "UNBOUNDED PRECEDING",
        .end = "CURRENT ROW",
    } },
    .{ "zetasqlite_window_rank", FixedRange{
        .unit = "GROUPS",
        .start = "UNBOUNDED PRECEDING",
        .end = "CURRENT ROW EXCLUDE TIES",
    } },
    .{ "zetasqlite_window_percent_rank", FixedRange{
        .unit = "GROUPS",
        .start = "CURRENT ROW",
        .end = "UNBOUNDED FOLLOWING",
    } },
    .{ "zetasqlite_window_row_number", FixedRange{
        .unit = "ROWS",
        .start = "UNBOUNDED PRECEDING",
        .end = "CURRENT ROW",
    } },
    .{ "zetasqlite_window_lag", FixedRange{
        .unit = "ROWS",
        .start = "UNBOUNDED PRECEDING",
        .end = "CURRENT ROW",
    } },
    .{ "zetasqlite_window_lead", FixedRange{
        .unit = "ROWS",
        .start = "CURRENT ROW",
        .end = "UNBOUNDED FOLLOWING",
    } },
});

/// Materializes a windowFuncFixedRanges entry as FrameClauseData, or null
/// when the function has no fixed range (Go: map lookup miss).
fn windowFuncFixedRange(
    alloc: std.mem.Allocator,
    func_name: []const u8,
) Error!?*types_data.FrameClauseData {
    const fixed = window_func_fixed_ranges.get(func_name) orelse return null;

    const start = try alloc.create(types_data.FrameBoundData);
    start.* = .{ .type = fixed.start };
    if (fixed.start_offset_int) |offset| {
        // Go: Offset: ExpressionData{Type: Literal, Literal: &LiteralData{
        // Value: IntValue(1)}} (cume_dist's `1 FOLLOWING` GROUPS bound).
        const literal = try alloc.create(types_data.LiteralData);
        literal.* = .{ .value = .{ .int = offset } };
        start.offset = .{ .type = .literal, .literal = literal };
    }
    const end = try alloc.create(types_data.FrameBoundData);
    end.* = .{ .type = fixed.end };

    const clause = try alloc.create(types_data.FrameClauseData);
    clause.* = .{ .unit = fixed.unit, .start = start, .end = end };
    return clause;
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
    if (c.type) |tp| {
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
        .type = if (column.type) |tp| try spec.newTypeFromProto(alloc, tp) else null,
    };
    return .{ .type = .column, .column = ref };
}

// ----------------------------------------------------------------------
// GROUP BY GROUPING SETS / ROLLUP / CUBE
//
// The resolved AST keeps ROLLUP and CUBE as their own nodes; both are defined
// as shorthand for a list of grouping sets (query-syntax.md #group_by_rollup,
// #group_by_cube), and expanding them here means the transformer only ever
// sees the one flat form it already lowers.
// ----------------------------------------------------------------------

/// Ceiling on CUBE's grouping elements. Each generated set becomes its own
/// SELECT in a UNION ALL, so 2^n is emitted SQL, not a bitmask — 10 is already
/// 1024 branches. Beyond it, refusing beats generating a query no engine runs.
const max_cube_groups = 10;

/// One grouping set, from the columns it groups by. An empty list is the
/// grand-total set.
fn appendGroupingSet(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*types_data.GroupingSetData),
    column_refs: []const *pb.ResolvedColumnRefProto,
) Error!void {
    var items: std.ArrayList(*types_data.ComputedColumnData) = .empty;
    for (column_refs) |ref| {
        const column = ref.column orelse return error.InvalidAST;
        const item = try alloc.create(types_data.ComputedColumnData);
        item.* = .{
            .column = try extractColumnData(alloc, column),
            .expression = try newColumnExpressionData(alloc, column),
        };
        try items.append(alloc, item);
    }
    const gs = try alloc.create(types_data.GroupingSetData);
    gs.* = .{ .group_by_columns = try items.toOwnedSlice(alloc) };
    try out.append(alloc, gs);
}

/// One grouping set from a selection of ROLLUP/CUBE groups, flattened. A group
/// is a parenthesised item — the `(b, c)` in `ROLLUP(a, (b, c))` — which enters
/// and leaves a grouping set whole.
fn appendMultiColumnSet(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*types_data.GroupingSetData),
    groups: []const *pb.ResolvedGroupingSetMultiColumnProto,
) Error!void {
    var refs: std.ArrayList(*pb.ResolvedColumnRefProto) = .empty;
    for (groups) |g| try refs.appendSlice(alloc, g.column_list);
    try appendGroupingSet(alloc, out, refs.items);
}

/// ROLLUP(g1, ..., gn) is n+1 grouping sets: every prefix of the group list,
/// longest first, ending with the grand total. The docs give ROLLUP(b, c) as
/// (b, c), (b), ().
fn expandRollup(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*types_data.GroupingSetData),
    groups: []const *pb.ResolvedGroupingSetMultiColumnProto,
) Error!void {
    var len = groups.len + 1;
    while (len > 0) {
        len -= 1;
        try appendMultiColumnSet(alloc, out, groups[0..len]);
    }
}

/// CUBE(g1, ..., gn) is 2^n grouping sets: every subset. The docs enumerate
/// CUBE(a, b, c) as (a,b,c) (a,b) (a,c) (a) (b,c) (b) (c) (), which is the
/// subset masks counted down with the *first* group as the high bit — so the
/// single-group case comes out (a), (), the same list ROLLUP(a) produces.
fn expandCube(
    alloc: std.mem.Allocator,
    out: *std.ArrayList(*types_data.GroupingSetData),
    groups: []const *pb.ResolvedGroupingSetMultiColumnProto,
) Error!void {
    if (groups.len > max_cube_groups) return error.UnsupportedNode;
    var selected: std.ArrayList(*pb.ResolvedGroupingSetMultiColumnProto) = .empty;
    var mask: usize = @as(usize, 1) << @as(u6, @intCast(groups.len));
    while (mask > 0) {
        mask -= 1;
        selected.clearRetainingCapacity();
        for (groups, 0..) |g, i| {
            const bit = @as(usize, 1) << @as(u6, @intCast(groups.len - 1 - i));
            if (mask & bit != 0) try selected.append(alloc, g);
        }
        try appendMultiColumnSet(alloc, out, selected.items);
    }
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
    return p.type orelse error.InvalidAST;
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
            const parent: ?*pb.ResolvedNonScalarFunctionCallBaseProto = switch (ns_node) {
                .resolved_aggregate_function_call_node => |agg| agg.parent,
                .resolved_analytic_function_call_node => |an| an.parent,
            };
            const non_scalar = parent orelse return error.InvalidAST;
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
            .resolved_create_statement_node => |n| return self.extractCreateStatementData(
                alloc,
                n,
                ctx,
            ),
            .resolved_insert_stmt_node => |n| return self.extractInsertStatementData(alloc, n, ctx),
            .resolved_update_stmt_node => |n| return self.extractUpdateStatementData(alloc, n, ctx),
            .resolved_delete_stmt_node => |n| return self.extractDeleteStatementData(alloc, n, ctx),
            .resolved_drop_stmt_node => |n| return extractDropStatementData(alloc, n),
            .resolved_drop_function_stmt_node => |n| return extractDropFunctionStatementData(
                alloc,
                n,
            ),
            .resolved_merge_stmt_node => |n| return self.extractMergeStatementData(alloc, n, ctx),
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

        const select_items = try alloc.alloc(
            *types_data.SelectItemData,
            node.output_column_list.len,
        );
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

    /// Go ExtractStatementData's ResolvedCreateTableStmt /
    /// ResolvedCreateTableAsSelectStmt / ResolvedCreateViewStmt cases,
    /// dispatched through the proto union wrappers.
    fn extractCreateStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        cs: *const pb.AnyResolvedCreateStatementProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const node = cs.node orelse return error.InvalidAST;
        switch (node) {
            .resolved_create_table_stmt_base_node => |base_any| {
                const base_node = base_any.node orelse return error.InvalidAST;
                switch (base_node) {
                    .resolved_create_table_as_select_stmt_node => |n| {
                        return self.extractCreateTableAsSelectStatementData(alloc, n, ctx);
                    },
                    // Go extractCreateTableStatementData: "create table
                    // statement extraction not implemented" (handled by
                    // spec.SQLiteSchema in the driver action instead).
                    .resolved_create_table_stmt_node => return error.Unimplemented,
                    else => return error.UnsupportedNode,
                }
            },
            .resolved_create_view_base_node => |vb_any| {
                const vb_node = vb_any.node orelse return error.InvalidAST;
                switch (vb_node) {
                    .resolved_create_view_stmt_node => |n| {
                        return self.extractCreateViewStatementData(alloc, n, ctx);
                    },
                    else => return error.UnsupportedNode,
                }
            },
            // CREATE FUNCTION and the rest: not statement-extracted in Go
            // either (functions go through newFunctionSpec).
            else => return error.UnsupportedNode,
        }
    }

    /// Go extractInsertStatementData.
    fn extractInsertStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedInsertStmtProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const table_scan = node.table_scan orelse return error.InvalidAST;
        // Go getTableName: the resolved Table carries the canonical name it
        // was registered under in the catalog.
        const table_name = (table_scan.table orelse return error.InvalidAST).name orelse
            return error.InvalidAST;

        const columns = try alloc.alloc([]const u8, node.insert_column_list.len);
        for (node.insert_column_list, 0..) |col, i| {
            columns[i] = col.name orelse "";
        }

        const insert_data = try alloc.create(types_data.InsertData);
        insert_data.* = .{ .table_name = table_name, .columns = columns };

        if (node.query) |query_node| {
            // INSERT ... SELECT.
            const query_scan = try self.ExtractScanData(alloc, query_node, ctx);
            const query_column_list = try scanColumnListOf(query_node);

            const select_items = try alloc.alloc(*types_data.SelectItemData, query_column_list.len);
            for (query_column_list, 0..) |col, i| {
                const item = try alloc.create(types_data.SelectItemData);
                item.* = .{
                    .expression = try newColumnExpressionData(alloc, col),
                    .alias = col.name orelse "",
                };
                select_items[i] = item;
            }

            const from_clause = try alloc.create(ScanData);
            from_clause.* = query_scan;
            const select = try alloc.create(types_data.SelectData);
            select.* = .{ .select_list = select_items, .from_clause = from_clause };
            insert_data.query = select;
        } else {
            // INSERT ... VALUES. Go routes each ResolvedDMLValue through
            // ExtractExpressionData's DMLValue case (unwrap .Value()).
            const values = try alloc.alloc([]const ExpressionData, node.row_list.len);
            for (node.row_list, 0..) |row, i| {
                const row_values = try alloc.alloc(ExpressionData, row.value_list.len);
                for (row.value_list, 0..) |dml_value, j| {
                    const value_expr = dml_value.value orelse return error.InvalidAST;
                    row_values[j] = try self.ExtractExpressionData(alloc, value_expr, ctx);
                }
                values[i] = row_values;
            }
            insert_data.values = values;
        }

        return .{ .type = .insert, .insert = insert_data };
    }

    /// Go extractUpdateStatementData.
    fn extractUpdateStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedUpdateStmtProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const table_scan_node = node.table_scan orelse return error.InvalidAST;
        const table_name = (table_scan_node.table orelse return error.InvalidAST).name orelse
            return error.InvalidAST;

        // Table scan data provides column info for WHERE / SET resolution.
        const table_scan = try alloc.create(ScanData);
        table_scan.* = try extractTableScanData(alloc, table_scan_node);

        const set_items = try alloc.alloc(*types_data.SetItemData, node.update_item_list.len);
        for (node.update_item_list, 0..) |item, i| {
            const target = item.target orelse return error.InvalidAST;
            const target_data = try self.ExtractExpressionData(alloc, target, ctx);

            const set_value = item.set_value orelse return error.InvalidAST;
            const value_expr = set_value.value orelse return error.InvalidAST;
            const value_data = try self.ExtractExpressionData(alloc, value_expr, ctx);

            // Go: column name from the target column ref, else fallback.
            var column_name: []const u8 = "unknown_column";
            if (target_data.type == .column) {
                if (target_data.column) |col_ref| column_name = col_ref.column_name;
            }

            const set_item = try alloc.create(types_data.SetItemData);
            set_item.* = .{ .column = column_name, .value = value_data };
            set_items[i] = set_item;
        }

        var where_clause: ?*ExpressionData = null;
        if (node.where_expr) |where_expr| {
            const where_data = try alloc.create(ExpressionData);
            where_data.* = try self.ExtractExpressionData(alloc, where_expr, ctx);
            where_clause = where_data;
        }

        var from_clause: ?*ScanData = null;
        if (node.from_scan) |from_scan| {
            const from_data = try alloc.create(ScanData);
            from_data.* = try self.ExtractScanData(alloc, from_scan, ctx);
            from_clause = from_data;
        }

        const update_data = try alloc.create(types_data.UpdateData);
        update_data.* = .{
            .table_name = table_name,
            .table_scan = table_scan,
            .set_items = set_items,
            .from_clause = from_clause,
            .where_clause = where_clause,
        };
        return .{ .type = .update, .update = update_data };
    }

    /// Go extractDeleteStatementData.
    fn extractDeleteStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedDeleteStmtProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const table_scan_node = node.table_scan orelse return error.InvalidAST;
        const table_name = (table_scan_node.table orelse return error.InvalidAST).name orelse
            return error.InvalidAST;

        const table_scan = try alloc.create(ScanData);
        table_scan.* = try extractTableScanData(alloc, table_scan_node);

        var where_clause: ?*ExpressionData = null;
        if (node.where_expr) |where_expr| {
            const where_data = try alloc.create(ExpressionData);
            where_data.* = try self.ExtractExpressionData(alloc, where_expr, ctx);
            where_clause = where_data;
        }

        const delete_data = try alloc.create(types_data.DeleteData);
        delete_data.* = .{
            .table_name = table_name,
            .table_scan = table_scan,
            .where_clause = where_clause,
        };
        return .{ .type = .delete, .delete = delete_data };
    }

    /// Go extractMergeStatementData.
    fn extractMergeStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedMergeStmtProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const table_scan_node = node.table_scan orelse return error.InvalidAST;
        // Go getTableName: the resolved table's registered name.
        const target_table_name = (table_scan_node.table orelse return error.InvalidAST).name orelse
            return error.InvalidAST;

        // Extract target table scan data.
        const target_scan = try alloc.create(ScanData);
        target_scan.* = try extractTableScanData(alloc, table_scan_node);

        // Extract source scan data.
        const from_scan = node.from_scan orelse return error.InvalidAST;
        const source_scan = try alloc.create(ScanData);
        source_scan.* = try self.ExtractScanData(alloc, from_scan, ctx);

        // Extract merge expression (typically an equality condition).
        const merge_expr_node = node.merge_expr orelse return error.InvalidAST;
        const merge_expr_data = try self.ExtractExpressionData(alloc, merge_expr_node, ctx);

        // Extract WHEN clauses.
        var when_clauses: std.ArrayList(*types_data.MergeWhenClauseData) = .empty;
        for (node.when_clause_list) |when| {
            const when_data = try alloc.create(types_data.MergeWhenClauseData);
            when_data.* = .{
                .match_type = when.match_type orelse .MATCHED,
                .action_type = when.action_type orelse .INSERT,
            };

            // Extract condition if present.
            if (when.match_expr) |match_expr| {
                const condition = try alloc.create(ExpressionData);
                condition.* = try self.ExtractExpressionData(alloc, match_expr, ctx);
                when_data.condition = condition;
            }

            switch (when_data.action_type) {
                .INSERT => {
                    // Extract INSERT columns.
                    const columns = try alloc.alloc(*ColumnData, when.insert_column_list.len);
                    for (when.insert_column_list, 0..) |col, i| {
                        const column_data = try alloc.create(ColumnData);
                        column_data.* = .{
                            .id = col.column_id orelse 0,
                            .name = col.name orelse "",
                        };
                        columns[i] = column_data;
                    }
                    when_data.insert_columns = columns;

                    // Extract INSERT values.
                    if (when.insert_row) |insert_row| {
                        const values = try alloc.alloc(ExpressionData, insert_row.value_list.len);
                        for (insert_row.value_list, 0..) |dml_value, i| {
                            // Go ExtractExpressionData's DMLValue case
                            // (unwrap .Value()).
                            const value_expr = dml_value.value orelse return error.InvalidAST;
                            values[i] = try self.ExtractExpressionData(alloc, value_expr, ctx);
                        }
                        when_data.insert_values = values;
                    }
                },
                .UPDATE => {
                    // Extract UPDATE SET items.
                    const set_items = try alloc.alloc(
                        *types_data.SetItemData,
                        when.update_item_list.len,
                    );
                    for (when.update_item_list, 0..) |item, i| {
                        // Extract target column name (only ColumnRef targets,
                        // like the Go original).
                        var column_name: []const u8 = "";
                        if (item.target) |target| {
                            if (target.node) |target_node| {
                                switch (target_node) {
                                    .resolved_column_ref_node => |ref| {
                                        if (ref.column) |col| column_name = col.name orelse "";
                                    },
                                    else => {},
                                }
                            }
                        }

                        const set_value = item.set_value orelse return error.InvalidAST;
                        const value_expr = set_value.value orelse return error.InvalidAST;
                        const set_item = try alloc.create(types_data.SetItemData);
                        set_item.* = .{
                            .column = column_name,
                            .value = try self.ExtractExpressionData(alloc, value_expr, ctx),
                        };
                        set_items[i] = set_item;
                    }
                    when_data.set_items = set_items;
                },
                // DELETE action has no additional data to extract.
                else => {},
            }

            try when_clauses.append(alloc, when_data);
        }

        const merge_data = try alloc.create(types_data.MergeData);
        merge_data.* = .{
            .target_table = target_table_name,
            .target_scan = target_scan,
            .source_scan = source_scan,
            .merge_expr = merge_expr_data,
            .when_clauses = try when_clauses.toOwnedSlice(alloc),
        };
        return .{ .type = .merge, .merge = merge_data };
    }

    /// Go extractCreateTableAsSelectStatementData.
    fn extractCreateTableAsSelectStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedCreateTableAsSelectStmtProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const base = node.parent orelse return error.InvalidAST;
        const create = base.parent orelse return error.InvalidAST;
        const table_name = try formatNamePath(alloc, create.name_path);

        const query = node.query orelse return error.InvalidAST;
        const query_scan = try self.ExtractScanData(alloc, query, ctx);

        const select_items = try alloc.alloc(
            *types_data.SelectItemData,
            node.output_column_list.len,
        );
        for (node.output_column_list, 0..) |oc, i| {
            const column = oc.column orelse return error.InvalidAST;
            const item = try alloc.create(types_data.SelectItemData);
            item.* = .{
                .expression = try newColumnExpressionData(alloc, column),
                .alias = oc.name orelse "",
            };
            select_items[i] = item;
        }

        const from_clause = try alloc.create(ScanData);
        from_clause.* = query_scan;
        const as_select = try alloc.create(types_data.SelectData);
        as_select.* = .{ .select_list = select_items, .from_clause = from_clause };

        const create_table = try alloc.create(types_data.CreateTableData);
        create_table.* = .{
            .table_name = table_name,
            .as_select = as_select,
            .if_not_exists = (create.create_mode orelse .CREATE_DEFAULT) == .CREATE_IF_NOT_EXISTS,
        };
        const create_data = try alloc.create(types_data.CreateData);
        create_data.* = .{ .type = .table, .table = create_table };
        return .{ .type = .create, .create = create_data };
    }

    /// Go extractCreateViewStatementData.
    fn extractCreateViewStatementData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedCreateViewStmtProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const base = node.parent orelse return error.InvalidAST;
        const create = base.parent orelse return error.InvalidAST;
        const view_name = try formatNamePath(alloc, create.name_path);

        const query = base.query orelse return error.InvalidAST;
        const query_scan = try self.ExtractScanData(alloc, query, ctx);

        const select_items = try alloc.alloc(
            *types_data.SelectItemData,
            base.output_column_list.len,
        );
        for (base.output_column_list, 0..) |oc, i| {
            const column = oc.column orelse return error.InvalidAST;
            const item = try alloc.create(types_data.SelectItemData);
            item.* = .{
                .expression = try newColumnExpressionData(alloc, column),
                .alias = oc.name orelse "",
            };
            select_items[i] = item;
        }

        const from_clause = try alloc.create(ScanData);
        from_clause.* = query_scan;

        const create_view = try alloc.create(types_data.CreateViewData);
        create_view.* = .{
            .view_name = view_name,
            .query = .{ .select_list = select_items, .from_clause = from_clause },
        };
        const create_data = try alloc.create(types_data.CreateData);
        create_data.* = .{ .type = .view, .view = create_view };
        return .{ .type = .create, .create = create_data };
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
                    .resolved_aggregate_scan_node => |a| return self.extractAggregateScanData(
                        alloc,
                        a,
                        ctx,
                    ),
                    // Anonymized/DifferentialPrivacy/AggregationThreshold:
                    // Go has no case for them either.
                    else => return error.UnsupportedNode,
                }
            },
            .resolved_order_by_scan_node => |n| return self.extractOrderByScanData(alloc, n, ctx),
            .resolved_limit_offset_scan_node => |n| return self.extractLimitScanData(alloc, n, ctx),
            .resolved_set_operation_scan_node => |n| return self.extractSetOperationScanData(
                alloc,
                n,
                ctx,
            ),
            .resolved_with_scan_node => |n| return self.extractWithScanNode(alloc, n, ctx),
            .resolved_with_ref_scan_node => |n| return self.extractWithRefScanNode(alloc, n, ctx),
            .resolved_array_scan_node => |n| return self.extractArrayScanData(alloc, n, ctx),
            .resolved_table_scan_node => |n| return extractTableScanData(alloc, n),
            .resolved_analytic_scan_node => |n| return self.extractAnalyticScanData(alloc, n, ctx),
            .resolved_recursive_scan_node => |n| return self.extractRecursiveScanData(
                alloc,
                n,
                ctx,
            ),
            .resolved_recursive_ref_scan_node => |n| return self.extractRecursiveRefScanData(
                alloc,
                n,
                ctx,
            ),
            else => return error.UnsupportedNode, // Go: "unsupported scan node type"
        }
    }

    fn extractSingleRowScanData(self: *const NodeExtractor) ScanData {
        _ = self;
        // Go: ScanData{Type: ScanTypeSingleRow} (no column list).
        return .{ .type = .single_row };
    }

    /// Go extractTableScanData. The table name comes from the resolved
    /// TableRefProto: the catalog registers every SimpleTableProto with
    /// `name` = the canonical "_"-joined SQLite table name (Go's
    /// getTableName migration note — Table().Name() carries the name the
    /// catalog registered), so no NodeMap/parser-AST walk is needed.
    /// Wildcard-table recognition (Gap G) is not ported; the catalog never
    /// registers wildcard tables, so the Go branch is unreachable here.
    fn extractTableScanData(
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedTableScanProto,
    ) Error!ScanData {
        const table_ref = node.table orelse return error.InvalidAST;
        const table_name = table_ref.name orelse return error.InvalidAST;

        const parent = node.parent orelse return error.InvalidAST;
        const table_scan = try alloc.create(types_data.TableScanData);
        table_scan.* = .{
            .table_name = table_name,
            .alias = node.alias orelse "",
        };
        return .{
            .type = .table,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .table_scan = table_scan,
        };
    }

    fn extractProjectScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedProjectScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const input_scan = node.input_scan orelse return error.InvalidAST;
        const input_scan_data = try self.ExtractScanData(alloc, input_scan, ctx);

        const computed_columns = try alloc.alloc(
            *types_data.ComputedColumnData,
            node.expr_list.len,
        );
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

        var aggregate_list: std.ArrayList(*types_data.ComputedColumnData) = .empty;
        for (base.aggregate_list) |agg_any| {
            const cc = try computedColumnOf(agg_any);
            try aggregate_list.append(alloc, try self.extractComputedColumnData(alloc, cc, ctx));
        }

        var group_by_list: std.ArrayList(*types_data.ComputedColumnData) = .empty;
        for (base.group_by_list) |group_by| {
            try group_by_list.append(
                alloc,
                try self.extractComputedColumnData(alloc, group_by, ctx),
            );
        }

        // Grouping sets (GROUP BY GROUPING SETS/ROLLUP/CUBE). The transformer
        // lowers these as a UNION ALL of one SELECT per set
        // (transformer/scan_aggregate.zig buildGroupingSetsQuery), so ROLLUP
        // and CUBE are expanded to concrete sets here and it never has to know
        // they existed. A GROUPING SETS list may itself hold ROLLUP and CUBE
        // items; the analyzer leaves them as siblings in one flat list, which
        // is exactly what appending each expansion in turn produces.
        var grouping_sets: std.ArrayList(*types_data.GroupingSetData) = .empty;
        for (base.grouping_set_list) |grouping_set_base| {
            const gs_node = grouping_set_base.node orelse return error.InvalidAST;
            switch (gs_node) {
                .resolved_grouping_set_node => |gs| try appendGroupingSet(
                    alloc,
                    &grouping_sets,
                    gs.group_by_column_list,
                ),
                .resolved_rollup_node => |r| try expandRollup(
                    alloc,
                    &grouping_sets,
                    r.rollup_column_list,
                ),
                .resolved_cube_node => |c| try expandCube(
                    alloc,
                    &grouping_sets,
                    c.cube_column_list,
                ),
                // ResolvedGroupingSetList / ResolvedGroupingSetProduct arise
                // only under FEATURE_MULTI_GROUPING_SETS, which the shim
                // leaves off, so the analyzer rejects those queries first.
                else => return error.UnsupportedNode,
            }
        }

        const parent = base.parent orelse return error.InvalidAST;
        const aggregate = try alloc.create(types_data.AggregateScanData);
        aggregate.* = .{
            .input_scan = input_scan_data,
            .group_by_list = try group_by_list.toOwnedSlice(alloc),
            .aggregate_list = try aggregate_list.toOwnedSlice(alloc),
            .grouping_sets = try grouping_sets.toOwnedSlice(alloc),
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

        const order_by_items = try alloc.alloc(
            *types_data.OrderByItemData,
            node.order_by_item_list.len,
        );
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

            const select_items = try alloc.alloc(
                *types_data.SelectItemData,
                item.output_column_list.len,
            );
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

        const with_entry_list = try alloc.alloc(
            *types_data.WithEntryData,
            node.with_entry_list.len,
        );
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

    /// Go extractRecursiveScanData.
    fn extractRecursiveScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedRecursiveScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        // Map the operation type.
        const op_type: []const u8 = switch (node.op_type orelse .UNION_ALL) {
            .UNION_ALL => "UNION ALL",
            .UNION_DISTINCT => "UNION",
            // Go: "unsupported recursive scan operation type"
            else => return error.Unimplemented,
        };

        var non_recursive_term = StatementData{};
        if (node.non_recursive_term) |item| {
            non_recursive_term = try self.extractSetOperationItemAsSelect(alloc, item, ctx);
        }

        var recursive_term = StatementData{};
        if (node.recursive_term) |item| {
            recursive_term = try self.extractSetOperationItemAsSelect(alloc, item, ctx);
        }

        const parent = node.parent orelse return error.InvalidAST;
        const recursive = try alloc.create(types_data.RecursiveScanData);
        recursive.* = .{
            .op_type = op_type,
            .non_recursive_term = non_recursive_term,
            .recursive_term = recursive_term,
        };
        return .{
            .type = .recursive,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .recursive_scan = recursive,
        };
    }

    /// Go extractSetOperationItemAsSelect: extracts a SetOperationItem's scan
    /// and output columns into a SELECT StatementData.
    fn extractSetOperationItemAsSelect(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        item: *const pb.ResolvedSetOperationItemProto,
        ctx: *TransformContext,
    ) Error!StatementData {
        const item_scan = item.scan orelse return error.InvalidAST;
        const scan_data = try self.ExtractScanData(alloc, item_scan, ctx);

        const select_items = try alloc.alloc(
            *types_data.SelectItemData,
            item.output_column_list.len,
        );
        for (item.output_column_list, 0..) |col, i| {
            const select_item = try alloc.create(types_data.SelectItemData);
            select_item.* = .{
                .expression = try newColumnExpressionData(alloc, col),
                .alias = col.name orelse "",
            };
            select_items[i] = select_item;
        }

        const from_clause = try alloc.create(ScanData);
        from_clause.* = scan_data;
        const select = try alloc.create(types_data.SelectData);
        select.* = .{ .select_list = select_items, .from_clause = from_clause };
        return .{ .type = .select, .select = select };
    }

    /// Go extractRecursiveRefScanData.
    fn extractRecursiveRefScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedRecursiveRefScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        _ = self;
        _ = ctx;
        const parent = node.parent orelse return error.InvalidAST;
        const column_data = try extractColumnDataList(alloc, parent.column_list);
        const recursive_ref = try alloc.create(types_data.RecursiveRefScanData);
        recursive_ref.* = .{ .column_list = column_data };
        return .{
            .type = .recursive_ref,
            .column_list = column_data,
            .recursive_ref_scan = recursive_ref,
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

    /// Go extractAnalyticScanData: flattens the function_group_list into a
    /// single function_list. Each group carries the PARTITION BY / ORDER BY
    /// shared by its analytic functions; those attach onto each function's
    /// WindowSpec (whose FrameClause was already set by
    /// extractAnalyticFunctionCallData).
    fn extractAnalyticScanData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedAnalyticScanProto,
        ctx: *TransformContext,
    ) Error!ScanData {
        const input_scan = node.input_scan orelse return error.InvalidAST;
        const input_scan_data = try self.ExtractScanData(alloc, input_scan, ctx);

        var function_list: std.ArrayList(*types_data.ComputedColumnData) = .empty;
        for (node.function_group_list) |group| {
            // Extract PARTITION BY expressions from the group. Go routes the
            // *ResolvedColumnRef through ExtractExpressionData, which lands
            // in NewColumnExpressionData.
            var group_partition_by: std.ArrayList(*ExpressionData) = .empty;
            if (group.partition_by) |partitioning| {
                for (partitioning.partition_by_list) |part_ref| {
                    const column = part_ref.column orelse return error.InvalidAST;
                    const part_data = try alloc.create(ExpressionData);
                    part_data.* = try newColumnExpressionData(alloc, column);
                    try group_partition_by.append(alloc, part_data);
                }
            }

            // Extract ORDER BY expressions from the group.
            var group_order_by: std.ArrayList(*types_data.OrderByItemData) = .empty;
            if (group.order_by) |ordering| {
                for (ordering.order_by_item_list) |order_item| {
                    const column_ref = order_item.column_ref orelse return error.InvalidAST;
                    const column = column_ref.column orelse return error.InvalidAST;
                    const item = try alloc.create(types_data.OrderByItemData);
                    item.* = .{
                        .expression = try newColumnExpressionData(alloc, column),
                        .is_descending = order_item.is_descending orelse false,
                        .null_order = order_item.null_order orelse .ORDER_UNSPECIFIED,
                    };
                    try group_order_by.append(alloc, item);
                }
            }

            const partition_slice = try group_partition_by.toOwnedSlice(alloc);
            const order_slice = try group_order_by.toOwnedSlice(alloc);

            for (group.analytic_function_list) |func_any| {
                // Go's analyticFunctionList items are ResolvedComputedColumns
                // whose Expr is the analytic function call.
                const cc = try computedColumnOf(func_any);
                const expr = cc.expr orelse return error.InvalidAST;
                const expr_data = try self.ExtractExpressionData(alloc, expr, ctx);

                // Merge the group's PARTITION BY / ORDER BY into the
                // function's window spec (Go only assigns non-empty lists).
                if (expr_data.type == .function) {
                    if (expr_data.function) |function| {
                        if (function.window_spec) |window_spec| {
                            if (partition_slice.len > 0) window_spec.partition_by = partition_slice;
                            if (order_slice.len > 0) window_spec.order_by = order_slice;
                        }
                    }
                }

                const out = try alloc.create(types_data.ComputedColumnData);
                out.* = .{
                    .column = try extractColumnData(alloc, cc.column),
                    .expression = expr_data,
                };
                try function_list.append(alloc, out);
            }
        }

        const parent = node.parent orelse return error.InvalidAST;
        const analytic = try alloc.create(types_data.AnalyticScanData);
        analytic.* = .{
            .input_scan = input_scan_data,
            .function_list = try function_list.toOwnedSlice(alloc),
        };
        return .{
            .type = .analytic,
            .column_list = try extractColumnDataList(alloc, parent.column_list),
            .analytic_scan = analytic,
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
                            .resolved_aggregate_function_call_node => |agg| {
                                return self.extractAggregateFunctionCallData(alloc, agg, ctx);
                            },
                            .resolved_analytic_function_call_node => |an| {
                                return self.extractAnalyticFunctionCallData(alloc, an, ctx);
                            },
                        }
                    },
                }
            },
            .resolved_cast_node => |n| return self.extractCastData(alloc, n, ctx),
            .resolved_subquery_expr_node => |n| return self.extractSubqueryData(alloc, n, ctx),
            .resolved_get_struct_field_node => |n| return self.extractGetStructFieldData(
                alloc,
                n,
                ctx,
            ),
            .resolved_make_struct_node => |n| return self.extractMakeStructData(alloc, n, ctx),
            // Go extractDMLDefaultData: a zero-value literal stands in for
            // the DEFAULT keyword (renders as NULL — no column defaults).
            .resolved_dmldefault_node => {
                const literal = try alloc.create(types_data.LiteralData);
                literal.* = .{};
                return .{ .type = .literal, .literal = literal };
            },
            .resolved_get_json_field_node => |n| return self.extractGetJsonFieldData(alloc, n, ctx),
            .resolved_parameter_node => |n| return extractParameterData(alloc, n, ctx),
            .resolved_argument_ref_node => |n| return extractArgumentRefData(alloc, n),
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
        const type_proto = vwt.type orelse return error.InvalidAST;
        const value_proto = vwt.value orelse return error.InvalidAST;

        const zetasqlite_value = try encoder.valueFromProto(alloc, value_proto, type_proto);

        const literal = try alloc.create(types_data.LiteralData);
        literal.* = .{
            .value = zetasqlite_value,
            .type_name = @tagName(type_proto.type_kind orelse .TYPE_UNKNOWN),
        };
        return .{ .type = .literal, .literal = literal };
    }

    /// Go extractParameterData: positional parameters (empty name) render as
    /// "?"; named parameters render as "@name". Each occurrence is also
    /// recorded on the context with its resolved type so the driver can cast
    /// bound values (Go getParamsFromNode + EncodeNamedValues).
    fn extractParameterData(
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedParameterProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const name = node.name orelse "";
        var identifier: []const u8 = undefined;
        if (name.len == 0) {
            identifier = "?"; // Positional parameter.
        } else {
            identifier = try std.fmt.allocPrint(alloc, "@{s}", .{name}); // Named.
        }

        var param_type: ?*spec.Type = null;
        if (node.parent) |parent| {
            if (parent.type) |tp| param_type = try spec.newTypeFromProto(alloc, tp);
        }
        try ctx.addCollectedParameter(identifier, param_type);

        const param = try alloc.create(types_data.ParameterData);
        param.* = .{ .identifier = identifier };
        return .{ .type = .parameter, .parameter = param };
    }

    /// Go extractArgumentRefData: a table/function argument reference renders
    /// as a named "@name" parameter.
    fn extractArgumentRefData(
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedArgumentRefProto,
    ) Error!ExpressionData {
        const name = node.name orelse "";
        const param = try alloc.create(types_data.ParameterData);
        param.* = .{ .identifier = try std.fmt.allocPrint(alloc, "@{s}", .{name}) };
        return .{ .type = .parameter, .parameter = param };
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
        const is_builtin = builtinGroupOf(raw_name) != null;
        // Go: fn.FullName(false) — strips any "<group>:" prefix (UDFs carry
        // an empty group, i.e. ":name").
        const original_func_name = stripFunctionGroup(raw_name);

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
                if (arg.type) |tp| {
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
            // requires exactly 2 arguments
            if (arguments.items.len != 2) return error.UnsupportedFunction;
            const having_func: []const u8 = if (std.mem.eql(u8, original_func_name, "min_by"))
                "zetasqlite_having_min"
            else
                "zetasqlite_having_max";

            const having_args = try alloc.alloc(ExpressionData, 1);
            having_args[0] = arguments.items[1];
            const wrapped_args = try alloc.alloc(ExpressionData, 2);
            wrapped_args[0] = arguments.items[0]; // x - the value to return
            wrapped_args[1] = try types_data.newFunctionCallExpressionData(
                alloc,
                having_func,
                having_args,
            );

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
            .IGNORE_NULLS => {
                const ignore_nulls = try types_data.newFunctionCallExpressionData(
                    alloc,
                    "zetasqlite_ignore_nulls",
                    &.{},
                );
                try arguments.append(alloc, ignore_nulls);
            },
            else => {},
        }

        function.arguments = try arguments.toOwnedSlice(alloc);
        return base_data;
    }

    /// Go getWindowBoundaryOptionFuncSQL: a ResolvedWindowFrame (or its
    /// absence) becomes a FrameClauseData. Absent frame -> Go's default
    /// `ROWS BETWEEN UNBOUNDED PRECEDING AND UNBOUNDED FOLLOWING`.
    fn getWindowBoundaryOptionFuncSQL(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: ?*const pb.ResolvedWindowFrameProto,
        ctx: *TransformContext,
    ) Error!*types_data.FrameClauseData {
        const clause = try alloc.create(types_data.FrameClauseData);
        const frame = node orelse {
            const start = try alloc.create(types_data.FrameBoundData);
            start.* = .{ .type = "UNBOUNDED PRECEDING" };
            const end = try alloc.create(types_data.FrameBoundData);
            end.* = .{ .type = "UNBOUNDED FOLLOWING" };
            clause.* = .{ .unit = "ROWS", .start = start, .end = end };
            return clause;
        };

        const frame_nodes = [2]*const pb.ResolvedWindowFrameExprProto{
            frame.start_expr orelse return error.InvalidAST,
            frame.end_expr orelse return error.InvalidAST,
        };
        var frames: [2]*types_data.FrameBoundData = undefined;
        for (frame_nodes, 0..) |frame_expr, i| {
            const typ = frame_expr.boundary_type orelse return error.InvalidAST;
            var literal = ExpressionData{};
            switch (typ) {
                .UNBOUNDED_PRECEDING, .CURRENT_ROW, .UNBOUNDED_FOLLOWING => {},
                .OFFSET_PRECEDING, .OFFSET_FOLLOWING => {
                    const expression = frame_expr.expression orelse return error.InvalidAST;
                    literal = try self.ExtractExpressionData(alloc, expression, ctx);
                },
                // Go: "unexpected boundary type %d"
                else => return error.UnsupportedNode,
            }
            frames[i] = try getWindowBoundaryTypeData(alloc, typ, literal);
        }

        const unit: []const u8 = switch (frame.frame_unit orelse .ROWS) {
            .ROWS => "ROWS",
            .RANGE => "RANGE",
            // Go: "unexpected frame unit %d"
            else => return error.UnsupportedNode,
        };
        clause.* = .{ .unit = unit, .start = frames[0], .end = frames[1] };
        return clause;
    }

    /// Go extractAnalyticFunctionCallData: base function call (window name
    /// normalization) plus the analytic modifiers as trailing pseudo-args —
    /// DISTINCT then IGNORE NULLS, in that order (unlike the aggregate path
    /// there is no ORDER BY/LIMIT/HAVING encoding; partitioning/ordering
    /// travel in the WindowSpec instead). The frame becomes WindowSpec
    /// FrameClause data; PARTITION BY / ORDER BY are attached later by
    /// extractAnalyticScanData from the surrounding function group.
    fn extractAnalyticFunctionCallData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedAnalyticFunctionCallProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const non_scalar = node.parent orelse return error.InvalidAST;
        const base = non_scalar.parent orelse return error.InvalidAST;

        // Extract the base function call (isWindowFunc=true selects the
        // zetasqlite_window_* runtime names).
        const base_data = try self.extractFunctionCallData(alloc, base, ctx, true);
        const function = base_data.function orelse return error.InvalidAST;

        var arguments: std.ArrayList(ExpressionData) = .empty;
        try arguments.appendSlice(alloc, function.arguments);

        if (non_scalar.distinct orelse false) {
            try arguments.append(alloc, try types_data.newFunctionCallExpressionData(
                alloc,
                "zetasqlite_distinct",
                &.{},
            ));
        }

        // Go windowFunctionsIgnoreNullsByDefault: percentile_disc only.
        const ignore_nulls_by_default =
            std.mem.eql(u8, function.name, "zetasqlite_window_percentile_disc");

        switch (non_scalar.null_handling_modifier orelse .DEFAULT_NULL_HANDLING) {
            .IGNORE_NULLS => {
                const ignore_nulls = try types_data.newFunctionCallExpressionData(
                    alloc,
                    "zetasqlite_ignore_nulls",
                    &.{},
                );
                try arguments.append(alloc, ignore_nulls);
            },
            .DEFAULT_NULL_HANDLING => if (ignore_nulls_by_default) {
                try arguments.append(alloc, try types_data.newFunctionCallExpressionData(
                    alloc,
                    "zetasqlite_ignore_nulls",
                    &.{},
                ));
            },
            else => {},
        }
        function.arguments = try arguments.toOwnedSlice(alloc);

        var frame_clause = try windowFuncFixedRange(alloc, function.name);
        if (frame_clause != null and node.window_frame != null) {
            // Go: "%s: window framing clause is not allowed for analytic
            // function"
            return error.UnsupportedFunction;
        }
        if (frame_clause == null) {
            frame_clause = try self.getWindowBoundaryOptionFuncSQL(alloc, node.window_frame, ctx);
        }

        // Ordering and partitioning come from the AnalyticFunctionGroup
        // node; omit them here (extractAnalyticScanData fills them in).
        const window_spec = try alloc.create(types_data.WindowSpecificationData);
        window_spec.* = .{ .frame_clause = frame_clause };
        function.window_spec = window_spec;

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
        const to_type_proto = parent.type orelse return error.InvalidAST;

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

    /// Go extractGetJsonFieldData: JSON field access lowers to
    /// zetasqlite_get_json_field(expr, "<field_name>").
    fn extractGetJsonFieldData(
        self: *const NodeExtractor,
        alloc: std.mem.Allocator,
        node: *const pb.ResolvedGetJsonFieldProto,
        ctx: *TransformContext,
    ) Error!ExpressionData {
        const expr = node.expr orelse return error.InvalidAST;
        const expr_data = try self.ExtractExpressionData(alloc, expr, ctx);

        const field_name = node.field_name orelse return error.InvalidAST;
        const name_literal = try alloc.create(types_data.LiteralData);
        name_literal.* = .{ .value = .{ .string = field_name }, .type_name = "STRING" };

        const args = try alloc.alloc(ExpressionData, 2);
        args[0] = expr_data;
        args[1] = .{ .type = .literal, .literal = name_literal };
        return types_data.newFunctionCallExpressionData(alloc, "zetasqlite_get_json_field", args);
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
        const type_proto = parent.type orelse return error.InvalidAST;
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

/// Go extractDropStatementData. The object type passes through verbatim
/// (Go's switch only canonicalizes the names it already matches).
fn extractDropStatementData(
    alloc: std.mem.Allocator,
    node: *const pb.ResolvedDropStmtProto,
) Error!StatementData {
    const drop_data = try alloc.create(types_data.DropData);
    drop_data.* = .{
        .if_exists = node.is_if_exists orelse false,
        .object_type = node.object_type orelse "",
        .object_name = try formatNamePath(alloc, node.name_path),
    };
    return .{ .type = .drop, .drop = drop_data };
}

/// Go extractDropFunctionStatementData.
fn extractDropFunctionStatementData(
    alloc: std.mem.Allocator,
    node: *const pb.ResolvedDropFunctionStmtProto,
) Error!StatementData {
    const drop_data = try alloc.create(types_data.DropData);
    drop_data.* = .{
        .if_exists = node.is_if_exists orelse false,
        .object_type = "FUNCTION",
        .object_name = try formatNamePath(alloc, node.name_path),
    };
    return .{ .type = .drop, .drop = drop_data };
}

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
    try testing.expectEqual(
        pb.ResolvedSubqueryExprEnums_SubqueryType.SCALAR,
        sub.subquery.?.subquery_type,
    );
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

test "extract ROW_NUMBER analytic scan (fixed frame, group ORDER BY)" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(
        alloc,
        "SELECT x, ROW_NUMBER() OVER (ORDER BY x) FROM UNNEST([3, 1, 2]) AS x",
    );
    var from: *const ScanData = stmt.select.?.from_clause.?;
    while (from.type == .project) from = &from.project_scan.?.input_scan;
    try testing.expectEqual(types_data.ScanType.analytic, from.type);
    const analytic = from.analytic_scan.?;

    try testing.expectEqual(@as(usize, 1), analytic.function_list.len);
    const function = analytic.function_list[0].expression.function.?;
    try testing.expectEqualStrings("zetasqlite_window_row_number", function.name);
    try testing.expectEqual(@as(usize, 0), function.arguments.len);

    // Window spec: no PARTITION BY, the group's ORDER BY on x, and the
    // fixed row_number frame from Go's windowFuncFixedRanges.
    const window_spec = function.window_spec.?;
    try testing.expectEqual(@as(usize, 0), window_spec.partition_by.len);
    try testing.expectEqual(@as(usize, 1), window_spec.order_by.len);
    const order_item = window_spec.order_by[0];
    try testing.expect(!order_item.is_descending);
    try testing.expectEqual(types_data.ExpressionType.column, order_item.expression.type);
    try testing.expectEqualStrings("x", order_item.expression.column.?.column_name);

    const frame = window_spec.frame_clause.?;
    try testing.expectEqualStrings("ROWS", frame.unit);
    try testing.expectEqualStrings("UNBOUNDED PRECEDING", frame.start.?.type);
    try testing.expectEqualStrings("CURRENT ROW", frame.end.?.type);
}

test "extract SUM OVER with PARTITION BY and explicit frame" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const stmt = try TestHarness.statementData(alloc,
        \\SELECT SUM(x) OVER (PARTITION BY y ORDER BY x DESC ROWS BETWEEN 1 PRECEDING AND CURRENT ROW)
        \\FROM UNNEST([STRUCT(1 AS x, 'a' AS y)])
    );
    var from: *const ScanData = stmt.select.?.from_clause.?;
    while (from.type == .project) from = &from.project_scan.?.input_scan;
    try testing.expectEqual(types_data.ScanType.analytic, from.type);
    const analytic = from.analytic_scan.?;

    try testing.expectEqual(@as(usize, 1), analytic.function_list.len);
    const function = analytic.function_list[0].expression.function.?;
    try testing.expectEqualStrings("zetasqlite_window_sum", function.name);
    // One argument: the analyzer inlines the struct-field access
    // ($unnest.x) as the SUM argument rather than a column ref.
    try testing.expectEqual(@as(usize, 1), function.arguments.len);

    const window_spec = function.window_spec.?;
    try testing.expectEqual(@as(usize, 1), window_spec.partition_by.len);
    try testing.expectEqualStrings("y", window_spec.partition_by[0].column.?.column_name);
    try testing.expectEqual(@as(usize, 1), window_spec.order_by.len);
    try testing.expect(window_spec.order_by[0].is_descending);

    // Explicit frame extracted via getWindowBoundaryOptionFuncSQL.
    const frame = window_spec.frame_clause.?;
    try testing.expectEqualStrings("ROWS", frame.unit);
    try testing.expectEqualStrings("PRECEDING", frame.start.?.type);
    try value_mod.expectValueEqual(.{ .int = 1 }, frame.start.?.offset.literal.?.value);
    try testing.expectEqualStrings("CURRENT ROW", frame.end.?.type);
}

test "extract analytic DISTINCT / RANK fixed GROUPS frame" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // COUNT(DISTINCT x) OVER (): DISTINCT becomes a trailing pseudo-arg;
    // no frame given -> Go default ROWS UNBOUNDED PRECEDING..FOLLOWING.
    {
        const stmt = try TestHarness.statementData(
            alloc,
            "SELECT COUNT(DISTINCT x) OVER () FROM UNNEST([1, 1, 2]) AS x",
        );
        var from: *const ScanData = stmt.select.?.from_clause.?;
        while (from.type == .project) from = &from.project_scan.?.input_scan;
        const function = from.analytic_scan.?.function_list[0].expression.function.?;
        try testing.expectEqualStrings("zetasqlite_window_count", function.name);
        try testing.expectEqual(@as(usize, 2), function.arguments.len);
        try testing.expectEqualStrings(
            "zetasqlite_distinct",
            function.arguments[1].function.?.name,
        );
        const frame = function.window_spec.?.frame_clause.?;
        try testing.expectEqualStrings("ROWS", frame.unit);
        try testing.expectEqualStrings("UNBOUNDED PRECEDING", frame.start.?.type);
        try testing.expectEqualStrings("UNBOUNDED FOLLOWING", frame.end.?.type);
    }

    // RANK(): fixed GROUPS frame with the EXCLUDE TIES end bound.
    {
        const stmt = try TestHarness.statementData(
            alloc,
            "SELECT RANK() OVER (ORDER BY x) FROM UNNEST([1, 1, 2]) AS x",
        );
        var from: *const ScanData = stmt.select.?.from_clause.?;
        while (from.type == .project) from = &from.project_scan.?.input_scan;
        const function = from.analytic_scan.?.function_list[0].expression.function.?;
        try testing.expectEqualStrings("zetasqlite_window_rank", function.name);
        const frame = function.window_spec.?.frame_clause.?;
        try testing.expectEqualStrings("GROUPS", frame.unit);
        try testing.expectEqualStrings("UNBOUNDED PRECEDING", frame.start.?.type);
        try testing.expectEqualStrings("CURRENT ROW EXCLUDE TIES", frame.end.?.type);
    }
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
