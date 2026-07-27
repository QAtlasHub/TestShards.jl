# TestShards.jl

[![Julia](https://img.shields.io/badge/julia-v1.10+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Split a Julia test suite across CI jobs, and record what each piece did.

The units are **whatever `runtests.jl` includes** — no naming convention, no manifest to keep
in sync. Adopting this removes, per repository: a shard-planning script, a test-file list, a
coverage-merge job, a timing-recording job, and the workflow YAML that held them together.

## Use it

**`test/runtests.jl`**

```julia
using MyPackage, TestShards

TestShards.@shard begin
    include("core/a.jl")
    for f in readdir(joinpath(@__DIR__, "solver"); join = true)
        include(f)                        # computed includes are units too
    end
    TestShards.@unit "stateful" begin     # one unit: same shard, in this order
        include("stateful/01_setup.jl")
        include("stateful/02_use.jl")
    end
end
```

`@shard` shadows `include` inside its block, so each call is observed as it happens. That is
why a loop over `readdir` shards exactly like a literal list — the interception is at the call,
not at the source text.

**`.github/workflows/CI.yml`**

```yaml
jobs:
  test:
    uses: QAtlasHub/TestShards.jl/.github/workflows/sharded-tests.yml@main
    with:
      shards: 8
      runner: '["self-hosted","rosina"]'   # or the default '"ubuntu-latest"'
    secrets: inherit
```

That call runs the shards, **merges every shard's coverage into one Codecov upload**, merges
every shard's records into one ordered document, records the timing history, and exposes a
single `All shards passed` job to gate on.

Add TestShards to your test dependencies and nothing else changes: a bare `Pkg.test()` sets no
environment, so it runs everything, exactly as before.

## Why it cannot silently drop a test

Every shard observes the **whole** sequence of includes and skips what is not its own. Two
properties follow, and they are what makes sharding safe rather than merely fast:

- **Assignment is total and deterministic.** Each shard computes the same split from the same
  timing history, so a unit belongs to exactly one shard. A unit no shard claims cannot exist.
- **A unit absent from the history is still assigned** — round-robin over the unknown units in
  observation order, identical in every shard. Adding a test file does not require a planning
  step, and cannot leave it unrun.

The failure modes that would otherwise leave CI green and meaningless are errors: a shard id
set with no slice (every shard would run everything), and a green default-branch run that
produced no timing rows (planning would round-robin forever without saying so).

## Two modes

| mode | how a shard learns its work | when |
|---|---|---|
| **auto** | `TESTSHARDS_ID` + `TESTSHARDS_N`, split by measured time | the default; balances itself from the second push |
| **manual** | `TESTSHARDS_UNITS` — an explicit list of unit names | hand-assigned groups, as a declared test-group matrix does |

An explicit list wins outright. `@unit` names a unit, so naming is how you assign by hand.

## Order

Within a shard, units run in **observed order**, whatever the packing decided. Across shards
order is not preserved — that is what parallelism means. Anything order-dependent therefore
belongs in one `@unit`, which stays whole and in sequence.

A suite that is sequential end to end cannot be sharded. That is a property of the suite, not a
limitation to work around.

## Records

Each unit's `@testset` tree is captured with per-testset timings and outcomes, and written as
JSONL — one unit per line, ordered by position in the full sequence:

```json
{"key":"core/a.jl","index":1,"shard":"s1","duration":0.20,
 "npass":2,"nfail":0,"nerror":0,"nbroken":0,
 "sections":[{"name":"inflation preserves the tiling","duration":0.056,
              "npass":2,"nfail":0,"nerror":0,"nbroken":0,
              "evidence":{"tolerance":1.0e-12,"achieved":3.2e-14,
                          "oracle":"closed-form inflation matrix"},
              "sections":[{"name":"sub-check", ...}]}]}
```

The shape is a **unit → testset hierarchy**, which maps onto a document as one page per unit
and one section per testset. Because identity is `(key, index)` and every shard agrees on it,
records from separate jobs merge into one ordered document — the report does not depend on how
the run was split.

Attach evidence to the running testset so the report can state what was established without a
reader going to the source:

```julia
@testset "inflation preserves the tiling" begin
    err = norm(inflate(t) - reference)
    evidence!(; tolerance = 1e-12, achieved = err, oracle = "closed-form inflation matrix")
    @test err < 1e-12
end
```

Outside a `@shard` block `evidence!` is a no-op, so a test file stays runnable on its own.

## One requirement sharding imposes

**Every unit must be independently includable.** A shard receives an arbitrary subset, so a
file relying on a helper defined in another file works unsharded and breaks the moment the two
land in different shards. `WARNING: Method definition ... overwritten` during a full run is the
tell. Give each file its own helpers, put shared ones in a file each includes, or bind the group
into one `@unit`.

## Scope

This partitions a suite across **CI jobs**. It does not run tests in parallel *within* a job —
that is [`ParallelTestRunner.jl`](https://github.com/JuliaTesting/ParallelTestRunner.jl) and
[`ReTestItems.jl`](https://github.com/JuliaTesting/ReTestItems.jl)'s business, and the two
compose.

Balancing by historical duration is standard practice (`pytest-split`, Knapsack, Buildkite's
test splitter); none is Julia-aware, and no Julia runner partitions across jobs. This fills that
gap for the author's own fleet.

## Environment

Set by the workflow; you do not normally write these.

| variable | meaning |
|---|---|
| `TESTSHARDS_ID` | this shard's label |
| `TESTSHARDS_N` | number of shards (auto mode) |
| `TESTSHARDS_UNITS` | explicit unit list (manual mode; wins over auto) |
| `TESTSHARDS_TIMINGS` | timing history TSV driving the balance |
| `TESTSHARDS_OUT` | where records and timings are written — must be inside the workspace, because `Pkg.test` sandboxes the suite |

## License

MIT.
