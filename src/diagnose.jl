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

"Seconds, to one decimal, the way every line of every report wants them."
_s(x) = string(round(x; digits=1), "s")

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
    diagnose(timings; n = 8, fixed = 0.0, sections = Dict(), shards = ShardWindow[],
             budget = 0) -> Diagnosis

Answer three questions the raw numbers do not: how many shards this suite can actually use,
what is stopping it from using more, and where to cut to move that limit.

`fixed` is the per-shard cost that does not shrink with more shards: a shard's job wall clock
minus the time its units took. It is what makes over-sharding expensive rather than merely
useless. **Pass `shards` and it is measured rather than guessed** — each window carries exactly
that subtraction, and their mean becomes `fixed` unless an explicit non-zero `fixed` overrides
it. `shards` also decides whether the model's premise held: see [`Observation`](@ref).

`budget` is how many jobs the ACCOUNT can run at once, which nothing in a test run can observe
and which is not a fact about the suite at all — see [`BudgetBound`](@ref). Left at 0 it
changes nothing and is claimed nothing about.
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

