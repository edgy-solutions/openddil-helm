#!/usr/bin/env bash
# ===========================================================================
# test_element_state_render.sh -- offline render proof for the elementState
# block (values.yaml) and its six render refusals.
#
# Render values: --set tierNode.enabled=true (the chart's default edges then
# yield tier projectors and faust-edge apps).
#
# Cases:
#   A. defaults  -> every tier-projector container whose config maps
#                   asset_element_telemetry carries ELEMENT_STATE_JSON once
#                   (4 layers at 11.19 / 38.7, heartbeat_s 300); every
#                   faust-edge carries ELEMENT_BANDS_JSON once; the hub
#                   projector carries no ELEMENT_STATE_JSON.
#   B. a profile layer with no kinds entry, or a field with no class.
#   C. a window key on a band or transition field.
#   D. upstream valueWindow other than none, or any upstream valueWindowS.
#   E. element_publish_tier absent or hq while logisticsSim is enabled.
#   F. a value field with a missing/non-positive deadband or no measured note.
#   G. one layer name in two profiles with different value-field deadbands.
# Each refusal render must fail and its stderr must name the offender.
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

render() {  # $1 = out file, rest = extra helm flags
  local out="$1"; shift
  helm template t "$CHART" --set tierNode.enabled=true "$@" > "$out" 2> "$out.err"
}

# Case A facts, one "key=value" per line.
inspect() {
  "$PY" - "$1" <<'PYEOF' | tr -d '\r'
import sys, json, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
cms = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "ConfigMap"}
state_ok = band_n = band_ok = mapped = other_state = 0
bad = []
for d in docs:
    if d.get("kind") != "Deployment":
        continue
    name = d["metadata"]["name"]
    pod = d["spec"]["template"]["spec"]
    for c in pod["containers"]:
        envs = c.get("env", [])
        st = [e["value"] for e in envs if e["name"] == "ELEMENT_STATE_JSON"]
        bd = [e["value"] for e in envs if e["name"] == "ELEMENT_BANDS_JSON"]
        if c["name"] == "faust-edge":
            band_n += 1
            if len(bd) != 1:
                bad.append(f"{name}: ELEMENT_BANDS_JSON x{len(bd)}")
            else:
                j = json.loads(bd[0])
                if set(j) == {"health"} and set(j["health"]) == {"limits", "names", "hysteresis", "severity"}:
                    band_ok += 1
                else:
                    bad.append(f"{name}: bands shape")
        if c["name"] == "projector" and "-tier-projector-" in name:
            cfgname = None
            for v in pod.get("volumes", []):
                if "configMap" in v and "tier-projector-config" in v["configMap"]["name"]:
                    cfgname = v["configMap"]["name"]
            text = "".join(cms[cfgname]["data"].values()) if cfgname in cms else ""
            if "handler: asset_element_telemetry" in text:
                mapped += 1
                if len(st) != 1:
                    bad.append(f"{name}: ELEMENT_STATE_JSON x{len(st)}")
                else:
                    j = json.loads(st[0])
                    ok = (sorted(j["deadbands"]) == sorted(["RADAR UNIT", "BACKPLANE", "PROCESSOR BANK", "GAN MMIC CHIP"])
                          and all(v == {"temp_c": 11.19, "load_pct": 38.7} for v in j["deadbands"].values())
                          and j["heartbeat_s"] == 300
                          and j["bands"]["health"]["limits"] == [0.9, 0.97])
                    if ok:
                        state_ok += 1
                    else:
                        bad.append(f"{name}: state content")
            elif st:
                other_state += 1
        elif c["name"] == "projector" and st:
            other_state += 1   # the hub or an edge projector
print(f"mapping_projectors={mapped}")
print(f"state_ok={state_ok}")
print(f"faust_edges={band_n}")
print(f"bands_ok={band_ok}")
print(f"other_projectors_with_state={other_state}")
print(f"problems={'; '.join(bad) or 'none'}")
PYEOF
}

val() { printf '%s\n' "$1" | sed -n "s/^$2=//p"; }

render "$TMP/default.yaml" || { echo "render failed:"; cat "$TMP/default.yaml.err"; exit 1; }
[ -n "${KEEP_A:-}" ] && cp "$TMP/default.yaml" "$KEEP_A"
got="$(inspect "$TMP/default.yaml")"
echo "$got" | sed 's/^/  /'
mapped="$(val "$got" mapping_projectors)"; ok="$(val "$got" state_ok)"
fe="$(val "$got" faust_edges)"; bok="$(val "$got" bands_ok)"
if [ "${mapped:-0}" -ge 1 ] && [ "$mapped" = "$ok" ] && [ "${fe:-0}" -ge 1 ] && [ "$fe" = "$bok" ] \
   && [ "$(val "$got" other_projectors_with_state)" = 0 ] && [ "$(val "$got" problems)" = none ]; then
  echo "PASS A defaults: $ok/$mapped tier projectors carry ELEMENT_STATE_JSON once, $bok/$fe faust-edges carry ELEMENT_BANDS_JSON once, hub none"
else
  echo "FAIL A defaults"; FAIL=1
fi

expect_fail() {  # $1 = label, $2 = values file, $3 = text the stderr must contain
  local key="${1%% *}"
  if render "$TMP/$key.yaml" -f "$2"; then
    echo "FAIL $1: a bad declaration rendered"; FAIL=1
  elif grep -qF -- "$3" "$TMP/$key.yaml.err"; then
    echo "PASS $1: render refused, names: $3"
  else
    echo "FAIL $1: refused for another reason (wanted: $3):"; tail -2 "$TMP/$key.yaml.err"; FAIL=1
  fi
}

mk() { cat > "$TMP/$1.values.yaml"; }

# B: refusal 1
mk B1 <<'Y'
logisticsSim:
  config:
    asset_profiles:
      - name: mrad
        layers:
          - { name: "RADAR UNIT", prefix: "TR" }
          - { name: "NEW LAYER", prefix: "NL" }
Y
expect_fail "B1 layer without a kinds entry" "$TMP/B1.values.yaml" 'elementState.kinds.mrad has no entry for layer "NEW LAYER"'
mk B2 <<'Y'
elementState:
  kinds:
    mrad:
      "BACKPLANE":
        health: { class: null }
Y
expect_fail "B2 field without a class" "$TMP/B2.values.yaml" 'elementState.kinds.mrad."BACKPLANE".health has no valid class'

# C: refusal 2
mk C1 <<'Y'
elementState:
  kinds:
    mrad:
      "BACKPLANE":
        health: { valueWindowS: 2 }
Y
expect_fail "C1 window on a band field" "$TMP/C1.values.yaml" 'elementState.kinds.mrad."BACKPLANE".health: window key "valueWindowS" is not allowed on a band field'
mk C2 <<'Y'
elementState:
  kinds:
    mrad:
      "BACKPLANE":
        tx_active: { windowS: 2 }
Y
expect_fail "C2 window on a transition field" "$TMP/C2.values.yaml" 'elementState.kinds.mrad."BACKPLANE".tx_active: window key "windowS" is not allowed on a transition field'

# D: refusal 3
mk D1 <<'Y'
elementState:
  destinations:
    upstream: { valueWindow: 5 }
Y
expect_fail "D1 upstream valueWindow not none" "$TMP/D1.values.yaml" 'elementState.destinations.upstream.valueWindow must be none'
mk D2 <<'Y'
elementState:
  destinations:
    upstream: { valueWindowS: 5 }
Y
expect_fail "D2 upstream valueWindowS" "$TMP/D2.values.yaml" 'elementState.destinations.upstream.valueWindowS is not allowed'

# E: refusal 4
mk E1 <<'Y'
logisticsSim:
  config:
    element_publish_tier: hq
Y
expect_fail "E1 publish tier hq" "$TMP/E1.values.yaml" 'logisticsSim.config.element_publish_tier must be edge'
mk E2 <<'Y'
logisticsSim:
  config:
    element_publish_tier: null
Y
expect_fail "E2 publish tier absent" "$TMP/E2.values.yaml" 'logisticsSim.config.element_publish_tier must be edge'

# F: refusal 5
mk F1 <<'Y'
elementState:
  kinds:
    mrad:
      "BACKPLANE":
        temp_c: { class: value, deadband: 0, measured: "x" }
Y
expect_fail "F1 non-positive deadband" "$TMP/F1.values.yaml" 'elementState.kinds.mrad."BACKPLANE".temp_c: a value field needs a deadband greater than 0'
mk F2 <<'Y'
elementState:
  kinds:
    mrad:
      "BACKPLANE":
        load_pct: { measured: null }
Y
expect_fail "F2 missing measured" "$TMP/F2.values.yaml" 'elementState.kinds.mrad."BACKPLANE".load_pct: a value field needs a non-empty measured note'
mk F3 <<'Y'
elementState:
  kinds:
    mrad:
      "BACKPLANE":
        load_pct: { deadband: null }
Y
expect_fail "F3 missing deadband" "$TMP/F3.values.yaml" 'elementState.kinds.mrad."BACKPLANE".load_pct: a value field needs a deadband greater than 0'

# G: refusal 6
mk G <<'Y'
elementState:
  kinds:
    other:
      "BACKPLANE":
        temp_c: { class: value, deadband: 5, measured: "x" }
        load_pct: { class: value, deadband: 38.7, measured: "x" }
Y
expect_fail "G same layer, different deadbands" "$TMP/G.values.yaml" 'layer "BACKPLANE" has different value-field deadbands in profiles'

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
