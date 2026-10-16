#!/usr/bin/env bash
# ===========================================================================
# test_reset_clear_declarations.sh -- offline proof for RESET_CLEAR_DECLARATIONS
# (exerciseControl.resetJob.clearExerciseDeclarations), against
# reset-scenario.sh's REAL functions (sourced via the RESET_SCENARIO_SOURCE_ONLY
# seam, as test_reset_policytrim.sh does). No cluster: every read is stubbed.
#
# Properties proved, for unset / "0" (keep), "1" (clear), and "x" (halt):
#   1. keep: asset_declaration + asset_correlation + asset-declarations are in
#      KEPT_*; clear: the arrays are empty; "x": check_clear_declarations
#      halts (exit 2) naming the value, before anything else runs.
#   2. phase 6 skips kept tables with one printed line, still deletes
#      asset_fielding; delete_table refuses a kept table (halt, exit 2).
#   3. the capture pass leaves the kept topic out of CAPTURED_TOPICS (so it is
#      neither trimmed nor policy-trimmed); asset-fielding stays in.
#   4. phase 1 records the kept tables' counts and kept topic log-start; the
#      verify steps report them UNCHANGED (PASS), FAIL when they moved, and
#      "UNCHANGED?" when there is no baseline. Clear mode predicts 0 / hw.
#   5. quick mode: quick_stores_sql omits the kept tables, quick_list_targets
#      omits the kept topic; clear mode has both.
#   6. the exercise reset record carries clear_exercise_declarations.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"
FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

# run_case VALUE BODY -- source the script with RESET_CLEAR_DECLARATIONS=VALUE
# in a fresh subshell, stub the reads, then eval BODY.
run_case() {
  local val="$1" body="$2"
  (
    if [ "$val" = "UNSET" ]; then unset RESET_CLEAR_DECLARATIONS; else export RESET_CLEAR_DECLARATIONS="$val"; fi
    NS=openddil; RELEASE=openddil; export NS RELEASE
    RESET_SCENARIO_SOURCE_ONLY=1; export RESET_SCENARIO_SOURCE_ONLY
    set --
    # shellcheck source=../reset-scenario.sh
    . "$SCRIPT" >/dev/null
    set +e
    DRY_RUN=true
    POSTGRES_PODS=(pg-a)
    REDPANDA_PODS=(rp-a)
    RESTATE_PODS=()
    ELECTRIC_PODS=()
    PG_COUNT_ASSET_DECLARATION=7
    pg_table_exists() { return 0; }
    pg_query() { echo "2026-01-01T00:00:00Z"; }
    pg_count() {
      case "$2" in
        asset_declaration) echo "$PG_COUNT_ASSET_DECLARATION" ;;
        asset_correlation) echo 3 ;;
        *) echo 0 ;;
      esac
    }
    restate_count() { echo 0; }
    measure_restate_cadence() { echo 30; }
    baseline_electric() { :; }
    broker_topics() { printf 'asset-declarations\nasset-fielding\n'; }
    DECL_LOGSTART=10
    topic_partitions() {
      case "$2" in
        asset-declarations) echo "0 $DECL_LOGSTART 50" ;;
        *) echo "0 4 4" ;;
      esac
    }
    topic_policy() { echo compact; }
    topic_shape() { echo "p=1 r=1"; }
    topic_dynamic_config() { echo "cleanup.policy=compact"; }
    TOPIC_CAPTURE_DIR="$(mktemp -d)"
    PRODUCER_DEPLOYS=()
    eval "$body"
  )
}

# --- 1. the arrays ----------------------------------------------------------
for v in UNSET "" 0; do
  o="$(run_case "$v" 'echo "T=${KEPT_TABLES[*]} P=${KEPT_TOPICS[*]} C=$CLEAR_DECLARATIONS"; check_clear_declarations; echo "rc=$?"')"
  [ "$o" = "$(printf 'T=asset_declaration asset_correlation P=asset-declarations C=false\nrc=0')" ] \
    && pass "1: value '${v}' keeps (arrays set, no halt)" || fail "1: value '${v}' -> $o"
done
o="$(run_case 1 'echo "T=${KEPT_TABLES[*]:-} P=${KEPT_TOPICS[*]:-} C=$CLEAR_DECLARATIONS"; check_clear_declarations; echo "rc=$?"')"
[ "$o" = "$(printf 'T= P= C=true\nrc=0')" ] && pass "1: value 1 clears (arrays empty)" || fail "1: value 1 -> $o"
o="$(run_case x 'check_clear_declarations; echo "AFTER-HALT-REACHED"' 2>&1)"; rc=$?
case "$o" in *"invalid value 'x'"*) ;; *) rc=99 ;; esac
case "$o" in *AFTER-HALT-REACHED*) rc=98 ;; esac
[ "$rc" -eq 2 ] && pass "1: value x halts (exit 2) naming x, nothing after" || fail "1: value x rc=$rc out=$o"

# --- 2. phase 6 and delete_table ---------------------------------------------
o="$(run_case UNSET 'phase6_stores')"
echo "$o" | grep -q 'asset_declaration .*skipped (kept: clearExerciseDeclarations=false)' \
  && echo "$o" | grep -q 'asset_correlation .*skipped (kept: clearExerciseDeclarations=false)' \
  && ! echo "$o" | grep -q 'DELETE FROM asset_declaration\|DELETE FROM asset_correlation' \
  && echo "$o" | grep -q 'DELETE FROM asset_fielding on pg-a' \
  && pass "2: keep: phase 6 skips both kept tables, still deletes asset_fielding" || fail "2: keep phase6: $o"
o="$(run_case 1 'phase6_stores')"
echo "$o" | grep -q 'DELETE FROM asset_declaration on pg-a' \
  && echo "$o" | grep -q 'DELETE FROM asset_correlation on pg-a' \
  && ! echo "$o" | grep -q 'skipped (kept' \
  && pass "2: clear: phase 6 deletes the declaration tables, no 'kept' line" || fail "2: clear phase6: $o"
o="$(run_case UNSET 'delete_table pg-a asset_declaration; echo AFTER' 2>&1)"; rc=$?
[ "$rc" -eq 2 ] && ! echo "$o" | grep -q AFTER && echo "$o" | grep -q 'KEPT_TABLES' \
  && pass "2: delete_table refuses a kept table (halt, exit 2)" || fail "2: delete_table rc=$rc out=$o"

# --- 3. capture pass ----------------------------------------------------------
o="$(run_case UNSET 'phase4_capture_pass >/dev/null; echo "C=${CAPTURED_TOPICS[*]}"')"
[ "$o" = "C=rp-a|asset-fielding" ] && pass "3: keep: only asset-fielding captured (kept topic not trimmable)" || fail "3: keep capture: $o"
o="$(run_case UNSET 'phase4_capture_pass' | grep -c 'asset-declarations: not captured, not trimmed, not policy-trimmed (kept: clearExerciseDeclarations=false)')"
[ "$o" = "1" ] && pass "3: keep: one printed line for the kept topic" || fail "3: kept line count=$o"
o="$(run_case 1 'phase4_capture_pass >/dev/null; echo "C=${CAPTURED_TOPICS[*]}"')"
[ "$o" = "C=rp-a|asset-declarations rp-a|asset-fielding" ] && pass "3: clear: both topics captured" || fail "3: clear capture: $o"

# --- 4. baseline + verify -----------------------------------------------------
o="$(run_case UNSET 'phase1_baseline >/dev/null; echo "B=${BASE_STORE_COUNT[pg-a|asset_declaration]} L=${BASE_KEPT_LOGSTART[rp-a|asset-declarations|0]}"; verify_stores; verify_topics')"
echo "$o" | grep -q '^B=7 L=10$' && pass "4: baseline recorded the kept count (7) and log-start (10)" || fail "4: baseline: $o"
echo "$o" | grep -q 'stores pg-a/asset_declaration (UNCHANGED, kept.*predicted=7 .*actual=7 .*PASS' \
  && echo "$o" | grep -q 'topics rp-a/asset-declarations/p0 (log_start UNCHANGED, kept.*predicted=10 .*actual=10 .*PASS' \
  && ! echo "$o" | grep -q 'predicted=0 .*asset_declaration\|predicted=50 ' \
  && pass "4: keep: kept table and topic verified UNCHANGED (PASS), not predicted 0 / hw" || fail "4: verify unchanged: $o"
o="$(run_case UNSET 'phase1_baseline >/dev/null; PG_COUNT_ASSET_DECLARATION=0; DECL_LOGSTART=50; verify_stores; verify_topics; echo "FAILFLAG=$OVERALL_FAIL"')"
echo "$o" | grep -q 'asset_declaration (UNCHANGED.*predicted=7 .*actual=0 .*FAIL' \
  && echo "$o" | grep -q 'asset-declarations/p0 (log_start UNCHANGED.*predicted=10 .*actual=50 .*FAIL' \
  && echo "$o" | grep -q 'FAILFLAG=1' \
  && pass "4: keep: a cleared declaration table / trimmed topic FAILS the verify" || fail "4: verify moved: $o"
o="$(run_case UNSET 'verify_stores; verify_topics')"
echo "$o" | grep -q 'asset_declaration (UNCHANGED?, kept.*actual=7' \
  && echo "$o" | grep -q 'asset-declarations/p0 (log_start UNCHANGED?, kept.*actual log_start=10' \
  && pass "4: keep: no baseline -> printed UNCHANGED? with the actual" || fail "4: no baseline: $o"
o="$(run_case 1 'phase1_baseline >/dev/null; PG_COUNT_ASSET_DECLARATION=0; DECL_LOGSTART=50; verify_stores; verify_topics; echo "FAILFLAG=$OVERALL_FAIL"')"
echo "$o" | grep -q 'stores pg-a/asset_declaration  .*predicted=0 .*actual=0 .*PASS' \
  && echo "$o" | grep -q 'topics rp-a/asset-declarations/p0 .*predicted=50 .*actual=50 .*PASS' \
  && ! echo "$o" | grep -q 'UNCHANGED, kept' \
  && pass "4: clear: declarations predicted 0 / log_start==hw as today" || fail "4: clear verify: $o"

# --- 5. quick mode ------------------------------------------------------------
o="$(run_case UNSET 'quick_stores_sql pg-a')"
! echo "$o" | grep -q 'DELETE FROM asset_declaration\|DELETE FROM asset_correlation' \
  && echo "$o" | grep -q 'DELETE FROM asset_fielding' && echo "$o" | grep -q 'asset_declaration: skipped (kept' \
  && pass "5: keep: quick SQL omits the kept tables, keeps asset_fielding" || fail "5: quick sql keep: $o"
o="$(run_case 1 'quick_stores_sql pg-a')"
echo "$o" | grep -q 'DELETE FROM asset_declaration' && echo "$o" | grep -q 'DELETE FROM asset_correlation' \
  && pass "5: clear: quick SQL deletes the declaration tables" || fail "5: quick sql clear: $o"
o="$(run_case UNSET 'quick_list_targets >/dev/null; echo "Q=${QUICK_TARGETS[*]}"')"
[ "$o" = "Q=rp-a|asset-fielding" ] && pass "5: keep: quick targets omit the kept topic" || fail "5: quick targets keep: $o"
o="$(run_case 1 'quick_list_targets >/dev/null; echo "Q=${QUICK_TARGETS[*]}"')"
[ "$o" = "Q=rp-a|asset-declarations rp-a|asset-fielding" ] && pass "5: clear: quick targets include it" || fail "5: quick targets clear: $o"

# --- 6. record and banner -----------------------------------------------------
o="$(run_case UNSET 'kubectl() { case "$*" in *"get deploy"*) return 0 ;; *"create configmap"*) echo "ARGS: $*" ;; *apply*) cat ;; esac; return 0; }; DRY_RUN=false; DECLARED_UNMEASURED_USED=(); write_exercise_reset_record; clear_declarations_banner')"
echo "$o" | grep -q '"clear_exercise_declarations": false' && echo "$o" | grep -q '^clear_exercise_declarations: false$' \
  && pass "6: record and banner state clear_exercise_declarations: false" || fail "6: record keep: $o"
o="$(run_case 1 'kubectl() { case "$*" in *"get deploy"*) return 0 ;; *"create configmap"*) echo "ARGS: $*" ;; *apply*) cat ;; esac; return 0; }; DRY_RUN=false; DECLARED_UNMEASURED_USED=(); write_exercise_reset_record; clear_declarations_banner')"
echo "$o" | grep -q '"clear_exercise_declarations": true' && echo "$o" | grep -q '^clear_exercise_declarations: true$' \
  && pass "6: record and banner state clear_exercise_declarations: true" || fail "6: record clear: $o"

if [ "$FAIL" -eq 0 ]; then echo "test_reset_clear_declarations: ALL PASS"; else echo "test_reset_clear_declarations: FAILED"; exit 1; fi
