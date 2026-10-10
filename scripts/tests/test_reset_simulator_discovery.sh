#!/usr/bin/env bash
# ===========================================================================
# test_reset_simulator_discovery.sh -- offline proof that reset-scenario.sh
# finds simulators by their declared label, not by a name pattern, against the
# REAL discovery block (sourced, with a `kubectl` function standing in for the
# cluster).
#
# Cases:
#   A. a simulator with the label is a producer whatever its name.
#   B. release-owned producers are still found by name, once each, and a
#      Deployment that matches both lists appears once.
#   C. a dis-sim Deployment WITHOUT the label is not a producer and is named
#      on a NOT A PRODUCER line (a declared exception, not a silent pass).
#   D. an unrelated Deployment is neither.
#   E. SIMULATOR_SELECTOR overrides the label.
# Flip: restore `^dis-sim-edge-` in the name regex and case A (a simulator
# not named dis-sim-edge-*) still passes but case C fails for the unlabelled
# dis-sim-edge-* Deployment; drop discover_simulators and case A fails.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"

NS="openddil"
RELEASE="openddil"
export NS RELEASE

# Deployments in the fake cluster: name|labels
FAKE_DEPLOYS="openddil-logistics-sim|app.kubernetes.io/name=logistics-sim
openddil-sensor-ingest-edge-01|
openddil-egress-intake|
alpha-sim-east|openddil.io/role=simulator,app.kubernetes.io/name=dis-sim
dis-sim-edge-labelled|openddil.io/role=simulator,app.kubernetes.io/name=dis-sim
dis-sim-edge-unlabelled|app.kubernetes.io/name=dis-sim
openddil-faust-regional|
other-thing|"

# kubectl get deploy -n NS [-l SELECTOR] -o name
kubectl() {
  [ "$1 $2" = "get deploy" ] || return 0
  local sel="" a prev=""
  for a in "$@"; do
    [ "$prev" = "-l" ] && sel="$a"
    prev="$a"
  done
  local line name labels ok want
  while IFS='|' read -r name labels; do
    [ -n "$name" ] || continue
    ok=true
    if [ -n "$sel" ]; then
      want="${sel#*=}"; local key="${sel%%=*}"
      case ",$labels," in *",$key=$want,"*) ;; *) ok=false ;; esac
    fi
    $ok && echo "deployment.apps/$name"
  done <<< "$FAKE_DEPLOYS"
  return 0
}

RESET_SCENARIO_SOURCE_ONLY=1
export RESET_SCENARIO_SOURCE_ONLY
set --

OUT="$(. "$SCRIPT" 2>&1; echo "PRODUCERS:${PRODUCER_DEPLOYS[*]}")"
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }
has_producer() { echo "$OUT" | grep "^PRODUCERS:" | tr ' ' '\n' | sed 's/^PRODUCERS://' | grep -qx "$1"; }

has_producer alpha-sim-east && pass "A: labelled simulator with an arbitrary name is a producer" \
  || fail "A: alpha-sim-east not a producer"
has_producer dis-sim-edge-labelled && pass "A: labelled dis-sim-edge-* is a producer" \
  || fail "A: dis-sim-edge-labelled not a producer"

for d in openddil-logistics-sim openddil-sensor-ingest-edge-01 openddil-egress-intake; do
  has_producer "$d" && pass "B: $d found by name" || fail "B: $d missing"
done
n="$(echo "$OUT" | grep "^PRODUCERS:" | tr ' ' '\n' | sed 's/^PRODUCERS://' | grep -cx dis-sim-edge-labelled)"
[ "$n" = 1 ] && pass "B: no duplicates" || fail "B: dis-sim-edge-labelled appears $n times"

has_producer dis-sim-edge-unlabelled && fail "C: unlabelled dis-sim-edge-unlabelled is a producer" \
  || pass "C: unlabelled dis-sim is not a producer"
echo "$OUT" | grep -q "NOT A PRODUCER: dis-sim-edge-unlabelled (no openddil.io/role=simulator label; reset leaves it running)" \
  && pass "C: NOT A PRODUCER line printed" || fail "C: NOT A PRODUCER line missing"
echo "$OUT" | grep -q "NOT A PRODUCER: alpha-sim-east" \
  && fail "C: labelled simulator reported NOT A PRODUCER" || pass "C: labelled simulator not reported"

has_producer other-thing && fail "D: other-thing is a producer" || pass "D: unrelated deployment is not"
has_producer openddil-faust-regional && fail "D: faust is a producer" || pass "D: faust is not"

OUT2="$(SIMULATOR_SELECTOR=app.kubernetes.io/name=dis-sim . "$SCRIPT" 2>&1; echo "PRODUCERS:${PRODUCER_DEPLOYS[*]}")"
echo "$OUT2" | grep "^PRODUCERS:" | tr ' ' '\n' | sed 's/^PRODUCERS://' | grep -qx dis-sim-edge-unlabelled \
  && pass "E: SIMULATOR_SELECTOR override honoured" || fail "E: override ignored"

echo
if [ "$FAIL" = 0 ]; then echo "test_reset_simulator_discovery: ALL PASS"; else echo "test_reset_simulator_discovery: FAILED"; exit 1; fi
