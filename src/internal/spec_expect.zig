//! Does a doc-derived expected value describe a result cell?
//!
//! The spec corpus (`testdata/specs/**.zon`, see tools/spec_import.py) carries
//! its expected values as bare ZON scalars, because upstream scraped them out
//! of the ASCII result tables printed in the GoogleSQL reference docs. That
//! makes this comparison a different problem from the one
//! `harness/corpus_runner.zig:467` solves: there, every expected value is
//! tagged (`{"t":"int","v":"5"}`) and the *want* side declares its own type.
//! Here it declares nothing, so the same value has to be able to match several
//! `driver.Cell` shapes.
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
//! This lives in the library rather than the harness because it is pure and it
//! is the only part of the spec pipeline that genuinely needs unit tests.

const std = @import("std");
const Zoir = std.zig.Zoir;
const driver = @import("../driver.zig");

pub const Options = struct {
    /// Absolute-or-relative float tolerance. Tighter than the corpus runner's
    /// relative 1e-5: these are published, doc-exact values, not the output of
    /// a differing float pipeline.
    tolerance: f64 = 1e-9,
};

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
            const want_f: f64 = switch (int) {
                .small => |v| @floatFromInt(v),
                .big => |v| v.toFloat(f64, .nearest_even)[0],
            };
            return numericMatch(want_f, got, opts);
        },
        .float_literal => |f| numericMatch(@floatCast(f), got, opts),

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
            // A struct rendered by the docs as a positional list.
            .struct_ => |fields| {
                if (fields.len != range.len) return false;
                for (fields, 0..) |field, i| {
                    if (!try matches(gpa, zoir, range.at(@intCast(i)), field.value, opts)) return false;
                }
                return true;
            },
            else => false,
        },

        // A char literal here means the converter emitted single quotes, which
        // it must never do (`'ab'` would not even parse, `'a'` would silently
        // become 97). Treat it as a corpus bug rather than matching it.
        .char_literal, .enum_literal, .struct_literal => false,
    };
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
    switch (got) {
        // Date/time kinds render as their Go ToApiString forms, which is what
        // the doc tables print.
        .string, .json, .date, .timestamp, .datetime, .time, .interval => |s| {
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
        .string, .json, .date, .timestamp, .datetime, .time, .interval => |s| {
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
fn check(src: [:0]const u8, got: driver.Cell) !bool {
    const gpa = testing.allocator;
    var ast = try std.zig.Ast.parse(gpa, src, .zon);
    defer ast.deinit(gpa);
    var zoir = try std.zig.ZonGen.generate(gpa, ast, .{});
    defer zoir.deinit(gpa);
    try testing.expect(zoir.compile_errors.len == 0);
    return matches(gpa, zoir, .root, got, .{});
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
