# test_evidence.jl — the log-based evidence transport (#82).
#
# Every case here is a mistake that was actually made while measuring this against live Actions runs,
# not a hypothetical. The transport itself was verified end to end in a real run; what a unit test
# can add is the PARSING, which is where all four of those mistakes were, and which a step script
# would have hidden.

using TestShards
using Test

const TS = TestShards

@testset "round trip, including the characters that would break a delimiter" begin
    for payload in (
        "A\tunit_one\nR\tunit_one",
        "R\tweird unit name with spaces",
        "R\tname\twith\ttabs\nR\ttrailing newline\n",
        "",
        "R\t" * repeat("x", 5000),          # a long payload still fits one line
    )
        line = TS.evidence_line("s1", payload)
        @test !occursin('\n', line)          # ONE line, or the collector cannot frame it
        @test TS.evidence_from_log(line) == ("s1" => payload)
    end
end

@testset "the runner echoes the step script, so the marker appears TWICE" begin
    # This is the log a real shard produces. The first occurrence is the runner echoing the step's
    # source, with the command substitution UNEXPANDED; the second is the output. A collector that
    # takes the first match decodes the literal `$(base64 -w0 ev.tsv)` — which is what happened, and
    # it surfaced as `base64: invalid input` rather than as a wrong answer, purely by luck.
    payload = "A\tunitA\nR\tunitA"
    real = TS.evidence_line("s2", payload)
    log = """
    2026-08-20T03:35:56.2794941Z [36;1mecho "$(TS.EVIDENCE_MARK):s2:\$(base64 -w0 ev.tsv):END"[0m
    2026-08-20T03:35:56.2857806Z shell: /usr/bin/bash -e {0}
    2026-08-20T03:35:57.0947313Z $(real)
    """
    @test TS.evidence_from_log(log) == ("s2" => payload)

    # …and the property that makes it work is that base64's alphabet cannot spell an unexpanded
    # substitution, NOT an ordering convention. Asserted directly, so a future rewrite that switches
    # to "take the last match" has to notice it is weakening the rule.
    echoed_only = """
    2026-08-20T03:35:56Z [36;1mecho "$(TS.EVIDENCE_MARK):s2:\$(base64 -w0 ev.tsv):END"[0m
    """
    @test TS.evidence_from_log(echoed_only) === nothing
end

@testset "a log with no evidence is a fact, not an error" begin
    @test TS.evidence_from_log("") === nothing
    @test TS.evidence_from_log("just some test output\nand a stack trace\n") === nothing
    # a shard that died before printing: the collector must report a missing shard, and the
    # completeness gate must be the thing that fails, not the reader
    @test TS.evidence_from_log("ERROR: LoadError: something\n") === nothing
end

@testset "a corrupt payload throws rather than reading as absent" begin
    # `!` is outside base64's alphabet, so this does not match the marker at all and is absent…
    @test TS.evidence_from_log("$(TS.EVIDENCE_MARK):s1:!!!!:END") === nothing
    # …but a payload made of base64 characters that does not decode is corruption, and silently
    # calling that "no evidence" would turn a broken transport into a missing shard.
    @test_throws ArgumentError TS._b64decode("AB!CD")
end

@testset "two logs claiming one shard is refused" begin
    p = "R\tu"
    a = TS.evidence_line("s1", p)
    b = TS.evidence_line("s1", "R\tv")
    @test TS.evidence_scan([a]) == Dict("s1" => p)
    # the failure mode this guards: reading `/runs/{id}/jobs` (every attempt) instead of
    # `/runs/{id}/attempts/{n}/jobs`, which merges a re-run's shard with the original's and looks
    # like a clean recovery while double-counting
    @test_throws ArgumentError TS.evidence_scan([a, b])
    @test TS.evidence_scan([a, TS.evidence_line("s2", p)]) == Dict("s1" => p, "s2" => p)
    @test TS.evidence_scan(["nothing here", a]) == Dict("s1" => p)
end

@testset "a shard id that cannot survive the marker is refused at emit time" begin
    @test_throws ArgumentError TS.evidence_line("s:1", "R\tu")   # `:` is the delimiter
    @test_throws ArgumentError TS.evidence_line("", "R\tu")
    @test_throws ArgumentError TS.evidence_line("s 1", "R\tu")
    @test TS.evidence_line("s1", "R\tu") isa String
    @test TS.evidence_line("shard-1.a_b", "R\tu") isa String
end

@testset "evidence_cli reproduces the artifact path's two files, verbatim" begin
    # The REAL formats, read off `src/json.jl`: `shard-<tag>.tsv` is one row
    # `tag, started, finished, nrecords, seconds, seen`; `ran-<tag>.tsv` is rows of
    # `index, tag, key`. The transport must reproduce the concatenation byte for byte, because
    # `completeness_cli` is unchanged and parses exactly these.
    mktempdir() do dir
        out1 = joinpath(dir, "s1")
        mkpath(out1)
        write(joinpath(out1, "shard-s1.tsv"), "s1\t100.0\t160.5\t2\t42.0\t5\n")
        write(joinpath(out1, "ran-s1.tsv"), "1\ts1\tapi/test_a.jl\n3\ts1\tapi/test_c.jl\n")
        out2 = joinpath(dir, "s2")
        mkpath(out2)
        write(joinpath(out2, "shard-s2.tsv"), "s2\t101.0\t155.0\t1\t18.0\t5\n")
        write(joinpath(out2, "ran-s2.tsv"), "2\ts2\tapi/test_b.jl\n")

        logs = joinpath(dir, "logs")
        mkpath(logs)
        write(
            joinpath(logs, "job-1.txt"),
            "some suite output\n" *
            TS.evidence_line("s1", TS.evidence_payload(out1, "s1")) *
            "\n",
        )
        write(
            joinpath(logs, "job-2.txt"),
            TS.evidence_line("s2", TS.evidence_payload(out2, "s2")) * "\ntrailing\n",
        )

        sh = joinpath(dir, "all-shards.tsv")
        rn = joinpath(dir, "all-ran.tsv")
        @test TS.evidence_cli([logs, sh, rn]) == 0
        # byte for byte what `find parts -name 'shard-*.tsv' -exec cat {} + | sort -u` produced
        @test sort(collect(eachline(sh))) ==
            ["s1\t100.0\t160.5\t2\t42.0\t5", "s2\t101.0\t155.0\t1\t18.0\t5"]
        @test sort(collect(eachline(rn))) ==
            ["1\ts1\tapi/test_a.jl", "2\ts2\tapi/test_b.jl", "3\ts1\tapi/test_c.jl"]

        # and the recovered files are what the UNCHANGED completeness check consumes
        @test TS.completeness_cli([sh, rn]) isa Integer
    end
end

@testset "a shard that wrote no ran-*.tsv still publishes its shard row" begin
    # A shard that observed the suite and ran none of its units is a real state — every unit it
    # owned may have been claimed by another shard — and it must still be counted, or the run looks
    # smaller than it was.
    mktempdir() do dir
        write(joinpath(dir, "shard-s9.tsv"), "s9\t1.0\t2.0\t0\t0.0\t7\n")
        p = TS.evidence_payload(dir, "s9")
        @test occursin("S\ts9\t", p)
        @test !occursin("R\t", p)
        @test TS.evidence_from_log(TS.evidence_line("s9", p)) == ("s9" => p)
    end
end

@testset "no evidence at all is a FAILURE, not an empty-but-complete run" begin
    # The exact shape of the outage: `collect` downloaded zero artifacts, every step before the gate
    # reported success, and the gate correctly refused with `units observed = 0`. The replacement
    # must refuse in the same place for the same reason.
    mktempdir() do dir
        logs = joinpath(dir, "logs")
        mkpath(logs)
        write(joinpath(logs, "job-1.txt"), "a shard that printed nothing useful\n")
        @test TS.evidence_cli([logs, joinpath(dir, "s.tsv"), joinpath(dir, "r.tsv")]) == 1
    end
    @test TS.evidence_cli(["definitely/not/a/dir", "a", "b"]) == 2
    @test TS.evidence_cli(["only-one-arg"]) == 2
end
