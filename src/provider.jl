# ─────────────────────────────────────────────────────────────────────────────────────
# The testset a unit runs in
# ─────────────────────────────────────────────────────────────────────────────────────
#
# A unit runs inside a testset this package builds by hand rather than through `@testset`, so
# that a FAILED unit can still be read back (a top-level `@testset` throws before returning its
# tree). The type of that testset is therefore ours to choose — and another tool that captures a
# suite through `Test`'s own interface needs it to be THEIRS. Pinax, for one, renders a suite as
# a document: its `PinaxTestSet` recovers `got`/`want`/`tol` from each assertion, and it only
# sees a suite whose testsets are of its type. With a `DefaultTestSet` here, such a tool records
# nothing at all — and, being a tool that reports on tests, it reports that silently.
#
# So the type is a registered choice. A provider supplies three operations:
#
#   open(key)  -> an AbstractTestSet, or `nothing` to decline this unit (use the default)
#   close(ts)  -> nothing; run after the testset is popped, for a tool that attaches a finished
#                 set to its parent there (`Test.finish` does exactly that)
#   fold(ts)   -> the counts + structure, as PLAIN DATA (see `unit_fold`)
#
# `open` returning `nothing` is what keeps this inert: a provider decides per unit whether its
# capture is actually running, so merely having the tool installed changes nothing.

"""
Named operations for building and reading the testset a unit runs in — see
[`register_unit_provider!`](@ref). `nothing` when no tool has registered, which is the default
and is the case in every run that does not load one.
"""
const UNIT_PROVIDER = Ref{Any}(nothing)

"""
    register_unit_provider!(; name, open, close = _noop, fold)

Register the testset a unit runs in. Called from a package extension's `__init__` — an assignment
rather than a method override, so nothing is overwritten at precompile time.

  - `open(key::String)` returns the `AbstractTestSet` for a unit, or **`nothing`** to decline it
    and leave the default in place. Decline unless the tool's capture is actually running: a
    suite that merely depends on the tool must not have its testset type changed underneath it.
  - `close(ts)` runs after the testset is popped. A tool that attaches a finished testset to its
    parent does it here (`Test.finish`), which is the only moment at which it can.
  - `fold(ts)` returns the counts and structure as plain data — see [`unit_fold`](@ref). This is
    what keeps the balancing history and the completeness verdict correct when the testset is not
    ours, and it is the first thing to test: the same suite must yield the same numbers whichever
    testset type ran it.

Only one provider can be registered: two tools cannot both own the type of one testset, and
letting the last one win would surface as a mysteriously empty report rather than as an error.
"""
function register_unit_provider!(; name::AbstractString, open, close=_noop_close, fold)
    p = UNIT_PROVIDER[]
    if p !== nothing && p.name != name
        error("TestShards: a unit-testset provider is already registered ($(p.name)); \
               $(name) cannot also own the type of a unit's testset")
    end
    UNIT_PROVIDER[] = (; name=String(name), open, close, fold)
    return nothing
end

_noop_close(_) = nothing

# The testset for a unit: the provider's, if one is registered and wants this unit.
function _unit_testset(key::AbstractString)
    p = UNIT_PROVIDER[]
    p === nothing && return Test.DefaultTestSet(key)
    ts = p.open(String(key))
    return ts === nothing ? Test.DefaultTestSet(key) : ts
end

_unit_close(ts::Test.DefaultTestSet) = nothing
function _unit_close(ts)
    p = UNIT_PROVIDER[]
    return p === nothing ? nothing : p.close(ts)
end

"""
    unit_fold(ctx, ts) -> Section

The unit's [`Section`](@ref) tree. A `DefaultTestSet` is read directly; any other testset type
goes through the registered provider's `fold`, which returns plain data —

    (; name, duration, npass, nfail, nerror, nbroken, sections)

with `sections` a vector of the same shape (`duration` in seconds; the fields may be omitted and
default to zero). Plain data rather than a `Section`, so a provider living in another package
does not have to name this package's types.
"""
unit_fold(ctx::ShardContext, ts::Test.DefaultTestSet) = _section(ctx, ts)
function unit_fold(ctx::ShardContext, ts)
    p = UNIT_PROVIDER[]
    p === nothing && error(
        "TestShards: a unit ran in a $(typeof(ts)) with no provider registered to read it",
    )
    return _section_from(ctx, ts, p.fold(ts))
end

# Plain data -> Section. `evidence!` keys its dictionary on the testset OBJECT, so evidence
# recorded under a foreign testset is still found here; a provider's nested data carries no
# object to look up, so nested evidence is attached only at the unit's own level for now.
function _section_from(ctx::ShardContext, ts, d)
    kids = Section[_section_from(ctx, nothing, s) for s in get(d, :sections, ())]
    return Section(
        String(get(d, :name, "")),
        Float64(get(d, :duration, 0.0)),
        Int(get(d, :npass, 0)),
        Int(get(d, :nfail, 0)),
        Int(get(d, :nerror, 0)),
        Int(get(d, :nbroken, 0)),
        ts === nothing ? Dict{String,Any}() : get(ctx.evidence, ts, Dict{String,Any}()),
        kids,
    )
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Capturing a testset tree
# ─────────────────────────────────────────────────────────────────────────────────────

_duration(ts) =
    try
        te = ts.time_end
        te === nothing ? 0.0 : Float64(te - ts.time_start)
    catch
        0.0
    end

function _section(ctx::ShardContext, ts::Test.DefaultTestSet)
    npass = nfail = nerror = nbroken = 0
    kids = Section[]
    for r in ts.results
        if r isa Test.DefaultTestSet
            s = _section(ctx, r)
            push!(kids, s)
            npass += s.npass
            nfail += s.nfail
            nerror += s.nerror
            nbroken += s.nbroken
        elseif r isa Test.Pass
            npass += 1
        elseif r isa Test.Fail
            nfail += 1
        elseif r isa Test.Error
            nerror += 1
        elseif r isa Test.Broken
            nbroken += 1
        end
    end
    npass += ts.n_passed          # passes recorded directly on this testset
    ev = get(ctx.evidence, ts, Dict{String,Any}())
    return Section(ts.description, _duration(ts), npass, nfail, nerror, nbroken, ev, kids)
end

