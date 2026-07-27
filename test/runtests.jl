using TestShards

# TestShards' own suite runs through TestShards: the package is its own reference deployment,
# so the driver, the split and the record format are exercised by every CI run rather than
# only by the assertions inside them.
#
# The two loops are not decoration. They are the README's central claim — that a unit produced
# by `readdir` shards exactly like a literal one, because the interception is at the `include`
# CALL and not in the source text — being made by this suite about itself.
TestShards.@shard begin
    include("core/test_assign.jl")
    include("core/test_diagnose.jl")
    include("core/test_unsharded.jl")
    for f in sort(readdir(joinpath(@__DIR__, "core", "partition"); join=true))
        include(f)
    end
    for f in sort(readdir(joinpath(@__DIR__, "core", "atomicity"); join=true))
        include(f)
    end
    include("core/test_balance.jl")
    include("core/test_order.jl")
    include("core/test_safety.jl")
    include("core/test_failure.jl")
    include("core/test_records.jl")
    include("core/test_windows.jl")
    include("core/test_coverage.jl")
    include("core/test_claim.jl")
    include("test_aqua.jl")
end
