#!/usr/bin/env bash
#
# Fetch every shard job's LOG for one attempt of one run, into a directory, so the collector can
# recover the evidence markers from them (TestShards.evidence_cli).
#
# Two things here are not obvious and both were measured against live runs:
#
#  1. `gh api .../actions/jobs/{id}/logs` DOES NOT WORK. The endpoint answers 302 with a
#     short-lived blob URL; gh exits 1 with no useful message. curl -L follows it.
#  2. The jobs must come from `/runs/{id}/attempts/{n}/jobs`, NOT `/runs/{id}/jobs`. The latter
#     returns every attempt's jobs, so a re-run merges two attempts' shards and the recovered
#     evidence double-counts while looking complete.
#
# The network commands are indirected through TS_GH / TS_CURL so `read-evidence.test.sh` can run
# every branch below without a network or a token.
set -uo pipefail

repo=${1:?repo}
run_id=${2:?run id}
attempt=${3:?attempt}
outdir=${4:?output directory}
filter=${5:-}          # only jobs whose name starts with this; empty means all

GH=${TS_GH:-gh}
CURL=${TS_CURL:-curl}

mkdir -p "$outdir"

ids=$("$GH" api "repos/$repo/actions/runs/$run_id/attempts/$attempt/jobs" \
        --paginate --jq ".jobs[]|select(.name|startswith(\"$filter\"))|\"\(.id)\"" 2>/dev/null)
rc=$?
if [ $rc -ne 0 ]; then
  echo "::error::could not list the jobs of run $run_id attempt $attempt. Without the job list there is nothing to read; this is not a partial result." >&2
  exit 1
fi
if [ -z "$ids" ]; then
  # An empty list is NOT an empty-but-fine run: the collector runs after the shards, so at least
  # one job must match. Reporting success here would hand the gate zero evidence and let a run
  # with no shards look verified.
  echo "::error::no job in run $run_id attempt $attempt matched '$filter'." >&2
  exit 1
fi

n=0; missed=0
for id in $ids; do
  if "$CURL" -sSL --fail-with-body \
       -H "Authorization: Bearer ${GH_TOKEN:-}" \
       -H "Accept: application/vnd.github+json" \
       "https://api.github.com/repos/$repo/actions/jobs/$id/logs" -o "$outdir/job-$id.log" 2>/dev/null
  then
    n=$((n+1))
  else
    # A job whose log cannot be read is reported and NOT fatal here: which shards are missing is
    # the completeness gate's judgement to make, not this script's. Failing here would replace a
    # precise "unit X ran nowhere" with an opaque transport error.
    rm -f "$outdir/job-$id.log"
    missed=$((missed+1))
    echo "::warning::could not read the log of job $id" >&2
  fi
done

echo "read $n job log(s) into $outdir${missed:+, $missed unreadable}"
[ "$n" -gt 0 ] || { echo "::error::no job log could be read at all." >&2; exit 1; }
