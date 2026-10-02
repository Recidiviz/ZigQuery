#!/usr/bin/env python3
"""Generate THIRD_PARTY_NOTICES: the license text of everything shipped inside
the release binaries.

Both `zigquery-server` and `zigquery-cli` statically link the googlesql shim
(Bazel) and the Zig-built C/C++ dependencies, so every library below travels in
the binary, and most of their licenses (BSD, MIT, ICU) require the notice to be
reproduced alongside it. The shim tarball ships the same file.

    uv run tools/third_party_notices.py            # rewrite THIRD_PARTY_NOTICES
    uv run tools/third_party_notices.py --check    # exit 1 if it is stale

License files are read from the dependencies' own fetched sources, so both
trees must be present: Bazel's external repositories (`bazel build //shim:all`
or any shim build fetches them) and Zig's package directory (`zig build
--fetch`). The versions printed come from the same place, so a dependency bump
followed by a re-run is a reviewable diff.

The component list is maintained by hand from what actually links. For the
shim, that is the target-configuration cc_library set:

    bazel cquery 'kind("cc_library|cc_import", deps(//shim:libgooglesql_shim.dylib))'

filtered to non-exec configurations (`bazel config` names them). For Zig,
it is build.zig's own dependencies plus the gRPC package's. The run fails if
build.zig.zon or the gRPC package's build.zig.zon gains a dependency that is
neither listed here nor in NOT_SHIPPED, which catches the Zig side drifting;
the Bazel side has no such check and needs the cquery above re-run whenever
MODULE.bazel changes.

Not listed, because no notice is owed in a binary: SQLite (public domain),
Zig's bundled libc++/libc++abi/libunwind/compiler-rt (Apache-2.0 WITH
LLVM-exception, whose exception waives attribution for compiled forms), and
glibc on Linux (LGPL, dynamically linked from the host or image).
"""

import argparse
import glob
import os
import re
import subprocess
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
OUT = os.path.join(REPO, "THIRD_PARTY_NOTICES")

# The MIT license of the Go projects this engine was ported from.
# Not fetched by either build, so kept here verbatim
# (both repositories carry this same text; so do the Recidiviz forks the port started from).
GOCCY_MIT = """\
MIT License

Copyright (c) 2022 Masaaki Goshima

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
"""

# Source kinds:
#   ("text", str)                      inline license text
#   ("repo", relpath)                  a path in this repository
#   ("bazel", repo_name, relpath)      a Bazel external repository
#   ("zig", dep_name, relpath)         a dependency of build.zig.zon
#   ("grpc", dep_name, relpath)        a dependency of the gRPC package's zon
#
# `version` is either a literal, ("bazel_module", repo_name) to read the
# module() version the repository declares, ("http_archive", name) to read the
# download URL googlesql pins it at, or ("zig_url", zon, dep_name) for the URL
# a build.zig.zon pins.
COMPONENTS = [
    # Ported from; not linked, but the port is a derivative work.
    dict(
        name="go-zetasqlite",
        spdx="MIT",
        url="https://github.com/goccy/go-zetasqlite",
        version="ported from Recidiviz/go-zetasqlite",
        files=[("text", GOCCY_MIT)],
    ),
    dict(
        name="bigquery-emulator",
        spdx="MIT",
        url="https://github.com/goccy/bigquery-emulator",
        version="ported from Recidiviz/bigquery-emulator",
        files=[("text", GOCCY_MIT)],
    ),
    # The googlesql shim (Bazel).
    dict(
        name="GoogleSQL",
        spdx="Apache-2.0",
        url="https://github.com/google/googlesql",
        version=("submodule", "third_party/googlesql"),
        files=[("repo", "third_party/googlesql/LICENSE")],
    ),
    dict(
        name="Abseil (googlesql shim)",
        spdx="Apache-2.0",
        url="https://github.com/abseil/abseil-cpp",
        version=("bazel_module", "abseil-cpp"),
        files=[("bazel", "abseil-cpp", "LICENSE")],
    ),
    dict(
        name="Protocol Buffers",
        spdx="BSD-3-Clause",
        url="https://github.com/protocolbuffers/protobuf",
        version=("bazel_module", "protobuf"),
        files=[("bazel", "protobuf", "LICENSE")],
    ),
    dict(
        name="RE2 (googlesql shim)",
        spdx="BSD-3-Clause",
        url="https://github.com/google/re2",
        version=("bazel_module", "re2"),
        files=[("bazel", "re2", "LICENSE")],
    ),
    dict(
        name="ICU",
        spdx="Unicode-3.0",
        url="https://github.com/unicode-org/icu",
        version=("http_archive", "icu"),
        files=[("bazel", "googlesql_http_archive_deps~icu", "LICENSE")],
    ),
    dict(
        name="BoringSSL (googlesql shim)",
        spdx="Apache-2.0",
        url="https://github.com/google/boringssl",
        version=("bazel_module", "boringssl"),
        files=[("bazel", "boringssl", "LICENSE")],
    ),
    dict(
        name="Differential Privacy",
        spdx="Apache-2.0",
        url="https://github.com/google/differential-privacy",
        version=("http_archive", "com_google_differential_privacy"),
        files=[
            (
                "bazel",
                "googlesql_http_archive_deps~com_google_differential_privacy",
                "LICENSE",
            )
        ],
    ),
    dict(
        name="Cephes Math Library (via Differential Privacy)",
        spdx="BSD-3-Clause",
        url="https://github.com/google/differential-privacy/tree/main/third_party/cephes",
        version=("http_archive", "com_google_differential_privacy"),
        files=[
            (
                "bazel",
                "googlesql_http_archive_deps~com_google_differential_privacy",
                "third_party/cephes/LICENSE",
            )
        ],
    ),
    dict(
        name="nlohmann/json",
        spdx="MIT",
        url="https://github.com/nlohmann/json",
        version=("bazel_module", "nlohmann_json"),
        files=[("bazel", "nlohmann_json", "LICENSE.MIT")],
    ),
    dict(
        name="GoogleTest (googlesql shim)",
        spdx="BSD-3-Clause",
        url="https://github.com/google/googletest",
        version=("bazel_module", "googletest"),
        files=[("bazel", "googletest", "LICENSE")],
    ),
    dict(
        name="zlib (googlesql shim)",
        spdx="Zlib",
        url="https://github.com/madler/zlib",
        version=("bazel_module", "zlib"),
        files=[("bazel", "zlib", "LICENSE")],
    ),
    # The server and CLI (Zig).
    dict(
        name="Apache Arrow nanoarrow (includes flatcc)",
        spdx="Apache-2.0",
        url="https://github.com/apache/arrow-nanoarrow",
        version=("zig_url", "build.zig.zon", "nanoarrow"),
        files=[("zig", "nanoarrow", "LICENSE.txt"), ("zig", "nanoarrow", "NOTICE.txt")],
    ),
    dict(
        name="gRPC (includes upb)",
        spdx="Apache-2.0 AND BSD-3-Clause AND MPL-2.0",
        url="https://github.com/grpc/grpc",
        version=("zig_url", "grpc", "upstream"),
        files=[("grpc", "upstream", "LICENSE"), ("grpc", "upstream", "NOTICE.txt")],
    ),
    dict(
        name="utf8_range (via gRPC)",
        spdx="MIT",
        url="https://github.com/protocolbuffers/utf8_range",
        version=("zig_url", "grpc", "upstream"),
        files=[("grpc", "upstream", "third_party/utf8_range/LICENSE")],
    ),
    dict(
        name="xxHash (via gRPC)",
        spdx="BSD-2-Clause",
        url="https://github.com/Cyan4973/xxHash",
        version=("zig_url", "grpc", "upstream"),
        files=[("grpc", "upstream", "third_party/xxhash/LICENSE")],
    ),
    dict(
        name="address_sorting (via gRPC)",
        spdx="BSD-3-Clause",
        url="https://github.com/grpc/grpc/tree/master/third_party/address_sorting",
        version=("zig_url", "grpc", "upstream"),
        files=[("grpc", "upstream", "third_party/address_sorting/LICENSE")],
    ),
    dict(
        name="Abseil (gRPC)",
        spdx="Apache-2.0",
        url="https://github.com/abseil/abseil-cpp",
        version=("zig_url", "grpc", "abseil"),
        files=[("grpc", "abseil", "LICENSE")],
    ),
    dict(
        name="RE2 (gRPC)",
        spdx="BSD-3-Clause",
        url="https://github.com/google/re2",
        version=("zig_url", "grpc", "re2"),
        files=[("grpc", "re2", "LICENSE")],
    ),
    dict(
        name="BoringSSL (gRPC)",
        spdx="Apache-2.0",
        url="https://github.com/google/boringssl",
        version=("zig_url", "grpc", "boringssl"),
        files=[("grpc", "boringssl", "LICENSE")],
    ),
    dict(
        name="c-ares",
        spdx="MIT",
        url="https://github.com/c-ares/c-ares",
        version=("zig_url", "grpc", "cares"),
        files=[("grpc", "cares", "LICENSE.md")],
    ),
    dict(
        name="zlib (gRPC)",
        spdx="Zlib",
        url="https://github.com/madler/zlib",
        version=("zig_url", "grpc", "zlib"),
        files=[("grpc", "zlib", "LICENSE")],
    ),
]

# Dependencies declared in a build.zig.zon that do not end up in a release
# binary, so owe no notice there.
NOT_SHIPPED = {
    ("build.zig.zon", "sqlite"): "public domain",
    ("grpc", "gtest"): "linked only into gRPC's own tests",
}


def die(msg):
    sys.exit(f"third_party_notices: {msg}")


def zon_deps(path):
    """name -> (url, hash) for each entry of a build.zig.zon's .dependencies."""
    with open(path) as f:
        text = f.read()
    deps = {}
    for m in re.finditer(
        r"\.(\w+)\s*=\s*\.\{\s*\.url\s*=\s*\"([^\"]+)\",\s*\.hash\s*=\s*\"([^\"]+)\"",
        text,
    ):
        deps[m.group(1)] = (m.group(2), m.group(3))
    return deps


def zig_pkg_dir(hash_):
    for base in (os.path.join(REPO, "zig-pkg"), os.path.expanduser("~/.cache/zig/p")):
        d = os.path.join(base, hash_)
        if os.path.isdir(d):
            return d
    die(f"Zig package {hash_} not fetched; run `zig build --fetch`")


class Sources:
    def __init__(self):
        self.root_zon = zon_deps(os.path.join(REPO, "build.zig.zon"))
        self.grpc_dir = zig_pkg_dir(self.root_zon["grpc"][1])
        self.grpc_zon = zon_deps(os.path.join(self.grpc_dir, "build.zig.zon"))
        self._external = None

    @property
    def external(self):
        if self._external is None:
            out = subprocess.run(
                ["bazel", "info", "output_base"],
                cwd=REPO,
                capture_output=True,
                text=True,
                check=False,
            )
            if out.returncode != 0:
                die("`bazel info output_base` failed:\n" + out.stderr)
            self._external = os.path.join(out.stdout.strip(), "external")
        return self._external

    def bazel_repo(self, name):
        # Canonical names are `<name>~` under Bazel 7 and `<name>+` under 8;
        # extension repositories are prefixed with their extension's owner.
        for pattern in (f"{name}~", f"{name}+", f"*~{name}", f"*+{name}"):
            hits = sorted(glob.glob(os.path.join(self.external, pattern)))
            if hits:
                return hits[0]
        die(f"Bazel repository {name} not fetched; build //shim first")

    def zon(self, which):
        return self.root_zon if which in ("zig", "build.zig.zon") else self.grpc_zon

    def read(self, src):
        kind = src[0]
        if kind == "text":
            return src[1]
        if kind == "repo":
            path = os.path.join(REPO, src[1])
        elif kind == "bazel":
            path = os.path.join(self.bazel_repo(src[1]), src[2])
        else:
            path = os.path.join(zig_pkg_dir(self.zon(kind)[src[1]][1]), src[2])
        if not os.path.isfile(path):
            die(f"missing license file {path}")
        with open(path, encoding="utf-8") as f:
            return f.read()

    def version(self, v):
        if isinstance(v, str):
            return v
        kind = v[0]
        if kind == "submodule":
            sha = subprocess.run(
                ["git", "rev-parse", f"HEAD:{v[1]}"],
                cwd=REPO,
                capture_output=True,
                text=True,
                check=False,
            ).stdout.strip()
            return f"commit {sha}"
        if kind == "bazel_module":
            with open(os.path.join(self.bazel_repo(v[1]), "MODULE.bazel")) as f:
                m = re.search(
                    r"module\([^)]*?version\s*=\s*\"([^\"]+)\"", f.read(), re.DOTALL
                )
            if not m:
                die(f"no module() version in {v[1]}")
            return m.group(1)
        if kind == "http_archive":
            with open(
                os.path.join(REPO, "third_party/googlesql/bazel/http_archive_deps.bzl")
            ) as f:
                text = f.read()
            m = re.search(
                rf"name\s*=\s*\"{v[1]}\".*?urls?\s*=\s*\[?\s*\"([^\"]+)\"",
                text,
                re.DOTALL,
            )
            if not m:
                die(f"no http_archive url for {v[1]}")
            return m.group(1)
        if kind == "zig_url":
            return self.zon(v[1])[v[2]][0]
        die(f"unknown version kind {kind}")


def check_coverage(src):
    listed = set()
    for c in COMPONENTS:
        for f in c["files"]:
            if f[0] in ("zig", "grpc"):
                listed.add(("build.zig.zon" if f[0] == "zig" else "grpc", f[1]))
    # grpc itself is covered by its `upstream` source.
    listed.add(("build.zig.zon", "grpc"))
    missing = []
    for zon_name, deps in (("build.zig.zon", src.root_zon), ("grpc", src.grpc_zon)):
        for dep in deps:
            key = (zon_name, dep)
            if key not in listed and key not in NOT_SHIPPED:
                missing.append(f"{zon_name}: .{dep}")
    if missing:
        die(
            "dependencies with no notice entry (add to COMPONENTS or NOT_SHIPPED):\n  "
            + "\n  ".join(missing)
        )


def render(src):
    rule = "=" * 79
    out = [
        "THIRD-PARTY SOFTWARE NOTICES",
        "",
        "zigquery-server and zigquery-cli include the software listed below, compiled",
        "and statically linked, or are derived from it. Each component's license",
        "follows in full. Generated by tools/third_party_notices.py; do not edit.",
        "",
    ]
    for c in COMPONENTS:
        out.append(f"  - {c['name']} ({c['spdx']})")
    out.append("")
    for c in COMPONENTS:
        out += [
            rule,
            c["name"],
            f"  {c['url']}",
            f"  {src.version(c['version'])}",
            f"  License: {c['spdx']}",
            rule,
            "",
        ]
        for f in c["files"]:
            out.append(src.read(f).rstrip().expandtabs(8))
            out.append("")
    return "\n".join(line.rstrip() for line in "\n".join(out).split("\n")) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument(
        "--check", action="store_true", help="fail if THIRD_PARTY_NOTICES is stale"
    )
    args = ap.parse_args()

    src = Sources()
    check_coverage(src)
    text = render(src)

    if args.check:
        with open(OUT, encoding="utf-8") as f:
            if f.read() != text:
                die(
                    "THIRD_PARTY_NOTICES is stale; run `uv run tools/third_party_notices.py`"
                )
        return
    with open(OUT, "w", encoding="utf-8") as f:
        f.write(text)
    print(f"wrote {os.path.relpath(OUT, REPO)} ({len(COMPONENTS)} components)")


if __name__ == "__main__":
    main()
