#!/usr/bin/env bash
# Render-integrity guards for openddil-demo.
#
# WHY THIS FILE EXISTS. The checks below were previously run ONCE, by hand, in
# the session that found each defect, and never persisted — so nothing would
# have failed if either defect returned (AUDIT-2026-08-15 F2). `helm lint`
# does not catch them: both defects render valid YAML and exit 0.
#
# Each guard is verified against a mutation that MODELS THE ORIGINAL DEFECT,
# per ADR-0037 clause 3 — not against a convenient edit that happens to go red.
#
#   ./scripts/check-chart-render.sh
#
# Exit 0 = clean. Exit 1 = a guard fired, naming what and why.
set -uo pipefail

CHART="$(cd "$(dirname "$0")/.." && pwd)/openddil-demo"
fail=0
PY=$(command -v python3 || command -v python || echo py)

render() { helm template t "$CHART" "$@" 2>/dev/null; }

# EVERY GUARD BELOW IS VACUOUS OVER AN EMPTY RENDER. "0 objects, 0 kinds,
# balanced" is a true statement and a useless one, and guards 1 and 2 printed
# exactly that — as `ok` — on a machine where `helm` was not installed, while
# guard 3 was the only one that refused. Found 2026-09-04 by running this
# script somewhere helm was missing.
#
# Same shape as everything else in this corpus about probes: the healthy
# reading and the did-not-run reading were byte-identical from the observer's
# position. Checked ONCE here rather than in each guard, so a guard added
# later inherits the floor instead of having to remember it.
require_nonempty_render() {
  if ! command -v helm >/dev/null 2>&1; then
    echo "helm not found — the guards below would all pass vacuously" >&2
    exit 1
  fi
  local n
  n=$(render | grep -c "^kind:")
  if [ "$n" -lt 1 ]; then
    echo "render produced no objects — the guards below would all pass" >&2
    echo "vacuously. Run 'helm template' by hand to see the real error." >&2
    exit 1
  fi
  echo "render: $n objects — guards below have something to check"
}
require_nonempty_render

# --- guard 1: document integrity -------------------------------------------
# THE DEFECT MODELLED: a missing `---` between loop iterations. Two objects
# merge into one YAML document, the later keys win, and an object SILENTLY
# DISAPPEARS from the release. The render still succeeds and `helm lint`
# still passes — the original was found only by counting 19 objects against
# 18 separators by hand.
#
# Parsed-document count is compared against `kind:` occurrences at column 0.
# A swallowed object leaves its `kind:` line in the text while the document
# count drops, so the two disagree exactly when a separator is lost.
echo "guard 1: document integrity"
for variant in "default" "emptydir"; do
  case "$variant" in
    default)  args=() ;;
    emptydir) args=(--set persistence.redpandaUseEmptyDir=true
                    --set persistence.restateUseEmptyDir=true) ;;
  esac
  out=$(render "${args[@]}")
  kinds=$(printf '%s\n' "$out" | grep -c '^kind:')
  docs=$(printf '%s\n' "$out" | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
print(len(docs))
' 2>/dev/null)
  if [ -z "$docs" ]; then
    echo "  FAIL [$variant]: render did not parse as YAML at all"
    fail=1
  elif [ "$kinds" != "$docs" ]; then
    echo "  FAIL [$variant]: $kinds 'kind:' lines but $docs parsed documents"
    echo "         an object was swallowed by a missing '---' separator"
    fail=1
  else
    echo "  ok   [$variant]: $docs objects, $kinds kinds, balanced"
  fi
done

# --- guard 2: every object is addressable ----------------------------------
# Same defect class, caught from a second direction (clause 3's "prefer a
# check against a DIFFERENT representation"): a merge can also produce two
# objects sharing a name, or one with no name at all.
echo "guard 2: object identity"
render | "$PY" -c '
import sys, yaml, collections
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
seen = collections.Counter()
bad = []
for d in docs:
    k = d.get("kind"); n = (d.get("metadata") or {}).get("name")
    if not k or not n:
        bad.append(f"object with kind={k!r} name={n!r}")
    else:
        seen[(k, n, (d.get("metadata") or {}).get("namespace") or "")] += 1
dupes = [f"{k}/{n}" for (k, n, _), c in seen.items() if c > 1]
if bad:   print("  FAIL: " + "; ".join(bad)); sys.exit(1)
if dupes: print("  FAIL: duplicate object identity: " + ", ".join(dupes)); sys.exit(1)
print(f"  ok   : {len(docs)} objects, all named, no duplicate identities")
' || fail=1

# --- guard 3: the escape hatch stays bounded --------------------------------
# THE DEFECT MODELLED: the NFS escape hatch swaps a PVC for an emptyDir and
# drops the size bound the PVC path carried (chart 0.1.46, ADR-0036 UD-7).
# Unbounded, it is charged against NODE ephemeral storage, and eviction picks
# victims by usage — so the pod killed is frequently not the pod at fault.
#
# Only the data volumes are asserted. The chart's other emptyDirs are
# bundle-asset and config copies, bounded by construction; values.yaml records
# that scoping deliberately.
echo "guard 3: emptyDir data volumes are bounded"
render --set persistence.redpandaUseEmptyDir=true \
       --set persistence.restateUseEmptyDir=true | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
unbounded, checked = [], 0
for d in docs:
    spec = (d.get("spec") or {})
    pod = (spec.get("template") or {}).get("spec") or {}
    for v in pod.get("volumes") or []:
        if v.get("name") != "data" or "emptyDir" not in v:
            continue
        checked += 1
        ed = v.get("emptyDir") or {}
        if not ed.get("sizeLimit"):
            nm = (d.get("metadata") or {}).get("name")
            unbounded.append(str(d.get("kind")) + "/" + str(nm))
if checked == 0:
    print("  FAIL: no data emptyDir rendered — the escape hatch did not engage,")
    print("        so this guard proved nothing (a green here would be empty)")
    sys.exit(1)
if unbounded:
    print("  FAIL: unbounded data emptyDir on: " + ", ".join(unbounded))
    sys.exit(1)
print(f"  ok   : {checked} data emptyDir volumes, all carry sizeLimit")
' || fail=1

echo
[ "$fail" -eq 0 ] && echo "chart render guards: clean" || echo "chart render guards: FAILED"
exit "$fail"
