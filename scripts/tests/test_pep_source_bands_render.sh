#!/usr/bin/env bash
# ===========================================================================
# test_pep_source_bands_render.sh -- releasability.pep.sourceBands.
#
# Renders are piped straight from `helm template` into a python reader (no
# render is saved). The only files written are small values files in a temp
# dir, removed on exit; they hold no Secret.
#   unset: no source-bands ConfigMap, no mount, no volume, no env.
#   set:   a ConfigMap named <release>-pep-source-bands-<10 hex> with key
#          source-bands.json; container pep mounts it read-only at
#          /etc/openddil/bands and carries OPENDDIL_SOURCE_BANDS_PATH.
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

# Prints one line: "cm=<name>|<keys>|<value> mount=<n> volume=<n> env=<value or ->"
READ='
import sys, yaml
cms, mount, vol, env = [], 0, 0, "-"
for d in yaml.safe_load_all(sys.stdin):
    if not d:
        continue
    n = d["metadata"]["name"]
    if d["kind"] == "ConfigMap" and "-pep-source-bands" in n:
        cms.append(n + "|" + ",".join(sorted(d["data"])) + "|" + d["data"].get("source-bands.json", ""))
    if d["kind"] == "Deployment" and n == "t-pep":
        spec = d["spec"]["template"]["spec"]
        for c in spec["containers"]:
            if c["name"] != "pep":
                continue
            for m in c.get("volumeMounts", []):
                if m["mountPath"] == "/etc/openddil/bands" and m.get("readOnly") is True:
                    mount += 1
            for e in c.get("env", []):
                if e["name"] == "OPENDDIL_SOURCE_BANDS_PATH":
                    env = e["value"]
        vol = sum(1 for v in spec.get("volumes", []) if "source-bands" in v.get("configMap", {}).get("name", ""))
print("cm=%s mount=%d volume=%d env=%s" % (";".join(cms) or "-", mount, vol, env))
'

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
printf '%s\n' "releasability:" "  pep:" "    sourceBands: '{\"a\":\"one\"}'" > "$TMPD/v1.yaml"
printf '%s\n' "releasability:" "  pep:" "    sourceBands: '{\"a\":\"two\"}'" > "$TMPD/v2.yaml"

rc=0
fail() { echo "FAIL $*"; rc=1; }
pass() { echo "PASS $*"; }

render() { # <values file, or empty for the defaults>
  if [ -n "$1" ]; then helm template t "$CHART" --set releasability.enabled=true -f "$1" 2>/dev/null | "$PY" -c "$READ"
  else helm template t "$CHART" --set releasability.enabled=true 2>/dev/null | "$PY" -c "$READ"; fi
}

U="$(render "")"
[ "$U" = "cm=- mount=0 volume=0 env=-" ] && pass "unset: no ConfigMap, mount, volume or env" || fail "unset: got '$U'"

A="$(render "$TMPD/v1.yaml")"
B="$(render "$TMPD/v2.yaml")"
NAME_A="$(printf '%s' "$A" | sed -n 's/^cm=\([^|]*\)|.*/\1/p')"
NAME_B="$(printf '%s' "$B" | sed -n 's/^cm=\([^|]*\)|.*/\1/p')"

printf '%s' "$NAME_A" | grep -Eq '^t-pep-source-bands-[0-9a-f]{10}$' && pass "set: name carries a 10-hex hash ($NAME_A)" || fail "set: name '$NAME_A'"
printf '%s' "$A" | grep -q '|source-bands.json|{"a":"one"}' && pass "set: key source-bands.json holds the value" || fail "set: key/value in '$A'"
printf '%s' "$A" | grep -q ' mount=1 volume=1 env=/etc/openddil/bands/source-bands.json$' && pass "set: read-only mount, volume and env" || fail "set: mount/volume/env in '$A'"
[ -n "$NAME_B" ] && [ "$NAME_A" != "$NAME_B" ] && pass "changed value gives a new name ($NAME_B)" || fail "changed value: '$NAME_A' vs '$NAME_B'"

exit $rc
