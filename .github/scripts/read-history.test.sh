#!/usr/bin/env bash
#
# The states a FRESH consumer is in, that this repository never is.
#
# This repository has a `ci-timings` branch and always has had one, so every path in
# `read-history.sh` that handles NOT having one is unreachable from a normal run here. One of
# them shipped broken (#54) and surfaced on the first adopter that happened to be fresh — which
# is every repository that has never been sharded.
#
# So the states are built here instead: a bare repository with no branch, and a remote that is
# not a repository at all. Both are local; neither needs a network or a second repository.
#
# Run it anywhere: `.github/scripts/read-history.test.sh`
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/read-history.sh"
failures=0

# The script is expected to exit non-zero in one of the cases below, so its exit code is
# captured rather than allowed to end this file.
run() {
  local dir=$1 out=$2 remote=$3
  ( cd "$dir" && bash "$script" "$remote" ci-timings "$out" ) > /tmp/rh.log 2>&1
  echo $?
}

check() {
  local what=$1 want=$2 got=$3
  if [ "$want" = "$got" ]; then
    echo "ok   — $what"
  else
    echo "FAIL — $what: wanted [$want], got [$got]"
    sed 's/^/       /' /tmp/rh.log
    failures=$((failures + 1))
  fi
}

# ── The positive control ──────────────────────────────────────────────────────────────
#
# Without it the two states below are satisfied by a script that has stopped reading histories
# altogether: "no history" is the correct answer to both, and a broken script says it always.
bare=$(mktemp -d)/remote.git
git init -q --bare "$bare"
seed=$(mktemp -d)
git init -q "$seed"
printf 'core/a.jl\t1.5\ncore/b.jl\t2.5\nsolver/heavy.jl\t40.0\n' > "$seed/timings.tsv"
git -C "$seed" add timings.tsv
git -C "$seed" -c user.email=t@example.invalid -c user.name=t commit -qm 'seed the history'
git -C "$seed" branch -M ci-timings
git -C "$seed" push -q "$bare" ci-timings

work=$(mktemp -d)
git init -q "$work"
rc=$(run "$work" "$work/timings.tsv" "$bare")
check "a history that exists is read" 0 "$rc"
check "…and all of it arrives" 3 "$(wc -l < "$work/timings.tsv" | tr -d ' ')"

# ── No ci-timings branch: the state every unsharded repository starts in ───────────────
#
# `ls-remote --exit-code` exits 2 here. Under errexit that kills a bare `x=$(...)` assignment
# before its status can be read, which is exactly how #54 shipped.
empty=$(mktemp -d)/remote.git
git init -q --bare "$empty"
work2=$(mktemp -d)
git init -q "$work2"
rc=$(run "$work2" "$work2/timings.tsv" "$empty")
check "no branch is survivable, not fatal" 0 "$rc"
check "…and leaves an empty history" 0 "$(wc -l < "$work2/timings.tsv" | tr -d ' ')"
grep -q 'round-robin' /tmp/rh.log
check "…and says what will happen instead" 0 "$?"

# ── A remote that cannot be reached: NOT the same thing as an absent branch ────────────
#
# Treating this as "no history" is what put one shard of eight on a different assignment
# function from the other seven: two units ran twice, two ran nowhere, and every shard was
# green. It has to fail.
work3=$(mktemp -d)
git init -q "$work3"
rc=$(run "$work3" "$work3/timings.tsv" "$(mktemp -d)/not-a-repository")
check "an unreachable remote FAILS rather than guessing" 1 "$rc"
grep -q 'Failing rather than guessing' /tmp/rh.log
check "…and says why guessing would be worse" 0 "$?"

echo
if [ "$failures" -eq 0 ]; then
  echo "read-history.sh: every consumer state behaved."
else
  echo "read-history.sh: $failures assertion(s) failed."
  exit 1
fi
