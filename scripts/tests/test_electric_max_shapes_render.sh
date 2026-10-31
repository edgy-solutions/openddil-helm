#!/usr/bin/env bash
# ===========================================================================
# test_electric_max_shapes_render.sh -- offline render proof for the declared
# shape ceiling (ELECTRIC_MAX_SHAPES) on the tier Electrics.
#
# Render values: one region, two edges, plus the hub.
#
# Cases:
#   A. each edge tier Electric has exactly one ELECTRIC_MAX_SHAPES, "256".
#   B. the region tier Electric and the hub Electric have none.
#   C. electric.maxShapes.edge=40 -> edges read "40"; electric.maxShapes.region=99
#      -> the region reads "99" and the hub still has none.
#   D. electric.maxShapes.edge=null -> no Electric has it.
#   E. no rendered manifest contains ELECTRIC_ENABLE_INTEGRATION_TESTING.
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

cat > "$TMP/tiers.yaml" <<'YEOF'
releasability: {enabled: true, oidc: {enabled: true}}
tierNode: {enabled: true}
tiers:
  - {id: region-a, kind: region, parent: root, hasChildren: true, label: region-a, publicOrigin: "http://region-a.test", directIngest: false, region: region-a}
  - {id: edge-a1, kind: edge, parent: region-a, hasChildren: false, label: edge-a1, publicOrigin: "http://edge-a1.test", directIngest: true, region: region-a}
  - {id: edge-a2, kind: edge, parent: region-a, hasChildren: false, label: edge-a2, publicOrigin: "http://edge-a2.test", directIngest: true, region: region-a}
YEOF

render() {  # $1 = out file, rest = extra --set flags
  local out="$1"; shift
  helm template t "$CHART" -f "$TMP/tiers.yaml" "$@" > "$out" 2> "$out.err" \
    || { echo "render failed:"; cat "$out.err"; exit 1; }
}

# One line per Electric container: <deployment> n=<count> val=<value|->
electric_facts() {
  "$PY" - "$1" <<'PYEOF' | tr -d '\r'
import sys, re, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not d or d.get("kind") != "Deployment":
        continue
    name = d["metadata"]["name"]
    if not (re.fullmatch(r"t-tier-electric-.+", name) or name == "t-electric-sync"):
        continue
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] != "electric":
            continue
        vals = [e.get("value") for e in c.get("env", []) if e["name"] == "ELECTRIC_MAX_SHAPES"]
        print(name, "n=%d" % len(vals), "val=%s" % (vals[0] if vals else "-"))
PYEOF
}

check() {
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ' ')"; echo "  want: $(echo "$3" | tr '\n' ' ')"; FAIL=1; fi
}

line() { printf '%s\n' "$1" | grep "^$2 " | sed -E 's/^[^ ]+ //'; }

render "$TMP/default.yaml"
f="$(electric_facts "$TMP/default.yaml")"
[ "$(printf '%s\n' "$f" | grep -c .)" = 4 ] || { echo "FAIL: expected 4 Electrics (2 edge, 1 region, hub), got:"; echo "$f"; FAIL=1; }

check "A edge-a1 has one, 256" "$(line "$f" t-tier-electric-edge-a1)" 'n=1 val=256'
check "A edge-a2 has one, 256" "$(line "$f" t-tier-electric-edge-a2)" 'n=1 val=256'
check "B region has none"      "$(line "$f" t-tier-electric-region-a)" 'n=0 val=-'
check "B hub has none"         "$(line "$f" t-electric-sync)" 'n=0 val=-'

render "$TMP/c1.yaml" --set electric.maxShapes.edge=40
f="$(electric_facts "$TMP/c1.yaml")"
check "C edge=40: edge-a1" "$(line "$f" t-tier-electric-edge-a1)" 'n=1 val=40'
check "C edge=40: edge-a2" "$(line "$f" t-tier-electric-edge-a2)" 'n=1 val=40'

render "$TMP/c2.yaml" --set electric.maxShapes.region=99
f="$(electric_facts "$TMP/c2.yaml")"
check "C region=99: region" "$(line "$f" t-tier-electric-region-a)" 'n=1 val=99'
check "C region=99: hub none" "$(line "$f" t-electric-sync)" 'n=0 val=-'

render "$TMP/d.yaml" --set electric.maxShapes.edge=null
f="$(electric_facts "$TMP/d.yaml")"
check "D edge=null: no Electric has it" "$(printf '%s\n' "$f" | sed -E 's/^[^ ]+ //' | sort -u)" 'n=0 val=-'

render "$TMP/e.yaml" --set electric.maxShapes=null
check "D maxShapes absent: renders, none" "$(electric_facts "$TMP/e.yaml" | sed -E 's/^[^ ]+ //' | sort -u)" 'n=0 val=-'

for x in default c1 c2 d e; do
  check "E no integration-testing flag ($x)" "$(grep -c ELECTRIC_ENABLE_INTEGRATION_TESTING "$TMP/$x.yaml")" "0"
done

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
