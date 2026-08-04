"""
    TestShards

Split a Julia test suite across CI jobs, and record what each piece did.

The shardable units are **whatever `runtests.jl` includes** — not files matching a naming
convention, and not a list you maintain. `@shard` shadows `include` inside its block, so every
include call is observed at the moment it happens; a unit computed by a loop over `readdir` is
seen exactly like a literal one.

```julia
using MyPackage, TestShards

TestShards.@shard begin
    include("core/test_a.jl")
    for f in readdir("solver"; join = true)
        include(f)                       # computed includes are units too
    end
    TestShards.@unit "stateful" begin    # one unit: same shard, in this order
        include("stateful/01_setup.jl")
        include("stateful/02_use.jl")
    end
end
```

Two properties make this safe, and both come from every shard observing the *whole* sequence
and skipping what is not its own:

  * **Nothing is silently dropped.** A unit that no shard claims cannot exist — assignment is a
    total function of the observed sequence, computed identically in every shard.
  * **Identity is shard-independent.** A unit is `(key, index)` where `index` is its position in
    the full sequence, so records from different shards merge into one ordered report.

Within a shard, units run in **observed order**. Across shards order is not preserved — that is
what parallelism means — so anything order-dependent belongs in one [`@unit`](@ref).

Each unit's `@testset` tree is captured with its per-testset timings and outcomes, giving a
file → testset hierarchy that a reporting layer can render directly (one page per unit, one
section per testset). Attach evidence to the running testset with [`evidence!`](@ref).

Sharding never changes what a bare `Pkg.test()` means: with no environment set, everything runs.
"""
module TestShards

using Downloads
using Test

export @shard, @unit, evidence!

# Manual mode: an explicit unit list, the way a hand-declared test-group matrix works.
const ENV_UNITS = "TESTSHARDS_UNITS"
# Auto mode: this shard's label and the shard count; assignment is computed locally.
const ENV_ID = "TESTSHARDS_ID"
const ENV_N = "TESTSHARDS_N"
# Timing history driving the automatic balance, and where to write this run's records.
const ENV_TIMINGS = "TESTSHARDS_TIMINGS"
const ENV_OUT = "TESTSHARDS_OUT"
# When the JOB holding this shard started, as epoch seconds. CI sets it in its first step; the
# Julia process cannot see the checkout, depot restore and precompilation that came before it,
# which is most of what a shard pays. Absent, the shard's window starts when Julia does.
const ENV_JOB_START = "TESTSHARDS_JOB_START"
# Work stealing. Set `TESTSHARDS_CLAIM` and a shard stops running what it was assigned and
# starts running whatever is still unclaimed — see [`Claimed`](@ref).
const ENV_CLAIM = "TESTSHARDS_CLAIM"
const ENV_CLAIM_TOKEN = "TESTSHARDS_CLAIM_TOKEN"
const ENV_CLAIM_REPO = "TESTSHARDS_CLAIM_REPO"
const ENV_CLAIM_NS = "TESTSHARDS_CLAIM_NS"
const ENV_CLAIM_SHA = "TESTSHARDS_CLAIM_SHA"
const ENV_CLAIM_MIN = "TESTSHARDS_CLAIM_MIN"
const ENV_CLAIM_API = "TESTSHARDS_CLAIM_API"
const ENV_CLAIM_TIMEOUT = "TESTSHARDS_CLAIM_TIMEOUT"

# ─────────────────────────────────────────────────────────────────────────────────────
# The module, in load order — a file may use anything the files above it define
# ─────────────────────────────────────────────────────────────────────────────────────

include("records.jl")       # what a run writes down: Section, UnitRecord, ShardWindow
include("ownership.jl")     # which units are this shard's, by assignment or by claim
include("provider.jl")      # the testset a unit runs in, and how a tool supplies its own
include("run.jl")           # running a unit, the evidence it leaves, and @shard / @unit
include("json.jl")          # minimal JSON writer — this package installs cold, with no deps
include("completeness.jl")  # did the run cover the suite, or only look like it did
include("coverage.jl")      # one LCOV report out of N shards
include("diagnose.jl")      # read the history back: Observation, Diagnosis
include("bottleneck.jl")    # what limits the suite, as a type, and its remedy
include("report.jl")        # the printed diagnosis, the CLIs, and the shard matrix

end # module TestShards
