using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

# Claiming replaces the one property everything else rested on — that assignment is a total
# function of the observed sequence — with a race against a server. What it buys is a late
# shard taking less work; what it costs is a new way for a unit to be silently skipped. These
# tests are about the second thing.

@testset "asking to claim without the means is an error, not a downgrade" begin
    d = make_suite()
    # A quiet fall back to assignment would run the suite with the strategy nobody asked for
    # and report success, which is indistinguishable from claiming having worked.
    ok, log, _ = run_suite(
        d;
        env=Dict("TESTSHARDS_ID" => "s1", "TESTSHARDS_N" => "2", "TESTSHARDS_CLAIM" => "1"),
        keep_stderr=true,
    )
    @test !ok
    @test occursin("TESTSHARDS_CLAIM_TOKEN", log)     # and it says WHICH piece is missing

    # And the off switches really are off.
    for off in ("", "0", "false", "no")
        @test TestShards._ownership(Dict("TESTSHARDS_CLAIM" => off)) isa TestShards.Assigned
    end
end

@testset "the claim configuration comes from the CI environment" begin
    own = TestShards._ownership(
        Dict(
            "TESTSHARDS_CLAIM" => "1",
            "GITHUB_REPOSITORY" => "o/r",
            "GITHUB_RUN_ID" => "42",
            "GITHUB_SHA" => "deadbeef",
            "GITHUB_TOKEN" => "t",
        ),
    )
    @test own isa TestShards.Claimed
    @test own.repo == "o/r"
    @test own.sha == "deadbeef"
    @test own.namespace == "tsclaim/42"      # per RUN, so two runs cannot collide
    @test own.min_seconds == 0.0

    # The explicit variables win over the ambient GitHub ones.
    own2 = TestShards._ownership(
        Dict(
            "TESTSHARDS_CLAIM" => "yes",
            "GITHUB_REPOSITORY" => "o/r",
            "GITHUB_SHA" => "a",
            "TESTSHARDS_CLAIM_REPO" => "other/repo",
            "TESTSHARDS_CLAIM_TOKEN" => "tok",
            "TESTSHARDS_CLAIM_NS" => "ns",
            "TESTSHARDS_CLAIM_MIN" => "2.5",
        ),
    )
    @test own2.repo == "other/repo"
    @test own2.namespace == "ns"
    @test own2.min_seconds == 2.5

    # Every attempt is bounded. A claim that never answers would otherwise hold the runner
    # until the job's own limit and report nothing at all — strictly worse than failing.
    @test own.timeout == 30.0
    @test TestShards._ownership(
        Dict(
            "TESTSHARDS_CLAIM" => "1",
            "TESTSHARDS_CLAIM_REPO" => "o/r",
            "TESTSHARDS_CLAIM_TOKEN" => "t",
            "TESTSHARDS_CLAIM_SHA" => "s",
            "TESTSHARDS_CLAIM_TIMEOUT" => "7.5",
        ),
    ).timeout == 7.5
end

"""
A context built by hand, touching no globals.

`_begin` is the obvious way to get one and is the wrong way: it installs the context in
`TestShards.CURRENT`, so calling it from inside a `@shard` block — which is where this suite
runs — replaces that block's own context with a fixture, and every later `include` dies with
"not inside a @shard block". The driver under test is the driver running the test.
"""
function bare_context(;
    shard="s1", nshards=2, ownership=TestShards.Assigned(), timings=Dict{String,Float64}()
)
    return TestShards.ShardContext(
        mktempdir(),
        shard,
        nothing,
        nshards,
        Dict{String,String}(),
        0,
        0,
        0,
        time(),
        ownership,
        timings,
        Tuple{Int,String}[],
        TestShards.UnitRecord[],
        IdDict{Any,Dict{String,Any}}(),
    )
end

@testset "a cheap unit is not worth a round trip, so it stays assigned" begin
    # Below the threshold the claim is skipped entirely — no request is made, which is what
    # makes this safe to leave on for a thousand-unit suite. `api` points nowhere on purpose:
    # if the threshold failed to apply, the request would be attempted and this would throw.
    c = TestShards.Claimed("http://127.0.0.1:1", "o/r", "ns", "sha", "tok", 10.0, 1, 5.0)
    ctx = bare_context(; ownership=c, timings=Dict("cheap.jl" => 0.4, "dear.jl" => 40.0))

    # Round-robin over the two shards: the first cheap unit falls to s1, the next to s2.
    @test TestShards._owns(ctx, "cheap.jl", 1)          # assigned, not claimed
    @test !TestShards._owns(ctx, "cheap.jl", 2)
    # The expensive one WOULD be claimed, and the endpoint is unreachable, so it raises rather
    # than guessing an answer.
    @test_throws ErrorException TestShards._owns(ctx, "dear.jl", 3)

    # And nothing above disturbed the @shard block this test is itself running inside.
    @test TestShards.current() !== nothing
    # Which is now enforced rather than trusted: reaching for `_begin` from in here — the
    # mistake that produced this helper — says so instead of breaking the next include.
    @test_throws ErrorException TestShards._begin(mktempdir(); env=Dict{String,String}())
    @test TestShards.current() !== nothing
end

@testset "an unreachable claim endpoint stops the shard instead of guessing" begin
    # Guessing "not mine" drops the unit; guessing "mine" runs it twice. Neither is reportable,
    # so the only honest outcome is to fail.
    c = TestShards.Claimed("http://127.0.0.1:1", "o/r", "ns", "sha", "tok", 0.0, 2, 5.0)
    err = try
        TestShards._claim(c, 7)
        nothing
    catch e
        e
    end
    @test err isa ErrorException
    @test occursin("could not claim unit 7", err.msg)
end

# ── Completeness ──────────────────────────────────────────────────────────────────────

w(shard, nunits, seen) = TestShards.ShardWindow(shard, 0.0, 1.0, nunits, 1.0, seen)

@testset "a run that covered its suite says so" begin
    c = TestShards.completeness(
        [w("s1", 2, 4), w("s2", 2, 4)],
        [(1, "s1", "a.jl"), (3, "s1", "c.jl"), (2, "s2", "b.jl"), (4, "s2", "d.jl")],
    )
    @test TestShards.complete(c)
    @test c.observed == 4
    @test c.ran == [1, 2, 3, 4]
    @test isempty(c.missed) && isempty(c.duplicated)
    @test occursin("every unit ran exactly once", TestShards.completeness_report(c))
end

@testset "a unit claimed by a shard that then died is a HOLE, and fails the run" begin
    # The failure claiming introduces: position 3 was observed by everyone and run by nobody.
    c = TestShards.completeness(
        [w("s1", 2, 4), w("s2", 1, 4)],
        [(1, "s1", "a.jl"), (2, "s1", "b.jl"), (4, "s2", "d.jl")],
    )
    @test !TestShards.complete(c)
    @test c.missed == [3]
    md = TestShards.completeness_report(c)
    @test occursin("never ran", md)
    @test occursin("position(s) 3", md)      # names it, rather than only counting
end

@testset "two shards that both believed they owned a unit is also a failure" begin
    c = TestShards.completeness(
        [w("s1", 2, 2), w("s2", 1, 2)],
        [(1, "s1", "a.jl"), (2, "s1", "b.jl"), (2, "s2", "b.jl")],
    )
    @test !TestShards.complete(c)
    @test c.duplicated == [2]
    @test occursin("ran twice", TestShards.completeness_report(c))
    @test occursin("s1 and s2", TestShards.completeness_report(c))
end

@testset "shards that disagree about the suite invalidate everything downstream" begin
    # Different observed counts mean they did not run the same runtests.jl, so `index` does not
    # identify the same unit across shards and the merged records are not one document.
    c = TestShards.completeness(
        [w("s1", 1, 4), w("s2", 1, 9)], [(1, "s1", "a.jl"), (2, "s2", "b.jl")]
    )
    @test !TestShards.complete(c)
    @test c.disagreed
    @test occursin("did not agree", TestShards.completeness_report(c))
end

@testset "the gate reads the shards' own files and returns an exit code" begin
    d = mktempdir()
    shards, ran = joinpath(d, "shards.tsv"), joinpath(d, "ran.tsv")
    write(shards, "s1\t0.0\t1.0\t1\t1.0\t2\ns2\t0.0\t1.0\t1\t1.0\t2\n")
    write(ran, "1\ts1\ta.jl\n2\ts2\tb.jl\n")
    @test TestShards.completeness_cli([shards, ran]) == 0

    write(ran, "1\ts1\ta.jl\n")                       # s2 never reported
    @test TestShards.completeness_cli([shards, ran]) == 1

    @test TestShards.completeness_cli([shards]) == 1  # not enough arguments
    # Nothing to check is a failure too: a gate that passes on no evidence is not a gate.
    @test TestShards.completeness_cli([joinpath(d, "absent"), joinpath(d, "absent")]) == 1
end

@testset "a real sharded run reports what it observed and what it took" begin
    d = make_suite()
    seen = Int[]
    ran = Tuple{Int,String,String}[]
    for k in 1:3
        _, _, out = run_suite(d; env=Dict("TESTSHARDS_ID" => "s$k", "TESTSHARDS_N" => "3"))
        ws = TestShards.load_shards(joinpath(out, "shard-s$k.tsv"))
        push!(seen, only(ws).seen)
        append!(ran, TestShards.load_ran(joinpath(out, "ran-s$k.tsv")))
    end
    @test length(unique(seen)) == 1               # every shard saw the same sequence
    c = TestShards.completeness([w("s$k", 0, seen[k]) for k in 1:3], ran)
    @test TestShards.complete(c)                  # …and between them ran all of it
    @test c.observed == first(seen)
end
