# ─────────────────────────────────────────────────────────────────────────────────────
# Coverage — one report out of N shards
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    LcovFile

One source file's coverage, merged across the shards that reported it.

`branches` maps `(line, block, branch)` to the number of times it was taken, or `nothing` for
lcov's `-`: reached by no shard at all.
"""
struct LcovFile
    source::String
    lines::Dict{Int,Int}                                       # line → hits
    functions::Dict{String,Tuple{Int,Int}}                     # name → (line, hits)
    branches::Dict{NTuple{3,String},Union{Int,Nothing}}
end

function LcovFile(source::AbstractString)
    return LcovFile(
        String(source),
        Dict{Int,Int}(),
        Dict{String,Tuple{Int,Int}}(),
        Dict{NTuple{3,String},Union{Int,Nothing}}(),
    )
end

"`(lines, hits)` for one file, or summed over several."
function line_totals(f::LcovFile)
    return (length(f.lines), count(>(0), values(f.lines)))
end

function line_totals(fs::AbstractVector{LcovFile})
    t = map(line_totals, fs)
    return (sum(first, t; init=0), sum(last, t; init=0))
end

"""
    restore_counters(parts, dest = ".") -> Vector{String}

Put every shard's raw coverage counters back where their sources are, tagged so they cannot
collide. Returns the paths written.

Julia writes `Foo.jl.<pid>.cov` beside `Foo.jl`, and CoverageTools finds them by globbing
`Foo.jl.*.cov`. Shards run on different machines, so their PIDs can be equal — `s1` and `s4`
both producing `TestShards.jl.1234.cov` would have one silently overwrite the other, and the
lost shard's coverage would simply not appear. The shard label goes into the name to prevent
that, in the glob's wildcard where CoverageTools still matches it.

`parts` is the artifact download directory: one subdirectory per shard, named
`...coverage-<shard>`, each holding the counter files under their original relative paths.

This exists in the package rather than in the workflow because it is the step where coverage
can go missing without anything failing — and the last thing to hold that job silently reported
54.5% for a suite that covered 94.8% for as long as it existed.
"""
function restore_counters(parts::AbstractString, dest::AbstractString=".")
    written = String[]
    isdir(parts) || return written
    for entry in sort(readdir(parts; join=true))
        isdir(entry) || continue
        shard = _counter_shard(basename(entry))
        isempty(shard) && continue
        for (root, _, files) in walkdir(entry)
            for f in files
                endswith(f, ".cov") || continue
                rel = relpath(joinpath(root, f), entry)
                out = joinpath(dest, _tag_counter(rel, shard))
                mkpath(dirname(out))
                cp(joinpath(root, f), out; force=true)
                push!(written, out)
            end
        end
    end
    return written
end

"`testshards-coverage-s3` → `s3`; anything else → `\"\"`."
function _counter_shard(dir::AbstractString)
    i = findlast("coverage-", dir)
    i === nothing && return ""
    return String(dir[(last(i) + 1):end])
end

"`src/Foo.jl.123.cov` → `src/Foo.jl.123-s3.cov`, which `Foo.jl.*.cov` still matches."
function _tag_counter(rel::AbstractString, shard::AbstractString)
    return string(chop(rel; tail=length(".cov")), "-", shard, ".cov")
end

"""
    merge_lcov(paths) -> Vector{LcovFile}

Merge lcov tracefiles into **one record per source file**, in the order the files were first
seen.

Merging is a UNION, and that is the whole subtlety. Every shard loads the whole package but
runs only part of the suite, so each report marks only the lines *that* shard executed; a line
missed by seven shards and hit by the eighth is covered. Concatenating the tracefiles instead
leaves N records for one source file, which reads as N times the line count against a fraction
of the hits: this repository's own CI reported **54.5%** that way against a true **94.8%**, and
Codecov rejected the report outright.

Line hits, function hits and branch counts are summed per key; `LF`/`LH` and the rest are
recomputed by [`write_lcov`](@ref) rather than trusted from the inputs.

Malformed lines are skipped rather than raising. Coverage is a byproduct of the run, so a
truncated report must degrade the number, never fail the suite that produced it.
"""
function merge_lcov(paths)
    order = String[]
    seen = Dict{String,LcovFile}()
    for path in paths
        isfile(path) || continue
        cur = nothing
        for raw in eachline(path)
            ln = strip(raw)
            if startswith(ln, "SF:")
                src = String(ln[4:end])
                cur = get!(seen, src) do
                    push!(order, src)
                    return LcovFile(src)
                end
            elseif cur === nothing || ln == "end_of_record"
                cur = nothing
            elseif startswith(ln, "DA:")
                n, c = _lcov_pair(ln[4:end])
                # BOTH halves must parse. A row we cannot read is not evidence that the line
                # exists and went uncovered — recording it that way inflates LF and pushes the
                # percentage down, which is the failure direction that gets believed.
                (n === nothing || c === nothing) && continue
                cur.lines[n] = get(cur.lines, n, 0) + c
            elseif startswith(ln, "FN:")
                n, name = _lcov_split(ln[4:end])
                n === nothing && continue
                # FN gives the definition line; the count arrives separately as FNDA.
                _, hits = get(cur.functions, name, (n, 0))
                cur.functions[name] = (n, hits)
            elseif startswith(ln, "FNDA:")
                c, name = _lcov_split(ln[6:end])
                c === nothing && continue
                line, hits = get(cur.functions, name, (0, 0))
                cur.functions[name] = (line, hits + c)
            elseif startswith(ln, "BRDA:")
                p = split(ln[6:end], ',')
                length(p) == 4 || continue
                key = (String(p[1]), String(p[2]), String(p[3]))
                taken = tryparse(Int, p[4])
                prev = get(cur.branches, key, missing)
                if taken !== nothing
                    # A number from any shard supersedes "-", which only says that THAT shard
                    # never reached the branch.
                    base = (prev === missing || prev === nothing) ? 0 : prev
                    cur.branches[key] = base + taken
                elseif prev === missing
                    cur.branches[key] = nothing
                end
            end
        end
    end
    return [seen[s] for s in order]
end

# Split on the FIRST comma only: lcov function names may contain commas, line numbers may not.
function _split1(s)
    i = findfirst(==(','), s)
    i === nothing && return (String(s), false, "")
    return (String(s[1:prevind(s, i)]), true, String(s[nextind(s, i):end]))
end

# `"12,3"` → (12, 3); either side unparseable → nothing in that slot.
function _lcov_pair(s)
    a, _, b = _split1(s)
    return (tryparse(Int, a), tryparse(Int, b))
end

# `"12,name"` → (12, "name"); no comma → (nothing, "").
function _lcov_split(s)
    a, found, b = _split1(s)
    found || return (nothing, "")
    return (tryparse(Int, a), b)
end

"""
    write_lcov(path, files)

Write merged [`LcovFile`](@ref)s back out as a tracefile, recomputing every summary line
(`LF`/`LH`, `FNF`/`FNH`, `BRF`/`BRH`) from the merged records so they cannot disagree with them.
"""
function write_lcov(path::AbstractString, files::AbstractVector{LcovFile})
    open(path, "w") do io
        for f in files
            println(io, "SF:", f.source)
            fns = sort(collect(f.functions); by=kv -> (last(kv)[1], first(kv)))
            for (name, (line, _)) in fns
                println(io, "FN:", line, ",", name)
            end
            for (name, (_, hits)) in sort(fns; by=first)
                println(io, "FNDA:", hits, ",", name)
            end
            if !isempty(fns)
                println(io, "FNF:", length(fns))
                println(io, "FNH:", count(kv -> last(kv)[2] > 0, fns))
            end
            brs = sort(
                collect(f.branches);
                by=kv -> (something(tryparse(Int, first(kv)[1]), 0), first(kv)),
            )
            for (key, taken) in brs
                println(
                    io,
                    "BRDA:",
                    key[1],
                    ",",
                    key[2],
                    ",",
                    key[3],
                    ",",
                    taken === nothing ? "-" : taken,
                )
            end
            if !isempty(brs)
                println(io, "BRF:", length(brs))
                println(io, "BRH:", count(kv -> last(kv) !== nothing && last(kv) > 0, brs))
            end
            nlines, nhits = line_totals(f)
            for (n, c) in sort(collect(f.lines); by=first)
                println(io, "DA:", n, ",", c)
            end
            println(io, "LF:", nlines)
            println(io, "LH:", nhits)
            println(io, "end_of_record")
        end
    end
    return nothing
end

"""
    merge_lcov_cli(args = ARGS) -> Int

`out.info in1.info in2.info ...` — merge and write, printing a Markdown summary.

Used by the CI collect step, which is why this lives in the package at all: as a step script it
was unreachable from `Pkg.test()`, so nothing could catch it reporting 54.5% for a suite that
covered 94.8%.
"""
function merge_lcov_cli(args=ARGS)
    length(args) >= 2 ||
        (println(stderr, "usage: merge_lcov out.info in1.info [in2.info ...]"); return 1)
    out, inputs = args[1], args[2:end]
    files = merge_lcov(inputs)
    if isempty(files)
        println(stderr, "TestShards: no usable coverage in $(length(inputs)) file(s).")
        return 1
    end
    write_lcov(out, files)
    nlines, nhits = line_totals(files)
    println("### Coverage\n")
    println("| | |\n|---|--:|")
    pct = nlines > 0 ? round(100 * nhits / nlines; digits=1) : 0.0
    println("| coverage | ", pct, "% (", nhits, "/", nlines, " lines) |")
    println("| merged from | ", length(inputs), " shard reports |")
    println("| source files | ", length(files), " |")
    return 0
end

