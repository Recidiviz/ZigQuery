# syntax=docker/dockerfile:1
#
# Nothing is compiled here. The binaries and the googlesql shim are built in
# the release workflow on a native runner per architecture and dropped into
# dist/, so the multi-arch image needs no QEMU — which matters a great deal
# when the alternative is emulating a full C++ analyzer build.
#
# distroless/cc supplies glibc and libstdc++. The shim is additionally linked
# with -static-libstdc++/-static-libgcc (see shim/BUILD.bazel), so the only
# real runtime dependency is glibc.
#
# Expected context layout, matching `zig build dist`:
#   dist/bin/{bigquery-emulator,zetasqlite-zig}
#   dist/lib/libgooglesql_shim.so
FROM gcr.io/distroless/cc-debian12:nonroot

# The binaries carry an rpath of $ORIGIN/../lib, so /usr/local/bin/../lib is
# where the shim has to land. Keep these two paths in step.
COPY dist/lib/ /usr/local/lib/
COPY dist/bin/ /usr/local/bin/

# REST and the (flag-only, not yet served) gRPC port, matching the Go
# emulator's defaults so existing fixtures need no changes.
EXPOSE 9050 9060

ENTRYPOINT ["/usr/local/bin/bigquery-emulator"]
