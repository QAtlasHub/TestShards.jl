using Test, TestShards

function plan_fixture(n; dir="core")
    root = mktempdir()
    mkpath(joinpath(root, dir))
    for i in 1:n
        write(joinpath(root, dir, "test_$(lpad(i, 2, '0')).jl"), "using Test\n@test true\n")
    end
    return universe(root)
end

@testset "every shard is a subset and their union is the whole suite" begin
    u = plan_fixture(9)
    for n in 1:12
        shards = TestShards.plan(u, n)
        all_files = reduce(vcat, s.files for s in shards)
        # The invariant that makes sharding safe at all: nothing runs twice, nothing is lost.
        @test sort(all_files) == sort([filekey(d, f) for (d, f) in u.files])
        @test length(unique(all_files)) == length(all_files)
        @test count(s -> s.oneshots, shards) == 1        # exactly one carries them
        @test length(shards) == min(n, length(u))        # n is a request, not a promise
    end
end

@testset "LPT balances against history; round-robin without it" begin
    u = plan_fixture(4)
    k = [filekey(d, f) for (d, f) in u.files]

    # 10 / 1 / 1 / 1 over two shards: the only balanced answer isolates the heavy file.
    t = Dict(k[1] => 10.0, k[2] => 1.0, k[3] => 1.0, k[4] => 1.0)
    shards = TestShards.plan(u, 2; timings=t)
    heavy = only(filter(s -> k[1] in s.files, shards))
    @test heavy.files == [k[1]]
    @test sort(only(filter(s -> !(k[1] in s.files), shards)).files) == sort(k[2:4])

    # With no history the split is round-robin, i.e. blind to weight — the honest fallback.
    rr = TestShards.plan(u, 2)
    @test sort(rr[1].files) == sort([k[1], k[3]])

    # One-shots go to the shard that finishes EARLIEST, off the critical path.
    @test !heavy.oneshots
end

@testset "an unknown file is estimated pessimistically (P90), not optimistically" begin
    u = plan_fixture(4)
    k = [filekey(d, f) for (d, f) in u.files]
    t = Dict(k[1] => 1.0, k[2] => 1.0, k[3] => 100.0)     # k[4] has no history
    shards = TestShards.plan(u, 2; timings=t)
    # P90 of {1,1,100} is 100, so the unknown file must NOT be piled onto the 100s shard.
    big = only(filter(s -> k[3] in s.files, shards))
    @test !(k[4] in big.files)
end

@testset "plan_json is a GitHub matrix, and only that on stdout" begin
    u = plan_fixture(3)
    j = plan_json(u, 2)
    @test startswith(j, "[{") && endswith(j, "}]")
    @test occursin("\"sid\":\"s1\"", j)
    @test occursin("\"files\":", j) && occursin("\"oneshots\":", j)
    @test count("\"sid\"", j) == 2
    @test_throws ArgumentError TestShards.plan(u, 0)
end

@testset "load_timings degrades instead of aborting CI" begin
    p = joinpath(mktempdir(), "t.tsv")
    write(p, "a/test_x.jl\t1.5\ngarbage line\nb/test_y.jl\tnotanumber\nb/test_z.jl\t2\n")
    t = load_timings(p)
    @test t == Dict("a/test_x.jl" => 1.5, "b/test_z.jl" => 2.0)
    @test isempty(load_timings(joinpath(mktempdir(), "absent.tsv")))
    @test isempty(load_timings(""))
end
