#!/usr/bin/env bash
# ===========================================================================
# test_forwarder_extraenv.sh -- offline render proof for
# egress.forwarder.extraEnv.
#
# Cases:
#   A. extraEnv empty (the default) -> the forwarder container has exactly the
#                     env names the chart has always rendered, in order.
#   B. extraEnv with two entries -> both are present, in order, after the
#                     existing ones, with their values.
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
FAIL=0

render() {  # $1 = out file, rest = extra --set flags
  local out="$1"; shift
  helm template t "$CHART" --set releasability.enabled=true --set egress.forwarder.enabled=true "$@" > "$out" 2> "$out.err" \
    || { echo "render failed:"; cat "$out.err"; return 1; }
}

env_of_raw() {  # $1 = rendered file -> the forwarder container's env as NAME=VALUE lines
  "$PY" - "$1" <<'PYEOF'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == "t-egress-forwarder":
        for c in d["spec"]["template"]["spec"]["containers"]:
            if c["name"] == "forwarder":
                for e in c.get("env", []):
                    print("%s=%s" % (e["name"], e.get("value", "")))
                sys.exit(0)
print("<no forwarder container>")
PYEOF
}
env_of() { env_of_raw "$1" | tr -d ''; }

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ' ')"; echo "  want: $(echo "$3" | tr '\n' ' ')"; FAIL=1; fi
}

BASE='OPENDDIL_EGRESS_BROKERS=
OPENDDIL_FORWARD_CONFIG=
POSTGRES_DSN=
LOG_LEVEL=INFO'

render "$TMP/empty.yaml" || exit 1
names_empty="$(env_of "$TMP/empty.yaml" | sed 's/=.*//')"
check "A extraEnv empty: only the existing env names" "$names_empty" "$(echo "$BASE" | sed 's/=.*//')"

render "$TMP/two.yaml" \
  --set 'egress.forwarder.extraEnv[0].name=OPENDDIL_FORWARD_RETRY_MAX_S' \
  --set-string 'egress.forwarder.extraEnv[0].value=5' \
  --set 'egress.forwarder.extraEnv[1].name=OPENDDIL_FORWARD_SESSION_TIMEOUT_MS' \
  --set-string 'egress.forwarder.extraEnv[1].value=6000' || exit 1
want="$(echo "$names_empty"; printf '%s\n' 'OPENDDIL_FORWARD_RETRY_MAX_S=5' 'OPENDDIL_FORWARD_SESSION_TIMEOUT_MS=6000')"
got="$(env_of "$TMP/two.yaml" | "$PY" -c '
import sys
for l in sys.stdin:
    n, _, v = l.rstrip("\n").partition("=")
    print(n if n in ("OPENDDIL_EGRESS_BROKERS","OPENDDIL_FORWARD_CONFIG","POSTGRES_DSN","LOG_LEVEL") else l.rstrip("\n"))
' | tr -d '\r')"
check "B extraEnv two entries: appended in order after the existing" "$got" "$want"

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
