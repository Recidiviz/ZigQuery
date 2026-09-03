const std = @import("std");

/// nanoarrow's C sources: the common core, the IPC reader/writer, and the flatcc runtime the IPC layer is generated against.
const nanoarrow_sources = [_][]const u8{
    "src/nanoarrow/common/array.c",
    "src/nanoarrow/common/array_stream.c",
    "src/nanoarrow/common/schema.c",
    "src/nanoarrow/common/utils.c",
    "src/nanoarrow/ipc/codecs.c",
    "src/nanoarrow/ipc/decoder.c",
    "src/nanoarrow/ipc/encoder.c",
    "src/nanoarrow/ipc/reader.c",
    "src/nanoarrow/ipc/writer.c",
    "thirdparty/flatcc/src/runtime/builder.c",
    "thirdparty/flatcc/src/runtime/emitter.c",
    "thirdparty/flatcc/src/runtime/refmap.c",
    "thirdparty/flatcc/src/runtime/verifier.c",
};

const nanoarrow_cflags = [_][]const u8{
    // The vendor's warnings are the vendor's business, as with SQLite.
    "-w",
    // NANOARROW_IPC_WITH_ZSTD is deliberately absent, not set to 0: codecs.c
    // gates on `#if defined(...)`, so defining it at all pulls in <zstd.h>.
    // Without it the IPC layer still builds and simply refuses compressed
    // batches on read; this server only writes, and writes uncompressed.
};

/// Compile-time options for the SQLite amalgamation.
///
///   USE_URI            `sqlite.zig` opens through `sqlite3_open`, and the driver's and server's in-memory DSN is
///                      `file:/<name>?vfs=memdb`. Off (the default), that URI
///                      is taken as a literal filename and every `:memory:`
///                      database becomes a file on disk.
///   MAX_FUNCTION_ARG   the two cases in
///                      testdata/specs/zigquery/syntax/query/function_arg_limit.zon
///                      pin the boundary at exactly 1000: 999 arguments must
///                      evaluate, 1001 must raise "too many arguments on
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

// zigquery: GoogleSQL -> SQLite translator, a faithful Zig port of
// Recidiviz/go-zetasqlite. The GoogleSQL analyzer is consumed as a Bazel-built
// C-ABI dylib from the googlesql repo (see zig/BUILD there); SQLite is the
// amalgamation, pinned by build.zig.zon and compiled by Zig itself, so the
// only build inputs from outside this repo are Zig and Bazel.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const opts: std.Build.StandardOptimizeOptionOptions = .{ .preferred_optimize_mode = std.builtin.OptimizeMode.ReleaseFast };
    const optimize = b.standardOptimizeOption(opts);

    // The shim (//shim) and the googlesql submodule (//third_party/googlesql)
    // both live in this repo now, so Bazel roots here and the library lands in
    // our own bazel-bin. The option stays for out-of-tree output bases (CI,
    // a remote cache, a hand-built library).
    //
    // Mach-O and ELF need different link lines, so //shim carries one
    // cc_binary per platform and the file name follows the target OS. A
    // cc_binary's output is named after the target, which is why this is two
    // targets rather than one with `select()`ed linkopts.
    const shim_name = switch (target.result.os.tag) {
        .macos => "libgooglesql_shim.dylib",
        else => "libgooglesql_shim.so",
    };
    const shim_rel = b.option(
        []const u8,
        "shim-dylib",
        "Path to the googlesql shim shared library, relative to the repo root",
    ) orelse b.pathJoin(&.{ "bazel-bin", "shim", shim_name });
    const build_shim = b.option(
        bool,
        "build-shim",
        "Run `bazel build -c opt //shim:<platform shim>` first",
    ) orelse false;

    const repo_root = b.build_root.path orelse ".";
    const shim_dylib = b.pathJoin(&.{ repo_root, shim_rel });
    const shim_dir = std.fs.path.dirname(shim_dylib) orelse repo_root;

    // A second rpath entry so a binary keeps working once it is copied out of
    // the build tree: the release tarball is bin/ + lib/, and the absolute
    // bazel-bin entry above is dev-only. `docs/M0_FINDINGS.md` describes the
    // install_name_tool dance this replaces. The dylib's install name is
    // already @rpath-relative, so no post-processing is needed either way.
    const shim_portable_rpath = switch (target.result.os.tag) {
        .macos => "@loader_path/../lib",
        else => "$ORIGIN/../lib",
    };

    // The statically-linkable counterpart to the dylib above: //shim also
    // builds a relocatable object with the same 13 GoogleSQL_* symbols
    // exported and everything else (its private abseil/RE2/protobuf) demoted
    // to local binding, so it can link directly into an executable without
    // colliding with a different copy of the same libraries linked in
    // alongside it (see shim/BUILD.bazel's SHIM_EXPORTS comment). Only `exe`
    // and `server_exe` use this — see `static_mod` below; every dev/test/
    // harness artifact keeps linking the dylib dynamically, unchanged.
    const shim_static_target = switch (target.result.os.tag) {
        .macos => "libgooglesql_shim_static_macos",
        else => "libgooglesql_shim_static_linux",
    };
    const shim_static_name = b.fmt("{s}.o", .{shim_static_target});
    const shim_static_rel = b.option(
        []const u8,
        "shim-static-obj",
        "Path to the statically-linkable googlesql shim object, relative to the repo root",
    ) orelse b.pathJoin(&.{ "bazel-bin", "shim", shim_static_name });
    const build_shim_static = b.option(
        bool,
        "build-shim-static",
        "Run `bazel build -c opt //shim:<platform static object>` first",
    ) orelse false;
    const shim_static_obj = b.pathJoin(&.{ repo_root, shim_static_rel });

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

    // gRPC core, for the Storage API transport
    // Built once and shared by every consumer of serverModule, always at
    // ReleaseFast whatever -Drelease says — the same deal SQLite gets above,
    // and for a stronger reason: `serverModule` is instantiated twice (once for
    // the real build, once at -ODebug for `coverage`), and an unpinned optimize
    // would make the second instantiation a second from-source build of
    // BoringSSL, abseil, upb, re2 and gRPC core. That build is ~2m50s on 14
    // cores; paying it twice is not a rounding error.
    //
    //   link_mode = .static  the package defaults to .dynamic, which would put
    //                        a second shared library next to the shim in the
    //                        dist tarball with its own rpath problem. It also
    //                        turns off the Darwin framework inheritance that
    //                        puts -framework CoreFoundation on our link line.
    //   pic       = true     the package couples pic to link_mode (defaulting
    //                        it to `linkmode == .dynamic`), so .static silently
    //                        turns it off. Needed to link the archive into a
    //                        PIE on Linux.
    //
    // `target` is passed through rather than pinned, so -Dcpu=baseline reaches
    // the vendored C/C++ too — see the arm64 SIGILL note in release.yml.
    const grpc_dep = b.dependency("grpc", .{
        .target = target,
        .optimize = .ReleaseFast,
        .link_mode = .static,
        .pic = true,
    });
    // nanoarrow, for the Storage Read API's ARROW format.
    //
    // Pinned to ReleaseFast for the same reason SQLite and gRPC are:
    // `serverModule` is instantiated twice, once at -ODebug for `coverage`, and
    // an unpinned optimize would compile it twice.
    //
    // The config header is normally produced by CMake from
    // nanoarrow_config.h.in. Generating it here rather than checking one in
    // keeps the version in one place and keeps a vendored header out of `src/`,
    // which `.paths` in build.zig.zon would otherwise ship.
    const nanoarrow_dep = b.dependency("nanoarrow", .{});
    const nanoarrow_config = b.addWriteFiles();
    const nanoarrow_config_dir = nanoarrow_config.add("nanoarrow/nanoarrow_config.h",
        \\#ifndef NANOARROW_CONFIG_H_INCLUDED
        \\#define NANOARROW_CONFIG_H_INCLUDED
        \\#define NANOARROW_VERSION_MAJOR 0
        \\#define NANOARROW_VERSION_MINOR 9
        \\#define NANOARROW_VERSION_PATCH 0
        \\#define NANOARROW_VERSION "0.9.0"
        \\#define NANOARROW_VERSION_INT                                        \
        \\  (NANOARROW_VERSION_MAJOR * 10000 + NANOARROW_VERSION_MINOR * 100 + \
        \\   NANOARROW_VERSION_PATCH)
        \\#if !defined(NANOARROW_CXX_NAMESPACE)
        \\#define NANOARROW_CXX_NAMESPACE nanoarrow
        \\#endif
        \\#define NANOARROW_CXX_NAMESPACE_BEGIN namespace NANOARROW_CXX_NAMESPACE {
        \\#define NANOARROW_CXX_NAMESPACE_END }
        \\#endif
        \\
    );
    const nanoarrow = b.addLibrary(.{
        .name = "nanoarrow",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
            .link_libc = true,
        }),
    });
    nanoarrow.root_module.addCSourceFiles(.{
        .root = nanoarrow_dep.path(""),
        .files = &nanoarrow_sources,
        .flags = &nanoarrow_cflags,
    });
    // Three roots: the library's own headers, the generated config beside them,
    // and flatcc's runtime headers, which the IPC sources include directly.
    nanoarrow.root_module.addIncludePath(nanoarrow_dep.path("src"));
    nanoarrow.root_module.addIncludePath(nanoarrow_config_dir.dirname().dirname());
    nanoarrow.root_module.addIncludePath(nanoarrow_dep.path("thirdparty/flatcc/include"));
    // The narrow C surface Zig actually calls. It lives with the library rather
    // than in the server module because it is the only thing that includes
    // nanoarrow's own headers -- see the comment at the top of the .h.
    nanoarrow.root_module.addCSourceFile(.{
        .file = b.path("src/server/grpc/nanoarrow_shim.c"),
        .flags = &.{"-std=c11"},
    });
    nanoarrow.root_module.addIncludePath(b.path("src/server/grpc"));

    const server_deps: ServerDeps = .{
        .target = target,
        .cgrpc = grpc_dep.module("cgrpc"),
        .nanoarrow = nanoarrow,
        // Only the shim header: Zig never sees nanoarrow's own.
        .nanoarrow_headers = &.{b.path("src/server/grpc")},
    };

    // The `coverage` step builds a second copy of the module tree at -ODebug,
    // so the wiring lives in engineModule/serverModule rather than inline.
    const deps: EngineDeps = .{
        .target = target,
        .build_options = build_opts.createModule(),
        .shim_dylib = shim_dylib,
        .shim_dir = shim_dir,
        .shim_portable_rpath = shim_portable_rpath,
        .shim_static_obj = shim_static_obj,
        .sqlite = sqlite,
        .sqlite_headers = sqlite_headers,
    };
    const mod = engineModule(b, deps, optimize, false);

    const maybe_bazel: ?*std.Build.Step.Run = if (build_shim) blk: {
        const bazel = b.addSystemCommand(&.{
            "bazel",                           "build",
            "-c",                              "opt",
            // Explicit on the command line because ~/.bazelrc is read after
            // the workspace .bazelrc and would otherwise win.
            "--jobs=4",                        "--local_resources=cpu=4",
            b.fmt("//shim:{s}", .{shim_name}),
        });
        bazel.setCwd(.{ .cwd_relative = repo_root });
        break :blk bazel;
    } else null;

    const maybe_bazel_static: ?*std.Build.Step.Run = if (build_shim_static) blk: {
        const bazel = b.addSystemCommand(&.{
            "bazel",                                    "build",
            "-c",                                       "opt",
            "--jobs=4",                                 "--local_resources=cpu=4",
            b.fmt("//shim:{s}", .{shim_static_target}),
        });
        bazel.setCwd(.{ .cwd_relative = repo_root });
        break :blk bazel;
    } else null;

    // The two release products link the shim's code directly rather than the
    // dylib every other module above/below uses — see engineModule's
    // `static_shim` doc comment.
    const static_mod = engineModule(b, deps, optimize, true);

    // CLI: zigquery "SELECT ..." (debug flags: --ast --data --sql)
    const exe = b.addExecutable(.{
        .name = "zigquery",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/cli.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigquery", .module = static_mod }},
        }),
    });
    if (maybe_bazel_static) |bz| exe.step.dependOn(&bz.step);
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| run_cmd.addArgs(args);
    b.step("run", "Run the CLI").dependOn(&run_cmd.step);

    // Unit tests over the library module.
    const unit_tests = b.addTest(.{ .root_module = mod });
    if (maybe_bazel) |bz| unit_tests.step.dependOn(&bz.step);
    const run_unit_tests = b.addRunArtifact(unit_tests);
    b.step("test", "Run unit tests").dependOn(&run_unit_tests.step);

    // Conformance harness: replays testdata/specs/**.zon.
    const spec_exe = b.addExecutable(.{
        .name = "spec-runner",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/spec/spec_runner.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| spec_exe.step.dependOn(&bz.step);
    b.installArtifact(spec_exe);
    // Just this binary. `install` would rebuild every harness and the server
    // too, which is a slow way to start a debug session over one spec case.
    b.step("install-spec", "Install zig-out/bin/spec-runner for debugging")
        .dependOn(&b.addInstallArtifact(spec_exe, .{}).step);
    const run_spec = b.addRunArtifact(spec_exe);
    run_spec.setCwd(.{ .cwd_relative = b.build_root.path.? });
    if (b.args) |args| run_spec.addArgs(args);
    b.step("spec", "Run the conformance spec corpus").dependOn(&run_spec.step);

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
    const run_gen_ast_pb = b.addRunArtifact(gen_proto);
    run_gen_ast_pb.addFileArg(b.path("proto/googlesql.fdset"));
    run_gen_ast_pb.addArg(b.pathFromRoot("src/proto/resolved_ast.zig"));
    // addFileArg resolves to an absolute path, which would put this machine's
    // checkout directory in the generated header and fail gen-proto-drift on
    // every other machine. The header gets the repo-relative label instead.
    run_gen_ast_pb.addArg("--source=proto/googlesql.fdset");
    run_gen_ast_pb.has_side_effects = true;

    // The generator emits structurally correct Zig and leaves layout to `zig
    // fmt`, so the committed file stays canonical and future diffs stay small.
    const fmt_gen_proto = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
    fmt_gen_proto.addArg(b.pathFromRoot("src/proto/resolved_ast.zig"));
    fmt_gen_proto.has_side_effects = true;
    fmt_gen_proto.step.dependOn(&run_gen_ast_pb.step);

    // The same generator, second input: the BigQuery Storage Read API protos.
    //
    // A separate output file, not a second fdset folded into the one above.
    // The generator is self-hosting — `pb` is the previous run's output — so a
    // descriptor that produced non-compiling Zig would leave the engine's
    // decoders unbuildable and the generator unable to rebuild them. Keeping
    // the trees apart means a bad storage descriptor can only break the server.
    //
    // `--wire-import` because this output lands in the server module, which
    // cannot reach src/proto/wire.zig by relative path: a file imported that way
    // joins the importing module, and wire.zig already belongs to the engine's.
    const run_gen_storage_pb = b.addRunArtifact(gen_proto);
    run_gen_storage_pb.addFileArg(b.path("proto/bigquery_storage.fdset"));
    run_gen_storage_pb.addArg(b.pathFromRoot("src/server/proto/storage.zig"));
    run_gen_storage_pb.addArg("--source=proto/bigquery_storage.fdset");
    run_gen_storage_pb.addArg("--wire-import=@import(\"zigquery\").wire");
    run_gen_storage_pb.addArg(
        "--desc=Plain-struct codecs for the BigQuery Storage Read API protos.",
    );
    run_gen_storage_pb.has_side_effects = true;

    const fmt_gen_storage = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
    fmt_gen_storage.addArg(b.pathFromRoot("src/server/proto/storage.zig"));
    fmt_gen_storage.has_side_effects = true;
    fmt_gen_storage.step.dependOn(&run_gen_storage_pb.step);

    // The REST surface. JSON codecs only — these messages never reach the
    // binary wire — and pruned to what the implemented RPCs reference, which
    // leaves out the option definitions --include_imports drags along.
    const run_gen_bq_pb = b.addRunArtifact(gen_proto);
    run_gen_bq_pb.addFileArg(b.path("proto/bigquery_v2.fdset"));
    run_gen_bq_pb.addArg(b.pathFromRoot("src/server/proto/bigquery.zig"));
    run_gen_bq_pb.addArg("--source=proto/bigquery_v2.fdset");
    run_gen_bq_pb.addArg("--json-only");
    // Roots, not the whole .fdset: the closure is what the implemented RPCs
    // reference. `Job` is the expensive one — JobConfiguration covers load,
    // extract and copy jobs this emulator never runs — and takes the closure
    // from 40 messages to 166.
    run_gen_bq_pb.addArg("--roots=google.cloud.bigquery.v2.PostQueryRequest,google.cloud.bigquery.v2.QueryResponse,google.cloud.bigquery.v2.GetQueryResultsRequest,google.cloud.bigquery.v2.GetQueryResultsResponse,google.cloud.bigquery.v2.ErrorProto,google.cloud.bigquery.v2.InsertJobRequest,google.cloud.bigquery.v2.GetJobRequest,google.cloud.bigquery.v2.Job");
    run_gen_bq_pb.addArg(
        "--desc=Plain-struct JSON codecs for the BigQuery v2 REST surface.",
    );
    run_gen_bq_pb.has_side_effects = true;

    const fmt_gen_bq = b.addSystemCommand(&.{ b.graph.zig_exe, "fmt" });
    fmt_gen_bq.addArg(b.pathFromRoot("src/server/proto/bigquery.zig"));
    fmt_gen_bq.has_side_effects = true;
    fmt_gen_bq.step.dependOn(&run_gen_bq_pb.step);

    const gen_proto_step = b.step(
        "gen-proto",
        "Regenerate the generated protobuf codecs from the committed .fdsets",
    );
    gen_proto_step.dependOn(&fmt_gen_proto.step);
    gen_proto_step.dependOn(&fmt_gen_storage.step);
    gen_proto_step.dependOn(&fmt_gen_bq.step);

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
            .root_source_file = b.path("entrypoints/bench/analyzer_threads.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
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
            .root_source_file = b.path("entrypoints/bench/shared_catalog_threads.zig"),
            .target = target,
            .optimize = optimize,
            .sanitize_thread = tsan,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
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
            .root_source_file = b.path("entrypoints/bench/codec_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| codec_exe.step.dependOn(&bz.step);
    b.installArtifact(codec_exe);
    const run_codec = b.addRunArtifact(codec_exe);
    if (b.args) |args| run_codec.addArgs(args);
    b.step("codec-bench", "Value codec cost with real rows").dependOn(&run_codec.step);

    // Per-row cost of named-timezone resolution (zoneOffsetSeconds): the
    // ICU-tzdata A/B point against the fixed hand-rolled DST rules it replaced.
    const tzbench_exe = b.addExecutable(.{
        .name = "tz-bench",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/bench/tz_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| tzbench_exe.step.dependOn(&bz.step);
    b.installArtifact(tzbench_exe);
    const run_tzbench = b.addRunArtifact(tzbench_exe);
    if (b.args) |args| run_tzbench.addArgs(args);
    b.step("tz-bench", "Per-row cost of named-timezone resolution").dependOn(&run_tzbench.step);

    // Per-query cost vs catalog size: the baseline the server's caching work
    // has to beat.
    const bench_exe = b.addExecutable(.{
        .name = "bench-engine",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/bench/bench_engine.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
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
            .root_source_file = b.path("entrypoints/bench/gsql_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
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
            .root_source_file = b.path("entrypoints/bench/load_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "zigquery", .module = mod }},
        }),
    });
    if (maybe_bazel) |bz| loadbench_exe.step.dependOn(&bz.step);
    const run_loadbench = b.addRunArtifact(loadbench_exe);
    b.step("load-bench", "Benchmark bulk CREATE TABLE cost").dependOn(&run_loadbench.step);

    // ---- bigquery-emulator server ----
    //
    // A separate module from the engine so `test` and `corpus` — the engine's
    // regression gates — are unaffected by server work.
    const server_mod = serverModule(b, server_deps, optimize, mod);
    // Paired with static_mod the same way server_mod is paired with mod: a
    // server_exe importing one's engine and the other's server module would
    // give it two distinct-but-identical Db/Catalog types that fail to
    // compile wherever a value crosses the bqserver/zigquery boundary.
    const static_server_mod = serverModule(b, server_deps, optimize, static_mod);

    const server_exe = b.addExecutable(.{
        .name = "bigquery-emulator",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/server.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bqserver", .module = static_server_mod },
                .{ .name = "zigquery", .module = static_mod },
            },
        }),
    });
    if (maybe_bazel_static) |bz| server_exe.step.dependOn(&bz.step);
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
            .root_source_file = b.path("entrypoints/bench/insert_bench.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bqserver", .module = server_mod },
                .{ .name = "zigquery", .module = mod },
            },
        }),
    });
    if (maybe_bazel) |bz| insertbench_exe.step.dependOn(&bz.step);
    const run_insertbench = b.addRunArtifact(insertbench_exe);
    if (b.args) |args| run_insertbench.addArgs(args);
    b.step("insert-bench", "Profile a tabledata.insertAll request body")
        .dependOn(&run_insertbench.step);

    // Round-trips a real gRPC call against the Storage Read transport.
    //
    // Not in `test-server`, and not a benchmark: gRPC's shutdown checks abort
    // rather than fail, and a mis-driven completion queue hangs. Either would
    // take down the gate CI runs on every PR. Like analyzer-threads, it carries
    // positive controls and exits nonzero when they misbehave, so a broken
    // build cannot quietly pass it.
    const grpcsmoke_exe = b.addExecutable(.{
        .name = "grpc-smoke",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/bench/grpc_smoke.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bqserver", .module = server_mod },
                .{ .name = "zigquery", .module = mod },
            },
        }),
    });
    if (maybe_bazel) |bz| grpcsmoke_exe.step.dependOn(&bz.step);
    const run_grpcsmoke = b.addRunArtifact(grpcsmoke_exe);
    if (b.args) |args| run_grpcsmoke.addArgs(args);
    b.step("grpc-smoke", "Round-trip a gRPC call against the transport skeleton")
        .dependOn(&run_grpcsmoke.step);

    // Browsable UI over the spec corpus. The HTTP transport imports only std, so spec-ui links
    // neither gRPC nor nanoarrow.
    const http_server_mod = b.createModule(.{
        .root_source_file = b.path("src/server/http/server.zig"),
        .target = target,
        .optimize = optimize,
    });
    const spec_ui_exe = b.addExecutable(.{
        .name = "spec-ui",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/spec/spec_ui.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "http_server", .module = http_server_mod },
                .{ .name = "zigquery", .module = mod },
            },
        }),
    });
    if (maybe_bazel) |bz| spec_ui_exe.step.dependOn(&bz.step);
    b.installArtifact(spec_ui_exe);
    const run_spec_ui = b.addRunArtifact(spec_ui_exe);
    run_spec_ui.setCwd(.{ .cwd_relative = b.build_root.path.? }); // reads testdata/specs
    if (b.args) |args| run_spec_ui.addArgs(args);
    b.step("spec-ui", "Browse the spec corpus results in a local web UI")
        .dependOn(&run_spec_ui.step);

    // ---- dist ----
    //
    // `install` writes all ten artifacts to zig-out/bin, eight of which are
    // harnesses and benchmarks. A release is only the two products, each
    // statically linked against the shim (see static_mod/static_server_mod
    // above) — so a tarball of zig-out is exactly the shipped tree, with no
    // sibling `lib/` needed, and `bin/bigquery-emulator` runs from wherever
    // it is unpacked.
    const dist_step = b.step("dist", "Install just the release artifacts (bin/)");
    dist_step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    dist_step.dependOn(&b.addInstallArtifact(server_exe, .{}).step);

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
    const cov_mod = engineModule(b, deps, .Debug, false);
    const cov_server_mod = serverModule(b, server_deps, .Debug, cov_mod);
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

    // Coverage from the other direction. `coverage` measures what the unit
    // tests reach; this measures what replaying testdata/specs reaches, which
    // is a different and larger part of the engine — the transformer and the
    // UDFs are driven almost entirely by SQL, not by `test` blocks, and read
    // near 0% there.
    //
    // Kept as its own report rather than merged into `coverage`: a line the
    // spec corpus covers is asserted against a *published expected value*,
    // while a line a unit test covers is asserted against whatever that test
    // says. Averaging the two would hide which kind of evidence a given file
    // actually has. Pass `-- --filter zigquery/` to scope the replay.
    const cov_spec_exe = b.addExecutable(.{
        .name = "spec-runner-cov",
        .root_module = b.createModule(.{
            .root_source_file = b.path("entrypoints/spec/spec_runner.zig"),
            .target = target,
            .optimize = .Debug,
            .imports = &.{.{ .name = "zigquery", .module = cov_mod }},
        }),
    });
    if (maybe_bazel) |bz| cov_spec_exe.step.dependOn(&bz.step);

    const cov_spec_runs = b.pathJoin(&.{ cov_root, "spec-runs" });
    const cov_spec_report = b.pathJoin(&.{ cov_root, "spec-report" });
    const cov_spec_mkdir = b.addSystemCommand(&.{ "mkdir", "-p", cov_spec_runs, cov_spec_report });

    const kcov_spec = b.addSystemCommand(&.{ "kcov", "--clean", cov_include, cov_spec_runs });
    kcov_spec.addArtifactArg(cov_spec_exe);
    if (b.args) |args| kcov_spec.addArgs(args);
    // The runner resolves testdata/specs against the cwd, and kcov inherits it.
    kcov_spec.setCwd(.{ .cwd_relative = b.build_root.path.? });
    kcov_spec.has_side_effects = true;
    kcov_spec.step.dependOn(&cov_spec_mkdir.step);

    // One binary, so there is nothing to merge — but kcov's per-run directory
    // is named after the executable, and `--merge` is what produces a stable
    // top-level index.html to open.
    const kcov_spec_merge = b.addSystemCommand(&.{ "kcov", "--merge", cov_spec_report, cov_spec_runs });
    kcov_spec_merge.has_side_effects = true;
    kcov_spec_merge.step.dependOn(&kcov_spec.step);

    b.step(
        "coverage-spec",
        b.fmt("Line coverage for the spec corpus -> {s}/index.html", .{cov_spec_report}),
    ).dependOn(&kcov_spec_merge.step);

    // Ephor static analysis
    // A build tool: it runs here, so it follows the host and not `-Dtarget`.
    // Built for `target` it would be a foreign binary that addRunArtifact then
    // tries to execute.
    const ephor_dep = b.dependency("ephor", .{ .target = b.graph.host, .optimize = .ReleaseSafe });
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

    // Debuggable test binaries (ZigBrains: FalsePattern/ZigBrains#82).
    //
    // A debugger needs a path to attach to, and the binary behind `zig build
    // test` never leaves the cache under a name anyone can predict. Installing
    // it fixes that. The checked-in run configurations in `.run/` point here.
    //
    // These install the artifacts `test` and `test-server` already run rather
    // than declaring new ones: a second `addTest` over the same module would
    // compile the whole tree again, and you would be debugging a binary no CI
    // step ever ran. `dest_sub_path` names them, because `addTest` calls every
    // artifact "test" and both land in the same directory.
    //
    // Build these at Debug — which is already the default here, since
    // preferred_optimize_mode only picks *which* release mode `-Drelease=true`
    // selects. Under `-Drelease=true` a breakpoint on, say, the
    // `normal_func_names.has` line resolves into inlined StaticStringMap code
    // and the enclosing function's arguments are gone, so pass
    // `-Drelease=false` explicitly from anything that might inherit a
    // `--release` from elsewhere.
    const install_engine_tests = b.addInstallArtifact(unit_tests, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
        .dest_sub_path = "engine-tests",
    });
    const install_server_tests = b.addInstallArtifact(server_tests, .{
        .dest_dir = .{ .override = .{ .custom = "tests" } },
        .dest_sub_path = "server-tests",
    });
    const install_test_step = b.step(
        "install-test",
        "Install test binaries to zig-out/tests/ for debugging",
    );
    install_test_step.dependOn(&install_engine_tests.step);
    install_test_step.dependOn(&install_server_tests.step);
}

/// Everything the engine module needs beyond an optimize mode.
const EngineDeps = struct {
    target: std.Build.ResolvedTarget,
    build_options: *std.Build.Module,
    shim_dylib: []const u8,
    shim_dir: []const u8,
    /// `@loader_path`/`$ORIGIN`-relative rpath, so an installed binary finds
    /// the shim at ../lib once it leaves the build tree.
    shim_portable_rpath: []const u8,
    /// The statically-linkable shim object (see the option comment at its
    /// construction). Only read when `engineModule`'s `static_shim` is true.
    shim_static_obj: []const u8,
    /// Static libsqlite3, shared by every module (see the note at its
    /// construction: always ReleaseFast, even under -ODebug).
    sqlite: *std.Build.Step.Compile,
    /// The amalgamation directory, for `sqlite.zig`'s @cInclude.
    sqlite_headers: std.Build.LazyPath,
};

/// `static_shim` selects which of //shim's two build outputs this instance
/// links: false (every dev/test/harness consumer) keeps the dylib dynamic,
/// exactly as today; true (`exe`/`server_exe` only, see their construction)
/// links the relocatable object directly, so the shim's code lands in the
/// executable and no sibling `lib/` is needed at runtime.
fn engineModule(
    b: *std.Build,
    deps: EngineDeps,
    optimize: std.builtin.OptimizeMode,
    static_shim: bool,
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
    if (static_shim) {
        mod.addObjectFile(.{ .cwd_relative = deps.shim_static_obj });
        // The relocatable object's own undefined symbols: a raw object file
        // does not carry a "needed libraries" list the way linkLibrary's
        // Compile step does, so the shim's C++ runtime and (macOS) framework
        // dependencies have to be stated explicitly. Confirmed minimal and
        // complete by the Phase 0 spike in docs/M0_FINDINGS.md: libc++ and,
        // on macOS, CoreFoundation — nothing else, despite `otool -L` on the
        // dylib also listing Foundation/libobjc (dyld's automatic umbrella-
        // framework re-export at load time, not a real link requirement).
        mod.link_libcpp = true;
        if (deps.target.result.os.tag == .macos) {
            mod.linkFramework("CoreFoundation", .{});
        }
    } else {
        mod.addObjectFile(.{ .cwd_relative = deps.shim_dylib });
        // Two entries, tried in order: where bazel left it (dev), then next to
        // the installed binary (release tarball, container image).
        mod.addRPath(.{ .cwd_relative = deps.shim_dir });
        // addRPathSpecial, not addRPath: a LazyPath is normalized, which collapses
        // `@loader_path/..` to nothing and leaves a CWD-relative `lib` that only
        // resolves when the process happens to start in the right directory.
        mod.addRPathSpecial(deps.shim_portable_rpath);
    }
    return mod;
}

/// Everything the server module needs beyond an optimize mode and an engine.
const ServerDeps = struct {
    target: std.Build.ResolvedTarget,
    /// Static libnanoarrow, for the ARROW data format. Built once at
    /// ReleaseFast and shared with the coverage tree, like SQLite.
    nanoarrow: *std.Build.Step.Compile,
    /// Header roots for `arrow.zig`'s @cInclude.
    nanoarrow_headers: []const std.Build.LazyPath,
    /// gRPC core's translate-c bindings, for the Storage Read API transport.
    /// See the note at its construction: one instance, always ReleaseFast,
    /// shared with the coverage tree.
    cgrpc: *std.Build.Module,
};

fn serverModule(
    b: *std.Build,
    deps: ServerDeps,
    optimize: std.builtin.OptimizeMode,
    engine: *std.Build.Module,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/server/root.zig"),
        .target = deps.target,
        .optimize = optimize,
        .link_libc = true,
        // No link_libcpp and no linkFramework here: the cgrpc module links
        // libgrpc, whose root module sets link_libcpp, and Compile.make walks
        // linked artifacts recursively — so `-framework CoreFoundation -lc++`
        // reach the link line on their own. Setting them here would be a
        // second, drifting copy of a fact the dependency already states.
        .imports = &.{
            .{ .name = "zigquery", .module = engine },
            .{ .name = "cgrpc", .module = deps.cgrpc },
        },
    });
    for (deps.nanoarrow_headers) |h| mod.addIncludePath(h);
    mod.linkLibrary(deps.nanoarrow);
    return mod;
}
