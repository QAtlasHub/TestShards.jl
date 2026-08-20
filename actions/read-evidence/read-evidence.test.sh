#!/usr/bin/env bash
#
# The states this script must handle that a normal run never shows: an unreadable job, an empty
# job list, and an API call that fails outright. All three are reachable here without a network
# or a token, because the two network commands are indirected through TS_GH / TS_CURL.
#
# The failure this guards against is specific: `gh api .../jobs/{id}/logs` returns 302 and gh does
# not follow it, so a version of this that used gh for the log fetch reported "read 0 job logs"
# while every job had a perfectly good log. That is a transport that fails SILENTLY into an
# unverifiable run, which is the one outcome the completeness gate exists to prevent.
#
# Run it anywhere: `actions/read-evidence/read-evidence.test.sh`
set -uo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
script="$here/read-evidence.sh"
tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT
failures=0

check() { # name expected_rc actual_rc
  if [ "$2" = "$3" ]; then echo "  ok   $1"; else echo "  FAIL $1 (want rc=$2, got rc=$3)"; failures=$((failures+1)); fi
}

# --- stubs -----------------------------------------------------------------------------------
mkdir -p "$tmp/bin"
cat > "$tmp/bin/gh-three" <<'EOF'
#!/usr/bin/env bash
printf '11\n12\n13\n'
EOF
cat > "$tmp/bin/gh-none" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$tmp/bin/gh-broken" <<'EOF'
#!/usr/bin/env bash
echo "api error" >&2; exit 1
EOF
cat > "$tmp/bin/curl-ok" <<'EOF'
#!/usr/bin/env bash
out=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out=$a; prev=$a; done
echo "log body" > "$out"
EOF
# fails for job 12 only — a partial read, which must be reported and not fatal
cat > "$tmp/bin/curl-partial" <<'EOF'
#!/usr/bin/env bash
out=""; url=""; prev=""
for a in "$@"; do [ "$prev" = "-o" ] && out=$a; case $a in https://*) url=$a;; esac; prev=$a; done
case "$url" in *"/jobs/12/logs") exit 22;; esac
echo "log body" > "$out"
EOF
cat > "$tmp/bin/curl-allfail" <<'EOF'
#!/usr/bin/env bash
exit 22
EOF
chmod +x "$tmp"/bin/*

run() { TS_GH="$1" TS_CURL="$2" bash "$script" o/r 99 1 "$3" "" >"$tmp/out.log" 2>&1; echo $?; }

echo "read-evidence.test.sh"

rc=$(run "$tmp/bin/gh-three" "$tmp/bin/curl-ok" "$tmp/all")
check "three jobs, all readable" 0 "$rc"
n=$(find "$tmp/all" -name 'job-*.log' | wc -l)
[ "$n" = 3 ] && echo "  ok   wrote 3 logs" || { echo "  FAIL wrote $n logs, want 3"; failures=$((failures+1)); }

rc=$(run "$tmp/bin/gh-three" "$tmp/bin/curl-partial" "$tmp/part")
check "one job unreadable is NOT fatal (the gate decides what is missing)" 0 "$rc"
n=$(find "$tmp/part" -name 'job-*.log' | wc -l)
[ "$n" = 2 ] && echo "  ok   kept 2 logs, dropped the unreadable one" || { echo "  FAIL kept $n, want 2"; failures=$((failures+1)); }
grep -q "could not read the log of job 12" "$tmp/out.log" \
  && echo "  ok   named the unreadable job" || { echo "  FAIL did not name the unreadable job"; failures=$((failures+1)); }

rc=$(run "$tmp/bin/gh-three" "$tmp/bin/curl-allfail" "$tmp/none1")
check "no log readable at all IS fatal" 1 "$rc"

rc=$(run "$tmp/bin/gh-none" "$tmp/bin/curl-ok" "$tmp/none2")
check "an empty job list is fatal, not an empty-but-fine run" 1 "$rc"

rc=$(run "$tmp/bin/gh-broken" "$tmp/bin/curl-ok" "$tmp/none3")
check "a failing job-list call is fatal" 1 "$rc"

echo
[ "$failures" -eq 0 ] && { echo "all good"; exit 0; } || { echo "$failures failure(s)"; exit 1; }
