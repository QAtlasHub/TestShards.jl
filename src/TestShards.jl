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
# When the JOB holding this shard started, as epoch seconds. CI sets it in its first step; the
# Julia process cannot see the checkout, depot restore and precompilation that came before it,
# which is most of what a shard pays. Absent, the shard's window starts when Julia does.
const ENV_JOB_START = "TESTSHARDS_JOB_START"

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
"""
struct ShardWindow
    shard::String
    started::Float64
    finished::Float64
    nunits::Int
    unit_seconds::Float64
end

"How long this shard's job was alive."
window(w::ShardWindow) = w.finished - w.started

"""
The part of a shard's window that no split of the suite can remove: checkout, depot restore,
precompilation, and the sandbox `Pkg.test` builds before the first unit runs.
"""
fixed_cost(w::ShardWindow) = window(w) - w.unit_seconds

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
    # concatenate into the timeline of the run — see [`ShardWindow`](@ref).
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
        )
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
    load_shards(path) -> Vector{ShardWindow}

Read merged `shard-*.tsv` rows (`shard`, started, finished, units, unit seconds). Malformed
rows are ignored, like [`load_timings`](@ref): a diagnosis must never be the thing that fails a
run.
"""
function load_shards(path::AbstractString)
    ws = ShardWindow[]
    (isempty(path) || !isfile(path)) && return ws
    for ln in eachline(path)
        parts = split(rstrip(ln, ['\n', '\r']), '\t')
        length(parts) == 5 || continue
        nums = map(p -> tryparse(Float64, p), parts[2:5])
        any(isnothing, nums) && continue
        push!(
            ws,
            ShardWindow(String(parts[1]), nums[1], nums[2], round(Int, nums[3]), nums[4]),
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
    first_shard::String
    last_shard::String
    windows::Vector{ShardWindow}     # by start time
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
            " shards",
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
        println(io, "| start window | ", round(o.start_window; digits=1), "s |")
    end
    if d.knee < d.n
        println(
            io,
            "\n> `shards: ",
            d.n,
            "` is past the knee. `shards: ",
            d.knee,
            "` finishes at the same wall clock and starts ",
            d.n - d.knee,
            " fewer jobs.",
        )
    end
    # The model says what the SPLIT can deliver; it assumes the shards run at the same time.
    # When they did not, saying so is the whole point — otherwise a run that the queue made
    # slow reads as a suite that is badly balanced, and the wrong thing gets fixed.
    if o !== nothing && o.wall > 1.25 * d.critical_path && o.start_window > 0
        println(
            io,
            "\n> The ",
            o.nshards,
            " shards did not overlap: `",
            o.last_shard,
            "` started ",
            round(o.start_window; digits=1),
            "s after `",
            o.first_shard,
            "`, so the run finished in ",
            round(o.wall; digits=1),
            "s against a predicted ",
            round(d.critical_path; digits=1),
            "s. The wall clock here is set by the queue, not by the split — a better balance ",
            "cannot fix it, and more shards make it worse.",
        )
    end
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

`timings.tsv [sections.tsv [shards.tsv]] [--shards N] [--fixed SECONDS]`, printing the Markdown
report. Used by the CI collect step so every run says where the suite is badly shaped.

The files are positional and in that order, because each one only adds detail to the answer:
the timings alone say how many shards the suite can use, the sections say where to cut the unit
that limits it, and the shard windows say whether the shards actually ran at the same time.
"""
function diagnose_cli(args=ARGS)
    files = String[]
    n, fixed = 8, 0.0
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--shards" && i < length(args)
            n = something(tryparse(Int, args[i + 1]), 8)
            i += 2
        elseif a == "--fixed" && i < length(args)
            fixed = something(tryparse(Float64, args[i + 1]), 0.0)
            i += 2
        else
            push!(files, a)
            i += 1
        end
    end
    isempty(files) && (
        println(
            stderr,
            "usage: timings.tsv [sections.tsv [shards.tsv]] [--shards N] [--fixed S]",
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
    shards = length(files) > 2 ? load_shards(files[3]) : ShardWindow[]
    print(diagnose_report(diagnose(timings; n, fixed, sections, shards)))
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
