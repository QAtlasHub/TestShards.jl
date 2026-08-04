# ─────────────────────────────────────────────────────────────────────────────────────
# What is limiting this suite — as a type, not as a paragraph
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    Bottleneck

What is setting this run's wall clock. One of [`QueueBound`](@ref), [`FixedCostBound`](@ref),
[`FloorBound`](@ref) or [`WorkBound`](@ref).

The same numbers mean opposite things at different scales, and that is the whole reason this is
a type rather than a sentence in the manual. A 150s suite with a 49s per-shard cost and a 130s
start window is being destroyed by both; a 40-minute suite with the identical figures is barely
inconvenienced. A reader can work that out from the raw numbers — but then every consumer
repository has to work it out again, and the ones that get it wrong get it wrong silently. So
[`bottleneck`](@ref) decides, and [`remedy`](@ref) and [`usable_shards`](@ref) dispatch on the
answer.
"""
abstract type Bottleneck end

"""
    QueueBound <: Bottleneck

The shards did not run at the same time, so the wall clock is set by the last one to start.
Nothing about the split can fix this — see [`Observation`](@ref).
"""
struct QueueBound <: Bottleneck end

"""
    FixedCostBound <: Bottleneck

A shard spends longer getting ready than testing. Splitting further multiplies the setup and
buys almost nothing; the cost itself has to come down.
"""
struct FixedCostBound <: Bottleneck end

"""
    FloorBound <: Bottleneck

The heaviest single unit is what is left. No split across jobs beats it, so it has to be cut in
two — `split_here` names where.
"""
struct FloorBound <: Bottleneck end

"""
    BudgetBound <: Bottleneck

The split would use more shards than the account can run at once, so the surplus queues behind
the first `budget` of them instead of adding parallelism.

Shard counts are chosen per repository; hosted runners are budgeted per **organisation**. Every
other regime here is a fact about the suite, and this one is not a fact about the suite at all —
it is why a knee of ten is the wrong number to act on when eight jobs is what the account can
actually deliver. Measured on QAtlasHub: two repositories, sixteen shards and eight, 91% of the
org's CI on a busy day, and a peak of 27 concurrent jobs between them.

`budget` has to be told to [`diagnose`](@ref); nothing in a test run can observe it.
"""
struct BudgetBound <: Bottleneck end

"""
    WorkBound <: Bottleneck

Nothing is in the way: the work still divides, and more shards would still make the run finish
sooner. This is the regime the whole design assumes, and the only one in which raising the
shard count is the right move.
"""
struct WorkBound <: Bottleneck end

"""
    bottleneck(d::Diagnosis) -> Bottleneck

Which of the five regimes this suite is in.

They are tested in the order below, because that is the order in which fixing one exposes the
next. A queue-bound run tells you nothing about its balance — the balance was never given a
chance to matter — so there is no point reporting the floor at it.

1. [`QueueBound`](@ref) — the shards spent a large share of the run waiting for the last one to
   START. Needs `shards` to detect; without windows a run cannot know this happened to it.
2. [`FixedCostBound`](@ref) — the per-shard fixed cost exceeds the heaviest bin, i.e. a shard
   spends more of its life getting ready than testing.
3. [`FloorBound`](@ref) — the requested shard count is at or past the knee, so the heaviest
   single unit is what remains.
4. [`WorkBound`](@ref) — otherwise.

[`BudgetBound`](@ref) sits between the first two: it is the only one that is not a fact about
the suite, and like the queue it invalidates what follows, because shards that queued cannot
tell you whether the split was good.

The queue test is **measured, not modelled**, and it used to be the other way round: "the
observed wall clock is well above the predicted one". That reads as a queue problem and is not
one. `critical_path` is built on `fixed`, and `fixed` is a lower bound — the shard windows
close when the test process exits, so per-shard work after the tests is outside them (see
[`ShardWindow`](@ref)). An understated `fixed` understates the prediction, and the gap that
opens gets blamed on the queue. Caught on this package's own CI: eight shards started **2s**
apart and were still called `QueueBound`, on a 16.7s gap the start window could account for at
most 2s of.

So the question is asked directly. If the last shard started 2s after the first, the queue did
not set a 70s wall clock, whatever the model expected.
"""
bottleneck(d::Diagnosis) = first(bottlenecks(d))

"""
    bottlenecks(d::Diagnosis) -> Vector{Bottleneck}

**Every** regime whose condition holds, in the order [`bottleneck`](@ref) tests them.

More than one is usually true. A run can be queue-bound, past its knee, and asking for more
shards than the account runs, all at once — those are three independent facts about it.
[`bottleneck`](@ref) returns the first, and *which one comes first is a policy, not a
measurement*. This is the set it was chosen from.

Nothing here is hidden behind that choice. [`remedy`](@ref) and [`usable_shards`](@ref)
dispatch on any [`Bottleneck`](@ref), so a caller that wants a different rule writes it:

```julia
bs = TestShards.bottlenecks(d)
# "tell me what the SUITE says, whatever the account can supply"
TestShards.usable_shards(TestShards.FloorBound(), d)
# "I care about the account first"
TestShards.BudgetBound() in bs && TestShards.remedy(TestShards.BudgetBound(), d)
```

The default order is defended in [`bottleneck`](@ref). It is a reasonable rule and it is not
the only one, which is why the alternatives stay reachable rather than being resolved away.
"""
function bottlenecks(d::Diagnosis)
    found = Bottleneck[]
    o = d.observed
    # A quarter of the run spent waiting for the last shard to arrive. Below that, whatever
    # else is wrong, it is not the queue.
    o !== nothing &&
        o.wall > 0 &&
        o.start_window > 0.25 * o.wall &&
        push!(found, QueueBound())
    # Declared rather than observed, so it only appears when someone said so.
    0 < d.budget < d.n && push!(found, BudgetBound())
    d.fixed > _max_bin_at(d, d.n) && push!(found, FixedCostBound())
    d.knee <= d.n && push!(found, FloorBound())
    isempty(found) && push!(found, WorkBound())
    return found
end

"The heaviest bin at `n`, recovered from the wall curve so the timings need not be kept."
function _max_bin_at(d::Diagnosis, n::Integer)
    return n <= length(d.walls) ? last(d.walls[n]) - d.fixed : d.floor_time
end

"""
    usable_shards(d::Diagnosis) -> Int

How many shards are worth starting under the regime [`bottleneck`](@ref) selected — which is
not always the knee, and is not always what you want asked.

Under [`QueueBound`](@ref) it is the number of runners the scheduler actually granted at once;
under [`BudgetBound`](@ref) it is the account's limit; otherwise it is the knee.

**It answers one question under one policy.** Call it with a regime to ask a different one —
`usable_shards(FloorBound(), d)` for what the suite could use regardless of what the account
supplies, `usable_shards(BudgetBound(), d)` for the reverse. [`bottlenecks`](@ref) says which
are true at once, and this deliberately does not reconcile them: the budget is a constraint on
the account, the knee is a property of the suite, and which of the two should give way is a
decision about the repository that the diagnosis is in no position to make.
"""
usable_shards(d::Diagnosis) = usable_shards(bottleneck(d), d)
usable_shards(::Bottleneck, d::Diagnosis) = d.knee
usable_shards(::BudgetBound, d::Diagnosis) = d.budget
function usable_shards(::QueueBound, d::Diagnosis)
    o = d.observed
    return o === nothing ? d.knee : clamp(o.peak, 1, d.knee)
end

"""
    remedy(d::Diagnosis) -> String

What to do about it, in one sentence, chosen by dispatch on [`bottleneck`](@ref) rather than
left to the reader.
"""
remedy(d::Diagnosis) = remedy(bottleneck(d), d)

function remedy(::QueueBound, d::Diagnosis)
    o = d.observed
    return string(
        "The ",
        o.nshards,
        " shards did not overlap: `",
        o.last_shard,
        "` started ",
        _s(o.start_window),
        " after `",
        o.first_shard,
        "`, and at most ",
        o.peak,
        " ran at once, so the run took ",
        _s(o.wall),
        " against a predicted ",
        _s(d.critical_path),
        ". The queue set this wall clock, not the split — a better balance cannot move it and ",
        "more shards make it worse. Start `shards: ",
        usable_shards(d),
        "`, or move to a runner pool that can start them together.",
    )
end

function remedy(::FixedCostBound, d::Diagnosis)
    return string(
        "Each shard spends ",
        _s(d.fixed),
        " getting ready and ",
        _s(_max_bin_at(d, d.n)),
        " testing, so `shards: ",
        d.n,
        "` buys ",
        _s(d.n * d.fixed),
        " of setup for it. Lower the setup — cache the depot, drop per-shard work that is not ",
        "tests, build once — or run `shards: ",
        usable_shards(d),
        "`. Splitting further multiplies the cost without touching the wall clock.",
    )
end

function remedy(::FloorBound, d::Diagnosis)
    return string(
        "`shards: ",
        d.n,
        "` is at or past the knee, so `",
        d.floor_unit,
        "` (",
        _s(d.floor_time),
        ") is what is left: no split across jobs finishes sooner than one unit does. Cut it in ",
        "two",
        if isempty(d.split_here)
            ""
        else
            " — its heaviest section is `$(first(first(d.split_here)))`"
        end,
        ", or drop to `shards: ",
        usable_shards(d),
        "` and keep the wall clock you already have.",
    )
end

function remedy(::BudgetBound, d::Diagnosis)
    return string(
        "`shards: ",
        d.n,
        "` asks for more than the ",
        d.budget,
        " concurrent jobs this account runs, so ",
        d.n - d.budget,
        " of them queue behind the rest and add no parallelism — they only add ",
        d.n - d.budget,
        " more fixed costs, and take that capacity from whatever else the organisation is ",
        "running. Use `shards: ",
        usable_shards(d),
        "`, or move this repository to a runner pool with its own budget.",
    )
end

function remedy(::WorkBound, d::Diagnosis)
    return string(
        "The work still divides: the knee is at N=",
        d.knee,
        " and `shards: ",
        d.n,
        "` is below it, so more shards would still make this run finish sooner.",
    )
end

"""
    _facts(d) -> Vector{Pair{String,String}}

The diagnosis as label/value pairs, in report order.

Both renderers walk this. Adding a fact to one of them and forgetting the other is not a
hypothetical: `budget` shipped showing in the plain-text summary under one name and in the
Markdown one under another, and `peak` reached CI in the Markdown only. One list, one set of
names, and a new fact appears in both or in neither.
"""
function _facts(d::Diagnosis)
    o = d.observed
    facts = ["units" => string(length(d.units)), "serial total" => _s(d.serial)]
    d.fixed > 0 && push!(facts, "fixed per shard" => _s(d.fixed))
    push!(
        facts,
        "predicted wall at N=$(d.n)" =>
            _s(d.critical_path) * " wall, " * _s(d.n * d.fixed + d.serial) * " runner",
    )
    push!(
        facts,
        "knee" => "N=$(d.knee)" * (d.knee < d.n ? "  ($(d.n) costs more for no gain)" : ""),
    )
    d.budget > 0 && push!(facts, "account runs at once" => "$(d.budget) jobs")
    push!(
        facts,
        "floor unit" => "$(d.floor_unit)  $(_s(d.floor_time)) — no split finishes sooner than this",
    )
    if o !== nothing
        push!(
            facts,
            "observed wall" =>
                _s(o.wall) *
                " wall, " *
                _s(o.runner_seconds) *
                " runner over $(o.nshards) shards ($(o.peak) at once)",
            "effective parallelism" =>
                string(round(o.effective; digits=1)) *
                "x of $(o.nshards) — " *
                _s(o.unit_seconds) *
                " of units in " *
                _s(o.wall),
            "start window" =>
                _s(o.start_window) * " ($(o.first_shard) first, $(o.last_shard) last)",
        )
    end
    bs = bottlenecks(d)
    also = length(bs) > 1 ? "  (also " * join(nameof.(typeof.(bs[2:end])), ", ") * ")" : ""
    push!(
        facts,
        "bottleneck" => "$(nameof(typeof(first(bs)))) — use shards: $(usable_shards(d))$(also)",
    )
    return facts
end

function Base.show(io::IO, ::MIME"text/plain", d::Diagnosis)
    println(io, "TestShards diagnosis — ", length(d.units), " units")
    for (label, value) in _facts(d)
        label == "units" && continue          # already in the heading
        println(io, "  ", rpad(label, 22), value)
    end
    println(io, "\n  heaviest units")
    for (k, v) in first(d.units, min(5, length(d.units)))
        println(io, "    ", rpad(_s(v), 9), k)
    end
    if !isempty(d.split_here)
        println(io, "\n  inside ", d.floor_unit, " — split at the heaviest section")
        for (name, v) in first(d.split_here, min(4, length(d.split_here)))
            println(io, "    ", rpad(_s(v), 9), name)
        end
    end
    return nothing
end

