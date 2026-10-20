#!/usr/bin/env bash
# ===========================================================================
# test_region_fan_in_cap.sh -- offline proof that every region fan-in topic
# topic-init declares carries a retention.bytes cap.
#
# The fan-in topic was bounded only by time (7 d); a sustained flood filled a
# 10 Gi region broker volume. topic-init enforces its spec on the live topic,
# so the cap in the spec is the cap on the broker.
#
# Cases:
#   A. default render: every "<region>-fan-in|" spec line ends in
#      retention.bytes=2147483648, and there is at least one such line.
#   B. --set regionFanIn.retentionBytes=1073741824: every line carries it.
#   C. retentionBytes=0: the render fails with the regionFanIn message.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"
command -v helm >/dev/null 2>&1 || { echo "SKIP: no helm"; exit 2; }

TMP="${KEEP_TMP:-$(mktemp -d)}"; [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$TMP"' EXIT
FAIL=0

# Every fan-in spec line carries exactly the expected cap.
check_cap() {
  local label="$1" want="$2"; shift 2
  if ! helm template t "$CHART" "$@" > "$TMP/r.yaml" 2>"$TMP/r.err"; then
    echo "FAIL $label: render: $(tail -1 "$TMP/r.err")"; FAIL=1; return
  fi
  local all bad
  all="$(grep -c -- '-fan-in|' "$TMP/r.yaml")"
  bad="$(grep -- '-fan-in|' "$TMP/r.yaml" | grep -vc -- "-c retention.bytes=$want\"")"
  if [ "$all" -eq 0 ]; then
    echo "FAIL $label: no fan-in spec rendered"; FAIL=1
  elif [ "$bad" -ne 0 ]; then
    echo "FAIL $label: $bad of $all fan-in spec(s) without retention.bytes=$want"
    grep -- '-fan-in|' "$TMP/r.yaml" | grep -v -- "retention.bytes=$want\"" | head -2
    FAIL=1
  else
    echo "PASS $label: $all fan-in spec(s) carry retention.bytes=$want"
  fi
}

check_cap "A default" 2147483648
check_cap "B override" 1073741824 --set regionFanIn.retentionBytes=1073741824

if helm template t "$CHART" --set regionFanIn.retentionBytes=0 > /dev/null 2>"$TMP/c.err"; then
  echo "FAIL C zero: render succeeded"; FAIL=1
elif grep -q 'regionFanIn.retentionBytes must be a positive byte count' "$TMP/c.err"; then
  echo "PASS C zero: render refused"
else
  echo "FAIL C zero: render failed for another reason: $(tail -1 "$TMP/c.err")"; FAIL=1
fi

exit $FAIL
