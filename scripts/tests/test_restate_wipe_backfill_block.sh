#!/usr/bin/env bash
# ===========================================================================
# test_restate_wipe_backfill_block.sh -- the Restate wipe hook refuses while
# a failure-episodes backfill pod does not read ok (ruling 2026-11-14).
#
# The wipe Job's `sh -c` script is pulled out of the render by a python
# reader and piped straight into `sh -s`. Neither the render nor the script
# is written to disk. The only file written is a stub `kubectl` in a temp
# dir at the front of PATH, removed on exit:
#   * `get pods -l openddil.io/failure-episodes-backfill=run ...` prints the
#     env var FIXTURE (or exits 1 when STUBFAIL=1);
#   * `get sts ...` exits 1, so every member reads "not present";
#   * anything else exits 0.
# Cases:
#   1. FIXTURE empty            -> exit 0, "Restate wipe complete"
#   2. "a:ok b:ok "             -> exit 0
#   3. "a:ok b:failed "         -> exit 1, REFUSED, b named, a not named
#   4. "a: " (still running)    -> exit 1
#   5. the pods get fails       -> exit 1
#   In every refused case no line "scaling to 0" appears.
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

EXTRACT='
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Job" and "-restate-wipe-" in d["metadata"]["name"]:
        sys.stdout.write(d["spec"]["template"]["spec"]["containers"][0]["command"][2])
        sys.exit(0)
sys.stderr.write("no restate-wipe Job in render\n")
sys.exit(3)
'

TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT
cat > "$TMPD/kubectl" <<'STUB'
#!/bin/sh
case "$*" in
  *"get pods -l openddil.io/failure-episodes-backfill=run"*)
    [ "${STUBFAIL:-}" = 1 ] && exit 1
    printf '%s' "${FIXTURE-}"
    exit 0 ;;
  *"get sts "*) exit 1 ;;
esac
exit 0
STUB
chmod +x "$TMPD/kubectl"

rc=0
fail() { echo "FAIL $*"; rc=1; }
pass() { echo "PASS $*"; }

# run_case <fixture> <stubfail> -> sets OUT and CODE
run_case() {
  OUT="$(helm template t "$CHART" --set restate.ephemeralOnUpgrade=true --set tierNode.enabled=true 2>/dev/null \
    | "$PY" -c "$EXTRACT" \
    | env PATH="$TMPD:$PATH" FIXTURE="$1" STUBFAIL="$2" sh -s 2>&1)"
  CODE=$?
}
# helm | python | sh: the pipeline status is sh's, which is what is wanted;
# a render or extract failure shows as missing output and fails the case.

no_scaling() { printf '%s\n' "$OUT" | grep -q 'scaling to 0' && fail "$1: 'scaling to 0' appeared in a refused case" || pass "$1: no 'scaling to 0'"; }

run_case "" 0
{ [ "$CODE" = 0 ] && printf '%s\n' "$OUT" | grep -q 'Restate wipe complete'; } && pass "1: empty fixture passes and completes" || fail "1: empty fixture (exit $CODE)"

run_case "a:ok b:ok " 0
[ "$CODE" = 0 ] && printf '%s\n' "$OUT" | grep -q 'Restate wipe complete' && pass "2: all ok passes" || fail "2: all ok (exit $CODE)"

run_case "a:ok b:failed " 0
if [ "$CODE" = 1 ] && printf '%s\n' "$OUT" | grep -q '^REFUSED:.*: b$'; then pass "3: failed pod refused, b named, a not named"; else fail "3: failed pod (exit $CODE)"; fi
no_scaling 3

run_case "a: " 0
[ "$CODE" = 1 ] && printf '%s\n' "$OUT" | grep -q '^REFUSED:.*: a$' && pass "4: running pod (empty message) refused" || fail "4: running pod (exit $CODE)"
no_scaling 4

run_case "" 1
[ "$CODE" = 1 ] && pass "5: kubectl get failure exits 1 (fail closed)" || fail "5: kubectl failure (exit $CODE)"
no_scaling 5

if [ "$rc" = 0 ]; then echo; echo "test_restate_wipe_backfill_block.sh: ALL PASS"; exit 0
else echo; echo "test_restate_wipe_backfill_block.sh: SOME FAILED"; exit 1; fi
