#!/usr/bin/env bash
# ===========================================================================
# test_ontology_deployment_layer.sh -- offline render proof for
# releasability.deploymentLayer (releasabilityYaml, usersYaml).
#
#   L1. both empty            -> no ConfigMap, no volume, no annotation.
#   L2. releasabilityYaml set -> ConfigMap has the key; EVERY workload whose
#                                bundleInit produces `ontology` has the volume,
#                                the init mount, the cp line and the
#                                annotation. The list is derived from the
#                                render, never hardcoded, and its size is
#                                cross-checked against a grep of the render.
#   L3. usersYaml set, variant users -> hub and tier policy-loaders mount and
#                                copy it (the script is RUN against a scratch
#                                tree); topaz checksum/policy changes; every
#                                other workload is unchanged from L1.
#   L4. usersYaml set, variant users-promoted -> the shipped variant is copied.
#   L5. one byte of releasabilityYaml changed -> checksum/ontology-deployment
#                                changes on every L2 workload.
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
if command -v cygpath >/dev/null 2>&1; then TMPW="$(cygpath -m "$TMP")"; else TMPW="$TMP"; fi
FAIL=0

printf 'default_originator_nation: ATL\nassets: {}\n' > "$TMP/rel.yaml"
printf 'default_originator_nation: ATM\nassets: {}\n' > "$TMP/rel2.yaml"
printf 'subjects:\n  deployment-layer-marker: {}\n' > "$TMP/users.yaml"

BASE="--set tierNode.enabled=true --set releasability.enabled=true --set releasability.publicOrigin=https://lab.invalid"
render() {  # $1 = out file, rest = extra helm flags
  local out="$1"; shift
  # shellcheck disable=SC2086
  helm template t "$CHART" $BASE "$@" > "$out" 2> "$out.err" \
    || { echo "render failed:"; cat "$out.err"; return 1; }
}

cat > "$TMP/az.py" <<'PYEOF'
import sys, json, subprocess, os, yaml

KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")
def load(path):
    return [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
def podspec(d):
    t = d["spec"]
    if d["kind"] == "CronJob":
        t = t["jobTemplate"]["spec"]
    return t["template"]
def workloads(path):
    return {d["metadata"]["name"]: d for d in load(path) if d["kind"] in KINDS}
def loader(d, name="bundle-loader"):
    for c in podspec(d)["spec"].get("initContainers", []):
        if c["name"] == name:
            return c
def script(c):
    return "\n".join(c["command"]) if c else ""
def ontology_workloads(path):
    return {n: d for n, d in workloads(path).items() if "-> /shared/ontology" in script(loader(d))}
def vols(d):
    return [v["name"] for v in podspec(d)["spec"].get("volumes", [])]
def ann(d):
    return podspec(d)["metadata"].get("annotations", {}) or {}
def sandbox(s, base):
    return (s.replace("/bundle/", base + "/bundle/").replace("/shared", base + "/shared")
             .replace("/ontology-deployment", base + "/od").replace("/destinations-deployment", base + "/dd"))
def run_sh(s, env=None):
    e = dict(os.environ)
    e.update(env or {})
    return subprocess.run(["sh", "-c", s], capture_output=True, text=True, env=e)

bad = 0
def check(name, ok, detail=""):
    global bad
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + str(detail)))
    if not ok: bad += 1

mode = sys.argv[1]
if mode == "L1":
    path = sys.argv[2]
    text = open(path, encoding="utf-8").read()
    check("L1 no ontology-deployment anywhere in the render", "ontology-deployment" not in text)
    check("L1 no ontology-deployment ConfigMap", not any(d["kind"] == "ConfigMap" and "ontology-deployment" in d["metadata"]["name"] for d in load(path)))
    check("L1 render found ontology workloads (analyzer is not vacuous)", len(ontology_workloads(path)) > 0)

elif mode == "L2":
    path, grep_count, root = sys.argv[2], int(sys.argv[3]), sys.argv[4]
    docs = load(path)
    cm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "t-ontology-deployment"]
    check("L2 ConfigMap t-ontology-deployment rendered", len(cm) == 1)
    if cm:
        check("L2 ConfigMap has releasability.yaml with the fixture", "default_originator_nation: ATL" in cm[0]["data"].get("releasability.yaml", ""))
        check("L2 ConfigMap has no users.yaml", "users.yaml" not in cm[0]["data"])
    ow = ontology_workloads(path)
    check("L2 ontology workload count equals grep of '-> /shared/ontology' (%d)" % grep_count, len(ow) == grep_count and grep_count > 0, "analyzer=%d grep=%d" % (len(ow), grep_count))
    for n, d in sorted(ow.items()):
        c = loader(d)
        mounts = {m["name"]: m for m in c.get("volumeMounts", [])}
        om = mounts.get("ontology-deployment")
        s = script(c)
        check("L2 %s volume" % n, "ontology-deployment" in vols(d))
        check("L2 %s init mount (/ontology-deployment, readOnly)" % n, bool(om) and om["mountPath"] == "/ontology-deployment" and om.get("readOnly") is True)
        check("L2 %s cp line" % n, "cp /ontology-deployment/releasability.yaml /shared/ontology/releasability.yaml" in s and "ontology deployment layer: releasability.yaml (" in s)
        check("L2 %s cp is after the last path copy" % n, s.rfind("cp /ontology-deployment/releasability.yaml") > s.rfind("-> /shared/"))
        check("L2 %s annotation" % n, "checksum/ontology-deployment" in ann(d))
    for n, d in sorted(workloads(path).items()):
        if n not in ow:
            check("L2 %s (not an ontology reader) has no layer" % n, "ontology-deployment" not in vols(d) and "checksum/ontology-deployment" not in ann(d))
    n0 = sorted(ow)[0]
    base = root + "/l2"
    for sub in ("bundle/contracts/ontology", "bundle/demo/ontology", "od"):
        os.makedirs(base + "/" + sub, exist_ok=True)
    open(base + "/bundle/contracts/ontology/releasability.yaml", "w").write("shipped\n")
    open(base + "/od/releasability.yaml", "w").write("deployment\n")
    import re
    for src in re.findall(r"\"/bundle/([^\"]+)\"", script(loader(ow[n0]))):
        os.makedirs(base + "/bundle/" + src, exist_ok=True)
    r = run_sh(sandbox(script(loader(ow[n0])), base))
    got = open(base + "/shared/ontology/releasability.yaml").read() if r.returncode == 0 else r.stderr
    check("L2 running %s's script leaves the deployment file in place" % n0, got == "deployment\n", got)
    check("L2 the script echoes the layer line", "ontology deployment layer: releasability.yaml (%d bytes)" % os.path.getsize(base + "/od/releasability.yaml") in r.stdout, r.stdout)

elif mode == "L3":
    l1, l3, root = sys.argv[2], sys.argv[3], sys.argv[4]
    w1, w3 = workloads(l1), workloads(l3)
    topaz = [n for n in w3 if n == "t-topaz-hq" or n.startswith("t-tier-topaz-")]
    check("L3 found hub and tier topaz (%s)" % ",".join(topaz), "t-topaz-hq" in topaz and any(n.startswith("t-tier-topaz-") for n in topaz))
    for n in topaz:
        d = w3[n]
        c = loader(d, "policy-loader")
        s = script(c)
        check("L3 %s policy-loader mounts the layer" % n, any(m["name"] == "ontology-deployment" and m["mountPath"] == "/ontology-deployment" for m in c["volumeMounts"]) and "ontology-deployment" in vols(d))
        check("L3 %s copies it for variant users" % n, "/ontology-deployment/users.yaml" in s and "(deployment layer)" in s)
        check("L3 %s checksum/policy differs from L1" % n, ann(d).get("checksum/policy") != ann(w1[n]).get("checksum/policy"))
    for n in w1:
        if n in topaz: continue
        check("L3 %s unchanged from L1" % n, json.dumps(w1[n], sort_keys=True) == json.dumps(w3[n], sort_keys=True))
    for n in topaz:
        base = root + "/l3-" + n
        os.makedirs(base + "/bundle/demo/policy", exist_ok=True); os.makedirs(base + "/od", exist_ok=True)
        open(base + "/bundle/demo/policy/users.yaml", "w").write("shipped-users\n")
        open(base + "/od/users.yaml", "w").write("deployment-users\n")
        r = run_sh(sandbox(script(loader(w3[n], "policy-loader")), base), {"OPENDDIL_POLICY_VARIANT": "users"})
        got = open(base + "/shared/policy/openddil/data.yaml").read() if r.returncode == 0 else r.stderr
        check("L3 running %s's policy-loader copies the deployment users.yaml" % n, got == "deployment-users\n", got)
        check("L3 %s says which one it used" % n, "entitlements: users (deployment layer)" in r.stdout, r.stdout)

elif mode == "L4":
    l4, root = sys.argv[2], sys.argv[3]
    w = workloads(l4)
    for n in [n for n in w if n == "t-topaz-hq" or n.startswith("t-tier-topaz-")]:
        c = loader(w[n], "policy-loader")
        env = {e["name"]: e["value"] for e in c["env"]}
        check("L4 %s variant is users-promoted" % n, env.get("OPENDDIL_POLICY_VARIANT") == "users-promoted", env)
        base = root + "/l4-" + n
        os.makedirs(base + "/bundle/demo/policy", exist_ok=True); os.makedirs(base + "/od", exist_ok=True)
        open(base + "/bundle/demo/policy/users.yaml", "w").write("shipped-users\n")
        open(base + "/bundle/demo/policy/users-promoted.yaml", "w").write("shipped-promoted\n")
        open(base + "/od/users.yaml", "w").write("deployment-users\n")
        s = sandbox(script(c), base)
        r = run_sh(s, {"OPENDDIL_POLICY_VARIANT": "users-promoted"})
        got = open(base + "/shared/policy/openddil/data.yaml").read() if r.returncode == 0 else r.stderr
        check("L4 %s copies the shipped users-promoted corpus" % n, got == "shipped-promoted\n", got)
        check("L4 %s says shipped" % n, "users-promoted (shipped)" in r.stdout, r.stdout)
        r2 = run_sh(s, {"OPENDDIL_POLICY_VARIANT": "nope"})
        check("L4 %s missing variant is still refused" % n, r2.returncode != 0 and "FATAL" in r2.stderr, r2.stderr)

elif mode == "L5":
    a, b = ontology_workloads(sys.argv[2]), ontology_workloads(sys.argv[3])
    check("L5 same workload set", sorted(a) == sorted(b) and len(a) > 0)
    for n in sorted(a):
        x = ann(a[n]).get("checksum/ontology-deployment")
        y = ann(b[n]).get("checksum/ontology-deployment") if n in b else None
        check("L5 %s checksum/ontology-deployment changed" % n, bool(x) and bool(y) and x != y, "%s %s" % (x, y))

sys.exit(1 if bad else 0)
PYEOF

run() {
  local out; out="$("$PY" "$TMP/az.py" "$@" | tr -d '\r')"
  echo "$out"
  if echo "$out" | grep -q '^FAIL' || [ -z "$out" ]; then FAIL=1; fi
}

render "$TMP/l1.yaml" || exit 1
run L1 "$TMP/l1.yaml"

render "$TMP/l2.yaml" --set-file releasability.deploymentLayer.releasabilityYaml="$TMP/rel.yaml" || exit 1
GREPN="$(grep -cE '^ +# .* -> /shared/ontology$' "$TMP/l2.yaml")"
run L2 "$TMP/l2.yaml" "$GREPN" "$TMPW"

render "$TMP/l3.yaml" --set releasability.policyVariant=users --set-file releasability.deploymentLayer.usersYaml="$TMP/users.yaml" || exit 1
render "$TMP/l1u.yaml" --set releasability.policyVariant=users || exit 1
run L3 "$TMP/l1u.yaml" "$TMP/l3.yaml" "$TMPW"

render "$TMP/l4.yaml" --set releasability.policyVariant=users-promoted --set-file releasability.deploymentLayer.usersYaml="$TMP/users.yaml" || exit 1
run L4 "$TMP/l4.yaml" "$TMPW"

render "$TMP/l5.yaml" --set-file releasability.deploymentLayer.releasabilityYaml="$TMP/rel2.yaml" || exit 1
run L5 "$TMP/l2.yaml" "$TMP/l5.yaml"

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$FAIL"
