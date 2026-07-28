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
        "s1\t100.0\t160.0\t2\t40.0\t3\n" *
        "s2\tnot-a-number\t160.0\t1\t10.0\t3\n" *   # unparseable
        "s3\t100.0\t160.0\n" *                   # too few columns
        "s4\t120.0\t200.0\t1\t50.0\t3\n",
    )
    ws = TestShards.load_shards(f)
    @test [w.shard for w in ws] == ["s1", "s4"]
    @test TestShards.load_shards(joinpath(dir, "absent.tsv")) == TestShards.ShardWindow[]
end

@testset "the job's end is folded in, because a shard cannot see its own" begin
    d = mktempdir()
    shards = joinpath(d, "shards.tsv")
    # A shard whose test process ended at 160, in a job that ran until 200: the 40s in between
    # is coverage processing and uploads, and it is fixed cost the shard cannot report.
    write(shards, "s1\t100.0\t160.0\t2\t40.0\t3\ns2\t100.0\t150.0\t1\t10.0\t3\n")

    bare = TestShards.load_shards(shards)
    @test TestShards.fixed_cost(bare[1]) ≈ 20.0        # 60s window, 40s of units

    ends = joinpath(d, "ended.tsv")
    write(ends, "s1\t200.0\ns2\t190.0\n")
    @test TestShards.load_ends(ends) == Dict("s1" => 200.0, "s2" => 190.0)

    fixed = TestShards.load_shards(shards; ends)
    @test fixed[1].finished == 200.0
    @test TestShards.fixed_cost(fixed[1]) ≈ 60.0       # three times what the shard could see

    # A shard missing from the file keeps its own figure rather than being dropped.
    partial = joinpath(d, "partial.tsv")
    write(partial, "s1\t200.0\n")
    ws = TestShards.load_shards(shards; ends=partial)
    @test ws[1].finished == 200.0
    @test ws[2].finished == 150.0

    # A stamp EARLIER than the process end would mean the clock ran backwards. Shrinking a
    # lower bound is never the safe direction, so it is ignored.
    backwards = joinpath(d, "backwards.tsv")
    write(backwards, "s1\t120.0\n")
    @test TestShards.load_shards(shards; ends=backwards)[1].finished == 160.0

    @test isempty(TestShards.load_ends(joinpath(d, "absent.tsv")))
    write(joinpath(d, "bad.tsv"), "s1\tnot-a-number\ns2\n")
    @test isempty(TestShards.load_ends(joinpath(d, "bad.tsv")))
end

@testset "a bigger measured fixed cost can flip the regime, which is the point" begin
    # This is why the understatement mattered rather than being untidy: the recommendation to
    # steal or not is FixedCostBound, and FixedCostBound is `fixed > heaviest bin`.
    t = Dict("heavy" => 40.0, "a" => 5.0, "b" => 5.0)
    seen = [
        TestShards.ShardWindow("s1", 0.0, 70.0, 1, 40.0, 3),
        TestShards.ShardWindow("s2", 0.0, 40.0, 2, 10.0, 3),
    ]
    # As the shards saw it: 30s and 30s of setup against a 40s bin — work-dominated.
    @test !(
        TestShards.bottleneck(TestShards.diagnose(t; n=2, shards=seen)) isa
        TestShards.FixedCostBound
    )
    # With the jobs' real ends, the same run is setup-dominated and the advice reverses.
    whole = [
        TestShards.ShardWindow("s1", 0.0, 120.0, 1, 40.0, 3),
        TestShards.ShardWindow("s2", 0.0, 90.0, 2, 10.0, 3),
    ]
    @test TestShards.bottleneck(TestShards.diagnose(t; n=2, shards=whole)) isa
        TestShards.FixedCostBound
end

@testset "effective parallelism is the work divided by the wall clock" begin
    # Two shards, perfectly overlapping: 40s of units each in a 60s window, so 80s of work in
    # 60s of wall clock.
    together = [
        TestShards.ShardWindow("s1", 100.0, 160.0, 2, 40.0, 4),
        TestShards.ShardWindow("s2", 100.0, 160.0, 2, 40.0, 4),
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
        TestShards.ShardWindow("s1", 100.0, 160.0, 2, 40.0, 4),
        TestShards.ShardWindow("s2", 160.0, 220.0, 2, 40.0, 4),
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
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0, 2),     # 20s fixed
        TestShards.ShardWindow("s2", 0.0, 25.0, 1, 5.0, 2),      # 20s fixed
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

@testset "peak concurrency counts the runners actually granted" begin
    # Eight shards requested, two ever alive at once.
    serialised = [
        TestShards.ShardWindow("s$i", 10.0 * i, 10.0 * i + 15, 1, 5.0, 8) for i in 1:8
    ]
    @test TestShards.peak_concurrency(serialised) == 2
    together = [TestShards.ShardWindow("s$i", 0.0, 60.0, 1, 40.0, 8) for i in 1:8]
    @test TestShards.peak_concurrency(together) == 8
    # A shard that finishes exactly when the next begins never overlapped it.
    @test TestShards.peak_concurrency([
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0, 2),
        TestShards.ShardWindow("s2", 60.0, 120.0, 1, 40.0, 2),
    ]) == 1
    @test TestShards.peak_concurrency(TestShards.ShardWindow[]) == 0
end

@testset "the bottleneck is a type, and the advice dispatches on it" begin
    # The work still divides and the shard count is below the knee: nothing is in the way.
    even = Dict("u$i" => 10.0 for i in 1:8)
    @test TestShards.bottleneck(TestShards.diagnose(even; n=2)) isa TestShards.WorkBound
    @test TestShards.usable_shards(TestShards.diagnose(even; n=2)) == 8

    # Past the knee with one dominant unit: the floor is what is left.
    heavy = Dict("heavy" => 40.0, "a" => 5.0, "b" => 5.0)
    d = TestShards.diagnose(heavy; n=8)
    @test TestShards.bottleneck(d) isa TestShards.FloorBound
    @test occursin("heavy", TestShards.remedy(d))

    # The same suite where getting ready costs more than the heaviest bin.
    costly = TestShards.diagnose(heavy; n=8, fixed=200.0)
    @test TestShards.bottleneck(costly) isa TestShards.FixedCostBound
    @test occursin("getting ready", TestShards.remedy(costly))

    # And the same suite again, this time measured, with the shards not overlapping. Identical
    # timings, identical split — a different regime, because of when the jobs ran.
    late = [
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0, 2),
        TestShards.ShardWindow("s2", 300.0, 325.0, 2, 10.0, 3),
    ]
    queued = TestShards.diagnose(heavy; n=2, shards=late)
    @test TestShards.bottleneck(queued) isa TestShards.QueueBound
    @test TestShards.usable_shards(queued) == 1        # only one ran at a time
    @test occursin("did not overlap", TestShards.remedy(queued))

    # Every regime answers, and answers with a shard count that is at least one.
    for x in (TestShards.diagnose(even; n=2), d, costly, queued)
        @test TestShards.bottleneck(x) isa TestShards.Bottleneck
        @test TestShards.usable_shards(x) >= 1
        @test !isempty(TestShards.remedy(x))
    end
end

@testset "a run whose shards started together is not queue-bound, whatever the model says" begin
    # Found on this package's own CI: eight shards started 2.0s apart, ran for 70.4s, and were
    # called QueueBound because the observed wall clock sat well above the predicted one. The
    # prediction was what was wrong — `fixed` is a LOWER bound (the windows close when the test
    # process exits), so it understates, and the gap that opens was being blamed on the queue.
    # The queue could account for 2s of a 16.7s gap.
    t = Dict("u$i" => 20.0 for i in 1:8)
    together = [TestShards.ShardWindow("s$i", i * 0.25, 70.0, 1, 20.0, 8) for i in 1:8]
    d = TestShards.diagnose(t; n=8, shards=together)
    @test d.observed.start_window < 0.25 * d.observed.wall
    @test !(TestShards.bottleneck(d) isa TestShards.QueueBound)

    # The property that was actually missing: the queue verdict must not depend on the model
    # term at all. `fixed` is a lower bound, so `critical_path` can be arbitrarily pessimistic
    # about how much of the wall clock is unexplained — and none of that is evidence about WHEN
    # the shards started, which is the only thing QueueBound claims.
    for f in (0.0, 1.0, 500.0)
        @test !(
            TestShards.bottleneck(TestShards.diagnose(t; n=8, shards=together, fixed=f)) isa
            TestShards.QueueBound
        )
    end

    # The five start windows this repository has actually produced, against its walls. Only the
    # first three were the queue; the last two were the suite.
    for (window, wall, queued) in (
        (199, 277, true), (130, 201, true), (181, 213, true), (4, 86, false), (2, 70, false)
    )
        ws = [
            TestShards.ShardWindow("s1", 0.0, Float64(wall), 1, 20.0, 2),
            TestShards.ShardWindow("s2", Float64(window), Float64(wall), 1, 20.0, 2),
        ]
        got = TestShards.bottleneck(TestShards.diagnose(t; n=8, shards=ws))
        @test (got isa TestShards.QueueBound) == queued
    end
end

@testset "the regime depends on scale, not just on the numbers" begin
    # THE reason this is a type. A 49s fixed cost against a 150s suite is fatal; against a
    # 40-minute suite it is a rounding error. Same fixed cost, same shard count, opposite
    # advice — and no consumer repository should have to work that out for itself.
    small = Dict("u$i" => 150.0 / 12 for i in 1:12)
    large = Dict("u$i" => 2400.0 / 12 for i in 1:12)
    @test TestShards.bottleneck(TestShards.diagnose(small; n=8, fixed=49.0)) isa
        TestShards.FixedCostBound
    @test TestShards.bottleneck(TestShards.diagnose(large; n=8, fixed=49.0)) isa
        TestShards.WorkBound
end

@testset "the report says when the queue, not the split, set the wall clock" begin
    t = Dict("heavy" => 40.0, "a" => 5.0)
    # Shards that overlap: observed wall clock is close to what the model predicts, so there is
    # nothing to warn about.
    ontime = [
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0, 2),
        TestShards.ShardWindow("s2", 0.0, 25.0, 1, 5.0, 2),
    ]
    md = TestShards.diagnose_report(TestShards.diagnose(t; n=2, shards=ontime))
    @test occursin("observed wall", md)
    @test occursin("effective parallelism", md)
    @test occursin("When each shard ran", md)
    @test !occursin("did not overlap", md)
    @test occursin("FloorBound", md)      # the regime is named, not just described

    # The same work, one shard starting 300s late.
    late = [
        TestShards.ShardWindow("s1", 0.0, 60.0, 1, 40.0, 2),
        TestShards.ShardWindow("s2", 300.0, 325.0, 1, 5.0, 2),
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
    write(shards, "s1\t0.0\t60.0\t1\t40.0\t2\ns2\t300.0\t325.0\t1\t5.0\t2\n")
    @test TestShards.diagnose_cli([tsv, secs, shards, "--shards", "2"]) == 0
    # Absent or unreadable windows degrade to the model-only report rather than failing.
    @test TestShards.diagnose_cli([tsv, secs, joinpath(dir, "absent.tsv")]) == 0
end

# ── The account's budget, which is not a fact about the suite ─────────────────────────

@testset "asking for more shards than the account runs is its own regime" begin
    # A suite that could genuinely use ten shards, on an account that runs four jobs at once.
    even = Dict("u$i" => 10.0 for i in 1:20)

    unaware = TestShards.diagnose(even; n=10)
    @test TestShards.bottleneck(unaware) isa TestShards.WorkBound
    @test TestShards.usable_shards(unaware) == unaware.knee    # 10 shards, says the suite

    capped = TestShards.diagnose(even; n=10, budget=4)
    @test TestShards.bottleneck(capped) isa TestShards.BudgetBound
    @test TestShards.usable_shards(capped) == 4                # 4 jobs, says the account
    md = TestShards.remedy(capped)
    @test occursin("6 of them queue", md)                      # names the surplus
    @test occursin("shards: 4", md)

    # Asking for exactly the budget is not budget-bound; the suite's own limits apply again.
    @test !(
        TestShards.bottleneck(TestShards.diagnose(even; n=4, budget=4)) isa
        TestShards.BudgetBound
    )
    # And an unset budget changes nothing at all.
    @test TestShards.bottleneck(TestShards.diagnose(even; n=10, budget=0)) isa
        TestShards.WorkBound
end

@testset "a known budget also caps the recommendation in the other regimes" begin
    # FloorBound would recommend the knee. The knee is still more than the account can run.
    heavy = Dict("heavy" => 40.0, "a" => 5.0, "b" => 5.0, "c" => 5.0)
    d = TestShards.diagnose(heavy; n=2, budget=1)
    @test TestShards.usable_shards(d) <= 1
    # Without a budget the same suite recommends its knee, whatever that is.
    @test TestShards.usable_shards(TestShards.diagnose(heavy; n=2)) >= 1
end

@testset "the observed queue still wins over the declared budget" begin
    # Both are true; the measured one is reported, because it happened.
    t = Dict("u$i" => 10.0 for i in 1:8)
    late = [
        TestShards.ShardWindow("s1", 0.0, 100.0, 4, 40.0, 8),
        TestShards.ShardWindow("s2", 80.0, 100.0, 4, 40.0, 8),
    ]
    d = TestShards.diagnose(t; n=8, budget=2, shards=late)
    @test TestShards.bottleneck(d) isa TestShards.QueueBound
end
