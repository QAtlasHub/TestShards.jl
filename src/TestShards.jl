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

# ─────────────────────────────────────────────────────────────────────────────────────
# Ownership — how a shard decides a unit is its to run
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    Ownership

How a shard decides whether a unit is its to run: [`Assigned`](@ref) or [`Claimed`](@ref).

The two are answers to different questions, and which one is right depends on something no
suite can know about itself — whether the runners start together. [`Observation`](@ref)
measures that, and [`QueueBound`](@ref) is the diagnosis that says [`Claimed`](@ref) is worth
its cost here.
"""
abstract type Ownership end

"""
    Assigned <: Ownership

Ownership by computation: every shard packs the same timing history the same way, so a unit
belongs to exactly one shard and no shard has to ask anyone.

That determinism is the package's central guarantee — and, under a congested queue, precisely
what is wrong: a shard that starts five minutes late still owns its share, and everyone else
waits for it. Determinism is what prevents a late runner from taking less.
"""
struct Assigned <: Ownership end

"""
    Claimed <: Ownership

Ownership by claim: a shard sweeps the whole observed sequence and runs whatever nobody has
taken yet. A shard that starts late claims what is left; if nothing is left it exits, having
wasted only its own startup instead of delaying everyone.

The primitive is **creating a git ref**, which is an atomic compare-and-swap on the server:
`POST /repos/:repo/git/refs` creates it or returns 422 because someone else already did. No
external service and no new secret — `contents: write` is already granted for the timing
history.

`git push` was the obvious implementation and is the wrong one: every shard would push the same
commit, so a push to an existing ref pointing at that same commit is a no-op that SUCCEEDS, and
every shard would believe it had won. Creating a ref fails whatever the sha is.

It buys work stealing at the price of one round trip per unit, and it introduces a failure mode
static assignment does not have: a shard that claims a unit and then dies leaves a hole. That
is why [`completeness`](@ref) is not optional — a run that silently skips a unit is exactly the
green-but-wrong outcome this package refuses everywhere else.

`min_seconds` keeps cheap units on [`Assigned`](@ref): below it, a round trip costs more than
the unit does. Mixing is safe — static assignment is total over the units it covers, so every
unit is still owned exactly once.
"""
struct Claimed <: Ownership
    api::String                  # base URL, so a test can point it somewhere it controls
    repo::String                 # "owner/name"
    namespace::String            # refs/<namespace>/<index>; per run, so runs cannot collide
    sha::String                  # any object the ref may point at; only its existence matters
    token::String
    min_seconds::Float64
    attempts::Int
    timeout::Float64             # seconds per attempt; a claim that never answers is a hang
end

"""
    _ownership(env) -> Ownership

[`Claimed`](@ref) when `TESTSHARDS_CLAIM` is set AND everything it needs is there, otherwise
[`Assigned`](@ref).

Asking for claiming without the means is an ERROR, not a downgrade. Falling back quietly would
turn "the token was not passed" into "the shards ran what they were assigned", which is a
working run with the wrong strategy — and the whole point of the input is to compare the two.
"""
function _ownership(env)
    wanted = lowercase(strip(get(env, ENV_CLAIM, "")))
    wanted in ("", "0", "false", "no") && return Assigned()
    c = Claimed(
        rstrip(get(env, ENV_CLAIM_API, "https://api.github.com"), '/'),
        get(env, ENV_CLAIM_REPO, get(env, "GITHUB_REPOSITORY", "")),
        get(env, ENV_CLAIM_NS, "tsclaim/" * get(env, "GITHUB_RUN_ID", "local")),
        get(env, ENV_CLAIM_SHA, get(env, "GITHUB_SHA", "")),
        get(env, ENV_CLAIM_TOKEN, get(env, "GITHUB_TOKEN", "")),
        something(tryparse(Float64, get(env, ENV_CLAIM_MIN, "")), 0.0),
        3,
        something(tryparse(Float64, get(env, ENV_CLAIM_TIMEOUT, "")), 30.0),
    )
    missing_bits = String[]
    isempty(c.repo) && push!(missing_bits, ENV_CLAIM_REPO)
    isempty(c.token) && push!(missing_bits, ENV_CLAIM_TOKEN)
    isempty(c.sha) && push!(missing_bits, ENV_CLAIM_SHA)
    isempty(missing_bits) || error(
        "$ENV_CLAIM is set but $(join(missing_bits, ", ")) is not. Claiming cannot fall back " *
        "to assignment quietly: that would run the suite with the strategy you did not ask " *
        "for and report it as a success.",
    )
    return c
end

"""
    _claim(c::Claimed, index) -> Bool

Try to become the owner of `index`. `true` iff this process created the ref.

201 is a win and 422 is a loss — both are answers. Anything else is the network or the token,
which is NOT an answer: it is retried, and if it never answers the shard errors rather than
guessing. Guessing "no" silently drops a unit; guessing "yes" runs it twice.
"""
function _claim(c::Claimed, index::Integer)
    url = "$(c.api)/repos/$(c.repo)/git/refs"
    body = "{\"ref\":$(_jstr("refs/$(c.namespace)/$(index)")),\"sha\":$(_jstr(c.sha))}"
    headers = [
        "Authorization" => "Bearer $(c.token)",
        "Accept" => "application/vnd.github+json",
        "Content-Type" => "application/json",
    ]
    last = ""
    for attempt in 1:(c.attempts)
        response = try
            Downloads.request(
                url;
                method="POST",
                headers=headers,
                input=IOBuffer(body),
                output=devnull,
                # A claim that never answers must not hang the shard. Without this the request
                # can block until the job's own limit hours later, which is strictly worse than
                # failing: a shard stuck here holds its runner and reports nothing at all.
                timeout=c.timeout,
                throw=false,
            )
        catch err                                   # DNS, TLS, connection refused
            last = sprint(showerror, err)
            nothing
        end
        if response isa Downloads.Response
            response.status == 201 && return true       # created it: ours
            response.status == 422 && return false      # already exists: someone else's
            last = "HTTP $(response.status)"
            # 401/403 will not improve by trying again, and reads as "everything is claimed".
            response.status in (401, 403, 404) && break
        elseif response !== nothing
            last = string(response)
        end
        attempt < c.attempts && sleep(0.5 * attempt)
    end
    return error(
        "TestShards: could not claim unit $(index) ($(last)). Refusing to continue: a shard " *
        "that cannot claim cannot tell an unclaimed unit from someone else's, and either " *
        "answer it invents is wrong — a dropped unit or a duplicated one.",
    )
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Shard context
# ─────────────────────────────────────────────────────────────────────────────────────

mutable struct ShardContext
    root::String
    shard::String                       # this shard's label; "" when unsharded
    units::Union{Nothing,Set{String}}   # manual mode: exactly these keys
    nshards::Int                        # auto mode
    assignment::Dict{String,String}     # auto mode: known keys → shard, from the history
    seen::Int                           # units observed so far (owned or not)
    unknown::Int                        # units observed that the history did not know
    depth::Int                          # >0 while inside a @unit
    started::Float64                    # epoch seconds; the job's start when CI reported one
    ownership::Ownership                # assigned by computation, or claimed at run time
    timings::Dict{String,Float64}       # the history, kept for the claim threshold
    ran::Vector{Tuple{Int,String}}      # (index, key) of what this shard actually ran
    records::Vector{UnitRecord}
    evidence::IdDict{Any,Dict{String,Any}}   # testset object → evidence attached to it
end

# Tests run single-threaded inside one process, and `@shard` blocks do not nest, so one
# current context is enough. Concurrent `@shard` blocks are not supported.
const CURRENT = Ref{Union{Nothing,ShardContext}}(nothing)

"""
    current() -> Union{Nothing,ShardContext}

The `@shard` block currently executing, or `nothing` outside one.
"""
current() = CURRENT[]

_ctx() = (c=CURRENT[]; c === nothing ? error("TestShards: not inside a @shard block") : c)

# ─────────────────────────────────────────────────────────────────────────────────────
# Timing history and assignment
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    load_timings(path) -> Dict{String,Float64}

Read a `"key\\tseconds"` TSV. A missing file or a malformed row is IGNORED: the timing plane is
advisory, and a truncated history must degrade the balance, never abort the run.
"""
function load_timings(path::AbstractString)
    t = Dict{String,Float64}()
    (isempty(path) || !isfile(path)) && return t
    for ln in eachline(path)
        parts = split(strip(ln), '\t')
        length(parts) == 2 || continue
        v = tryparse(Float64, parts[2])
        v === nothing && continue
        t[String(parts[1])] = v
    end
    return t
end

"""
    assign(timings, n) -> Dict{String,String}

Longest-processing-time bin packing of the KNOWN units: heaviest first into the least-loaded
shard. Computed identically in every shard from the same history, so no coordination is needed
and no unit can land in two shards.

Units absent from the history are not here; they are assigned on sight, round-robin over the
order they are observed in (see [`_owns`](@ref)), which is also identical everywhere.
"""
function assign(timings::AbstractDict, n::Integer)
    a = Dict{String,String}()
    n >= 1 || throw(ArgumentError("TestShards.assign: n must be ≥ 1, got $n"))
    loads = zeros(Float64, n)
    for k in sort(collect(keys(timings)); by=k -> (-timings[k], k))   # ties broken by name
        b = argmin(loads)
        a[String(k)] = "s$(b)"
        loads[b] += timings[k]
    end
    return a
end

"""
    _owns(ctx, key) -> Bool

Does this shard run `key`? Manual mode consults the explicit list. Auto mode consults the
history-derived assignment, and falls back to round-robin over the *unknown* units in
observation order — so a test file added since the last recorded run is still guaranteed to
land in exactly one shard.
"""
function _owns(ctx::ShardContext, key::AbstractString, index::Integer)
    # An explicit list wins outright: naming units IS the request to run exactly those, with or
    # without a shard label. The label then only tags this shard's output files.
    ctx.units === nothing || return key in ctx.units          # manual
    isempty(ctx.shard) && return true                        # unsharded: everything
    return _owns(ctx.ownership, ctx, key, index)
end

"The historical assignment, and round-robin over what the history has not seen."
function _owns(::Assigned, ctx::ShardContext, key::AbstractString, ::Integer)
    haskey(ctx.assignment, key) && return ctx.assignment[key] == ctx.shard
    ctx.unknown += 1
    return "s$((ctx.unknown - 1) % ctx.nshards + 1)" == ctx.shard
end

"""
Take it if nobody else has. Cheap units are left to [`Assigned`](@ref): below the threshold a
round trip costs more than running the unit would, and mixing is safe because static assignment
is total over the units it still covers.
"""
function _owns(c::Claimed, ctx::ShardContext, key::AbstractString, index::Integer)
    get(ctx.timings, key, Inf) < c.min_seconds && return _owns(Assigned(), ctx, key, index)
    return _claim(c, index)
end

# ─────────────────────────────────────────────────────────────────────────────────────
# The testset a unit runs in
# ─────────────────────────────────────────────────────────────────────────────────────
#
# A unit runs inside a testset this package builds by hand rather than through `@testset`, so
# that a FAILED unit can still be read back (a top-level `@testset` throws before returning its
# tree). The type of that testset is therefore ours to choose — and another tool that captures a
# suite through `Test`'s own interface needs it to be THEIRS. Pinax, for one, renders a suite as
# a document: its `PinaxTestSet` recovers `got`/`want`/`tol` from each assertion, and it only
# sees a suite whose testsets are of its type. With a `DefaultTestSet` here, such a tool records
# nothing at all — and, being a tool that reports on tests, it reports that silently.
#
# So the type is a registered choice. A provider supplies three operations:
#
#   open(key)  -> an AbstractTestSet, or `nothing` to decline this unit (use the default)
#   close(ts)  -> nothing; run after the testset is popped, for a tool that attaches a finished
#                 set to its parent there (`Test.finish` does exactly that)
#   fold(ts)   -> the counts + structure, as PLAIN DATA (see `unit_fold`)
#
# `open` returning `nothing` is what keeps this inert: a provider decides per unit whether its
# capture is actually running, so merely having the tool installed changes nothing.

"""
Named operations for building and reading the testset a unit runs in — see
[`register_unit_provider!`](@ref). `nothing` when no tool has registered, which is the default
and is the case in every run that does not load one.
"""
const UNIT_PROVIDER = Ref{Any}(nothing)

"""
    register_unit_provider!(; name, open, close = _noop, fold)

Register the testset a unit runs in. Called from a package extension's `__init__` — an assignment
rather than a method override, so nothing is overwritten at precompile time.

  - `open(key::String)` returns the `AbstractTestSet` for a unit, or **`nothing`** to decline it
    and leave the default in place. Decline unless the tool's capture is actually running: a
    suite that merely depends on the tool must not have its testset type changed underneath it.
  - `close(ts)` runs after the testset is popped. A tool that attaches a finished testset to its
    parent does it here (`Test.finish`), which is the only moment at which it can.
  - `fold(ts)` returns the counts and structure as plain data — see [`unit_fold`](@ref). This is
    what keeps the balancing history and the completeness verdict correct when the testset is not
    ours, and it is the first thing to test: the same suite must yield the same numbers whichever
    testset type ran it.

Only one provider can be registered: two tools cannot both own the type of one testset, and
letting the last one win would surface as a mysteriously empty report rather than as an error.
"""
function register_unit_provider!(; name::AbstractString, open, close=_noop_close, fold)
    p = UNIT_PROVIDER[]
    if p !== nothing && p.name != name
        error("TestShards: a unit-testset provider is already registered ($(p.name)); \
               $(name) cannot also own the type of a unit's testset")
    end
    UNIT_PROVIDER[] = (; name=String(name), open, close, fold)
    return nothing
end

_noop_close(_) = nothing

# The testset for a unit: the provider's, if one is registered and wants this unit.
function _unit_testset(key::AbstractString)
    p = UNIT_PROVIDER[]
    p === nothing && return Test.DefaultTestSet(key)
    ts = p.open(String(key))
    return ts === nothing ? Test.DefaultTestSet(key) : ts
end

_unit_close(ts::Test.DefaultTestSet) = nothing
function _unit_close(ts)
    p = UNIT_PROVIDER[]
    return p === nothing ? nothing : p.close(ts)
end

"""
    unit_fold(ctx, ts) -> Section

The unit's [`Section`](@ref) tree. A `DefaultTestSet` is read directly; any other testset type
goes through the registered provider's `fold`, which returns plain data —

    (; name, duration, npass, nfail, nerror, nbroken, sections)

with `sections` a vector of the same shape (`duration` in seconds; the fields may be omitted and
default to zero). Plain data rather than a `Section`, so a provider living in another package
does not have to name this package's types.
"""
unit_fold(ctx::ShardContext, ts::Test.DefaultTestSet) = _section(ctx, ts)
function unit_fold(ctx::ShardContext, ts)
    p = UNIT_PROVIDER[]
    p === nothing && error(
        "TestShards: a unit ran in a $(typeof(ts)) with no provider registered to read it",
    )
    return _section_from(ctx, ts, p.fold(ts))
end

# Plain data -> Section. `evidence!` keys its dictionary on the testset OBJECT, so evidence
# recorded under a foreign testset is still found here; a provider's nested data carries no
# object to look up, so nested evidence is attached only at the unit's own level for now.
function _section_from(ctx::ShardContext, ts, d)
    kids = Section[_section_from(ctx, nothing, s) for s in get(d, :sections, ())]
    return Section(
        String(get(d, :name, "")),
        Float64(get(d, :duration, 0.0)),
        Int(get(d, :npass, 0)),
        Int(get(d, :nfail, 0)),
        Int(get(d, :nerror, 0)),
        Int(get(d, :nbroken, 0)),
        ts === nothing ? Dict{String,Any}() : get(ctx.evidence, ts, Dict{String,Any}()),
        kids,
    )
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Capturing a testset tree
# ─────────────────────────────────────────────────────────────────────────────────────

_duration(ts) =
    try
        te = ts.time_end
        te === nothing ? 0.0 : Float64(te - ts.time_start)
    catch
        0.0
    end

function _section(ctx::ShardContext, ts::Test.DefaultTestSet)
    npass = nfail = nerror = nbroken = 0
    kids = Section[]
    for r in ts.results
        if r isa Test.DefaultTestSet
            s = _section(ctx, r)
            push!(kids, s)
            npass += s.npass
            nfail += s.nfail
            nerror += s.nerror
            nbroken += s.nbroken
        elseif r isa Test.Pass
            npass += 1
        elseif r isa Test.Fail
            nfail += 1
        elseif r isa Test.Error
            nerror += 1
        elseif r isa Test.Broken
            nbroken += 1
        end
    end
    npass += ts.n_passed          # passes recorded directly on this testset
    ev = get(ctx.evidence, ts, Dict{String,Any}())
    return Section(ts.description, _duration(ts), npass, nfail, nerror, nbroken, ev, kids)
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Running a unit
# ─────────────────────────────────────────────────────────────────────────────────────

function _key(ctx::ShardContext, path::AbstractString)
    return replace(relpath(abspath(path), ctx.root), '\\' => '/')
end

"""
    _run(ctx, key, body)

Observe a unit, and run `body` if this shard owns it. The observation counter advances either
way — that is what keeps `index`, and the round-robin fallback, identical across shards.

The testset is pushed and popped by hand rather than via `@testset` so that the tree can be
read back even when the unit failed: a top-level `@testset` throws before returning its result.
Failure is re-signalled once, at the end of the whole block.
"""
function _run(ctx::ShardContext, key::AbstractString, body)
    ctx.seen += 1
    index = ctx.seen
    _owns(ctx, key, index) || return nothing
    push!(ctx.ran, (index, String(key)))

    ts = _unit_testset(key)
    Test.push_testset(ts)
    t0 = time()
    try
        body()
    catch err
        # An error escaping the unit (a load error, say) is recorded as the unit's error rather
        # than aborting the shard, so the remaining units still run and still get recorded.
        Test.record(
            ts,
            Test.Error(
                :nontest_error, Expr(:tuple), err, Base.catch_stack(), LineNumberNode(0)
            ),
        )
    finally
        Test.pop_testset()
    end
    # A tool that attaches a finished testset to its parent can only do it now that the parent is
    # current again — which is the whole reason a hand-popped testset needs this second step.
    _unit_close(ts)
    dt = time() - t0
    sec = unit_fold(ctx, ts)
    push!(
        ctx.records,
        UnitRecord(
            key,
            index,
            ctx.shard,
            dt,
            sec.npass,
            sec.nfail,
            sec.nerror,
            sec.nbroken,
            sec.sections,
        ),
    )
    status = sec.nfail + sec.nerror == 0 ? "ok" : "FAIL"
    println(
        "  [$(status)] $(key)  $(round(dt; digits=2))s  ($(sec.npass) pass, $(sec.nfail) fail, $(sec.nerror) error)",
    )
    return nothing
end

# Paths are resolved against the file that wrote `@shard`, matching what Julia's own `include`
# does inside a script — NOT against `pwd()`, which differs between a local run and `Pkg.test`.
function _resolve(ctx::ShardContext, path)
    return isabspath(path) ? String(path) : joinpath(ctx.root, String(path))
end

"Include a file as part of the current unit, without opening a new one."
_plain_include(path) = Base.include(Main, _resolve(_ctx(), path))

# The `include` seen inside a `@shard` block: each call is its own unit, unless we are already
# inside a `@unit`, in which case it is part of that one.
function _include(path)
    ctx = _ctx()
    ctx.depth > 0 && return Base.include(Main, _resolve(ctx, path))
    file = _resolve(ctx, path)
    return _run(ctx, _key(ctx, file), () -> Base.include(Main, file))
end

function _run_unit(name::AbstractString, body)
    ctx = _ctx()
    if ctx.depth > 0                     # nested @unit: already inside a unit, just run it
        return body()
    end
    ctx.depth += 1
    try
        _run(ctx, String(name), body)
    finally
        ctx.depth -= 1
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Evidence
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    evidence!(; kwargs...)

Attach evidence to the `@testset` currently running — what was checked, to what tolerance, on
what grounds — so the report can state it without a reader going to the source:

```julia
@testset "inflation preserves the tiling" begin
    err = norm(inflate(t) - reference)
    evidence!(; tolerance = 1e-12, achieved = err, oracle = "closed-form inflation matrix")
    @test err < 1e-12
end
```

Values that are not `Real`, `Bool`, or `AbstractString` are stored as their `string()` form, so
anything is safe to pass. Outside a `@shard` block this is a no-op, which keeps a test file
runnable on its own.
"""
function evidence!(; kwargs...)
    ctx = CURRENT[]
    ctx === nothing && return nothing
    ts = try
        Test.get_testset()
    catch
        return nothing
    end
    d = get!(ctx.evidence, ts, Dict{String,Any}())
    for (k, v) in kwargs
        d[String(k)] = v isa Union{Real,Bool,AbstractString} ? v : string(v)
    end
    return nothing
end

"""
    evidence(ts) -> Dict{String,Any}

What [`evidence!`](@ref) recorded against a testset — or an empty dictionary when it recorded nothing.

It is keyed on the testset **object**, so it works whichever type that testset is, including one a
[`register_unit_provider!`](@ref) provider handed out. That is the point of exposing it: a provider
whose tool renders a suite can put what a test *established* into its output, beside whether the test
passed, and it does not have to reach into this package's internals to do so.

The evidence for a whole subtree is reachable by walking the testset's own children — a provider's
type knows its nesting, and this reads one node at a time.
"""
function evidence(ts)
    ctx = CURRENT[]
    ctx === nothing && return Dict{String,Any}()
    return get(ctx.evidence, ts, Dict{String,Any}())
end

# ─────────────────────────────────────────────────────────────────────────────────────
# The block
# ─────────────────────────────────────────────────────────────────────────────────────

function _begin(root::AbstractString; env=ENV)
    # Installing a second context would replace the first one's, and the first block would then
    # fail on its next `include` with "not inside a @shard block" — a long way from the cause.
    # `@shard` blocks do not nest, and the way this happens in practice is a test that wants a
    # context and reaches for `_begin` to get one, inside the suite the driver is running.
    CURRENT[] === nothing || error(
        "TestShards: a @shard block is already running. Blocks do not nest, and a second " *
        "`_begin` would silently take the first one's place.",
    )
    units_spec = get(env, ENV_UNITS, "")
    units = if isempty(units_spec)
        nothing
    else
        Set(String(strip(x)) for x in split(units_spec, ",") if !isempty(strip(x)))
    end
    shard = get(env, ENV_ID, "")
    n = something(tryparse(Int, get(env, ENV_N, "")), 1)

    if !isempty(shard) && units === nothing && n <= 1
        error(
            "$ENV_ID is set but neither $ENV_UNITS (manual) nor $ENV_N > 1 (auto) is — every " *
            "shard would run the WHOLE suite and pass for the wrong reason. Fix the workflow.",
        )
    end
    timings = load_timings(get(env, ENV_TIMINGS, ""))
    ownership = _ownership(env)
    # A job start reported by CI wins: it includes the checkout, the depot restore and the
    # precompilation, which are the bulk of what a shard pays and are invisible from in here.
    # A malformed value falls back rather than failing — this is measurement, not correctness.
    job_start = something(tryparse(Float64, get(env, ENV_JOB_START, "")), time())
    ctx = ShardContext(
        abspath(root),
        shard,
        units,
        n,
        units === nothing ? assign(timings, n) : Dict{String,String}(),
        0,
        0,
        0,
        job_start,
        ownership,
        timings,
        Tuple{Int,String}[],
        UnitRecord[],
        IdDict{Any,Dict{String,Any}}(),
    )
    mode = if units !== nothing
        "manual ($(length(units)) units)"
    elseif isempty(shard)
        "ALL"
    else
        "auto $(shard)/$(n) ($(length(timings)) timed)"
    end
    println("TestShards: $mode")
    CURRENT[] = ctx
    return ctx
end

function _end(ctx::ShardContext; env=ENV)
    CURRENT[] = nothing
    out = get(env, ENV_OUT, "")
    isempty(out) || write_records(ctx, out)

    npass = sum(r -> r.npass, ctx.records; init=0)
    nfail = sum(r -> r.nfail, ctx.records; init=0)
    nerror = sum(r -> r.nerror, ctx.records; init=0)
    println(
        "TestShards: $(length(ctx.records))/$(ctx.seen) units ran — " *
        "$(npass) pass, $(nfail) fail, $(nerror) error",
    )
    # Failure is signalled ONCE, here, because the per-unit testsets were driven by hand
    # precisely so that a failure would not abort the shard before everything was recorded.
    nfail + nerror == 0 || error(
        "TestShards: $(nfail) failed and $(nerror) errored across $(length(ctx.records)) units",
    )
    return nothing
end

"""
    @shard begin ... end

Run the block with `include` shadowed, so each include is a shardable unit. See the module
docstring for the whole picture.

The test root — what unit keys are relative to — is the directory of the file this macro is
written in, so keys are stable no matter where CI runs from.
"""
macro shard(body)
    root = abspath(dirname(String(__source__.file)))
    return esc(quote
        local __ts_ctx = $(_begin)($root)
        try
            let include = $(_include)
                $body
            end
        finally
            $(_end)(__ts_ctx)
        end
    end)
end

"""
    @unit "name" begin ... end

Treat everything in the block as ONE shardable unit: it runs in a single shard, in the order
written. This is the only way to keep order-dependent files together, since across shards order
is not preserved.

It is also the manual-mode handle: in manual mode a shard is given unit names to run, so naming
a unit is how you assign work by hand rather than by measured time.
"""
macro unit(name, body)
    return esc(quote
        $(_run_unit)($name, () -> let include = $(_plain_include)
            $body
        end)
    end)
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Serialisation — minimal JSON, no dependency (the planner installs this package cold)
# ─────────────────────────────────────────────────────────────────────────────────────

function _jstr(s)
    return '"' *
           replace(
               String(s),
               '\\' => "\\\\",
               '"' => "\\\"",
               '\n' => "\\n",
               '\r' => "\\r",
               '\t' => "\\t",
           ) *
           '"'
end

_jval(v::Bool) = v ? "true" : "false"
_jval(v::Integer) = string(v)
_jval(v::Real) = isfinite(v) ? string(Float64(v)) : _jstr(string(v))
_jval(v::AbstractString) = _jstr(v)
_jval(v) = _jstr(string(v))

function _jobj(io, pairs)
    print(io, "{")
    for (i, (k, v)) in enumerate(pairs)
        i == 1 || print(io, ",")
        print(io, _jstr(k), ":", v)
    end
    return print(io, "}")
end

function _jsection(io, s::Section)
    ev = sprint(
        io2 -> _jobj(io2, [k => _jval(v) for (k, v) in sort(collect(s.evidence); by=first)])
    )
    kids = sprint() do io2
        print(io2, "[")
        for (i, c) in enumerate(s.sections)
            i == 1 || print(io2, ",")
            _jsection(io2, c)
        end
        return print(io2, "]")
    end
    return _jobj(
        io,
        [
            "name" => _jval(s.name),
            "duration" => _jval(s.duration),
            "npass" => _jval(s.npass),
            "nfail" => _jval(s.nfail),
            "nerror" => _jval(s.nerror),
            "nbroken" => _jval(s.nbroken),
            "evidence" => ev,
            "sections" => kids,
        ],
    )
end

"""
    write_records(ctx, dir)

Write this shard's records as JSONL (one unit per line) plus its timings as TSV.

Two files because they have different consumers and different lifetimes: the TSV is the
planner's history and is merged into a single ledger, while the JSONL is the report's input and
is merged into one ordered document. Both key on the same unit key, so they always agree.
"""
function write_records(ctx::ShardContext, dir::AbstractString)
    mkpath(dir)
    tag = isempty(ctx.shard) ? "local" : ctx.shard
    open(joinpath(dir, "records-$(tag).jsonl"), "w") do io
        for r in ctx.records
            secs = sprint() do io2
                print(io2, "[")
                for (i, s) in enumerate(r.sections)
                    i == 1 || print(io2, ",")
                    _jsection(io2, s)
                end
                return print(io2, "]")
            end
            _jobj(
                io,
                [
                    "key" => _jval(r.key),
                    "index" => _jval(r.index),
                    "shard" => _jval(r.shard),
                    "duration" => _jval(r.duration),
                    "npass" => _jval(r.npass),
                    "nfail" => _jval(r.nfail),
                    "nerror" => _jval(r.nerror),
                    "nbroken" => _jval(r.nbroken),
                    "sections" => secs,
                ],
            )
            println(io)
        end
    end
    open(joinpath(dir, "timings-$(tag).tsv"), "w") do io
        for r in ctx.records
            println(io, r.key, '\t', round(r.duration; digits=3))
        end
    end
    # When this shard ran, as opposed to for how long. One row, so the shards' files
    # concatenate into the timeline of the run — see [`ShardWindow`](@ref). The last column is
    # how many units this shard OBSERVED, identical in every shard, and it is what
    # [`completeness`](@ref) measures the run against.
    open(joinpath(dir, "shard-$(tag).tsv"), "w") do io
        return println(
            io,
            tag,
            '\t',
            round(ctx.started; digits=3),
            '\t',
            round(time(); digits=3),
            '\t',
            length(ctx.records),
            '\t',
            round(sum(r -> r.duration, ctx.records; init=0.0); digits=3),
            '\t',
            ctx.seen,
        )
    end
    # WHICH positions in the observed sequence this shard took. Under `Claimed` ownership
    # nothing can derive that from the assignment, because there is no assignment: the only
    # record that a unit ran at all is the shard that ran it saying so.
    open(joinpath(dir, "ran-$(tag).tsv"), "w") do io
        for (index, key) in ctx.ran
            println(io, index, '\t', tag, '\t', key)
        end
    end
    # A flat view of the same tree, `unit <TAB> section path <TAB> seconds`. The planner never
    # reads this — it exists so [`diagnose`](@ref) can say WHERE inside a heavy unit to cut,
    # without anything downstream having to parse JSON.
    open(joinpath(dir, "sections-$(tag).tsv"), "w") do io
        for r in ctx.records
            _write_sections(io, r.key, "", r.sections)
        end
    end
    println("TestShards: wrote $(length(ctx.records)) records → $dir")
    return nothing
end

function _write_sections(io, key, prefix, sections)
    for s in sections
        path = isempty(prefix) ? s.name : string(prefix, " / ", s.name)
        println(io, key, '\t', path, '\t', round(s.duration; digits=3))
        _write_sections(io, key, path, s.sections)
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Completeness — did the run cover the suite, or only look like it did
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    Completeness

Whether the shards between them ran every unit they observed, exactly once.

Under [`Assigned`](@ref) this is a theorem: assignment is a total function of the observed
sequence, so a unit no shard claims cannot exist. Under [`Claimed`](@ref) it is not — a shard
that claims a unit and then dies or is cancelled leaves the unit claimed and never run, and the
merged records are short by one with nothing to say so. That is the green-but-wrong outcome
this package refuses everywhere else, which is why claiming does not ship without this check.

It is worth running under both. It costs nothing, and it turns the guarantee from something the
design argues into something each run demonstrates.
"""
struct Completeness
    observed::Int                       # units the shards saw, agreed across shards
    ran::Vector{Int}                    # positions that ran, sorted
    missed::Vector{Int}                 # observed but never run — a hole
    duplicated::Vector{Int}             # run by more than one shard
    disagreed::Bool                     # shards reported different observation counts
    placement::Dict{Int,Vector{String}} # position → the shards that ran it
end

function complete(c::Completeness)
    return isempty(c.missed) && isempty(c.duplicated) && !c.disagreed && c.observed > 0
end

"""
    load_ran(path) -> Vector{Tuple{Int,String,String}}

Read merged `ran-*.tsv` rows: position, shard, unit key. Malformed rows are skipped — but note
that a row skipped here reads as a MISSING unit downstream, which fails the run rather than
passing it quietly. That is the safe direction for this particular file.
"""
function load_ran(path::AbstractString)
    rows = Tuple{Int,String,String}[]
    (isempty(path) || !isfile(path)) && return rows
    for ln in eachline(path)
        parts = split(rstrip(ln, ['\n', '\r']), '\t')
        length(parts) == 3 || continue
        i = tryparse(Int, parts[1])
        i === nothing && continue
        push!(rows, (i, String(parts[2]), String(parts[3])))
    end
    return rows
end

"""
    completeness(windows, ran) -> Completeness

Check the run against itself: every shard reports how many units it OBSERVED, and each reports
which positions it took. The two must reconcile.
"""
function completeness(
    windows::AbstractVector{ShardWindow}, ran::AbstractVector{<:Tuple{Int,String,String}}
)
    seens = unique(w.seen for w in windows)
    observed = isempty(seens) ? 0 : maximum(seens)
    placement = Dict{Int,Vector{String}}()
    for (i, shard, _) in ran
        push!(get!(placement, i, String[]), shard)
    end
    positions = sort(collect(keys(placement)))
    return Completeness(
        observed,
        positions,
        [i for i in 1:observed if !haskey(placement, i)],
        [i for i in positions if length(placement[i]) > 1],
        length(seens) > 1,
        placement,
    )
end

"""
    completeness_report(c) -> String

The check as Markdown, naming what is missing rather than only that something is.
"""
function completeness_report(c::Completeness)
    io = IOBuffer()
    ok = complete(c)
    println(io, "### Completeness\n")
    println(io, "| | |\n|---|--:|")
    println(io, "| units observed | ", c.observed, " |")
    println(io, "| units run | ", length(c.ran), " |")
    println(io, "| verdict | ", ok ? "**every unit ran exactly once**" : "**FAILED**", " |")
    if c.disagreed
        println(
            io,
            "\n> The shards did not agree on how many units the suite has. They did not all ",
            "observe the same sequence, so nothing downstream — the split, the indices, the ",
            "merged records — means what it claims to.",
        )
    end
    if !isempty(c.missed)
        println(
            io,
            "\n> **",
            length(c.missed),
            " unit(s) never ran**: position(s) ",
            join(c.missed, ", "),
            ". Under claimed ownership this is what a shard dying after it claimed work looks ",
            "like — the run is green and the suite was not tested.",
        )
    end
    if !isempty(c.duplicated)
        println(
            io,
            "\n> **",
            length(c.duplicated),
            " unit(s) ran twice**: ",
            join(("$(i) on " * join(c.placement[i], " and ") for i in c.duplicated), "; "),
            ". Wasted rather than wrong, but it means two shards both believed they owned it.",
        )
    end
    return String(take!(io))
end

"""
    completeness_cli(args = ARGS) -> Int

`shards.tsv ran.tsv` — 0 if the run covered its suite, 1 if it did not. The CI gate calls this,
which is the only reason claiming is safe to offer at all.
"""
function completeness_cli(args=ARGS)
    length(args) >= 2 ||
        (println(stderr, "usage: completeness shards.tsv ran.tsv"); return 1)
    c = completeness(load_shards(args[1]), load_ran(args[2]))
    print(completeness_report(c))
    if c.observed == 0
        println(
            stderr,
            "TestShards: no shard reported how many units it observed — cannot verify the run.",
        )
        return 1
    end
    return complete(c) ? 0 : 1
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Coverage — one report out of N shards
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    LcovFile

One source file's coverage, merged across the shards that reported it.

`branches` maps `(line, block, branch)` to the number of times it was taken, or `nothing` for
lcov's `-`: reached by no shard at all.
"""
struct LcovFile
    source::String
    lines::Dict{Int,Int}                                       # line → hits
    functions::Dict{String,Tuple{Int,Int}}                     # name → (line, hits)
    branches::Dict{NTuple{3,String},Union{Int,Nothing}}
end

function LcovFile(source::AbstractString)
    return LcovFile(
        String(source),
        Dict{Int,Int}(),
        Dict{String,Tuple{Int,Int}}(),
        Dict{NTuple{3,String},Union{Int,Nothing}}(),
    )
end

"`(lines, hits)` for one file, or summed over several."
function line_totals(f::LcovFile)
    return (length(f.lines), count(>(0), values(f.lines)))
end

function line_totals(fs::AbstractVector{LcovFile})
    t = map(line_totals, fs)
    return (sum(first, t; init=0), sum(last, t; init=0))
end

"""
    restore_counters(parts, dest = ".") -> Vector{String}

Put every shard's raw coverage counters back where their sources are, tagged so they cannot
collide. Returns the paths written.

Julia writes `Foo.jl.<pid>.cov` beside `Foo.jl`, and CoverageTools finds them by globbing
`Foo.jl.*.cov`. Shards run on different machines, so their PIDs can be equal — `s1` and `s4`
both producing `TestShards.jl.1234.cov` would have one silently overwrite the other, and the
lost shard's coverage would simply not appear. The shard label goes into the name to prevent
that, in the glob's wildcard where CoverageTools still matches it.

`parts` is the artifact download directory: one subdirectory per shard, named
`...coverage-<shard>`, each holding the counter files under their original relative paths.

This exists in the package rather than in the workflow because it is the step where coverage
can go missing without anything failing — and the last thing to hold that job silently reported
54.5% for a suite that covered 94.8% for as long as it existed.
"""
function restore_counters(parts::AbstractString, dest::AbstractString=".")
    written = String[]
    isdir(parts) || return written
    for entry in sort(readdir(parts; join=true))
        isdir(entry) || continue
        shard = _counter_shard(basename(entry))
        isempty(shard) && continue
        for (root, _, files) in walkdir(entry)
            for f in files
                endswith(f, ".cov") || continue
                rel = relpath(joinpath(root, f), entry)
                out = joinpath(dest, _tag_counter(rel, shard))
                mkpath(dirname(out))
                cp(joinpath(root, f), out; force=true)
                push!(written, out)
            end
        end
    end
    return written
end

"`testshards-coverage-s3` → `s3`; anything else → `\"\"`."
function _counter_shard(dir::AbstractString)
    i = findlast("coverage-", dir)
    i === nothing && return ""
    return String(dir[(last(i) + 1):end])
end

"`src/Foo.jl.123.cov` → `src/Foo.jl.123-s3.cov`, which `Foo.jl.*.cov` still matches."
function _tag_counter(rel::AbstractString, shard::AbstractString)
    return string(chop(rel; tail=length(".cov")), "-", shard, ".cov")
end

"""
    merge_lcov(paths) -> Vector{LcovFile}

Merge lcov tracefiles into **one record per source file**, in the order the files were first
seen.

Merging is a UNION, and that is the whole subtlety. Every shard loads the whole package but
runs only part of the suite, so each report marks only the lines *that* shard executed; a line
missed by seven shards and hit by the eighth is covered. Concatenating the tracefiles instead
leaves N records for one source file, which reads as N times the line count against a fraction
of the hits: this repository's own CI reported **54.5%** that way against a true **94.8%**, and
Codecov rejected the report outright.

Line hits, function hits and branch counts are summed per key; `LF`/`LH` and the rest are
recomputed by [`write_lcov`](@ref) rather than trusted from the inputs.

Malformed lines are skipped rather than raising. Coverage is a byproduct of the run, so a
truncated report must degrade the number, never fail the suite that produced it.
"""
function merge_lcov(paths)
    order = String[]
    seen = Dict{String,LcovFile}()
    for path in paths
        isfile(path) || continue
        cur = nothing
        for raw in eachline(path)
            ln = strip(raw)
            if startswith(ln, "SF:")
                src = String(ln[4:end])
                cur = get!(seen, src) do
                    push!(order, src)
                    return LcovFile(src)
                end
            elseif cur === nothing || ln == "end_of_record"
                cur = nothing
            elseif startswith(ln, "DA:")
                n, c = _lcov_pair(ln[4:end])
                # BOTH halves must parse. A row we cannot read is not evidence that the line
                # exists and went uncovered — recording it that way inflates LF and pushes the
                # percentage down, which is the failure direction that gets believed.
                (n === nothing || c === nothing) && continue
                cur.lines[n] = get(cur.lines, n, 0) + c
            elseif startswith(ln, "FN:")
                n, name = _lcov_split(ln[4:end])
                n === nothing && continue
                # FN gives the definition line; the count arrives separately as FNDA.
                _, hits = get(cur.functions, name, (n, 0))
                cur.functions[name] = (n, hits)
            elseif startswith(ln, "FNDA:")
                c, name = _lcov_split(ln[6:end])
                c === nothing && continue
                line, hits = get(cur.functions, name, (0, 0))
                cur.functions[name] = (line, hits + c)
            elseif startswith(ln, "BRDA:")
                p = split(ln[6:end], ',')
                length(p) == 4 || continue
                key = (String(p[1]), String(p[2]), String(p[3]))
                taken = tryparse(Int, p[4])
                prev = get(cur.branches, key, missing)
                if taken !== nothing
                    # A number from any shard supersedes "-", which only says that THAT shard
                    # never reached the branch.
                    base = (prev === missing || prev === nothing) ? 0 : prev
                    cur.branches[key] = base + taken
                elseif prev === missing
                    cur.branches[key] = nothing
                end
            end
        end
    end
    return [seen[s] for s in order]
end

# Split on the FIRST comma only: lcov function names may contain commas, line numbers may not.
function _split1(s)
    i = findfirst(==(','), s)
    i === nothing && return (String(s), false, "")
    return (String(s[1:prevind(s, i)]), true, String(s[nextind(s, i):end]))
end

# `"12,3"` → (12, 3); either side unparseable → nothing in that slot.
function _lcov_pair(s)
    a, _, b = _split1(s)
    return (tryparse(Int, a), tryparse(Int, b))
end

# `"12,name"` → (12, "name"); no comma → (nothing, "").
function _lcov_split(s)
    a, found, b = _split1(s)
    found || return (nothing, "")
    return (tryparse(Int, a), b)
end

"""
    write_lcov(path, files)

Write merged [`LcovFile`](@ref)s back out as a tracefile, recomputing every summary line
(`LF`/`LH`, `FNF`/`FNH`, `BRF`/`BRH`) from the merged records so they cannot disagree with them.
"""
function write_lcov(path::AbstractString, files::AbstractVector{LcovFile})
    open(path, "w") do io
        for f in files
            println(io, "SF:", f.source)
            fns = sort(collect(f.functions); by=kv -> (last(kv)[1], first(kv)))
            for (name, (line, _)) in fns
                println(io, "FN:", line, ",", name)
            end
            for (name, (_, hits)) in sort(fns; by=first)
                println(io, "FNDA:", hits, ",", name)
            end
            if !isempty(fns)
                println(io, "FNF:", length(fns))
                println(io, "FNH:", count(kv -> last(kv)[2] > 0, fns))
            end
            brs = sort(
                collect(f.branches);
                by=kv -> (something(tryparse(Int, first(kv)[1]), 0), first(kv)),
            )
            for (key, taken) in brs
                println(
                    io,
                    "BRDA:",
                    key[1],
                    ",",
                    key[2],
                    ",",
                    key[3],
                    ",",
                    taken === nothing ? "-" : taken,
                )
            end
            if !isempty(brs)
                println(io, "BRF:", length(brs))
                println(io, "BRH:", count(kv -> last(kv) !== nothing && last(kv) > 0, brs))
            end
            nlines, nhits = line_totals(f)
            for (n, c) in sort(collect(f.lines); by=first)
                println(io, "DA:", n, ",", c)
            end
            println(io, "LF:", nlines)
            println(io, "LH:", nhits)
            println(io, "end_of_record")
        end
    end
    return nothing
end

"""
    merge_lcov_cli(args = ARGS) -> Int

`out.info in1.info in2.info ...` — merge and write, printing a Markdown summary.

Used by the CI collect step, which is why this lives in the package at all: as a step script it
was unreachable from `Pkg.test()`, so nothing could catch it reporting 54.5% for a suite that
covered 94.8%.
"""
function merge_lcov_cli(args=ARGS)
    length(args) >= 2 ||
        (println(stderr, "usage: merge_lcov out.info in1.info [in2.info ...]"); return 1)
    out, inputs = args[1], args[2:end]
    files = merge_lcov(inputs)
    if isempty(files)
        println(stderr, "TestShards: no usable coverage in $(length(inputs)) file(s).")
        return 1
    end
    write_lcov(out, files)
    nlines, nhits = line_totals(files)
    println("### Coverage\n")
    println("| | |\n|---|--:|")
    pct = nlines > 0 ? round(100 * nhits / nlines; digits=1) : 0.0
    println("| coverage | ", pct, "% (", nhits, "/", nlines, " lines) |")
    println("| merged from | ", length(inputs), " shard reports |")
    println("| source files | ", length(files), " |")
    return 0
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Diagnosis — read the history back and say where the suite is badly shaped
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    load_sections(path) -> Dict{String,Vector{Pair{String,Float64}}}

Read a `sections-*.tsv` (`unit <TAB> section path <TAB> seconds`) into per-unit section lists.
Malformed rows are ignored, like [`load_timings`](@ref): a diagnosis must never be the thing
that fails a run.
"""
function load_sections(path::AbstractString)
    d = Dict{String,Vector{Pair{String,Float64}}}()
    (isempty(path) || !isfile(path)) && return d
    for ln in eachline(path)
        parts = split(rstrip(ln, ['\n', '\r']), '\t')
        length(parts) == 3 || continue
        v = tryparse(Float64, parts[3])
        v === nothing && continue
        push!(get!(d, String(parts[1]), Pair{String,Float64}[]), String(parts[2]) => v)
    end
    return d
end

"""
    load_ends(path) -> Dict{String,Float64}

Read merged `ended-*.tsv` rows, `shard <TAB> epoch seconds`: when each shard's JOB finished, as
opposed to when its test process did.

A shard cannot record this itself — it is not running any more. CI writes it after the work
that follows the tests, which on this repository is coverage processing and is not small. One
number per shard, so the only format knowledge outside this file is a `printf`.
"""
function load_ends(path::AbstractString)
    ends = Dict{String,Float64}()
    (isempty(path) || !isfile(path)) && return ends
    for ln in eachline(path)
        parts = split(rstrip(ln, ['\n', '\r']), '\t')
        length(parts) == 2 || continue
        v = tryparse(Float64, parts[2])
        v === nothing && continue
        ends[String(parts[1])] = v
    end
    return ends
end

"""
    load_shards(path; ends = "") -> Vector{ShardWindow}

Read merged `shard-*.tsv` rows (`shard`, started, finished, units, unit seconds, observed).
Malformed rows are ignored, like [`load_timings`](@ref): a diagnosis must never be the thing
that fails a run.

`ends` is an optional [`load_ends`](@ref) file, and it fixes a real understatement rather than
adding a nicety. The `finished` a shard can write for itself is when its test PROCESS ended;
everything the job does afterwards — processing coverage, uploading artefacts — is outside it.
Measured here that tail is about half the fixed cost on this suite and about a tenth of it on a
large one, so without `ends` [`fixed_cost`](@ref) is a lower bound, and the
[`FixedCostBound`](@ref) test built on it is biased towards saying no.

A shard present in `ends` gets the later of the two timestamps; one absent keeps its own, so a
partial file degrades the measurement rather than corrupting it.
"""
function load_shards(path::AbstractString; ends="")
    ws = ShardWindow[]
    (isempty(path) || !isfile(path)) && return ws
    stamps = ends isa AbstractDict ? ends : load_ends(ends)
    for ln in eachline(path)
        parts = split(rstrip(ln, ['\n', '\r']), '\t')
        length(parts) == 6 || continue
        nums = map(p -> tryparse(Float64, p), parts[2:6])
        any(isnothing, nums) && continue
        shard = String(parts[1])
        # `max`, not replace: a stamp earlier than the process end would mean the clock moved
        # backwards, and shrinking a window is never the safe direction for a lower bound.
        finished = max(nums[2], get(stamps, shard, -Inf))
        push!(
            ws,
            ShardWindow(
                shard, nums[1], finished, round(Int, nums[3]), nums[4], round(Int, nums[5])
            ),
        )
    end
    sort!(ws; by=w -> (w.started, w.shard))
    return ws
end

"""
    Observation

What the shards of one run actually did in absolute time, as opposed to what the model predicts.

The model behind [`Diagnosis`](@ref) assumes the shards run concurrently. `effective` is the
number of shards that assumption was worth: the work done divided by the wall clock it took. It
equals the shard count only when they truly overlap, and falls towards 1 — or below it, since
each shard re-pays first-use compilation — as the queue spreads them out.
"""
struct Observation
    nshards::Int
    started::Float64                 # epoch: the first shard's start
    finished::Float64                # epoch: the last shard's finish
    wall::Float64                    # finished - started
    start_window::Float64            # last start - first start
    runner_seconds::Float64          # Σ over shards of their window
    unit_seconds::Float64            # Σ over shards of the time their units took
    effective::Float64               # unit_seconds / wall
    fixed::Float64                   # mean over shards of window - unit seconds
    peak::Int                        # most shards alive at once — the runners actually granted
    first_shard::String
    last_shard::String
    windows::Vector{ShardWindow}     # by start time
end

"""
    peak_concurrency(windows) -> Int

The largest number of shards alive at the same instant.

Requesting `N` jobs is not acquiring `N` runners. This counts the ones the scheduler actually
granted at once, which is the ceiling on any parallelism the split could have delivered.
"""
function peak_concurrency(windows::AbstractVector{ShardWindow})
    isempty(windows) && return 0
    # A sweep over the endpoints. Ends are processed before starts at equal times, so a shard
    # that finishes exactly when another begins is not counted as overlapping it.
    events = vcat([(w.started, 1) for w in windows], [(w.finished, -1) for w in windows])
    sort!(events; by=e -> (e[1], e[2]))
    live, peak = 0, 0
    for (_, delta) in events
        live += delta
        peak = max(peak, live)
    end
    return peak
end

"""
    observe(windows) -> Union{Nothing,Observation}

Fold the shards' windows into the run-level figures. `nothing` for an empty list, so a caller
can pass whatever CI collected without checking first.
"""
function observe(windows::AbstractVector{ShardWindow})
    isempty(windows) && return nothing
    ws = sort(collect(windows); by=w -> (w.started, w.shard))
    started, finished = minimum(w.started for w in ws), maximum(w.finished for w in ws)
    wall = finished - started
    unit_seconds = sum(w.unit_seconds for w in ws)
    return Observation(
        length(ws),
        started,
        finished,
        wall,
        maximum(w.started for w in ws) - started,
        sum(window, ws),
        unit_seconds,
        wall > 0 ? unit_seconds / wall : 0.0,
        sum(fixed_cost, ws) / length(ws),
        peak_concurrency(ws),
        first(ws).shard,                 # ws is sorted by start, so these are the first
        last(ws).shard,                  # and the last shard to START, not to finish
        ws,
    )
end

"""
    Diagnosis

What the timing history says about the shape of the suite, rather than about any one run.

`walls` is the predicted wall clock per shard count under the model `wall(N) = fixed +
max_bin(N)`: a shard pays a fixed cost (checkout, depot restore, precompile) that does not
shrink when you add shards, plus the load of its heaviest bin. `knee` is the smallest `N` at
which `walls` stops improving — past it, more shards buy nothing and cost a fixed price each.

The floor is the single heaviest unit: no split of the suite across jobs can finish sooner
than that, so `floor_unit` is the only place where more parallelism can come from.

`observed` is the same run as measured rather than modelled, when the shards reported their
windows. The model's whole premise is that the shards overlap; `observed` is what says whether
they did.
"""
struct Diagnosis
    n::Int
    fixed::Float64
    serial::Float64
    critical_path::Float64
    knee::Int
    floor_unit::String
    floor_time::Float64
    units::Vector{Pair{String,Float64}}          # heaviest first
    walls::Vector{Pair{Int,Float64}}
    split_here::Vector{Pair{String,Float64}}     # sections of the floor unit, heaviest first
    observed::Union{Nothing,Observation}
    budget::Int                                  # concurrent jobs the account can run; 0 = unknown
end

"Load of the heaviest bin when LPT-packing `timings` into `n` shards."
function _max_bin(timings::AbstractDict, n::Integer)
    isempty(timings) && return 0.0
    loads = zeros(Float64, n)
    for k in sort(collect(keys(timings)); by=k -> (-timings[k], k))
        loads[argmin(loads)] += timings[k]
    end
    return maximum(loads)
end

"""
    diagnose(timings; n = 8, fixed = 0.0, sections = Dict(), shards = ShardWindow[]) -> Diagnosis

Answer three questions the raw numbers do not: how many shards this suite can actually use,
what is stopping it from using more, and where to cut to move that limit.

`fixed` is the per-shard cost that does not shrink with more shards: a shard's job wall clock
minus the time its units took. It is what makes over-sharding expensive rather than merely
useless. **Pass `shards` and it is measured rather than guessed** — each window carries exactly
that subtraction, and their mean becomes `fixed` unless an explicit non-zero `fixed` overrides
it. `shards` also decides whether the model's premise held: see [`Observation`](@ref).
"""
function diagnose(
    timings::AbstractDict;
    n::Integer=8,
    fixed::Real=0.0,
    sections::AbstractDict=Dict{String,Vector{Pair{String,Float64}}}(),
    shards::AbstractVector{ShardWindow}=ShardWindow[],
    budget::Integer=0,
)
    isempty(timings) &&
        throw(ArgumentError("TestShards.diagnose: the timing history is empty"))
    observed = observe(shards)
    # A measured fixed cost beats a declared one, but only when nothing was declared: a caller
    # who passes `fixed` is asking what a hypothetical price would do to the curve.
    fixed = fixed > 0 || observed === nothing ? fixed : max(observed.fixed, 0.0)
    units = sort([String(k) => Float64(v) for (k, v) in timings]; by=last, rev=true)
    serial = sum(last, units)
    floor_unit, floor_time = first(units)

    walls = [
        i => Float64(fixed) + _max_bin(timings, i) for i in 1:max(n, 2 * length(units))
    ]
    # The knee is where the curve flattens: the first N whose wall is within 1% of the best
    # achievable. Anything past it pays another `fixed` for no reduction in wall clock.
    best = minimum(last, walls)
    knee = first(first(filter(p -> last(p) <= best * 1.01, walls)))

    secs = sort(get(sections, floor_unit, Pair{String,Float64}[]); by=last, rev=true)
    return Diagnosis(
        Int(n),
        Float64(fixed),
        serial,
        Float64(fixed) + _max_bin(timings, n),
        knee,
        floor_unit,
        floor_time,
        units,
        walls,
        secs,
        observed,
        max(Int(budget), 0),
    )
end

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

Which of the four regimes this suite is in.

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
function bottleneck(d::Diagnosis)
    o = d.observed
    # A quarter of the run spent waiting for the last shard to arrive. Below that, whatever
    # else is wrong, it is not the queue.
    o !== nothing && o.wall > 0 && o.start_window > 0.25 * o.wall && return QueueBound()
    # Second for the same reason the queue is first: asking for more shards than the account
    # runs at once means the surplus queued, and a run whose shards queued says nothing about
    # its own balance. Declared rather than observed, so it only fires when someone said so.
    0 < d.budget < d.n && return BudgetBound()
    d.fixed > _max_bin_at(d, d.n) && return FixedCostBound()
    d.knee <= d.n && return FloorBound()
    return WorkBound()
end

"The heaviest bin at `n`, recovered from the wall curve so the timings need not be kept."
function _max_bin_at(d::Diagnosis, n::Integer)
    return n <= length(d.walls) ? last(d.walls[n]) - d.fixed : d.floor_time
end

"""
    usable_shards(d::Diagnosis) -> Int

How many shards are worth starting, which is not always the knee.

Under [`QueueBound`](@ref) it is the number of runners the scheduler actually granted at once:
requesting more produced jobs that queued rather than parallelism. Otherwise it is the knee.
"""
usable_shards(d::Diagnosis) = usable_shards(bottleneck(d), d)
function usable_shards(::Bottleneck, d::Diagnosis)
    return d.budget > 0 ? min(d.knee, d.budget) : d.knee
end
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
        round(o.start_window; digits=1),
        "s after `",
        o.first_shard,
        "`, and at most ",
        o.peak,
        " ran at once, so the run took ",
        round(o.wall; digits=1),
        "s against a predicted ",
        round(d.critical_path; digits=1),
        "s. The queue set this wall clock, not the split — a better balance cannot move it and ",
        "more shards make it worse. Start `shards: ",
        usable_shards(d),
        "`, or move to a runner pool that can start them together.",
    )
end

function remedy(::FixedCostBound, d::Diagnosis)
    return string(
        "Each shard spends ",
        round(d.fixed; digits=1),
        "s getting ready and ",
        round(_max_bin_at(d, d.n); digits=1),
        "s testing, so `shards: ",
        d.n,
        "` buys ",
        round(d.n * d.fixed; digits=1),
        "s of setup for it. Lower the setup — cache the depot, drop per-shard work that is not ",
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
        round(d.floor_time; digits=1),
        "s) is what is left: no split across jobs finishes sooner than one unit does. Cut it in ",
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

function Base.show(io::IO, ::MIME"text/plain", d::Diagnosis)
    row(label, rest...) = println(io, "  ", rpad(label, 18), rest...)
    println(io, "TestShards diagnosis — ", length(d.units), " units")
    row("serial total", round(d.serial; digits=1), "s")
    d.fixed > 0 && row("fixed per shard", round(d.fixed; digits=1), "s")
    row(
        "predicted at N=$(d.n)",
        round(d.critical_path; digits=1),
        "s wall, ",
        round(d.n * d.fixed + d.serial; digits=1),
        "s runner",
    )
    row("knee", "N=", d.knee, d.knee < d.n ? "  (N=$(d.n) costs more for no gain)" : "")
    d.budget > 0 && row("account budget", d.budget, " concurrent jobs")
    row(
        "floor",
        d.floor_unit,
        "  ",
        round(d.floor_time; digits=1),
        "s — no split finishes sooner than this",
    )
    o = d.observed
    if o !== nothing
        row(
            "observed",
            round(o.wall; digits=1),
            "s wall, ",
            round(o.runner_seconds; digits=1),
            "s runner over ",
            o.nshards,
            " shards (",
            o.peak,
            " at once)",
        )
        row(
            "effective",
            round(o.effective; digits=1),
            "x of ",
            o.nshards,
            " — start window ",
            round(o.start_window; digits=1),
            "s (",
            o.first_shard,
            " first, ",
            o.last_shard,
            " last)",
        )
    end
    row("bottleneck", nameof(typeof(bottleneck(d))), " — use shards: ", usable_shards(d))
    println(io, "\n  heaviest units")
    for (k, v) in first(d.units, min(5, length(d.units)))
        println(io, "    ", rpad(round(v; digits=1), 8), k)
    end
    if !isempty(d.split_here)
        println(io, "\n  inside ", d.floor_unit, " — split at the heaviest section")
        for (name, v) in first(d.split_here, min(4, length(d.split_here)))
            println(io, "    ", rpad(round(v; digits=1), 8), name)
        end
    end
    return nothing
end

"""
    diagnose_report(d) -> String

The diagnosis as Markdown, for a CI job summary.
"""
function diagnose_report(d::Diagnosis)
    io = IOBuffer()
    println(io, "### Shard diagnosis\n")
    println(io, "| | |\n|---|--:|")
    println(io, "| units | ", length(d.units), " |")
    println(io, "| serial total | ", round(d.serial; digits=1), "s |")
    d.fixed > 0 && println(io, "| fixed cost per shard | ", round(d.fixed; digits=1), "s |")
    println(
        io, "| predicted wall at N=", d.n, " | ", round(d.critical_path; digits=1), "s |"
    )
    println(io, "| knee | N=", d.knee, " |")
    d.budget > 0 && println(io, "| account runs at once | ", d.budget, " jobs |")
    println(
        io, "| floor unit | `", d.floor_unit, "` (", round(d.floor_time; digits=1), "s) |"
    )
    o = d.observed
    if o !== nothing
        println(io, "| **observed wall** | **", round(o.wall; digits=1), "s** |")
        println(
            io,
            "| effective parallelism | ",
            round(o.effective; digits=1),
            "x (",
            round(o.unit_seconds; digits=1),
            "s of units in ",
            round(o.wall; digits=1),
            "s) |",
        )
        println(
            io,
            "| start window | ",
            round(o.start_window; digits=1),
            "s (",
            o.peak,
            " of ",
            o.nshards,
            " shards ran at once) |",
        )
    end
    # One sentence, chosen by dispatch on what is actually limiting this suite. The four
    # regimes want opposite actions — split the floor unit, or stop splitting — so leaving the
    # reader to pick from a list of true statements is how the wrong one gets acted on.
    println(io, "\n> **", nameof(typeof(bottleneck(d))), ".** ", remedy(d))
    println(io, "\n<details><summary>Heaviest units</summary>\n")
    println(io, "| unit | seconds | share |\n|---|--:|--:|")
    for (k, v) in first(d.units, min(10, length(d.units)))
        println(
            io,
            "| `",
            k,
            "` | ",
            round(v; digits=1),
            " | ",
            round(100 * v / d.serial; digits=1),
            "% |",
        )
    end
    if !isempty(d.split_here)
        println(io, "\n**Split `", d.floor_unit, "` here to lower the floor:**\n")
        println(io, "| section | seconds |\n|---|--:|")
        for (name, v) in first(d.split_here, min(6, length(d.split_here)))
            println(io, "| ", name, " | ", round(v; digits=1), " |")
        end
    end
    if o !== nothing
        println(io, "\n</details>\n\n<details><summary>When each shard ran</summary>\n")
        println(io, "| shard | started | window | units | on units | fixed |")
        println(io, "|---|--:|--:|--:|--:|--:|")
        for w in o.windows
            println(
                io,
                "| `",
                w.shard,
                "` | +",
                round(w.started - o.started; digits=1),
                "s | ",
                round(window(w); digits=1),
                "s | ",
                w.nunits,
                " | ",
                round(w.unit_seconds; digits=1),
                "s | ",
                round(fixed_cost(w); digits=1),
                "s |",
            )
        end
    end
    println(io, "\n</details>")
    return String(take!(io))
end

"""
    diagnose_cli(args = ARGS) -> Int

`timings.tsv [sections.tsv [shards.tsv]] [--shards N] [--fixed SECONDS] [--ends FILE]
[--budget JOBS]`, printing the Markdown report. Used by the CI collect step so every run says where the suite is badly shaped.

The files are positional and in that order, because each one only adds detail to the answer:
the timings alone say how many shards the suite can use, the sections say where to cut the unit
that limits it, and the shard windows say whether the shards actually ran at the same time.
"""
function diagnose_cli(args=ARGS)
    files = String[]
    n, fixed, ends, budget = 8, 0.0, "", 0
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--shards" && i < length(args)
            n = something(tryparse(Int, args[i + 1]), 8)
            i += 2
        elseif a == "--fixed" && i < length(args)
            fixed = something(tryparse(Float64, args[i + 1]), 0.0)
            i += 2
        elseif a == "--ends" && i < length(args)
            ends = args[i + 1]
            i += 2
        elseif a == "--budget" && i < length(args)
            budget = something(tryparse(Int, args[i + 1]), 0)
            i += 2
        else
            push!(files, a)
            i += 1
        end
    end
    isempty(files) && (
        println(
            stderr,
            "usage: timings.tsv [sections.tsv [shards.tsv]] [--shards N] [--fixed S] [--ends F] " *
            "[--budget J]",
        );
        return 1
    )
    timings = load_timings(files[1])
    if isempty(timings)
        println(stderr, "TestShards: no timing history yet — nothing to diagnose.")
        return 0
    end
    sections = if length(files) > 1
        load_sections(files[2])
    else
        Dict{String,Vector{Pair{String,Float64}}}()
    end
    shards = length(files) > 2 ? load_shards(files[3]; ends) : ShardWindow[]
    print(diagnose_report(diagnose(timings; n, fixed, sections, shards, budget)))
    return 0
end

"""
    matrix_json(n) -> String

The GitHub Actions `matrix: include:` array for `n` shards.

It carries only labels. Which units a shard runs is decided **inside** the shard, from the
timing history, so the planning job never loads the package under test and never needs to know
what the suite contains.
"""
function matrix_json(n::Integer)
    n >= 1 || throw(ArgumentError("TestShards.matrix_json: n must be ≥ 1, got $n"))
    return "[" * join(("{\"sid\":\"s$(b)\"}" for b in 1:n), ",") * "]"
end

end # module TestShards
