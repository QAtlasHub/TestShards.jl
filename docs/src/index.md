# TestShards.jl

Run a Julia test suite across several CI jobs at once, balanced by how long each part actually
took last time.

The shardable units are **whatever `runtests.jl` includes** — literal or computed. There is no
naming convention to follow and no manifest to keep in sync, and a bare `Pkg.test()` is
unchanged: with no environment set, everything runs, in order.

```julia
using MyPackage, TestShards

TestShards.@shard begin
    include("core/a.jl")
    for f in readdir(joinpath(@__DIR__, "solver"); join = true)
        include(f)
    end
end
```

```yaml
jobs:
  test:
    permissions:
      contents: write
    uses: QAtlasHub/TestShards.jl/.github/workflows/sharded-tests.yml@main
    with:
      shards: 8
    secrets: inherit
```

## Where to go

- [Getting started](getting-started.md) — installing, wiring CI, running one shard locally.
- [Units](units.md) — what gets split, keeping order-dependent files together, ordering.
- [Balancing](balancing.md) — the timing history, how many shards a suite can use, the diagnosis.
- [Records](records.md) — what a run reports, and attaching evidence to a testset.
- [Guarantees](guarantees.md) — what cannot silently go wrong, and the one rule your suite must follow.
- [API](api.md) — every exported and public function.

## Scope

This splits a suite across **CI jobs**. It does not run tests in parallel *within* a job — that
is [ParallelTestRunner.jl](https://github.com/JuliaTesting/ParallelTestRunner.jl) and
[ReTestItems.jl](https://github.com/JuliaTesting/ReTestItems.jl)'s business, and the two compose.
