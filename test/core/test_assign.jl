using Test, TestShards

@testset "LPT: heaviest first into the least-loaded shard" begin
    t = Dict("a" => 10.0, "b" => 1.0, "c" => 1.0, "d" => 1.0)
    a = TestShards.assign(t, 2)
    @test length(unique(values(a))) == 2
    heavy = a["a"]
    @test count(k -> a[k] == heavy, keys(a)) == 1        # 10 alone, 1+1+1 together
    @test TestShards.assign(t, 1) |> values |> unique == ["s1"]
    @test_throws ArgumentError TestShards.assign(t, 0)
end

@testset "assignment is deterministic — every shard must compute the same one" begin
    # This is what removes the need for any coordination between jobs: identical input,
    # identical output, so no unit can be claimed twice or dropped.
    t = Dict("x$i" => Float64(i % 7) for i in 1:50)
    @test TestShards.assign(t, 5) == TestShards.assign(t, 5)
    # Equal weights must not tie-break on hash order, which varies between processes.
    e = Dict("a" => 1.0, "b" => 1.0, "c" => 1.0, "d" => 1.0)
    @test TestShards.assign(e, 2)["a"] == "s1"
end

@testset "load_timings degrades instead of aborting the run" begin
    p = joinpath(mktempdir(), "t.tsv")
    write(p, "a\t1.5\ngarbage\nb\tnotanumber\nc\t2\n")
    @test TestShards.load_timings(p) == Dict("a" => 1.5, "c" => 2.0)
    @test isempty(TestShards.load_timings(joinpath(mktempdir(), "absent.tsv")))
    @test isempty(TestShards.load_timings(""))
end

@testset "matrix_json carries labels only" begin
    @test TestShards.matrix_json(3) ==
        "[{\"sid\":\"s1\"},{\"sid\":\"s2\"},{\"sid\":\"s3\"}]"
    @test_throws ArgumentError TestShards.matrix_json(0)
end
