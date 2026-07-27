using TestShards

# Dogfooded: TestShards' own suite runs through TestShards, so the driver is exercised on
# every CI run and not only by the tests below it.
TestShards.@shard begin
    include("core/test_assign.jl")
    include("core/test_sharding.jl")
    include("test_aqua.jl")
end
