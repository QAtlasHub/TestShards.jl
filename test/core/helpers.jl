# Shared fixtures, in a module so that several test files can include this without
# redefining each other's helpers in `Main`. That collision is the exact hazard sharding
# exposes — see the README — so this suite must not have it either.
module TSHelpers

using Test
using TestShards

export make_suite, run_suite, unit_keys
export shared_suite, whole_units, partition_check, shard_runs_clean
export bare_context, shard_window, lcov_trace
export StubSet, stub_fold, with_provider

const PROJ = dirname(Base.active_project())

"Build a suite on disk; returns its directory. `extra` is appended inside the @shard block."
function make_suite(; extra="")
    d = mktempdir()
    for sub in ("core", "gen", "seq")
        mkpath(joinpath(d, sub))
    end
    for f in ("a", "b")
        write(
            joinpath(d, "core", "$f.jl"),
            "using Test\n@testset \"$f\" begin; @test true; end\n",
        )
    end
    for f in ("c", "d", "e")
        write(joinpath(d, "gen", "$f.jl"), "using Test\n@test true\n")
    end
    write(joinpath(d, "seq", "01.jl"), "using Test\nglobal SEQ = 7\n@test true\n")
    write(joinpath(d, "seq", "02.jl"), "using Test\n@test SEQ == 7\n")   # order-dependent
    write(
        joinpath(d, "runtests.jl"),
        """
        using TestShards
        TestShards.@shard begin
            include("core/a.jl")
            for f in sort(readdir(joinpath(@__DIR__, "gen"); join=true))
                include(f)                       # computed includes
            end
            include("core/b.jl")
            TestShards.@unit "seq" begin
                include("seq/01.jl")
                include("seq/02.jl")
            end
            $extra
        end
        """,
    )
    return d
end

"""
    run_suite(d; env) -> (ok, log, outdir)

Run a suite in a SUBPROCESS. Inline would fold its results — including deliberate failures —
into the suite doing the testing.
"""
function run_suite(d; env=Dict{String,String}(), keep_stderr=false)
    out = mktempdir()
    e = copy(ENV)
    # Strip the OUTER run's shard variables first. When this suite is itself sharded, the
    # child would otherwise inherit `TESTSHARDS_ID`/`TESTSHARDS_N` from the shard running the
    # test and split the fixture suite too — so a test asserting on an unsharded run would see
    # one eighth of it. Invisible while the suite runs whole; guaranteed once it is sharded.
    for k in collect(keys(e))
        startswith(k, "TESTSHARDS_") && delete!(e, k)
    end
    merge!(e, env)
    e["TESTSHARDS_OUT"] = out
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJ $(joinpath(d, "runtests.jl"))`
    io = IOBuffer()
    # stderr is dropped by default — a deliberately failing fixture dumps a stacktrace and it
    # is noise. Ask for it when the point of the test is WHY the run failed: asserting only
    # that it failed passes for any reason at all, including the wrong one.
    ok = success(
        pipeline(ignorestatus(setenv(cmd, e)); stdout=io, stderr=keep_stderr ? io : devnull)
    )
    return (ok, String(take!(io)), out)
end

"""
The unit keys a run actually executed, read back from its emitted timings.

Matches `timings-*.tsv` specifically, NOT every `.tsv`. `sections-*.tsv` sits beside it and
also carries the unit key in its first column, so a loose glob counts a unit once per section.
"""
function unit_keys(out)
    return sort(
        reduce(
            vcat,
            [
                first.(split.(readlines(f), '\t')) for f in readdir(out; join=true) if
                startswith(basename(f), "timings-") && endswith(f, ".tsv")
            ];
            init=String[],
        ),
    )
end

# ── The partition and atomicity checks, one N per unit ────────────────────────────────
#
# These dominate the suite, and what they cost is subprocesses: one per shard, per N. Holding
# every N in one file made that file the heaviest unit and therefore the floor on how fast any
# split of this suite can finish — which the diagnosis said in as many words. They are one file
# per N now, and the fixture below is built ONCE per shard process so that splitting them does
# not multiply the setup instead.

const _SUITE = Ref{Union{Nothing,String}}(nothing)
const _WHOLE = Ref{Union{Nothing,Vector{String}}}(nothing)

"The fixture suite, built once per process and shared by every N."
function shared_suite()
    _SUITE[] === nothing && (_SUITE[] = make_suite())
    return _SUITE[]
end

"""
Every unit key an UNSHARDED run of the fixture executes — the oracle the partition checks
compare against, so "nothing was dropped" is measured rather than assumed. Computed once per
process; `test_unsharded.jl` is what asserts this run is itself complete.
"""
function whole_units()
    _WHOLE[] === nothing && (_WHOLE[] = unit_keys(run_suite(shared_suite())[3]))
    return _WHOLE[]
end

"Sorted unit keys collected from all `n` shards of the fixture suite."
function partition_check(n::Integer)
    got = String[]
    for k in 1:n
        _, _, out = run_suite(
            shared_suite(); env=Dict("TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "$n")
        )
        append!(got, unit_keys(out))
    end
    return sort(got)
end

"Did shard `k` of `n` finish without error? False means a `@unit` was torn across shards."
function shard_runs_clean(n::Integer, k::Integer)
    ok, _, _ = run_suite(
        shared_suite(); env=Dict("TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "$n")
    )
    return ok
end

# ── Fixtures the tests build directly ─────────────────────────────────────────────────

"""
    bare_context(; shard, nshards, ownership, timings, root) -> TestShards.ShardContext

A context built directly, touching no globals.

`TestShards._begin` is the obvious way to get one and is the wrong way: it installs the context
in `TestShards.CURRENT`, so calling it from inside a `@shard` block — which is where this suite
runs — replaces that block's own context, and every later `include` dies with "not inside a
@shard block". The driver under test is the driver running the test.

Keyword arguments rather than the struct's field order, which changed three times in a day and
took every test that spelled it out with it. Two files had grown their own copy of this.
"""
function bare_context(;
    shard="s1",
    nshards=2,
    ownership=TestShards.Assigned(),
    timings=Dict{String,Float64}(),
    root=mktempdir(),
)
    return TestShards.ShardContext(
        root,
        shard,
        nothing,
        nshards,
        Dict{String,String}(),
        0,
        0,
        0,
        time(),
        ownership,
        timings,
        Tuple{Int,String}[],
        TestShards.UnitRecord[],
        IdDict{Any,Dict{String,Any}}(),
    )
end

"A `ShardWindow` with the parts a test does not care about filled in."
function shard_window(shard, nunits, seen; started=0.0, finished=1.0, unit_seconds=1.0)
    return TestShards.ShardWindow(shard, started, finished, nunits, unit_seconds, seen)
end

"Write a minimal lcov tracefile: `src => Dict(line => hits)`."
function lcov_trace(path, files)
    open(path, "w") do io
        for (src, lines) in files
            println(io, "SF:", src)
            for (n, c) in sort(collect(lines); by=first)
                println(io, "DA:", n, ",", c)
            end
            println(io, "LF:", length(lines))
            println(io, "LH:", count(>(0), values(lines)))
            println(io, "end_of_record")
        end
    end
    return path
end

# ── A foreign testset, for the unit-testset provider seam ─────────────────────────────

"""
Records nothing but its own tally, exactly as an outside tool's testset would, and is
deliberately NOT a `DefaultTestSet`.
"""
mutable struct StubSet <: Test.AbstractTestSet
    description::String
    npass::Int
    nfail::Int
    nerror::Int
    nbroken::Int
    closed::Bool
end
StubSet(desc::AbstractString) = StubSet(String(desc), 0, 0, 0, 0, false)

function Test.record(ts::StubSet, res)
    res isa Test.Pass && (ts.npass += 1)
    res isa Test.Fail && (ts.nfail += 1)
    res isa Test.Error && (ts.nerror += 1)
    res isa Test.Broken && (ts.nbroken += 1)
    return res
end
Test.finish(ts::StubSet) = ts

"The fold a provider supplies: a foreign testset reduced to the counts a record needs."
function stub_fold(ts::StubSet)
    return (;
        name=ts.description,
        duration=0.5,
        npass=ts.npass,
        nfail=ts.nfail,
        nerror=ts.nerror,
        nbroken=ts.nbroken,
    )
end

"""
Register a provider, run `f`, and put the global back whatever happens.

Registration mutates a package global, so a provider left behind would change the testset type
of every later unit in this suite — including in another file, which is precisely the kind of
cross-unit coupling this package exists to make impossible.
"""
function with_provider(f; name="stub", open, close=(_) -> nothing, fold=stub_fold)
    saved = TestShards.UNIT_PROVIDER[]
    TestShards.UNIT_PROVIDER[] = nothing
    try
        TestShards.register_unit_provider!(; name=name, open=open, close=close, fold=fold)
        return f()
    finally
        TestShards.UNIT_PROVIDER[] = saved
    end
end

end # module TSHelpers
