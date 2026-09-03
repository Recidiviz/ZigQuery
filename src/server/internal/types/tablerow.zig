//! The `{"f":[{"v":…}]}` shape a result row travels in.
//!
//! A leaf module — driver and govalue, nothing from the handler layer — because
//! the generated `proto/bigquery.zig` names `TableRow` for `QueryResponse.rows`
//! and would otherwise close an import cycle.
//!
//! Two shapes are load-bearing for clients and are reproduced exactly:
//! `"v": null` is emitted rather than omitted, and every scalar is a string,
//! because Go renders cells with fmt.Sprint
//! (internal/contentdata/repository.go convertValueToCell). See govalue.zig for
//! the float rules that follow.

const std = @import("std");
const zigquery = @import("zigquery");
const driver = zigquery.driver;
const govalue = @import("govalue.zig");

/// Named rather than inferred: writeValue and jsonStringify are mutually
/// recursive through `jw.write`, and these hooks only ever run under Stringify.
const Error = std.json.Stringify.Error;

pub const TableCell = struct {
    cell: driver.Cell,

    pub fn jsonStringify(self: TableCell, jw: anytype) Error!void {
        try jw.beginObject();
        try jw.objectField("v");
        try writeValue(self.cell, jw);
        try jw.endObject();
    }
};

pub const TableRow = struct {
    cells: []const driver.Cell,

    pub fn jsonStringify(self: TableRow, jw: anytype) Error!void {
        try jw.beginObject();
        try jw.objectField("f");
        try jw.beginArray();
        for (self.cells) |cell| try jw.write(TableCell{ .cell = cell });
        try jw.endArray();
        try jw.endObject();
    }
};

fn writeValue(cell: driver.Cell, jw: anytype) Error!void {
    switch (cell) {
        .null => try jw.write(null),
        .int => |v| {
            var buf: [govalue.int_buf_len]u8 = undefined;
            try jw.write(govalue.formatIntBuf(&buf, v));
        },
        .float => |v| {
            var buf: [govalue.float_buf_len]u8 = undefined;
            try jw.write(govalue.formatFloatBuf(&buf, v));
        },
        .bool => |v| try jw.write(govalue.formatBool(v)),
        // BYTES arrive already base64-encoded and NUMERIC as decimal text, both
        // as text from the driver — see driver.zig's Cell docs.
        .string,
        .bytes,
        .json,
        .date,
        .timestamp,
        .datetime,
        .time,
        .interval,
        .range,
        => |v| try jw.write(v),
        .array => |items| {
            try jw.beginArray();
            for (items) |item| try jw.write(TableCell{ .cell = item });
            try jw.endArray();
        },
        .struct_ => |fields| {
            try jw.beginObject();
            try jw.objectField("f");
            try jw.beginArray();
            for (fields) |f| try jw.write(TableCell{ .cell = f.value });
            try jw.endArray();
            try jw.endObject();
        },
    }
}

const testing = std.testing;

fn expectRow(expected: []const u8, cells: []const driver.Cell) !void {
    const got = try std.json.Stringify.valueAlloc(
        testing.allocator,
        TableRow{ .cells = cells },
        .{},
    );
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(expected, got);
}

test "a null cell emits v:null rather than omitting the key" {
    try expectRow(
        \\{"f":[{"v":null}]}
    , &.{.null});
}

test "every scalar is a string, with Go's renderings" {
    try expectRow(
        \\{"f":[{"v":"1"},{"v":"1e+21"},{"v":"-0"},{"v":"true"},{"v":"2024-01-02"}]}
    , &.{
        .{ .int = 1 },
        .{ .float = 1e21 },
        .{ .float = -0.0 },
        .{ .bool = true },
        .{ .date = "2024-01-02" },
    });
}

test "an array wraps each element in its own v" {
    var items = [_]driver.Cell{ .{ .int = 1 }, .{ .int = 2 } };
    try expectRow(
        \\{"f":[{"v":[{"v":"1"},{"v":"2"}]}]}
    , &.{.{ .array = &items }});
}

test "a struct nests another f array" {
    var fields = [_]driver.Cell.Field{
        .{ .name = "a", .value = .{ .int = 1 } },
        .{ .name = "b", .value = .{ .string = "x" } },
    };
    try expectRow(
        \\{"f":[{"v":{"f":[{"v":"1"},{"v":"x"}]}}]}
    , &.{.{ .struct_ = &fields }});
}

test "strings are escaped by the serializer" {
    try expectRow(
        \\{"f":[{"v":"a\"b"},{"v":"tab\there"}]}
    , &.{ .{ .string = "a\"b" }, .{ .string = "tab\there" } });
}
