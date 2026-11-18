#!/usr/bin/env bash
# ===========================================================================
# test_projector_groups_render.sh -- the projectors' declared consumer
# groups, read from a render that never touches disk.
#
# openddil.projectorGroupIds (_helpers.tpl) mirrors the consumer groups in
# the openddil-projector image's baked config. It becomes the
# `openddil.io/consumer-groups` annotation on projector-hq and on every
# non-tier-managed edge projector, and the consumer-declaration census
# reads that annotation. A group the image runs but the list lacks is
# reported as undeclared.
#
# Cases:
#   A. projector-hq declares every group in EXPECTED below, each once,
#      prefixed hq/, and nothing else.
#   B. every per-edge projector that renders declares the same set,
#      prefixed with its edge id.
#   C. only with PROJECTOR_CONFIG=<openddil-projector
#      src/config/projector_config.yaml>: the list equals that file's
#      consumer_group set plus projector-asset-element-telemetry (which the
#      baked file deliberately leaves unmapped; the element rows reach the
#      projector by another config). Without PROJECTOR_CONFIG, C is reported
#      as not run, never as passed.
#
# The render is piped straight into the reader, which prints Deployment
# names and group names only. No rendered manifest is written anywhere.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }

# The projector's consumer groups: openddil-projector's baked config at the
# failure-episodes merge (16 on its master before it, plus the two
# failure-episodes groups), plus projector-asset-element-telemetry.
EXPECTED="projector-asset-correlation projector-asset-declaration projector-asset-element-inventory
projector-asset-element-telemetry projector-asset-fielding projector-capability-state projector-cm-state
projector-effector-launch projector-failure-episodes projector-failure-episodes-withheld
projector-logistics-status projector-munition-track projector-parts-availability
projector-region-fleet-summary projector-region-top-factors projector-region-wear-trends
projector-tactical-events projector-telemetry-latest projector-telemetry-windows"

READER='
import sys, yaml, collections
expected = sorted(sys.argv[1].split())
cfg = sys.argv[2]
fail = 0
seen = 0
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "Deployment":
        continue
    name = d["metadata"]["name"]
    ann = (d["metadata"].get("annotations") or {}).get("openddil.io/consumer-groups")
    # tier projectors read their own tier config, with its own group set
    if ann is None or "projector" not in name or "-tier-projector-" in name:
        continue
    pairs = ann.split()
    prefixes = {p.split("/", 1)[0] for p in pairs}
    groups = [p.split("/", 1)[1] for p in pairs]
    dup = sorted(g for g, n in collections.Counter(groups).items() if n > 1)
    missing = sorted(set(expected) - set(groups))
    extra = sorted(set(groups) - set(expected))
    case = "A" if name.endswith("-projector-hq") else "B"
    want_prefix = {"hq"} if case == "A" else None
    ok = not dup and not missing and not extra and len(prefixes) == 1 and (want_prefix is None or prefixes == want_prefix)
    seen += case == "A"
    print(("PASS" if ok else "FAIL") + f" {case}: {name}: {len(groups)} groups, prefix {sorted(prefixes)}"
          + (f", missing {missing}" if missing else "") + (f", extra {extra}" if extra else "")
          + (f", duplicated {dup}" if dup else ""))
    fail += not ok
if seen != 1:
    print(f"FAIL A: {seen} projector-hq Deployments rendered with the annotation (expected 1)")
    fail += 1
if cfg:
    import re
    baked = set(re.findall(r"^\s*consumer_group:\s*(\S+)", open(cfg, encoding="utf-8").read(), re.M))
    want = baked | {"projector-asset-element-telemetry"}
    ok = want == set(expected)
    print(("PASS" if ok else "FAIL") + f" C: list equals {cfg}: {len(baked)} baked + 1"
          + ("" if ok else f"; only in list {sorted(set(expected) - want)}; only in config {sorted(want - set(expected))}"))
    fail += not ok
else:
    print("NOT RUN C: set PROJECTOR_CONFIG to check the list against the projector image config")
sys.exit(1 if fail else 0)
'

FAIL=0
helper="$(sed -n '/define "openddil.projectorGroupIds"/{n;p;}' "$CHART/templates/_helpers.tpl")"
if [ "$(echo "$helper" | tr ' ' '\n' | sort | tr '\n' ' ')" = "$(echo $EXPECTED | tr ' ' '\n' | sort | tr '\n' ' ')" ]; then
  echo "PASS list: _helpers.tpl names the $(echo $EXPECTED | wc -w) expected groups"
else
  echo "FAIL list: _helpers.tpl differs from EXPECTED"; FAIL=1
fi

# A + B (+ C): default values (no edge is tier-managed, so every per-edge
# projector renders), then tierNode on (only projector-hq carries the list).
for setargs in "" "--set tierNode.enabled=true"; do
  echo "-- render ${setargs:-default values}"
  # shellcheck disable=SC2086
  if ! helm template t "$CHART" $setargs 2>/dev/null | "$PY" -c "$READER" "$EXPECTED" "${PROJECTOR_CONFIG:-}"; then
    FAIL=1
  fi
done

echo
if [ "$FAIL" -eq 0 ]; then echo "test_projector_groups_render.sh: ALL PASS"; else echo "test_projector_groups_render.sh: SOME FAILED"; fi
exit "$FAIL"
