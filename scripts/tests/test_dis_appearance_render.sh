#!/usr/bin/env bash
# ===========================================================================
# test_dis_appearance_render.sh -- per-edge sensorIngest.disAppearance.
#
# Renders are piped straight from `helm template` into a python reader (no
# render is saved). The only files written are small values files in a temp
# dir, removed on exit; they hold no Secret.
#   unset: no dis-appearance ConfigMap; no edge's sensor-ingest has the mount.
#   set on edge-01 only: a ConfigMap named
#          <release>-sensor-ingest-edge-01-dis-appearance-<10 hex>, key
#          dis_appearance.yaml; edge-01's sensor-ingest container mounts it
#          read-only at /ontology/dis_appearance.yaml with subPath
#          dis_appearance.yaml; edge-02 and edge-03 render without it.
#   A changed value gives a different ConfigMap name.
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

# Prints "cm=<name>|<keys>|<first line> mounts=<edge:subPath:readOnly,...>"
READ='
import sys, yaml
cms, mounts = [], []
for d in yaml.safe_load_all(sys.stdin):
    if not d:
        continue
    n = d["metadata"]["name"]
    if d["kind"] == "ConfigMap" and "-dis-appearance-" in n:
        cms.append(n + "|" + ",".join(sorted(d["data"])) + "|" + d["data"].get("dis_appearance.yaml", "").split("\n")[0])
    if d["kind"] == "Deployment" and n.startswith("t-sensor-ingest-"):
        for c in d["spec"]["template"]["spec"]["containers"]:
            if c["name"] != "sensor-ingest":
                continue
            for m in c.get("volumeMounts", []):
                if m["mountPath"] == "/ontology/dis_appearance.yaml":
                    mounts.append("%s:%s:%s" % (n[len("t-sensor-ingest-"):], m.get("subPath"), m.get("readOnly")))
print("cm=%s mounts=%s" % (";".join(cms) or "-", ",".join(mounts) or "-"))
'

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
mk() { # <file> <first line of the table>
  printf '%s\n' "edges:" \
    "  - {id: edge-01, region: region-east, udpPort: 62040, sensorIngest: {disAppearance: \"$2\\nmore: 1\\n\"}}" \
    "  - {id: edge-02, region: region-east, udpPort: 62041}" \
    "  - {id: edge-03, region: region-west, udpPort: 62042}" > "$1"
}
mk "$TMPD/v1.yaml" "one: 1"
mk "$TMPD/v2.yaml" "two: 2"

rc=0
fail() { echo "FAIL $*"; rc=1; }
pass() { echo "PASS $*"; }

render() { # <values file, or empty for the defaults>
  if [ -n "$1" ]; then helm template t "$CHART" -f "$1" 2>/dev/null | "$PY" -c "$READ"
  else helm template t "$CHART" 2>/dev/null | "$PY" -c "$READ"; fi
}

U="$(render "")"
[ "$U" = "cm=- mounts=-" ] && pass "unset: no ConfigMap and no mount" || fail "unset: got '$U'"

A="$(render "$TMPD/v1.yaml")"
B="$(render "$TMPD/v2.yaml")"
NAME_A="$(printf '%s' "$A" | sed -n 's/^cm=\([^|]*\)|.*/\1/p')"
NAME_B="$(printf '%s' "$B" | sed -n 's/^cm=\([^|]*\)|.*/\1/p')"

printf '%s' "$NAME_A" | grep -Eq '^t-sensor-ingest-edge-01-dis-appearance-[0-9a-f]{10}$' && pass "set: name carries a 10-hex hash ($NAME_A)" || fail "set: name '$NAME_A'"
printf '%s' "$A" | grep -q '|dis_appearance.yaml|one: 1 ' && pass "set: key dis_appearance.yaml holds the value" || fail "set: key/value in '$A'"
[ "${A##* mounts=}" = "edge-01:dis_appearance.yaml:True" ] && pass "set: edge-01 only, subPath, read-only" || fail "set: mounts in '$A'"
[ -n "$NAME_B" ] && [ "$NAME_A" != "$NAME_B" ] && pass "changed value gives a new name ($NAME_B)" || fail "changed value: '$NAME_A' vs '$NAME_B'"

exit $rc
