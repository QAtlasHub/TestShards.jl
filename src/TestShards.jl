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
function _owns(ctx::ShardContext, key::AbstractString)
    # An explicit list wins outright: naming units IS the request to run exactly those, with or
    # without a shard label. The label then only tags this shard's output files.
    ctx.units === nothing || return key in ctx.units          # manual
    isempty(ctx.shard) && return true                        # unsharded: everything
    haskey(ctx.assignment, key) && return ctx.assignment[key] == ctx.shard
    ctx.unknown += 1
    return "s$((ctx.unknown - 1) % ctx.nshards + 1)" == ctx.shard
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
    _owns(ctx, key) || return nothing

    ts = Test.DefaultTestSet(key)
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
    dt = time() - t0
    sec = _section(ctx, ts)
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

# ─────────────────────────────────────────────────────────────────────────────────────
# The block
# ─────────────────────────────────────────────────────────────────────────────────────

function _begin(root::AbstractString; env=ENV)
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
    ctx = ShardContext(
        abspath(root),
        shard,
        units,
        n,
        units === nothing ? assign(timings, n) : Dict{String,String}(),
        0,
        0,
        0,
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
    println("TestShards: wrote $(length(ctx.records)) records → $dir")
    return nothing
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
