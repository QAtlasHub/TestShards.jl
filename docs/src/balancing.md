# Balancing

## How the split is decided

Each shard reads the same timing history and computes the same assignment: heaviest unit first
into the least-loaded shard — longest-processing-time bin packing [Graham1969](@cite). Because
every shard runs the identical computation over the identical input, no coordination is needed
— and a unit cannot land in two shards or in none.

A unit with no history yet is assigned as it is encountered, spread evenly across shards. So a
test added since the last recorded run is still guaranteed to run exactly once, with no planning
step in between.

With no history at all — a fresh repository — the split is even but blind. It balances itself
from the second push to the default branch, once timings have been recorded.

## The history

Each shard writes the time each of its units took; CI merges them and stores the result on a
`ci-timings` orphan branch. Only pushes to the default branch record: a pull request must never
rewrite the history it was planned against.

## How many shards can this suite use?

A shard pays a fixed cost before running anything — checkout, depot restore, precompilation —
and that cost does not shrink when you add shards:

> `wall(N) = fixed + (load of the heaviest shard at N)`

The second term falls as `N` grows, until the **heaviest single unit** dominates. From there,
more shards change nothing and each still costs `fixed`.

[`TestShards.diagnose`](@ref) finds that point:

```julia
julia> using TestShards

julia> t = TestShards.load_timings("timings.tsv");

julia> TestShards.diagnose(t; n = 8, fixed = 60.0)
TestShards diagnosis — 11 units
  serial total      152.1s
  fixed per shard   60.0s
  at N=8            106.8s wall, 632.1s runner
  knee              N=4  (N=8 costs more for no gain)
  floor             core/test_partition_large.jl  46.8s — no split finishes sooner than this

  heaviest units
    46.8    core/test_partition_large.jl
    35.1    core/test_unit_atomicity.jl
    26.9    core/test_partition_small.jl
```

- **knee** — the smallest shard count that reaches the best wall clock. Past it you are paying
  for jobs that do not make the run finish sooner.
- **floor** — the heaviest single unit. No split across jobs beats it, so lowering it is the
  only way to go faster.

To lower the floor, split that unit. The diagnosis names the heaviest `@testset`s inside it, so
you know where to cut rather than guessing.

## Measuring `fixed`

Take one shard's job wall clock and subtract the time its units took; the remainder is the
fixed cost. It is usually dominated by precompilation.

`fixed` scales the reported cost but not the knee, so leaving it at `0` still answers "how many
shards can this suite use". Pass it via the `fixed-cost-seconds` workflow input to get the
runner-time figures right too.

## Sharing the depot cache

All shards instantiate the same project, so they should share one dependency cache. The bundled
workflow does this. Giving each shard its own cache key makes it pay precompilation separately
— which is exactly the `fixed` term above, multiplied by the shard count.
