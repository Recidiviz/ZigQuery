# Plan — a ZON spec runner for the REST surface

The REST surface is pinned in two places, and neither is data:

- 66 `test` blocks at the bottom of `src/server/server.zig` — lines 1484–3529, about 2,050 of
  the file's 3,529 — each building a `Server`, driving `s.handler().func` without a socket, and
  asserting on status, body bytes, substrings, or cells.
- `testdata/golden.json`, 23 responses captured from the Go emulator by
  `tools/capture_golden.py`. Nothing replays it. Twelve source comments cite it by case name
  (`error.zig`, `handler/query.zig`, `types/response.zig`, `types/schema.zig`,
  `types/govalue.zig`); it was last compared over the wire in M0, when it held 17 cases.

This plan moves both into ZON specs under `testdata/rest/`, replayed by a new
`zig build spec-rest`, the way `zig build spec` replays `testdata/specs/`. It is written to be
executed one commit at a time, with `zig build test-server` and `zig build spec-rest` green at
every stage.

---

## 0. Can the suite be ZON? Yes — prototyped

A throwaway loader (not committed) parsed spec files holding six of the server tests on
Zig 0.16.0 and rendered their payloads back to JSON. What it established:

- **The envelope can be typed.** `std.zon.parse` returns a field typed
  `std.zig.Zoir.Node.Index` untouched (`zon/parse.zig`, `parseExprInner`:
  `if (T == Zoir.Node.Index) return node;`). So file, case, step and expectation are plain Zig
  structs parsed by the standard library, and only the JSON payloads are walked by hand.
- **Typed means strict.** An unknown field is a load error with a location, where
  `spec_run.zig`'s `field()` lookups skip a misspelled key without a word:

  ```
  17:26: error: unexpected field 'stauts'
  17:26: note: supported: 'status', 'body', 'json', 'json_subset', 'contains', ...
  ```

  `.status = .conflcit` fails the same way against `std.http.Status`'s tags.
- **ZON payloads render to the tests' exact bytes.** Struct literals keep source order, so
  `.{ .datasetReference = .{ .projectId = "test", .datasetId = "ds1" } }` renders
  `{"datasetReference":{"projectId":"test","datasetId":"ds1"}}`, byte-identical to the literal in
  `inserting a declared dataset is 409 and leaves it as it was`; so does that test's whole 409
  error envelope. The one key that is a Zig keyword, `error`, is written `.@"error"`.
- **`[]` has no ZON spelling.** `.{}` is both the empty struct and the empty tuple, and
  `.rows = .{}` renders `{"rows":{}}`. §2 settles it: a request that needs `[]` uses `.body`,
  and in an expectation `.{}` matches either.
- **Floats lose their text.** Zoir keeps an int's value but a float only as `f128`, while
  `json_pb.compare` compares numbers as source text. REST renders every float and every INT64 as
  a string, so the loader rejects float literals in payloads instead of guessing a spelling.

One ownership rule the implementation must keep: `fromZoirAlloc` stores `ast` and `zoir` into the
`Diagnostics` it is handed, and `Diagnostics.deinit` frees both. The parsed `Node.Index` fields
point into that `zoir`, so the `Diagnostics` lives as long as the file's cases run.

---

## 1. Where things go

| piece | path | reason |
|---|---|---|
| specs | `testdata/rest/**/*.zon` | beside `testdata/specs/`, not in it: `spec_run.loadManifest` exits on a top-level directory other than googlesql/bigquery/zigquery, and `vsbq.py`, `spec_ui` and `spec_import.py` all treat that tree as SQL |
| core | `src/server/rest_spec.zig`, exported from `src/server/root.zig` | needs `Server`; its loader and matcher tests run under `test-server`; `spec_ui` can call it later as it calls `spec_run` |
| CLI | `entrypoints/spec/rest_spec_runner.zig` | the `spec_runner.zig` / `spec_run.zig` split |
| build | `zig build spec-rest`, `zig build install-spec-rest` | imports `bqserver` (`server_mod`) and `zigquery` (`mod`), as `insert-bench` does |
| JSON comparison | `src/server/json_pb.zig` | `compare` is private, reachable only through `expectJsonEqual`, which is hard-wired to `std.testing.allocator`; expose it with an allocator and put the subset matcher beside it, so "same JSON" has one definition |

Spec files by resource, following `handler/*.zig`:

```
testdata/rest/
  routing.zon                 unknown path, the /bigquery/v2 prefix, malformed bodies
  jobs/query.zon              jobs.query: parameters, errors, state across requests
  jobs/insert.zon             jobs.insert: destination tables, WRITE_APPEND/WRITE_TRUNCATE, DDL
  jobs/get_query_results.zon  paging, pageToken, formatOptions, the maxResults=0 probe
  jobs/get.zon                jobs.get and jobs.list, which no server test requests today
  datasets.zon
  tables.zon                  insert/get/list/patch/delete, views, nested modes
  tabledata/insert_all.zon
  go_golden.zon               the 23 golden.json captures
```

---

## 2. Format

Every ZON snippet below loaded through the prototype.

```zig
.{
    .spec = "rest/tabledata/insert_all",
    .server = .{ .project = "test", .dataset = "ds1" },
    // The shape google-cloud-bigquery creates before it streams into a table.
    .setup = .{
        .{
            .POST = "/projects/test/datasets/ds1/tables",
            .json = .{
                .tableReference = .{ .projectId = "test", .datasetId = "ds1", .tableId = "stream" },
                .schema = .{ .fields = .{
                    .{ .name = "name", .type = "STRING" },
                    .{ .name = "age", .type = "INTEGER" },
                } },
            },
        },
    },
    .cases = .{
        .{
            .desc = "insertAll writes rows that a later query can read",
            .steps = .{
                // `age` arrives as a JSON string, as insert_rows sends an INTEGER column.
                .{
                    .POST = "/projects/test/datasets/ds1/tables/stream/insertAll",
                    .json = .{ .rows = .{
                        .{ .insertId = "a", .json = .{ .name = "Alice", .age = "30" } },
                        .{ .insertId = "b", .json = .{ .name = "Bob", .age = "25" } },
                    } },
                    .expect = .{ .body = "{}" },
                },
                .{
                    .POST = "/projects/test/queries",
                    .json = .{ .query = "SELECT name FROM `test.ds1.stream` WHERE age > 27" },
                    .expect = .{ .rows = .{.{"Alice"}} },
                },
            },
        },
        .{
            .desc = "insertAll with an empty rows array is a no-op",
            .steps = .{
                .{
                    .POST = "/projects/test/datasets/ds1/tables/stream/insertAll",
                    .body = "{\"rows\":[]}",
                    .expect = .{ .body = "{}" },
                },
            },
        },
    },
}
```

A capture, and a loop unrolled into steps (the `maxResults` paging test):

```zig
.{
    .desc = "maxResults pages through a result, and the token resumes it",
    .server = .{ .project = "test" },
    .steps = .{
        .{
            .POST = "/projects/test/jobs",
            .json = .{ .configuration = .{ .query = .{
                .query = "SELECT n FROM UNNEST([1,2,3,4,5]) AS n ORDER BY n",
                .useLegacySql = false,
            } } },
            .capture = .{ .job = "jobReference.jobId" },
        },
        .{
            .GET = "/projects/test/queries/${job}?maxResults=2&pageToken=0",
            .expect = .{ .rows = .{ .{"1"}, .{"2"} }, .json_subset = .{ .pageToken = "2" } },
        },
        .{
            .GET = "/projects/test/queries/${job}?maxResults=2&pageToken=2",
            .expect = .{ .rows = .{ .{"3"}, .{"4"} }, .json_subset = .{ .pageToken = "4" } },
        },
        // The short last page carries no token, which is how the client knows to stop.
        .{
            .GET = "/projects/test/queries/${job}?maxResults=2&pageToken=4",
            .expect = .{ .rows = .{.{"5"}}, .excludes = .{"\"pageToken\""} },
        },
        .{
            .GET = "/projects/test/queries/${job}?pageToken=99",
            .expect = .{ .json_subset = .{ .rows = .{} }, .excludes = .{"\"pageToken\""} },
        },
    },
},
```

The token values `"2"` and `"4"` assume a token is a row offset, as the probe's `"pageToken":"0"`
suggests; confirm when porting. Pinning them makes the case stronger than the loop it replaces,
which checked only the concatenated rows and the page count.

A restart (`declared datasets survive a restart on a file-backed database`):

```zig
.{
    .desc = "declared datasets survive a restart on a file-backed database",
    .server = .{ .project = "test", .dataset = "ds1", .database = .temp },
    .steps = .{
        .{ .PATCH = "/projects/test/datasets/ds1", .json = .{ .description = "kept" }, .name = "patched" },
        .{ .restart = true },
        .{ .GET = "/projects/test/datasets/ds1", .expect = .{ .same_as = "patched" } },
    },
},
```

### Chaining requests

A case is one `Server`, so every step sees what the steps before it did. A value one response
mints and a later request needs, such as a job id, travels by name: `.capture` binds it and
`${name}` spends it.

```zig
.{
    .desc = "jobs.get answers with the resource jobs.insert returned",
    .steps = .{
        .{
            .POST = "/projects/test/jobs",
            .json = .{ .configuration = .{ .query = .{
                .query = "SELECT 1 AS n",
                .useLegacySql = false,
            } } },
            .name = "inserted",
            .capture = .{ .job = "jobReference.jobId" },
            .expect = .{ .json_subset = .{
                .selfLink = "http://0.0.0.0:9050/bigquery/v2/projects/test/jobs/${job}",
                .configuration = .{ .query = .{ .destinationTable = .{
                    .projectId = "test",
                    .datasetId = "_anon",
                    .tableId = "${job}",
                } } },
                .status = .{ .state = "DONE" },
            } },
        },
        // Stored and served back unchanged, wall-clock statistics included.
        .{ .GET = "/projects/test/jobs/${job}", .expect = .{ .same_as = "inserted" } },
        .{ .GET = "/projects/test/queries/${job}", .expect = .{ .rows = .{.{"1"}} } },
        .{
            .POST = "/projects/test/queries",
            .json = .{ .query = "SELECT n FROM `test._anon.${job}`" },
            .expect = .{ .rows = .{.{"1"}} },
        },
    },
},
```

The flow was run against a built emulator (the 2026-09-11 binary) before it was written down:
jobs.get's body was byte-identical to jobs.insert's, getQueryResults and the `_anon` read each
returned `[["1"]]`, and `/projects/test/jobs/nosuchjob` answered the 404 envelope
`job nosuchjob is not found`.

- A step runs as: interpolate its request, dispatch, bind its captures, check its expectations.
  Binding comes before checking, so the step that mints an id can already assert
  `.tableId = "${job}"`.
- A capture is a dotted path to a string leaf. One `.capture` may bind several names. A path
  that is absent or not a string fails the step, prints the body, and ends the case.
- Names are case-local. Captures made in file `.setup` are visible to every case, since setup
  runs inside each case's server.
- `${name}` expands in the target (path and query string), `.body`, string leaves of `.json`, and
  every expected string. It does not expand in `.name` or `.same_as`, which name steps.
- The job resource carries wall-clock `creationTime`/`startTime`/`endTime`, so no literal body
  can match it. `.same_as` makes the exact claim against the earlier response; `.json_subset`
  makes the claims that can be written down. `selfLink` can be, because the runner's server is
  built with `Options`' default host and port.

jobs.get ignores its project segment (`_ = project_id;` in `handleJobsGet`): the same binary
answered `/projects/other/jobs/<id>` with 200. BigQuery scopes a job id to its project; probe it
before a case pins a 404 there.

### The typed envelope

```zig
const ServerOptions = struct {
    project: []const u8 = "test",
    dataset: ?[]const u8 = null,
    /// A runner-owned file under .zig-cache/tmp, removed after the case. No arbitrary paths.
    database: ?enum { temp } = null,
};

const Step = struct {
    // Exactly one; `?` splits the path from the query string, as the transport does.
    GET: ?[]const u8 = null,
    POST: ?[]const u8 = null,
    PATCH: ?[]const u8 = null,
    DELETE: ?[]const u8 = null,
    json: ?Zoir.Node.Index = null, // request body from ZON
    body: ?[]const u8 = null, // request body verbatim
    name: ?[]const u8 = null, // makes the response referable by `.same_as`
    capture: ?Zoir.Node.Index = null, // .{ .var = "dotted.path" }
    restart: bool = false,
    expect: Expect = .{},
};

const Expect = struct {
    status: std.http.Status = .ok,
    body: ?[]const u8 = null,
    json: ?Zoir.Node.Index = null,
    json_subset: ?Zoir.Node.Index = null,
    rows: ?Zoir.Node.Index = null,
    contains: []const []const u8 = &.{},
    excludes: []const []const u8 = &.{},
    same_as: ?[]const u8 = null,
};

const Case = struct {
    desc: []const u8,
    server: ?ServerOptions = null, // replaces the file's, whole
    steps: []const Step,
    skip: ?[]const u8 = null,
    diverges_from_go: ?[]const u8 = null, // go_golden.zon only
};

const SpecFile = struct {
    spec: []const u8,
    server: ServerOptions = .{},
    setup: []const Step = &.{},
    cases: []const Case,
};
```

### Semantics

- Each case gets a fresh `Server.init`, the isolation today's tests have. File `.setup` runs at the
  start of every case.
- Steps run in order. The first unmet expectation ends the case and is reported with the step's
  index, its request line, and both sides.
- `.expect` defaults to `.{ .status = .ok }`, so setup-shaped steps (today's
  `_ = try request(...)`) are checked too. A broken setup fails where it breaks.
- `.capture` and `${name}` are described under *Chaining requests*.
- `.json`/`.json_subset` on the expect side also accept a string, parsed as JSON text before the
  comparison. It is the escape hatch for `[]` and for the nested REST row shape, which is
  shorter as `"[{\"f\":[{\"v\":{\"f\":[{\"v\":\"1768003200.0\"}]}}]}]"` than as ZON.

| expectation | checks |
|---|---|
| `.status` | a `std.http.Status` tag; default `.ok` |
| `.body` | the bytes, exactly |
| `.json` | the whole body, structurally: key order free, numbers by text (`json_pb.compare`) |
| `.json_subset` | only the keys named, recursively; arrays element-wise at equal length, so a subset pins list order |
| `.rows` | `rows[i].f[j].v` as strings and nulls |
| `.contains`, `.excludes` | substrings: error text, and absence |
| `.same_as` | the body of an earlier step with that `.name`, exactly |

The runner's doc comment states the one obvious way: `.json_subset` for anything with structure,
`.contains` for message text, `.body` only where the bytes are the claim (goldens, `{}`, error
envelopes).

Rejected at load, as a `(load)` failure carrying line:col: unknown fields and enum tags (by
`std.zon.parse`); no method field or two; `.json` together with `.body`; a float, char or enum
literal inside a payload; `.same_as` naming no earlier step; a `${name}` that no earlier step or
`.setup` captures; a name captured twice in one case; `.restart` without `.database = .temp`; a
`desc` repeated within a file. Captures are declared, so a misspelled `${jbo}` is caught at its
line and column before anything runs.

---

## 3. What ports, and what replaces what does not

All 66 tests, sorted by what they need:

| tests | what they need | becomes |
|---|---|---|
| 54 | requests, then status/body/substring/cell assertions | cases, one for one |
| 4 | a Zig loop: the paging `while`, `useInt64Timestamp`'s three shapes, the `b_ds`/`a_ds` and `gone`/`gone_view` pairs | unrolled steps; the three shapes become three cases |
| 4 | a read of `_anon.<job>` through `s.db.query` | a `jobs.query` step on `test._anon.${job}`, with `.rows` |
| 1 | two `Server` lifetimes on one file | a `.restart` step; the `zigquery_catalog` assertion stays in Zig |
| 2 | a last assertion on engine state (no `test__anon_%` catalog rows after the refused patch; `db.default_project` back to `test`) | the HTTP steps port; each engine assertion stays as a small Zig test |
| 1 | `rawExec("DROP TABLE ...")` to build the broken state | stays in Zig whole |

About the `_anon` row: `server.zig:1239` makes a finished job's result readable as
`<project>._anon.<job_id>`, and `jobs.query` runs the same `db.query` the tests call. A
`jobs.query` on `test._anon.<id>` returned the job's rows on the 2026-09-11 binary (see
*Chaining requests*). On the branch tip, the undeclared-dataset check (`Db.requireDataset`) runs
only when creating a table, view or function, and skips `_anon` by name, so reads are unaffected.
`two jobs' destination tables do not collide` also asserts the ids differ; reading 1 through
`${a}` and 2 through `${b}` already proves it.

End state: about 67 cases in ZON; `server.zig` keeps four small tests and the `request` helper
they use, and drops `requestQuery`, `jobIdOf`, `onlyCell`, `cellsOf`, `pageTokenOf` and
`createStreamTable`.

---

## 4. The goldens

- `go_golden.zon` holds the 23 captures as `.body` expectations, byte-exact. `capture_golden.py`
  re-serialized each response (`json.loads`, then `json.dump(indent=2)`), but compacting them
  gives back Go's bytes: Python keeps key order, and none of the 23 bodies holds a character Go's
  encoder escapes (`<`, `>`, `&`, U+2028, U+2029). `<JOBID>` becomes `${job}`, captured by the
  step that returns it.
- `capture_golden.py` writes `go_golden.zon` itself through `tools/zon.py`, keeping raw response
  bytes rather than re-serializing them. `golden.json` goes, and the twelve comments that cite
  `testdata/golden.json: <case>` cite `go_golden.zon` by the same name.
- The first run is the first replay since M0. Each difference is either a bug, or a place this
  server answers as BigQuery does rather than as Go does; the latter keeps today's answer as its
  expectation and records the Go capture's difference in `.diverges_from_go` — provenance on
  the expectation, per `.claude/rules/code-style.md`.

---

## 5. CLI and report

```
zig build spec-rest -- [--filter PATH] [--case DESC] [--verbose] [--routes]
```

- A PASS/FAIL/SKIP count, then each failure:
  `rest/tables  tables.patch refuses to change a schema, as Go does  step 2 (PATCH
  /projects/test/datasets/ds1/tables/fixed): status: want 400 bad_request, got 200 ok`, and the
  body.
- `--verbose` prints every step's response.
- `--routes` lists the routes no case reached. The runner sums `Server.route_stats[id].count`
  before each `deinit`, so this is free. Today it would name `jobs.get`, `jobs.list`,
  `discovery` and `debug_stats`: no server test requests any of them.
- Exit status 1 on any failure. No baseline file: every case starts as a passing test, so any
  failure is a regression. The SQL corpus needs `spec_baseline.txt` because it imports cases this
  engine has never passed; this suite has none.

---

## 6. Stages

Each is a commit. The gate is `zig build test-server` and `zig build spec-rest`, both green.

1. **Runner, format, first file.** `rest_spec.zig`, the CLI, the build steps, and `json_pb`'s
   comparison exposed with an allocator plus the subset matcher. Unit tests for every matcher,
   each with a mismatch it must reject (`json_pb.zig:765`: without one, a helper blesses every
   golden it is given). Port the routing tests into `routing.zon` and delete them from
   `server.zig`. Then change one expected status by hand and read the failure.
2. **Port by resource.** One commit per file: `datasets.zon`, `tables.zon`,
   `tabledata/insert_all.zon`, `jobs/query.zon`, `jobs/insert.zon`,
   `jobs/get_query_results.zon`. Each commit deletes the tests it ports. A case's `desc` is its
   test's name, so grepping for a test name still lands, and the test's comments move onto the
   case. `jobs/get.zon` is new coverage rather than a port. Split the three engine-state
   assertions into small Zig tests.
3. **Goldens.** `capture_golden.py` emits ZON, `go_golden.zon` lands, `golden.json` goes, the
   citations follow, and the first-replay differences are triaged.
4. **CI.** `zig build spec-rest` in the `test` job after `test-server`, on the same shim dylib.
   It dispatches in-process, so it needs no `-Drelease`.

Later, if wanted:

- `--target URL`: the same steps over `std.http.Client` to a running process. Against this
  server's binary it covers what in-process dispatch skips (the socket, gzip, the query-string
  split); against the Go emulator it replaces `capture_golden.py`'s hand-listed cases with the
  spec files. `.restart` steps skip.
- `spec_ui` listing REST results beside SQL ones; `rest_spec.Record` keeps `spec_run.Record`'s
  shape for that.
- The 27 gRPC tests in `grpc/read_service.zig` are out of scope.

---

## 7. Risks

- A breakpoint inside a test body is gone. `install-spec-rest` with `--case` replaces it, as
  `.run/Debug spec case.run.xml` does for the SQL runner.
- A fresh `Server` for each of about 67 cases. Measure in stage 1; if it shows, add a file-level
  `.shared_server = true` like `spec_run`'s shared connection.
- `.{}` matching both `{}` and `[]` in an expectation could let `[]` turn into `{}` unnoticed. The
  goldens pin `array_empty` and `array_null` byte-exact, which is where clients read it.
