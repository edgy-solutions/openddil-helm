#!/usr/bin/env bash
# ===========================================================================
# restart-exercise.sh -- the one operator action for "restart the exercise"
# ===========================================================================
#
# USAGE
#   restart-exercise.sh --release R --namespace N [reset-scenario.sh args...]
#   in-cluster (the chart's reset Job):
#     EXERCISE_CONTROL_URL=http://<svc>:<port> [RESTART_SUBJECT=<subject>] \
#       restart-exercise.sh --release R --namespace N [reset-scenario.sh args...]
#
# A restart is only ever sent after a reset that measured zero. This script
# runs the reset first and sends the restart only if that reset exited 0:
#
#   1. reset-scenario.sh (same directory; RESET_SCRIPT overrides it for
#      tests) runs with the remaining args, output streamed. Non-zero exit ->
#      "RESTART NOT SENT" and that exit code; nothing else is called.
#   2. The measured_zero_at it recorded is read from the ConfigMap
#      <R>-exercise-reset-record (key record.json).
#   3. A kubectl port-forward to svc/<R>-exercise-control is opened (unless
#      EXERCISE_CONTROL_URL is set: then there is no service lookup and no
#      port-forward, and that URL is used as is), and
#      GET /exercise/status is polled (every POLL_INTERVAL_S, default 5, up to
#      POLL_TIMEOUT_S, default 180) until exercise-control reports that same
#      measured_zero_at -- the mounted ConfigMap lags by the kubelet sync.
#      Timeout -> exit 3. The port-forward is killed on every exit path.
#   4. POST /exercise/op/restart. 409 -> exit 4; other non-200 -> exit 5. On
#      200 control only says it forwarded the op: the adapter's own answer is
#      the body's "status". 2xx -> exit 0; anything else -> exit 6.
#
# EXIT CODES  0 sent | 3 control never saw the zero | 4 refused (409) |
#             5 unexpected answer | 6 control forwarded it, adapter did not
#             accept (non-2xx or no status) | reset's own code when the reset failed |
#             1 usage or environment error
#
# WHO THIS TALKS TO. exercise-control directly, through a port-forward. That
# is a cluster-admin operator path: it does not pass the gateway, and the
# subject is recorded as "operator-script". The gate in exercise-control (a
# restart needs a fresh measured zero that no earlier restart has used)
# applies all the same -- it lives in the service, not in this script.
#
# In-cluster it is run by the chart's reset Job, launched by exercise-control's
# reset op. It POSTs to the control Service directly (the chart's NetworkPolicy
# admits the Job's pods), with RESTART_SUBJECT as the subject (allowed
# characters A-Za-z0-9._@:- , up to 96). Control's restart gate applies as
# always. The Job has backoffLimit 0, so a halted reset is never retried.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESET_SCRIPT="${RESET_SCRIPT:-$HERE/reset-scenario.sh}"
POLL_INTERVAL_S="${POLL_INTERVAL_S:-5}"
POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-180}"
SUBJECT="${RESTART_SUBJECT:-operator-script}"

REL=""; NSP=""; PASS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --release)   REL="${2:-}"; shift 2 || break ;;
    --namespace) NSP="${2:-}"; shift 2 || break ;;
    *) PASS+=("$1"); shift ;;
  esac
done
if [ -z "$REL" ] || [ -z "$NSP" ]; then
  echo "usage: restart-exercise.sh --release R --namespace N [reset-scenario.sh args...]" >&2
  exit 1
fi

if ! printf '%s' "$SUBJECT" | grep -Eq '^[A-Za-z0-9._@:-]{1,96}$'; then
  echo "usage: RESTART_SUBJECT must match [A-Za-z0-9._@:-]{1,96}" >&2
  exit 1
fi

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "restart-exercise: no python on PATH" >&2; exit 1; }

PF_PID=""
TMPD="$(mktemp -d)"
cleanup() {
  if [ -n "$PF_PID" ]; then
    kill "$PF_PID" 2>/dev/null
    wait "$PF_PID" 2>/dev/null
  fi
  rm -rf "$TMPD"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

# json_get KEY [PATH...] : print a nested key from JSON on stdin ("" if absent)
json_get() {
  "$PY" -c '
import json, sys
try:
    d = json.load(sys.stdin)
    for k in sys.argv[1:]:
        d = d[k]
    print("" if d is None else d)
except Exception:
    print("")
' "$@" | tr -d '\r'
}

# --- 1. the reset -----------------------------------------------------------
NS="$NSP" RELEASE="$REL" bash "$RESET_SCRIPT" ${PASS[@]+"${PASS[@]}"}
rc=$?
if [ "$rc" -ne 0 ]; then
  echo "RESTART NOT SENT: reset exited $rc — no measured zero"
  exit "$rc"
fi

# --- 2. the zero the reset recorded -----------------------------------------
ZERO="$(kubectl get configmap "${REL}-exercise-reset-record" -n "$NSP" \
          -o jsonpath='{.data.record\.json}' 2>/dev/null | json_get measured_zero_at)"
if [ -z "$ZERO" ]; then
  echo "RESTART NOT SENT: no measured_zero_at in ConfigMap ${REL}-exercise-reset-record"
  exit 3
fi
if [ -z "${EXERCISE_CONTROL_URL:-}" ]; then
  SVC_PORT="$(kubectl get svc "${REL}-exercise-control" -n "$NSP" \
                -o jsonpath='{.spec.ports[0].port}' 2>/dev/null | tr -d '\r')"
  [ -n "$SVC_PORT" ] || { echo "restart-exercise: cannot read the ${REL}-exercise-control service port" >&2; exit 1; }
fi

# --- 3. port-forward, then wait until control sees that zero ----------------
if [ -n "${EXERCISE_CONTROL_URL:-}" ]; then
  BASE="${EXERCISE_CONTROL_URL%/}"
else
  LOCAL_PORT="$("$PY" -c '
import socket
s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' | tr -d '\r')"
  kubectl port-forward -n "$NSP" "svc/${REL}-exercise-control" "${LOCAL_PORT}:${SVC_PORT}" \
    >"$TMPD/pf.log" 2>&1 &
  PF_PID=$!
  BASE="http://127.0.0.1:${LOCAL_PORT}"
fi

waited=0
seen=""
while :; do
  seen="$(curl -s -m 5 "$BASE/exercise/status" 2>/dev/null | json_get reset measured_zero_at)"
  [ "$seen" = "$ZERO" ] && break
  if [ "$waited" -ge "$POLL_TIMEOUT_S" ]; then
    echo "RESTART NOT SENT: exercise-control does not yet see the zero at $ZERO"
    exit 3
  fi
  sleep "$POLL_INTERVAL_S"
  waited=$(( waited + POLL_INTERVAL_S ))
done

# --- 4. the restart ---------------------------------------------------------
code="$(curl -s -m 30 -o "$TMPD/resp.json" -w '%{http_code}' -X POST \
          -H "X-OpenDDIL-Subject: $SUBJECT" -H 'Content-Type: application/json' \
          -d '{}' "$BASE/exercise/op/restart")"
echo "POST /exercise/op/restart -> HTTP $code"
cat "$TMPD/resp.json" 2>/dev/null; echo
case "$code" in
  200) astatus="$(json_get status <"$TMPD/resp.json")"
       case "$astatus" in
         2[0-9][0-9]) echo "RESTART SENT (adapter $astatus)"; exit 0 ;;
         *) echo "RESTART NOT ACCEPTED: adapter status ${astatus:-none} error $(json_get error <"$TMPD/resp.json")"; exit 6 ;;
       esac ;;
  409) echo "RESTART REFUSED: $(json_get reason <"$TMPD/resp.json")"; exit 4 ;;
  *)   echo "RESTART FAILED: unexpected HTTP $code"; exit 5 ;;
esac
