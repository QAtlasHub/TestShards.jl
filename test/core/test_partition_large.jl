using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "shards PARTITION the suite (N=5,6,7 — more shards than units)" begin
    d = make_suite()
    whole = unit_keys(run_suite(d)[3])
    for n in 5:7
        got = String[]
        for k in 1:n
            _, _, out = run_suite(
                d; env=Dict("TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "$n")
            )
            append!(got, unit_keys(out))
        end
        @test sort(got) == whole
        @test length(unique(got)) == length(got)
    end
end
