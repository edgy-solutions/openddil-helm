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

# ---------------------------------------------------------------------------
# THE KIND GATE'S DROP COUNTER — read here because nothing else reads it.
# ---------------------------------------------------------------------------
# The ingress kind gate (openddil-demo/dynamic-mappings/dis-kind-gate.yaml)
# refuses DIS entity kinds outside the admitted set and counts what it refuses,
# per kind, as `dis_ingress_kind_dropped`. Redpanda Connect exposes it on
# :4196 in Prometheus form — and NOTHING SCRAPES :4196. No ServiceMonitor, no
# prometheus.io/scrape annotation anywhere in the chart. A counter that exists
# only at an endpoint nobody reads is the same shape as a test that asserts
# nothing: present, plausible, and never consulted. So it is read here, in the
# one place a person looks before they sever or record.
#
# IT DOES NOT GATE THE EXIT CODE, DELIBERATELY. Drops are the gate WORKING. A
# feed carrying munitions is supposed to have them refused, so every recording
# with live weapons in it will show a non-zero counter, and a pre-flight that
# fails on correct behaviour is a pre-flight that gets skipped. What is printed
# instead is the number and its movement over the interval, which is what lets
# a reader say whether it matches the feed they think they are watching. The
# same holds for the gate being ABSENT: it is printed loudly, but this script's
# exit code means "every measured stage advanced", and overloading it with a
# second meaning would make a red result ambiguous. The gate is enforced by the
# work-package step that installs it, not by this check.
#
# THREE STATES, KEPT DISTINCT, because two of them look identical if you are
# careless about it:
#   * endpoint unreachable   -> the counter is UNMEASURED. It says nothing, and
#                               must not be read as a zero.
#   * endpoint up, no series -> Connect creates a series on its first
#                               increment, so this is EITHER "nothing refused
#                               yet" OR "the gate is not loaded at all".
#                               Resolved by looking for the mapping file.
#   * series present         -> the value, plus its delta over the interval.
#
# Pods are discovered rather than listed, unlike PROBES above. There is a third
# edge in the lab that PROBES does not cover; a hardcoded list would have read
# two of three and reported silence for the one nobody thought about.

CONNECT_METRICS_PORT=4196
GATE_MAPPING=dis-kind-gate.yaml

# Echoes "UNREACHABLE", or zero or more `kind=value` lines (none = no series).
kind_drops() {
  local body
  # `sh -c` rather than a bare argv path: a container-absolute path as a direct
  # argument gets rewritten by MSYS when this is run from Git Bash on Windows,
  # and the failure surfaces as `ls: C:/Program Files/Git/mappings` — which
  # would read here as an unreachable endpoint rather than as a quoting bug.
  body="$(kubectl exec -n "$NS" "$1" -c connect -- \
            sh -c "wget -qO- http://localhost:$CONNECT_METRICS_PORT/metrics" \
          2>/dev/null)"
  if [ -z "$body" ]; then
    echo "UNREACHABLE"
    return
  fi
  # Connect appends its own `label` and `path` labels to every series a metric
  # processor emits, so `kind` is matched wherever it sits in the block rather
  # than by position.
  printf '%s\n' "$body" | awk '
    /^dis_ingress_kind_dropped\{/ {
      k = "?"
      if (match($0, /kind="[^"]*"/)) k = substr($0, RSTART + 6, RLENGTH - 7)
      agg[k] += $NF
    }
    END { for (k in agg) printf "%s=%d\n", k, agg[k] }
  '
}

# Is the gate mapping actually loaded in this pod? This is what separates
# "nothing has been refused" from "nothing can be refused".
gate_present() {
  kubectl exec -n "$NS" "$1" -c connect -- sh -c 'ls -1 /mappings' 2>/dev/null \
    | grep -q "$GATE_MAPPING"
}

# Sample every Connect pod's per-kind counters into the two named assoc arrays.
# Namerefs rather than eval: the pod name and the kind both end up inside an
# array subscript, and an eval there is one unexpected character away from
# executing it.
sample_drops() {
  local -n reach="$1"
  local -n val="$2"
  local pod line k v
  [ "${#CONNECT_PODS[@]}" -eq 0 ] && return 0
  for pod in "${CONNECT_PODS[@]}"; do
    reach["$pod"]=1
    while read -r line; do
      [ -z "$line" ] && continue
      if [ "$line" = "UNREACHABLE" ]; then
        reach["$pod"]=0
        continue
      fi
      k="${line%%=*}"; v="${line#*=}"
      val["$pod|$k"]="$v"
      KINDS_SEEN["$pod|$k"]=1
    done < <(kind_drops "$pod")
  done
}

# Deployment-name matching, not a label selector: the component label is
# `redpanda-connect-<edge id>`, which differs per edge and so cannot be matched
# by equality. Nothing else in the namespace carries this substring.
CONNECT_PODS=()
while read -r pod; do
  [ -n "$pod" ] && CONNECT_PODS+=("$pod")
done < <(kubectl get pods -n "$NS" -o name 2>/dev/null \
           | sed -n 's|^pod/||p' | grep -- '-redpanda-connect-')

declare -A DROP_FIRST DROP_SECOND REACH_FIRST REACH_SECOND KINDS_SEEN

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

sample_drops REACH_FIRST DROP_FIRST

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

# ---------------------------------------------------------------------------
# The kind gate's drops. Reported, never gating — see the comment on kind_drops.
# ---------------------------------------------------------------------------
sample_drops REACH_SECOND DROP_SECOND

echo
echo "kind gate — DIS entity kinds refused at admission"
if [ "${#CONNECT_PODS[@]}" -eq 0 ]; then
  printf '  %-16s no redpanda-connect pods found in %s — counter unmeasured\n' \
    "(none)" "$NS"
else
  for pod in "${CONNECT_PODS[@]}"; do
    short="$(printf '%s' "$pod" | sed 's/.*redpanda-connect-//; s/-[^-]*-[^-]*$//')"
    if [ "${REACH_SECOND[$pod]:-0}" = "0" ] && [ "${REACH_FIRST[$pod]:-0}" = "0" ]; then
      printf '  %-16s UNMEASURED — :%s unreachable, this is not a zero\n' \
        "$short" "$CONNECT_METRICS_PORT"
      continue
    fi
    kinds=""
    for key in "${!KINDS_SEEN[@]}"; do
      case "$key" in
        "$pod|"*) kinds="$kinds ${key#*|}" ;;
      esac
    done
    if [ -z "$kinds" ]; then
      # No series. Which of the two reasons is it?
      if gate_present "$pod"; then
        printf '  %-16s gate loaded, nothing refused since pod start\n' "$short"
      else
        printf '  %-16s GATE NOT LOADED — %s absent from /mappings\n' \
          "$short" "$GATE_MAPPING"
        printf '  %-16s   every DIS kind is admitted here, so munitions become\n' ""
        printf '  %-16s   assets. Required by WORK-DEPLOY-revision-51 section 2.9.\n' ""
      fi
      continue
    fi
    for k in $(printf '%s\n' $kinds | sort -n); do
      before="${DROP_FIRST["$pod|$k"]:-0}"
      after="${DROP_SECOND["$pod|$k"]:-0}"
      delta=$(( after - before ))
      if [ "$delta" -gt 0 ]; then
        printf '  %-16s kind=%-4s %-10s +%s over %ss (refusing now)\n' \
          "$short" "$k" "$after" "$delta" "$INTERVAL"
      else
        printf '  %-16s kind=%-4s %-10s no change over %ss\n' \
          "$short" "$k" "$after" "$INTERVAL"
      fi
    done
  done
  echo
  echo "  A number here is the gate working, not a fault — kind 1 is the only"
  echo "  admitted kind, so a munition-carrying feed SHOULD show kind=2 rising."
  echo "  Judge it against the feed you expect: a zero during live weapons and"
  echo "  a rising count during a platforms-only run are both worth a pause."
fi

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
