#!/usr/bin/env bash
# ===========================================================================
# test_reset_electric_clear.sh -- offline proof for phase 7 (electric) in
# reset-scenario.sh: the REAL phase7_electric, _electric_instance, the Job
# manifest builder and the discovery function, against a file-backed kubectl
# stub (the instances run in background subshells, so state lives in files).
#
# Cases:
#   1. PVC instance: scale to 0, Job created (guard + clear, right claim),
#      scale back to the recorded replicas, result "cleared".
#   2. Guard refusal (the Job Fails with a REFUSED log): result "refused",
#      the phase returns 1, scale-back still happens.
#   3. emptyDir instance: pod-delete path, no Job.
#   4. Discovery drops a Completed pod and a terminating pod (F-1020-6d), and
#      the Deployment regex takes dashed tier ids but nothing else.
#   5. DRY_RUN: no scale, create or delete.
#   6. Scale-down never completes: result "timeout", no Job, scale-back made.
#   7. The REAL guard script (pulled out of the manifest) refuses a live
#      Deployment and passes a scaled-down one.
# Mutations (red-checks) are done against a copy: set SCRIPT to the copy.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"
PY="${PY:-python3}"
command -v "$PY" >/dev/null 2>&1 || PY="py -3"

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

ST="$(mktemp -d)"
trap 'rm -rf "$ST"' EXIT
CALLS="$ST/calls.log"
HUB="${RELEASE}-electric-sync"
CLAIM="${RELEASE}-electric-sync-data"

ELECTRIC_POLL_S=0
ELECTRIC_SCALE_WAIT_S=2
ELECTRIC_JOB_WAIT_S=2
ELECTRIC_BACK_WAIT_S=2
RESET_RUNNER_IMAGE="runner:test"
ELECTRIC_IMAGE="electric:test"
IMAGE_PULL_SECRETS="regcred"
export ELECTRIC_IMAGE RESET_RUNNER_IMAGE IMAGE_PULL_SECRETS

# State files per Deployment D: $ST/D.spec (replicas), $ST/D.claim (PVC claim
# name, empty = emptyDir), $ST/stuck (scale-down never takes effect),
# $ST/jobmode (cleared|refused). Only the call shapes reset-scenario.sh makes.
kubectl() {
  local argstr="$*" d
  case "$argstr" in
    "get deploy -n $NS "*"-o jsonpath={.spec.replicas}")
      d="$5"; cat "$ST/$d.spec" ;;
    "get deploy -n $NS "*"electric-data"*)
      d="$5"; cat "$ST/$d.claim" 2>/dev/null ;;
    "get deploy -n $NS "*"-o jsonpath={.spec.replicas}{\"|\"}"*)
      d="$5"
      local spec; spec="$(cat "$ST/$d.spec")"
      if [ -f "$ST/stuck" ]; then printf '%s|%s|%s' "$spec" "1" "1"
      else printf '%s|%s|%s' "$spec" "$spec" "$spec"; fi ;;
    "get deploy -n $NS "*"-o go-template="*) printf 'app=electric,' ;;
    "get pods -n $NS -l "*"-o name")
      echo "$argstr" >> "$ST/podargs.log"
      [ -f "$ST/podsfail" ] && return 1
      if [ -f "$ST/stuck" ]; then echo "pod/x"; fi ;;
    "get pvc -n $NS "*) echo "persistentvolumeclaim/x" ;;
    "scale deploy -n $NS "*)
      d="$5"; local n="${argstr##*--replicas=}"
      echo "scale $d $n" >> "$CALLS"
      echo "$n" > "$ST/$d.spec"
      return 0 ;;
    "create -n $NS -f -")
      echo "create" >> "$CALLS"; cat > "$ST/job.yaml" ;;
    "get job -n $NS "*)
      case "$(cat "$ST/jobmode" 2>/dev/null)" in
        refused) printf '|1|True' ;;
        *) printf '1||' ;;
      esac ;;
    "logs -n $NS "*"-c clear")
      echo "CLEARED: x entries_before=12 entries_after=0" ;;
    "logs -n $NS "*"-c guard")
      [ "$(cat "$ST/jobmode" 2>/dev/null)" = refused ] \
        && echo "REFUSED: x replicas=1 ready=1 pods=1" || echo "GUARD-OK: x" ;;
    "delete pod -n $NS "*)
      echo "delete-pod ${argstr##* }" >> "$CALLS" ;;
    "get pods -n $NS -o jsonpath="*)
      # Apply the phase filter the jsonpath asks for to the fixture table.
      awk -F'|' -v f="$argstr" '
        { if (index(f, "phase==\"Running\"") && $2 != "Running") next
          printf "%s\t%s\n", $1, $3 }' "$ST/pods.tbl" ;;
    "get pods -n $NS -o name")
      awk -F'|' '{ print "pod/" $1 }' "$ST/pods.tbl" ;;
    *) echo "test stub: unhandled kubectl call ($argstr)" >&2; return 1 ;;
  esac
}

reset_state() {
  rm -f "$ST"/* 2>/dev/null
  : > "$CALLS"
  echo 1 > "$ST/$HUB.spec"
  echo "$CLAIM" > "$ST/$HUB.claim"
  ELECTRIC_CLEARED_JSON=()
  ELECTRIC_DEPLOYS=("$HUB")
  ELECTRIC_PODS=("${HUB}-5d9f7c-abcde")
  SKIP_ELECTRIC=false
  DRY_RUN=false
}
lineno() { grep -n -m1 -- "$1" "$CALLS" | cut -d: -f1; }

# --- case 1: PVC instance, happy path -----------------------------------
reset_state
phase7_electric > "$ST/p7.out" 2>&1; rc=$?
s0="$(lineno "scale $HUB 0")"; cr="$(lineno create)"; s1="$(lineno "scale $HUB 1")"
if [ "$rc" -eq 0 ] && [ -n "$s0" ] && [ -n "$cr" ] && [ -n "$s1" ] \
   && [ "$s0" -lt "$cr" ] && [ "$cr" -lt "$s1" ]; then
  pass "1a: scale to 0 -> create Job -> scale back to 1, phase rc 0"
else
  fail "1a: order/rc wrong rc=$rc s0=$s0 create=$cr s1=$s1 ($(cat "$CALLS" | tr '\n' ';'))"
fi
y="$ST/job.yaml"
if grep -q "claimName: $CLAIM" "$y" && grep -q "name: guard" "$y" && grep -q "name: clear" "$y" \
   && grep -q "mountPath: /app/persistent" "$y" && grep -q "app.kubernetes.io/component: electric-clear" "$y" \
   && grep -q "openddil.io/reset-run:" "$y" && grep -q "image: \"electric:test\"" "$y" \
   && grep -q "image: \"runner:test\"" "$y" && grep -q "name: regcred" "$y" \
   && grep -q "backoffLimit: 0" "$y" && grep -q "activeDeadlineSeconds: 180" "$y" \
   && grep -q "serviceAccountName: ${RELEASE}-exercise-reset" "$y"; then
  pass "1b: Job has guard + clear, the right claim, labels, images, pull secret, limits"
else
  fail "1b: Job manifest missing pieces ($(cat "$y" 2>/dev/null | head -c 600))"
fi
if $PY -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); assert d["kind"]=="Job"' "$y" 2>/dev/null; then
  pass "1c: Job manifest is valid YAML"
else
  fail "1c: Job manifest does not parse"
fi
if [ "${#ELECTRIC_CLEARED_JSON[@]}" -eq 1 ] \
   && [[ "${ELECTRIC_CLEARED_JSON[0]}" == *'"result": "cleared"'* ]] \
   && [[ "${ELECTRIC_CLEARED_JSON[0]}" == *'"entries_before": 12'* ]] \
   && [[ "${ELECTRIC_CLEARED_JSON[0]}" == *'"mode": "pvc"'* ]] \
   && [[ "${ELECTRIC_CLEARED_JSON[0]}" == *"\"instance\": \"$HUB\""* ]]; then
  pass "1d: record result cleared, entries_before 12, names the instance"
else
  fail "1d: record wrong: ${ELECTRIC_CLEARED_JSON[*]}"
fi

# --- case 2: guard refusal ----------------------------------------------
reset_state
echo refused > "$ST/jobmode"
phase7_electric > "$ST/p7.out" 2>&1; rc=$?
cr="$(lineno create)"; s1="$(lineno "scale $HUB 1")"
if [ "$rc" -eq 1 ] && [[ "${ELECTRIC_CLEARED_JSON[0]:-}" == *'"result": "refused"'* ]] \
   && [ -n "$cr" ] && [ -n "$s1" ] && [ "$cr" -lt "$s1" ]; then
  pass "2: refused -> result refused, phase rc 1, scale-back still happens"
else
  fail "2: refusal handling wrong rc=$rc rec=${ELECTRIC_CLEARED_JSON[*]:-} calls=$(tr '\n' ';' < "$CALLS")"
fi

# --- case 3: emptyDir instance ------------------------------------------
reset_state
: > "$ST/$HUB.claim"
phase7_electric > "$ST/p7.out" 2>&1; rc=$?
if [ "$rc" -eq 0 ] && grep -q "delete-pod ${HUB}-5d9f7c-abcde" "$CALLS" \
   && ! grep -q "^create" "$CALLS" && ! grep -q "^scale" "$CALLS" \
   && [[ "${ELECTRIC_CLEARED_JSON[0]:-}" == *'"result": "pod-deleted"'* ]] \
   && [[ "${ELECTRIC_CLEARED_JSON[0]:-}" == *'"mode": "pod-delete"'* ]]; then
  pass "3: emptyDir -> pod deleted, no Job, no scaling, result pod-deleted"
else
  fail "3: emptyDir path wrong rc=$rc calls=$(tr '\n' ';' < "$CALLS") rec=${ELECTRIC_CLEARED_JSON[*]:-}"
fi

# --- case 4: discovery ----------------------------------------------------
reset_state
cat > "$ST/pods.tbl" <<EOF
${RELEASE}-electric-sync-aaa-11111|Running|
${RELEASE}-tier-electric-edge-01-bbb-22222|Running|
${RELEASE}-tier-electric-edge-02-ccc-33333|Succeeded|
${RELEASE}-electric-sync-ddd-44444|Running|2026-10-20T00:00:00Z
${RELEASE}-postgres-hq-0|Running|
EOF
got="$(discover_electric_pods | tr '\n' ' ')"
if [ "$got" = "${RELEASE}-electric-sync-aaa-11111 ${RELEASE}-tier-electric-edge-01-bbb-22222 " ]; then
  pass "4a: discovery keeps only Running, non-terminating Electric pods"
else
  fail "4a: discovery wrong: '$got'"
fi
n=0
for name in ${RELEASE}-electric-sync ${RELEASE}-tier-electric-edge-01 ${RELEASE}-tier-electric-region-east \
            ${RELEASE}-tier-electric-pep-only-x-extra-; do
  [[ "$name" =~ $ELECTRIC_DEPLOY_REGEX ]] && n=$((n + 1))
done
neg=0
for name in ${RELEASE}-electric-sync-data ${RELEASE}-electric-sync-x ${RELEASE}-tier-electric- \
            ${RELEASE}-postgres-hq other-electric-sync; do
  [[ "$name" =~ $ELECTRIC_DEPLOY_REGEX ]] && neg=$((neg + 1))
done
if [ "$n" -eq 3 ] && [ "$neg" -eq 0 ]; then
  pass "4b: Deployment regex takes hub + dashed tier ids and nothing else"
else
  fail "4b: regex matched $n of 3 wanted and $neg unwanted"
fi

# --- case 5: dry run ----------------------------------------------------
reset_state
DRY_RUN=true
phase7_electric > "$ST/p7.out" 2>&1; rc=$?
DRY_RUN=false
if [ "$rc" -eq 0 ] && [ ! -s "$CALLS" ] && [[ "${ELECTRIC_CLEARED_JSON[0]:-}" == *'"result": "dry-run"'* ]]; then
  pass "5: dry run -> no scale/create/delete, result dry-run"
else
  fail "5: dry run mutated or mis-recorded rc=$rc calls=$(tr '\n' ';' < "$CALLS") rec=${ELECTRIC_CLEARED_JSON[*]:-}"
fi

# --- case 6: scale-down never completes -----------------------------------
reset_state
: > "$ST/stuck"
phase7_electric > "$ST/p7.out" 2>&1; rc=$?
if [ "$rc" -eq 1 ] && [[ "${ELECTRIC_CLEARED_JSON[0]:-}" == *'"result": "timeout"'* ]] \
   && ! grep -q "^create" "$CALLS" && grep -q "scale $HUB 1" "$CALLS" \
   && grep -q "still up" "$ST/p7.out"; then
  pass "6: stuck scale-down -> timeout, no Job, scaled back, line names what is up"
else
  fail "6: stuck handling wrong rc=$rc rec=${ELECTRIC_CLEARED_JSON[*]:-} calls=$(tr '\n' ';' < "$CALLS")"
fi

# --- case 7: the real guard script ----------------------------------------
reset_state
phase7_electric > "$ST/p7.out" 2>&1
guard="$ST/guard.sh"
$PY -c '
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
open(sys.argv[2], "w", newline="\n").write(d["spec"]["template"]["spec"]["initContainers"][0]["args"][0])
' "$ST/job.yaml" "$guard" 2>/dev/null
mkdir -p "$ST/gbin"
cat > "$ST/gbin/kubectl" <<'GK'
#!/usr/bin/env bash
case "$*" in
  *"jsonpath={.spec.replicas}"*) echo "${G_SPEC:-0}" ;;
  *"jsonpath={.status.readyReplicas}"*) echo "${G_READY:-}" ;;
  *go-template*) printf 'app=electric,' ;;
  *"get pods"*) for _ in $(seq 1 "${G_PODS:-0}"); do echo pod/x; done ;;
esac
GK
chmod +x "$ST/gbin/kubectl"
g_out="$(PATH="$ST/gbin:$PATH" NS=$NS DEPLOY=$HUB INSTANCE=$HUB G_SPEC=1 G_READY=1 G_PODS=1 bash "$guard" 2>&1)"; g_rc=$?
g_ok="$(PATH="$ST/gbin:$PATH" NS=$NS DEPLOY=$HUB INSTANCE=$HUB G_SPEC=0 G_READY= G_PODS=0 bash "$guard" 2>&1)"; g_ok_rc=$?
g_pod="$(PATH="$ST/gbin:$PATH" NS=$NS DEPLOY=$HUB INSTANCE=$HUB G_SPEC=0 G_READY= G_PODS=1 bash "$guard" 2>&1)"; g_pod_rc=$?
if [ "$g_rc" -ne 0 ] && [[ "$g_out" == "REFUSED: $HUB replicas=1 ready=1 pods=1" ]] \
   && [ "$g_ok_rc" -eq 0 ] && [ "$g_pod_rc" -ne 0 ] && [[ "$g_pod" == *"pods=1"* ]]; then
  pass "7: guard refuses replicas=1 and a lingering pod, passes 0/0/0"
else
  fail "7: guard wrong: rc=$g_rc out='$g_out' ok_rc=$g_ok_rc pod_rc=$g_pod_rc"
fi

# --- case 8: pod reads fail closed and exclude Failed/Succeeded pods ------
# 8a: the real guard with `get pods` failing must REFUSE (not pass with 0).
cat > "$ST/gbin/kubectl" <<'GK'
#!/usr/bin/env bash
case "$*" in
  *"jsonpath={.spec.replicas}"*) echo 0 ;;
  *"jsonpath={.status.readyReplicas}"*) echo "" ;;
  *go-template*) printf 'app=electric,' ;;
  *"get pods"*) echo "$*" >> "$G_ARGS"; [ -n "${G_PODSFAIL:-}" ] && exit 1; exit 0 ;;
esac
GK
g_out="$(G_ARGS="$ST/gargs.log" G_PODSFAIL=1 PATH="$ST/gbin:$PATH" NS=$NS DEPLOY=$HUB INSTANCE=$HUB bash "$guard" 2>&1)"; g_rc=$?
if [ "$g_rc" -ne 0 ] && [[ "$g_out" == *"REFUSED: $HUB pods unreadable"* ]] && [[ "$g_out" != *GUARD-OK* ]]; then
  pass "8a: guard refuses when kubectl get pods fails"
else
  fail "8a: guard failed open rc=$g_rc out='$g_out'"
fi
# 8b: _electric_state returns non-zero when `get pods` fails.
: > "$ST/podsfail"
_electric_state "$HUB" > /dev/null 2>&1; s_rc=$?
rm -f "$ST/podsfail"
if [ "$s_rc" -ne 0 ]; then
  pass "8b: _electric_state fails when kubectl get pods fails"
else
  fail "8b: _electric_state returned 0 with get pods failing"
fi
# 8c: both pod counts pass the field selector that drops Failed/Succeeded.
: > "$ST/podargs.log"
_electric_state "$HUB" > /dev/null 2>&1
G_ARGS="$ST/gargs.log" PATH="$ST/gbin:$PATH" NS=$NS DEPLOY=$HUB INSTANCE=$HUB bash "$guard" >/dev/null 2>&1
if grep -q -- '--field-selector=status.phase!=Succeeded,status.phase!=Failed' "$ST/podargs.log"    && grep -q -- '--field-selector=status.phase!=Succeeded,status.phase!=Failed' "$ST/gargs.log"; then
  pass "8c: _electric_state and the guard both exclude Failed/Succeeded pods"
else
  fail "8c: field selector missing (state: $(cat "$ST/podargs.log") guard: $(cat "$ST/gargs.log"))"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_reset_electric_clear: ALL PASS"
  exit 0
fi
echo "test_reset_electric_clear: FAILED"
exit 1
