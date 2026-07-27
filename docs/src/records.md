# Records

Every run writes a record of what it did: one line per unit, holding that unit's `@testset`
tree with per-testset durations and outcomes. CI merges the shards' records into one document
ordered by position in the suite, so the result does not depend on how the run was split.

```json
{"key":"core/a.jl","index":1,"shard":"s1","duration":0.20,
 "npass":2,"nfail":0,"nerror":0,"nbroken":0,
 "sections":[{"name":"inflation preserves the tiling","duration":0.056,
              "npass":2,"nfail":0,"nerror":0,"nbroken":0,
              "evidence":{"tolerance":1.0e-12,"achieved":3.2e-14,
                          "oracle":"closed-form inflation matrix"},
              "sections":[{"name":"sub-check","duration":0.007, "...":"..."}]}]}
```

The shape is a **unit → testset** hierarchy, which maps onto a document as one page per unit
and one section per testset. `index` is the unit's position in the full suite and is the same
in every shard, so records from separate jobs sort back into source order.

Alongside it, two flat TSVs: `timings-*.tsv` (the planner's history) and `sections-*.tsv`
(`unit`, section path, seconds — what [`TestShards.diagnose`](@ref) reads to say where to split a heavy
unit).

## Attaching evidence

A passing test says only that it passed. [`evidence!`](@ref) records *what* it established, so
a report can state it without a reader going to the source:

```julia
@testset "inflation preserves the tiling" begin
    err = norm(inflate(t) - reference)
    evidence!(; tolerance = 1e-12, achieved = err, oracle = "closed-form inflation matrix")
    @test err < 1e-12
end
```

Evidence attaches to the `@testset` currently running and travels with it into the record.
Values that are not `Real`, `Bool` or `AbstractString` are stored as their `string()` form, so
anything is safe to pass.

Outside a `@shard` block `evidence!` does nothing, which keeps a test file runnable on its own.

## Where they go

Set `TESTSHARDS_OUT` to a directory and the records are written there. Locally, with it unset,
nothing is written — running the tests leaves no artefacts behind.

Under `Pkg.test` the suite is copied into a sandbox, so the directory must be an absolute path
inside your workspace. The bundled workflow handles this.
