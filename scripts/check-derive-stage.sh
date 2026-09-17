#!/usr/bin/env bash
# ===========================================================================
# check-derive-stage.sh — does the DERIVE STAGE actually complete anything?
# ===========================================================================
# THE GAP THIS FILLS. `check-advancing.sh` asks whether topics advance, and on
# 2026-09-17 it was green across all nine stages while fusion had received
# ZERO invocations, ever. `check_tier_feed.py` was clean across 45 consumers
# at the same moment. Both were telling the truth. Neither was asking the
# question.
#
# The derive stage sits BETWEEN two advancing stages: Restate consumes an
# input topic, invokes a Virtual Object, the handler produces to an output
# topic. Every part of that can look healthy while nothing completes --
# subscription registered, consumer lag falling, pods Running, deployment
# reachable, output at +0 forever. CONSUMED IS NOT COMPLETED.
#
# THE THREE TERMS, per the dispatch:
#   1. consumed  — the subscription's consumer group advances
#   2. completed — the handler's OUTPUT topic advances
#   3. reachable — the registered deployment answers on its URI
#
# Term 3 is what distinguishes "the derive stage is broken" from "the derive
# stage has nothing to do". Without it a quiet fleet reads identically to a
# dead one, which is the failure this whole corpus keeps re-finding.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT REFUSES TO REPORT A NUMBER IT DID NOT READ
# ---------------------------------------------------------------------------
# The first draft of this measurement reported `0` for all eight watermarks,
# including one known to be 1,436,481. The cause: it did not export
# KUBECONFIG, `2>/dev/null` swallowed kubectl's error, and `END {print s+0}`
# turned "no input at all" into a confident zero. A failed read and an empty
# topic were byte-identical at the caller.
#
# That is the same shape as the outage it was written to detect, arriving in
# the detector. So: kubectl's stderr is captured and shown, a read that
# returns no partition rows is an ERROR and not a zero, and the cluster guard
# runs first -- an un-exported KUBECONFIG can otherwise silently address a
# different cluster, which is precisely what require-cluster.sh exists for.
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/require-cluster.sh
. "$HERE/lib/require-cluster.sh"
openddil_require_cluster

NS="${NS:-openddil}"
WINDOW="${1:-90}"

# tier | broker pod | restate svc | derive-stage OUTPUT topics
ROWS=(
  "edge-01|openddil-redpanda-edge-01-0|openddil-tier-restate-edge-01|asset-cm-state asset-logistics-status"
  "edge-02|openddil-redpanda-edge-02-0|openddil-tier-restate-edge-02|asset-cm-state asset-logistics-status"
  "region-east|openddil-redpanda-region-east-0|openddil-tier-restate-region-east|asset-cm-state asset-logistics-status"
)

fail=0

# ---------------------------------------------------------------------------
# Read a topic's summed high watermark, or FAIL LOUDLY. Never returns a
# fabricated 0: an unreadable topic exits non-zero and prints why.
# ---------------------------------------------------------------------------
hw() {
  local pod="$1" topic="$2" out rc rows
  out=$(kubectl -n "$NS" exec "$pod" -c redpanda -- \
          rpk topic describe "$topic" -p 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "READ-FAILED rc=$rc: $(printf '%s' "$out" | head -1)" >&2
    return 1
  fi
  # HIGH-WATERMARK is the last column; partition rows start with a digit.
  rows=$(printf '%s\n' "$out" | awk 'NR>1 && $1 ~ /^[0-9]+$/' | wc -l)
  if [ "$rows" -lt 1 ]; then
    echo "READ-FAILED: no partition rows for $topic on $pod" >&2
    return 1
  fi
  printf '%s\n' "$out" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {s += $NF} END {print s}'
}

# ---------------------------------------------------------------------------
# Term 3: is the registered deployment reachable, and what is registered?
# ---------------------------------------------------------------------------
probe_restate() {
  local tier="$1" svc="$2" pod dep sub
  pod=$(kubectl -n "$NS" get pod -o name 2>/dev/null \
        | grep "tier-fusion-${tier}" | head -1 | sed 's|pod/||')
  if [ -z "$pod" ]; then
    echo "  restate[$tier]: NO fusion pod to probe from"
    return 1
  fi
  dep=$(kubectl -n "$NS" exec "$pod" -c logistics-fusion -- python -c \
"import json,urllib.request as u
print(len(json.load(u.urlopen('http://$svc:9070/deployments',timeout=10))['deployments']))" 2>/dev/null)
  sub=$(kubectl -n "$NS" exec "$pod" -c logistics-fusion -- python -c \
"import json,urllib.request as u
print(len(json.load(u.urlopen('http://$svc:9070/subscriptions',timeout=10))['subscriptions']))" 2>/dev/null)
  if [ -z "$dep" ] || [ -z "$sub" ]; then
    echo "  restate[$tier]: ADMIN API UNREACHABLE — cannot enumerate"
    echo "                  (this is the 'node N1:<gen> was shut down or removed'"
    echo "                   state if the pod is Running: wipe + re-bootstrap)"
    return 1
  fi
  if [ "$dep" -lt 1 ] || [ "$sub" -lt 1 ]; then
    echo "  restate[$tier]: deployments=$dep subscriptions=$sub — NOT REGISTERED"
    echo "                  Restate is empty. A wiped Restate that no bootstrap"
    echo "                  re-registered reads Running and derives nothing."
    return 1
  fi
  echo "  restate[$tier]: deployments=$dep subscriptions=$sub — registered"
  return 0
}

echo "=== term 3: deployment registration + reachability ==="
for row in "${ROWS[@]}"; do
  tier="${row%%|*}"; r="${row#*|}"; r="${r#*|}"; svc="${r%%|*}"
  probe_restate "$tier" "$svc" || fail=1
done

echo
echo "=== terms 1+2: consumed vs completed over ${WINDOW}s ==="
declare -A before
for row in "${ROWS[@]}"; do
  tier="${row%%|*}"; r="${row#*|}"; pod="${r%%|*}"
  r="${r#*|}"; topics="${r#*|}"
  for t in $topics; do
    if v=$(hw "$pod" "$t"); then
      before["$tier/$t"]="$v"
    else
      echo "  FATAL: cannot read $tier/$t — refusing to report a delta" >&2
      exit 2
    fi
  done
done

start=$(date -u +%s)
while [ $(( $(date -u +%s) - start )) -lt "$WINDOW" ]; do sleep 10; done
elapsed=$(( $(date -u +%s) - start ))

printf "\n%-12s %-26s %14s %14s %10s\n" TIER "OUTPUT TOPIC" BEFORE AFTER DELTA
printf -- "--------------------------------------------------------------------------------\n"
moved=0; frozen=0
for row in "${ROWS[@]}"; do
  tier="${row%%|*}"; r="${row#*|}"; pod="${r%%|*}"
  r="${r#*|}"; topics="${r#*|}"
  for t in $topics; do
    if ! a=$(hw "$pod" "$t"); then
      echo "  FATAL: cannot re-read $tier/$t" >&2; exit 2
    fi
    b="${before["$tier/$t"]}"
    d=$(( a - b ))
    if [ "$d" -gt 0 ]; then
      mark="advancing"; moved=$((moved+1))
    else
      mark="FROZEN"; frozen=$((frozen+1)); fail=1
    fi
    printf "%-12s %-26s %14s %14s %10s  <- %s\n" "$tier" "$t" "$b" "$a" "+$d" "$mark"
  done
done

echo
echo "over ${elapsed}s: ${moved} advancing, ${frozen} frozen"
if [ "$fail" -eq 0 ]; then
  echo "derive stage: COMPLETING"
else
  echo "derive stage: NOT COMPLETING — see above."
  echo
  echo "A frozen OUTPUT with a healthy input and a registered, reachable"
  echo "deployment is the derive stage failing silently. Check Restate's logs"
  echo "for a consumer task dying on a codec it cannot decompress, and check"
  echo "/query -- if it answers 'node N1:<gen> was shut down or removed', the"
  echo "cluster metadata is corrupt and the fix is a wipe + re-bootstrap."
fi
exit "$fail"
