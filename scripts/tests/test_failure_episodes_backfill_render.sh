#!/usr/bin/env bash
# ===========================================================================
# test_failure_episodes_backfill_render.sh -- the one-shot failure-episodes
# backfill Jobs, read from renders that never touch disk.
#
# One Job per AssetCM (the hub cm-service and every tier-cm-<tier>), because
# the script produces to its own broker with no tier filter. Cases:
#   1. disabled (default): no object named *failure-episodes-backfill*.
#   2. enabled, no files: Jobs = 1 + tier-cm Deployments; no ConfigMap, no
#      --file; hook annotations, cm-service image, workingDir; broker equals
#      the matching cm Deployment's; --admin equals the matching bootstrap
#      Job's RESTATE_ADMIN_URL.
#   3. enabled, files for hub and one tier: exactly those two Jobs carry
#      --file, the volume and mount; their ConfigMaps hold the input
#      byte-for-byte with hook weight "25"; the others carry none.
#   4. every Job: restartPolicy Never, backoffLimit 2.
#
# Renders are piped into the reader, which prints names and counts only.
# Nothing rendered is written anywhere. The only files are the synthetic
# --set-file inputs, which hold no render and are removed on exit.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }
command -v helm >/dev/null 2>&1 || { echo "FAIL: helm not found"; exit 1; }

READER='
import sys, yaml
mode = sys.argv[1]
want_files = {}
for a in sys.argv[2:]:
    k, p = a.split("=", 1)
    want_files[k] = open(p, "rb").read().decode()
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
fail = 0
def check(ok, msg):
    global fail
    print(("PASS " if ok else "FAIL ") + msg)
    fail += not ok

bf = [d for d in docs if "failure-episodes-backfill" in d["metadata"]["name"]]
if mode == "disabled":
    check(len(bf) == 0, f"1: disabled renders {len(bf)} backfill objects")
    sys.exit(1 if fail else 0)

TAG = "failure-episodes-backfill-"
jobs = {d["metadata"]["name"].split(TAG, 1)[1]: d for d in bf if d["kind"] == "Job"}
cms = {d["metadata"]["name"].split(TAG, 1)[1]: d for d in bf if d["kind"] == "ConfigMap"}
deps = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Deployment"}
bootj = {d["metadata"]["name"]: d for d in docs if d["kind"] == "Job"}
def env(c):
    return {e["name"]: e.get("value") for e in c.get("env", [])}
def ctr(d, name=None):
    cs = d["spec"]["template"]["spec"]["containers"]
    return [c for c in cs if name is None or c["name"] == name][0]

rel = [n for n in deps if n.endswith("-cm-service")][0][: -len("-cm-service")]
hub_dep = deps[rel + "-cm-service"]
tier_deps = sorted(n for n, d in deps.items() if n.startswith(rel + "-tier-cm-")
                   and any(c["name"] == "cm-service" for c in d["spec"]["template"]["spec"]["containers"]))
tier_ids = [n[len(rel + "-tier-cm-"):] for n in tier_deps]
print(f"hub cm-service Deployments: 1; tier-cm Deployments: {len(tier_deps)}; Jobs rendered: {len(jobs)}")
check(len(tier_deps) > 0, "2: at least one tier-cm Deployment rendered")
check(sorted(jobs) == sorted(["hub"] + tier_ids), f"2: Jobs = 1 + {len(tier_ids)} tiers")
hub_img = ctr(hub_dep, "cm-service")["image"]

for key, j in sorted(jobs.items()):
    if key == "hub":
        dep = hub_dep
        boot = bootj[rel + "-cm-service-bootstrap"]
    else:
        dep = deps[rel + "-tier-cm-" + key]
        boot = bootj[rel + "-tier-restate-bootstrap-" + key]
    bootenv = env(ctr(boot, "bootstrap"))
    c = ctr(j)
    a = j["metadata"]["annotations"]
    check(a.get("helm.sh/hook") == "post-upgrade" and a.get("helm.sh/hook-weight") == "30"
          and a.get("helm.sh/hook-delete-policy") == "before-hook-creation", f"2: {key}: hook annotations")
    check(c["image"] == hub_img, f"2: {key}: cm-service image")
    check(c.get("workingDir") == "/app/src" and c["command"] == ["python", "/app/src/backfill_failure_episodes.py"], f"2: {key}: workingDir and command")
    want_broker = env(ctr(dep, "cm-service")).get("CM_KAFKA_BROKERS")
    check(want_broker is not None and env(c).get("CM_KAFKA_BROKERS") == want_broker, f"2: {key}: CM_KAFKA_BROKERS equals the cm Deployment")
    args = c.get("args", [])
    adm = args[args.index("--admin") + 1] if "--admin" in args else None
    check(adm is not None and adm == bootenv.get("RESTATE_ADMIN_URL"), f"2: {key}: --admin equals the bootstrap Job RESTATE_ADMIN_URL")
    sp = j["spec"]
    check(sp["template"]["spec"]["restartPolicy"] == "Never" and sp["backoffLimit"] == 2, f"4: {key}: restartPolicy Never, backoffLimit 2")
    has_file = "--file" in args
    vols = sp["template"]["spec"].get("volumes", [])
    mounts = c.get("volumeMounts", [])
    if key in want_files:
        check(has_file and args[args.index("--file") + 1] == "/backfill/episodes.jsonl", f"3: {key}: --file arg")
        check(len(vols) == 1 and len(mounts) == 1 and mounts[0]["mountPath"] == "/backfill" and mounts[0].get("readOnly") is True, f"3: {key}: volume and read-only mount")
        cm = cms.get(key)
        check(cm is not None and cm["data"]["episodes.jsonl"] == want_files[key], f"3: {key}: ConfigMap content byte-equal")
        ca = cm["metadata"]["annotations"] if cm is not None else {}
        check(ca.get("helm.sh/hook") == "post-upgrade" and ca.get("helm.sh/hook-weight") == "25"
              and ca.get("helm.sh/hook-delete-policy") == "before-hook-creation", f"3: {key}: ConfigMap hook weight 25")
        check(bool(sp["template"]["metadata"].get("annotations", {}).get("checksum/episodes")), f"3: {key}: checksum annotation")
    else:
        check(not has_file and not vols and not mounts, f"2/3: {key}: no file arg, volume or mount")
if mode == "nofiles":
    check(len(cms) == 0, f"2: {len(cms)} ConfigMaps (expected 0)")
else:
    check(sorted(cms) == sorted(want_files), f"3: ConfigMaps exist for exactly {sorted(want_files)}")
check(len(jobs) > 0, "Jobs checked > 0")
sys.exit(1 if fail else 0)
'

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
printf '%s\n%s\n' '{"asset":"t-1","episode":{}}' '{"asset":"t-2","episode":{}}' > "$TMPD/hub.jsonl"
printf '%s\n%s\n' '{"asset":"t-3","episode":{}}' '{"asset":"t-4","episode":{}}' > "$TMPD/tier.jsonl"
HUBP="$TMPD/hub.jsonl"; TIERP="$TMPD/tier.jsonl"
if command -v cygpath >/dev/null 2>&1; then HUBP="$(cygpath -m "$HUBP")"; TIERP="$(cygpath -m "$TIERP")"; fi

# A leaf tier (edge-01), a tier with children (region-east) and a tier under
# it (sector-7, also with children).
TIERARGS=(
  --set tierNode.enabled=true
  --set 'edges[0].id=edge-01' --set 'edges[0].region=region-east' --set 'edges[0].udpPort=62040'
  --set 'edges[1].id=region-east' --set 'edges[1].region=hq' --set 'edges[1].hasChildren=true'
  --set 'edges[2].id=sector-7' --set 'edges[2].parent=region-east' --set 'edges[2].hasChildren=true'
)
EN=(--set cmService.failureEpisodesBackfill.enabled=true)
rc=0

echo "== disabled"
helm template t "$CHART" "${TIERARGS[@]}" 2>/dev/null | "$PY" -c "$READER" disabled || rc=1
echo "== enabled, no files"
helm template t "$CHART" "${TIERARGS[@]}" "${EN[@]}" 2>/dev/null | "$PY" -c "$READER" nofiles || rc=1
echo "== enabled, files for hub and edge-01"
helm template t "$CHART" "${TIERARGS[@]}" "${EN[@]}" \
    --set-file "cmService.failureEpisodesBackfill.files.hub=$HUBP" \
    --set-file "cmService.failureEpisodesBackfill.files.edge-01=$TIERP" 2>/dev/null \
  | "$PY" -c "$READER" files "hub=$HUBP" "edge-01=$TIERP" || rc=1

if [ "$rc" = 0 ]; then echo; echo "test_failure_episodes_backfill_render.sh: ALL PASS"; exit 0
else echo; echo "test_failure_episodes_backfill_render.sh: SOME FAILED"; exit 1; fi
