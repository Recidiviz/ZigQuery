//! CLI: zetasqlite-zig [--sql] "SELECT ..."
//!
//! Executes a GoogleSQL query against an in-memory database and prints the
//! result rows (tab-separated, header first). With --sql, prints the
//! generated SQLite SQL instead of executing (debugging aid).

const std = @import("std");
const zetasqlite = @import("zetasqlite");
const driver = zetasqlite.driver;

pub fn main(init: std.process.Init) !void {
    var stdout_buf: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buf);
    const out = &stdout_writer.interface;

    var print_sql = false;
    var sql: ?[]const u8 = null;
    var args_it = std.process.Args.Iterator.init(init.minimal.args);
    _ = args_it.next(); // program name
    while (args_it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--sql")) {
            print_sql = true;
        } else {
            sql = arg;
        }
    }

    const query = sql orelse {
        try out.writeAll("usage: zetasqlite-zig [--sql] \"SELECT ...\"\n");
        try out.flush();
        std.process.exit(2);
    };

    var arena_state = std.heap.ArenaAllocator.init(init.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    if (print_sql) {
        const stmts = driver.translate(arena, query, .{}) catch |err| {
            try out.print("error: {s}: {s}\n", .{
                @errorName(err),
                zetasqlite.analyzer_ffi.last_error,
            });
            try out.flush();
            std.process.exit(1);
        };
        for (stmts) |stmt| try out.print("{s};\n", .{stmt});
        try out.flush();
        return;
    }

    var db = try driver.Db.open(init.gpa, ":memory:");
    defer db.close();

    var rows = db.query(query, &.{}, .{}) catch |err| {
        try out.print("error: {s}: {s}\n", .{ @errorName(err), db.lastError() });
        try out.flush();
        std.process.exit(1);
    };
    defer rows.deinit();

    for (rows.columns(), 0..) |name, i| {
        if (i > 0) try out.writeAll("\t");
        try out.print("{s}", .{name});
    }
    try out.writeAll("\n");

    while (rows.next() catch |err| {
        try out.print("error: {s}: {s}\n", .{ @errorName(err), db.lastError() });
        try out.flush();
        std.process.exit(1);
    }) |row| {
        for (row, 0..) |cell, i| {
            if (i > 0) try out.writeAll("\t");
            try printCell(out, cell);
        }
        try out.writeAll("\n");
    }
    try out.flush();
}

fn printCell(out: *std.Io.Writer, cell: driver.Cell) std.Io.Writer.Error!void {
    switch (cell) {
        .null => try out.writeAll("NULL"),
        .int => |i| try out.print("{d}", .{i}),
        .float => |f| try out.print("{d}", .{f}),
        .bool => |b| try out.writeAll(if (b) "true" else "false"),
        .string => |s| try out.print("{s}", .{s}),
        .date => |s| try out.print("{s}", .{s}),
        .bytes => |b| {
            for (b) |c| try out.print("{x:0>2}", .{c});
        },
        .array => |cells| {
            try out.writeAll("[");
            for (cells, 0..) |c, i| {
                if (i > 0) try out.writeAll(", ");
                try printCell(out, c);
            }
            try out.writeAll("]");
        },
        .struct_ => |fields| {
            try out.writeAll("{");
            for (fields, 0..) |field, i| {
                if (i > 0) try out.writeAll(", ");
                try out.print("{s}: ", .{field.name});
                try printCell(out, field.value);
            }
            try out.writeAll("}");
        },
    }
}
