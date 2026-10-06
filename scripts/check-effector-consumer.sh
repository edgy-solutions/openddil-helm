#!/usr/bin/env bash
# ===========================================================================
# check-effector-consumer.sh — is the effector-launch PROJECTOR CONSUMER alive?
# ===========================================================================
# THE GAP THIS FILLS. `effector_launch` holds one row per DIS Fire. A
# deployment where nothing has fired has an empty table, and that is the
# correct and common case -- not a partial deployment. The completeness
# gate cannot tell that apart from a stopped projector just by reading the
# table, so an empty table is permitted only while something else proves
# the producer side is alive.
#
# THAT PRODUCER IS NOT FUSION. check-derive-stage.sh's verdict is about the
# derive stage's Restate handler, and says nothing about whether the
# projector's effector-launch consumer group is still reading. A sparse
# declaration that borrowed the fusion verdict for this table would be
# answering a different question than the one it is asked, which is the
# exact "explains away a stopped producer" failure this file exists to
# avoid repeating.
#
# WHY THIS SCRIPT REFUSES TO REPORT A NUMBER IT DID NOT READ. Same discipline
# as check-derive-stage.sh: kubectl's stderr is captured and shown, a read
# that cannot be parsed with confidence is an ERROR and not a zero, and the
# cluster guard runs first. A failed read publishes NOTHING, so a stale
# result ages out on its own rather than a fresh false one overwriting it.
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"

# SOURCE_ONLY lets a fixture test load the parsing functions below without
# running the cluster guard or the probe itself -- the same shape
# reset-scenario.sh's own offline test uses. Never set this to skip the
# guard for a real run.
if [ "${OPENDDIL_EFFECTOR_CONSUMER_SOURCE_ONLY:-0}" != "1" ]; then
  # shellcheck source=lib/require-cluster.sh
  . "$HERE/lib/require-cluster.sh"
  openddil_require_cluster
fi

NS="${NS:-openddil}"
REL="${OPENDDIL_RELEASE:-openddil}"
TOPIC="effector-events"
TIER=""
WINDOW=60
while [ $# -gt 0 ]; do
  case "$1" in
    --tier) TIER="$2"; shift 2 ;;
    -n) NS="$2"; shift 2 ;;
    *) WINDOW="$1"; shift ;;
  esac
done

# GROUP AND BROKER, per store. `--tier <id>` reads the group the tier's own
# projector uses (templates/_helpers.tpl's tierProjectorConfig, consumer_group
# tier-projector-effector-launch-<id>) on that tier's own broker
# (<release>-redpanda-<id>-0, the same service tier-node.yaml's $broker
# resolves to). The default (root) reads the root projector's group
# (projector-effector-launch, openddil-projector's own config) on the root
# broker (<release>-redpanda-hq-0) -- same pod naming check-derive-stage.sh's
# tier rows use, one level up at "hq" instead of a tier id.
if [ -n "$TIER" ]; then
  GROUP="tier-projector-effector-launch-${TIER}"
  POD="${REL}-redpanda-${TIER}-0"
else
  GROUP="projector-effector-launch"
  POD="${REL}-redpanda-hq-0"
fi

RESULT="${OPENDDIL_EFFECTOR_CONSUMER_RESULT:-${TMPDIR:-/tmp}/openddil-effector-consumer.result}"

# ---------------------------------------------------------------------------
# parse_group_describe — reads `rpk group describe <group>` text on stdin,
# prints "STATE<TAB>MEMBERS<TAB>TOTAL-LAG" on success. Prints nothing and
# returns 1 on anything it cannot parse with confidence: a garbled read must
# never read as a confident "0 members, 0 lag".
# ---------------------------------------------------------------------------
parse_group_describe() {
  awk '
    BEGIN { FS = "[ \t]+"; state = ""; members = ""; lag = "" }
    $1 == "STATE" && NF == 2   { state = $2; next }
    $1 == "MEMBERS" && NF == 2 { members = $2; next }
    $1 == "TOTAL-LAG" && NF == 2 { lag = $2; next }
    END {
      if (state == "" || members !~ /^[0-9]+$/ || lag !~ /^[0-9]+$/) { exit 1 }
      print state "\t" members "\t" lag
    }
  '
}

# ---------------------------------------------------------------------------
# read_group POD — one `rpk group describe` read, or FAIL LOUDLY. Never
# fabricates a 0; an unreadable or unparseable group exits non-zero and
# prints why.
# ---------------------------------------------------------------------------
read_group() {
  local pod="$1" out rc
  out=$(kubectl -n "$NS" exec "$pod" -c redpanda -- rpk group describe "$GROUP" 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "READ-FAILED rc=$rc: $(printf '%s' "$out" | head -1)" >&2
    return 1
  fi
  if ! printf '%s\n' "$out" | parse_group_describe; then
    echo "READ-FAILED: could not parse 'rpk group describe $GROUP' on $pod" >&2
    return 1
  fi
}

# ---------------------------------------------------------------------------
# read_hwm POD TOPIC — summed high watermark, or FAIL LOUDLY. Same shape as
# check-derive-stage.sh's hw(): a read that returns no partition rows is an
# ERROR, never a confident 0.
# ---------------------------------------------------------------------------
read_hwm() {
  local pod="$1" topic="$2" out rc rows
  out=$(kubectl -n "$NS" exec "$pod" -c redpanda -- \
          rpk topic describe "$topic" -p 2>&1)
  rc=$?
  if [ "$rc" -ne 0 ]; then
    echo "READ-FAILED rc=$rc: $(printf '%s' "$out" | head -1)" >&2
    return 1
  fi
  rows=$(printf '%s\n' "$out" | awk 'NR>1 && $1 ~ /^[0-9]+$/' | wc -l)
  if [ "$rows" -lt 1 ]; then
    echo "READ-FAILED: no partition rows for $topic on $pod" >&2
    return 1
  fi
  printf '%s\n' "$out" | awk 'NR>1 && $1 ~ /^[0-9]+$/ {s += $NF} END {print s}'
}

# A fixture test sources this file for the two functions above and stops
# here, never reaching the cluster guard or the loop below.
if [ "${OPENDDIL_EFFECTOR_CONSUMER_SOURCE_ONLY:-0}" = "1" ]; then
  return 0 2>/dev/null || exit 0
fi

echo "=== effector-launch consumer probe ==="
echo "  namespace: $NS   group: $GROUP   pod: $POD   window: ${WINDOW}s"
echo

one_read() {
  local gd hwmv
  gd="$(read_group "$POD")" || return 1
  hwmv="$(read_hwm "$POD" "$TOPIC")" || return 1
  printf '%s\t%s\n' "$gd" "$hwmv"
}

first="$(one_read)" || { echo "FATAL: cannot read $GROUP / $TOPIC on $POD — refusing to publish a stale or fabricated verdict." >&2; exit 3; }
IFS=$'\t' read -r state1 members1 lag1 hwm1 <<<"$first"
echo "  read 1: state=$state1 members=$members1 lag=$lag1 hwm=$hwm1"

start=$(date -u +%s)
while [ $(( $(date -u +%s) - start )) -lt "$WINDOW" ]; do sleep 5; done
elapsed=$(( $(date -u +%s) - start ))

second="$(one_read)" || { echo "FATAL: cannot re-read $GROUP / $TOPIC on $POD" >&2; exit 3; }
IFS=$'\t' read -r state2 members2 lag2 hwm2 <<<"$second"
echo "  read 2: state=$state2 members=$members2 lag=$lag2 hwm=$hwm2"
echo

# ---------------------------------------------------------------------------
# VERDICT. ALIVE needs at least one member AND either zero lag at the
# second read or lag that fell across the window. Anything else -- missing,
# Empty, Dead, zero members, or lag that is above zero and did not fall --
# is NOT_ALIVE.
# ---------------------------------------------------------------------------
alive=0
if [ "$members2" -ge 1 ] 2>/dev/null; then
  case "$state2" in
    ""|Empty|Dead) alive=0 ;;
    *)
      if [ "$lag2" -eq 0 ] || [ "$lag2" -lt "$lag1" ]; then
        alive=1
      fi
      ;;
  esac
fi
verdict=$( [ "$alive" -eq 1 ] && echo ALIVE || echo NOT_ALIVE )

# CONSUMED, NOT WRITTEN. The gate does not judge rows-versus-records -- a
# refusal to write (unknown launcher, no fire) is legitimate -- so this is
# printed for an operator to read, never fed back into the verdict above.
if [ "${hwm2:-0}" -gt 0 ] 2>/dev/null && [ "${lag2:-0}" -eq 0 ] 2>/dev/null; then
  echo "consumed, not written: the projector has consumed $hwm2 record(s) from $TOPIC with zero lag."
  echo "(this says nothing about rows written -- a refusal is a legitimate reason to consume without writing)"
  echo
fi

# PUBLISH THE VERDICT, both ways -- see check-derive-stage.sh's own note by
# the same name for why a file that only appears on ALIVE would let a stale
# ALIVE outlive a real NOT_ALIVE.
{
  printf 'epoch=%s\n' "$(date -u +%s)"
  printf 'verdict=%s\n' "$verdict"
  printf 'window_s=%s\n' "$elapsed"
  printf 'group=%s\n' "$GROUP"
  printf 'members=%s\n' "$members2"
  printf 'lag=%s\n' "$lag2"
  printf 'hwm=%s\n' "$hwm2"
  printf 'namespace=%s\n' "$NS"
} > "$RESULT" 2>/dev/null \
  && echo "verdict published: $RESULT" \
  || echo "WARNING: could not publish verdict to $RESULT -- the completeness" \
          "gate will treat effector_launch as unmeasured" >&2

if [ "$verdict" = "ALIVE" ]; then
  echo "effector-launch consumer: ALIVE"
  exit 0
else
  echo "effector-launch consumer: NOT ALIVE — see above."
  exit 1
fi
