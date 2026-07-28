//! Faithful port of go-zetasqlite internal/coordinator_coordinator.go.
//!
//! Go holds transformer instances behind interfaces; the Zig port keeps the
//! exact same direct-dispatch switches but calls the stateless `transform`
//! functions in src/internal/transformer/*.zig. No singleton: the driver
//! creates one QueryCoordinator per process (init is trivially cheap).

const std = @import("std");
const pb = @import("../../proto/resolved_ast.zig");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const types_data = @import("types_data.zig");
const context = @import("context.zig");
const interfaces = @import("types_interfaces.zig");
const extractor_mod = @import("extractor.zig");

// Expression transformers.
const literal = @import("../transformer/literal.zig");
const function = @import("../transformer/function.zig");
const cast = @import("../transformer/cast.zig");
const column_ref = @import("../transformer/column_ref.zig");
const subquery = @import("../transformer/subquery.zig");
const parameter = @import("../transformer/parameter.zig");

// Statement transformers.
const stmt_query = @import("../transformer/stmt_query.zig");
const stmt_dml = @import("../transformer/stmt_dml.zig");
const stmt_create_table_as_select = @import("../transformer/stmt_create_table_as_select.zig");
const stmt_create_view = @import("../transformer/stmt_create_view.zig");
const stmt_drop = @import("../transformer/stmt_drop.zig");
const stmt_merge = @import("../transformer/stmt_merge.zig");

// Scan transformers.
const scan_table = @import("../transformer/scan_table.zig");
const scan_project = @import("../transformer/scan_project.zig");
const scan_filter = @import("../transformer/scan_filter.zig");
const scan_join = @import("../transformer/scan_join.zig");
const scan_aggregate = @import("../transformer/scan_aggregate.zig");
const scan_orderby = @import("../transformer/scan_orderby.zig");
const scan_limit = @import("../transformer/scan_limit.zig");
const scan_setop = @import("../transformer/scan_setop.zig");
const scan_single_row = @import("../transformer/scan_single_row.zig");
const scan_with = @import("../transformer/scan_with.zig");
const scan_with_ref = @import("../transformer/scan_with_ref.zig");
const scan_array = @import("../transformer/scan_array.zig");
const scan_analytic = @import("../transformer/scan_analytic.zig");
const scan_recursive = @import("../transformer/scan_recursive.zig");
const scan_recursive_ref = @import("../transformer/scan_recursive_ref.zig");
const with_entry = @import("../transformer/with_entry.zig");

pub const Error = interfaces.Error;
pub const NodeExtractor = extractor_mod.NodeExtractor;

const ExpressionData = types_data.ExpressionData;
const StatementData = types_data.StatementData;
const ScanData = types_data.ScanData;
const ColumnData = types_data.ColumnData;
const TransformContext = context.TransformContext;

/// Go QueryCoordinator: orchestrates the transformation by delegating to
/// the appropriate transformers.
pub const QueryCoordinator = struct {
    alloc: std.mem.Allocator,
    extractor: NodeExtractor = .{},

    /// Go NewQueryCoordinator (transformer wiring is comptime here).
    pub fn init(alloc: std.mem.Allocator) QueryCoordinator {
        return .{ .alloc = alloc };
    }

    /// Go TransformStatementNode: extract pure data from the AST node, then
    /// delegate. (Go's debug printing of AST/extracted JSON is handled by
    /// the CLI driver in this port.)
    pub fn transformStatementNode(
        self: *QueryCoordinator,
        node: *const pb.AnyResolvedNodeProto,
        ctx: *TransformContext,
    ) Error!sqlbuilder.SQLFragment {
        const data = try self.extractor.ExtractStatementData(self.alloc, node, ctx);

        const token = try ctx.fragmentContext().enterScope();
        defer ctx.fragmentContext().exitScope(token);

        return self.transformStatement(data, ctx);
    }

    /// Go TransformExpression: direct dispatch on the expression data type.
    pub fn transformExpression(
        self: *QueryCoordinator,
        expr_data: ExpressionData,
        ctx: *TransformContext,
    ) Error!*sqlbuilder.SQLExpression {
        switch (expr_data.type) {
            .literal => return literal.transform(self, expr_data, ctx),
            .function => return function.transform(self, expr_data, ctx),
            .cast => return cast.transform(self, expr_data, ctx),
            .column => return column_ref.transform(self, expr_data, ctx),
            .subquery => return subquery.transform(self, expr_data, ctx),
            .parameter => return parameter.transform(self, expr_data, ctx),
            // Go: "unsupported expression data type: %v"
            else => return error.UnsupportedNode,
        }
    }

    /// Go TransformStatement: direct dispatch on the statement data type,
    /// wrapped in its own fragment scope.
    pub fn transformStatement(
        self: *QueryCoordinator,
        stmt_data: StatementData,
        ctx: *TransformContext,
    ) Error!sqlbuilder.SQLFragment {
        const token = try ctx.fragmentContext().enterScope();
        defer ctx.fragmentContext().exitScope(token);

        switch (stmt_data.type) {
            .select => return stmt_query.transform(self, stmt_data, ctx),
            .insert, .update, .delete => return stmt_dml.transform(self, stmt_data, ctx),
            .create => {
                if (stmt_data.create) |create_data| {
                    switch (create_data.type) {
                        .table => {
                            if (create_data.table) |table| {
                                if (table.as_select != null) {
                                    return stmt_create_table_as_select.transform(self, stmt_data, ctx);
                                }
                            }
                            // Go: "unsupported CREATE TABLE statement"
                            // (plain CREATE TABLE never reaches the
                            // transformer; spec.SQLiteSchema handles it).
                            return error.UnsupportedNode;
                        },
                        .view => return stmt_create_view.transform(self, stmt_data, ctx),
                    }
                }
                // Go: "unsupported create statement type"
                return error.UnsupportedNode;
            },
            .drop => return stmt_drop.transform(self, stmt_data, ctx),
            .merge => return stmt_merge.transform(self, stmt_data, ctx),
        }
    }

    /// A transformed scan, before anyone has decided whether it costs a
    /// subquery level.
    ///
    /// `query` is a *partially filled* SELECT: a slot left empty is a slot the
    /// consuming scan may still claim. A scan that is only a row source — a
    /// table, a WITH reference, an UNNEST — leaves everything but `from_clause`
    /// empty, which is GoogleSQL's "`from_` set, `select_list_` free" state
    /// (query_expression.h). Nothing becomes a subquery until `materializeScan`
    /// says so.
    ///
    /// `alias` is computed inside the scan's own fragment scope (it embeds that
    /// scope's id) but consumed by the parent, after the scope has been left —
    /// hence carrying it here rather than reading `getID()` at use.
    pub const ScanResult = struct {
        query: *sqlbuilder.SelectStatement,
        alias: []const u8,
        columns: []const *ColumnData,
    };

    /// Go TransformScan: direct dispatch, then the alias this scan would take
    /// if it is materialized.
    pub fn transformScan(
        self: *QueryCoordinator,
        scan_data: ScanData,
        ctx: *TransformContext,
    ) Error!ScanResult {
        const token = try ctx.fragmentContext().enterScope();
        defer ctx.fragmentContext().exitScope(token);

        var alias_base: []const u8 = undefined;
        var query: *sqlbuilder.SelectStatement = undefined;
        switch (scan_data.type) {
            .table => {
                alias_base = "table_scan";
                query = try scan_table.transform(self, scan_data, ctx);
            },
            .join => {
                alias_base = "join_scan";
                query = try scan_join.transform(self, scan_data, ctx);
            },
            .filter => {
                alias_base = "filter_scan";
                query = try scan_filter.transform(self, scan_data, ctx);
            },
            .project => {
                alias_base = "project_scan";
                query = try scan_project.transform(self, scan_data, ctx);
            },
            .aggregate => {
                alias_base = "aggregate_scan";
                query = try scan_aggregate.transform(self, scan_data, ctx);
            },
            .order_by => {
                alias_base = "order_by_scan";
                query = try scan_orderby.transform(self, scan_data, ctx);
            },
            .limit => {
                alias_base = "limit_scan";
                query = try scan_limit.transform(self, scan_data, ctx);
            },
            .set_op => {
                alias_base = "set_op_scan";
                query = try scan_setop.transform(self, scan_data, ctx);
            },
            .single_row => {
                alias_base = "single_row_scan";
                query = try scan_single_row.transform(self, scan_data, ctx);
            },
            .with => {
                alias_base = "with_scan";
                query = try scan_with.transform(self, scan_data, ctx);
            },
            .with_ref => {
                alias_base = "with_ref_scan";
                query = try scan_with_ref.transform(self, scan_data, ctx);
            },
            // Go: "WithEntry scans should use TransformWithEntry method"
            .with_entry => return error.UnsupportedNode,
            .array => {
                alias_base = "array_scan";
                query = try scan_array.transform(self, scan_data, ctx);
            },
            .analytic => {
                alias_base = "analytic_scan";
                query = try scan_analytic.transform(self, scan_data, ctx);
            },
            .recursive => {
                alias_base = "recursive_scan";
                query = try scan_recursive.transform(self, scan_data, ctx);
            },
            .recursive_ref => {
                alias_base = "recursive_ref_scan";
                query = try scan_recursive_ref.transform(self, scan_data, ctx);
            },
        }

        return .{
            .query = query,
            .alias = try std.fmt.allocPrint(self.alloc, "{s}_{s}", .{
                alias_base,
                ctx.fragmentContext().getID(),
            }),
            .columns = scan_data.column_list,
        };
    }

    /// Turns a transformed scan into a FROM item, spending a subquery level to
    /// do it, and re-points the scan's output columns at the new alias.
    /// GoogleSQL WrapQueryExpression (sql_builder.cc:1619).
    ///
    /// Callers must invoke this immediately after `transformScan`: the column
    /// registrations below are what later sibling scans and expressions resolve
    /// against, so their order has to follow transformation order.
    pub fn materializeScan(
        self: *QueryCoordinator,
        result: ScanResult,
        ctx: *TransformContext,
    ) Error!*sqlbuilder.FromItem {
        try self.addSelectListIfNeeded(result, ctx);
        const from_item = try self.asFromItem(result);
        from_item.alias = result.alias;

        // Verify output column names against extracted data and add to scope.
        try self.validateColumnData(from_item, result.columns);

        // Add available column expressions.
        for (result.columns) |column| {
            const info = try self.alloc.create(context.ColumnInfo);
            info.* = .{ .name = column.name, .id = column.id };
            try ctx.fragmentContext().addAvailableColumn(column.id, info);
        }

        // Register scope mappings for output columns, and retire any pending
        // entries for them: past this point the columns live behind `alias`,
        // and leaving a stale expression pending would resolve them against a
        // scope they are no longer in. See the invariant on FragmentContext.
        try ctx.fragmentContext().registerColumnScopeMapping(result.alias, result.columns);
        for (result.columns) |column| _ = ctx.fragmentContext().takePending(column.id);

        return from_item;
    }

    /// Completes a scan into a standalone query *without* wrapping it in a
    /// FROM item: for a scan consumed as an expression — a scalar, EXISTS or
    /// IN subquery — where nothing outside names its columns.
    ///
    /// Its columns stop being pending without gaining a scope, so a later
    /// reference to one fails loudly (ColumnNotFound) instead of resolving
    /// against whatever scope happens to be current.
    pub fn finishScan(
        self: *QueryCoordinator,
        result: ScanResult,
        ctx: *TransformContext,
    ) Error!*sqlbuilder.SelectStatement {
        try self.addSelectListIfNeeded(result, ctx);
        for (result.columns) |column| _ = ctx.fragmentContext().takePending(column.id);
        return result.query;
    }

    /// Spends a subquery level: materializes `result` and returns a fresh
    /// statement selecting from it. For a consumer whose clause slot is
    /// already taken in `result.query`.
    pub fn wrapScan(
        self: *QueryCoordinator,
        result: ScanResult,
        ctx: *TransformContext,
    ) Error!*sqlbuilder.SelectStatement {
        const from_item = try self.materializeScan(result, ctx);
        const q = try sqlbuilder.newSelectStatement(self.alloc);
        q.from_clause = from_item;
        return q;
    }

    /// Projects the scan's output columns, but only if it has no select list
    /// of its own — a scan that already filled that slot said what it wanted
    /// to say. GoogleSQL AddSelectListIfNeeded (sql_builder.cc:1710).
    ///
    /// This is the one place a column stops being pending, so it is also the
    /// one place that has to register the column's new scope. Doing half of
    /// that leaves the column resolving against a scope it is no longer in.
    fn addSelectListIfNeeded(
        self: *QueryCoordinator,
        result: ScanResult,
        ctx: *TransformContext,
    ) Error!void {
        const q = result.query;
        if (q.select_list.len > 0 or q.set_operation != null) return;
        if (result.columns.len == 0) return;

        const fc = ctx.fragmentContext();
        const select_list = try self.alloc.alloc(*sqlbuilder.SelectListItem, result.columns.len);
        for (result.columns, 0..) |col, i| {
            const alias = try context.generateIDBasedAlias(self.alloc, col.name, col.id);
            const expr = fc.takePending(col.id) orelse
                try fc.getQualifiedColumnExpression(col.id);
            const item = try self.alloc.create(sqlbuilder.SelectListItem);
            item.* = .{ .expression = expr, .alias = alias };
            select_list[i] = item;
        }
        q.select_list = select_list;
    }

    /// The FROM item for a scan, wrapping it in a subquery only if it is more
    /// than a bare row source. A scan that set nothing but `from_clause` is
    /// already a FROM item — wrapping it would add a level that says nothing.
    fn asFromItem(
        self: *QueryCoordinator,
        result: ScanResult,
    ) Error!*sqlbuilder.FromItem {
        const q = result.query;
        if (q.select_list.len == 0 and q.set_operation == null and
            q.where_clause == null and q.group_by_list.len == 0 and
            q.having_clause == null and q.order_by_list.len == 0 and
            q.limit_clause == null and q.with_clauses.len == 0)
        {
            if (q.from_clause) |from| return from;
        }
        return sqlbuilder.newSubqueryFromItem(self.alloc, q, "");
    }

    /// Go TransformWithEntry.
    pub fn transformWithEntry(
        self: *QueryCoordinator,
        scan_data: ScanData,
        ctx: *TransformContext,
    ) Error!*sqlbuilder.WithClause {
        // Go: "expected WITH entry data, got type %v"
        if (scan_data.type != .with_entry) return error.UnsupportedNode;

        const token = try ctx.fragmentContext().enterScope();
        defer ctx.fragmentContext().exitScope(token);

        return with_entry.transform(self, scan_data, ctx);
    }

    /// Go TransformExpressionDataList (nil in -> nil out).
    pub fn transformExpressionDataList(
        self: *QueryCoordinator,
        expr_data_list: ?[]const ExpressionData,
        ctx: *TransformContext,
    ) Error!?[]const *sqlbuilder.SQLExpression {
        const list = expr_data_list orelse return null;
        const result = try self.alloc.alloc(*sqlbuilder.SQLExpression, list.len);
        for (list, 0..) |expr_data, i| {
            result[i] = try self.transformExpression(expr_data, ctx);
        }
        return result;
    }

    /// Go TransformOptionalExpressionData.
    pub fn transformOptionalExpressionData(
        self: *QueryCoordinator,
        expr_data: ?*const ExpressionData,
        ctx: *TransformContext,
    ) Error!?*sqlbuilder.SQLExpression {
        const data = expr_data orelse return null;
        return try self.transformExpression(data.*, ctx);
    }

    /// Go validateColumnData: validates that output columns in a
    /// transformed scan's SelectList use id-based aliases and match the
    /// ScanData.ColumnList. For SELECT * subqueries, recursively uses the
    /// subquery's SelectList.
    fn validateColumnData(
        self: *QueryCoordinator,
        from_item: ?*const sqlbuilder.FromItem,
        expected_columns: []const *ColumnData,
    ) Error!void {
        const item = from_item orelse return;
        if (expected_columns.len == 0) return;

        var select_list: ?[]const *sqlbuilder.SelectListItem = null;
        switch (item.type) {
            .subquery => {
                // Go: "subquery FromItem has nil Subquery"
                const sub = item.subquery orelse return error.ValidationFailed;
                select_list = try self.getSelectListRecursive(sub);
            },
            // Table scans don't have SelectLists to validate.
            .table => return,
            // For other types (joins, ...) we may not have a direct
            // SelectList.
            else => return,
        }

        // Go: "could not extract SelectList from FromItem"
        const list = select_list orelse return error.ValidationFailed;

        // Go: "SelectList length mismatch: got %d items, expected %d"
        if (list.len != expected_columns.len) return error.ValidationFailed;

        // Validate each SelectListItem alias against the expected id-based
        // aliases (Go builds a set; the lists are small, scan linearly).
        for (list) |sel_item| {
            // Go: "SelectListItem at index %d has empty alias"
            if (sel_item.alias.len == 0) return error.ValidationFailed;

            var found = false;
            for (expected_columns) |col| {
                const expected_alias = try context.generateIDBasedAlias(self.alloc, col.name, col.id);
                if (std.mem.eql(u8, sel_item.alias, expected_alias)) {
                    found = true;
                    break;
                }
            }
            // Go: "... has unexpected alias '%s'"
            if (!found) return error.ValidationFailed;
        }
    }

    /// Go getSelectListRecursive: extracts the SelectList from a
    /// SelectStatement, following SELECT * subqueries recursively.
    fn getSelectListRecursive(
        self: *QueryCoordinator,
        stmt: *const sqlbuilder.SelectStatement,
    ) Error!?[]const *sqlbuilder.SelectListItem {
        if (stmt.set_operation) |set_op| {
            return self.getSelectListRecursive(set_op.items[0]);
        }

        if (stmt.select_list.len == 0) return null;

        // Check if this is a SELECT * query.
        if (stmt.select_list.len == 1) {
            const item = stmt.select_list[0];
            if (item.is_star_expansion or item.expression.type == .star) {
                // SELECT * - recurse into the FROM clause.
                if (stmt.from_clause) |from| {
                    if (from.type == .subquery) {
                        if (from.subquery) |sub| return self.getSelectListRecursive(sub);
                    }
                    if (from.type == .join) {
                        var items: std.ArrayList(*sqlbuilder.SelectListItem) = .empty;
                        const join = from.join orelse return error.ValidationFailed;
                        const left_sub = (join.left orelse return error.ValidationFailed).subquery orelse
                            return error.ValidationFailed;
                        const right_sub = (join.right orelse return error.ValidationFailed).subquery orelse
                            return error.ValidationFailed;
                        if (try self.getSelectListRecursive(left_sub)) |left_items| {
                            try items.appendSlice(self.alloc, left_items);
                        }
                        if (try self.getSelectListRecursive(right_sub)) |right_items| {
                            try items.appendSlice(self.alloc, right_items);
                        }
                        return try items.toOwnedSlice(self.alloc);
                    }
                }
            }
        }

        // Return the current SelectList.
        return stmt.select_list;
    }
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;
const analyzer_ffi = @import("../../analyzer_ffi.zig");

test "transformStatementNode transforms SELECT 1 AS x end-to-end" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const analyzed = try analyzer_ffi.analyzeNextStatement(alloc, "SELECT 1 AS x", 0, "{}");
    const config = context.TransformConfig{};
    const ctx = try TransformContext.init(alloc, &config);
    var coordinator = QueryCoordinator.init(alloc);

    const fragment = try coordinator.transformStatementNode(analyzed.node, ctx);
    try testing.expectEqualStrings(
        "SELECT\n1 AS `x`",
        try fragment.toString(alloc),
    );
    // Scope bookkeeping unwinds cleanly.
    try testing.expectEqualStrings("0", ctx.fragmentContext().getID());
}

test "transformScan rejects WITH-entry data" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    const config = context.TransformConfig{};
    const ctx = try TransformContext.init(alloc, &config);
    var coordinator = QueryCoordinator.init(alloc);

    const scan_data = ScanData{ .type = .with_entry };
    try testing.expectError(error.UnsupportedNode, coordinator.transformScan(scan_data, ctx));
    try testing.expectError(error.UnsupportedNode, with_entry_via_scan(&coordinator, ctx));
}

fn with_entry_via_scan(coordinator: *QueryCoordinator, ctx: *TransformContext) Error!*sqlbuilder.WithClause {
    // transformWithEntry with a non-with-entry payload is rejected too.
    return coordinator.transformWithEntry(ScanData{ .type = .project }, ctx);
}
