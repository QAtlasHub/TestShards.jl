# Composing with other tools

A unit runs inside a testset this package builds by hand rather than through `@testset`, so that a
**failed** unit can still be read back — a top-level `@testset` throws before returning its tree.
That leaves the *type* of that testset ours to choose, and another tool that captures a suite
through `Test`'s own interface needs it to be theirs.

That type is therefore a registered choice: [`TestShards.register_unit_provider!`](@ref).

## Why it has to be an extension point

`Test` builds a nested testset from its parent's **type**. A tool that captures a suite by being an
`AbstractTestSet` — recording each assertion as it happens — sees a suite only because of that rule.
TestShards never goes through `@testset`, so with a `DefaultTestSet` for every unit such a tool sees
nothing at all. Being a tool that reports *on tests*, it reports that silently: an empty run and a
green verdict, which is indistinguishable from a suite with no tests.

There is a second, independent cause. `_run` pushes and pops the unit's testset by hand and never
calls `Test.finish`; a tool that attaches a finished testset to its parent does it in `finish`, so
even with the right type the unit would never appear.

Hence three operations rather than one:

| | |
| --- | --- |
| `open(key)` | the testset for a unit — or **`nothing`** to decline it and leave the default |
| `close(ts)` | runs *after* the pop, which is the only moment a parent can be reached |
| `fold(ts)`  | the counts and structure, as plain data |

`fold` is the one that keeps this package honest: the balancing history and the completeness verdict
are computed from the per-unit counts, and it cannot read those out of a testset type it does not
know. **The first thing to test in any provider is that the same suite yields the same numbers
whichever testset ran it** — a discrepancy there would silently corrupt the split.

`open` returning `nothing` is what keeps a provider inert. Decline unless the tool's capture is
actually running: a suite that merely *depends* on the tool must not have its testset type changed
underneath it, and a plain `Pkg.test()` must behave exactly as it did before.

Only one provider can be registered. Two tools cannot both own the type of one testset, and letting
the last one win would surface as a mysteriously empty report rather than as an error.

## Who writes the provider

**The consumer does, in its own package.** A provider needs the counts out of its own testset type,
which is its private business; this package's side of the seam is one function call and no types at
all — which is why `fold` returns plain data. Putting the provider here instead would mean this
package reading another's internals, so that another package's refactor would break *this* one, and
the fix would land in the wrong repository.

That is also what keeps the dependency graph one-directional: TestShards depends on nothing but two
standard libraries, and a consumer's extension is invisible to everyone who only wants sharding.

## What a test established

`evidence!` records what a test *grounds* — a tolerance, an achieved residual, the oracle it compared
against — and it keys that on the testset **object**, so it keeps working when the testset is a
provider's rather than this package's. `TestShards.evidence(ts)` is the reader:

```julia
@testset "inflation preserves the tiling" begin
    err = norm(inflate(t) - reference)
    evidence!(; tolerance = 1e-12, achieved = err, oracle = "closed-form inflation matrix")
    @test err < 1e-12
end
```

A provider whose tool renders a suite can then put that beside the verdict, instead of it living only
in this package's records. Walk the testset's own children for a subtree — the provider's type knows
its own nesting, and the reader takes one node at a time.

## The first one: Pinax

[Pinax](https://github.com/QAtlasHub/Pinax.jl) renders a test suite as a document. It recovers
`got` / `want` / `tol` from each `isapprox` assertion, so its report shows how much room a test
passed *by* — a check sitting at 97 % of its tolerance is one refactor from red and looks identical
to a solid one in a green badge. It folds a `@testset for` sweep into a convergence figure, and it
shows the code behind each check.

Its provider ships **in Pinax**, as `PinaxTestShardsExt`. Loading both packages is the whole setup —
the extension registers itself, and there is no switch to set:

```julia
using MyPackage, TestShards, Pinax
TestShards.@shard begin
    include("core/a.jl")
    include("core/b.jl")
end
```

```console
$ julia -e 'using Pinax, Test; Pinax.test("test/runtests.jl"; out="test-report")'
```

One page per unit, sections mirroring the `@testset` nesting. Sharded, each shard *dumps* instead of
rendering and one job renders every dump as a single document, so the shard boundary does not appear
in the output:

```console
# in each shard
PINAX_TEST_DUMP=pinax-dumps/s1.toml julia -e 'using Pinax, Test; Pinax.test("test/runtests.jl")'
# once, afterwards
julia -e 'using Pinax; Pinax.render_test_report(readdir("pinax-dumps"; join=true); out="test-report")'
```

Without the provider the two are mutually blind, and silently: with a `DefaultTestSet` per unit,
Pinax's capture records nothing and reports `0/0 passed` — an empty *and* green report, which is
indistinguishable from a suite with no tests. That is the failure this seam exists to prevent, and it
is measured on both sides (see QAtlasHub/Pinax.jl and issue #22 here).
