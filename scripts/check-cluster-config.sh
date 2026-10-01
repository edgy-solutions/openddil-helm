#!/usr/bin/env bash
# ===========================================================================
# check-cluster-config.sh — is auto_create_topics_enabled actually false on
# every broker in a LIVE namespace?
# ===========================================================================
# Usage: check-cluster-config.sh [namespace]
#   namespace   default: openddil (or $OPENDDIL_NAMESPACE)
#   EXPECT      the value every broker must read back (default: false).
#               EXPECT=true is the red-check: it must FAIL on every broker
#               that actually reads false, proving this wrapper can fail.
#
# THIS WRAPS, AND NEVER DUPLICATES, openddil-demo/scripts/redpanda-auto-create-off.sh
# (read its header first). That file is the ONE place that knows how to ask a
# broker's Admin API for the property — this script's only job is to derive
# BROKERS from the LIVE cluster instead of a hand-written host list, run that
# script in ASSERT_ONLY=1 mode (never `rpk cluster config set` — read-only),
# and reinterpret its per-broker output against $EXPECT. It does not re-ask
# any broker anything the wrapped script did not already ask.
#
# WHY BROKERS IS DERIVED, NOT LISTED: a hand list goes stale the moment a
# tier is added or removed, and goes stale silently -- it still runs, it
# just stops being a statement about the whole cluster. Every redpanda
# broker in this chart is a StatefulSet named "<release>-redpanda-<tier>"
# with a same-named Service carrying a port literally named "admin" -- so
# the right host:port pair is read off that Service, per broker, with no
# tier list and no HQ special-case.
#
# THE ADMIN-PORT DISCREPANCY (RUNBOOK-NOTE-cluster-config-not-applied-by-chart.md
# vs. the wrapped script's own header) was settled by measurement, not
# guessed: see c:\tmp\overnight-1001\D6\admin-ports.txt. Reading each
# broker's admin port off its own Service (as this script does) reproduces
# the wrapped script's documented ports exactly, HQ included -- so this
# script makes no HQ exception and needed none.
#
# EXIT: 0 every broker reads $EXPECT; 1 at least one does not (named); 3 the
# gate could not run (kubectl unavailable, namespace missing, no redpanda
# broker found live, no pod available to exec the probe from, or the
# wrapped script is missing).
# ===========================================================================
set -uo pipefail

NS="${1:-${OPENDDIL_NAMESPACE:-openddil}}"
EXPECT="${EXPECT:-false}"
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/openddil-demo/scripts/redpanda-auto-create-off.sh"

case "$EXPECT" in
  true|false) ;;
  *) echo "EXPECT must be 'true' or 'false', got '$EXPECT'" >&2; exit 2 ;;
esac

command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found — GATE NOT RUN" >&2; exit 3; }
[ -r "$SCRIPT" ] || { echo "$SCRIPT not found — GATE NOT RUN" >&2; exit 3; }
kubectl get ns "$NS" >/dev/null 2>&1 || { echo "namespace '$NS' not found (or cluster unreachable) — GATE NOT RUN" >&2; exit 3; }

# --- derive BROKERS from the live cluster, not a hand list ------------------
# A redpanda broker StatefulSet here is always named "<release>-redpanda-<tier>"
# with a same-named Service. Ask the cluster, not a values file, so a tier
# this run never heard of is still covered.
sts_names="$(kubectl get statefulsets -n "$NS" -o name 2>/dev/null | sed -n 's|^statefulset.apps/||p' | grep -- '-redpanda-' || true)"
if [ -z "$sts_names" ]; then
  echo "no '*-redpanda-*' StatefulSet found in namespace '$NS' — GATE NOT RUN" >&2
  exit 3
fi

BROKERS=""
declare -a NAMES=() PORTS=()
for name in $sts_names; do
  port="$(kubectl get svc "$name" -n "$NS" -o jsonpath='{.spec.ports[?(@.name=="admin")].port}' 2>/dev/null)"
  if [ -z "$port" ]; then
    echo "StatefulSet $name has no same-named Service exposing a port named 'admin' — GATE NOT RUN" >&2
    exit 3
  fi
  NAMES+=("$name"); PORTS+=("$port")
  BROKERS="${BROKERS:+$BROKERS }$name:$port"
done

# Any already-running redpanda pod can run the probe (same image, rpk
# ships in it) -- exactly the wrapped script's own "STANDALONE INVOCATION".
# Pick the first broker's -0 pod and require it Ready.
PROBE_POD=""
for name in "${NAMES[@]}"; do
  phase="$(kubectl get pod "${name}-0" -n "$NS" -o jsonpath='{.status.phase}' 2>/dev/null || true)"
  if [ "$phase" = "Running" ]; then PROBE_POD="${name}-0"; break; fi
done
if [ -z "$PROBE_POD" ]; then
  echo "no Running redpanda broker pod found to exec the probe from — GATE NOT RUN" >&2
  exit 3
fi

echo "cluster-config gate — namespace '$NS'"
echo "  brokers (derived from live StatefulSets + each one's own Service 'admin' port): $BROKERS"
echo "  probe pod: $PROBE_POD (ASSERT_ONLY=1 — no 'rpk cluster config set' is ever run)"
echo "  EXPECT=$EXPECT"
echo

OUT="$(MSYS_NO_PATHCONV=1 kubectl -n "$NS" exec -i "$PROBE_POD" -- \
        env BROKERS="$BROKERS" ASSERT_ONLY=1 \
        sh -s < "$SCRIPT" 2>&1)"
rc=$?
echo "$OUT" | sed 's/^/  /'
echo

if [ "$rc" -gt 1 ] && ! printf '%s\n' "$OUT" | grep -q '^auto_create_topics_enabled:'; then
  echo "the wrapped script did not complete (exit $rc) — GATE NOT RUN" >&2
  exit 3
fi

# --- reinterpret the wrapped script's own per-broker lines against EXPECT --
# Never re-asks a broker: this only parses lines the wrapped script already
# printed. Two shapes carry a value ("OK: ... =false" and "FAIL: ...
# ='true' (want false)"); a third ("FAIL: ... Admin API unreachable") carries
# none and is treated as a broker this run could not measure.
measured="$(printf '%s\n' "$OUT" | sed -n \
  -e "s/^OK:   \\([^ ]*\\) auto_create_topics_enabled=\\(true\\|false\\)\$/\\1 \\2/p" \
  -e "s/^FAIL: \\([^ ]*\\) auto_create_topics_enabled='\\([a-z]*\\)' .*/\\1 \\2/p")"
unreachable="$(printf '%s\n' "$OUT" | sed -n "s/^FAIL: \\([^ ]*\\) Admin API unreachable.*/\\1/p")"

fail=0
printf '%-40s %-10s %-10s %s\n' BROKER MEASURED EXPECT RESULT
for i in "${!NAMES[@]}"; do
  b="${NAMES[$i]}:${PORTS[$i]}"
  val="$(printf '%s\n' "$measured" | awk -v b="$b" '$1==b{print $2}')"
  if [ -z "$val" ]; then
    printf '%-40s %-10s %-10s %s\n' "$b" "unreachable" "$EXPECT" "FAIL"
    fail=1
    continue
  fi
  if [ "$val" = "$EXPECT" ]; then
    printf '%-40s %-10s %-10s %s\n' "$b" "$val" "$EXPECT" "PASS"
  else
    printf '%-40s %-10s %-10s %s\n' "$b" "$val" "$EXPECT" "FAIL"
    fail=1
  fi
done

echo
if [ "$fail" -eq 0 ]; then
  echo "RESULT: PASS — every broker reads auto_create_topics_enabled=$EXPECT"
  exit 0
else
  echo "RESULT: FAIL — at least one broker does not read $EXPECT (see table above)"
  exit 1
fi
