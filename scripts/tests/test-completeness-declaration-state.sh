#!/usr/bin/env bash
# Offline proof that the completeness gate reads asset_declaration before it
# trusts a declared-unlabelled entry, driving the REAL gate through a fake
# kubectl (same approach as test-completeness-sparse-producer.sh). An entry
# means "unlabelled unless a declaration exists in that store". Ids synthetic.
#   (a) no declaration row, asset unlabelled        -> rc 0, excused
#   (b) declaration row, asset labelled             -> rc 0, HAS A DECLARATION line
#   (c) declaration row, asset still unlabelled     -> rc 1, counted, not excused
#   (d) no declaration row, asset labelled          -> rc 1, NOT unlabelled
#   (e) asset_declaration query returns an error    -> rc 3
#   (f) table absent                                -> as (a)/(d) with "absent" line
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$(cd "$HERE/.." && pwd)/check-releasability-completeness.sh"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"
export FK="$WORK/state"; mkdir -p "$FK"
cat > "$WORK/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
# Fake kubectl. State files under $FK: decl_mode (ok|error|absent), decl_rows
# (ids with a declaration), unlabelled (1 = the asset has a NULL-label row).
case "${1:-}" in
  config) echo "synthetic-offline-ctx"; exit 0 ;;
  exec)
    shift; sql=""; prev=""
    for a in "$@"; do [ "$prev" = "-c" ] && sql="$a"; prev="$a"; done
    unl="$(cat "$FK/unlabelled")"
    case "$sql" in
      *"to_regclass('public.asset_declaration')"*)
        case "$(cat "$FK/decl_mode")" in
          error) echo "ERROR: connection to server failed" ;;
          absent) echo f ;;
          *) echo t ;;
        esac ;;
      *"FROM asset_declaration"*) cat "$FK/decl_rows" ;;
      *"column_name='asset_id'"*) echo 1 ;;
      *"column_name='"*) echo 0 ;;
      *"GROUP BY"*)
        if [ "$unl" = 1 ]; then echo "synth:fixture:1|1|1"; else echo "synth:fixture:1|0|0"; fi ;;
      *"column_name = 'originator_nation'"*|*"table_type='BASE TABLE'"*|*"column_name IN ('originator_nation','releasable_to')"*)
        echo synthetic_asset_table ;;
      *"FILTER (WHERE originator_nation IS NULL)"*)
        echo "synthetic_asset_table|2|$unl|$unl" ;;
      *"originator_nation IS NULL"*)
        if [ "$unl" = 1 ]; then echo "synth:fixture:1"; fi ;;
      *) : ;;
    esac
    exit 0 ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$WORK/bin/kubectl"
export PATH="$WORK/bin:$PATH"
export OPENDDIL_EXPECT_CONTEXT="synthetic-offline-ctx"
export OPENDDIL_NAMESPACE="openddil"
unset OPENDDIL_DECLARED_UNLABELLED_EXTRA
{ echo "context: synthetic-offline-ctx"; echo; echo "declared_unlabelled:"; echo
  printf '  "synth:fixture:1":\n    stores: [root]\n    reason: >-\n      Synthetic fixture.\n\n'; } > "$WORK/main.yaml"
export OPENDDIL_DECLARED_UNLABELLED="$WORK/main.yaml"

setup() { # mode decl_row(0/1) unlabelled(0/1)
  echo "$1" > "$FK/decl_mode"
  if [ "$2" = 1 ]; then echo synth:fixture:1 > "$FK/decl_rows"; else : > "$FK/decl_rows"; fi
  echo "$3" > "$FK/unlabelled"
}
run() { out="$(bash "$GATE" -n openddil --root-only 2>&1)"; rc=$?; }
has() { grep -qF -- "$1" <<<"$out"; }

setup ok 0 1; run
if [ $rc -eq 0 ] && has "DECLARED: synth:fixture:1" && ! has "HAS A DECLARATION"; then pass "(a) no row, unlabelled: excused, rc 0"; else fail "(a) rc=$rc"; echo "$out" | tail -8; fi

setup ok 1 0; run
if [ $rc -eq 0 ] && has "declared-unlabelled: synth:fixture:1 HAS A DECLARATION in this store"; then pass "(b) row, labelled: rc 0, HAS A DECLARATION"; else fail "(b) rc=$rc"; echo "$out" | tail -8; fi

setup ok 1 1; run
if [ $rc -eq 1 ] && has "HAS A DECLARATION" && ! has "DECLARED: synth:fixture:1" && has "unlabelled value(s)"; then pass "(c) row, still unlabelled: rc 1, not excused"; else fail "(c) rc=$rc"; echo "$out" | tail -8; fi

setup ok 0 0; run
if [ $rc -eq 1 ] && has "NOT unlabelled"; then pass "(d) no row, labelled: rc 1, NOT unlabelled"; else fail "(d) rc=$rc"; echo "$out" | tail -8; fi

setup error 0 1; run
if [ $rc -eq 3 ] && has "GATE NOT RUN"; then pass "(e) query error: rc 3"; else fail "(e) rc=$rc"; echo "$out" | tail -8; fi

setup absent 0 1; run
if [ $rc -eq 0 ] && has "asset_declaration: absent in this store — no declarations"; then pass "(f1) absent + unlabelled: rc 0, absent line"; else fail "(f1) rc=$rc"; echo "$out" | tail -8; fi
setup absent 0 0; run
if [ $rc -eq 1 ] && has "absent in this store" && has "NOT unlabelled"; then pass "(f2) absent + labelled: rc 1, absent line"; else fail "(f2) rc=$rc"; echo "$out" | tail -8; fi

echo
[ "$FAIL" -eq 0 ] && echo "test-completeness-declaration-state.sh: ALL PASS" || echo "test-completeness-declaration-state.sh: AT LEAST ONE FAILURE" >&2
exit "$FAIL"
