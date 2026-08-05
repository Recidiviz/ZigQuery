# syntax=docker/dockerfile:1
#
# Nothing is compiled here. The binaries and the googlesql shim are built in
# the release workflow on a native runner per architecture and dropped into
# dist/, so the multi-arch image needs no QEMU — which matters a great deal
# when the alternative is emulating a full C++ analyzer build.
#
# distroless/cc supplies glibc and libstdc++, and the shim needs both. The
# -static-libstdc++ in shim/BUILD.bazel does NOT take effect under Bazel's C++
# toolchain, which appends its own -lstdc++ to the link line, so libstdc++ is
# a genuine runtime dependency however that flag reads.
#
# debian13, not debian12. A shared library records the symbol versions it was
# built against, so the runtime's glibc/libstdc++ must be at least as new as
# the builder's. The shim is built on RunsOn's ubuntu24-full (glibc 2.39,
# GCC 13 -> GLIBCXX_3.4.32) and needs GLIBC_2.38 / GLIBCXX_3.4.31; debian12
# tops out at 2.36 / 3.4.30 and fails at exec with "version not found", while
# debian13 provides 2.41 / 3.4.33.
#
# That is an invariant, not a one-off: if the builder image ever moves to a
# newer glibc than this base, the image breaks again the same way.
#
# Expected context layout, matching `zig build dist`:
#   dist/bin/{bigquery-emulator,zetasqlite-zig}
#   dist/lib/libgooglesql_shim.so
FROM gcr.io/distroless/cc-debian13:nonroot

# The binaries carry an rpath of $ORIGIN/../lib, so /usr/local/bin/../lib is
# where the shim has to land. Keep these two paths in step.
COPY dist/lib/ /usr/local/lib/
COPY dist/bin/ /usr/local/bin/

# REST and the (flag-only, not yet served) gRPC port, matching the Go
# emulator's defaults so existing fixtures need no changes.
EXPOSE 9050 9060

ENTRYPOINT ["/usr/local/bin/bigquery-emulator"]
