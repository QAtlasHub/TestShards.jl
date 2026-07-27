using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "a failing unit is recorded, does not abort the shard, and fails the run once" begin
    d = make_suite(; extra="include(\"bad.jl\")\ninclude(\"core/a.jl\")")
    write(joinpath(d, "bad.jl"), "using Test\n@test false\n")
    ok, log, out = run_suite(d)
    @test !ok
    @test occursin("[FAIL] bad.jl", log)
    # Everything after the failure still ran and was recorded — which is why the failure is
    # re-signalled once at the end instead of thrown where it happened.
    @test "bad.jl" in unit_keys(out)
end
