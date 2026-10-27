#!/usr/bin/env bash
# Writes the googlesql shim's output names and content-addressed cache key to $GITHUB_OUTPUT.
# Shared by the shim build workflow and the restore-only shim action.
#
# The shim is the single most expensive thing in this repo to build and among
# the least frequently changed, so it is keyed on its actual inputs.
set -euo pipefail
platform="$1"

case "$platform" in
  darwin-*) lib=libgooglesql_shim.dylib
            static_target=libgooglesql_shim_static_macos ;;
  *)        lib=libgooglesql_shim.so
            static_target=libgooglesql_shim_static_linux ;;
esac
static_lib="$static_target.o"
if command -v sha256sum >/dev/null 2>&1; then sha() { sha256sum "$@"; }
else sha() { shasum -a 256 "$@"; }; fi

key=$( { git rev-parse "HEAD:third_party/googlesql"
         sha shim/analyzer_shim.cc shim/shim.lds shim/BUILD.bazel \
             shim/shim_exports_macos.list \
             MODULE.bazel MODULE.bazel.lock .bazelrc .bazelversion
         echo "$platform"
       } | sha | cut -c1-32 )

echo "lib=$lib"                                   >> "$GITHUB_OUTPUT"
echo "static_target=$static_target"               >> "$GITHUB_OUTPUT"
echo "static_lib=$static_lib"                     >> "$GITHUB_OUTPUT"
echo "path=dist/shim/$lib"                        >> "$GITHUB_OUTPUT"
echo "static-path=dist/shim/$static_lib"          >> "$GITHUB_OUTPUT"
echo "key=shim-$platform-$key"                    >> "$GITHUB_OUTPUT"
