# Shared fixtures, in a module so that several test files can include this without
# redefining each other's helpers in `Main`. That collision is the exact hazard sharding
# exposes — see the README — so this suite must not have it either.
module TSHelpers

export make_suite, run_suite, unit_keys
export shared_suite, whole_units, partition_check, shard_runs_clean

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
function run_suite(d; env=Dict{String,String}())
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
    ok = success(pipeline(ignorestatus(setenv(cmd, e)); stdout=io, stderr=devnull))
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

end # module TSHelpers
