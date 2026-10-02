# ⚡️ZigQuery - A BigQuery Emulator

<p style="text-align: center;">
  <strong>A BigQuery emulator server, built on <a href="https://ziglang.org">Zig</a>, <a href="https://github.com/google/googlesql">GoogleSQL</a>, and <a href="https://sqlite.org">SQLite</a>.</strong><br />
  Focused on query engine correctness, performance, throughput, and stability
</p>


<img type="image/svg+xml" src="./docs/bench/emubench.svg">

## Usage

```
docker pull ghcr.io/recidiviz/zigquery:latest
```

```
Usage:
  zigquery-server --project=<name> [OPTIONS]

A local BigQuery emulator serving the REST API and the Storage Read API.

Flags take the form --name=value.

Options:
  --project=<name>        project ID to serve (required)
  --dataset=<name>        create an empty dataset with this ID at startup
  --host=<addr>           address both servers bind (default: 0.0.0.0)
  --port=<port>           REST API port (default: 9050)
  --grpc-port=<port>      Storage Read API gRPC port; 0 picks a free port (default: 9060)
  --database=<path>       SQLite file to store data in; :memory: or empty keeps data in memory (default: :memory:)
  --data-from-json=<path> load datasets and tables from a JSON file at startup; repeatable, files load in order
  --log-level=<level>     accepted for compatibility; currently ignored
  --log-format=<format>   accepted for compatibility; currently ignored
  -h, --help              show this help and exit
```

## Development

[See docs/BUILD.md](./docs/BUILD.md) for environment setup and build commands.

## Why Zig?

[GoogleSQL](https://github.com/google/googlesql)'s query analyzer powers the core of the emulator.
It is written in C++ and requires a complex build system configured in Bazel.
Zig can link C natively, so interop becomes nearly free.

Intentional, explicit control over memory allocation improves process stability.

## CI & releases

| Workflow      | Trigger                     | What it does                                                                                                              |
|---------------|-----------------------------|---------------------------------------------------------------------------------------------------------------------------|
| `ci.yml`      | PR, push                    | ephor + `zig fmt`, unit tests, the spec corpus under `--strict`, the concurrency harnesses, and a `gen-proto` drift check |
| `bench.yml`   | push, `bench` label, manual | `gsql-bench --json` charted by github-action-benchmark on the `benchmarks` branch                                         |
| `release.yml` | `v*.*.*` tag                | four platform tarballs, a multi-arch GHCR image, and a GitHub release                                                     |

Runners are powered by [RunsOn](https://runs-on.com) on EC2 (see `.github/runs-on.yml`).
Release builds for darwin run on GitHub-hosted larger runners: arm64 and x64 built and smoke-tested
natively rather than cross-compiled.

## License

`zigquery` is licensed under the [Apache License 2.0](LICENSE); see [NOTICE](NOTICE).
Release binaries statically link third-party libraries whose licenses are collected
in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
`zigquery` is not affiliated with or endorsed by Google. BigQuery is a trademark of Google LLC.

# Addendum

The architecture comes from our work on the fork of [@goccy](https://github.com/goccy)'s original
implementation.
We are very grateful for his contributions to open source software.