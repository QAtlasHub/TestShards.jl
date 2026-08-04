"""
    diagnose_report(d) -> String

The diagnosis as Markdown, for a CI job summary.
"""
function diagnose_report(d::Diagnosis)
    io = IOBuffer()
    println(io, "### Shard diagnosis\n")
    println(io, "| | |\n|---|--:|")
    for (label, value) in _facts(d)
        println(io, "| ", label, " | ", value, " |")
    end
    # EVERY regime that holds, not only the one the default policy ranks first. Several are
    # usually true and they want different things — split the floor unit, or stop splitting —
    # so which to act on is a decision about this repository, and reporting one while dropping
    # the rest would be making that decision here.
    for (i, b) in enumerate(bottlenecks(d))
        println(
            io, "\n> ", i == 1 ? "**" : "*also* **", nameof(typeof(b)), ".** ", remedy(b, d)
        )
    end
    println(io, "\n<details><summary>Heaviest units</summary>\n")
    println(io, "| unit | seconds | share |\n|---|--:|--:|")
    for (k, v) in first(d.units, min(10, length(d.units)))
        println(
            io, "| `", k, "` | ", _s(v), " | ", round(100 * v / d.serial; digits=1), "% |"
        )
    end
    if !isempty(d.split_here)
        println(io, "\n**Split `", d.floor_unit, "` here to lower the floor:**\n")
        println(io, "| section | seconds |\n|---|--:|")
        for (name, v) in first(d.split_here, min(6, length(d.split_here)))
            println(io, "| ", name, " | ", _s(v), " |")
        end
    end
    println(io, "\n</details>")
    o = d.observed
    if o !== nothing
        println(io, "\n<details><summary>When each shard ran</summary>\n")
        println(io, "| shard | started | window | units | on units | fixed |")
        println(io, "|---|--:|--:|--:|--:|--:|")
        for w in o.windows
            println(
                io,
                "| `",
                w.shard,
                "` | +",
                _s(w.started - o.started),
                " | ",
                _s(window(w)),
                " | ",
                w.nunits,
                " | ",
                _s(w.unit_seconds),
                " | ",
                _s(fixed_cost(w)),
                " |",
            )
        end
        println(io, "\n</details>")
    end
    return String(take!(io))
end

"""
    diagnose_cli(args = ARGS) -> Int

`timings.tsv [sections.tsv [shards.tsv]] [--shards N] [--fixed SECONDS] [--ends FILE]
[--budget JOBS]`, printing the Markdown report. Used by the CI collect step so every run says where the suite is badly shaped.

The files are positional and in that order, because each one only adds detail to the answer:
the timings alone say how many shards the suite can use, the sections say where to cut the unit
that limits it, and the shard windows say whether the shards actually ran at the same time.
"""
function diagnose_cli(args=ARGS)
    files = String[]
    n, fixed, ends, budget = 8, 0.0, "", 0
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--shards" && i < length(args)
            n = something(tryparse(Int, args[i + 1]), 8)
            i += 2
        elseif a == "--fixed" && i < length(args)
            fixed = something(tryparse(Float64, args[i + 1]), 0.0)
            i += 2
        elseif a == "--ends" && i < length(args)
            ends = args[i + 1]
            i += 2
        elseif a == "--budget" && i < length(args)
            budget = something(tryparse(Int, args[i + 1]), 0)
            i += 2
        else
            push!(files, a)
            i += 1
        end
    end
    isempty(files) && (
        println(
            stderr,
            "usage: timings.tsv [sections.tsv [shards.tsv]] [--shards N] [--fixed S] [--ends F] " *
            "[--budget J]",
        );
        return 1
    )
    timings = load_timings(files[1])
    if isempty(timings)
        println(stderr, "TestShards: no timing history yet — nothing to diagnose.")
        return 0
    end
    sections = if length(files) > 1
        load_sections(files[2])
    else
        Dict{String,Vector{Pair{String,Float64}}}()
    end
    shards = length(files) > 2 ? load_shards(files[3]; ends) : ShardWindow[]
    print(diagnose_report(diagnose(timings; n, fixed, sections, shards, budget)))
    return 0
end

"""
    matrix_json(n) -> String

The GitHub Actions `matrix: include:` array for `n` shards.

It carries only labels. Which units a shard runs is decided **inside** the shard, from the
timing history, so the planning job never loads the package under test and never needs to know
what the suite contains.
"""
function matrix_json(n::Integer)
    n >= 1 || throw(ArgumentError("TestShards.matrix_json: n must be ≥ 1, got $n"))
    return "[" * join(("{\"sid\":\"s$(b)\"}" for b in 1:n), ",") * "]"
end
