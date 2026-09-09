#!/usr/bin/env bash
# ===========================================================================
# check-advancing.sh — do the numbers MOVE?
# ===========================================================================
# Usage: check-advancing.sh [namespace] [interval-seconds]
#
# WHY THIS EXISTS, AND WHY IT IS A PRE-FLIGHT RATHER THAN A DASHBOARD
#
# On 2026-09-09 the pipeline had been dead for three and a half hours and
# every probe was green. Two edge bridges had stopped consuming — one on a
# consumer-group generation error, one with NO ERROR AT ALL — and an edge's
# sensor-ingest had entered a fatal librdkafka producer state, which is
# unrecoverable by design. That ingest kept RECEIVING and DECODING: 460,181
# messages decoded, 21,264 kafka errors, pod 1/1 Running, restarts 0.
#
# Every counter except the one that mattered looked healthy.
#
# It was found by a baseline taken before a severance test, and it was found
# because that baseline asked whether numbers ADVANCE rather than whether
# they exist. That question is this script.
#
# WHAT IT IS NOT. It is not a health check in the Kubernetes sense and it is
# not a substitute for the readiness probes those components should have. It
# is the question a person asks before trusting a measurement, made runnable
# so it can be asked before every severance and before every recording — the
# two occasions where a silently frozen pipeline is most expensive and least
# visible.
#
# A DEMO CANNOT AFFORD THIS OUTAGE: invisible for hours, discovered by the
# first person who looks at a timestamp — which, during a recording, is the
# audience.
# ===========================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# WHICH CLUSTER. Asserted, never inherited. See lib/require-cluster.sh.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib/require-cluster.sh" || exit 1

NS="${1:-openddil}"
INTERVAL="${2:-20}"

# Everything that must be moving for a measurement to mean anything, as
# (label, pod, port, topic). Deliberately spans the whole path — ingest to
# edge broker, edge broker to region, region to HQ — because each of the
# three failures seen so far broke a different link and each looked identical
# from the others' side.
PROBES=(
  # LABELLED FOR THE STAGE IT ACTUALLY MEASURES. sensor-ingest produces to
  # `ingress-dis-raw`; `raw-sensor-stream` is the DIS MAPPER's output. The
  # first draft called this row "ingest", which would have sent a reader to
  # the wrong component -- and did: the mapper at edge-02 was the wedged one
  # while ingest was healthy.
  "e1 ingest|openddil-redpanda-edge-01-0|9092|ingress-dis-raw"
  "e1 mapper|openddil-redpanda-edge-01-0|9092|raw-sensor-stream"
  "e2 ingest|openddil-redpanda-edge-02-0|9092|ingress-dis-raw"
  "e2 mapper|openddil-redpanda-edge-02-0|9092|raw-sensor-stream"
  "e1 derived|openddil-redpanda-edge-01-0|9092|telemetry-latest-state"
  "e2 derived|openddil-redpanda-edge-02-0|9092|telemetry-latest-state"
  "region inbound|openddil-redpanda-region-east-0|9092|telemetry-latest-state"
  "region rollups|openddil-redpanda-region-east-0|9092|region-fleet-summary"
  "HQ inbound|openddil-redpanda-hq-0|19092|telemetry-latest-state"
)

hw() {
  kubectl exec -n "$NS" "$1" -- rpk topic describe "$3" -p \
    --brokers "localhost:$2" 2>/dev/null \
    | awk 'NR>1 && $6 ~ /^[0-9]+$/ {s+=$6} END{print s+0}'
}

echo "advancing check — namespace $NS, interval ${INTERVAL}s"
echo

declare -a LABEL POD PORT TOPIC FIRST
n=0
for spec in "${PROBES[@]}"; do
  IFS='|' read -r l p q t <<<"$spec"
  LABEL[$n]="$l"; POD[$n]="$p"; PORT[$n]="$q"; TOPIC[$n]="$t"
  FIRST[$n]="$(hw "$p" "$q" "$t")"
  n=$((n+1))
done

sleep "$INTERVAL"

frozen=0
unreadable=0
for i in $(seq 0 $((n-1))); do
  second="$(hw "${POD[$i]}" "${PORT[$i]}" "${TOPIC[$i]}")"
  delta=$(( second - ${FIRST[$i]} ))
  if [ "${FIRST[$i]}" = "0" ] && [ "$second" = "0" ]; then
    # ZERO AND ZERO IS NOT FROZEN, it is unread. A topic that has never
    # carried anything cannot advance, and calling that a stall would make
    # this check cry wolf on every declared-idle family — which is how a
    # pre-flight gets ignored.
    printf '  %-16s %-24s no data (declared-idle families read this way)\n' \
      "${LABEL[$i]}" "${TOPIC[$i]}"
    unreadable=$((unreadable + 1))
  elif [ "$delta" -gt 0 ]; then
    printf '  %-16s %-24s +%s\n' "${LABEL[$i]}" "${TOPIC[$i]}" "$delta"
  else
    printf '  %-16s %-24s FROZEN at %s\n' "${LABEL[$i]}" "${TOPIC[$i]}" "$second"
    frozen=$((frozen + 1))
  fi
done

echo
if [ "$frozen" -eq 0 ]; then
  echo "advancing: every measured stage moved over ${INTERVAL}s"
  echo
  echo "WHAT THIS DOES NOT ESTABLISH:"
  echo "  * That the data is CORRECT. A stage can advance with wrong content;"
  echo "    this only rules out the silently-stopped case."
  echo "  * That a stage will still be moving in a minute. A wedge can begin"
  echo "    at any time, which is why this is a pre-flight and not a proof."
  exit 0
fi

echo "advancing: $frozen stage(s) FROZEN over ${INTERVAL}s" >&2
echo "  A frozen stage with healthy pods is the shape this exists to catch:" >&2
echo "  a bridge that stopped consuming without logging an error, or an" >&2
echo "  ingest in a fatal producer state that still receives and decodes." >&2
echo "  Check the component's committed offsets and its error counters, not" >&2
echo "  its pod status. DO NOT SEVER OR RECORD until this passes: a" >&2
echo "  measurement taken over a frozen pipeline describes nothing." >&2
exit 1
