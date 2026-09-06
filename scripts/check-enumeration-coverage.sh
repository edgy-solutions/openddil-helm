#!/usr/bin/env bash
# ===========================================================================
# check-enumeration-coverage.sh — how much of the scenario does the ontology
# actually recognise?
# ===========================================================================
# Usage: check-enumeration-coverage.sh [namespace]
#
# WHAT THIS IS FOR
# A scenario emits DIS entity types. The ontology
# (openddil-contracts/ontology/dis_entity_types.yaml) maps a 7-tuple to a
# canonical platform. A type the ontology does not know is NOT an error at
# ingest — it falls through to the `_default` entry and the asset arrives
# with an unresolved variant. That is the correct behaviour and it is also
# invisible: the pipeline keeps working and the asset is simply less
# described than the operator assumes.
#
# So the question "is the ontology ready for this scenario?" cannot be
# answered by whether anything broke. It has to be COUNTED.
#
# THE NUMBER THAT MATTERS IS UNKNOWN, AND IT MUST BE ABLE TO BE NON-ZERO.
# A coverage check that can only report success is the vacuous-pass shape
# this corpus keeps recording. This prints the unresolved count first and
# exits non-zero when it is above the threshold, so "we are ready" is a
# measurement rather than an absence of complaints.
#
# GD-11 CONTEXT: the ontology recognises ZERO kind=2 (munition) entries
# today. A scenario carrying munitions will therefore report every one of
# them unresolved — which is the finding, not a malfunction of this script.
# ===========================================================================
set -uo pipefail

NS="${1:-openddil}"
MAX_UNKNOWN="${MAX_UNKNOWN:-0}"

q() {
  kubectl exec -n "$NS" openddil-postgres-hq-0 -- \
    psql -U postgres -d openddil -tAc "$1" 2>/dev/null | tr -d '\r'
}

echo "enumeration coverage — namespace $NS"
echo

TOTAL="$(q "SELECT count(*) FROM telemetry_latest_state;")"
if [ -z "$TOTAL" ] || [ "$TOTAL" -eq 0 ] 2>/dev/null; then
  echo "FAIL: the fleet is EMPTY, so coverage is undefined." >&2
  echo "      Refusing to report 100% of nothing — a coverage number over an" >&2
  echo "      empty fleet is the vacuous pass this check exists to avoid." >&2
  exit 1
fi

# An unresolved platform arrives with no variant, or with the ontology's
# fallback marker. Both are counted; they are the same condition reported
# two ways depending on which stage did the falling back.
UNKNOWN="$(q "SELECT count(*) FROM telemetry_latest_state
              WHERE platform_variant IS NULL
                 OR btrim(platform_variant) = ''
                 OR upper(platform_variant) LIKE 'UNKNOWN%'
                 OR upper(platform_variant) LIKE '%UNSPECIFIED%';")"
KNOWN=$(( TOTAL - UNKNOWN ))

printf '  UNRESOLVED : %s of %s\n' "$UNKNOWN" "$TOTAL"
printf '  resolved   : %s\n' "$KNOWN"
echo
echo "  variants present:"
# GROUP BY the variant EXPRESSION, not "GROUP BY 1" — position 1 is the
# concatenated select item, which contains count(*), and grouping by an
# aggregate is illegal. Two wrong turns here in a row (first "ORDER BY 2"
# against a one-column select, then "GROUP BY 1" against an expression
# holding an aggregate), and neither was visible as anything but a blank
# section. `q` sends stderr to /dev/null, so the
# first version of this rendered an EMPTY section beside "14 resolved" and
# looked like a fleet with no variants. A display that can render empty on
# error is the same defect this script exists to catch, one layer in.
VARIANTS="$(q "SELECT coalesce(nullif(btrim(platform_variant),''),'(none)') || '  x' || count(*)
                 FROM telemetry_latest_state
                GROUP BY coalesce(nullif(btrim(platform_variant),''),'(none)')
                ORDER BY count(*) DESC;")"
if [ -z "$VARIANTS" ]; then
  echo "  FAIL: the variant breakdown query returned NOTHING while the fleet" >&2
  echo "        holds $TOTAL assets. That is a broken query, not an empty" >&2
  echo "        fleet — the two must never look alike here." >&2
  exit 1
fi
printf '%s
' "$VARIANTS" | sed 's/^/    /'

# Munitions are the known hole, so report them as their own line rather than
# folding them into the total — "12 unresolved" and "12 unresolved, all of
# them munitions" call for different work.
echo
MUNITION_HINT="$(q "SELECT count(*) FROM telemetry_latest_state
                     WHERE asset_id LIKE 'dis:%'
                       AND coalesce(btrim(platform_variant),'') = '';")"
echo "  note: the ontology recognises ZERO kind=2 (munition) entries (GD-11)."
echo "        A scenario emitting munitions reports them unresolved here, and"
echo "        that is the finding rather than a fault in this check."
echo "        DIS-sourced assets with no variant at all: ${MUNITION_HINT:-?}"

echo
if [ "$UNKNOWN" -le "$MAX_UNKNOWN" ] 2>/dev/null; then
  echo "enumeration coverage: PASS ($UNKNOWN unresolved, threshold $MAX_UNKNOWN)"
  exit 0
fi
echo "enumeration coverage: $UNKNOWN unresolved (threshold $MAX_UNKNOWN)" >&2
echo "  Each unresolved type needs an entry in" >&2
echo "  openddil-contracts/ontology/dis_entity_types.yaml, sourced from" >&2
echo "  SISO-REF-010 and reviewed — the curation rules in that file's header" >&2
echo "  are not optional, and inventing an entry to clear this number would" >&2
echo "  make the check worse than useless." >&2
exit 1
