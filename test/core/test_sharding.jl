using Test, TestShards

# End-to-end properties are exercised in SUBPROCESSES, because `@shard` drives a whole suite
# (including deliberate failures) and running that inline would fold its results into this one.

"Build a suite; returns its directory."
function suite(; extra="")
    d = mktempdir()
    mkpath(joinpath(d, "core"))
    mkpath(joinpath(d, "gen"))
    mkpath(joinpath(d, "seq"))
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

const PROJ = dirname(Base.active_project())

"Run a suite with `env`; returns (success, stdout, out_dir)."
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

function units(out)
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

@testset "unsharded runs everything — a bare Pkg.test is unchanged" begin
    d = suite()
    ok, log, out = run_suite(d)
    @test ok
    @test units(out) ==
        ["core/a.jl", "core/b.jl", "gen/c.jl", "gen/d.jl", "gen/e.jl", "seq"]
    @test occursin("TestShards: ALL", log)
end

@testset "the shards PARTITION the suite: union is whole, nothing twice" begin
    d = suite()
    _, _, ref = run_suite(d)
    whole = units(ref)
    for n in 2:7
        got = String[]
        for k in 1:n
            _, _, out = run_suite(
                d; env=Dict("TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "$n")
            )
            append!(got, units(out))
        end
        @test sort(got) == whole            # nothing dropped
        @test length(unique(got)) == length(got)   # nothing run twice
    end
end

@testset "history balances: a heavy unit is isolated" begin
    d = suite()
    h = joinpath(d, "h.tsv")
    write(h, "core/a.jl\t1\ncore/b.jl\t1\ngen/c.jl\t30\ngen/d.jl\t1\ngen/e.jl\t1\nseq\t1\n")
    got = Dict{String,Vector{String}}()
    for k in 1:3
        _, _, out = run_suite(
            d;
            env=Dict(
                "TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "3", "TESTSHARDS_TIMINGS" => h
            ),
        )
        got["s$k"] = units(out)
    end
    heavy = only([s for (s, u) in got if "gen/c.jl" in u])
    @test got[heavy] == ["gen/c.jl"]        # the 30s unit gets a shard to itself
    @test length(unique(reduce(vcat, values(got)))) == 6      # still a partition
end

@testset "a unit stays whole and in order — order-dependent files survive" begin
    d = suite()
    for n in 2:5, k in 1:n
        ok, _, out = run_suite(
            d; env=Dict("TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "$n")
        )
        # `seq` depends on 01 running before 02; if @unit leaked, this shard would error.
        @test ok
    end
end

@testset "within a shard, units run in OBSERVED order" begin
    d = suite()
    _, log, _ = run_suite(d; env=Dict("TESTSHARDS_UNITS" => "seq,core/b.jl,core/a.jl"))
    ran = [m.captures[1] for m in eachmatch(r"\[ok\] (\S+)", log)]
    @test ran == ["core/a.jl", "core/b.jl", "seq"]   # source order, not the listed order
end

@testset "a shard id with no slice would run EVERYTHING — that is an error" begin
    d = suite()
    ok, log, _ = run_suite(d; env=Dict("TESTSHARDS_ID" => "s1"))
    @test !ok
end

@testset "a failing unit is recorded, does not abort the shard, and fails the run once" begin
    d = suite(; extra="include(\"bad.jl\")\ninclude(\"core/a.jl\")")
    write(joinpath(d, "bad.jl"), "using Test\n@test false\n")
    ok, log, out = run_suite(d)
    @test !ok                                     # the run fails
    @test occursin("[FAIL] bad.jl", log)
    # ...but everything after it still ran and was recorded — that is why the failure is
    # re-signalled once at the end rather than thrown where it happened.
    @test "bad.jl" in units(out)
    @test occursin("core/a.jl", join(units(out), ","))
end

@testset "records carry the testset tree and its evidence" begin
    d = suite()
    write(
        joinpath(d, "core", "a.jl"),
        """
        using Test, TestShards
        @testset "outer" begin
            evidence!(; tolerance = 1e-12, oracle = "closed form")
            @test true
            @testset "inner" begin; @test true; end
        end
        """,
    )
    _, _, out = run_suite(d)
    line = only(
        filter(
            l -> occursin("\"core/a.jl\"", l),
            readlines(joinpath(out, "records-local.jsonl")),
        ),
    )
    @test occursin("\"name\":\"outer\"", line)
    @test occursin("\"name\":\"inner\"", line)        # nesting preserved
    @test occursin("\"tolerance\":1.0e-12", line)
    @test occursin("\"oracle\":\"closed form\"", line)
    @test occursin("\"index\":1", line)               # position in the full sequence
end
