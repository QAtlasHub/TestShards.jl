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

A secret does not always survive the call into a reusable workflow: the token was present in the
caller's own job and absent inside the called workflow, **with the secret named rather than
inherited** — the form makes no difference.

The failure is quiet by construction. Codecov rejects a tokenless upload during *processing*,
which happens after the uploader has already succeeded at queueing it, so the step goes green and
coverage simply stops arriving.

**You are in it when your repository is private *and* this workflow is in another organisation.**
Measured across four callers of one reusable, same named `secrets:` block, one variable at a time:

| caller's organisation | caller's visibility | token |
|---|---|---|
| same as the callee | public | **arrives** |
| different | public | **arrives** |
| same as the callee | private | **arrives** |
| different | **private** | **empty** |

Neither condition alone predicts it — it is the combination. The failing caller's token was
verifiably present in its own job, so it is the call losing it and not a missing secret, and
`secrets: inherit` versus a named secret makes no difference.

There is a second, unrelated way to end up with no token, worth ruling out first: an
**organisation** secret does not reach a **private** repository on a free plan at all, so such a
repo has an empty token in *every* job of its own. That one is fixed by giving the repository its
own secret, not by moving the upload.

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

### Calling it twice from one workflow

A matrix over Julia versions is two calls, and they share a run. Without a discriminator they
collide on `upload-artifact`, which rejects a duplicate name — so **the second call fails on an
upload after its tests passed**. Give each its own prefix:

```yaml
jobs:
  ci:     { uses: ..., with: { shards: 8, artifact-prefix: 'v1' } }
  ci-lts: { uses: ..., with: { shards: 8, artifact-prefix: 'lts', julia-version: '1.10', record-timings: false } }
```

`record-timings: false` on the secondary leg matters more than the prefix does, and fails more
quietly. Both legs would otherwise record to the same branch having measured **different**
configurations: whichever finishes last wins, and every later run is planned against a history
that is half one version and half the other. Nothing fails; the balance just stops meaning what
it says.

If you set a prefix and upload coverage yourself, pass the matching artifact to the action:
`artifact: v1-lcov`.

### Inputs

Every input has a default, so `shards` is the only one most suites ever set.

| input | default | |
|---|---|---|
| `shards` | `8` | how many jobs to split across; `1` runs the suite whole — see below |
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
| `registries` | `''` | registries to add and refresh before resolving, one per line — see below |
| `artifact-prefix` | `'testshards'` | set it when ONE workflow calls this twice — see below |
| `record-timings` | `true` | turn it off on the secondary legs of a multi-version matrix |
| `testshards-spec` | `'name="TestShards"'` | where the merge jobs install TestShards from |

#### `shards: 1` — the suite whole

`shards: 1` does not mean "one of one shard". It means **run the suite whole, in one job**: no
split, no shard id, nothing skipped. Everything that is not the split still happens — the
exactly-once check, the merged coverage report, the diagnosis that tells you how many shards
this suite could actually use.

It is what to write when a suite has one unit, when it is too small to be worth splitting, or
when you adopt this for the report and want the split later. Ask for the split by raising the
number; nothing else about the call changes.

This repository's own CI runs one, on every commit, next to its eight-way call — so the
sentence above is demonstrated rather than asserted.

#### `registries` — for a project that resolves from an overlay

Each line is either a name Pkg knows or a clone URL. Each is added **only if it is not already
reachable** — re-adding an existing registry errors rather than doing nothing — and then **every
registry in every depot is refreshed**:

```yaml
    with:
      registries: |
        General
        https://github.com/my-org/MyRegistry.git
```

Registries are depot-level, so this reaches inside `Pkg.test`'s sandbox.

Set it even for a package that resolves entirely from General, if you run on a persistent
self-hosted depot. **Present is not the same as current**, and the two fail differently: a
missing registry stops the resolve, while a stale one resolves fine and simply cannot see a
version registered since it was last pulled.

!!! warning "One `Pkg.Registry.update()` is not enough"
    It manages `DEPOT_PATH[1]` only, and a self-hosted runner can carry the same registry twice —
    a per-runner front depot and a shared `~/.julia`. A runner whose *front* depot lacks the
    registry resolves from the shared clone, which the plain call never touches. The result is
    "some shards green, one red on the same commit", and waiting after a registration does not
    help, because the staleness is per runner. This workflow therefore refreshes each depot in
    turn.

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
