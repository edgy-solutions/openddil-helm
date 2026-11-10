#!/usr/bin/env bash
# ===========================================================================
# test_algorithms_render.sh -- offline render proof for the algorithms block
# (values.yaml), its faust-edge wiring, and its ten render refusals.
#
# Render values: --set tierNode.enabled=true (the chart's default edges then
# yield faust-edge apps). Renders go to a mktemp dir and are filtered in the
# pipe so no Secret document is ever written to disk.
#
# Cases:
#   A. defaults  -> every faust-edge Deployment carries ALGORITHMS_DIR,
#                   ALGORITHMS_ENABLED=wear,thermal and ALGORITHM_PARAMS_JSON={} once,
#                   no PROGNOSTICS_* env, a bundle-loader copying
#                   agents/algorithms, the read-only mount, and a
#                   produces-topics annotation with derived-sustainment and
#                   the prognostics_accumulators changelog.
#                   (wear and thermal are both enabled by default.)
#   B. overrides -> --set (int64) and -f (float64) reach ALGORITHM_PARAMS_JSON.
#   C. refusals  -> one case per rule (C1..C10b); each render must fail and its
#                   stderr must name the offender.
#   D. byte check -> check-algorithm-declarations.sh exits 0 / 1 / 2.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"
CHECK="$HERE/../check-algorithm-declarations.sh"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

# Drops every document whose top-level kind is Secret, so nothing sensitive is saved.
nosecret() {
  "$PY" -c '
import re, sys
text = sys.stdin.read()
keep = [d for d in re.split(r"(?m)^---[ \t]*$", text)
        if not re.search(r"(?m)^kind:[ \t]*[\"\x27]?Secret[\"\x27]?[ \t]*$", d)]
sys.stdout.write("---".join(keep))
'
}

CHART_USE="$CHART"
render() {  # $1 = out file, rest = extra helm flags
  local out="$1"; shift
  helm template t "$CHART_USE" --set tierNode.enabled=true "$@" 2> "$out.err" | nosecret > "$out"
  return "${PIPESTATUS[0]}"
}

val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

inspect() {
  "$PY" - "$1" <<'PYEOF' | tr -d '\r'
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
n = ok = 0
bad = []
pj = set()
for d in docs:
    if d.get("kind") != "Deployment" or "-faust-edge-" not in d["metadata"]["name"]:
        continue
    name = d["metadata"]["name"]
    edge = name.split("-faust-edge-", 1)[1]
    n += 1
    pod = d["spec"]["template"]["spec"]
    c = next(c for c in pod["containers"] if c["name"] == "faust-edge")
    envs = c.get("env", [])
    def one(k):
        return [e.get("value") for e in envs if e["name"] == k]
    if one("ALGORITHMS_DIR") != ["/opt/openddil/algorithms"]:
        bad.append(f"{name}: ALGORITHMS_DIR {one('ALGORITHMS_DIR')}")
    if one("ALGORITHMS_ENABLED") != ["wear,thermal"]:
        bad.append(f"{name}: ALGORITHMS_ENABLED {one('ALGORITHMS_ENABLED')}")
    if len(one("ALGORITHM_PARAMS_JSON")) != 1:
        bad.append(f"{name}: ALGORITHM_PARAMS_JSON x{len(one('ALGORITHM_PARAMS_JSON'))}")
    else:
        pj.add(one("ALGORITHM_PARAMS_JSON")[0])
    if any(e["name"].startswith("PROGNOSTICS_") for e in envs):
        bad.append(f"{name}: a PROGNOSTICS_ env is present")
    loader = next((i for i in pod.get("initContainers", []) if i["name"] == "bundle-loader"), None)
    if not loader or "/bundle/agents/algorithms" not in " ".join(loader["command"]):
        bad.append(f"{name}: bundle-loader does not copy agents/algorithms")
    mounts = [m for m in c.get("volumeMounts", []) if m["mountPath"] == "/opt/openddil/algorithms"]
    if not (len(mounts) == 1 and mounts[0].get("readOnly") is True and mounts[0].get("subPath") == "algorithms"):
        bad.append(f"{name}: read-only algorithms mount")
    prod = d["metadata"]["annotations"]["openddil.io/produces-topics"].split()
    for want in (f"{edge}/derived-sustainment", f"{edge}/openddil-{edge}-prognostics_accumulators-changelog"):
        if prod.count(want) != 1:
            bad.append(f"{name}: produces-topics has {want} x{prod.count(want)}")
    if not bad or not any(b.startswith(name) for b in bad):
        ok += 1
print(f"faust_edges={n}")
print(f"ok={ok}")
print(f"params_json={'|'.join(sorted(pj))}")
print(f"problems={'; '.join(bad) or 'none'}")
PYEOF
}

# ---- A: defaults
render "$TMP/default.yaml" || { echo "render failed:"; tail -3 "$TMP/default.yaml.err"; exit 1; }
got="$(inspect "$TMP/default.yaml")"
echo "$got" | sed 's/^/  /'
fe="$(val "$got" faust_edges)"
if [ "${fe:-0}" -ge 1 ] && [ "$fe" = "$(val "$got" ok)" ] && [ "$(val "$got" problems)" = none ] && [ "$(val "$got" params_json)" = "{}" ]; then
  echo "PASS A defaults: $fe faust-edge Deployments carry the three ALGORITHM env vars once, no PROGNOSTICS_, the bundle copy, the read-only mount and both produces-topics names"
else
  echo "FAIL A defaults"; FAIL=1
fi

# ---- B: overrides
expect_json() {  # $1 = label, $2 = expected ALGORITHM_PARAMS_JSON, rest = helm flags
  local label="$1" want="$2"; shift 2
  local key="${label%% *}"
  if ! render "$TMP/$key.yaml" "$@"; then
    echo "FAIL $label: render failed:"; tail -2 "$TMP/$key.yaml.err"; FAIL=1; return
  fi
  local g; g="$(inspect "$TMP/$key.yaml")"
  if [ "$(val "$g" params_json)" = "$want" ]; then
    echo "PASS $label: ALGORITHM_PARAMS_JSON = $want"
  else
    echo "FAIL $label: got $(val "$g" params_json), wanted $want"; FAIL=1
  fi
}
# inspect() reports "problems" for the unchanged env checks; only params_json matters here.
expect_json "B1 --set int" '{"wear":{"track_life_total_km":10}}' --set algorithms.units.wear.params.track_life_total_km=10
cat > "$TMP/B2.values.yaml" <<'Y'
algorithms:
  units:
    wear:
      params:
        track_life_total_km: 10.5
        barrel_life_total_rounds: 100
Y
expect_json "B2 -f float" '{"wear":{"barrel_life_total_rounds":100,"track_life_total_km":10.5}}' -f "$TMP/B2.values.yaml"

expect_json "B3 thermal --set" '{"thermal":{"delta_threshold_k":90}}' --set algorithms.units.thermal.params.delta_threshold_k=90

# ---- C: refusals
expect_fail() {  # $1 = label, $2 = text stderr must contain, rest = helm flags
  local label="$1" needle="$2"; shift 2
  local key="${label%% *}"
  if render "$TMP/$key.yaml" "$@"; then
    echo "FAIL $label: a bad declaration rendered"; FAIL=1
  elif grep -qF -- "$needle" "$TMP/$key.yaml.err"; then
    echo "PASS $label: render refused, names: $needle"
  else
    echo "FAIL $label: refused for another reason (wanted: $needle):"; tail -2 "$TMP/$key.yaml.err"; FAIL=1
  fi
}

expect_fail "C1 prognosticsEnv present" "faustEdge.prognosticsEnv was removed" --set faustEdge.prognosticsEnv.X=1
expect_fail "C2a enabled null" "algorithms.enabled must be" --set algorithms.enabled=null
expect_fail "C2b enabled empty" "algorithms.enabled must not" --set 'algorithms.enabled={}'
expect_fail "C2c enabled duplicate" "algorithms.enabled has a duplicate entry" --set 'algorithms.enabled={wear,wear}'
expect_fail "C3 enabled without a chart copy" "files/algorithms/nosuch/unit.yaml" --set 'algorithms.enabled={wear,nosuch}'

# C4: a chart copy under mktemp with a mangled apiVersion
cp -r "$CHART" "$TMP/c4chart"
sed -i 's#^apiVersion: openddil.io/algorithm/v1#apiVersion: openddil.io/algorithm/v0#' "$TMP/c4chart/files/algorithms/wear/unit.yaml"
if cmp -s "$CHART/files/algorithms/wear/unit.yaml" "$TMP/c4chart/files/algorithms/wear/unit.yaml"; then
  echo "FAIL C4: the mangle changed nothing"; FAIL=1
else
  CHART_USE="$TMP/c4chart"
  expect_fail "C4 apiVersion mismatch" "apiVersion must be openddil.io/algorithm/v1"
  CHART_USE="$CHART"
  # and a unit field that does not match its directory
  cp -r "$CHART" "$TMP/c4bchart"
  sed -i 's#^unit: wear#unit: other#' "$TMP/c4bchart/files/algorithms/wear/unit.yaml"
  CHART_USE="$TMP/c4bchart"
  expect_fail "C4b unit differs from its directory" 'unit is "other" but the directory is "wear"'
  CHART_USE="$CHART"
fi

expect_fail "C5 units key not enabled" "algorithms.units.thermal is set" --set 'algorithms.enabled={wear}' --set algorithms.units.thermal.params.x=1
expect_fail "C6 key other than params" "algorithms.units.wear.param is not allowed" --set algorithms.units.wear.param.x=1
expect_fail "C7 undeclared param" "algorithms.units.wear.params.track_life_km is not declared" --set algorithms.units.wear.params.track_life_km=1
expect_fail "C8a --set-string on a number" "algorithms.units.wear.params.track_life_total_km must be a number" --set-string algorithms.units.wear.params.track_life_total_km=10
cat > "$TMP/C8b.values.yaml" <<'Y'
algorithms:
  units:
    wear:
      params:
        barrel_life_total_rounds: 10.5
Y
expect_fail "C8b -f fractional integer" "algorithms.units.wear.params.barrel_life_total_rounds must be an integer" -f "$TMP/C8b.values.yaml"
expect_fail "C8c bool on a number" "algorithms.units.wear.params.critical_fraction must be a number" --set algorithms.units.wear.params.critical_fraction=true
expect_fail "C9 below minimum" "algorithms.units.wear.params.critical_fraction is -1, below the declared minimum" --set algorithms.units.wear.params.critical_fraction=-1
cat > "$TMP/C9b.values.yaml" <<'Y'
algorithms:
  units:
    thermal:
      params:
        ewma_alpha: 1.5
Y
expect_fail "C9b above maximum" "algorithms.units.thermal.params.ewma_alpha is 1.5, above the declared maximum" -f "$TMP/C9b.values.yaml"
expect_fail "C7b undeclared thermal param" "algorithms.units.thermal.params.delta_k is not declared" --set algorithms.units.thermal.params.delta_k=1
expect_fail "C10 memory below the sum" "above faustEdge.resources.limits.memory" --set faustEdge.resources.limits.memory=8Mi
expect_fail "C10b bad memory suffix" 'unsupported suffix "G"' --set faustEdge.resources.limits.memory=1G

# ---- D: byte check
mkdir -p "$TMP/ta/algorithms/wear" "$TMP/ta/algorithms/thermal"
cp "$CHART/files/algorithms/wear/unit.yaml" "$TMP/ta/algorithms/wear/unit.yaml"
cp "$CHART/files/algorithms/thermal/unit.yaml" "$TMP/ta/algorithms/thermal/unit.yaml"
bash "$CHECK" "$TMP/ta" > "$TMP/d1.out" 2>&1; rc=$?
[ "$rc" = 0 ] && echo "PASS D1 identical copy exits 0" || { echo "FAIL D1: exit $rc"; FAIL=1; }
printf '#' >> "$TMP/ta/algorithms/wear/unit.yaml"
bash "$CHECK" "$TMP/ta" > "$TMP/d2.out" 2>&1; rc=$?
if [ "$rc" = 1 ] && grep -q 'unit wear' "$TMP/d2.out"; then echo "PASS D2 one byte changed exits 1, names the unit"; else echo "FAIL D2: exit $rc"; cat "$TMP/d2.out"; FAIL=1; fi
bash "$CHECK" "$TMP/absent" > "$TMP/d3.out" 2>&1; rc=$?
[ "$rc" = 2 ] && echo "PASS D3 absent dir exits 2" || { echo "FAIL D3: exit $rc"; FAIL=1; }

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "FAILED"; fi
exit "$FAIL"
