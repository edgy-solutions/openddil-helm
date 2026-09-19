#!/usr/bin/env bash
# ===========================================================================
# snapshot-consumers.sh — every consumer group's state, on every broker
# ===========================================================================
# BUILT FOR UD-14, the wedge that has never been reproduced.
#
# On 2026-09-09 four clients sat at `1/1 Running` for 3.5 hours having stopped
# consuming. A broker restart was tested twice (6s and 150s) and recovered
# cleanly both times, which EXONERATED the broker and left the actual trigger
# untested: the helm rollout that preceded it. Rollouts kept happening, but
# nobody was watching the right thing while one did, so the evidence was never
# collected.
#
# This collects it. Snapshot before a rollout, snapshot after, diff. A client
# that was Stable and is now Empty, or whose committed offset stopped moving
# while its topic's watermark advanced, is the wedge -- caught in the act
# rather than inferred hours later.
#
# WHY GROUP STATE AND OFFSETS, NOT POD STATUS. Pod status is precisely what
# lies here: the whole point of UD-14 is four pods that read healthy while
# doing nothing. The broker's view of the group is the reading that disagreed,
# and it is the only one that would have.
#
#   ./scripts/snapshot-consumers.sh <label>          # write a snapshot
#   ./scripts/snapshot-consumers.sh --diff <a> <b>   # compare two
#
# Snapshots land in ${OPENDDIL_SNAPSHOT_DIR:-/tmp/openddil-snapshots}.
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/require-cluster.sh
. "$HERE/lib/require-cluster.sh"
openddil_require_cluster

NS="${NS:-openddil}"
DIR="${OPENDDIL_SNAPSHOT_DIR:-/tmp/openddil-snapshots}"
mkdir -p "$DIR"

brokers() {
  kubectl -n "$NS" get pods -o name 2>/dev/null \
    | sed -n 's|^pod/\(.*redpanda[^/]*\)$|\1|p' \
    | grep -vE 'connect|topic-init' | sort -u
}

snapshot() {
  local label="$1" out="$DIR/$1.snap"
  : > "$out"
  local n=0
  for b in $(brokers); do
    # `rpk group list` then describe each: the group's STATE and its summed
    # committed offset. Both are needed -- a group can report Stable and still
    # have stopped committing, which is the shape being hunted.
    local groups
    groups="$(kubectl -n "$NS" exec "$b" -c redpanda -- rpk group list 2>/dev/null \
               | awk 'NR>1 && NF>=2 {print $2}' | sort -u)"
    for g in $groups; do
      local desc state committed lag
      desc="$(kubectl -n "$NS" exec "$b" -c redpanda -- rpk group describe "$g" 2>/dev/null)"
      state="$(printf '%s' "$desc" | awk '/^STATE/{print $2}')"
      committed="$(printf '%s' "$desc" \
        | awk '$1 ~ /^[a-z0-9._-]+$/ && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9-]+$/ {s += $3} END {print s+0}')"
      # LAG IS THE THIRD TERM. Without it, "committed did not move" fires on
      # every idle group -- first run reported 44 of them, nearly all stuck at
      # 0 on a declared-idle tier and on known-empty topics. A detector whose
      # signature matches 44 healthy things would bury the one real case,
      # which is the failure mode this was built to catch, arriving in the
      # detector. Same three-term shape as the relay stall probe.
      lag="$(printf '%s' "$desc" | awk '/^TOTAL-LAG/{print $2}')"
      printf '%s\t%s\t%s\t%s\t%s\n' "$b" "$g" "${state:-UNKNOWN}" "${committed:-0}" "${lag:-0}" >> "$out"
      n=$((n + 1))
    done
  done
  sort -o "$out" "$out"
  echo "snapshot '$label': $n group-on-broker rows -> $out"
}

diff_snaps() {
  local a="$DIR/$1.snap" b="$DIR/$2.snap"
  [ -f "$a" ] || { echo "missing snapshot: $a" >&2; exit 2; }
  [ -f "$b" ] || { echo "missing snapshot: $b" >&2; exit 2; }

  echo "comparing '$1' -> '$2'"
  echo
  # THE WEDGE SIGNATURE: present in both, state still looks fine, committed
  # offset did not move. Reported separately from groups that changed state,
  # because a group that went Empty is visible to anyone and this one is not.
  local wedged=0 changed=0 gone=0 rows=0
  local idle=0
  while IFS=$'\t' read -r broker group state committed lag; do
    rows=$((rows + 1))
    local after
    after="$(awk -F'\t' -v b="$broker" -v g="$group" '$1==b && $2==g {print $3"\t"$4"\t"$5}' "$b")"
    if [ -z "$after" ]; then
      printf "  GONE     %-28s %-44s (was %s)\n" "$broker" "$group" "$state"
      gone=$((gone + 1)); continue
    fi
    local state2 committed2 lag2 rest
    state2="${after%%$'\t'*}"; rest="${after#*$'\t'}"
    committed2="${rest%%$'\t'*}"; lag2="${rest##*$'\t'}"

    if [ "$state" != "$state2" ]; then
      printf "  STATE    %-28s %-44s %s -> %s\n" "$broker" "$group" "$state" "$state2"
      changed=$((changed + 1))
      continue
    fi
    [ "$state2" = "Stable" ] || continue
    [ "$committed2" = "$committed" ] || continue

    # Committed did not move. THE THIRD TERM decides what that means: with lag
    # waiting there is work it is not doing (a wedge); with no lag there is
    # nothing to do (an idle group, and saying so is not a finding).
    case "$lag2" in ''|*[!0-9]*) lag2=0 ;; esac
    if [ "$lag2" -gt 0 ]; then
      printf "  WEDGED   %-28s %-44s Stable, committed stuck at %s, LAG %s\n" \
             "$broker" "$group" "$committed" "$lag2"
      wedged=$((wedged + 1))
    else
      idle=$((idle + 1))
    fi
  done < "$a"

  echo
  echo "$rows group(s) compared: $changed changed state, $gone disappeared,"
  echo "  $wedged WEDGED (Stable, committed frozen, lag waiting), $idle idle (frozen, no lag)"
  if [ "$wedged" -gt 0 ]; then
    echo
    echo "WEDGED IS THE UD-14 SIGNATURE: the broker still counts the group as a"
    echo "healthy member, its pod reads 1/1 Running, there is work waiting, and"
    echo "it is committing nothing. That is the state four clients held for 3.5"
    echo "hours on 2026-09-09 and the one a rollout has never been watched for."
    return 1
  fi
  echo
  echo "No group was Stable with lag waiting and a frozen offset. The idle"
  echo "count is NOT a finding: those groups have nothing to consume."
  return 0
}

if [ "${1:-}" = "--diff" ]; then
  diff_snaps "${2:?need snapshot A}" "${3:?need snapshot B}"
else
  snapshot "${1:?need a label}"
fi
