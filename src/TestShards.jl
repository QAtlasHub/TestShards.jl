"""
    TestShards

Split a Julia test suite across CI jobs, balanced by measured per-file runtime.

Three pieces, deliberately separable because they run in different processes:

  * [`universe`](@ref) — the canonical list of test files, with a **completeness guard**:
    a directory holding `test_*.jl` that is not declared fails loudly instead of silently
    running zero tests. This is the part worth having even without sharding.
  * [`plan`](@ref) / [`plan_json`](@ref) — partition that universe into `N` shards and emit
    a GitHub Actions `matrix: include:` array. Runs in the *planning* job, which must NOT
    load the package under test, so nothing here depends on it.
  * [`runtests`](@ref) — inside `Pkg.test`, select this shard's slice from the environment,
    run it, and emit per-file timings for the next run's planner.

The loop is: run → emit timings → store them (a `ci-timings` orphan branch is the usual
place) → next run's planner bin-packs against them. Without a history the planner degrades
to deterministic round-robin, which is correct but not yet balanced.

Nothing here runs tests in parallel *within* a job; that is `ParallelTestRunner.jl` /
`ReTestItems.jl`'s business, and the two compose.
"""
module TestShards

using Test

export Universe,
    universe, filekey, load_timings, plan, plan_json, select, runtests, @runtests

# Canonical environment protocol. One name per concept, all prefixed, so a repo can grep
# for who sets what. A migrating repo changes its workflow and its `runtests.jl` in the same
# commit — they live in the same repository — so no legacy aliases are carried here.
const ENV_FILES = "TESTSHARDS_FILES"      # "core/test_a.jl,core/test_b.jl" — the planner's slice
const ENV_SHARD = "TESTSHARDS_SHARD"      # "k/N" — round-robin fallback, no history needed
const ENV_ONESHOTS = "TESTSHARDS_ONESHOTS" # "1" ⇒ this shard also runs the whole-package checks
const ENV_ID = "TESTSHARDS_ID"            # shard label, e.g. "s3" (names the timing file)
const ENV_EMIT = "TESTSHARDS_EMIT"        # "1" ⇒ write timings for the next planner
const ENV_OUT = "TESTSHARDS_OUT"          # where to write them (see `runtests` on Pkg.test)

# ─────────────────────────────────────────────────────────────────────────────────────
# Universe
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    Universe

The canonical, deterministic test-file list: `dirs` in declared order × files sorted
lexically. Every selection mode picks a SUBSET of `files`, so the union of all shards is
exactly the whole suite, by construction rather than by hope.
"""
struct Universe
    root::String
    dirs::Vector{String}
    files::Vector{Tuple{String,String}}
end

Base.length(u::Universe) = length(u.files)

"""
    filekey(dir, file) -> String

The stable `"dir/file"` key used by the timing history, the planner, and `TESTSHARDS_FILES`.
"""
filekey(d::AbstractString, f::AbstractString) = string(d, f)

_istestfile(f) = startswith(f, "test_") && endswith(f, ".jl")
_slash(d) = endswith(d, "/") ? String(d) : String(d) * "/"

"""
    universe(root; dirs = nothing) -> Universe

Build the canonical universe under `root` (your `test/` directory).

**By default the suite is DISCOVERED**: every directory under `root` holding `test_*.jl` is
included, ordered lexically. Nothing to declare, so nothing can drift — the failure mode
this replaces is a hand-maintained directory list where adding a test directory and
forgetting to register it means it silently runs zero tests, forever, while CI stays green.

Pass `dirs` only when you want to PIN the set (to fix an order, or to keep a directory out).
Then the **completeness guard** runs: a directory holding `test_*.jl` that is not declared
is an error, and so is a declared directory that is missing or empty. The first catches the
silent-zero-tests case; the second catches a rename that left the list pointing at nothing.

`root` itself and `ci/` are always exempt — `runtests.jl` and the one-shot checks live there.
"""
function universe(root::AbstractString; dirs=nothing)
    isdir(root) || error("TestShards.universe: test root does not exist: $(repr(root))")

    discovered = Set{String}()
    for (dir, _, files) in walkdir(root)
        any(_istestfile, files) || continue
        rel = replace(relpath(dir, root), '\\' => '/')
        (rel == "." || rel == "ci" || startswith(rel, "ci/")) && continue
        push!(discovered, rel * "/")
    end

    if dirs === nothing
        declared = sort(collect(discovered))
        isempty(declared) && error(
            "TestShards.universe: found no directory holding test_*.jl under $(repr(root)). " *
            "Test files must be named test_*.jl and live in a subdirectory of test/.",
        )
    else
        declared = [_slash(d) for d in dirs]
        leaked = sort(collect(setdiff(discovered, Set(declared))))
        isempty(leaked) || error(
            "TestShards completeness guard: these directories under $(repr(root)) hold " *
            "test_*.jl files but are not in `dirs`, so they would never run: $(leaked)",
        )
        for d in declared
            p = joinpath(root, d)
            (isdir(p) && any(_istestfile, readdir(p))) || error(
                "TestShards completeness guard: declared directory $(repr(d)) is missing " *
                "or holds no test_*.jl files under $(repr(root)).",
            )
        end
    end

    files = Tuple{String,String}[]
    for d in declared, f in sort(filter(_istestfile, readdir(joinpath(root, d))))
        push!(files, (d, f))
    end
    return Universe(String(root), declared, files)
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Timing history
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    load_timings(path) -> Dict{String,Float64}

Read a `"key\\tseconds"` TSV. A missing file, or a malformed row, is IGNORED rather than
raised: the timing plane is advisory, and planning must degrade to round-robin, never abort
CI because a history file got truncated.
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

# ─────────────────────────────────────────────────────────────────────────────────────
# Planning
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    Shard

One CI job's slice: `files` (universe keys), whether it also carries the one-shot
whole-package checks, and the estimated seconds the planner packed it to.
"""
struct Shard
    sid::String
    files::Vector{String}
    oneshots::Bool
    est::Float64
end

"""
    plan(u::Universe, n::Integer; timings = Dict()) -> Vector{Shard}

Partition `u` into at most `n` shards.

With a timing history: **longest-processing-time** bin packing — take the slowest file
first, put it in the least-loaded bin. A file with no history is estimated at the **P90** of
the known times, deliberately pessimistic so a new, surprisingly heavy test is isolated
rather than piled onto an already-full shard.

Without one: deterministic round-robin. Correct, just not yet balanced.

`n` is a REQUEST, not a promise. Empty bins are dropped, so a suite with fewer files than
`n` yields `length(u)` shards instead of shards that run nothing. The one-shot checks go to
the bin that finishes EARLIEST, keeping them off the critical path.
"""
function plan(u::Universe, n::Integer; timings::AbstractDict=Dict{String,Float64}())
    n >= 1 || throw(ArgumentError("TestShards.plan: n must be ≥ 1, got $n"))
    isempty(u.files) && throw(ArgumentError("TestShards.plan: the universe is empty"))
    keys_ = [filekey(d, f) for (d, f) in u.files]

    default_t = if isempty(timings)
        1.0
    else
        s = sort(collect(values(timings)))
        s[clamp(ceil(Int, 0.9 * length(s)), 1, length(s))]
    end
    est(k) = Float64(get(timings, k, default_t))

    bins = [String[] for _ in 1:n]
    loads = zeros(Float64, n)
    if isempty(timings)
        for (i, k) in enumerate(keys_)
            b = ((i - 1) % n) + 1
            push!(bins[b], k)
            loads[b] += est(k)
        end
    else
        for k in sort(keys_; by=est, rev=true)
            b = argmin(loads)
            push!(bins[b], k)
            loads[b] += est(k)
        end
    end

    keep = [b for b in 1:n if !isempty(bins[b])]
    bins, loads = bins[keep], loads[keep]
    aqua_bin = argmin(loads)
    return [Shard("s$(b)", bins[b], b == aqua_bin, loads[b]) for b in eachindex(bins)]
end

_json_escape(s) = replace(String(s), '\\' => "\\\\", '"' => "\\\"")

"""
    plan_json(shards) -> String

Serialise a plan as the `matrix: include:` array GitHub Actions consumes:

```json
[{"sid":"s1","files":"core/test_a.jl,core/test_b.jl","oneshots":"1"}, …]
```

Print this — and ONLY this — on stdout; diagnostics belong on stderr, or they corrupt the
matrix.
"""
function plan_json(shards::AbstractVector{Shard})
    io = IOBuffer()
    print(io, "[")
    for (i, s) in enumerate(shards)
        i == 1 || print(io, ",")
        print(io, "{\"sid\":\"", _json_escape(s.sid), "\",")
        print(io, "\"files\":\"", _json_escape(join(s.files, ",")), "\",")
        print(io, "\"oneshots\":\"", s.oneshots ? "1" : "0", "\"}")
    end
    print(io, "]")
    return String(take!(io))
end

plan_json(u::Universe, n::Integer; kwargs...) = plan_json(plan(u, n; kwargs...))

"""
    main(args = ARGS; root = "test", dirs = nothing) -> Int

Planner entry point: takes `N [timings.tsv]`, prints the matrix JSON on stdout and a human
summary on stderr, and returns a process exit code.

This is meant to be called **without any file in the repository being planned** — the
workflow installs TestShards into a temporary environment and calls this, so a consumer repo
carries no `ci/` scripts at all:

```
julia -e 'using Pkg; Pkg.activate(;temp=true); Pkg.add("TestShards");
          using TestShards; exit(TestShards.main())' 8 timings.tsv
```
"""
function main(args=ARGS; root="test", dirs=nothing)
    n = tryparse(Int, get(args, 1, ""))
    (n === nothing || n < 1) &&
        (println(stderr, "usage: plan_shards.jl <N> [timings.tsv]"); return 1)
    timings = load_timings(get(args, 2, ""))
    u = universe(root; dirs)
    shards = plan(u, n; timings)
    mode = isempty(timings) ? "round-robin (no timing history)" : "LPT bin-packing"
    println(
        stderr,
        "TestShards: N=$n → $(length(shards)) shards  mode=$mode  files=$(length(u))",
    )
    for s in shards
        println(
            stderr,
            "  $(s.sid): $(length(s.files)) files  est=$(round(s.est; digits=1))s" *
            (s.oneshots ? "  +one-shots" : ""),
        )
    end
    println(plan_json(shards))
    return 0
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Selection (inside Pkg.test)
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    select(u::Universe; env = ENV) -> (files, description, oneshots)

Resolve this process's slice, in precedence order:

  1. `TESTSHARDS_FILES` — the planner's explicit list. Every entry must be in the universe;
     one that is not is an error, because it means the planner and the suite disagree about
     what exists.
  2. `TESTSHARDS_SHARD="k/N"` — round-robin, history-free.
  3. neither — the whole suite. This is what a bare `Pkg.test()` does, so sharding never
     changes what "run the tests" means locally.

If `TESTSHARDS_ID` is set but no slice is given, that is an ERROR rather than a full run:
it means a workflow wired the shard id but not its selection, and every shard would silently
run everything — slow, and green for the wrong reason.
"""
function select(u::Universe; env=ENV)
    files_spec = get(env, ENV_FILES, "")
    shard_spec = get(env, ENV_SHARD, "")

    if !isempty(files_spec)
        want = [strip(x) for x in split(files_spec, ",") if !isempty(strip(x))]
        idx = Dict(filekey(d, f) => (d, f) for (d, f) in u.files)
        sel = Tuple{String,String}[]
        unknown = String[]
        for w in want
            haskey(idx, w) ? push!(sel, idx[w]) : push!(unknown, String(w))
        end
        isempty(unknown) || error(
            "$ENV_FILES names files outside the canonical universe — the planner and the " *
            "suite disagree about what exists: $(unknown)",
        )
        return (sel, "FILES (n=$(length(sel)))", get(env, ENV_ONESHOTS, "0") == "1")
    end

    if !isempty(shard_spec)
        parts = split(shard_spec, "/")
        length(parts) == 2 || error("$ENV_SHARD must be \"k/N\"; got $(repr(shard_spec))")
        k = tryparse(Int, strip(parts[1]))
        n = tryparse(Int, strip(parts[2]))
        (k === nothing || n === nothing) &&
            error("$ENV_SHARD must be integer \"k/N\"; got $(repr(shard_spec))")
        (1 <= k <= n) || error("$ENV_SHARD needs 1 ≤ k ≤ N; got $k/$n")
        n <= length(u) || error(
            "$ENV_SHARD N=$n exceeds the $(length(u))-file suite; shards " *
            "$(length(u) + 1)..$n would run zero tests — lower N.",
        )
        sel = [tf for (i, tf) in enumerate(u.files) if ((i - 1) % n) + 1 == k]
        return (sel, "SHARD $k/$n", k == 1)
    end

    isempty(get(env, ENV_ID, "")) || error(
        "$ENV_ID is set but neither $ENV_FILES nor $ENV_SHARD is — every shard would run " *
        "the WHOLE suite and pass for the wrong reason. Fix the workflow that sets these.",
    )
    return (u.files, "ALL", true)
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Driver
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    runtests(u::Universe; oneshots = String[], label = "tests", env = ENV)

Run this shard's slice and, when `TESTSHARDS_EMIT=1`, write per-file timings for the next
planner.

`oneshots` are whole-package checks (Aqua, a citation check, …) given as paths relative to
`u.root`. They are NOT shardable units — they run exactly once per plan, in whichever shard
the planner marked, so they never land on the critical path.

**Where the timings go.** `Pkg.test` copies the suite into a sandbox, so `@__DIR__` points
somewhere `upload-artifact` will never look. Set `TESTSHARDS_OUT` to a path inside the
workspace (`\${{ github.workspace }}/test/.ci-out`); it is inherited into the sandbox.
"""
function runtests(u::Universe; oneshots=String[], label="tests", env=ENV)
    sel, desc, run_oneshots = select(u; env)
    println(
        "TestShards: $desc → $(length(sel))/$(length(u)) files; one-shots=$(run_oneshots)"
    )

    emit = get(env, ENV_EMIT, "0") == "1"
    out = get(env, ENV_OUT, joinpath(u.root, ".ci-out"))
    sid = get(env, ENV_ID, "local")
    emit && mkpath(out)

    timings = Tuple{String,Float64}[]
    # The emit lives in `finally` on purpose: a top-level `@testset` THROWS when anything
    # inside it failed, so writing afterwards would silently skip exactly the runs whose
    # timings you still want — a red shard's files took however long they took, and the next
    # planner should keep packing against that rather than fall back to a stale estimate.
    try
        @testset "$label" begin
            for (d, f) in sel
                path = joinpath(u.root, d, f)
                @testset "$f" begin
                    t = @elapsed Base.include(Main, path)
                    println("  [time] $(filekey(d, f)): $(round(t; digits=2))s")
                    push!(timings, (filekey(d, f), t))
                end
            end
            if run_oneshots
                for o in oneshots
                    @testset "$o" begin
                        Base.include(Main, joinpath(u.root, o))
                    end
                end
            end
        end
    finally
        if emit
            open(joinpath(out, "timings-$(sid).tsv"), "w") do io
                for (k, t) in timings
                    println(io, k, '\t', round(t; digits=3))
                end
            end
            println("TestShards: emitted $(length(timings)) rows → $out/timings-$(sid).tsv")
        end
    end
    return nothing
end

"""
    runtests(root::AbstractString; dirs = nothing, oneshots = String[], label = "tests")

Discover the universe under `root` and run this shard's slice. The one-argument form most
suites want; see [`universe`](@ref) for when to pin `dirs`.
"""
function runtests(root::AbstractString; dirs=nothing, kwargs...)
    return runtests(universe(root; dirs); kwargs...)
end

"""
    @runtests [kwargs...]

Zero-ceremony form for `test/runtests.jl` — resolves the test root from the calling file, so
a whole sharded suite is two lines:

```julia
using MyPackage, TestShards
TestShards.@runtests oneshots = ["test_aqua.jl"]
```

Locally, a bare `Pkg.test()` sets none of the environment variables and therefore runs
everything, exactly as it did before. Sharding is additive; it never changes what "run the
tests" means on your machine.
"""
macro runtests(kwargs...)
    # The root comes from `__source__` — the CALL SITE's file — not from `@__DIR__`, which
    # expands where the macro is DEFINED and would resolve to this package's own `src/`.
    root = abspath(dirname(String(__source__.file)))
    return esc(:($runtests($root; $(kwargs...))))
end

end # module TestShards
