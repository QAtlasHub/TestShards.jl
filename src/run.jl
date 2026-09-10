# ─────────────────────────────────────────────────────────────────────────────────────
# Running a unit
# ─────────────────────────────────────────────────────────────────────────────────────

# Run `f` with `ts` as the current testset, and leave the previous one current afterwards.
#
# Two implementations because Julia 1.13 changed what "current testset" IS. Through 1.12 it was
# a STACK in task-local storage, entered with `Test.push_testset` and left with
# `Test.pop_testset`. In 1.13 it became a `ScopedValue` (`Test.CURRENT_TESTSET`), which cannot
# be pushed and popped at all — a scoped value is entered, and `push_testset`/`pop_testset` no
# longer exist. `Test.@testset` itself switched to `@with` for the same reason.
#
# Both spellings reach into Test's internals, which is what breaks: neither `push_testset` nor
# `CURRENT_TESTSET` is public API. The alternative — using `@testset` and reading its return —
# is not available, because a top-level `@testset` throws instead of returning when the unit
# fails, which is the whole reason this function exists.
#
# `TESTSET_DEPTH` moves with `CURRENT_TESTSET` because two things read it, and both fail
# QUIETLY if it says 0. `Test.finish` uses it to decide whether a testset is top-level — a
# top-level one THROWS instead of recording, so a failing nested `@testset` inside a unit would
# be caught by `_run` below and filed as an `:nontest_error`, turning a FAIL into an ERROR. And
# stdlib's `@testset` infers an untyped nested set's type as
# `get_testset_depth() == 0 ? DefaultTestSet : typeof(get_testset())`, so a 0 there drops a
# registered provider's type (see `provider.jl`) — which is the case that reports nothing at all
# and reports it silently.
#
# The scope is inherited by tasks SPAWNED inside it, which task-local storage was not. For a
# unit that joins what it spawns that is strictly better — results that used to vanish into the
# fallback testset now land correctly. For one that does not join, it converts a deterministic
# drop into a race against `unit_fold`; `@shard`'s docstring states the requirement.
@static if VERSION >= v"1.13"
    function _with_testset(f, ts)
        return Base.ScopedValues.with(
            f,
            Test.CURRENT_TESTSET => ts,
            Test.TESTSET_DEPTH => Test.get_testset_depth() + 1,
        )
    end
else
    function _with_testset(f, ts)
        Test.push_testset(ts)
        try
            return f()
        finally
            Test.pop_testset()
        end
    end
end

function _key(ctx::ShardContext, path::AbstractString)
    return replace(relpath(abspath(path), ctx.root), '\\' => '/')
end

"""
    _run(ctx, key, body)

Observe a unit, and run `body` if this shard owns it. The observation counter advances either
way — that is what keeps `index`, and the round-robin fallback, identical across shards.

The testset is entered by hand rather than via `@testset` so that the tree can be read back
even when the unit failed: a top-level `@testset` throws before returning its result (still
true on 1.13 — measured, not assumed). Failure is re-signalled once, at the end of the whole
block.
"""
function _run(ctx::ShardContext, key::AbstractString, body)
    ctx.seen += 1
    index = ctx.seen
    _owns(ctx, key, index) || return nothing
    push!(ctx.ran, (index, String(key)))

    ts = _unit_testset(key)
    t0 = time()
    _with_testset(ts) do
        try
            body()
        catch err
            # An error escaping the unit (a load error, say) is recorded as the unit's error
            # rather than aborting the shard, so the remaining units still run and still get
            # recorded.
            Test.record(
                ts,
                # XXX: `Base.catch_stack` is an internal spelling of what is now
                # `Base.current_exceptions()`; measured on 1.13 the two return the same
                # `Base.ExceptionStack` (`==`), and upstream's own `@testset` has moved to the
                # public name. Left as-is so this commit changes one thing.
                Test.Error(
                    :nontest_error, Expr(:tuple), err, Base.catch_stack(), LineNumberNode(0)
                ),
            )
        end
    end
    # A tool that attaches a finished testset to its parent can only do it now that the parent is
    # current again — which is the whole reason a hand-entered testset needs this second step.
    _unit_close(ts)
    dt = time() - t0
    sec = unit_fold(ctx, ts)
    push!(
        ctx.records,
        UnitRecord(
            key,
            index,
            ctx.shard,
            dt,
            sec.npass,
            sec.nfail,
            sec.nerror,
            sec.nbroken,
            sec.sections,
        ),
    )
    status = sec.nfail + sec.nerror == 0 ? "ok" : "FAIL"
    println(
        "  [$(status)] $(key)  $(round(dt; digits=2))s  ($(sec.npass) pass, $(sec.nfail) fail, $(sec.nerror) error)",
    )
    return nothing
end

# Paths are resolved against the file that wrote `@shard`, matching what Julia's own `include`
# does inside a script — NOT against `pwd()`, which differs between a local run and `Pkg.test`.
function _resolve(ctx::ShardContext, path)
    return isabspath(path) ? String(path) : joinpath(ctx.root, String(path))
end

"Include a file as part of the current unit, without opening a new one."
_plain_include(path) = Base.include(Main, _resolve(_ctx(), path))

# The `include` seen inside a `@shard` block: each call is its own unit, unless we are already
# inside a `@unit`, in which case it is part of that one.
function _include(path)
    ctx = _ctx()
    ctx.depth > 0 && return Base.include(Main, _resolve(ctx, path))
    file = _resolve(ctx, path)
    return _run(ctx, _key(ctx, file), () -> Base.include(Main, file))
end

function _run_unit(name::AbstractString, body)
    ctx = _ctx()
    if ctx.depth > 0                     # nested @unit: already inside a unit, just run it
        return body()
    end
    ctx.depth += 1
    try
        _run(ctx, String(name), body)
    finally
        ctx.depth -= 1
    end
    return nothing
end

# ─────────────────────────────────────────────────────────────────────────────────────
# Evidence
# ─────────────────────────────────────────────────────────────────────────────────────

"""
    evidence!(; kwargs...)

Attach evidence to the `@testset` currently running — what was checked, to what tolerance, on
what grounds — so the report can state it without a reader going to the source:

```julia
@testset "inflation preserves the tiling" begin
    err = norm(inflate(t) - reference)
    evidence!(; tolerance = 1e-12, achieved = err, oracle = "closed-form inflation matrix")
    @test err < 1e-12
end
```

Values that are not `Real`, `Bool`, or `AbstractString` are stored as their `string()` form, so
anything is safe to pass. Outside a `@shard` block this is a no-op, which keeps a test file
runnable on its own.
"""
function evidence!(; kwargs...)
    ctx = CURRENT[]
    ctx === nothing && return nothing
    ts = try
        Test.get_testset()
    catch
        return nothing
    end
    d = get!(ctx.evidence, ts, Dict{String,Any}())
    for (k, v) in kwargs
        d[String(k)] = v isa Union{Real,Bool,AbstractString} ? v : string(v)
    end
    return nothing
end

"""
    evidence(ts) -> Dict{String,Any}

What [`evidence!`](@ref) recorded against a testset — or an empty dictionary when it recorded nothing.

It is keyed on the testset **object**, so it works whichever type that testset is, including one a
[`register_unit_provider!`](@ref) provider handed out. That is the point of exposing it: a provider
whose tool renders a suite can put what a test *established* into its output, beside whether the test
passed, and it does not have to reach into this package's internals to do so.

The evidence for a whole subtree is reachable by walking the testset's own children — a provider's
type knows its nesting, and this reads one node at a time.
"""
function evidence(ts)
    ctx = CURRENT[]
    ctx === nothing && return Dict{String,Any}()
    return get(ctx.evidence, ts, Dict{String,Any}())
end

# ─────────────────────────────────────────────────────────────────────────────────────
# The block
# ─────────────────────────────────────────────────────────────────────────────────────

function _begin(root::AbstractString; env=ENV)
    # Installing a second context would replace the first one's, and the first block would then
    # fail on its next `include` with "not inside a @shard block" — a long way from the cause.
    # `@shard` blocks do not nest, and the way this happens in practice is a test that wants a
    # context and reaches for `_begin` to get one, inside the suite the driver is running.
    CURRENT[] === nothing || error(
        "TestShards: a @shard block is already running. Blocks do not nest, and a second " *
        "`_begin` would silently take the first one's place.",
    )
    units_spec = get(env, ENV_UNITS, "")
    units = if isempty(units_spec)
        nothing
    else
        Set(String(strip(x)) for x in split(units_spec, ",") if !isempty(strip(x)))
    end
    shard = get(env, ENV_ID, "")
    n = something(tryparse(Int, get(env, ENV_N, "")), 1)

    if !isempty(shard) && units === nothing && n <= 1
        error(
            "$ENV_ID is set but neither $ENV_UNITS (manual) nor $ENV_N > 1 (auto) is — every " *
            "shard would run the WHOLE suite and pass for the wrong reason. Fix the workflow.",
        )
    end
    timings = load_timings(get(env, ENV_TIMINGS, ""))
    ownership = _ownership(env)
    # A job start reported by CI wins: it includes the checkout, the depot restore and the
    # precompilation, which are the bulk of what a shard pays and are invisible from in here.
    # A malformed value falls back rather than failing — this is measurement, not correctness.
    job_start = something(tryparse(Float64, get(env, ENV_JOB_START, "")), time())
    ctx = ShardContext(
        abspath(root),
        shard,
        units,
        n,
        units === nothing ? assign(timings, n) : Dict{String,String}(),
        0,
        0,
        0,
        job_start,
        ownership,
        timings,
        Tuple{Int,String}[],
        UnitRecord[],
        IdDict{Any,Dict{String,Any}}(),
    )
    mode = if units !== nothing
        "manual ($(length(units)) units)"
    elseif isempty(shard)
        "ALL"
    else
        "auto $(shard)/$(n) ($(length(timings)) timed)"
    end
    println("TestShards: $mode")
    CURRENT[] = ctx
    return ctx
end

function _end(ctx::ShardContext; env=ENV)
    CURRENT[] = nothing
    out = get(env, ENV_OUT, "")
    isempty(out) || write_records(ctx, out)

    npass = sum(r -> r.npass, ctx.records; init=0)
    nfail = sum(r -> r.nfail, ctx.records; init=0)
    nerror = sum(r -> r.nerror, ctx.records; init=0)
    println(
        "TestShards: $(length(ctx.records))/$(ctx.seen) units ran — " *
        "$(npass) pass, $(nfail) fail, $(nerror) error",
    )
    # Failure is signalled ONCE, here, because the per-unit testsets were driven by hand
    # precisely so that a failure would not abort the shard before everything was recorded.
    nfail + nerror == 0 || error(
        "TestShards: $(nfail) failed and $(nerror) errored across $(length(ctx.records)) units",
    )
    return nothing
end

"""
    @shard begin ... end

Run the block with `include` shadowed, so each include is a shardable unit. See the module
docstring for the whole picture.

The test root — what unit keys are relative to — is the directory of the file this macro is
written in, so keys are stable no matter where CI runs from.

A unit must `wait`/`fetch`/`@sync` every task it spawns before its own top-level code returns.
A unit is folded and reported the moment that code returns, so a result arriving later is
recorded into a testset nobody reads again. On Julia ≥ 1.13 this is worse than it sounds: a
spawned task inherits the unit's testset for its whole life, so a LATE FAILURE lands on the
right object after the unit has already been reported green. Before 1.13 the same result was
dropped on the floor instead — deterministically, which is the only thing that made it
survivable.
"""
macro shard(body)
    root = abspath(dirname(String(__source__.file)))
    return esc(quote
        local __ts_ctx = $(_begin)($root)
        try
            let include = $(_include)
                $body
            end
        finally
            $(_end)(__ts_ctx)
        end
    end)
end

"""
    @unit "name" begin ... end

Treat everything in the block as ONE shardable unit: it runs in a single shard, in the order
written. This is the only way to keep order-dependent files together, since across shards order
is not preserved.

It is also the manual-mode handle: in manual mode a shard is given unit names to run, so naming
a unit is how you assign work by hand rather than by measured time.
"""
macro unit(name, body)
    return esc(quote
        $(_run_unit)($name, () -> let include = $(_plain_include)
            $body
        end)
    end)
end
