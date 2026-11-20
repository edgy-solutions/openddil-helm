#!/usr/bin/env bash
# ===========================================================================
# test_element_band_events_render.sh -- offline render proof that the
# per-element band transitions (openddil.element.band) are routed to the
# edge-local topic element-band-events by a tier-managed edge's faust-edge,
# land in the owning leaf tier's projector, and cross no bridge or uplink.
#
# Topology: region-a is a tier node (has children) with edge-a1 under it;
# edge-a2 is on the region but NOT in tierNode.tiers (unmanaged); edge-d is
# attached directly to HQ (unmanaged).
#
# Cases:
#   A. managed edge-a1 faust-edge: env ELEMENT_BAND_EVENTS_TOPIC and
#      produces-topics name edge-a1/element-band-events.
#   B. unmanaged edge-a2 and edge-d: no such env, no such produces entry.
#   C. leaf tier projector (edge-a1): the config entry, and the
#      consumer-groups annotation names edge-a1/tier-projector-element-band-events-edge-a1.
#   D. region-a (has children): no such entry or group.
#   E. no bridge / uplink topic list carries it (the checked lists are printed).
#   F. the topic-init script names it.
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

cat > "$TMP/values.yaml" <<'YAML'
tierNode:
  enabled: true
  tiers: [region-a, edge-a1]
linkStatus:
  enabled: true
releasability:
  enabled: true
regions:
  - id: region-a
edges:
  - id: edge-a1
    region: region-a
    udpPort: 62040
  - id: edge-a2
    region: region-a
    udpPort: 62041
  - id: edge-d
    udpPort: 62042
tiers:
  - {id: region-a, kind: region, parent: root, hasChildren: true, label: region-a, publicOrigin: "", directIngest: false, region: region-a}
  - {id: edge-a1, kind: edge, parent: region-a, hasChildren: false, label: edge-a1, publicOrigin: "", directIngest: true, region: region-a}
  - {id: edge-a2, kind: edge, parent: region-a, hasChildren: false, label: edge-a2, publicOrigin: "", directIngest: true, region: region-a}
  - {id: edge-d, kind: edge, parent: "", hasChildren: false, label: edge-d, publicOrigin: "", directIngest: true, region: ""}
YAML

helm template t "$CHART" -f "$TMP/values.yaml" > "$TMP/out.yaml" 2> "$TMP/err" \
  || { echo "FAIL render failed:"; head -5 "$TMP/err"; exit 1; }

"$PY" - "$TMP/out.yaml" <<'PYEOF'
import sys, re, yaml
T = "element-band-events"
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
fail = 0
def ok(cond, msg):
    global fail
    print(("ok   " if cond else "FAIL ") + msg)
    if not cond: fail = 1

def dep(name):
    return next((d for d in docs if d["kind"] == "Deployment" and d["metadata"]["name"] == name), None)
def envof(d):
    out = {}
    for c in d["spec"]["template"]["spec"].get("containers", []):
        for e in c.get("env", []):
            out[e["name"]] = e.get("value")
    return out
def produces(d):
    return d["metadata"]["annotations"].get("openddil.io/produces-topics", "").split()
def projcfg(tier):
    cm = next((d for d in docs if d["kind"] == "ConfigMap" and d["metadata"]["name"] == f"t-tier-projector-config-{tier}"), None)
    return None if cm is None else yaml.safe_load(cm["data"]["projector_config.yaml"])

# A
d = dep("t-faust-edge-edge-a1")
ok(d is not None, "A faust-edge-edge-a1 rendered")
ok(envof(d).get("ELEMENT_BAND_EVENTS_TOPIC") == T, "A managed edge-a1 env ELEMENT_BAND_EVENTS_TOPIC=" + T)
ok(f"edge-a1/{T}" in produces(d), f"A managed edge-a1 produces-topics names edge-a1/{T}")
# B
for e in ("edge-a2", "edge-d"):
    d = dep(f"t-faust-edge-{e}")
    ok(d is not None, f"B faust-edge-{e} rendered")
    ok("ELEMENT_BAND_EVENTS_TOPIC" not in envof(d), f"B unmanaged {e} has no ELEMENT_BAND_EVENTS_TOPIC env")
    ok(not any(T in p for p in produces(d)), f"B unmanaged {e} produces-topics has no {T}")
# C
cfg = projcfg("edge-a1")
ents = [x for x in (cfg or {}).get("mappings", []) if x.get("topic") == T]
ok(len(ents) == 1, "C leaf tier edge-a1 projector config has one element-band-events entry")
if ents:
    x = ents[0]
    want = {"handler": "tactical_events", "table": "tactical_events", "mode": "append", "decode_as": "cloudevents.json",
            "consumer_group": "tier-projector-element-band-events-edge-a1"}
    ok(all(x.get(k) == v for k, v in want.items()), "C entry fields: handler/table/mode/decode_as/consumer_group")
    tac = next(y for y in cfg["mappings"] if y.get("topic") == "tactical-events")
    ok(x.get("retention_hours") == tac.get("retention_hours") and x.get("retention_hours") is not None,
       "C entry retention_hours equals the tactical-events entry's")
pj = dep("t-tier-projector-edge-a1")
ann = pj["metadata"]["annotations"].get("openddil.io/consumer-groups", "").split()
ok("edge-a1/tier-projector-element-band-events-edge-a1" in ann, "C consumer-groups annotation names edge-a1/tier-projector-element-band-events-edge-a1")
# D
cfg = projcfg("region-a")
ok(cfg is not None and any(x.get("topic") == "tactical-events" for x in cfg.get("mappings", [])) and not any(x.get("topic") == T for x in cfg.get("mappings", [])), "D region-a (has children) projector config has tactical-events and no element-band-events entry")
pj = dep("t-tier-projector-region-a")
ok(pj is not None and T not in pj["metadata"]["annotations"].get("openddil.io/consumer-groups", ""), "D region-a consumer-groups has no element-band-events group")
# E
checked = []
for d in docs:
    n = d["metadata"]["name"]
    if d["kind"] == "Deployment":
        for k, v in envof(d).items():
            if re.search(r"TOPICS|UPLINK|BRIDGE|RELAY|MIRROR", k):
                checked.append(f"env {k} of {n}")
                ok(T not in str(v), f"E {k} of {n} lacks {T}")
    if d["kind"] == "ConfigMap" and re.search(r"bridge|connect|relay|uplink|mirror", n):
        for k, v in (d.get("data") or {}).items():
            checked.append(f"configmap {n}/{k}")
            ok(T not in str(v), f"E configmap {n}/{k} lacks {T}")
kinds = sorted({re.sub(r"\S+ of \S+", "", c) if False else c.split(" of ")[0] if c.startswith("env") else "configmap " + re.sub(r"(edge|region)-[a-z0-9-]+", "*", c.split()[1]) for c in checked})
print("E checked %d bridge/uplink lists and configs, kinds: %s" % (len(checked), "; ".join(kinds)))
ok(len(checked) > 0 and any("BRIDGE_TOPICS" in c for c in checked) and any("uplink" in c for c in checked),
   "E the checked set includes BRIDGE_TOPICS envs and tier uplink configs")
# F
ok(any(re.search(r'"' + T + r'\|-p 4', str(d)) for d in docs if d["kind"] in ("Job", "ConfigMap")), "F topic-init script names " + T)
sys.exit(fail)
PYEOF
rc=$?
[ $rc -eq 0 ] && echo "PASS test_element_band_events_render" || echo "FAILED test_element_band_events_render"
exit $rc
