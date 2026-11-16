#!/usr/bin/env bash
# ===========================================================================
# test_pep_handle_state_render.sh -- offline render proof for the opt-in PEP
# handle-state volume (releasability.pep.handleState).
#
# Render values: one region, two edges, plus the hub (4 PEP Deployments).
# The render is NEVER written unfiltered: helm's stdout goes straight into a
# python filter that drops every `kind: Secret` document; only the rest is
# written to disk.
#
# Cases:
#   A. default: no PEP Deployment has the env, a handle-state volume or a
#      strategy; no PVC named *-handle-state.
#   B. enabled: 4 PVCs (hub + 3 tiers), 64Mi, RWO, keep annotation, no
#      storageClassName; each PEP has Recreate, env pair, mount, own claim.
#   C. enabled + size/storageClass/everySeconds: PVCs and env follow.
#   D. enabled false renders identical (sha256) to the key removed.
#   E. no other Deployment (Electric, intake, forwarder) gains the env,
#      mount, volume or strategy.
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
FAIL=0; N=0; FAILED=""

cat > "$TMP/tiers.yaml" <<'YEOF'
releasability: {enabled: true, oidc: {enabled: true}}
tierNode: {enabled: true}
tiers:
  - {id: region-a, kind: region, parent: root, hasChildren: true, label: region-a, publicOrigin: "http://region-a.test", directIngest: false, region: region-a}
  - {id: edge-a1, kind: edge, parent: region-a, hasChildren: false, label: edge-a1, publicOrigin: "http://edge-a1.test", directIngest: true, region: region-a}
  - {id: edge-a2, kind: edge, parent: region-a, hasChildren: false, label: edge-a2, publicOrigin: "http://edge-a2.test", directIngest: true, region: region-a}
YEOF

# Secret-stripping filter: stdin -> stdout, drops whole documents whose
# top-level kind is Secret.
cat > "$TMP/strip.py" <<'PYEOF'
import re, sys
text = sys.stdin.read()
docs = re.split(r"(?m)^---[ \t]*$", text)
keep = [d for d in docs if not re.search(r"(?m)^kind:[ \t]*Secret[ \t]*$", d)]
sys.stdout.write("---".join(keep))
PYEOF

# $1 = out file (filtered), rest = extra --set flags. Nothing but the
# filter writes the render.
render() {
  local out="$1"; shift
  helm template t "$CHART" -f "$TMP/tiers.yaml" "$@" 2> "$out.err" | "$PY" "$TMP/strip.py" > "$out"
  if [ "${PIPESTATUS[0]}" != 0 ]; then echo "render failed:"; cat "$out.err"; exit 1; fi
}

# Prints one line per failed assertion.
# usage: assess <file> <off|on> <size> <storageClass> <everySeconds>
assess() {
  "$PY" - "$@" <<'PYEOF' | tr -d '\r'
import sys, yaml
path, mode, size, sc, every = sys.argv[1:6]
docs = [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
PEPS = {"t-pep", "t-tier-pep-region-a", "t-tier-pep-edge-a1", "t-tier-pep-edge-a2"}
deps = {d["metadata"]["name"]: d for d in docs if d.get("kind") == "Deployment"}
pvcs = {d["metadata"]["name"]: d for d in docs
        if d.get("kind") == "PersistentVolumeClaim" and d["metadata"]["name"].endswith("-handle-state")}
bad = []
if not PEPS <= set(deps):
    bad.append("missing PEP deployments %s" % sorted(PEPS - set(deps)))
def ctrs(d): return d["spec"]["template"]["spec"]["containers"]
def envs(d): return {e["name"]: e.get("value") for c in ctrs(d) for e in c.get("env", [])}
def mounts(d): return [m for c in ctrs(d) for m in c.get("volumeMounts", [])]
def vols(d): return d["spec"]["template"]["spec"].get("volumes", [])
F, E = "OPENDDIL_PEP_HANDLE_STATE_FILE", "OPENDDIL_PEP_HANDLE_STATE_EVERY_S"
for n in sorted(PEPS & set(deps)):
    d = deps[n]
    if mode == "off":
        if F in envs(d) or E in envs(d): bad.append(n + " has env")
        if any(v["name"] == "handle-state" for v in vols(d)): bad.append(n + " has volume")
        if any(m["name"] == "handle-state" for m in mounts(d)): bad.append(n + " has mount")
        if "strategy" in d["spec"]: bad.append(n + " has strategy")
    else:
        if d["spec"].get("strategy") != {"type": "Recreate"}: bad.append(n + " strategy")
        e = envs(d)
        if e.get(F) != "/var/lib/openddil-pep/handles.json": bad.append(n + " file env %r" % e.get(F))
        if e.get(E) != every: bad.append(n + " every env %r" % e.get(E))
        ms = [m for m in mounts(d) if m["name"] == "handle-state"]
        if len(ms) != 1 or ms[0]["mountPath"] != "/var/lib/openddil-pep": bad.append(n + " mount")
        vs = [v for v in vols(d) if v["name"] == "handle-state"]
        if len(vs) != 1 or vs[0].get("persistentVolumeClaim", {}).get("claimName") != n + "-handle-state":
            bad.append(n + " claimName")
        p = pvcs.get(n + "-handle-state")
        if p is None:
            bad.append(n + " no PVC"); continue
        s = p["spec"]
        if s["accessModes"] != ["ReadWriteOnce"]: bad.append(n + " pvc access")
        if s["resources"]["requests"]["storage"] != size: bad.append(n + " pvc size")
        if sc:
            if s.get("storageClassName") != sc: bad.append(n + " pvc storageClassName")
        elif "storageClassName" in s:
            bad.append(n + " pvc has storageClassName")
        if p["metadata"].get("annotations", {}).get("helm.sh/resource-policy") != "keep": bad.append(n + " pvc keep")
        if not p["metadata"].get("labels") or p["metadata"]["labels"] != d["metadata"]["labels"]:
            bad.append(n + " pvc labels")
if mode == "off" and pvcs: bad.append("PVCs rendered: %s" % sorted(pvcs))
if mode == "on" and len(pvcs) != 4: bad.append("expected 4 PVCs, got %d" % len(pvcs))
for n, d in deps.items():
    if n in PEPS: continue
    if F in envs(d) or E in envs(d): bad.append(n + " (other) has env")
    if any(m["name"] == "handle-state" for m in mounts(d)): bad.append(n + " (other) has mount")
    if any(v["name"] == "handle-state" for v in vols(d)): bad.append(n + " (other) has volume")
for b in bad: print(b)
PYEOF
}

# Strategy of every non-PEP Deployment, to compare an enabled render with the
# default one.
other_strategies() {
  "$PY" - "$1" <<'PYEOF' | tr -d '\r'
import sys, yaml
PEPS = {"t-pep", "t-tier-pep-region-a", "t-tier-pep-edge-a1", "t-tier-pep-edge-a2"}
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"] not in PEPS:
        print(d["metadata"]["name"], d["spec"].get("strategy"))
PYEOF
}

check() {  # name, got, want
  N=$((N+1))
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ';')"; echo "  want: $(echo "$3" | tr '\n' ';')"; FAIL=1; FAILED="$FAILED [$1]"; fi
}

render "$TMP/a.yaml"
check "A default: nothing rendered" "$(assess "$TMP/a.yaml" off 64Mi '' 30)" ""

render "$TMP/b.yaml" --set releasability.pep.handleState.enabled=true
check "B enabled: 4 PVCs, Recreate, env, mount, claim" "$(assess "$TMP/b.yaml" on 64Mi '' 30)" ""

render "$TMP/c.yaml" --set releasability.pep.handleState.enabled=true \
  --set releasability.pep.handleState.size=128Mi \
  --set releasability.pep.handleState.storageClass=local-path \
  --set releasability.pep.handleState.everySeconds=10
check "C size/storageClass/everySeconds" "$(assess "$TMP/c.yaml" on 128Mi local-path 10)" ""

render "$TMP/d.yaml" --set releasability.pep.handleState=null
check "D enabled false == key removed (sha256)" "$(sha256sum < "$TMP/a.yaml")" "$(sha256sum < "$TMP/d.yaml")"

check "E other deployments unchanged (B vs default)" "$(other_strategies "$TMP/b.yaml")" "$(other_strategies "$TMP/a.yaml")"
check "E other deployments unchanged (C vs default)" "$(other_strategies "$TMP/c.yaml")" "$(other_strategies "$TMP/a.yaml")"

if [ "$FAIL" = 0 ]; then echo "PASS $N/$N"; else echo "FAIL:$FAILED"; fi
exit "$FAIL"
