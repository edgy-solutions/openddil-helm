#!/usr/bin/env bash
# compose-kubectl-shim.sh -- a sourced `kubectl` function that answers the
# specific calls the writer census, bridge graph, and phase-4 restore reads
# make (see reset-scenario.sh: declared_consumers/declared_producers,
# bridge_graph, topic_partitions/consume_from_hw, and the replicas/scale
# helpers) by talking to the openddil-demo docker compose stack instead of a
# real cluster.
#
# Usage: source this file AFTER setting NS/RELEASE the same way
# reset-scenario.sh would (NS is unused by compose but kept so call sites
# don't need to change; RELEASE defaults to "openddil", matching reset-
# scenario.sh's own default), then run reset-scenario.sh's
# --writer-census-only or a quiesce/settle pass with this `kubectl`
# function in scope instead of the real binary. It is a test/dev aid, not
# a cluster client -- it never touches a real Kubernetes API.
#
# It is "good enough" for --writer-census-only and a quiesce/settle run
# against openddil-demo's compose stack. It is NOT a general kubectl replacement -- see "WHAT THIS
# DOES NOT COVER" at the bottom before relying on it for anything else.
#
# WARNING: this `kubectl` function shells out to the REAL `docker` binary
# on PATH. If a real openddil-demo compose stack happens to be up wherever
# this is sourced, "exec"/"scale" calls run against those REAL containers
# (docker exec / docker stop / docker start) -- there is no dry-run mode.
# Only source this somewhere you have confirmed is the disposable compose
# stack you mean to drive, never near a stack you did not start yourself
# for this purpose.

# ---------------------------------------------------------------------------
# Pod -> compose service map
#
# reset-scenario.sh names redpanda pods "${RELEASE}-redpanda-<broker-id>-0".
# The openddil-demo compose stack's broker services are:
#
#   broker-id   compose service     notes
#   ---------   -----------------   --------------------------------------
#   edge-01     redpanda-edge-01
#   edge-02     redpanda-edge-02
#   edge-03     redpanda-edge-03
#   hq          redpanda-hq
#
# There is no region-east / region-west broker service in compose (compare
# docker-compose.yml's faust-regional-east/-west, which run against the
# edge+hq brokers directly, "tier not managed" -- the lab's up-to-5-broker
# topology with a tier-managed region broker has no compose equivalent).
# A REDPANDA_PODS list built for compose must therefore only ever contain
# edge-01, edge-02, edge-03, hq.
#
# None of the compose services above declare an explicit `container_name:`,
# so their actual container names depend on the compose project name
# (directory-derived, no .env/COMPOSE_PROJECT_NAME override exists in
# openddil-demo) and on which compose CLI generation created them. Rather
# than hardcode a name, every lookup below resolves the live container via
# `docker ps` filtered on compose's own `com.docker.compose.service` label,
# which is stable across compose v1/v2 and any project name.
# ---------------------------------------------------------------------------

RELEASE="${RELEASE:-openddil}"

declare -A _COMPOSE_SERVICE_OF_BROKER=(
  [edge-01]=redpanda-edge-01
  [edge-02]=redpanda-edge-02
  [edge-03]=redpanda-edge-03
  [hq]=redpanda-hq
)

# The three bridges compose actually runs, and the source broker-id each
# one reads from -- a fixed, small table (3 rows, one per compose bridge
# service), not a re-derivation of the chart's consumer-groups annotation
# (compose has no annotation to read; see "WHAT THIS DOES NOT COVER").
declare -A _COMPOSE_BRIDGE_SRC=(
  [edge-hq-bridge-01]=edge-01
  [edge-hq-bridge-02]=edge-02
  [edge-hq-bridge-03]=edge-03
)

declare -A _SHIM_WARNED=()   # de-dupe the "unhandled call" stderr note

_shim_warn_once() {
  local key="$1"
  [ -n "${_SHIM_WARNED[$key]:-}" ] && return 0
  _SHIM_WARNED[$key]=1
  echo "compose-kubectl-shim: $2" >&2
}

# _compose_container_for SERVICE -- the live container name for a compose
# service, resolved by label rather than by guessing the project-name
# prefix. Empty if the service isn't running.
_compose_container_for() {
  docker ps --filter "label=com.docker.compose.service=$1" \
    --format '{{.Names}}' 2>/dev/null | head -1
}

# _compose_container_for_pod POD -- POD is "${RELEASE}-redpanda-<id>-0" or
# a bridge/other workload name already matching a compose service key.
_compose_container_for_broker() {
  local id="$1" svc="${_COMPOSE_SERVICE_OF_BROKER[$1]:-}"
  [ -z "$svc" ] && return 1
  _compose_container_for "$svc"
}

kubectl() {
  local argstr="$*"

  case "$argstr" in
    # ---- kubectl exec -n NS <broker pod> -c redpanda -- rpk ... --------
    *"exec -n "*" -c redpanda -- rpk "*)
      local pod id container
      # argv form: exec -n NS <pod> -c redpanda -- rpk ARGS...
      pod=""
      local i=0 n=$#
      local -a args=("$@")
      for ((i=0; i<n; i++)); do
        if [ "${args[$i]}" = "-c" ] && [ "${args[$((i+1))]:-}" = "redpanda" ]; then
          pod="${args[$((i-1))]}"
          break
        fi
      done
      id="${pod#${RELEASE}-redpanda-}"; id="${id%-0}"
      container="$(_compose_container_for_broker "$id")"
      if [ -z "$container" ]; then
        _shim_warn_once "rpk:$id" "no running container for broker '$id' (pod $pod) -- returning empty"
        return 0
      fi
      # Find "rpk" in argv and exec everything from there on, inside the
      # resolved container.
      local -a rpk_args=()
      local seen=0
      for ((i=0; i<n; i++)); do
        if [ "$seen" = 1 ]; then
          rpk_args+=("${args[$i]}")
        elif [ "${args[$i]}" = "rpk" ]; then
          seen=1
        fi
      done
      docker exec "$container" rpk "${rpk_args[@]}"
      return $?
      ;;

    # ---- kubectl get cm -n NS ${RELEASE}-toxiproxy-config -o jsonpath=... .data.toxiproxy\.json
    *"get cm -n "*"toxiproxy-config"*)
      local container
      container="$(_compose_container_for toxiproxy)"
      if [ -z "$container" ]; then
        _shim_warn_once "toxiproxy-cm" "no running toxiproxy container -- returning empty config"
        return 0
      fi
      docker exec "$container" cat /etc/toxiproxy.json
      return $?
      ;;

    # ---- kubectl get deploy,statefulset -n NS -o jsonpath=...consumer-groups...env... (bridge_graph)
    # Distinguished from the plain declared_consumers/declared_producers
    # call (same "get deploy,statefulset" prefix) by the trailing
    # containers[0].env range bridge_graph's jsonpath adds.
    *"get deploy,statefulset -n "*"containers[0].env"*)
      local b src dest_host dest_port
      for b in "${!_COMPOSE_BRIDGE_SRC[@]}"; do
        local container
        container="$(_compose_container_for "$b")"
        [ -z "$container" ] && continue
        src="${_COMPOSE_BRIDGE_SRC[$b]}"
        # The bridge containers are Redpanda Connect, configured from a
        # mounted YAML (redpanda-connect-edge-0N.yaml), not DEST_HOST/
        # DEST_PORT env vars -- those are the chart's own env names for its
        # own bridge Deployment, which compose does not run. We already
        # know which broker each compose bridge reads from (the table
        # above) and which it writes to (always hq, per docker-compose.yml);
        # emit a synthetic env line downstream code can parse the same way,
        # using hq's own broker/port naming so bridge_graph's "is this a
        # known broker service" check still matches.
        printf 'Deployment/%s\topenddil/%s-bridge\tDEST_HOST=%s-redpanda-hq|DEST_PORT=9092|\n' \
          "$b" "$src" "$RELEASE"
      done
      _shim_warn_once "bridge-graph-synth" "bridge_graph: compose has no consumer-groups/env annotations; emitting a synthesized 3-row edge-0N->hq table from the known compose bridge topology, not read from any chart annotation"
      return 0
      ;;

    # ---- kubectl get deploy,statefulset -n NS -o jsonpath=...consumer-groups... (declared_consumers)
    # ---- kubectl get deploy,statefulset -n NS -o jsonpath=...produces-topics... (declared_producers)
    *"get deploy,statefulset -n "*)
      _shim_warn_once "declared-annotations" "declared_consumers/declared_producers: compose services carry no openddil.io/consumer-groups or openddil.io/produces-topics annotation equivalent -- returning empty (every live topic/group will read as undeclared)"
      return 0
      ;;

    # ---- kubectl get deploy -n NS NAME -o jsonpath='{.spec.replicas}'
    *"get deploy -n "*"jsonpath="*".spec.replicas"*)
      # argv form: get(0) deploy(1) -n(2) NS(3) NAME(4) -o(5) jsonpath=...(6)
      local -a args=("$@")
      local svc_name="${args[4]}"
      local container
      container="$(_compose_container_for "$svc_name" 2>/dev/null)"
      if [ -z "$container" ]; then
        # Fall back: treat the deploy name's compose-service form (strip a
        # leading "${RELEASE}-" if present) for workloads whose k8s name
        # doesn't match its compose service name 1:1.
        container="$(_compose_container_for "${svc_name#${RELEASE}-}" 2>/dev/null)"
      fi
      if [ -n "$container" ] && [ "$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null)" = "true" ]; then
        printf '1'
      else
        printf '0'
      fi
      return 0
      ;;

    # ---- kubectl scale deploy|statefulset -n NS NAME --replicas=N --------
    *"scale "*"--replicas="*)
      local -a args=("$@")
      local svc_name="" replicas=""
      local i
      for ((i=0; i<$#; i++)); do
        case "${args[$i]}" in
          --replicas=*) replicas="${args[$i]#--replicas=}" ;;
        esac
      done
      # NAME is the positional right before --replicas=N, after -n NS.
      for ((i=0; i<$#; i++)); do
        if [ "${args[$i]}" = "-n" ]; then
          svc_name="${args[$((i+2))]}"
          break
        fi
      done
      local container
      container="$(_compose_container_for "$svc_name" 2>/dev/null)"
      [ -z "$container" ] && container="$(_compose_container_for "${svc_name#${RELEASE}-}" 2>/dev/null)"
      if [ -z "$container" ]; then
        _shim_warn_once "scale:$svc_name" "scale: no running container for '$svc_name' -- nothing to stop/start"
        return 0
      fi
      # Compose has no notion of a declarative replica COUNT for these
      # single-instance services -- only running/not-running. --replicas=0
      # maps to a stop; any other value maps to a start. See "WHAT THIS
      # DOES NOT COVER".
      if [ "$replicas" = "0" ]; then
        docker stop "$container" >/dev/null
      else
        docker start "$container" >/dev/null
      fi
      return $?
      ;;

    *)
      _shim_warn_once "unhandled:$1 $2 $3" "unhandled kubectl call ('$argstr') -- returning empty"
      return 0
      ;;
  esac
}

# ---------------------------------------------------------------------------
# WHAT THIS DOES NOT COVER
#
#  - No region-tier broker. compose only ever has edge-01/edge-02/edge-03/
#    hq redpanda services; there is no redpanda-region-east/-west, unlike
#    the lab's up-to-5-broker, tier-managed-region topology. REDPANDA_PODS
#    built against this shim must stay within the 4 brokers above.
#
#  - declared_consumers()/declared_producers() return EMPTY, always.
#    compose services carry no openddil.io/consumer-groups or
#    openddil.io/produces-topics annotation (or any label standing in for
#    one) -- there is nothing in the compose files for a kubectl jsonpath
#    read to find. Any writer-census run against compose will therefore
#    report every live topic/group as undeclared (phase3b_writer_census's
#    PRODUCER_OWNER/consumer-ownership lookups stay empty), which is a
#    correct reflection of what compose actually exposes, not a bug in the
#    shim -- but it means --writer-census-only against compose cannot be
#    used to prove a real "all declared" pass, only to exercise the code
#    path and the undeclared-halt behavior.
#
#  - bridge_graph()'s DEST_HOST/DEST_PORT/src-broker-id edges are
#    SYNTHESIZED from a fixed 3-row table (the three compose
#    edge-hq-bridge-0N services, each hardcoded to source from its
#    matching edge broker and land on hq), not read from any compose
#    data -- the real edge-hq-bridge containers are Redpanda Connect
#    processes configured from a mounted YAML file, not DEST_HOST/
#    DEST_PORT env vars, and carry no consumer-groups annotation to read a
#    source broker-id from either. If openddil-demo's bridge topology ever
#    changes (a new bridge, a different source/destination), this table
#    goes stale silently -- it is not derived from the compose files, so
#    nothing will flag the drift.
#
#  - toxiproxy's config IS read for real (docker exec into the toxiproxy
#    container and cat the mounted /etc/toxiproxy.json), since that part
#    of bridge_graph has a direct compose equivalent.
#
#  - "scale --replicas=N" only ever stops (N=0) or starts (N!=0) the
#    container; compose's single-instance services have no multi-replica
#    scaling semantics, so N is otherwise ignored. The replicas readback
#    (`get deploy ... jsonpath='{.spec.replicas}'`) mirrors this: it
#    reports 1 if the container is running, 0 otherwise, never any other
#    value -- callers that compare an exact previous replica count (e.g.
#    restoring "3" after a scale-to-0) will restore to "running", not to
#    the original count.
#
#  - restate and postgres `kubectl exec` calls (phase-4's restate/postgres
#    reads) are NOT handled -- only four call shapes (rpk exec, deploy/
#    statefulset annotation+env jsonpath, toxiproxy-config cm jsonpath,
#    scale) are covered. Anything else falls through to the default case,
#    which logs one warning per distinct call and returns empty/success so
#    `set -e` callers don't abort, but does not fake an answer.
# ---------------------------------------------------------------------------
