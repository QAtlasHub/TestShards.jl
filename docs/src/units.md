# Units

A **unit** is one thing a shard can be given. Units are discovered by watching your suite run,
not by matching filenames or reading a manifest.

## Every `include` is a unit

[`@shard`](@ref) shadows `include` inside its block, so each call is observed at the moment it
happens:

```julia
TestShards.@shard begin
    include("core/a.jl")                 # a unit
    for f in readdir("solver"; join = true)
        include(f)                       # each of these is a unit too
    end
end
```

Because the interception is at the *call* and not at the source text, a unit produced by a loop
is seen exactly like a literal one. Nothing has to predict what the loop will yield.

An `include` **inside** an included file is an ordinary `include` — it does not create a unit.
Only the calls written in the `@shard` block do.

## Keeping files together: `@unit`

Files that must run in sequence — one sets up state another reads — cannot be split across
jobs. Bind them into a single unit with [`@unit`](@ref):

```julia
TestShards.@shard begin
    include("core/a.jl")

    TestShards.@unit "stateful" begin
        include("stateful/01_setup.jl")
        include("stateful/02_use.jl")
    end
end
```

The group runs in one shard, in the order written, and the planner treats it as one heavy unit.
Its name is also how you address it in manual mode.

## Ordering

**Within a shard**, units run in the order they were observed, regardless of how the balancer
packed them.

**Across shards**, order is not preserved. That is what running in parallel means. If your
suite is sequential end to end, it cannot be sharded — that is a property of the suite, not a
limitation to work around.

## Choosing units by hand

Setting `TESTSHARDS_UNITS` runs exactly the named units and nothing else, which is how a
hand-declared test-group matrix works:

```yaml
strategy:
  matrix:
    group: ['fast', 'heavy']
env:
  TESTSHARDS_UNITS: ${{ matrix.group }}
```

with `@unit "fast"` and `@unit "heavy"` in the suite. An explicit list always wins over the
automatic split.
