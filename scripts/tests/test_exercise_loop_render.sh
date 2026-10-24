#!/usr/bin/env bash
# ===========================================================================
# test_exercise_loop_render.sh -- offline render proof for the exercise loop
# (exerciseControl.loop) and the lab/test stub adapter
# (exerciseControl.stubAdapter).
#
# Fail renders (each must name its reason):
#   F1 a reset step while resetJob is off
#   F2 a step kind outside op/reset/wait_s/await
#   F3 an op step naming an op the adapter lacks
#   F4 an adapter op named loop, F5 a sequence named loop / loopstop
#   F6 stub adapter enabled with no simSourceConfigMap
# Positive renders:
#   P0 default render carries none of it
#   P1 loop.json, env, per-edge Connect metrics Service, NetworkPolicy rule,
#      Role rule scoped by resourceNames
#   P2 the record ConfigMap has metadata only -- no `data` field
#   P3 the stub adapter: Deployment + Service, env, no role label, and the
#      simulator script ConfigMap mounted at /src
#   P4 stub disabled (exercise-control on): no stub Deployment or Service
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"
command -v helm >/dev/null 2>&1 || { echo "SKIP: no helm"; exit 2; }
PY=$(command -v python3 || command -v python || echo py)
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

BASE=(--set releasability.enabled=true --set exerciseControl.enabled=true
      --set exerciseControl.adapter.endpoint=https://example.invalid/api
      --set exerciseControl.adapter.operations.pause.method=POST
      --set exerciseControl.adapter.operations.pause.path=/pause
      --set exerciseControl.adapter.operations.stop.method=POST
      --set exerciseControl.adapter.operations.stop.path=/stop
      --set exerciseControl.adapter.operations.run.method=POST
      --set exerciseControl.adapter.operations.run.path=/run)
LOOP=(--set exerciseControl.loop.enabled=true)
RESET=(--set exerciseControl.resetJob.enabled=true)

failcase() {
  local name="$1" needle="$2"; shift 2
  if helm template t "$CHART" "$@" >/dev/null 2>"$TMP/e"; then
    echo "FAIL $name: render succeeded"; FAIL=1
  elif grep -q -- "$needle" "$TMP/e"; then
    echo "PASS $name: refused ($needle)"
  else
    echo "FAIL $name: failed for another reason: $(tail -1 "$TMP/e" | cut -c1-200)"; FAIL=1
  fi
}

failcase "F1 reset step, resetJob off" "loop has a reset step but exerciseControl.resetJob.enabled is false" \
  "${BASE[@]}" "${LOOP[@]}"
failcase "F2 unknown step kind" "step 1 has kind \"bogus\"" \
  "${BASE[@]}" "${LOOP[@]}" "${RESET[@]}" \
  --set-json 'exerciseControl.loop.steps=[{"await":"scenarioEnd"},{"bogus":"x"}]'
failcase "F3 op not in adapter" "op \"resume\" is not in exerciseControl.adapter.operations" \
  "${BASE[@]}" "${LOOP[@]}" "${RESET[@]}" \
  --set-json 'exerciseControl.loop.steps=[{"op":"resume"}]'
failcase "F4 adapter op named loop" "reserved for the loop" \
  "${BASE[@]}" --set exerciseControl.adapter.operations.loop.method=POST \
  --set exerciseControl.adapter.operations.loop.path=/x
failcase "F5a sequence named loop" "reserved for the loop" \
  "${BASE[@]}" --set-json 'exerciseControl.sequences={"loop":{"label":"L","steps":[{"wait_s":1}]}}'
failcase "F5b sequence named loopstop" "reserved for the loop" \
  "${BASE[@]}" --set-json 'exerciseControl.sequences={"loopstop":{"label":"L","steps":[{"wait_s":1}]}}'

failcase "F6 stub enabled, no simSourceConfigMap" "exerciseControl.stubAdapter.simSourceConfigMap"   "${BASE[@]}" --set exerciseControl.stubAdapter.enabled=true
failcase "F6b message says the image has no script" "carries no simulator script"   "${BASE[@]}" --set exerciseControl.stubAdapter.enabled=true

# P4: stub disabled, exercise-control on.
helm template t "$CHART" "${BASE[@]}" > "$TMP/p4.yaml" 2>/dev/null
if grep -q "exercise-stub-adapter" "$TMP/p4.yaml"; then
  echo "FAIL P4 stub disabled still renders stub objects"; FAIL=1
else echo "PASS P4 stub disabled renders no stub objects"; fi

# P0: default render has none of it.
helm template t "$CHART" > "$TMP/p0.yaml" 2>/dev/null
if grep -q "exercise-loop-record\|exercise-stub-adapter\|EXERCISE_LOOP" "$TMP/p0.yaml"; then
  echo "FAIL P0 default render carries loop/stub objects"; FAIL=1
else echo "PASS P0 default render carries no loop/stub objects"; fi

# P1/P2: loop enabled.
helm template t "$CHART" "${BASE[@]}" "${LOOP[@]}" "${RESET[@]}" > "$TMP/p1.yaml" 2>"$TMP/p1.err" \
  || { echo "FAIL P1 render: $(tail -1 "$TMP/p1.err")"; FAIL=1; }
"$PY" - "$TMP/p1.yaml" <<'PYEOF' || FAIL=1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
def get(kind, name):
    for d in docs:
        if d.get("kind") == kind and d["metadata"]["name"] == name:
            return d
bad = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok:
        bad.append(msg)
cm = get("ConfigMap", "t-exercise-control-adapter")
loop = json.loads(cm["data"].get("loop.json", "null")) if cm else None
check(bool(loop) and loop.get("steps") == [{"await": "scenarioEnd"}, {"op": "stop"}, {"reset": "quick"}, {"op": "run"}]
      and loop.get("quietSeconds") == 120 and loop.get("fallbackSeconds") == 720 and loop.get("recordMax") == 50,
      "P1 loop.json carries steps, quietSeconds, fallbackSeconds, recordMax")
dep = get("Deployment", "t-exercise-control")
env = {e["name"]: e.get("value") for e in dep["spec"]["template"]["spec"]["containers"][0]["env"]}
check(env.get("EXERCISE_LOOP_FILE") == "/etc/exercise/loop.json", "P1 EXERCISE_LOOP_FILE")
check(env.get("EXERCISE_LOOP_RECORD_CM") == "t-exercise-loop-record", "P1 EXERCISE_LOOP_RECORD_CM")
srcs = [s for s in (env.get("EXERCISE_INFLIGHT_SOURCES") or "").split(",") if s]
check(len(srcs) >= 1 and all(s.endswith(":4196/metrics") and "-redpanda-connect-" in s and "-metrics" in s for s in srcs),
      "P1 EXERCISE_INFLIGHT_SOURCES names the Connect metrics Services on :4196 (%d)" % len(srcs))
svcs = [d for d in docs if d.get("kind") == "Service"
        and "-redpanda-connect-" in d["metadata"]["name"] and d["metadata"]["name"].endswith("-metrics")]
check(len(svcs) >= 1 and len(svcs) == len(srcs) and all(s["spec"].get("clusterIP") == "None" and s["spec"]["ports"][0]["port"] == 4196 for s in svcs),
      "P1 one headless metrics Service per edge Connect on 4196")
np = get("NetworkPolicy", "t-exercise-control-only")
ports = [p.get("port") for r in np["spec"]["egress"] for p in r.get("ports", [])]
check(4196 in ports, "P1 NetworkPolicy egress allows the Connect metrics port")
role = get("Role", "t-exercise-control")
rule = [r for r in role["rules"] if r.get("resources") == ["configmaps"]]
check(len(rule) == 1 and rule[0].get("resourceNames") == ["t-exercise-loop-record"]
      and sorted(rule[0]["verbs"]) == ["get", "patch"], "P1 Role: configmaps get+patch on the record only")
rec = get("ConfigMap", "t-exercise-loop-record")
check(rec is not None, "P2 record ConfigMap renders")
check(rec is not None and "data" not in rec and "binaryData" not in rec,
      "P2 record ConfigMap has no data field (helm upgrades never overwrite records)")
sys.exit(1 if bad else 0)
PYEOF

# P3: stub adapter.
helm template t "$CHART" "${BASE[@]}" --set exerciseControl.stubAdapter.enabled=true \
  --set exerciseControl.stubAdapter.simSourceConfigMap=my-sim-src \
  --set exerciseControl.stubAdapter.simArgs="--rate 2" \
  --set-json 'exerciseControl.stubAdapter.simArgsCycle=["--a","--b"]' \
  --set exerciseControl.stubAdapter.env.DIS_TARGET_HOST=h > "$TMP/p3.yaml" 2>"$TMP/p3.err" \
  || { echo "FAIL P3 render: $(tail -1 "$TMP/p3.err")"; FAIL=1; }
"$PY" - "$TMP/p3.yaml" <<'PYEOF' || FAIL=1
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
def get(kind, name):
    for d in docs:
        if d.get("kind") == kind and d["metadata"]["name"] == name:
            return d
bad = []
def check(ok, msg):
    print(("PASS " if ok else "FAIL ") + msg)
    if not ok:
        bad.append(msg)
dep = get("Deployment", "t-exercise-stub-adapter")
svc = get("Service", "t-exercise-stub-adapter")
check(dep is not None and svc is not None, "P3 stub Deployment and Service render")
if dep:
    labels = dep["spec"]["template"]["metadata"]["labels"]
    check("openddil.io/role" not in labels and "openddil.io/role" not in dep["metadata"]["labels"],
          "P3 stub carries no openddil.io/role label")
    c = dep["spec"]["template"]["spec"]["containers"][0]
    env = {e["name"]: e.get("value") for e in c["env"]}
    check(env.get("STUB_SIM_PATH") == "/src/dis_sim.py" and env.get("STUB_SIM_ARGS") == "--rate 2"
          and json.loads(env.get("STUB_SIM_ARGS_CYCLE", "null")) == ["--a", "--b"]
          and env.get("DIS_TARGET_HOST") == "h" and env.get("STUB_PORT") == "8096", "P3 stub env")
    check(c["command"][-1].endswith("stub_adapter.py") and "dis-sim" in c["image"],
          "P3 stub runs stub_adapter.py from the dis-sim image")
    pod = dep["spec"]["template"]["spec"]
    vol = [v for v in pod.get("volumes", []) if v.get("name") == "sim-src"]
    check(len(vol) == 1 and vol[0].get("configMap", {}).get("name") == "my-sim-src"
          and vol[0]["configMap"].get("items") == [{"key": "dis_sim.py", "path": "dis_sim.py"}],
          "P3 volume sim-src is the named ConfigMap, key dis_sim.py")
    mnt = [m for m in c.get("volumeMounts", []) if m.get("name") == "sim-src"]
    check(len(mnt) == 1 and mnt[0].get("mountPath") == "/src",
          "P3 sim-src mounted at /src")
sys.exit(1 if bad else 0)
PYEOF
exit $FAIL
