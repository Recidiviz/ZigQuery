//! Object-based SQL generation layer, a faithful port of go-zetasqlite's
//! internal/sqlbuilder_sqlbuilder.go ("SQLFragment" object model + SQLWriter).
//!
//! Rendering matches the Go original, including its quirks: WriteLine emits
//! the indent prefix wherever the cursor currently is (which produces trailing
//! "  " runs before newlines mid-statement), and ExpressionType.cast renders
//! nothing (the Go switch has no case for it).
//!
//! One deliberate divergence. Go's WithClause always writes
//! " AS MATERIALIZED \t(" and never reads its own `materialized` field; this
//! honours the field, so a CTE is materialized only when something asks for
//! it. Since 3.35 SQLite already applies the right heuristic on its own —
//! materialize a CTE referenced more than once, inline it otherwise — and
//! forcing the keyword takes that away. For a single-use CTE it is the
//! difference between an index seek and a full scan plus a materialization:
//!
//!     WITH c AS MATERIALIZED (SELECT a AS a1 FROM t) SELECT * FROM c WHERE a1 = 5
//!       |--MATERIALIZE c / |  `--SCAN t / `--SCAN c
//!     WITH c AS            (SELECT a AS a1 FROM t) SELECT * FROM c WHERE a1 = 5
//!       `--SEARCH t USING INDEX ta (a=?)
//!
//! The corpus cannot show this (tiny unindexed in-memory tables) and its
//! timing is unchanged; the evidence is the plan.
//!
//! All allocation goes through a caller-provided allocator (an arena in
//! practice); no deinit methods are provided.
//!
//! One measurement, so the obvious optimization is not re-attempted: rendering
//! compactly (no indentation, no newlines — the writer supports it already via
//! use_newlines) removed 13.2% of the bytes and changed prepare time by +0.2%,
//! i.e. nothing. Whitespace is free to tokenize, so the quirks above cost
//! readability of the output and nothing else.
//!
//! Prepare cost is per subquery *level*, not per byte. Trimming text is
//! worthless; removing nesting works — and that is no longer this file's
//! problem. The transformer used to emit one SELECT per resolved scan; it now
//! writes each scan into a free clause slot of the query being built and takes
//! a level only when the slot it needs is occupied. See
//! src/internal/sqlbuilder/query_expr.zig for the rules and
//! docs/SLOT_MODEL_PLAN.md for what that bought (-40% levels, -34% bytes).
//!
//! So: a change here that trades output size for anything at all is very
//! probably not worth it. A change that removes a *level* still is.
// ephor:ignore-file ZA103 ZA301 ZA302 ZA304 ZT105

const std = @import("std");

pub const Error = std.mem.Allocator.Error;

// ---------------------------------------------------------------------------
// SQLWriter
// ---------------------------------------------------------------------------

/// SQLWriter handles SQL string generation with proper formatting.
/// Mirrors Go's SQLWriter exactly: `write` never indents; `writeLine` writes
/// the indent prefix, then the string, then "\n" (or " " when use_newlines is
/// false, in which case no indent prefix is written either).
pub const SQLWriter = struct {
    allocator: std.mem.Allocator,
    builder: std.ArrayList(u8) = .empty,
    indent_level: usize = 0,
    use_newlines: bool = true,

    pub fn init(allocator: std.mem.Allocator) SQLWriter {
        return .{ .allocator = allocator };
    }

    pub fn write(self: *SQLWriter, s: []const u8) Error!void {
        try self.builder.appendSlice(self.allocator, s);
    }

    pub fn writeLine(self: *SQLWriter, s: []const u8) Error!void {
        if (self.use_newlines) {
            for (0..self.indent_level) |_| {
                try self.builder.appendSlice(self.allocator, "  ");
            }
        }
        try self.builder.appendSlice(self.allocator, s);
        if (self.use_newlines) {
            try self.builder.append(self.allocator, '\n');
        } else {
            try self.builder.append(self.allocator, ' ');
        }
    }

    pub fn indent(self: *SQLWriter) void {
        self.indent_level += 1;
    }

    pub fn dedent(self: *SQLWriter) void {
        if (self.indent_level > 0) self.indent_level -= 1;
    }

    /// Current contents of the writer (borrowed; valid until the next write).
    pub fn string(self: *const SQLWriter) []const u8 {
        return self.builder.items;
    }
};

/// Go strings.TrimSpace over the ASCII whitespace that can appear in output.
const whitespace = " \t\n\x0b\x0c\r";

/// Renders `fragment` (a pointer to any type with writeSql) into a fresh
/// writer, mirroring the Go per-type String() implementations.
fn render(
    allocator: std.mem.Allocator,
    fragment: anytype,
    use_newlines: bool,
    trim_result: bool,
) Error![]u8 {
    var writer = SQLWriter.init(allocator);
    writer.use_newlines = use_newlines;
    try fragment.writeSql(&writer);
    if (trim_result) {
        const trimmed = std.mem.trim(u8, writer.builder.items, whitespace);
        return allocator.dupe(u8, trimmed);
    }
    return writer.builder.toOwnedSlice(allocator);
}

fn create(allocator: std.mem.Allocator, value: anytype) Error!*@TypeOf(value) {
    const ptr = try allocator.create(@TypeOf(value));
    ptr.* = value;
    return ptr;
}

fn writeQuoted(writer: *SQLWriter, name: []const u8) Error!void {
    try writer.write("`");
    try writer.write(name);
    try writer.write("`");
}

// ---------------------------------------------------------------------------
// Enums
// ---------------------------------------------------------------------------

/// SelectType represents different SELECT variants.
pub const SelectType = enum {
    standard,
    distinct,
    all,
    as_struct,
    as_value,
};

/// ExpressionType represents different types of SQL expressions.
pub const ExpressionType = enum {
    column,
    literal,
    parameter,
    function,
    list,
    unary,
    binary,
    subquery,
    star,
    case,
    exists,
    cast,
};

/// FromItemType represents different types of FROM clause items.
pub const FromItemType = enum {
    table,
    subquery,
    join,
    with_ref,
    table_function,
    unnest,
    single_row,
};

/// JoinType represents different types of JOINs.
pub const JoinType = enum {
    inner,
    left,
    right,
    full,
    cross,
};

// ---------------------------------------------------------------------------
// Expressions
// ---------------------------------------------------------------------------

/// CaseExpression represents SQL CASE expressions.
pub const CaseExpression = struct {
    /// Optional expression after CASE (for CASE expr WHEN...).
    case_expr: ?*SQLExpression = null,
    /// WHEN condition THEN result pairs.
    when_clauses: []const *WhenClause = &.{},
    /// Optional ELSE expression.
    else_expr: ?*SQLExpression = null,

    pub fn writeSql(self: *const CaseExpression, writer: *SQLWriter) Error!void {
        try writer.write("CASE");
        if (self.case_expr) |case_expr| {
            try writer.write(" ");
            try case_expr.writeSql(writer);
        }
        for (self.when_clauses) |when_clause| {
            try writer.write(" WHEN ");
            try when_clause.condition.writeSql(writer);
            try writer.write(" THEN ");
            try when_clause.result.writeSql(writer);
        }
        if (self.else_expr) |else_expr| {
            try writer.write(" ELSE ");
            try else_expr.writeSql(writer);
        }
        try writer.write(" END");
    }

    pub fn toString(self: *const CaseExpression, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

/// WhenClause represents a WHEN-THEN clause in a CASE expression.
pub const WhenClause = struct {
    condition: *SQLExpression,
    result: *SQLExpression,
};

/// ExistsExpression represents SQL EXISTS expressions.
pub const ExistsExpression = struct {
    subquery: ?*SelectStatement = null,

    pub fn writeSql(self: *const ExistsExpression, writer: *SQLWriter) Error!void {
        try writer.write("EXISTS (");
        if (self.subquery) |subquery| {
            try subquery.writeSql(writer);
        }
        try writer.write(")");
    }

    pub fn toString(self: *const ExistsExpression, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

/// ListExpression represents SQL list expressions.
pub const ListExpression = struct {
    expressions: []const *SQLExpression = &.{},

    pub fn writeSql(self: *const ListExpression, writer: *SQLWriter) Error!void {
        // Go renders each element through expr.String() (a fresh writer whose
        // use_newlines depends on the element), then writes that string.
        try writer.write("(");
        for (self.expressions, 0..) |expr, i| {
            try writer.write(try expr.toString(writer.allocator));
            if (i != self.expressions.len - 1) {
                try writer.write(",");
            }
        }
        try writer.write(")");
    }

    pub fn toString(self: *const ListExpression, allocator: std.mem.Allocator) Error![]u8 {
        // No String() in Go (never used as a standalone fragment there).
        return render(allocator, self, false, false);
    }
};

/// UnaryExpression represents SQL unary expressions.
pub const UnaryExpression = struct {
    operator: []const u8 = "",
    expression: *SQLExpression,

    pub fn writeSql(self: *const UnaryExpression, writer: *SQLWriter) Error!void {
        try writer.write(self.operator);
        try writer.write(" (");
        try self.expression.writeSql(writer);
        try writer.write(")");
    }

    pub fn toString(self: *const UnaryExpression, allocator: std.mem.Allocator) Error![]u8 {
        // No String() in Go (never used as a standalone fragment there).
        return render(allocator, self, false, false);
    }
};

pub const BinaryExpression = struct {
    left: ?*SQLExpression = null,
    right: ?*SQLExpression = null,
    operator: []const u8 = "",

    /// OR binds looser than AND, so an OR operand nested under an AND needs
    /// parens to keep its grouping: writing `(a OR b) AND c` flat as
    /// `a OR b AND c` reparses, by SQL's own precedence, as `a OR (b AND c)`.
    /// Every other operator pair this builder produces — comparisons and IN
    /// under AND/OR, AND under OR — already binds correctly unparenthesized.
    fn operandNeedsParens(self: *const BinaryExpression, operand: *const SQLExpression) bool {
        if (!std.mem.eql(u8, self.operator, "AND")) return false;
        const inner = operand.binary_expression orelse return false;
        return std.mem.eql(u8, inner.operator, "OR");
    }

    fn writeOperand(
        self: *const BinaryExpression,
        writer: *SQLWriter,
        operand: *const SQLExpression,
    ) Error!void {
        if (self.operandNeedsParens(operand)) {
            try writer.write("(");
            try operand.writeSql(writer);
            try writer.write(")");
        } else {
            try operand.writeSql(writer);
        }
    }

    pub fn writeSql(self: *const BinaryExpression, writer: *SQLWriter) Error!void {
        if (self.left) |left| {
            try self.writeOperand(writer, left);
        }
        try writer.write(" ");
        try writer.write(self.operator);
        try writer.write(" ");
        if (self.right) |right| {
            try self.writeOperand(writer, right);
        }
    }

    pub fn toString(self: *const BinaryExpression, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

/// SQLExpression represents any SQL expression.
pub const SQLExpression = struct {
    type: ExpressionType = .column,
    value: []const u8 = "",
    list_expression: ?*ListExpression = null,
    unary_expression: ?*UnaryExpression = null,
    binary_expression: ?*BinaryExpression = null,
    function_call: ?*FunctionCall = null,
    subquery: ?*SelectStatement = null,
    case_expression: ?*CaseExpression = null,
    exists_expr: ?*ExistsExpression = null,
    alias: []const u8 = "",
    table_alias: []const u8 = "",
    collation: []const u8 = "",

    pub fn writeSql(self: *const SQLExpression, writer: *SQLWriter) Error!void {
        switch (self.type) {
            .column => {
                if (self.table_alias.len > 0) {
                    try writeQuoted(writer, self.table_alias);
                    try writer.write(".");
                    try writeQuoted(writer, self.value);
                } else {
                    try writeQuoted(writer, self.value);
                }
            },
            .literal => try writer.write(self.value),
            .list => try self.list_expression.?.writeSql(writer),
            .unary => try self.unary_expression.?.writeSql(writer),
            .binary => try self.binary_expression.?.writeSql(writer),
            .function => {
                if (self.function_call) |function_call| {
                    try function_call.writeSql(writer);
                }
            },
            .subquery => {
                try writer.write("(");
                if (self.subquery) |subquery| {
                    try subquery.writeSql(writer);
                }
                try writer.write(")");
            },
            .star => {
                if (self.table_alias.len > 0) {
                    try writer.write(self.table_alias);
                    try writer.write(".*");
                } else {
                    try writer.write("*");
                }
            },
            .case => {
                if (self.case_expression) |case_expression| {
                    try case_expression.writeSql(writer);
                }
            },
            .exists => {
                if (self.exists_expr) |exists_expr| {
                    try exists_expr.writeSql(writer);
                }
            },
            .parameter => try writer.write(self.value),
            // Go's switch has no case for ExpressionTypeCast: renders nothing.
            .cast => {},
        }

        // Add collation if specified.
        if (self.collation.len > 0) {
            try writer.write(" COLLATE ");
            try writer.write(self.collation);
        }

        if (self.alias.len > 0 and
            !(self.type == .column and std.mem.eql(u8, self.alias, self.value)))
        {
            try writer.write(" AS ");
            try writeQuoted(writer, self.alias);
        }
    }

    pub fn toString(self: *const SQLExpression, allocator: std.mem.Allocator) Error![]u8 {
        // Go: writer.useNewlines = e.Subquery != nil
        return render(allocator, self, self.subquery != null, false);
    }
};

/// FunctionCall represents SQL function calls.
pub const FunctionCall = struct {
    name: []const u8 = "",
    arguments: []const *SQLExpression = &.{},
    is_distinct: bool = false,
    window_spec: ?*WindowSpecification = null,

    pub fn writeSql(self: *const FunctionCall, writer: *SQLWriter) Error!void {
        try writer.write(self.name);
        try writer.write("(");
        if (self.is_distinct) {
            try writer.write("DISTINCT ");
        }
        for (self.arguments, 0..) |arg, i| {
            if (i > 0) {
                try writer.write(", ");
            }
            try arg.writeSql(writer);
        }
        try writer.write(")");
        if (self.window_spec) |window_spec| {
            try writer.write(" OVER (");
            try window_spec.writeSql(writer);
            try writer.write(")");
        }
    }

    pub fn toString(self: *const FunctionCall, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

/// WindowSpecification represents OVER clause specifications.
pub const WindowSpecification = struct {
    partition_by: []const *SQLExpression = &.{},
    order_by: []const *OrderByItem = &.{},
    frame_clause: ?*FrameClause = null,

    pub fn writeSql(self: *const WindowSpecification, writer: *SQLWriter) Error!void {
        if (self.partition_by.len > 0) {
            try writer.write("PARTITION BY ");
            for (self.partition_by, 0..) |expr, i| {
                if (i > 0) {
                    try writer.write(", ");
                }
                try expr.writeSql(writer);
            }
        }

        if (self.order_by.len > 0) {
            if (self.partition_by.len > 0) {
                try writer.write(" ");
            }
            try writer.write("ORDER BY ");
            for (self.order_by, 0..) |item, i| {
                if (i > 0) {
                    try writer.write(", ");
                }
                try item.writeSql(writer);
            }
        }

        if (self.frame_clause) |frame_clause| {
            if (self.partition_by.len > 0 or self.order_by.len > 0) {
                try writer.write(" ");
            }
            try frame_clause.writeSql(writer);
        }
    }

    pub fn toString(self: *const WindowSpecification, allocator: std.mem.Allocator) Error![]u8 {
        // No String() in Go (never used as a standalone fragment there).
        return render(allocator, self, false, false);
    }
};

/// FrameClause represents window frame specifications.
pub const FrameClause = struct {
    /// ROWS, RANGE, GROUPS
    unit: []const u8 = "",
    start: *FrameBound,
    end: ?*FrameBound = null,

    pub fn writeSql(self: *const FrameClause, writer: *SQLWriter) Error!void {
        try writer.write(self.unit);
        if (self.end) |end| {
            try writer.write(" BETWEEN ");
            try self.start.writeSql(writer);
            try writer.write(" AND ");
            try end.writeSql(writer);
        } else {
            try writer.write(" ");
            try self.start.writeSql(writer);
        }
    }

    pub fn toString(self: *const FrameClause, allocator: std.mem.Allocator) Error![]u8 {
        // No String() in Go (never used as a standalone fragment there).
        return render(allocator, self, false, false);
    }
};

/// FrameBound represents frame boundary specifications.
pub const FrameBound = struct {
    /// UNBOUNDED, CURRENT, PRECEDING, FOLLOWING
    type: []const u8 = "",
    offset: ?*SQLExpression = null,

    pub fn writeSql(self: *const FrameBound, writer: *SQLWriter) Error!void {
        if (self.offset) |offset| {
            try offset.writeSql(writer);
            try writer.write(" ");
        }
        try writer.write(self.type);
    }

    pub fn toString(self: *const FrameBound, allocator: std.mem.Allocator) Error![]u8 {
        // No String() in Go (never used as a standalone fragment there).
        return render(allocator, self, false, false);
    }
};

// ---------------------------------------------------------------------------
// SELECT components
// ---------------------------------------------------------------------------

/// One column REPLACE'd in a SELECT * REPLACE (...) expansion.
/// (Go uses map[string]*SQLExpression, whose iteration order is random; the
/// Zig port uses an ordered slice of pairs so output is deterministic.)
pub const ReplaceColumn = struct {
    column: []const u8,
    expression: *SQLExpression,
};

/// SelectListItem represents an item in the SELECT clause.
pub const SelectListItem = struct {
    expression: *SQLExpression,
    alias: []const u8 = "",
    is_star_expansion: bool = false,
    /// For SELECT * EXCEPT
    except_columns: []const []const u8 = &.{},
    /// For SELECT * REPLACE
    replace_columns: []const ReplaceColumn = &.{},

    pub fn writeSql(self: *const SelectListItem, writer: *SQLWriter) Error!void {
        if (self.is_star_expansion) {
            try self.expression.writeSql(writer);
            if (self.except_columns.len > 0) {
                try writer.write(" EXCEPT (");
                for (self.except_columns, 0..) |col, i| {
                    if (i > 0) {
                        try writer.write(", ");
                    }
                    try writeQuoted(writer, col);
                }
                try writer.write(")");
            }
            if (self.replace_columns.len > 0) {
                try writer.write(" REPLACE (");
                for (self.replace_columns, 0..) |replace, i| {
                    if (i > 0) {
                        try writer.write(", ");
                    }
                    try replace.expression.writeSql(writer);
                    try writer.write(" AS ");
                    try writeQuoted(writer, replace.column);
                }
                try writer.write(")");
            }
        } else {
            try self.expression.writeSql(writer);
            if (self.alias.len > 0 and
                !(self.expression.type == .column and
                    std.mem.eql(u8, self.alias, self.expression.value)))
            {
                try writer.write(" AS ");
                try writeQuoted(writer, self.alias);
            }
        }
    }

    pub fn toString(self: *const SelectListItem, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

/// TableReference represents a table reference in SQL.
pub const TableReference = struct {
    table_name: []const u8 = "",
    alias: []const u8 = "",
};

/// FromItem represents items in the FROM clause.
pub const FromItem = struct {
    type: FromItemType = .table,
    table_name: []const u8 = "",
    alias: []const u8 = "",
    subquery: ?*SelectStatement = null,
    join: ?*JoinClause = null,
    with_ref: []const u8 = "",
    table_function: ?*TableFunction = null,
    unnest_expr: ?*SQLExpression = null,
    hints: []const []const u8 = &.{},

    pub fn writeSql(self: *const FromItem, writer: *SQLWriter) Error!void {
        switch (self.type) {
            .table => {
                try writeQuoted(writer, self.table_name);
                if (self.alias.len > 0) {
                    try writer.write(" AS ");
                    try writeQuoted(writer, self.alias);
                }
            },
            .subquery => {
                try writer.write("(\n");
                if (self.subquery) |subquery| {
                    writer.indent();
                    try subquery.writeSql(writer);
                    writer.dedent();
                }
                try writer.write("\n)");
                if (self.alias.len > 0) {
                    try writer.write(" AS ");
                    try writeQuoted(writer, self.alias);
                }
            },
            .join => {
                if (self.join) |join| {
                    try join.writeSql(writer);
                }
            },
            .with_ref => {
                try writer.write(self.with_ref);
                if (self.alias.len > 0) {
                    try writer.write(" AS ");
                    try writeQuoted(writer, self.alias);
                }
            },
            .table_function => {
                if (self.table_function) |table_function| {
                    try table_function.writeSql(writer);
                }
                if (self.alias.len > 0) {
                    try writer.write(" AS ");
                    try writeQuoted(writer, self.alias);
                }
            },
            .unnest => {
                try writer.write("UNNEST(");
                if (self.unnest_expr) |unnest_expr| {
                    try unnest_expr.writeSql(writer);
                }
                try writer.write(")");
                if (self.alias.len > 0) {
                    try writer.write(" AS ");
                    try writeQuoted(writer, self.alias);
                }
            },
            // Go's switch has no case for FromItemTypeSingleRow: renders nothing.
            .single_row => {},
        }
    }

    pub fn toString(self: *const FromItem, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, false);
    }
};

/// JoinClause represents JOIN operations.
pub const JoinClause = struct {
    type: JoinType = .inner,
    left: ?*FromItem = null,
    right: ?*FromItem = null,
    condition: ?*SQLExpression = null,
    using: []const []const u8 = &.{},

    pub fn writeSql(self: *const JoinClause, writer: *SQLWriter) Error!void {
        if (self.left) |left| {
            try left.writeSql(writer);
        }

        switch (self.type) {
            .inner => try writer.write(" INNER JOIN "),
            .left => try writer.write(" LEFT JOIN "),
            .right => try writer.write(" RIGHT JOIN "),
            .full => try writer.write(" FULL OUTER JOIN "),
            .cross => try writer.write(" CROSS JOIN "),
        }

        if (self.right) |right| {
            try right.writeSql(writer);
        }

        if (self.type != .cross) {
            if (self.using.len > 0) {
                try writer.write(" USING (");
                for (self.using, 0..) |col, i| {
                    if (i > 0) {
                        try writer.write(", ");
                    }
                    try writer.write(col);
                }
                try writer.write(")");
            } else if (self.condition) |condition| {
                try writer.write(" ON ");
                try condition.writeSql(writer);
            }
        }
    }

    pub fn toString(self: *const JoinClause, allocator: std.mem.Allocator) Error![]u8 {
        // No String() in Go (never used as a standalone fragment there).
        return render(allocator, self, false, false);
    }
};

/// TableFunction represents table-valued functions.
pub const TableFunction = struct {
    name: []const u8 = "",
    arguments: []const *SQLExpression = &.{},

    pub fn writeSql(self: *const TableFunction, writer: *SQLWriter) Error!void {
        try writer.write(self.name);
        try writer.write("(");
        for (self.arguments, 0..) |arg, i| {
            if (i > 0) {
                try writer.write(", ");
            }
            try arg.writeSql(writer);
        }
        try writer.write(")");
    }

    pub fn toString(self: *const TableFunction, allocator: std.mem.Allocator) Error![]u8 {
        // No String() in Go (never used as a standalone fragment there).
        return render(allocator, self, false, false);
    }
};

/// OrderByItem represents items in ORDER BY clause.
pub const OrderByItem = struct {
    expression: *SQLExpression,
    /// ASC, DESC
    direction: []const u8 = "",
    /// NULLS FIRST, NULLS LAST
    nulls_order: []const u8 = "",

    pub fn writeSql(self: *const OrderByItem, writer: *SQLWriter) Error!void {
        try self.expression.writeSql(writer);
        if (self.direction.len > 0) {
            try writer.write(" ");
            try writer.write(self.direction);
        }
        if (self.nulls_order.len > 0) {
            try writer.write(" ");
            try writer.write(self.nulls_order);
        }
    }

    pub fn toString(self: *const OrderByItem, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

/// WithClause represents CTE (Common Table Expression) definitions.
pub const WithClause = struct {
    name: []const u8 = "",
    /// Emits `AS MATERIALIZED` when set. The Go original ignores this field
    /// and always materializes; see the note in the module header.
    materialized: bool = false,
    recursive: bool = false,
    columns: []const []const u8 = &.{},
    query: ?*SelectStatement = null,

    pub fn writeSql(self: *const WithClause, writer: *SQLWriter) Error!void {
        try writeQuoted(writer, self.name);
        if (self.columns.len > 0) {
            try writer.write(" (");
            for (self.columns, 0..) |col, i| {
                if (i > 0) {
                    try writer.write(", ");
                }
                try writer.write(col);
            }
            try writer.write(")");
        }
        // The Go source contains a literal tab here: " AS MATERIALIZED \t(".
        try writer.write(if (self.materialized) " AS MATERIALIZED \t(" else " AS \t(");
        try writer.writeLine("");
        writer.indent();
        if (self.query) |query| {
            try query.writeSql(writer);
        }
        writer.dedent();
        try writer.writeLine(")");
    }

    pub fn toString(self: *const WithClause, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

/// SetOperation represents UNION, INTERSECT, EXCEPT operations.
pub const SetOperation = struct {
    /// UNION, INTERSECT, EXCEPT
    type: []const u8 = "",
    /// ALL, DISTINCT
    modifier: []const u8 = "",
    items: []const *SelectStatement = &.{},

    pub fn writeSql(self: *const SetOperation, writer: *SQLWriter) Error!void {
        for (self.items, 0..) |item, i| {
            try item.writeSql(writer);
            if (i != self.items.len - 1) {
                try writer.writeLine("");
                try writer.write(self.type);
                if (self.modifier.len > 0) {
                    try writer.write(" ");
                    try writer.write(self.modifier);
                }
                try writer.writeLine("");
            }
        }
    }

    pub fn toString(self: *const SetOperation, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, false, false);
    }
};

pub const LimitClause = struct {
    count: *SQLExpression,
    offset: ?*SQLExpression = null,
};

/// SelectStatement represents the main SELECT statement structure.
pub const SelectStatement = struct {
    // WITH clause
    with_clauses: []const *WithClause = &.{},

    // SELECT clause
    select_type: SelectType = .standard,
    select_list: []const *SelectListItem = &.{},
    as_struct_type: []const u8 = "",
    as_value_type: []const u8 = "",

    // FROM clause
    from_clause: ?*FromItem = null,

    // WHERE clause
    where_clause: ?*SQLExpression = null,

    // GROUP BY clause
    group_by_list: []const *SQLExpression = &.{},

    // HAVING clause
    having_clause: ?*SQLExpression = null,

    // ORDER BY clause
    order_by_list: []const *OrderByItem = &.{},

    // LIMIT OFFSET clause
    limit_clause: ?*LimitClause = null,

    // Set operations
    set_operation: ?*SetOperation = null,

    // Hints
    hints: []const []const u8 = &.{},

    pub fn writeSql(self: *const SelectStatement, writer: *SQLWriter) Error!void {
        // WITH clause
        if (self.with_clauses.len > 0) {
            // Check if any WITH clause is recursive
            var has_recursive = false;
            for (self.with_clauses) |with_clause| {
                if (with_clause.recursive) {
                    has_recursive = true;
                    break;
                }
            }

            if (has_recursive) {
                try writer.write("WITH RECURSIVE ");
            } else {
                try writer.write("WITH ");
            }

            for (self.with_clauses, 0..) |with_clause, i| {
                if (i > 0) {
                    try writer.write(", ");
                    try writer.writeLine("");
                }
                try with_clause.writeSql(writer);
            }
            try writer.writeLine("");
        }

        // SetOperations implement their own writer for SELECT (but use
        // WithClauses, GroupBy, OrderBy)
        if (self.set_operation) |set_operation| {
            try set_operation.writeSql(writer);
        } else {
            // SELECT clause
            switch (self.select_type) {
                .distinct => try writer.write("SELECT DISTINCT"),
                .all => try writer.write("SELECT ALL"),
                .as_struct => try writer.write("SELECT AS STRUCT"),
                .as_value => try writer.write("SELECT AS VALUE"),
                .standard => try writer.write("SELECT"),
            }

            if (self.as_struct_type.len > 0) {
                try writer.write(" AS ");
                try writer.write(self.as_struct_type);
            }

            if (self.select_list.len > 0) {
                try writer.writeLine("");
                writer.indent();
                for (self.select_list, 0..) |item, i| {
                    if (i > 0) {
                        try writer.write(",");
                        try writer.writeLine("");
                    }
                    try item.writeSql(writer);
                }
                writer.dedent();
            }

            // FROM clause
            if (self.from_clause) |from_clause| {
                if (from_clause.type != .single_row) {
                    try writer.writeLine("");
                    try writer.write("FROM ");
                    try from_clause.writeSql(writer);
                }
            }
        }

        // WHERE clause
        if (self.where_clause) |where_clause| {
            try writer.writeLine("");
            try writer.write("WHERE ");
            try where_clause.writeSql(writer);
        }

        // GROUP BY clause
        if (self.group_by_list.len > 0) {
            try writer.writeLine("");
            try writer.write("GROUP BY ");
            for (self.group_by_list, 0..) |expr, i| {
                if (i > 0) {
                    try writer.write(", ");
                }
                try expr.writeSql(writer);
            }
        }

        // HAVING clause
        if (self.having_clause) |having_clause| {
            try writer.writeLine("");
            try writer.write("HAVING ");
            try having_clause.writeSql(writer);
        }

        // ORDER BY clause
        if (self.order_by_list.len > 0) {
            try writer.writeLine("");
            try writer.write("ORDER BY ");
            for (self.order_by_list, 0..) |item, i| {
                if (i > 0) {
                    try writer.write(", ");
                }
                try item.writeSql(writer);
            }
        }

        // LIMIT clause
        if (self.limit_clause) |limit_clause| {
            try writer.writeLine("");
            try writer.write("LIMIT ");
            try limit_clause.count.writeSql(writer);

            if (limit_clause.offset) |offset| {
                try writer.write(" OFFSET ");
                try offset.writeSql(writer);
            }
        }
    }

    pub fn toString(self: *const SelectStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

// ---------------------------------------------------------------------------
// DDL / DML statements
// ---------------------------------------------------------------------------

pub const CreateTableStatement = struct {
    if_not_exists: bool = false,
    table_name: []const u8 = "",
    columns: []const *ColumnDefinition = &.{},
    as_select: ?*SelectStatement = null,

    pub fn writeSql(self: *const CreateTableStatement, writer: *SQLWriter) Error!void {
        try writer.write("CREATE TABLE");
        if (self.if_not_exists) {
            try writer.write(" IF NOT EXISTS");
        }
        try writer.write(" ");
        try writeQuoted(writer, self.table_name);

        if (self.as_select) |as_select| {
            try writer.write(" AS ");
            try as_select.writeSql(writer);
            return;
        }

        try writer.write(" (");
        try writer.writeLine("");
        writer.indent();
        for (self.columns, 0..) |col, i| {
            if (i > 0) {
                try writer.write(",");
                try writer.writeLine("");
            }
            try col.writeSql(writer);
        }
        writer.dedent();
        try writer.writeLine("");
        try writer.write(")");
    }

    pub fn toString(self: *const CreateTableStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const ColumnDefinition = struct {
    name: []const u8 = "",
    type: []const u8 = "",
    not_null: bool = false,
    default_value: ?*SQLExpression = null,
    is_primary_key: bool = false,

    pub fn writeSql(self: *const ColumnDefinition, writer: *SQLWriter) Error!void {
        try writeQuoted(writer, self.name);
        try writer.write(" ");
        try writer.write(self.type);
        if (self.not_null) {
            try writer.write(" NOT NULL");
        }
        if (self.is_primary_key) {
            try writer.write(" PRIMARY KEY");
        }
        if (self.default_value) |default_value| {
            try writer.write(" DEFAULT ");
            try default_value.writeSql(writer);
        }
    }

    pub fn toString(self: *const ColumnDefinition, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const CreateViewStatement = struct {
    if_not_exists: bool = false,
    view_name: []const u8 = "",
    query: SQLFragment,

    pub fn writeSql(self: *const CreateViewStatement, writer: *SQLWriter) Error!void {
        try writer.write("CREATE VIEW");
        if (self.if_not_exists) {
            try writer.write(" IF NOT EXISTS");
        }
        try writer.write(" ");
        try writeQuoted(writer, self.view_name);
        try writer.write(" AS ");
        try self.query.writeSql(writer);
    }

    pub fn toString(self: *const CreateViewStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

/// One entry of Go's CreateFunctionStatement.Options map (unused in
/// rendering, kept for structural fidelity; ordered slice instead of map).
pub const FunctionOption = struct {
    name: []const u8,
    value: *SQLExpression,
};

pub const CreateFunctionStatement = struct {
    if_not_exists: bool = false,
    function_name: []const u8 = "",
    parameters: []const *ParameterDefinition = &.{},
    return_type: []const u8 = "",
    language: []const u8 = "",
    code: []const u8 = "",
    options: []const FunctionOption = &.{},

    pub fn writeSql(self: *const CreateFunctionStatement, writer: *SQLWriter) Error!void {
        try writer.write("CREATE FUNCTION");
        if (self.if_not_exists) {
            try writer.write(" IF NOT EXISTS");
        }
        try writer.write(" ");
        try writeQuoted(writer, self.function_name);
        try writer.write("(");
        for (self.parameters, 0..) |param, i| {
            if (i > 0) {
                try writer.write(", ");
            }
            try param.writeSql(writer);
        }
        try writer.write(")");
        if (self.return_type.len > 0) {
            try writer.write(" RETURNS ");
            try writer.write(self.return_type);
        }
        if (self.language.len > 0) {
            try writer.write(" LANGUAGE ");
            try writer.write(self.language);
        }
        if (self.code.len > 0) {
            try writer.write(" AS ");
            try writer.write(self.code);
        }
    }

    pub fn toString(self: *const CreateFunctionStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const ParameterDefinition = struct {
    name: []const u8 = "",
    type: []const u8 = "",

    pub fn writeSql(self: *const ParameterDefinition, writer: *SQLWriter) Error!void {
        try writeQuoted(writer, self.name);
        try writer.write(" ");
        try writer.write(self.type);
    }

    pub fn toString(self: *const ParameterDefinition, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const DeleteStatement = struct {
    table: SQLFragment,
    where_expr: ?SQLFragment = null,

    pub fn writeSql(self: *const DeleteStatement, writer: *SQLWriter) Error!void {
        try writer.write("DELETE FROM ");
        try self.table.writeSql(writer);
        if (self.where_expr) |where_expr| {
            try writer.write(" WHERE ");
            // Go writes WhereExpr.String() (rendered with the fragment's own
            // writer), not WhereExpr.WriteSql(writer).
            try writer.write(try where_expr.toString(writer.allocator));
        }
    }

    pub fn toString(self: *const DeleteStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const InsertStatement = struct {
    table_name: []const u8 = "",
    columns: []const []const u8 = &.{},
    query: ?*SelectStatement = null,
    rows: []const SQLFragment = &.{},

    pub fn writeSql(self: *const InsertStatement, writer: *SQLWriter) Error!void {
        try writer.write("INSERT INTO ");
        const table_line = try std.fmt.allocPrint(writer.allocator, "`{s}`", .{self.table_name});
        defer writer.allocator.free(table_line);
        try writer.writeLine(table_line);
        const joined = try std.mem.join(writer.allocator, ", ", self.columns);
        defer writer.allocator.free(joined);
        const columns_line = try std.fmt.allocPrint(writer.allocator, " ({s}) ", .{joined});
        defer writer.allocator.free(columns_line);
        try writer.writeLine(columns_line);
        if (self.query) |query| {
            try writer.write(" ");
            try query.writeSql(writer);
        } else if (self.rows.len > 0) {
            try writer.writeLine("VALUES ");
            for (self.rows, 0..) |value, i| {
                try writer.write("(");
                try writer.write(try value.toString(writer.allocator));
                try writer.write(")");
                if (self.rows.len != 1 and i != self.rows.len - 1) {
                    try writer.write(",");
                }
            }
        }
    }

    pub fn toString(self: *const InsertStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const CreateIndexStatement = struct {
    index_name: []const u8 = "",
    table_name: []const u8 = "",
    columns: []const []const u8 = &.{},

    pub fn writeSql(self: *const CreateIndexStatement, writer: *SQLWriter) Error!void {
        try writer.write("CREATE INDEX ");
        try writeQuoted(writer, self.index_name);
        try writer.write(" ON ");
        try writeQuoted(writer, self.table_name);
        try writer.write(" (");
        for (self.columns, 0..) |column, i| {
            if (i > 0) {
                try writer.write(", ");
            }
            try writeQuoted(writer, column);
        }
        try writer.write(")");
    }

    pub fn toString(self: *const CreateIndexStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const DropStatement = struct {
    if_exists: bool = false,
    object_type: []const u8 = "",
    object_name: []const u8 = "",

    pub fn writeSql(self: *const DropStatement, writer: *SQLWriter) Error!void {
        try writer.write("DROP ");
        try writer.write(self.object_type);
        if (self.if_exists) {
            try writer.write(" IF EXISTS");
        }
        try writer.write(" ");
        try writeQuoted(writer, self.object_name);
    }

    pub fn toString(self: *const DropStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const TruncateStatement = struct {
    table_name: []const u8 = "",

    pub fn writeSql(self: *const TruncateStatement, writer: *SQLWriter) Error!void {
        try writer.write("TRUNCATE TABLE ");
        try writeQuoted(writer, self.table_name);
    }

    pub fn toString(self: *const TruncateStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const UpdateStatement = struct {
    table: *FromItem,
    set_items: []const *SetItem = &.{},
    from_clause: ?*FromItem = null,
    where_clause: ?*SQLExpression = null,

    pub fn writeSql(self: *const UpdateStatement, writer: *SQLWriter) Error!void {
        try writer.write("UPDATE ");
        try self.table.writeSql(writer);
        try writer.write(" SET ");
        for (self.set_items, 0..) |item, i| {
            if (i > 0) {
                try writer.write(", ");
            }
            try item.writeSql(writer);
        }
        if (self.from_clause) |from_clause| {
            try writer.write(" FROM ");
            try from_clause.writeSql(writer);
        }
        if (self.where_clause) |where_clause| {
            try writer.write(" WHERE ");
            try where_clause.writeSql(writer);
        }
    }

    pub fn toString(self: *const UpdateStatement, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

pub const SetItem = struct {
    column: *SQLExpression,
    value: *SQLExpression,

    pub fn writeSql(self: *const SetItem, writer: *SQLWriter) Error!void {
        try self.column.writeSql(writer);
        try writer.write(" = ");
        try self.value.writeSql(writer);
    }

    pub fn toString(self: *const SetItem, allocator: std.mem.Allocator) Error![]u8 {
        return render(allocator, self, true, true);
    }
};

/// CompoundSQLFragment represents multiple SQL statements that should be executed in sequence.
pub const CompoundSQLFragment = struct {
    statements: []const SQLFragment = &.{},

    pub fn writeSql(self: *const CompoundSQLFragment, writer: *SQLWriter) Error!void {
        for (self.statements, 0..) |stmt, i| {
            if (i > 0) {
                try writer.write(";\n");
            }
            try writer.write(try stmt.toString(writer.allocator));
        }
    }

    /// Go: strings.Join(statements, ";\n") + ";"
    pub fn toString(self: *const CompoundSQLFragment, allocator: std.mem.Allocator) Error![]u8 {
        var buf: std.ArrayList(u8) = .empty;
        for (self.statements, 0..) |stmt, i| {
            if (i > 0) {
                try buf.appendSlice(allocator, ";\n");
            }
            try buf.appendSlice(allocator, try stmt.toString(allocator));
        }
        try buf.append(allocator, ';');
        return buf.toOwnedSlice(allocator);
    }

    /// GetStatements returns the individual statements in the compound fragment.
    pub fn getStatements(self: *const CompoundSQLFragment) []const SQLFragment {
        return self.statements;
    }
};

// ---------------------------------------------------------------------------
// SQLFragment
// ---------------------------------------------------------------------------

/// SQLFragment represents any component that can generate SQL. The Go
/// original is an interface; here it is a tagged union over the closed set
/// of fragment types defined in this file.
///
/// Note: WhenClause, TableReference, and LimitClause are not variants because
/// they have no WriteSql in Go (they are rendered by their parents).
pub const SQLFragment = union(enum) {
    select_statement: *const SelectStatement,
    select_list_item: *const SelectListItem,
    expression: *const SQLExpression,
    list_expression: *const ListExpression,
    unary_expression: *const UnaryExpression,
    binary_expression: *const BinaryExpression,
    case_expression: *const CaseExpression,
    exists_expression: *const ExistsExpression,
    function_call: *const FunctionCall,
    window_specification: *const WindowSpecification,
    frame_clause: *const FrameClause,
    frame_bound: *const FrameBound,
    from_item: *const FromItem,
    join_clause: *const JoinClause,
    table_function: *const TableFunction,
    order_by_item: *const OrderByItem,
    with_clause: *const WithClause,
    set_operation: *const SetOperation,
    create_table_statement: *const CreateTableStatement,
    create_index_statement: *const CreateIndexStatement,
    column_definition: *const ColumnDefinition,
    create_view_statement: *const CreateViewStatement,
    create_function_statement: *const CreateFunctionStatement,
    parameter_definition: *const ParameterDefinition,
    delete_statement: *const DeleteStatement,
    insert_statement: *const InsertStatement,
    drop_statement: *const DropStatement,
    truncate_statement: *const TruncateStatement,
    update_statement: *const UpdateStatement,
    set_item: *const SetItem,
    compound: *const CompoundSQLFragment,

    pub fn writeSql(self: SQLFragment, writer: *SQLWriter) Error!void {
        return switch (self) {
            inline else => |fragment| fragment.writeSql(writer),
        };
    }

    /// Mirrors the per-type Go String() methods (each type's own writer
    /// configuration and trimming behavior).
    pub fn toString(self: SQLFragment, allocator: std.mem.Allocator) Error![]u8 {
        return switch (self) {
            inline else => |fragment| fragment.toString(allocator),
        };
    }
};

/// Convenience: render any fragment to an owned SQL string, using the same
/// semantics as the Go String() method of the underlying type.
pub fn toSql(allocator: std.mem.Allocator, fragment: SQLFragment) Error![]u8 {
    return fragment.toString(allocator);
}

// ---------------------------------------------------------------------------
// Builder helper functions
// ---------------------------------------------------------------------------

/// NewSelectStatement creates a new SELECT statement.
pub fn newSelectStatement(allocator: std.mem.Allocator) Error!*SelectStatement {
    return create(allocator, SelectStatement{ .select_type = .standard });
}

pub fn newSelectStarStatement(
    allocator: std.mem.Allocator,
    from: ?*FromItem,
) Error!*SelectStatement {
    const select_list = try allocator.alloc(*SelectListItem, 1);
    select_list[0] = try create(allocator, SelectListItem{
        .expression = try newStarExpression(allocator, null),
    });
    return create(allocator, SelectStatement{
        .select_type = .standard,
        .from_clause = from,
        .select_list = select_list,
    });
}

/// NewColumnExpression creates a new column reference expression.
pub fn newColumnExpression(
    allocator: std.mem.Allocator,
    column: []const u8,
    table_alias: ?[]const u8,
) Error!*SQLExpression {
    const expr = try create(allocator, SQLExpression{
        .type = .column,
        .value = column,
    });
    if (table_alias) |alias| expr.table_alias = alias;
    return expr;
}

/// NewStarExpression creates a new star (*) expression for SELECT *.
pub fn newStarExpression(
    allocator: std.mem.Allocator,
    table_alias: ?[]const u8,
) Error!*SQLExpression {
    const expr = try create(allocator, SQLExpression{ .type = .star });
    if (table_alias) |alias| expr.table_alias = alias;
    return expr;
}

/// NewLiteralExpression creates a new literal expression.
pub fn newLiteralExpression(allocator: std.mem.Allocator, value: []const u8) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .literal,
        .value = value,
    });
}

/// NewFunctionExpression creates a new function call expression.
pub fn newFunctionExpression(
    allocator: std.mem.Allocator,
    name: []const u8,
    args: []const *SQLExpression,
) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .function,
        .function_call = try create(allocator, FunctionCall{
            .name = name,
            .arguments = args,
        }),
    });
}

/// NewBinaryExpression creates a new binary expression.
pub fn newBinaryExpression(
    allocator: std.mem.Allocator,
    left: ?*SQLExpression,
    operator: []const u8,
    right: ?*SQLExpression,
) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .binary,
        .binary_expression = try create(allocator, BinaryExpression{
            .left = left,
            .operator = operator,
            .right = right,
        }),
    });
}

/// NewCaseExpression creates a new CASE expression (searched case).
pub fn newCaseExpression(
    allocator: std.mem.Allocator,
    when_clauses: []const *WhenClause,
    else_expr: ?*SQLExpression,
) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .case,
        .case_expression = try create(allocator, CaseExpression{
            .when_clauses = when_clauses,
            .else_expr = else_expr,
        }),
    });
}

/// NewSimpleCaseExpression creates a new CASE expression with a case
/// expression (simple case).
pub fn newSimpleCaseExpression(
    allocator: std.mem.Allocator,
    case_expr: ?*SQLExpression,
    when_clauses: []const *WhenClause,
    else_expr: ?*SQLExpression,
) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .case,
        .case_expression = try create(allocator, CaseExpression{
            .case_expr = case_expr,
            .when_clauses = when_clauses,
            .else_expr = else_expr,
        }),
    });
}

/// NewSubqueryFromItem creates a subquery FROM item.
pub fn newSubqueryFromItem(
    allocator: std.mem.Allocator,
    subquery: *SelectStatement,
    alias: []const u8,
) Error!*FromItem {
    return create(allocator, FromItem{
        .type = .subquery,
        .subquery = subquery,
        .alias = alias,
    });
}

/// NewListExpression creates a new list expression.
pub fn newListExpression(
    allocator: std.mem.Allocator,
    expressions: []const *SQLExpression,
) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .list,
        .list_expression = try create(allocator, ListExpression{
            .expressions = expressions,
        }),
    });
}

/// NewNotExpression creates a new NOT expression.
pub fn newNotExpression(
    allocator: std.mem.Allocator,
    expression: *SQLExpression,
) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .unary,
        .unary_expression = try create(allocator, UnaryExpression{
            .operator = "NOT",
            .expression = expression,
        }),
    });
}

/// NewExistsExpression creates a new EXISTS expression.
pub fn newExistsExpression(
    allocator: std.mem.Allocator,
    subquery: *SelectStatement,
) Error!*SQLExpression {
    return create(allocator, SQLExpression{
        .type = .exists,
        .exists_expr = try create(allocator, ExistsExpression{
            .subquery = subquery,
        }),
    });
}

/// NewInnerJoin creates an INNER JOIN.
pub fn newInnerJoin(
    allocator: std.mem.Allocator,
    left: ?*FromItem,
    right: ?*FromItem,
    condition: ?*SQLExpression,
) Error!*FromItem {
    return create(allocator, FromItem{
        .type = .join,
        .join = try create(allocator, JoinClause{
            .type = .inner,
            .left = left,
            .right = right,
            .condition = condition,
        }),
    });
}

/// NewCompoundSQLFragment creates a new compound SQL fragment.
pub fn newCompoundSQLFragment(
    allocator: std.mem.Allocator,
    statements: []const SQLFragment,
) Error!*CompoundSQLFragment {
    return create(allocator, CompoundSQLFragment{ .statements = statements });
}

// NOTE: Go's NewLiteralExpressionFromGoValue depends on ValueFromGoValue /
// LiteralFromValue from the value codec layer and is intentionally not part
// of this file's port; it belongs with the value-encoding module.

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn testTable(allocator: std.mem.Allocator, name: []const u8) Error!*FromItem {
    return create(allocator, FromItem{ .type = .table, .table_name = name });
}

fn testSelectItem(allocator: std.mem.Allocator, expr: *SQLExpression) Error!*SelectListItem {
    return create(allocator, SelectListItem{ .expression = expr });
}

test "simple select list with from subquery and alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inner = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newColumnExpression(a, "x", null))},
        .from_clause = try testTable(a, "t"),
    });
    const outer = try create(a, SelectStatement{
        .select_list = &.{
            try testSelectItem(a, try newColumnExpression(a, "a", null)),
            try testSelectItem(a, try newColumnExpression(a, "b", null)),
        },
        .from_clause = try newSubqueryFromItem(a, inner, "sub"),
    });

    try testing.expectEqualStrings(
        "SELECT\n`a`,  \n`b`\nFROM (\nSELECT  \n`x`  \nFROM `t`\n) AS `sub`",
        try outer.toString(a),
    );
}

test "binary expression" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try newBinaryExpression(
        a,
        try newColumnExpression(a, "a", null),
        "=",
        try newLiteralExpression(a, "1"),
    );
    try testing.expectEqualStrings("`a` = 1", try expr.toString(a));
}

test "column with table alias, collation, and alias" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const expr = try newColumnExpression(a, "name", "t1");
    expr.collation = "NOCASE";
    expr.alias = "n";
    try testing.expectEqualStrings("`t1`.`name` COLLATE NOCASE AS `n`", try expr.toString(a));

    // Alias suppressed when it matches the column name.
    const same = try newColumnExpression(a, "name", null);
    same.alias = "name";
    try testing.expectEqualStrings("`name`", try same.toString(a));
}

test "function call without and with DISTINCT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const sum = try newFunctionExpression(a, "SUM", &.{
        try newColumnExpression(a, "x", null),
    });
    try testing.expectEqualStrings("SUM(`x`)", try sum.toString(a));

    sum.function_call.?.is_distinct = true;
    try testing.expectEqualStrings("SUM(DISTINCT `x`)", try sum.toString(a));
}

test "function call with window specification and frame clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const fc = try newFunctionExpression(a, "SUM", &.{
        try newColumnExpression(a, "x", null),
    });
    fc.function_call.?.window_spec = try create(a, WindowSpecification{
        .partition_by = &.{try newColumnExpression(a, "a", null)},
        .order_by = &.{try create(a, OrderByItem{
            .expression = try newColumnExpression(a, "b", null),
            .direction = "DESC",
        })},
        .frame_clause = try create(a, FrameClause{
            .unit = "ROWS",
            .start = try create(a, FrameBound{ .type = "UNBOUNDED PRECEDING" }),
            .end = try create(a, FrameBound{ .type = "CURRENT ROW" }),
        }),
    });
    try testing.expectEqualStrings(
        "SUM(`x`) OVER (PARTITION BY `a` ORDER BY `b` DESC " ++
            "ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)",
        try fc.toString(a),
    );
}

test "frame bound with offset and single-bound frame clause" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const frame = try create(a, FrameClause{
        .unit = "ROWS",
        .start = try create(a, FrameBound{
            .type = "PRECEDING",
            .offset = try newLiteralExpression(a, "5"),
        }),
    });
    try testing.expectEqualStrings("ROWS 5 PRECEDING", try frame.toString(a));
}

test "searched CASE expression with ELSE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const when = try create(a, WhenClause{
        .condition = try newBinaryExpression(
            a,
            try newColumnExpression(a, "a", null),
            "=",
            try newLiteralExpression(a, "1"),
        ),
        .result = try newLiteralExpression(a, "'one'"),
    });
    const expr = try newCaseExpression(a, &.{when}, try newLiteralExpression(a, "'other'"));
    try testing.expectEqualStrings(
        "CASE WHEN `a` = 1 THEN 'one' ELSE 'other' END",
        try expr.toString(a),
    );
}

test "simple CASE expression with operand, no ELSE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const when = try create(a, WhenClause{
        .condition = try newLiteralExpression(a, "1"),
        .result = try newLiteralExpression(a, "'one'"),
    });
    const expr = try newSimpleCaseExpression(
        a,
        try newColumnExpression(a, "x", null),
        &.{when},
        null,
    );
    try testing.expectEqualStrings("CASE `x` WHEN 1 THEN 'one' END", try expr.toString(a));
}

test "WITH clause with two entries, one materialized" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const q1 = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newColumnExpression(a, "a", null))},
        .from_clause = try testTable(a, "x"),
    });
    const q2 = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newColumnExpression(a, "b", null))},
        .from_clause = try testTable(a, "y"),
    });
    const stmt = try create(a, SelectStatement{
        .with_clauses = &.{
            try create(a, WithClause{ .name = "t1", .materialized = true, .query = q1 }),
            try create(a, WithClause{ .name = "t2", .query = q2 }),
        },
        .select_list = &.{try testSelectItem(a, try newStarExpression(a, null))},
        .from_clause = try testTable(a, "t1"),
    });

    // `materialized` is honoured per clause; Go emits the keyword for both.
    try testing.expectEqualStrings(
        "WITH `t1` AS MATERIALIZED \t(\nSELECT  \n`a`  \nFROM `x`)\n" ++
            ", \n`t2` AS \t(\nSELECT  \n`b`  \nFROM `y`)\n" ++
            "\nSELECT\n*\nFROM `t1`",
        try stmt.toString(a),
    );
}

test "WITH RECURSIVE keyword when any clause is recursive" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const q = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newLiteralExpression(a, "1"))},
    });
    const stmt = try create(a, SelectStatement{
        .with_clauses = &.{
            try create(a, WithClause{ .name = "r", .recursive = true, .query = q }),
        },
        .select_list = &.{try testSelectItem(a, try newStarExpression(a, null))},
        .from_clause = try testTable(a, "r"),
    });

    try testing.expectEqualStrings(
        "WITH RECURSIVE `r` AS \t(\nSELECT  \n1)\n\nSELECT\n*\nFROM `r`",
        try stmt.toString(a),
    );
}

test "INNER JOIN with ON condition" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const join = try newInnerJoin(
        a,
        try testTable(a, "t1"),
        try testTable(a, "t2"),
        try newBinaryExpression(
            a,
            try newColumnExpression(a, "a", "t1"),
            "=",
            try newColumnExpression(a, "b", "t2"),
        ),
    );
    try testing.expectEqualStrings(
        "`t1` INNER JOIN `t2` ON `t1`.`a` = `t2`.`b`",
        try join.toString(a),
    );
}

test "LEFT JOIN with USING columns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const from = try create(a, FromItem{
        .type = .join,
        .join = try create(a, JoinClause{
            .type = .left,
            .left = try testTable(a, "t1"),
            .right = try testTable(a, "t2"),
            .using = &.{ "a", "b" },
        }),
    });
    try testing.expectEqualStrings("`t1` LEFT JOIN `t2` USING (a, b)", try from.toString(a));
}

test "full statement: WHERE, GROUP BY, HAVING, ORDER BY with collation and nulls order, LIMIT OFFSET" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const col_a = try newColumnExpression(a, "a", null);
    const order_a = try newColumnExpression(a, "a", null);
    order_a.collation = "NOCASE";

    const stmt = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, col_a)},
        .from_clause = try testTable(a, "t"),
        .where_clause = try newBinaryExpression(
            a,
            try newColumnExpression(a, "b", null),
            "=",
            try newLiteralExpression(a, "1"),
        ),
        .group_by_list = &.{try newColumnExpression(a, "a", null)},
        .having_clause = try newBinaryExpression(
            a,
            try newFunctionExpression(a, "COUNT", &.{try newStarExpression(a, null)}),
            ">",
            try newLiteralExpression(a, "1"),
        ),
        .order_by_list = &.{
            try create(a, OrderByItem{
                .expression = order_a,
                .direction = "ASC",
                .nulls_order = "NULLS FIRST",
            }),
            try create(a, OrderByItem{
                .expression = try newColumnExpression(a, "b", null),
                .direction = "DESC",
                .nulls_order = "NULLS LAST",
            }),
        },
        .limit_clause = try create(a, LimitClause{
            .count = try newLiteralExpression(a, "10"),
            .offset = try newLiteralExpression(a, "5"),
        }),
    });

    try testing.expectEqualStrings(
        "SELECT\n`a`\nFROM `t`\nWHERE `b` = 1\nGROUP BY `a`\nHAVING COUNT(*) > 1\n" ++
            "ORDER BY `a` COLLATE NOCASE ASC NULLS FIRST, `b` DESC NULLS LAST\n" ++
            "LIMIT 10 OFFSET 5",
        try stmt.toString(a),
    );
}

test "EXISTS subquery renders without newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inner = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newLiteralExpression(a, "1"))},
        .from_clause = try testTable(a, "t"),
    });
    const exists = try newExistsExpression(a, inner);
    try testing.expectEqualStrings("EXISTS (SELECT 1 FROM `t`)", try exists.toString(a));

    const not_exists = try newNotExpression(a, exists);
    try testing.expectEqualStrings(
        "NOT (EXISTS (SELECT 1 FROM `t`))",
        try not_exists.toString(a),
    );
}

test "subquery expression renders with newlines" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const inner = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newLiteralExpression(a, "1"))},
    });
    const expr = try create(a, SQLExpression{ .type = .subquery, .subquery = inner });
    try testing.expectEqualStrings("(SELECT\n1)", try expr.toString(a));
}

test "cast expression type renders nothing except alias (faithful to Go)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const bare = try create(a, SQLExpression{ .type = .cast, .value = "ignored" });
    try testing.expectEqualStrings("", try bare.toString(a));

    const aliased = try create(a, SQLExpression{ .type = .cast, .alias = "c" });
    try testing.expectEqualStrings(" AS `c`", try aliased.toString(a));
}

test "star expressions and star expansion with EXCEPT / REPLACE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    try testing.expectEqualStrings("*", try (try newStarExpression(a, null)).toString(a));
    try testing.expectEqualStrings("t.*", try (try newStarExpression(a, "t")).toString(a));

    const item = try create(a, SelectListItem{
        .expression = try newStarExpression(a, null),
        .is_star_expansion = true,
        .except_columns = &.{ "a", "b" },
        .replace_columns = &.{.{
            .column = "c",
            .expression = try newLiteralExpression(a, "1"),
        }},
    });
    try testing.expectEqualStrings("* EXCEPT (`a`, `b`) REPLACE (1 AS `c`)", try item.toString(a));
}

test "list expression and unary NOT" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const list = try newListExpression(a, &.{
        try newLiteralExpression(a, "1"),
        try newLiteralExpression(a, "2"),
        try newLiteralExpression(a, "3"),
    });
    try testing.expectEqualStrings("(1,2,3)", try list.toString(a));

    const in_expr = try newBinaryExpression(a, try newColumnExpression(a, "a", null), "IN", list);
    try testing.expectEqualStrings("`a` IN (1,2,3)", try in_expr.toString(a));

    const not_expr = try newNotExpression(a, in_expr);
    try testing.expectEqualStrings("NOT (`a` IN (1,2,3))", try not_expr.toString(a));
}

test "set operation UNION ALL" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const s1 = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newLiteralExpression(a, "1"))},
    });
    const s2 = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newLiteralExpression(a, "2"))},
    });
    const stmt = try create(a, SelectStatement{
        .set_operation = try create(a, SetOperation{
            .type = "UNION",
            .modifier = "ALL",
            .items = &.{ s1, s2 },
        }),
    });
    try testing.expectEqualStrings("SELECT\n1\nUNION ALL\nSELECT\n2", try stmt.toString(a));
}

test "SELECT DISTINCT and select type variants" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stmt = try create(a, SelectStatement{
        .select_type = .distinct,
        .select_list = &.{try testSelectItem(a, try newColumnExpression(a, "a", null))},
        .from_clause = try testTable(a, "t"),
    });
    try testing.expectEqualStrings("SELECT DISTINCT\n`a`\nFROM `t`", try stmt.toString(a));
}

test "single-row from item is omitted" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stmt = try create(a, SelectStatement{
        .select_list = &.{try testSelectItem(a, try newLiteralExpression(a, "1"))},
        .from_clause = try create(a, FromItem{ .type = .single_row }),
    });
    try testing.expectEqualStrings("SELECT\n1", try stmt.toString(a));
}

test "insert statement with VALUES row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const row = try newLiteralExpression(a, "1, 'x'");
    const stmt = try create(a, InsertStatement{
        .table_name = "t",
        .columns = &.{ "a", "b" },
        .rows = &.{SQLFragment{ .expression = row }},
    });
    try testing.expectEqualStrings(
        "INSERT INTO `t`\n (a, b) \nVALUES \n(1, 'x')",
        try stmt.toString(a),
    );
}

test "create table, drop, truncate, and toSql convenience" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const ct = try create(a, CreateTableStatement{
        .if_not_exists = true,
        .table_name = "t",
        .columns = &.{
            try create(a, ColumnDefinition{
                .name = "id",
                .type = "INTEGER",
                .not_null = true,
                .is_primary_key = true,
            }),
            try create(a, ColumnDefinition{
                .name = "v",
                .type = "TEXT",
                .default_value = try newLiteralExpression(a, "'x'"),
            }),
        },
    });
    try testing.expectEqualStrings(
        "CREATE TABLE IF NOT EXISTS `t` (\n" ++
            "`id` INTEGER NOT NULL PRIMARY KEY,  \n" ++
            "`v` TEXT DEFAULT 'x'\n" ++
            ")",
        try ct.toString(a),
    );

    const drop = DropStatement{ .if_exists = true, .object_type = "TABLE", .object_name = "t" };
    try testing.expectEqualStrings(
        "DROP TABLE IF EXISTS `t`",
        try toSql(a, .{ .drop_statement = &drop }),
    );

    const trunc = TruncateStatement{ .table_name = "t" };
    try testing.expectEqualStrings(
        "TRUNCATE TABLE `t`",
        try toSql(a, .{ .truncate_statement = &trunc }),
    );
}

test "delete and update statements" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const del = DeleteStatement{
        .table = .{ .from_item = try testTable(a, "t") },
        .where_expr = .{ .expression = try newBinaryExpression(
            a,
            try newColumnExpression(a, "a", null),
            "=",
            try newLiteralExpression(a, "1"),
        ) },
    };
    try testing.expectEqualStrings("DELETE FROM `t` WHERE `a` = 1", try del.toString(a));

    const upd = UpdateStatement{
        .table = try testTable(a, "t"),
        .set_items = &.{try create(a, SetItem{
            .column = try newColumnExpression(a, "a", null),
            .value = try newLiteralExpression(a, "2"),
        })},
        .where_clause = try newBinaryExpression(
            a,
            try newColumnExpression(a, "b", null),
            "=",
            try newLiteralExpression(a, "3"),
        ),
    };
    try testing.expectEqualStrings("UPDATE `t` SET `a` = 2 WHERE `b` = 3", try upd.toString(a));
}

test "compound SQL fragment" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const compound = try newCompoundSQLFragment(a, &.{
        .{ .create_index_statement = &.{
            .index_name = "t_a",
            .table_name = "t",
            .columns = &.{"a"},
        } },
        .{ .drop_statement = &.{ .object_type = "TABLE", .object_name = "t" } },
    });
    try testing.expectEqualStrings(
        "CREATE INDEX `t_a` ON `t` (`a`);\nDROP TABLE `t`;",
        try compound.toString(a),
    );
    try testing.expectEqualStrings(
        "CREATE INDEX `t_a` ON `t` (`a`);\nDROP TABLE `t`",
        try render(a, compound, true, false),
    );
    try testing.expectEqual(@as(usize, 2), compound.getStatements().len);
}

test "unnest, with_ref, and table function from items" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const unnest = try create(a, FromItem{
        .type = .unnest,
        .unnest_expr = try newColumnExpression(a, "arr", null),
        .alias = "elem",
    });
    try testing.expectEqualStrings("UNNEST(`arr`) AS `elem`", try unnest.toString(a));

    const with_ref = try create(a, FromItem{ .type = .with_ref, .with_ref = "cte" });
    try testing.expectEqualStrings("cte", try with_ref.toString(a));

    const tf = try create(a, FromItem{
        .type = .table_function,
        .table_function = try create(a, TableFunction{
            .name = "generate_series",
            .arguments = &.{
                try newLiteralExpression(a, "1"),
                try newLiteralExpression(a, "10"),
            },
        }),
        .alias = "g",
    });
    try testing.expectEqualStrings("generate_series(1, 10) AS `g`", try tf.toString(a));
}

test "newSelectStarStatement helper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const stmt = try newSelectStarStatement(a, try testTable(a, "t"));
    try testing.expectEqualStrings("SELECT\n*\nFROM `t`", try stmt.toString(a));
}

test "SQLWriter basic behavior" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var w = SQLWriter.init(a);
    try w.write("A");
    w.indent();
    try w.writeLine("B");
    w.dedent();
    w.dedent(); // no-op at zero
    try w.writeLine("C");
    try testing.expectEqualStrings("A  B\nC\n", w.string());

    var w2 = SQLWriter.init(a);
    w2.use_newlines = false;
    w2.indent();
    try w2.writeLine("B");
    try testing.expectEqualStrings("B ", w2.string());
}
