# TestShards.jl

Your test suite runs in one CI job and takes twenty minutes. TestShards runs it in eight jobs and
takes three, balanced by how long each file actually took last time.

You wrap `runtests.jl` in one macro and call one workflow. There is no list of test files to
maintain, no naming convention to follow, and `Pkg.test()` on your machine keeps doing exactly
what it did before.

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
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

Each `include` is one shardable piece — including the ones the `for` loop produces. That is the
whole adoption: no shard-planning step, no coverage-merge job, no job that records timings.

## Start here

- **[Getting started](getting-started.md)** — install, wire up CI, every workflow input, and how
  to reproduce one shard on your machine.

Then, as you need them:

- [Units](units.md) — what gets split, and keeping order-dependent files together.
- [Balancing](balancing.md) — the timing history, how many shards your suite can actually use.
- [Records](records.md) — what a run reports, and attaching evidence to a testset.
- [Guarantees](guarantees.md) — what cannot silently go wrong, and the one rule your suite must
  follow.
- [Composing](composing.md) — letting another tool own the testset a unit runs in.
- [API](api.md) — every exported and public function.

## What a run gives you

| | |
|---|---|
| **One coverage upload** | the shards' counters are merged once, not uploaded N times |
| **One ordered record** | every unit, every testset, in suite order — not eight interleaved logs |
| **A completeness check** | the run fails if a unit ran nowhere, or ran twice |
| **A diagnosis** | what is limiting *your* suite, and what follows from it |

## How the splitting differs

**A unit is whatever `runtests.jl` includes.** [`@shard`](@ref) shadows `include` inside its
block, so the interception happens at the *call*. A file produced by `for f in readdir(...)`
shards exactly like a literal `include("a.jl")` — nothing to register, nothing to keep in sync.

**Balance comes from measurement.** Each green run on the default branch records how long every
unit took, and the next run bin-packs from those numbers rather than from a file count.

**Every run reconciles what ran against what was observed**, because splitting a suite introduces
a failure a green badge cannot show you: a unit that ran in *no* shard.

| | what defines a piece | how it balances | adding a test file |
|---|---|---|---|
| A hand-written job matrix | a list in the workflow | you do, by hand | edit the list — or it silently never runs |
| A path or naming convention | a directory or filename rule | file count | must be named to match |
| [ReTestItems.jl](https://github.com/JuliaTesting/ReTestItems.jl), [ParallelTestRunner.jl](https://github.com/JuliaTesting/ParallelTestRunner.jl) | a `@testitem` / a file | worker processes inside one job | nothing |
| **TestShards** | whatever `runtests.jl` includes | measured runtime | nothing |

## Scope

This splits a suite across **CI jobs**. It does not run tests in parallel *within* a job — that is
[ParallelTestRunner.jl](https://github.com/JuliaTesting/ParallelTestRunner.jl) and
[ReTestItems.jl](https://github.com/JuliaTesting/ReTestItems.jl)'s business, and the two compose.
What limits each is different: worker processes are bounded by one runner's cores, jobs by what
your account will schedule at once.
