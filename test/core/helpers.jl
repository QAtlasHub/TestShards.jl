# Shared fixtures, in a module so that several test files can include this without
# redefining each other's helpers in `Main`. That collision is the exact hazard sharding
# exposes — see the README — so this suite must not have it either.
module TSHelpers

export make_suite, run_suite, unit_keys

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
    merge!(e, env)
    e["TESTSHARDS_OUT"] = out
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$PROJ $(joinpath(d, "runtests.jl"))`
    io = IOBuffer()
    ok = success(pipeline(ignorestatus(setenv(cmd, e)); stdout=io, stderr=devnull))
    return (ok, String(take!(io)), out)
end

"The unit keys a run actually executed, read back from its emitted timings."
function unit_keys(out)
    return sort(
        reduce(
            vcat,
            [
                first.(split.(readlines(f), '\t')) for
                f in readdir(out; join=true) if endswith(f, ".tsv")
            ];
            init=String[],
        ),
    )
end

end # module TSHelpers
