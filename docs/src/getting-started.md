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
    secrets: inherit
```

!!! warning "The `contents: write` grant is required"
    A called workflow's jobs may not request more permission than the caller granted, and
    recording the timing history needs write access. Granting less makes the run fail to
    **start**, with no log to read.

### Inputs

| input | default | |
|---|---|---|
| `shards` | `8` | how many jobs to split across |
| `runner` | `'"ubuntu-latest"'` | `runs-on` as JSON, e.g. `'["self-hosted","rosina"]'` |
| `julia-version` | `'1'` | |
| `test-root` | `'test'` | directory holding `runtests.jl` |
| `coverage` | `true` | merge the shards' coverage and upload it |
| `diagnose` | `true` | report what the history says about the suite's shape |
| `fixed-cost-seconds` | `'0'` | per-shard overhead, for the cost figures (see [Balancing](balancing.md)) |

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
