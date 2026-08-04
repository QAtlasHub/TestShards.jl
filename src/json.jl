# ─────────────────────────────────────────────────────────────────────────────────────
# Serialisation — minimal JSON, no dependency (the planner installs this package cold)
# ─────────────────────────────────────────────────────────────────────────────────────

function _jstr(s)
    return '"' *
           replace(
               String(s),
               '\\' => "\\\\",
               '"' => "\\\"",
               '\n' => "\\n",
               '\r' => "\\r",
               '\t' => "\\t",
           ) *
           '"'
end

_jval(v::Bool) = v ? "true" : "false"
_jval(v::Integer) = string(v)
_jval(v::Real) = isfinite(v) ? string(Float64(v)) : _jstr(string(v))
_jval(v::AbstractString) = _jstr(v)
_jval(v) = _jstr(string(v))

function _jobj(io, pairs)
    print(io, "{")
    for (i, (k, v)) in enumerate(pairs)
        i == 1 || print(io, ",")
        print(io, _jstr(k), ":", v)
    end
    return print(io, "}")
end

"A JSON array of `items`, each written by `write!(io, item)`. Used for sections and for the\nsection lists hanging off a record, which is the same shape twice."
function _jarray(items, write!)
    return sprint() do io
        print(io, "[")
        for (i, item) in enumerate(items)
            i == 1 || print(io, ",")
            write!(io, item)
        end
        return print(io, "]")
    end
end

function _jsection(io, s::Section)
    ev = sprint(
        io2 -> _jobj(io2, [k => _jval(v) for (k, v) in sort(collect(s.evidence); by=first)])
    )
    kids = _jarray(s.sections, _jsection)
    return _jobj(
        io,
        [
            "name" => _jval(s.name),
            "duration" => _jval(s.duration),
            "npass" => _jval(s.npass),
            "nfail" => _jval(s.nfail),
            "nerror" => _jval(s.nerror),
            "nbroken" => _jval(s.nbroken),
            "evidence" => ev,
            "sections" => kids,
        ],
    )
end

"One line of `records-*.jsonl`: the unit, its counts, and its testset tree."
function _jrecord(io, r::UnitRecord)
    return _jobj(
        io,
        [
            "key" => _jval(r.key),
            "index" => _jval(r.index),
            "shard" => _jval(r.shard),
            "duration" => _jval(r.duration),
            "npass" => _jval(r.npass),
            "nfail" => _jval(r.nfail),
            "nerror" => _jval(r.nerror),
            "nbroken" => _jval(r.nbroken),
            "sections" => _jarray(r.sections, _jsection),
        ],
    )
end

"""
    write_records(ctx, dir)

Write this shard's records as JSONL (one unit per line) plus its timings as TSV.

Two files because they have different consumers and different lifetimes: the TSV is the
planner's history and is merged into a single ledger, while the JSONL is the report's input and
is merged into one ordered document. Both key on the same unit key, so they always agree.
"""
function write_records(ctx::ShardContext, dir::AbstractString)
    mkpath(dir)
    tag = isempty(ctx.shard) ? "local" : ctx.shard
    open(joinpath(dir, "records-$(tag).jsonl"), "w") do io
        for r in ctx.records
            _jrecord(io, r)
            println(io)
        end
    end
    open(joinpath(dir, "timings-$(tag).tsv"), "w") do io
        for r in ctx.records
            println(io, r.key, '\t', round(r.duration; digits=3))
        end
    end
    # When this shard ran, as opposed to for how long. One row, so the shards' files
    # concatenate into the timeline of the run — see [`ShardWindow`](@ref). The last column is
    # how many units this shard OBSERVED, identical in every shard, and it is what
    # [`completeness`](@ref) measures the run against.
    open(joinpath(dir, "shard-$(tag).tsv"), "w") do io
        return println(
            io,
            tag,
            '\t',
            round(ctx.started; digits=3),
            '\t',
            round(time(); digits=3),
            '\t',
            length(ctx.records),
            '\t',
            round(sum(r -> r.duration, ctx.records; init=0.0); digits=3),
            '\t',
            ctx.seen,
        )
    end
    # WHICH positions in the observed sequence this shard took. Under `Claimed` ownership
    # nothing can derive that from the assignment, because there is no assignment: the only
    # record that a unit ran at all is the shard that ran it saying so.
    open(joinpath(dir, "ran-$(tag).tsv"), "w") do io
        for (index, key) in ctx.ran
            println(io, index, '\t', tag, '\t', key)
        end
    end
    # A flat view of the same tree, `unit <TAB> section path <TAB> seconds`. The planner never
    # reads this — it exists so [`diagnose`](@ref) can say WHERE inside a heavy unit to cut,
    # without anything downstream having to parse JSON.
    open(joinpath(dir, "sections-$(tag).tsv"), "w") do io
        for r in ctx.records
            _write_sections(io, r.key, "", r.sections)
        end
    end
    println("TestShards: wrote $(length(ctx.records)) records → $dir")
    return nothing
end

function _write_sections(io, key, prefix, sections)
    for s in sections
        path = isempty(prefix) ? s.name : string(prefix, " / ", s.name)
        println(io, key, '\t', path, '\t', round(s.duration; digits=3))
        _write_sections(io, key, path, s.sections)
    end
    return nothing
end

