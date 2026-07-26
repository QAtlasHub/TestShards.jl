using Test, TestShards

"Build a throwaway suite; returns its root."
function fixture(dirs_files)
    root = mktempdir()
    for (d, fs) in dirs_files
        mkpath(joinpath(root, d))
        for f in fs
            write(joinpath(root, d, f), "using Test\n@test true\n")
        end
    end
    return root
end

@testset "discovery is the default — nothing to declare, nothing to drift" begin
    root = fixture(["core" => ["test_a.jl", "test_b.jl"], "solver" => ["test_c.jl"]])
    u = universe(root)
    @test u.dirs == ["core/", "solver/"]
    @test [filekey(d, f) for (d, f) in u.files] == ["core/test_a.jl", "core/test_b.jl", "solver/test_c.jl"]
    @test length(u) == 3

    # A directory added later is picked up with no registration step. This is the whole
    # reason discovery is the default: the hand-maintained list is what silently goes stale.
    mkpath(joinpath(root, "extra"))
    write(joinpath(root, "extra", "test_new.jl"), "using Test\n@test true\n")
    @test length(universe(root)) == 4
end

@testset "non-test files and ci/ are not units" begin
    root = fixture(["core" => ["test_a.jl", "helpers.jl"], "ci" => ["test_ignored.jl"]])
    u = universe(root)
    @test [f for (_, f) in u.files] == ["test_a.jl"]
end

@testset "completeness guard fires ONLY when dirs is pinned" begin
    root = fixture(["core" => ["test_a.jl"], "solver" => ["test_c.jl"]])
    @test length(universe(root)) == 2                      # discovery: no guard needed
    @test_throws ErrorException universe(root; dirs=["core/"])        # undeclared solver/
    @test_throws ErrorException universe(root; dirs=["core/", "gone/"])  # declared, missing
    @test length(universe(root; dirs=["core/", "solver/"])) == 2
    @test universe(root; dirs=["core", "solver"]).dirs == ["core/", "solver/"]  # slash optional
end

@testset "an empty root is an error, not an empty plan" begin
    @test_throws ErrorException universe(mktempdir())
    @test_throws ErrorException universe(joinpath(mktempdir(), "nope"))
end
