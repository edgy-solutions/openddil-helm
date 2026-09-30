#!/usr/bin/env bash
# ===========================================================================
# test_reset_ownership.sh — offline proof for SPEC-consumer-declarations.md
# Parts B and C, against the REAL functions in reset-scenario.sh (not a
# reimplementation of them).
# ===========================================================================
#
# reset-scenario.sh talks to a live cluster (require-cluster.sh's own guard
# `exit`s if it can't), so this test sources it with
# RESET_SCENARIO_SOURCE_ONLY=1 (see the matching guard around the
# require-cluster.sh source line, and the one just above "# main" at the
# bottom of the file) to load its function definitions without running the
# cluster check or any phase. It then overrides the four functions that are
# reset-scenario.sh's ONLY points of contact with a live cluster —
# `census_groups`, `declared_consumers`, `restate_subscriptions`,
# `_pods_of_workload` — with fixed fixture data, so everything downstream of
# them (build_declared_owner_map, derive_quiesce_set, assert_consumers_
# declared, _scan_live_consumers) runs its own real logic against known
# input and a known expected output.
#
# Fixture: egress-gate-c2 on the hq broker, reached through
# ${RELEASE}-toxiproxy under the OLD ownership resolution (see egress.yaml's
# own annotation comment and the spec's Problem section) — the measured case
# an IP-based owner walk could never see past PROXY/openddil-toxiproxy. This
# is the one case the whole spec exists to fix, so it is the one this test
# proves against the real functions, not a synthetic stand-in for it.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../reset-scenario.sh"

NS="openddil"
RELEASE="openddil"
export NS RELEASE

RESET_SCENARIO_SOURCE_ONLY=1
export RESET_SCENARIO_SOURCE_ONLY
# `source` inherits this script's OWN positional parameters, not an empty
# list — cleared here so reset-scenario.sh's arg-parsing while loop (still
# top-level code, still runs before the SOURCE_ONLY guard near its "# main")
# sees $#=0 and falls straight through instead of possibly hitting its own
# "unknown flag" branch, which calls `exit` (not `return`) and would kill
# this test process, not just the sourced script.
set --
# shellcheck source=../reset-scenario.sh
. "$SCRIPT"
# reset-scenario.sh's own `set -euo pipefail` (line 70) now applies to THIS
# shell too — sourcing runs in the caller's context, it does not sandbox it.
# This test deliberately calls functions that are SUPPOSED to return 1
# (assert_consumers_declared on an undeclared consumer, assert_no_live_
# consumers on a scan that never clears) and inspects that exit code itself,
# so -e has to come back off here or the first such call would kill this
# test process before its assertion ever runs.
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# Every case below rebuilds the declared-owner map from scratch: it is
# cached per-shell (DECLARED_MAP_BUILT), and different cases here declare
# (or undeclare) different things on purpose.
reset_owner_cache() {
  DECLARED_MAP_BUILT=false
  DECLARED_OWNER=()
  DECLARED_OWNER_DUPES=()
  RESTATE_OWNER_BY_GROUP=()
  WORKLOAD_PODS_CACHE=()
}

HQ_POD="${RELEASE}-redpanda-hq-0"
REDPANDA_PODS=("$HQ_POD")
PRODUCER_DEPLOYS=()
RESTATE_PODS=()

# No family-floor noise in this fixture — the spec's own item 3 (floor) is
# unchanged and not what this test is proving.
discover() { :; }

# ---------------------------------------------------------------------------
# (a) A proxied group WITH a declaration lands in derive_quiesce_set's
# output as its real owner, not PROXY/openddil-toxiproxy — the defect this
# whole spec exists to close (egress-gate-c2, measured on the lab).
# ---------------------------------------------------------------------------
census_groups() {
  # $1 = pod. One live group (egress-gate-c2) holding the target topic.
  printf 'MEMBERS\tegress-gate-c2\t1\tStable\t10.0.0.1\n'
  printf 'TOPIC\tegress-gate-c2\thq-egress-status\n'
}
declared_consumers() {
  printf 'hq\tegress-gate-c2\tDeployment/openddil-egress-gate-c2\n'
}
restate_subscriptions() { :; }
_pods_of_workload() { printf '%s\n' "openddil-egress-gate-c2-abc12"; }

reset_owner_cache
derived_out="$(derive_quiesce_set "$HQ_POD|hq-egress-status" 2>/dev/null)"
if printf '%s\n' "$derived_out" | grep -qx 'Deployment/openddil-egress-gate-c2'; then
  pass "(a) declared proxied consumer (egress-gate-c2) appears in derive_quiesce_set as its real owner"
else
  fail "(a) expected Deployment/openddil-egress-gate-c2 in derive_quiesce_set output, got: $derived_out"
fi

# ---------------------------------------------------------------------------
# (b) Remove the declaration (same live group, same members>0) -> assert_
# consumers_declared must refuse: return 1, and name the group.
# ---------------------------------------------------------------------------
declared_consumers() { :; }   # the annotation is gone; the live group is not

reset_owner_cache
pf_out="$(assert_consumers_declared "$HQ_POD|hq-egress-status" 2>&1)"
pf_rc=$?
if [ "$pf_rc" -eq 1 ] && printf '%s\n' "$pf_out" | grep -q '^UNDECLARED CONSUMER: group=egress-gate-c2'; then
  pass "(b) undeclared live consumer (egress-gate-c2) -> assert_consumers_declared returns 1 and reports it"
else
  fail "(b) expected rc=1 and an UNDECLARED CONSUMER line, got rc=$pf_rc output: $pf_out"
fi

# ---------------------------------------------------------------------------
# (c) A members=0 group with no declaration is ORPHAN OFFSETS, not
# UNDECLARED, and does not fail the assertion by itself.
# ---------------------------------------------------------------------------
census_groups() {
  printf 'MEMBERS\torphan-group\t0\tEmpty\t\n'
  printf 'TOPIC\torphan-group\thq-egress-status\n'
}
declared_consumers() { :; }
restate_subscriptions() { :; }

reset_owner_cache
orphan_out="$(assert_consumers_declared "$HQ_POD|hq-egress-status" 2>&1)"
orphan_rc=$?
if [ "$orphan_rc" -eq 0 ] \
   && printf '%s\n' "$orphan_out" | grep -q '^ORPHAN OFFSETS (no members, not blocking): group=orphan-group' \
   && ! printf '%s\n' "$orphan_out" | grep -q 'UNDECLARED CONSUMER'; then
  pass "(c) members=0 undeclared group -> ORPHAN OFFSETS, assertion still passes"
else
  fail "(c) expected rc=0 and an ORPHAN OFFSETS line with no UNDECLARED CONSUMER, got rc=$orphan_rc output: $orphan_out"
fi

# ---------------------------------------------------------------------------
# (d) [Part C] The wall-clock fix. A scan that always fails and takes real
# time (2s sleep, standing in for the ~40s `rpk group describe` census
# assert_no_live_consumers actually pays per attempt) must not let the old
# sleep-sum bug turn a 3s budget into minutes: with QUIESCE_EXPIRY_TIMEOUT=3
# and QUIESCE_EXPIRY_INTERVAL=1, this must return 1 in well under the old
# bug's failure mode (measured 14+ minutes on the lab) — under ~8s wall-clock
# is the proof asked for here (2 scans x 2s + at most one 1s sleep, plus
# scheduling slack).
# ---------------------------------------------------------------------------
_scan_live_consumers() {
  sleep 2
  echo "LIVE CONSUMER: group=stub-always-fails" >&2
  return 1
}
QUIESCE_EXPIRY_TIMEOUT=3
QUIESCE_EXPIRY_INTERVAL=1

d_start="$SECONDS"
assert_no_live_consumers "$HQ_POD|hq-egress-status" >/tmp/_d_out_$$ 2>&1
d_rc=$?
d_elapsed=$((SECONDS - d_start))
rm -f /tmp/_d_out_$$

echo "(d) measured wall-clock: ${d_elapsed}s (TIMEOUT=3 INTERVAL=1, stub always fails)"
if [ "$d_rc" -eq 1 ] && [ "$d_elapsed" -lt 8 ]; then
  pass "(d) always-failing scan returns 1 in ${d_elapsed}s (< 8s) wall-clock, not a sleep-sum"
else
  fail "(d) expected rc=1 in under 8s wall-clock, got rc=$d_rc elapsed=${d_elapsed}s"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_ownership.sh: ALL PASS"
else
  echo "test_reset_ownership.sh: AT LEAST ONE FAILURE" >&2
fi
exit "$FAIL"
