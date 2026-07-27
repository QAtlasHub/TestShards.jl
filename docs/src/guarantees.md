# Guarantees

Sharding fails in ways that leave CI green, so the interesting question is not what works but
what cannot silently go wrong.

## The split is a partition

Every shard observes the **whole** sequence of units and skips what is not its own. Assignment
is therefore a total, deterministic function of that sequence, computed identically everywhere:

- a unit runs in **exactly one** shard — never twice, never nowhere;
- a unit no shard claims **cannot exist**;
- a unit with no timing history is still assigned, so adding a test file cannot leave it unrun.

## …and every run proves it

The paragraph above is an argument. Each run also *checks* it: every shard reports how many
units it observed and which positions it took, and the collect job reconciles them with
[`TestShards.completeness`](@ref). The run fails if a unit ran nowhere, if a unit ran twice, or
if two shards disagreed about how many units the suite has.

Under the default [`Assigned`](@ref TestShards.Assigned) ownership that check can only pass —
which is the point of running it anyway, at no cost. Under
[`Claimed`](@ref TestShards.Claimed) it is load-bearing: see below.

## Work stealing, and the guarantee it gives up

`steal: true` replaces assignment with a claim — a shard runs whatever nobody has taken, so one
that starts late takes less work instead of delaying everyone. It is worth it exactly when the
diagnosis says [`QueueBound`](@ref TestShards.QueueBound).

It also gives up the theorem. A shard that claims a unit and is then cancelled, OOM-killed or
disconnected leaves that unit claimed and never run, and the merged records are simply short by
one. **That is why the completeness check is not optional and not conditional** — with claiming
on, it is the only thing between a dead runner and a green run that never tested part of the
suite.

Three further things stay loud rather than convenient:

- a shard asked to claim without the token, repository or sha to do it **errors**; falling back
  to assignment would run the suite with the strategy you did not ask for and report success;
- a claim request that neither succeeds nor is refused — a network failure — **errors** after
  retrying, because both available guesses are wrong: one drops a unit, the other runs it twice;
- the claim namespace includes the run id and attempt, so a re-run cannot inherit the previous
  attempt's claims and skip everything.

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
