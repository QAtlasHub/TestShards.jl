# Testset internals

A unit runs inside a testset this package enters by hand, not through `@testset`. That one
decision is why `Test`'s internals appear in `src/run.jl` at all, and why the file carries two
implementations of the same six lines.

## Why not `@testset`

A top-level `@testset` **throws instead of returning** when something inside it fails. TestShards
needs the opposite: a failed unit's tree has to be readable, because the counts in
`unit_fold` and the per-unit record are built from it, and because the remaining units
still have to run. So `_run` enters the testset itself, runs the body, leaves, and re-signals
failure once at the end of the whole shard.

Measured on 1.10, 1.12 and 1.13 alike — this is not a version-specific quirk that a newer Julia
removed the need for.

## What Julia 1.13 changed

Through 1.12, "the current testset" was a **stack in task-local storage** (quoting
`stdlib/Test/src/Test.jl`, so these two blocks are not runnable here — the first no longer
exists on 1.13, the second not before it):

```julia
function push_testset(ts::AbstractTestSet)                     # julia ≤ 1.12
    testsets = get(task_local_storage(), :__BASETESTNEXT__, AbstractTestSet[])
    push!(testsets, ts)
    setindex!(task_local_storage(), testsets, :__BASETESTNEXT__)
end
```

In 1.13 it is a scoped value:

```julia
const CURRENT_TESTSET = ScopedValue{AbstractTestSet}(FallbackTestSet())   # julia ≥ 1.13
const TESTSET_DEPTH   = ScopedValue{Int}(0)
```

A scoped value cannot be pushed and popped — it is *entered* — so `push_testset` and
`pop_testset` are gone rather than renamed. This was deliberate and announced: Julia's own
`NEWS.md` for 1.13 carries "The testset stack was changed to use `ScopedValue` rather than task
local storage", and `Test.@testset` itself now expands to `@with(CURRENT_TESTSET => ts,
TESTSET_DEPTH => get_testset_depth() + 1, expr)`.

`_with_testset` is that difference and nothing else. Everything downstream — `_unit_close`,
`unit_fold`, the records, the printed line — sees the same thing either way, which is the
contract both implementations have to meet:

```jldoctest
julia> using Test, TestShards

julia> ts = Test.DefaultTestSet("a unit");

julia> outer = Test.get_testset_depth();

julia> TestShards._with_testset(ts) do
           Test.get_testset() === ts, Test.get_testset_depth() - outer
       end
(true, 1)

julia> Test.get_testset_depth() == outer
true
```

The depth is asserted as an INCREMENT, not as `1`: it counts from whatever is already open, so
the absolute value depends on the caller — inside Documenter's own testset this block reads `2`
where a bare session reads `1`. One level deeper, and back where it started, is the property
`_with_testset` actually has.

## Why the branch tests the name, not the version

`@static if isdefined(Test, :CURRENT_TESTSET)`, not `VERSION >= v"1.13"`.

The two agree on every released version — measured on 1.10, 1.11, 1.12, 1.13 and 1.14-DEV — and
disagree in exactly the place a version test is wrong, because a prerelease sorts before its own
release:

```jldoctest
julia> v"1.13.0-rc1" >= v"1.13"
false
```

An rc **has** `CURRENT_TESTSET`, so a version test would send it down the branch that calls
`push_testset` and it would die on the very bug this split exists to avoid.

## Why `TESTSET_DEPTH` moves with `CURRENT_TESTSET`

Two things read the depth, and both fail quietly when it reads `0`:

- `Test.finish` decides from it whether a testset is top-level, and a top-level one **throws
  instead of recording**. A failing nested `@testset` inside a unit would then be caught by
  `_run`'s own `catch` and filed as a `:nontest_error` — a **fail reported as an error**.
- stdlib's `@testset` infers an untyped nested set's type as
  `get_testset_depth() == 0 ? DefaultTestSet : typeof(get_testset())`. A `0` there drops a
  registered provider's testset type (see [Composing](composing.md)), which is the case that
  records nothing at all and reports that silently.

`test/core/test_failure.jl` pins the first of these directly.

## Tasks spawned inside a unit

A scoped value is inherited by tasks spawned inside its scope; task-local storage was not. For a
unit that `wait`s or `fetch`es everything it spawns, 1.13 is strictly better — results that used
to vanish into the fallback testset now land on the right testset. For a unit that does **not**
join, the same inheritance means a late result targets a testset the shard has already folded
and reported, turning a deterministic drop into a race.

So: **a unit must join every task it spawns before its own top-level code returns.** This is
stated on `@shard` as well, because it is a requirement on the caller, not an internal detail.

## What is still not public

Neither `push_testset` nor `CURRENT_TESTSET` is exported or marked `public`. This package
therefore depends on an internal on both sides of the branch, and a later reshuffle upstream
will break it again in the same way. The public route — `@testset` and its return value — is
unavailable for the reason at the top of this page.
