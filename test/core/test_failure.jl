using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

@testset "a failing unit is recorded, does not abort the shard, and fails the run once" begin
    d = make_suite(; extra="include(\"bad.jl\")\ninclude(\"core/a.jl\")")
    write(joinpath(d, "bad.jl"), "using Test\n@test false\n")
    ok, log, out = run_suite(d)
    @test !ok
    @test occursin("[FAIL] bad.jl", log)
    # Everything after the failure still ran and was recorded — which is why the failure is
    # re-signalled once at the end instead of thrown where it happened.
    @test "bad.jl" in unit_keys(out)
end

@testset "a failing NESTED testset is a fail, not an error" begin
    # The depth the unit's testset is entered at is what tells an inner `@testset` it is not
    # top-level.  Get it wrong and the inner one's `finish` throws instead of recording, `_run`
    # catches that as a `:nontest_error`, and a real FAIL is reported as an ERROR — the same
    # count, in the wrong column, with nothing red to say so.
    #
    # The bare `@test false` above cannot see this: it records straight onto the current testset
    # and never reaches the depth logic at all.
    d = make_suite(; extra="include(\"nested.jl\")")
    write(
        joinpath(d, "nested.jl"),
        """
        using Test
        @testset "outer" begin
            @test true
            @testset "inner" begin
                @test false
            end
        end
        """,
    )
    ok, log, out = run_suite(d)
    @test !ok
    @test occursin("[FAIL] nested.jl", log)
    @test occursin("(1 pass, 1 fail, 0 error)", log)
    @test !occursin("(0 pass, 0 fail, 1 error)", log)
end
