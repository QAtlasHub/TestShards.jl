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
