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

julia> w = TestShards.load_shards("shards.tsv");

julia> TestShards.diagnose(t; n = 8, shards = w)
TestShards diagnosis — 12 units
  serial total      152.1s
  fixed per shard   48.7s
  predicted at N=8  95.5s wall, 542.0s runner
  knee              N=4  (N=8 costs more for no gain)
  floor             core/test_partition_large.jl  46.8s — no split finishes sooner than this
  observed          201.0s wall, 542.0s runner over 8 shards
  effective         0.8x of 8 — start window 130.0s (s1 first, s4 last)

  heaviest units
    46.8    core/test_partition_large.jl
    34.4    core/test_unit_atomicity.jl
    25.1    core/test_partition_small.jl
```

- **knee** — the smallest shard count that reaches the best wall clock. Past it you are paying
  for jobs that do not make the run finish sooner.
- **floor** — the heaviest single unit. No split across jobs beats it, so lowering it is the
  only way to go faster.

To lower the floor, split that unit. The diagnosis names the heaviest `@testset`s inside it, so
you know where to cut rather than guessing.

## Did the shards actually run at the same time?

Everything above assumes they did. A shard count only buys parallelism if the runners are
available; when the queue is congested the run finishes at

> `(when the LAST shard starts) + (its share of the work)`

and no amount of balancing changes that. So each shard also records **when** it ran, not only
for how long, and the diagnosis reports the two numbers that make the difference visible:

- **start window** — how long after the first shard the last one started.
- **effective parallelism** — the work divided by the wall clock it took. This is what the
  shard count was actually worth.

The run above is this package's own: 8 shards, and an effective parallelism of **0.8**. The
split was fine — the model says 95.5 s — but the last shard started 130 s after the first, so
the run took 201 s. A run whose observed wall clock is far above the prediction says so
explicitly in the CI summary, because the fix is a different one: fewer shards, or a runner
pool that can actually start them together, not a better balance.

Effective parallelism below 1 does not quite mean "one job would have been faster", though it
is a strong hint. The per-unit seconds are measured in separate processes, each re-paying
first-use compilation, so their sum overstates what a single job would take. Compare against a
real unsharded run before concluding.

Start times come from each runner's own clock. They are NTP-synced, so treat a spread of a
second or two as noise rather than as a queue effect.

## Measuring `fixed`

Take one shard's job wall clock and subtract the time its units took; the remainder is the
fixed cost. **The shards report this themselves** — the window each one recorded is exactly
that subtraction — so `diagnose` measures `fixed` rather than guessing it, and the
`fixed-cost-seconds` workflow input can stay at `0`. Set it only to ask what a hypothetical
price would do to the curve; an explicit value wins over the measured one.

`fixed` scales the reported cost but not the knee, so an unmeasured run still answers "how many
shards can this suite use".

## Sharing the depot cache

All shards instantiate the same project, so they should share one dependency cache, and the
bundled workflow does this: one `cache-name` for the whole matrix, `include-matrix: false`.
A shard that starts after another has finished then restores that shard's depot instead of
building its own, and only one copy is stored per run instead of one per shard.

Do not expect it to move `fixed` much on its own. Measured on this package, precompiling the
project under test is 3–4 s of a ~49 s fixed cost; the rest is installing Julia, processing
coverage, and starting a `Pkg.test` sandbox — none of which a depot cache touches. Read your
own diagnosis before assuming precompilation is where your shards' time goes.
