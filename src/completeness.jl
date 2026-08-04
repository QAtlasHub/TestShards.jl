# ─────────────────────────────────────────────────────────────────────────────────────
# Completeness — did the run cover the suite, or only look like it did
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    Completeness

Whether the shards between them ran every unit they observed, exactly once.

Under [`Assigned`](@ref) this is a theorem: assignment is a total function of the observed
sequence, so a unit no shard claims cannot exist. Under [`Claimed`](@ref) it is not — a shard
that claims a unit and then dies or is cancelled leaves the unit claimed and never run, and the
merged records are short by one with nothing to say so. That is the green-but-wrong outcome
this package refuses everywhere else, which is why claiming does not ship without this check.

It is worth running under both. It costs nothing, and it turns the guarantee from something the
design argues into something each run demonstrates.
"""
struct Completeness
    observed::Int                       # units the shards saw, agreed across shards
    ran::Vector{Int}                    # positions that ran, sorted
    missed::Vector{Int}                 # observed but never run — a hole
    duplicated::Vector{Int}             # run by more than one shard
    disagreed::Bool                     # shards reported different observation counts
    placement::Dict{Int,Vector{String}} # position → the shards that ran it
end

function complete(c::Completeness)
    return isempty(c.missed) && isempty(c.duplicated) && !c.disagreed && c.observed > 0
end

"""
    load_ran(path) -> Vector{Tuple{Int,String,String}}

Read merged `ran-*.tsv` rows: position, shard, unit key. Malformed rows are skipped — but note
that a row skipped here reads as a MISSING unit downstream, which fails the run rather than
passing it quietly. That is the safe direction for this particular file.
"""
function load_ran(path::AbstractString)
    rows = Tuple{Int,String,String}[]
    (isempty(path) || !isfile(path)) && return rows
    for ln in eachline(path)
        parts = split(rstrip(ln, ['\n', '\r']), '\t')
        length(parts) == 3 || continue
        i = tryparse(Int, parts[1])
        i === nothing && continue
        push!(rows, (i, String(parts[2]), String(parts[3])))
    end
    return rows
end

"""
    completeness(windows, ran) -> Completeness

Check the run against itself: every shard reports how many units it OBSERVED, and each reports
which positions it took. The two must reconcile.
"""
function completeness(
    windows::AbstractVector{ShardWindow}, ran::AbstractVector{<:Tuple{Int,String,String}}
)
    seens = unique(w.seen for w in windows)
    observed = isempty(seens) ? 0 : maximum(seens)
    placement = Dict{Int,Vector{String}}()
    for (i, shard, _) in ran
        push!(get!(placement, i, String[]), shard)
    end
    positions = sort(collect(keys(placement)))
    return Completeness(
        observed,
        positions,
        [i for i in 1:observed if !haskey(placement, i)],
        [i for i in positions if length(placement[i]) > 1],
        length(seens) > 1,
        placement,
    )
end

"""
    completeness_report(c) -> String

The check as Markdown, naming what is missing rather than only that something is.
"""
function completeness_report(c::Completeness)
    io = IOBuffer()
    ok = complete(c)
    println(io, "### Completeness\n")
    println(io, "| | |\n|---|--:|")
    println(io, "| units observed | ", c.observed, " |")
    println(io, "| units run | ", length(c.ran), " |")
    println(io, "| verdict | ", ok ? "**every unit ran exactly once**" : "**FAILED**", " |")
    if c.disagreed
        println(
            io,
            "\n> The shards did not agree on how many units the suite has. They did not all ",
            "observe the same sequence, so nothing downstream — the split, the indices, the ",
            "merged records — means what it claims to.",
        )
    end
    if !isempty(c.missed)
        println(
            io,
            "\n> **",
            length(c.missed),
            " unit(s) never ran**: position(s) ",
            join(c.missed, ", "),
            ". Under claimed ownership this is what a shard dying after it claimed work looks ",
            "like — the run is green and the suite was not tested.",
        )
    end
    if !isempty(c.duplicated)
        println(
            io,
            "\n> **",
            length(c.duplicated),
            " unit(s) ran twice**: ",
            join(("$(i) on " * join(c.placement[i], " and ") for i in c.duplicated), "; "),
            ". Wasted rather than wrong, but it means two shards both believed they owned it.",
        )
    end
    return String(take!(io))
end

"""
    completeness_cli(args = ARGS) -> Int

`shards.tsv ran.tsv` — 0 if the run covered its suite, 1 if it did not. The CI gate calls this,
which is the only reason claiming is safe to offer at all.
"""
function completeness_cli(args=ARGS)
    length(args) >= 2 ||
        (println(stderr, "usage: completeness shards.tsv ran.tsv"); return 1)
    c = completeness(load_shards(args[1]), load_ran(args[2]))
    print(completeness_report(c))
    if c.observed == 0
        println(
            stderr,
            "TestShards: no shard reported how many units it observed — cannot verify the run.",
        )
        return 1
    end
    return complete(c) ? 0 : 1
end

