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

### How much it is worth, and when it is not

Under assignment the run cannot finish before the last shard to *start* has also done its share:

> `wall ≈ last_start + fixed + serial/N`

Under claiming that shard finds nothing left and does none of it:

> `wall ≈ max(when the early shards absorb everything, last_start + fixed)`

So **what stealing removes from the critical path is one share, `serial/N`** — and no more,
however many shards arrived late, because the wall clock is set by whichever finishes last
either way.

Whether that is worth having is decided by one ratio, `share / fixed`, and **the diagnosis
already computes it**: [`FixedCostBound`](@ref TestShards.FixedCostBound) is exactly the case
where the fixed cost exceeds the heaviest bin, which is to say `share < fixed`.

- **Work-dominated (`share > fixed`)** — a late shard's share is the largest single item on the
  critical path, and stealing removes it. A shard that claims nothing costs `fixed` instead of
  `fixed + share`, so it finishes well before the working ones and never sets the wall clock.
- **Setup-dominated ([`FixedCostBound`](@ref TestShards.FixedCostBound))** — the shards that
  claim nothing still pay for checkout, Julia, the depot and coverage, and that is *more* than
  the work stealing saved. They can finish last while having run nothing at all.

Measured, two suites in the same organisation:

| | `serial/N` | fixed | ratio |
|---|--:|--:|--:|
| this package, N=8 | 27 s | 49 s | **0.55** — setup-dominated |
| QAtlas.jl, N=16 | 255–651 s | 225–271 s | **1.1–2.6** — work-dominated |

Note what that table does *not* say. It is tempting to conclude that a larger shard count makes
stealing worth less, since `serial/N` shrinks as `N` grows — but QAtlas runs **twice** the shard
count and is still work-dominated by a wide margin. `N` only matters through the share it
produces; what decides the question is that share against the fixed cost, and a big suite split
sixteen ways still has more work per shard than a small one split eight ways.

So: **steal when a run is [`QueueBound`](@ref TestShards.QueueBound) and the suite is not
[`FixedCostBound`](@ref TestShards.FixedCostBound).** This package's own suite is the second
kind, which is why stealing does not help it — and why measuring it here says nothing about
whether it helps yours.

One measurement to trust more than the others: a shard that claims nothing spends its whole
life on setup, so **its wall clock *is* the fixed cost**, with nothing to subtract. In a run
here with a 119 s start window, four shards ran zero units and reported 46–75 s, against the
24.7 s the in-process windows report. That is the understatement of #16, confirmed from the
other side — and it is worst on small suites, where the trailing coverage step the window
misses is half the fixed cost rather than a tenth of it.

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
