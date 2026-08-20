# evidence.jl — moving a shard's evidence to the collector WITHOUT storage.
#
# The completeness gate compares what each shard was ASSIGNED against what it actually RAN, and that
# comparison is irreducibly cross-shard: `assign` is total only over the units the timing history has
# seen (everything else is placed by `_owns`'s round-robin over observation order), a shard checking
# itself compares `ctx.ran` against the very assignment that defined it, and under `Claimed` there is
# no assignment to compare against at all. So the evidence has to travel.
#
# It used to travel as an artifact. Actions artifact storage is metered in GigabyteHours against a
# per-period allowance, and once that allowance is crossed `CreateArtifact` refuses BEFORE any bytes
# are sent — a 0-byte artifact fails exactly as a large one does, and the accrual does not fall when
# artifacts are deleted. A suite that cannot verify itself for the rest of a billing period is not a
# suite. `actions/cache` was measured as a replacement and does not work: save succeeds and the entry
# is listed as active, restore misses every key.
#
# What is left needs no storage at all. A shard PRINTS its evidence; the collector reads that shard's
# job log back through the Actions API. Costs nothing, keeps nothing, needs only `actions: read` —
# which a fork pull request also has, unlike a write token.
#
# THE PARSING IS THE WHOLE RISK, WHICH IS WHY IT LIVES HERE AND NOT IN A STEP SCRIPT. The runner
# echoes a step's script into the log before running it, so the marker text appears TWICE: once as
# source, with `$(...)` unexpanded, and once as output. A collector that takes the first match
# decodes the literal string `$(base64 -w0 ev.tsv)` and reports success on garbage. That is a
# one-character bug, invisible in YAML, and pinned in `test/core/test_evidence.jl`.

const EVIDENCE_MARK = "TESTSHARDS-EVIDENCE"

# Base64's alphabet is exactly [A-Za-z0-9+/=], and an UNEXPANDED command substitution cannot be made
# of those characters — `$`, `(` and a space are all outside it. So the payload group discriminates
# the echoed source from the real output by CONSTRUCTION, and the collector needs no rule about which
# occurrence to prefer. An earlier version of this took the last match instead; that works until
# something else in the log happens to end with a marker, and "prefer the last" is a convention where
# this is a property.
const _EVIDENCE_RE = Regex("$(EVIDENCE_MARK):([A-Za-z0-9_.-]+):([A-Za-z0-9+/=]*):END")

"""
    evidence_line(sid, payload::AbstractString) -> String

The one line a shard prints so its `payload` can be recovered from its job log.

`payload` is base64-encoded, so a tab or a newline inside a unit name cannot break the framing — the
evidence is a TSV whose fields are exactly the strings the suite chose, and quoting them into a log
line any other way would make the collector's job depend on the units' names.
"""
function evidence_line(sid, payload::AbstractString)
    s = String(sid)
    occursin(r"^[A-Za-z0-9_.-]+$", s) || throw(
        ArgumentError(
            "evidence_line: shard id $(repr(s)) is not [A-Za-z0-9_.-]+. The id appears verbatim " *
            "in the marker, so a character the pattern does not accept would make the line " *
            "unreadable rather than merely unusual.",
        ),
    )
    return "$(EVIDENCE_MARK):$(s):$(_b64encode(payload)):END"
end

"""
    evidence_from_log(log::AbstractString) -> Union{Nothing,Pair{String,String}}

Recover `sid => payload` from one job's log, or `nothing` if the log carries no evidence.

Returns `nothing` rather than throwing: a shard that died before printing has no evidence and that is
a fact about the run for the caller to report, not an error in reading. A shard that printed a marker
whose payload will not decode DOES throw — that is corruption, and silently treating it as absent
would turn a broken transport into a missing shard.
"""
function evidence_from_log(log::AbstractString)
    m = match(_EVIDENCE_RE, log)
    m === nothing && return nothing
    return String(m.captures[1]) => _b64decode(String(m.captures[2]))
end

"""
    evidence_scan(logs) -> Dict{String,String}

`sid => payload` over an iterable of job logs, skipping the ones that carry no evidence.

Duplicate shard ids are refused. Two logs claiming the same shard means the collector is reading the
wrong set of jobs — most often a run's jobs across two ATTEMPTS rather than one attempt's — and
merging them would produce exactly the double-counting the completeness gate exists to detect, while
looking like a clean recovery.
"""
function evidence_scan(logs)
    out = Dict{String,String}()
    for log in logs
        e = evidence_from_log(log)
        e === nothing && continue
        haskey(out, e.first) && throw(
            ArgumentError(
                "evidence_scan: shard $(repr(e.first)) appears in two job logs. Read one " *
                "ATTEMPT's jobs (`/runs/{id}/attempts/{n}/jobs`), not the run's, or the same " *
                "shard from two attempts merges into one apparently complete run.",
            ),
        )
        out[e.first] = e.second
    end
    return out
end

# --- base64, written out because this package installs cold and declares no dependencies ----------
const _B64 = collect("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

function _b64encode(s::AbstractString)
    b = Vector{UInt8}(codeunits(s))
    io = IOBuffer()
    i = 1
    while i + 2 <= length(b)
        n = (Int(b[i]) << 16) | (Int(b[i + 1]) << 8) | Int(b[i + 2])
        for k in (18, 12, 6, 0)
            print(io, _B64[((n >> k) & 0x3f) + 1])
        end
        i += 3
    end
    rem = length(b) - i + 1
    if rem == 1
        n = Int(b[i]) << 16
        print(io, _B64[((n >> 18) & 0x3f) + 1], _B64[((n >> 12) & 0x3f) + 1], "==")
    elseif rem == 2
        n = (Int(b[i]) << 16) | (Int(b[i + 1]) << 8)
        print(
            io,
            _B64[((n >> 18) & 0x3f) + 1],
            _B64[((n >> 12) & 0x3f) + 1],
            _B64[((n >> 6) & 0x3f) + 1],
            "=",
        )
    end
    return String(take!(io))
end

function _b64decode(s::AbstractString)
    rev = Dict(c => i - 1 for (i, c) in enumerate(_B64))
    chars = [c for c in s if c != '=']
    all(c -> haskey(rev, c), chars) || throw(
        ArgumentError(
            "evidence: payload is not base64 — the marker is present but corrupt"
        ),
    )
    out = UInt8[]
    acc = 0
    bits = 0
    for c in chars
        acc = (acc << 6) | rev[c]
        bits += 6
        if bits >= 8
            bits -= 8
            push!(out, UInt8((acc >> bits) & 0xff))
        end
    end
    return String(out)
end

"""
    evidence_payload(dir, tag) -> String

The two files the completeness gate needs, as one string: every line of `shard-\$(tag).tsv` prefixed
`S\\t`, every line of `ran-\$(tag).tsv` prefixed `R\\t`.

One payload per shard rather than two markers, because a shard that printed one marker and died would
otherwise be indistinguishable from a shard that ran nothing — and "ran nothing" is precisely the
state the gate exists to catch.

The contents travel VERBATIM. `shard-*.tsv` and `ran-*.tsv` are the files
[`completeness_cli`](@ref) already reads, so changing how the evidence moves changes nothing about
what is checked.
"""
function evidence_payload(dir::AbstractString, tag::AbstractString)
    io = IOBuffer()
    for (prefix, name) in (("S", "shard-$(tag).tsv"), ("R", "ran-$(tag).tsv"))
        path = joinpath(dir, name)
        isfile(path) || continue
        for line in eachline(path)
            isempty(line) && continue
            println(io, prefix, '\t', line)
        end
    end
    return String(take!(io))
end

"""
    emit_evidence(dir, tag) -> Nothing

Print this shard's [`evidence_line`](@ref) to stdout, where the collector reads it back out of the
job log. Called from the shard's job AFTER the suite, so a failing suite still publishes what it ran.
"""
function emit_evidence(dir::AbstractString, tag::AbstractString)
    println(evidence_line(tag, evidence_payload(dir, tag)))
    return nothing
end

"""
    evidence_cli(args) -> Int

`args` is a directory of job logs, then the two output paths. Each file in the directory is one job's
log; shard ids come from the markers, not from the file names, so the collector need not name files
after shards it has not read yet.

Reconstructs `all-shards.tsv` and `all-ran.tsv` byte for byte as the artifact path produced them, so
[`completeness_cli`](@ref) is unchanged — only where its two inputs come from moves.

Returns 1 when no log carried evidence. That is the same refusal the artifact path made when
`parts/` was empty (`units observed = 0`), and it is deliberate: a run that cannot be verified must
not report as verified.
"""
function evidence_cli(args)
    length(args) == 3 || begin
        println(stderr, "usage: evidence_cli(logdir, all-shards.tsv, all-ran.tsv)")
        return 2
    end
    dir, shards_out, ran_out = args
    isdir(dir) || begin
        println(stderr, "evidence_cli: $(dir) is not a directory")
        return 2
    end
    files = sort(filter(isfile, readdir(dir; join=true)))
    found = evidence_scan(read(f, String) for f in files)
    if isempty(found)
        println(
            stderr,
            "evidence_cli: no job log carried a $(EVIDENCE_MARK) marker. Either no shard ran, or " *
            "the collector read the wrong jobs. Not treating this as an empty-but-complete run.",
        )
        return 1
    end
    open(shards_out, "w") do sh
        open(ran_out, "w") do rn
            for sid in sort(collect(keys(found)))
                for line in eachsplit(found[sid], '\n'; keepempty=false)
                    length(line) > 2 || continue
                    tag = line[1]
                    rest = SubString(line, 3)
                    if tag == 'S'
                        println(sh, rest)
                    elseif tag == 'R'
                        println(rn, rest)
                    else
                        nothing
                    end
                end
            end
        end
    end
    println(
        "Recovered evidence from $(length(found)) shard(s): ",
        join(sort(collect(keys(found))), " "),
    )
    return 0
end
