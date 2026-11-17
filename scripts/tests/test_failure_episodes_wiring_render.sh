#!/usr/bin/env bash
# ===========================================================================
# test_failure_episodes_wiring_render.sh -- the failure-episodes topics and
# the tier projectors' subscriptions, read from a render that never touches
# disk.
#
# cm-service emits closed failure episodes to `failure-episodes` and refusals
# to `failure-episodes-withheld`. Broker auto-create is off, so a topic no
# chart template creates silently loses every record. Tier projectors read the
# chart-generated openddil.tierProjectorConfig, not the image's config, so a
# tier store gets rows only if that config maps the topics.
#
# Cases:
#   1. every topic-init Job script (hub and each tier) holds both topic specs,
#      exactly as expected, once each.
#   2. each of those scripts passes `sh -n`.
#   3. every tier-projector-config-<tier> ConfigMap holds exactly one mapping
#      per topic, with the expected fields and no asset_ttl_hours.
#   4. consumer groups are unique within each tier's config.
#
# The render is piped straight into the reader, which prints names and counts
# only. No rendered manifest, and no extracted script, is written anywhere.
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
import sys, yaml, subprocess, collections
SPEC_TAIL = "|-p 4 -r 1 -c cleanup.policy=delete -c retention.ms=-1 -c compression.type=lz4"
TOPICS = ["failure-episodes", "failure-episodes-withheld"]
specs = ["\"" + t + SPEC_TAIL + "\"" for t in TOPICS]
fail = 0
jobs = 0
tiers = 0
for d in yaml.safe_load_all(sys.stdin):
    if not d:
        continue
    name = d["metadata"]["name"]
    if d.get("kind") == "Job" and "topic-init" in name:
        scripts = []
        for c in d["spec"]["template"]["spec"].get("containers", []):
            for part in (c.get("command") or []) + (c.get("args") or []):
                if "for spec in" in part:
                    scripts.append(part)
        if len(scripts) != 1:
            print(f"FAIL 1: {name}: {len(scripts)} topic-spec scripts (expected 1)")
            fail += 1
            continue
        jobs += 1
        sc = scripts[0]
        counts = [sc.count(s) for s in specs]
        ok = counts == [1, 1]
        print(("PASS" if ok else "FAIL") + f" 1: {name}: spec counts {counts}")
        fail += not ok
        r = subprocess.run(["sh", "-n"], input=sc.encode(), capture_output=True)
        ok = r.returncode == 0
        print(("PASS" if ok else "FAIL") + f" 2: {name}: sh -n" + ("" if ok else ": " + r.stderr.decode()[:200]))
        fail += not ok
    elif d.get("kind") == "ConfigMap" and "-tier-projector-config-" in name:
        tier = name.split("-tier-projector-config-", 1)[1]
        cfg = yaml.safe_load(d["data"]["projector_config.yaml"])
        maps = cfg.get("mappings") or cfg.get("topics") or []
        problems = []
        for t in TOPICS:
            m = [x for x in maps if x.get("topic") == t]
            if len(m) != 1:
                problems.append(f"{t}: {len(m)} mappings")
                continue
            m = m[0]
            want = {"handler": t.replace("-", "_"), "table": t.replace("-", "_"),
                    "consumer_group": "tier-projector-" + t + "-" + tier,
                    "decode_as": "json", "mode": "custom"}
            for k, v in want.items():
                if m.get(k) != v:
                    problems.append(f"{t}: {k}={m.get(k)!r} want {v!r}")
            extra = sorted(set(m) - set(want) - {"topic"})
            if extra:
                problems.append(f"{t}: unexpected keys {extra}")
        tiers += 1
        print(("PASS" if not problems else "FAIL") + f" 3: tier {tier}: " + ("both mappings" if not problems else "; ".join(problems)))
        fail += bool(problems)
        groups = [x.get("consumer_group") for x in maps]
        dup = sorted(g for g, n in collections.Counter(groups).items() if n > 1)
        print(("PASS" if not dup else "FAIL") + f" 4: tier {tier}: {len(groups)} consumer groups, " + ("unique" if not dup else f"duplicated {dup}"))
        fail += bool(dup)
print(f"topic-init Jobs checked: {jobs}")
print(f"tier configs checked: {tiers}")
if jobs == 0:
    print("FAIL 1: no topic-init Job checked"); fail += 1
if tiers == 0:
    print("FAIL 3: no tier projector config checked"); fail += 1
sys.exit(1 if fail else 0)
'

# A leaf tier (edge-01), a tier with children (region-east) and a tier under
# it (sector-7, also with children).
if helm template t "$CHART" \
    --set tierNode.enabled=true \
    --set 'edges[0].id=edge-01' --set 'edges[0].region=region-east' --set 'edges[0].udpPort=62040' \
    --set 'edges[1].id=region-east' --set 'edges[1].region=hq' --set 'edges[1].hasChildren=true' \
    --set 'edges[2].id=sector-7' --set 'edges[2].parent=region-east' --set 'edges[2].hasChildren=true' \
    2>/dev/null | "$PY" -c "$READER"; then
  echo; echo "test_failure_episodes_wiring_render.sh: ALL PASS"; exit 0
else
  echo; echo "test_failure_episodes_wiring_render.sh: SOME FAILED"; exit 1
fi
