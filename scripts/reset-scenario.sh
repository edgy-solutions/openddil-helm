#!/usr/bin/env bash
# ===========================================================================
# reset-scenario.sh — the only real delete in the system
# ===========================================================================
#
# WHAT THIS IS
#
# A live demo runs a scenario, then has to run it again from the same
# baseline. Nothing in the pipeline is built to make that possible on its
# own: Restate's Virtual Objects are durable by design, the carrying Kafka
# topics are compacted (last record per key kept forever), the projector
# tables are upsert-only with no retention, the regional aggregator holds a
# Faust table backed by a changelog topic that replays on every restart, and
# Electric's shape logs are append-only. Each of those is the CORRECT
# behaviour for a system that is supposed to remember a fleet. None of them
# is what a demo operator wants between take one and take two.
#
# This script is the deliberate exception: it reaches into five kinds of
# state and empties them. It is the ONLY place in this repo that does a real,
# permanent delete of scenario data. Every other script either reads,
# restarts, or reconfigures.
#
# WHAT THIS RESETS, AND WHAT IT DOES NOT
#
# It resets the DEPLOYMENT — the whole fleet's accumulated scenario state —
# never a single asset. There is no "remove this one asset" mode here on
# purpose: per-asset deletion is the lifecycle question (see
# FINDING-2026-09-26-no-asset-eviction.md and the lifecycle ADR's answer,
# "no deletes"), and conflating the two would make an operator reach for a
# blunt whole-fleet tool to solve a one-asset problem, or vice versa.
#
# THE FIVE COMPONENTS, AND WHY EACH NEEDS ITS OWN STEP
# (full detail: PREDICTION-2026-09-26-scenario-reset.md, this doc's sibling
# and the source of every predicted value this script verifies against)
#
#   1. Restate     — per-Virtual-Object journals on a PVC. AssetLogistics
#                     re-arms its own timer every tick, forever
#                     (asset_logistics.py:477). Clearing state without first
#                     cancelling the scheduled timer lets the very next tick
#                     fire against empty state and recreate what was cleared.
#   2. Topics       — the carrying topics are cleanup.policy=compact, so the
#                     last record per key survives indefinitely. Deleting or
#                     recreating a topic would require restating its config
#                     here — a second copy of the chart's topic matrix that
#                     drifts. Trimming needs no config knowledge at all.
#   3. Stores       — 12 of 13 tables are upsert-mode with no retention.
#                     TRUNCATE is rejected: it emits one WAL message that
#                     Electric's client does not reliably honour, so the
#                     failure mode is "Postgres says 0 rows, UI still shows
#                     the old fleet." Per-row DELETE propagates correctly.
#   4. Aggregator   — Faust's table is memory-backed but changelog-backed:
#                     a pod bounce replays the changelog and restores every
#                     key. The changelog IS a topic, so it is trimmed in step
#                     4 (topics) — but the Faust pods must not restart until
#                     after that trim, which is why the restart is its own
#                     step, strictly after topics.
#   5. Electric     — no PVC, no mounted volume: shape logs live in the pod's
#                     container filesystem. Deleting the pod is the entire
#                     mechanism; clients rebuild shapes against a new handle
#                     on their next request.
#
# ORDER IS THE MECHANISM, NOT A CONVENTION. See the numbered phase comments
# below for why each step has to precede the next; getting two of them
# backwards produces a reset that looks complete on inspection and is not.
#
# Reference: PREDICTION-2026-09-26-scenario-reset.md — every "predicted"
# value this script's --verify pass checks against was written there BEFORE
# this script existed, specifically so the run could disagree with it.
# ===========================================================================
set -euo pipefail

# ---------------------------------------------------------------------------
# WHICH CLUSTER. Asserted, never inherited. See lib/require-cluster.sh.
# There is deliberately no --force / escape hatch here, for the same reason
# there is none in require-cluster.sh itself: this script deletes rows and
# state for a living, and the one time a shortcut around the cluster check
# would be reached for is exactly the wrong cluster, under time pressure.
# ---------------------------------------------------------------------------
# RESET_SCENARIO_SOURCE_ONLY (test-only escape hatch, see the matching guard
# near the "main" dispatch below): skips the cluster assertion when this file
# is sourced for its function definitions instead of run — the guard itself
# calls `exit`, not `return`, so left unguarded it would kill the sourcing
# shell (the test harness), not just this script.
if [ "${RESET_SCENARIO_SOURCE_ONLY:-}" != 1 ]; then
  . "$(dirname "$0")/lib/require-cluster.sh"
fi

NS="${NS:-openddil}"
RELEASE="${RELEASE:-openddil}"

# ---------------------------------------------------------------------------
# Flags
# ---------------------------------------------------------------------------
DRY_RUN=false
BASELINE_ONLY=false
VERIFY_ONLY=false
SKIP_RESTATE=false
SKIP_TOPICS=false
SKIP_AGGREGATOR=false
SKIP_STORES=false
SKIP_ELECTRIC=false
SKIP_PRODUCERS=false
RED_CHECK_TOPIC_CONFIG=false   # JUDGMENT CALL 10 red-check, see phase4_topics
CENSUS_ONLY=false              # census-derived-quiesce read-only preview, see run_census_only
RED_CHECK_ELECTRIC=false       # electric shape-handle red-check, see the RED-CHECK block before phase1_baseline
RED_CHECK_QUIESCE=false        # census-derived-quiesce red-check, see run_red_check_quiesce
WRITER_CENSUS_WINDOW_S=70       # phase 3b: must be >= 2x the longest timer cadence (30s aggregator heartbeat)
WRITER_CENSUS_ONLY=false        # read-only writer census + declared/undeclared verdict, see run_writer_census_only

usage() {
  cat <<'EOF'
reset-scenario.sh — reset all scenario state for the openddil demo deployment

USAGE
  reset-scenario.sh [flags]

  Env overrides:
    NS       target namespace (default: openddil)
    RELEASE  helm release name, used for name-pattern discovery (default: openddil)

FLAGS
  --dry-run          Print every mutating command; execute none. Reads
                      (baseline, discovery, high-watermarks, verify) still
                      run, because you need real numbers to print a real plan.
  --baseline-only     Run phase 1 (record every §4 count) and exit. No writes.
  --verify-only       Run phase 8 alone (re-read every §4 count, PASS/FAIL)
                      against whatever the cluster already is, and exit with
                      that phase's exit code. No writes, no quiesce, no
                      restore — phases 2-7 and 9 do not run. Against a LIVE,
                      UNRESET cluster this is the red check: every populated
                      store and topic reads non-zero against phase 8's
                      "predicted 0" lines, so this MUST exit non-zero. If it
                      passes against a live cluster, the check is broken, not
                      the cluster.
  --skip-restate      Do not cancel invocations or clear Restate state.
  --skip-topics       Do not trim any topic partition.
  --skip-aggregator   Do not restart the Faust deployments. THIS IS THE
                      DOCUMENTED RED-CHECK (PREDICTION doc §5): skipping it
                      alone is expected to leave the regional rollup carrying
                      the pre-reset asset_count even though every store and
                      topic reads clean.
  --skip-stores       Do not DELETE FROM any Postgres table.
  --skip-electric     Do not delete the Electric pods.
  --skip-producers    Do not scale producers down or back up.
  --red-check-topic-config
                      After the first pure-compact topic is policy-trimmed
                      (alter, trim, alter back), perturb its cleanup.policy
                      and confirm the post-restore capture assertion
                      notices before putting it back. Self-repairing;
                      touches exactly one topic. See JUDGMENT CALL 10.
  --census-only       Print the broker consumer census, the derived quiesce
                      set with its provenance (census/restate/floor per
                      workload), and the live-consumer assertion result
                      against the pure-compact (policy-trim) bucket, then
                      exit. Runs the real phase 4 capture pass (a read) so
                      it exercises the same code paths a real run would.
                      MUTATES NOTHING.
  --red-check-quiesce Capture, derive the quiesce set, quiesce every kind in
                      it (including a throwaway DaemonSet this red-check
                      creates itself, since fact 6 is that none exist in the
                      namespace today), run the live-consumer assertion,
                      restore everything, and exit. Touches NO topic. This
                      is what proves the quiesce/restore path handles every
                      kind in work item 3's table without risking a delete.
  --red-check-electric
                      Read every Electric shape handle, then run the phase 8
                      electric check WITHOUT deleting any pod. Read-only.
                      Every handle line must FAIL (UNCHANGED) and, on a
                      populated fleet, every rows line must FAIL (non-zero);
                      exits 0 only if they all did, i.e. only if the check
                      can fail.
  --writer-census-window N
                      Seconds between the two partition reads phase 3b's
                      writer census takes (default 70; must be at least
                      twice the longest timer cadence it needs to see
                      advance, the 30s aggregator heartbeat).
  --writer-census-only
                      Run the writer census (step 1), classify local vs
                      bridged writes, print the per-(broker,topic) table and
                      the declared/undeclared verdict, then exit — 0 if
                      every live local topic is declared, 2 otherwise. No
                      scaling, no halt. For compose proofs and lab
                      pre-checks.
  --help              This text.

Every --skip-* flag prints a loud warning naming the residue it leaves, and
--skip-* does NOT soften the phase 8 zero assertion: the point of the flag is
to make a partial reset visibly, provably partial, not to hide the
consequence of using it.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=true ;;
    --baseline-only) BASELINE_ONLY=true ;;
    --verify-only) VERIFY_ONLY=true ;;
    --skip-restate) SKIP_RESTATE=true ;;
    --skip-topics) SKIP_TOPICS=true ;;
    --skip-aggregator) SKIP_AGGREGATOR=true ;;
    --skip-stores) SKIP_STORES=true ;;
    --skip-electric) SKIP_ELECTRIC=true ;;
    --skip-producers) SKIP_PRODUCERS=true ;;
    --red-check-topic-config) RED_CHECK_TOPIC_CONFIG=true ;;
    --census-only) CENSUS_ONLY=true ;;
    --red-check-quiesce) RED_CHECK_QUIESCE=true ;;
    --red-check-electric) RED_CHECK_ELECTRIC=true ;;
    --writer-census-window) shift; WRITER_CENSUS_WINDOW_S="$1" ;;
    --writer-census-only) WRITER_CENSUS_ONLY=true ;;
    --help|-h) usage; exit 0 ;;
    *) echo "unknown flag: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

# Stamped once, before anything mutates. The aggregator verify needs a
# before-this-run boundary to tell a FRESH rollup from a leftover row, and it
# has to be the same boundary for every phase, so it is taken here and never
# re-read. UTC, because the DB columns are timestamptz.
#
# This host value is only a FALLBACK. It is replaced in phase 1 by the
# database's own now(), because this script runs on a workstation and compares
# against a timestamptz column written by a pod: if the workstation clock is
# even slightly ahead of the cluster, no row ever looks "fresh" and a correct
# reset reports UNMEASURED. The boundary has to come from the same clock as the
# column it is compared to.
RUN_STARTED_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RUN_STARTED_AT_SOURCE="workstation clock (fallback)"

OVERALL_FAIL=0

echo "reset-scenario: namespace=$NS release=$RELEASE dry-run=$DRY_RUN"

# ---------------------------------------------------------------------------
# maybe_run — the single gate every MUTATING action goes through.
#
# Under --dry-run it prints the exact argv it would have executed and does
# nothing. Otherwise it prints the same line (every destructive action says
# what it is about to do, with the target's full name, before doing it —
# required, not decorative: a reset that fails silently partway through is
# indistinguishable from one that succeeded, unless every step announced
# itself first) and then runs it.
#
# Reads (baseline counts, discovery, high-watermarks) do NOT go through
# this — they run unconditionally, dry-run or not, because --dry-run still
# has to show real trim offsets and real row counts to be worth anything.
# ---------------------------------------------------------------------------
maybe_run() {
  local desc="$1"; shift
  echo "-> $desc"
  if $DRY_RUN; then
    printf '   [dry-run] would run:'
    printf ' %q' "$@"
    printf '\n'
    return 0
  fi
  "$@"
}

skip_warning() {
  local component="$1" residue="$2"
  echo
  echo "!!! SKIPPING $component RESET — NOT reset, residue expected !!!"
  echo "    $residue"
  echo
}

# ---------------------------------------------------------------------------
# Discovery — every target is FOUND, never hardcoded, exactly as
# check-advancing.sh discovers its Connect pods by name-pattern rather than
# by listing edges. A hardcoded instance list goes stale the day a tier is
# added (or, per the PREDICTION doc, is asymmetric on purpose: edge-03 has a
# broker and a projector but NO tier Postgres/Restate/Electric stack — a
# script that assumes tiers are uniform either errors looking for
# tier-pg-edge-03 or silently reads a clean reset over a tier it never
# touched). The patterns below name FAMILIES (postgres-hq / tier-pg-,
# restate-server / tier-restate-, etc.), not instances; kubectl tells us
# which instances of each family currently exist.
# ---------------------------------------------------------------------------
discover() {
  # $1 = kubectl resource kind (sts | deploy | pods), $2 = extended regex
  # matched against the bare resource name (kind/ prefix stripped).
  # `|| true`: under `set -e`, a grep that legitimately finds nothing (no
  # tier-pg-edge-03, because there isn't one) must not abort the script.
  kubectl get "$1" -n "$NS" -o name 2>/dev/null \
    | sed 's#^[^/]*/##' \
    | grep -E "$2" || true
}

# RESOLVED BY MEASUREMENT (ROWS doc, call 6). A name-pattern alone is wrong
# here in BOTH directions, and the lab proves both:
#
#   openddil-tier-restate-bootstrap-edge-01-bfhcx   Succeeded   container: bootstrap
#                                                               image: cm-service
#   openddil-restate-hub-864ff98b68-bnrr8           Running     container: restate-hub
#                                                               image: hub-restate-projector
#
# The three `tier-restate-bootstrap-*` Job pods DO match `^…-tier-restate-`
# and would be exec'd into as if they were runtimes — they are terminated
# SDK Jobs, so every query against them fails. `restate-hub` is the hub's SDK
# service (a Deployment, not the runtime) and is excluded only by luck of the
# current pattern, which is not a property to depend on.
#
# So Restate runtimes are discovered by the one thing that actually defines
# one: a Running pod with a container named `restate` — which is the same
# container name every exec below already passes to `-c`. On the lab this
# selects exactly 4 (restate-server-0 + three tier-restate-*-0) and excludes
# the hub SDK Deployment and all three bootstrap Jobs.
discover_restate_runtimes() {
  kubectl get pods -n "$NS" \
    -o jsonpath='{range .items[?(@.status.phase=="Running")]}{.metadata.name}{"\t"}{range .spec.containers[*]}{.name}{","}{end}{"\n"}{end}' \
    2>/dev/null | grep -E $'\t(.*,)?restate,' | cut -f1 || true
}

mapfile -t POSTGRES_PODS < <(discover pods "^${RELEASE}-(postgres-hq|tier-pg-)")
mapfile -t RESTATE_PODS  < <(discover_restate_runtimes)
mapfile -t REDPANDA_PODS < <(discover pods "^${RELEASE}-redpanda-" | grep -v -- '-connect-' || true)
mapfile -t ELECTRIC_PODS < <(discover pods "^${RELEASE}-(electric-sync|tier-electric-)")
mapfile -t FAUST_DEPLOYS < <(discover deploy "^${RELEASE}-faust-")
# egress-intake is a producer for this purpose: it writes intake_records from
# a destination's returned artifacts over HTTP, and it reads its answers topic
# by assignment with no committed group, so the census can never derive it.
# Left running, it refills intake_records between phase 6 and phase 8, and it
# holds partitions on a topic that phase 4 policy-trims. It goes down in phase 2
# and comes back in phase 9 with the other producers. Once back, it re-polls the
# destination and the rows return. That is a refill, the same as every producer.
mapfile -t PRODUCER_DEPLOYS < <(discover deploy \
  "^${RELEASE}-logistics-sim\$|^${RELEASE}-sensor-ingest-edge-|^dis-sim-edge-|^${RELEASE}-egress-intake\$")

# JUDGMENT CALL 10 — SUPERSEDED. This used to be a hand-written name-pattern
# list of state consumers to quiesce around phase 4's delete-and-recreate of
# pure-compact topics, in the same family-regex style as every mapfile
# above. Run B's abort (see SPEC-census-quiesce.md's header) is what this
# pattern actually costs: `asset-registry-service` was an ordinary
# Deployment holding an offset on `telemetry-latest-state` and matched NONE
# of the families below, so it was never quiesced, won the auto-create race
# in the delete-to-create window, and the recreate failed with
# TOPIC_ALREADY_EXISTS. A name pattern missing a consumer is not a bug in
# the pattern, it is what a pattern does.
#
# The regex also over-quiesced: `cm-service`/`tier-cm-` and
# `logistics-fusion-service`/`tier-fusion-` are Restate SINKS (fact 4) that
# consume nothing directly — Restate holds the Kafka subscription — so
# quiescing them was pure ceremony that happened to be harmless, not
# correct.
#
# Replaced by derive_quiesce_set(), which builds the quiesce list per run
# from three ACTUAL sources of truth (the broker consumer census, Restate's
# own /subscriptions list, and a narrower documented floor for exactly the
# case host resolution provably cannot see — proxy masking, fact 3) instead
# of a hand-kept regex. See derive_quiesce_set — kept and exercised
# today by --census-only and --red-check-quiesce; policy-trim (below) no
# longer deletes anything, so phase4_topics itself no longer calls it.
echo "discovered: postgres=${#POSTGRES_PODS[@]} restate=${#RESTATE_PODS[@]}" \
     "redpanda=${#REDPANDA_PODS[@]} electric=${#ELECTRIC_PODS[@]}" \
     "faust=${#FAUST_DEPLOYS[@]} producers=${#PRODUCER_DEPLOYS[@]}"

# ===========================================================================
# CENSUS — derive the quiesce set for phase 4 from measured reality instead
# of a name pattern. See SPEC-census-quiesce.md. All read-only.
#
# SUPERSEDED BY SPEC-consumer-declarations.md (2026-09-30): derivation used
# to resolve a group's owner from its member's connection-source IP (the
# functions that walked IP -> pod -> owner are gone now) — fact 3 (toxiproxy
# masks every real owner behind ONE Deployment name on the HQ broker) proved
# that path SOMETIMES IMPOSSIBLE no matter how carefully it was written, and
# `egress-gate-c2` was the measured cost: proxied, absent from FLOOR_FAMILY_
# REGEX, never quiesced. Ownership is now read from the chart's own
# `openddil.io/consumer-groups` annotation (declared_consumers, below) or
# Restate's own subscription list (restate_subscriptions) — both name the
# real owner directly, with no host in between for a proxy to sit in front
# of. Detecting that a live consumer exists still needs no owner resolution
# at all: MEMBERS on the group says so directly, which is why assert_no_
# live_consumers and the new assert_consumers_declared
# pre-flight (Part B item 4) both re-read the census fresh rather than
# trusting derivation's list — an unresolvable owner is now a REFUSAL
# (assert_consumers_declared), not a silent skip.
# ===========================================================================

# census_groups POD — one broker's consumer census, read-only, two
# tab-separated streams tagged in column 1:
#
#   MEMBERS  group  members_count  state  comma_separated_host_ips
#   TOPIC    group  topic
#
# ONE `rpk group describe` call for every group on this broker (measured
# fact 1: the flag accepts a list), not one call per group — the same
# proven shape as census-probe.sh's measurement script, extended to also
# read the STATE/MEMBERS header fields and to emit a TOPIC row for EVERY
# topic in the block, including a zero-member group's rows (it still holds
# committed offsets, per work item 1 — a group with MEMBERS 0 still
# matters, it just has no host on this pass).
#
# `rpk group describe`'s per-group block is: a small header (GROUP,
# COORDINATOR, STATE, BALANCER, MEMBERS <count>), then one table whose rows
# carry TOPIC/PARTITION/.../MEMBER-ID/CLIENT-ID/HOST — HOST is the row's
# last field when a member is actually assigned, and something else (never
# IP-shaped) when it is not. Parsed by field NAME, never by fixed column
# position, for the same reason topic_shape()/topic_partitions() above do:
# a blank HOST on an unassigned partition does not shift every column after
# it the way a genuinely variable-width field would, but nothing here
# should assume the exact width is stable across rpk versions either.
census_groups() {
  local pod="$1"
  local -a groups
  mapfile -t groups < <(kubectl exec -n "$NS" "$pod" -c redpanda -- rpk group list 2>/dev/null \
    | awk 'NR>1{print $2}')
  [ "${#groups[@]}" -eq 0 ] && return 0

  kubectl exec -n "$NS" "$pod" -c redpanda -- rpk group describe "${groups[@]}" 2>/dev/null | awk '
    function flush() {
      if (group != "") {
        print "MEMBERS\t" group "\t" members "\t" state "\t" hostlist
      }
    }
    BEGIN { FS = "[ \t]+" }
    /^GROUP([ \t]|$)/ {
      flush()
      group = $2; state = ""; members = ""; hostlist = ""
      delete hosts
      next
    }
    group == "" { next }
    $1 == "STATE" && NF == 2   { state = $2; next }
    $1 == "MEMBERS" && NF == 2 { members = $2; next }
    $1 == "COORDINATOR" || $1 == "BALANCER" || $1 == "TOTAL-LAG" { next }
    $1 == "TOPIC" && $2 == "PARTITION" { next }   # the data table'\''s own header row
    NF < 2 { next }                                # blank lines between sections
    $1 ~ /__assignor/ { next }                     # Faust leader-election control topics
    {
      print "TOPIC\t" group "\t" $1
      if ($NF ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && !($NF in hosts)) {
        hosts[$NF] = 1
        hostlist = (hostlist == "" ? $NF : hostlist "," $NF)
      }
    }
    END { flush() }
  '
}

# Declared proxies. Exactly one, per measured fact 3: openddil-toxiproxy
# masks every real consumer on the HQ broker behind its own Deployment name
# and host IP — CLIENT-ID does not disambiguate (rdkafka or faust-0.15.3),
# and two DIFFERENT real owners report the SAME host through it.
#
# NARROWED SCOPE (SPEC-consumer-declarations.md): the only remaining caller
# of _is_declared_proxy_name is _owner_of_pod, below, and _owner_of_pod's
# only remaining caller is restate_subscriptions, which only ever passes it
# a Restate runtime pod — never toxiproxy — so the PROXY branch cannot fire
# in practice any more. Left in place because _owner_of_pod is still a
# general pod->owner walk whose documented contract includes a PROXY result,
# and a future caller of it (not just restate_subscriptions) should get that
# contract honoured rather than silently dropped.
DECLARED_PROXY_DEPLOYS=("${RELEASE}-toxiproxy")

_is_declared_proxy_name() {
  local candidate="$1" p
  for p in "${DECLARED_PROXY_DEPLOYS[@]}"; do
    [ "$candidate" = "$p" ] && return 0
  done
  return 1
}

declare -A OWNER_CACHE_BY_POD # restate_subscriptions already has a pod name
                               # and never needs an IP->pod step at all

# _owner_of_pod POD -> Kind/Name (or PROXY/Name, per the declared-proxy
# check above). pod -> ownerReferences[0] directly; a ReplicaSet owner is
# walked one level further to the Deployment that owns IT; no owner
# reference at all means an unowned pod, returned as Pod/<podname> — see
# work item 3's table for why that case is a hard stop, not a quiesce
# target.
_owner_of_pod() {
  local pod="$1" cached kind name rskind rsname result
  cached="${OWNER_CACHE_BY_POD[$pod]:-}"
  if [ -n "$cached" ]; then
    printf '%s' "$cached"
    return 0
  fi
  read -r kind name < <(kubectl get pod -n "$NS" "$pod" \
    -o jsonpath='{.metadata.ownerReferences[0].kind} {.metadata.ownerReferences[0].name}' 2>/dev/null)
  if [ "${kind:-}" = "ReplicaSet" ]; then
    read -r rskind rsname < <(kubectl get rs -n "$NS" "$name" \
      -o jsonpath='{.metadata.ownerReferences[0].kind} {.metadata.ownerReferences[0].name}' 2>/dev/null)
    result="${rskind:-ReplicaSet}/${rsname:-$name}"
  elif [ -z "${kind:-}" ]; then
    result="Pod/$pod"
  else
    result="$kind/$name"
  fi
  if _is_declared_proxy_name "${result#*/}"; then
    result="PROXY/${result#*/}"
  fi
  OWNER_CACHE_BY_POD["$pod"]="$result"
  printf '%s' "$result"
}

# declared_consumers -> "<broker-id>\t<group>\t<Kind>/<name>" per entry in
# every Deployment/StatefulSet's `openddil.io/consumer-groups` annotation
# (SPEC-consumer-declarations.md Part A), ONE kubectl call for the whole
# namespace. This is the replacement for owner-by-connection-IP: the chart
# writes the real owner onto the workload itself, so there is no host in
# between for a proxy (fact 3) to stand in front of.
#
# The annotation key's embedded dot is escaped the same way kubectl's own
# docs escape "kubernetes.io/created-by" in a jsonpath expression
# (`{.metadata.annotations.kubernetes\.io/created-by}`) — the backslash
# escapes only the literal dot inside the field name; the "/" needs no
# escaping because jsonpath never treats "/" as a path separator.
declared_consumers() {
  local owner value pair
  kubectl get deploy,statefulset -n "$NS" \
    -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\t"}{.metadata.annotations.openddil\.io/consumer-groups}{"\n"}{end}' \
    2>/dev/null \
  | while IFS=$'\t' read -r owner value; do
      [ -z "$value" ] && continue
      for pair in $value; do
        printf '%s\t%s\t%s\n' "${pair%%/*}" "${pair#*/}" "$owner"
      done
    done
}

# Ownership lookup, built once per shell (SPEC-consumer-declarations.md Part
# B items 1-2):
#   DECLARED_OWNER["<broker pod>|<group>"]       -> Kind/Name
#   DECLARED_OWNER_DUPES["<broker pod>|<group>"] -> "<owner1> <owner2> ..."
#     (set only when more than one workload declares the SAME pair — a
#     chart bug, not a missing declaration, and assert_consumers_declared
#     FAILs loudly on it rather than picking one)
#   RESTATE_OWNER_BY_GROUP["<group>"]            -> Kind/Name
#
# Keyed by "<broker pod>|<group>", the SAME shape census_groups() already
# emits ("$pod|$f2" in derive_quiesce_set/_scan_live_consumers/
# assert_consumers_declared below) — broker-id (the annotation's own unit)
# is turned into the broker pod name here, once, so every other caller can
# look a census row's key up directly with no id->pod translation of its
# own. Restate is keyed by group id alone, not "pod|group": fact 5's
# /subscriptions endpoint reports no broker, and group ids are unique
# across Restate runtimes (Part B item 2), so a group-id-only match is
# exact, not a guess.
declare -A DECLARED_OWNER=()
declare -A DECLARED_OWNER_DUPES=()
declare -A RESTATE_OWNER_BY_GROUP=()
DECLARED_MAP_BUILT=false

build_declared_owner_map() {
  $DECLARED_MAP_BUILT && return 0
  DECLARED_MAP_BUILT=true

  local broker group owner pod key prev
  while IFS=$'\t' read -r broker group owner; do
    [ -z "$broker" ] && continue
    pod="${RELEASE}-redpanda-${broker}-0"
    key="$pod|$group"
    prev="${DECLARED_OWNER[$key]:-}"
    if [ -z "$prev" ]; then
      DECLARED_OWNER["$key"]="$owner"
    elif [ "$prev" != "$owner" ]; then
      DECLARED_OWNER_DUPES["$key"]="${DECLARED_OWNER_DUPES[$key]:-$prev} $owner"
    fi
  done < <(declared_consumers)

  local rpod rtopic rgid rowner
  while IFS=$'\t' read -r rpod rtopic rgid rowner; do
    [ -z "$rgid" ] && continue
    RESTATE_OWNER_BY_GROUP["$rgid"]="$rowner"
  done < <(restate_subscriptions)
}

# declared_producers -> "<broker-id>\t<topic>\t<Kind>/<name>" per entry in
# every Deployment/StatefulSet's `openddil.io/produces-topics` annotation —
# the writer-census counterpart of declared_consumers() above, same shape,
# same ONE kubectl call for the whole namespace, same jsonpath escaping.
# Bridges/uplinks carry no such annotation (they forward, not originate —
# see the chart's own comment where the annotation is defined), so they
# never appear here; the writer census reads them separately, as bridge-
# graph edges (bridge_graph(), below).
declared_producers() {
  local owner value pair
  kubectl get deploy,statefulset -n "$NS" \
    -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\t"}{.metadata.annotations.openddil\.io/produces-topics}{"\n"}{end}' \
    2>/dev/null \
  | while IFS=$'\t' read -r owner value; do
      [ -z "$value" ] && continue
      for pair in $value; do
        printf '%s\t%s\t%s\n' "${pair%%/*}" "${pair#*/}" "$owner"
      done
    done
}

# PRODUCER_OWNER["<broker pod>|<topic>"] -> space-separated "Kind/Name"
# owners. Several declared writers of the same topic is normal (e.g. a
# source Faust app and the Faust aggregator both appending to one fan-in
# topic) and is recorded as several names in the same value, not an error
# — unlike DECLARED_OWNER_DUPES above, which flags two DIFFERENT consumer-
# group declarations for what must be one real owner. A topic can have
# many writers; a consumer group cannot have two different declared
# owners without the chart itself disagreeing with itself.
declare -A PRODUCER_OWNER=()
PRODUCER_MAP_BUILT=false

build_declared_producer_map() {
  $PRODUCER_MAP_BUILT && return 0
  PRODUCER_MAP_BUILT=true

  local broker topic owner pod key
  while IFS=$'\t' read -r broker topic owner; do
    [ -z "$broker" ] && continue
    pod="${RELEASE}-redpanda-${broker}-0"
    key="$pod|$topic"
    if [ -z "${PRODUCER_OWNER[$key]:-}" ]; then
      PRODUCER_OWNER["$key"]="$owner"
    else
      PRODUCER_OWNER["$key"]="${PRODUCER_OWNER[$key]} $owner"
    fi
  done < <(declared_producers)
}

declare -A WORKLOAD_PODS_CACHE=() # "Kind/Name" -> newline-joined pod names,
                                   # built once per workload and reused for
                                   # every group that workload owns

# _pods_of_workload "Kind/Name" -> newline-separated pod names currently
# matching that workload's OWN selector (Part B item 6, for _scan_live_
# consumers's report). kubectl has no single verb for "list the pods this
# Deployment/StatefulSet selects", so a cache miss costs two calls: read
# .spec.selector.matchLabels back as a go-template join (no jq — the same
# constraint restate_subscriptions above is written under) and then list
# pods with that label selector. Cached per workload so a group's every
# member host costs this once, not once per member.
_pods_of_workload() {
  local workload="$1" kind name selector pods
  if [ -n "${WORKLOAD_PODS_CACHE[$workload]+set}" ]; then
    printf '%s' "${WORKLOAD_PODS_CACHE[$workload]}"
    return 0
  fi
  kind="$(printf '%s' "${workload%%/*}" | tr '[:upper:]' '[:lower:]')"
  name="${workload#*/}"
  selector="$(kubectl get "$kind" -n "$NS" "$name" \
    -o go-template='{{range $k, $v := .spec.selector.matchLabels}}{{$k}}={{$v}},{{end}}' 2>/dev/null)"
  selector="${selector%,}"
  pods=""
  if [ -n "$selector" ]; then
    pods="$(kubectl get pods -n "$NS" -l "$selector" \
      -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)"
  fi
  WORKLOAD_PODS_CACHE["$workload"]="$pods"
  printf '%s' "$pods"
}

# restate_subscriptions -> pod  topic  group_id  owner, one row per
# subscription, across every runtime in RESTATE_PODS.
#
# RESOLVED BY MEASUREMENT, fact 5: Restate's OWN subscription list is
# authoritative for Restate-mediated consumers, because Restate — not the
# runtime's own visible consumer group — holds the Kafka subscription; the
# broker-side census in census_groups() cannot see these at all (fact 4:
# the CM and fusion services consume nothing directly, they are Restate
# sinks).
#
# No jq (constraint) — `curl` is present in the runtime pod, `wget` is not
# (also fact 5). `source` is `"kafka://<alias>/<topic>"`; the topic is
# everything after the LAST `/`. `options.group.id` is a flat string field.
# Both are pulled by position across the whole response (grep -oE for each
# field name, in the order they appear) rather than by parsing nested
# objects — a real JSON parser is the right tool for that and this script
# deliberately has none (constraint), so this reads it the same way
# json_field() already reads Restate's own --json output: a flat scalar
# grep, not a walk. This assumes each subscription emits exactly one
# `source` and one `group.id`, in the same relative order as every other
# subscription's fields — true of every subscription list measured so far,
# and the one assumption this function makes in exchange for not writing a
# JSON parser in awk.
restate_subscriptions() {
  local pod raw owner
  local -a sources groupids
  local i n topic gid
  for pod in "${RESTATE_PODS[@]}"; do
    owner="$(_owner_of_pod "$pod")"
    raw="$(kubectl exec -n "$NS" "$pod" -c restate -- sh -c \
      "curl -s -m 15 http://localhost:9070/subscriptions" 2>/dev/null)"
    [ -z "$raw" ] && continue

    mapfile -t sources < <(printf '%s' "$raw" \
      | grep -oE '"source"[[:space:]]*:[[:space:]]*"kafka://[^"]*"' \
      | sed -E 's#^"source"[[:space:]]*:[[:space:]]*"kafka://[^/]*/##; s/"$//')
    mapfile -t groupids < <(printf '%s' "$raw" \
      | grep -oE '"group\.id"[[:space:]]*:[[:space:]]*"[^"]*"' \
      | sed -E 's/^"group\.id"[[:space:]]*:[[:space:]]*"//; s/"$//')

    n="${#sources[@]}"
    i=0
    while [ "$i" -lt "$n" ]; do
      topic="${sources[$i]}"
      gid="${groupids[$i]:-}"
      [ -n "$topic" ] && printf '%s\t%s\t%s\t%s\n' "$pod" "$topic" "$gid" "$owner"
      i=$((i + 1))
    done
  done
}

# Work item 2's declared family floor. Originally the only route past a
# proxy-masked consumer (fact 3: proxy masking was not mechanically
# resolvable from the broker side) — now a BACKSTOP, not the only route: the
# chart's own openddil.io/consumer-groups annotation (SPEC-consumer-
# declarations.md) names openddil-projector-hq's real groups directly
# through item 1 below, proxy or no proxy. The floor stays because it is
# NAME-pattern-derived and item 1 is DECLARATION-derived — a family member a
# future chart change forgets to annotate still gets picked up here, same
# as it always has.
#
# `cm-service`/`tier-cm-` and `logistics-fusion-service`/`tier-fusion-` are
# DELIBERATELY ABSENT — fact 4 measured them as Restate sinks that consume
# nothing directly, so quiescing them was never correct; see the removed
# STATE_CONSUMER_DEPLOYS comment above discover_restate_runtimes() for the
# full accounting of what changed and why.
FLOOR_FAMILY_REGEX="^${RELEASE}-(projector-|tier-projector-|faust-|edge-hq-bridge-|tier-uplink-|asset-registry-service|redpanda-connect-|faust-regional-)"

# derive_quiesce_set "pod|topic" ... -> sorted, unique Kind/Name lines on
# stdout; a provenance line (source, then the workload) per entry on
# stderr, so an operator reading the log can see that a workload came from
# the census and not from a guess (work item 2).
#
# Arguments are "pod|topic" pairs — CAPTURED_TOPICS' own shape, not bare
# topic names. Each tier runs its OWN Redpanda broker; the same topic NAME
# on two different brokers is two unrelated topics with two unrelated
# consumer censuses, so matching by name alone would blur an untouched
# broker's topic into scope (or the reverse). Keeping the pod|topic pairing
# end to end is what keeps that scoping exact for the census match (item
# 1). Restate's own subscription list (item 2) has no such pairing to give
# — fact 5's endpoint reports only `kafka://<alias>/<topic>`, no broker pod
# — so that half of the union matches on topic NAME alone, over the union
# of every target topic's bare name.
derive_quiesce_set() {
  local -a targets=("$@")
  local -A is_target=() is_target_topicname=()
  local t
  for t in "${targets[@]}"; do
    is_target["$t"]=1
    is_target_topicname["${t#*|}"]=1
  done

  local -A found=()   # Kind/Name -> provenance source (first source wins)
  local -a order=()   # first-seen order, for the provenance log

  local -A producer_set=()
  local p
  for p in "${PRODUCER_DEPLOYS[@]}"; do producer_set["Deployment/$p"]=1; done

  build_declared_owner_map

  # --- item 1: declared/Restate owner of every census group holding a target
  # topic ---------------------------------------------------------------
  # REPLACES the old connection-source-IP owner walk (SPEC-consumer-
  # declarations.md Part B item 3): a proxied consumer's real owner was
  # never visible from its connection-source IP — every one of them reaches
  # the broker through ${RELEASE}-toxiproxy and resolved to the SAME PROXY/
  # openddil-toxiproxy name, which is exactly how egress-gate-c2 went
  # unquiesced (see the Problem section this spec was written against). The
  # chart's own annotation names the real owner directly, keyed by the SAME
  # "broker pod|group" pair census_groups() already emits, so there is no
  # host-resolution step left for a proxy to sit in front of. An undeclared
  # group adds nothing here on purpose — assert_consumers_declared (item 4)
  # is what refuses those, not a silent drop here. Dropping the Redpanda
  # broker StatefulSets themselves is no longer needed either: the chart
  # never annotates the broker's own StatefulSet, only real consumers.
  local pod tag f2 f3 f4 f5
  local -A group_is_target=()
  for pod in "${REDPANDA_PODS[@]}"; do
    while IFS=$'\t' read -r tag f2 f3 f4 f5; do
      [ -z "$tag" ] && continue
      [ "$tag" = "TOPIC" ] && [ -n "${is_target[$pod|$f3]:-}" ] && group_is_target["$pod|$f2"]=1
    done < <(census_groups "$pod")
  done

  local key group owner
  for key in "${!group_is_target[@]}"; do
    group="${key#*|}"
    owner="${DECLARED_OWNER[$key]:-}"
    if [ -z "$owner" ]; then
      owner="${RESTATE_OWNER_BY_GROUP[$group]:-}"
    fi
    [ -z "$owner" ] && continue
    if [ -z "${found[$owner]:-}" ] && [ -z "${producer_set[$owner]:-}" ]; then
      if [ -n "${DECLARED_OWNER[$key]:-}" ]; then
        found["$owner"]="declared"
      else
        found["$owner"]="restate"
      fi
      order+=("$owner")
    fi
  done

  # --- item 2: Restate runtimes whose subscription topic is a target -----
  local rpod rtopic rgid rowner
  while IFS=$'\t' read -r rpod rtopic rgid rowner; do
    [ -z "$rpod" ] && continue
    if [ -n "${is_target_topicname[$rtopic]:-}" ] \
       && [ -z "${found[$rowner]:-}" ] && [ -z "${producer_set[$rowner]:-}" ]; then
      found["$rowner"]="restate"
      order+=("$rowner")
    fi
  done < <(restate_subscriptions)

  # --- item 3: the declared family floor ----------------------------------
  local -a floor_deploys=()
  mapfile -t floor_deploys < <(discover deploy "$FLOOR_FAMILY_REGEX")
  local fd fdname
  for fd in "${floor_deploys[@]}"; do
    fdname="Deployment/$fd"
    if [ -z "${found[$fdname]:-}" ] && [ -z "${producer_set[$fdname]:-}" ]; then
      found["$fdname"]="floor"
      order+=("$fdname")
    fi
  done

  local name
  for name in "${order[@]}"; do
    printf '%-8s %s\n' "${found[$name]}" "$name" >&2
  done
  for name in "${!found[@]}"; do
    printf '%s\n' "$name"
  done | sort -u
}

# assert_no_live_consumers "pod|topic" ... -> 0 if zero groups anywhere
# hold a live (members_count > 0) offset on any of the given topics, 1
# otherwise. Written as the actual safety gate for the topics
# about to be DELETED, back when the pure-compact (now policy-trim) bucket
# was deleted and recreated — policy-trim never deletes anything, so
# phase4_topics no longer calls this itself. Kept, and still called
# directly against the policy-trim bucket, by --census-only and
# --red-check-quiesce, as a standalone rehearsal of the same read.
#
# Re-reads the census FRESH, every call — deliberately not reusing
# derive_quiesce_set's earlier read, which was taken BEFORE the quiesce and
# would assert against stale data (constraint: do not cache census reads
# across phases).
_scan_live_consumers() {
  local -a targets=("$@")
  [ "${#targets[@]}" -eq 0 ] && return 0
  local -A is_target=()
  local t
  for t in "${targets[@]}"; do is_target["$t"]=1; done

  local pod tag f2 f3 f4 f5
  local -A group_members=() group_state=() group_hosts=() group_topic=()
  for pod in "${REDPANDA_PODS[@]}"; do
    while IFS=$'\t' read -r tag f2 f3 f4 f5; do
      [ -z "$tag" ] && continue
      case "$tag" in
        MEMBERS)
          group_members["$pod|$f2"]="$f3"
          group_state["$pod|$f2"]="$f4"
          group_hosts["$pod|$f2"]="$f5"
          ;;
        TOPIC)
          # Comma-appended, not overwritten: a single group can hold offsets
          # on more than one target topic (e.g. several changelogs on the
          # same broker), and overwriting would silently drop every target
          # topic but the last one seen out of the LIVE CONSUMER report
          # below — a diagnostic completeness bug, not a safety one (ok is
          # still set false either way), but the report exists so an
          # operator can act on it, and an incomplete list is a worse
          # report than a slower one.
          if [ -n "${is_target[$pod|$f3]:-}" ]; then
            case ",${group_topic[$pod|$f2]:-}," in
              *",$f3,"*) ;;
              *) group_topic["$pod|$f2"]="${group_topic[$pod|$f2]:+${group_topic[$pod|$f2]},}$f3" ;;
            esac
          fi
          ;;
      esac
    done < <(census_groups "$pod")
  done

  build_declared_owner_map

  # Owners come from the declared/Restate lookup (SPEC-consumer-
  # declarations.md Part B item 6), not connection-source IP — a proxied
  # consumer's host IP never told you who it really was (fact 3); the
  # annotation does. The raw member host list is still shown (it is real,
  # measured data), just relabelled: it is where the connection came FROM,
  # not who owns it.
  local ok=true key members grp gtopic hostcsv owner podlist
  for key in "${!group_topic[@]}"; do
    members="${group_members[$key]:-0}"
    if [ "${members:-0}" -gt 0 ] 2>/dev/null; then
      ok=false
      pod="${key%%|*}"; grp="${key#*|}"
      gtopic="${group_topic[$key]}"
      hostcsv="${group_hosts[$key]:-}"

      owner="${DECLARED_OWNER[$key]:-}"
      [ -z "$owner" ] && owner="${RESTATE_OWNER_BY_GROUP[$grp]:-}"
      [ -z "$owner" ] && owner="UNDECLARED"

      podlist="none"
      if [ "$owner" != "UNDECLARED" ]; then
        podlist="$(_pods_of_workload "$owner" | tr '\n' ',')"
        podlist="${podlist%,}"
        [ -z "$podlist" ] && podlist="none"
      fi

      echo "LIVE CONSUMER: group=$grp topics=$gtopic broker=$pod members=$members" \
           "state=${group_state[$key]:-?}" >&2
      echo "    owners=$owner pods=$podlist" >&2
      echo "    member hosts (connection source; not used for ownership)=${hostcsv:-none}" >&2
    fi
  done

  $ok
}

# assert_consumers_declared "pod|topic" ... -> 0 if every consumer group
# holding a target topic is declared (chart annotation or Restate's own
# subscription list), 1 otherwise. THE pre-flight gate (SPEC-consumer-
# declarations.md Part B item 4) — run BEFORE any mutation, so refusing
# here costs a stopped run, never a wrongly-skipped quiesce: an undeclared
# LIVE consumer is exactly the egress-gate-c2 case (toxiproxy-masked,
# invisible to the old IP-based derive_quiesce_set/assert_no_live_
# consumers). A members=0 group is reported (ORPHAN OFFSETS) but does not
# fail — a dead group's leftover offsets are noise, not a coverage gap.
#
# Fresh census, same reasoning as _scan_live_consumers: must not reuse a
# read taken before some other phase changed the cluster.
assert_consumers_declared() {
  local -a targets=("$@")
  [ "${#targets[@]}" -eq 0 ] && return 0
  local -A is_target=()
  local t
  for t in "${targets[@]}"; do is_target["$t"]=1; done

  build_declared_owner_map

  local pod tag f2 f3 f4 f5
  local -A group_members=() group_topic=()
  for pod in "${REDPANDA_PODS[@]}"; do
    while IFS=$'\t' read -r tag f2 f3 f4 f5; do
      [ -z "$tag" ] && continue
      case "$tag" in
        MEMBERS) group_members["$pod|$f2"]="$f3" ;;
        TOPIC)
          if [ -n "${is_target[$pod|$f3]:-}" ]; then
            case ",${group_topic[$pod|$f2]:-}," in
              *",$f3,"*) ;;
              *) group_topic["$pod|$f2"]="${group_topic[$pod|$f2]:+${group_topic[$pod|$f2]},}$f3" ;;
            esac
          fi
          ;;
      esac
    done < <(census_groups "$pod")
  done

  local ok=true n=0 undeclared=0 key broker group topics members owner dup
  for key in "${!group_topic[@]}"; do
    n=$((n + 1))
    broker="${key%%|*}"; group="${key#*|}"
    topics="${group_topic[$key]}"
    members="${group_members[$key]:-0}"

    dup="${DECLARED_OWNER_DUPES[$key]:-}"
    if [ -n "$dup" ]; then
      ok=false
      undeclared=$((undeclared + 1))
      echo "DUPLICATE DECLARATION: group=$group broker=$broker topics=$topics" \
           "owners=$dup" >&2
      continue
    fi

    owner="${DECLARED_OWNER[$key]:-}"
    [ -z "$owner" ] && owner="${RESTATE_OWNER_BY_GROUP[$group]:-}"
    [ -n "$owner" ] && continue

    if [ "${members:-0}" -gt 0 ] 2>/dev/null; then
      ok=false
      undeclared=$((undeclared + 1))
      echo "UNDECLARED CONSUMER: group=$group broker=$broker topics=$topics members=$members" >&2
    else
      echo "ORPHAN OFFSETS (no members, not blocking): group=$group broker=$broker topics=$topics" >&2
    fi
  done

  if $ok; then
    echo "PRE-FLIGHT: PASS ($n groups on targets, $undeclared undeclared live)"
  else
    echo "PRE-FLIGHT: FAIL ($n groups on targets, $undeclared undeclared live)"
  fi

  $ok
}

# ---------------------------------------------------------------------------
# assert_no_live_consumers "pod|topic" ... — work item 4's gate, with the
# patience the first version lacked.
#
# MEASURED 2026-09-27, and this is the whole reason this wrapper exists: a
# consumer group does NOT drop its members when the pods go away. The
# red-check quiesced every one of the 23 derived workloads, quiesce_workload_
# set confirmed status.replicas=0 for all of them, and the census STILL
# reported 34 groups at members>0 — because Redpanda holds a member until its
# session times out. Timed on a fixture whose pods were deleted at t=0:
#
#     t=11s..44s  STATE=Stable  MEMBERS=6      (every pod already gone)
#     t=49s       STATE=Empty   MEMBERS=0
#
# ~45s, i.e. a stock session timeout. The tell that those were stale members
# rather than live consumers: their host IPs no longer resolved to any pod at
# all. A one-shot read therefore fails EVERY time, on a correctly quiesced
# cluster, and phase 4 would abort forever — a reset that never round-trips
# for a reason that has nothing to do with consumers.
#
# So: poll. Fail only if a group is STILL holding members after the timeout,
# which is a real missed consumer. Aborting late is cheap here (nothing has
# been mutated yet, so the trap restores and the lab is untouched); aborting
# wrongly is what costs a night.
#
# WALL-CLOCK, NOT SLEEP-SUM (SPEC-consumer-declarations.md Part C, measured
# defect 2026-09-30): the deadline used to be `waited += QUIESCE_EXPIRY_
# INTERVAL`, counting only the sleeps between scans, never the scan itself.
# A scan is 5 brokers x `rpk group describe` + owner lookups, measured at
# ~40s on the lab — so a "180s" budget of pure sleep-sum let the loop run
# past 14 real minutes before anyone noticed it hadn't actually stopped at
# 180s of wall-clock time. `$SECONDS` (bash's own elapsed-since-shell-start
# counter) captured once at entry and re-read every iteration counts the
# scan time too, so the budget means what it says.
QUIESCE_EXPIRY_TIMEOUT="${QUIESCE_EXPIRY_TIMEOUT:-180}"
QUIESCE_EXPIRY_INTERVAL="${QUIESCE_EXPIRY_INTERVAL:-5}"

assert_no_live_consumers() {
  [ "$#" -eq 0 ] && return 0

  # The diagnostics are worth printing only for the read that actually
  # decides, so each attempt's stderr is buffered and only the last one is
  # shown. Every attempt runs in THIS shell, so the declared-owner cache
  # (build_declared_owner_map) survives between attempts.
  local buf; buf="$(mktemp)"
  local start elapsed rc=0 announced=false
  start="$SECONDS"

  while :; do
    rc=0
    _scan_live_consumers "$@" 2>"$buf" || rc=$?
    elapsed=$((SECONDS - start))
    if [ "$rc" -eq 0 ]; then
      $announced && echo "ASSERTION: clear after ${elapsed}s (wall-clock) of waiting" \
        "for group members to expire." >&2
      rm -f "$buf"
      return 0
    fi
    if [ "$elapsed" -ge "$QUIESCE_EXPIRY_TIMEOUT" ]; then
      break
    fi
    if ! $announced; then
      announced=true
      echo "ASSERTION: groups still hold members; waiting up to" \
           "${QUIESCE_EXPIRY_TIMEOUT}s (wall-clock) for session timeouts to expire" \
           "(measured ~45s on this cluster)." >&2
    fi
    sleep "$QUIESCE_EXPIRY_INTERVAL"
  done

  elapsed=$((SECONDS - start))
  echo "ASSERTION: still holding members after ${elapsed}s (wall-clock) — these are" \
       "NOT stale members. Offenders, from the final census read:" >&2
  cat "$buf" >&2
  rm -f "$buf"
  return 1
}

# ---------------------------------------------------------------------------
# Stores — the table list and the one permanent exclusion.
#
# audit_log is carried in its OWN array, never in TABLES, and delete_table()
# below refuses it a second time at the point of use. It is the ADR-0029
# decision log. A reset that clears the record of who was allowed to see
# what is a cover-up, not a reset — the one table whose entire purpose is to
# outlive operator acts must outlive this one.
# ---------------------------------------------------------------------------
TABLES=(
  telemetry_latest_state
  asset_cm_state
  asset_logistics_status
  asset_capability_state
  asset_telemetry_windows
  asset_registry
  asset_element_telemetry
  region_fleet_summary
  region_top_factors
  region_wear_trends
  tactical_events
  edge_buffer_status
  inventory_items
  intake_records
  effector_launch
)
# effector_declared_load is deliberately NOT in TABLES. It is the declared
# munitions-per-launcher-variant config, not run data — the projector
# reloads it wholesale from EFFECTOR_DECLARED_LOAD_PATH at every startup
# (src/effector_declared_load.py), so clearing it here would only leave the
# table empty until the next pod restart re-populated it, while the
# effector_launch rows it's compared against (effector_launcher_counts) ARE
# reset above. Clearing config tables on a scenario reset is not what this
# script is for.
EXCLUDED_TABLES=(audit_log egress_delivered_events)  # ADR-0029 decision log
# (audit_log, PERMANENT, see header) plus the forwarder's own delivery
# dedup ledger (egress_delivered_events) -- a reset must not erase the
# record of what was already sent, or a re-delivery on the next run would
# look like a first delivery. delete_table() refuses both the same way.

# Declared heartbeats: deleted in phase 6 like every table above, but NOT
# predicted 0 in phase 8. edge_buffer_status is one row the projector upserts
# every EDGE_BUFFER_PROBE_INTERVAL_S (2s, openddil-projector
# src/edge_buffer_monitor.py) from a live link probe, not from any topic, so
# it is back within seconds of the DELETE whether or not producers are
# quiesced. Predicting 0 for it was wrong on all four instances. Predicted
# instead: no row older than the run boundary. That fails on a row nothing
# writes any more; it cannot tell a deleted-and-rewritten row from one that
# was never deleted, because the heartbeat refreshes both.
HEARTBEAT_TABLES=(edge_buffer_status)

is_heartbeat_table() {
  local t
  for t in "${HEARTBEAT_TABLES[@]}"; do [ "$t" = "$1" ] && return 0; done
  return 1
}

# pg_query POD SQL — every call reads $POSTGRES_USER / $POSTGRES_DB from the
# POD'S OWN ENVIRONMENT AT RUNTIME. Never hardcoded: hq's container runs
# POSTGRES_USER=postgres, the tier instances run POSTGRES_USER=openddil, and
# a script that assumed one would authenticate correctly against three
# instances and silently fail (or worse, silently no-op) against the fourth.
#
# `-- sh -c '...'`: required here for two independent reasons, not one — the
# command needs a shell to expand $POSTGRES_USER/$POSTGRES_DB at all, and
# separately, ANY kubectl exec that hands the container a shell pipeline or
# a container-absolute path must go through sh -c/bash -c on this toolchain.
# A bare argument that merely LOOKS like a POSIX path gets silently rewritten
# by MSYS when this runs under Git Bash on Windows, and the failure then
# surfaces as an unreachable service, not as a quoting bug — see
# check-advancing.sh's kind_drops() for the first time this bit someone.
pg_query() {
  local pod="$1" sql="$2"
  kubectl exec -n "$NS" "$pod" -c postgres -- sh -c \
    "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -tAc \"$sql\"" \
    2>/dev/null
}

pg_table_exists() {
  local pod="$1" table="$2" v
  v="$(pg_query "$pod" "SELECT to_regclass('public.${table}') IS NOT NULL")"
  [ "$v" = "t" ]
}

pg_count() {
  local pod="$1" table="$2"
  pg_query "$pod" "SELECT count(*) FROM ${table}"
}

delete_table() {
  local pod="$1" table="$2" excl
  for excl in "${EXCLUDED_TABLES[@]}"; do
    if [ "$table" = "$excl" ]; then
      echo "REFUSING to delete from $table — it is in EXCLUDED_TABLES (ADR-0029)." >&2
      halt_reset "refused to delete from $table on $pod: it is in EXCLUDED_TABLES (ADR-0029)" \
        "$table on $pod untouched; tables already deleted in phase 6 stay deleted"
    fi
  done
  maybe_run "DELETE FROM $table on $pod" \
    kubectl exec -n "$NS" "$pod" -c postgres -- sh -c \
    "psql -v ON_ERROR_STOP=1 -U \"\$POSTGRES_USER\" -d \"\$POSTGRES_DB\" -c \"DELETE FROM ${table};\""
}

# ---------------------------------------------------------------------------
# Restate result reading — machine format, not a parsed table.
#
# RESOLVED BY MEASUREMENT 2026-09-27 (see
# /c/tmp/rev51-run/ROWS-2026-09-26-reset-six-judgment-calls.md, call 1).
# An earlier revision hand-parsed the CLI's rendered table and handled both a
# box-drawing and a pipe-delimited shape. Both were guesses, and one was dead
# code: `restate sql --help` offers `--json` and `--jsonl`, and the default
# `--table-style` is `compact`, i.e. NO borders at all.
#
# So the parser is gone. `--json` emits one human line ("N rows. Query took
# ...") followed by a JSON array, and everything below reads the array.
#
# The cross-check the parser needed is gone with it, and that is the point:
# measured, it compared two numbers that are legitimately different —
#   select count(distinct service_key), count(*) from state -> 14, 84
# 14 Virtual Object keys, 6 state entries each. A guard comparing those would
# have aborted a CORRECT reset and blamed the parser. Where a count matters,
# this script now says which of the two it means.
# ---------------------------------------------------------------------------
restate_sql() {
  # Raw passthrough, kept for callers that only need an exit status.
  local pod="$1" sql="$2"
  kubectl exec -n "$NS" "$pod" -c restate -- restate sql --json "$sql" 2>/dev/null
}

restate_json() {
  # The JSON array only: drop the leading human-readable summary line.
  local pod="$1" sql="$2"
  restate_sql "$pod" "$sql" | sed -n '/^[[:space:]]*\[/,$p'
}

json_field() {
  # $1 = JSON array text, $2 = flat scalar field name -> one value per line.
  # Every field this script reads (service_name, service_key, id, n) is a flat
  # scalar, so this needs no JSON parser and pulls no nested object.
  #
  # `|| true` IS LOAD-BEARING, not defensive clutter. With `set -euo pipefail`
  # (line 70) a grep that matches nothing returns 1, pipefail promotes that to
  # the pipeline, the function returns 1, and every caller of the form
  # `x="$(json_field ... | head -1)"` kills the script from inside a command
  # substitution. "No rows matched" is a legitimate and expected answer here —
  # it is the answer after phase 3 clears the state, and on a cold cluster it is
  # the answer at baseline. Guarding once here fixes every call site.
  local raw="$1" field="$2"
  printf '%s' "$raw" \
    | { grep -oE "\"${field}\":(\"[^\"]*\"|-?[0-9]+(\.[0-9]+)?)" || true; } \
    | sed -E "s/^\"${field}\"://; s/^\"//; s/\"\$//"
}

restate_count() {
  # Single-aggregate query -> the one value of the named column. Reads the
  # field by NAME rather than by position or by "last number on the line":
  # the summary line carries digits of its own ("1 rows. Query took 2.39ms"),
  # so a positional read of the whole output is a trap.
  local pod="$1" sql="$2" col="${3:-n}"
  json_field "$(restate_json "$pod" "$sql")" "$col" | tail -1
}

# Set during phase 1 from a LIVE scheduled invocation, because by verify time
# there are deliberately none left to measure.
MEASURED_CADENCE_S=""

measure_restate_cadence() {
  # Emits a whole number of seconds on stdout. Prefers the value measured at
  # baseline; measures fresh if that is missing; falls back to the env default
  # only when there is no scheduled invocation anywhere to read.
  if [ -n "$MEASURED_CADENCE_S" ]; then
    printf '%s' "$MEASURED_CADENCE_S"
    return
  fi
  local pod raw a b da db delta
  for pod in "${RESTATE_PODS[@]}"; do
    raw="$(restate_json "$pod" \
      "select scheduled_at, scheduled_start_at from sys_invocation where status = 'scheduled' limit 1")"
    a="$(json_field "$raw" "scheduled_at" | head -1)"
    b="$(json_field "$raw" "scheduled_start_at" | head -1)"
    [ -z "$a" ] || [ -z "$b" ] && continue
    da="$(date -d "$a" +%s 2>/dev/null || true)"
    db="$(date -d "$b" +%s 2>/dev/null || true)"
    if [ -n "$da" ] && [ -n "$db" ]; then
      delta=$((db - da))
      # Sanity-bound it. A negative or absurd delta means the read is wrong,
      # and a wrong cadence silently weakens the re-arm check rather than
      # failing it, so an out-of-range value is discarded rather than used.
      if [ "$delta" -gt 0 ] && [ "$delta" -le 600 ]; then
        MEASURED_CADENCE_S="$delta"
        printf '%s' "$delta"
        return
      fi
    fi
  done
  printf '%s' "$RESTATE_CADENCE_SECONDS"
}

# ---------------------------------------------------------------------------
# Electric shape reads (ROWS doc, call 4). All three unknowns that made an
# earlier revision substitute a weaker check are now measured:
#   port    read per pod from its own container spec — 5133 on the hub,
#           3000 on each tier. A hardcoded port reads 1 instance in 4.
#   client  only `curl` is present (`wget` is not installed).
#   shape   /v1/shape?table=<t>&offset=-1 answers 200 with an
#           `electric-handle` response header and a JSON array body.
# ---------------------------------------------------------------------------
ELECTRIC_SHAPE_TABLE="${ELECTRIC_SHAPE_TABLE:-telemetry_latest_state}"

electric_port() {
  # Never assumed. Empty output means "do not guess" — the caller reports
  # UNMEASURED rather than inventing 3000.
  kubectl get pod -n "$NS" "$1" \
    -o jsonpath='{.spec.containers[0].ports[0].containerPort}' 2>/dev/null || true
}

electric_shape() {
  # Headers on stderr, body on stdout, so one call can serve both readers
  # without parsing a merged stream.
  local pod="$1" port="$2"
  [ -z "$port" ] && return 0
  kubectl exec -n "$NS" "$pod" -- sh -c \
    "curl -s -m 15 -D /dev/stderr 'http://127.0.0.1:${port}/v1/shape?table=${ELECTRIC_SHAPE_TABLE}&offset=-1'" \
    2>&1 || true
}

electric_shape_handle() {
  # The handle identifies the shape LOG. A different handle after the pod is
  # deleted is the actual evidence that the log was discarded and rebuilt;
  # an unchanged handle means it survived, which is the failure to catch.
  electric_shape "$1" "$2" \
    | { grep -i '^electric-handle:' || true; } | head -1 | sed -E 's/^[^:]+:[[:space:]]*//; s/[[:space:]]*$//'
}

# The pod name is not an identity: phase 7 deletes the pod, and its
# replacement has a new name. The baseline is keyed by the name with the
# ReplicaSet and pod hashes stripped, and verify looks it up the same way.
# Keyed by pod name, the lookup after phase 7 always read empty, so the
# UNCHANGED branch could never fire.
electric_instance() {
  printf '%s' "$1" | sed -E 's/-[a-z0-9]+-[a-z0-9]+$//'
}

electric_shape_rows() {
  # What a client that syncs the shape now would hold: the whole log replayed
  # to Electric's up-to-date marker, inserts minus deletes. NOT the first
  # chunk of offset=-1. That chunk is the snapshot taken when the shape was
  # created, and every change since lives in later chunks, so on a populated
  # lab it read 0 on all four instances and the rows line could never fail.
  #
  # The replay runs inside the pod: the log is ~10 MB per chunk, and only the
  # two counts cross kubectl exec. Counting `"operation":"insert"` by grep is
  # exact because a JSON string cannot hold an unescaped quote. Updates do not
  # change the row count. Empty output means UNMEASURED (a non-200, a lost
  # handle, or more than 2000 chunks), never 0.
  local pod="$1" port="$2"
  [ -z "$port" ] && return 0
  kubectl exec -i -n "$NS" "$pod" -- sh -s "$port" "$ELECTRIC_SHAPE_TABLE" 2>/dev/null <<'REPLAY' || true
u="http://127.0.0.1:$1/v1/shape?table=$2"; off=-1; h=""; ins=0; del=0; n=0
b=/tmp/shape-rows.$$.b; hd=/tmp/shape-rows.$$.h
while :; do
  n=$((n + 1)); [ "$n" -gt 2000 ] && break
  q="$u&offset=$off"; [ -n "$h" ] && q="$q&handle=$h"
  code=$(curl -s -m 60 -o "$b" -D "$hd" -w '%{http_code}' "$q")
  [ "$code" = 200 ] || break
  ins=$((ins + $(grep -o '"operation":"insert"' "$b" | wc -l)))
  del=$((del + $(grep -o '"operation":"delete"' "$b" | wc -l)))
  if grep -qi '^electric-up-to-date' "$hd" || grep -q '"control":"up-to-date"' "$b"; then
    echo $((ins - del)); break
  fi
  h=$(sed -n 's/^electric-handle: *//Ip' "$hd" | tr -d '\r')
  off=$(sed -n 's/^electric-offset: *//Ip' "$hd" | tr -d '\r')
  { [ -n "$h" ] && [ -n "$off" ]; } || break
done
rm -f "$b" "$hd"
REPLAY
}

# ---------------------------------------------------------------------------
# Redpanda: read a topic's per-partition (partition, log-start, high-water)
# rows. Column layout ($1 partition, $(NF-1) log-start, $NF high-watermark)
# matches how check-derive-stage.sh's hw() and check-advancing.sh's hw()
# both key off a numeric partition id in $1 / trailing numeric column — this
# reuses that same measured layout rather than asserting a fixed column
# count, since REPLICAS can render as a single bracketed token that shifts
# absolute column numbers.
# ---------------------------------------------------------------------------
topic_partitions() {
  local pod="$1" topic="$2"
  kubectl exec -n "$NS" "$pod" -c redpanda -- rpk topic describe "$topic" -p 2>/dev/null \
    | awk 'NR > 1 && $1 ~ /^[0-9]+$/ { print $1, $(NF - 1), $NF }' || true
}

broker_topics() {
  local pod="$1"
  kubectl exec -n "$NS" "$pod" -c redpanda -- rpk topic list 2>/dev/null \
    | awk 'NR > 1 { print $1 }' || true
}

is_internal_topic() {
  case "$1" in
    _*) return 0 ;;   # covers both `_`- and `__`-prefixed internal topics
    # FOUND BY THE BASELINE, not by review. The `_*` test above only catches
    # topics whose name STARTS with an underscore, and Faust's control topics
    # do not — they are `<app-id>-__assignor-__leader`, e.g.
    # `openddil-edge-01-__assignor-__leader`, so all 11 of them on the lab were
    # in the trim set. Trimming a leader-election log is a control-plane
    # mutation that the PREDICTION doc predicts nothing about and that this
    # script has no business making: it is not scenario data, and its residue
    # is not what "the fleet is empty" means.
    #
    # The `-changelog` topics are deliberately NOT excluded here — those ARE
    # scenario state (Faust table backing logs) and the PREDICTION doc requires
    # them trimmed before the Faust restart. The two are cleanly separable:
    # every assignor/leader topic contains `__`, and no changelog topic does.
    *-__assignor-__leader) return 0 ;;
    *__*) return 0 ;;   # any other Faust/Kafka control topic of that family
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# JUDGMENT CALL 10 — topic config capture, read-only. `rpk topic trim-prefix`
# was proven (2026-09-27, scratch topics) to return POLICY_VIOLATION when a
# topic's cleanup.policy is pure `compact`; it only succeeds when the policy
# is `compact,delete`. 53 topics on the lab (13 each on hq/edge-01/edge-02/
# edge-03, 1 on region-east — all state topics or Faust changelogs) are pure
# `compact`, so phase 4 has to alter their cleanup.policy to `compact,delete`
# before it can trim them at all — and a restore back to the captured value
# afterward needs that same live config read back BEFORE the alter, or there
# is nothing to restore it to.
#
# These three are READS. They do not go through maybe_run and they run
# under --dry-run too — a dry-run that cannot show the real captured config
# for a policy-trimmed topic is worthless for exactly the topics that
# need the most scrutiny.
# ---------------------------------------------------------------------------
topic_dynamic_config() {
  # Sorted `key=value` lines, DYNAMIC_TOPIC_CONFIG rows only. DEFAULT_CONFIG
  # rows are excluded on purpose: a default is a default whoever creates the
  # topic, so capturing them would just be restating broker defaults as if
  # they were part of this topic's identity.
  #
  # This reasoning used to be stated as "they come back on their own the
  # moment a topic is recreated (auto_create_topics_enabled, measured fact
  # 3)". As of chart 0.1.61 auto-create is OFF on every broker, so nothing
  # comes back on its own any more -- but the exclusion is still right, for
  # the reason above rather than that one.
  local pod="$1" topic="$2"
  kubectl exec -n "$NS" "$pod" -c redpanda -- rpk topic describe "$topic" -c 2>/dev/null \
    | awk '$3=="DYNAMIC_TOPIC_CONFIG"{printf "%s=%s\n",$1,$2}' | sort || true
}

topic_shape() {
  # Single line: "<partitions> <replicas>". Parsed by KEY NAME out of the
  # SUMMARY block, same reasoning as topic_partitions() above: REPLICAS can
  # render as a bracketed token that shifts absolute column numbers, so this
  # reads by name and never by position.
  local pod="$1" topic="$2"
  kubectl exec -n "$NS" "$pod" -c redpanda -- rpk topic describe "$topic" 2>/dev/null \
    | awk '$1=="PARTITIONS"{p=$2} $1=="REPLICAS"{r=$2} END{print p, r}' || true
}

topic_policy() {
  # The cleanup.policy value alone, or empty if the row cannot be read. This
  # is the ONLY thing phase 4 uses to decide trim vs delete-and-recreate, so
  # an empty result is handled by the caller as "unknown" — never defaulted
  # into either bucket.
  local pod="$1" topic="$2"
  kubectl exec -n "$NS" "$pod" -c redpanda -- rpk topic describe "$topic" -c 2>/dev/null \
    | awk '$1=="cleanup.policy"{print $2}' || true
}

# ---------------------------------------------------------------------------
# Capture store. A pod|topic -> multi-line-config assoc array was rejected:
# bash has no native nested value, so a multi-line config would have to be
# flattened into one string and re-split, and it would give an operator
# nothing to inspect afterwards. A file does both jobs for free — it is the
# artifact someone can `diff` by hand if this phase ever disagrees with them
# about what "matches" means.
#
# Not deleted at the end. It is evidence for exactly the case this phase is
# built to catch: a topic that came back different from what was there
# before its delete.
# ---------------------------------------------------------------------------
TOPIC_CAPTURE_DIR="${TMPDIR:-/tmp}/reset-scenario-capture-$$"

# assert_topic_matches_capture POD TOPIC -> 0 equal, 1 differs.
#
# Re-reads shape + dynamic config LIVE, in the same two-part form the
# capture file was written in, and diffs the two. Deliberately compares the
# WHOLE dynamic set and the shape, not just the one key the policy-trim
# restore's `--set` passed — comparing only what was just written would
# make this an assertion that the alter-config command's own argument was
# echoed back, which proves nothing. Comparing everything is what lets it
# also catch any other drift between the pre-mutation capture and what the
# broker actually holds afterward, cleanup.policy included.
#
# Under --dry-run nothing was mutated, so this reads the topic's own,
# still-live, unmutated config against a capture taken from that same
# config moments earlier — it trivially passes. That is not special-cased
# below; it falls out of calling this function unconditionally.
assert_topic_matches_capture() {
  local pod="$1" topic="$2"
  local capfile="$TOPIC_CAPTURE_DIR/$pod/$topic.cap"
  local live
  live="$(mktemp)"
  { printf 'shape %s\n' "$(topic_shape "$pod" "$topic")"; topic_dynamic_config "$pod" "$topic"; } > "$live"
  if diff -u "$capfile" "$live" > /dev/null 2>&1; then
    rm -f "$live"
    return 0
  fi
  echo "CAPTURE MISMATCH: $topic on $pod does not match its pre-mutation capture" >&2
  diff -u "$capfile" "$live" >&2 || true
  rm -f "$live"
  return 1
}

# ===========================================================================
# PHASE 1 — BASELINE. Recorded and printed before anything is touched.
# A reset with no before-reading cannot be shown to have done anything: the
# claim this script exists to support ("run, reset, re-run: same baseline
# counts") is only checkable if there IS a first-run baseline on record.
# ===========================================================================
declare -A BASE_STORE_COUNT   # key "pod|table" -> count
declare -A BASE_AUDIT_COUNT   # key "pod" -> audit_log count (never deleted, re-checked unchanged in phase 8)
declare -A BASE_RESTATE_KEYS  # key "pod" -> DISTINCT Virtual Object keys (14 on the lab)
declare -A BASE_RESTATE_ROWS  # key "pod" -> state ROWS. NOT derivable from keys: measured 84/14 on hq but 59/8, 43/6, 98/14 on the tiers, so entries-per-key is ragged and both numbers are asserted separately.
declare -A BASE_RESTATE_SCHED # key "pod" -> scheduled invocation count
declare -A BASE_ELECTRIC_HANDLE # key electric_instance(pod) -> shape handle before the reset (must CHANGE after)
declare -A BASE_ELECTRIC_ROWS   # key electric_instance(pod) -> shape row count before the reset
declare -A BASE_TOPIC_HW      # key "pod|topic|partition" -> high watermark
declare -A ORIG_REPLICAS      # key deployment name -> replica count before quiesce (producers only, phase 2)

# Per-kind captured state for the DERIVED quiesce set (work item 3) —
# separate from ORIG_REPLICAS above, which stays exactly as phase 2 always
# used it (producers, keyed by bare deployment name). These are keyed by
# the full "Kind/Name" the derived set already uses, because the derived
# set can hold any of the four kinds in the work-item-3 table, not just
# Deployments.
declare -A QSTATE_REPLICAS     # key "Deployment|StatefulSet|ReplicaSet/name" -> replica count before quiesce
declare -A QSTATE_NODESEL      # key "DaemonSet/name" -> captured nodeSelector, as JSON (via -o jsonpath-as-json; plain jsonpath prints Go map syntax, not JSON)
declare -A QSTATE_NODESEL_HAD  # key "DaemonSet/name" -> set (to 1) iff nodeSelector existed pre-quiesce; its ABSENCE is what tells restore to remove the key rather than replace it with the captured value
declare -A QSTATE_SUSPEND      # key "Job/name" -> captured .spec.suspend before quiesce
declare -a QSTATE_QUIESCED=()  # ordered list of "Kind/Name" this run actually attempted to quiesce — restore and the EXIT trap walk THIS, not the derived set, for the same reason restore_state_consumers used to: an entry the quiesce loop never reached must not be "restored" from an empty capture

# CENSUS_QUIESCED — the writer-census's OWN subset of "Kind/Name" entries
# (phase 3b, below), kept separate from QSTATE_QUIESCED rather than
# re-deriving it later, because phase 5/9 need to ask "did the CENSUS
# quiesce this one" specifically (a Faust entry here gets scaled back
# fresh to reload the just-trimmed changelogs instead of a rollout
# restart — see phase5_aggregator). Every entry added here is ALSO added
# to QSTATE_QUIESCED by the same quiesce_workload_set/quiesce_derived_
# workload call that adds it here, so arm_scale_trap/emergency_restore_
# scales already cover it with NO second trap and NO second replica map:
# the capture lives in QSTATE_REPLICAS, same as every other derived-set
# entry.
declare -a CENSUS_QUIESCED=()

baseline_electric() {
  echo "--- electric (shape handle + rows, per instance) ---"
  local pod inst eport ehandle erows
  for pod in "${ELECTRIC_PODS[@]}"; do
    inst="$(electric_instance "$pod")"
    eport="$(electric_port "$pod")"
    if [ -z "$eport" ]; then
      printf '  %-52s port=UNMEASURED (no containerPort in spec — not guessed)\n' "$pod"
      continue
    fi
    ehandle="$(electric_shape_handle "$pod" "$eport")"
    erows="$(electric_shape_rows "$pod" "$eport")"
    if [ -n "${BASE_ELECTRIC_HANDLE[$inst]+x}" ]; then
      echo "  WARNING: two electric pods reduce to instance '$inst'; the second overwrites the first baseline" >&2
    fi
    BASE_ELECTRIC_HANDLE["$inst"]="$ehandle"
    BASE_ELECTRIC_ROWS["$inst"]="${erows:-UNMEASURED}"
    printf '  %-52s port=%-5s rows=%-4s handle=%s\n' \
      "$inst" "$eport" "${erows:-UNMEASURED}" "${ehandle:-UNMEASURED}"
  done
}

phase1_baseline() {
  echo
  echo "=== PHASE 1: baseline (read-only) ==="

  # Re-stamp the freshness boundary from the DATABASE clock (see the comment at
  # RUN_STARTED_AT). Taken from the first discovered Postgres pod, before any
  # mutation, so every later "is this row newer than the run?" question is asked
  # in the same time base as the rows it is asking about.
  if [ "${#POSTGRES_PODS[@]}" -gt 0 ]; then
    local dbnow
    dbnow="$(pg_query "${POSTGRES_PODS[0]}" "SELECT now()" || true)"
    if [ -n "$dbnow" ]; then
      RUN_STARTED_AT="$dbnow"
      RUN_STARTED_AT_SOURCE="database clock on ${POSTGRES_PODS[0]}"
    fi
  fi
  echo "  run boundary: $RUN_STARTED_AT  [$RUN_STARTED_AT_SOURCE]"

  echo "--- stores ---"
  local pod table cnt
  for pod in "${POSTGRES_PODS[@]}"; do
    for table in "${TABLES[@]}"; do
      if pg_table_exists "$pod" "$table"; then
        cnt="$(pg_count "$pod" "$table")"
        BASE_STORE_COUNT["$pod|$table"]="$cnt"
        printf '  %-28s %-28s %s\n' "$pod" "$table" "$cnt"
      else
        printf '  %-28s %-28s (table not present, skipped)\n' "$pod" "$table"
      fi
    done
    if pg_table_exists "$pod" "audit_log"; then
      cnt="$(pg_count "$pod" "audit_log")"
      BASE_AUDIT_COUNT["$pod"]="$cnt"
      printf '  %-28s %-28s %s   (EXCLUDED — recorded only to confirm UNCHANGED in phase 8)\n' \
        "$pod" "audit_log" "$cnt"
    fi
  done

  echo "--- restate ---"
  # TWO numbers, deliberately. Measured 2026-09-27: 14 Virtual Object keys hold
  # 84 state rows (6 entries each), so "how much state is there" has two correct
  # answers and a predicted zero that names neither is unverifiable. Both are
  # recorded and both are asserted in phase 8.
  local keys rows sched
  for pod in "${RESTATE_PODS[@]}"; do
    keys="$(restate_count "$pod" "select count(distinct service_key) as n from state")"
    rows="$(restate_count "$pod" "select count(*) as n from state")"
    sched="$(restate_count "$pod" "select count(*) as n from sys_invocation where status = 'scheduled'")"
    BASE_RESTATE_KEYS["$pod"]="${keys:-0}"
    BASE_RESTATE_ROWS["$pod"]="${rows:-0}"
    BASE_RESTATE_SCHED["$pod"]="${sched:-0}"
    printf '  %-28s object-keys=%-5s state-rows=%-6s scheduled-invocations=%s\n' \
      "$pod" "${keys:-0}" "${rows:-0}" "${sched:-0}"
  done
  # Measure the re-arm cadence NOW, while scheduled invocations still exist.
  # After phase 3 there are none by design, so this is the only window in the
  # run where the number can be read rather than assumed.
  printf '  re-arm cadence (measured from scheduled_at -> scheduled_start_at): %ss\n' \
    "$(measure_restate_cadence)"

  baseline_electric

  echo "--- topics (per broker, per partition) ---"
  local topic line part logstart hw
  for pod in "${REDPANDA_PODS[@]}"; do
    while read -r topic; do
      [ -z "$topic" ] && continue
      is_internal_topic "$topic" && continue
      while read -r part logstart hw; do
        [ -z "$part" ] && continue
        BASE_TOPIC_HW["$pod|$topic|$part"]="$hw"
        printf '  %-28s %-30s p%-3s log_start=%-8s hw=%s\n' "$pod" "$topic" "$part" "$logstart" "$hw"
      done < <(topic_partitions "$pod" "$topic")
    done < <(broker_topics "$pod")
  done

  echo "--- producers (current replica counts) ---"
  local d rc
  for d in "${PRODUCER_DEPLOYS[@]}"; do
    rc="$(kubectl get deploy -n "$NS" "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    printf '  %-40s replicas=%s\n' "$d" "${rc:-?}"
  done

  echo "=== end baseline ==="
}

# ===========================================================================
# PHASE 2 — QUIESCE PRODUCERS. First mutation, before any state is cleared:
# resetting into a live feed re-fills what the rest of this script is about
# to empty, so nothing downstream can be trusted until producers are down.
# Original replica counts are captured HERE, not assumed to be 1, because
# phase 9 restores exactly what was recorded here.
# ===========================================================================
phase2_quiesce() {
  echo
  echo "=== PHASE 2: quiesce producers ==="
  if $SKIP_PRODUCERS; then
    skip_warning "PRODUCERS" \
      "Producers stay at their current replica count. Any store, topic, or\n    Restate state cleared below will start refilling immediately from the\n    live feed — the rest of this reset's readings will not hold still."
    return 0
  fi
  # Armed BEFORE the first scale, not after: a failure reading the very first
  # replica count must already be covered. See emergency_restore_scales.
  arm_scale_trap
  # No IP->pod map to build any more (SPEC-consumer-declarations.md): ownership
  # comes from the chart's own annotation, not the scaled-down pod's own IP,
  # so there is nothing here that a scale-to-zero could make unresolvable.
  local d rc
  for d in "${PRODUCER_DEPLOYS[@]}"; do
    rc="$(kubectl get deploy -n "$NS" "$d" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
    ORIG_REPLICAS["$d"]="${rc:-1}"
    if [ -z "$rc" ]; then
      echo "WARNING: could not read current replica count for $d; recorded 1 as a" >&2
      echo "         last resort. If that is wrong, phase 9 will restore it wrong." >&2
    fi
    maybe_run "scale $d to 0 (was ${ORIG_REPLICAS[$d]})" \
      kubectl scale deploy -n "$NS" "$d" --replicas=0
  done
}

# restate_residue POD -> "keys rows scheduled open", one line. Any value that
# cannot be read prints as "?", and "?" is never zero: an unreadable read
# that defaulted to 0 would let a pod the script cannot see pass as cleared.
restate_residue() {
  local pod="$1" k r s o v out=""
  k="$(restate_count "$pod" "select count(distinct service_key) as n from state")"
  r="$(restate_count "$pod" "select count(*) as n from state")"
  s="$(restate_count "$pod" "select count(*) as n from sys_invocation where status = 'scheduled'")"
  o="$(restate_count "$pod" "select count(*) as n from sys_invocation where status <> 'completed'")"
  for v in "$k" "$r" "$s" "$o"; do
    [[ "$v" =~ ^[0-9]+$ ]] || v="?"
    out="$out $v"
  done
  printf '%s\n' "${out# }"
}

# One cancel-then-clear pass over one pod. Every id read is cancelled, and
# every service read is cleared, even when a cross-check count disagrees with
# the list: the list is a snapshot of objects that re-arm themselves, and the
# re-read in phase3_restate, not this pass, decides whether the pod is clear.
restate_clear_pass() {
  local pod="$1" raw ids id svc_raw services svc
  # 1. Open invocations (the scheduled timers, plus any running or backing
  #    off that would re-arm), cancelled BEFORE any clear.
  raw="$(restate_json "$pod" "select id from sys_invocation where status <> 'completed'")"
  mapfile -t ids < <(json_field "$raw" "id")
  for id in "${ids[@]}"; do
    echo "-> cancel invocation $id on $pod"
    # Same -y / timeout reasoning as the state clear below: no tty here.
    if ! kubectl exec -n "$NS" "$pod" -c restate -- \
           timeout "${RESTATE_CMD_TIMEOUT:-60}" restate -y invocations cancel "$id"; then
      # Admin-API fallback, the exact syntax measured working in
      # FINDING-2026-09-26-no-asset-eviction.md. An id that completed between
      # the read and the cancel (a timer that fired and re-armed under a new
      # id) fails both: harmless, because the re-read sees the new id.
      echo "   CLI cancel failed for $id on $pod — falling back to admin API" >&2
      kubectl exec -n "$NS" "$pod" -c restate -- sh -c \
        "curl -s -X DELETE 'http://localhost:9070/invocations/$id?mode=cancel'" || true
    fi
  done

  # 2. Services with any state, cleared only after their timers are cancelled.
  svc_raw="$(restate_json "$pod" "select service_name, count(distinct service_key) as n from state group by service_name")"
  mapfile -t services < <(json_field "$svc_raw" "service_name")
  for svc in "${services[@]}"; do
    echo "-> clear state for service $svc on $pod"
    # -y RESOLVED BY MEASUREMENT (ROWS doc, call 5). `restate --help` carries a
    # global "-y, --yes: Auto answer yes to confirmation prompts. Default to
    # false, unless running on ci". kubectl exec here has no tty, so WITHOUT -y
    # a confirmation prompt makes this hang forever rather than fail. The
    # timeout is the belt to that braces.
    if ! kubectl exec -n "$NS" "$pod" -c restate -- \
           timeout "${RESTATE_CMD_TIMEOUT:-60}" restate -y state clear "$svc"; then
      # -f/--force is documented for a version mismatch between CLI and
      # server. Not a first attempt on purpose: it is an escape hatch for
      # exactly one failure mode (PREDICTION doc §3.3).
      echo "   plain clear failed for $svc on $pod — retrying with -f/--force" >&2
      kubectl exec -n "$NS" "$pod" -c restate -- \
        timeout "${RESTATE_CMD_TIMEOUT:-60}" restate -y state clear "$svc" -f || true
    fi
  done
}

# ===========================================================================
# PHASE 3 — RESTATE. Per instance: cancel open invocations FIRST, THEN clear
# state per service, THEN re-read; repeat until two reads, RESTATE_ZERO_GAP_S
# apart, both read zero on all four counts (object keys, state rows,
# scheduled, open). Bounded at RESTATE_CLEAR_MAX_PASSES; a pod that is not
# clear by then HALTS the whole reset (halt_reset), naming the residue.
#
# Cancel-before-clear is LOAD-BEARING: the measured baseline is one
# self-re-arming timer per asset (asset_logistics.py:477). Clear state
# before cancelling and the very next tick fires against empty state and
# reschedules itself (FINDING-2026-09-26-no-asset-eviction.md).
#
# WHY A LOOP, NOT A ONE-SHOT CROSS-CHECK. The id list and its count(*) are
# two reads of a set that changes under them: a timer that fires between
# them re-arms under a new id. On 2026-10-01 that made the lab read 7 ids
# against a count of 8 on one instance; the old guard refused, then
# `continue`d, and the surviving objects refilled every store the later
# phases emptied. Refusing was right and continuing was wrong. The loop
# replaces both: whatever a pass misses, the re-read sees, and only a
# measured zero, read twice, lets the reset move on.
#
# Service names are DISCOVERED from the state table's own group-by, never
# hardcoded, so a new Virtual Object service needs no change here.
# ===========================================================================
RESTATE_CLEAR_MAX_PASSES="${RESTATE_CLEAR_MAX_PASSES:-5}"
RESTATE_ZERO_GAP_S="${RESTATE_ZERO_GAP_S:-5}"

phase3_restate() {
  echo
  echo "=== PHASE 3: restate (cancel, clear, re-read until two reads agree at zero) ==="
  if $SKIP_RESTATE; then
    skip_warning "RESTATE" \
      "Scheduled invocations are not cancelled and Virtual Object state is not\n    cleared. The self-re-arming timer (asset_logistics.py:477) keeps firing;\n    every store this script empties below will be repopulated by Restate's\n    own next tick, on its own schedule, regardless of the producers' state."
    return 0
  fi

  local pod pass r1 r2 i cleared=() not_reached
  for i in "${!RESTATE_PODS[@]}"; do
    pod="${RESTATE_PODS[$i]}"
    not_reached="${RESTATE_PODS[*]:$((i + 1))}"
    echo "-- $pod --"
    if $DRY_RUN; then
      echo "   residue now (keys rows scheduled open): $(restate_residue "$pod")"
      maybe_run "cancel every open invocation, clear every service, re-read until two zero reads ${RESTATE_ZERO_GAP_S}s apart (max ${RESTATE_CLEAR_MAX_PASSES} passes) on $pod" true
      continue
    fi
    pass=0
    while :; do
      pass=$((pass + 1))
      if [ "$pass" -gt "$RESTATE_CLEAR_MAX_PASSES" ]; then
        halt_reset "Restate on $pod is not clear after ${RESTATE_CLEAR_MAX_PASSES} cancel-clear-reread passes" \
          "$pod residue (keys rows scheduled open): ${r2:-$r1}" \
          "Restate instances cleared to a double zero read: ${cleared[*]:-none}" \
          "Restate instances not reached: ${not_reached:-none}"
      fi
      echo "   pass $pass"
      restate_clear_pass "$pod"
      r1="$(restate_residue "$pod")"; r2=""
      echo "   read 1 (keys rows scheduled open): $r1"
      [ "$r1" = "0 0 0 0" ] || continue
      sleep "$RESTATE_ZERO_GAP_S"
      r2="$(restate_residue "$pod")"
      echo "   read 2 after ${RESTATE_ZERO_GAP_S}s (keys rows scheduled open): $r2"
      [ "$r2" = "0 0 0 0" ] && break
    done
    echo "   $pod: clear after $pass pass(es), two zero reads"
    cleared+=("$pod")
  done
}

# ===========================================================================
# PHASE 3b — WRITER CENSUS.
#
# WHY. A reset once halted mid-phase-4: a region's own 30s Faust
# aggregator heartbeat and the region->hq uplink forwarding that region's
# aggregator output were both still writing when phase 4 trimmed hq before
# the region, and neither writer was ever quiesced because nothing had
# ever asked "who is still writing, right now" — only "who is still
# consuming" (the pre-flight above). This phase asks the writer question,
# with the same discipline the consumer side already has: a declared
# writer may be quiesced and restored by name; an UNDECLARED one that is
# caught actually writing is a halt, not a guess.
#
# "local" vs "bridged": a sampled new record carries a `kafka_topic`
# header iff it arrived over a bridge/uplink (the forwarder stamps it);
# otherwise it was written locally, on this broker, by something this
# chart should have declared in openddil.io/produces-topics.
# ===========================================================================
WRITER_CENSUS_SAMPLE="${WRITER_CENSUS_SAMPLE:-200}"
WRITER_SETTLE_TRIES="${WRITER_SETTLE_TRIES:-3}"

# writer_census_read POD -- "TOPIC PARTITION LOGSTART HW" per line, for
# every non-internal topic on POD. ONE kubectl exec per broker (not one
# per topic): broker_topics()/is_internal_topic() give the topic list
# (already its own single read), then a single shell script run inside
# the pod loops over those topics, calling `rpk topic describe <t> -p`
# once per topic — `rpk topic describe` ignores `-p` when given more than
# one topic name, so the per-topic call cannot be collapsed further, but
# the kubectl round trip can: that is what makes two full before/after
# passes of a live broker (writer_census, below) affordable within one
# census window.
writer_census_read() {
  local pod="$1" topic script=""
  while read -r topic; do
    [ -z "$topic" ] && continue
    is_internal_topic "$topic" && continue
    script+="printf 'TOPIC\t%s\n' '$topic'; rpk topic describe '$topic' -p 2>/dev/null; "
  done < <(broker_topics "$pod")
  [ -z "$script" ] && return 0
  kubectl exec -n "$NS" "$pod" -c redpanda -- sh -c "$script" 2>/dev/null | awk '
    $1 == "TOPIC" { topic = $2; next }
    $1 ~ /^[0-9]+$/ { print topic, $1, $(NF - 1), $NF }
  '
}

# writer_census WINDOW -- two writer_census_read() passes, WINDOW seconds
# apart, across every REDPANDA_PODS broker; for every partition whose hw
# advanced, samples up to WRITER_CENSUS_SAMPLE of the new records (one
# `rpk topic consume` per advanced partition, reading both the record key
# and its header keys in the SAME call: `-f '%k\t%h{%k;}\n'` — a record
# is bridged iff its header-key list contains `kafka_topic`, local
# otherwise). Fills these globals, one (broker,topic) entry per line of
# output; a value is the literal string "?" when either round's read
# failed or disagreed (a shrinking hw is not a valid read) — "?" is never
# treated as, or printed as, zero.
#   WC_TOPICS             ordered "pod|topic" keys this call saw
#   WC_ADVANCED[pt]        total new records (sum over partitions), or "?"
#   WC_LOCAL[pt]           sampled local-write count, or "?"
#   WC_BRIDGED[pt]         sampled bridged-write count, or "?"
#   WC_KEYS[pt]            up to 3 sample record keys of a local write
declare -A WC_ADVANCED=() WC_LOCAL=() WC_BRIDGED=() WC_KEYS=()
WC_TOPICS=()

writer_census() {
  local window="$1" pod topic part ls hw key
  local -A b_ls=() b_hw=() a_ls=() a_hw=() seen=()
  WC_ADVANCED=(); WC_LOCAL=(); WC_BRIDGED=(); WC_KEYS=(); WC_TOPICS=()

  for pod in "${REDPANDA_PODS[@]}"; do
    while read -r topic part ls hw; do
      [ -z "$topic" ] && continue
      key="$pod|$topic|$part"
      b_ls["$key"]="$ls"; b_hw["$key"]="$hw"
      seen["$pod|$topic"]=1
    done < <(writer_census_read "$pod")
  done

  echo "writer census: sleeping ${window}s between reads (>= 2x the 30s aggregator heartbeat expected)"
  sleep "$window"

  for pod in "${REDPANDA_PODS[@]}"; do
    while read -r topic part ls hw; do
      [ -z "$topic" ] && continue
      key="$pod|$topic|$part"
      a_ls["$key"]="$ls"; a_hw["$key"]="$hw"
      seen["$pod|$topic"]=1
    done < <(writer_census_read "$pod")
  done

  mapfile -t WC_TOPICS < <(printf '%s\n' "${!seen[@]}" | sort)

  local pt part_hw_b part_hw_a part_ls_b delta advanced total_local total_bridged
  local -a sample_keys
  local -A parts_seen
  local k n rkey hdrs line sampled
  for pt in "${WC_TOPICS[@]}"; do
    pod="${pt%%|*}"; topic="${pt#*|}"
    advanced=0; total_local=0; total_bridged=0
    local unreadable=false
    sample_keys=()
    parts_seen=()
    for k in "${!b_hw[@]}"; do
      [[ "$k" == "$pt|"* ]] && parts_seen["${k#"$pt"|}"]=1
    done
    for k in "${!a_hw[@]}"; do
      [[ "$k" == "$pt|"* ]] && parts_seen["${k#"$pt"|}"]=1
    done
    for part in "${!parts_seen[@]}"; do
      key="$pt|$part"
      part_hw_b="${b_hw[$key]:-}"; part_hw_a="${a_hw[$key]:-}"; part_ls_b="${b_ls[$key]:-}"
      if [ -z "$part_hw_b" ] || [ -z "$part_hw_a" ] || [ -z "$part_ls_b" ]; then
        unreadable=true
        continue
      fi
      delta=$(( part_hw_a - part_hw_b ))
      if [ "$delta" -lt 0 ]; then
        unreadable=true
        continue
      fi
      [ "$delta" -eq 0 ] && continue
      advanced=$(( advanced + delta ))
      n="$delta"; [ "$n" -gt "$WRITER_CENSUS_SAMPLE" ] && n="$WRITER_CENSUS_SAMPLE"
      # Every record prints one "<key>\t<headers>" line, so a line with a
      # tab is a record even when both halves are empty (a keyless,
      # headerless local write prints as a bare tab). Splitting by hand
      # rather than with IFS=$'\t' keeps that line from being dropped.
      sampled=0
      while IFS= read -r line; do
        [[ "$line" == *$'\t'* ]] || continue
        sampled=$((sampled + 1))
        rkey="${line%%$'\t'*}"; hdrs="${line#*$'\t'}"
        if [[ "$hdrs" == *kafka_topic* ]]; then
          total_bridged=$((total_bridged + 1))
        else
          total_local=$((total_local + 1))
          [ "${#sample_keys[@]}" -lt 3 ] && sample_keys+=("${rkey:-<no-key>}")
        fi
      done < <(kubectl exec -n "$NS" "$pod" -c redpanda -- \
                 timeout "${RPK_CMD_TIMEOUT:-60}" \
                 rpk topic consume "$topic" -p "$part" -o "$part_hw_b" -n "$n" \
                 -f '%k\t%h{%k;}\n' 2>/dev/null)
      # The high watermark moved but no record could be read back: the
      # writer is unknown, which is not the same as no local writer.
      [ "$sampled" -eq 0 ] && unreadable=true
    done
    if $unreadable; then
      WC_ADVANCED["$pt"]="?"; WC_LOCAL["$pt"]="?"; WC_BRIDGED["$pt"]="?"
    else
      WC_ADVANCED["$pt"]="$advanced"; WC_LOCAL["$pt"]="$total_local"; WC_BRIDGED["$pt"]="$total_bridged"
    fi
    WC_KEYS["$pt"]="${sample_keys[*]:-}"
    echo "writer census: $pod $topic advanced=${WC_ADVANCED[$pt]} local=${WC_LOCAL[$pt]} bridged=${WC_BRIDGED[$pt]}"
  done
}

# phase3b_writer_census -- see the PHASE 3b header above. Not gated by any
# --skip-* flag: an undeclared live writer is exactly the defect this
# phase exists to catch, and a cluster that would fail this check is a
# cluster phase 4 must not be allowed to trim.
phase3b_writer_census() {
  echo
  echo "=== PHASE 3b: writer census ==="
  build_declared_producer_map

  writer_census "$WRITER_CENSUS_WINDOW_S"

  local pt pod topic to_quiesce owner_list owner already
  local -a to_quiesce_entries=()
  local -A to_quiesce_seen=()
  for pt in "${WC_TOPICS[@]}"; do
    pod="${pt%%|*}"; topic="${pt#*|}"
    if [ "${WC_LOCAL[$pt]}" = "?" ]; then
      halt_reset "writer census: could not read $pod/$topic cleanly (failing closed)" \
        "Restate cleared, no topic trimmed" \
        "advanced=${WC_ADVANCED[$pt]} local=${WC_LOCAL[$pt]} bridged=${WC_BRIDGED[$pt]}"
    fi
    [ "${WC_LOCAL[$pt]}" -eq 0 ] && continue

    owner_list="${PRODUCER_OWNER[$pt]:-}"
    if [ -z "$owner_list" ]; then
      halt_reset "writer census: $pod/$topic has ${WC_LOCAL[$pt]} undeclared local write(s) in this window" \
        "sample keys: ${WC_KEYS[$pt]:-<none captured>}" \
        "Restate cleared, no topic trimmed"
    fi
    for owner in $owner_list; do
      [ -n "${to_quiesce_seen[$owner]:-}" ] && continue
      already=false
      local qe
      for qe in "${QSTATE_QUIESCED[@]:-}"; do [ "$qe" = "$owner" ] && already=true; done
      $already && continue
      to_quiesce_seen["$owner"]=1
      to_quiesce_entries+=("$owner")
    done
  done

  if [ "${#to_quiesce_entries[@]}" -gt 0 ]; then
    echo "writer census: quiescing ${#to_quiesce_entries[@]} declared writer(s): ${to_quiesce_entries[*]}"
    quiesce_workload_set "${to_quiesce_entries[@]}"
    CENSUS_QUIESCED+=("${to_quiesce_entries[@]}")
  else
    echo "writer census: every live local write is declared; nothing new to quiesce"
  fi

  local try pass local_advance bridged_advance
  for (( try = 1; try <= WRITER_SETTLE_TRIES; try++ )); do
    echo "writer census: settle attempt $try/$WRITER_SETTLE_TRIES"
    writer_census "$WRITER_CENSUS_WINDOW_S"
    local_advance=""
    bridged_advance=""
    for pt in "${WC_TOPICS[@]}"; do
      if [ "${WC_LOCAL[$pt]}" = "?" ] || [ "${WC_BRIDGED[$pt]}" = "?" ]; then
        halt_reset "writer census settle: could not read $pt cleanly on try $try (failing closed)" \
          "quiesced this run: ${CENSUS_QUIESCED[*]:-none}"
      fi
      [ "${WC_LOCAL[$pt]}" -gt 0 ] && local_advance="${local_advance:+$local_advance, }$pt (local=${WC_LOCAL[$pt]})"
      [ "${WC_BRIDGED[$pt]}" -gt 0 ] && bridged_advance="${bridged_advance:+$bridged_advance, }$pt (bridged=${WC_BRIDGED[$pt]})"
    done
    if [ -n "$local_advance" ]; then
      halt_reset "writer census settle: still advancing locally after quiesce: $local_advance" \
        "declared writers did not stop, or a writer is undeclared" \
        "quiesced this run: ${CENSUS_QUIESCED[*]:-none}"
    fi
    if [ -z "$bridged_advance" ]; then
      echo "writer census: settle PASS on try $try -- zero advance, local and bridged, on every partition"
      pass=0
      break
    fi
    echo "writer census: bridged-only advance on try $try (a drain): $bridged_advance"
    pass=1
  done
  if [ "${pass:-1}" -ne 0 ]; then
    halt_reset "writer census: still advancing after $WRITER_SETTLE_TRIES settle tries: $bridged_advance" \
      "quiesced this run: ${CENSUS_QUIESCED[*]:-none}"
  fi
}

# run_writer_census_only -- --writer-census-only (read-only). Step 1 +
# classification + the declared/undeclared verdict; no scaling, no halt.
run_writer_census_only() {
  echo "=== --writer-census-only: writer census (read-only) ==="
  build_declared_producer_map
  writer_census "$WRITER_CENSUS_WINDOW_S"

  local pt pod topic undeclared=0
  echo
  echo "broker topic advanced local bridged declared-owner(s)"
  for pt in "${WC_TOPICS[@]}"; do
    pod="${pt%%|*}"; topic="${pt#*|}"
    echo "$pod $topic ${WC_ADVANCED[$pt]} ${WC_LOCAL[$pt]} ${WC_BRIDGED[$pt]} ${PRODUCER_OWNER[$pt]:-<none>}"
    if [ "${WC_LOCAL[$pt]}" = "?" ]; then
      undeclared=$((undeclared + 1))
      echo "  UNREADABLE: $pod/$topic advanced but no new record could be read back -- counted as undeclared" >&2
      continue
    fi
    if [ "${WC_LOCAL[$pt]}" -gt 0 ] && [ -z "${PRODUCER_OWNER[$pt]:-}" ]; then
      undeclared=$((undeclared + 1))
      echo "  UNDECLARED: $pod/$topic has ${WC_LOCAL[$pt]} local write(s) with no declared owner" >&2
    fi
  done
  echo
  if [ "$undeclared" -eq 0 ]; then
    echo "--writer-census-only: PASSED -- every live local topic is declared"
    return 0
  fi
  echo "--writer-census-only: FAILED -- $undeclared live local topic(s) undeclared" >&2
  return 2
}

# ===========================================================================
# PHASE 4 — TOPICS.
#
# JUDGMENT CALL 10. The header this replaced argued for delete-and-recreate:
# trimming needs no knowledge of a topic's own config, and `rpk topic trim-
# prefix` returns POLICY_VIOLATION when a topic's cleanup.policy is pure
# `compact` (proven 2026-09-27 on scratch topics; see the note on
# topic_dynamic_config) — so a pure-compact topic looked impossible to empty
# any other way. 53 topics on the lab (13 each on hq/edge-01/edge-02/
# edge-03, 1 on region-east — all state topics or Faust changelogs) are pure
# `compact`.
#
# WHY THAT WAS WRONG: OFFSETS MUST NEVER GO BACKWARDS. Restate's Kafka
# ingress deduplicates each subscription by (consumer group, topic,
# partition), using the record's offset as the sequence number it has
# already seen. A topic that is deleted and recreated restarts at offset 0,
# and Restate silently drops every record below the old high-water mark as
# already-seen, while the consumer group itself stays Stable and broker-side
# lag reads ~0 — nothing about a delete-then-create looks wrong from the
# broker's side. Phase 10, below, exists because that drop is otherwise
# invisible from anywhere this script can read.
#
# SO EMPTYING NEVER DELETES. A pure-compact topic instead gains `delete`
# cleanup.policy for exactly as long as its trim takes, in four steps:
#
#   1. `rpk topic alter-config <t> --set cleanup.policy=compact,delete
#      --no-confirm` (alter-config prompts for confirmation exactly like
#      trim-prefix does, JUDGMENT CALL 9 below — same `--no-confirm` fix).
#   2. trim every partition to its own high watermark — the same per-
#      partition hw-read-then-trim this phase already does for the
#      trim-eligible bucket, reused rather than copied.
#   3. `rpk topic alter-config <t> --set cleanup.policy=<the CAPTURED
#      value> --no-confirm` — restored to whatever this topic's capture
#      read before step 1, never hardcoded back to plain `compact`.
#   4. assert_topic_matches_capture, the same post-mutation check the old
#      recreate path used, now reading the topic back after the restore
#      instead of after a create — plus log_start == high_watermark on
#      every partition, same as the trim-eligible bucket is checked for.
#
# The topic is never gone, so there is no window for auto-create to race
# against and nothing for a quiesced consumer to hang on. The per-topic
# quiesce this bucket used to require around that window (quiesce_derived_
# set, below) is gone from this phase's own mutation pass for exactly that
# reason — it is still exercised, standalone, by --census-only and
# --red-check-quiesce, which validate the same derivation/ownership
# machinery for its own sake and no longer rehearse a phase 4 gate that this
# phase does not run any more.
#
#   cleanup.policy contains "delete"  -> trim (unchanged path, below)
#   cleanup.policy is pure "compact"  -> policy-trim (alter, trim, alter back)
#
# THE CAPTURE ITSELF IS UNCHANGED. The config this bucket needs is not
# restated from this script's own knowledge of the chart — it is CAPTURED
# from the live broker immediately before any mutation (see topic_shape/
# topic_dynamic_config and the capture store above is_internal_topic). There
# is no second copy of the chart's topic matrix to drift, because nothing
# here claims to know the matrix; it reads whatever the broker is actually
# running right now. And a capture that is never checked against what comes
# back is only a hope that the restore matched it — assert_topic_matches_
# capture is what turns that into an actual check, on every policy-trimmed
# topic, every run.
#
# STILL TRUE, UNCHANGED FROM THE ORIGINAL HEADER:
#
# Faust's changelog topics need no special-casing: they are ordinary topics
# on these same brokers and are swept in by the same per-broker enumeration,
# as long as they are not internal-prefixed (they are not).
#
# `rpk topic trim-prefix` sets the log START offset; it does NOT zero the
# high watermark. The predicted post-reset state for a trimmed topic is
# log_start == high_watermark, not high_watermark == 0 — read the high
# watermark first, per partition, and trim exactly to it.
# ===========================================================================

# ---------------------------------------------------------------------------
# Consumer quiesce for the DERIVED set (derive_quiesce_set, above). Built
# for the topics that used to be deleted-and-recreated, back when that
# window was the one thing a live consumer could lose a race against (see
# JUDGMENT CALL 10, above) — policy-trim never makes a topic disappear, so
# phase4_topics itself no longer calls this. Kept, and still called
# directly, by --census-only and --red-check-quiesce, which exercise the
# same derivation/ownership machinery on its own merits. Same shape
# phase2_quiesce's producer quiesce always had — read the live value,
# capture it before mutating, scale/patch through maybe_run — generalised
# across every kind in work item 3's table, because the derived set can
# hold a StatefulSet (the Restate runtimes), a DaemonSet (only ever seen in
# --red-check-quiesce today — fact 6, zero exist in the namespace), or a
# Job, not only a Deployment.
#
# The EXIT trap is installed by the caller (quiesce_workload_set) the
# moment it decides to quiesce anything, not inside this function — same
# reasoning as the superseded quiesce_state_consumers had: the moment that
# matters is "something is now being taken down."
# ---------------------------------------------------------------------------

# _kind_arg KIND -> the kubectl resource-type argument for that kind. A
# one-line lookup, not a case statement repeated at every call site.
_kind_arg() {
  case "$1" in
    Deployment)  echo deploy ;;
    StatefulSet) echo sts ;;
    ReplicaSet)  echo rs ;;
    DaemonSet)   echo ds ;;
    Job)         echo job ;;
    Pod)         echo pod ;;
    *)           echo "$1" ;;
  esac
}

# quiesce_derived_workload "Kind/Name" — dispatch by kind, work item 3's
# table exactly. Captures the live value into the matching QSTATE_* map
# BEFORE mutating (the same capture-then-restore-verbatim rule phase 4
# already follows for topic configs), then appends to QSTATE_QUIESCED so
# restore_derived_workload and the EXIT trap both know this entry was
# actually touched.
#
# DaemonSet capture uses `-o jsonpath-as-json`, not plain `-o jsonpath`:
# plain jsonpath prints a map as Go's `map[key:value]`, which is not valid
# JSON and cannot be dropped into a JSON Patch `value` verbatim. `jsonpath-
# as-json` (kubectl's own JSON-safe variant of the same query language)
# returns a genuine JSON array of matches with no jq involved, so a single
# `sed` strip of the surrounding `[`/`]` is enough to get the captured
# value itself, or an empty string when nodeSelector was absent — which is
# exactly the "captured-absent restores to null" case the table asks for,
# and why QSTATE_NODESEL_HAD exists as a separate flag rather than trying
# to tell "captured empty object" and "captured absent" apart from the
# string alone.
#
# A bare Pod (no owner) is a hard stop, per the table — printed and
# refused, not silently skipped, because a Pod surviving into the derived
# set means owner resolution ran out of options for it.
quiesce_derived_workload() {
  local entry="$1" kind name karg rc nodesel_json
  kind="${entry%%/*}"
  name="${entry#*/}"
  karg="$(_kind_arg "$kind")"

  case "$kind" in
    Deployment|StatefulSet|ReplicaSet)
      rc="$(kubectl get "$karg" -n "$NS" "$name" -o jsonpath='{.spec.replicas}' 2>/dev/null)"
      QSTATE_REPLICAS["$entry"]="${rc:-1}"
      if [ -z "$rc" ]; then
        echo "WARNING: could not read current replica count for $entry; recorded 1 as a" >&2
        echo "         last resort. If that is wrong, the restore below will restore" >&2
        echo "         it wrong." >&2
      fi
      maybe_run "scale $entry to 0 (was ${QSTATE_REPLICAS[$entry]})" \
        kubectl scale "$karg" -n "$NS" "$name" --replicas=0
      QSTATE_QUIESCED+=("$entry")
      ;;
    DaemonSet)
      nodesel_json="$(kubectl get ds -n "$NS" "$name" -o jsonpath-as-json='{.spec.template.spec.nodeSelector}' 2>/dev/null \
        | sed -e 's/^\[//' -e 's/\]$//')"
      if [ -n "$nodesel_json" ] && [ "$nodesel_json" != "null" ]; then
        QSTATE_NODESEL["$entry"]="$nodesel_json"
        QSTATE_NODESEL_HAD["$entry"]=1
      fi
      maybe_run "quiesce $entry (merge-patch nodeSelector to add openddil.io/quiesced=true — no node carries this label, so every pod is evicted)" \
        kubectl patch ds -n "$NS" "$name" --type merge \
        -p '{"spec":{"template":{"spec":{"nodeSelector":{"openddil.io/quiesced":"true"}}}}}'
      QSTATE_QUIESCED+=("$entry")
      ;;
    Job)
      local suspend
      suspend="$(kubectl get job -n "$NS" "$name" -o jsonpath='{.spec.suspend}' 2>/dev/null)"
      QSTATE_SUSPEND["$entry"]="${suspend:-false}"
      maybe_run "suspend $entry (was ${QSTATE_SUSPEND[$entry]})" \
        kubectl patch job -n "$NS" "$name" --type merge -p '{"spec":{"suspend":true}}'
      QSTATE_QUIESCED+=("$entry")
      ;;
    Pod)
      echo "CANNOT QUIESCE: $entry has no owner — a bare Pod cannot be scaled," >&2
      echo "  DaemonSet-patched, or Job-suspended. This is a hard stop for this" >&2
      echo "  entry, per work item 3's table; it is not quiesced and not restored." >&2
      halt_reset "cannot quiesce $entry: a bare Pod has no owner to scale" \
        "$entry still running; quiesced so far: ${QSTATE_QUIESCED[*]:-none}"
      ;;
    *)
      echo "WARNING: $entry — unrecognised kind '$kind', not quiesced." >&2
      halt_reset "cannot quiesce $entry: unrecognised kind '$kind'" \
        "$entry still running; quiesced so far: ${QSTATE_QUIESCED[*]:-none}"
      ;;
  esac
}

# restore_derived_workload "Kind/Name" — the inverse of quiesce_derived_
# workload, from the SAME QSTATE_* maps. Safe to call on an entry that was
# never actually quiesced (all three maps miss, so the guard returns early)
# — the normal case when this runs from the EXIT trap after the quiesce
# loop died partway through its own list.
#
# DaemonSet restore is a JSON Patch (RFC 6902), not a merge patch like the
# quiesce side: a merge patch can only ADD or overwrite keys, it cannot
# REMOVE the one this function's quiesce step added when the original had
# no nodeSelector at all — that needs an explicit `remove` op. When the
# original DID have a nodeSelector, `replace` puts back the exact captured
# JSON verbatim, openddil.io/quiesced included in whatever the merge patch
# left behind and now overwritten away.
restore_derived_workload() {
  local entry="$1" kind name karg rc suspend
  kind="${entry%%/*}"
  name="${entry#*/}"
  karg="$(_kind_arg "$kind")"

  case "$kind" in
    Deployment|StatefulSet|ReplicaSet)
      rc="${QSTATE_REPLICAS[$entry]:-}"
      [ -z "$rc" ] && return 0
      maybe_run "restore $entry to $rc" \
        kubectl scale "$karg" -n "$NS" "$name" --replicas="$rc"
      ;;
    DaemonSet)
      if [ -n "${QSTATE_NODESEL_HAD[$entry]:-}" ]; then
        maybe_run "restore $entry nodeSelector to captured value (verbatim)" \
          kubectl patch ds -n "$NS" "$name" --type=json \
          -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":${QSTATE_NODESEL[$entry]}}]"
      else
        maybe_run "restore $entry nodeSelector (remove — captured-absent)" \
          kubectl patch ds -n "$NS" "$name" --type=json \
          -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]'
      fi
      ;;
    Job)
      suspend="${QSTATE_SUSPEND[$entry]:-}"
      [ -z "$suspend" ] && return 0
      maybe_run "restore $entry suspend=$suspend" \
        kubectl patch job -n "$NS" "$name" --type merge -p "{\"spec\":{\"suspend\":$suspend}}"
      ;;
    *)
      return 0
      ;;
  esac
}

# quiesce_workload_set "Kind/Name" ... — arms the trap once, quiesces every
# entry, then waits for the Deployment/StatefulSet/ReplicaSet entries'
# live pods to actually terminate (a DaemonSet/Job entry has no equivalent
# "status.replicas" to poll the same way, and is not polled here).
#
# THIS WAIT IS A COURTESY, NOT THE SAFETY GATE. assert_no_live_consumers
#, called by the caller after this returns, is what actually
# decides whether a delete may proceed — it re-reads the census fresh
# rather than trusting that a fixed 120s poll here caught everything. That
# split is deliberate: this loop existed in the superseded quiesce_state_
# consumers as a best-effort wait; making the CENSUS the gate instead of
# the poll is exactly the fix work item 4 is for.
quiesce_workload_set() {
  local -a entries=("$@")
  [ "${#entries[@]}" -eq 0 ] && return 0
  arm_scale_trap
  # No IP->pod map to build any more (SPEC-consumer-declarations.md): ownership
  # comes from the chart's own annotation, not the scaled-down pod's own IP,
  # so there is nothing here that a scale-to-zero could make unresolvable.
  local e
  for e in "${entries[@]}"; do
    quiesce_derived_workload "$e" || true
  done

  if $DRY_RUN; then
    echo "   [dry-run] not waiting for pods to terminate — nothing was actually" \
         "scaled down"
    return 0
  fi

  local kind name karg i cur
  for e in "${entries[@]}"; do
    kind="${e%%/*}"
    name="${e#*/}"
    case "$kind" in
      Deployment|StatefulSet|ReplicaSet) karg="$(_kind_arg "$kind")" ;;
      *) continue ;;
    esac
    i=0
    while [ "$i" -lt 60 ]; do
      cur="$(kubectl get "$karg" -n "$NS" "$name" -o jsonpath='{.status.replicas}' 2>/dev/null)"
      if [ -z "$cur" ] || [ "$cur" = "0" ]; then
        break
      fi
      sleep 2
      i=$((i + 1))
    done
    if [ "$i" -ge 60 ]; then
      echo "WARNING: $e still reports status.replicas=$cur after 120s of polling —" >&2
      echo "         proceeding anyway; assert_no_live_consumers re-checks the" >&2
      echo "         actual census rather than trusting this poll." >&2
    fi
  done
}

# The real (non-red-check) entry point: derive the set from every captured
# topic (trims included — work item 2 says derive from the full capture,
# even though the LATER assertion is scoped to the delete bucket only, work
# item 4), quiesce it, and remember exactly what was derived so the
# restore call after the mutation pass has something to iterate.
DERIVED_QUIESCE_SET=()

quiesce_derived_set() {
  local -a targets=("$@")
  mapfile -t DERIVED_QUIESCE_SET < <(derive_quiesce_set "${targets[@]}")
  echo "derived quiesce set: ${#DERIVED_QUIESCE_SET[@]} workload(s) (see provenance above)"
  quiesce_workload_set "${DERIVED_QUIESCE_SET[@]}"
}

# restore_derived_set — walks QSTATE_QUIESCED, not DERIVED_QUIESCE_SET:
# the former is what was actually attempted (see its declaration), which is
# the same "safe on a never-quiesced entry, safe to call twice" contract
# restore_state_consumers used to keep by checking ORIG_REPLICAS per entry.
restore_derived_set() {
  local e
  for e in "${QSTATE_QUIESCED[@]:-}"; do
    [ -z "$e" ] && continue
    restore_derived_workload "$e"
  done
}

# ---------------------------------------------------------------------------
# emergency_restore_scales — the SINGLE EXIT trap, covering BOTH scale-downs.
#
# WHY THIS EXISTS, and why it is not the per-phase trap it replaced.
#
# Every phase here is called BARE at the bottom of the file, not inside a
# function that checks its status. Under `set -euo pipefail` that means a
# `return 1` from any phase aborts the whole script on the spot — so
# phase4_topics' new failure path (a topic that did not match its capture)
# would abort BEFORE phase9_restore_producers ever ran, leaving the producers
# phase 2 scaled to zero still at zero. That is precisely the half state this
# script exists to prevent, and phase 4's own `trap 'restore_state_consumers'
# EXIT` could not prevent it: it rescued the consumers and left the producers
# down, and its matching `trap - EXIT` would have disarmed any script-wide
# trap for phases 5 through 9 as a side effect. Two traps on EXIT are one
# trap; the second silently wins.
#
# So: ONE trap, armed the first time anything is scaled down, restoring
# everything with a recorded original count.
#
# Three properties a trap must have that an ordinary restore need not:
#   * it cannot be allowed to fail. Each scale is guarded individually and
#     prints the exact by-hand command on failure, because a trap that dies
#     halfway leaves the operator with no list of what is still down.
#   * it must not fire on a clean run. SCALES_RESTORED is set by phase 9, and
#     a zero exit status returns immediately — otherwise a legitimately
#     non-zero phase 8 (a --skip-* red-check SUCCEEDING) would print an
#     alarming emergency block over an already-correct cluster.
#   * it must respect --dry-run. A dry run that mutates the cluster from its
#     error path is not a dry run.
# ---------------------------------------------------------------------------
SCALES_ARMED=false
SCALES_RESTORED=false

arm_scale_trap() {
  $SCALES_ARMED && return 0
  SCALES_ARMED=true
  # In a full reset on_reset_exit already owns EXIT and calls
  # emergency_restore_scales itself; arming here would replace it (two traps
  # on EXIT are one trap, see above).
  $RESET_RUN && return 0
  trap 'emergency_restore_scales' EXIT
}

emergency_restore_scales() {
  local exit_code="${1:-$?}"
  trap - EXIT   # never re-enter, whatever happens below
  [ "$exit_code" -eq 0 ] && return 0
  $SCALES_RESTORED && return 0

  echo >&2
  echo "!!! ABORTED AT EXIT $exit_code WITH WORKLOADS SCALED DOWN !!!" >&2
  echo "    Restoring recorded replica counts so the cluster is not left" >&2
  echo "    half reset. This is a ROLLBACK of the scale-downs only — every" >&2
  echo "    store, topic and Restate mutation already made STAYS made, and" >&2
  echo "    this cluster has NOT been reset. Read the phase output above" >&2
  echo "    before re-running." >&2
  echo >&2

  local d rc
  for d in "${PRODUCER_DEPLOYS[@]:-}"; do
    [ -z "$d" ] && continue
    rc="${ORIG_REPLICAS[$d]:-}"
    [ -z "$rc" ] && continue
    echo "-> emergency restore $d to $rc" >&2
    $DRY_RUN && continue
    kubectl scale deploy -n "$NS" "$d" --replicas="$rc" >&2 || {
      echo "   COULD NOT RESTORE $d. Run this by hand:" >&2
      echo "     kubectl scale deploy -n $NS $d --replicas=$rc" >&2
    }
  done

  # Second loop, extending this trap rather than duplicating it (work item
  # 3): the derived-set quiesce (any kind in its table) restores from the
  # QSTATE_* maps by walking QSTATE_QUIESCED — same "never fail, print the
  # by-hand command" guard shape as the producer loop above, generalised
  # across kind because a DaemonSet/Job entry has no `kubectl scale`
  # equivalent.
  local entry kind name karg suspend
  for entry in "${QSTATE_QUIESCED[@]:-}"; do
    [ -z "$entry" ] && continue
    kind="${entry%%/*}"
    name="${entry#*/}"
    karg="$(_kind_arg "$kind")"
    case "$kind" in
      Deployment|StatefulSet|ReplicaSet)
        rc="${QSTATE_REPLICAS[$entry]:-}"
        [ -z "$rc" ] && continue
        echo "-> emergency restore $entry to $rc" >&2
        $DRY_RUN && continue
        kubectl scale "$karg" -n "$NS" "$name" --replicas="$rc" >&2 || {
          echo "   COULD NOT RESTORE $entry. Run this by hand:" >&2
          echo "     kubectl scale $karg -n $NS $name --replicas=$rc" >&2
        }
        ;;
      DaemonSet)
        echo "-> emergency restore $entry nodeSelector" >&2
        $DRY_RUN && continue
        if [ -n "${QSTATE_NODESEL_HAD[$entry]:-}" ]; then
          kubectl patch ds -n "$NS" "$name" --type=json \
            -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":${QSTATE_NODESEL[$entry]}}]" >&2 || {
            echo "   COULD NOT RESTORE $entry. Run this by hand (verbatim captured JSON):" >&2
            echo "     kubectl patch ds -n $NS $name --type=json -p '[{\"op\":\"replace\",\"path\":\"/spec/template/spec/nodeSelector\",\"value\":${QSTATE_NODESEL[$entry]}}]'" >&2
          }
        else
          kubectl patch ds -n "$NS" "$name" --type=json \
            -p '[{"op":"remove","path":"/spec/template/spec/nodeSelector"}]' >&2 || {
            echo "   COULD NOT RESTORE $entry. Run this by hand:" >&2
            echo "     kubectl patch ds -n $NS $name --type=json -p '[{\"op\":\"remove\",\"path\":\"/spec/template/spec/nodeSelector\"}]'" >&2
          }
        fi
        ;;
      Job)
        suspend="${QSTATE_SUSPEND[$entry]:-}"
        [ -z "$suspend" ] && continue
        echo "-> emergency restore $entry suspend=$suspend" >&2
        $DRY_RUN && continue
        kubectl patch job -n "$NS" "$name" --type merge -p "{\"spec\":{\"suspend\":$suspend}}" >&2 || {
          echo "   COULD NOT RESTORE $entry. Run this by hand:" >&2
          echo "     kubectl patch job -n $NS $name --type merge -p '{\"spec\":{\"suspend\":$suspend}}'" >&2
        }
        ;;
    esac
  done
}

# ===========================================================================
# PHASE 4 ORDERING — bridge graph, topological sort, destination stability.
#
# A reset once trimmed hq before region-east while region-east's own
# aggregator output was still arriving at hq over the uplink: a
# destination trimmed before its
# source is exactly how a forwarded write lands on an offset the trim
# already walked past. This section makes "source before destination" a
# property of the ORDER phase 4 walks brokers in, not a hope.
# ===========================================================================

# _broker_id_of_pod POD -- the broker-id half of a redpanda pod name, the
# inverse of the "${RELEASE}-redpanda-${broker}-0" construction every
# other broker-pod mapping in this file already uses (build_declared_
# owner_map, declared_producers, etc).
_broker_id_of_pod() {
  local pod="$1" id
  id="${pod#${RELEASE}-redpanda-}"
  id="${id%-0}"
  printf '%s' "$id"
}

# bridge_graph -- one kubectl get for every Deployment/StatefulSet's
# consumer-groups annotation + env (a bridge/uplink carries DEST_HOST and
# DEST_PORT -- see edge.yaml's own comment on the produces-topics
# annotation it deliberately omits), plus one kubectl get for
# ${RELEASE}-toxiproxy-config, to build the source->destination broker-id
# edges this ordering is based on.
#
# Destination resolution: DEST_HOST is either a broker Service directly
# (compared against every known broker id's own "${RELEASE}-redpanda-
# <id>" prefix), or -- the severance-injection seam -- the toxiproxy
# Service, in which case the proxy listening on DEST_PORT names the real
# upstream broker (openddil.toxiproxyConfigJson's own "listen"/"upstream"
# pair, read back with no jq: Values' own encoding/json sorts a map's
# keys alphabetically when it marshals, so "listen" always precedes
# "upstream" within one proxy object -- measured against the chart's own
# render, not assumed). An edge that resolves to neither is a halt, not a
# guess.
declare -a BRIDGE_EDGES=()      # ordered "src-id dest-id", for printing
declare -A BRIDGE_DESTS=()      # broker-id -> 1 iff it is a destination of some edge
BRIDGE_GRAPH_BUILT=false

bridge_graph() {
  $BRIDGE_GRAPH_BUILT && return 0
  BRIDGE_GRAPH_BUILT=true
  BRIDGE_EDGES=()
  BRIDGE_DESTS=()

  local -a known_ids=()
  local pod
  for pod in "${REDPANDA_PODS[@]}"; do
    known_ids+=("$(_broker_id_of_pod "$pod")")
  done

  local toxi_json port upstream
  declare -A toxi_upstream=()
  toxi_json="$(kubectl get cm -n "$NS" "${RELEASE}-toxiproxy-config" -o jsonpath='{.data.toxiproxy\.json}' 2>/dev/null)"
  if [ -n "$toxi_json" ]; then
    while read -r port upstream; do
      [ -z "$port" ] && continue
      toxi_upstream["$port"]="$upstream"
    done < <(printf '%s\n' "$toxi_json" | awk -F'"' '
      $2 == "listen"   { split($4, a, ":"); port = a[2] }
      $2 == "upstream" { print port, $4 }
    ')
  fi

  local owner cg envraw name value dest_host dest_port src_id dest_id host_only kid
  while IFS=$'\t' read -r owner cg envraw; do
    [ -z "$owner" ] && continue
    dest_host=""; dest_port=""
    while IFS='=' read -r name value; do
      [ "$name" = "DEST_HOST" ] && dest_host="$value"
      [ "$name" = "DEST_PORT" ] && dest_port="$value"
    done < <(printf '%s\n' "$envraw" | tr '|' '\n')
    [ -z "$dest_host" ] && [ -z "$dest_port" ] && continue
    if [ -z "$dest_host" ] || [ -z "$dest_port" ]; then
      halt_reset "bridge graph: $owner has one of DEST_HOST/DEST_PORT set but not the other" \
        "DEST_HOST=${dest_host:-<missing>} DEST_PORT=${dest_port:-<missing>}"
    fi

    src_id="${cg%%/*}"
    if [ -z "$cg" ] || [ -z "$src_id" ]; then
      halt_reset "bridge graph: $owner has DEST_HOST/DEST_PORT but no openddil.io/consumer-groups pair to read its source broker-id from" \
        "DEST_HOST=$dest_host DEST_PORT=$dest_port"
    fi

    dest_id=""
    host_only="${dest_host%%.*}"
    for kid in "${known_ids[@]}"; do
      if [ "$host_only" = "${RELEASE}-redpanda-${kid}" ]; then
        dest_id="$kid"
        break
      fi
    done
    if [ -z "$dest_id" ]; then
      upstream="${toxi_upstream[$dest_port]:-}"
      if [ -z "$upstream" ]; then
        halt_reset "bridge graph: $owner's DEST_PORT $dest_port matches no proxy in ${RELEASE}-toxiproxy-config, and DEST_HOST ($dest_host) is not a broker service" \
          "cannot resolve this edge's destination broker"
      fi
      host_only="${upstream%%:*}"
      host_only="${host_only%%.*}"
      for kid in "${known_ids[@]}"; do
        if [ "$host_only" = "${RELEASE}-redpanda-${kid}" ]; then
          dest_id="$kid"
          break
        fi
      done
      if [ -z "$dest_id" ]; then
        halt_reset "bridge graph: $owner's DEST_PORT $dest_port resolves to upstream $upstream, which matches no known broker" \
          "known brokers: ${known_ids[*]:-none}"
      fi
    fi

    BRIDGE_EDGES+=("$src_id $dest_id")
    BRIDGE_DESTS["$dest_id"]=1
  done < <(kubectl get deploy,statefulset -n "$NS" \
    -o jsonpath='{range .items[*]}{.kind}{"/"}{.metadata.name}{"\t"}{.metadata.annotations.openddil\.io/consumer-groups}{"\t"}{range .spec.template.spec.containers[0].env[*]}{.name}{"="}{.value}{"|"}{end}{"\n"}{end}' \
    2>/dev/null)
}

# topo_sort_redpanda_pods -- reorders the global REDPANDA_PODS so every
# edge's source broker is walked before its destination (Kahn's
# algorithm; ties broken by broker id so the order is deterministic, not
# just acyclic). Cycle -> halt naming every broker-id still blocked, since
# that is exactly the set the cycle runs through. Call AFTER bridge_graph.
topo_sort_redpanda_pods() {
  local -a ids=() order=()
  local -A indeg=() pod_by_id=()
  local pod id edge src dst

  for pod in "${REDPANDA_PODS[@]}"; do
    id="$(_broker_id_of_pod "$pod")"
    ids+=("$id")
    pod_by_id["$id"]="$pod"
    indeg["$id"]=0
  done
  for edge in "${BRIDGE_EDGES[@]:-}"; do
    [ -z "$edge" ] && continue
    dst="${edge#* }"
    [ -n "${indeg[$dst]+x}" ] && indeg["$dst"]=$(( ${indeg[$dst]} + 1 ))
  done

  local -a remaining=("${ids[@]}")
  while [ "${#remaining[@]}" -gt 0 ]; do
    local -a ready=() still=()
    for id in "${remaining[@]}"; do
      if [ "${indeg[$id]:-0}" -eq 0 ]; then
        ready+=("$id")
      else
        still+=("$id")
      fi
    done
    if [ "${#ready[@]}" -eq 0 ]; then
      halt_reset "bridge graph: cycle among broker(s) ${still[*]} -- phase 4 cannot order a source-first trim" \
        "edges: ${BRIDGE_EDGES[*]:-none}"
    fi
    mapfile -t ready < <(printf '%s\n' "${ready[@]}" | sort)
    order+=("${ready[@]}")
    for id in "${ready[@]}"; do
      for edge in "${BRIDGE_EDGES[@]:-}"; do
        [ -z "$edge" ] && continue
        src="${edge%% *}"; dst="${edge#* }"
        [ "$src" = "$id" ] && [ -n "${indeg[$dst]+x}" ] && indeg["$dst"]=$(( ${indeg[$dst]} - 1 ))
      done
    done
    remaining=("${still[@]}")
  done

  REDPANDA_PODS=()
  for id in "${order[@]}"; do
    REDPANDA_PODS+=("${pod_by_id[$id]}")
  done

  echo "phase 4 order (source-first): ${order[*]}"
  if [ "${#BRIDGE_EDGES[@]}" -gt 0 ]; then
    echo "bridge graph edges:"
    local e
    for e in "${BRIDGE_EDGES[@]}"; do
      echo "  ${e%% *} -> ${e#* }"
    done
  else
    echo "bridge graph: no edges (no bridge/uplink Deployment or StatefulSet carries both DEST_HOST and DEST_PORT)"
  fi
}

# assert_destination_stable POD -- the pre-trim destination-stability
# gate. A no-op for any broker bridge_graph never marked as a destination
# of an edge: a source-only broker has nothing yet arriving that phase
# 4's own capture did not already account for.
#
# Two batched reads of every CAPTURED_TOPICS partition belonging to POD,
# DEST_SETTLE_S apart; retried up to DEST_READ_TRIES. Still disagreeing
# on the last try is a halt naming exactly the partitions that moved --
# this broker is still receiving forwarded writes, and trimming it now
# would repeat the defect this ordering exists to prevent.
assert_destination_stable() {
  local pod="$1" id
  id="$(_broker_id_of_pod "$pod")"
  [ -z "${BRIDGE_DESTS[$id]:-}" ] && return 0

  local tries="${DEST_READ_TRIES:-6}" settle="${DEST_SETTLE_S:-5}"
  local try pt topic part logstart hw k moved
  local -A r1 r2
  for (( try = 1; try <= tries; try++ )); do
    r1=(); r2=(); moved=""
    for pt in "${CAPTURED_TOPICS[@]}"; do
      [ "${pt%%|*}" = "$pod" ] || continue
      topic="${pt#*|}"
      while read -r part logstart hw; do
        [ -z "$part" ] && continue
        r1["$topic|$part"]="$logstart $hw"
      done < <(topic_partitions "$pod" "$topic")
    done
    sleep "$settle"
    for pt in "${CAPTURED_TOPICS[@]}"; do
      [ "${pt%%|*}" = "$pod" ] || continue
      topic="${pt#*|}"
      while read -r part logstart hw; do
        [ -z "$part" ] && continue
        r2["$topic|$part"]="$logstart $hw"
      done < <(topic_partitions "$pod" "$topic")
    done
    for k in "${!r1[@]}"; do
      [ "${r1[$k]:-}" = "${r2[$k]:-}" ] || moved="${moved:+$moved, }$k (${r1[$k]:-?} -> ${r2[$k]:-?})"
    done
    if [ -z "$moved" ]; then
      echo "  $pod: destination-stable after $try read(s)"
      return 0
    fi
    echo "  $pod: destination moved on try $try: $moved"
  done
  halt_reset "phase 4: $pod is a bridge destination and did not settle after $tries double-read(s), ${settle}s apart" \
    "still moving: $moved"
}

# assert_broker_fully_trimmed POD -- the post-trim double read, EVERY
# broker (not only destinations): two batched reads, DEST_SETTLE_S apart,
# of every CAPTURED_TOPICS partition belonging to POD; every partition
# must read log-start == hw on BOTH reads. A mismatch (or a second read
# that moved) means something wrote to this broker again after phase 4
# trimmed it -- the per-topic verify inside the mutation loop already
# checks the FIRST read as it goes; this is the second, independent one,
# over the whole broker, after every one of its topics is done.
assert_broker_fully_trimmed() {
  local pod="$1" settle="${DEST_SETTLE_S:-5}"
  local pt topic part logstart hw bad=""
  for pt in "${CAPTURED_TOPICS[@]}"; do
    [ "${pt%%|*}" = "$pod" ] || continue
    topic="${pt#*|}"
    while read -r part logstart hw; do
      [ -z "$part" ] && continue
      [ "$logstart" = "$hw" ] || bad="${bad:+$bad, }$topic p$part (log-start=$logstart hw=$hw, read 1)"
    done < <(topic_partitions "$pod" "$topic")
  done
  if [ -n "$bad" ]; then
    halt_reset "phase 4: $pod has partition(s) not fully trimmed on the first post-trim read" "$bad"
  fi

  sleep "$settle"
  bad=""
  for pt in "${CAPTURED_TOPICS[@]}"; do
    [ "${pt%%|*}" = "$pod" ] || continue
    topic="${pt#*|}"
    while read -r part logstart hw; do
      [ -z "$part" ] && continue
      [ "$logstart" = "$hw" ] || bad="${bad:+$bad, }$topic p$part (log-start=$logstart hw=$hw, read 2)"
    done < <(topic_partitions "$pod" "$topic")
  done
  if [ -n "$bad" ]; then
    halt_reset "phase 4: $pod has partition(s) that advanced again after trimming, on the second post-trim read ${settle}s later" "$bad"
  fi
  echo "  $pod: post-trim double read clean (log-start == hw, twice, ${settle}s apart)"
}

# ---------------------------------------------------------------------------
# phase4_capture_pass — the read-only capture half of phase 4, pulled into
# its own function so --census-only (work item 6) runs the SAME capture
# code a real run does instead of a second, driftable copy of it.
# Populates the now-global CAPTURED_TOPICS / TOPIC_BUCKET / CAPTURE_TRIM_N /
# CAPTURE_POLICYTRIM_N — promoted from phase4_topics' own locals to globals
# for exactly that reuse.
#
# ALL brokers, ALL non-internal topics, BEFORE any mutation. This has to be
# a separate, complete pass rather than capture-then-mutate per topic,
# because the pre-flight consumer-declaration check and --census-only's
# read-only preview both need the FULL tally before any mutation pass
# begins, not just phase 4's own.
# ---------------------------------------------------------------------------
CAPTURED_TOPICS=()
declare -A TOPIC_BUCKET=()
CAPTURE_TRIM_N=0
CAPTURE_POLICYTRIM_N=0

phase4_capture_pass() {
  mkdir -p "$TOPIC_CAPTURE_DIR"
  echo "topic capture directory (kept after this run — evidence, not scratch): $TOPIC_CAPTURE_DIR"

  CAPTURED_TOPICS=()
  TOPIC_BUCKET=()
  CAPTURE_TRIM_N=0
  CAPTURE_POLICYTRIM_N=0

  local pod topic policy shape dynamic capdir capfile
  for pod in "${REDPANDA_PODS[@]}"; do
    while read -r topic; do
      [ -z "$topic" ] && continue
      is_internal_topic "$topic" && continue

      policy="$(topic_policy "$pod" "$topic")"
      capdir="$TOPIC_CAPTURE_DIR/$pod"
      mkdir -p "$capdir"
      capfile="$capdir/$topic.cap"
      shape="$(topic_shape "$pod" "$topic")"
      dynamic="$(topic_dynamic_config "$pod" "$topic")"
      { printf 'shape %s\n' "$shape"; printf '%s\n' "$dynamic"; } > "$capfile"

      case "$policy" in
        *delete*)
          TOPIC_BUCKET["$pod|$topic"]="trim"
          CAPTURE_TRIM_N=$((CAPTURE_TRIM_N + 1))
          ;;
        compact)
          TOPIC_BUCKET["$pod|$topic"]="policy-trim"
          CAPTURE_POLICYTRIM_N=$((CAPTURE_POLICYTRIM_N + 1))
          ;;
        *)
          # Covers both an empty read (rpk/awk found no cleanup.policy row)
          # and any value that is neither of the two measured shapes. An
          # unreadable policy must not be silently treated as trim-eligible
          # — trim-prefix's own POLICY_VIOLATION on a pure-compact topic is
          # the entire reason this split exists, so guessing wrong here
          # reproduces the bug this phase was rewritten to fix.
          echo "WARNING: $pod/$topic — cleanup.policy read back as '${policy:-EMPTY}'," >&2
          echo "         neither pure compact nor delete-containing. Skipping this" >&2
          echo "         topic: not trimmed, not policy-trimmed." >&2
          continue
          ;;
      esac
      CAPTURED_TOPICS+=("$pod|$topic")
    done < <(broker_topics "$pod")
  done

  echo "capture: $((CAPTURE_TRIM_N + CAPTURE_POLICYTRIM_N)) topics ($CAPTURE_TRIM_N trim-eligible, $CAPTURE_POLICYTRIM_N policy-trim-eligible)"
}

# ---------------------------------------------------------------------------
# trim_topic_to_hw POD TOPIC — the one trim action both buckets below
# perform identically: read every partition's own high watermark and trim
# its log-start to exactly that offset. Pulled into its own function so the
# policy-trim bucket (which can only run this AFTER its own alter-config
# widens cleanup.policy) reuses the exact same form the trim-eligible
# bucket uses — same hw read, same --no-confirm, same per-partition loop —
# instead of a second copy that could drift from JUDGMENT CALL 9's fix.
#
# Called bare (trim-eligible bucket) it behaves exactly as before: a failed
# trim-prefix kills the script via `set -e`. Called as the condition of an
# `if !` (policy-trim bucket, below) that suspension of `set -e` extends
# into this function too, so a failed trim-prefix there is reported, not
# fatal — the caller still has an alter-config to undo.
# ---------------------------------------------------------------------------
trim_topic_to_hw() {
  # Returns non-zero if ANY partition's trim failed, not just the last one:
  # under `if !` set -e is off, and a loop's status is its last command's.
  local pod="$1" topic="$2" part logstart hw rc=0
  while read -r part logstart hw; do
    [ -z "$part" ] && continue
    if [ "$logstart" = "$hw" ]; then
      printf '  %-28s %-30s p%-3s already at hw=%s — nothing to trim\n' \
        "$pod" "$topic" "$part" "$hw"
      continue
    fi
    # JUDGMENT CALL 9 — `rpk topic trim-prefix` PROMPTS ("Confirm deletion
    # of all data before the new start offsets? (Y/n)"); `kubectl exec` has
    # no tty, so an unguarded prompt reads EOF and `set -e` kills the script
    # mid-mutation. `--no-confirm` ("Disable confirmation prompt"), plus a
    # timeout so any other prompt on this path fails fast instead of
    # hanging.
    maybe_run "trim $topic partition $part on $pod: log_start $logstart -> $hw" \
      kubectl exec -n "$NS" "$pod" -c redpanda -- \
      timeout "${RPK_CMD_TIMEOUT:-60}" \
      rpk topic trim-prefix "$topic" --offset "$hw" --partitions "$part" --no-confirm || rc=1
  done < <(topic_partitions "$pod" "$topic")
  return "$rc"
}

phase4_topics() {
  echo
  echo "=== PHASE 4: topics (capture, then trim or policy-trim) ==="
  if $SKIP_TOPICS; then
    skip_warning "TOPICS" \
      "No partition is trimmed. Every compacted topic — trim-eligible or\n    pure-compact alike — keeps its full latest-per-key contents, including\n    the Faust changelog topics phase 5 depends on being empty — if phase 5\n    also runs, it will republish the SAME pre-reset fleet from state that\n    was expected to be empty."
    return 0
  fi

  # Source-first by construction: resolve the live bridge/uplink graph and
  # reorder REDPANDA_PODS so phase4_capture_pass itself (below) walks every
  # source broker before its destination. Printed before the capture pass,
  # so the order a run used is in its own log.
  bridge_graph
  topo_sort_redpanda_pods

  phase4_capture_pass

  # --- mutation pass, in the SAME order the capture pass built
  # CAPTURED_TOPICS in. Re-deriving this order by re-listing topics from the
  # broker was rejected: calling broker_topics() a second time is exactly
  # the kind of second, driftable read this phase exists to avoid, on the
  # one call site where getting a DIFFERENT topic list than the capture
  # pass saw would silently desync a topic from its own capture file.
  #
  # No pre-mutation consumer quiesce or live-consumer gate runs here any
  # more. Both existed only to guard the DELETE this phase used to do (a
  # trim cannot make a topic disappear, so there was never anything for a
  # consumer to race against); see the header above and the DERIVED
  # quiesce intro comment below for where that machinery still lives.
  local pod topic pt part logstart hw failure="" failure_reason=""
  local red_check_done=false capfile cap_policy restore_cmd verify_failed
  local last_pod=""
  for pt in "${CAPTURED_TOPICS[@]}"; do
    pod="${pt%%|*}"
    topic="${pt#*|}"

    # Broker boundary: CAPTURED_TOPICS is grouped contiguously by pod (the
    # capture pass's own outer loop is `for pod in REDPANDA_PODS`, now in
    # source-first order), so a pod change here means the PREVIOUS pod's
    # topics are all done — its post-trim double read runs now — and the
    # NEW pod, if it is a bridge destination, must prove stable before its
    # first topic is touched. Both halt_reset internally; neither returns
    # on failure.
    if [ "$pod" != "$last_pod" ]; then
      [ -n "$last_pod" ] && assert_broker_fully_trimmed "$last_pod"
      assert_destination_stable "$pod"
      last_pod="$pod"
    fi

    if [ "${TOPIC_BUCKET[$pt]}" = "trim" ]; then
      if ! trim_topic_to_hw "$pod" "$topic"; then
        failure="$pt"
        failure_reason="trim failed on at least one partition — cleanup.policy was not touched"
        break
      fi
      continue
    fi

    # pure compact -> policy-trim in place: widen cleanup.policy to
    # compact,delete just long enough for trim-prefix to be legal, trim,
    # then alter straight back to the captured value. See the header above
    # for why this replaced delete-then-recreate: a recreated topic's
    # offsets restart at 0, and Restate's Kafka-ingress dedup (keyed on
    # consumer group/topic/partition + offset) would silently drop every
    # record below the old high watermark while the group kept reporting
    # Stable at ~0 lag. Trimming in place never moves an offset backward,
    # so that failure mode cannot occur here.
    capfile="$TOPIC_CAPTURE_DIR/$pod/$topic.cap"
    cap_policy="$(awk -F= '$1=="cleanup.policy"{print $2}' "$capfile")"
    if [ -z "$cap_policy" ]; then
      failure="$pt"
      failure_reason="capture file has no cleanup.policy row to restore to afterward — nothing altered yet"
      break
    fi
    restore_cmd="kubectl exec -n $NS $pod -c redpanda -- rpk topic alter-config $topic --set cleanup.policy=$cap_policy --no-confirm"

    # Step 1 — CHECKED against `rpk topic alter-config --help` on the local
    # compose broker (2026-10-06): like trim-prefix (JUDGMENT CALL 9),
    # alter-config also prompts for confirmation ("Use the flag
    # '--no-confirm' to avoid the confirmation prompt"), so it gets the
    # same --no-confirm fix. Nothing has been altered yet if this fails.
    if ! maybe_run "policy-trim $topic on $pod: widen cleanup.policy to compact,delete" \
      kubectl exec -n "$NS" "$pod" -c redpanda -- \
      timeout "${RPK_CMD_TIMEOUT:-60}" \
      rpk topic alter-config "$topic" --set cleanup.policy=compact,delete --no-confirm; then
      failure="$pt"
      failure_reason="alter-config to compact,delete failed — nothing altered; cleanup.policy is still $cap_policy"
      break
    fi

    # Step 2 — the exact trim action the trim-eligible bucket above uses,
    # reused rather than copied so the two buckets cannot drift apart.
    # cleanup.policy is now compact,delete and has NOT been restored yet.
    if ! trim_topic_to_hw "$pod" "$topic"; then
      failure="$pt"
      failure_reason="trim failed after widening cleanup.policy — restore it by hand: $restore_cmd"
      break
    fi

    # Step 3 — restore cleanup.policy to the CAPTURED value, read back out
    # of this topic's own capture file rather than hardcoded, in case a
    # future bucketing change ever lets anything other than plain "compact"
    # land in this branch.
    if ! maybe_run "policy-trim $topic on $pod: restore cleanup.policy to $cap_policy" \
      kubectl exec -n "$NS" "$pod" -c redpanda -- \
      timeout "${RPK_CMD_TIMEOUT:-60}" \
      rpk topic alter-config "$topic" --set cleanup.policy="$cap_policy" --no-confirm; then
      failure="$pt"
      failure_reason="restore of cleanup.policy to $cap_policy failed — topic is still compact,delete: $restore_cmd"
      break
    fi

    # Step 4 — verify from a fresh read. assert_topic_matches_capture covers
    # shape plus the whole dynamic set (cleanup.policy included); log-start
    # == hw is this phase's own promise (data gone, offsets preserved) and
    # is checked here directly because a config diff alone would never
    # catch it.
    if ! assert_topic_matches_capture "$pod" "$topic"; then
      failure="$pt"
      failure_reason="policy-trimmed topic did not match its capture after restoring cleanup.policy"
      break
    fi

    verify_failed=false
    while read -r part logstart hw; do
      [ -z "$part" ] && continue
      if [ "$logstart" != "$hw" ]; then
        echo "VERIFY FAILED: $topic on $pod partition $part: log-start=$logstart hw=$hw (expected equal)" >&2
        verify_failed=true
      fi
    done < <(topic_partitions "$pod" "$topic")
    if $verify_failed; then
      failure="$pt"
      failure_reason="log-start-offset did not equal high-watermark on at least one partition after policy-trim"
      break
    fi

    if $RED_CHECK_TOPIC_CONFIG && ! $red_check_done; then
      red_check_done=true
      if $DRY_RUN; then
        echo "  --red-check-topic-config: skipped under --dry-run — the probe has to" \
             "actually perturb cleanup.policy to test whether the assertion notices," \
             "and --dry-run means nothing here is allowed to actually mutate."
      else
        echo "  --red-check-topic-config: probing $topic on $pod"
        # cleanup.policy is the perturbation field because it is the one
        # dynamic key present on all policy-trim-eligible topics (the
        # changelogs carry nothing else), and compact,delete is a value the
        # broker accepts — so this tests the ASSERTION, not rpk's input
        # validation.
        maybe_run "red-check: perturb cleanup.policy on $topic ($pod)" \
          kubectl exec -n "$NS" "$pod" -c redpanda -- \
          timeout "${RPK_CMD_TIMEOUT:-60}" \
          rpk topic alter-config "$topic" --set cleanup.policy=compact,delete --no-confirm

        if assert_topic_matches_capture "$pod" "$topic"; then
          echo "RED-CHECK FAILED: the capture assertion did not notice a perturbed" >&2
          echo "cleanup.policy — it cannot be trusted to notice drift on a policy-trimmed" >&2
          echo "topic either." >&2
          # Restore runs on this path too — a real config change was just
          # made to the lab, and a failed red-check is not a reason to
          # leave it there.
          maybe_run "red-check: restore cleanup.policy on $topic ($pod)" \
            kubectl exec -n "$NS" "$pod" -c redpanda -- \
            timeout "${RPK_CMD_TIMEOUT:-60}" \
            rpk topic alter-config "$topic" --set cleanup.policy="$cap_policy" --no-confirm
          failure="$pt"
          failure_reason="red-check: assertion did not notice a perturbed cleanup.policy"
          break
        fi

        maybe_run "red-check: restore cleanup.policy on $topic ($pod)" \
          kubectl exec -n "$NS" "$pod" -c redpanda -- \
          timeout "${RPK_CMD_TIMEOUT:-60}" \
          rpk topic alter-config "$topic" --set cleanup.policy="$cap_policy" --no-confirm

        if ! assert_topic_matches_capture "$pod" "$topic"; then
          echo "RED-CHECK: restoring cleanup.policy did not repair the assertion —" >&2
          echo "the probe could not put $topic back the way it found it." >&2
          failure="$pt"
          failure_reason="red-check: could not restore cleanup.policy after perturbing it"
          break
        fi
        echo "  --red-check-topic-config: PASSED ($topic on $pod)"
      fi
    fi
  done

  # The LAST pod touched only gets its post-trim double read on the NEXT
  # pod's boundary crossing above, which never happens for the last one —
  # so it runs once more here, same as every earlier pod did.
  [ -z "$failure" ] && [ -n "$last_pod" ] && assert_broker_fully_trimmed "$last_pod"

  if [ -n "$failure" ]; then
    echo "PHASE 4 FAILED: ${failure#*|} on ${failure%%|*} — ${failure_reason:-did not match its captured configuration}." >&2
    echo "The capture directory holds the expected form for every topic this" >&2
    echo "run touched: $TOPIC_CAPTURE_DIR" >&2
    halt_reset "phase 4: ${failure#*|} on ${failure%%|*} did not match its captured configuration" \
      "${failure#*|}: ${failure_reason:-did not match its captured configuration}" \
      "captured configuration for every topic touched: $TOPIC_CAPTURE_DIR"
  fi
}

# ===========================================================================
# PHASE 5 — AGGREGATOR. Restart the Faust deployments ONLY NOW. Phase 4's
# changelog trim must already have happened: Faust replays its changelog
# topic on startup and restores every key from it, so restarting before the
# trim (or skipping the trim, --skip-topics/--skip-aggregator's own residue)
# produces a reset that LOOKS complete — stores empty, topics trimmed — while
# the regional rollup still carries the pre-reset fleet. This is the
# documented red-check (PREDICTION doc §5): --skip-aggregator exists
# specifically to make that failure mode visible on demand instead of
# hypothetical.
# ===========================================================================
phase5_aggregator() {
  echo
  echo "=== PHASE 5: aggregator (restart Faust, after topics are trimmed) ==="
  if $SKIP_AGGREGATOR; then
    skip_warning "AGGREGATOR" \
      "Faust deployments are NOT restarted. THIS IS THE DOCUMENTED RED-CHECK\n    (PREDICTION doc §5): expect every store to read 0 and every topic to\n    read trimmed, while the regional rollup (region-fleet-summary) keeps\n    serving the PRE-RESET asset_count from the in-memory Faust table that\n    was never asked to reload. If phase 8 does NOT show that residue, the\n    aggregator step was never load-bearing and this red-check has failed."
    return 0
  fi
  local d entry census_entry in_census
  for d in "${FAUST_DEPLOYS[@]}"; do
    entry="Deployment/$d"
    in_census=false
    for census_entry in "${CENSUS_QUIESCED[@]:-}"; do
      [ "$census_entry" = "$entry" ] && in_census=true
    done
    if $in_census; then
      # Writer-census-quiesced (phase 3b): scaling it back from 0 IS a
      # fresh start that reloads from the just-trimmed changelogs, which
      # is what the rollout restart below exists to force for every other
      # Faust deploy. A rollout restart on top of that would be redundant,
      # so this one is restored here, not in the loop below, and phase 9
      # skips it too (see phase9_restore_producers).
      echo "  $d: writer-census-quiesced, scaling back fresh instead of rollout restart"
      restore_derived_workload "$entry"
      continue
    fi
    maybe_run "rollout restart $d" kubectl rollout restart deploy -n "$NS" "$d"
  done
}

# ===========================================================================
# PHASE 6 — STORES. DELETE, never TRUNCATE (see header). audit_log is never
# touched — see EXCLUDED_TABLES and delete_table()'s own refusal.
# ===========================================================================
phase6_stores() {
  echo
  echo "=== PHASE 6: stores (DELETE FROM, never TRUNCATE, never audit_log) ==="
  if $SKIP_STORES; then
    skip_warning "STORES" \
      "No table is touched. Every projector table keeps its pre-reset rows —\n    telemetry_latest_state, asset_cm_state, etc. — and the UI will keep\n    showing the previous run's fleet regardless of what Restate or Kafka\n    now hold."
    return 0
  fi
  local pod table
  for pod in "${POSTGRES_PODS[@]}"; do
    for table in "${TABLES[@]}"; do
      if pg_table_exists "$pod" "$table"; then
        delete_table "$pod" "$table"
      else
        printf '  %-28s %-28s (table not present, skipped)\n' "$pod" "$table"
      fi
    done
  done
}

# ===========================================================================
# PHASE 7 — ELECTRIC. Delete the pods; there is no PVC and no mounted
# volume on electric-sync or any tier-electric-* (hub.yaml:99-120), so shape
# logs live only in the container filesystem. Deleting the pod IS the
# reset — clients rebuild shapes against a new handle on their next request.
# Run after stores are emptied (phase 6), so the shapes clients rebuild
# reflect the reset data, not the old fleet re-synced into a fresh shape.
# ===========================================================================
phase7_electric() {
  echo
  echo "=== PHASE 7: electric (delete pods — no volume, deletion is the reset) ==="
  if $SKIP_ELECTRIC; then
    skip_warning "ELECTRIC" \
      "Electric pods are not deleted, so their existing shape logs are not\n    discarded. A client holding an old shape handle can keep being served\n    an append-only log seeded from before the reset."
    return 0
  fi
  local pod
  for pod in "${ELECTRIC_PODS[@]}"; do
    maybe_run "delete electric pod $pod (discards its shape logs)" \
      kubectl delete pod -n "$NS" "$pod"
  done
}

# ===========================================================================
# PHASE 9 — RESTORE PRODUCERS. Scale back to what phase 2 recorded, never to
# an assumed 1 — a producer legitimately running more than one replica would
# come back short, quietly, and the shortfall would look like a healthy
# demo running at reduced load rather than an operator error.
#
# DELIBERATELY LAST. This used to run BEFORE the verify phase (old phase 8,
# then phase 9 verify) — which meant the "0 rows" / "0 keys" assertions were
# re-read AFTER the live feed was already back on, so a slow verify pass (or
# just an unlucky tick) could read genuine post-reset refill and PASS a check
# that had already stopped proving anything about the reset itself (the
# 2026-09-28 morning card's finding: "the check ran after the thing that
# invalidated it"). Producers now stay at zero all the way through phase 8
# and only come back here, the last mutation in the script. See phase 8's own
# header for the per-reading soundness argument this reordering rests on.
# ===========================================================================
phase9_restore_producers() {
  echo
  echo "=== PHASE 9: restore producers to their original replica counts ==="
  if $SKIP_PRODUCERS; then
    skip_warning "PRODUCERS (restore)" \
      "Nothing to restore — phase 2 never scaled anything down for this run."
    # Still the end of the scale-down window: phase 4 may have quiesced and
    # already restored the state consumers even with --skip-producers, and a
    # red-check's non-zero phase 8 must not read as an emergency.
    SCALES_RESTORED=true
    return 0
  fi
  local d rc
  for d in "${PRODUCER_DEPLOYS[@]}"; do
    rc="${ORIG_REPLICAS[$d]:-}"
    if [ -z "$rc" ]; then
      echo "ERROR: no recorded original replica count for $d — refusing to guess" >&2
      echo "       (this should be impossible unless phase 2 was skipped for" >&2
      echo "       this deployment specifically; check discovery output above)." >&2
      OVERALL_FAIL=1
      continue
    fi
    maybe_run "scale $d back to $rc" \
      kubectl scale deploy -n "$NS" "$d" --replicas="$rc"
  done
  # Every scale-down this run made has now been undone by its own phase, so a
  # non-zero exit from phase 8 — which is what a --skip-* red-check SUCCEEDING
  # looks like — must not print an emergency-rollback block over a cluster
  # whose replica counts are already correct.
  #
  # A restore failure here (the ERROR path above, OVERALL_FAIL=1) must still
  # make the script's own exit status non-zero even when phase 8 itself
  # PASSED cleanly — main exits on OVERALL_FAIL, not on phase 8's captured
  # return value alone, exactly so a producer left at zero cannot be mistaken
  # for a successful reset.

  # Writer census (Part 4): the Faust entries of CENSUS_QUIESCED were
  # already restored by phase 5 (scaled back fresh, not rollout-restarted
  # — see phase5_aggregator). Everything else the census quiesced —
  # non-Faust declared writers — is restored here, with the producers,
  # from the same QSTATE_REPLICAS capture phase 3b recorded before
  # scaling each one to 0.
  local census_entry is_faust_entry faust_name
  for census_entry in "${CENSUS_QUIESCED[@]:-}"; do
    [ -z "$census_entry" ] && continue
    is_faust_entry=false
    for faust_name in "${FAUST_DEPLOYS[@]}"; do
      [ "$census_entry" = "Deployment/$faust_name" ] && is_faust_entry=true
    done
    $is_faust_entry && continue
    echo "  $census_entry: restoring writer-census quiesce"
    restore_derived_workload "$census_entry"
  done

  SCALES_RESTORED=true
}

# ===========================================================================
# PHASE 10 — SUBSCRIPTION LIVENESS. Everything through phase 9 checks the
# broker's own side: topic configs, row counts, consumer-group state. None
# of that can see the one failure mode phase 4's header above exists to
# prevent — a topic whose offsets went backwards and now has Restate's own
# ingress dedup silently discarding records below the old high-water mark,
# while the consumer group itself still reads Stable at ~0 lag. The only
# way to see THAT is to ask Restate directly whether a subscription is
# actually producing invocations after T, which is what
# check-subscription-liveness.sh does; this phase just calls it and maps
# its exit code into OVERALL_FAIL. See its own header
# for the LIVE/STALLED/IDLE/UNMEASURED verdicts and exit codes (0 pass,
# 1 fail, 3 usage error).
#
# PHASE9_DONE_AT is recorded by the driver immediately after phase 9
# returns, RFC3339 UTC, second precision — not inside this function, so a
# future caller of this function alone (a red-check, say) cannot mistake
# some earlier timestamp for "when producers came back".
# ===========================================================================
phase10_subscription_liveness() {
  echo
  echo "=== PHASE 10: subscription liveness ==="
  local script wait rc=0
  script="$(dirname "$0")/check-subscription-liveness.sh"
  wait="${RESET_LIVENESS_WAIT:-300}"

  if [ ! -f "$script" ]; then
    echo "PHASE 10 FAILED: $script not found. A missing check is treated the" >&2
    echo "same as a failed one, never a silent skip — this script has no other" >&2
    echo "way of knowing whether Restate is actually consuming after the reset." >&2
    OVERALL_FAIL=1
    return 0
  fi

  if $DRY_RUN; then
    echo "-> check subscription liveness since $PHASE9_DONE_AT (wait up to ${wait}s)"
    printf '   [dry-run] would run:'
    printf ' %q' bash "$script" --since "$PHASE9_DONE_AT" --wait "$wait"
    printf '\n'
    return 0
  fi

  local out
  out="$(bash "$script" --since "$PHASE9_DONE_AT" --wait "$wait" 2>&1)" || rc=$?
  echo "$out"

  case "$rc" in
    0) : ;;
    1)
      OVERALL_FAIL=1
      echo "PHASE 10 FAILED: liveness check found stalled or unmeasured" >&2
      echo "subscription(s) since $PHASE9_DONE_AT:" >&2
      printf '%s\n' "$out" | grep -E '^(STALLED|UNMAPPED|UNMEASURED) ' >&2 || true
      ;;
    3)
      OVERALL_FAIL=1
      echo "PHASE 10 FAILED: check-subscription-liveness.sh exited 3 (usage" >&2
      echo "error) — that is a bug in how this script calls it, not a reading" >&2
      echo "about the cluster." >&2
      ;;
    *)
      OVERALL_FAIL=1
      echo "PHASE 10 FAILED: check-subscription-liveness.sh exited $rc" \
           "(unrecognized)." >&2
      ;;
  esac
  return 0
}

# ===========================================================================
# PHASE 8 — ZERO ASSERTION. Re-read every §4 reading and print PREDICTED vs
# ACTUAL, PASS/FAIL per line, WHILE STILL QUIESCED — producers have been at
# zero since phase 2 and do not come back until phase 9, strictly AFTER this
# phase returns. Exits non-zero if anything fails.
#
# THIS REPLACES THE OLD PHASE 9 (verify), WHICH RAN AFTER PRODUCERS WERE
# RESTORED (old phase 8). The 2026-09-28 morning card named the defect
# precisely: reading "0 rows" / "0 keys" at a moment when the live feed is
# already back on proves nothing — nothing was PREVENTING refill at the
# instant of the read, so a PASS there is not a round-trip proof, it is a
# race this script happened to win. Moving the read to before producers come
# back does not change what each reading measures; it changes whether
# anything could have refilled it by the time the reading happens.
#
# PER-READING SOUNDNESS, decided by asking one question of each: with
# producers at zero (phase 2) and topics/restate/stores/electric already
# reset (phases 3-7), is anything STILL RUNNING between this phase and each
# reading's own reset action that could put the count back above zero?
#
#   verify_stores (incl. audit_log UNCHANGED)
#       VALID. Every store table's only writer is a Kafka/Restate consumer
#       (the projector family — projector-/tier-projector-/redpanda-connect-
#       /etc., restored at the end of phase 4 and running throughout phases
#       5-7), and none of those consumers has anything left to consume:
#       input topics were trimmed empty in phase 4, Restate state
#       was cleared in phase 3, and the producers that would put new
#       messages on those topics are the one thing phase 2 already turned
#       off and phase 9 has not yet turned back on.
#       CAVEAT, not a reason to move or drop this reading: region_fleet_
#       summary (it is in TABLES, so it gets the same blanket "0 rows"
#       prediction as every other store) is written by the Faust
#       aggregator's UNCONDITIONAL 30s @app.timer (aggregator_app.py:160,
#       see verify_aggregator below), which fires on a clock, not on input
#       arrival, and has been running since phase 5. A genuinely correct
#       reset can show a fresh row here purely from that timer and read as a
#       FALSE FAIL against this reading's blanket zero prediction. This is
#       not introduced by this reorder — phase 5 already ran before this
#       reading in the old order too — and fixing it (excluding one table
#       from a shared per-table loop, or making this check freshness-aware
#       the way verify_aggregator already is) is a separate, larger change.
#       Flagged here, not silently patched.
#
#   verify_topics
#       VALID, same reasoning and the SAME caveat: the region-fleet-summary
#       TOPIC (not just its table) is the aggregator's own output topic, so
#       its high watermark can advance past log_start after phase 4's trim
#       purely from the 30s timer, independent of producers or quiescence.
#       Every other topic (carrier topics and changelogs the aggregator does
#       not itself emit into) has no writer left running once producers are
#       off, so log_start == high_watermark holds for them.
#
#   verify_restate_once "immediate" and "after Nx cadence"
#       VALID, and this pair is the actual bug fix. In the old order both
#       reads ran AFTER phase 8 (old) restored producers — if a producer's
#       traffic reaches Restate directly (derive_quiesce_set item 2: some
#       Restate runtimes subscribe straight to a carrier topic), a resumed
#       producer could feed a NEW object key into Restate during or before
#       either read, and "0 object keys AND 0 state rows" would be measuring
#       fresh, legitimate data, not residue. With producers still at zero
#       for both reads, the only thing either read can possibly observe is
#       Restate's OWN re-arm timer — the one failure mode this pair exists
#       to catch (asset_logistics.py:477) — never producer refill.
#
#   verify_aggregator
#       VALID, and independent of quiescence by construction: the predicted
#       fresh row is emitted by Faust's 30s timer, "not by input arrival"
#       (see the JUDGMENT CALL 8 comment on this function), so it needs
#       Faust running (phase 5) and real time to pass — nothing from
#       producers. Reading it BEFORE producers return is actually SAFER than
#       the old order: in the old order, real telemetry could already be
#       flowing back in during this function's up-to-90s poll window, and a
#       correctly-working aggregator could pick up a fresh row carrying a
#       real asset_count instead of 0 — a FALSE FAIL for a reset that worked.
#
#   verify_electric
#       VALID. Scoped to ELECTRIC_SHAPE_TABLE (default telemetry_latest_
#       state, see electric_shape()) — a table populated only by producer-
#       driven telemetry ingestion, never by the aggregator's timer, so it
#       carries none of the region_fleet_summary caveat above. With
#       producers off, nothing writes it between phase 7's pod delete and
#       this read.
#
# VERDICT: all six readings are KEPT here, unmoved. The defect was entirely
# about WHEN this phase ran relative to producer restore, not about any
# individual reading being invalid even while quiesced — with one standing
# exception (region_fleet_summary the table, region-fleet-summary the topic)
# that quiescing producers cannot fix, because its writer was never a
# producer in the first place.
#
# Skip flags do NOT soften this phase. A --skip-aggregator run is SUPPOSED
# to fail its aggregator line — that failure is the red-check succeeding,
# not the script malfunctioning (PREDICTION doc §5).
#
# --verify-only runs THIS phase alone, against whatever the cluster already
# is, and does nothing else (see the flag's own usage text and `main`,
# below). On a live, unreset cluster every populated store and topic reads
# non-zero against this phase's "predicted 0" lines — that FAIL is
# --verify-only's red check: if it does not fail against a live, unreset
# deployment, the check is not checking anything.
#
# Restate is re-checked TWICE: immediately, and again after one full
# re-arm cadence. A check taken immediately after `state clear` cannot see
# the only failure mode that matters here — the object re-arming on its own
# next tick — because that tick has not happened yet.
#
# THE CADENCE IS MEASURED, NOT CARRIED (ROWS doc, call 2). An earlier revision
# inferred 60s from a store's observed update interval. Read off a scheduled
# invocation directly, the real re-arm is 30s:
#
#   scheduled_at        2026-09-27T04:09:18.650Z
#   scheduled_start_at  2026-09-27T04:09:48.649Z     -> 30.0s
#
# i.e. the inference was 2x the truth. Here the error was in the safe
# direction by luck; the same mistake the other way is the false-FROZEN bug
# found earlier tonight — a check sampling faster than the thing it samples.
# So measure_restate_cadence() reads the delta from the cluster and the wait
# is floored at 2x it, for the same reason check-advancing.sh needs an
# interval floor: one period is not enough to distinguish "did not re-arm"
# from "has not re-armed yet".
#
# RESTATE_CADENCE_SECONDS still overrides, and is used as the fallback when
# there is no scheduled invocation to measure (e.g. a cluster already at 0).
# ===========================================================================
RESTATE_CADENCE_SECONDS="${RESTATE_CADENCE_SECONDS:-30}"
AGGREGATOR_POLL_TIMEOUT_SECONDS="${AGGREGATOR_POLL_TIMEOUT_SECONDS:-90}"
AGGREGATOR_POLL_INTERVAL_SECONDS="${AGGREGATOR_POLL_INTERVAL_SECONDS:-10}"

report() {
  local component="$1" predicted="$2" actual="$3" status
  if [ "$predicted" = "$actual" ]; then status=PASS; else status=FAIL; OVERALL_FAIL=1; fi
  printf '  %-55s predicted=%-14s actual=%-14s %s\n' "$component" "$predicted" "$actual" "$status"
}

verify_stores() {
  echo "--- stores: predicted 0 rows (audit_log predicted UNCHANGED) ---"
  local pod table cnt base
  for pod in "${POSTGRES_PODS[@]}"; do
    for table in "${TABLES[@]}"; do
      if pg_table_exists "$pod" "$table"; then
        if is_heartbeat_table "$table"; then
          cnt="$(pg_query "$pod" "SELECT count(*) FROM $table WHERE updated_at < '$RUN_STARTED_AT'::timestamptz" || true)"
          report "stores $pod/$table (heartbeat, rows older than boundary)" "0" "${cnt:-UNMEASURED}"
        else
          cnt="$(pg_count "$pod" "$table")"
          report "stores $pod/$table" "0" "$cnt"
        fi
      fi
    done
    if pg_table_exists "$pod" "audit_log"; then
      cnt="$(pg_count "$pod" "audit_log")"
      base="${BASE_AUDIT_COUNT[$pod]:-}"
      if [ -z "$base" ]; then
        printf '  %-55s no phase-1 baseline recorded (ran with --verify-only?) actual=%s\n' \
          "stores $pod/audit_log (UNCHANGED?)" "$cnt"
      else
        report "stores $pod/audit_log (UNCHANGED)" "$base" "$cnt"
      fi
    fi
  done
}

verify_topics() {
  echo "--- topics: predicted log_start == high_watermark on every partition ---"
  local pod topic part logstart hw
  for pod in "${REDPANDA_PODS[@]}"; do
    while read -r topic; do
      [ -z "$topic" ] && continue
      is_internal_topic "$topic" && continue
      while read -r part logstart hw; do
        [ -z "$part" ] && continue
        report "topics $pod/$topic/p$part" "$hw" "$logstart"
      done < <(topic_partitions "$pod" "$topic")
    done < <(broker_topics "$pod")
  done
}

verify_restate_once() {
  local label="$1" pod keys rows sched
  echo "--- restate ($label): predicted 0 object keys AND 0 state rows ---"
  for pod in "${RESTATE_PODS[@]}"; do
    # Both numbers asserted. On the lab these read 14 and 84 before a reset, so
    # a predicted zero that names only one of them is only half a check.
    keys="$(restate_count "$pod" "select count(distinct service_key) as n from state")"
    rows="$(restate_count "$pod" "select count(*) as n from state")"
    sched="$(restate_count "$pod" "select count(*) as n from sys_invocation where status = 'scheduled'")"
    report "restate $pod object-keys ($label)" "0" "${keys:-0}"
    report "restate $pod state-rows ($label)" "0" "${rows:-0}"
    printf '  %-55s scheduled-invocations=%s (informational — the object re-arming\n' \
      "restate $pod ($label)" "${sched:-0}"
    printf '  %-55s   shows up as scheduled-invocations>0 alongside state-rows>0)\n' ""
  done
}
verify_aggregator() {
  echo "--- aggregator: predicted a FRESH rollup arrives carrying asset_count=0 ---"
  # ==========================================================================
  # JUDGMENT CALL 8 — found by the dry-run, and it invalidated the original
  # check outright rather than merely breaking it.
  #
  # The original polled `rpk topic consume region-fleet-summary` and grepped the
  # value for `"asset_count": N`. That can never match: region-fleet-summary
  # carries PROTOBUF (openddil/regional/v1/region_fleet_summary.proto), not
  # JSON. A live record off the lab is 93 bytes of wire format —
  #
  #   0a 0b "region-east"   field 1 (region_id)
  #   10 05                 field 2 (nominal)         = 5
  #   18 01                 field 3 (degraded)        = 1
  #   30 06                 field 6 (asset_count)     = 6
  #   3a 0c ...             field 7 (observed_at)
  #
  # — so the grep found nothing, `count` stayed empty, and the poll ran its full
  # window and then declared UNMEASURED. The check would have reported a FAIL
  # forever, on a correct reset, for a reason that had nothing to do with the
  # aggregator. It was unfalsifiable, which is worse than absent.
  #
  # Rather than hand-roll a protobuf field walker in bash (wrong tool, and it
  # would have to skip length-delimited fields correctly to stay right as the
  # message grows), this reads the value where the REAL consumer has already
  # decoded it: the projector UPSERTs each record into `region_fleet_summary`,
  # whose `asset_count` column is that same field 6. That is a strictly stronger
  # assertion than the topic read — it proves topic -> projector -> table, not
  # just that bytes exist on a partition.
  #
  # FRESHNESS IS THE WHOLE TRICK. Phase 6 DELETEs this table, so "0 rows" alone
  # proves only that the delete ran, not that the aggregator came back. The
  # assertion is therefore: a row whose `updated_at` is later than this run's
  # start exists, AND its asset_count is 0. That distinguishes the three cases
  # the old check collapsed into one — no rollup arrived (UNMEASURED), a rollup
  # arrived carrying the pre-reset count (FAIL, the §5 red-check), and a rollup
  # arrived carrying 0 (PASS).
  #
  # THE WINDOW STAYS >2x THE EMIT PERIOD (call 3). The rollup is emitted by a 30s
  # @app.timer (aggregator_app.py:160), not by input arrival, so 30s is its
  # shortest possible advance interval by construction. The 90s default spans at
  # least two emits. Do not lower it below 60s: sampling a 30s emitter over 10s
  # is exactly how check-advancing.sh produced a false FROZEN.
  # ==========================================================================
  local pod fresh maxcount elapsed=0
  pod="$(printf '%s\n' "${POSTGRES_PODS[@]}" | grep -E -- '-region-east(-[0-9]+)?$' | head -1 || true)"
  if [ -z "$pod" ]; then
    # Fall back to the hub, which also carries the projection.
    pod="$(printf '%s\n' "${POSTGRES_PODS[@]}" | grep -E -- 'postgres-hq(-[0-9]+)?$' | head -1 || true)"
  fi
  if [ -z "$pod" ]; then
    echo "  no region-east or hq postgres pod discovered — cannot read region_fleet_summary"
    OVERALL_FAIL=1
    return
  fi
  echo "  reading the decoded projection on $pod (rows newer than $RUN_STARTED_AT)"
  while [ "$elapsed" -lt "$AGGREGATOR_POLL_TIMEOUT_SECONDS" ]; do
    fresh="$(pg_query "$pod" \
      "SELECT count(*) FROM region_fleet_summary WHERE updated_at > '${RUN_STARTED_AT}'::timestamptz" || true)"
    if [ -n "$fresh" ] && [ "$fresh" != "0" ]; then
      maxcount="$(pg_query "$pod" \
        "SELECT coalesce(max(asset_count),-1) FROM region_fleet_summary WHERE updated_at > '${RUN_STARTED_AT}'::timestamptz" || true)"
      echo "  $fresh fresh rollup row(s) landed since the run started"
      report "aggregator region_fleet_summary asset_count (max over fresh rows)" \
        "0" "${maxcount:--1}"
      return
    fi
    sleep "$AGGREGATOR_POLL_INTERVAL_SECONDS"
    elapsed=$((elapsed + AGGREGATOR_POLL_INTERVAL_SECONDS))
  done
  printf '  %-55s PREDICTED=0  ACTUAL=UNMEASURED  -> FAIL\n' \
    "aggregator region_fleet_summary asset_count"
  echo "     no region_fleet_summary row with updated_at > ${RUN_STARTED_AT} appeared within" \
       "${AGGREGATOR_POLL_TIMEOUT_SECONDS}s."
  echo "     UNMEASURED, not zero: the prediction is 'a rollup arrives and carries 0', and an"
  echo "     empty table does not verify it — phase 6 emptied it. Either the aggregator did not"
  echo "     come back, the projector is not consuming, or the window was shorter than the 30s"
  echo "     emit period."
  OVERALL_FAIL=1
}

verify_electric() {
  echo "--- electric: predicted a NEW shape handle and 0 rows per instance ---"
  # RESOLVED BY MEASUREMENT (ROWS doc, call 4). An earlier revision substituted
  # a weaker "is the pod gone" check because the port and table were unknown.
  # Measured: the shape API answers, returns an `electric-handle` header and a
  # JSON array body, `curl` is present in the pod, and — the reason a hardcoded
  # port would have read one instance in four — THE PORT DIFFERS PER INSTANCE:
  # 5133 on the hub, 3000 on all three tiers. So the port is read from each
  # pod's own container spec, never assumed.
  #
  # This is the real §4 check: a new handle proves the shape log was discarded,
  # and 0 rows proves the client that re-creates it sees an empty fleet.
  local pod inst base port handle rows
  ELECTRIC_HANDLE_UNCHANGED=0
  ELECTRIC_ROWS_NONZERO=0
  for pod in "${ELECTRIC_PODS[@]}"; do
    inst="$(electric_instance "$pod")"
    if ! kubectl get pod -n "$NS" "$pod" -o name >/dev/null 2>&1; then
      # The pod name changed, which is itself the mechanism working. Re-resolve
      # by instance so the shape can still be read.
      pod="$(kubectl get pods -n "$NS" --no-headers -o custom-columns='N:.metadata.name' 2>/dev/null \
        | while read -r n; do [ "$(electric_instance "$n")" = "$inst" ] && echo "$n"; done | head -1 || true)"
      if [ -z "$pod" ]; then
        printf '  %-55s PREDICTED=new-handle  ACTUAL=UNMEASURED (no pod for instance) -> FAIL\n' "electric $inst handle"
        OVERALL_FAIL=1
        continue
      fi
    fi
    port="$(electric_port "$pod")"
    handle="$(electric_shape_handle "$pod" "$port")"
    rows="$(electric_shape_rows "$pod" "$port")"
    if [ -z "$handle" ]; then
      printf '  %-55s PREDICTED=new-handle  ACTUAL=UNMEASURED -> FAIL\n' "electric $inst handle"
      echo "     shape endpoint on port ${port:-?} did not answer. UNMEASURED, not zero."
      OVERALL_FAIL=1
      continue
    fi
    base="${BASE_ELECTRIC_HANDLE[$inst]:-}"
    if [ -z "$base" ]; then
      # No baseline means no comparison: "differs from nothing" is not a pass.
      printf '  %-55s PREDICTED=new-handle  ACTUAL=UNMEASURED (no baseline handle) -> FAIL\n' "electric $inst handle"
      OVERALL_FAIL=1
    elif [ "$handle" = "$base" ]; then
      # An unchanged handle means the shape log survived, which is the
      # failure this phase exists to catch.
      ELECTRIC_HANDLE_UNCHANGED=$((ELECTRIC_HANDLE_UNCHANGED + 1))
      report "electric $inst shape-handle" "new-handle" "UNCHANGED"
    else
      report "electric $inst shape-handle" "new-handle" "new-handle"
    fi
    printf '     handle before=%s after=%s\n' "${base:-none}" "$handle"
    # Empty is UNMEASURED, not 0: an unreadable shape must not pass as empty.
    [ -n "$rows" ] && [ "$rows" != 0 ] && ELECTRIC_ROWS_NONZERO=$((ELECTRIC_ROWS_NONZERO + 1))
    report "electric $inst shape-rows" "0" "${rows:-UNMEASURED}"
  done
}

# ---------------------------------------------------------------------------
# run_census_only — work item 6's --census-only. Runs the REAL capture pass
# (a read, so it exercises the same code paths a real run's phase 4 would),
# then prints the raw broker census, Restate's own subscription list, the
# derived quiesce set with its provenance, and the live-consumer assertion
# result against the pure-compact (delete-eligible) bucket. MUTATES
# NOTHING: every call this function makes is a read — no scale, no patch,
# no topic touched (acceptance check 5).
# ---------------------------------------------------------------------------
run_census_only() {
  echo "=== --census-only: broker consumer census (read-only) ==="
  local pod tag f2 f3 f4 f5
  for pod in "${REDPANDA_PODS[@]}"; do
    echo "-- $pod --"
    while IFS=$'\t' read -r tag f2 f3 f4 f5; do
      [ -z "$tag" ] && continue
      [ "$tag" = "MEMBERS" ] && printf '  group=%-40s members=%-4s state=%-10s hosts=%s\n' \
        "$f2" "$f3" "$f4" "${f5:-none}"
    done < <(census_groups "$pod")
  done

  echo
  echo "=== --census-only: restate subscriptions (read-only) ==="
  local rpod rtopic rgid rowner
  while IFS=$'\t' read -r rpod rtopic rgid rowner; do
    [ -z "$rpod" ] && continue
    printf '  pod=%-40s topic=%-40s group.id=%-30s owner=%s\n' "$rpod" "$rtopic" "${rgid:-?}" "$rowner"
  done < <(restate_subscriptions)

  echo
  echo "=== --census-only: capture pass (read-only) ==="
  phase4_capture_pass

  echo
  echo "=== --census-only: pre-flight (consumer ownership) ==="
  local pf_rc=0
  assert_consumers_declared "${CAPTURED_TOPICS[@]}" || pf_rc=$?

  echo
  echo "=== --census-only: derived quiesce set, with provenance ==="
  local -a derived=()
  mapfile -t derived < <(derive_quiesce_set "${CAPTURED_TOPICS[@]}")
  echo "derived quiesce set: ${#derived[@]} workload(s)"
  local w
  for w in "${derived[@]}"; do
    printf '  %s\n' "$w"
  done

  echo
  echo "=== --census-only: live-consumer assertion (against the pure-compact/policy-trim bucket) ==="
  local -a policytrim_targets=()
  local dpt
  for dpt in "${CAPTURED_TOPICS[@]}"; do
    [ "${TOPIC_BUCKET[$dpt]}" = "policy-trim" ] && policytrim_targets+=("$dpt")
  done
  if assert_no_live_consumers "${policytrim_targets[@]}"; then
    echo "ASSERTION: PASS — zero live members on any of the ${#policytrim_targets[@]} pure-compact topic(s)."
  else
    echo "ASSERTION: FAIL — see LIVE CONSUMER lines above."
    echo "NOTE: this is expected on a live, unquiesced cluster — --census-only" \
         "mutates nothing, so nothing has been scaled down. A FAIL here says" \
         "which consumers are live RIGHT NOW; it is informational only — phase" \
         "4 itself no longer quiesces or gates on this, since policy-trim never" \
         "makes a topic disappear for a live consumer to race against."
  fi

  # Exit status reflects the pre-flight (undeclared-consumer) read, not the
  # live-consumer assertion just above — that one is EXPECTED to fail on an
  # unquiesced cluster (see the NOTE above) and must not make --census-only
  # itself look broken. The pre-flight has no such "expected to fail" case:
  # it is the same read a real run gates on.
  return "$pf_rc"
}

# ---------------------------------------------------------------------------
# run_red_check_quiesce — work item 6's --red-check-quiesce. Proves the
# quiesce/restore path in quiesce_derived_workload/restore_derived_workload
# handles EVERY kind in work item 3's table — including DaemonSet — without
# risking a single topic delete: this function never calls `rpk topic
# delete` or `rpk topic create`.
#
# Fact 6 measured ZERO DaemonSets in the namespace today, so the DaemonSet
# branch has nothing real to exercise it against. This red-check creates
# one throwaway DaemonSet of its own for exactly that reason — its exact
# shape (name, image, tolerations) is this red-check's own choice, not
# something the spec dictates, since nothing about it needs to resemble a
# real workload: it only needs to exist long enough for merge-patch-then-
# JSON-patch-restore to run against it. `registry.k8s.io/pause:3.9` is used
# because it is the smallest image already trusted by every Kubernetes
# control plane (it is the pod-infra-container image), so this red-check
# pulls nothing project-specific. Deleted again before this function
# returns, success or failure path alike.
# ---------------------------------------------------------------------------
REDCHECK_DS_NAME="${RELEASE}-redcheck-quiesce-probe"

run_red_check_quiesce() {
  echo "=== --red-check-quiesce: capture (read-only) ==="
  phase4_capture_pass

  echo
  echo "=== --red-check-quiesce: pre-flight (consumer ownership) ==="
  if ! assert_consumers_declared "${CAPTURED_TOPICS[@]}"; then
    echo "--red-check-quiesce REFUSED: an undeclared live consumer exists on a" >&2
    echo "target topic (see UNDECLARED CONSUMER lines above). A real run would" >&2
    echo "abort here too, before any quiesce — this red-check does the same." >&2
    return 1
  fi

  echo
  echo "=== --red-check-quiesce: creating throwaway DaemonSet ($REDCHECK_DS_NAME) ==="
  echo "    (fact 6: zero DaemonSets exist in $NS today — this is the only way" \
       "to exercise the DaemonSet branch of quiesce/restore short of waiting" \
       "for one to be deployed for real)"
  maybe_run "create red-check DaemonSet $REDCHECK_DS_NAME" \
    bash -c "kubectl apply -n '$NS' -f - <<'DSEOF'
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $REDCHECK_DS_NAME
  labels:
    app.kubernetes.io/managed-by: reset-scenario-redcheck
spec:
  selector:
    matchLabels:
      app: $REDCHECK_DS_NAME
  template:
    metadata:
      labels:
        app: $REDCHECK_DS_NAME
    spec:
      tolerations:
        - operator: Exists
      containers:
        - name: pause
          image: registry.k8s.io/pause:3.9
          resources:
            requests:
              cpu: 5m
              memory: 8Mi
DSEOF"

  local -a derived=()
  if ! $DRY_RUN; then
    mapfile -t derived < <(derive_quiesce_set "${CAPTURED_TOPICS[@]}")
    derived+=("DaemonSet/$REDCHECK_DS_NAME")
    # Producers too — not because they are in the derived set (they are
    # deliberately deduped OUT of it, phase 2 owns them), but because phase 4's
    # real precondition is that phase 2 has ALREADY run. Without this the
    # red-check asserts against a cluster the real run never sees:
    # openddil-logistics-sim keeps consuming telemetry-latest-state, the
    # assertion fails on it forever, and the red-check can never pass while
    # reporting nothing wrong with the quiesce it is supposed to be testing.
    # Measured 2026-09-27: that is exactly what it did.
    local p
    for p in "${PRODUCER_DEPLOYS[@]}"; do derived+=("Deployment/$p"); done
  fi
  echo
  echo "=== --red-check-quiesce: derived set (+ the throwaway DaemonSet): ${#derived[@]} workload(s) ==="
  local w
  for w in "${derived[@]}"; do printf '  %s\n' "$w"; done

  echo
  echo "=== --red-check-quiesce: quiescing ==="
  quiesce_workload_set "${derived[@]}"

  echo
  echo "=== --red-check-quiesce: live-consumer assertion (against the pure-compact/policy-trim bucket) ==="
  local -a policytrim_targets=()
  local dpt assert_rc=0
  for dpt in "${CAPTURED_TOPICS[@]}"; do
    [ "${TOPIC_BUCKET[$dpt]}" = "policy-trim" ] && policytrim_targets+=("$dpt")
  done
  assert_no_live_consumers "${policytrim_targets[@]}" || assert_rc=$?

  echo
  echo "=== --red-check-quiesce: restoring ==="
  restore_derived_set

  echo
  echo "=== --red-check-quiesce: deleting throwaway DaemonSet ($REDCHECK_DS_NAME) ==="
  maybe_run "delete red-check DaemonSet $REDCHECK_DS_NAME" \
    kubectl delete ds -n "$NS" "$REDCHECK_DS_NAME" --ignore-not-found

  echo
  if [ "$assert_rc" -eq 0 ]; then
    echo "ASSERTION: PASS — zero live members on any of the ${#policytrim_targets[@]} pure-compact topic(s), post-quiesce."
  else
    echo "ASSERTION: FAIL — see LIVE CONSUMER lines above. This is a live-cluster" >&2
    echo "reading, not a defect in this red-check: --red-check-quiesce only proves" >&2
    echo "the quiesce/restore machinery still works for whatever calls it; phase 4" >&2
    echo "itself no longer gates on this reading (policy-trim never deletes a" >&2
    echo "topic, so there is nothing left for a live consumer to race against)." >&2
  fi
  echo "--red-check-quiesce: TOUCHED NO TOPIC. Confirm the restore with your own" \
       "'kubectl get deploy,sts -n $NS' diff before/after (acceptance check 6)."
}

phase8_zero() {
  echo
  echo "=== PHASE 8: zero assertion (PREDICTED vs ACTUAL, while still quiesced) ==="

  if $SKIP_STORES; then
    skip_warning "STORES (verify)" "stores were not reset; the lines below are expected to FAIL."
  fi
  verify_stores

  if $SKIP_TOPICS; then
    skip_warning "TOPICS (verify)" "topics were not trimmed; the lines below are expected to FAIL."
  fi
  verify_topics

  if $SKIP_RESTATE; then
    skip_warning "RESTATE (verify)" "restate was not reset; the lines below are expected to FAIL."
  fi
  verify_restate_once "immediate"

  if $SKIP_AGGREGATOR; then
    skip_warning "AGGREGATOR (verify)" \
      "Faust was not restarted; this line is EXPECTED to FAIL — that is the red-check (PREDICTION doc §5)."
  fi
  verify_aggregator

  if $SKIP_ELECTRIC; then
    skip_warning "ELECTRIC (verify)" "electric pods were not deleted; the line below is expected to FAIL."
  fi
  verify_electric

  if ! $SKIP_RESTATE; then
    echo
    local wait_s
    wait_s=$(( $(measure_restate_cadence) * 2 ))
    echo "waiting ${wait_s}s (2x the measured re-arm cadence) before re-checking" \
         "restate — a check run immediately after 'state clear' cannot see the timer" \
         "re-arming itself, because that tick has not fired yet, and ONE period" \
         "cannot tell 'did not re-arm' from 'has not re-armed yet'"
    sleep "$wait_s"
    verify_restate_once "after ${wait_s}s (2x cadence)"
  fi

  echo
  if [ "$OVERALL_FAIL" -eq 0 ]; then
    echo "reset-scenario: ALL VERIFIED READINGS MATCH PREDICTION"
  else
    echo "reset-scenario: AT LEAST ONE READING DID NOT MATCH PREDICTION" >&2
    echo "  If you passed a --skip-* flag, some FAILs above are the expected" >&2
    echo "  residue that flag documents, not a bug in this run." >&2
  fi
  return "$OVERALL_FAIL"
}

# ---------------------------------------------------------------------------
# HALT WITH THE STATE NAMED. A safety refusal anywhere in a full reset stops
# the WHOLE reset: no later phase runs. The one EXIT trap (on_reset_exit)
# then says where it stopped, which phases ran and so STAY applied, which did
# not run, and what the refusal measured, before handing over to
# emergency_restore_scales for the scale-downs.
#
# Why not refuse-and-continue: on 2026-10-01 phase 3 refused one Restate
# instance and carried on. Every later phase then emptied stores and topics
# that the uncleared instance refilled while everything else was quiesced: a
# reset that ran to the end and reset nothing. A partial reset is worse than
# none, because it looks like one.
#
# halt_reset REASON [STATE-LINE...] records the refusal and exits 2. Exit 2
# is distinct from phase 8's exit 1 (a completed run whose zero assertion
# failed). A phase that stops with a bare `return 1` (set -e) also reaches
# the trap, so it is reported as a halt too, with its own ERROR lines above
# as the reason.
# ---------------------------------------------------------------------------
RESET_RUN=false
RUN_COMPLETED=false
CURRENT_PHASE=""
PHASES_DONE=()
HALT_REASON=""
HALT_DETAIL=()
ALL_PHASES=("1 baseline" "pre-flight" "2 quiesce" "3 restate" "3b writer census" "4 topics" "5 aggregator" "6 stores" "7 electric" "8 zero assertion" "9 restore" "10 subscription liveness")
PHASE9_DONE_AT=""

halt_reset() {
  HALT_REASON="$1"; shift
  HALT_DETAIL=("$@")
  echo "HALT: $HALT_REASON" >&2
  exit 2
}

# run_phase "N name" FUNCTION. Called bare, so set -e still aborts on a
# phase's `return 1` (inside an `if` or `||` it would not).
run_phase() {
  CURRENT_PHASE="$1"
  "$2"
  PHASES_DONE+=("$1")
  CURRENT_PHASE=""
}

on_reset_exit() {
  local rc=$? p d done_p line
  trap - EXIT
  if [ "$rc" -ne 0 ] && ! $RUN_COMPLETED; then
    local -a not_run=()
    for p in "${ALL_PHASES[@]}"; do
      [ "$p" = "$CURRENT_PHASE" ] && continue
      done_p=false
      for d in "${PHASES_DONE[@]}"; do [ "$d" = "$p" ] && done_p=true; done
      $done_p || not_run+=("$p")
    done
    {
      echo
      echo "=================== RESET HALTED (exit $rc) ==================="
      if $DRY_RUN; then echo "  [dry-run] this run mutated nothing"; fi
      echo "  reason:    ${HALT_REASON:-a phase stopped non-zero; its ERROR/ABORTED lines are above}"
      echo "  halted in: ${CURRENT_PHASE:-between phases}"
      echo "  completed: ${PHASES_DONE[*]:-none}  (their mutations STAY made)"
      echo "  not run:   ${not_run[*]:-none}"
      for line in "${HALT_DETAIL[@]}"; do
        echo "  state:     $line"
      done
      if $SCALES_ARMED && ! $SCALES_RESTORED; then
        echo "  workloads: scaled-down workloads are restored next (below)"
      else
        echo "  workloads: none left scaled down by this run"
      fi
      echo "  THIS CLUSTER HAS NOT BEEN RESET. Fix the cause, then re-run the whole reset."
      echo "================================================================"
    } >&2
  fi
  emergency_restore_scales "$rc"
  exit "$rc"
}

# Test-only escape hatch (scripts/tests/test_reset_ownership.sh sources this
# file to reuse its function definitions against stubbed kubectl/census_groups/
# restate_subscriptions output). RESET_SCENARIO_SOURCE_ONLY is never set by
# this script itself, only by a test harness that sets it before sourcing —
# a normal invocation never reaches this branch. Stops before the cluster
# guard has any effect on the outcome (it already ran, harmlessly, above:
# see the matching guard around the require-cluster.sh source line) and
# before main ever calls a phase.
if [ "${RESET_SCENARIO_SOURCE_ONLY:-}" = 1 ]; then
  return 0
fi

# ===========================================================================
# main
# ===========================================================================
if $BASELINE_ONLY; then
  phase1_baseline
  exit 0
fi

if $CENSUS_ONLY; then
  run_census_only
  exit $?
fi

if $WRITER_CENSUS_ONLY; then
  run_writer_census_only
  exit $?
fi

if $RED_CHECK_QUIESCE; then
  run_red_check_quiesce
  exit $?
fi

if $VERIFY_ONLY; then
  # --verify-only skips phase 1, so it never gets the database-clock boundary,
  # and the workstation value stamped at startup is LATER than any rollup this
  # mode is meant to inspect — every row would look stale and the aggregator
  # line would read UNMEASURED on a perfectly reset cluster. So this mode takes
  # its own boundary: the DB clock, backed off by two emit periods, which is the
  # narrowest window that is guaranteed to contain at least one rollup.
  if [ "${#POSTGRES_PODS[@]}" -gt 0 ]; then
    vo_now="$(pg_query "${POSTGRES_PODS[0]}" \
      "SELECT now() - interval '$(( ${RESTATE_CADENCE_SECONDS:-30} * 2 )) seconds'" || true)"
    if [ -n "$vo_now" ]; then
      RUN_STARTED_AT="$vo_now"
      RUN_STARTED_AT_SOURCE="database clock on ${POSTGRES_PODS[0]}, minus 2 emit periods (--verify-only)"
    fi
  fi
  echo "run boundary: $RUN_STARTED_AT  [$RUN_STARTED_AT_SOURCE]"
  # --verify-only runs phase 8 ALONE, against whatever the cluster already is
  # — no quiesce, no clear, no restore. On a live, unreset deployment this is
  # the red check: every populated store/topic line above reads non-zero
  # against phase 8's "predicted 0", so this exits non-zero. See phase 8's
  # own header for the full per-reading argument.
  phase8_zero
  exit $?
fi

if $RED_CHECK_ELECTRIC; then
  # Read-only. Baseline, then the phase 8 electric check with NO pod deleted:
  # every handle is unchanged, so every handle line must read FAIL. If any
  # reads PASS, the check cannot tell a surviving shape log from a discarded
  # one, and phase 8's electric PASS means nothing.
  echo "=== RED-CHECK: electric shape handle (no pod is deleted) ==="
  baseline_electric
  verify_electric || true
  # Rows: on a populated fleet every shape holds rows, so every rows line
  # must read FAIL against phase 8's 0. Run this on an empty fleet and it
  # cannot, which is reported, not excused.
  if [ "${#ELECTRIC_PODS[@]}" -gt 0 ] \
     && [ "$ELECTRIC_HANDLE_UNCHANGED" -eq "${#ELECTRIC_PODS[@]}" ] \
     && [ "$ELECTRIC_ROWS_NONZERO" -eq "${#ELECTRIC_PODS[@]}" ]; then
    echo "--red-check-electric: PASSED (handle ${ELECTRIC_HANDLE_UNCHANGED}/${#ELECTRIC_PODS[@]} UNCHANGED, rows ${ELECTRIC_ROWS_NONZERO}/${#ELECTRIC_PODS[@]} non-zero; every line FAILED as it must)"
    exit 0
  fi
  echo "--red-check-electric: FAILED (handle ${ELECTRIC_HANDLE_UNCHANGED}/${#ELECTRIC_PODS[@]} UNCHANGED, rows ${ELECTRIC_ROWS_NONZERO}/${#ELECTRIC_PODS[@]} non-zero; every one must be both)" >&2
  exit 1
fi

RESET_RUN=true
trap 'on_reset_exit' EXIT
run_phase "1 baseline" phase1_baseline

# --- pre-flight (SPEC-consumer-declarations.md Part B item 5): every live
# consumer group on a target topic must have a declared owner BEFORE
# anything below scales a single workload down. Runs the real capture pass
# early (phase4_topics' own capture, at line ~2113, re-runs it — cheap and
# idempotent, not worth threading a "already captured" flag through for)
# so CAPTURED_TOPICS reflects this run's actual topic set, not a stale or
# guessed one. Unconditional in dry-run too: a dry run that "passes" over an
# undeclared consumer would print a plan nobody should trust.
CURRENT_PHASE="pre-flight"
phase4_capture_pass
if ! assert_consumers_declared "${CAPTURED_TOPICS[@]}"; then
  echo "PRE-FLIGHT ABORTED: an undeclared live consumer exists on a target" >&2
  echo "topic (see UNDECLARED CONSUMER lines above). Nothing has been" >&2
  echo "mutated — no workload scaled, no topic touched. Add the missing" >&2
  echo "openddil.io/consumer-groups declaration and re-run." >&2
  halt_reset "pre-flight: an undeclared live consumer on a target topic" \
    "nothing mutated: no workload scaled, no topic touched"
fi
PHASES_DONE+=("pre-flight")

run_phase "2 quiesce" phase2_quiesce
run_phase "3 restate" phase3_restate
run_phase "3b writer census" phase3b_writer_census
run_phase "4 topics" phase4_topics
run_phase "5 aggregator" phase5_aggregator
run_phase "6 stores" phase6_stores
run_phase "7 electric" phase7_electric
# phase 8 runs BEFORE producers come back (that ordering is the whole point
# of this reorder — see phase 8's header). Guarded with `|| true` so a FAIL
# here (OVERALL_FAIL=1, a non-zero return) does not let `set -e` skip straight
# to the EXIT trap and leave phase 9 unrun: a failed zero assertion must still
# get its producers back, exactly like a passing one does.
CURRENT_PHASE="8 zero assertion"
phase8_zero || true
PHASES_DONE+=("8 zero assertion")
run_phase "9 restore" phase9_restore_producers
# Recorded here, right after phase 9 returns, RFC3339 UTC second precision —
# this is "when producers came back", the T phase 10 measures liveness since.
PHASE9_DONE_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "reset-scenario: producers restored. This script asserts zero at rest" \
     "only — confirming the reset holds under a live refill is" \
     "check-advancing.sh's job, not this script's; run it separately."
# Runs even if phase 8 failed — phase 8 is already `|| true` before phase 9
# for the same reason (see its header); a failed zero assertion is still not
# a reason to skip the one check that can see Restate's own dedup silently
# dropping records. phase10_subscription_liveness never returns non-zero
# itself (failures map into OVERALL_FAIL instead), so this stays a bare
# run_phase call like every other phase.
run_phase "10 subscription liveness" phase10_subscription_liveness
RUN_COMPLETED=true
exit "$OVERALL_FAIL"
