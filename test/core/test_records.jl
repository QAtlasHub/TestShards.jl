using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "records carry the testset tree and its evidence" begin
    d = make_suite()
    write(
        joinpath(d, "core", "a.jl"),
        """
        using Test, TestShards
        @testset "outer" begin
            evidence!(; tolerance = 1e-12, oracle = "closed form")
            @test true
            @testset "inner" begin; @test true; end
        end
        """,
    )
    _, _, out = run_suite(d)
    line = only(
        filter(
            l -> occursin("\"core/a.jl\"", l),
            readlines(joinpath(out, "records-local.jsonl")),
        ),
    )
    @test occursin("\"name\":\"outer\"", line)
    @test occursin("\"name\":\"inner\"", line)       # nesting preserved
    @test occursin("\"tolerance\":1.0e-12", line)
    @test occursin("\"oracle\":\"closed form\"", line)
    @test occursin("\"index\":1", line)              # position in the full sequence
end
