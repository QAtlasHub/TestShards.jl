using Test, TestShards

# The bug this file exists to prevent: the collect job merged the shards' lcov reports by
# concatenating them, which leaves N records for one source file. Summing LF/LH across those
# records reported 54.5% for a suite that covered 94.8%, and Codecov rejected the report
# outright. It survived because the merge lived in a workflow step, where no test could reach
# it. It lives here now.

"Write a minimal lcov tracefile: `src => Dict(line => hits)`."
function write_trace(path, files)
    open(path, "w") do io
        for (src, lines) in files
            println(io, "SF:", src)
            for (n, c) in sort(collect(lines); by=first)
                println(io, "DA:", n, ",", c)
            end
            println(io, "LF:", length(lines))
            println(io, "LH:", count(>(0), values(lines)))
            println(io, "end_of_record")
        end
    end
    return path
end

@testset "merging shard reports is a union, not a sum" begin
    d = mktempdir()
    # Two shards of one suite: each loads the whole file, each runs a different half. Line 3 is
    # covered by neither; line 1 by both.
    a = write_trace(
        joinpath(d, "a.info"), ["src/M.jl" => Dict(1 => 2, 2 => 5, 3 => 0, 4 => 0)]
    )
    b = write_trace(
        joinpath(d, "b.info"), ["src/M.jl" => Dict(1 => 1, 2 => 0, 3 => 0, 4 => 7)]
    )

    merged = TestShards.merge_lcov([a, b])
    f = only(merged)                          # ONE record, not two
    @test f.source == "src/M.jl"
    @test f.lines[1] == 3                     # hits add up
    @test f.lines[2] == 5                     # covered by a only
    @test f.lines[4] == 7                     # covered by b only
    @test f.lines[3] == 0                     # covered by neither
    @test TestShards.line_totals(f) == (4, 3)  # 4 lines, 3 hit — the union

    # What the old concatenation reported instead: 8 lines, 4 hit → 50%.
    naive_lines = 4 + 4
    naive_hits = 2 + 2
    @test naive_hits / naive_lines < 3 / 4    # the understatement is real, not a rounding
end

@testset "the written report has one record per file, with recomputed totals" begin
    d = mktempdir()
    a = write_trace(joinpath(d, "a.info"), ["src/M.jl" => Dict(1 => 1, 2 => 0)])
    b = write_trace(joinpath(d, "b.info"), ["src/M.jl" => Dict(1 => 0, 2 => 3)])
    out = joinpath(d, "merged.info")
    TestShards.write_lcov(out, TestShards.merge_lcov([a, b]))

    text = read(out, String)
    @test count("SF:src/M.jl", text) == 1     # the whole point
    @test occursin("LF:2\n", text)
    @test occursin("LH:2\n", text)            # both lines covered, by different shards
    @test count("end_of_record", text) == 1
    # And it round-trips: merging the merged report changes nothing.
    again = only(TestShards.merge_lcov([out]))
    @test TestShards.line_totals(again) == (2, 2)
end

@testset "several source files keep their first-seen order" begin
    d = mktempdir()
    a = write_trace(
        joinpath(d, "a.info"), ["src/A.jl" => Dict(1 => 1), "src/B.jl" => Dict(1 => 0)]
    )
    b = write_trace(
        joinpath(d, "b.info"), ["src/B.jl" => Dict(1 => 4), "src/C.jl" => Dict(1 => 1)]
    )
    merged = TestShards.merge_lcov([a, b])
    @test [f.source for f in merged] == ["src/A.jl", "src/B.jl", "src/C.jl"]
    @test TestShards.line_totals(merged) == (3, 3)   # B is covered by the second shard
end

@testset "function and branch records merge too" begin
    d = mktempdir()
    write(
        joinpath(d, "a.info"),
        """
        SF:src/M.jl
        FN:10,solve
        FNDA:2,solve
        BRDA:12,0,0,1
        BRDA:12,0,1,-
        DA:10,2
        end_of_record
        """,
    )
    write(
        joinpath(d, "b.info"),
        """
        SF:src/M.jl
        FN:10,solve
        FNDA:5,solve
        BRDA:12,0,0,-
        BRDA:12,0,1,3
        DA:10,5
        end_of_record
        """,
    )
    f = only(TestShards.merge_lcov([joinpath(d, "a.info"), joinpath(d, "b.info")]))
    @test f.functions["solve"] == (10, 7)                 # counts add, line kept
    @test f.branches[("12", "0", "0")] == 1               # "-" from b does not erase a's 1
    @test f.branches[("12", "0", "1")] == 3               # nor a's "-" erase b's 3

    out = joinpath(d, "m.info")
    TestShards.write_lcov(out, TestShards.merge_lcov([joinpath(d, "a.info")]))
    text = read(out, String)
    @test occursin("FNF:1\n", text) && occursin("FNH:1\n", text)
    @test occursin("BRF:2\n", text) && occursin("BRH:1\n", text)   # one taken, one "-"
    @test occursin("BRDA:12,0,1,-\n", text)                        # "-" survives the round trip
end

@testset "a truncated or malformed report degrades the number, never the run" begin
    d = mktempdir()
    write(
        joinpath(d, "bad.info"),
        """
        DA:1,1
        SF:src/M.jl
        DA:not-a-number,3
        DA:5,
        DA:7,2
        FNDA:oops
        BRDA:1,2
        """,                                   # no end_of_record either
    )
    f = only(TestShards.merge_lcov([joinpath(d, "bad.info")]))
    @test f.lines == Dict(7 => 2)              # the one parseable row, and no exception
    @test isempty(f.functions)
    @test isempty(f.branches)
    # A path that does not exist is skipped, not fatal.
    @test isempty(TestShards.merge_lcov([joinpath(d, "absent.info")]))
    @test isempty(TestShards.merge_lcov(String[]))
end

@testset "the CLI writes the report and summarises it" begin
    d = mktempdir()
    a = write_trace(joinpath(d, "a.info"), ["src/M.jl" => Dict(1 => 1, 2 => 0)])
    b = write_trace(joinpath(d, "b.info"), ["src/M.jl" => Dict(1 => 0, 2 => 1)])
    out = joinpath(d, "lcov.info")

    md = mktemp() do path, io
        redirect_stdout(io) do
            @test TestShards.merge_lcov_cli([out, a, b]) == 0
        end
        flush(io)
        read(path, String)
    end
    @test isfile(out)
    @test occursin("100.0% (2/2 lines)", md)
    @test occursin("merged from | 2 shard reports", md)

    @test TestShards.merge_lcov_cli([out]) == 1                       # too few arguments
    @test TestShards.merge_lcov_cli([out, joinpath(d, "absent")]) == 1  # nothing usable IS an error
end
