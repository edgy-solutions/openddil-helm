#!/usr/bin/env bash
# ===========================================================================
# test-completeness-sparse-producer.sh — offline proof that the completeness
# gate's sparse branch reads its producer PER ENTRY, against the REAL gate
# script (scripts/check-releasability-completeness.sh), not a reimplementation
# of it.
# ===========================================================================
# No offline harness existed for this gate before this file (scripts/ and
# scripts/tests/ were searched; the two existing tests there cover
# reset-scenario.sh, not this gate). The gate talks to a cluster through
# kubectl alone (require-cluster.sh's own guard, then `psql` via `kubectl
# exec`), so this test puts a FAKE kubectl first on PATH and drives the real
# script through it end to end -- never a copy of its parsing logic.
#
# THE FAKE CLUSTER. The fake kubectl answers `config current-context` with a
# fixed synthetic name, matched by OPENDDIL_EXPECT_CONTEXT so require-
# cluster.sh's guard passes without editing it (the guard itself is never
# touched). It answers every `psql` read (`kubectl exec ... -- psql ...`)
# with a three-table schema: effector_launch and tactical_events, both
# labelled (originator_nation + releasable_to) and both at 0 rows -- exactly
# the shape this test is about, a labelled table that is correctly empty --
# plus one fully-labelled, 1-row table (synthetic_asset_table) so the gate
# has something populated to check. Without it every table in the schema is
# empty and the gate correctly refuses to call that a pass (see the real
# script's own "nothing to check" guard) regardless of how the two sparse
# tables are explained, which would make case (a) untestable here. Every
# other kubectl call (the tier-kind probe, the all-tiers discovery) is
# harmlessly accepted and ignored; this test only drives the single-store
# form (--root-only), the same way the all-tiers dispatcher invokes it per
# store.
#
# THE TWO SPARSE TABLES ARE KEPT DELIBERATELY INDEPENDENT. tactical_events
# (producer derive-stage) and effector_launch (producer effector-launch) are
# driven by two SEPARATE result files, and cases (f) and (g) each hold one
# producer's file fresh-and-good while the other is absent -- proving the
# two tables' verdicts cannot leak into each other.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELM_ROOT="$(cd "$HERE/../.." && pwd)"
GATE="$HELM_ROOT/scripts/check-releasability-completeness.sh"

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# ---------------------------------------------------------------------------
# The fake cluster: a kubectl that answers `config current-context` and
# every `psql` read with a synthetic two-table schema. Written once, reused
# by every case below.
# ---------------------------------------------------------------------------
STUBDIR="$(mktemp -d)"
cat > "$STUBDIR/kubectl" <<'STUB'
#!/usr/bin/env bash
# Fake kubectl for test-completeness-sparse-producer.sh. Synthetic schema
# only: effector_launch and tactical_events (both labelled, both at 0 rows)
# plus synthetic_asset_table (labelled, 1 row, fully labelled) -- nothing
# here is a real cluster name, pod or database.
case "${1:-}" in
  config)
    echo "${FAKE_CLUSTER_CONTEXT:-synthetic-offline-ctx}"
    exit 0
    ;;
  exec)
    shift
    sql=""
    prev=""
    for a in "$@"; do
      [ "$prev" = "-c" ] && sql="$a"
      prev="$a"
    done
    case "$sql" in
      *"column_name = 'originator_nation'"*)
        printf 'effector_launch\nsynthetic_asset_table\ntactical_events\n' ;;
      *"table_type='BASE TABLE'"*)
        printf 'effector_launch\nsynthetic_asset_table\ntactical_events\n' ;;
      *"column_name IN ('originator_nation','releasable_to')"*)
        printf 'effector_launch\nsynthetic_asset_table\ntactical_events\n' ;;
      *"FILTER (WHERE originator_nation IS NULL)"*)
        printf 'effector_launch|0|0|0\nsynthetic_asset_table|1|0|0\ntactical_events|0|0|0\n' ;;
      *)
        : ;;
    esac
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$STUBDIR/kubectl"
export PATH="$STUBDIR:$PATH"

FAKE_CLUSTER_CONTEXT="synthetic-offline-ctx"
export FAKE_CLUSTER_CONTEXT
# Stubbed through the env the guard already honours (require-cluster.sh
# precedence #1) -- the guard file itself is never edited or bypassed.
export OPENDDIL_EXPECT_CONTEXT="$FAKE_CLUSTER_CONTEXT"
export OPENDDIL_NAMESPACE="openddil"

RESULTS_DIR="$(mktemp -d)"
export OPENDDIL_DERIVE_RESULT="$RESULTS_DIR/derive.result"
export OPENDDIL_EFFECTOR_CONSUMER_RESULT="$RESULTS_DIR/effector.result"
# A deliberately-missing declared-unlabelled file: no asset excuse must
# participate in a result that is only about the two sparse tables.
export OPENDDIL_DECLARED_UNLABELLED="$RESULTS_DIR/no-such-declared-unlabelled.yaml"

cleanup() { rm -rf "$STUBDIR" "$RESULTS_DIR"; }
trap cleanup EXIT

write_derive() {
  local verdict="$1" ns="${2:-openddil}" epoch="${3:-$(date -u +%s)}"
  {
    printf 'epoch=%s\n' "$epoch"
    printf 'verdict=%s\n' "$verdict"
    printf 'window_s=90\n'
    printf 'advancing=2\nfrozen=0\n'
    printf 'namespace=%s\n' "$ns"
  } > "$OPENDDIL_DERIVE_RESULT"
}
rm_derive() { rm -f "$OPENDDIL_DERIVE_RESULT"; }

write_effector() {
  local verdict="$1" ns="${2:-openddil}" epoch="${3:-$(date -u +%s)}" group="${4:-projector-effector-launch}"
  {
    printf 'epoch=%s\n' "$epoch"
    printf 'verdict=%s\n' "$verdict"
    printf 'window_s=60\n'
    printf 'group=%s\n' "$group"
    printf 'members=1\n'
    printf 'lag=0\n'
    printf 'hwm=0\n'
    printf 'namespace=%s\n' "$ns"
  } > "$OPENDDIL_EFFECTOR_CONSUMER_RESULT"
}
rm_effector() { rm -f "$OPENDDIL_EFFECTOR_CONSUMER_RESULT"; }

now="$(date -u +%s)"
old_epoch=$(( now - 9999 ))   # well past the default 1800s max age

run_gate() { bash "$GATE" -n openddil --root-only 2>&1; }

expect_line() {
  # expect_line LABEL OUTPUT PATTERN...  -- every PATTERN must appear
  # (grep -F, fixed string) in the line(s) mentioning "effector_launch" (or
  # whichever table name is PATTERN 1's prefix search target); here we just
  # grep the whole output since the row text is a few lines (two for the
  # UNMEASURED case).
  local label="$1" out="$2"; shift 2
  local ok=1 p
  for p in "$@"; do
    printf '%s\n' "$out" | grep -qF -- "$p" || ok=0
  done
  [ "$ok" -eq 1 ] && pass "$label" || fail "$label (missing one of: $*)"
}

# ---------------------------------------------------------------------------
# (a) effector ALIVE, right namespace+group, fresh; derive COMPLETING, right
# namespace, fresh -> effector_launch SPARSE, gate exits 0.
# ---------------------------------------------------------------------------
write_derive COMPLETING openddil "$now"
write_effector ALIVE openddil "$now" projector-effector-launch
out_a="$(run_gate)"; rc_a=$?
expect_line "(a) effector_launch line: SPARSE, producer alive" "$out_a" \
  "effector_launch" "SPARSE, producer effector-launch alive"
[ "$rc_a" -eq 0 ] && pass "(a) gate exit 0" || fail "(a) expected gate exit 0, got $rc_a"

# ---------------------------------------------------------------------------
# (b) effector NOT_ALIVE, fresh, right ns/group; derive still good ->
# effector_launch PRODUCER STOPPED, gate fails.
# ---------------------------------------------------------------------------
write_effector NOT_ALIVE openddil "$now" projector-effector-launch
out_b="$(run_gate)"; rc_b=$?
expect_line "(b) effector_launch line: PRODUCER STOPPED" "$out_b" \
  "effector_launch" "PRODUCER STOPPED (effector-launch)"
[ "$rc_b" -eq 1 ] && pass "(b) gate exit 1" || fail "(b) expected gate exit 1, got $rc_b"

# ---------------------------------------------------------------------------
# (c) effector result absent; derive still good -> effector_launch
# UNMEASURED, gate fails.
# ---------------------------------------------------------------------------
rm_effector
out_c="$(run_gate)"; rc_c=$?
expect_line "(c) effector_launch line: PRODUCER UNMEASURED (absent)" "$out_c" \
  "effector_launch" "PRODUCER UNMEASURED (effector-launch)"
[ "$rc_c" -eq 1 ] && pass "(c) gate exit 1" || fail "(c) expected gate exit 1, got $rc_c"

# ---------------------------------------------------------------------------
# (d) effector ALIVE but older than max age; derive still good ->
# effector_launch UNMEASURED, gate fails.
# ---------------------------------------------------------------------------
write_effector ALIVE openddil "$old_epoch" projector-effector-launch
out_d="$(run_gate)"; rc_d=$?
expect_line "(d) effector_launch line: PRODUCER UNMEASURED (stale)" "$out_d" \
  "effector_launch" "PRODUCER UNMEASURED (effector-launch)" "older than"
[ "$rc_d" -eq 1 ] && pass "(d) gate exit 1" || fail "(d) expected gate exit 1, got $rc_d"

# ---------------------------------------------------------------------------
# (e) effector ALIVE, fresh, but a DIFFERENT namespace; derive still good ->
# effector_launch UNMEASURED, gate fails.
# ---------------------------------------------------------------------------
write_effector ALIVE other-namespace "$now" projector-effector-launch
out_e="$(run_gate)"; rc_e=$?
expect_line "(e) effector_launch line: PRODUCER UNMEASURED (namespace)" "$out_e" \
  "effector_launch" "PRODUCER UNMEASURED (effector-launch)" "namespace other-namespace"
[ "$rc_e" -eq 1 ] && pass "(e) gate exit 1" || fail "(e) expected gate exit 1, got $rc_e"

# ---------------------------------------------------------------------------
# (f) derive COMPLETING, fresh, right ns; no effector file at all ->
# effector_launch UNMEASURED, tactical_events SPARSE -- the two producers
# must stay separate (tactical_events must NOT also go unmeasured just
# because effector's file is missing).
# ---------------------------------------------------------------------------
rm_effector
write_derive COMPLETING openddil "$now"
out_f="$(run_gate)"; rc_f=$?
expect_line "(f) effector_launch UNMEASURED" "$out_f" \
  "effector_launch" "PRODUCER UNMEASURED (effector-launch)"
expect_line "(f) tactical_events SPARSE (producers are separate)" "$out_f" \
  "tactical_events" "SPARSE, producer derive-stage alive"
[ "$rc_f" -eq 1 ] && pass "(f) gate exit 1" || fail "(f) expected gate exit 1, got $rc_f"

# ---------------------------------------------------------------------------
# (g) the mirror of (f): effector ALIVE, fresh, right ns/group; derive file
# absent -> tactical_events UNMEASURED, effector_launch SPARSE.
# ---------------------------------------------------------------------------
rm_derive
write_effector ALIVE openddil "$now" projector-effector-launch
out_g="$(run_gate)"; rc_g=$?
expect_line "(g) tactical_events UNMEASURED" "$out_g" \
  "tactical_events" "PRODUCER UNMEASURED (derive-stage)"
expect_line "(g) effector_launch SPARSE (producers are separate)" "$out_g" \
  "effector_launch" "SPARSE, producer effector-launch alive"
[ "$rc_g" -eq 1 ] && pass "(g) gate exit 1" || fail "(g) expected gate exit 1, got $rc_g"

# ---------------------------------------------------------------------------
# (h) effector ALIVE, fresh, right ns, but a TIER group's result on a root
# run -> effector_launch UNMEASURED: one tier's consumer says nothing about
# the root projector's.
# ---------------------------------------------------------------------------
write_derive COMPLETING openddil "$now"
write_effector ALIVE openddil "$now" tier-projector-effector-launch-edge-a
out_h="$(run_gate)"; rc_h=$?
expect_line "(h) effector_launch UNMEASURED (group)" "$out_h"   "effector_launch" "PRODUCER UNMEASURED (effector-launch)" "expected projector-effector-launch"
[ "$rc_h" -eq 1 ] && pass "(h) gate exit 1" || fail "(h) expected gate exit 1, got $rc_h"

# ---------------------------------------------------------------------------
# (i) effector ALIVE, fresh, but the file names no group -> UNMEASURED.
# ---------------------------------------------------------------------------
write_effector ALIVE openddil "$now" projector-effector-launch
sed -i '/^group=/d' "$OPENDDIL_EFFECTOR_CONSUMER_RESULT"
out_i="$(run_gate)"; rc_i=$?
expect_line "(i) effector_launch UNMEASURED (no group line)" "$out_i"   "effector_launch" "PRODUCER UNMEASURED (effector-launch)"
[ "$rc_i" -eq 1 ] && pass "(i) gate exit 1" || fail "(i) expected gate exit 1, got $rc_i"

echo
if [ "$FAIL" -eq 0 ]; then
  echo "test-completeness-sparse-producer.sh: ALL PASS"
else
  echo "test-completeness-sparse-producer.sh: AT LEAST ONE FAILURE" >&2
fi
exit "$FAIL"
