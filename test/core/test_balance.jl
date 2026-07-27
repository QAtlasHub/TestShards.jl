using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "history balances: a heavy unit gets a shard to itself" begin
    d = make_suite()
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
        got["s$k"] = unit_keys(out)
    end
    heavy = only([s for (s, u) in got if "gen/c.jl" in u])
    @test got[heavy] == ["gen/c.jl"]
    @test length(unique(reduce(vcat, values(got)))) == 6      # still a partition
end
