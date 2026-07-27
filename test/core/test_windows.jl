using Test, TestShards
isdefined(Main, :TSHelpers) || include(joinpath(@__DIR__, "helpers.jl"))
using .TSHelpers

# A shard window is the one measurement the per-unit timings cannot produce: whether the shards
# ran at the same time. Everything the model says about wall clock rests on assuming they did.

@testset "a shard reports the window it ran in" begin
    d = make_suite()
    # An epoch stamp from CI: the shard's window must start at the JOB's start, not at the
    # Julia process's, or the checkout and precompilation it is meant to expose fall outside it.
    job_start = round(Int, time()) - 100      # what `date +%s` writes in the workflow
    _, _, out = run_suite(d; env=Dict("TESTSHARDS_JOB_START" => string(job_start)))

    ws = TestShards.load_shards(joinpath(out, "shard-local.tsv"))
    w = only(ws)
    @test w.shard == "local"
    @test w.started ≈ job_start
    @test w.finished > w.started
    @test w.nunits == length(unit_keys(out))
    @test w.unit_seconds > 0
    # The 100s that CI reported but Julia never saw are exactly what `fixed_cost` is for.
    @test TestShards.fixed_cost(w) > 100
    @test TestShards.window(w) ≈ w.finished - w.started
end

@testset "without a job start the window is the process's own" begin
    d = make_suite()
    before = time()
    _, _, out = run_suite(d)
    w = only(TestShards.load_shards(joinpath(out, "shard-local.tsv")))
    @test w.started >= before             # this run, not an inherited stamp
    @test 0 <= TestShards.fixed_cost(w) < 120
end

@testset "a malformed row is ignored, never fatal" begin
    dir = mktempdir()
    f = joinpath(dir, "shards.tsv")
    write(
        f,
        "s1\t100.0\t160.0\t2\t40.0\n" *
        "s2\tnot-a-number\t160.0\t1\t10.0\n" *   # unparseable
        "s3\t100.0\t160.0\n" *                   # too few columns
        "s4\t120.0\t200.0\t1\t50.0\n",
    )
    ws = TestShards.load_shards(f)
    @test [w.shard for w in ws] == ["s1", "s4"]
    @test TestShards.load_shards(joinpath(dir, "absent.tsv")) == TestShards.ShardWindow[]
end

@testset "effective parallelism is the work divided by the wall clock" begin
    # Two shards, perfectly overlapping: 40s of units each in a 60s window, so 80s of work in
    # 60s of wall clock.
    together = [
        TestShards.ShardWindow("s1", 100.0, 160.0, 2, 40.0),
        TestShards.ShardWindow("s2", 100.0, 160.0, 2, 40.0),
    ]
    o = TestShards.observe(together)
    @test o.wall ≈ 60.0
    @test o.start_window ≈ 0.0
    @test o.effective ≈ 80 / 60
    @test o.fixed ≈ 20.0                  # 60s window, 40s of it on units
    @test o.runner_seconds ≈ 120.0

    # The same two shards, one starting after the other has finished. Identical work, identical
    # split, identical per-unit timings — and half the parallelism.
    apart = [
        TestShards.ShardWindow("s1", 100.0, 160.0, 2, 40.0),
        TestShards.ShardWindow("s2", 160.0, 220.0, 2, 40.0),
    ]
    p = TestShards.observe(apart)
    @test p.wall ≈ 120.0
    @test p.start_window ≈ 60.0
    @test p.effective ≈ 80 / 120
    @test p.effective < o.effective       # the number the timings alone cannot show
    @test p.first_shard == "s1"
    @test p.last_shard == "s2"            # last to START
    @test p.runner_seconds ≈ o.runner_seconds   # the runner bill is unchanged

    @test TestShards.observe(TestShards.ShardWindow[]) === nothing
end

@testset "the diagnosis measures the fixed cost instead of guessing it" begin
    t = Dict("heavy" => 40.0, "a" => 5.0)
    ws = [
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0),     # 20s fixed
        TestShards.ShardWindow("s2", 0.0, 25.0, 1, 5.0),      # 20s fixed
    ]
    d = TestShards.diagnose(t; n=2, shards=ws)
    @test d.fixed ≈ 20.0                  # measured, not passed in
    @test d.observed !== nothing
    @test d.observed.nshards == 2

    # An explicit price is a question about a hypothetical, so it wins.
    @test TestShards.diagnose(t; n=2, fixed=99.0, shards=ws).fixed ≈ 99.0
    # And with no windows at all nothing changes: the model still answers on its own.
    @test TestShards.diagnose(t; n=2).observed === nothing
    @test TestShards.diagnose(t; n=2).fixed == 0.0
end

@testset "the report says when the queue, not the split, set the wall clock" begin
    t = Dict("heavy" => 40.0, "a" => 5.0)
    # Shards that overlap: observed wall clock is close to what the model predicts, so there is
    # nothing to warn about.
    ontime = [
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0),
        TestShards.ShardWindow("s2", 0.0, 25.0, 1, 5.0),
    ]
    md = TestShards.diagnose_report(TestShards.diagnose(t; n=2, shards=ontime))
    @test occursin("observed wall", md)
    @test occursin("effective parallelism", md)
    @test occursin("When each shard ran", md)
    @test !occursin("did not overlap", md)

    # The same work, one shard starting 300s late.
    late = [
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0),
        TestShards.ShardWindow("s2", 300.0, 325.0, 1, 5.0),
    ]
    md2 = TestShards.diagnose_report(TestShards.diagnose(t; n=2, shards=late))
    @test occursin("did not overlap", md2)
    @test occursin("`s2` started", md2)   # names the shard that set the finish line
    @test occursin("325.0s", md2)         # the observed wall, not the predicted one

    # The plain-text show method carries the same two facts.
    txt = sprint(show, MIME"text/plain"(), TestShards.diagnose(t; n=2, shards=late))
    @test occursin("observed", txt)
    @test occursin("effective", txt)
end

@testset "the CLI takes the windows as its third file" begin
    dir = mktempdir()
    tsv = joinpath(dir, "t.tsv")
    secs = joinpath(dir, "s.tsv")
    shards = joinpath(dir, "w.tsv")
    write(tsv, "heavy\t40\na\t5\n")
    write(secs, "heavy\touter\t39\n")
    write(shards, "s1\t0.0\t60.0\t1\t40.0\ns2\t300.0\t325.0\t1\t5.0\n")
    @test TestShards.diagnose_cli([tsv, secs, shards, "--shards", "2"]) == 0
    # Absent or unreadable windows degrade to the model-only report rather than failing.
    @test TestShards.diagnose_cli([tsv, secs, joinpath(dir, "absent.tsv")]) == 0
end
