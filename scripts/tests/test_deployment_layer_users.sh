#!/usr/bin/env bash
# ===========================================================================
# test_deployment_layer_users.sh -- offline render proof for
# releasability.deploymentLayer.usersPromotedYaml and .realmUsersJson.
#
#   P1. usersPromotedYaml set -> ConfigMap carries users-promoted.yaml; every
#       topaz policy-loader (hub and tiers) mounts it and, RUN against a
#       scratch tree, picks it for variant users-promoted and the shipped
#       file for variant users; topaz checksum/policy changes with it.
#   P2. usersPromotedYaml with liveReload on -> policy-sync syncs it for the
#       users-promoted variant.
#   R1. realmUsersJson set -> the keycloak-realm ConfigMap carries the overlay
#       and the merge script; a merge-realm-users init container runs before
#       prepare-realm; keycloak checksum/policy changes.
#   R2. malformed JSON, non-array, missing id/username, repeated username or
#       id -> render fails. (Username clashing with a BUNDLE user is refused
#       by the merge script, covered in R3.)
#   R4. both unset -> no ontology-deployment ConfigMap, no merge container,
#       no overlay keys (the byte-identical-to-before comparison is a
#       before/after helm template diff, done by hand at release time).
#   R3. the merge script, run on the shipped realm template: override by id,
#       append, keep-unmentioned, clash refusal, marker and anchors intact.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"
REALM="${REALM:-$HERE/../../../openddil-demo/policy/realm-openddil.json}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
if command -v cygpath >/dev/null 2>&1; then TMPW="$(cygpath -m "$TMP")"; CHARTW="$(cygpath -m "$CHART")"; REALMW="$(cygpath -m "$REALM")"; else TMPW="$TMP"; CHARTW="$CHART"; REALMW="$REALM"; fi
FAIL=0

printf 'subjects:\n  deployment-users-marker: {}\n' > "$TMP/users.yaml"
printf 'subjects:\n  deployment-promoted-marker: {}\n' > "$TMP/promoted.yaml"
printf 'subjects:\n  deployment-promoted-marker-2: {}\n' > "$TMP/promoted2.yaml"
cat > "$TMP/ov.json" <<'EOF'
[
  {"id": "11111111-1111-4111-8111-111111111111", "username": "operator.atl-hq", "enabled": true},
  {"id": "66666666-6666-4666-8666-666666666666", "username": "observer.new", "enabled": true}
]
EOF
printf '[{"id": "66666666-6666-4666-8666-666666666666", "username": "observer.other", "enabled": true}]\n' > "$TMP/ov2.json"

BASE="--set tierNode.enabled=true --set releasability.enabled=true --set releasability.publicOrigin=https://lab.invalid --set releasability.keycloak.enabled=true --set releasability.oidc.enabled=true"
render() {  # $1 = out file, rest = extra helm flags
  local out="$1"; shift
  # shellcheck disable=SC2086
  helm template t "$CHART" $BASE "$@" > "$out" 2> "$out.err" \
    || { echo "render failed:"; cat "$out.err"; return 1; }
}
refuses() {  # $1 = name, $2 = expected message fragment, rest = helm flags
  local name="$1" frag="$2"; shift 2
  # shellcheck disable=SC2086
  if helm template t "$CHART" $BASE "$@" > "$TMP/r.out" 2> "$TMP/r.err"; then
    echo "FAIL $name  rendered but should be refused"; FAIL=1
  elif grep -q -- "$frag" "$TMP/r.err"; then echo "PASS $name"
  else echo "FAIL $name  refused with the wrong message: $(head -c 300 "$TMP/r.err")"; FAIL=1; fi
}

cat > "$TMP/az.py" <<'PYEOF'
import sys, os, subprocess, yaml

KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")
def load(path):
    return [d for d in yaml.safe_load_all(open(path, encoding="utf-8")) if d]
def workloads(path):
    return {d["metadata"]["name"]: d for d in load(path) if d["kind"] in KINDS}
def tmpl(d):
    return d["spec"]["template"]
def init(d, name):
    for c in tmpl(d)["spec"].get("initContainers", []):
        if c["name"] == name: return c
def cont(d, name):
    for c in tmpl(d)["spec"].get("containers", []):
        if c["name"] == name: return c
def script(c):
    return "\n".join(c["command"][2:]) if c else ""   # drop "sh", "-c"
def ann(d):
    return tmpl(d)["metadata"].get("annotations", {}) or {}
def vols(d):
    return [v["name"] for v in tmpl(d)["spec"].get("volumes", [])]
def topaz(w):
    return [n for n in w if n == "t-topaz-hq" or n.startswith("t-tier-topaz-")]
def sandbox(s, base):
    return (s.replace("/bundle/", base + "/bundle/").replace("/shared", base + "/shared")
             .replace("/ontology-deployment", base + "/od").replace("/destinations-deployment", base + "/dd"))
def run_sh(s, env=None):
    e = dict(os.environ); e.update(env or {})
    return subprocess.run(["sh", "-c", s], capture_output=True, text=True, env=e)

bad = 0
def check(name, ok, detail=""):
    global bad
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + str(detail)))
    if not ok: bad += 1

mode = sys.argv[1]
if mode == "P1":
    p0, p1, p2, root = sys.argv[2:6]
    w0, w1, w2 = workloads(p0), workloads(p1), workloads(p2)
    cm = [d for d in load(p1) if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "t-ontology-deployment"]
    check("P1 ConfigMap rendered with exactly users-promoted.yaml", len(cm) == 1 and sorted(cm[0]["data"]) == ["users-promoted.yaml"], cm and sorted(cm[0]["data"]))
    check("P1 ConfigMap holds the fixture", len(cm) == 1 and "deployment-promoted-marker" in cm[0]["data"]["users-promoted.yaml"])
    tz = topaz(w1)
    check("P1 hub and tier topaz found", "t-topaz-hq" in tz and any(n.startswith("t-tier-topaz-") for n in tz), tz)
    for n in tz:
        c = init(w1[n], "policy-loader")
        check("P1 %s mounts the layer" % n, any(m["name"] == "ontology-deployment" and m["mountPath"] == "/ontology-deployment" for m in c["volumeMounts"]) and "ontology-deployment" in vols(w1[n]))
        check("P1 %s checksum/policy differs from unset" % n, ann(w1[n]).get("checksum/policy") != ann(w0[n]).get("checksum/policy"))
        check("P1 %s checksum/policy changes with one byte" % n, ann(w1[n]).get("checksum/policy") != ann(w2[n]).get("checksum/policy"))
        check("P1 %s checksum/ontology-deployment present and changes" % n, ann(w1[n]).get("checksum/ontology-deployment") not in (None, ann(w2[n]).get("checksum/ontology-deployment")))
        base = root + "/p1-" + n
        os.makedirs(base + "/bundle/demo/policy", exist_ok=True); os.makedirs(base + "/od", exist_ok=True)
        open(base + "/bundle/demo/policy/users.yaml", "w").write("shipped-users\n")
        open(base + "/bundle/demo/policy/users-promoted.yaml", "w").write("shipped-promoted\n")
        open(base + "/od/users-promoted.yaml", "w").write("deployment-promoted\n")
        s = sandbox(script(c), base)
        for variant, want in (("users-promoted", "deployment-promoted\n"), ("users", "shipped-users\n")):
            r = run_sh(s, {"OPENDDIL_POLICY_VARIANT": variant})
            got = open(base + "/shared/policy/openddil/data.yaml").read() if r.returncode == 0 else r.stderr
            check("P1 %s variant %s -> %s" % (n, variant, want.strip()), got == want, got)
        r = run_sh(s, {"OPENDDIL_POLICY_VARIANT": "nope"})
        check("P1 %s missing variant still refused" % n, r.returncode != 0 and "FATAL" in r.stderr)
    for n in w0:
        if n in tz: continue
        check("P1 %s unchanged from unset" % n, w0[n] == w1[n])

elif mode == "P2":
    w = workloads(sys.argv[2])
    for n in topaz(w):
        s = script(cont(w[n], "policy-sync"))
        check("P2 %s policy-sync syncs users-promoted" % n, "users|users-promoted)" in s and "/ontology-deployment/${OPENDDIL_POLICY_VARIANT}.yaml" in s)
        check("P2 %s liveReload keeps topaz checksum free of the corpus" % n, "checksum/ontology-deployment" not in ann(w[n]))

elif mode == "R1":
    r0, r1, r2 = sys.argv[2:5]
    docs = load(r1)
    cm = [d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "t-keycloak-realm"]
    check("R1 keycloak-realm ConfigMap has overlay and merge script", len(cm) == 1 and "realm-users-overlay.json" in cm[0]["data"] and "merge-realm-users.py" in cm[0]["data"])
    check("R1 overlay is the validated JSON array", len(cm) == 1 and "operator.atl-hq" in cm[0]["data"]["realm-users-overlay.json"] and cm[0]["data"]["realm-users-overlay.json"].lstrip().startswith("["))
    kc = workloads(r1)["t-keycloak"]
    names = [c["name"] for c in tmpl(kc)["spec"]["initContainers"]]
    check("R1 init order bundle-loader, merge-realm-users, prepare-realm", names.index("bundle-loader") < names.index("merge-realm-users") < names.index("prepare-realm"), names)
    m = init(kc, "merge-realm-users")
    check("R1 merge container runs the script on the staged realm", m["command"][-2:] == ["/bundle-realm/realm-openddil.json", "/subst/realm-users-overlay.json"] and "merge-realm-users.py" in " ".join(m["command"]))
    check("R1 merge container is the stock python image", m["image"].startswith("python:"), m["image"])
    k0 = workloads(r0)["t-keycloak"]
    check("R1 keycloak checksum/policy changes when set", ann(kc).get("checksum/policy") != ann(k0).get("checksum/policy"))
    check("R1 keycloak checksum/policy changes with the overlay", ann(kc).get("checksum/policy") != ann(workloads(r2)["t-keycloak"]).get("checksum/policy"))
    check("R1 unset keycloak has no merge container", init(k0, "merge-realm-users") is None)
    subst = [d for d in load(r0) if d["kind"] == "ConfigMap" and d["metadata"]["name"] == "t-keycloak-realm"][0]["data"]
    check("R1 unset ConfigMap has neither key", "realm-users-overlay.json" not in subst and "merge-realm-users.py" not in subst)

elif mode == "R4":
    text = open(sys.argv[2], encoding="utf-8").read()
    check("R4 unset: no ontology-deployment ConfigMap", not any(d["kind"] == "ConfigMap" and "ontology-deployment" in d["metadata"]["name"] for d in load(sys.argv[2])))
    check("R4 unset: no merge-realm-users anywhere", "merge-realm-users" not in text and "users-promoted.yaml: |" not in text)

sys.exit(1 if bad else 0)
PYEOF

run() {
  local out; out="$("$PY" "$TMP/az.py" "$@" | tr -d '\r')"
  echo "$out"
  if echo "$out" | grep -q '^FAIL' || [ -z "$out" ]; then FAIL=1; fi
}

render "$TMP/p0.yaml" --set releasability.policyVariant=users-promoted --set releasability.liveReload.enabled=false || exit 1
render "$TMP/p1.yaml" --set releasability.policyVariant=users-promoted --set releasability.liveReload.enabled=false --set-file releasability.deploymentLayer.usersPromotedYaml="$TMP/promoted.yaml" || exit 1
render "$TMP/p2.yaml" --set releasability.policyVariant=users-promoted --set releasability.liveReload.enabled=false --set-file releasability.deploymentLayer.usersPromotedYaml="$TMP/promoted2.yaml" || exit 1
run P1 "$TMP/p0.yaml" "$TMP/p1.yaml" "$TMP/p2.yaml" "$TMPW"

render "$TMP/p3.yaml" --set releasability.policyVariant=users-promoted --set releasability.liveReload.enabled=true --set-file releasability.deploymentLayer.usersPromotedYaml="$TMP/promoted.yaml" || exit 1
run P2 "$TMP/p3.yaml"

render "$TMP/r0.yaml" || exit 1
render "$TMP/r1.yaml" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/ov.json" || exit 1
render "$TMP/r2.yaml" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/ov2.json" || exit 1
run R1 "$TMP/r0.yaml" "$TMP/r1.yaml" "$TMP/r2.yaml"
run R4 "$TMP/r0.yaml"

printf '{not json' > "$TMP/bad1.json"
printf '{"id": "a", "username": "b"}' > "$TMP/bad2.json"
printf '[{"username": "b"}]' > "$TMP/bad3.json"
printf '[{"id": "a"}]' > "$TMP/bad4.json"
printf '[{"id": "a", "username": "b"}, {"id": "c", "username": "b"}]' > "$TMP/bad5.json"
printf '[{"id": "a", "username": "b"}, {"id": "a", "username": "c"}]' > "$TMP/bad6.json"
printf '["x"]' > "$TMP/bad7.json"
printf '[{bad' > "$TMP/bad8.json"
refuses "R2 text that is not JSON is refused" "must be a JSON array" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad1.json"
refuses "R2 a JSON object is refused" "must be a JSON array" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad2.json"
refuses "R2 missing id is refused" 'needs a non-empty string \\"id\\"\|needs a non-empty string "id"' --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad3.json"
refuses "R2 missing username is refused" 'username' --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad4.json"
refuses "R2 repeated username is refused" "repeats username b" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad5.json"
refuses "R2 repeated id is refused" "repeats id a" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad6.json"
refuses "R2 non-object element is refused" "is not an object" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad7.json"
refuses "R2 truncated JSON is refused" "not valid JSON" --set-file releasability.deploymentLayer.realmUsersJson="$TMP/bad8.json"

# R3: the merge script itself, on the shipped realm template.
cat > "$TMP/r3.py" <<'PYEOF'
import json, os, shutil, subprocess, sys
script, realm, ov, tmp = sys.argv[1:5]
bad = 0
def check(name, ok, detail=""):
    global bad
    print(("PASS " if ok else "FAIL ") + name + ("" if ok else "  " + str(detail)))
    if not ok: bad += 1
def users(path):
    return json.loads(open(path, encoding="utf-8").read().replace("__TIER_CLIENTS__", "{},"))["users"]
def merge(overlay_path, name):
    dst = os.path.join(tmp, name); shutil.copy(realm, dst)
    r = subprocess.run([sys.executable, "-I", script, dst, overlay_path], capture_output=True, text=True)
    return dst, r
orig = users(realm)
dst, r = merge(ov, "m1.json")
check("R3 merge succeeds", r.returncode == 0, r.stderr)
got = users(dst)
ids = [u["id"] for u in orig]
check("R3 override by id: id 1111 renamed, replaced entirely", got[0]["id"] == ids[0] and got[0]["username"] == "operator.atl-hq" and sorted(got[0]) == ["enabled", "id", "username"], got[0])
check("R3 keep-unmentioned: the other bundle users are unchanged and in order", got[1:len(orig)] == orig[1:], [u["username"] for u in got])
check("R3 append: the new id is last", len(got) == len(orig) + 1 and got[-1]["username"] == "observer.new")
check("R3 usernames unique", len({u["username"] for u in got}) == len(got))
a, b = open(realm, encoding="utf-8").read(), open(dst, encoding="utf-8").read()
check("R3 everything before the users array is byte-identical (marker, realm anchor)", a[:a.index('"users"')] == b[:b.index('"users"')] and "__TIER_CLIENTS__" in b)
clash = os.path.join(tmp, "clash.json")
json.dump([{"id": "77777777-7777-4777-8777-777777777777", "username": orig[1]["username"]}], open(clash, "w"))
dst3, r3 = merge(clash, "m3.json")
check("R3 username clash with a bundle user is refused", r3.returncode != 0 and "more than one realm user" in r3.stderr, r3.stderr)
check("R3 a refused merge leaves the realm untouched", open(dst3, encoding="utf-8").read() == a)
rename_only = os.path.join(tmp, "again.json")
json.dump([{"id": orig[1]["id"], "username": orig[1]["username"], "enabled": False}], open(rename_only, "w"))
dst4, r4 = merge(rename_only, "m4.json")
check("R3 replacing a user by id keeping its own username is not a clash", r4.returncode == 0, r4.stderr)
print("usernames after merge: " + ", ".join(u["username"] for u in got))
sys.exit(1 if bad else 0)
PYEOF
out="$("$PY" "$TMP/r3.py" "$CHARTW/files/merge-realm-users.py" "$REALMW" "$TMPW/ov.json" "$TMPW" | tr -d '\r')"
echo "$out"
if echo "$out" | grep -q '^FAIL' || [ -z "$out" ]; then FAIL=1; fi

if [ "$FAIL" = 0 ]; then echo "ALL PASS"; else echo "FAILURES"; fi
exit "$FAIL"
