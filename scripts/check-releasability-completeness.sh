#!/usr/bin/env bash
# ADR-0029 §7 — the label-completeness gate.
#
#   ./scripts/check-releasability-completeness.sh [-n NAMESPACE] [-p POD]
#
# Exit 0 = every populated labelled table is fully labelled in THIS
#          deployment, apart from assets DECLARED unlabelled (named on the
#          PASS line). Enforcement may be enabled here.
# Exit 1 = it is not. GATE FAILS.
# Exit 3 = the gate could not answer. GATE NOT RUN. Any exit other than 0 or
#          1 (78 from the cluster guard, 2 for a bad argument, 126/127 for a
#          self-call that could not execute) means the same thing.
#
# NOT RUN IS ITS OWN VERDICT. Until 2026-09-29 a gate that could not answer
# exited 1 like a gate that found leaks, and the every-store summary said
# "AT LEAST ONE STORE FAILS" after checking no store at all (the self-call
# could not execute when invoked as `bash <name>.sh`). A reader cannot act on
# a verdict that means two opposite things: one says fix the data, the other
# says the data was never looked at.
#
# LABEL FIRST, ENFORCE SECOND, NEVER THE REVERSE.
# Deny-unlabeled blanks legitimate data when it meets a partially-labelled
# dataset, and an operator cannot tell that from correct enforcement — both
# look like an empty screen. This gate is the only instrument standing
# between those two outcomes.
#
# ---------------------------------------------------------------------------
# THE TABLE LIST IS DERIVED FROM information_schema, NEVER HARDCODED
# ---------------------------------------------------------------------------
# ADR-0029 §7's added constraint, and it is a constraint rather than a style
# preference. Running this check by hand on 2026-08-12 found inventory_items
# — named in the migration's scope list AND present in schema.hcl — ABSENT
# from the deployed schema. A gate iterating the migration's list would issue
# SELECT ... FROM inventory_items and get:
#
#     ERROR:  column "originator_nation" does not exist
#
# A gate that errors is a gate that did not run, and an errored gate is
# indistinguishable from an unreachable database: both surface as "the check
# failed", both invite a retry, and neither says "your schema of record and
# your deployed schema disagree."
#
# The deeper reason: this gate's question is "is every labelled row in THIS
# DEPLOYMENT labelled?" A hardcoded list answers a question about the schema
# of record instead, and silently substitutes one for the other.
#
# ---------------------------------------------------------------------------
# EMPTY TABLES PROVE NOTHING, AND MUST BE EXPLAINED BY SOMEONE WHO KNOWS
# ---------------------------------------------------------------------------
# A zero over zero rows is vacuous. Counting it as evidence is the same error
# this gate exists to prevent, one layer up. So empty tables never contribute
# to a pass, and a run where EVERY table is empty exits non-zero: a gate with
# nothing to check is not a gate that passed.
#
# Added 2026-09-05: an empty table is now also a FAILURE unless the
# deployment has DECLARED it empty with a reason. There are two reasons a
# table is empty —
#
#   * nothing here produces that data, which is normal;
#   * something that should be producing it has stopped, which is a fault;
#
# — and from this gate's position they are byte-identical. The deployment is
# the only party that knows, so it writes the reason down
# (ontology/expected-empty.yaml) and the gate refuses to report a reassuring
# zero for a table nobody has explained.
#
# The declaration is read from the deployment overlay, NOT from a flag on
# this script. A reason typed on a command line vanishes; one in a file has
# an author and a date and shows up in a diff when it becomes untrue.
set -uo pipefail

# ---------------------------------------------------------------------------
# WHICH CLUSTER. Asserted, never inherited. See lib/require-cluster.sh for
# why this is a mechanism rather than a line in the README.
#
# The `|| exit 3` is load-bearing: these scripts run under `set -u` without
# `-e`, so a missing or unreadable helper would otherwise print a warning and
# let the script continue UNGUARDED -- a guard that fails open is worse than
# none, because it is also reassuring. It is 3 (NOT RUN), not 1: nothing was
# checked.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib/require-cluster.sh" || exit 3


# ---------------------------------------------------------------------------
# WHY THIS FILE USES `grep -q PATTERN <<<"$var"` AND NEVER `printf | grep -q`
# ---------------------------------------------------------------------------
# `set -o pipefail` and `grep -q` are a false-negative generator, and the
# failure is SIZE-DEPENDENT, which is the worst property it could have.
#
# `grep -q` exits on the FIRST match and closes its input. The upstream
# `printf` then takes SIGPIPE and exits 141. With `pipefail` the pipeline
# reports 141 — so a pipeline that MATCHED reports FAILURE.
#
# It only happens when the data exceeds the pipe buffer (~64KB). Below that,
# printf finishes writing before grep exits, there is no SIGPIPE, and the
# check is correct. So every one of these worked on small inputs and would
# have started lying as the fleet grew.
#
# The direction of the lie is what makes it worth this comment. In the
# `match && bad || ok` shape a SIGPIPE reads as "no match" and takes the
# `ok` branch — REPORTING A PASS ON A REAL LEAK. A check that gets quieter
# as the data gets bigger is the exact opposite of what these files are for.
#
# A here-string is not a pipeline, so `pipefail` has nothing to report.

NS="${OPENDDIL_NAMESPACE:-openddil}"
POD="${OPENDDIL_PG_POD:-openddil-postgres-hq-0}"
PGUSER="${OPENDDIL_PG_USER:-postgres}"
PGDB="${OPENDDIL_PG_DB:-openddil}"
# Where the deployment declares which labelled tables it expects to be empty.
# Defaults to the overlay beside this checkout; override for another layout.
EXPECTED_EMPTY="${OPENDDIL_EXPECTED_EMPTY:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/openddil-demo/ontology/expected-empty.yaml}"
# Where the deployment declares assets it keeps unlabelled on purpose (a lab
# fixture). Scoped to one kube-context inside the file; see its header.
DECLARED_UNLABELLED_FILE="${OPENDDIL_DECLARED_UNLABELLED:-$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lab-declared-unlabelled.yaml}"

# --- which store? -----------------------------------------------------------
# ONE GATE PER STORE, AND EVERY TIER HAS ONE.
#
# The §7 gate's question is "is every labelled row in THIS DEPLOYMENT
# labelled?" — and once tiers have their own stores and their own
# authorizers, "this deployment" stops being one place. A tier decides
# locally against its own data, so enabling enforcement there is a decision
# about THAT store, and a pass at the root says nothing about it.
#
# That is the same error the script's closing paragraph already refuses one
# level up: a result about one cluster restated as a claim about another.
# Tiers make it available one level down, inside a single cluster.
#
#   --tier <id>   gate ONE tier's own store (tier-pg-<id>, user `openddil`)
#   --root-only   gate ONLY the root store
#   --all-tiers   accepted, and now the default; kept so existing invocations
#                 and runbooks keep working unchanged
#
# EVERY STORE IS THE DEFAULT, BY CONSTRUCTION.
#
# This used to default to the root alone and require `--all-tiers` to do the
# whole deployment. The flag existed and worked; the readiness checklist
# invoked the single-store form, and on 2026-09-17 that run was recorded as
# readiness while two tier stores held unlabelled rows. The gate's own footer
# said what it was -- "a statement about the root store AND NOTHING ELSE" --
# and it was read as a pass anyway.
#
# That is the covers-one-of-N shape one level up from the code: the mechanism
# existed, the procedure did not use it. A correct default fixes it where
# remembering a flag does not, so the narrow answer is now the one you have
# to ask for by name.
TIER=""
ALL_TIERS=1
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NS="$2"; shift 2 ;;
    -p) POD="$2"; shift 2 ;;
    --tier) TIER="$2"; ALL_TIERS=0; shift 2 ;;
    --root-only) ALL_TIERS=0; shift ;;
    --all-tiers) ALL_TIERS=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

# The two stores are NOT symmetric and the difference has bitten before: the
# ROOT store's superuser is `postgres`, a TIER store's is `openddil`. Using
# the wrong one fails with `FATAL: role "openddil" does not exist`, which
# reads as a broken gate rather than a wrong flag. (PILOT-RUNBOOK §4 rung
# (ii) carries the same note for the same reason.)
if [ -n "$TIER" ]; then
  REL="${OPENDDIL_RELEASE:-openddil}"
  POD="${REL}-tier-pg-${TIER}-0"
  PGUSER="openddil"
fi

if [ "$ALL_TIERS" -eq 1 ]; then
  # Discover tiers from the cluster rather than from a list. Same rule as the
  # table enumeration below: ask the running system, because a hardcoded list
  # answers a question about the schema of record instead of the deployment.
  # Resolved to an absolute path and run through bash, so the self-call works
  # however this was invoked. `self="$0"` broke under `bash <name>.sh`: $0 is
  # then a bare name, the exec fails with 127, and that 127 used to be
  # reported as a failing store.
  self="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  tiers="$(kubectl get pods -n "$NS" -o name 2>/dev/null \
            | sed -n 's|^pod/.*-tier-pg-\(.*\)-0$|\1|p' | sort -u)"
  echo "gating the root store and $(printf '%s' "$tiers" | grep -c .) tier store(s)"
  echo
  failed=""; notrun=""; declared_all=""
  sub_out="$(mktemp)"
  # One store: stream its report, keep a copy to read its declared-unlabelled
  # line, and sort its exit into PASS / FAIL / NOT RUN.
  run_store() {
    local label="$1"; shift
    bash "$self" "$@" 2>&1 | tee "$sub_out"
    local s="${PIPESTATUS[0]}"
    case "$s" in
      0) : ;;
      1) failed="$failed $label" ;;
      *) notrun="$notrun $label(exit $s)" ;;
    esac
    declared_all="$declared_all $(sed -n 's/^DECLARED-UNLABELLED-EXCUSED://p' "$sub_out")"
  }
  # --root-only is REQUIRED here: the default is now every store, so a bare
  # self-call would recurse until something ran out.
  run_store root -n "$NS" --root-only
  for t in $tiers; do
    echo
    echo "=============================================================="
    run_store "$t" -n "$NS" --tier "$t"
  done
  rm -f "$sub_out"
  echo
  n_tiers="$(printf '%s' "$tiers" | grep -c .)"
  declared_ids="$(printf '%s\n' $declared_all | sed '/^$/d' | sort -u | tr '\n' ' ')"
  n_declared="$(printf '%s\n' $declared_all | sed '/^$/d' | sort -u | grep -c . || true)"
  if [ -n "$failed" ]; then
    echo "AT LEAST ONE STORE FAILS:$failed — enforcement must not be enabled there." >&2
    echo "Every store is reported above; the first failure is not the only one." >&2
    [ -n "$notrun" ] && echo "ALSO NOT RUN (no verdict about these):$notrun" >&2
    exit 1
  fi
  if [ -n "$notrun" ]; then
    echo "GATE NOT RUN on:$notrun" >&2
    echo "Those stores were NOT CHECKED. This is the absence of an answer about" >&2
    echo "them -- not a pass, and not a failure of their data." >&2
    exit 3
  fi
  if [ "$n_tiers" -eq 0 ]; then
    # "ALL STORES PASS" over zero tier stores is a true statement that
    # reads as a claim about tiers. It is not one. A deployment with
    # tierNode disabled has exactly one store, and saying so is the
    # difference between a result and an impression.
    echo "THE ROOT STORE PASSES. No tier store exists in this deployment,"
    echo "so this says NOTHING about per-tier enforcement — there is none"
    echo "to say anything about."
  else
    echo "ALL $((n_tiers + 1)) STORES PASS (root + $n_tiers tier)."
  fi
  # The excuse is part of the verdict, so it is printed with it -- never only
  # in a per-store section someone may have scrolled past.
  if [ "$n_declared" -gt 0 ]; then
    echo "$n_declared declared unlabelled asset(s), excused by declaration: $declared_ids"
    echo "  ($DECLARED_UNLABELLED_FILE)"
  else
    echo "0 declared unlabelled assets."
  fi
  exit 0
fi

# WHICH CLUSTER AM I ABOUT TO ASSERT ABOUT?
# Printed always, because this gate's output is a claim about ONE deployment
# and the most expensive mistake available here is restating one cluster's
# result as a claim about another (EXCHANGE-LEDGER X-7). A kubeconfig that
# has not been set resolves silently to whatever context is current, which on
# at least one machine is a long-lived production cluster.
CTX="$(kubectl config current-context 2>/dev/null)" || CTX=""
if [ -z "$CTX" ]; then
  echo "cannot determine kubectl context — refusing to report on an" >&2
  echo "unidentified cluster. GATE NOT RUN." >&2
  exit 3
fi
echo "ADR-0029 completeness gate"
echo "  context:   $CTX"
echo "  store:     $([ -n "$TIER" ] && echo "tier $TIER" || echo root)"
echo "  namespace: $NS   pod: $POD   db: $PGDB   user: $PGUSER"
echo

q() { kubectl exec -n "$NS" "$POD" -- psql -U "$PGUSER" -d "$PGDB" -At -c "$1" 2>&1; }

# Declared-empty tables. Parsed with grep/sed rather than a YAML library so
# this script keeps its only dependency being kubectl — the same reason the
# rest of it composes SQL by hand.
# A DECLARATION MAY BE SCOPED TO A CLASS OF STORE.
#
# `asset_registry` is populated at the ROOT (14 rows) and empty at every tier,
# because the registry is a root-side component (ADR-0028) and no tier
# projector has a mapping for it. Declaring it empty without a scope would
# excuse it at the root too -- so the day the root's registry emptied, the
# gate that exists to notice would be the thing explaining it away.
#
# An entry may therefore carry `stores: [tier]` or `stores: [root]`, or name
# tiers explicitly. NO `stores:` KEY MEANS EVERY STORE, so every existing
# declaration keeps its current meaning.
#
# Found 2026-09-18 on the first --all-tiers run that got far enough to reach
# this branch: the edge stores were failing earlier on unlabelled rows, so
# nothing had ever asked the question at a tier.
THIS_STORE="root"
TIER_KIND=""
if [ -n "$TIER" ]; then
  THIS_STORE="tier"
  # LEAF OR INTERMEDIATE, derived rather than listed.
  #
  # Some tables are empty at a LEAF and populated at an INTERMEDIATE: the
  # region_* rollups are produced by a tier with children, so an edge store
  # has nothing that could write them, while the region's copies must keep
  # being checked. Declaring them `stores: [tier]` would excuse both.
  #
  # The distinction is taken from the RELAY KIND the chart already derives
  # from hasChildren: an intermediate runs `tier-uplink-<id>`, a leaf runs
  # `edge-hq-bridge-<id>`. Asked of the running deployment rather than read
  # from a list, same rule as the tier enumeration -- a hardcoded roster in
  # an ontology file answers a question about a topology instead of about
  # this one.
  if kubectl get deploy -n "$NS" -o name 2>/dev/null \
       | grep -q -- "-tier-uplink-${TIER}\$"; then
    TIER_KIND="intermediate"
  else
    TIER_KIND="leaf"
  fi
fi

DECLARED_EMPTY=""
if [ -f "$EXPECTED_EMPTY" ]; then
  # Emit "table<TAB>scope-list" then filter to the entries in scope here. The
  # awk keeps the grep/sed-only dependency rule: kubectl and nothing else.
  # A SPARSE ENTRY IS NOT AN EXPECTED-EMPTY ENTRY and must never be read as
  # one. Found 2026-09-18 by red-checking the sparse branch: this awk emitted
  # every entry lacking a `stores:` key, so `tactical_events` -- which carries
  # `sparse: true` and no scope -- landed in BOTH lists. is_declared_empty is
  # tested first, so it won, and the conditional producer check never ran.
  # A conditional declaration silently became an unconditional one: precisely
  # the "explains away a stopped producer" failure the sparse category was
  # added to prevent, arriving inside the parser for it.
  DECLARED_EMPTY="$(sed -n '/^expected_empty:/,$p' "$EXPECTED_EMPTY" | awk -v store="$THIS_STORE" -v tier="$TIER" -v kind="$TIER_KIND" '
    /^  [a-z_][a-z_0-9]*:[[:space:]]*$/ {
      if (tbl != "") emit()
      tbl = $1; sub(":", "", tbl); scopes = ""; sparse = 0
      next
    }
    /^    sparse:[[:space:]]*true[[:space:]]*$/ { sparse = 1; next }
    /^    stores:[[:space:]]*\[/ {
      scopes = $0
      sub(/^[^[]*\[/, "", scopes); sub(/\].*$/, "", scopes); gsub(/[ \t"]/, "", scopes)
      next
    }
    END { if (tbl != "") emit() }
    function emit(   n, a, i) {
      if (sparse) return                               # conditional: handled elsewhere
      if (scopes == "") { print tbl; return }          # unscoped = every store
      n = split(scopes, a, ",")
      for (i = 1; i <= n; i++)
        if (a[i] == store || (tier != "" && a[i] == tier) \
            || (kind != "" && a[i] == kind)) { print tbl; return }
    }')"
  # SPARSE tables: empty is expected only WHILE THE PRODUCER IS ALIVE.
  # Parsed separately from declared-empty because it is a different claim --
  # "nothing produces this here" versus "this producer speaks rarely".
  DECLARED_SPARSE="$(sed -n '/^expected_empty:/,$p' "$EXPECTED_EMPTY" | awk '
    /^  [a-z_][a-z_0-9]*:[[:space:]]*$/ { tbl = $1; sub(":", "", tbl); next }
    /^    sparse:[[:space:]]*true[[:space:]]*$/ { if (tbl != "") print tbl }')"
  echo "  declared-empty: $(printf '%s' "$DECLARED_EMPTY" | tr '\n' ' ')"
  echo "                  (from $EXPECTED_EMPTY, in scope for: $THIS_STORE${TIER:+ $TIER}${TIER_KIND:+ [$TIER_KIND]})"
  [ -n "$DECLARED_SPARSE" ] && \
    echo "  declared-sparse: $(printf '%s' "$DECLARED_SPARSE" | tr '\n' ' ') (empty OK only while the producer is completing)"
else
  echo "  declared-empty: NONE — no $EXPECTED_EMPTY"
  echo "                  every empty labelled table will be reported as"
  echo "                  unexplained, which is the intended default."
fi
echo

is_declared_empty() {
  grep -qx "$1" <<<"$DECLARED_EMPTY"
}

# ---------------------------------------------------------------------------
# DECLARED-UNLABELLED ASSETS: a deliberate unlabelled fixture, named
# ---------------------------------------------------------------------------
# See lab-declared-unlabelled.yaml's header for the whole argument. In short:
# a lab that keeps one asset unlabelled on purpose had a gate that was red on
# every run, and a gate that is always red is not read. A declared asset's
# values -- THAT ASSET's, matched on the key column -- are subtracted from the
# count; every other unlabelled value fails exactly as before. The excused
# assets are named on the verdict line, and a declared asset that is NOT
# unlabelled in a store it is declared for FAILS the gate (stale excuse).
#
# SCOPED TO ONE CLUSTER: the file's `context:` must equal this run's context.
DECLARED_UNLABELLED=""
if [ -f "$DECLARED_UNLABELLED_FILE" ]; then
  du_ctx="$(sed -n 's/^context:[[:space:]]*\([^[:space:]#]*\).*$/\1/p' "$DECLARED_UNLABELLED_FILE" | head -1)"
  if [ "$du_ctx" = "$CTX" ]; then
    DECLARED_UNLABELLED="$(sed -n '/^declared_unlabelled:/,$p' "$DECLARED_UNLABELLED_FILE" | awk -v store="$THIS_STORE" -v tier="$TIER" -v kind="$TIER_KIND" '
      /^  "[^"]+":[[:space:]]*$/ {
        if (id != "") emit()
        id = $1; gsub(/"/, "", id); sub(/:$/, "", id); scopes = ""
        next
      }
      /^    stores:[[:space:]]*\[/ {
        scopes = $0
        sub(/^[^[]*\[/, "", scopes); sub(/\].*$/, "", scopes); gsub(/[ \t"]/, "", scopes)
        next
      }
      END { if (id != "") emit() }
      function emit(   n, a, i) {
        if (scopes == "") { print id; return }
        n = split(scopes, a, ",")
        for (i = 1; i <= n; i++)
          if (a[i] == store || (tier != "" && a[i] == tier) \
              || (kind != "" && a[i] == kind)) { print id; return }
      }')"
    echo "  declared-unlabelled: $(printf '%s' "${DECLARED_UNLABELLED:-NONE in scope}" | tr '\n' ' ')"
    echo "                  (from $DECLARED_UNLABELLED_FILE, context $du_ctx)"
  else
    echo "  declared-unlabelled: NONE — $DECLARED_UNLABELLED_FILE is for context"
    echo "                  '${du_ctx:-<unset>}', this run is '$CTX'; the whole file is ignored."
  fi
else
  echo "  declared-unlabelled: NONE — no $DECLARED_UNLABELLED_FILE"
fi
echo
# SQL list of the declared ids, for `key IN (...)`. Ids are checked against a
# conservative charset first: they are spliced into SQL by hand.
DU_SQL=""
for id in $DECLARED_UNLABELLED; do
  if ! grep -qE '^[A-Za-z0-9:._-]+$' <<<"$id"; then
    echo "declared-unlabelled id '$id' has characters outside [A-Za-z0-9:._-]." >&2
    echo "Refusing to splice it into SQL. GATE NOT RUN." >&2
    exit 3
  fi
  DU_SQL="${DU_SQL:+$DU_SQL,}'$id'"
done

# The key column a table's rows are named by: asset_id, else subject, else
# region_id, else empty. Shared by the declared-unlabelled subtraction and
# the findings list, so the two cannot disagree about which rows an id names.
key_column() {
  local cand n
  for cand in asset_id subject region_id; do
    n="$(q "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='$1' AND column_name='$cand';")"
    if [ "${n:-0}" = "1" ]; then echo "$cand"; return; fi
  done
}

# ---------------------------------------------------------------------------
# REGION-KEYED ROLLUPS: excused ONLY on an exact match
# ---------------------------------------------------------------------------
# A non-aggregate table keyed on region_id, carrying a per-region fleet_total,
# can show the same shape the phantom-partial correlate further below was
# built for: a region whose only assets are the declared-unlabelled fixture
# composes into a single NULL-nation, NULL-releasable_to row for that region,
# honestly. The rule is generalised past one named view on purpose -- nothing
# below names a table, only the shape "non-aggregate, keyed on region_id,
# carries a per-region fleet_total", so a future rollup of the same shape is
# covered without a second copy of this logic.
#
# EXCUSED ONLY ON AN EXACT MATCH, same discipline as the phantom-partial rule:
# the NULL-label row's fleet_total must EQUAL the number of declared-
# unlabelled assets asset_logistics_status places in that region, and that
# count must be non-zero. One asset more or fewer than declared, and the row
# stays a finding.
#
# ONE RULE, ONE PLACE: the counting path and the findings-listing path both
# call this function for the same table, so they cannot disagree about which
# regions are excused.
#
# Found 2026-10-03, the first gate run after asset_lifecycle_summary landed:
# region-west's only asset is the declared-unlabelled fixture, so the view's
# only row for that region is (region-west, NULL, NULL, fleet_total 1) --
# correct composition, not a missing label.
has_fleet_total_column() {
  local n
  n="$(q "SELECT count(*) FROM information_schema.columns WHERE table_schema='public' AND table_name='$1' AND column_name='fleet_total';" </dev/null)"
  [ "${n:-0}" = "1" ]
}

# Regions of table $1 excused by an exact match. One "region_id|fleet_total"
# line per excused region; nothing if $1 has no fleet_total column or there
# is no declared-unlabelled fixture to match against.
excused_region_rollup_rows() {
  local t="$1" r ft dn
  [ -n "$DU_SQL" ] || return 0
  has_fleet_total_column "$t" || return 0
  while IFS='|' read -r r ft; do
    [ -n "$r" ] || continue
    dn="$(q "SELECT count(*) FROM asset_logistics_status WHERE region_id='$r' AND asset_id IN ($DU_SQL);" </dev/null)"
    if [ "$ft" = "$dn" ] && [ "${dn:-0}" != "0" ]; then
      printf '%s|%s\n' "$r" "$ft"
    fi
  done < <(q "SELECT region_id, fleet_total FROM \"$t\" WHERE originator_nation IS NULL AND releasable_to IS NULL;" </dev/null)
}

# ---------------------------------------------------------------------------
# THE THIRD TERM: is the producer alive?
# ---------------------------------------------------------------------------
# `tactical_events` at the root is empty most of the time and that is CORRECT:
# events fire on TRANSITIONS, a stable fleet emits none, and the root prunes
# at 24h. Declaring it expected-empty would have been wrong -- the declaration
# would equally explain away a producer that had genuinely stopped, which is
# the move expected-empty.yaml's own header exists to make visible.
#
# The table cannot be its own evidence. If it is empty there is no newest row
# to age against retention, so the checkable condition is not "past retention"
# but "the producer is demonstrably completing" -- measured by
# check-derive-stage.sh, which asks whether fusion completes invocations.
#
#   empty AND producer completing      -> sparse   (green, with the reason)
#   empty AND producer not completing  -> stopped  (a finding)
#   empty AND no fresh measurement     -> unexplained (a finding)
#
# THE THIRD BRANCH IS THE LOAD-BEARING ONE. Absence of evidence buys nothing:
# a gate that treats "nobody measured" as "probably fine" is the reassuring
# zero this whole file was written to refuse. So this FAILS CLOSED to the
# behaviour it had before the category existed.
#
# Same shape as the relay stall probe's `destination reachable` clause: an
# absence is benign only when something else proves the source is alive.
DERIVE_RESULT="${OPENDDIL_DERIVE_RESULT:-${TMPDIR:-/tmp}/openddil-derive-stage.result}"
# A measurement older than this is not evidence about now. Deliberately short:
# the derive stage wedged for eight hours once while every other instrument
# stayed green, so a verdict from that long ago says nothing about this run.
DERIVE_MAX_AGE_S="${OPENDDIL_DERIVE_MAX_AGE_S:-1800}"

producer_state() {
  # -> "completing" | "not_completing" | "unmeasured:<why>"
  [ -f "$DERIVE_RESULT" ] || { echo "unmeasured:no result file at $DERIVE_RESULT"; return; }
  local epoch verdict age now
  epoch="$(sed -n 's/^epoch=//p' "$DERIVE_RESULT" | head -1)"
  verdict="$(sed -n 's/^verdict=//p' "$DERIVE_RESULT" | head -1)"
  case "$epoch" in ''|*[!0-9]*) echo "unmeasured:unreadable timestamp"; return ;; esac
  now="$(date -u +%s)"
  age=$(( now - epoch ))
  if [ "$age" -gt "$DERIVE_MAX_AGE_S" ]; then
    echo "unmeasured:result is ${age}s old, older than ${DERIVE_MAX_AGE_S}s"
    return
  fi
  case "$verdict" in
    COMPLETING)     echo "completing" ;;
    NOT_COMPLETING) echo "not_completing" ;;
    *)              echo "unmeasured:verdict=${verdict:-<empty>}" ;;
  esac
}

is_declared_sparse() {
  grep -qx "$1" <<<"${DECLARED_SPARSE:-}"
}

reason_for() {
  # The declared reason, flattened onto one line for the report. Printing it
  # here rather than only in the file is deliberate: the operator reading a
  # gate result is the person who needs to judge whether the reason is still
  # true.
  sed -n "/^  $1:/,/^  [a-z_]*:/p" "$EXPECTED_EMPTY" 2>/dev/null \
    | sed -n '/reason:/,/^    [a-z_]*:/p' \
    | sed '1s/.*reason:[[:space:]]*>-*//' | sed '$d' \
    | tr '\n' ' ' | tr -s ' ' | cut -c1-160
}

# --- step 1: derive the labelled-table set from the LIVE schema -------------
TABLES="$(q "SELECT table_name FROM information_schema.columns WHERE column_name = 'originator_nation' AND table_schema = 'public' ORDER BY table_name;")"
if grep -qiE "error|refused|not found|Unable to connect" <<<"$TABLES"; then
  echo "could not read information_schema — the gate DID NOT RUN." >&2
  echo "This is the absence of an answer, not a pass and not a fail:" >&2
  printf '%s\n' "$TABLES" | sed 's/^/    /' >&2
  exit 3
fi
if [ -z "$TABLES" ]; then
  echo "no table in this deployment carries originator_nation." >&2
  echo "Either the Arc 1 migration has not been applied here, or this is not" >&2
  echo "an OpenDDIL store. Refusing to report a vacuous pass." >&2
  exit 1
fi

# --- step 1b: THE TABLES THIS GATE COULD NOT SEE ----------------------------
# The enumeration above asks for tables that HAVE `originator_nation`, and
# then checks those for NULLs. It therefore answers "are the labelled tables
# labelled?" while being read as "is the served data partitionable?" — and
# those are different questions with different answers.
#
# A table with NO label columns at all was never in the enumeration, so the
# gate said complete while nine of fourteen served tables were answering 502
# through the gateway: the predicate names columns they do not have, Electric
# rejects the query, and the browser renders a transport failure as an
# absence of data. A 502 found what this gate could not.
#
# UNLABELABLE IS A FINDING, NOT A SKIP. It is reported here and, when the
# deployment declares `releasability.labeledTables`, reconciled against it —
# a list in a chart and columns in a schema are two copies of one fact.
echo
echo "labelability of every table in the store"
ALL="$(q "SELECT table_name FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE' ORDER BY table_name;")"
LABELLED_BOTH="$(q "SELECT table_name FROM information_schema.columns WHERE table_schema='public' AND column_name IN ('originator_nation','releasable_to') GROUP BY table_name HAVING count(DISTINCT column_name)=2 ORDER BY table_name;")"
unlabelable=""
for t in $ALL; do
  if ! grep -qx "$t" <<<"$LABELLED_BOTH"; then
    unlabelable="$unlabelable $t"
  fi
done
n_lab="$(printf '%s
' $LABELLED_BOTH | grep -c . || true)"
n_unl="$(printf '%s
' $unlabelable | grep -c . || true)"
echo "  labelable   : $n_lab — $(printf '%s ' $LABELLED_BOTH)"
if [ -n "$unlabelable" ]; then
  echo "  UNLABELABLE : $n_unl —$unlabelable"
  echo "        These carry neither originator_nation nor releasable_to, so the"
  echo "        read path CANNOT filter them. Any that the gateway serves will"
  echo "        fail at Electric and reach the browser as a transport error."
  echo "        Declaring them in releasability.labeledTables would be wrong;"
  echo "        the fix is either labels on the rows or an explicit refusal."
fi

# Reconcile with what the deployment TELLS the gateway about each table.
#
# FOUR CLASSES, and the reconciliation is what stops any of them becoming a
# hiding place:
#   nation-filtered  must HAVE label columns, or the predicate fails
#   role-served      must NOT have them — a table that CAN be partitioned and
#                    is served unfiltered is the failure this path prevents
#   subject-scoped   partitioned by who; the column must exist
#   pending          known to need labels, refused meanwhile
# Anything in NONE of them is the loud case: a table joined the store and
# nobody decided how it may be read.
if [ -n "${OPENDDIL_LABELED_TABLES:-}${OPENDDIL_ROLE_SERVED_TABLES:-}" ]; then
  drift=0
  in_list() { case ",$2," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }
  SUBJ_TABLES="$(printf '%s' "${OPENDDIL_SUBJECT_SCOPED_TABLES:-}" | tr ',' '
' | cut -d: -f1 | tr '
' ',')"

  for t in $LABELLED_BOTH; do
    if in_list "$t" "${OPENDDIL_ROLE_SERVED_TABLES:-}"; then
      echo "  FAIL: '$t' HAS label columns but is declared role-served —" >&2
      echo "        it would be served unfiltered though it can be" >&2
      echo "        partitioned. That is the bypass this gate exists for." >&2
      drift=1
    elif ! in_list "$t" "${OPENDDIL_LABELED_TABLES:-}"; then
      echo "  FAIL: '$t' carries labels but is declared in no class — it" >&2
      echo "        would be refused as unlabelable, a lie about the data." >&2
      drift=1
    fi
  done

  for t in $unlabelable; do
    if in_list "$t" "${OPENDDIL_LABELED_TABLES:-}"; then
      echo "  FAIL: '$t' is declared nation-filtered but has no label" >&2
      echo "        columns — every query against it fails at Electric." >&2
      drift=1
    elif in_list "$t" "${OPENDDIL_ROLE_SERVED_TABLES:-}"; then
      echo "  ok   $t: role-served (declared — no asset data to partition)"
    elif in_list "$t" "$SUBJ_TABLES"; then
      echo "  ok   $t: subject-scoped (declared)"
    elif in_list "$t" "${OPENDDIL_PENDING_LABEL_TABLES:-}"; then
      echo "  note $t: pending labels — refused until stamped"
    else
      echo "  FAIL: '$t' is in NO declared class. A table reached the store" >&2
      echo "        and nobody decided how it may be read; it is refused by" >&2
      echo "        default, which is safe and silent — and silence is how" >&2
      echo "        the previous nine went unnoticed." >&2
      drift=1
    fi
  done
  [ "$drift" -eq 0 ] && echo "  ok: every table is declared, and each class matches the schema"
  [ "$drift" -eq 0 ] || fail=1
else
  echo "  note: no table-class declaration supplied to this run, so the"
  echo "        chart's classes were NOT reconciled against the schema."
fi

# --- step 2: count per table ------------------------------------------------
# Counting NULLs on BOTH columns. A row with a nation but a NULL
# releasable_to is HALF-labelled, and the §4 filter's second clause
# (user_nation = ANY(releasable_to)) evaluates to NULL rather than false
# against it. Half-labelled is its own state; the gate must not let it hide
# behind the nation column being present.
SQL=""
for t in $TABLES; do
  [ -n "$SQL" ] && SQL="$SQL UNION ALL "
  SQL="$SQL SELECT '$t' AS t, count(*) AS n, count(*) FILTER (WHERE originator_nation IS NULL) AS nn, count(*) FILTER (WHERE releasable_to IS NULL) AS nr FROM \"$t\""
done
ROWS="$(q "$SQL ORDER BY t;")"
if grep -qiE "^ERROR|refused|Unable to connect" <<<"$ROWS"; then
  echo "counting query failed — the gate DID NOT RUN:" >&2
  printf '%s\n' "$ROWS" | sed 's/^/    /' >&2
  exit 3
fi

# --- step 3: report ---------------------------------------------------------
printf '%-28s %8s %12s %16s\n' TABLE ROWS NULL_NATION NULL_RELEASABLE
populated=0
# ---------------------------------------------------------------------------
# AGGREGATE TABLES: labelled by COMPOSITION, and a NULL nation is the answer
# ---------------------------------------------------------------------------
# Everywhere else "labelled" means both columns are non-null, because an
# asset-bearing row carries an authorship claim and a release list. A rollup
# carries no authorship: it is a number over many assets of possibly mixed
# nationality, and ADR-0029's addendum makes originator_nation an AUTHORSHIP
# CLAIM that a derived row inherits only when derivation preserves single
# authorship.
#
# It is not a formality. The §4 predicate is a disjunction, so a non-null
# originator_nation ALONE grants access — stamping a rollup with the nation
# most contributors share would bypass the composed intersection for everyone
# in that nation while looking like a perfectly ordinary label. The NULL is
# what makes the floor hold.
#
# So for these tables the test inverts: releasable_to must be non-null (the
# composition happened), and originator_nation must be NULL (nothing was
# claimed). A rollup WITH a nation is the finding here, not one without.
AGGREGATE_TABLES=" region_fleet_summary region_top_factors region_wear_trends "

is_aggregate() { case "$AGGREGATE_TABLES" in *" $1 "*) return 0 ;; *) return 1 ;; esac; }

unlabelled=0
aggregate_ok=0
du_values=0
du_found=""
empty_tables=""
declared_tables=""
undeclared_tables=""
sparse_tables=""
stopped_tables=""
unmeasured_tables=""
while IFS='|' read -r t n nn nr; do
  [ -n "$t" ] || continue
  if [ "$n" -eq 0 ]; then
    if is_declared_empty "$t"; then
      printf '%-28s %8s %12s %16s   (empty - DECLARED)\n' "$t" "$n" "$nn" "$nr"
      declared_tables="$declared_tables $t"
    elif is_declared_sparse "$t"; then
      # SPARSE: empty is expected only WHILE THE PRODUCER IS ALIVE. The third
      # term comes from check-derive-stage.sh, and an unmeasured or stale
      # verdict buys nothing -- see producer_state() for why that branch is
      # the load-bearing one.
      case "$(producer_state)" in
        completing)
          printf '%-28s %8s %12s %16s   (empty - SPARSE, producer completing)\n' "$t" "$n" "$nn" "$nr"
          sparse_tables="$sparse_tables $t"
          ;;
        not_completing)
          printf '%-28s %8s %12s %16s   <-- EMPTY and PRODUCER STOPPED\n' "$t" "$n" "$nn" "$nr"
          stopped_tables="$stopped_tables $t"
          ;;
        unmeasured:*)
          why="$(producer_state)"; why="${why#unmeasured:}"
          printf '%-28s %8s %12s %16s   <-- EMPTY, PRODUCER UNMEASURED\n' "$t" "$n" "$nn" "$nr"
          printf '%28s   (%s)\n' "" "$why"
          unmeasured_tables="$unmeasured_tables $t"
          ;;
      esac
    else
      printf '%-28s %8s %12s %16s   <-- EMPTY, UNDECLARED\n' "$t" "$n" "$nn" "$nr"
      undeclared_tables="$undeclared_tables $t"
    fi
    empty_tables="$empty_tables $t"
    continue
  fi
  populated=$((populated + 1))
  mark=""
  # Declared-unlabelled subtraction: THAT asset's NULLs, on this table's key
  # column, and nothing else. Aggregates key on region_id and hold no asset,
  # so no asset declaration can excuse a rollup.
  du_note=""
  if [ -n "$DU_SQL" ] && ! is_aggregate "$t"; then
    du_key="$(key_column "$t" </dev/null)"
    case "$du_key" in
      asset_id|subject)
        while IFS='|' read -r du_id du_nn du_nr; do
          [ -n "$du_id" ] || continue
          case "$du_nn$du_nr" in *[!0-9]*)
            echo "declared-unlabelled count on '$t' returned: $du_id|$du_nn|$du_nr" >&2
            echo "GATE NOT RUN." >&2
            exit 3 ;;
          esac
          [ $((du_nn + du_nr)) -gt 0 ] || continue
          nn=$((nn - du_nn)); nr=$((nr - du_nr))
          du_values=$((du_values + du_nn + du_nr))
          du_found="$du_found $du_id"
          du_note="$du_note   ($((du_nn + du_nr)) DECLARED: $du_id)"
        done < <(q "SELECT $du_key, count(*) FILTER (WHERE originator_nation IS NULL), count(*) FILTER (WHERE releasable_to IS NULL) FROM \"$t\" WHERE $du_key IN ($DU_SQL) GROUP BY $du_key;" </dev/null)
        ;;
      region_id)
        # See excused_region_rollup_rows() above: EXCUSED ONLY ON AN EXACT
        # MATCH. Each excused region contributes exactly one row that is NULL
        # in both label columns, so it subtracts 1 from nn and 1 from nr.
        while IFS='|' read -r du_r du_ft; do
          [ -n "$du_r" ] || continue
          nn=$((nn - 1)); nr=$((nr - 1))
          du_note="$du_note   ($du_ft DECLARED: region $du_r)"
          echo "$t region $du_r: NULL-label group holds $du_ft asset(s) = $du_ft declared unlabelled asset(s) there   (DECLARED)"
        done < <(excused_region_rollup_rows "$t")
        ;;
    esac
  fi
  if is_aggregate "$t"; then
    if [ "$nr" -gt 0 ]; then
      mark="   <-- NOT COMPOSED"
      unlabelled=$((unlabelled + nr))
    elif [ "$nn" -lt "$n" ]; then
      # A rollup that DID claim an authorship it cannot have.
      mark="   <-- AGGREGATE CLAIMS AN ORIGINATOR"
      unlabelled=$((unlabelled + (n - nn)))
    else
      mark="   (aggregate - composed, claims no originator)"
      aggregate_ok=$((aggregate_ok + 1))
    fi
  elif [ "$nn" -gt 0 ] || [ "$nr" -gt 0 ]; then
    mark="   <-- UNLABELLED"
    unlabelled=$((unlabelled + nn + nr))
  fi
  # NULL_NATION / NULL_RELEASABLE are printed AFTER the subtraction: the
  # columns show what fails, and du_note shows what was excused.
  printf '%-28s %8s %12s %16s%s%s\n' "$t" "$n" "$nn" "$nr" "$mark" "$du_note"
done <<< "$ROWS"

# ---------------------------------------------------------------------------
# PHANTOM PARTIALS - a legacy rollup replayed from before the partition
# ---------------------------------------------------------------------------
# A new consumer group starts at offset 0 and replays a topic history. A
# rollup emitted BEFORE partitioning by releasability class carries no
# releasable_to, decodes as the EMPTY class, and carries the WHOLE region
# counts. It lands beside the real partials as a phantom.
#
# THE GATE MUST LOOK WHERE THE PEP DENIES. An empty releasable_to denies
# every subject under the section 4 predicate, so this row renders on no
# screen - the filter correctness is what hides it. Wrong data that no
# subject can see is the most patient kind: nobody reports it, no panel
# disagrees, and it surfaces the day entitlements widen. A check that
# inspects only what is served has agreed not to look here.
#
# THIS IS A CORRELATE, NOT A DECLARATION. Neither half is suspicious alone -
# an empty class is legitimate (contributors releasable to nobody), and a
# partial holding every asset is legitimate (a single-class region). Their
# CONJUNCTION indicates a pre-partition row. The declaration that would
# settle it is a producer version stamped on the message (ADR-0034
# addendum); until that exists this is the cheap detector, and it is honest
# about being one.
phantom_sql="SELECT f.region_id FROM region_fleet_summary f"
phantom_sql="$phantom_sql WHERE length(f.releasability_class) = 0"
phantom_sql="$phantom_sql AND f.asset_count >= (SELECT COALESCE(sum(g.asset_count),0)"
phantom_sql="$phantom_sql FROM region_fleet_summary g WHERE g.region_id = f.region_id"
phantom_sql="$phantom_sql AND length(g.releasability_class) > 0);"
phantoms="$(q "$phantom_sql")"
# A DECLARED UNLABELLED ASSET PRODUCES THIS SHAPE HONESTLY. An unlabelled
# contributor composes into the empty class, and a region whose only assets
# are declared-unlabelled has no labelled partial beside it -- so the
# correlate fires on a current rollup, not a replayed one. Found 2026-09-29:
# the lab fixture is region-west's only asset, and this detector was the
# eighth "unlabelled value" every pre-flight had been attributing to it.
#
# EXCUSED ONLY ON AN EXACT MATCH: the empty-class partial's asset_count must
# EQUAL the number of declared-unlabelled assets that asset_logistics_status
# places in that region (the observed placement the rollup composes from; the
# registry holds an undeclared asset as region-unspecified). One more asset in
# that partial than was declared, and it is reported as a phantom as before.
if [ -n "$phantoms" ] && [ -n "$DU_SQL" ]; then
  still=""
  for r in $phantoms; do
    ec="$(q "SELECT asset_count FROM region_fleet_summary WHERE region_id='$r' AND length(releasability_class)=0;")"
    dn="$(q "SELECT count(*) FROM asset_logistics_status WHERE region_id='$r' AND asset_id IN ($DU_SQL);")"
    if [ -n "$ec" ] && [ "$ec" = "$dn" ] && [ "${dn:-0}" != "0" ] 2>/dev/null; then
      echo "empty-class partial in region $r holds $ec asset(s) = $dn declared unlabelled asset(s) there   (DECLARED, not a phantom)"
      du_values=$((du_values + 1))
    else
      still="$still $r"
    fi
  done
  phantoms="$(printf '%s\n' $still | sed '/^$/d')"
fi
if [ -n "$phantoms" ]; then
  echo "PHANTOM PARTIAL(S) - legacy rollups replayed from before the partition:" >&2
  printf "%s
" "$phantoms" | sed "s/^/    region /" >&2
  echo "  Each is releasable to NOBODY, so it renders on no screen and no" >&2
  echo "  operator will report it. It carries the whole region counts under" >&2
  echo "  the empty class, which is what a pre-partition emission decodes to." >&2
  echo "  Retire them; a key change is a migration, not an edit." >&2
  unlabelled=$((unlabelled + 1))
fi
echo
if [ "$populated" -eq 0 ]; then
  echo "every labelled table is EMPTY. The gate has nothing to check, which is" >&2
  echo "not the same as passing — a zero over zero rows is vacuous, and" >&2
  echo "counting it as evidence is the error this gate exists to prevent." >&2
  exit 1
fi

# STALE DECLARATION: a declared asset that is not unlabelled in a store it is
# declared for. The excuse no longer matches anything, so it can only explain
# away whatever arrives next -- and for a fixture it means the asset vanished
# or was labelled, which are findings in their own right.
du_stale=""
for id in $DECLARED_UNLABELLED; do
  grep -qw -- "$id" <<<"$du_found" || du_stale="$du_stale $id"
done
if [ -n "$du_stale" ]; then
  echo "GATE FAILS: declared-unlabelled asset(s) NOT unlabelled in this store:$du_stale"
  echo "  Declared in $DECLARED_UNLABELLED_FILE for this store, but no labelled"
  echo "  table here holds an unlabelled value for them. Either the asset"
  echo "  vanished (which a fixture must not do), it was labelled, or the"
  echo "  declaration's scope is wrong. Fix the cause or remove the row."
  exit 1
fi
du_ids="$(printf '%s\n' $du_found | sed '/^$/d' | sort -u | tr '\n' ' ')"
du_n="$(printf '%s\n' $du_found | sed '/^$/d' | sort -u | grep -c . || true)"

if [ "$unlabelled" -gt 0 ]; then
  echo "GATE FAILS: $unlabelled unlabelled value(s) across $populated populated table(s)."
  [ "$du_n" -gt 0 ] && echo "  (not counting $du_values value(s) of $du_n declared unlabelled asset(s): $du_ids)"
  echo
  echo "Subjects missing a declaration (table-qualified):"
  # NOT EVERY LABELLED TABLE IS ASSET-KEYED. The rollups key on region_id and
  # tactical_events on `subject`. An earlier version asked every table for
  # `asset_id`, so three of them answered with a raw psql error printed into
  # the findings section, and the fix after that SKIPPED those tables --
  # which is how this gate came to report "6 unlabelled value(s)" and then
  # name nothing at all.
  #
  # A gate that fails without saying what failed sends the operator to find
  # it by hand, and it is indistinguishable from a gate whose finding list is
  # genuinely empty. Trading a loud wrong answer for a quiet empty one is not
  # a fix. So: resolve the key column PER TABLE, and qualify each subject
  # with the table it came from -- ids from different key spaces must not be
  # silently merged into one list.
  #
  # Found 2026-09-17, the first time tactical_events was non-empty: the
  # derive stage had never produced a row, so this branch had never run
  # against the table whose key column it could not handle.
  #
  # ONE RULE, ONE PLACE. The predicate below MUST match the counting rule
  # above, and the first version of it did not: it asked every table for
  # `originator_nation IS NULL OR releasable_to IS NULL`, which is the
  # NON-AGGREGATE rule, and so accused all three region_* rollups of missing
  # a declaration while the count of 6 correctly excluded them. An aggregate
  # with a NULL originator is CORRECT -- composed rows claim no authorship --
  # and naming it as a finding sends the operator to "fix" the one thing that
  # was right.
  #
  # A second implementation of a rule is a second rule. The offence predicate
  # is therefore derived from the same is_aggregate() classification the
  # counter uses, not re-stated from memory of what it does.
  for t in $TABLES; do
    # Offence predicate, per class -- mirrors the counting rule exactly:
    #   aggregate      : releasable_to IS NULL  (not composed)
    #                 OR originator_nation IS NOT NULL  (claims authorship)
    #   non-aggregate  : originator_nation IS NULL OR releasable_to IS NULL
    if is_aggregate "$t"; then
      pred="releasable_to IS NULL OR originator_nation IS NOT NULL"
    else
      pred="originator_nation IS NULL OR releasable_to IS NULL"
    fi
    key="$(key_column "$t")"
    # A declared asset was already subtracted from the count, so it must not
    # be named here either: a findings list that includes the excused asset
    # would send the operator to "fix" the fixture.
    if [ -n "$DU_SQL" ] && ! is_aggregate "$t"; then
      case "$key" in
        asset_id|subject) pred="($pred) AND $key NOT IN ($DU_SQL)" ;;
        region_id)
          # Same exact-match rule as the counting path, via the same
          # function (excused_region_rollup_rows) -- not restated.
          excused_regions_sql=""
          while IFS='|' read -r ex_r ex_ft; do
            [ -n "$ex_r" ] || continue
            excused_regions_sql="${excused_regions_sql:+$excused_regions_sql,}'$ex_r'"
          done < <(excused_region_rollup_rows "$t")
          [ -n "$excused_regions_sql" ] && pred="($pred) AND region_id NOT IN ($excused_regions_sql)"
          ;;
      esac
    fi
    if [ -z "$key" ]; then
      # Say so, rather than dropping the table silently. An unlabelled row in
      # a table with no usable key is still a finding; it just cannot be
      # named, and the operator needs to know which table to open.
      bad="$(q "SELECT count(*) FROM \"$t\" WHERE $pred;")"
      [ "${bad:-0}" = "0" ] || echo "$t: ${bad} unlabelled row(s), NO asset_id/subject/region_id column to name them by"
      continue
    fi
    q "SELECT DISTINCT '$t' || ' [' || '$key' || '] ' || COALESCE($key::text,'<NULL>') FROM \"$t\" WHERE $pred;"
  done | sort -u | sed '/^$/d' | sed 's/^/    /'
  echo
  echo "Declare them in the deployment ontology overlay (releasability.yaml)"
  echo "and let the labels flow through ingress. DO NOT enable deny-unlabeled"
  echo "here until this reads zero: enforcing against a partially-labelled"
  echo "dataset blanks legitimate data, and an operator cannot tell that from"
  echo "correct enforcement."
  exit 1
fi

if [ -n "$stopped_tables" ]; then
  echo "GATE FAILS: sparse table(s) empty AND their producer is not completing:$stopped_tables"
  echo
  echo "These tables are declared sparse, which permits an empty table ONLY"
  echo "while the producer is demonstrably alive. check-derive-stage.sh says"
  echo "it is not completing, so the emptiness is the downstream half of that"
  echo "outage -- not the rare-event case the declaration describes."
  exit 1
fi

if [ -n "$unmeasured_tables" ]; then
  echo "GATE FAILS: sparse table(s) empty with NO FRESH producer measurement:$unmeasured_tables"
  echo
  echo "A sparse declaration is conditional on the producer being alive, and"
  echo "nothing has measured that recently. Absence of evidence buys nothing:"
  echo "treating 'nobody looked' as 'probably fine' is the reassuring zero"
  echo "this gate exists to refuse."
  echo
  echo "Run:  bash scripts/check-derive-stage.sh 60"
  echo "then re-run this gate. It publishes the verdict this reads."
  exit 1
fi

if [ -n "$undeclared_tables" ]; then
  echo "GATE FAILS: labelled table(s) empty with no declared reason:$undeclared_tables"
  echo
  echo "An empty table and a stalled producer look identical from here. Only"
  echo "the deployment knows which this is, so the deployment has to say —"
  echo "add each table to $EXPECTED_EMPTY with a reason, a producer and a"
  echo "date, or find out why the producer stopped."
  echo
  echo "That file is NOT a suppression list. A row in it is a dated claim"
  echo "that a named producer is absent for a named reason, and it shows up"
  echo "in a diff when it stops being true."
  exit 1
fi

if [ "$du_n" -gt 0 ]; then
  echo "GATE PASSES: $populated populated table(s), zero undeclared unlabelled values."
  echo "  $du_n declared unlabelled asset(s) excused: $du_ids($du_values value(s))"
  echo "  $(printf '%s' "$du_ids" | tr ' ' '\n' | sed '/^$/d' | while read -r id; do
          sed -n "/^  \"$id\":/,/^  \"/p" "$DECLARED_UNLABELLED_FILE" | sed -n '/reason:/,$p' | sed '1d;/^  "/d' | tr '\n' ' ' | tr -s ' '
        done | cut -c1-200)"
else
  echo "GATE PASSES: $populated populated table(s), zero unlabelled values."
fi
# Machine-readable, for the every-store summary: the ids excused HERE.
echo "DECLARED-UNLABELLED-EXCUSED:$du_ids"
if [ -n "$declared_tables" ]; then
  echo
  echo "Empty by declaration, and excluded from that result:"
  for t in $declared_tables; do
    printf '  %s\n' "$t"
    printf '      %s\n' "$(reason_for "$t")"
  done
fi
echo
echo "This is a statement about the ${TIER:+tier-$TIER}${TIER:-root} store on"
echo "'$CTX' AND NOTHING ELSE — not about the other stores in this same"
echo "cluster, which decide locally against their own data. Deployed schemas"
echo "provably diverge between clusters, so a pass here must not be restated"
echo "as a claim about another deployment (EXCHANGE-LEDGER X-7)."
exit 0
