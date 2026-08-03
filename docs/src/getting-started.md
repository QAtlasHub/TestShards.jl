# Getting started

## Install

```julia
pkg> add TestShards
```

TestShards is used from your test suite, so it belongs in your **test** dependencies:

```toml
[extras]
TestShards = "acceef1d-f5e0-4fe4-a546-818dc56ce7b2"

[targets]
test = ["Test", "TestShards"]
```

## Wrap your suite

Take whatever `test/runtests.jl` already does and put it inside [`@shard`](@ref):

```julia
using MyPackage, TestShards

TestShards.@shard begin
    include("core/a.jl")
    include("core/b.jl")
    for f in readdir(joinpath(@__DIR__, "solver"); join = true)
        include(f)
    end
end
```

Each `include` becomes one shardable unit. Nothing else changes: run `Pkg.test()` and the whole
suite runs, in order, as before.

## Wire up CI

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    permissions:
      contents: write        # the timing history is pushed to a `ci-timings` branch
    uses: QAtlasHub/TestShards.jl/.github/workflows/sharded-tests.yml@main
    with:
      shards: 8
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

!!! warning "The `contents: write` grant is required"
    A called workflow's jobs may not request more permission than the caller granted, and
    recording the timing history needs write access. Granting less makes the run fail to
    **start**, with no log to read.

### If your Codecov token does not arrive

Check the `collect` job for this warning:

```
No CODECOV_TOKEN reached this workflow, so the upload will be rejected during processing
```

A secret does not always survive the call into a reusable workflow. Measured across an
organisation boundary: the token was present in the caller's own job and absent inside the called
workflow, **with the secret named rather than inherited** — the form makes no difference.

The failure is quiet by construction. Codecov rejects a tokenless upload during *processing*,
which happens after the uploader has already succeeded at queueing it, so the step goes green and
coverage simply stops arriving.

**Which case you are in is decided by the organisation, not the repository.** Measured both ways
against the same reusable and the same named `secrets:` block: a caller in the *same* organisation
gets the token and uploads normally; a caller in a *different* one gets nothing. A repository
boundary is fine.

Nothing is lost, because the merge has already happened: the report is published as the
`testshards-lcov` artifact. Upload it from your own repository, where your token works, in a job
of its own — and tell the workflow to stop trying, so it does not warn you every run about a
token you deliberately did not send:

```yaml
  test:
    uses: QAtlasHub/TestShards.jl/.github/workflows/sharded-tests.yml@main
    with:
      shards: 8
      coverage-upload: false     # this repository sends it, below
    # no `secrets:` block — it would not arrive, and not sending it is what silences the warning

  coverage:
    needs: test
    runs-on: ubuntu-latest
    steps:
      - uses: QAtlasHub/TestShards.jl/actions/upload-coverage@main
        with:
          codecov-token: ${{ secrets.CODECOV_TOKEN }}
```

An **action** runs inside your job, so the token never crosses anything. `codecov/codecov-action`
is the proof that this works — another organisation's action, receiving that same token without
trouble, in the very run whose reusable-workflow call did not.

| input | default | |
|---|---|---|
| `codecov-token` | — | required |
| `artifact` | `testshards-lcov` | only change it if you renamed it |
| `fail-on-error` | `'false'` | fail the job on a failed upload |
| `flags` | `''` | Codecov flags, comma-separated |

Give it its own job. It checks out the repository — Codecov needs the tree to build the report's
file network, and an upload without one is rejected during processing, silently — and a checkout
cleans the workspace.

### Inputs

Every input has a default, so `shards` is the only one most suites ever set.

| input | default | |
|---|---|---|
| `shards` | `8` | how many jobs to split across |
| `runner` | `'"ubuntu-latest"'` | `runs-on` as JSON, e.g. `'["self-hosted","my-label"]'` |
| `helper-runner` | `'"ubuntu-latest"'` | runner for the small merge jobs — keep it hosted, they need no depot |
| `julia-version` | `'1'` | |
| `test-root` | `'test'` | directory holding `runtests.jl` |
| `coverage` | `true` | merge the shards' coverage and upload it once |
| `coverage-upload` | `true` | set `false` when you upload the merged report yourself |
| `diagnose` | `true` | report what the history says about the suite's shape |
| `steal` | `false` | claim work instead of being assigned it — see [Guarantees](guarantees.md) |
| `steal-min-seconds` | `'0'` | with `steal`, leave units cheaper than this statically assigned |
| `stagger-seconds` | `'0'` | delay each shard's start on purpose, to compare arrival strategies |
| `prebuild` | `false` | precompile once and hand it to the shards — **hosted runners only**, see [Balancing](balancing.md) |
| `concurrency-budget` | `'0'` | how many jobs your *account* can run at once; `0` = unknown |
| `fixed-cost-seconds` | `'0'` | per-shard overhead, for the cost figures (see [Balancing](balancing.md)) |
| `registries` | `''` | registries to add before resolving, one per line — see below |
| `testshards-spec` | `'name="TestShards"'` | where the merge jobs install TestShards from |

#### `registries` — for a project that resolves from an overlay

Only needed when your dependencies do not all come from General. Each line is either a name Pkg
knows or a clone URL, and each is added **only if it is not already reachable**, because
re-adding an existing registry errors rather than doing nothing:

```yaml
    with:
      registries: |
        General
        https://github.com/my-org/MyRegistry.git
```

Registries are depot-level, so this reaches inside `Pkg.test`'s sandbox.

!!! warning "On a self-hosted pool, a missing registry fails *partially*"
    The depot is persistent per box, and the boxes need not carry the same registries. Whichever
    ones happen to have run a job that added yours have it and the rest do not — so the same
    commit resolves on some shards and dies on others with `expected package X to be registered`.
    It reads as flake and is not.

The workflow exposes an `All shards passed` job — that is the one to require in branch
protection, rather than the individual shards, whose names change with `shards`.

## Run one shard locally

Sharding is driven entirely by environment variables, so you can reproduce any CI shard:

```bash
TESTSHARDS_ID=s3 TESTSHARDS_N=8 julia --project -e 'using Pkg; Pkg.test()'
```

Or run an explicit selection, which is usually what you want when chasing one failure:

```bash
TESTSHARDS_UNITS="core/a.jl,solver/heavy.jl" julia --project -e 'using Pkg; Pkg.test()'
```

| variable | meaning |
|---|---|
| `TESTSHARDS_ID` | this shard's label |
| `TESTSHARDS_N` | number of shards |
| `TESTSHARDS_UNITS` | explicit unit list; takes precedence over the above |
| `TESTSHARDS_TIMINGS` | timing history TSV used to balance |
| `TESTSHARDS_OUT` | where to write records and timings |

With none of them set, everything runs.
