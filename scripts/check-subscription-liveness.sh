#!/usr/bin/env bash
# ===========================================================================
# check-subscription-liveness.sh — is a Restate Kafka SUBSCRIPTION actually
# delivering, or just registered?
# ===========================================================================
# THE GAP THIS FILLS. Restate's Kafka ingress deduplicates each subscription
# by (consumer group, topic, partition), using the record's offset as the
# sequence number it has already seen. If a topic's offsets ever go
# backwards -- the topic was deleted and recreated, and the new topic starts
# back at offset 0 -- Restate treats every record below the old high mark as
# already-seen and drops it, silently. No error is raised anywhere.
#
# The consumer group driving that subscription still reports Stable, and
# broker-side lag still reads ~0, because the broker has no notion that the
# topic underneath it is a different topic than the one the group last
# committed against. Lag answers "is the consumer caught up with the
# broker", not "is anything the consumer reads ever reaching a handler". So
# a broker-side read -- `rpk group describe`, `rpk topic describe -p` -- is
# structurally blind to this failure. It can only be seen from Restate's own
# side: did the subscription's handler actually get invoked.
#
# THE THREE QUESTIONS, per subscription:
#   1. input   — has the source topic held a record since T at all
#   2. invoked — has Restate created an invocation from this subscription
#                since T
# Verdict is built from those two:
#   LIVE     input yes, invocations > 0 — subscription is delivering.
#   STALLED  input yes, invocations == 0 after the wait window — the drop
#            this script exists to catch.
#   IDLE     no input since T at all. Not a failure: a quiet topic and a
#            dropped subscription are indistinguishable from "zero
#            invocations", so this is reported as unmeasured, not passing.
#   UNMAPPED subscription's source cluster does not resolve to a broker pod
#            that exists.
#   UNMEASURED any read (admin API, topic read, SQL) could not be parsed
#            with confidence.
#
# ---------------------------------------------------------------------------
# WHY THIS SCRIPT REFUSES TO REPORT A NUMBER IT DID NOT READ
# ---------------------------------------------------------------------------
# Same discipline as check-derive-stage.sh and check-effector-consumer.sh: an
# unreadable or unparseable read is an ERROR, never a confident zero, and the
# cluster guard runs first. A check that finds zero subscriptions to examine
# is not a quiet pass -- it found nothing to check, and that is reported as
# a failure rather than silently agreeing with whatever is or isn't there.
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# SOURCE_ONLY lets a fixture test load the parsing/verdict functions below
# without running the cluster guard or the probe itself -- the same shape
# check-effector-consumer.sh's own offline test uses. Never set this to skip
# the guard for a real run.
if [ "${OPENDDIL_SUBSCRIPTION_LIVENESS_SOURCE_ONLY:-0}" != "1" ]; then
  # shellcheck source=lib/require-cluster.sh
  . "$HERE/lib/require-cluster.sh"
  openddil_require_cluster
fi

NS="${NS:-openddil}"
REL="${OPENDDIL_RELEASE:-openddil}"
RPK_CMD_TIMEOUT="${RPK_CMD_TIMEOUT:-20}"
POLL_INTERVAL_S=15

# ---------------------------------------------------------------------------
# discover_restate_pods — Restate runtimes in NS, root tier and every other
# tier alike. Copied from reset-scenario.sh's discover_restate_runtimes()
# (not sourced -- this script must not depend on that file at runtime): a
# Restate runtime is a Running pod with a container literally named
# `restate`, which is also the container name every exec below passes to
# `-c`. That selector was resolved by measurement there (a name-pattern
# alone catches terminated bootstrap Jobs and misses nothing) and is reused
# as-is, not re-derived.
# ---------------------------------------------------------------------------
discover_restate_pods() {
  kubectl get pods -n "$NS" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}' \
    2>/dev/null | grep -E $'\t(.*,)?restate,' | cut -f1 || true
}

# ---------------------------------------------------------------------------
# parse_subscriptions RAW -> "id<TAB>cluster<TAB>topic<TAB>handler" lines,
# one per subscription.
#
# No JSON parser available on either side (python3 may not exist in the
# pod; this script deliberately carries none either), so this reads the
# admin API's response the same way reset-scenario.sh's restate_subscriptions
# reads it: grep -oE over flat scalar fields, never a real object walk.
#
# UNLIKE restate_subscriptions, this does NOT pull id/source/sink as three
# independent whole-document passes and zip them by position -- that is
# only safe when every subscription in the response is guaranteed to emit
# exactly one of each field in the same relative order, and this script also
# needs `id`, which that approach never carried. Instead, each WHOLE
# subscription object is matched first (anchored on the fixed id/source/
# sink/options key order every subscription object uses -- only the OPTIONS
# value's internal key order varies, never the four top-level keys), and
# id/source/sink are then re-read from within that one already-isolated
# match. A subscription whose shape doesn't match the anchor is skipped, not
# guessed at.
# ---------------------------------------------------------------------------
parse_subscriptions() {
  local raw="$1" flat obj id src sink cluster topic handler
  flat="$(printf '%s' "$raw" | tr -d '\n')"
  printf '%s\n' "$flat" \
    | grep -oE '\{"id"[[:space:]]*:[[:space:]]*"[^"]*"[[:space:]]*,[[:space:]]*"source"[[:space:]]*:[[:space:]]*"kafka://[^"]*"[[:space:]]*,[[:space:]]*"sink"[[:space:]]*:[[:space:]]*"service://[^"]*"[[:space:]]*,[[:space:]]*"options"[[:space:]]*:[[:space:]]*\{[^}]*\}[[:space:]]*\}' \
    | while IFS= read -r obj; do
        id="$(printf '%s' "$obj" | grep -oE '"id"[[:space:]]*:[[:space:]]*"[^"]*"' \
              | sed -E 's/^"id"[[:space:]]*:[[:space:]]*"//; s/"$//')"
        src="$(printf '%s' "$obj" | grep -oE '"source"[[:space:]]*:[[:space:]]*"kafka://[^"]*"' \
              | sed -E 's#^"source"[[:space:]]*:[[:space:]]*"kafka://##; s/"$//')"
        sink="$(printf '%s' "$obj" | grep -oE '"sink"[[:space:]]*:[[:space:]]*"service://[^"]*"' \
              | sed -E 's#^"sink"[[:space:]]*:[[:space:]]*"service://##; s/"$//')"
        cluster="${src%%/*}"
        topic="${src#*/}"
        handler="$sink"
        if [ -n "$id" ] && [ -n "$cluster" ] && [ -n "$topic" ] && [ -n "$handler" ]; then
          printf '%s\t%s\t%s\t%s\n' "$id" "$cluster" "$topic" "$handler"
        fi
      done
}

# ---------------------------------------------------------------------------
# broker_pod_for_cluster CLUSTER -> broker pod name, or empty.
#
# Subscription sources are `kafka://openddil-<x>/<topic>` (the `openddil-`
# prefix is fixed by the chart's own subscription-registration template, not
# by the release name), and the matching broker pod is `<release>-redpanda-
# <x>-0`. A cluster name that doesn't start with the fixed prefix cannot be
# mapped -- that is a shape this script has never seen, not a broker it can
# guess at, so it returns empty rather than fabricating a pod name.
# ---------------------------------------------------------------------------
broker_pod_for_cluster() {
  local cluster="$1"
  case "$cluster" in
    openddil-*) printf '%s-redpanda-%s-0' "$REL" "${cluster#openddil-}" ;;
    *) printf '' ;;
  esac
}

# ---------------------------------------------------------------------------
# restate_json_arr POD SQL -> the JSON array text only (drops the leading
# human-readable "N rows. Query took ..." summary line). Same split
# reset-scenario.sh's restate_json uses on `restate sql --json`'s output.
# ---------------------------------------------------------------------------
restate_json_arr() {
  local pod="$1" sql="$2" out
  out="$(kubectl exec -n "$NS" "$pod" -c restate -- restate sql --json "$sql" 2>/dev/null)"
  printf '%s\n' "$out" | sed -n '/^[[:space:]]*\[/,$p'
}

# ---------------------------------------------------------------------------
# json_field RAW FIELD -> one value per line. Same flat-scalar grep
# reset-scenario.sh's json_field uses -- every field this script reads is a
# flat scalar, so no JSON parser is needed, and `|| true` is load-bearing:
# "no rows matched" is a legitimate answer (zero invocations since T) and
# must not make the pipeline fail under `pipefail`.
# ---------------------------------------------------------------------------
json_field() {
  local raw="$1" field="$2"
  printf '%s' "$raw" \
    | { grep -oE "\"${field}\":(\"[^\"]*\"|-?[0-9]+(\.[0-9]+)?)" || true; } \
    | sed -E "s/^\"${field}\"://; s/^\"//; s/\"\$//"
}

# ---------------------------------------------------------------------------
# restate_count_since POD SUB_ID SINCE -> an invocation count on stdout, or
# prints nothing and returns 1. Never prints a fabricated 0 for a read that
# could not be parsed -- that is the exact failure mode ("no error, ~0 lag")
# this whole check exists to stop reproducing in its own measurement.
# ---------------------------------------------------------------------------
restate_count_since() {
  local pod="$1" id="$2" since="$3" sql arr n
  sql="select count(*) as n from sys_invocation where invoked_by_subscription_id = '${id}' and created_at > timestamp '${since}'"
  arr="$(restate_json_arr "$pod" "$sql")"
  n="$(json_field "$arr" "n" | tail -1)"
  if ! [[ "$n" =~ ^[0-9]+$ ]]; then
    return 1
  fi
  printf '%s' "$n"
}

# ---------------------------------------------------------------------------
# read_input BROKER_POD TOPIC SINCE -> "yes" or "no" on stdout, or prints
# nothing and returns 1 on any error.
#
# Form chosen for `rpk topic consume`: `-o "@<SINCE>:end" -n 1 --meta-only
# --pretty-print=false`, wrapped in `timeout`. `@t1:t2` consumes from
# timestamp t1 until timestamp t2, and `end` as t2 means "the current end of
# the partition at the moment the command starts" (per `rpk topic consume
# --help`'s OFFSETS section) -- not "wait for new data forever". That is the
# form that answers "is there a record at or after T" without ever blocking
# on a topic that has nothing newer: an end-bounded read returns as soon as
# it has read up to the end it captured at start, whether that is one record
# or none. `-n 1` additionally stops it after the first record on a topic
# that does have a lot of input, rather than reading the whole range.
# `--meta-only` and `--pretty-print=false` keep the read to one line of
# metadata with no record VALUE in it -- this only needs to know a record
# existed, never what it said. `timeout` is the belt-and-braces: measured
# against a local broker, both the hit and the miss case return in well
# under a second, but a stuck read must still not hang the whole check.
# ---------------------------------------------------------------------------
read_input() {
  local pod="$1" topic="$2" since="$3" out rc
  out="$(kubectl exec -n "$NS" "$pod" -c redpanda -- \
          timeout "$RPK_CMD_TIMEOUT" rpk topic consume "$topic" \
            -o "@${since}:end" -n 1 --meta-only --pretty-print=false 2>&1)"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "READ-FAILED rc=$rc topic=$topic pod=$pod: $(printf '%s' "$out" | head -1)" >&2
    return 1
  fi
  if [ -n "$out" ]; then
    echo yes
  else
    echo no
  fi
}

# ---------------------------------------------------------------------------
# compute_verdict INPUT INVOCATIONS -> LIVE | STALLED | IDLE | UNMEASURED.
#
# INPUT is "yes" / "no" / "error". INVOCATIONS is a non-negative integer or
# "error" -- it is only ever consulted when INPUT is "yes", so an UNMAPPED
# subscription (which never gets this far) never passes through here at all;
# the caller reports UNMAPPED directly. Pure function: no I/O, no clock, so a
# fixture test can exercise every branch without a cluster.
#
# STALLED is the provisional reading right after one check; the caller is
# what turns a provisional STALLED into a final one by re-calling this after
# re-reading INVOCATIONS, for up to --wait seconds. This function has no
# notion of "provisional" -- it always reports what the two inputs it was
# given say, right now.
# ---------------------------------------------------------------------------
compute_verdict() {
  local input="$1" invocations="$2"
  if [ "$input" = "no" ]; then
    echo IDLE
    return 0
  fi
  if [ "$input" != "yes" ]; then
    echo UNMEASURED
    return 0
  fi
  if ! [[ "$invocations" =~ ^[0-9]+$ ]]; then
    echo UNMEASURED
    return 0
  fi
  if [ "$invocations" -gt 0 ]; then
    echo LIVE
  else
    echo STALLED
  fi
}

# ---------------------------------------------------------------------------
# compute_exit TOTAL STALLED UNMEASURED -> 0 or 1.
#
# TOTAL == 0 is a FAIL on its own -- a check that discovered zero
# subscriptions found nothing to check, and that must never read the same
# as "checked everything, all clear". UNMEASURED here is meant to include
# UNMAPPED: both are read failures from the gate's point of view, counted
# together in the `unmeasured=` summary field. Pure function, same reason as
# compute_verdict.
# ---------------------------------------------------------------------------
compute_exit() {
  local total="$1" stalled="$2" unmeasured="$3"
  if [ "$total" -eq 0 ] || [ "$stalled" -gt 0 ] || [ "$unmeasured" -gt 0 ]; then
    echo 1
  else
    echo 0
  fi
}

# A fixture test sources this file for the functions above and stops here,
# never reaching the cluster guard, argument parsing, or the probe's main
# loop below.
if [ "${OPENDDIL_SUBSCRIPTION_LIVENESS_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

usage() {
  echo "Usage: $0 --since <RFC3339 UTC, e.g. 2026-01-01T00:00:00Z> [--wait SECONDS]" >&2
}

SINCE=""
WAIT=300
while [ $# -gt 0 ]; do
  case "$1" in
    --since) SINCE="${2:-}"; shift 2 ;;
    --wait) WAIT="${2:-}"; shift 2 ;;
    *) usage; exit 3 ;;
  esac
done
if [ -z "$SINCE" ] || ! [[ "$WAIT" =~ ^[0-9]+$ ]]; then
  usage
  exit 3
fi

echo "=== subscription liveness since $SINCE (wait up to ${WAIT}s) ==="
echo "  namespace: $NS   release: $REL"
echo

mapfile -t RESTATE_PODS < <(discover_restate_pods)

SUB_POD=(); SUB_ID=(); SUB_CLUSTER=(); SUB_TOPIC=(); SUB_HANDLER=()
for pod in "${RESTATE_PODS[@]}"; do
  raw="$(kubectl exec -n "$NS" "$pod" -c restate -- sh -c \
    "curl -s -m 15 http://localhost:9070/subscriptions" 2>/dev/null)"
  [ -z "$raw" ] && continue
  while IFS=$'\t' read -r sub_id sub_cluster sub_topic sub_handler; do
    [ -z "$sub_id" ] && continue
    SUB_POD+=("$pod")
    SUB_ID+=("$sub_id")
    SUB_CLUSTER+=("$sub_cluster")
    SUB_TOPIC+=("$sub_topic")
    SUB_HANDLER+=("$sub_handler")
  done < <(parse_subscriptions "$raw")
done

TOTAL="${#SUB_ID[@]}"
VERDICT=(); INPUT_FLAG=(); INV_COUNT=()
PENDING_IDX=()

for i in "${!SUB_ID[@]}"; do
  cluster="${SUB_CLUSTER[$i]}"
  topic="${SUB_TOPIC[$i]}"
  id="${SUB_ID[$i]}"
  pod="${SUB_POD[$i]}"

  broker="$(broker_pod_for_cluster "$cluster")"
  if [ -z "$broker" ] || ! kubectl get pod -n "$NS" "$broker" >/dev/null 2>&1; then
    VERDICT[$i]="UNMAPPED"
    INPUT_FLAG[$i]="error"
    INV_COUNT[$i]="n/a"
    continue
  fi

  if inp="$(read_input "$broker" "$topic" "$SINCE")"; then
    INPUT_FLAG[$i]="$inp"
  else
    INPUT_FLAG[$i]="error"
  fi

  if [ "${INPUT_FLAG[$i]}" != "yes" ]; then
    INV_COUNT[$i]="n/a"
    VERDICT[$i]="$(compute_verdict "${INPUT_FLAG[$i]}" "n/a")"
    continue
  fi

  if inv="$(restate_count_since "$pod" "$id" "$SINCE")"; then
    INV_COUNT[$i]="$inv"
  else
    INV_COUNT[$i]="error"
  fi
  VERDICT[$i]="$(compute_verdict "${INPUT_FLAG[$i]}" "${INV_COUNT[$i]}")"
  [ "${VERDICT[$i]}" = "STALLED" ] && PENDING_IDX+=("$i")
done

if [ "${#PENDING_IDX[@]}" -gt 0 ]; then
  start=$(date -u +%s)
  while [ "${#PENDING_IDX[@]}" -gt 0 ] && [ $(( $(date -u +%s) - start )) -lt "$WAIT" ]; do
    sleep "$POLL_INTERVAL_S"
    still_pending=()
    for i in "${PENDING_IDX[@]}"; do
      if inv="$(restate_count_since "${SUB_POD[$i]}" "${SUB_ID[$i]}" "$SINCE")"; then
        INV_COUNT[$i]="$inv"
      else
        INV_COUNT[$i]="error"
      fi
      VERDICT[$i]="$(compute_verdict "${INPUT_FLAG[$i]}" "${INV_COUNT[$i]}")"
      [ "${VERDICT[$i]}" = "STALLED" ] && still_pending+=("$i")
    done
    PENDING_IDX=("${still_pending[@]}")
  done
fi

live=0; idle=0; stalled=0; unmeasured=0
for i in "${!SUB_ID[@]}"; do
  v="${VERDICT[$i]}"
  printf '%s %s %s %s -> %s input=%s invocations=%s\n' \
    "$v" "${SUB_POD[$i]}" "${SUB_ID[$i]}" "${SUB_TOPIC[$i]}" "${SUB_HANDLER[$i]}" \
    "${INPUT_FLAG[$i]}" "${INV_COUNT[$i]}"
  case "$v" in
    LIVE) live=$((live + 1)) ;;
    IDLE)
      idle=$((idle + 1))
      echo "  liveness unmeasured: no input since $SINCE"
      ;;
    STALLED) stalled=$((stalled + 1)) ;;
    UNMAPPED|UNMEASURED) unmeasured=$((unmeasured + 1)) ;;
  esac
done

echo
echo "subscriptions=$TOTAL live=$live idle=$idle stalled=$stalled unmeasured=$unmeasured"

fail="$(compute_exit "$TOTAL" "$stalled" "$unmeasured")"
if [ "$TOTAL" -eq 0 ]; then
  echo "FAIL: zero subscriptions discovered -- a check that found nothing to" >&2
  echo "  check must not pass." >&2
fi
exit "$fail"
