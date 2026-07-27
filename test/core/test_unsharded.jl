using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "unsharded runs everything — a bare Pkg.test is unchanged" begin
    d = make_suite()
    ok, log, out = run_suite(d)
    @test ok
    @test unit_keys(out) ==
        ["core/a.jl", "core/b.jl", "gen/c.jl", "gen/d.jl", "gen/e.jl", "seq"]
    @test occursin("TestShards: ALL", log)
end
