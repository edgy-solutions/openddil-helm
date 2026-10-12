#!/usr/bin/env bash
# ===========================================================================
# test_topic_init_partition_drift.sh -- offline proof that topic-init LOGS a
# partition-count mismatch and never fails on it.
#
# Renders the chart, takes one tier topic-init script and the hub one (the hub
# render carries the HQ-only egress loop too), and runs each under `sh` with a
# stub `rpk` first on PATH. No cluster.
#
# Cases (each for the tier script and the hub script):
#   A. drift: `topic list` shows three spec topics at the wrong count (the last
#      is an HQ-only egress topic on the hub) and one absent. Expect one
#      TOPIC_INIT_PARTITION_DRIFT line each (absent -> live=missing), the
#      "4 topic(s)" summary, and exit 0.
#   B. no drift: every spec topic at its spec count. Expect no drift line,
#      "0 topic(s)", exit 0.
#   C. `topic list` failing after the wait loop: no drift line, exit 0.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }
command -v helm >/dev/null 2>&1 || { echo "SKIP: no helm"; exit 2; }

TMP="${KEEP_TMP:-$(mktemp -d)}"; [ -n "${KEEP_TMP:-}" ] || trap 'rm -rf "$TMP"' EXIT
FAIL=0; RUNS=0
mkdir -p "$TMP/bin"

helm template t "$CHART" --set releasability.enabled=true > "$TMP/render.yaml" 2>/dev/null \
  || { echo "FAIL: render"; exit 1; }

# Extract the scripts and the spec table (topic -> -p N) of each.
"$PY" - "$TMP" <<'PYEOF'
import re, sys, yaml
tmp = sys.argv[1]
docs = [d for d in yaml.safe_load_all(open(tmp + "/render.yaml", encoding="utf-8")) if d]
picked = {}
for d in docs:
    if d.get("kind") != "Job":
        continue
    n = d["metadata"]["name"]
    if n == "t-topic-init":
        which = "hub"
    elif n.startswith("t-topic-init-") and "tier" not in picked:
        which = "tier"
    else:
        continue
    if which in picked:
        continue
    c = d["spec"]["template"]["spec"]["containers"][0]
    text = "\n".join(c["command"][2:])
    picked[which] = text
    open("%s/%s.sh" % (tmp, which), "w", encoding="utf-8", newline="\n").write(text + "\n")
    specs = re.findall(r'"([a-z0-9-]+)\|-p (\d+) ', text)
    open("%s/%s.specs" % (tmp, which), "w", newline=chr(10)).write(chr(10).join("%s %s" % s for s in specs) + chr(10))
if set(picked) != {"hub", "tier"}:
    sys.exit("missing a topic-init Job: %s" % sorted(picked))
PYEOF
[ $? -eq 0 ] || { echo "FAIL: could not extract topic-init scripts"; exit 1; }

# Stub rpk. `topic list` prints $STUB_TABLE (header + rows) unless
# STUB_LIST_FAIL is set AND the list has been called once already (so the
# wait loop's probe succeeds). Every other subcommand exits 0 silently.
cat > "$TMP/bin/rpk" <<'STUB'
#!/bin/sh
case " $* " in
  *" topic list "*)
    if [ -n "${STUB_LIST_FAIL:-}" ]; then
      n=$(cat "$STUB_COUNT" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$STUB_COUNT"
      [ "$n" -gt 1 ] && exit 1
    fi
    cat "$STUB_TABLE"
    ;;
esac
exit 0
STUB
chmod +x "$TMP/bin/rpk"

# $1 which, $2 mode (drift|clean)
make_table() {
  { printf 'NAME PARTITIONS REPLICAS\n'
    i=0; total=$(grep -c . "$TMP/$1.specs")
    while read -r t p; do
      [ -n "$t" ] || continue
      i=$((i + 1))
      if [ "$2" = drift ]; then
        case $i in
          1) continue ;;                 # absent
          2) p=$((p + 5)) ;;             # wrong
          3) p=$((p + 1)) ;;             # wrong
          "$total") p=$((p + 2)) ;;      # wrong; the last spec (hub: an HQ-only egress topic)
        esac
      fi
      printf '%s %s 1\n' "$t" "$p"
    done < "$TMP/$1.specs"
  } > "$TMP/table.txt"
}

run_case() { # which mode expect_drift_lines
  local which="$1" mode="$2" want="$3" out rc n
  RUNS=$((RUNS + 1))
  make_table "$which" "$mode"
  rm -f "$TMP/count"
  out=$(PATH="$TMP/bin:$PATH" STUB_TABLE="$TMP/table.txt" STUB_COUNT="$TMP/count" \
        STUB_LIST_FAIL="$([ "$mode" = listfail ] && echo 1)" sh -e "$TMP/$which.sh" 2>&1); rc=$?
  n=$(printf '%s\n' "$out" | grep -c '^TOPIC_INIT_PARTITION_DRIFT ')
  echo "--- $which/$mode: exit=$rc drift_lines=$n"
  printf '%s\n' "$out" | grep -E '^TOPIC_INIT_PARTITION_DRIFT |^INFO: partition drift' | sed 's/^/    /'
  if [ "$rc" -ne 0 ]; then echo "FAIL: $which/$mode exited $rc"; FAIL=1; fi
  if [ "$n" -ne "$want" ]; then echo "FAIL: $which/$mode expected $want drift lines, got $n"; FAIL=1; fi
}

for w in tier hub; do
  run_case "$w" drift 4
  run_case "$w" clean 0
  run_case "$w" listfail 0
done

# Vacuity floor: a harness that ran no case proves nothing.
[ "$RUNS" -eq 6 ] || { echo "FAIL: ran $RUNS of 6 cases"; FAIL=1; }
if [ "$FAIL" -eq 0 ]; then echo "topic-init partition drift: PASS"; else echo "topic-init partition drift: FAIL"; fi
exit "$FAIL"
