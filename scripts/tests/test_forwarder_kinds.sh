#!/usr/bin/env bash
# ===========================================================================
# test_forwarder_kinds.sh -- offline render proof that the egress forwarder
# loads the kind declarations the way the gate and the assembler do.
#
# forwarder.py stamps the ledger's episode columns from the kinds'
# x-openddil declarations, read from OPENDDIL_EGRESS_KINDS_DIR. Without the
# env and mount the fallback is silent and every stamp is NULL.
#
# Cases (BASE_REF = the last chart without the wiring; override via env):
#   A. defaults: the render equals BASE_REF's, chart version normalised.
#   B. egress.kinds set + forwarder enabled with a route: the forwarder has
#      the env, a mount at that path, a volume naming <release>-egress-kinds,
#      the checksum/kinds annotation, and that ConfigMap is in the render.
#   C. same values as B: the forwarder is the only Deployment whose rendered
#      spec differs from BASE_REF's.
# Exit 2 = SKIP (no helm / python+PyYAML / BASE_REF).
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"
BASE_REF="${BASE_REF:-540f75d}"
command -v helm >/dev/null 2>&1 || { echo "SKIP: no helm"; exit 2; }
PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

mkdir -p "$TMP/base"
( cd "$HERE/../.." && git archive "$BASE_REF" openddil-demo 2>/dev/null ) | tar -x -C "$TMP/base" 2>/dev/null
[ -f "$TMP/base/openddil-demo/Chart.yaml" ] || { echo "SKIP: no $BASE_REF to compare against"; exit 2; }
BASE="$TMP/base/openddil-demo"

cat > "$TMP/b.yaml" <<'YEOF'
releasability:
  enabled: true
egress:
  kinds:
    FaultReport:
      $schema: "https://json-schema.org/draft/2020-12/schema"
      type: object
      properties:
        asset_id: {type: string}
  forwarder:
    enabled: true
    config:
      - name: fault-out
        source_topic: egress-sink-faults
        destination: https://sink.example.invalid/ingest
YEOF

render() {  # $1 chart $2 out, rest = helm args
  local chart="$1" out="$2"; shift 2
  helm template t "$chart" "$@" > "$out" 2> "$out.err" \
    || { echo "FAIL render: $(tail -n 1 "$out.err")"; FAIL=1; return 1; }
}

render "$BASE"  "$TMP/a_base.yaml" || exit 1
render "$CHART" "$TMP/a_new.yaml"  || exit 1
render "$BASE"  "$TMP/b_base.yaml" -f "$TMP/b.yaml" || exit 1
render "$CHART" "$TMP/b_new.yaml"  -f "$TMP/b.yaml" || exit 1

# A: default renders equal once the chart version is normalised.
norm() { sed -E 's/0\.1\.15[0-9]/CHARTVER/g' "$1"; }
if diff <(norm "$TMP/a_base.yaml") <(norm "$TMP/a_new.yaml") > "$TMP/a.diff"; then
  echo "PASS A defaults: render identical to $BASE_REF (version normalised)"
else
  echo "FAIL A defaults: render differs from $BASE_REF ($(grep -c '^[<>]' "$TMP/a.diff") lines)"; FAIL=1
fi

# B and C in one python pass.
"$PY" - "$TMP/b_base.yaml" "$TMP/b_new.yaml" <<'PYEOF'
import sys, yaml, re
def load(p):
    return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
base, new = load(sys.argv[1]), load(sys.argv[2])
FWD, MOUNT, CMNAME = "t-egress-forwarder", "/etc/openddil/egress-kinds", "t-egress-kinds"
fail = 0

dep = next((d for d in new if d["kind"] == "Deployment" and d["metadata"]["name"] == FWD), None)
missing = []
if dep is None:
    missing.append("forwarder Deployment")
else:
    pod = dep["spec"]["template"]
    spec = pod["spec"]
    c = next(c for c in spec["containers"] if c["name"] == "forwarder")
    env = {e["name"]: e.get("value") for e in c.get("env", [])}
    if env.get("OPENDDIL_EGRESS_KINDS_DIR") != MOUNT:
        missing.append("env OPENDDIL_EGRESS_KINDS_DIR=%s" % MOUNT)
    if not any(m["mountPath"] == MOUNT and m["name"] == "egress-kinds" and m.get("readOnly")
               for m in c.get("volumeMounts", [])):
        missing.append("readOnly volumeMount egress-kinds at %s" % MOUNT)
    if not any(v["name"] == "egress-kinds" and v.get("configMap", {}).get("name") == CMNAME
               for v in spec.get("volumes", [])):
        missing.append("volume egress-kinds from configMap %s" % CMNAME)
    if "checksum/kinds" not in pod["metadata"].get("annotations", {}):
        missing.append("annotation checksum/kinds")
if not any(d["kind"] == "ConfigMap" and d["metadata"]["name"] == CMNAME for d in new):
    missing.append("ConfigMap %s in the render" % CMNAME)
if missing:
    print("FAIL B kinds set: forwarder missing: " + "; ".join(missing)); fail = 1
else:
    print("PASS B kinds set: forwarder has env, mount, volume %s, checksum; ConfigMap rendered" % CMNAME)

def deps(docs):
    return {d["metadata"]["name"]: d["spec"] for d in docs if d["kind"] == "Deployment"}
bd, nd = deps(base), deps(new)
changed = sorted(n for n in set(bd) | set(nd) if bd.get(n) != nd.get(n))
if changed == [FWD]:
    print("PASS C scope: only %s changed against base (%d Deployments compared)" % (FWD, len(nd)))
else:
    print("FAIL C scope: changed Deployments = %s, want [%s]" % (changed, FWD)); fail = 1
sys.exit(fail)
PYEOF
[ $? -eq 0 ] || FAIL=1

exit $FAIL
