# TestShards.jl

[![Julia](https://img.shields.io/badge/julia-v1.10+-9558b2.svg)](https://julialang.org)
[![Code Style: Blue](https://img.shields.io/badge/Code%20Style-Blue-4495d1.svg)](https://github.com/invenia/BlueStyle)
[![License](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

Split a Julia test suite across CI jobs, balanced by measured per-file runtime — and keep the
plumbing out of your repository.

Adopting this removes, per repo: a hand-written test-file universe, a shard-planning script, a
coverage-merge job, a timing-recording job, and the several hundred lines of workflow YAML that
held them together. What is left is two lines of `runtests.jl` and a five-line workflow call.

## Use it

**`test/runtests.jl`**

```julia
using MyPackage, TestShards

TestShards.@runtests oneshots = ["test_aqua.jl"]
```

The suite is **discovered**: every directory under `test/` holding `test_*.jl` is a shardable
unit, ordered deterministically. There is no list to maintain, so there is no list to forget to
update. `oneshots` are whole-package checks (Aqua, a citation check) — not shardable, so they run
exactly once per plan, in whichever shard finishes earliest.

Add TestShards to your `[extras]` / `[targets]` test deps, and nothing else changes: a bare
`Pkg.test()` still runs everything, locally, exactly as before.

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

That one call plans the shards, runs them, **merges every shard's coverage into a single Codecov
upload**, records the timing history, and exposes one `All shards passed` job to gate on.

## How the balancing works

Run → each shard emits its per-file times → they are merged into a `ci-timings` orphan branch →
the next run's planner bin-packs against them, longest file first into the least-loaded shard.

A file with no history is estimated at the **P90** of the known times, deliberately pessimistic,
so a new and surprisingly heavy test gets isolated instead of piled onto an already-full shard.
With no history at all the planner emits deterministic round-robin: correct, just not yet
balanced. A fresh repo therefore works immediately and balances itself from the second push.

Only pushes to the default branch record timings. A PR must never rewrite the history it was
planned against.

## What it refuses to do quietly

Sharding fails in ways that leave CI green, so the failure modes are errors rather than warnings:

- A shard id set with no slice selected would make **every shard run the whole suite** — green,
  slow, and meaningless. That is an error.
- A planner naming a file the suite does not have means the two disagree about what exists. That
  is an error, not a skipped file.
- With `dirs` pinned, a directory holding `test_*.jl` that is not declared would **run zero tests
  forever**. That is an error. (Discovery, the default, removes the failure mode instead.)
- A green run on the default branch that produced **zero timing rows** means the emit path is
  broken and planning would silently round-robin forever. The workflow fails.

Timings are emitted even when a shard fails — a red shard's files still took however long they
took, and dropping that would make the next plan fall back to a stale estimate exactly where the
suite is changing.

## Scope

This partitions a suite across **CI jobs**. It does not run tests in parallel *within* a job —
that is [`ParallelTestRunner.jl`](https://github.com/JuliaTesting/ParallelTestRunner.jl) and
[`ReTestItems.jl`](https://github.com/JuliaTesting/ReTestItems.jl)'s business, and the two compose.

Balancing by historical duration is standard practice (`pytest-split`, Knapsack, Buildkite's test
splitter all do it); none of them is Julia-aware, and none of the Julia runners partitions across
jobs. This fills that specific gap for the author's own fleet.

## Environment protocol

Set by the workflow; you do not normally write these.

| variable | meaning |
|---|---|
| `TESTSHARDS_FILES` | this shard's slice, comma-separated `dir/file` keys |
| `TESTSHARDS_SHARD` | `"k/N"` round-robin fallback, needs no history |
| `TESTSHARDS_ONESHOTS` | `1` if this shard also runs the whole-package checks |
| `TESTSHARDS_ID` | shard label, names the emitted timing file |
| `TESTSHARDS_EMIT` | `1` to write timings for the next planner |
| `TESTSHARDS_OUT` | where to write them — must be inside the workspace, because `Pkg.test` sandboxes the suite |

## License

MIT.
