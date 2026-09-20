# syntax=docker/dockerfile:1
#
# Nothing is compiled here. The binaries are built in the release workflow on
# a native runner per architecture and dropped into dist/, so the multi-arch
# image needs no QEMU — which matters a great deal when the alternative is
# emulating a full C++ analyzer build.
#
# The googlesql shim is statically linked into bigquery-emulator (see
# static_mod/static_server_mod in build.zig), so there is no dist/lib/ to
# copy and no shim-specific rpath to keep in step. distroless/cc-debian13 is
# still the base rather than a slimmer distroless/static: unconfirmed on
# Linux whether Zig's link_libcpp there statically links Zig's own bundled
# libc++, as it does on the macOS build this migration verified directly, or
# whether the static object still pulls in the system libstdc++ the way the
# old dylib genuinely did (glibc 2.38 / GLIBCXX 3.4.31 floor, unchanged from
# before this migration if so) — worth checking once a Linux build exists to
# inspect, not assumed here.
#
# Expected context layout, matching `zig build dist -Dshim-static-obj=...`
# (see release.yml):
#   dist/bin/{bigquery-emulator,zigquery}
FROM gcr.io/distroless/cc-debian13:nonroot

COPY dist/bin/ /usr/local/bin/

# REST and the (flag-only, not yet served) gRPC port, matching the Go
# emulator's defaults so existing fixtures need no changes.
EXPOSE 9050 9060

ENTRYPOINT ["/usr/local/bin/zigquery-server"]
