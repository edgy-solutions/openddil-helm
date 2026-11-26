#!/usr/bin/env bash
# ===========================================================================
# test_reports_carry_up_render.sh -- closed failure episodes carry up through
# the tiers, and the tier PEP and frontend are wired to the hub's egress pane.
# Read from a render that never touches disk.
#
# Topology: a hub; region-a under it (a tier with children); managed edges
# edge-a and edge-b under region-a; edge-u, an edge the chart does not manage.
#
# The render is piped into an inline python filter, which prints names and
# counts only. Only values files and stderr go in the temp dir.
#
# Cases:
#   A. failure-episodes is in each managed edge's bridge config and in
#      region-a's uplink config.
#   B. failure-episodes is absent from edge-u's bridge config.
#   C. failure-episodes-withheld is in no relay config.
#   D. releasability on: every tier PEP has OPENDDIL_EGRESS_PANE_URL once, with
#      the hub PEP's value; off: none has it.
#   E. releasability on: every tier frontend has OPENDDIL_EGRESS_PANE_VIA_PEP=on
#      once; off: none has it.
#   F. region-a's deployment.json has reports.closesCarriedUp true.
#   G. edge-a, edge-b and edge-u have no reports key, nor does the hub's.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }
command -v helm >/dev/null 2>&1 || { echo "FAIL: helm not found"; exit 1; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

cat > "$TMP/topology.yaml" <<'YEOF'
tierNode:
  enabled: true
  tiers: [region-a, edge-a, edge-b]
edges:
  - {id: edge-a, region: region-a, udpPort: 62040}
  - {id: edge-b, region: region-a, udpPort: 62041}
  - {id: edge-u, region: region-a, udpPort: 62042}
  - {id: region-a, region: hq, hasChildren: true}
YEOF

# Prints one "KEY value" line per fact; never the manifests themselves.
READER='
import sys, re, json, yaml
want_name = "OPENDDIL_EGRESS_PANE_URL"
via = "OPENDDIL_EGRESS_PANE_VIA_PEP"
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
def pods(d):
    if d.get("kind") in ("Deployment", "StatefulSet"):
        yield d["metadata"]["name"], d["spec"]["template"]["spec"]
for d in docs:
    name = d["metadata"]["name"]
    if d.get("kind") == "ConfigMap":
        for k, v in (d.get("data") or {}).items():
            if "bridge" in name or "uplink" in name or "relay" in name:
                topics = set(re.findall(r"[a-z][a-z0-9-]+", v))
                if "raw-sensor-stream" in topics or "tactical-events" in topics:
                    print("RELAYALL", name, k)
                for t in ("failure-episodes", "failure-episodes-withheld"):
                    if t in topics:
                        print("RELAY", name, k, t)
            if k == "deployment.json":
                j = json.loads(v)
                print("DEPLOY", name, json.dumps(j.get("reports"), separators=(",", ":")) if "reports" in j else "absent")
for dname, spec in (p for d in docs for p in pods(d)):
    for c in spec.get("containers", []):
        env = [(e["name"], e.get("value", "")) for e in c.get("env", [])]
        is_pep = "/app/pep.py" in (c.get("command") or []) + (c.get("args") or [])
        if is_pep:
            vals = [v for n, v in env if n == want_name]
            print("PEP", dname, len(vals), vals[0] if vals else "")
        if any(n == "OPENDDIL_PEP_UPSTREAM" for n, _ in env):
            vals = [v for n, v in env if n == via]
            print("FE", dname, len(vals), vals[0] if vals else "")
'

render() {  # $1 = errfile, rest = helm args; prints facts
  local err="$1"; shift
  helm template t "$CHART" -f "$TMP/topology.yaml" "$@" 2> "$err" | "$PY" -c "$READER" | tr -d '\r'
  return "${PIPESTATUS[0]}"
}

on="$(render "$TMP/on.err" --set releasability.enabled=true)" || { echo "FAIL: render (on) failed"; head -5 "$TMP/on.err"; exit 1; }
off="$(render "$TMP/off.err" --set releasability.enabled=false)" || { echo "FAIL: render (off) failed"; head -5 "$TMP/off.err"; exit 1; }

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ' ')"; echo "  want: $(echo "$3" | tr '\n' ' ')"; FAIL=1; fi
}

# The relay config ConfigMaps for one tier id, by name suffix.
relay_for() {  # $1 = facts, $2 = tier id, $3 = topic
  printf '%s\n' "$1" | awk -v id="$2" -v t="$3" '$1=="RELAY" && $4==t && $2 ~ ("-" id "$") {print $2}' | sort -u
}
echo "$on" | grep -q '^RELAY ' || { echo "FAIL: no relay config carries any failure topic; the reader found nothing"; FAIL=1; }

# A
for id in edge-a edge-b region-a; do
  got="$(relay_for "$on" "$id" failure-episodes | grep -c .)"
  check "A $id relay config carries failure-episodes" "$([ "$got" -ge 1 ] && echo yes || echo no)" "yes"
done
# B
check "B edge-u has a bridge config" "$(printf '%s
' "$on" | awk '$1=="RELAYALL" && $2 ~ /-edge-u$/' | grep -c .)" "1"
check "B edge-u bridge config does not carry failure-episodes" "$(relay_for "$on" edge-u failure-episodes | grep -c .)" "0"
# C
check "C failure-episodes-withheld is in no relay config" "$(printf '%s\n' "$on" | grep -c '^RELAY .* failure-episodes-withheld$')" "0"

# D
hub_url="$(printf '%s\n' "$on" | awk '$1=="PEP" && $2 ~ /-pep$/ {print $4}' | sort -u)"
tier_peps="$(printf '%s\n' "$on" | awk '$1=="PEP" && $2 ~ /tier-pep-/')"
check "D hub PEP has a pane URL" "$([ -n "$hub_url" ] && echo yes || echo no)" "yes"
check "D tier PEPs ($(printf '%s\n' "$tier_peps" | grep -c .)): one pane URL each, the hub PEP value" "$(printf '%s\n' "$tier_peps" | awk -v u="$hub_url" '{print $3, ($4==u)}' | sort -u)" "1 1"
check "D releasability off: no PEP has a pane URL" "$(printf '%s\n' "$off" | awk '$1=="PEP" && $3!=0' | grep -c .)" "0"

# E
tier_fe="$(printf '%s\n' "$on" | awk '$1=="FE" && $2 ~ /tier-frontend-/')"
check "E tier frontends ($(printf '%s\n' "$tier_fe" | grep -c .)): VIA_PEP=on once each" "$(printf '%s\n' "$tier_fe" | awk '{print $3, $4}' | sort -u)" "1 on"
check "E releasability off: no tier frontend has VIA_PEP" "$(printf '%s\n' "$off" | awk '$1=="FE" && $3!=0' | grep -c .)" "0"

# F, G
dep() { printf '%s\n' "$on" | awk -v id="$1" '$1=="DEPLOY" && $2 ~ ("-" id "$") {print $3}' | sort -u; }
check "F region-a deployment.json: reports.closesCarriedUp true" "$(dep region-a)" '{"closesCarriedUp":true}'
for id in edge-a edge-b; do
  check "G $id deployment.json has no reports key" "$(dep "$id")" "absent"
done
# edge-u is unmanaged: it has no tier frontend, so no deployment.json to carry the key.
check "G edge-u has no tier deployment.json (so no reports key)" "$(dep edge-u | grep -c .)" "0"
check "G hub deployment.json has no reports key" "$(printf '%s\n' "$on" | awk '$1=="DEPLOY" && $2 !~ /tier-frontend-config/ {print $3}' | sort -u)" "absent"

exit "$FAIL"
