using Test, TestShards

function fixture()
    root = mktempdir()
    mkpath(joinpath(root, "core"))
    for f in ("test_a.jl", "test_b.jl", "test_c.jl")
        write(joinpath(root, "core", f), "using Test\n@test true\n")
    end
    return universe(root)
end

@testset "selection precedence: FILES > SHARD > everything" begin
    u = fixture()
    files, desc, one = select(u; env=Dict("TESTSHARDS_FILES" => "core/test_b.jl"))
    @test [f for (_, f) in files] == ["test_b.jl"]
    @test occursin("FILES", desc)
    @test one == false                                   # oneshots default off for a slice

    files, desc, one = select(u; env=Dict("TESTSHARDS_SHARD" => "1/3"))
    @test [f for (_, f) in files] == ["test_a.jl"]
    @test one == true                                    # shard 1 carries them

    files, desc, one = select(u; env=Dict{String,String}())
    @test length(files) == 3 && desc == "ALL" && one == true
end

@testset "a shard that would silently run EVERYTHING is an error" begin
    u = fixture()
    # The failure this prevents: a workflow wires the id but not the slice, every shard runs
    # the whole suite, CI is green, slow, and means nothing.
    @test_throws ErrorException select(u; env=Dict("TESTSHARDS_ID" => "s1"))
end

@testset "planner/suite disagreement is an error, not a silent skip" begin
    u = fixture()
    @test_throws ErrorException select(
        u; env=Dict("TESTSHARDS_FILES" => "core/test_gone.jl")
    )
end

@testset "malformed k/N is rejected" begin
    u = fixture()
    for bad in ("1", "x/3", "0/3", "4/3", "1/9")          # 1/9 exceeds the 3-file suite
        @test_throws ErrorException select(u; env=Dict("TESTSHARDS_SHARD" => bad))
    end
end

@testset "runtests emits timings even when the shard fails" begin
    root = mktempdir()
    mkpath(joinpath(root, "core"))
    write(joinpath(root, "core", "test_bad.jl"), "using Test\n@test false\n")
    out = mktempdir()

    # Run it in a SUBPROCESS, the way CI does. Calling `runtests` inline would record the
    # deliberate failure into this suite's own testset — a nested testset does not throw, it
    # reports upward — so the check would poison the very run it is part of.
    code = """
    using TestShards
    runtests(universe($(repr(root)));
             env = Dict("TESTSHARDS_FILES" => "core/test_bad.jl",
                        "TESTSHARDS_ID" => "s1",
                        "TESTSHARDS_EMIT" => "1",
                        "TESTSHARDS_OUT" => $(repr(out))))
    """
    cmd = `$(Base.julia_cmd()) --startup-file=no --project=$(dirname(Base.active_project())) -e $code`
    ok = success(pipeline(ignorestatus(cmd); stdout=devnull, stderr=devnull))
    @test !ok                                    # a red shard must exit nonzero

    # A red shard's files still took however long they took; losing that would make the next
    # plan fall back to a stale estimate exactly where the suite is changing.
    @test isfile(joinpath(out, "timings-s1.tsv"))
    @test occursin("core/test_bad.jl", read(joinpath(out, "timings-s1.tsv"), String))
end
