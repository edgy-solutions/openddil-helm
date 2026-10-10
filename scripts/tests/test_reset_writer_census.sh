#!/usr/bin/env bash
# ===========================================================================
# test_reset_writer_census.sh — offline proof for phase 3b (writer census),
# the bridge graph (source-first ordering, destination stability) and the
# phase 5 / phase 9 CENSUS_QUIESCED restore, against
# reset-scenario.sh's REAL functions (sourced the same way the other
# test_reset_*.sh files do; see test_reset_policytrim.sh's header for the
# SOURCE_ONLY seam).
#
# Two seams are used, same philosophy as test_reset_ownership.sh: override
# the functions that are the script's ONLY points of contact with a live
# broker (declared_producers, writer_census_read) with fixed fixture data,
# and let everything downstream (writer_census, phase3b_writer_census,
# run_writer_census_only, phase5_aggregator, phase9_restore_producers) run
# its own real logic. bridge_graph/assert_destination_stable/assert_broker_
# fully_trimmed make their kubectl calls inline (no such seam exists), so
# those are proved against a `kubectl` stub instead, in the same positional-
# args style test_reset_policytrim.sh uses.
#
# `sleep` is overridden to a no-op that also advances WC_ROUND exactly when
# called with the writer-census window argument — writer_census_read's
# fixture is keyed by WC_ROUND, so this is what makes the "before" and
# "after" reads of one writer_census() call differ. Case 6 does not depend
# on sleep at all: its kubectl stub advances by call count instead, so a
# no-op sleep is sufficient there too.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"

NS="openddil"
RELEASE="openddil"
export NS RELEASE
RESET_SCENARIO_SOURCE_ONLY=1
export RESET_SCENARIO_SOURCE_ONLY
set --
# shellcheck source=../reset-scenario.sh
. "$SCRIPT"
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

M="$(mktemp -d)"
trap 'rm -rf "$M"' EXIT

# --- fixtures ---------------------------------------------------------------
declare -A FIX_TOPICS=()   # pod -> space-separated topic names (1 partition each)
declare -A FIX_HW=()       # "pod|topic|round" -> high watermark at that round
declare -A FIX_LS=()       # "pod|topic" -> log-start (constant; census never trims)
declare -A CONSUME_OUT=()  # "pod|topic|offset" -> canned `rpk topic consume` lines
declare -A REPLICAS_FIXTURE=()  # workload name -> pre-quiesce replica count
declare -a BG_FIXTURE_ROWS=()   # bridge_graph's "owner\tcg\tenvraw" rows
BG_TOXI_FIXTURE=""
declare -A DESC_FIXTURE=()      # "pod|topic|call#" -> "part logstart hw" line
                                 # (call# comes from $M/desc_calls.log, a line
                                 # count -- see the kubectl stub below for why
                                 # a plain associative-array counter can't be
                                 # used here)
WC_ROUND=0

reset_fixtures() {
  FIX_TOPICS=(); FIX_HW=(); FIX_LS=(); CONSUME_OUT=(); REPLICAS_FIXTURE=()
  BG_FIXTURE_ROWS=(); BG_TOXI_FIXTURE=""; DESC_FIXTURE=()
  WC_ROUND=0
  PRODUCER_MAP_BUILT=false; PRODUCER_OWNER=()
  BRIDGE_GRAPH_BUILT=false; BRIDGE_EDGES=(); BRIDGE_DESTS=()
  CENSUS_QUIESCED=(); QSTATE_QUIESCED=(); QSTATE_REPLICAS=()
  SCALES_ARMED=false; SCALES_RESTORED=false
  : > "$M/scale.log"
  : > "$M/desc_calls.log"
}

# writer_census_read's ONLY point of contact with a live broker, replaced
# with the fixture above, keyed by the round `sleep` (below) advances.
writer_census_read() {
  local pod="$1" topic hw ls
  for topic in ${FIX_TOPICS[$pod]:-}; do
    [ -z "$topic" ] && continue
    hw="${FIX_HW["$pod|$topic|$WC_ROUND"]:-}"
    ls="${FIX_LS["$pod|$topic"]:-0}"
    [ -z "$hw" ] && continue
    echo "$topic 0 $ls $hw"
  done
}

# declared_producers's ONLY point of contact, replaced per case with
# DECLARED_PRODUCERS_FIXTURE, "broker\ttopic\towner" per line.
DECLARED_PRODUCERS_FIXTURE=""
declared_producers() { printf '%s\n' "$DECLARED_PRODUCERS_FIXTURE"; }

sleep() {
  [ "${1:-}" = "${WRITER_CENSUS_WINDOW_S:-}" ] && WC_ROUND=$((WC_ROUND + 1))
  return 0
}

# kubectl — only reached by bridge_graph, assert_destination_stable,
# assert_broker_fully_trimmed (case 5/6), and the quiesce/restore/scale path
# (case 2/3) — declared_producers and writer_census_read never call it.
kubectl() {
  local -a A=("$@")
  local argstr="$*"
  case "$argstr" in
    "exec -n "*)
      local pod="${A[3]}"
      case "$argstr" in
        *"rpk topic consume "*)
          local rest topic off
          rest="${argstr#*rpk topic consume }"
          topic="${rest%% *}"
          off="$(printf '%s\n' "$rest" | sed -n 's/.*-o \([^ ]*\).*/\1/p')"
          printf '%s\n' "${CONSUME_OUT["$pod|$topic|$off"]:-}"
          ;;
        *"rpk topic describe "*)
          # topic_partitions runs this through a pipe (`| awk ...`), and a
          # pipeline component is its own subshell -- an in-process
          # DESC_CALLS[key]++ would reset to 1 on every single call. Count
          # with a file instead: file writes escape the subshell boundary,
          # shell variables do not.
          local topic key n
          topic="${argstr#*rpk topic describe }"; topic="${topic%% *}"
          key="$pod|$topic"
          echo "$key" >> "$M/desc_calls.log"
          n=$(grep -cF "$key" "$M/desc_calls.log")
          printf 'PARTITION  LEADER  EPOCH  REPLICAS  LOG-START-OFFSET  HIGH-WATERMARK\n'
          printf '%s\n' "${DESC_FIXTURE["$key|$n"]:-0 1 1 [1] 0 0}"
          ;;
      esac
      ;;
    "get deploy,statefulset "*)
      printf '%s\n' "${BG_FIXTURE_ROWS[@]}"
      ;;
    "get cm "*)
      printf '%s\n' "$BG_TOXI_FIXTURE"
      ;;
    "get "*".status.replicas"*)
      echo 0
      ;;
    "get "*".spec.replicas"*)
      echo "${REPLICAS_FIXTURE[${A[4]}]:-2}"
      ;;
    "scale "*)
      echo "kubectl $argstr" >> "$M/scale.log"
      ;;
  esac
  return 0
}

DRY_RUN=false
RPK_CMD_TIMEOUT=60
WRITER_CENSUS_SAMPLE=200

# ===========================================================================
# case 1 — undeclared live local topic halts phase 3b; phase 4 never runs.
# ===========================================================================
reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="rogue-topic"
FIX_LS["openddil-redpanda-a-0|rogue-topic"]=0
FIX_HW["openddil-redpanda-a-0|rogue-topic|0"]=100
FIX_HW["openddil-redpanda-a-0|rogue-topic|1"]=105
CONSUME_OUT["openddil-redpanda-a-0|rogue-topic|100"]=$'k1\t\nk2\t\nk3\t\nk4\t\nk5\t'
DECLARED_PRODUCERS_FIXTURE=""   # nothing declared anywhere
WRITER_CENSUS_WINDOW_S=9
WRITER_SETTLE_TRIES=3

out="$( (set -e; phase3b_writer_census; echo AFTER-3b) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "1: undeclared local writer halts (rc 2)" || fail "1: rc=$rc, expected 2"
grep -q "openddil-redpanda-a-0/rogue-topic has 5 undeclared local write(s)" <<<"$out" \
  && pass "1: broker/topic/count named" || fail "1: undeclared message not found as expected"
grep -q "AFTER-3b" <<<"$out" && fail "1: something ran after the halt (phase 4 would be next)" \
  || pass "1: nothing ran after the halt — phase 4 never reached"

# ===========================================================================
# case 2 — a declared local writer (one Faust, one plain Deployment) is
# scaled to 0, recorded, settle passes; phase 5 restores the Faust entry
# fresh, phase 9 restores the other, both to their captured replica counts.
# ===========================================================================
reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="good-topic chlog-topic"
FIX_LS["openddil-redpanda-a-0|good-topic"]=0; FIX_LS["openddil-redpanda-a-0|chlog-topic"]=0
FIX_HW["openddil-redpanda-a-0|good-topic|0"]=50;   FIX_HW["openddil-redpanda-a-0|good-topic|1"]=55;   FIX_HW["openddil-redpanda-a-0|good-topic|2"]=55
FIX_HW["openddil-redpanda-a-0|chlog-topic|0"]=10;  FIX_HW["openddil-redpanda-a-0|chlog-topic|1"]=12;  FIX_HW["openddil-redpanda-a-0|chlog-topic|2"]=12
CONSUME_OUT["openddil-redpanda-a-0|good-topic|50"]=$'k1\t\nk2\t\nk3\t\nk4\t\nk5\t'
CONSUME_OUT["openddil-redpanda-a-0|chlog-topic|10"]=$'c1\t\nc2\t'
DECLARED_PRODUCERS_FIXTURE=$'a\tgood-topic\tDeployment/good-writer\na\tchlog-topic\tDeployment/faust-edge-01'
REPLICAS_FIXTURE[good-writer]=3
REPLICAS_FIXTURE[faust-edge-01]=1
WRITER_CENSUS_WINDOW_S=9
WRITER_SETTLE_TRIES=3
FAUST_DEPLOYS=(faust-edge-01)
PRODUCER_DEPLOYS=()
SKIP_AGGREGATOR=false
SKIP_PRODUCERS=false
OVERALL_FAIL=0

out="$( (
  set -e
  phase3b_writer_census
  echo "QUIESCED=${CENSUS_QUIESCED[*]}"
  phase5_aggregator
  phase9_restore_producers
) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "2: declared writers quiesce, settle, restore cleanly (rc 0)" \
  || fail "2: rc=$rc, expected 0"
grep -q "QUIESCED=Deployment/faust-edge-01 Deployment/good-writer" <<<"$out" \
  && pass "2: both declared writers recorded in CENSUS_QUIESCED" \
  || fail "2: CENSUS_QUIESCED did not contain both entries as expected"
grep -q "settle PASS on try 1" <<<"$out" && pass "2: settle passes on the first try" \
  || fail "2: settle did not pass on try 1"
grep -q "writer-census-quiesced, scaling back fresh" <<<"$out" \
  && pass "2: phase 5 restores the Faust entry fresh, not by rollout restart" \
  || fail "2: phase 5 did not take the writer-census-quiesced path"
grep -qF "kubectl scale deploy -n openddil good-writer --replicas=0" "$M/scale.log" \
  && pass "2: good-writer scaled to 0" || fail "2: good-writer was not scaled to 0"
grep -qF "kubectl scale deploy -n openddil faust-edge-01 --replicas=0" "$M/scale.log" \
  && pass "2: faust-edge-01 scaled to 0" || fail "2: faust-edge-01 was not scaled to 0"
grep -qF "kubectl scale deploy -n openddil good-writer --replicas=3" "$M/scale.log" \
  && pass "2: good-writer restored to its captured replicas (3), by phase 9" \
  || fail "2: good-writer was not restored to 3"
grep -qF "kubectl scale deploy -n openddil faust-edge-01 --replicas=1" "$M/scale.log" \
  && pass "2: faust-edge-01 restored to its captured replicas (1), by phase 5" \
  || fail "2: faust-edge-01 was not restored to 1"

# ===========================================================================
# case 3 — a declared writer still advancing after the quiesce halts, naming
# it; the emergency trap (arm_scale_trap / emergency_restore_scales) restores
# it without a second mechanism.
# ===========================================================================
reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="stuck-topic"
FIX_LS["openddil-redpanda-a-0|stuck-topic"]=0
FIX_HW["openddil-redpanda-a-0|stuck-topic|0"]=10
FIX_HW["openddil-redpanda-a-0|stuck-topic|1"]=15
FIX_HW["openddil-redpanda-a-0|stuck-topic|2"]=20
CONSUME_OUT["openddil-redpanda-a-0|stuck-topic|10"]=$'k1\t\nk2\t\nk3\t\nk4\t\nk5\t'
CONSUME_OUT["openddil-redpanda-a-0|stuck-topic|15"]=$'k6\t\nk7\t\nk8\t\nk9\t\nk10\t'
DECLARED_PRODUCERS_FIXTURE=$'a\tstuck-topic\tDeployment/stuck-writer'
REPLICAS_FIXTURE[stuck-writer]=2
WRITER_CENSUS_WINDOW_S=9
WRITER_SETTLE_TRIES=3
RESET_RUN=false
PRODUCER_DEPLOYS=()

out="$( (set -e; phase3b_writer_census; echo AFTER-3b) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "3: still-advancing writer halts (rc 2)" || fail "3: rc=$rc, expected 2"
grep -q "still advancing locally after quiesce: openddil-redpanda-a-0|stuck-topic (local=5)" <<<"$out" \
  && pass "3: halt names the advancing (broker,topic)" || fail "3: advancing topic not named as expected"
grep -q "AFTER-3b" <<<"$out" && fail "3: something ran after the halt" || pass "3: nothing ran after the halt"
grep -q "ABORTED AT EXIT 2 WITH WORKLOADS SCALED DOWN" <<<"$out" \
  && pass "3: emergency-restore trap fired" || fail "3: emergency-restore trap did not fire"
grep -qF "kubectl scale deploy -n openddil stuck-writer --replicas=0" "$M/scale.log" \
  && pass "3: stuck-writer was quiesced" || fail "3: stuck-writer was never scaled to 0"
grep -qF "kubectl scale deploy -n openddil stuck-writer --replicas=2" "$M/scale.log" \
  && pass "3: emergency restore scaled stuck-writer back to its captured replicas (2)" \
  || fail "3: emergency restore did not restore stuck-writer"

# ===========================================================================
# case 4 — bridged-only advance (a drain) settles by try 2 and passes; one
# that never stops halts after WRITER_SETTLE_TRIES.
# ===========================================================================
reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="drain-topic"
FIX_LS["openddil-redpanda-a-0|drain-topic"]=0
FIX_HW["openddil-redpanda-a-0|drain-topic|0"]=0
FIX_HW["openddil-redpanda-a-0|drain-topic|1"]=5    # initial local advance -> quiesced
FIX_HW["openddil-redpanda-a-0|drain-topic|2"]=8    # settle try 1: +3, all bridged (drain)
FIX_HW["openddil-redpanda-a-0|drain-topic|3"]=8    # settle try 2: zero advance -> pass
CONSUME_OUT["openddil-redpanda-a-0|drain-topic|0"]=$'k1\t\nk2\t\nk3\t\nk4\t\nk5\t'
CONSUME_OUT["openddil-redpanda-a-0|drain-topic|5"]=$'b1\tkafka_topic;\nb2\tkafka_topic;\nb3\tkafka_topic;'
DECLARED_PRODUCERS_FIXTURE=$'a\tdrain-topic\tDeployment/drain-writer'
REPLICAS_FIXTURE[drain-writer]=1
WRITER_CENSUS_WINDOW_S=9
WRITER_SETTLE_TRIES=3

out="$( (set -e; phase3b_writer_census) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "4a: bridged-only drain settles by try 2 (rc 0)" || fail "4a: rc=$rc, expected 0"
grep -q "bridged-only advance on try 1" <<<"$out" && pass "4a: try 1 reported as a drain" \
  || fail "4a: try 1 not reported as a drain"
grep -q "settle PASS on try 2" <<<"$out" && pass "4a: settle PASS on try 2" \
  || fail "4a: did not pass on try 2 as expected"

reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="never-drains-topic"
FIX_LS["openddil-redpanda-a-0|never-drains-topic"]=0
FIX_HW["openddil-redpanda-a-0|never-drains-topic|0"]=0
FIX_HW["openddil-redpanda-a-0|never-drains-topic|1"]=5    # initial local advance -> quiesced
FIX_HW["openddil-redpanda-a-0|never-drains-topic|2"]=8    # settle try 1: bridged-only
FIX_HW["openddil-redpanda-a-0|never-drains-topic|3"]=11   # settle try 2: bridged-only
FIX_HW["openddil-redpanda-a-0|never-drains-topic|4"]=14   # settle try 3: bridged-only, still
CONSUME_OUT["openddil-redpanda-a-0|never-drains-topic|0"]=$'k1\t\nk2\t\nk3\t\nk4\t\nk5\t'
CONSUME_OUT["openddil-redpanda-a-0|never-drains-topic|5"]=$'b1\tkafka_topic;\nb2\tkafka_topic;\nb3\tkafka_topic;'
CONSUME_OUT["openddil-redpanda-a-0|never-drains-topic|8"]=$'b4\tkafka_topic;\nb5\tkafka_topic;\nb6\tkafka_topic;'
CONSUME_OUT["openddil-redpanda-a-0|never-drains-topic|11"]=$'b7\tkafka_topic;\nb8\tkafka_topic;\nb9\tkafka_topic;'
DECLARED_PRODUCERS_FIXTURE=$'a\tnever-drains-topic\tDeployment/never-drains-writer'
REPLICAS_FIXTURE[never-drains-writer]=1
WRITER_CENSUS_WINDOW_S=9
WRITER_SETTLE_TRIES=3

out="$( (set -e; phase3b_writer_census; echo AFTER-3b) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "4b: bridged advance that never stops halts after WRITER_SETTLE_TRIES (rc 2)" \
  || fail "4b: rc=$rc, expected 2"
grep -q "still advancing after 3 settle tries" <<<"$out" \
  && pass "4b: halt names the settle-tries exhaustion" || fail "4b: expected halt message not found"
grep -q "AFTER-3b" <<<"$out" && fail "4b: something ran after the halt" || pass "4b: nothing ran after the halt"

# ===========================================================================
# case 5 — bridge graph: the four lab edges order source-first; a cycle and
# an unresolvable DEST_PORT both halt.
# ===========================================================================
reset_fixtures
REDPANDA_PODS=("$RELEASE-redpanda-hq-0" "$RELEASE-redpanda-edge-03-0" \
               "$RELEASE-redpanda-region-east-0" "$RELEASE-redpanda-edge-02-0" \
               "$RELEASE-redpanda-edge-01-0")
BG_FIXTURE_ROWS=(
  $'Deployment/edge-hq-bridge-01\tedge-01/region-edge-01-source-edge-01\tDEST_HOST='"$RELEASE"'-toxiproxy.openddil.svc.cluster.local|DEST_PORT=18400|'
  $'Deployment/edge-hq-bridge-02\tedge-02/region-edge-02-source-edge-02\tDEST_HOST='"$RELEASE"'-toxiproxy.openddil.svc.cluster.local|DEST_PORT=18401|'
  $'Deployment/edge-hq-bridge-03\tedge-03/region-edge-03-source-edge-03\tDEST_HOST='"$RELEASE"'-toxiproxy.openddil.svc.cluster.local|DEST_PORT=18402|'
  $'Deployment/tier-uplink-region-east\tregion-east/region-region-east-hq-source\tDEST_HOST='"$RELEASE"'-toxiproxy.openddil.svc.cluster.local|DEST_PORT=18403|'
)
BG_TOXI_FIXTURE='[
  {
    "enabled": true,
    "listen": "0.0.0.0:18400",
    "name": "uplink-edge-01",
    "upstream": "'"$RELEASE"'-redpanda-region-east:9092"
  },
  {
    "enabled": true,
    "listen": "0.0.0.0:18401",
    "name": "uplink-edge-02",
    "upstream": "'"$RELEASE"'-redpanda-region-east:9092"
  },
  {
    "enabled": true,
    "listen": "0.0.0.0:18402",
    "name": "uplink-edge-03",
    "upstream": "'"$RELEASE"'-redpanda-hq:9092"
  },
  {
    "enabled": true,
    "listen": "0.0.0.0:18403",
    "name": "uplink-region-east",
    "upstream": "'"$RELEASE"'-redpanda-hq:9092"
  }
]'

out="$( (set -e; bridge_graph; topo_sort_redpanda_pods) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "5a: four lab edges resolve cleanly (rc 0)" || fail "5a: rc=$rc, expected 0"
grep -q "phase 4 order (source-first): edge-01 edge-02 edge-03 region-east hq" <<<"$out" \
  && pass "5a: order is edge-01, edge-02, edge-03, region-east, hq" \
  || fail "5a: order did not match the lab's four edges as expected"

reset_fixtures
REDPANDA_PODS=("$RELEASE-redpanda-a-0" "$RELEASE-redpanda-b-0")
BG_FIXTURE_ROWS=(
  $'Deployment/bridge-a-to-b\ta/group-a\tDEST_HOST='"$RELEASE"'-redpanda-b.openddil.svc.cluster.local|DEST_PORT=9092|'
  $'Deployment/bridge-b-to-a\tb/group-b\tDEST_HOST='"$RELEASE"'-redpanda-a.openddil.svc.cluster.local|DEST_PORT=9092|'
)
out="$( (set -e; bridge_graph; topo_sort_redpanda_pods) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "5b: a cycle halts (rc 2)" || fail "5b: rc=$rc, expected 2"
grep -q "cycle among broker(s) a b" <<<"$out" && pass "5b: cycle names both brokers" \
  || fail "5b: cycle message not found as expected"

reset_fixtures
REDPANDA_PODS=("$RELEASE-redpanda-hq-0" "$RELEASE-redpanda-edge-01-0")
BG_FIXTURE_ROWS=(
  $'Deployment/edge-hq-bridge-01\tedge-01/region-edge-01-source-edge-01\tDEST_HOST='"$RELEASE"'-toxiproxy.openddil.svc.cluster.local|DEST_PORT=99999|'
)
BG_TOXI_FIXTURE='[
  {
    "enabled": true,
    "listen": "0.0.0.0:18400",
    "name": "uplink-edge-01",
    "upstream": "'"$RELEASE"'-redpanda-hq:9092"
  }
]'
out="$( (set -e; bridge_graph) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "5c: an unresolvable DEST_PORT halts (rc 2)" || fail "5c: rc=$rc, expected 2"
grep -q "DEST_PORT 99999 matches no proxy" <<<"$out" && pass "5c: halt names the unresolvable port" \
  || fail "5c: expected halt message not found"

# With link control off there is no toxiproxy and no ${RELEASE}-toxiproxy-config:
# every bridge's DEST_HOST is its destination broker's own Service, and the
# missing ConfigMap must not halt.
reset_fixtures
REDPANDA_PODS=("$RELEASE-redpanda-hq-0" "$RELEASE-redpanda-edge-03-0" \
               "$RELEASE-redpanda-region-east-0" "$RELEASE-redpanda-edge-02-0" \
               "$RELEASE-redpanda-edge-01-0")
BG_FIXTURE_ROWS=(
  $'Deployment/edge-hq-bridge-01\tedge-01/region-edge-01-source-edge-01\tDEST_HOST='"$RELEASE"'-redpanda-region-east.openddil.svc.cluster.local|DEST_PORT=9092|'
  $'Deployment/edge-hq-bridge-02\tedge-02/region-edge-02-source-edge-02\tDEST_HOST='"$RELEASE"'-redpanda-region-east.openddil.svc.cluster.local|DEST_PORT=9092|'
  $'Deployment/edge-hq-bridge-03\tedge-03/region-edge-03-source-edge-03\tDEST_HOST='"$RELEASE"'-redpanda-hq.openddil.svc.cluster.local|DEST_PORT=9092|'
  $'Deployment/tier-uplink-region-east\tregion-east/region-region-east-hq-source\tDEST_HOST='"$RELEASE"'-redpanda-hq.openddil.svc.cluster.local|DEST_PORT=9092|'
)
out="$( (set -e; bridge_graph; topo_sort_redpanda_pods) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "5d: direct DEST_HOSTs with no toxiproxy ConfigMap resolve (rc 0)" \
  || fail "5d: rc=$rc, expected 0"
grep -q "phase 4 order (source-first): edge-01 edge-02 edge-03 region-east hq" <<<"$out" \
  && pass "5d: order is edge-01, edge-02, edge-03, region-east, hq" \
  || fail "5d: order did not match the direct-wired edges as expected"

# ===========================================================================
# case 6 — destination stability: a double read that keeps moving retries up
# to DEST_READ_TRIES then halts; a post-trim double read that regresses on
# the second pass halts too.
# ===========================================================================
reset_fixtures
DEST_READ_TRIES=3
DEST_SETTLE_S=0
BRIDGE_DESTS[movy]=1
CAPTURED_TOPICS=("$RELEASE-redpanda-movy-0|movy-topic")
# Every describe call returns a strictly higher hw than the last, so no two
# consecutive reads can ever agree within DEST_READ_TRIES.
DESC_FIXTURE["$RELEASE-redpanda-movy-0|movy-topic|1"]="0 1 1 [1] 50 100"
DESC_FIXTURE["$RELEASE-redpanda-movy-0|movy-topic|2"]="0 1 1 [1] 50 101"
DESC_FIXTURE["$RELEASE-redpanda-movy-0|movy-topic|3"]="0 1 1 [1] 50 102"
DESC_FIXTURE["$RELEASE-redpanda-movy-0|movy-topic|4"]="0 1 1 [1] 50 103"
DESC_FIXTURE["$RELEASE-redpanda-movy-0|movy-topic|5"]="0 1 1 [1] 50 104"
DESC_FIXTURE["$RELEASE-redpanda-movy-0|movy-topic|6"]="0 1 1 [1] 50 105"
out="$( (set -e; assert_destination_stable "$RELEASE-redpanda-movy-0") 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "6a: a destination that keeps moving halts after DEST_READ_TRIES (rc 2)" \
  || fail "6a: rc=$rc, expected 2"
grep -q "did not settle after 3 double-read(s)" <<<"$out" \
  && pass "6a: halt names the try count" || fail "6a: expected halt message not found"

reset_fixtures
DEST_READ_TRIES=3
DEST_SETTLE_S=0
CAPTURED_TOPICS=("$RELEASE-redpanda-fin-0|fin-topic")
# First post-trim read: trimmed (log-start == hw). Second: advanced again.
DESC_FIXTURE["$RELEASE-redpanda-fin-0|fin-topic|1"]="0 1 1 [1] 50 50"
DESC_FIXTURE["$RELEASE-redpanda-fin-0|fin-topic|2"]="0 1 1 [1] 50 60"
out="$( (set -e; assert_broker_fully_trimmed "$RELEASE-redpanda-fin-0") 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "6b: a post-trim regression on the 2nd read halts (rc 2)" \
  || fail "6b: rc=$rc, expected 2"
grep -q "advanced again after trimming, on the second post-trim read" <<<"$out" \
  && pass "6b: halt names the second-read regression" || fail "6b: expected halt message not found"

# ===========================================================================
# case 7 — --writer-census-only: exits 0/2 correctly, never scales.
# ===========================================================================
reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="clean-topic"
FIX_LS["openddil-redpanda-a-0|clean-topic"]=0
FIX_HW["openddil-redpanda-a-0|clean-topic|0"]=5
FIX_HW["openddil-redpanda-a-0|clean-topic|1"]=8
CONSUME_OUT["openddil-redpanda-a-0|clean-topic|5"]=$'k1\t\nk2\t\nk3\t'
DECLARED_PRODUCERS_FIXTURE=$'a\tclean-topic\tDeployment/clean-writer'
WRITER_CENSUS_WINDOW_S=9

out="$( (set -e; run_writer_census_only) 2>&1 )"; rc=$?
[ "$rc" -eq 0 ] && pass "7a: every live local topic declared -> exit 0" || fail "7a: rc=$rc, expected 0"
grep -q "PASSED" <<<"$out" && pass "7a: PASSED reported" || fail "7a: PASSED not reported"
[ -s "$M/scale.log" ] && fail "7a: --writer-census-only scaled something" \
  || pass "7a: --writer-census-only scaled nothing"

reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="dirty-topic"
FIX_LS["openddil-redpanda-a-0|dirty-topic"]=0
FIX_HW["openddil-redpanda-a-0|dirty-topic|0"]=5
FIX_HW["openddil-redpanda-a-0|dirty-topic|1"]=9
CONSUME_OUT["openddil-redpanda-a-0|dirty-topic|5"]=$'k1\t\nk2\t\nk3\t\nk4\t'
DECLARED_PRODUCERS_FIXTURE=""
WRITER_CENSUS_WINDOW_S=9

out="$( (set -e; run_writer_census_only) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "7b: an undeclared live local topic -> exit 2" || fail "7b: rc=$rc, expected 2"
grep -q "FAILED" <<<"$out" && pass "7b: FAILED reported" || fail "7b: FAILED not reported"
grep -q "UNDECLARED: openddil-redpanda-a-0/dirty-topic" <<<"$out" && pass "7b: undeclared topic named" \
  || fail "7b: undeclared topic not named"
[ -s "$M/scale.log" ] && fail "7b: --writer-census-only scaled something even on FAILED" \
  || pass "7b: --writer-census-only scaled nothing, even on FAILED"

# 7c: a topic that advanced but read back nothing is "?". It counts
# against PASSED and must be named, not just counted.
reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="silent-topic"
FIX_LS["openddil-redpanda-a-0|silent-topic"]=0
FIX_HW["openddil-redpanda-a-0|silent-topic|0"]=20
FIX_HW["openddil-redpanda-a-0|silent-topic|1"]=23
DECLARED_PRODUCERS_FIXTURE=""
WRITER_CENSUS_WINDOW_S=9

out="$( (set -e; run_writer_census_only) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "7c: an unreadable topic -> exit 2" || fail "7c: rc=$rc, expected 2"
grep -q "UNREADABLE: openddil-redpanda-a-0/silent-topic" <<<"$out" && pass "7c: unreadable topic named" \
  || fail "7c: unreadable topic not named"

# ===========================================================================
# case 8 — sampling must not fail open.
# 8a: the high watermark advances but the consume returns nothing. The
#     writer is unknown, so the read is "?" and phase 3b halts; it must not
#     count as zero local writes.
# 8b: a keyless, headerless record prints as a bare tab. It is a local
#     write and must be counted, not skipped as a blank line.
# ===========================================================================
reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="silent-topic"
FIX_LS["openddil-redpanda-a-0|silent-topic"]=0
FIX_HW["openddil-redpanda-a-0|silent-topic|0"]=20
FIX_HW["openddil-redpanda-a-0|silent-topic|1"]=23
# no CONSUME_OUT entry: the consume prints nothing
DECLARED_PRODUCERS_FIXTURE=""
WRITER_CENSUS_WINDOW_S=9
WRITER_SETTLE_TRIES=3

out="$( (set -e; phase3b_writer_census; echo AFTER-3b) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "8a: advanced but unread halts (rc 2)" || fail "8a: rc=$rc, expected 2"
grep -q "could not read openddil-redpanda-a-0/silent-topic cleanly" <<<"$out" \
  && pass "8a: unreadable topic named" || fail "8a: unreadable message not found"
grep -q "AFTER-3b" <<<"$out" && fail "8a: something ran after the halt" \
  || pass "8a: nothing ran after the halt"

reset_fixtures
REDPANDA_PODS=(openddil-redpanda-a-0)
FIX_TOPICS[openddil-redpanda-a-0]="bare-topic"
FIX_LS["openddil-redpanda-a-0|bare-topic"]=0
FIX_HW["openddil-redpanda-a-0|bare-topic|0"]=7
FIX_HW["openddil-redpanda-a-0|bare-topic|1"]=9
CONSUME_OUT["openddil-redpanda-a-0|bare-topic|7"]=$'\t\n\t'
DECLARED_PRODUCERS_FIXTURE=""
WRITER_CENSUS_WINDOW_S=9
WRITER_SETTLE_TRIES=3

out="$( (set -e; phase3b_writer_census; echo AFTER-3b) 2>&1 )"; rc=$?
[ "$rc" -eq 2 ] && pass "8b: keyless headerless writes halt (rc 2)" || fail "8b: rc=$rc, expected 2"
grep -q "openddil-redpanda-a-0/bare-topic has 2 undeclared local write(s)" <<<"$out" \
  && pass "8b: both bare-tab records counted" || fail "8b: bare-tab records not counted as 2"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_writer_census.sh: ALL PASS"
else
  echo "test_reset_writer_census.sh: SOME FAILED"
fi
exit "$FAIL"
