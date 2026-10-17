#!/usr/bin/env bash
# ===========================================================================
# test_require_cluster_allowlist.sh -- offline proof for the allowed/barred
# .expected-context format in lib/require-cluster.sh and its two Python
# duplicates (check_consumer_census.py, check_tier_feed.py).
#
# kubectl is a stub printing $STUB_CONTEXT. The library is copied into a
# scratch tree so the real checkout's .expected-context is never read.
# Context names are synthetic: lab-a, lab-b, barred-x.
#
# Every bash case runs twice: library run directly, and sourced by a caller
# under `set -euo pipefail`. OPENDDIL_TEST_LIB overrides the library copied
# (used to prove the tests can go red against a mutated library).
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SRC_LIB="${OPENDDIL_TEST_LIB:-$HERE/../lib/require-cluster.sh}"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/repo/scripts/lib" "$TMP/bin"
cp "$SRC_LIB" "$TMP/repo/scripts/lib/require-cluster.sh"
cp "$HERE/../check_consumer_census.py" "$HERE/../check_tier_feed.py" "$TMP/repo/scripts/"
LIB="$TMP/repo/scripts/lib/require-cluster.sh"
EC="$TMP/repo/.expected-context"
FAIL=0
pass() { echo "PASS [$MODE]: $1"; }
fail() { echo "FAIL [$MODE]: $1"; FAIL=1; }

cat > "$TMP/bin/kubectl" <<'KEOF'
#!/usr/bin/env bash
if [ "$1 $2" = "config current-context" ]; then
  [ -n "${STUB_CONTEXT:-}" ] || { echo "error: current-context is not set" >&2; exit 1; }
  printf '%s\n' "$STUB_CONTEXT"
fi
exit 0
KEOF
chmod +x "$TMP/bin/kubectl"
cat > "$TMP/errexit-caller.sh" <<CEOF
set -euo pipefail
. "$LIB"
CEOF

# run_case NAME ENV ACTUAL   (file content already written to $EC, or removed)
run_case() {
  local target="$LIB"
  [ "$MODE" = errexit ] && target="$TMP/errexit-caller.sh"
  env -u OPENDDIL_EXPECT_CONTEXT PATH="$TMP/bin:$PATH" STUB_CONTEXT="$3" \
    KUBERNETES_SERVICE_HOST= ${2:+OPENDDIL_EXPECT_CONTEXT="$2"} \
    bash "$target" > "$TMP/$1.out" 2>&1
  RC=$?
}
setfile() { printf '%b' "$1" > "$EC"; }
expect_rc() {  # NAME RC PATTERN
  if [ "$RC" = "$2" ] && grep -q -- "$3" "$TMP/$1.out"; then pass "$1"
  else fail "$1 (rc=$RC, want $2 /$3/)"; cat "$TMP/$1.out"; fi
}

cases() {
  setfile 'lab-a\n';                          run_case a "" lab-a
  expect_rc a 0 '^cluster: lab-a (asserted)$'
  setfile 'lab-a\n';                          run_case b "" lab-b
  expect_rc b 78 'wrong cluster'
  setfile 'lab-a\nlab-b\n';                   run_case c "" lab-a
  expect_rc c 78 'allows 2 clusters (lab-a, lab-b)'
  grep -q 'Nothing has been read and nothing has been written' "$TMP/c.out" \
    && pass "c says nothing read or written" || fail "c silent-ness"
  setfile 'lab-a\nlab-b\n';                   run_case d lab-b lab-b
  expect_rc d 0 '^cluster: lab-b (asserted)$'
  setfile 'lab-a\nlab-b\n';                   run_case e lab-b lab-a
  expect_rc e 78 'wrong cluster'
  setfile 'lab-a\n!barred-x\n';               run_case f barred-x lab-a
  expect_rc f 78 "'barred-x' is barred"
  setfile 'lab-a\n!barred-x\n';               run_case g barred-x barred-x
  expect_rc g 78 'barred'
  # g2: the only path where the barred-actual check, not the env check, is
  # what stops a match: the same name is both allowed and barred in the file.
  setfile 'barred-x\n!barred-x\n';            run_case g2 "" barred-x
  expect_rc g2 78 "current context 'barred-x' is barred"
  setfile '# top\n\n  lab-a  # trailing\n\t\n'; run_case h "" lab-a
  expect_rc h 0 '^cluster: lab-a (asserted)$'
  setfile '!barred-x\n';                      run_case i "" lab-a
  expect_rc i 78 'no expected kube-context'
  rm -f "$EC";                                run_case j lab-a lab-a
  expect_rc j 0 '^cluster: lab-a (asserted)$'
  # actual barred without env naming it
  setfile 'lab-a\n!barred-x\n';               run_case k "" barred-x
  expect_rc k 78 "current context 'barred-x' is barred"
}

for MODE in direct errexit; do
  echo "== $MODE"
  cases
done

# ---- Python parity: c, d, f, h -------------------------------------------
PY=""
for c in python python3 py; do command -v "$c" >/dev/null 2>&1 && { PY="$c"; break; }; done
MODE=python
if [ -z "$PY" ]; then
  fail "no python interpreter found"
else
  PYDIR="$TMP/repo/scripts"
  command -v cygpath >/dev/null 2>&1 && PYDIR="$(cygpath -m "$PYDIR")"
  # py_case NAME MODULE ENV ACTUAL -> RC, output in $TMP/NAME.out
  py_case() {
    env -u OPENDDIL_EXPECT_CONTEXT ${3:+OPENDDIL_EXPECT_CONTEXT="$3"} \
      PYDIR="$PYDIR" MOD="$2" CTX="$4" MSYS_NO_PATHCONV=1 \
      "$PY" -I -c '
import os, sys, importlib
sys.path.insert(0, os.environ["PYDIR"])
m = importlib.import_module(os.environ["MOD"])
m.require_cluster(os.environ["CTX"])
print("OK")' > "$TMP/$1.out" 2>&1
    RC=$?
  }
  for mod in check_consumer_census check_tier_feed; do
    setfile 'lab-a\nlab-b\n';       py_case "pc-$mod" $mod "" lab-a
    expect_rc "pc-$mod" 78 'allows 2 clusters (lab-a, lab-b)'
    setfile 'lab-a\nlab-b\n';       py_case "pd-$mod" $mod lab-b lab-b
    expect_rc "pd-$mod" 0 '^OK$'
    setfile 'lab-a\n!barred-x\n';   py_case "pf-$mod" $mod barred-x lab-a
    expect_rc "pf-$mod" 78 "'barred-x' is barred"
    setfile 'lab-a\n!barred-x\n';   py_case "pg-$mod" $mod barred-x barred-x
    expect_rc "pg-$mod" 78 'barred'
    setfile '# top\n\n  lab-a  # trailing\n'; py_case "ph-$mod" $mod "" lab-a
    expect_rc "ph-$mod" 0 '^OK$'
  done
fi

exit "$FAIL"
