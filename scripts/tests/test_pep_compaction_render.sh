#!/usr/bin/env bash
# ===========================================================================
# test_pep_compaction_render.sh -- offline render proof for
# releasability.pep.electricCompaction.
#
# Render values: --set releasability.enabled=true --set tierNode.enabled=true
# (the chart's default regions and edges then yield the hub PEP plus one PEP
# per tier).
#
# Cases:
#   A. default         -> every PEP container carries
#                         OPENDDIL_ELECTRIC_COMPACTION=true, exactly once.
#   B. false           -> every PEP container carries it as false; the PEP
#                         count is the same as in A.
#   C. not a boolean   -> the render fails and names the value.
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
  helm template t "$CHART" --set releasability.enabled=true --set tierNode.enabled=true "$@" > "$out" 2> "$out.err"
}

# One line per PEP container: "<deployment> <count of the env> <its value>".
pep_env() {
  "$PY" - "$1" <<'PYEOF' | tr -d '\r'
import sys, yaml
for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")):
    if not d or d.get("kind") != "Deployment":
        continue
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] != "pep":
            continue
        vals = [e.get("value", "") for e in c.get("env", []) if e["name"] == "OPENDDIL_ELECTRIC_COMPACTION"]
        print(d["metadata"]["name"], len(vals), ",".join(vals) or "-")
PYEOF
}

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ' ')"; echo "  want: $(echo "$3" | tr '\n' ' ')"; FAIL=1; fi
}

render "$TMP/default.yaml" || { echo "render failed:"; cat "$TMP/default.yaml.err"; exit 1; }
got_a="$(pep_env "$TMP/default.yaml")"
n_a="$(printf '%s\n' "$got_a" | grep -c .)"
[ "$n_a" -ge 2 ] || { echo "FAIL A: expected the hub PEP and tier PEPs, found $n_a"; FAIL=1; }
printf '%s\n' "$got_a" | grep -q '^t-pep ' || { echo "FAIL A: the hub PEP t-pep did not render"; FAIL=1; }
check "A default: every PEP ($n_a) has it once, true" "$(printf '%s\n' "$got_a" | awk '{print $2, $3}' | sort -u)" "1 true"

render "$TMP/off.yaml" --set releasability.pep.electricCompaction=false || { echo "render failed:"; cat "$TMP/off.yaml.err"; exit 1; }
got_b="$(pep_env "$TMP/off.yaml")"
check "B false: every PEP has it once, false" "$(printf '%s\n' "$got_b" | awk '{print $2, $3}' | sort -u)" "1 false"
check "B false: the same PEPs as the default" "$(printf '%s\n' "$got_b" | awk '{print $1}')" "$(printf '%s\n' "$got_a" | awk '{print $1}')"

if render "$TMP/bad.yaml" --set-string releasability.pep.electricCompaction=off; then
  echo "FAIL C: a non-boolean value rendered"; FAIL=1
elif grep -q 'releasability.pep.electricCompaction must be true or false, got "off"' "$TMP/bad.yaml.err"; then
  echo "PASS C not a boolean: the render fails and names the value"
else
  echo "FAIL C: the render failed for another reason:"; tail -3 "$TMP/bad.yaml.err"; FAIL=1
fi

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
