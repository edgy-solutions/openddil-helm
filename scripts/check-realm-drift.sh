#!/usr/bin/env bash
# ===========================================================================
# check-realm-drift.sh -- do the identity pods agree on the realm they started from?
# ===========================================================================
# Usage: OPENDDIL_EXPECT_CONTEXT=<kube-context> KUBECONFIG=<file> \
#          check-realm-drift.sh [-n namespace]
#
# ADR-0045 (next increment, item 7). With every link up, exactly ONE realm
# version is expected across the root Keycloak and every tier Keycloak
# replica (§3): the realm is one realm, held in several places.
#
# WHAT IT READS: the openddil.io/realm-version pod annotation (the chart's
# digest of the realm INPUTS, see openddil.realmVersion) from every Running
# pod whose app.kubernetes.io/component is `keycloak` or `tier-keycloak-*`.
# It reads the inputs digest the pod was STARTED from, so a pod that has not
# rolled onto the current inputs is drift. It does not read the live realm.
#
# SEVERED TIERS: a tier is severed when NetworkPolicy openddil-sever-<tier>
# exists (sever-tier.sh's policy name). Its pods are listed apart and left
# out of the count: an older digest there is expected, not drift.
#
# Exit: 0 one distinct version across linked pods; 1 DRIFT (more than one);
#       2 no linked pod carries the annotation (replicas off, or the
#       annotation is missing); 3 refused (no cluster declared or wrong one).
# A Running pod without the annotation counts as its own value, `missing`.
# Read-only: nothing is written to the cluster.
set -u -o pipefail

NS="openddil"
if [ "${1:-}" = "-n" ]; then NS="${2:-}"; shift 2; fi
if [ -z "$NS" ]; then echo "usage: $0 [-n namespace]" >&2; exit 3; fi

# WHICH CLUSTER. Asserted, never inherited from current-context.
if [ -z "${KUBECONFIG:-}" ] || [ -z "${OPENDDIL_EXPECT_CONTEXT:-}" ]; then
  echo "REFUSING TO RUN: KUBECONFIG and OPENDDIL_EXPECT_CONTEXT must both be set." >&2
  exit 3
fi
ctx="$(kubectl config current-context 2>/dev/null)"
if [ "$ctx" != "$OPENDDIL_EXPECT_CONTEXT" ]; then
  echo "REFUSING TO RUN: current context is '${ctx}', expected '${OPENDDIL_EXPECT_CONTEXT}'." >&2
  exit 3
fi

# component <TAB> pod <TAB> version, Running pods only. A dot in an annotation
# key is escaped for jsonpath.
rows="$(kubectl -n "$NS" get pods --field-selector=status.phase=Running \
  -o jsonpath='{range .items[*]}{.metadata.labels.app\.kubernetes\.io/component}{"\t"}{.metadata.name}{"\t"}{.metadata.annotations.openddil\.io/realm-version}{"\n"}{end}')" || {
  echo "could not list pods in namespace '$NS'" >&2; exit 3; }

linked=(); severed=()
while IFS=$'\t' read -r comp pod ver; do
  case "$comp" in keycloak|tier-keycloak-*) ;; *) continue ;; esac
  [ -n "$ver" ] || ver="missing"
  if [[ "$comp" == tier-keycloak-* ]] && \
     kubectl -n "$NS" get networkpolicy "openddil-sever-${comp#tier-keycloak-}" >/dev/null 2>&1; then
    severed+=("$comp $pod $ver")
  else
    linked+=("$comp $pod $ver")
  fi
done <<< "$rows"

if [ "${#severed[@]}" -gt 0 ]; then
  echo "severed (an older digest is expected, not drift):"
  printf '  %s\n' "${severed[@]}"
fi
for l in ${linked[@]+"${linked[@]}"}; do echo "$l"; done

if [ "${#linked[@]}" -eq 0 ]; then
  echo "no linked identity pod found: identity.replica is off, or no Keycloak pod is Running" >&2
  exit 2
fi
carrying=0; for l in "${linked[@]}"; do [ "${l##* }" = "missing" ] || carrying=$((carrying+1)); done
if [ "$carrying" -eq 0 ]; then
  echo "no linked pod carries openddil.io/realm-version: identity.replica is off, or the annotation is missing" >&2
  exit 2
fi
n="$(printf '%s\n' "${linked[@]}" | awk '{print $NF}' | sort -u | wc -l | tr -d ' ')"
echo "distinct realm versions across linked identity pods: $n"
if [ "$n" -gt 1 ]; then echo "DRIFT"; exit 1; fi
exit 0
