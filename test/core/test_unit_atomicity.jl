using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "a @unit stays whole — order-dependent files survive every split" begin
    d = make_suite()
    for n in 2:5, k in 1:n
        # The `seq` unit needs 01 before 02. If @unit leaked across shards, some k would error.
        ok, _, _ = run_suite(d; env=Dict("TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "$n"))
        @test ok
    end
end
