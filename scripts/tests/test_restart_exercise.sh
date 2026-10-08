#!/usr/bin/env bash
# ===========================================================================
# test_restart_exercise.sh -- offline proof for restart-exercise.sh and for
# the RESET_HALT_BEFORE_PHASE fault-injection knob in reset-scenario.sh.
#
# `kubectl` is a stub on PATH: `get` answers the reset-record ConfigMap and
# the Service port; `port-forward` starts a stub HTTP server standing in for
# exercise-control (it records every request). The reset script is replaced
# through the RESET_SCRIPT seam by a stub that exits with STUB_RESET_RC.
#
# Cases:
#   T1  reset exits 2          -> "RESTART NOT SENT", exit 2, no request at all
#   T2  reset 0, status shows the zero -> exactly one POST /exercise/op/restart
#   T3  control answers 409    -> exit 4, "RESTART REFUSED: <reason>"
#   T6  control 200 but body status 503 -> exit 6, "RESTART NOT ACCEPTED"
#   T4  the zero never appears -> exit 3, no POST
#   T5  the port-forward process is gone after every case above
#   K   RESET_HALT_BEFORE_PHASE=2 (SOURCE_ONLY seam) -> exit 2, the phase-2
#       marker is never printed; unset -> the marker is printed (no-op)
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WRAPPER="${WRAPPER:-$HERE/../restart-exercise.sh}"
RESET="$HERE/../reset-scenario.sh"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

mkdir -p "$TMP/bin"
ZERO="2026-10-07T12:00:00Z"

cat > "$TMP/srv.py" <<'PYEOF'
import json, os, sys
from http.server import BaseHTTPRequestHandler, HTTPServer
LOG = os.environ["STUB_REQ_LOG"]
SEES = os.environ.get("STUB_SEES_ZERO", "")
CODE = int(os.environ.get("STUB_RESTART_CODE", "200"))
ASTATUS = int(os.environ.get("STUB_ADAPTER_STATUS", "200"))
class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def _out(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code); self.send_header("Content-Length", str(len(b)))
        self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        open(LOG, "a").write("GET %s\n" % self.path)
        self._out(200, {"reset": {"measured_zero_at": SEES or None, "verdict": "PASS"}})
    def do_POST(self):
        n = int(self.headers.get("Content-Length", 0) or 0)
        if n: self.rfile.read(n)
        open(LOG, "a").write("POST %s subject=%s\n" % (self.path, self.headers.get("X-OpenDDIL-Subject")))
        if CODE == 409:
            self._out(409, {"error": "reset required", "reason": "stale"})
        else:
            self._out(CODE, {"op": "restart", "status": ASTATUS,
                             "error": None if 200 <= ASTATUS < 300 else "adapter refused"})
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF

cat > "$TMP/bin/kubectl" <<KEOF
#!/usr/bin/env bash
case "\$1" in
  get)
    case "\$*" in
      *configmap*) printf '{"measured_zero_at": "$ZERO", "verdict": "PASS"}' ;;
      *svc*)       printf '8095' ;;
    esac ;;
  port-forward)
    last="\${@: -1}"; local_port="\${last%%:*}"
    echo "\$\$" > "$TMP/pf.pid"
    exec "$PY" "$TMP/srv.py" "\$local_port" ;;
esac
KEOF
chmod +x "$TMP/bin/kubectl"

cat > "$TMP/reset-stub.sh" <<'SEOF'
#!/usr/bin/env bash
echo "stub reset ran: $*"
exit "${STUB_RESET_RC:-0}"
SEOF
chmod +x "$TMP/reset-stub.sh"

run_case() {  # $1 = name; env STUB_* set by caller
  rm -f "$TMP/req.log" "$TMP/pf.pid"; : > "$TMP/req.log"
  PATH="$TMP/bin:$PATH" RESET_SCRIPT="$TMP/reset-stub.sh" STUB_REQ_LOG="$TMP/req.log" \
    POLL_INTERVAL_S=1 POLL_TIMEOUT_S="${POLL_TIMEOUT_S:-6}" \
    bash "$WRAPPER" --release rel --namespace ns --dry-run > "$TMP/$1.out" 2>&1
  RC=$?
}
pf_gone() {
  [ ! -f "$TMP/pf.pid" ] && return 0
  sleep 1
  ! kill -0 "$(cat "$TMP/pf.pid")" 2>/dev/null
}
posts() { grep -c '^POST ' "$TMP/req.log"; }

# T1
STUB_RESET_RC=2 STUB_SEES_ZERO="$ZERO" run_case t1
if [ "$RC" = 2 ] && grep -q "RESTART NOT SENT: reset exited 2" "$TMP/t1.out" && [ ! -s "$TMP/req.log" ] && [ ! -f "$TMP/pf.pid" ]; then
  pass "T1 reset rc 2: not sent, nothing called"; else fail "T1 (rc=$RC)"; cat "$TMP/t1.out"; fi

# T2
STUB_RESET_RC=0 STUB_SEES_ZERO="$ZERO" STUB_RESTART_CODE=200 run_case t2
if [ "$RC" = 0 ] && [ "$(posts)" = 1 ] && grep -q "POST /exercise/op/restart subject=operator-script" "$TMP/req.log" \
   && grep -q "RESTART SENT" "$TMP/t2.out"; then pass "T2 one POST, subject operator-script"; else fail "T2 (rc=$RC)"; cat "$TMP/t2.out"; fi
pf_gone && pass "T5 port-forward gone after T2" || fail "T5 after T2"

# T3
STUB_RESET_RC=0 STUB_SEES_ZERO="$ZERO" STUB_RESTART_CODE=409 run_case t3
if [ "$RC" = 4 ] && [ "$(posts)" = 1 ] && grep -q "RESTART REFUSED: stale" "$TMP/t3.out"; then
  pass "T3 409 -> exit 4"; else fail "T3 (rc=$RC)"; cat "$TMP/t3.out"; fi
pf_gone && pass "T5 port-forward gone after T3" || fail "T5 after T3"

# T6
STUB_RESET_RC=0 STUB_SEES_ZERO="$ZERO" STUB_RESTART_CODE=200 STUB_ADAPTER_STATUS=503 run_case t6
if [ "$RC" = 6 ] && [ "$(posts)" = 1 ] && ! grep -q "RESTART SENT" "$TMP/t6.out"    && grep -q "RESTART NOT ACCEPTED: adapter status 503 error adapter refused" "$TMP/t6.out"; then
  pass "T6 control 200, adapter 503 -> exit 6, not sent"; else fail "T6 (rc=$RC)"; cat "$TMP/t6.out"; fi
pf_gone && pass "T5 port-forward gone after T6" || fail "T5 after T6"

# T4
STUB_RESET_RC=0 STUB_SEES_ZERO="2026-01-01T00:00:00Z" POLL_TIMEOUT_S=3 run_case t4
if [ "$RC" = 3 ] && [ "$(posts)" = 0 ] && grep -q "RESTART NOT SENT: exercise-control does not yet see the zero at $ZERO" "$TMP/t4.out"; then
  pass "T4 zero never appears -> exit 3, no POST"; else fail "T4 (rc=$RC)"; cat "$TMP/t4.out"; fi
pf_gone && pass "T5 port-forward gone after T4" || fail "T5 after T4"

# K: the fault-injection knob, via the SOURCE_ONLY seam
knob() {  # $1 = RESET_HALT_BEFORE_PHASE value ("" = unset)
  (
    export RESET_SCENARIO_SOURCE_ONLY=1 NS=ns RELEASE=rel
    [ -n "$1" ] && export RESET_HALT_BEFORE_PHASE="$1"
    set --
    . "$RESET"
    set +e
    ph2() { echo "PHASE-2-MARKER"; }
    run_phase "2 quiesce" ph2
    echo "AFTER"
  ) > "$TMP/knob.out" 2> "$TMP/knob.err"
  RC=$?
}
knob 2
if [ "$RC" = 2 ] && ! grep -q PHASE-2-MARKER "$TMP/knob.out" \
   && grep -q "HALT: injected halt before phase 2 (RESET_HALT_BEFORE_PHASE)" "$TMP/knob.err"; then
  pass "K halt before phase 2: exit 2, marker never printed"; else fail "K (rc=$RC)"; cat "$TMP/knob.out" "$TMP/knob.err"; fi
knob ""
if [ "$RC" = 0 ] && grep -q PHASE-2-MARKER "$TMP/knob.out"; then pass "K unset is a no-op"; else fail "K unset (rc=$RC)"; fi
knob 3
if [ "$RC" = 0 ] && grep -q PHASE-2-MARKER "$TMP/knob.out"; then pass "K other phase is a no-op"; else fail "K other (rc=$RC)"; fi

exit "$FAIL"
