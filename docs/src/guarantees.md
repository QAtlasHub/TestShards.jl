# Guarantees

Sharding fails in ways that leave CI green, so the interesting question is not what works but
what cannot silently go wrong.

## The split is a partition

Every shard observes the **whole** sequence of units and skips what is not its own. Assignment
is therefore a total, deterministic function of that sequence, computed identically everywhere:

- a unit runs in **exactly one** shard — never twice, never nowhere;
- a unit no shard claims **cannot exist**;
- a unit with no timing history is still assigned, so adding a test file cannot leave it unrun.

## What is an error rather than a warning

| situation | why it must be loud |
|---|---|
| a shard label with no selection | every shard would run the whole suite: green, slow, and meaningless |
| a unit named that the suite does not have | the plan and the suite disagree about what exists |
| a green default-branch run that produced no timings | balancing would silently fall back to an even split forever |

## Failure still reports

A failing unit is recorded, does not abort its shard, and the run fails once at the end. Timings
are written even for a failed run — a red unit still took however long it took, and dropping
that would make the next split fall back to a stale estimate exactly where the suite is
changing.

## The one rule your suite must follow

**Every unit must be independently includable.**

A shard receives an arbitrary subset, so a file that relies on a helper defined in another file
works unsharded and breaks the moment the two land in different shards. The tell, during a full
run, is:

```
WARNING: Method definition foo(Any) in module Main ... overwritten ...
```

Fix it by giving each file its own helpers, putting shared ones in a file that each includes, or
binding the group into one [`@unit`](@ref).

This is the only requirement sharding adds. Everything else about your suite stays as it was.
