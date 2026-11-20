#!/usr/bin/env bash
# ===========================================================================
# test_bundle_sources_lock.sh -- the lock-reading step of build-bundle.yml,
# which is scripts/bundle-sources.sh. Runs it against the real lock (ok) and
# against a missing repo, a duplicate repo, a short sha, an uppercase sha and
# an extra line (each refused). Fixtures are small files in a temp dir.
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$HERE/../.."
S="$ROOT/scripts/bundle-sources.sh"
TMPD="$(mktemp -d)"
trap 'rm -rf "$TMPD"' EXIT

rc=0
fail() { echo "FAIL $*"; rc=1; }
pass() { echo "PASS $*"; }

A=1111111111111111111111111111111111111111
B=2222222222222222222222222222222222222222
C=3333333333333333333333333333333333333333
D=4444444444444444444444444444444444444444
good() { printf '%s\n' "# c" "contracts $A" "stack $B" "tactical-agents $C" "demo $D"; }

OUT="$(bash "$S" "$ROOT/bundle-sources.lock" 2>&1)"
[ $? = 0 ] && [ "$(printf '%s\n' "$OUT" | grep -Ec '^(contracts|stack|tactical-agents|demo)=[0-9a-f]{40}$')" = 4 ] \
  && pass "real lock reads ok" || fail "real lock: $OUT"

good > "$TMPD/good"
OUT="$(bash "$S" "$TMPD/good" 2>&1)"
[ $? = 0 ] && printf '%s' "$OUT" | grep -q "stack=$B" && pass "fixture lock reads ok" || fail "fixture lock: $OUT"

refused() { # <name> <file>
  if bash "$S" "$2" >/dev/null 2>&1; then fail "$1: accepted"; else pass "$1: refused"; fi
}
good | grep -v '^stack' > "$TMPD/missing"
refused "missing repo" "$TMPD/missing"
{ good; echo "demo $D"; } > "$TMPD/dup"
refused "duplicate repo" "$TMPD/dup"
printf '%s\n' "contracts $A" "stack ${B:0:39}" "tactical-agents $C" "demo $D" > "$TMPD/short"
refused "short sha" "$TMPD/short"
printf '%s\n' "contracts $A" "stack ABABABABABABABABABABABABABABABABABABABAB" "tactical-agents $C" "demo $D" > "$TMPD/upper"
refused "uppercase sha" "$TMPD/upper"
{ good; echo "extra $A"; } > "$TMPD/extra"
refused "extra line" "$TMPD/extra"
refused "missing file" "$TMPD/none"

exit $rc
