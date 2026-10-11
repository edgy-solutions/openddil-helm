#!/usr/bin/env bash
# ===========================================================================
# test_link_traffic_render.sh -- offline render proof that a link counts what
# its relay carries (openddil.linkTrafficTopics) and that the hub frontend
# learns each direct child link's shape (deployment.json childLinks).
#
# Topology: region-a runs a tier node with edge-a1 and edge-a2 under it;
# edge-d is attached directly to HQ.
#
# Cases:
#   A. region LINK_TRAFFIC_TOPICS == its BRIDGE_TOPICS minus link-heartbeat,
#      and carries the rollups.
#   B. every edge / leaf tier projector: LINK_TRAFFIC_TOPICS == BRIDGE_TOPICS
#      minus link-heartbeat; a managed edge's list has no raw-sensor-stream.
#   C. no LINK_TRAFFIC_TOPICS anywhere contains link-heartbeat.
#   D. linkStatus.trafficTopics set -> render fails with the message.
#   E. hub frontend deployment.json childLinks, in childTierIds order.
#   F. default render: BRIDGE_TOPICS byte-identical to the recorded baseline.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

cat > "$TMP/values.yaml" <<'YAML'
tierNode:
  enabled: true
  tiers: [region-a, edge-a1, edge-a2]
linkStatus:
  enabled: true
releasability:
  enabled: true
regions:
  - id: region-a
edges:
  - id: edge-a1
    region: region-a
    udpPort: 62040
  - id: edge-a2
    region: region-a
    udpPort: 62041
  - id: edge-d
    udpPort: 62042
tiers:
  - {id: region-a, kind: region, parent: root, hasChildren: true, label: region-a, publicOrigin: "", directIngest: false, region: region-a}
  - {id: edge-a1, kind: edge, parent: region-a, hasChildren: false, label: edge-a1, publicOrigin: "", directIngest: true, region: region-a}
  - {id: edge-a2, kind: edge, parent: region-a, hasChildren: false, label: edge-a2, publicOrigin: "", directIngest: true, region: region-a}
  - {id: edge-d, kind: edge, parent: "", hasChildren: false, label: edge-d, publicOrigin: "", directIngest: true, region: ""}
YAML

render() {  # $1 = out file, rest = extra helm flags
  local out="$1"; shift
  helm template t "$CHART" -f "$TMP/values.yaml" "$@" > "$out" 2> "$out.err"
}

# env_of <file>: one "<deployment> <BRIDGE_TOPICS> <LINK_TRAFFIC_TOPICS>" line
# per projector container that carries a LINK_TRAFFIC_TOPICS env.
env_of() {
  "$PY" - "$1" <<'PYEOF'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not d or d.get("kind") != "Deployment":
        continue
    for c in d["spec"]["template"]["spec"].get("containers", []):
        e = {x["name"]: x.get("value") for x in c.get("env", [])}
        if "LINK_TRAFFIC_TOPICS" in e:
            print(d["metadata"]["name"], e.get("BRIDGE_TOPICS", ""), e["LINK_TRAFFIC_TOPICS"])
PYEOF
}

childlinks() {
  "$PY" - "$1" <<'PYEOF'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"].endswith("-frontend-deployment-config"):
        print(d["data"]["deployment.json"].strip()); sys.exit(0)
print("<none>")
PYEOF
}

# minus_hb <csv>: the csv without link-heartbeat, order preserved.
minus_hb() { echo "$1" | tr ',' '\n' | grep -vx 'link-heartbeat' | paste -sd, -; }

ok() {
  if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1: $3"; FAIL=1; fi
}

render "$TMP/m.yaml" || { echo "render failed:"; cat "$TMP/m.yaml.err"; exit 1; }
env_of "$TMP/m.yaml" | tr -d '\r' > "$TMP/m.env"

# ---- A -------------------------------------------------------------------
miss=""
line="$(grep 'tier-projector-region-a ' "$TMP/m.env")"
[ -n "$line" ] || miss="$miss no-region-line"
read -r _ b l <<< "$line"
[ "$l" = "$(minus_hb "$b")" ] || miss="$miss mismatch"
case ",$l," in *,region-fleet-summary,*) ;; *) miss="$miss fleet-summary";; esac
case ",$l," in *,asset-telemetry-windows,*) ;; *) miss="$miss telemetry-windows";; esac
ok "A region counts its uplink" "$([ -z "$miss" ] && echo 0 || echo 1)" "$miss (bridge=$b traffic=$l)"

# ---- B -------------------------------------------------------------------
miss=""; n=0
while read -r name b l; do
  case "$name" in *projector-edge-*|*projector-config*) ;; *) continue;; esac
  n=$((n+1))
  [ "$l" = "$(minus_hb "$b")" ] || miss="$miss $name:mismatch"
  case "$name" in
    *tier-projector-edge-a*) case ",$l," in *,raw-sensor-stream,*) miss="$miss $name:raw";; esac;;
  esac
done < "$TMP/m.env"
[ "$n" -ge 3 ] || miss="$miss only-$n-edge-projectors"
ok "B edges count their bridge" "$([ -z "$miss" ] && echo 0 || echo 1)" "$miss"

# ---- C -------------------------------------------------------------------
miss=""
while read -r name b l; do
  case ",$l," in *,link-heartbeat,*) miss="$miss $name";; esac
done < "$TMP/m.env"
ok "C no heartbeat in any traffic list" "$([ -z "$miss" ] && echo 0 || echo 1)" "$miss"

# ---- D -------------------------------------------------------------------
if render "$TMP/d.yaml" --set 'linkStatus.trafficTopics={a}'; then
  echo "FAIL D stale override: render succeeded"; FAIL=1
elif grep -qF 'linkStatus.trafficTopics is no longer read: each link counts the topics its relay carries (openddil.linkTrafficTopics); remove it' "$TMP/d.yaml.err"; then
  echo "PASS D stale override"
else
  echo "FAIL D stale override: message missing"; FAIL=1
fi

# ---- E -------------------------------------------------------------------
want='[{"hasChildren":true,"id":"region-a"},{"hasChildren":false,"id":"edge-d"}]'
got="$(childlinks "$TMP/m.yaml" | "$PY" -c 'import sys,json; print(json.dumps(json.load(sys.stdin).get("childLinks"),separators=(",",":")))')"
ok "E childLinks" "$([ "$got" = "$want" ] && echo 0 || echo 1)" "got=$got"

# ---- F -------------------------------------------------------------------
# Baseline = the BRIDGE_TOPICS the chart rendered before this change, default values.
BASE_F="${BRIDGE_BASELINE:-$HERE/fixtures/link_traffic_default_bridge_topics.txt}"
helm template t "$CHART" 2>/dev/null | grep -A1 'name: BRIDGE_TOPICS' | grep 'value:' > "$TMP/f.now"
if cmp -s "$TMP/f.now" "$BASE_F"; then echo "PASS F default BRIDGE_TOPICS unchanged"
else echo "FAIL F default BRIDGE_TOPICS changed vs baseline"; FAIL=1; fi

# ---- G -------------------------------------------------------------------
# Releasability off and no pane: the hub frontend still gets deployment.json,
# because the header places each child link's row from childLinks.
helm template t "$CHART" > "$TMP/g.yaml" 2>/dev/null
gotg="$(childlinks "$TMP/g.yaml" | "$PY" -c 'import sys,json; c=json.load(sys.stdin).get("childLinks") or []; print("ok" if c and all(e.get("hasChildren") is False for e in c) else "bad %r" % c)')"
ok "G childLinks rendered with releasability off" "$([ "$gotg" = "ok" ] && echo 0 || echo 1)" "got=$gotg"

exit "$FAIL"
