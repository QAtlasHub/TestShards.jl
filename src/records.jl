# ─────────────────────────────────────────────────────────────────────────────────────
# Records — the structure a reporting layer consumes
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    Section

One `@testset`, with its nested sections. `duration` is wall-clock from Julia's own testset
bookkeeping, so it is per-section rather than per-file.
"""
struct Section
    name::String
    duration::Float64
    npass::Int
    nfail::Int
    nerror::Int
    nbroken::Int
    evidence::Dict{String,Any}
    sections::Vector{Section}
end

"""
    UnitRecord

One shardable unit: what ran, where, for how long, and what it established.

`index` is the unit's position in the FULL observed sequence, identical in every shard, so
records merged from separate jobs sort back into source order.
"""
struct UnitRecord
    key::String
    index::Int
    shard::String
    duration::Float64
    npass::Int
    nfail::Int
    nerror::Int
    nbroken::Int
    sections::Vector{Section}
end

"""
    ShardWindow

When one shard ran, in absolute time, and how much of that window it spent on units.

The per-unit durations say how the work divides; they cannot say whether the shards ran *at the
same time*. Under a congested queue they do not, and then the wall clock is set by the last
shard to start rather than by the heaviest bin. This is the record that makes that visible:
merged across shards it gives the start window, the observed wall clock and, by subtraction,
the fixed cost each shard actually paid.

`started` and `finished` are epoch seconds from the runner's own clock, so a spread of a second
or two between shards is noise rather than a queue effect.

The window runs from the job's start — CI reports it through `TESTSHARDS_JOB_START` — to the
moment the test process ends, which is as far as a shard can see: it is not running when its
job finishes. Work the job does *after* the tests — processing coverage, uploading artefacts —
is therefore outside it, and measured here that tail is about half the fixed cost on this suite.

CI closes the gap from outside by stamping the job's end into an `ended-*.tsv` that
[`load_shards`](@ref) folds back in. Without that file `finished` is the process end and
[`fixed_cost`](@ref) is a **lower bound**.
"""
struct ShardWindow
    shard::String
    started::Float64
    finished::Float64
    nunits::Int
    unit_seconds::Float64
    seen::Int                    # units OBSERVED — the same in every shard
end

"How long this shard's job was alive."
window(w::ShardWindow) = w.finished - w.started

"""
The part of a shard's window that no split of the suite can remove: checkout, depot restore,
precompilation, and the sandbox `Pkg.test` builds before the first unit runs.

Exact when CI supplied the job's end (see [`ShardWindow`](@ref) and [`load_ends`](@ref)); a
**lower bound** without it, because the window then stops at the test process rather than at
the job.
"""
fixed_cost(w::ShardWindow) = window(w) - w.unit_seconds

