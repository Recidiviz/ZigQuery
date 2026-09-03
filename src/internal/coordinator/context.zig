const std = @import("std");
const sqlbuilder = @import("../sqlbuilder/sqlbuilder.zig");
const types_data = @import("types_data.zig");

pub const Error = types_data.Error;
pub const ColumnData = types_data.ColumnData;
pub const ScanData = types_data.ScanData;

const spec = @import("../spec.zig");

/// One query-parameter occurrence collected during extraction.
/// The driver uses the types to cast bound values.
pub const CollectedParam = struct {
    /// "?" for positional, "@name" for named parameters.
    identifier: []const u8 = "",
    type: ?*spec.Type = null,
};

pub const TransformConfig = struct {
    debug: bool = false,
};

pub fn defaultTransformConfig() TransformConfig {
    const debug = if (std.c.getenv("ZIGQUERY_DEBUG")) |v|
        std.mem.eql(u8, std.mem.sliceTo(v, 0), "true")
    else
        false;
    return .{ .debug = debug };
}

/// Replacement for Go's context.Context values consulted by the pipeline
/// (currentTimeFromContext etc. in later milestones).
pub const QueryContext = struct {
    current_time_unix_micros: ?i64 = null,
    debug: bool = false,
};

/// ColumnInfo stores metadata about available columns.
pub const ColumnInfo = struct {
    name: []const u8 = "",
    type: []const u8 = "",
    table_alias: []const u8 = "",
    expression: ?*sqlbuilder.SQLExpression = null,
    id: i64 = 0,
};

/// generateIDBasedAlias creates a unique column alias using the column ID.
pub fn generateIDBasedAlias(
    alloc: std.mem.Allocator,
    column_name: []const u8,
    column_id: i64,
) error{OutOfMemory}![]u8 {
    return std.fmt.allocPrint(alloc, "{s}__{d}", .{ column_name, column_id });
}

/// Go DefaultScopeToken (value type; ID() is the pre-formatted id string).
pub const ScopeToken = struct {
    id: usize,
    start_size: usize,
    id_str: []const u8,
};

pub const QualifiedColumnRef = struct {
    column_name: []const u8,
    table_alias: []const u8,
};

/// Go DefaultFragmentContext.
pub const FragmentContext = struct {
    alloc: std.mem.Allocator,
    /// Column ID -> Expression.
    column_map: std.AutoHashMap(i64, *sqlbuilder.SQLExpression),
    /// Column ID -> ColumnInfo.
    available_columns: std.AutoHashMap(i64, *ColumnInfo),
    /// Column ID -> ColumnData for reverse lookup (kept for parity with Go;
    /// like the original, nothing writes it yet).
    column_data: std.AutoHashMap(i64, *ColumnData),
    scopes: std.ArrayList(ScopeToken),
    count: usize,
    /// Maps column ID to scope alias.
    column_id_to_scope: std.AutoHashMap(i64, []const u8),
    /// Column ID -> the expression that computes it, not yet projected into
    /// any SELECT list. GoogleSQL SQLBuilder::pending_columns_ (sql_builder.h).
    ///
    /// A scan that is only a row source (a table, a WITH reference, an UNNEST)
    /// leaves its columns here instead of spending a subquery level to alias
    /// them, and whoever consumes them either references them in place or
    /// projects them when it materializes.
    ///
    /// **Invariant:** a column is pending *xor* resolvable through
    /// `column_id_to_scope` — never both, never neither. `takePending` is the
    /// only transition, and its callers must register the scope in the same
    /// step. Breaking this reads a column against the wrong scope, which is
    /// wrong results rather than a compile error.
    pending: std.AutoHashMap(i64, *sqlbuilder.SQLExpression),

    pub fn init(alloc: std.mem.Allocator) error{OutOfMemory}!*FragmentContext {
        const fc = try alloc.create(FragmentContext);
        fc.* = .{
            .alloc = alloc,
            .column_map = std.AutoHashMap(i64, *sqlbuilder.SQLExpression).init(alloc),
            .available_columns = std.AutoHashMap(i64, *ColumnInfo).init(alloc),
            .column_data = std.AutoHashMap(i64, *ColumnData).init(alloc),
            .scopes = .empty,
            .count = 0,
            .column_id_to_scope = std.AutoHashMap(i64, []const u8).init(alloc),
            .pending = std.AutoHashMap(i64, *sqlbuilder.SQLExpression).init(alloc),
        };
        return fc;
    }

    /// Records the expression computing `column_id`, to be projected later (or
    /// referenced in place).
    pub fn setPending(
        self: *FragmentContext,
        column_id: i64,
        expr: *sqlbuilder.SQLExpression,
    ) error{OutOfMemory}!void {
        try self.pending.put(column_id, expr);
    }

    pub fn getPending(self: *const FragmentContext, column_id: i64) ?*sqlbuilder.SQLExpression {
        return self.pending.get(column_id);
    }

    /// Consumes a pending expression: the caller is projecting it, so it stops
    /// being pending. See the invariant on `pending` — the caller must register
    /// the column's new scope in the same step.
    pub fn takePending(self: *FragmentContext, column_id: i64) ?*sqlbuilder.SQLExpression {
        if (self.pending.fetchRemove(column_id)) |kv| return kv.value;
        return null;
    }

    /// AddAvailableColumn adds a column to the available columns map.
    pub fn addAvailableColumn(
        self: *FragmentContext,
        column_id: i64,
        info: *ColumnInfo,
    ) error{OutOfMemory}!void {
        // Store by column ID for proper disambiguation.
        try self.available_columns.put(column_id, info);

        if (info.expression) |expr| {
            try self.column_map.put(column_id, expr);
        } else {
            // Create default column reference.
            const expr = try self.alloc.create(sqlbuilder.SQLExpression);
            expr.* = .{ .type = .column, .value = info.name };
            try self.column_map.put(column_id, expr);
        }
    }

    /// When transforming the columns for the base table of a DML statement,
    /// do not use aliases; use the underlying SQLite column names.
    pub fn addAvailableColumnsForDML(
        self: *FragmentContext,
        scan_data: *const ScanData,
    ) Error!void {
        const table_scan = scan_data.table_scan orelse return error.InvalidAST;
        for (scan_data.column_list) |col| {
            // Register scope alias.
            try self.registerColumnScope(col.id, table_scan.table_name);

            // Add to available columns (simple name, not qualified).
            const info = try self.alloc.create(ColumnInfo);
            info.* = .{
                .name = col.name,
                .expression = try sqlbuilder.newColumnExpression(self.alloc, col.name, null),
            };
            try self.addAvailableColumn(col.id, info);
        }
    }

    pub fn getID(self: *const FragmentContext) []const u8 {
        if (self.scopes.items.len == 0) return "0";
        return self.scopes.items[self.scopes.items.len - 1].id_str;
    }

    /// EnterScope enters a new scope.
    pub fn enterScope(self: *FragmentContext) error{OutOfMemory}!ScopeToken {
        self.count += 1;
        const token = ScopeToken{
            .id = self.count,
            .start_size = self.column_map.count(),
            .id_str = try std.fmt.allocPrint(self.alloc, "{d}", .{self.count}),
        };
        try self.scopes.append(self.alloc, token);
        return token;
    }

    /// ExitScope exits the current scope (removes scopes until the matching
    /// token is found, like the Go original).
    pub fn exitScope(self: *FragmentContext, token: ScopeToken) void {
        var i = self.scopes.items.len;
        while (i > 0) {
            i -= 1;
            if (self.scopes.items[i].id == token.id) {
                self.scopes.shrinkRetainingCapacity(i);
                break;
            }
        }
    }

    /// GetQualifiedColumnRef returns the qualified column reference for a
    /// column ID. Go panics when the column is missing; the port returns
    /// error.ColumnNotFound ("transformers must add columns before getting
    /// qualified refs").
    pub fn getQualifiedColumnRef(
        self: *const FragmentContext,
        column_id: i64,
    ) Error!QualifiedColumnRef {
        if (self.column_id_to_scope.get(column_id)) |scope_alias| {
            const info = self.available_columns.get(column_id) orelse
                return .{ .column_name = "", .table_alias = "" };
            return .{ .column_name = info.name, .table_alias = scope_alias };
        }
        return error.ColumnNotFound;
    }

    pub fn getQualifiedColumnExpression(
        self: *const FragmentContext,
        column_id: i64,
    ) Error!*sqlbuilder.SQLExpression {
        const ref = try self.getQualifiedColumnRef(column_id);
        return sqlbuilder.newColumnExpression(self.alloc, ref.column_name, null);
    }

    /// RegisterColumnScope registers a mapping from column ID to scope alias.
    pub fn registerColumnScope(
        self: *FragmentContext,
        column_id: i64,
        scope_alias: []const u8,
    ) error{OutOfMemory}!void {
        try self.column_id_to_scope.put(column_id, scope_alias);
    }

    /// RegisterColumnScopeMapping registers scope mappings for a column list.
    pub fn registerColumnScopeMapping(
        self: *FragmentContext,
        scope_alias: []const u8,
        columns: []const *ColumnData,
    ) error{OutOfMemory}!void {
        for (columns) |col| {
            try self.column_id_to_scope.put(col.id, scope_alias);
            const info = try self.alloc.create(ColumnInfo);
            info.* = .{
                .name = try generateIDBasedAlias(self.alloc, col.name, col.id),
                .id = col.id,
            };
            try self.available_columns.put(col.id, info);
        }
    }
};

/// Go Scope (context scope with variable bindings).
pub const Scope = struct {
    id: usize,
    variables: std.StringHashMap(*sqlbuilder.SQLExpression),
    parent: ?*Scope,
};

/// Go ScopeManager (nested scopes; no mutex — single-threaded).
pub const ScopeManager = struct {
    alloc: std.mem.Allocator,
    count: usize,
    scopes: std.ArrayList(*Scope),

    pub fn init(alloc: std.mem.Allocator) error{OutOfMemory}!*ScopeManager {
        const sm = try alloc.create(ScopeManager);
        sm.* = .{ .alloc = alloc, .count = 0, .scopes = .empty };
        return sm;
    }

    pub fn enterScope(self: *ScopeManager) error{OutOfMemory}!*Scope {
        const parent: ?*Scope = if (self.scopes.items.len > 0)
            self.scopes.items[self.scopes.items.len - 1]
        else
            null;

        self.count += 1;
        const scope = try self.alloc.create(Scope);
        scope.* = .{
            .id = self.count,
            .variables = std.StringHashMap(*sqlbuilder.SQLExpression).init(self.alloc),
            .parent = parent,
        };
        try self.scopes.append(self.alloc, scope);
        return scope;
    }

    pub fn exitScope(self: *ScopeManager) void {
        if (self.scopes.items.len > 0) {
            self.scopes.shrinkRetainingCapacity(self.scopes.items.len - 1);
        }
    }

    pub fn currentScope(self: *const ScopeManager) ?*Scope {
        if (self.scopes.items.len == 0) return null;
        return self.scopes.items[self.scopes.items.len - 1];
    }
};

/// Go DefaultTransformContext. WithFragmentContext keeps Go's value-copy
/// semantics: the copy shares scope/withMappings (reference types in Go)
/// but gets its own fragment-context pointer and recursive-CTE name.
pub const TransformContext = struct {
    query_ctx: QueryContext = .{},
    fragment_context: *FragmentContext,
    config: *const TransformConfig,
    scope: *ScopeManager,
    /// WITH query name -> position-based column mappings.
    with_mappings: *std.StringHashMap([]const []const u8),
    /// Parameter occurrences collected during extraction, in traversal
    /// order (Go getParamsFromNode; shared across context copies).
    collected_params: *std.ArrayList(CollectedParam),
    /// Allocator backing collected_params appends.
    alloc: std.mem.Allocator,
    /// Current recursive CTE being defined.
    recursive_cte_name: []const u8 = "",
    /// User-defined FunctionSpec lookup for CallSQL inlining (Go
    /// withFuncMap / funcMapFromContext). Set by the driver before
    /// transforming; null means no UDFs are registered.
    func_map: ?*const spec.FuncMap = null,

    /// Go funcMapFromContext: the UDF spec for `name`, or null.
    pub fn findFunctionSpec(self: *const TransformContext, name: []const u8) ?*spec.FunctionSpec {
        const map = self.func_map orelse return null;
        return map.get(name);
    }

    pub fn init(
        alloc: std.mem.Allocator,
        config: *const TransformConfig,
    ) error{OutOfMemory}!*TransformContext {
        const mappings = try alloc.create(std.StringHashMap([]const []const u8));
        mappings.* = std.StringHashMap([]const []const u8).init(alloc);
        const params = try alloc.create(std.ArrayList(CollectedParam));
        params.* = .empty;
        const ctx = try alloc.create(TransformContext);
        ctx.* = .{
            .fragment_context = try FragmentContext.init(alloc),
            .config = config,
            .scope = try ScopeManager.init(alloc),
            .with_mappings = mappings,
            .collected_params = params,
            .alloc = alloc,
        };
        return ctx;
    }

    /// Records a parameter occurrence (Go getParamsFromNode ordering rules:
    /// named parameters are deduplicated by identifier, every positional
    /// "?" occurrence is kept).
    pub fn addCollectedParameter(
        self: *TransformContext,
        identifier: []const u8,
        param_type: ?*spec.Type,
    ) error{OutOfMemory}!void {
        if (identifier.len > 0 and identifier[0] == '@') {
            for (self.collected_params.items) |p| {
                if (std.mem.eql(u8, p.identifier, identifier)) return;
            }
        }
        try self.collected_params.append(self.alloc, .{
            .identifier = identifier,
            .type = param_type,
        });
    }

    pub fn fragmentContext(self: *const TransformContext) *FragmentContext {
        return self.fragment_context;
    }

    /// WithFragmentContext returns a new context with an updated fragment
    /// context (Go: struct copy with a new fragmentContext pointer).
    pub fn withFragmentContext(
        self: *const TransformContext,
        alloc: std.mem.Allocator,
        fc: *FragmentContext,
    ) error{OutOfMemory}!*TransformContext {
        const new_ctx = try alloc.create(TransformContext);
        new_ctx.* = self.*; // copy
        new_ctx.fragment_context = fc;
        return new_ctx;
    }

    /// AddWithEntryColumnMapping adds column mappings for a WITH query.
    pub fn addWithEntryColumnMapping(
        self: *TransformContext,
        alloc: std.mem.Allocator,
        name: []const u8,
        columns: []const *ColumnData,
    ) error{OutOfMemory}!void {
        const mapping = try alloc.alloc([]const u8, columns.len);
        for (columns, 0..) |col, i| {
            mapping[i] = try generateIDBasedAlias(alloc, col.name, col.id);
        }
        try self.with_mappings.put(name, mapping);
    }

    /// GetWithEntryMapping retrieves column mappings for a WITH query.
    pub fn getWithEntryMapping(
        self: *const TransformContext,
        name: []const u8,
    ) ?[]const []const u8 {
        return self.with_mappings.get(name);
    }

    pub fn setRecursiveCTEName(self: *TransformContext, name: []const u8) void {
        self.recursive_cte_name = name;
    }

    pub fn getRecursiveCTEName(self: *const TransformContext) []const u8 {
        return self.recursive_cte_name;
    }
};

/// Go TransformResult.
pub const TransformResult = struct {
    fragment: sqlbuilder.SQLFragment,
};

// ----------------------------------------------------------------------
// Tests
// ----------------------------------------------------------------------

const testing = std.testing;

test "generateIDBasedAlias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alias = try generateIDBasedAlias(arena.allocator(), "col", 42);
    try testing.expectEqualStrings("col__42", alias);
}

test "fragment context scope enter/exit and GetID" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fc = try FragmentContext.init(alloc);
    try testing.expectEqualStrings("0", fc.getID());

    const t1 = try fc.enterScope();
    try testing.expectEqualStrings("1", fc.getID());
    const t2 = try fc.enterScope();
    try testing.expectEqualStrings("2", fc.getID());

    fc.exitScope(t2);
    try testing.expectEqualStrings("1", fc.getID());
    fc.exitScope(t1);
    try testing.expectEqualStrings("0", fc.getID());

    // Counter keeps increasing across scopes (Go semantics).
    const t3 = try fc.enterScope();
    try testing.expectEqualStrings("3", fc.getID());
    fc.exitScope(t3);
}

test "RegisterColumnScopeMapping + GetQualifiedColumnRef" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const fc = try FragmentContext.init(alloc);
    var col1 = ColumnData{ .id = 7, .name = "a" };
    var col2 = ColumnData{ .id = 8, .name = "b" };
    const cols = [_]*ColumnData{ &col1, &col2 };
    try fc.registerColumnScopeMapping("project_scan_1", &cols);

    const ref = try fc.getQualifiedColumnRef(7);
    try testing.expectEqualStrings("a__7", ref.column_name);
    try testing.expectEqualStrings("project_scan_1", ref.table_alias);

    const expr = try fc.getQualifiedColumnExpression(8);
    try testing.expectEqual(sqlbuilder.ExpressionType.column, expr.type);
    try testing.expectEqualStrings("b__8", expr.value);

    // Missing column: Go panics; the port errors.
    try testing.expectError(error.ColumnNotFound, fc.getQualifiedColumnRef(999));
}

test "transform context WITH mappings and fragment-context copy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const config = TransformConfig{};
    const ctx = try TransformContext.init(alloc, &config);

    var col = ColumnData{ .id = 3, .name = "x" };
    const cols = [_]*ColumnData{&col};
    try ctx.addWithEntryColumnMapping(alloc, "t", &cols);
    const mapping = ctx.getWithEntryMapping("t").?;
    try testing.expectEqual(@as(usize, 1), mapping.len);
    try testing.expectEqualStrings("x__3", mapping[0]);
    try testing.expect(ctx.getWithEntryMapping("missing") == null);

    // WithFragmentContext: copy shares withMappings, swaps fragment context.
    const fc2 = try FragmentContext.init(alloc);
    const ctx2 = try ctx.withFragmentContext(alloc, fc2);
    try testing.expect(ctx2.fragment_context == fc2);
    try testing.expect(ctx2.fragment_context != ctx.fragment_context);
    try testing.expect(ctx2.getWithEntryMapping("t") != null);

    ctx2.setRecursiveCTEName("rec");
    try testing.expectEqualStrings("rec", ctx2.getRecursiveCTEName());
    try testing.expectEqualStrings("", ctx.getRecursiveCTEName());
}

test "scope manager parent chain" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const sm = try ScopeManager.init(alloc);
    try testing.expect(sm.currentScope() == null);
    const s1 = try sm.enterScope();
    const s2 = try sm.enterScope();
    try testing.expect(s2.parent == s1);
    try testing.expect(sm.currentScope() == s2);
    sm.exitScope();
    try testing.expect(sm.currentScope() == s1);
    sm.exitScope();
    try testing.expect(sm.currentScope() == null);
}
