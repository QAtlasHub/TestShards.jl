using TestShards

# TestShards' own suite runs through TestShards: the package is its own reference deployment,
# so the driver, the split and the record format are exercised by every CI run rather than
# only by the assertions inside them.
TestShards.@shard begin
    include("core/test_assign.jl")
    include("core/test_diagnose.jl")
    include("core/test_unsharded.jl")
    include("core/test_partition_small.jl")
    include("core/test_partition_large.jl")
    include("core/test_balance.jl")
    include("core/test_unit_atomicity.jl")
    include("core/test_order.jl")
    include("core/test_safety.jl")
    include("core/test_failure.jl")
    include("core/test_records.jl")
    include("test_aqua.jl")
end
