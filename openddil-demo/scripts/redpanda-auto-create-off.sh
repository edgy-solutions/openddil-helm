#!/bin/sh
# redpanda-auto-create-off.sh — enforce, or assert, that
# auto_create_topics_enabled=false on every broker's Admin API.
#
# ONE SCRIPT, TWO CONSUMERS, SO THEY CANNOT DISAGREE:
#   1. The `{{ .Release.Name }}-redpanda-auto-create-off` post-install/
#      post-upgrade hook Job (templates/hook-redpanda-auto-create-off.yaml)
#      embeds this file verbatim via `.Files.Get`, and supplies BROKERS from
#      the chart's own tier list. This is the fix for FOLLOW-UPS.md "OPEN
#      2026-09-27 — auto_create_topics_enabled=false, as a revision 52 chart
#      change" on a cluster that already exists: infrastructure.yaml's
#      `--set redpanda.auto_create_topics_enabled=false` broker arg only
#      seeds this at FIRST cluster formation (fresh install / fresh emptyDir)
#      and does nothing on a PVC-backed cluster that formed before the flag
#      shipped.
#   2. A standalone red-check against a LIVE cluster, no chart
#      install/upgrade required — see INVOCATION below. Because it is the
#      same file, a red-check that fails here is not "the Job's script
#      diverged from what was tested."
#
# USAGE
#   BROKERS="host1:adminport host2:adminport ..." ASSERT_ONLY=0|1 sh redpanda-auto-create-off.sh
#
#   ASSERT_ONLY=1 skips the `rpk cluster config set` step (waits for the
#   Admin API and reads the property back only) — the red-check mode: a
#   broker still at Redpanda's default `true` reports FAIL, the summary
#   line is N/M with N < M, and the script exits nonzero.
#
# ADMIN PORTS (NOT the Kafka port): 9644 for edge/region brokers
# (redpandaEdge.adminPort), 19644 for hq (redpandaHq.adminPort) — see
# openddil-demo/values.yaml.
#
# STANDALONE INVOCATION against a live cluster (same image the chart uses,
# rpk ships in it — no chart install needed). Exec into any already-running
# redpanda pod and pipe this file in over stdin, with BROKERS/ASSERT_ONLY set
# via `env` (a bare `sh -s < file` does not carry env vars on its own):
#
#   kubectl -n <namespace> exec -i <any-redpanda-pod> -- \
#     env BROKERS="<release>-redpanda-edge-01:9644 <release>-redpanda-edge-02:9644 <release>-redpanda-edge-03:9644 <release>-redpanda-region-east:9644 <release>-redpanda-hq:19644" \
#         ASSERT_ONLY=1 \
#     sh -s < openddil-demo/scripts/redpanda-auto-create-off.sh
#
# Substitute the real release name and, if the tier-managed region differs
# from region-east, its broker host. Or, with no running pod to exec into,
# `kubectl run` a one-off with the same image instead:
#
#   kubectl -n <namespace> run redpanda-ac-check --rm -i --restart=Never \
#     --image=docker.redpanda.com/redpandadata/redpanda:v26.1.7 \
#     --overrides='{"spec":{"containers":[{"name":"redpanda-ac-check","image":"docker.redpanda.com/redpandadata/redpanda:v26.1.7","stdin":true,"command":["sh","-s"],"env":[{"name":"BROKERS","value":"<same list as above>"},{"name":"ASSERT_ONLY","value":"1"}]}]}}' \
#     < openddil-demo/scripts/redpanda-auto-create-off.sh

set -u
: "${ASSERT_ONLY:=0}"
: "${BROKERS:?BROKERS must be set to a space-separated list of host:adminport}"

ok=0
total=0

for B in $BROKERS; do
  total=$((total + 1))
  echo "Waiting for $B (Admin API)..."
  attempts=0
  # Explicit -X admin.hosts=$B on EVERY rpk admin call below. NEVER rely on
  # the localhost fallback: see infrastructure.yaml's topic-init Job comment
  # — rpk falls back to localhost when -X admin.hosts/brokers is omitted,
  # never reaches this pod's actual target broker, and silently wedges the
  # whole hook chain rather than failing visibly.
  until rpk cluster health -X admin.hosts="$B" >/dev/null 2>&1; do
    attempts=$((attempts + 1))
    if [ "$attempts" -ge 60 ]; then
      echo "ERROR: $B Admin API unreachable after ~3min — failing." >&2
      exit 1
    fi
    sleep 3
  done

  if [ "$ASSERT_ONLY" != "1" ]; then
    echo "INFO: Setting auto_create_topics_enabled=false on $B"
    rpk cluster config set auto_create_topics_enabled false -X admin.hosts="$B" || true
  fi

  # READ IT BACK. Never infer the setting from the `set` call's exit code,
  # and never infer it from the broker start arg being present (that arg is
  # a no-op on a cluster old enough to have formed before it shipped — the
  # whole reason this script exists).
  val=$(rpk cluster config get auto_create_topics_enabled -X admin.hosts="$B" 2>/dev/null | tr -d '[:space:]')
  if [ "$val" = "false" ]; then
    echo "OK:   $B auto_create_topics_enabled=false"
    ok=$((ok + 1))
  else
    echo "FAIL: $B auto_create_topics_enabled='${val:-<empty>}' (want false)"
  fi

  # For the record only (restart-needed column) — does not gate the job.
  echo "INFO: $B cluster config status:"
  rpk cluster config status -X admin.hosts="$B" || true
  echo
done

echo "auto_create_topics_enabled: ${ok}/${total} brokers false"
if [ "$ok" -ne "$total" ]; then
  exit 1
fi
