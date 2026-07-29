using Test
using TestShards

isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

# The unit-testset provider seam, exercised with a STUB provider — no other package involved. The
# contract is what matters here: the type a unit runs in, the second step a hand-popped testset
# needs, and the fold that keeps the counts right when the testset is not ours. The real consumer
# (Pinax) is tested end to end in `test_pinax.jl`.

@testset "with no provider, a unit runs in a DefaultTestSet" begin
    saved = TestShards.UNIT_PROVIDER[]
    TestShards.UNIT_PROVIDER[] = nothing
    try
        @test TestShards._unit_testset("u.jl") isa Test.DefaultTestSet
        @test TestShards._unit_close(Test.DefaultTestSet("u.jl")) === nothing
    finally
        TestShards.UNIT_PROVIDER[] = saved
    end
end

@testset "a provider owns the type, and its close runs after the pop" begin
    closed = String[]
    with_provider(; open=k -> StubSet(k), close=ts -> push!(closed, ts.description)) do
        ts = TestShards._unit_testset("u.jl")
        @test ts isa StubSet && ts.description == "u.jl"
        TestShards._unit_close(ts)
        @test closed == ["u.jl"]        # the step a hand-popped testset needs to reach its parent
    end
end

@testset "a provider declines by returning nothing — the default stands" begin
    # This is what keeps merely HAVING the tool installed inert: the provider decides, per unit,
    # whether its capture is actually running.
    with_provider(; open=_ -> nothing) do
        @test TestShards._unit_testset("u.jl") isa Test.DefaultTestSet
    end
end

@testset "two providers is an error, not a race" begin
    saved = TestShards.UNIT_PROVIDER[]
    TestShards.UNIT_PROVIDER[] = nothing
    try
        TestShards.register_unit_provider!(; name="A", open=k -> StubSet(k), fold=stub_fold)
        # re-registering the SAME name is idempotent (an extension may be initialised twice)
        TestShards.register_unit_provider!(; name="A", open=k -> StubSet(k), fold=stub_fold)
        @test TestShards.UNIT_PROVIDER[].name == "A"
        err = nothing
        try
            TestShards.register_unit_provider!(;
                name="B", open=k -> StubSet(k), fold=stub_fold
            )
        catch e
            err = e
        end
        @test err isa ErrorException
        @test occursin("A", err.msg) && occursin("B", err.msg)   # says which two
    finally
        TestShards.UNIT_PROVIDER[] = saved
    end
end

@testset "a provider can read what a test established" begin
    # `evidence!` keys on the testset OBJECT, so it already works when the testset is a provider's
    # rather than ours. `evidence` is the reader that lets that provider surface it without reaching
    # into this package's internals.
    saved_ctx = TestShards.CURRENT[]
    stub = StubSet("u.jl")
    try
        @test TestShards.evidence(stub) == Dict{String,Any}()   # no context at all: empty, not an error
        ctx = bare_context(; shard="", nshards=1)
        TestShards.CURRENT[] = ctx
        @test TestShards.evidence(stub) == Dict{String,Any}()   # a context, but nothing recorded
        ctx.evidence[stub] = Dict{String,Any}(
            "tolerance" => 1.0e-12, "oracle" => "closed form"
        )
        ev = TestShards.evidence(stub)
        @test ev["tolerance"] == 1.0e-12 && ev["oracle"] == "closed form"
        @test TestShards.evidence(StubSet("u.jl")) == Dict{String,Any}()   # by identity, not by name
    finally
        TestShards.CURRENT[] = saved_ctx
    end
end

@testset "the fold keeps the counts, whichever testset ran the unit" begin
    # The regression that would matter and would not show: the balancing history and the
    # completeness verdict are built on these numbers, so a foreign testset must yield the same
    # ones. A `nothing` fold result field defaults to zero rather than erroring.
    ctx = bare_context(; shard="", nshards=1)
    stub = StubSet("u.jl")
    for _ in 1:3
        Test.record(stub, Test.Pass(:test, :x, :x, nothing))
    end
    Test.record(stub, Test.Broken(:skipped, :x))
    sec = with_provider(; open=k -> StubSet(k)) do
        TestShards.unit_fold(ctx, stub)
    end
    @test (sec.name, sec.npass, sec.nfail, sec.nerror, sec.nbroken) == ("u.jl", 3, 0, 0, 1)
    @test sec.duration == 0.5
    @test isempty(sec.sections)                     # the stub reports no nesting

    # nested plain data folds into nested Sections
    nested = with_provider(;
        open=k -> StubSet(k),
        fold=_ -> (; name="u.jl", npass=1, sections=[(; name="inner", npass=2)]),
    ) do
        TestShards.unit_fold(ctx, StubSet("u.jl"))
    end
    @test nested.npass == 1 && length(nested.sections) == 1
    @test nested.sections[1].name == "inner" && nested.sections[1].npass == 2
    @test nested.sections[1].duration == 0.0        # an omitted field is zero, not an error

    # a foreign testset with NO provider is an error naming the type — never a silent zero
    saved = TestShards.UNIT_PROVIDER[]
    TestShards.UNIT_PROVIDER[] = nothing
    try
        @test_throws ErrorException TestShards.unit_fold(ctx, StubSet("u.jl"))
    finally
        TestShards.UNIT_PROVIDER[] = saved
    end
end
