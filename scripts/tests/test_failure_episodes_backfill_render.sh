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
#      byte-for-byte with pre-upgrade hook weight "35"; the others carry none.
#   4. every Job: restartPolicy Never, backoffLimit 0.
#   5. every run and check Job: bundle-loader initContainer (gen/python ->
#      proto, baselines -> baselines), PYTHONPATH, CM_BASELINES_DIR, bundle
#      mounts; env names and mountPaths cover the matching cm Deployment's
#      (less the excluded names), extras printed as a record.
#   6. check Jobs: one per run Job, pre-upgrade, weight "40", backoffLimit 0,
#      command has `import main`, `--dry-run`, the run Job's --admin, and
#      --file exactly when the run Job has it.
#   7. run Jobs: command has /dev/termination-log, `exit 0` and --admin; the
#      pod label openddil.io/failure-episodes-backfill=run is on run pods only.
#   8. every pre-* hook weight added by this template is below 49.
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
import re, sys, yaml
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
allj = {d["metadata"]["name"].split(TAG, 1)[1]: d for d in bf if d["kind"] == "Job"}
jobs = {k: d for k, d in allj.items() if not k.startswith("check-")}
checks = {k[len("check-"):]: d for k, d in allj.items() if k.startswith("check-")}
LBL = "openddil.io/failure-episodes-backfill"
Q = chr(39)
def cmdtext(c):
    return " ".join(c.get("command", []))
def adminof(t):
    m = re.search("--admin " + Q + "([^" + Q + "]*)" + Q, t)
    return m.group(1) if m else None
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
    check(c.get("workingDir") == "/app/src" and c["command"][:2] == ["sh", "-c"] and "python /app/src/backfill_failure_episodes.py" in cmdtext(c), f"2: {key}: workingDir and command")
    want_broker = env(ctr(dep, "cm-service")).get("CM_KAFKA_BROKERS")
    check(want_broker is not None and env(c).get("CM_KAFKA_BROKERS") == want_broker, f"2: {key}: CM_KAFKA_BROKERS equals the cm Deployment")
    txt = cmdtext(c)
    adm = adminof(txt)
    check(adm is not None and adm == bootenv.get("RESTATE_ADMIN_URL"), f"2: {key}: --admin equals the bootstrap Job RESTATE_ADMIN_URL")
    sp = j["spec"]
    check(sp["template"]["spec"]["restartPolicy"] == "Never" and sp["backoffLimit"] == 0, f"4: {key}: restartPolicy Never, backoffLimit 0")
    has_file = "--file" in txt
    vols = sp["template"]["spec"].get("volumes", [])
    mounts = c.get("volumeMounts", [])
    if key in want_files:
        check(has_file and "--file /backfill/episodes.jsonl" in txt, f"3: {key}: --file arg")
        ep_v = [v for v in vols if v["name"] == "episodes"]
        ep_m = [m for m in mounts if m["name"] == "episodes"]
        check(len(ep_v) == 1 and len(ep_m) == 1 and ep_m[0]["mountPath"] == "/backfill" and ep_m[0].get("readOnly") is True, f"3: {key}: episodes volume and read-only mount")
        cm = cms.get(key)
        check(cm is not None and cm["data"]["episodes.jsonl"] == want_files[key], f"3: {key}: ConfigMap content byte-equal")
        ca = cm["metadata"]["annotations"] if cm is not None else {}
        check(ca.get("helm.sh/hook") == "pre-upgrade" and ca.get("helm.sh/hook-weight") == "35"
              and ca.get("helm.sh/hook-delete-policy") == "before-hook-creation", f"3: {key}: ConfigMap pre-upgrade weight 35")
        check(bool(sp["template"]["metadata"].get("annotations", {}).get("checksum/episodes")), f"3: {key}: checksum annotation")
    else:
        check(not has_file and not any(v["name"] == "episodes" for v in vols) and not any(m["name"] == "episodes" for m in mounts), f"2/3: {key}: no file arg, episodes volume or mount")
if mode == "nofiles":
    check(len(cms) == 0, f"2: {len(cms)} ConfigMaps (expected 0)")
else:
    check(sorted(cms) == sorted(want_files), f"3: ConfigMaps exist for exactly {sorted(want_files)}")
check(len(jobs) > 0, "Jobs checked > 0")

# Names the Job need not carry: the Deployment HTTP/log/staleness settings
# and its database connection names.
SKIP = {"CM_HTTP_PORT", "CM_STALENESS_WINDOW_S", "LOG_LEVEL"}
def skipped(n):
    return n in SKIP or n.startswith("PG") or "DSN" in n
check(sorted(checks) == sorted(jobs), f"6: one check Job per run Job ({len(checks)} of {len(jobs)})")
for kind, group in (("run", jobs), ("check", checks)):
    for key, j in sorted(group.items()):
        dep = hub_dep if key == "hub" else deps[rel + "-tier-cm-" + key]
        pod = j["spec"]["template"]["spec"]
        c = ctr(j)
        e = env(c)
        tag = f"{kind} {key}"
        ics = pod.get("initContainers", [])
        bl = [i for i in ics if i["name"] == "bundle-loader"]
        itxt = " ".join(bl[0].get("command", [])) if bl else ""
        check(len(bl) == 1 and "/bundle/contracts/gen/python" in itxt and "/shared/proto" in itxt
              and "/bundle/contracts/baselines" in itxt and "/shared/baselines" in itxt, f"5: {tag}: bundle-loader paths")
        check(e.get("PYTHONPATH") == "/proto:/app/src" and e.get("CM_BASELINES_DIR") == "/baselines", f"5: {tag}: PYTHONPATH and CM_BASELINES_DIR")
        mset = {(m["name"], m["mountPath"], m.get("subPath")) for m in c.get("volumeMounts", [])}
        check(("bundle-shared", "/proto", "proto") in mset and ("bundle-shared", "/baselines", "baselines") in mset, f"5: {tag}: bundle-shared mounts")
        dc = ctr(dep, "cm-service")
        dn = {n for n in env(dc) if not skipped(n)}
        miss = sorted(dn - set(e))
        check(not miss, f"5: {tag}: carries the cm Deployment env names (missing {miss})")
        print(f"     record: {tag}: Deployment env names not on the Job: {sorted(set(env(dc)) - set(e))}")
        dm = {m["mountPath"] for m in dc.get("volumeMounts", [])}
        jm = {m["mountPath"] for m in c.get("volumeMounts", [])}
        check(not (dm - jm), f"5: {tag}: carries the cm Deployment mountPaths (missing {sorted(dm - jm)})")
        print(f"     record: {tag}: Job mountPaths not on the Deployment: {sorted(jm - dm)}")
        lab = j["spec"]["template"]["metadata"]["labels"].get(LBL)
        txt = cmdtext(c)
        if kind == "run":
            check(lab == "run", f"7: {key}: run pod carries the backfill label")
            check("/dev/termination-log" in txt and "exit 0" in txt and "--admin" in txt, f"7: {key}: command has termination-log, exit 0, --admin")
        else:
            rt = cmdtext(ctr(jobs[key]))
            a = j["metadata"]["annotations"]
            check(lab is None, f"7: {key}: check pod does not carry the backfill label")
            check(a.get("helm.sh/hook") == "pre-upgrade" and a.get("helm.sh/hook-weight") == "40"
                  and a.get("helm.sh/hook-delete-policy") == "before-hook-creation,hook-succeeded"
                  and j["spec"]["backoffLimit"] == 0, f"6: {key}: check hook pre-upgrade weight 40, backoffLimit 0")
            check("import main" in txt and "--dry-run" in txt and adminof(txt) is not None and adminof(txt) == adminof(rt), f"6: {key}: command has import main, --dry-run and the run Job --admin")
            check(("--file" in txt) == ("--file" in rt), f"6: {key}: --file iff the run Job has it")
for d in bf:
    a = d["metadata"].get("annotations", {})
    hk = a.get("helm.sh/hook", "")
    if hk.startswith("pre-"):
        w = int(a["helm.sh/hook-weight"])
        nm = d["metadata"]["name"]
        check(w < 49, f"8: {nm}: pre-* weight {w} below 49")
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
