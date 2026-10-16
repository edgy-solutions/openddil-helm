#!/usr/bin/env bash
# Offline proof of OPENDDIL_DECLARED_UNLABELLED_EXTRA on the REAL gate script
# (scripts/check-releasability-completeness.sh), driven through a fake kubectl
# like test-completeness-sparse-producer.sh. Only the declared-unlabelled
# header and the early exit codes are asserted; ids and context are synthetic.
#   (a) extra unset            -> single header, as before
#   (b) extra merged           -> both files named, both ids in scope
#   (c) extra path missing     -> exit 3
#   (d) extra wrong context    -> extra ignored, NONE line names it
#   (e) id declared in both    -> exit 3 before any SQL
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$(cd "$HERE/.." && pwd)/check-releasability-completeness.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
cat > "$WORK/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
case "${1:-}" in
  config) echo "synthetic-offline-ctx"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/kubectl"
export PATH="$WORK/bin:$PATH"
export OPENDDIL_EXPECT_CONTEXT="synthetic-offline-ctx"
export OPENDDIL_NAMESPACE="openddil"

mkfile() { # path context ids...
  local f="$1" ctx="$2"; shift 2
  { echo "context: $ctx"; echo; echo "declared_unlabelled:"; echo
    for id in "$@"; do
      printf '  "%s":\n    stores: [root]\n    reason: >-\n      Synthetic fixture %s.\n\n' "$id" "$id"
    done; } > "$f"
}
mkfile "$WORK/main.yaml"  synthetic-offline-ctx  synth:main:1
mkfile "$WORK/extra.yaml" synthetic-offline-ctx  synth:extra:1
mkfile "$WORK/other.yaml" some-other-ctx         synth:extra:1
mkfile "$WORK/dup.yaml"   some-other-ctx         synth:main:1
export OPENDDIL_DECLARED_UNLABELLED="$WORK/main.yaml"

run() { bash "$GATE" -n openddil --root-only 2>&1; }
has() { grep -qF -- "$2" <<<"$1"; }

unset OPENDDIL_DECLARED_UNLABELLED_EXTRA
out="$(run)"; rc=$?
if has "$out" "declared-unlabelled: synth:main:1" && ! has "$out" "extra.yaml"; then
  pass "(a) extra unset: single header"; else fail "(a) $out"; fi

export OPENDDIL_DECLARED_UNLABELLED_EXTRA="$WORK/extra.yaml"
out="$(run)"
if has "$out" "declared-unlabelled: synth:main:1" && has "$out" "declared-unlabelled: synth:extra:1" \
   && has "$out" "(from $WORK/extra.yaml"; then
  pass "(b) extra merged: one header line per file"; else fail "(b) $out"; fi

export OPENDDIL_DECLARED_UNLABELLED_EXTRA="$WORK/missing.yaml"
out="$(run)"; rc=$?
if [ "$rc" -eq 3 ] && has "$out" "$WORK/missing.yaml"; then
  pass "(c) extra missing: exit 3, path named"; else fail "(c) rc=$rc $out"; fi

export OPENDDIL_DECLARED_UNLABELLED_EXTRA="$WORK/other.yaml"
out="$(run)"
if has "$out" "$WORK/other.yaml is for context" && has "$out" "declared-unlabelled: synth:main:1"; then
  pass "(d) extra wrong context: ignored, NONE line names it"; else fail "(d) $out"; fi

mkfile "$WORK/dup.yaml" synthetic-offline-ctx synth:main:1
export OPENDDIL_DECLARED_UNLABELLED_EXTRA="$WORK/dup.yaml"
out="$(run)"; rc=$?
if [ "$rc" -eq 3 ] && has "$out" "synth:main:1"; then
  pass "(e) duplicate id: exit 3, id named"; else fail "(e) rc=$rc $out"; fi

echo
[ "$FAIL" -eq 0 ] && echo "test-completeness-declared-extra.sh: ALL PASS" || echo "test-completeness-declared-extra.sh: AT LEAST ONE FAILURE" >&2
exit "$FAIL"
