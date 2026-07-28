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

A shard can only see as far as its own test process, and its job keeps going afterwards —
processing coverage, uploading artefacts. CI therefore stamps the job's end separately and the
diagnosis folds it back in, because that tail is not small: measured here it is about **half**
the fixed cost on this suite, and about a tenth of it on a large one.

Without that stamp the measured `fixed` is a **lower bound**, and so is every conclusion drawn
from it — including [`FixedCostBound`](@ref TestShards.FixedCostBound), which is the test that
decides whether work stealing is worth anything. Understating the fixed cost biases that test
towards saying no.

`fixed` scales the reported cost but not the knee, so an unmeasured run still answers "how many
shards can this suite use".

## What is actually limiting this suite

The numbers above support five different conclusions, and they want opposite actions. Rather
than leave the reader to pick, the diagnosis decides — [`TestShards.bottleneck`](@ref) returns
one of five types and [`TestShards.remedy`](@ref) and [`TestShards.usable_shards`](@ref)
dispatch on it:

| regime | what it means | what to do |
|---|---|---|
| [`QueueBound`](@ref TestShards.QueueBound) | the shards never overlapped | fewer shards, or a pool that can start them |
| [`BudgetBound`](@ref TestShards.BudgetBound) | more shards asked for than the account runs at once | ask for what you can get, or move to another pool |
| [`FixedCostBound`](@ref TestShards.FixedCostBound) | a shard spends longer getting ready than testing | lower the setup, or split less |
| [`FloorBound`](@ref TestShards.FloorBound) | the heaviest single unit is what is left | cut that unit in two |
| [`WorkBound`](@ref TestShards.WorkBound) | nothing is in the way | more shards would still help |

### Usually more than one is true, and the choice between them is yours

They are tested in that order, because fixing one is what exposes the next: a queue-bound run
says nothing about its own balance, since the balance was never given a chance to matter.

**That order is a policy, not a measurement.** A run is regularly queue-bound *and* past its
knee *and* over budget — three independent facts, wanting different things. `bottleneck`
returns the first under the default rule; [`TestShards.bottlenecks`](@ref) returns **all of
them**, and the CI summary prints every one rather than the winner alone.

Nothing is resolved away behind that default. [`TestShards.remedy`](@ref) and
[`TestShards.usable_shards`](@ref) dispatch on any regime, so a different rule is a call away:

```julia
d  = TestShards.diagnose(t; n = 16, budget = 8, shards = w)
bs = TestShards.bottlenecks(d)                            # everything that holds

TestShards.usable_shards(TestShards.FloorBound(), d)      # what the SUITE could use
TestShards.usable_shards(TestShards.BudgetBound(), d)     # what the ACCOUNT will supply
```

### The budget is a constraint, and this package does not resolve it

`BudgetBound` is the odd one out, deliberately: it is the only regime that is **not a fact about
the suite**. Shard counts are chosen per repository; hosted runners are budgeted per
**organisation**. Measured on QAtlasHub, two repositories running sixteen shards and eight were
91% of the org's CI on a busy day, at a peak of 27 concurrent jobs between them — so they could
not both run at full width, and the surplus shards of either were queueing behind the other
repository rather than adding parallelism.

The knee is a property of your suite; the budget is a limit on your account. **Which of the two
should give way is a decision about your repository**, and it has a different answer depending
on whether that repository is the one you care about finishing first. So `usable_shards` does
not quietly take the smaller of the two: it answers under the regime it is given, both are
askable, and the report states both numbers.

Nothing inside a test run can observe an account's limit, so unlike everything else here it has
to be told: `concurrency-budget` in the workflow, `budget` in [`TestShards.diagnose`](@ref).
Left unset, the diagnosis behaves exactly as before and claims nothing about it.

This is a type rather than a paragraph because **the same numbers mean opposite things at
different scales**. A 49 s per-shard cost and a 130 s start window are fatal to a 150 s suite
and a rounding error on a 40-minute one. Deciding which case you are in is a fact about your
repository, and every consumer working it out again by hand is how the wrong one gets acted on.

## Precompiling once instead of once per shard

Every shard precompiles the package under test for itself, and the depot cache cannot prevent
it: the package changes with every commit while its dependencies do not, and the test step runs
under `--check-bounds=yes` and `--code-coverage`, which is a **different precompile
configuration** from the one `julia-buildpkg` produced. Measured on QAtlas.jl, that is ~219 s
inside *every one* of sixteen shards — about 3,500 runner-seconds a run for one answer.

`prebuild: true` builds it once, in its own job, and hands the result to the shards. Measured
here, a shard that adopts the shared cache prints no precompile line at all, and adopting it
costs 1.8 s.

**It is a trade, not a win.** The build is serialised in front of the shards, so it buys runner
time and costs some wall clock, and the shards each pay a download. On a suite whose
precompilation is seconds it is a net loss — this package's own is 1–4 s, and turning it on
here costs more than it saves. At QAtlas's numbers it saves ~3,200 runner-seconds a run.

Which side of that you want is a fact about your **account**, not your suite — see the budget
discussion above; runner-seconds spent here are capacity taken from every other repository in
the organisation. So it is off by default, and the numbers to decide it with are in the
diagnosis.

## Sharing the depot cache

All shards instantiate the same project, so they should share one dependency cache, and the
bundled workflow does this: one `cache-name` for the whole matrix, `include-matrix: false`.
A shard that starts after another has finished then restores that shard's depot instead of
building its own, and only one copy is stored per run instead of one per shard.

How much that is worth depends entirely on the dependency tree, and the two ends look nothing
alike. Measured on *this* package — one dependency — precompilation is 3–4 s of a ~49 s fixed
cost, so the cache is nearly free and nearly pointless; what is left is installing Julia,
processing coverage and starting a `Pkg.test` sandbox, none of which a depot cache touches. On a
suite with a real dependency tree it is the other way round: precompilation dominates the fixed
cost, and sharing the cache is the difference between paying it once and paying it once per
shard.

Which of the two you are in is a fact about your repository, not about sharding, and it is
exactly what the measured `fixed` above tells you. Read it before deciding anything costs too
much.
