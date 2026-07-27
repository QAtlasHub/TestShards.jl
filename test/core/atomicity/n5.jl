using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "..", "helpers.jl"))
using .TSHelpers

# The `seq` unit needs 01 before 02, so a shard that got only half of it would error. Split one
# N per unit: this file used to hold every N and cost one subprocess for each shard of each.
@testset "a @unit stays whole at N=5" begin
    for k in 1:5
        @test shard_runs_clean(5, k)
    end
end
