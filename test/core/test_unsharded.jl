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

# The two halves of what `shards: 1` means. The workflow sends the count and NO id, and the
# package runs the suite whole; sending an id as well is the configuration that cannot mean
# anything, and it is still refused. The fix for that combination belongs in the caller, so
# both are pinned here — relaxing the guard would make `shards: 1` pass by running the whole
# suite in every shard, which is the green-for-the-wrong-reason outcome it exists to stop.
@testset "shards: 1 — a count with no id runs the suite whole" begin
    d = make_suite()
    ok, log, out = run_suite(d; env=Dict("TESTSHARDS_N" => "1"))
    @test ok
    @test unit_keys(out) ==
        ["core/a.jl", "core/b.jl", "gen/c.jl", "gen/d.jl", "gen/e.jl", "seq"]
    @test occursin("TestShards: ALL", log)
end

@testset "an id with nothing to split is refused, loudly" begin
    d = make_suite()
    ok, log, _ = run_suite(
        d; env=Dict("TESTSHARDS_ID" => "s1", "TESTSHARDS_N" => "1"), keep_stderr=true
    )
    @test !ok
    @test occursin("pass for the wrong reason", log)
end
