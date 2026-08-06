//! Does a doc-derived expected value describe a result cell?
//!
//! The `googlesql/` and `bigquery/` spec trees (see tools/spec_import.py) carry
//! their expected values as bare ZON scalars, because upstream scraped them out
//! of the ASCII result tables printed in the GoogleSQL reference docs. A table
//! cell reading `42` does not say whether the column was INT64, FLOAT64 or the
//! string "42", so the want side declares nothing and the same value has to be
//! able to match several `driver.Cell` shapes.
//!
//! Two consequences drive the design:
//!
//!   - **Numbers are compared numerically, never textually.** A doc table
//!     showing `4.71238898038469` must match a `.float` cell, and NUMERIC /
//!     BIGNUMERIC / JSON cells arrive as `.string`, so a string want and a
//!     numeric got (and the reverse) are both parsed to f64 and compared with a
//!     tolerance. Rendering floats to text and comparing the text would make us
//!     hostage to Zig's `{d}` matching Go's `strconv.FormatFloat(v,'g',-1,64)`,
//!     which produced the doc tables — it does not, at the exponent boundaries.
//!   - **Text rendering is the fallback, not the rule.** Only arrays and structs
//!     compared against a string want go through `renderCell`.
//!
//! One tree does not fit that description: `testdata/specs/zigquery`, this
//! engine's own regression suite, was machine-exported from go-zetasqlite's
//! `query_test.go` with every expected value carrying its type. Nothing there is
//! a scraped doc table, so nothing there needs the fallbacks — and accepting
//! them would silently weaken 748 cases that used to assert types. Those files
//! declare `.typed = true`, which turns every rule below into the exact,
//! kind-checked comparison the retired corpus runner performed.
//!
//! This lives in the library rather than the harness because it is pure and it
//! is the only part of the spec pipeline that genuinely needs unit tests.

const std = @import("std");
const Zoir = std.zig.Zoir;
const driver = @import("../driver.zig");

pub const Options = struct {
    /// Absolute-or-relative float tolerance. The default is tighter than the
    /// retired corpus runner's relative 1e-5: doc-derived values are published
    /// and exact, not the output of a differing float pipeline. `typed` specs
    /// ask for 1e-5 back, because theirs *are*.
    tolerance: f64 = 1e-9,

    /// The expectation was exported with its type rather than scraped from a
    /// doc table, so assert the cell's kind and not just its value: an integer
    /// want demands an `.int` cell, a string want demands text, an array want
    /// demands an array. Turns off every cross-kind fallback below.
    typed: bool = false,
};

/// The comparison `testdata/specs/zigquery` runs under — the semantics of the
/// retired `harness/corpus_runner.zig:cellMatches`, named once here so the
/// runner does not restate the tolerance.
pub const typed_options: Options = .{ .typed = true, .tolerance = 1e-5 };

pub const Error = error{OutOfMemory};

/// True when the expected value at `node` describes `got`.
pub fn matches(
    gpa: std.mem.Allocator,
    zoir: Zoir,
    node: Zoir.Node.Index,
    got: driver.Cell,
    opts: Options,
) Error!bool {
    return switch (node.get(zoir)) {
        .null => got == .null,
        .true => got == .bool and got.bool,
        .false => got == .bool and !got.bool,

        .nan => got == .float and std.math.isNan(got.float),
        .pos_inf => got == .float and std.math.isPositiveInf(got.float),
        .neg_inf => got == .float and std.math.isNegativeInf(got.float),

        .int_literal => |int| {
            // `.small` is the common case; `.big` is not hypothetical — the
            // corpus holds microsecond timestamps like 1710504000000000.
            const want_i64: ?i64 = switch (int) {
                .small => |v| v,
                .big => |v| v.toInt(i64) catch null,
            };
            // An integer want against an integer cell is compared EXACTLY.
            // Routing it through the float tolerance would make 1710504000000000
            // and ...001 equal, since they differ by 6e-16 relatively.
            if (got == .int) {
                return want_i64 != null and want_i64.? == got.int;
            }
            // A typed want said INT64. A cell of any other kind is a wrong
            // answer, not a formatting difference.
            if (opts.typed) return false;
            const want_f: f64 = switch (int) {
                .small => |v| @floatFromInt(v),
                .big => |v| v.toFloat(f64, .nearest_even)[0],
            };
            return numericMatch(want_f, got, opts);
        },
        .float_literal => |f| {
            if (opts.typed) {
                return got == .float and floatNear(@floatCast(f), got.float, opts.tolerance);
            }
            return numericMatch(@floatCast(f), got, opts);
        },

        .string_literal => |want| stringMatch(gpa, want, got, opts),

        // `.{}` in value position is an empty array; at row level the caller
        // handles it before reaching here.
        .empty_literal => switch (got) {
            .array => |a| a.len == 0,
            else => false,
        },

        .array_literal => |range| switch (got) {
            .array => |cells| {
                if (cells.len != range.len) return false;
                for (cells, 0..) |cell, i| {
                    if (!try matches(gpa, zoir, range.at(@intCast(i)), cell, opts)) return false;
                }
                return true;
            },
            // A struct rendered by the docs as a positional list. Only the doc
            // tables are that lossy; a typed export spells a struct as a struct.
            .struct_ => |fields| {
                if (opts.typed) return false;
                if (fields.len != range.len) return false;
                for (fields, 0..) |field, i| {
                    if (!try matches(gpa, zoir, range.at(@intCast(i)), field.value, opts)) {
                        return false;
                    }
                }
                return true;
            },
            else => false,
        },

        // `.{ .name = value }` — a STRUCT with its field names intact, which
        // only a typed export has. Doc tables print structs positionally, so
        // outside `typed` this still reads as a converter bug (below).
        .struct_literal => |lit| {
            if (!opts.typed or got != .struct_) return false;
            if (got.struct_.len != lit.names.len) return false;
            for (got.struct_) |f| {
                const want = fieldNamed(zoir, lit, f.name) orelse return false;
                if (!try matches(gpa, zoir, want, f.value, opts)) return false;
            }
            return true;
        },

        // A char literal here means the converter emitted single quotes, which
        // it must never do (`'ab'` would not even parse, `'a'` would silently
        // become 97). Treat it as a corpus bug rather than matching it.
        .char_literal, .enum_literal => false,
    };
}

/// The value of `name` in a ZON struct literal. Linear because these are
/// STRUCT field lists — a handful of entries, never enough to index.
fn fieldNamed(
    zoir: Zoir,
    lit: @FieldType(Zoir.Node, "struct_literal"),
    name: []const u8,
) ?Zoir.Node.Index {
    for (lit.names, 0..) |n, i| {
        if (std.mem.eql(u8, n.get(zoir), name)) return lit.vals.at(@intCast(i));
    }
    return null;
}

/// Numeric want against any cell that can carry a number — including the
/// `.string`/`.json` cells that NUMERIC, BIGNUMERIC and JSON results arrive as.
fn numericMatch(want: f64, got: driver.Cell, opts: Options) bool {
    const have: f64 = switch (got) {
        .int => |v| @floatFromInt(v),
        .float => |v| v,
        .bool => |v| if (v) 1 else 0,
        .string, .json => |s| std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch return false,
        else => return false,
    };
    return floatNear(want, have, opts.tolerance);
}

fn floatNear(a: f64, b: f64, tol: f64) bool {
    if (std.math.isNan(a) and std.math.isNan(b)) return true;
    if (a == b) return true; // covers the infinities
    const diff = @abs(a - b);
    if (diff <= tol) return true;
    const scale = @max(@abs(a), @abs(b));
    return scale > 0 and diff / scale <= tol;
}

fn stringMatch(
    gpa: std.mem.Allocator,
    want: []const u8,
    got: driver.Cell,
    opts: Options,
) Error!bool {
    // A typed want said STRING (or a date/time kind, which reach here as their
    // Go ToApiString form). Bytes must be equal and the cell must carry text:
    // no parse-the-number fallback, no rendering a container down to a string.
    if (opts.typed) {
        return switch (got) {
            .string, .date, .timestamp, .datetime, .time, .interval => |s| std.mem.eql(u8, want, s),
            else => false,
        };
    }
    switch (got) {
        // Date/time kinds render as their Go ToApiString forms, which is what
        // the doc tables print.
        .string, .json, .date, .timestamp, .datetime, .time, .interval, .range => |s| {
            if (std.mem.eql(u8, want, s)) return true;
            // A quoted number in the docs against a NUMERIC-as-string cell.
            const w = std.fmt.parseFloat(f64, want) catch return false;
            const h = std.fmt.parseFloat(f64, s) catch return false;
            return floatNear(w, h, opts.tolerance);
        },
        // The docs quote numbers as often as not.
        .int, .float, .bool => {
            const w = std.fmt.parseFloat(f64, want) catch return false;
            return numericMatch(w, got, opts);
        },
        .bytes => |b| return std.mem.eql(u8, want, b),
        .array, .struct_ => {
            const rendered = try renderCell(gpa, got);
            defer gpa.free(rendered);
            return std.mem.eql(u8, want, rendered);
        },
        .null => return false,
    }
}

/// A cell as the reference docs print it: arrays `[a, b]`, structs `{1 a}`.
/// Caller owns the result.
///
/// Deliberately not `src/main.zig`'s `printCell`: that one is private to the
/// CLI, renders bytes as hex, and has no NULL spelling inside a container.
pub fn renderCell(gpa: std.mem.Allocator, cell: driver.Cell) Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(gpa);
    try writeCell(gpa, &buf, cell);
    return buf.toOwnedSlice(gpa);
}

fn writeCell(gpa: std.mem.Allocator, buf: *std.ArrayList(u8), cell: driver.Cell) Error!void {
    switch (cell) {
        .null => try buf.appendSlice(gpa, "NULL"),
        .bool => |b| try buf.appendSlice(gpa, if (b) "true" else "false"),
        .int => |v| try buf.print(gpa, "{d}", .{v}),
        .float => |v| try buf.print(gpa, "{d}", .{v}),
        .string, .json, .date, .timestamp, .datetime, .time, .interval, .range => |s| {
            try buf.appendSlice(gpa, s);
        },
        .bytes => |b| try buf.appendSlice(gpa, b),
        .array => |cells| {
            try buf.append(gpa, '[');
            for (cells, 0..) |c, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try writeCell(gpa, buf, c);
            }
            try buf.append(gpa, ']');
        },
        .struct_ => |fields| {
            // Value first, then the field name, which is omitted when the
            // field is anonymous: `{blue color, round shape}`, `{2025 year, 09
            // month, 10 day}`, `{NULL id, ABC name}`, `{1}`. That is how the
            // reference docs print a STRUCT (operators.md, string_functions.md)
            // and it is what ZetaSQL's Value::Format produces. Reading names
            // first, JSON-style, would be a third convention answering to
            // nothing.
            try buf.append(gpa, '{');
            for (fields, 0..) |f, i| {
                if (i > 0) try buf.appendSlice(gpa, ", ");
                try writeCell(gpa, buf, f.value);
                if (f.name.len > 0) try buf.print(gpa, " {s}", .{f.name});
            }
            try buf.append(gpa, '}');
        },
    }
}

// ---- tests ----

const testing = std.testing;

/// Parses a ZON value and matches it against `got`, the way the runner will.
fn checkOpts(src: [:0]const u8, got: driver.Cell, opts: Options) !bool {
    const gpa = testing.allocator;
    var ast = try std.zig.Ast.parse(gpa, src, .zon);
    defer ast.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);
    try testing.expect(zoir.compile_errors.len == 0);
    return matches(gpa, zoir, .root, got, opts);
}

fn check(src: [:0]const u8, got: driver.Cell) !bool {
    return checkOpts(src, got, .{});
}

/// The same, under the `testdata/specs/zigquery` comparison.
fn checkTyped(src: [:0]const u8, got: driver.Cell) !bool {
    return checkOpts(src, got, typed_options);
}

test "scalars match their own kind" {
    try testing.expect(try check("null", .null));
    try testing.expect(try check("true", .{ .bool = true }));
    try testing.expect(try check("false", .{ .bool = false }));
    try testing.expect(!try check("true", .{ .bool = false }));
    try testing.expect(try check("42", .{ .int = 42 }));
    try testing.expect(!try check("42", .{ .int = 43 }));
    try testing.expect(try check("\"ab\"", .{ .string = "ab" }));
    try testing.expect(!try check("\"ab\"", .{ .string = "ba" }));
}

test "int literals past i32 arrive as big and still compare" {
    // The corpus really does carry microsecond timestamps this size.
    try testing.expect(try check("1710504000000000", .{ .int = 1710504000000000 }));
    // Off by one. Exact, not tolerant: relatively these differ by only 6e-16,
    // so a float comparison would call them equal.
    try testing.expect(!try check("1710504000000000", .{ .int = 1710504000000001 }));
    try testing.expect(try check("-1710504000000000", .{ .int = -1710504000000000 }));
    // Beyond i64 entirely: no integer cell can equal it.
    try testing.expect(!try check("99999999999999999999999999", .{ .int = std.math.maxInt(i64) }));
}

test "floats compare with tolerance, not textually" {
    try testing.expect(try check("3.0", .{ .float = 3.0 }));
    try testing.expect(try check("4.71238898038469", .{ .float = 4.712388980384690 }));
    try testing.expect(!try check("3.0", .{ .float = 3.01 }));
    // An int want against a float cell and the reverse.
    try testing.expect(try check("3", .{ .float = 3.0 }));
    try testing.expect(try check("3.0", .{ .int = 3 }));
}

test "float specials are literal keywords in ZON" {
    try testing.expect(try check("nan", .{ .float = std.math.nan(f64) }));
    try testing.expect(try check("inf", .{ .float = std.math.inf(f64) }));
    try testing.expect(try check("-inf", .{ .float = -std.math.inf(f64) }));
    try testing.expect(!try check("inf", .{ .float = -std.math.inf(f64) }));
}

test "NUMERIC and JSON cells arrive as strings but compare numerically" {
    try testing.expect(try check("1.25", .{ .string = "1.25" }));
    try testing.expect(try check("100", .{ .string = "100" }));
    // and a quoted number in the docs against a real numeric cell
    try testing.expect(try check("\"42\"", .{ .int = 42 }));
    try testing.expect(!try check("\"42\"", .{ .int = 43 }));
}

test "a string want matches every date/time cell kind" {
    try testing.expect(try check("\"2024-03-15\"", .{ .date = "2024-03-15" }));
    try testing.expect(try check("\"2024-03-15T12:30:45\"", .{ .datetime = "2024-03-15T12:30:45" }));
    try testing.expect(try check("\"12:30:45\"", .{ .time = "12:30:45" }));
    try testing.expect(try check("\"1-2 3 4:5:6\"", .{ .interval = "1-2 3 4:5:6" }));
}

test "arrays compare elementwise" {
    var cells = [_]driver.Cell{ .{ .int = 1 }, .{ .int = 2 }, .{ .int = 3 } };
    try testing.expect(try check(".{ 1, 2, 3 }", .{ .array = &cells }));
    try testing.expect(!try check(".{ 1, 2 }", .{ .array = &cells }));
    try testing.expect(!try check(".{ 1, 2, 4 }", .{ .array = &cells }));
}

test "an empty ZON literal in value position is an empty array" {
    var none = [_]driver.Cell{};
    try testing.expect(try check(".{}", .{ .array = &none }));
}

test "a string want falls back to rendering an array or struct" {
    var cells = [_]driver.Cell{ .{ .int = 1 }, .{ .int = 2 } };
    try testing.expect(try check("\"[1, 2]\"", .{ .array = &cells }));

    var fields = [_]driver.Cell.Field{
        .{ .name = "a", .value = .{ .int = 1 } },
        .{ .name = "b", .value = .{ .string = "x" } },
    };
    try testing.expect(try check("\"{1 a, x b}\"", .{ .struct_ = &fields }));
}

test "a struct renders value-then-name, as the reference docs print it" {
    // docs/operators.md:2656 prints STRUCT('blue' AS color, 'round' AS shape)
    // as `{blue color, round shape}` — the name trails its value.
    var named = [_]driver.Cell.Field{
        .{ .name = "color", .value = .{ .string = "blue" } },
        .{ .name = "shape", .value = .{ .string = "round" } },
    };
    try testing.expect(try check("\"{blue color, round shape}\"", .{ .struct_ = &named }));

    // An anonymous field contributes its value alone: `SELECT STRUCT(1)` is
    // documented as `{1}`, not `{1 }`.
    var one = [_]driver.Cell.Field{.{ .name = "", .value = .{ .int = 1 } }};
    try testing.expect(try check("\"{1}\"", .{ .struct_ = &one }));

    var two = [_]driver.Cell.Field{
        .{ .name = "", .value = .{ .string = "abc" } },
        .{ .name = "", .value = .{ .int = 3 } },
    };
    try testing.expect(try check("\"{abc, 3}\"", .{ .struct_ = &two }));

    // Named and anonymous side by side: docs/string_functions.md:3099 prints
    // `{id key, 123}`.
    var mixed = [_]driver.Cell.Field{
        .{ .name = "key", .value = .{ .string = "id" } },
        .{ .name = "", .value = .{ .int = 123 } },
    };
    try testing.expect(try check("\"{id key, 123}\"", .{ .struct_ = &mixed }));

    // And a NULL keeps its spelling inside the braces
    // (docs/string_functions.md:3168, `{NULL id, ABC name}`).
    var with_null = [_]driver.Cell.Field{
        .{ .name = "id", .value = .null },
        .{ .name = "name", .value = .{ .string = "ABC" } },
    };
    try testing.expect(try check("\"{NULL id, ABC name}\"", .{ .struct_ = &with_null }));
}

test "renderCell spells NULL inside containers" {
    const gpa = testing.allocator;
    var cells = [_]driver.Cell{ .{ .int = 1 }, .null };
    const s = try renderCell(gpa, .{ .array = &cells });
    defer gpa.free(s);
    try testing.expectEqualStrings("[1, NULL]", s);
}

test "a char literal never matches - the converter must not emit single quotes" {
    try testing.expect(!try check("'a'", .{ .int = 97 }));
    try testing.expect(!try check("'a'", .{ .string = "a" }));
}

// ---- typed mode ----
//
// Each of these pairs a loose-mode match with the typed-mode rejection of the
// same input. The rejections are the point: they are the type assertions the
// corpus runner made, which a bare untyped conversion would have thrown away.

test "typed: a number want demands a numeric cell of its own kind" {
    try testing.expect(try checkTyped("42", .{ .int = 42 }));
    try testing.expect(!try checkTyped("42", .{ .int = 43 }));
    try testing.expect(try checkTyped("1.5", .{ .float = 1.5 }));

    // Loose mode reads NUMERIC/BIGNUMERIC/JSON cells, which arrive as text, as
    // numbers. A typed INT64 expectation must not.
    try testing.expect(try check("42", .{ .string = "42" }));
    try testing.expect(!try checkTyped("42", .{ .string = "42" }));

    // Nor may INT64 satisfy itself with a FLOAT64 cell, or the reverse.
    try testing.expect(try check("3", .{ .float = 3.0 }));
    try testing.expect(!try checkTyped("3", .{ .float = 3.0 }));
    try testing.expect(try check("3.0", .{ .int = 3 }));
    try testing.expect(!try checkTyped("3.0", .{ .int = 3 }));

    // BOOL coercing to 1/0 is a doc-table convenience, not a typed answer.
    try testing.expect(try check("1", .{ .bool = true }));
    try testing.expect(!try checkTyped("1", .{ .bool = true }));
}

test "typed: floats keep the corpus's 1e-5 tolerance, not the doc suite's 1e-9" {
    // go-zetasqlite compared floats at relative 1e-5 because the two engines'
    // float pipelines differ; the doc suite has no such gap.
    try testing.expect(try checkTyped("1.0", .{ .float = 1.000001 }));
    try testing.expect(!try check("1.0", .{ .float = 1.000001 }));
    try testing.expect(!try checkTyped("1.0", .{ .float = 1.001 }));
}

test "typed: a string want demands text, never a number" {
    try testing.expect(try checkTyped("\"ab\"", .{ .string = "ab" }));
    try testing.expect(try checkTyped("\"2024-03-15\"", .{ .date = "2024-03-15" }));
    try testing.expect(try checkTyped("\"12:30:45\"", .{ .time = "12:30:45" }));

    // The corpus holds 134 numeric-looking string cells. Loose mode lets any of
    // them be satisfied by an INT64 result; that is the single largest thing a
    // bare conversion would have given away.
    try testing.expect(try check("\"42\"", .{ .int = 42 }));
    try testing.expect(!try checkTyped("\"42\"", .{ .int = 42 }));
    try testing.expect(try check("\"1.25\"", .{ .float = 1.25 }));
    try testing.expect(!try checkTyped("\"1.25\"", .{ .float = 1.25 }));

    // And text is compared byte-for-byte: no reparsing "1.0" as 1.
    try testing.expect(try check("\"1.0\"", .{ .string = "1" }));
    try testing.expect(!try checkTyped("\"1.0\"", .{ .string = "1" }));
}

test "typed: an array want demands an array, not a struct read positionally" {
    var cells = [_]driver.Cell{ .{ .int = 1 }, .{ .int = 2 } };
    try testing.expect(try checkTyped(".{ 1, 2 }", .{ .array = &cells }));
    try testing.expect(!try checkTyped(".{ 1, 3 }", .{ .array = &cells }));

    var fields = [_]driver.Cell.Field{
        .{ .name = "a", .value = .{ .int = 1 } },
        .{ .name = "b", .value = .{ .int = 2 } },
    };
    try testing.expect(try check(".{ 1, 2 }", .{ .struct_ = &fields }));
    try testing.expect(!try checkTyped(".{ 1, 2 }", .{ .struct_ = &fields }));

    // The rendered-text fallback goes too.
    try testing.expect(try check("\"[1, 2]\"", .{ .array = &cells }));
    try testing.expect(!try checkTyped("\"[1, 2]\"", .{ .array = &cells }));
}

test "typed: a struct literal matches a STRUCT cell by field name" {
    var fields = [_]driver.Cell.Field{
        .{ .name = "fruit", .value = .{ .string = "pears" } },
        .{ .name = "sold", .value = .{ .int = 40 } },
    };
    const cell: driver.Cell = .{ .struct_ = &fields };

    try testing.expect(try checkTyped(".{ .fruit = \"pears\", .sold = 40 }", cell));
    // Field order is the cell's business, not the expectation's.
    try testing.expect(try checkTyped(".{ .sold = 40, .fruit = \"pears\" }", cell));
    // A wrong value, a wrong name, and a missing field all fail.
    try testing.expect(!try checkTyped(".{ .fruit = \"pears\", .sold = 41 }", cell));
    try testing.expect(!try checkTyped(".{ .fruit = \"pears\", .qty = 40 }", cell));
    try testing.expect(!try checkTyped(".{ .fruit = \"pears\" }", cell));

    // Nested, as `SELECT STRUCT(STRUCT(1 AS n) AS inner)` returns.
    var inner = [_]driver.Cell.Field{.{ .name = "n", .value = .{ .int = 1 } }};
    var outer = [_]driver.Cell.Field{.{ .name = "s", .value = .{ .struct_ = &inner } }};
    try testing.expect(try checkTyped(".{ .s = .{ .n = 1 } }", .{ .struct_ = &outer }));
    try testing.expect(!try checkTyped(".{ .s = .{ .n = 2 } }", .{ .struct_ = &outer }));

    // Outside typed mode a struct literal is still a converter bug: the doc
    // tables print structs positionally, so nothing there should emit one.
    try testing.expect(!try check(".{ .fruit = \"pears\", .sold = 40 }", cell));
}

test "typed: null, bool and empty arrays are unchanged" {
    try testing.expect(try checkTyped("null", .null));
    try testing.expect(!try checkTyped("null", .{ .int = 0 }));
    try testing.expect(!try checkTyped("\"\"", .null));
    try testing.expect(try checkTyped("true", .{ .bool = true }));
    try testing.expect(!try checkTyped("true", .{ .int = 1 }));

    var none = [_]driver.Cell{};
    try testing.expect(try checkTyped(".{}", .{ .array = &none }));
    try testing.expect(!try checkTyped(".{}", .null));
}
