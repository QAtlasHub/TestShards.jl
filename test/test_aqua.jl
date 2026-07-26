using Aqua, TestShards, Test

@testset "Aqua" begin
    Aqua.test_all(TestShards)
end
