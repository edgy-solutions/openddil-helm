#!/usr/bin/env bash
# ===========================================================================
# check-service-routing.sh — does every node route a NEW Service?
# ===========================================================================
# Usage: check-service-routing.sh [namespace]
#   namespace  where the throwaway probe objects go (default: openddil-preflight;
#              created and deleted by this script if it does not exist)
#   PROBE_IMAGE      busybox-compatible image (default busybox:1.36); point it at
#                    an image the nodes already hold on an air-gapped cluster
#   PROBE_WINDOW_S   how long each node gets to program the new Service (default 75)
#
# WHY THIS EXISTS. A node whose kube-proxy cannot apply its rules keeps the OLD
# rules and keeps reporting Ready. Every pod on it stays Running. Services
# whose endpoints did not move keep working from it. Only Services whose pods
# were REPLACED become unreachable, and only from that node. A helm upgrade
# replaces exactly those pods, so the first thing to notice is a post-upgrade
# hook Job that happens to land on the node: it times out with EHOSTUNREACH,
# helm reports "post-upgrade hooks failed", and the fault reads as a chart
# failure. It took two hours to see it was not one.
#
# One way to get there: kube-proxy's iptables-restore fails with "sendmsg()
# failed: Message too long" because the node cannot raise its netlink send
# buffer (unprivileged containers as nodes). Partial syncs fit and full syncs
# do not, so a node is fine until the first large change and then is stuck
# for good, and restarting the agent forces a full sync. This script does not
# care about the cause; it tests the symptom.
#
# WHAT IT DOES. It creates a brand-new Service with one brand-new endpoint, so
# every node's kube-proxy has to program rules it has never had. Then it runs
# one probe pod pinned to each Ready node. Each probe tries the Service
# ClusterIP and, as a control, the target pod's IP directly:
#   VIP ok                    node routes Services
#   VIP FAIL, pod IP ok       STALE SERVICE ROUTING on that node: the fault above
#   VIP FAIL, pod IP FAIL     pod network fault on that node (a different fault)
# A probe on a pinned node that never reports is also a FAIL. Zero nodes probed
# is a FAIL, not a pass.
#
# Run it before every upgrade, reset or recording. Exit 0 = every node routes;
# exit 1 = a node does not (named), or the check could not run.
set -uo pipefail

NS="${1:-openddil-preflight}"
IMAGE="${PROBE_IMAGE:-busybox:1.36}"
WINDOW="${PROBE_WINDOW_S:-75}"
RUN="rt-$(date +%s)"
LBL="openddil.io/preflight=service-routing"
created_ns=0

cleanup() {
  if [ "$created_ns" -eq 1 ]; then
    kubectl delete ns "$NS" --wait=false >/dev/null 2>&1
  else
    kubectl -n "$NS" delete pod,svc -l "$LBL" --wait=false >/dev/null 2>&1
  fi
}
trap cleanup EXIT

if ! kubectl get ns "$NS" >/dev/null 2>&1; then
  kubectl create ns "$NS" >/dev/null || { echo "cannot create namespace $NS"; exit 1; }
  created_ns=1
fi

# The target: a fresh pod behind a fresh Service. Fresh is the point -- a
# Service every node already knows proves nothing about a node that stopped
# learning.
kubectl -n "$NS" apply -f - >/dev/null <<EOF || { echo "cannot create probe target"; exit 1; }
apiVersion: v1
kind: Pod
metadata:
  name: $RUN-target
  labels: {openddil.io/preflight: service-routing, run: $RUN}
spec:
  tolerations: [{operator: Exists}]
  containers:
    - name: httpd
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command: [sh, -c, 'echo routed > /tmp/index.html && exec httpd -f -p 8080 -h /tmp']
      ports: [{containerPort: 8080}]
      readinessProbe: {tcpSocket: {port: 8080}, periodSeconds: 2}
---
apiVersion: v1
kind: Service
metadata:
  name: $RUN
  labels: {openddil.io/preflight: service-routing}
spec:
  selector: {run: $RUN}
  ports: [{port: 8080, targetPort: 8080}]
EOF

if ! kubectl -n "$NS" wait pod/"$RUN-target" --for=condition=Ready --timeout=120s >/dev/null 2>&1; then
  echo "probe target never became Ready (image $IMAGE pullable?) -- check did not run"
  exit 1
fi
VIP=$(kubectl -n "$NS" get svc "$RUN" -o jsonpath='{.spec.clusterIP}')
PIP=$(kubectl -n "$NS" get pod "$RUN-target" -o jsonpath='{.status.podIP}')
TNODE=$(kubectl -n "$NS" get pod "$RUN-target" -o jsonpath='{.spec.nodeName}')
echo "new Service $RUN  VIP $VIP  ->  pod $PIP on $TNODE"

nodes=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 ~ /^Ready/ {print $1}')
if [ -z "$nodes" ]; then echo "no Ready nodes listed -- check did not run"; exit 1; fi

# Each probe retries the VIP for the whole window, which spans more than one
# kube-proxy retry period, so a slow node is not mistaken for a stuck one.
tries=$(( WINDOW / 3 ))
for n in $nodes; do
  kubectl -n "$NS" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: $RUN-$(printf '%s' "$n" | tr -c 'a-z0-9-' '-' | cut -c1-40)
  labels: {openddil.io/preflight: service-routing, probe: $RUN}
  annotations: {openddil.io/node: "$n"}
spec:
  nodeName: $n
  restartPolicy: Never
  tolerations: [{operator: Exists}]
  containers:
    - name: probe
      image: $IMAGE
      imagePullPolicy: IfNotPresent
      command:
        - sh
        - -c
        - |
          vip=FAIL; i=0
          while [ \$i -lt $tries ]; do
            if wget -T 2 -q -O - http://$VIP:8080/ 2>/dev/null | grep -q routed; then vip="ok after \$((i*3))s"; break; fi
            i=\$((i+1)); sleep 3
          done
          pip=FAIL
          wget -T 3 -q -O - http://$PIP:8080/ 2>/dev/null | grep -q routed && pip=ok
          echo "RESULT vip=\$vip pip=\$pip"
EOF
done

deadline=$(( $(date +%s) + WINDOW + 60 ))
expected=$(printf '%s\n' $nodes | wc -l | tr -d ' ')
while :; do
  done_n=$(kubectl -n "$NS" get pods -l "probe=$RUN" --no-headers 2>/dev/null | awk '$3=="Completed"||$3=="Error"' | wc -l | tr -d ' ')
  [ "$done_n" -ge "$expected" ] && break
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 5
done

fail=0; probed=0
printf '%-28s %-16s %s\n' NODE VIP POD-IP
for p in $(kubectl -n "$NS" get pods -l "probe=$RUN" -o name); do
  n=$(kubectl -n "$NS" get "$p" -o jsonpath='{.metadata.annotations.openddil\.io/node}')
  r=$(kubectl -n "$NS" logs "$p" 2>/dev/null | grep '^RESULT' | tail -1)
  if [ -z "$r" ]; then
    printf '%-28s %-16s %s\n' "$n" "NO REPORT" "-"; fail=1; continue
  fi
  probed=$((probed+1))
  vip=$(printf '%s' "$r" | sed -n 's/.*vip=\(.*\) pip=.*/\1/p')
  pip=$(printf '%s' "$r" | sed -n 's/.*pip=\(.*\)$/\1/p')
  verdict=""
  case "$vip" in
    ok*) ;;
    *) fail=1
       if [ "$pip" = ok ]; then verdict="  <- STALE SERVICE ROUTING (kube-proxy not applying rules on this node)"
       else verdict="  <- POD NETWORK FAULT (pod IP unreachable too)"; fi ;;
  esac
  printf '%-28s %-16s %s%s\n' "$n" "$vip" "$pip" "$verdict"
done

if [ "$probed" -lt 1 ]; then echo "0 nodes probed -- check did not run"; exit 1; fi
if [ "$probed" -lt "$expected" ]; then fail=1; fi
echo
[ "$fail" -eq 0 ] && echo "service routing: $probed/$expected nodes ok" \
                  || echo "service routing: FAILED ($probed/$expected nodes reported)"
exit "$fail"
