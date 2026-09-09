#!/bin/sh
# ===========================================================================
# relay-stall-probe.sh — liveness for a Benthos/redpanda-connect relay
# ===========================================================================
# Exit 0 = alive. Exit 1 = stalled, restart me.
#
# WHY AN EXEC PROBE AND NOT A SIDECAR. The Python services hold their own
# progress state in memory, so their detector lives in-process. A relay is a
# third-party binary with no hook — but the Connect image HAS a shell, wget
# and awk (checked, 2026-09-09), so the state can live in a file beside it in
# the same container. A sidecar was the fallback for a distroless image and is
# not needed: it would add a component that can itself be wrong, which is the
# failure class this whole mechanism exists to reduce.
#
# THE DECISION, and every term is load-bearing:
#
#   stalled == input advanced  AND  confirmed output did not
#                              AND  destination reachable      (relays only)
#
# input advanced        — `input_received` grew since the last sample. Without
#                         this the probe fires on an idle source and restarts
#                         a healthy relay every window, which is a worse
#                         outage than the wedge it was added to catch.
#
# confirmed output      — `output_sent`, NOT `output_batch_sent` attempts and
#                         not a produce call. VERIFIED 2026-09-09 by taking
#                         the destination away: input_received advanced by 296
#                         while output_sent stayed frozen. That is the same
#                         distinction that made the Python detector count
#                         confirmed deliveries rather than produce() calls,
#                         and it was measured here rather than assumed.
#
# destination reachable — a TCP check against the address this relay actually
#                         publishes to, so a NetworkPolicy sever affects the
#                         probe exactly as it affects the relay. UNREACHABLE
#                         IS NOT STALLED: under severance a relay's output
#                         legitimately stops, because buffering IS the
#                         designed degraded mode. Without this term the probe
#                         would restart the bridge every window for the whole
#                         duration of a cut — failing closed across a link
#                         that is expected to fail, arriving as a liveness
#                         probe.
#
# The DIS mapper publishes to its own local broker, so it runs two-term:
# leave DEST_HOST empty and the reachability term is skipped.
#
# STATE lives in a file because a probe is a fresh process each time and
# "advanced since last time" needs a last time. Losing the file (pod restart)
# reads as "no previous sample", which reports alive — a probe that cannot
# remember must not accuse.
# ===========================================================================
set -u

METRICS_URL="${METRICS_URL:-http://localhost:4195/metrics}"
STATE_FILE="${STATE_FILE:-/tmp/relay-stall.state}"
DEST_HOST="${DEST_HOST:-}"
DEST_PORT="${DEST_PORT:-9092}"

now="$(date +%s)"

sample="$(wget -qO- "$METRICS_URL" 2>/dev/null \
  | awk '/^input_received/{i=$2} /^output_sent/{o=$2} END{printf "%d %d", i, o}')"
in_now="${sample% *}"
out_now="${sample#* }"

# A relay whose metrics cannot be read has not been shown to be stalled. It
# may be very sick, but this probe answers one question and must not answer a
# different one by accident.
if [ -z "$sample" ] || [ "$in_now" = "0" ] && [ "$out_now" = "0" ]; then
  echo "metrics unreadable or zero — not judging"
  exit 0
fi

if [ ! -f "$STATE_FILE" ]; then
  echo "$in_now $out_now $now" > "$STATE_FILE"
  echo "first sample recorded — alive"
  exit 0
fi

read -r in_prev out_prev t_prev < "$STATE_FILE"
echo "$in_now $out_now $now" > "$STATE_FILE"

elapsed=$(( now - t_prev ))
in_delta=$(( in_now - in_prev ))
out_delta=$(( out_now - out_prev ))

if [ "$in_delta" -le 0 ]; then
  echo "input idle (+$in_delta over ${elapsed}s) — not stalled"
  exit 0
fi

if [ "$out_delta" -gt 0 ]; then
  echo "flowing (in +$in_delta, out +$out_delta over ${elapsed}s)"
  exit 0
fi

if [ -n "$DEST_HOST" ]; then
  if ! nc -z -w 3 "$DEST_HOST" "$DEST_PORT" 2>/dev/null; then
    # Buffering, by design. This is the branch that keeps a severance from
    # becoming a crash loop.
    echo "destination $DEST_HOST:$DEST_PORT unreachable — buffering, not stalled"
    exit 0
  fi
fi

echo "STALLED: input +$in_delta, confirmed output +0 over ${elapsed}s, destination reachable"
exit 1
