# TestShards.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://codes.sota-shimozono.com/TestShards.jl/stable/)
[![codecov](https://codecov.io/gh/QAtlasHub/TestShards.jl/branch/main/graph/badge.svg)](https://app.codecov.io/gh/QAtlasHub/TestShards.jl)
[![Julia](https://img.shields.io/badge/julia-v1.10+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Run a Julia test suite across several CI jobs at once, balanced by how long each part actually
took last time.

## What you get

- **Sharded CI from a five-line workflow call.** No shard-planning script, no list of test
  files, no coverage-merge job, no timing-recording job.
- **Nothing to declare.** The shardable units are whatever `runtests.jl` includes — literal or
  computed. There is no naming convention to follow and no manifest to keep in sync.
- **One merged coverage report** and **one ordered record** of what ran, per run.
- **A diagnosis** naming what is actually limiting your suite — the queue, the per-shard setup,
  one heavy test, or nothing — and what follows from each.
- **A completeness check on every run**: the shards reconcile what they observed against what
  they ran, and the run fails if a unit ran nowhere or twice.
- **Work stealing**, optional, for when the runners do not start together.

A bare `Pkg.test()` is unchanged: with no environment set, everything runs, in order.

## Install

```julia
pkg> add TestShards
```

and add it to your test dependencies (`[extras]` + `[targets]` in `Project.toml`).

## Use

**`test/runtests.jl`** — wrap what you already have:

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

**`.github/workflows/CI.yml`**:

```yaml
jobs:
  test:
    permissions:
      contents: write        # to record the timing history
    uses: QAtlasHub/TestShards.jl/.github/workflows/sharded-tests.yml@main
    with:
      shards: 8
    secrets: inherit
```

That runs the shards, merges their coverage into one upload, merges their records into one
ordered document, checks that every unit ran exactly once, updates the timing history, and
exposes a single `All shards passed` job to require in branch protection.

## What to expect

A shard costs a fixed amount before it runs anything — checkout, depot restore, precompilation
— and that cost does not shrink when you add shards. So the wall clock is roughly

> `wall(N) = fixed + (load of the heaviest shard)`

and it stops improving once the heaviest *single test* dominates. Adding shards past that point
buys nothing and pays the fixed cost again each time.

`TestShards.diagnose` finds that point for you from the recorded history, and CI prints it on
every run:

```
TestShards diagnosis — 22 units
  serial total      216.9s
  fixed per shard   24.7s
  predicted at N=8  53.7s wall, 414.6s runner
  knee              N=10
  floor             core/partition/n7.jl  23.1s — no split finishes sooner than this
  observed          70.4s wall, 414.6s runner over 8 shards (8 at once)
  effective         3.1x of 8 — start window 2.0s (s2 first, s1 last)
  bottleneck        WorkBound — use shards: 10
```

That is this package's own suite. Read it as: 217 s of work finished in 70 s; the eight shards
really did run at once (a 2 s start window); nothing is in the way, so more shards would still
help, up to ten.

The last line is the one to read first. The same numbers mean opposite things at different
scales — a 25 s per-shard cost is fatal to a two-minute suite and a rounding error on a
forty-minute one — so the diagnosis decides which case you are in rather than leaving it to
you. Under `FloorBound` it also names the heaviest `@testset`s *inside* the unit that is the
floor, so you know where to cut.

The wall-clock model assumes the shards run at the same time. On GitHub-hosted runners they
often do not: the start window on this repository has ranged from 2 s to 199 s between
consecutive pushes. That is why the shards record *when* they ran and not only for how long,
and why `steal: true` exists — with it, a shard that starts late takes less work instead of
delaying everyone.

The first run of a fresh repository has no history and falls back to an even split — correct,
just not yet balanced. It balances itself from the second push to the default branch.

## Documentation

| | |
|---|---|
| [Getting started](https://codes.sota-shimozono.com/TestShards.jl/stable/getting-started/) | installing, wiring CI, running one shard locally |
| [Units](https://codes.sota-shimozono.com/TestShards.jl/stable/units/) | what gets split, `@unit`, ordering |
| [Balancing](https://codes.sota-shimozono.com/TestShards.jl/stable/balancing/) | the timing history, choosing a shard count, the diagnosis |
| [Records](https://codes.sota-shimozono.com/TestShards.jl/stable/records/) | what each run reports, and `evidence!` |
| [Guarantees](https://codes.sota-shimozono.com/TestShards.jl/stable/guarantees/) | what cannot silently go wrong, and the one rule your suite must follow |

## Scope

This splits a suite across **CI jobs**. It does not run tests in parallel *within* a job — that
is [ParallelTestRunner.jl](https://github.com/JuliaTesting/ParallelTestRunner.jl) and
[ReTestItems.jl](https://github.com/JuliaTesting/ReTestItems.jl)'s business, and the two compose.

## License

MIT.
