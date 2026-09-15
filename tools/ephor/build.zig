//! ephor, built with the Zig release it supports. The root package's `ephor` and `ephor-upgrade`
//! steps run this package's `run` and `upgrade` steps.

const std = @import("std");

pub fn build(b: *std.Build) void {
    // A build tool: it runs here, so it follows the host.
    const ephor = b.dependency("ephor", .{
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    }).artifact("ephor");
    const here = b.build_root.path orelse ".";

    // ephor reads ephor.json from its working directory, the repository root.
    const run = b.addRunArtifact(ephor);
    run.setCwd(.{ .cwd_relative = b.pathJoin(&.{ here, "..", ".." }) });
    if (b.args) |args| run.addArgs(args);
    b.step("run", "Run ephor over the repository").dependOn(&run.step);

    // `ephor upgrade` rewrites the build.zig.zon in its working directory, this package's.
    const upgrade = b.addRunArtifact(ephor);
    upgrade.addArg("upgrade");
    upgrade.setCwd(.{ .cwd_relative = here });
    b.step("upgrade", "Upgrade ephor to the latest version").dependOn(&upgrade.step);
}
