#!/usr/bin/env bash
# ===========================================================================
# test_pep_element_shapes_render.sh -- offline render proof for the PEP's
# element-state serving and bounds.
#
# Render values: an explicit tier list (one region, two edges), OIDC on, each
# tier with a public origin; the hub PEP renders alongside.
#
# Cases:
#   A. an edge tier PEP lists asset_element_state in OPENDDIL_LABELED_TABLES.
#   B. a regional tier PEP and the hub PEP do not.
#   C. every PEP carries OPENDDIL_PEP_TIER, OPENDDIL_PEP_METRICS_PORT (with a
#      named containerPort), and the four element-shape values, once each, at
#      the defaults (false / 8 / 30 / 120).
#   D. the values flow through when set.
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

# The labelled-tables env is rendered only for a tier that declares a public
# origin under OIDC, so the render uses a small explicit tier list that does.
cat > "$TMP/tiers.yaml" <<'YEOF'
releasability: {enabled: true, oidc: {enabled: true}}
tierNode: {enabled: true}
tiers:
  - {id: region-a, kind: region, parent: root, hasChildren: true, label: region-a, publicOrigin: "http://region-a.test", directIngest: false, region: region-a}
  - {id: edge-a1, kind: edge, parent: region-a, hasChildren: false, label: edge-a1, publicOrigin: "http://edge-a1.test", directIngest: true, region: region-a}
  - {id: edge-a2, kind: edge, parent: region-a, hasChildren: false, label: edge-a2, publicOrigin: "http://edge-a2.test", directIngest: true, region: region-a}
YEOF
edge_ids="edge-a1 edge-a2"
region_ids="region-a"

render() {  # $1 = out file, rest = extra --set flags
  local out="$1"; shift
  helm template t "$CHART" -f "$TMP/tiers.yaml" "$@" > "$out" 2> "$out.err"
}

# One line per PEP container:
#   <deployment> table=<0|1> tier=<v> port=<v> named=<0|1> del=<v> max=<v> grace=<v> idle=<v>
pep_facts() {
  "$PY" - "$1" <<'PYEOF' | tr -d '\r'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not d or d.get("kind") != "Deployment":
        continue
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] != "pep":
            continue
        env = {}
        n = {}
        for e in c.get("env", []):
            env[e["name"]] = e.get("value", "")
            n[e["name"]] = n.get(e["name"], 0) + 1
        keys = ["OPENDDIL_PEP_TIER", "OPENDDIL_PEP_METRICS_PORT",
                "OPENDDIL_PEP_ELEMENT_DELETE_UPSTREAM", "OPENDDIL_PEP_VIEWER_SHAPE_MAX",
                "OPENDDIL_PEP_ELEMENT_GRACE_S", "OPENDDIL_PEP_HOLDER_IDLE_S"]
        once = all(n.get(k) == 1 for k in keys)
        tables = env.get("OPENDDIL_LABELED_TABLES", "").split(",")
        named = any(p.get("name") == "metrics" and str(p.get("containerPort")) == env.get("OPENDDIL_PEP_METRICS_PORT")
                    for p in c.get("ports", []))
        print(d["metadata"]["name"],
              "table=%d" % ("asset_element_state" in tables),
              "once=%d" % once,
              "tier=%s" % env.get("OPENDDIL_PEP_TIER", "-"),
              "port=%s" % env.get("OPENDDIL_PEP_METRICS_PORT", "-"),
              "named=%d" % named,
              "del=%s" % env.get("OPENDDIL_PEP_ELEMENT_DELETE_UPSTREAM", "-"),
              "max=%s" % env.get("OPENDDIL_PEP_VIEWER_SHAPE_MAX", "-"),
              "grace=%s" % env.get("OPENDDIL_PEP_ELEMENT_GRACE_S", "-"),
              "idle=%s" % env.get("OPENDDIL_PEP_HOLDER_IDLE_S", "-"))
PYEOF
}

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ' ')"; echo "  want: $(echo "$3" | tr '\n' ' ')"; FAIL=1; fi
}

render "$TMP/default.yaml" || { echo "render failed:"; cat "$TMP/default.yaml.err"; exit 1; }
facts="$(pep_facts "$TMP/default.yaml")"
n="$(printf '%s\n' "$facts" | grep -c .)"
[ "$n" -ge 3 ] || { echo "FAIL: expected the hub PEP and several tier PEPs, found $n"; FAIL=1; }

edge_lines=""; region_lines=""
for id in $edge_ids; do edge_lines="$edge_lines$(printf '%s\n' "$facts" | grep "^t-tier-pep-$id ")"$'\n'; done
for id in $region_ids; do region_lines="$region_lines$(printf '%s\n' "$facts" | grep "^t-tier-pep-$id ")"$'\n'; done
hub_line="$(printf '%s\n' "$facts" | grep '^t-pep ')"

ne="$(printf '%s' "$edge_lines" | grep -c .)"; nr="$(printf '%s' "$region_lines" | grep -c .)"
[ "$ne" -ge 1 ] || { echo "FAIL: no edge tier PEP found"; FAIL=1; }
[ "$nr" -ge 1 ] || { echo "FAIL: no regional tier PEP found"; FAIL=1; }

check "A edge tier PEPs ($ne) list asset_element_state" "$(printf '%s' "$edge_lines" | grep -c ' table=1 ')" "$ne"
check "B regional tier PEPs ($nr) do not" "$(printf '%s' "$region_lines" | grep -c ' table=0 ')" "$nr"
check "B hub PEP does not" "$(printf '%s\n' "$hub_line" | grep -c ' table=0 ')" "1"

check "C every PEP carries the six values once, named metrics port, defaults" \
  "$(printf '%s\n' "$facts" | sed -E 's/^[^ ]+ table=[01] //; s/tier=[^ ]+ //' | sort -u)" \
  "once=1 port=9464 named=1 del=false max=8 grace=30 idle=120"
check "C hub PEP tier id is hub" "$(printf '%s\n' "$hub_line" | grep -c ' tier=hub ')" "1"
check "C tier PEPs carry their own tier id" \
  "$(printf '%s' "$edge_lines$region_lines" | grep -v '^$' | awk '{id=$1; sub(/^t-tier-pep-/,"",id); split($0,a,"tier="); split(a[2],b," "); print (id==b[1]) ? "ok" : "bad:" $1}' | sort -u)" "ok"

render "$TMP/set.yaml" \
  --set releasability.elementShapes.deleteUpstream=true \
  --set releasability.elementShapes.viewerMax=5 \
  --set releasability.elementShapes.graceS=7 \
  --set releasability.elementShapes.holderIdleS=11 \
  --set releasability.pep.metricsPort=9999 || { echo "render failed:"; cat "$TMP/set.yaml.err"; exit 1; }
check "D values flow through to every PEP" \
  "$(pep_facts "$TMP/set.yaml" | sed -E 's/^[^ ]+ table=[01] //; s/tier=[^ ]+ //' | sort -u)" \
  "once=1 port=9999 named=1 del=true max=5 grace=7 idle=11"

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
