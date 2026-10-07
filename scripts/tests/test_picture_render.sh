#!/usr/bin/env bash
# ===========================================================================
# test_picture_render.sh -- offline render proof for the picture route's
# assembler wiring. The picture route decides every answer through the
# egress gate, so the assembler must reach the same PDP the other gate
# consumers do.
#
# Cases:
#   A. picture on  -> assembler env OPENDDIL_TOPAZ_URL equals the egress
#                     gate's (the one PDP every gate consumer uses).
#   B. picture off -> assembler env has no OPENDDIL_TOPAZ_URL (nothing
#                     rendered differs from a chart without the route).
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
  helm template t "$CHART" --set releasability.enabled=true --set egress.assembler.enabled=true "$@" > "$out" 2> "$out.err" \
    || { echo "render failed:"; cat "$out.err"; return 1; }
}

topaz_of() {  # $1 = rendered file, $2 = Deployment name -> env value or <absent>
  "$PY" - "$1" "$2" <<'EOF'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"] == sys.argv[2]:
        for c in d["spec"]["template"]["spec"]["containers"]:
            for e in c.get("env", []):
                if e["name"] == "OPENDDIL_TOPAZ_URL":
                    print(e.get("value")); sys.exit(0)
        print("<absent>"); sys.exit(0)
print("<no deployment>")
EOF
}

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1 ($2)"; else echo "FAIL $1: got '$2', want '$3'"; FAIL=1; fi
}

render "$TMP/on.yaml" --set picture.enabled=true \
  --set 'picture.serviceClients[0].clientId=svc-a' \
  --set 'picture.serviceClients[0].destination=system:x' \
  --set 'picture.serviceClients[0].existingSecret.name=s' \
  --set 'picture.serviceClients[0].existingSecret.key=k' || exit 1
want="$(topaz_of "$TMP/on.yaml" t-egress-gate-c2)"
case "$want" in http*) ;; *) echo "FAIL A: the egress gate has no PDP url to compare ($want)"; exit 1 ;; esac
check "A picture on" "$(topaz_of "$TMP/on.yaml" t-egress-assembler)" "$want"

render "$TMP/off.yaml" || exit 1
check "B picture off" "$(topaz_of "$TMP/off.yaml" t-egress-assembler)" "<absent>"

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
