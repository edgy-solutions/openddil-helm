#!/usr/bin/env bash
# =============================================================================
# check-entity-assignment.sh — does the render actually carry the DIS entity
# allow-list that sensorIngest.entityAssignment declares?
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# templates/edge.yaml validates sensorIngest.entityAssignment (values.yaml)
# at render time and groups it per edge, but a render-time `fail` only ever
# catches a MALFORMED map — not a correctly-shaped map that quietly renders
# the wrong thing (an id dropped from every sidecar, or one id copied into
# two). This independently re-derives the map from the merged values files
# and asserts the render agrees with it.
#
# USAGE
#   scripts/check-entity-assignment.sh <chart-dir> [helm template args...]
#   e.g. scripts/check-entity-assignment.sh ./openddil-demo -n openddil \
#          -f base.yaml -f site.yaml
#
# The map itself is read from the merged -f/--values files, IN THE ORDER
# GIVEN — the last file that sets sensorIngest.entityAssignment wins, same as
# Helm's own "a later -f file's list fully replaces an earlier one" for this
# key (it is one list, not a per-element deep merge). A file that never
# mentions the key does not touch whatever an earlier file set. If no -f
# file sets it, the chart's own values.yaml default applies.
#
# WHAT THIS CHECKS (all three must hold):
#   1. the union of every rendered DIS_ADMITTED_ENTITY_IDS == the map's ids
#   2. no id is rendered into more than one sidecar
#   3. every sensor-ingest Deployment carries the env iff the map is
#      non-empty (empty map -> no sidecar carries it; non-empty -> all do)
#
# TESTABILITY
# -----------
# Set CHECK_ENTITY_ASSIGNMENT_RENDER_FILE to a path holding a pre-rendered
# manifest to check that file instead of invoking `helm template` — the
# expected map is still read from the -f files given on the command line.
# This is the seam the tampered-render tests use to prove disagreement is
# actually caught, without needing a template defect to produce one.
#
# EXIT
#   0  the render agrees with the map
#   1  it does not; each disagreement is listed
#   3  NOT RUN: the render failed, or produced no sensor-ingest Deployments.
#      Zero Deployments is not "nothing to disagree with"; it is a render
#      that measured nothing.
# =============================================================================
set -uo pipefail

if [ $# -lt 1 ] || [ ! -d "$1" ]; then
  echo "usage: $0 <chart-dir> [helm template args...]" >&2
  exit 3
fi
chart="$1"; shift

PY=$(command -v python3 || command -v python || echo py)

# -- which -f/--values files were given, in order (last wins) --------------
valuefiles=()
i=0
while [ $i -lt $# ]; do
  idx=$((i + 1))
  arg="${!idx}"
  case "$arg" in
    -f|--values)
      nidx=$((idx + 1))
      valuefiles+=("${!nidx}")
      i=$((i + 2))
      ;;
    --values=*)
      valuefiles+=("${arg#--values=}")
      i=$((i + 1))
      ;;
    *)
      i=$((i + 1))
      ;;
  esac
done

render="$(mktemp)"; errs="$(mktemp)"
trap 'rm -f "$render" "$errs"' EXIT

if [ -n "${CHECK_ENTITY_ASSIGNMENT_RENDER_FILE:-}" ]; then
  cp "$CHECK_ENTITY_ASSIGNMENT_RENDER_FILE" "$render"
elif ! helm template entity-assignment-check "$chart" "$@" >"$render" 2>"$errs"; then
  echo "NOT RUN: helm template failed:" >&2
  tail -5 "$errs" >&2
  exit 3
fi

"$PY" - "$render" "$chart/values.yaml" "${valuefiles[@]}" <<'PYEOF'
import collections
import re
import sys

import yaml

render_path = sys.argv[1]
chart_values_path = sys.argv[2]
value_file_paths = sys.argv[3:]

ENTITY_RE = re.compile(r"^dis:[0-9]+:[0-9]+:[0-9]+$")


def read_entity_assignment(path):
    """(present, value). `present` is False when the file does not set
    sensorIngest.entityAssignment at all -- that must not be confused with
    an explicit empty list, which IS a value and must win over an earlier
    file's non-empty one."""
    try:
        with open(path, "r", encoding="utf-8") as f:
            doc = yaml.safe_load(f) or {}
    except FileNotFoundError:
        print(f"NOT RUN: values file not found: {path}", file=sys.stderr)
        sys.exit(3)
    sensor = doc.get("sensorIngest")
    if not isinstance(sensor, dict) or "entityAssignment" not in sensor:
        return False, None
    return True, (sensor["entityAssignment"] or [])


present, entity_map = read_entity_assignment(chart_values_path)
if not present:
    entity_map = []
for path in value_file_paths:
    p, v = read_entity_assignment(path)
    if p:
        entity_map = v

for entry in entity_map:
    if not isinstance(entry, dict) or "id" not in entry or "edge" not in entry:
        print(f"NOT RUN: malformed sensorIngest.entityAssignment entry: {entry!r}",
              file=sys.stderr)
        sys.exit(3)

expected_ids = {entry["id"] for entry in entity_map}

with open(render_path, "r", encoding="utf-8") as f:
    docs = [d for d in yaml.safe_load_all(f) if d]

sensor_deploys = []
for d in docs:
    if d.get("kind") != "Deployment":
        continue
    name = (d.get("metadata") or {}).get("name", "")
    if "-sensor-ingest-" not in name:
        continue
    containers = (((d.get("spec") or {}).get("template") or {})
                  .get("spec", {}).get("containers", []))
    for c in containers:
        if c.get("name") == "sensor-ingest":
            sensor_deploys.append((name, c))
            break

if not sensor_deploys:
    print("NOT RUN: the render produced no sensor-ingest Deployments.", file=sys.stderr)
    sys.exit(3)

rendered = {}  # name -> (has_env, set(ids))
for name, c in sensor_deploys:
    env = {e.get("name"): e.get("value") for e in (c.get("env") or [])}
    raw = env.get("DIS_ADMITTED_ENTITY_IDS")
    ids = set(raw.split(",")) if raw else set()
    rendered[name] = (raw is not None, ids)

fail = False

rendered_union = set()
for _name, (_has_env, ids) in rendered.items():
    rendered_union |= ids

missing = expected_ids - rendered_union
extra = rendered_union - expected_ids
if missing:
    print(f"FAIL: id(s) in sensorIngest.entityAssignment but rendered into no sidecar: "
          f"{sorted(missing)}")
    fail = True
if extra:
    print(f"FAIL: id(s) rendered into a sidecar but not in sensorIngest.entityAssignment: "
          f"{sorted(extra)}")
    fail = True

seen_in = collections.defaultdict(list)
for name, (_has_env, ids) in rendered.items():
    for entity_id in ids:
        seen_in[entity_id].append(name)
dupes = {eid: names for eid, names in seen_in.items() if len(names) > 1}
for eid, names in sorted(dupes.items()):
    print(f"FAIL: id {eid!r} is rendered into more than one sidecar: {sorted(names)}")
    fail = True

map_nonempty = len(entity_map) > 0
for name, (has_env, _ids) in sorted(rendered.items()):
    if map_nonempty and not has_env:
        print(f"FAIL: {name} carries no DIS_ADMITTED_ENTITY_IDS although "
              f"sensorIngest.entityAssignment is non-empty")
        fail = True
    if not map_nonempty and has_env:
        print(f"FAIL: {name} carries DIS_ADMITTED_ENTITY_IDS although "
              f"sensorIngest.entityAssignment is empty")
        fail = True

if fail:
    sys.exit(1)

print(f"OK: {len(sensor_deploys)} sensor-ingest Deployment(s), "
      f"{len(rendered_union)} id(s), agree with sensorIngest.entityAssignment.")
PYEOF
