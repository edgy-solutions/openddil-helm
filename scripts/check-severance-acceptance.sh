#!/usr/bin/env bash
# ===========================================================================
# check-severance-acceptance.sh — does a severed tier keep working, and does
# HQ notice?
# ===========================================================================
# Usage: check-severance-acceptance.sh <tier-id> [namespace]
#
# Four assertions, and the third is the one that was missing for months:
#
#   (a) THE TIER SERVES ITS OWN FRESHLY COMPUTED DATA while severed — its
#       newest sample timestamp ADVANCES. Not "the tier is up", not "the
#       tier has rows": frozen rows and live rows look identical in every
#       check that reads a count or a pod status.
#
#   (b) THE TIER KEEPS COMPUTING SEVERITY while severed — the derived
#       tables move too, not just the raw projection.
#
#   (c) HQ'S VIEW OF THAT EDGE GOES STALE — its timestamp stops advancing,
#       AND ITS ROWS DO NOT DISAPPEAR. Three outcomes, only one correct:
#         fresh  -> a path still crosses the boundary. The sever is
#                   partial and every severance result is void.
#         empty  -> nothing writes HQ's view at all. That is not the
#                   degraded mode ADR-0036 clause 4 specifies; "no data"
#                   and "old data" say opposite things to an operator.
#         stale  -> correct: HQ holds the last thing it knew, and knows
#                   it is old.
#
#   (d) HEAL CONVERGES — and this is only evidence BECAUSE (c) observed
#       divergence first. Convergence onto a value that never moved is a
#       check that cannot fail, which is what the original rung (iv) was.
#
# The sever is scripts/sever-tier.sh, which cuts every path across the
# boundary and proves the cut both ways before returning. A toxiproxy
# toggle is NOT sufficient here and using one is how (c) came to be
# untested in the first place.
# ===========================================================================
set -uo pipefail

TIER="${1:-}"
NS="${2:-openddil}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DWELL="${DWELL_S:-75}"

if [ -z "$TIER" ]; then
  echo "usage: $0 <tier-id> [namespace]" >&2
  exit 2
fi

fail=0
c_froze=0
note() { printf '  %-6s %s\n' "$1" "$2"; }
bad()  { note "FAIL" "$1"; fail=1; }
ok()   { note "ok" "$1"; }

tier_q() {
  kubectl exec -n "$NS" "openddil-tier-pg-${TIER}-0" -- \
    psql -U openddil -d openddil -tAc "$1" 2>/dev/null | tr -d '\r' | head -1
}
hq_q() {
  kubectl exec -n "$NS" openddil-postgres-hq-0 -- \
    psql -U postgres -d openddil -tAc "$1" 2>/dev/null | tr -d '\r' | head -1
}

TIER_NEWEST="select coalesce(max(last_sample_at)::text,'none') from telemetry_latest_state;"
TIER_SEV="select count(*) from asset_logistics_status;"
TIER_SEV_AGE="select coalesce(extract(epoch from now()-max(updated_at))::int, -1) from asset_logistics_status;"
HQ_NEWEST="select coalesce(max(last_sample_at)::text,'none') from telemetry_latest_state where edge_id='${TIER}';"
HQ_ROWS="select count(*) from telemetry_latest_state where edge_id='${TIER}';"

echo "severance acceptance — tier ${TIER}"
echo

# --- 0. baseline, and a non-vacuity floor -----------------------------------
echo "baseline (connected)"
b_tier="$(tier_q "$TIER_NEWEST")"
b_hq="$(hq_q "$HQ_NEWEST")"
b_rows="$(hq_q "$HQ_ROWS")"

if [ -z "$b_tier" ] || [ "$b_tier" = "none" ]; then
  bad "the tier store has no telemetry at all — nothing to test."
  exit 1
fi
if [ -z "$b_rows" ] || [ "$b_rows" -eq 0 ] 2>/dev/null; then
  bad "HQ holds NO rows for ${TIER} before any sever. Assertion (c) could"
  note "" "not distinguish 'went empty' from 'was always empty'."
  exit 1
fi
# HQ must be FRESH here, or assertion (c) cannot mean anything: a view
# that was ALREADY frozen will still be frozen during severance, and the
# check would report "stale as expected" about a staleness the sever did
# not cause. This is the vacuity floor for (c) and it is not optional.
b_hqlag="$(hq_q "select coalesce(extract(epoch from now()-max(last_sample_at))::int, -1) from telemetry_latest_state where edge_id='${TIER}';")"
if [ -z "$b_hqlag" ] || [ "$b_hqlag" -lt 0 ] 2>/dev/null || [ "$b_hqlag" -gt 60 ] 2>/dev/null; then
  bad "HQ's view of ${TIER} is ALREADY ${b_hqlag:-?}s stale before any sever."
  note "" "Assertion (c) would then confirm a staleness the sever did not"
  note "" "cause. Either the bridge is not carrying this edge or nothing"
  note "" "at HQ is projecting it — fix that before running this."
  exit 1
fi
# A PEER EDGE, used as the control for (c). If HQ's view of ${TIER} goes
# stale we need to know that HQ ITSELF is still ingesting -- otherwise a
# stopped projector, a wedged HQ broker or a dead postgres would all
# present as "the severed edge went stale" and pass.
PEER="$(hq_q "select edge_id from telemetry_latest_state where edge_id <> '${TIER}' group by 1 order by max(last_sample_at) desc limit 1;")"
if [ -z "$PEER" ]; then
  bad "HQ holds rows for no edge other than ${TIER} — (c) would have no"
  note "" "control, and an HQ-wide outage would read as a successful sever."
  exit 1
fi
ok "peer edge for control: ${PEER}"
ok "tier newest=${b_tier}"
ok "HQ   newest=${b_hq}  rows=${b_rows}  lag=${b_hqlag}s (fresh — (c) can fail)"

# --- 1. sever ---------------------------------------------------------------
echo
echo "severing (all paths, proven both ways)"
if ! bash "${HERE}/sever-tier.sh" "$TIER" on "$NS"; then
  bad "sever did not prove itself — refusing to report on an unproven cut."
  exit 1
fi

echo
echo "dwelling ${DWELL}s under severance"
sleep "$DWELL"

# FROZEN IS A COMPARISON BETWEEN TWO SAMPLES TAKEN DURING SEVERANCE, never
# a comparison against the baseline. Between reading the baseline and the
# cut taking hold, a few in-flight messages still land at HQ -- measured
# once at 4.4 seconds' worth. Requiring HQ's timestamp to equal the
# baseline exactly fails on that race and reports a working sever as
# broken, which is the mirror image of the bug this whole test exists for.
#
# So: sample, wait, sample again. If HQ did not move BETWEEN those two, it
# has stopped, whatever it did in the first seconds.
d_hq1="$(hq_q "$HQ_NEWEST")"
echo "  HQ at T1: ${d_hq1}"
sleep 40
echo "  HQ at T2: $(hq_q "$HQ_NEWEST")"

d_tier="$(tier_q "$TIER_NEWEST")"
d_sevage="$(tier_q "$TIER_SEV_AGE")"
d_hq="$(hq_q "$HQ_NEWEST")"
d_rows="$(hq_q "$HQ_ROWS")"
d_peerlag="$(hq_q "select coalesce(extract(epoch from now()-max(last_sample_at))::int,-1) from telemetry_latest_state where edge_id='${PEER}';")"
d_hqlag="$(hq_q "select coalesce(extract(epoch from now()-max(last_sample_at))::int,-1) from telemetry_latest_state where edge_id='${TIER}';")"

echo
echo "during severance"
# (a) the tier advances
if [ "$d_tier" != "$b_tier" ] && [ "$d_tier" != "none" ]; then
  ok "(a) tier ADVANCED  ${b_tier} -> ${d_tier}"
else
  bad "(a) tier did NOT advance (still ${d_tier}) — it is frozen, not severance-tolerant."
fi
# (b) severity still computing
if [ -n "$d_sevage" ] && [ "$d_sevage" -ge 0 ] 2>/dev/null && [ "$d_sevage" -lt 60 ]; then
  ok "(b) tier severity still computing (updated ${d_sevage}s ago)"
else
  bad "(b) tier severity stale or absent (age=${d_sevage:-?}s)"
fi
# (c) HQ stale, not fresh, not empty
if [ -z "$d_rows" ] || [ "$d_rows" -eq 0 ] 2>/dev/null; then
  bad "(c) HQ went EMPTY for ${TIER}. Not stale — nothing writes its view."
  note "" "'No data' and 'old data' say opposite things to an operator."
elif [ "$d_hq" != "$d_hq1" ]; then
  bad "(c) HQ IS STILL ADVANCING while the site is severed:"
  note "" "${d_hq1} -> ${d_hq}, 40s apart, both during severance."
  note "" "A path still crosses the boundary. Every severance result from"
  note "" "this deployment is void until it is found."
elif [ -z "$d_hqlag" ] || [ "$d_hqlag" -lt 45 ] 2>/dev/null; then
  bad "(c) HQ stopped advancing but is only ${d_hqlag:-?}s behind — too"
  note "" "little to distinguish a severed edge from a slow one. Dwell longer."
elif [ -z "$d_peerlag" ] || [ "$d_peerlag" -lt 0 ] 2>/dev/null || [ "$d_peerlag" -gt 90 ] 2>/dev/null; then
  bad "(c) ${TIER} froze at HQ, but so did the peer ${PEER} (${d_peerlag:-?}s)."
  note "" "That is an HQ-wide outage wearing a successful sever's clothes."
else
  ok "(c) HQ STALE and intact — frozen at ${d_hq} (${d_hqlag}s behind),"
  note "" "unmoved across 40s of severance, ${d_rows} rows retained"
  note "" "control: peer ${PEER} still fresh at HQ (${d_peerlag}s) — HQ is"
  note "" "healthy and ingesting, so this staleness is ${TIER}-specific"
  c_froze=1
fi

# --- 2. heal ----------------------------------------------------------------
echo
echo "healing"
bash "${HERE}/sever-tier.sh" "$TIER" off "$NS" || bad "heal did not prove itself"

echo
echo "waiting for convergence"
converged=0
for i in $(seq 1 20); do
  sleep 6
  a_hq="$(hq_q "$HQ_NEWEST")"
  if [ "$a_hq" != "$d_hq" ] && [ "$a_hq" != "none" ]; then
    converged=1; break
  fi
done

echo
echo "after heal"
if [ "$converged" -eq 1 ] && [ "$c_froze" -eq 1 ]; then
  ok "(d) HQ CONVERGED — ${d_hq} -> ${a_hq} (drained after $((i*6))s)"
  note "" "non-vacuous: HQ was observed frozen at ${d_hq} first"
elif [ "$converged" -eq 1 ]; then
  # HQ resumed advancing, but it had never stopped. That is not a
  # convergence result -- it is the original rung (iv), which passed for
  # months by comparing a moving value to itself. Reporting it as a pass
  # here would launder a failed (c) into a green (d).
  bad "(d) VACUOUS — HQ advanced after heal, but (c) never saw it freeze."
  note "" "There is nothing to converge from. This is not evidence."
else
  bad "(d) HQ did not resume advancing within 120s of heal (stuck at ${d_hq})"
fi

echo
if [ "$fail" -eq 0 ]; then
  echo "severance acceptance: PASS (a,b,c,d)"
  echo
  echo "WHAT THIS DOES NOT ESTABLISH:"
  echo "  * That HQ's staleness is VISIBLE to an operator. (c) reads the"
  echo "    store; the freshness indicator in the UI is a separate claim"
  echo "    and needs an eye on the screen."
  echo "  * That any tier but ${TIER} behaves this way. One site."
  exit 0
fi
echo "severance acceptance: FAILED" >&2
exit 1
