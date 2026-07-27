using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "within a shard, units run in OBSERVED order" begin
    d = make_suite()
    # Listed deliberately out of order: execution must follow the source, not the request.
    _, log, _ = run_suite(d; env=Dict("TESTSHARDS_UNITS" => "seq,core/b.jl,core/a.jl"))
    ran = [m.captures[1] for m in eachmatch(r"\[ok\] (\S+)", log)]
    @test ran == ["core/a.jl", "core/b.jl", "seq"]
end

@testset "an explicit unit list selects manual mode on its own" begin
    d = make_suite()
    _, log, out = run_suite(d; env=Dict("TESTSHARDS_UNITS" => "core/a.jl"))
    @test occursin("manual", log)
    @test unit_keys(out) == ["core/a.jl"]
end
