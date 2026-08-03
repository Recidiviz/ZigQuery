const std = @import("std");

/// Compile-time options for the SQLite amalgamation.
///
///   USE_URI            `sqlite.zig` opens through `sqlite3_open`, and the
///                      driver's and server's in-memory DSN is
///                      `file:/<name>?vfs=memdb`. Off (the default), that URI
///                      is taken as a literal filename and every `:memory:`
///                      database becomes a file on disk.
///   MAX_FUNCTION_ARG   corpus cases 724/725 ("function call with many
///                      arguments - under/above limit") are in baseline.txt
///                      and pin the boundary at exactly 1000: 999 arguments
///                      must evaluate, 1001 must raise "too many arguments on
///                      function". The default of 127 fails both.
///   DQS=0              a double-quoted token that names no column stays an
///                      error rather than falling back to a string literal.
const sqlite_cflags = [_][]const u8{
    // The amalgamation's own warnings are the vendor's business, not ours.
    "-w",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_USE_URI=1",
    "-DSQLITE_DQS=0",
    "-DSQLITE_MAX_FUNCTION_ARG=1000",
};

// zetasqlite-zig: GoogleSQL -> SQLite translator, a faithful Zig port of
// Recidiviz/go-zetasqlite. The GoogleSQL analyzer is consumed as a Bazel-built
// C-ABI dylib from the googlesql repo (see zig/BUILD there); SQLite is the
// amalgamation, pinned by build.zig.zon and compiled by Zig itself, so the
// only build inputs from outside this repo are Zig and Bazel.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opts: std.Build.StandardOptimizeOptionOptions = .{ .preferred_optimize_mode = std.builtin.OptimizeMode.ReleaseFast };
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

    // The codec phase timers are off by default because they are not free at
    // codec call volumes: a span costs ~18 ns, and a real workload makes
    // millions of them (commit a3bb4e3 measured 11.9 M over ~19 k rows, which
    // is ~210 ms of pure instrumentation). Left always-on they distort the very
    // path they exist to measure. Turn them on for harness runs only.
    const codec_timers = b.option(
        bool,
        "codec-timers",
        "Instrument the value codec phases (~18ns/span; needed by codec-bench)",
    ) orelse false;
    const build_opts = b.addOptions();
    build_opts.addOption(bool, "codec_timers", codec_timers);

    // SQLite is built once and linked into every module below, always at
    // ReleaseFast whatever `-Drelease` says. The `coverage` step builds the
    // whole module tree a second time at -ODebug, and an -O0 amalgamation
    // would make every kcov run pay for a library whose lines kcov then
    // discards anyway (--include-path keeps the report to src/).
    const sqlite_dep = b.dependency("sqlite", .{});
    const sqlite_headers = sqlite_dep.path("");
    const sqlite = b.addLibrary(.{
        .name = "sqlite3",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    sqlite.root_module.addCSourceFile(.{
        .file = sqlite_dep.path("sqlite3.c"),
        .flags = &sqlite_cflags,
    });
    sqlite.root_module.addIncludePath(sqlite_headers);

    // The `coverage` step builds a second copy of the module tree at -ODebug,
    // so the wiring lives in engineModule/serverModule rather than inline.
    const deps: EngineDeps = .{
        .target = target,
        .build_options = build_opts.createModule(),
        .shim_dylib = shim_dylib,
        .shim_dir = shim_dir,
        .sqlite = sqlite,
        .sqlite_headers = sqlite_headers,
    };
    const mod = engineModule(b, deps, optimize);

    const maybe_bazel: ?*std.Build.Step.Run = if (build_shim) blk: {
        const bazel = b.addSystemCommand(&.{
            "bazel",                          "build",
            "-c",                             "opt",
            // Explicit on the command line because ~/.bazelrc is read after
            // the workspace .bazelrc and would otherwise win.
            "--jobs=4",                       "--local_resources=cpu=4",
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

    // Spec conformance: replays testdata/specs/**.zon, imported from
    // goccy/googlesqlite by tools/spec_import.py.
    const spec_exe = b.addExecutable(.{
        .name = "spec-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/spec_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| spec_exe.step.dependOn(&bz.step);
    b.installArtifact(spec_exe);
    const run_spec = b.addRunArtifact(spec_exe);
    run_spec.setCwd(.{ .cwd_relative = b.build_root.path.? });
    if (b.args) |args| run_spec.addArgs(args);
    b.step("spec", "Run the GoogleSQL spec corpus").dependOn(&run_spec.step);

    // Regenerates src/proto/resolved_ast.zig from the committed
    // proto/googlesql.fdset. Run when the googlesql submodule (and with it the
    // .fdset) moves — never as part of `test`, exactly as the Python script it
    // replaced was run by hand.
    //
    // The generator is self-hosting: `pb` below is the very file the run step
    // overwrites, because --include_imports put descriptor.proto's own decoders
    // in there. See the header of tools/gen_proto.zig.
    const gen_proto = b.addExecutable(.{
        .name = "gen-proto",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/gen_proto.zig"),
            // A build tool: it runs here, so it follows the host and not
            // -Dtarget. -ODebug because it is a second of work on a 190 KB
            // input, and optimizing it would cost more than it saves.
            .target = b.graph.host,
            .optimize = .Debug,
            .imports = &.{.{
                .name = "pb",
                .module = b.createModule(.{
                    .root_source_file = b.path("src/proto/resolved_ast.zig"),
                    .target = b.graph.host,
                    .optimize = .Debug,
                }),
            }},
        }),
    });
    const run_gen_proto = b.addRunArtifact(gen_proto);
    run_gen_proto.addFileArg(b.path("proto/googlesql.fdset"));
    run_gen_proto.addArg(b.pathFromRoot("src/proto/resolved_ast.zig"));
    run_gen_proto.has_side_effects = true;

    // The generator emits structurally correct Zig and leaves layout to `zig
    // fmt`, so the committed file stays canonical and future diffs stay small.
    const fmt_gen_proto = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
    fmt_gen_proto.addArg(b.pathFromRoot("src/proto/resolved_ast.zig"));
    fmt_gen_proto.has_side_effects = true;
    fmt_gen_proto.step.dependOn(&run_gen_proto.step);

    b.step("gen-proto", "Regenerate src/proto/resolved_ast.zig from proto/googlesql.fdset")
        .dependOn(&fmt_gen_proto.step);

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
    b.installArtifact(codec_exe);
    const run_codec = b.addRunArtifact(codec_exe);
    if (b.args) |args| run_codec.addArgs(args);
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

    // The goccy/googlesqlite bench corpus (testdata/bench_corpus), so this
    // engine can be read against that project's published RESULTS.md.
    const gsqlbench_exe = b.addExecutable(.{
        .name = "gsql-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/gsql_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| gsqlbench_exe.step.dependOn(&bz.step);
    b.installArtifact(gsqlbench_exe);
    const run_gsqlbench = b.addRunArtifact(gsqlbench_exe);
    run_gsqlbench.setCwd(.{ .cwd_relative = b.build_root.path.? });
    if (b.args) |args| run_gsqlbench.addArgs(args);
    b.step("gsql-bench", "Run the goccy/googlesqlite bench corpus")
        .dependOn(&run_gsqlbench.step);

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

    // What an "in-memory" database still writes to disk, and whether
    // temp_store moves it.
    const ioprobe_exe = b.addExecutable(.{
        .name = "io-probe",
        .root_module = b.createModule(.{
            .root_source_file = b.path("harness/io_probe.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zetasqlite", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| ioprobe_exe.step.dependOn(&bz.step);
    b.installArtifact(ioprobe_exe);
    const run_ioprobe = b.addRunArtifact(ioprobe_exe);
    if (b.args) |args| run_ioprobe.addArgs(args);
    b.step("io-probe", "Measure SQLite temp-file traffic on an in-memory db")
        .dependOn(&run_ioprobe.step);

    // ---- bigquery-emulator server ----
    //
    // A separate module from the engine so `test` and `corpus` — the engine's
    // regression gates — are unaffected by server work.
    const server_mod = serverModule(b, target, optimize, mod);

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

    // ---- coverage ----
    //
    // kcov (`brew install kcov`) drives a test binary under a debugger and
    // reads line hits back out of DWARF, so nothing is instrumented at compile
    // time. The tests are pinned to -ODebug regardless of -Doptimize: once
    // inlining and dead-code elimination are on, line coverage measures the
    // optimizer rather than the tests.
    //
    // --include-path keeps the report to this repo's own sources; without it
    // the Zig std lib dominates and the percentage means nothing.
    const cov_mod = engineModule(b, deps, .Debug);
    const cov_server_mod = serverModule(b, target, .Debug, cov_mod);
    const cov_tests = b.addTest(.{ .name = "engine-tests", .root_module = cov_mod });
    const cov_server_tests = b.addTest(.{ .name = "server-tests", .root_module = cov_server_mod });
    if (maybe_bazel) |bz| {
        cov_tests.step.dependOn(&bz.step);
        cov_server_tests.step.dependOn(&bz.step);
    }

    const cov_root = b.pathJoin(&.{ b.install_path, "coverage" });
    const cov_runs = b.pathJoin(&.{ cov_root, "runs" });
    const cov_report = b.pathJoin(&.{ cov_root, "report" });
    const cov_include = b.fmt("--include-path={s}", .{b.pathFromRoot("src")});

    // kcov's mkdir of the output directory is not recursive, and it does not
    // notice until the first periodic flush — mid-run, after minutes of tests.
    const cov_mkdir = b.addSystemCommand(&.{ "mkdir", "-p", cov_runs, cov_report });

    // --clean drops what the *same* binary recorded last time (the other
    // binary's directory is left alone), so a test that has since been deleted
    // stops counting as covered.
    const kcov_engine = b.addSystemCommand(&.{ "kcov", "--clean", cov_include, cov_runs });
    kcov_engine.addArtifactArg(cov_tests);
    kcov_engine.has_side_effects = true;
    kcov_engine.step.dependOn(&cov_mkdir.step);

    // Ordered, not parallel: both runs rewrite the shared index in cov_runs.
    const kcov_server = b.addSystemCommand(&.{ "kcov", "--clean", cov_include, cov_runs });
    kcov_server.addArtifactArg(cov_server_tests);
    kcov_server.has_side_effects = true;
    kcov_server.step.dependOn(&kcov_engine.step);

    // Each run only sees the half of the tree its own binary links, so the
    // headline number has to come from a merge of the two.
    const kcov_merge = b.addSystemCommand(&.{ "kcov", "--merge", cov_report, cov_runs });
    kcov_merge.has_side_effects = true;
    kcov_merge.step.dependOn(&kcov_server.step);

    b.step("coverage", b.fmt("Line coverage for the unit tests -> {s}/index.html", .{cov_report}))
        .dependOn(&kcov_merge.step);

    // Ephor static analysis
    const ephor_dep = b.dependency("ephor", .{ .target = target, .optimize = .ReleaseSafe });
    const ephor_artifact = ephor_dep.artifact("ephor");
    const ephor_cmd = b.addRunArtifact(ephor_artifact);
    if (b.args) |args| {
        ephor_cmd.addArgs(args);
    }
    const ephor_step = b.step("ephor", "Run ephor static analysis");
    ephor_step.dependOn(&ephor_cmd.step);

    // Ephor upgrade
    const ephor_upgrade_cmd = b.addRunArtifact(ephor_artifact);
    ephor_upgrade_cmd.addArgs(&.{"upgrade"});
    const ephor_upgrade_step = b.step("ephor-upgrade", "Upgrade ephor to latest version");
    ephor_upgrade_step.dependOn(&ephor_upgrade_cmd.step);
}

/// Everything the engine module needs beyond an optimize mode.
const EngineDeps = struct {
    target: std.Build.ResolvedTarget,
    build_options: *std.Build.Module,
    shim_dylib: []const u8,
    shim_dir: []const u8,
    /// Static libsqlite3, shared by every module (see the note at its
    /// construction: always ReleaseFast, even under -ODebug).
    sqlite: *std.Build.Step.Compile,
    /// The amalgamation directory, for `sqlite.zig`'s @cInclude.
    sqlite_headers: std.Build.LazyPath,
};

fn engineModule(
    b: *std.Build,
    deps: EngineDeps,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target = deps.target,
        .optimize = optimize,
        .link_libc = true,
    });
    mod.addImport("build_options", deps.build_options);
    mod.addIncludePath(deps.sqlite_headers);
    mod.linkLibrary(deps.sqlite);
    mod.addObjectFile(.{ .cwd_relative = deps.shim_dylib });
    mod.addRPath(.{ .cwd_relative = deps.shim_dir });
    return mod;
}

fn serverModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    engine: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/server/root.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "zetasqlite", .module = engine }},
    });
}
