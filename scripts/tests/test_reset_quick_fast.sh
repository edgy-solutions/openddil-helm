#!/usr/bin/env bash
# ===========================================================================
# test_reset_quick_fast.sh -- offline proof for the fast `--quick` steps of
# reset-scenario.sh: the quiesce set, the shared Restate waits, the one-exec
# per-broker topic trim (the generated pod script, run against a fake rpk, and
# the local parse of its output) and the one-psql per-pod stores clear.
#
# kubectl is a shell function here, so nothing touches a cluster. The real
# functions under test are sourced from the script (see test_reset_ownership.sh
# for the RESET_SCENARIO_SOURCE_ONLY seam).
#
# Cases:
#   1. sequence: discovery is the top-level load; then Q2 Q3 Q4 Q5 Q6 Q7 Q9 in
#      order, and none of the proof work is ever called
#   2. exec counts: one `rpk topic list` per broker, one trim exec per broker,
#      one psql exec per postgres pod
#   3. the pod script against a fake rpk (widen/trim/restore, delete-only,
#      alter failure still restores, trim failure still restores)
#   4. local parse: POLICY mismatch halts and the scale trap restores; a PART
#      with logstart != hw is residue in the banner with exit 0; an alter FAIL
#      halts
#   5. the stores SQL names exactly TABLES, no TRUNCATE, no audit_log, keeps the
#      heartbeat tables, refuses EXCLUDED_TABLES
#   6. --dry-run prints the scripts and the SQL and execs nothing
#   7. banners at start and end, end banner with the time and the residue
#   8. refusals and restart-exercise.sh behave as before
#   9. Q2 set construction and Q3 shared sleeps
#
# RED CHECK: SCRIPT=<path> runs this against a mutated copy.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="${SCRIPT:-$HERE/../reset-scenario.sh}"
WRAPPER="${WRAPPER:-$HERE/../restart-exercise.sh}"

NS="openddil"
RELEASE="openddil"
export NS RELEASE
RESET_SCENARIO_SOURCE_ONLY=1
export RESET_SCENARIO_SOURCE_ONLY
set --
# shellcheck source=../reset-scenario.sh
. "$SCRIPT"
set +e

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
CALLS="$T/calls.log"
KLOG="$T/kubectl.log"
TOPIC_CAPTURE_DIR="$T/capture"

# ---------------------------------------------------------------------------
# fake rpk, state in $T/rpk/: policy.<topic>, parts.<topic> ("p logstart hw")
# ---------------------------------------------------------------------------
mkdir -p "$T/bin" "$T/rpk"
cat > "$T/bin/rpk" <<'RPKEOF'
#!/usr/bin/env bash
D="$FAKE_RPK_DIR"
echo "$*" >> "$D/rpk.log"
[ "$1" = topic ] || exit 2
sub="$2"; shift 2
case "$sub" in
  describe)
    t="$1"; flag="$2"
    if [ "$flag" = "-c" ]; then
      echo "KEY VALUE SOURCE"
      [ -f "$D/policy.$t" ] && echo "cleanup.policy $(cat "$D/policy.$t") DYNAMIC_TOPIC_CONFIG"
      exit 0
    fi
    echo "PARTITION LEADER EPOCH REPLICAS LOG-START-OFFSET HIGH-WATERMARK"
    while read -r p ls hw; do echo "$p 1 1 [1] $ls $hw"; done < "$D/parts.$t"
    ;;
  alter-config)
    t="$1"; v="${3#cleanup.policy=}"
    if [ "$t" = "${FAIL_ALTER_TOPIC:-}" ] && [ "$v" = "compact,delete" ]; then exit 1; fi
    if [ "$t" = "${FAIL_RESTORE_TOPIC:-}" ] && [ "$v" != "compact,delete" ]; then exit 1; fi
    echo "$v" > "$D/policy.$t"
    ;;
  trim-prefix)
    t="$1"
    [ "$t" = "${FAIL_TRIM_TOPIC:-}" ] && exit 1
    [ "$(cat "$D/policy.$t")" = "compact" ] && exit 1   # POLICY_VIOLATION
    awk '{print $1, $3, $3}' "$D/parts.$t" > "$D/parts.$t.new" && mv "$D/parts.$t.new" "$D/parts.$t"
    ;;
esac
RPKEOF
chmod +x "$T/bin/rpk"
export FAKE_RPK_DIR="$T/rpk"

seed_topic() {  # seed_topic TOPIC POLICY "p ls hw" ...
  local t="$1" pol="$2"; shift 2
  echo "$pol" > "$T/rpk/policy.$t"
  : > "$T/rpk/parts.$t"
  local row
  for row in "$@"; do echo "$row" >> "$T/rpk/parts.$t"; done
}

# ---------------------------------------------------------------------------
# kubectl stub (a function: the script's `kubectl` calls resolve to it).
#   exec ... -c redpanda -- rpk topic list      -> $T/topiclist.<pod>
#   exec ... -c redpanda -- sh -c SCRIPT        -> fixture ($T/fixture.out) if
#                                                  EXEC_MODE=fixture, else the
#                                                  script run against fake rpk
#   exec -i ... -c postgres -- sh -c ...        -> saves stdin, prints a count
#   anything else                               -> logged only
# ---------------------------------------------------------------------------
EXEC_MODE=script
kubectl() {
  echo "$*" >> "$KLOG"
  if [ "$1" = exec ]; then
    local pod="" container="" arg prev=""
    for arg in "$@"; do
      [ "$prev" = "-c" ] && [ -z "$container" ] && container="$arg"
      case "$arg" in "${RELEASE}-"*) [ -z "$pod" ] && pod="$arg" ;; esac
      prev="$arg"
    done
    if [ "$container" = redpanda ]; then
      if [[ "$*" == *"rpk topic list"* ]]; then
        { echo "NAME PARTITIONS REPLICAS"; cat "$T/topiclist.$pod" 2>/dev/null; } ; return 0
      fi
      if [ "$EXEC_MODE" = fixture ]; then cat "$T/fixture.out"; return 0; fi
      local script="${@: -1}"
      PATH="$T/bin:$PATH" sh -c "$script"
      return $?
    fi
    if [ "$container" = postgres ]; then
      cat > "$T/sql.$pod"
      echo "NOTICE:  RESET_TOTAL 42 15"
      return 0
    fi
    return 0
  fi
  if [ "$1" = get ] && [[ "$*" == *"status.replicas"* ]]; then echo 0; return 0; fi
  return 0
}
n_exec() {  # n_exec PATTERN -> number of logged exec lines matching
  grep -c "^exec .*$1" "$KLOG" 2>/dev/null || true
}

# Proof-work functions must never run in quick mode: each logs its name.
phase1_baseline()               { echo "phase1_baseline" >> "$CALLS"; }
phase4_capture_pass()           { echo "phase4_capture_pass" >> "$CALLS"; }
assert_consumers_declared()     { echo "assert_consumers_declared" >> "$CALLS"; return 0; }
writer_census()                 { echo "writer_census" >> "$CALLS"; }
phase3b_writer_census()         { echo "phase3b_writer_census" >> "$CALLS"; }
phase4_topics()                 { echo "phase4_topics" >> "$CALLS"; }
assert_destination_stable()     { echo "assert_destination_stable" >> "$CALLS"; }
assert_broker_fully_trimmed()   { echo "assert_broker_fully_trimmed" >> "$CALLS"; }
phase8_zero()                   { echo "phase8_zero" >> "$CALLS"; }
phase10_subscription_liveness() { echo "phase10_subscription_liveness" >> "$CALLS"; }
write_exercise_reset_record()   { echo "write_exercise_reset_record" >> "$CALLS"; }
# the graph read is not under test here (it reads deployments); the order step
# keeps the array as given
bridge_graph()                  { :; }
topo_sort_redpanda_pods()       { :; }

PROOF_WORK="phase1_baseline phase4_capture_pass assert_consumers_declared writer_census phase3b_writer_census phase4_topics assert_destination_stable assert_broker_fully_trimmed phase8_zero phase10_subscription_liveness write_exercise_reset_record"

REDPANDA_PODS=("${RELEASE}-redpanda-hq-0" "${RELEASE}-redpanda-edge-01-0")
POSTGRES_PODS=("${RELEASE}-postgres-hq-0" "${RELEASE}-tier-pg-edge-01-0")
RESTATE_PODS=(r1 r2 r3 r4)
PRODUCER_DEPLOYS=(prod1)
printf 'state-a\nstate-b\n_schemas\nopenddil-edge-01-__assignor-__leader\nfeed-1\n' > "$T/topiclist.${REDPANDA_PODS[0]}"
printf 'state-a\nfeed-2\n' > "$T/topiclist.${REDPANDA_PODS[1]}"

# --- 2a. Q2 listing: one `rpk topic list` exec per broker, same filter --------
: > "$KLOG"
quick_list_targets
[ "$(n_exec 'rpk topic list')" -eq "${#REDPANDA_PODS[@]}" ] \
  && pass "2: Q2 listing is one 'rpk topic list' exec per broker (${#REDPANDA_PODS[@]})" \
  || fail "2: listing execs = $(n_exec 'rpk topic list'), expected ${#REDPANDA_PODS[@]}"
[ "${#QUICK_TARGETS[@]}" -eq 5 ] && ! printf '%s\n' "${QUICK_TARGETS[@]}" | grep -q '_schemas\|__assignor' \
  && pass "2: internal and Faust control topics filtered out (5 targets)" \
  || fail "2: targets: ${QUICK_TARGETS[*]}"

# --- 3. the pod script against a fake rpk -------------------------------------
run_pod_script() {  # run_pod_script TOPIC... -> output in $T/pod.out, rpk log reset
  : > "$T/rpk/rpk.log"
  quick_trim_script "$@" > "$T/pod.sh"
  PATH="$T/bin:$PATH" sh "$T/pod.sh" > "$T/pod.out" 2>"$T/pod.err"
}
seed_topic tc compact "0 5 9" "1 0 4"
seed_topic td compact,delete "0 2 8"
run_pod_script tc td
grep -qx 'POLICY tc compact compact' "$T/pod.out" && pass "3: pure-compact topic ends restored to compact" || fail "3: tc policy line: $(grep POLICY "$T/pod.out")"
grep -q 'alter-config tc --set cleanup.policy=compact,delete' "$T/rpk/rpk.log" \
  && grep -q 'trim-prefix tc -o end' "$T/rpk/rpk.log" \
  && grep -q 'alter-config tc --set cleanup.policy=compact --no-confirm' "$T/rpk/rpk.log" \
  && pass "3: compact topic was widened, trimmed, restored (in that order)" || fail "3: tc rpk calls: $(grep ' tc ' "$T/rpk/rpk.log" | tr '\n' '|')"
[ "$(grep -n 'alter-config tc' "$T/rpk/rpk.log" | head -1 | cut -d: -f1)" -lt "$(grep -n 'trim-prefix tc' "$T/rpk/rpk.log" | cut -d: -f1)" ] \
  && [ "$(grep -n 'trim-prefix tc' "$T/rpk/rpk.log" | cut -d: -f1)" -lt "$(grep -n 'alter-config tc' "$T/rpk/rpk.log" | tail -1 | cut -d: -f1)" ] \
  && pass "3: widen precedes trim precedes restore" || fail "3: order wrong"
grep -qx 'PART tc 0 9 9' "$T/pod.out" && grep -qx 'PART tc 1 4 4' "$T/pod.out" \
  && pass "3: PART lines are read after the trim (logstart == hw)" || fail "3: PART lines: $(grep '^PART tc' "$T/pod.out" | tr '\n' '|')"
grep -qx 'POLICY td compact,delete compact,delete' "$T/pod.out" && ! grep -q 'alter-config td' "$T/rpk/rpk.log" \
  && grep -q 'trim-prefix td' "$T/rpk/rpk.log" && pass "3: delete-policy topic is only trimmed, never altered" || fail "3: td handling"
tail -1 "$T/pod.out" | grep -qx DONE && pass "3: script ends with DONE" || fail "3: no DONE"

seed_topic ta compact "0 1 3"
FAIL_ALTER_TOPIC=ta run_pod_script ta
grep -qx 'FAIL ta alter 1' "$T/pod.out" \
  && grep -q 'alter-config ta --set cleanup.policy=compact --no-confirm' "$T/rpk/rpk.log" \
  && grep -qx 'POLICY ta compact compact' "$T/pod.out" \
  && pass "3: an alter failure prints FAIL alter and still attempts the restore" || fail "3: alter failure output: $(tr '\n' '|' < "$T/pod.out")"

seed_topic tt compact "0 1 3"
FAIL_TRIM_TOPIC=tt run_pod_script tt
grep -qx 'FAIL tt trim 1' "$T/pod.out" \
  && grep -qx 'POLICY tt compact compact' "$T/pod.out" \
  && [ "$(cat "$T/rpk/policy.tt")" = compact ] \
  && pass "3: a trim failure still restores the policy" || fail "3: trim failure output: $(tr '\n' '|' < "$T/pod.out")"

seed_topic tr compact "0 1 3"
FAIL_RESTORE_TOPIC=tr run_pod_script tr
grep -qx 'FAIL tr restore 1' "$T/pod.out" && grep -qx 'POLICY tr compact compact,delete' "$T/pod.out" \
  && pass "3: a failed restore is reported (FAIL restore, POLICY after != before)" || fail "3: restore failure output"

# --- 4. local parse --------------------------------------------------------------
# run_quick_topics_fixture FIXTURE_TEXT -> runs the REAL run_quick_sequence with
# the real quick_topics, a fixture standing in for the broker output, and a
# scaled-down workload registered so the scale trap has something to restore.
run_quick_fixture() {
  printf '%s\n' "$1" > "$T/fixture.out"
  : > "$KLOG"; : > "$CALLS"
  (
    QUICK=true; DRY_RUN=false; EXEC_MODE=fixture
    REDPANDA_PODS=("${RELEASE}-redpanda-hq-0")
    QUICK_BROKER_TOPICS=(); QUICK_BROKER_TOPICS["${REDPANDA_PODS[0]}"]=" tc td"
    QUICK_RESIDUE=()
    quick_quiesce_all() {
      SCALES_ARMED=true
      QSTATE_QUIESCED+=("Deployment/victim"); QSTATE_REPLICAS["Deployment/victim"]=2
    }
    restate_open_preflight() { :; }; quick_restate() { :; }; quick_stores() { :; }; phase5_aggregator() { :; }
    phase7_electric() { :; }; phase9_restore_producers() { SCALES_RESTORED=true; }
    run_reset_sequence
  ) > "$T/qout" 2> "$T/qerr"
  RC=$?
}
GOOD=$'POLICY tc compact compact\nPART tc 0 9 9\nPOLICY td compact,delete compact,delete\nPART td 0 8 8\nDONE'

run_quick_fixture "$GOOD"
[ "$RC" -eq 0 ] && tail -1 "$T/qout" | grep -q 'Residue: none\.' && pass "4: a clean broker output exits 0 with Residue: none" || fail "4: clean rc=$RC last=$(tail -1 "$T/qout")"

run_quick_fixture $'POLICY tc compact compact\nPART tc 0 9 9\nPOLICY td compact,delete compact,delete\nPART td 0 8 12\nPART td 1 3 3\nDONE'
[ "$RC" -eq 0 ] && tail -1 "$T/qout" | grep -qF 'Residue: openddil-redpanda-hq-0/td/p0 (4 left).' \
  && pass "4: PART logstart != hw -> exit 0, residue pod/topic/pN (n left) in the banner" || fail "4: residue rc=$RC last=$(tail -1 "$T/qout")"

run_quick_fixture $'POLICY tc compact compact\nFAIL tc trim 1\nPART tc 0 9 9\nPOLICY td compact,delete compact,delete\nDONE'
[ "$RC" -eq 0 ] && tail -1 "$T/qout" | grep -qF 'tc (trim failed, rc=1)' \
  && pass "4: a trim FAIL is residue, not a halt" || fail "4: trim fail rc=$RC last=$(tail -1 "$T/qout")"

run_quick_fixture $'POLICY tc compact compact,delete\nPART tc 0 9 9\nPOLICY td compact,delete compact,delete\nDONE'
if [ "$RC" -eq 2 ] && grep -q 'HALT:' "$T/qerr" && grep -q 'emergency restore Deployment/victim to 2' "$T/qerr" \
   && grep -q '^scale deployments -n openddil victim --replicas=2\|^scale deployment -n openddil victim --replicas=2\|scale .*victim --replicas=2' "$KLOG"; then
  pass "4: a POLICY before != after halts (exit 2) and the scale trap restores the workload"
else fail "4: policy mismatch rc=$RC err=$(head -3 "$T/qerr" | tr '\n' '|')"; fi

run_quick_fixture $'POLICY tc compact compact\nFAIL tc alter 1\nPART tc 0 1 3\nPOLICY td compact,delete compact,delete\nDONE'
[ "$RC" -eq 2 ] && grep -q 'HALT:' "$T/qerr" && pass "4: an alter FAIL halts" || fail "4: alter fail rc=$RC"

run_quick_fixture $'POLICY tc compact compact\nPART tc 0 9 9'
[ "$RC" -eq 2 ] && pass "4: output that ends before DONE halts (truncated)" || fail "4: truncated rc=$RC"

# --- 2b. Q4 exec count against the fake rpk -----------------------------------------
seed_topic state-a compact "0 5 9"; seed_topic state-b compact "0 5 9"
seed_topic feed-1 compact,delete "0 2 8"; seed_topic feed-2 compact,delete "0 2 8"
: > "$KLOG"; : > "$CALLS"
(
  DRY_RUN=false; EXEC_MODE=script; QUICK_RESIDUE=()
  quick_list_targets
  quick_topics
  [ "${#QUICK_RESIDUE[@]}" -eq 0 ] && echo "RESIDUE-NONE"
) > "$T/q4.out" 2> "$T/q4.err"
[ "$(n_exec 'sh -c TOPICS=')" -eq "${#REDPANDA_PODS[@]}" ] \
  && pass "2: Q4 makes exactly one trim exec per broker (${#REDPANDA_PODS[@]})" \
  || fail "2: trim execs = $(n_exec 'sh -c TOPICS='); log: $(grep -c . "$KLOG")"
grep -q RESIDUE-NONE "$T/q4.out" && pass "4: end to end through the fake rpk leaves no residue" || fail "4: e2e: $(tail -3 "$T/q4.out" | tr '\n' '|') $(head -2 "$T/q4.err")"
[ -s "$TOPIC_CAPTURE_DIR/${REDPANDA_PODS[0]}.quick-trim.out" ] && pass "4: each broker's raw output is kept as evidence" || fail "4: no evidence file"
for f in capture_pass destination_stable fully_trimmed; do :; done
! grep -qE 'assert_destination_stable|assert_broker_fully_trimmed|phase4_capture_pass' "$CALLS" \
  && pass "2: Q4 never calls the capture pass or the stability/trim assertions" || fail "2: Q4 called proof work: $(cat "$CALLS")"

# --- 5. the stores SQL -------------------------------------------------------------------
SQL="$(quick_stores_sql pgpod)"
got="$(printf '%s\n' "$SQL" | grep -oE 'DELETE FROM [a-z_]+' | awk '{print $3}' | sort | tr '\n' ' ')"
want="$(for _t in "${TABLES[@]}"; do is_kept_table "$_t" || printf '%s\n' "$_t"; done | sort | tr '\n' ' ')"
[ "$got" = "$want" ] && pass "5: the SQL deletes from exactly the TABLES set minus KEPT_TABLES (${#TABLES[@]} tables)" || fail "5: SQL tables differ: got [$got] want [$want]"
printf '%s\n' "$SQL" | grep -qi 'truncate' && fail "5: SQL contains TRUNCATE" || pass "5: no TRUNCATE"
printf '%s\n' "$SQL" | grep -qi 'audit_log' && fail "5: SQL names audit_log" || pass "5: no audit_log"
printf '%s\n' "$SQL" | grep -qi 'egress_delivered_events' && fail "5: SQL names the delivery ledger" || pass "5: no egress_delivered_events"
ok=true
for h in "${HEARTBEAT_TABLES[@]}"; do
  printf '%s\n' "$SQL" | grep -q "to_regclass('public.${h}') IS NOT NULL THEN DELETE FROM ${h};" || ok=false
done
$ok && pass "5: heartbeat tables (${HEARTBEAT_TABLES[*]}) are deleted like the rest, each guarded by to_regclass" || fail "5: heartbeat table lines missing"
unguarded="$(printf '%s\n' "$SQL" | grep 'DELETE FROM' | grep -vc "to_regclass('public\.[a-z_]*') IS NOT NULL THEN DELETE")"
[ "$unguarded" -eq 0 ] && pass "5: every DELETE is guarded by to_regclass in SQL" || fail "5: $unguarded unguarded DELETE(s)"
( TABLES+=(audit_log); quick_refuse_excluded pgpod ) > /dev/null 2>"$T/ref.err"
[ $? -eq 2 ] && grep -q 'EXCLUDED_TABLES' "$T/ref.err" && pass "5: a table in EXCLUDED_TABLES is refused (halt)" || fail "5: audit_log was not refused"

# --- 2c. Q6 exec count --------------------------------------------------------------------
: > "$KLOG"
( DRY_RUN=false; quick_stores ) > "$T/q6.out" 2>&1
[ "$(n_exec 'postgres')" -eq "${#POSTGRES_PODS[@]}" ] && pass "2: Q6 makes exactly one exec per postgres pod (${#POSTGRES_PODS[@]})" \
  || fail "2: postgres execs = $(n_exec 'postgres')"
[ "$(grep -c 'deleted 42 row(s) from 15 table(s)' "$T/q6.out")" -eq "${#POSTGRES_PODS[@]}" ] \
  && pass "2: one count line per pod" || fail "2: count lines: $(grep -c deleted "$T/q6.out")"
[ -s "$T/sql.${POSTGRES_PODS[0]}" ] && grep -q 'DELETE FROM asset_registry' "$T/sql.${POSTGRES_PODS[0]}" \
  && pass "2: the SQL travels on stdin of that one exec" || fail "2: no SQL on stdin"

# --- 6. --dry-run ---------------------------------------------------------------------------
: > "$KLOG"
( DRY_RUN=true; QUICK_RESIDUE=(); quick_list_targets; : > "$KLOG"; quick_topics; quick_stores ) > "$T/dry.out" 2>&1
[ "$(n_exec '.')" -eq 0 ] && pass "6: --dry-run execs nothing in Q4/Q6" || fail "6: dry-run exec lines: $(grep '^exec' "$KLOG" | head -2)"
grep -q 'generated script for '"${REDPANDA_PODS[0]}" "$T/dry.out" && grep -q '^TOPICS=' "$T/dry.out" && grep -q '^echo DONE\|^DONE$' "$T/dry.out" \
  && pass "6: --dry-run prints each broker's generated script" || fail "6: scripts not printed"
grep -q 'DO \$q\$' "$T/dry.out" && grep -q 'DELETE FROM asset_registry' "$T/dry.out" && pass "6: --dry-run prints the stores SQL" || fail "6: SQL not printed"

# --- 7 + 1. sequence and banners with stubbed quick steps -------------------------------------
REAL_DEFS="$(declare -f quick_quiesce_all quick_restate quick_topics quick_stores phase5_aggregator phase7_electric phase9_restore_producers)"
quick_quiesce_all()    { echo "Q2" >> "$CALLS"; }
restate_open_preflight() { :; }
quick_restate()        { echo "Q3" >> "$CALLS"; }
quick_topics()         { echo "Q4" >> "$CALLS"; }
phase5_aggregator()    { echo "Q5" >> "$CALLS"; }
quick_stores()         { echo "Q6" >> "$CALLS"; }
phase7_electric()      { echo "Q7" >> "$CALLS"; }
phase9_restore_producers() { echo "Q9" >> "$CALLS"; }
: > "$CALLS"
( QUICK=true; DRY_RUN=false; QUICK_RESIDUE=("pod/t/p0 (3 left)" "pod/u/p1 (1 left)"); run_reset_sequence ) > "$T/seq.out" 2> "$T/seq.err"
RC=$?
[ "$RC" -eq 0 ] && pass "1: stubbed quick run exits 0" || fail "1: rc=$RC"
[ "$(tr '\n' ' ' < "$CALLS" | sed 's/ $//')" = "Q2 Q3 Q4 Q5 Q6 Q7 Q9" ] && pass "1: sequence is exactly Q2 Q3 Q4 Q5 Q6 Q7 Q9" || fail "1: sequence was '$(tr '\n' ' ' < "$CALLS")'"
bad=""
for f in $PROOF_WORK; do grep -qx "$f" "$CALLS" && bad="$bad $f"; done
[ -z "$bad" ] && pass "1: none of the proof work was called" || fail "1: called:$bad"
[ "$(grep -c '^(quick step ' "$T/seq.out")" -eq 7 ] && pass "7: every quick step prints (quick step <name>: N s)" || fail "7: step timing lines: $(grep -c '^(quick step ' "$T/seq.out")"
head -1 "$T/seq.out" | grep -q '^QUICK RESET: state cleared, NOT MEASURED\. Skipped: 1 baseline, pre-flight consumer assertion, 3b writer census windows, 4 capture and double read, 8 zero assertion, 10 subscription liveness\. No exercise reset record was written\.$' \
  && pass "7: start banner names the six skipped items" || fail "7: start banner: $(head -1 "$T/seq.out")"
tail -1 "$T/seq.out" | grep -Eq '^QUICK RESET: state cleared in [0-9]+ s, NOT MEASURED\. Skipped: .*\. Residue: pod/t/p0 \(3 left\); pod/u/p1 \(1 left\)\. No exercise reset record was written\.$' \
  && pass "7: end banner has the time and the residue list" || fail "7: end banner: $(tail -1 "$T/seq.out")"

# --- 9a. Q2 set construction -------------------------------------------------------------------
eval "$REAL_DEFS"   # the real functions back, for the cases that exercise them
phase2_quiesce()          { echo "phase2_quiesce" >> "$CALLS"; }
build_declared_producer_map() { :; }
derive_quiesce_set()      { printf 'Deployment/proj-a\nDeployment/faust-x\nDeployment/prod1\n'; }
quiesce_workload_set()    { echo "QSET $*" >> "$CALLS"; }
declare -A PRODUCER_OWNER=()
PRODUCER_OWNER["${REDPANDA_PODS[0]}|feed-1"]="Deployment/faust-r StatefulSet/rs-hub Deployment/proj-a"
CENSUS_QUIESCED=()
: > "$CALLS"; : > "$KLOG"
SAVED_RESTATE_PODS=(${RESTATE_PODS[@]+"${RESTATE_PODS[@]}"})
RESTATE_PODS=(rs-hub-0)
DRY_RUN=true quick_quiesce_all > "$T/q2.out" 2>&1
RESTATE_PODS=(${SAVED_RESTATE_PODS[@]+"${SAVED_RESTATE_PODS[@]}"})
grep -q 'StatefulSet/rs-hub' "$CALLS" && fail "9: Q2 scaled down a Restate server (Q3 needs it up)" \
  || pass "9: Q2 never quiesces a Restate server, even a declared writer"
grep -qx 'QSET Deployment/proj-a Deployment/faust-x Deployment/faust-r' "$CALLS" \
  && pass "9: Q2 quiesces derived set + declared owners, deduped, without re-scaling a producer" || fail "9: Q2 set: $(grep QSET "$CALLS")"
[ "${CENSUS_QUIESCED[*]}" = "Deployment/proj-a Deployment/faust-x Deployment/faust-r" ] \
  && pass "9: Q2 records the set in CENSUS_QUIESCED (phase 5 / phase 9 handling)" || fail "9: CENSUS_QUIESCED=${CENSUS_QUIESCED[*]}"
grep -qx phase2_quiesce "$CALLS" && ! grep -qE 'phase4_capture_pass|writer_census' "$CALLS" && pass "9: Q2 runs phase 2 for producers and no capture/census" || fail "9: Q2 calls: $(tr '\n' ' ' < "$CALLS")"

# --- 9b. Q3 shared waits ------------------------------------------------------------------------
SLEEPS=0
sleep() { SLEEPS=$((SLEEPS + 1)); }
restate_clear_pass() { :; }
restate_residue() { echo "0 0 0 0"; }
RESTATE_PODS=(r1 r2 r3 r4); DRY_RUN=false
quick_restate > "$T/q3.out" 2>&1
[ "$SLEEPS" -eq 1 ] && pass "9: Q3 sleeps the zero-read gap once for 4 runtimes (not once per runtime)" || fail "9: Q3 slept $SLEEPS times"
SLEEPS=0
phase3_restate > "$T/p3.out" 2>&1
[ "$SLEEPS" -eq 4 ] && pass "9: (reference) phase3_restate sleeps once per runtime: 4" || fail "9: phase3_restate slept $SLEEPS"
SLEEPS=0; rm -f "$T/rn"
# state in a file: restate_residue runs in a $(...) subshell
restate_residue() { if [ "$1" = r2 ] && [ ! -f "$T/rn" ]; then : > "$T/rn"; echo "0 3 0 0"; else echo "0 0 0 0"; fi; }
RESTATE_PODS=(r1 r2); quick_restate > "$T/q3b.out" 2>&1
[ "$SLEEPS" -eq 2 ] && pass "9: a runtime that needs a second pass costs one more shared sleep (2 total)" || fail "9: Q3 slept $SLEEPS, expected 2"
unset -f sleep restate_clear_pass restate_residue

# --- 8. refusals and restart-exercise.sh as before ---------------------------------------------------
cat > "$T/bin/kubectl" <<KEOF
#!/usr/bin/env bash
echo "\$*" >> "$T/kubectl2.log"
KEOF
chmod +x "$T/bin/kubectl"
: > "$T/kubectl2.log"
( unset -f kubectl; export PATH="$T/bin:$PATH"; set -- --quick --verify-only; . "$SCRIPT" ) > "$T/r.out" 2> "$T/r.err"
RC=$?
[ "$RC" -eq 1 ] && grep -q 'usage error: --quick cannot be combined' "$T/r.err" && [ ! -s "$T/kubectl2.log" ] \
  && pass "8: --quick --verify-only still exits 1, nothing run" || fail "8: refusal rc=$RC"
cat > "$T/reset-stub.sh" <<SEOF
#!/usr/bin/env bash
echo ran >> "$T/reset-ran.log"
SEOF
chmod +x "$T/reset-stub.sh"; : > "$T/reset-ran.log"
( unset -f kubectl; PATH="$T/bin:$PATH" RESET_SCRIPT="$T/reset-stub.sh" bash "$WRAPPER" --release rel --namespace ns --quick ) > /dev/null 2> "$T/w.err"
RC=$?
[ "$RC" -eq 1 ] && [ ! -s "$T/reset-ran.log" ] && grep -q -- '--quick refused' "$T/w.err" \
  && pass "8: restart-exercise.sh --quick still refused, reset never invoked" || fail "8: wrapper rc=$RC"

echo
if [ "$FAIL" -eq 0 ]; then echo "test_reset_quick_fast: ALL PASS"; exit 0; fi
echo "test_reset_quick_fast: FAILED"; exit 1
