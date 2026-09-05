#!/usr/bin/env bash
# ADR-0029 §7 — the label-completeness gate.
#
#   ./scripts/check-releasability-completeness.sh [-n NAMESPACE] [-p POD]
#
# Exit 0 = every populated labelled table is fully labelled in THIS
#          deployment. Enforcement may be enabled here.
# Exit 1 = it is not, OR the gate could not answer. Those two are reported
#          differently and never conflated.
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

NS="${OPENDDIL_NAMESPACE:-openddil}"
POD="${OPENDDIL_PG_POD:-openddil-postgres-hq-0}"
PGUSER="${OPENDDIL_PG_USER:-postgres}"
PGDB="${OPENDDIL_PG_DB:-openddil}"
# Where the deployment declares which labelled tables it expects to be empty.
# Defaults to the overlay beside this checkout; override for another layout.
EXPECTED_EMPTY="${OPENDDIL_EXPECTED_EMPTY:-$(cd "$(dirname "$0")/../.." 2>/dev/null && pwd)/openddil-demo/ontology/expected-empty.yaml}"

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
#   --tier <id>   gate the tier's own store (tier-pg-<id>, user `openddil`)
#   --all-tiers   gate the root and every tier that has a store, and FAIL if
#                 any of them does, rather than reporting the first
TIER=""
ALL_TIERS=0
while [ $# -gt 0 ]; do
  case "$1" in
    -n) NS="$2"; shift 2 ;;
    -p) POD="$2"; shift 2 ;;
    --tier) TIER="$2"; shift 2 ;;
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
  self="$0"
  tiers="$(kubectl get pods -n "$NS" -o name 2>/dev/null \
            | sed -n 's|^pod/.*-tier-pg-\(.*\)-0$|\1|p' | sort -u)"
  echo "gating the root store and $(printf '%s' "$tiers" | grep -c .) tier store(s)"
  echo
  rc=0
  "$self" -n "$NS" || rc=1
  for t in $tiers; do
    echo
    echo "=============================================================="
    "$self" -n "$NS" --tier "$t" || rc=1
  done
  echo
  n_tiers="$(printf '%s' "$tiers" | grep -c .)"
  if [ "$rc" -eq 0 ]; then
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
  else
    echo "AT LEAST ONE STORE FAILS — enforcement must not be enabled there." >&2
    echo "Every store is reported above; the first failure is not the only one." >&2
  fi
  exit "$rc"
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
  echo "unidentified cluster." >&2
  exit 1
fi
echo "ADR-0029 completeness gate"
echo "  context:   $CTX"
echo "  store:     ${TIER:+tier $TIER}${TIER:-root}"
echo "  namespace: $NS   pod: $POD   db: $PGDB   user: $PGUSER"
echo

q() { kubectl exec -n "$NS" "$POD" -- psql -U "$PGUSER" -d "$PGDB" -At -c "$1" 2>&1; }

# Declared-empty tables. Parsed with grep/sed rather than a YAML library so
# this script keeps its only dependency being kubectl — the same reason the
# rest of it composes SQL by hand.
DECLARED_EMPTY=""
if [ -f "$EXPECTED_EMPTY" ]; then
  DECLARED_EMPTY="$(sed -n '/^expected_empty:/,$p' "$EXPECTED_EMPTY" \
    | sed -n 's/^  \([a-z_][a-z_0-9]*\):[[:space:]]*$/\1/p')"
  echo "  declared-empty: $(printf '%s' "$DECLARED_EMPTY" | tr '\n' ' ')"
  echo "                  (from $EXPECTED_EMPTY)"
else
  echo "  declared-empty: NONE — no $EXPECTED_EMPTY"
  echo "                  every empty labelled table will be reported as"
  echo "                  unexplained, which is the intended default."
fi
echo

is_declared_empty() {
  printf '%s\n' "$DECLARED_EMPTY" | grep -qx "$1"
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
if printf '%s' "$TABLES" | grep -qiE "error|refused|not found|Unable to connect"; then
  echo "could not read information_schema — the gate DID NOT RUN." >&2
  echo "This is the absence of an answer, not a pass and not a fail:" >&2
  printf '%s\n' "$TABLES" | sed 's/^/    /' >&2
  exit 1
fi
if [ -z "$TABLES" ]; then
  echo "no table in this deployment carries originator_nation." >&2
  echo "Either the Arc 1 migration has not been applied here, or this is not" >&2
  echo "an OpenDDIL store. Refusing to report a vacuous pass." >&2
  exit 1
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
if printf '%s' "$ROWS" | grep -qiE "^ERROR|refused|Unable to connect"; then
  echo "counting query failed — the gate DID NOT RUN:" >&2
  printf '%s\n' "$ROWS" | sed 's/^/    /' >&2
  exit 1
fi

# --- step 3: report ---------------------------------------------------------
printf '%-28s %8s %12s %16s\n' TABLE ROWS NULL_NATION NULL_RELEASABLE
populated=0
unlabelled=0
empty_tables=""
declared_tables=""
undeclared_tables=""
while IFS='|' read -r t n nn nr; do
  [ -n "$t" ] || continue
  if [ "$n" -eq 0 ]; then
    if is_declared_empty "$t"; then
      printf '%-28s %8s %12s %16s   (empty - DECLARED)\n' "$t" "$n" "$nn" "$nr"
      declared_tables="$declared_tables $t"
    else
      printf '%-28s %8s %12s %16s   <-- EMPTY, UNDECLARED\n' "$t" "$n" "$nn" "$nr"
      undeclared_tables="$undeclared_tables $t"
    fi
    empty_tables="$empty_tables $t"
    continue
  fi
  populated=$((populated + 1))
  mark=""
  if [ "$nn" -gt 0 ] || [ "$nr" -gt 0 ]; then
    mark="   <-- UNLABELLED"
    unlabelled=$((unlabelled + nn + nr))
  fi
  printf '%-28s %8s %12s %16s%s\n' "$t" "$n" "$nn" "$nr" "$mark"
done <<< "$ROWS"

echo
if [ "$populated" -eq 0 ]; then
  echo "every labelled table is EMPTY. The gate has nothing to check, which is" >&2
  echo "not the same as passing — a zero over zero rows is vacuous, and" >&2
  echo "counting it as evidence is the error this gate exists to prevent." >&2
  exit 1
fi

if [ "$unlabelled" -gt 0 ]; then
  echo "GATE FAILS: $unlabelled unlabelled value(s) across $populated populated table(s)."
  echo
  echo "Assets missing a declaration (deduplicated across tables):"
  for t in $TABLES; do
    q "SELECT DISTINCT asset_id FROM \"$t\" WHERE originator_nation IS NULL OR releasable_to IS NULL;"
  done | sort -u | sed '/^$/d' | sed 's/^/    /'
  echo
  echo "Declare them in the deployment ontology overlay (releasability.yaml)"
  echo "and let the labels flow through ingress. DO NOT enable deny-unlabeled"
  echo "here until this reads zero: enforcing against a partially-labelled"
  echo "dataset blanks legitimate data, and an operator cannot tell that from"
  echo "correct enforcement."
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

echo "GATE PASSES: $populated populated table(s), zero unlabelled values."
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
