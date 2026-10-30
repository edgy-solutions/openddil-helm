#!/usr/bin/env bash
# ===========================================================================
# test_relay_gate.sh -- offline proof that the two cross-tier relays wait for
# their destination instead of exiting, and that the wait actually behaves.
#
# The relays (edge-hq-bridge `bridge`, tier-uplink `uplink`) use Connect's
# legacy kafka output, which dials its brokers at init and EXITS if it cannot.
# Under a sever that put them in a kubelet back-off (10 .. 300 s) that does not
# react to the network returning. relayGate wraps them in a shell that polls
# the destination, then execs Connect.
#
# A render can carry Secrets, so NO full render is written to disk: helm's
# output is piped through a python filter that keeps only the relay
# Deployments, and only that is written.
#
# Render values: --set tierNode.enabled=true (the chart's own default regions
# and edges then yield 3 edge-hq-bridge and 2 tier-uplink Deployments).
#
# Cases:
#   A. default render: every bridge and uplink has command /bin/sh -c, a script
#      with `nc -z` and `exec /redpanda-connect "$@"`, the original args, and
#      DEST_HOST/DEST_PORT. At least one of each kind.
#   B. relayGate.enabled=false: no command, original args.
#   C. relayStallProbe.enabled=false: DEST_* still present, gate still
#      rendered, no livenessProbe.
#   D. behaviour: nc fails 3 times then succeeds -> 4 nc calls, Connect stub
#      called once with the original args, one "unreachable" and one
#      "reachable after 3" log line.
#   E. behaviour: reachable at once -> 1 nc call, no "unreachable" line.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"
command -v helm >/dev/null 2>&1 || { echo "SKIP: no helm"; exit 2; }
PY=""
for c in python3 python "py -3"; do
  if $c -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with yaml"; exit 2; }

TMP="${KEEP_TMP:-$(mktemp -d)}"; [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$TMP"' EXIT
FAIL=0
fail() { echo "FAIL $*"; FAIL=1; }
pass() { echo "PASS $*"; }

# stdin: helm render. stdout: only the relay Deployments, as JSON lines.
cat > "$TMP/filter.py" <<'PYEOF'
import sys, json, yaml
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "Deployment":
        continue
    n = d["metadata"]["name"]
    if "-edge-hq-bridge-" in n or "-tier-uplink-" in n:
        print(json.dumps(d))
PYEOF

# stdin: filtered JSON lines. argv[1]: mode. Prints one line per problem.
cat > "$TMP/check.py" <<'PYEOF'
import sys, json
mode = sys.argv[1]
want = {"bridge": ["--chilled", "run", "/connect.yaml"], "uplink": ["-c", "/connect/connect.yaml"]}
seen = {"bridge": 0, "uplink": 0}
bad = []
for line in sys.stdin:
    d = json.loads(line)
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] not in want:
            continue
        k = c["name"]; seen[k] += 1
        who = d["metadata"]["name"]
        env = {e["name"] for e in c.get("env", [])}
        cmd = c.get("command")
        if c.get("args") != want[k]:
            bad.append(who + ": args changed: %r" % (c.get("args"),))
        if mode == "off":
            if cmd is not None:
                bad.append(who + ": command rendered with the gate off")
            continue
        if not cmd or cmd[:2] != ["/bin/sh", "-c"] or len(cmd) < 3:
            bad.append(who + ": no /bin/sh -c command"); continue
        if "nc -z" not in cmd[2] or 'exec /redpanda-connect "$@"' not in cmd[2]:
            bad.append(who + ": script lacks nc -z / exec")
        if not {"DEST_HOST", "DEST_PORT"} <= env:
            bad.append(who + ": DEST_HOST/DEST_PORT missing")
        if mode == "noprobe" and c.get("livenessProbe"):
            bad.append(who + ": livenessProbe present with the probe off")
if not (seen["bridge"] and seen["uplink"]):
    bad.append("need >=1 bridge and >=1 uplink, saw %r" % seen)
for b in bad:
    print(b)
print("bridge=%d uplink=%d" % (seen["bridge"], seen["uplink"]), file=sys.stderr)
sys.exit(1 if bad else 0)
PYEOF

# argv[1]: jsonl, argv[2]: out file. Writes the first bridge's gate script.
cat > "$TMP/extract.py" <<'PYEOF'
import sys, json
for line in open(sys.argv[1]):
    d = json.loads(line)
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] == "bridge" and c.get("command"):
            open(sys.argv[2], "w", newline="\n").write(c["command"][2]); sys.exit(0)
sys.exit(1)
PYEOF

render() { # label, then helm args
  local label="$1"; shift
  helm template t "$CHART" --set tierNode.enabled=true "$@" 2>"$TMP/h.err" | $PY "$TMP/filter.py" > "$TMP/$label.jsonl" \
    || { fail "$label: render/filter: $(tail -1 "$TMP/h.err")"; return 1; }
  [ -s "$TMP/$label.jsonl" ] || { fail "$label: no relay Deployments rendered: $(tail -1 "$TMP/h.err")"; return 1; }
}

run_check() { # label mode text
  local out
  out="$($PY "$TMP/check.py" "$2" < "$TMP/$1.jsonl" 2>"$TMP/c.err")"
  if [ $? -eq 0 ]; then pass "$1: $3 ($(cat "$TMP/c.err"))"; else fail "$1: $3"; echo "$out" | head -4; fi
}

render A && run_check A gate "gate, args, DEST_* on every relay"
render B --set relayGate.enabled=false && run_check B off "no command, original args"
render C --set relayStallProbe.enabled=false && run_check C noprobe "DEST_* and gate kept, no liveness"

# Re-render with a 1 s poll so D does not sit 2 s per probe; extract one script.
render P --set relayGate.pollSeconds=1 || exit 1
$PY "$TMP/extract.py" "$TMP/P.jsonl" "$TMP/gate1.sh" || { fail "D/E: could not extract a gate script"; exit 1; }
grep -q 'sleep 1$' "$TMP/gate1.sh" || fail "D: pollSeconds=1 did not reach the script"

mkdir -p "$TMP/bin"
cat > "$TMP/bin/nc" <<NCEOF
#!/bin/sh
# Fails \$(cat nc.fails) times, then succeeds. Counts calls in a file.
c=\$(cat "$TMP/nc.count" 2>/dev/null || echo 0); c=\$((c+1)); echo \$c > "$TMP/nc.count"
[ "\$c" -gt "\$(cat "$TMP/nc.fails")" ]
NCEOF
cat > "$TMP/connect-stub" <<CSEOF
#!/bin/sh
echo "\$*" >> "$TMP/connect.argv"
CSEOF
chmod +x "$TMP/bin/nc" "$TMP/connect-stub"
sed "s#/redpanda-connect#$TMP/connect-stub#" "$TMP/gate1.sh" > "$TMP/gate-run.sh"

gate_run() { # number of nc failures before success
  rm -f "$TMP/nc.count" "$TMP/connect.argv"; echo "$1" > "$TMP/nc.fails"
  PATH="$TMP/bin:$PATH" DEST_HOST=parent.example DEST_PORT=9092 \
    sh "$TMP/gate-run.sh" --chilled run /connect.yaml > "$TMP/gate.log" 2>&1
}

F0=$FAIL
gate_run 3
ncs="$(cat "$TMP/nc.count" 2>/dev/null || echo 0)"
nconn="$(wc -l < "$TMP/connect.argv" 2>/dev/null || echo 0)"
[ "$ncs" -eq 4 ] || fail "D: expected 4 nc calls, saw $ncs"
[ "$nconn" -eq 1 ] && [ "$(cat "$TMP/connect.argv")" = "--chilled run /connect.yaml" ] \
  || fail "D: connect stub not called once with the original args: $(cat "$TMP/connect.argv" 2>/dev/null)"
[ "$(grep -c unreachable "$TMP/gate.log")" -eq 1 ] || fail "D: expected one unreachable line"
[ "$(grep -c 'reachable after 3' "$TMP/gate.log")" -eq 1 ] || fail "D: expected one 'reachable after 3' line"
[ "$FAIL" -eq "$F0" ] && pass "D: 4 nc calls, connect once with original args, 1 unreachable + 1 reachable-after-3 line"

F0=$FAIL
gate_run 0
ncs="$(cat "$TMP/nc.count" 2>/dev/null || echo 0)"
nconn="$(wc -l < "$TMP/connect.argv" 2>/dev/null || echo 0)"
[ "$ncs" -eq 1 ] || fail "E: expected 1 nc call, saw $ncs"
[ "$nconn" -eq 1 ] || fail "E: connect stub not called once"
grep -q unreachable "$TMP/gate.log" && fail "E: unreachable logged though reachable at once"
grep -q 'reachable after' "$TMP/gate.log" && fail "E: 'reachable after' logged though reachable at once"
[ "$FAIL" -eq "$F0" ] && pass "E: reachable at once -> 1 nc call, no wait lines, connect once"

exit $FAIL
