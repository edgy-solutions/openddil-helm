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
# EMPTY TABLES PROVE NOTHING, AND ARE REPORTED AS SUCH
# ---------------------------------------------------------------------------
# A zero over zero rows is vacuous. Counting it as evidence is the same error
# this gate exists to prevent, one layer up. Empty tables are listed
# separately and never contribute to a pass, and a run where EVERY table is
# empty exits non-zero: a gate with nothing to check is not a gate that
# passed, and "nothing is broken" must not stand in for "nothing was
# examined".
set -uo pipefail

NS="${OPENDDIL_NAMESPACE:-openddil}"
POD="${OPENDDIL_PG_POD:-openddil-postgres-hq-0}"
PGUSER="${OPENDDIL_PG_USER:-postgres}"
PGDB="${OPENDDIL_PG_DB:-openddil}"

while [ $# -gt 0 ]; do
  case "$1" in
    -n) NS="$2"; shift 2 ;;
    -p) POD="$2"; shift 2 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

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
echo "  namespace: $NS   pod: $POD   db: $PGDB"
echo

q() { kubectl exec -n "$NS" "$POD" -- psql -U "$PGUSER" -d "$PGDB" -At -c "$1" 2>&1; }

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
while IFS='|' read -r t n nn nr; do
  [ -n "$t" ] || continue
  if [ "$n" -eq 0 ]; then
    printf '%-28s %8s %12s %16s   (empty - proves nothing)\n' "$t" "$n" "$nn" "$nr"
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

echo "GATE PASSES: $populated populated table(s), zero unlabelled values."
if [ -n "$empty_tables" ]; then
  echo "Empty, and therefore excluded from that result:$empty_tables"
fi
echo
echo "This is a statement about '$CTX' AND NOTHING ELSE. Deployed schemas"
echo "provably diverge between clusters, so a pass here must not be restated"
echo "as a claim about another deployment (EXCHANGE-LEDGER X-7)."
exit 0
