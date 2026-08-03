# TestShards.jl

[![docs: stable](https://img.shields.io/badge/docs-stable-blue.svg)](https://qatlashub.github.io/TestShards.jl/stable/)
[![codecov](https://codecov.io/gh/QAtlasHub/TestShards.jl/branch/main/graph/badge.svg)](https://app.codecov.io/gh/QAtlasHub/TestShards.jl)
[![Julia](https://img.shields.io/badge/julia-v1.10+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Your test suite runs in one CI job and takes twenty minutes. TestShards runs it in eight jobs and
takes three, balanced by how long each file actually took last time.

You wrap `runtests.jl` in one macro and call one workflow. There is no list of test files to
maintain, no naming convention to follow, and `Pkg.test()` on your machine keeps doing exactly
what it did before.

## Install

```julia
pkg> add TestShards
```

It is used *from* your test suite, so it belongs in your test dependencies:

```toml
[extras]
Test = "8dfed614-e22c-5e08-85e1-65c5234f0b40"
TestShards = "acceef1d-f5e0-4fe4-a546-818dc56ce7b2"

[targets]
test = ["Test", "TestShards"]
```

Julia 1.10 or newer.

## Quick start

**1. Wrap what `test/runtests.jl` already does.**

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

Each `include` is one shardable piece — including the ones the `for` loop produces. Nothing else
in your suite changes.

**2. Point CI at the workflow.**

```yaml
name: CI
on:
  push:
    branches: [main]
  pull_request:

jobs:
  test:
    permissions:
      contents: write        # required — see the note below
    uses: QAtlasHub/TestShards.jl/.github/workflows/sharded-tests.yml@main
    with:
      shards: 8
    secrets:
      CODECOV_TOKEN: ${{ secrets.CODECOV_TOKEN }}
```

That is the whole adoption for a **public** repository. You do not write a shard-planning step, a
coverage-merge job, or a job that records timings — the workflow is those things.

If yours is **private**, the secret above will not arrive and the upload will fail without
failing the job. That is not a mistake on your part and there is a supported way round it — see
[When one block is not enough](#when-one-block-is-not-enough).

> **`contents: write` is required.** A called workflow's jobs cannot request more permission than
> the caller granted, and the timing history is written to a `ci-timings` branch. Granting less
> makes the run fail to *start*, with no log to read.

In branch protection, require the **`All shards passed`** job. Do not require the individual
shards: their names change when you change `shards`.

## When one block is not enough

Thirty-four suites adopted this in one day, and five kinds of suite needed more than the block
above. Each of these is measured, not anticipated:

| your suite | what to add | why |
|---|---|---|
| a **private** repository | `coverage-upload: false`, plus a job of your own running [`actions/upload-coverage`](https://qatlashub.github.io/TestShards.jl/stable/getting-started/) | a private caller's secret does not reach a workflow in another organisation, so the reusable cannot upload for you. It still merges the report and publishes it as an artifact; only the sending is yours |
| runs on a **persistent self-hosted depot** | `registries: General` — even if that is all you use | it also *refreshes*. A registry that is present but stale resolves fine and simply cannot see a version published since it was last pulled |
| resolves from a **private overlay registry** | `registries:` with that registry's clone URL | added only if absent, because re-adding one errors |
| tests **more than one Julia version** | `artifact-prefix:` on each call, and `record-timings: false` on all but one | two calls share a run: without a prefix they collide on artifact names, and both would record measurements of *different* versions into one timing history |
| came from a **hand-written test manifest** | read it before deleting it | a manifest can *exclude* things — a directory run by a separate job, a file that is meant to fail. A glob cannot see a decision, and it will silently pull those back in |

Two things this cannot do yet: check out **submodules**, and pass **your own environment** to the
shards or collect **your own artifacts** from them. If your suite needs either, it cannot use this
workflow — see [#58](https://github.com/QAtlasHub/TestShards.jl/issues/58) and
[#59](https://github.com/QAtlasHub/TestShards.jl/issues/59).

## What you get out of a run

| | |
|---|---|
| **One coverage upload** | the shards' counters are merged once, not uploaded N times |
| **One ordered record** | every unit, every testset, in suite order — not eight interleaved logs |
| **A completeness check** | the run fails if a unit ran nowhere, or ran twice |
| **A diagnosis** | what is limiting *your* suite, and what follows from it |

The first run of a fresh repository has no history, so it falls back to an even split — correct,
just not yet balanced. It balances itself from the second push to the default branch.

## CI templates

**Self-hosted runners.** `runner` is `runs-on` as JSON, so a list works:

```yaml
    with:
      shards: 8
      runner: '["self-hosted","my-label"]'
```

**No coverage** (skips the merge and upload jobs entirely):

```yaml
    with:
      shards: 8
      coverage: false
```

**When the runners do not start together.** On hosted runners they often do not — on this
repository the start window between the first and last shard has ranged from 2 s to 199 s.
`steal: true` lets a shard that starts late take less work instead of delaying everyone:

```yaml
    with:
      shards: 8
      steal: true
```

**When the organisation cannot actually run that many jobs at once.** Shard counts are chosen per
repository but runners are budgeted per organisation, so a suite that *could* use sixteen may only
ever get eight — the rest queue and add cost without adding parallelism. Tell the diagnosis what
you have and it will say so:

```yaml
    with:
      shards: 16
      concurrency-budget: '8'
```

Every input, with its default, is in
[Getting started](https://qatlashub.github.io/TestShards.jl/stable/getting-started/).

## Running one shard locally

Sharding is driven entirely by environment variables, so any CI shard reproduces on your machine:

```bash
TESTSHARDS_ID=s3 TESTSHARDS_N=8 julia --project -e 'using Pkg; Pkg.test()'
```

Chasing one failure, run exactly the files you care about:

```bash
TESTSHARDS_UNITS="core/a.jl,solver/heavy.jl" julia --project -e 'using Pkg; Pkg.test()'
```

With none of them set, everything runs, in order. That is the same `Pkg.test()` you had before.

## How the splitting works, and how it differs

**A unit is whatever `runtests.jl` includes.** `@shard` shadows `include` inside its block, so the
interception happens at the *call*. A file produced by `for f in readdir(...)` therefore shards
exactly like a literal `include("a.jl")` — there is nothing to register and nothing to keep in
sync. Add a test file and it is sharded on the next run.

**Balance comes from measurement, not from counting.** Every green run on the default branch
records how long each unit took, and the next run bin-packs from those numbers. Splitting by file
count or by directory puts four fast files against one slow one and calls it balanced.

**Every run reconciles what ran against what was observed.** Splitting a suite introduces a
failure mode a green badge cannot show you: a unit that ran in *no* shard. So the shards compare
notes, and the run fails on a hole, a duplicate, or a disagreement.

How that compares with the other ways to split a Julia suite:

| | what defines a piece | how it balances | adding a test file |
|---|---|---|---|
| A hand-written job matrix | a list in the workflow | you do, by hand | edit the list — or it silently never runs |
| A path or naming convention | a directory or filename rule | file count | must be named to match |
| [ReTestItems.jl](https://github.com/JuliaTesting/ReTestItems.jl), [ParallelTestRunner.jl](https://github.com/JuliaTesting/ParallelTestRunner.jl) | a `@testitem` / a file | worker processes inside one job | nothing |
| **TestShards** | whatever `runtests.jl` includes | measured runtime | nothing |

The last row and the third are not alternatives. Those packages run tests in parallel **within**
one job, across worker processes; this splits a suite **across CI jobs**. They compose, and what
limits each is different: worker processes are bounded by one runner's cores, jobs by what your
account will schedule at once.

## Reading the diagnosis

CI prints this on every run:

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

That is this package's own suite: 217 s of work finished in 70 s, the eight shards really did run
at once, and nothing is in the way — so more shards would still help, up to ten.

**Read the last line first.** A shard pays a fixed cost before it runs anything, and that cost
does not shrink when you add shards, so a 25 s per-shard setup is fatal to a two-minute suite and
a rounding error on a forty-minute one. The bottleneck line says which case you are in and names
the remedy that follows — including, under `FloorBound`, the heaviest `@testset`s *inside* the
one file that no split can finish sooner than.

## Documentation

| | |
|---|---|
| [Getting started](https://qatlashub.github.io/TestShards.jl/stable/getting-started/) | installing, wiring CI, every workflow input, running one shard locally |
| [Units](https://qatlashub.github.io/TestShards.jl/stable/units/) | what gets split, keeping order-dependent files together |
| [Balancing](https://qatlashub.github.io/TestShards.jl/stable/balancing/) | the timing history, how many shards your suite can use |
| [Records](https://qatlashub.github.io/TestShards.jl/stable/records/) | what a run reports, and attaching evidence to a testset |
| [Guarantees](https://qatlashub.github.io/TestShards.jl/stable/guarantees/) | what cannot silently go wrong, and the one rule your suite must follow |
| [Composing](https://qatlashub.github.io/TestShards.jl/stable/composing/) | letting another tool own the testset a unit runs in |

## License

MIT.
