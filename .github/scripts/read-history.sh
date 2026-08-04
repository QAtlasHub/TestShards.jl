#!/usr/bin/env bash
#
# Read the timing history the whole run is planned against — ONCE, for every shard.
#
#   read-history.sh [remote] [branch] [out]
#
# Defaults: origin, ci-timings, timings.tsv. The arguments exist so that a test can point this
# at a scratch remote and be in a state a consumer is in — no history at all, or a remote that
# cannot be reached. See `read-history.test.sh` beside this file.
#
# WHY THIS IS A FILE AND NOT A `run:` BLOCK
#
# Nothing can run a `run:` block. The defect this code exists to prevent (#54) shipped because
# the branch handling "no timing history yet" could not be reached by having no timing history,
# and a test that COPIES the snippet would not catch its reintroduction either — the mistake is
# a shell-option interaction, not a wrong string. A caller and a test that run the same file is
# the only arrangement where the test means anything.
#
# `set -e` IS DELIBERATE and load-bearing. A workflow `run:` step's shell is `bash -e {0}`, so
# errexit was on for the original block whatever it asked for, and the `if`-captured assignment
# below is what makes it survive. Dropping `-e` here would make this script safer and the test
# WORTHLESS: the very mistake it guards against would stop failing.
set -euo pipefail

remote=${1:-origin}
branch=${2:-ci-timings}
out=${3:-timings.tsv}

# `ls-remote --exit-code` distinguishes the cases: 0 = branch exists, 2 = no matching ref,
# anything else = error. Measured.
#
# Captured through an `if`, and that is not style. Under errexit a bare `lsr=$(...); rc=$?`
# kills the script the moment ls-remote exits non-zero, BEFORE `rc` is read: a repository with
# no ci-timings branch yet died with exit 2 and no output, which is the one case this code was
# written to handle. An assignment inside an `if` condition is exempt from errexit however the
# shell was invoked.
if lsr=$(git ls-remote --exit-code --heads "$remote" "$branch" 2>&1); then rc=0; else rc=$?; fi

if [ "$rc" -eq 0 ]; then
  if ! git fetch --depth=1 "$remote" "$branch"; then
    echo "::error::The $branch branch exists but could not be fetched. Failing here, before any shard starts, rather than letting the shards disagree about the split."
    exit 1
  fi
  if git show FETCH_HEAD:timings.tsv > "$out" 2>/dev/null; then
    echo "$(wc -l < "$out") timing rows."
  else
    echo "$branch carries no timings.tsv yet — round-robin."
    : > "$out"
  fi
elif [ "$rc" -eq 2 ]; then
  echo "No $branch branch yet — round-robin until the first push to the default branch."
  : > "$out"
else
  echo "::error::Could not tell whether the $branch branch exists (git ls-remote exit $rc). Failing rather than guessing: guessing wrong puts the shards on different assignments, which double-runs some units and skips others while every shard stays green."
  echo "$lsr"
  exit 1
fi
