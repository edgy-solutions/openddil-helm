#!/usr/bin/env bash
# ===========================================================================
# test_entity_assignment.sh — proves sensorIngest.entityAssignment's four
# render-time `fail`s actually fire, and that check-entity-assignment.sh
# (scripts/check-entity-assignment.sh) catches a render that disagrees with
# the map even though the map itself is well-formed.
# ===========================================================================
# Driven against the REAL chart (helm template) and the REAL checker script,
# never a reimplementation of either.
#
# Cases 1 and 2 ("render disagrees with a well-formed map") cannot come from
# the chart itself -- templates/edge.yaml's own validation already refuses a
# map shaped to produce either directly. So this test renders a VALID map
# once, tampers with the rendered TEXT (not the map), and points the checker
# at the tampered file through its CHECK_ENTITY_ASSIGNMENT_RENDER_FILE seam.
# The map the checker compares against still comes from the real -f file,
# untouched -- only the "live render" half is swapped, same philosophy as
# check-pull-credentials.sh's PULLCHECK_FIXTURE_DIR seam.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="$(cd "$HERE/../.." && pwd)/openddil-demo"
CHECK="$HERE/../check-entity-assignment.sh"
PY=$(command -v python3 || command -v python || echo py)

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

M="$(mktemp -d)"
trap 'rm -rf "$M"' EXIT

# -- fixture value files. Generic synthetic ids; edges are edge-01/02/03,
#    the chart's own default edges[] (openddil-demo/values.yaml). ----------
cat > "$M/valid.yaml" <<'YAML'
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1:1", edge: edge-01 }
    - { id: "dis:1:1:2", edge: edge-01 }
    - { id: "dis:2:1:7", edge: edge-02 }
    - { id: "dis:3:1:9", edge: edge-03 }
  unassignedEdge: edge-03
YAML

cat > "$M/malformed.yaml" <<'YAML'
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1", edge: edge-01 }
YAML

cat > "$M/duplicate.yaml" <<'YAML'
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1:1", edge: edge-01 }
    - { id: "dis:1:1:1", edge: edge-02 }
YAML

cat > "$M/unknown-edge.yaml" <<'YAML'
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1:1", edge: edge-04 }
YAML

cat > "$M/edge-without-ids.yaml" <<'YAML'
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1:1", edge: edge-01 }
    - { id: "dis:2:1:1", edge: edge-02 }
  unassignedEdge: edge-01
YAML

# the fallback edge with no entries of its own
cat > "$M/fallback-empty.yaml" <<'YAML'
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1:1", edge: edge-01 }
    - { id: "dis:2:1:7", edge: edge-02 }
  unassignedEdge: edge-03
YAML

# a one-edge deployment whose only edge is the fallback: nothing to deny
cat > "$M/fallback-only.yaml" <<'YAML'
edges:
  - { id: edge-01, region: region-east, udpPort: 62040 }
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1:1", edge: edge-01 }
  unassignedEdge: edge-01
YAML

cat > "$M/sources.yaml" <<'YAML'
sensorIngest:
  entityAssignment:
    - { id: "dis:1:1:1", edge: edge-01 }
    - { id: "dis:2:1:7", edge: edge-02 }
  unassignedEdge: edge-03
  nonAssetSources:
    - { site: 1, application: 900, name: stand-in-adapter }
    - { site: 1, application: 901, kind: 3, name: scenario-controller }
YAML

# ===========================================================================
# case 3 — each of the four render-time `fail`s actually fires, naming the
# offending entry.
# ===========================================================================
out="$(helm template t "$CHART" -f "$M/malformed.yaml" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "3a: a malformed id halts the render" || fail "3a: rc=$rc, expected non-zero"
grep -q 'malformed id "dis:1:1"' <<<"$out" && pass "3a: the offending id is named" \
  || fail "3a: offending id not named as expected"

out="$(helm template t "$CHART" -f "$M/duplicate.yaml" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "3b: a duplicate id halts the render" || fail "3b: rc=$rc, expected non-zero"
grep -q 'id "dis:1:1:1" is assigned to more than one edge (edge-01 and edge-02)' <<<"$out" \
  && pass "3b: both edges are named" || fail "3b: duplicate message not found as expected"

out="$(helm template t "$CHART" -f "$M/unknown-edge.yaml" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "3c: an unknown edge halts the render" || fail "3c: rc=$rc, expected non-zero"
grep -q 'names edge "edge-04", which is not in edges\[\]' <<<"$out" && pass "3c: the unknown edge is named" \
  || fail "3c: unknown-edge message not found as expected"

out="$(helm template t "$CHART" -f "$M/edge-without-ids.yaml" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && pass "3d: an edge with no entries halts the render" || fail "3d: rc=$rc, expected non-zero"
grep -q 'edge "edge-03" has no entries while the list is non-empty' <<<"$out" \
  && pass "3d: the under-covered edge is named" || fail "3d: edge-without-ids message not found as expected"

# ===========================================================================
# case 6 -- the fallback-edge and non-asset-source render rules each fire.
# ===========================================================================
expect_fail() {  # name, message-fragment, yaml-body...
  local name="$1" frag="$2"; shift 2
  printf '%s\n' "$@" > "$M/$name.yaml"
  out="$(helm template t "$CHART" -f "$M/$name.yaml" 2>&1)"; rc=$?
  if [ "$rc" -ne 0 ] && grep -qF -- "$frag" <<<"$out"; then pass "6: $name halts with its message"
  else fail "6: $name rc=$rc, message '$frag' not found"; fi
}
E1='  entityAssignment: [{ id: "dis:1:1:1", edge: edge-01 }, { id: "dis:2:1:7", edge: edge-02 }]'
expect_fail f-missing "required once sensorIngest.entityAssignment is non-empty" sensorIngest: "$E1"
expect_fail f-emptylist "is set but sensorIngest.entityAssignment is empty" sensorIngest: '  unassignedEdge: edge-03'
expect_fail f-unknown 'unassignedEdge: "edge-09" is not in edges[]' sensorIngest: "$E1" '  unassignedEdge: edge-09'
expect_fail f-site "must each be an integer 0-65535" sensorIngest: '  nonAssetSources: [{ site: 70000, application: 1, name: x }]'
expect_fail f-kind "must be an integer 0-255" sensorIngest: '  nonAssetSources: [{ site: 1, application: 1, kind: 256, name: x }]'
expect_fail f-name "has no name" sensorIngest: '  nonAssetSources: [{ site: 1, application: 1 }]'
expect_fail f-dup "is listed twice" sensorIngest: '  nonAssetSources: [{ site: 1, application: 1, name: x }, { site: 1, application: 1, name: y }]'
expect_fail f-asset "an asset cannot come from a non-asset source" sensorIngest: \
  '  entityAssignment: [{ id: "dis:1:900:5", edge: edge-01 }, { id: "dis:2:1:7", edge: edge-02 }]' \
  '  unassignedEdge: edge-03' '  nonAssetSources: [{ site: 1, application: 900, name: x }]'

# ===========================================================================
# case 7 -- the fallback edge carries the deny env, not an admit env; with no
# entries of its own it still renders; with nothing to deny it renders none.
# ===========================================================================
out="$(helm template t "$CHART" -f "$M/valid.yaml" 2>&1)"
grep -qF 'value: "dis:1:1:1,dis:1:1:2,dis:2:1:7"' <<<"$out" && grep -q 'name: DIS_DENIED_ENTITY_IDS' <<<"$out" \
  && pass "7a: the fallback edge's deny list is the other edges' ids, sorted" \
  || fail "7a: expected deny list not rendered"
[ "$(grep -c 'name: DIS_DENIED_ENTITY_IDS' <<<"$out")" -eq 1 ] && pass "7a: exactly one sidecar carries a deny list" \
  || fail "7a: deny env on more than one sidecar"

out="$("$CHECK" "$CHART" -f "$M/fallback-empty.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "7b: a fallback edge with zero entries passes the check" \
  || fail "7b: rc=$rc -- output: $out"

helm template t "$CHART" -f "$M/fallback-only.yaml" > "$M/fallback-only-render.yaml" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "7c: a fallback-only deployment renders" || fail "7c: rc=$rc"
grep -qE 'DIS_DENIED_ENTITY_IDS|DIS_ADMITTED_ENTITY_IDS' "$M/fallback-only-render.yaml" \
  && fail "7c: an env rendered although there is nothing to deny" || pass "7c: no deny and no admit env"
out="$("$CHECK" "$CHART" -f "$M/fallback-only.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "7c: the check passes" || fail "7c: rc=$rc -- output: $out"

# tampers: a dropped deny id, and an admit env on the fallback edge
helm template t "$CHART" -f "$M/valid.yaml" > "$M/valid-render.yaml" 2>&1
sed 's/value: "dis:1:1:1,dis:1:1:2,dis:2:1:7"/value: "dis:1:1:1,dis:1:1:2"/' "$M/valid-render.yaml" > "$M/tamper3.yaml"
cmp -s "$M/valid-render.yaml" "$M/tamper3.yaml" && fail "7d: tamper planted nothing"
out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper3.yaml" "$CHECK" "$CHART" -f "$M/valid.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q "DIS_DENIED_ENTITY_IDS" <<<"$out" && pass "7d: a deny list missing an id fails the check" \
  || fail "7d: rc=$rc -- output: $out"

sed 's/name: DIS_DENIED_ENTITY_IDS/name: DIS_ADMITTED_ENTITY_IDS/' "$M/valid-render.yaml" > "$M/tamper4.yaml"
cmp -s "$M/valid-render.yaml" "$M/tamper4.yaml" && fail "7e: tamper planted nothing"
out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper4.yaml" "$CHECK" "$CHART" -f "$M/valid.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "7e: an admit list on the fallback edge fails the check" \
  || fail "7e: rc=$rc -- output: $out"

# ===========================================================================
# case 8 -- nonAssetSources renders on every edge; a dropped one is caught.
# ===========================================================================
helm template t "$CHART" -f "$M/sources.yaml" > "$M/sources-render.yaml" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "8: nonAssetSources renders" || fail "8: rc=$rc"
[ "$(grep -cF 'value: "1:900,1:901:3"' "$M/sources-render.yaml")" -eq 3 ] \
  && pass "8: DIS_NON_ASSET_SOURCES is on all three sidecars" || fail "8: not on exactly three sidecars"
out="$("$CHECK" "$CHART" -f "$M/sources.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "8: the check passes" || fail "8: rc=$rc -- output: $out"
sed '0,/value: "1:900,1:901:3"/s//value: "1:900"/' "$M/sources-render.yaml" > "$M/tamper5.yaml"
out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper5.yaml" "$CHECK" "$CHART" -f "$M/sources.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "8: a sidecar with the wrong sources fails the check" \
  || fail "8: rc=$rc -- output: $out"

# ===========================================================================
# case 4 — a valid 3-edge map renders cleanly and the checker passes.
# ===========================================================================
out="$(helm template t "$CHART" -f "$M/valid.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "4: a valid 3-edge map renders (rc 0)" || fail "4: rc=$rc, expected 0"
printf '%s\n' "$out" > "$M/valid-render.yaml"

out="$("$CHECK" "$CHART" -f "$M/valid.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "4: check-entity-assignment.sh passes against the valid map" \
  || fail "4: rc=$rc, expected 0 -- output: $out"
grep -q "^OK:" <<<"$out" && pass "4: OK reported" || fail "4: OK not reported"

# ===========================================================================
# case 5 — the empty (default) map renders no env at all, and the checker
# passes.
# ===========================================================================
out="$(helm template t "$CHART" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "5: the default (empty) map renders (rc 0)" || fail "5: rc=$rc, expected 0"
grep -qE "DIS_ADMITTED_ENTITY_IDS|DIS_DENIED_ENTITY_IDS|DIS_NON_ASSET_SOURCES" <<<"$out" \
  && fail "5: env rendered although the map is empty" \
  || pass "5: no admit, deny or source env rendered"

out="$("$CHECK" "$CHART" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "5: check-entity-assignment.sh passes against the empty map" \
  || fail "5: rc=$rc, expected 0 -- output: $out"

# ===========================================================================
# case 1 — one id removed from one sidecar: the checker must catch it even
# though sensorIngest.entityAssignment itself is well-formed.
# ===========================================================================
"$PY" - "$M/valid-render.yaml" "$M/tamper1.yaml" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    text = f.read()
target = 'value: "dis:2:1:7"'
assert target in text, "plant target not found: the test would prove nothing"
text = text.replace(target, 'value: ""', 1)
with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF

out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper1.yaml" "$CHECK" "$CHART" -f "$M/valid.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "1: an id dropped from one sidecar fails the check (rc 1)" \
  || fail "1: rc=$rc, expected 1 -- output: $out"
grep -q "dis:2:1:7" <<<"$out" && pass "1: the missing id is named" \
  || fail "1: missing id not named as expected"

# ===========================================================================
# case 2 — one id copied into a second sidecar: the checker must catch the
# duplicate even though the UNION of rendered ids still matches the map.
# ===========================================================================
"$PY" - "$M/valid-render.yaml" "$M/tamper2.yaml" <<'PYEOF'
import sys
src, dst = sys.argv[1], sys.argv[2]
with open(src, encoding="utf-8") as f:
    text = f.read()
target = 'value: "dis:2:1:7"'
assert target in text, "plant target not found: the test would prove nothing"
text = text.replace(target, 'value: "dis:2:1:7,dis:1:1:1"', 1)
with open(dst, "w", encoding="utf-8") as f:
    f.write(text)
PYEOF

out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper2.yaml" "$CHECK" "$CHART" -f "$M/valid.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && pass "2: an id copied into a second sidecar fails the check (rc 1)" \
  || fail "2: rc=$rc, expected 1 -- output: $out"
grep -q "dis:1:1:1' is rendered into more than one sidecar" <<<"$out" && pass "2: the duplicated id is named" \
  || fail "2: duplicate-id message not found as expected"


# ===========================================================================
# case 9 -- sensorIngest.assignment (rules mode), nationStamping, and a
# site-less nonAssetSources entry. (a)-(g) follow the item-6 spec letters.
# ===========================================================================
cat > "$M/rules.yaml" <<'YAML'
sensorIngest:
  assignment:
    fallbackEdge: edge-03
    rules:
      - { name: ids-1, edge: edge-01, match: { ids: ["dis:1:1:1", "dis:1:1:2"] } }
      - { name: box-1, edge: edge-02, match: { geofence: { south: 10.0, west: 20.0, north: 11.5, east: 21.5 } } }
      - { name: markings-1, edge: edge-02, match: { marking: "^AB" } }
      - { name: country-1, edge: edge-01, match: { country: [1, 2] } }
YAML

# the sidecar's env, by Deployment name, as JSON
sidecar_env() {  # render-file
  "$PY" - "$1" <<'PYEOF'
import json, sys
import yaml
out = {}
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not d or d.get("kind") != "Deployment":
        continue
    name = d["metadata"]["name"]
    if "-sensor-ingest-" not in name:
        continue
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] == "sensor-ingest":
            out[name] = {e["name"]: e.get("value") for e in c.get("env", [])}
print(json.dumps(out))
PYEOF
}

# (a) rules: the same JSON on every sidecar, no admit or deny env.
helm template t "$CHART" -f "$M/rules.yaml" > "$M/rules-render.yaml" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "9a: a rules deployment renders" || fail "9a: rc=$rc -- $(tail -3 "$M/rules-render.yaml")"
sidecar_env "$M/rules-render.yaml" > "$M/rules-env.json" 2>&1
if "$PY" - "$M/rules-env.json" <<'PYEOF'
import json, sys
envs = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(envs) == 3, f"expected 3 sidecars, got {len(envs)}"
want = [
    {"name": "ids-1", "edge": "edge-01", "match": {"ids": ["dis:1:1:1", "dis:1:1:2"]}},
    {"name": "box-1", "edge": "edge-02", "match": {"geofence": {"south": 10.0, "west": 20.0, "north": 11.5, "east": 21.5}}},
    {"name": "markings-1", "edge": "edge-02", "match": {"marking": "^AB"}},
    {"name": "country-1", "edge": "edge-01", "match": {"country": [1, 2]}},
]
for name, env in envs.items():
    assert json.loads(env["DIS_ASSIGNMENT_RULES"]) == want, name
    assert env["DIS_FALLBACK_EDGE"] == "edge-03", name
    for k in ("DIS_ADMITTED_ENTITY_IDS", "DIS_DENIED_ENTITY_IDS"):
        assert k not in env, f"{name} carries {k}"
assert len({e["DIS_ASSIGNMENT_RULES"] for e in envs.values()}) == 1
PYEOF
then pass "9a: identical rules and fallback on every sidecar, no admit or deny env"
else fail "9a: rules env wrong"; fi
out="$("$CHECK" "$CHART" -f "$M/rules.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && grep -qi "rules mode" <<<"$out" && pass "9a: the checker recognises rules mode and passes" \
  || fail "9a: checker rc=$rc -- $out"

# the checker must catch tampered renders in rules mode
sed '0,/DIS_FALLBACK_EDGE/{n;s/edge-03/edge-01/}' "$M/rules-render.yaml" > "$M/tamper-fb.yaml"
cmp -s "$M/rules-render.yaml" "$M/tamper-fb.yaml" && fail "9a: fallback tamper planted nothing"
out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper-fb.yaml" "$CHECK" "$CHART" -f "$M/rules.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q "DIS_FALLBACK_EDGE" <<<"$out" && pass "9a: one sidecar with a different fallback edge fails the check" \
  || fail "9a: fallback tamper rc=$rc -- $out"
sed '0,/\^AB/s//^AC/' "$M/rules-render.yaml" > "$M/tamper-rules.yaml"
cmp -s "$M/rules-render.yaml" "$M/tamper-rules.yaml" && fail "9a: rules tamper planted nothing"
out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper-rules.yaml" "$CHECK" "$CHART" -f "$M/rules.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q "DIS_ASSIGNMENT_RULES" <<<"$out" && pass "9a: one sidecar with different rules fails the check" \
  || fail "9a: rules tamper rc=$rc -- $out"
sed 's/name: DIS_FALLBACK_EDGE/name: DIS_DENIED_ENTITY_IDS/' "$M/rules-render.yaml" > "$M/tamper-deny.yaml"
out="$(CHECK_ENTITY_ASSIGNMENT_RENDER_FILE="$M/tamper-deny.yaml" "$CHECK" "$CHART" -f "$M/rules.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 1 ] && grep -q "DIS_DENIED_ENTITY_IDS" <<<"$out" && pass "9a: a deny env in rules mode fails the check" \
  || fail "9a: deny tamper rc=$rc -- $out"

# (b)-(d) and the other refusals
expect_fail g-both "one model per deployment" sensorIngest: \
  '  entityAssignment: [{ id: "dis:1:1:1", edge: edge-01 }, { id: "dis:2:1:7", edge: edge-02 }]' \
  '  unassignedEdge: edge-03' '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-01, match: { ids: ["dis:3:1:1"] } }] }'
expect_fail g-edge "sensorIngest.assignment.rules[r1].edge" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-09, match: { ids: ["dis:3:1:1"] } }] }'
expect_fail g-nonasset "an asset cannot come from a non-asset source" sensorIngest: \
  '  nonAssetSources: [{ application: 900, name: x }]' \
  '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-01, match: { ids: ["dis:7:900:1"] } }] }'
expect_fail g-fb-missing "sensorIngest.assignment.fallbackEdge: required" sensorIngest: \
  '  assignment: { rules: [{ name: r1, edge: edge-01, match: { country: [1] } }] }'
expect_fail g-fb-unknown "sensorIngest.assignment.fallbackEdge" sensorIngest: \
  '  assignment: { fallbackEdge: edge-09, rules: [{ name: r1, edge: edge-01, match: { country: [1] } }] }'
expect_fail g-fb-norules "sensorIngest.assignment.fallbackEdge: \"edge-03\" is set but" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03 }'
expect_fail g-noname "sensorIngest.assignment.rules[0].name" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03, rules: [{ edge: edge-01, match: { country: [1] } }] }'
expect_fail g-dupname "name \"r1\" is used twice" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-01, match: { country: [1] } }, { name: r1, edge: edge-02, match: { country: [2] } }] }'
expect_fail g-match0 "sensorIngest.assignment.rules[r1].match" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-01, match: {} }] }'
expect_fail g-match2 "sensorIngest.assignment.rules[r1].match" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-01, match: { country: [1], marking: "^A" } }] }'
expect_fail g-badid "sensorIngest.assignment.rules[r1].match.ids" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-01, match: { ids: ["dis:1:1"] } }] }'
expect_fail g-dupid "listed twice" sensorIngest: \
  '  assignment: { fallbackEdge: edge-03, rules: [{ name: r1, edge: edge-01, match: { ids: ["dis:1:1:1"] } }, { name: r2, edge: edge-02, match: { ids: ["dis:1:1:1"] } }] }'

# (e) nation stamping
cat > "$M/nation.yaml" <<'YAML'
sensorIngest:
  nationStamping:
    overrides: { "dis:1:1:1": ATL }
    rules:
      - { name: markings-1, nation: BDR, match: { marking: "^BD" } }
      - { name: box-1, nation: ATL, match: { geofence: { south: 10.0, west: 20.0, north: 11.5, east: 21.5 } } }
YAML
helm template t "$CHART" -f "$M/nation.yaml" > "$M/nation-render.yaml" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "9e: nation stamping renders" || fail "9e: rc=$rc"
sidecar_env "$M/nation-render.yaml" > "$M/nation-env.json" 2>&1
if "$PY" - "$M/nation-env.json" <<'PYEOF'
import json, sys
envs = json.load(open(sys.argv[1], encoding="utf-8"))
assert len(envs) == 3
want = {"overrides": {"dis:1:1:1": "ATL"}, "rules": [
    {"name": "markings-1", "nation": "BDR", "match": {"marking": "^BD"}},
    {"name": "box-1", "nation": "ATL", "match": {"geofence": {"south": 10.0, "west": 20.0, "north": 11.5, "east": 21.5}}}]}
for name, env in envs.items():
    assert json.loads(env["DIS_NATION_RULES"]) == want, name
PYEOF
then pass "9e: DIS_NATION_RULES is the overrides and rules, on every sidecar"
else fail "9e: nation env wrong"; fi
expect_fail n-badcode "sensorIngest.nationStamping.rules[r1].nation" sensorIngest: \
  '  nationStamping: { rules: [{ name: r1, nation: atl, match: { country: [1] } }] }'
expect_fail n-badover "sensorIngest.nationStamping.overrides" sensorIngest: \
  '  nationStamping: { overrides: { "dis:1:1:1": ATLA } }'
expect_fail n-exempt-case "must be three capital letters or \"exempt\"" sensorIngest:   '  nationStamping: { overrides: { "dis:1:1:1": EXEMPT } }'
expect_fail n-exempt-suffix "must be three capital letters or \"exempt\"" sensorIngest:   '  nationStamping: { overrides: { "dis:1:1:1": exempt2 } }'
cat > "$M/nation-exempt.yaml" <<'YAML'
sensorIngest:
  nationStamping:
    overrides: { "dis:1:1:1": exempt, "dis:7:1:42": ATL }
YAML
helm template t "$CHART" -f "$M/nation-exempt.yaml" > "$M/nation-exempt-render.yaml" 2>&1; rc=$?
[ "$rc" -eq 0 ] && grep -qF '\"dis:1:1:1\":\"exempt\"' "$M/nation-exempt-render.yaml"   && pass "9e: an exempt override renders into DIS_NATION_RULES"   || fail "9e: exempt override rc=$rc or not in DIS_NATION_RULES"

expect_fail n-badkey "sensorIngest.nationStamping.overrides" sensorIngest: \
  '  nationStamping: { overrides: { "dis:1:1": ATL } }'
expect_fail n-dupname "name \"r1\" is used twice" sensorIngest: \
  '  nationStamping: { rules: [{ name: r1, nation: ATL, match: { country: [1] } }, { name: r1, nation: BDR, match: { country: [2] } }] }'
expect_fail n-ids "sensorIngest.nationStamping.rules[r1].match" sensorIngest: \
  '  nationStamping: { rules: [{ name: r1, nation: ATL, match: { ids: ["dis:1:1:1"] } }] }'
out="$(helm template t "$CHART" 2>&1)"
grep -q "DIS_NATION_RULES" <<<"$out" && fail "9e: DIS_NATION_RULES rendered with nothing set" \
  || pass "9e: no DIS_NATION_RULES when nothing is set"

# (f) a site-less non-asset source renders *:<app>; the list stays sorted
cat > "$M/nosite.yaml" <<'YAML'
sensorIngest:
  nonAssetSources:
    - { application: 900, name: any-site-adapter }
    - { site: 1, application: 901, kind: 3, name: scenario-controller }
    - { application: 902, kind: 4, name: any-site-kind }
YAML
helm template t "$CHART" -f "$M/nosite.yaml" > "$M/nosite-render.yaml" 2>&1; rc=$?
[ "$rc" -eq 0 ] && pass "9f: a site-less source renders" || fail "9f: rc=$rc"
[ "$(grep -cF 'value: "*:900,*:902:4,1:901:3"' "$M/nosite-render.yaml")" -eq 3 ] \
  && pass "9f: *:900 is on all three sidecars, sorted" || fail "9f: expected token list not on three sidecars"
out="$("$CHECK" "$CHART" -f "$M/nosite.yaml" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "9f: the checker agrees" || fail "9f: checker rc=$rc -- $out"
expect_fail s-dup "source *:900 is listed twice" sensorIngest: \
  '  nonAssetSources: [{ application: 900, name: x }, { application: 900, name: y }]'

# (g) empty rules: the sidecar Deployments are byte-identical to the
#     unchanged chart's, kept as golden files taken before this feature.
GOLD="$HERE/golden-entity-assignment"
for f in default valid sources fallback-only; do
  if [ "$f" = default ]; then args=(); else args=(-f "$M/$f.yaml"); fi
  helm template t "$CHART" "${args[@]}" 2>/dev/null | "$PY" "$HERE/sensor_ingest_docs.py" > "$M/gold-$f.yaml"
  cmp -s "$M/gold-$f.yaml" "$GOLD/$f.yaml" && pass "9g: $f sidecar Deployments are byte-identical to the unchanged chart" \
    || fail "9g: $f sidecar Deployments differ from the golden"
done
echo
if [ "$FAIL" -eq 0 ]; then
  echo "test_entity_assignment.sh: ALL PASS"
else
  echo "test_entity_assignment.sh: SOME FAILED"
fi
exit "$FAIL"
