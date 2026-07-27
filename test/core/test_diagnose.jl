using Test, TestShards

@testset "the knee is where more shards stop buying wall clock" begin
    # One unit dominates: no split can finish sooner than it, so the curve flattens as soon
    # as the rest fits beside it.
    t = Dict("heavy" => 40.0, "a" => 5.0, "b" => 5.0, "c" => 5.0, "d" => 5.0)
    d = TestShards.diagnose(t; n=8)
    @test d.floor_unit == "heavy"
    @test d.floor_time == 40.0
    @test d.knee <= 2                       # 40 | 20 is already optimal
    @test d.critical_path ≈ 40.0            # N=8 cannot beat the floor
    @test first(first(d.units)) == "heavy"  # heaviest first

    # An even suite has no floor to hit, so the knee sits at the shard count.
    e = Dict("u$i" => 10.0 for i in 1:8)
    @test TestShards.diagnose(e; n=8).knee == 8
end

@testset "fixed cost changes the price of a shard, not the knee" begin
    t = Dict("heavy" => 40.0, "a" => 5.0, "b" => 5.0, "c" => 5.0, "d" => 5.0)
    bare = TestShards.diagnose(t; n=8)
    paid = TestShards.diagnose(t; n=8, fixed=60.0)
    @test paid.critical_path ≈ bare.critical_path + 60.0
    @test paid.serial == bare.serial
    @test paid.knee <= bare.knee            # a per-shard price never justifies MORE shards
end

@testset "it points at the section to cut, inside the unit that is the floor" begin
    t = Dict("heavy" => 40.0, "light" => 1.0)
    secs = Dict(
        "heavy" => ["outer" => 39.0, "outer / inner" => 30.0, "cheap" => 1.0],
        "light" => ["whatever" => 1.0],
    )
    d = TestShards.diagnose(t; n=4, sections=secs)
    @test d.floor_unit == "heavy"
    @test first(first(d.split_here)) == "outer"          # heaviest section first
    @test !any(p -> first(p) == "whatever", d.split_here) # only the floor unit's sections
end

@testset "reproduces the analysis of this repository's own recorded history" begin
    # The numbers measured on the first main-branch run, kept as a regression on the model:
    # 8 shards were bought and only 4 were usable.
    t = Dict(
        "core/test_partition_large.jl" => 46.77,
        "core/test_unit_atomicity.jl" => 35.063,
        "core/test_partition_small.jl" => 26.865,
        "test_aqua.jl" => 12.677,
        "core/test_balance.jl" => 8.843,
        "core/test_failure.jl" => 6.909,
        "core/test_order.jl" => 5.951,
        "core/test_safety.jl" => 3.433,
        "core/test_unsharded.jl" => 3.013,
        "core/test_records.jl" => 2.144,
        "core/test_assign.jl" => 0.466,
    )
    d = TestShards.diagnose(t; n=8, fixed=60.0)
    @test d.knee == 4
    @test d.floor_unit == "core/test_partition_large.jl"
    @test 100 < d.critical_path < 115        # 60 fixed + the 46.8s floor
    @test 150 < d.serial < 155
end

@testset "reporting and the CLI" begin
    t = Dict("heavy" => 40.0, "a" => 5.0)
    md = TestShards.diagnose_report(TestShards.diagnose(t; n=8))
    @test occursin("Shard diagnosis", md)
    @test occursin("past the knee", md)      # 8 requested, far fewer usable
    @test occursin("`heavy`", md)

    dir = mktempdir()
    tsv = joinpath(dir, "t.tsv")
    write(tsv, "heavy\t40\na\t5\n")
    @test TestShards.diagnose_cli([tsv, "--shards", "8"]) == 0
    @test TestShards.diagnose_cli([joinpath(dir, "absent.tsv")]) == 0   # nothing to say ≠ failure
    @test TestShards.diagnose_cli(String[]) == 1                       # no argument IS an error
    @test_throws ArgumentError TestShards.diagnose(Dict{String,Float64}(); n=4)
end

@testset "sections are written flat so nothing downstream parses JSON" begin
    d = mktempdir()
    mkpath(joinpath(d, "core"))
    write(
        joinpath(d, "core", "a.jl"),
        """
        using Test
        @testset "outer" begin
            @test true
            @testset "inner" begin; @test true; end
        end
        """,
    )
    write(
        joinpath(d, "runtests.jl"),
        "using TestShards\nTestShards.@shard begin\n    include(\"core/a.jl\")\nend\n",
    )
    out = mktempdir()
    e = copy(ENV)
    for k in collect(keys(e))
        startswith(k, "TESTSHARDS_") && delete!(e, k)
    end
    e["TESTSHARDS_OUT"] = out
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) $(joinpath(d, "runtests.jl"))`
    run(pipeline(setenv(cmd, e); stdout=devnull, stderr=devnull))

    secs = TestShards.load_sections(joinpath(out, "sections-local.tsv"))
    @test haskey(secs, "core/a.jl")
    names = first.(secs["core/a.jl"])
    @test "outer" in names
    @test "outer / inner" in names           # nesting flattened to a path, not lost
end
