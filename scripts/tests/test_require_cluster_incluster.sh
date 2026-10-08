#!/usr/bin/env bash
# ===========================================================================
# test_require_cluster_incluster.sh -- offline proof for the in-cluster branch
# of lib/require-cluster.sh.
#
# `kubectl` is a stub on PATH that reports an empty current-context, as it
# does inside a pod. OPENDDIL_SA_DIR points at a temp directory standing in
# for the service account mount.
#
# Cases:
#   a  SA namespace matches in-cluster:<ns>   -> rc 0, "(asserted)" line
#   b  SA namespace differs from expectation  -> 78, "wrong cluster"
#   c  no expectation declared                -> 78
#   d  no SA namespace file                   -> 78, empty-context refusal
#   e  SA file but KUBERNETES_SERVICE_HOST empty -> 78, empty-context refusal
#   f  a non-empty kubeconfig context still wins and is compared as before
# ===========================================================================
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
# A copy of the library in a scratch tree, so a local .expected-context file
# in the real checkout cannot supply an expectation.
mkdir -p "$TMP/repo/scripts/lib"
cp "$HERE/../lib/require-cluster.sh" "$TMP/repo/scripts/lib/"
LIB="$TMP/repo/scripts/lib/require-cluster.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

mkdir -p "$TMP/bin" "$TMP/sa" "$TMP/empty"
cat > "$TMP/bin/kubectl" <<'KEOF'
#!/usr/bin/env bash
[ "$1 $2" = "config current-context" ] && printf '%s' "${STUB_CONTEXT:-}"
exit 0
KEOF
chmod +x "$TMP/bin/kubectl"
printf 'ns1\n' > "$TMP/sa/namespace"

# run_case NAME SA_DIR HOSTVAL EXPECT [CONTEXT]
run_case() {
  env -u OPENDDIL_EXPECT_CONTEXT PATH="$TMP/bin:$PATH" OPENDDIL_SA_DIR="$2" \
    KUBERNETES_SERVICE_HOST="$3" STUB_CONTEXT="${5:-}" \
    ${4:+OPENDDIL_EXPECT_CONTEXT="$4"} \
    bash "$LIB" > "$TMP/$1.out" 2>&1
  RC=$?
}

run_case a "$TMP/sa" api-host in-cluster:ns1
if [ "$RC" = 0 ] && grep -qx "cluster: in-cluster:ns1 (asserted)" "$TMP/a.out"; then pass "a match"; else fail "a (rc=$RC)"; cat "$TMP/a.out"; fi

run_case b "$TMP/sa" api-host in-cluster:ns2
if [ "$RC" = 78 ] && grep -q "wrong cluster" "$TMP/b.out"; then pass "b other namespace refused"; else fail "b (rc=$RC)"; cat "$TMP/b.out"; fi

run_case c "$TMP/sa" api-host ""
if [ "$RC" = 78 ] && grep -q "no expected kube-context" "$TMP/c.out"; then pass "c no expectation refused"; else fail "c (rc=$RC)"; cat "$TMP/c.out"; fi

run_case d "$TMP/empty" api-host in-cluster:ns1
if [ "$RC" = 78 ] && grep -q "no current-context" "$TMP/d.out"; then pass "d no SA file refused"; else fail "d (rc=$RC)"; cat "$TMP/d.out"; fi

run_case e "$TMP/sa" "" in-cluster:ns1
if [ "$RC" = 78 ] && grep -q "no current-context" "$TMP/e.out"; then pass "e no service host refused"; else fail "e (rc=$RC)"; cat "$TMP/e.out"; fi

run_case f1 "$TMP/sa" api-host lab-ctx lab-ctx
if [ "$RC" = 0 ] && grep -qx "cluster: lab-ctx (asserted)" "$TMP/f1.out"; then pass "f context match"; else fail "f1 (rc=$RC)"; cat "$TMP/f1.out"; fi
run_case f2 "$TMP/sa" api-host in-cluster:ns1 lab-ctx
if [ "$RC" = 78 ] && grep -q "wrong cluster" "$TMP/f2.out" && grep -q "current context  : lab-ctx" "$TMP/f2.out"; then
  pass "f context wins over the service account"; else fail "f2 (rc=$RC)"; cat "$TMP/f2.out"; fi

exit "$FAIL"
