#!/usr/bin/env bash
# ===========================================================================
# sever-tier.sh — isolate a tier's site from the root, for real.
# ===========================================================================
# Usage: sever-tier.sh <tier-id> on|off|status [namespace]
#
# WHY THIS EXISTS, AND WHY toxiproxy IS NOT ENOUGH
# ------------------------------------------------
# The severance rehearsal cut `hq-link` — the toxiproxy in front of the HQ
# broker that the edge->HQ bridge publishes through — and concluded the site
# was severed. It was not. A proxy on one link severs THAT LINK. Anything
# crossing the boundary by another route is untouched, and something was:
# the root's per-edge projector read the edge broker DIRECTLY and wrote the
# root store, so HQ stayed fresh through every sever anyone ever ran. Rung
# (iv)'s "HQ converges" was convergence onto a value HQ had never left.
#
#   *A sever measures only the paths it cuts.*
#
# So this does not enumerate paths. It applies a DEFAULT-DENY NetworkPolicy
# to the site's pods — ingress and egress — allowing only same-site traffic
# and DNS. A path nobody knew about is cut by the same rule as a path
# everybody knew about, which is the only way to test for the one nobody
# knew about.
#
# THE SIMULATOR EXCEPTION, and it is not a loophole
# -------------------------------------------------
# In this deployment the sensor generator is CENTRAL: `logistics-sim` runs
# on the root side and writes into every edge broker directly, and the DIS
# sim feeds the site's sensor-ingest over UDP. On real hardware those are
# sensors AT THE SITE. A naive isolation therefore cuts the site's own
# sensor feed, the tier's telemetry stops advancing, and the run reports a
# frozen tier — a FALSE NEGATIVE that looks exactly like the failure this
# test is for, and which one would be tempted to fix by weakening the test.
#
# The simulators are allowed through, explicitly and narrowly, because they
# stand in for on-site sensors. Everything else crossing the boundary is
# cut. If that exception is ever widened to something that is not a sensor
# stand-in, this test stops meaning anything.
#
# A POLICY IS NOT A CUT UNTIL EVERY FLOW RE-ESTABLISHES UNDER IT
# ---------------------------------------------------------------
# NetworkPolicy filters CONNECTIONS, and conntrack lets ESTABLISHED ones
# through. Applying the policy to running pods stops nothing that is
# already open. Measured here: with the policy applied and the site
# "proven" isolated, the edge->HQ bridge kept publishing — the HQ topic
# high-watermark went 92 -> 99 during severance. Deleting the bridge pod,
# with the same policy still in place, froze it at 103 immediately.
#
# The reason this was so convincing is worth stating: the two-sided probe
# below OPENS A NEW CONNECTION, so it correctly reported the policy was
# live. It could not report that the traffic which mattered had never
# stopped. *A control that tests the mechanism you installed is not a
# control on the outcome you wanted.*
#
# So `on` restarts every pod in the site after applying the policy. That
# also kills inbound sockets held by ROOT pods, which nothing on the site
# side could otherwise close — the site pod is the server, and deleting
# it is the only lever the site has. Deliberately NOT an enumeration of
# which pods hold cross-boundary connections: the whole point is to catch
# the one nobody listed.
#
# PROVING THE CUT
# ---------------
# `on` does not trust the policy. It probes from inside a site pod, both
# ways: a ROOT service must become unreachable AND a SITE peer must stay
# reachable. One-sided proof is how you get a test that passes because it
# broke everything, or one that passes because it broke nothing.
#
# It also verifies the cluster ENFORCES NetworkPolicy at all. A CNI without
# a policy controller accepts every policy and applies none, so the sever
# would report success having done nothing — and the run would then read
# "no other paths exist" off a test that never cut anything.
# ===========================================================================
set -uo pipefail

# ---------------------------------------------------------------------------
# WHICH CLUSTER. Asserted, never inherited. See lib/require-cluster.sh for
# why this is a mechanism rather than a line in the README.
#
# The `|| exit 1` is load-bearing: these scripts run under `set -u` without
# `-e`, so a missing or unreadable helper would otherwise print a warning and
# let the script continue UNGUARDED -- a guard that fails open is worse than
# none, because it is also reassuring.
# ---------------------------------------------------------------------------
. "$(dirname "$0")/lib/require-cluster.sh" || exit 1


TIER="${1:-}"
ACTION="${2:-status}"
NS="${3:-openddil}"
POLICY="openddil-sever-${TIER}"

# ---------------------------------------------------------------------------
# TWO MODES, BECAUSE A LEAF AND AN INTERMEDIATE DIFFER
# ---------------------------------------------------------------------------
# For a LEAF, "cut from the parent" and "cut from everything above" are the
# same policy, and this script only ever had one.
#
# For an INTERMEDIATE they are different, and the difference is not academic:
# a region with its children also cut renders, ON ITS OWN SCREEN, exactly like
# a region serving its own data with its children attached. Its rollups drift
# down as edges stop arriving while the panel stays green and fresh. The
# failure would be invisible at precisely the surface the test watches.
#
#   --from-parent  cut the tier's UPLINK; its subtree stays attached.
#                  The default, because it is the scenario that names a
#                  DDIL event: the link to higher echelon is lost and the
#                  tier keeps serving the subtree it is responsible for.
#   --isolate      cut everything, subtree included. A site-loss scenario.
#
# A leaf has no subtree, so the two modes render identically there — which is
# correct, and is why the flag is not restricted to intermediates.
MODE="from-parent"
for arg in "$@"; do
  case "$arg" in
    --from-parent) MODE="from-parent" ;;
    --isolate)     MODE="isolate" ;;
    --dry-run)     DRY_RUN=1 ;;
    --restart-relay-on-heal) RESTART_RELAY=1 ;;
  esac
done
DRY_RUN="${DRY_RUN:-0}"
RESTART_RELAY="${RESTART_RELAY:-0}"

# ---------------------------------------------------------------------------
# --restart-relay-on-heal -- OPT-IN, OFF BY DEFAULT, and here is why it exists
# ---------------------------------------------------------------------------
# `on` already restarts the site so open flows re-establish under the policy.
# `off` had no counterpart, and the asymmetry has a measurable cost.
#
# The relay cannot buffer: redpanda-connect EXITS at startup when it cannot
# initialise its Kafka output, so a severed relay crash-loops rather than
# waiting. Kubernetes backs that off 10 -> 20 -> 40 -> 80 -> 160 -> 300s and
# CAPS AT 300s, and a container in backoff does not retry when the network
# returns -- it waits out the timer it is already in.
#
# Measured 2026-09-19: the relay's last failed run ended 15:56:10Z and it
# started successfully at 16:01:21Z, a 311s gap that is the cap plus
# scheduling. The heal landed at roughly 16:00:45, about 25-45s before that
# timer expired, so the relay returned 36s later BY COINCIDENCE OF TIMING
# rather than by reacting to anything. Had the heal landed just after the
# 15:56:10 crash, the relay would have sat idle for a further five minutes
# over a perfectly healthy network.
#
# So heal-to-fresh is 0-300s depending only on where the heal falls inside a
# backoff window nobody controls. Deleting the relay pod clears the backoff
# and makes the figure a property of the system instead of the clock.
#
# WHY OFF BY DEFAULT. The default path is what the severance test measures,
# and the 300s worst case is a REAL property of this deployment. Turning the
# restart on by default would improve the demo by hiding the finding, which
# is the move this corpus exists to refuse. The flag makes the choice
# explicit and the readiness doc records BOTH numbers.

if [ -z "$TIER" ]; then
  echo "usage: $0 <tier-id> on|off|status [namespace] [--from-parent|--isolate] [--dry-run]" >&2
  echo "" >&2
  echo "  --from-parent  (default) cut the uplink; the subtree stays attached" >&2
  echo "  --isolate      cut everything, subtree included" >&2
  echo "  --dry-run      render the policy and print it; apply nothing" >&2
  echo "  --restart-relay-on-heal   on 'off', also restart this tier's relay" >&2
  echo "                 so heal-to-fresh does not wait out a CrashLoopBackOff" >&2
  echo "                 window of up to 300s. OFF by default: the default IS" >&2
  echo "                 the measurement, and the worst case is a real property" >&2
  echo "" >&2
  echo "  LOG IN BEFORE YOU CUT. Keycloak runs at the ROOT, so a severed tier" >&2
  echo "  cannot mint new sessions -- an existing cookie keeps working for its" >&2
  echo "  TTL, a fresh login does not. Open and authenticate every screen the" >&2
  echo "  demonstration will use BEFORE the first cut, or the recording shows" >&2
  echo "  an identity outage nobody intended to demonstrate." >&2
  exit 2
fi

# --- site membership, discovered from the cluster, never hardcoded ---------
mapfile -t SITE < <(
  kubectl get pods -n "$NS" \
    -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/component}{"\n"}{end}' \
    2>/dev/null | grep -F "$TIER" | sort -u | grep -v "^$"
)

if [ "${#SITE[@]}" -eq 0 ]; then
  echo "FAIL: no pods carry a component label containing '$TIER'." >&2
  echo "      Refusing to apply a policy that would select NOTHING and" >&2
  echo "      report a successful sever having cut zero pods." >&2
  exit 1
fi

# Non-vacuity floor: a site without its broker or its store is not a site,
# and a policy built from a partial discovery would leave the missing pods
# fully connected while still reporting the site isolated.
for required in "redpanda-${TIER}" "tier-pg-${TIER}" "tier-cm-${TIER}"; do
  if ! grep -qx "$required" <<<"$(printf '%s\n' "${SITE[@]}")"; then
    echo "FAIL: site discovery found ${#SITE[@]} component(s) but not" >&2
    echo "      '$required'. An incomplete site leaves pods connected and" >&2
    echo "      still reports a sever. Is the tier deployed?" >&2
    exit 1
  fi
done

status() {
  if kubectl get networkpolicy "$POLICY" -n "$NS" >/dev/null 2>&1; then
    echo "SEVERED — policy $POLICY applied to ${#SITE[@]} site component(s)"
  else
    echo "connected — no policy $POLICY"
  fi
  printf '  site (%d): %s\n' "${#SITE[@]}" "${SITE[*]}"
}

# --- two-sided reachability control ---------------------------------------
# Run from inside a site pod. Python, because the service images have it and
# a shell with neither nc nor curl is common in slim images.
probe() {  # probe <host> <port> -> OPEN | SHUT
  kubectl exec -n "$NS" "deploy/openddil-tier-cm-${TIER}" -- \
    python -c "
import socket
s = socket.socket(); s.settimeout(4)
try:
    s.connect(('$1', $2)); print('OPEN')
except Exception:
    print('SHUT')
" 2>/dev/null | tr -d '\r' | tail -1
}

ROOT_HOST="openddil-postgres-hq"; ROOT_PORT=5432
SITE_HOST="openddil-tier-pg-${TIER}"; SITE_PORT=5432

# ---------------------------------------------------------------------------
# THE SUBTREE, discovered from what is deployed
# ---------------------------------------------------------------------------
# A child's bridge config names its parent's broker, so the set of tiers whose
# bridge points at THIS tier is exactly this tier's children. Read from the
# cluster rather than from a values file, for the same reason site membership
# is: the question is what is running, not what was declared.
#
# Empty for a leaf, which is why --from-parent and --isolate render the same
# policy there.
CHILD_BRIDGES=()
while IFS= read -r line; do
  [ -n "$line" ] && CHILD_BRIDGES+=("$line")
done < <(
  kubectl get cm -n "$NS" -o name 2>/dev/null     | sed -n 's|.*/openddil-edge-hq-bridge-config-||p'     | while IFS= read -r child; do
        [ -z "$child" ] && continue
        # A TIER IS NOT ITS OWN CHILD. A bridge config names its own broker on
        # the INPUT side and its parent's on the OUTPUT side, so a bare match
        # finds the tier itself and calls it a child of itself. Same shape as
        # the self-parent `bridgeTarget` refused when the tier list was built:
        # a relation that must be irreflexive, discovered from a string that
        # appears on both ends of it.
        #
        # Left in, edge-01 would have reported a one-member subtree and its
        # two modes would have rendered differently -- a leaf pretending to
        # have dependants.
        [ "$child" = "$TIER" ] && continue
        if kubectl get cm -n "$NS" "openddil-edge-hq-bridge-config-$child"              -o "jsonpath={.data.connect\.yaml}" 2>/dev/null              | grep -q -- "-redpanda-${TIER}:"; then
          echo "edge-hq-bridge-$child"
        fi
      done
)

render_policy() {
  local sel=""
  local c
  for c in "${SITE[@]}"; do
    sel="${sel}                - ${c}"$'\n'
  done
  # In from-parent mode the children stay reachable; in isolate mode they do
  # not. Rendered into the SAME allow-list the simulators use, so there is one
  # place a pod can be permitted and no second mechanism to forget.
  if [ "$MODE" = "from-parent" ] && [ "${#CHILD_BRIDGES[@]}" -gt 0 ]; then
    for c in "${CHILD_BRIDGES[@]}"; do
      [ -n "$c" ] && sel="${sel}                - ${c}
"
    done
  fi
  cat <<EOF
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: ${POLICY}
  namespace: ${NS}
  annotations:
    openddil.io/purpose: >-
      Test-only isolation of tier ${TIER} from the root. Default-deny in
      both directions; same-site and DNS allowed; the central simulators
      are allowed in because they stand in for on-site sensors.
spec:
  podSelector:
    matchExpressions:
      - key: app.kubernetes.io/component
        operator: In
        values:
${sel}  policyTypes: [Ingress, Egress]
  ingress:
    - from:
        - podSelector:
            matchExpressions:
              - key: app.kubernetes.io/component
                operator: In
                values:
${sel}    - from:
        - podSelector:
            matchExpressions:
              - key: app.kubernetes.io/component
                operator: In
                values:
                - logistics-sim
                - dis-sim-edge-northpoint
                - dis-sim-edge-capeverdant
  egress:
    - to:
        - podSelector:
            matchExpressions:
              - key: app.kubernetes.io/component
                operator: In
                values:
${sel}    - ports:
        - {protocol: UDP, port: 53}
        - {protocol: TCP, port: 53}
EOF
}

# The tier's own outbound relay. Leaves carry `edge-hq-bridge-<id>`;
# an intermediate carries `tier-uplink-<id>`. Probed rather than assumed, so
# a tier kind this script has not met yet reports "none found" instead of
# silently restarting nothing while claiming it did.
relay_components() {
  for c in "edge-hq-bridge-${TIER}" "tier-uplink-${TIER}"; do
    if kubectl get pods -n "$NS" -l "app.kubernetes.io/component=$c"          --no-headers 2>/dev/null | grep -q .; then
      echo "$c"
    fi
  done
}

# ---------------------------------------------------------------------------
# DRY RUN. Render and print; apply nothing, restart nothing, probe nothing.
# ---------------------------------------------------------------------------
# This script deletes pods and applies a default-deny policy. An edit to it
# that is wrong is wrong DURING a sever, when half the site is restarting --
# which is how a previous attempt left `${child_sel}` referenced and
# undefined, a failure that would have surfaced under `set -u` at apply time
# and not before. So the render is inspectable without consequences, and the
# operator can read the allow-list before trusting it.
if [ "$DRY_RUN" = "1" ]; then
  echo "DRY RUN — mode=$MODE, nothing will be applied"
  printf '  site (%d): %s
' "${#SITE[@]}" "${SITE[*]}"
  if [ "${#CHILD_BRIDGES[@]}" -gt 0 ]; then
    printf '  subtree (%d): %s
' "${#CHILD_BRIDGES[@]}" "${CHILD_BRIDGES[*]}"
    if [ "$MODE" = "from-parent" ]; then
      echo "  -> subtree STAYS ATTACHED (--from-parent)"
    else
      echo "  -> subtree IS CUT (--isolate)"
    fi
  else
    echo "  subtree: none — this tier is a leaf, so both modes are identical"
  fi
  echo
  if [ "$RESTART_RELAY" = "1" ]; then
    _rc="$(relay_components)"
    if [ -n "$_rc" ]; then
      printf '  on heal, WOULD restart relay: %s
' "$(echo "$_rc" | tr '
' ' ')"
    else
      echo "  on heal, --restart-relay-on-heal is set but NO relay component"
      echo "  was found for ${TIER} — the step would do nothing. Fix the tier"
      echo "  id or drop the flag rather than reading a silent no-op as a heal."
    fi
    echo
  fi
  render_policy
  exit 0
fi


case "$ACTION" in
  status)
    status
    ;;

  on)
    before_root="$(probe "$ROOT_HOST" "$ROOT_PORT")"
    if [ "$before_root" != "OPEN" ]; then
      echo "FAIL: the root is ALREADY unreachable from the site before any" >&2
      echo "      policy was applied (got '${before_root:-no answer}')." >&2
      echo "      A sever proves nothing when the link was already down." >&2
      exit 1
    fi

    if ! render_policy | kubectl apply -f - >/dev/null; then
      echo "FAIL: policy apply rejected" >&2
      exit 1
    fi
    sleep 3

    # Force every flow to re-establish under the policy. Without this the
    # policy is applied and the traffic continues; see the header.
    join="$(printf '%s,' "${SITE[@]}")"; join="${join%,}"
    echo "  restarting ${#SITE[@]} site pod(s) so open connections re-establish under the policy"
    kubectl delete pod -n "$NS"       -l "app.kubernetes.io/component in (${join})" --wait=false >/dev/null 2>&1

    # Wait for the site to come back, or the measurements that follow are
    # of a site that is down rather than a site that is isolated.
    #
    # TWO EXCLUSIONS, and the second is the interesting one:
    #   * Completed pods (finished Jobs) are not workloads and never
    #     become Ready.
    #   * THE BRIDGE IS EXPECTED TO FAIL. Its entire job is to cross the
    #     boundary this policy closes, so under a real sever it cannot
    #     start. Requiring the WHOLE site to be healthy contradicts what
    #     the test is for -- the first version of this gate did exactly
    #     that and reported "site did not return to Ready" about a site
    #     that was 13/14 up and behaving correctly.
    deadline=$(( $(date +%s) + 300 ))
    while :; do
      notready="$(kubectl get pods -n "$NS"         -l "app.kubernetes.io/component in (${join})"         --no-headers 2>/dev/null         | grep -v "Completed"         | grep -v "edge-hq-bridge"         | grep -vc " Running")"
      [ "${notready:-1}" -eq 0 ] && break
      if [ "$(date +%s)" -gt "$deadline" ]; then
        echo "FAIL: the site did not return to Ready within 300s" >&2
        echo "      (${notready} serving pod(s) still not Running)." >&2
        echo "      Refusing to measure a severed site that is also down:" >&2
        echo "      a frozen tier would then be this, not a finding." >&2
        kubectl get pods -n "$NS" -l "app.kubernetes.io/component in (${join})"           --no-headers 2>/dev/null | grep -v "Completed" | grep -v " Running" >&2
        exit 1
      fi
      sleep 6
    done
    echo "  site serving pods are Ready again, isolated"

    # CORROBORATION, not a requirement: the bridge SHOULD be unhealthy.
    # If it is happily Running while the site is severed, it is still
    # reaching HQ and the cut is not what it claims.
    bstate="$(kubectl get pods -n "$NS" -l app.kubernetes.io/component=edge-hq-bridge-${TIER}                 --no-headers 2>/dev/null | grep -v Completed | awk '{print $3}' | head -1)"
    case "${bstate:-missing}" in
      Running) echo "  note: the bridge is Running — checked seconds after restart, so" ;
               echo "        it may simply not have failed its first publish yet. Only" ;
               echo "        a bridge still Running LATE in the dwell means it is still" ;
               echo "        reaching HQ; assertion (c) is what settles that." ;;
      *)       echo "  ok: the bridge is ${bstate:-absent}, as a severed bridge should be" ;;
    esac

    r="$(probe "$ROOT_HOST" "$ROOT_PORT")"
    s="$(probe "$SITE_HOST" "$SITE_PORT")"
    echo "sever ${TIER}: root ${ROOT_HOST}:${ROOT_PORT} -> ${r:-?}   site ${SITE_HOST}:${SITE_PORT} -> ${s:-?}"

    if [ "$r" = "SHUT" ] && [ "$s" = "OPEN" ]; then
      echo "SEVERED and PROVEN — root unreachable, site intact (${#SITE[@]} components)"
      exit 0
    fi
    echo "FAIL: the sever is not what it claims." >&2
    if [ "$r" != "SHUT" ]; then
      echo "      Root is STILL REACHABLE. Either the CNI does not enforce" >&2
      echo "      NetworkPolicy — in which case every 'severance' result" >&2
      echo "      from this cluster is void — or the site selector missed" >&2
      echo "      the pod that carries the traffic." >&2
    fi
    if [ "$s" != "OPEN" ]; then
      echo "      The site cannot reach ITSELF. That is an outage, not an" >&2
      echo "      isolation, and any 'tier frozen' reading taken now would" >&2
      echo "      be this policy rather than a finding about the tier." >&2
    fi
    exit 1
    ;;

  off)
    kubectl delete networkpolicy "$POLICY" -n "$NS" --ignore-not-found >/dev/null
    sleep 5
    r="$(probe "$ROOT_HOST" "$ROOT_PORT")"
    echo "heal ${TIER}: root ${ROOT_HOST}:${ROOT_PORT} -> ${r:-?}"
    if [ "$r" = "OPEN" ]; then
      if [ "$RESTART_RELAY" = "1" ]; then
        _rc="$(relay_components)"
        if [ -z "$_rc" ]; then
          echo "  note: --restart-relay-on-heal set, but no relay component was"
          echo "        found for ${TIER}. NOTHING WAS RESTARTED — do not read"
          echo "        the heal figure below as the with-restart number."
        else
          _join="$(echo "$_rc" | tr '
' ',')"; _join="${_join%,}"
          echo "  restarting relay (${_join}) so heal does not wait out a"
          echo "  CrashLoopBackOff window of up to 300s"
          kubectl delete pod -n "$NS"             -l "app.kubernetes.io/component in (${_join})" --wait=false >/dev/null 2>&1
        fi
      fi
      echo "HEALED and PROVEN — root reachable again"
      exit 0
    fi
    echo "FAIL: root still unreachable after removing the policy." >&2
    exit 1
    ;;

  *)
    echo "usage: $0 <tier-id> on|off|status [namespace]" >&2
    exit 2
    ;;
esac
