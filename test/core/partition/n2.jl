using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "..", "helpers.jl"))
using .TSHelpers

# One N per unit: the cost here is one subprocess per shard, so keeping every N in one file made
# it the heaviest unit in the suite and the floor on how fast any split can finish.
@testset "shards PARTITION the suite (N=2)" begin
    ran = partition_check(2)
    @test ran == whole_units()                        # nothing dropped
    @test length(unique(ran)) == length(ran)          # nothing run twice
end
