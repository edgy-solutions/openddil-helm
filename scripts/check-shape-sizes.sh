#!/usr/bin/env bash
# ===========================================================================
# check-shape-sizes.sh — how many bytes must a PEP hold to serve a screen?
# ===========================================================================
# THE READ-PATH DIMENSION THAT DID NOT EXIST.
#
# On 2026-09-18 every tier PEP was OOMKilled in a loop and every panel showed
# FEED UNAVAILABLE. The write path was perfect: nine advancing stages, the
# derive stage completing at all three tiers, the completeness gate green.
# Nothing in the suite measured a single byte of what the read path carries.
#
# One table -- `tactical_events` -- had grown to a 10 MiB shape, 99.5% of the
# whole client load, from 18,562 residue rows left by an already-fixed relay
# defect. The PEP buffered it per request in unbounded threads against a
# 256 MiB cap. Every instrument outside the PEP was green.
#
# So this asks the question none of the others do: for each tier, how large is
# the snapshot a browser must be sent, per table? A table over the ceiling is
# a RETENTION or PREDICATE finding -- rows nobody prunes, or a filter that
# fails to narrow -- and it is a finding at the store, not at the client.
#
# WHY A CEILING AND NOT A TREND. A trend needs history this has no place to
# keep, and the failure is not gradual from the operator's seat: it is fine,
# fine, fine, then every panel is blank. A declared ceiling turns that into a
# number somebody can act on while it is still only a number.
#
# The same constant lives in the PEP (OPENDDIL_SHAPE_WARN_BYTES) which WARNS
# per response. That is the runtime half; this is the pre-flight half. They
# are deliberately the same number, and if you change one, change both.
#
#   ./scripts/check-shape-sizes.sh [namespace] [ceiling-bytes]
#
# Exit 0 = every shape under the ceiling. Exit 1 = at least one over, named.
# ===========================================================================
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=lib/require-cluster.sh
. "$HERE/lib/require-cluster.sh"
openddil_require_cluster

NS="${1:-openddil}"
CEILING="${2:-2097152}"     # 2 MiB, matching OPENDDIL_SHAPE_WARN_BYTES
REL="${OPENDDIL_RELEASE:-openddil}"

# Discover tiers from the cluster, not from a list — same rule the
# completeness gate uses. A hardcoded list answers a question about the chart
# instead of about the deployment.
tiers="$(kubectl get pods -n "$NS" -o name 2>/dev/null \
          | sed -n 's|^pod/.*-tier-pg-\(.*\)-0$|\1|p' | sort -u)"

if [ -z "$tiers" ]; then
  echo "no tier stores found in $NS — nothing to measure." >&2
  echo "This is NOT a pass: it means the enumeration found nothing, which" >&2
  echo "reads identically to every shape being small." >&2
  exit 1
fi

echo "shape sizes per tier (ceiling $(( CEILING / 1024 )) KiB)"
echo

fail=0
for t in $tiers; do
  pep="$(kubectl -n "$NS" get pod -o name 2>/dev/null \
          | grep "tier-pep-${t}-" | head -1 | sed 's|pod/||')"
  if [ -z "$pep" ]; then
    echo "  [$t] NO PEP POD — cannot measure this tier's read path"
    fail=1
    continue
  fi

  # Measured from INSIDE the PEP, against the Electric it actually talks to,
  # so the number is the one that process would have to hold. Measuring from
  # elsewhere would answer a question about a different network path.
  out="$(kubectl -n "$NS" exec "$pep" -c pep -- python -c "
import os, sys, urllib.parse, urllib.request
E = os.environ['OPENDDIL_ELECTRIC_URL'].rstrip('/')
TABLES = '''asset_capability_state asset_cm_state asset_logistics_status
edge_buffer_status region_fleet_summary region_top_factors region_wear_trends
tactical_events telemetry_latest_state'''.split()
total = 0
for tb in TABLES:
    u = E + '/v1/shape?' + urllib.parse.urlencode([('table', tb), ('offset', '-1')])
    try:
        with urllib.request.urlopen(u, timeout=30) as r:
            n = len(r.read())
    except Exception as e:
        print('%s ERR %s' % (tb, str(e)[:40])); continue
    total += n
    print('%s %d' % (tb, n))
print('TOTAL %d' % total)
" 2>/dev/null)"

  if [ -z "$out" ]; then
    echo "  [$t] MEASUREMENT FAILED — refusing to report this tier as clean"
    fail=1
    continue
  fi

  echo "  [$t]"
  over=0
  while read -r table bytes _; do
    [ -z "$table" ] && continue
    if [ "$bytes" = "ERR" ]; then
      printf "      %-28s %s\n" "$table" "unreadable"
      continue
    fi
    if [ "$table" = "TOTAL" ]; then
      printf "      %-28s %10s KiB   (one client load)\n" "TOTAL" "$(( bytes / 1024 ))"
      continue
    fi
    if [ "$bytes" -ge "$CEILING" ]; then
      printf "      %-28s %10s KiB  <-- OVER CEILING\n" "$table" "$(( bytes / 1024 ))"
      over=1
      fail=1
    else
      printf "      %-28s %10s KiB\n" "$table" "$(( bytes / 1024 ))"
    fi
  done <<< "$out"
  [ "$over" -eq 1 ] && echo "      ^ retention or predicate finding at THIS tier's store"
  echo
done

if [ "$fail" -eq 0 ]; then
  echo "shape sizes: every shape under the ceiling"
else
  echo "shape sizes: AT LEAST ONE SHAPE OVER THE CEILING."
  echo
  echo "A shape this size is held per-request by the PEP serving it. The fix is"
  echo "at the STORE -- prune the rows (declared retention) or narrow the"
  echo "predicate -- not at the client and not by raising the PEP's memory"
  echo "limit, which only changes how many concurrent shapes it survives."
fi
exit "$fail"
