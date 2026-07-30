const std = @import("std");

// zetasqlite-zig: GoogleSQL -> SQLite translator, a faithful Zig port of
// Recidiviz/go-zetasqlite. The GoogleSQL analyzer is consumed as a Bazel-built
// C-ABI dylib from the googlesql repo (see zig/BUILD there); SQLite comes from
// the Homebrew keg (the macOS SDK stub lacks window-function support).
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opts: std.Build.StandardOptimizeOptionOptions = .{
        .preferred_optimize_mode = std.builtin.OptimizeMode.ReleaseFast
    };
    const optimize = b.standardOptimizeOption(opts);

    // The shim (//shim) and the googlesql submodule (//third_party/googlesql)
    // both live in this repo now, so Bazel roots here and the dylib lands in
    // our own bazel-bin. The option stays for out-of-tree output bases (CI,
    // a remote cache, a hand-built dylib).
    const shim_rel = b.option(
        []const u8,
        "shim-dylib",
        "Path to libgooglesql_shim.dylib, relative to the repo root",
    ) orelse "bazel-bin/shim/libgooglesql_shim.dylib";
    const build_shim = b.option(
        bool,
        "build-shim",
        "Run `bazel build -c opt //shim:libgooglesql_shim.dylib` first",
    ) orelse false;

    const repo_root = b.build_root.path orelse ".";
    const shim_dylib = b.pathJoin(&.{ repo_root, shim_rel });
    const shim_dir = std.fs.path.dirname(shim_dylib) orelse repo_root;

    const sqlite_include = "/opt/homebrew/opt/sqlite/include";
    const sqlite_lib = "/opt/homebrew/opt/sqlite/lib";

    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addIncludePath(.{ .cwd_relative = sqlite_include });
    mod.addLibraryPath(.{ .cwd_relative = sqlite_lib });
    mod.linkSystemLibrary("sqlite3", .{});
    mod.addObjectFile(.{ .cwd_relative = shim_dylib });
    mod.addRPath(.{ .cwd_relative = shim_dir });

    const maybe_bazel: ?*std.Build.Step.Run = if (build_shim) blk: {
        const bazel = b.addSystemCommand(&.{
            "bazel",       "build",
            "-c",          "opt",
            // Explicit on the command line because ~/.bazelrc is read after
            // the workspace .bazelrc and would otherwise win.
            "--jobs=4",    "--local_resources=cpu=4",
            "//shim:libgooglesql_shim.dylib",
        });
        bazel.setCwd(.{ .cwd_relative = repo_root });
        break :blk bazel;
    } else null;

    // CLI: zetasqlite-zig "SELECT ..." (debug flags: --ast --data --sql)
    const exe = b.addExecutable(.{
        .name = "zetasqlite-zig",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| exe.step.dependOn(&bz.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the CLI").dependOn(&run_cmd.step);

    // Unit tests over the library module.
    const unit_tests = b.addTest(.{ .root_module = mod });
    if (maybe_bazel) |bz| unit_tests.step.dependOn(&bz.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    // Conformance harness: replays testdata/corpus.json.
    const corpus_exe = b.addExecutable(.{
        .name = "corpus-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/corpus_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| corpus_exe.step.dependOn(&bz.step);
    b.installArtifact(corpus_exe);
    const run_corpus = b.addRunArtifact(corpus_exe);
    run_corpus.setCwd(.{ .cwd_relative = b.build_root.path.? });
    if (b.args) |args| run_corpus.addArgs(args);
    b.step("corpus", "Run the conformance corpus").dependOn(&run_corpus.step);

    // Concurrency gating experiment: is the analyzer stack safe to drive from
    // several threads, one Db each? Not part of `test` — it is a deliberate
    // experiment, run on demand.
    const tsan = b.option(
        bool,
        "tsan",
        "Build the concurrency experiment with ThreadSanitizer (Zig side only; " ++
            "the C++ shim needs its own `bazel build --features=tsan` to be covered)",
    ) orelse false;
    const threads_exe = b.addExecutable(.{
        .name = "analyzer-threads",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/analyzer_threads.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| threads_exe.step.dependOn(&bz.step);
    b.installArtifact(threads_exe);
    const run_threads = b.addRunArtifact(threads_exe);
    if (b.args) |args| run_threads.addArgs(args);
    b.step("analyzer-threads", "Run the concurrency gating experiment").dependOn(&run_threads.step);

    // Does a SharedCatalog actually make a connection pool coherent? Paired
    // with a per-connection-catalog control that must fail, so a green result
    // means something.
    const sc_threads_exe = b.addExecutable(.{
        .name = "shared-catalog-threads",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/shared_catalog_threads.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| sc_threads_exe.step.dependOn(&bz.step);
    b.installArtifact(sc_threads_exe);
    const run_sc_threads = b.addRunArtifact(sc_threads_exe);
    if (b.args) |args| run_sc_threads.addArgs(args);
    b.step("shared-catalog-threads", "Shared-catalog coherence under a pool")
        .dependOn(&run_sc_threads.step);

    const codec_exe = b.addExecutable(.{
        .name = "codec-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/codec_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| codec_exe.step.dependOn(&bz.step);
    const run_codec = b.addRunArtifact(codec_exe);
    b.step("codec-bench", "Value codec cost with real rows").dependOn(&run_codec.step);

    // Per-query cost vs catalog size: the baseline the server's caching work
    // has to beat.
    const bench_exe = b.addExecutable(.{
        .name = "bench-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/bench_engine.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| bench_exe.step.dependOn(&bz.step);
    b.installArtifact(bench_exe);
    const run_bench = b.addRunArtifact(bench_exe);
    if (b.args) |args| run_bench.addArgs(args);
    b.step("bench", "Benchmark per-query cost vs catalog size").dependOn(&run_bench.step);

    const loadbench_exe = b.addExecutable(.{
        .name = "load-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/load_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| loadbench_exe.step.dependOn(&bz.step);
    const run_loadbench = b.addRunArtifact(loadbench_exe);
    b.step("load-bench", "Benchmark bulk CREATE TABLE cost").dependOn(&run_loadbench.step);


    // ---- bigquery-emulator server ----
    //
    // A separate module from the engine so `test` and `corpus` — the engine's
    // regression gates — are unaffected by server work.
    const server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zetasqlite", .module = mod }},
    });

    const server_exe = b.addExecutable(.{
        .name = "bigquery-emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/server/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bqserver", .module = server_mod },
                .{ .name = "zetasqlite", .module = mod },
            },
        }),
    });
    if (maybe_bazel) |bz| server_exe.step.dependOn(&bz.step);
    b.installArtifact(server_exe);

    const run_server = b.addRunArtifact(server_exe);
    if (b.args) |args| run_server.addArgs(args);
    b.step("server", "Run the emulator").dependOn(&run_server.step);

    const server_tests = b.addTest(.{ .root_module = server_mod });
    if (maybe_bazel) |bz| server_tests.step.dependOn(&bz.step);
    const run_server_tests = b.addRunArtifact(server_tests);
    b.step("test-server", "Run server unit tests").dependOn(&run_server_tests.step);

    // Where insertAll's time goes, phase by phase, on a captured request body.
    const insertbench_exe = b.addExecutable(.{
        .name = "insert-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/insert_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bqserver", .module = server_mod },
                .{ .name = "zetasqlite", .module = mod },
            },
        }),
    });
    if (maybe_bazel) |bz| insertbench_exe.step.dependOn(&bz.step);
    const run_insertbench = b.addRunArtifact(insertbench_exe);
    if (b.args) |args| run_insertbench.addArgs(args);
    b.step("insert-bench", "Profile a tabledata.insertAll request body")
        .dependOn(&run_insertbench.step);
}
