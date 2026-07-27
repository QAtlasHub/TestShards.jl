using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "a shard id with no slice would run EVERYTHING — that is an error" begin
    d = make_suite()
    ok, _, _ = run_suite(d; env=Dict("TESTSHARDS_ID" => "s1"))
    @test !ok
end
