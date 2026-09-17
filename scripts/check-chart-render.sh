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
# A variant per OPTIONAL BLOCK, because a template guarded by `if` is
# invisible to a default render and therefore unguarded by it. The
# releasability stack renders nothing at all unless asked for, so without
# its own variant a missing separator or a duplicated name in it would ship
# — the exact defect guard 1 exists to catch, hiding behind a feature flag.
VARIANTS="default emptydir releasability tiernode"

# ONE definition of each variant, read by every guard below. Guards 2 and 3
# used to run against the DEFAULT RENDER ONLY, so anything behind an `if` was
# checked by guard 1 and by nothing else — which is the same "a template
# behind a feature flag is unguarded" defect guard 1 exists to catch, one
# level up in the tooling.
variant_args() {
  case "$1" in
    default)  echo "" ;;
    emptydir) echo "--set persistence.redpandaUseEmptyDir=true --set persistence.restateUseEmptyDir=true" ;;
    releasability)
      # The whole stack, including the pieces that only appear when
      # authentication is on. `publicOrigin` is supplied because the OIDC
      # helpers deliberately `fail` without one rather than inventing a
      # redirect URI — a wrong redirect URI is the misconfiguration whose
      # usual repair is a wildcard.
      echo "--set releasability.enabled=true --set releasability.lockDownElectric=true --set releasability.oidc.enabled=true --set releasability.keycloak.enabled=true --set releasability.publicOrigin=https://lab.invalid" ;;
    tiernode)
      # THE TIER NODE, WITH ENFORCEMENT. Added 2026-09-05: the tier-node
      # templates were behind `tierNode.enabled` and therefore rendered by
      # NO variant — the same "a template behind a feature flag is
      # unguarded" defect guard 1 exists to catch, for the third time.
      #
      # This variant carries the per-tier PEP, the per-tier NetworkPolicy
      # and the per-tier Ingress, which are the objects most likely to
      # collide by name across tiers.
      echo "--set tierNode.enabled=true --set releasability.enabled=true --set releasability.lockDownElectric=true --set releasability.publicOrigin=https://lab.invalid" ;;
  esac
}

for variant in $VARIANTS; do
  # shellcheck disable=SC2207
  args=($(variant_args "$variant"))
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
for variant in $VARIANTS; do
  # shellcheck disable=SC2207
  args=($(variant_args "$variant"))
  printf '  [%s] ' "$variant"
  render "${args[@]}" | "$PY" -c '
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
print(f"ok   {len(docs)} objects, all named, no duplicate identities")
' || fail=1
done

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

# --- guard 4: every inline shell script the chart renders actually PARSES ---
# THE DEFECT MODELLED: a comment block placed INSIDE a line continuation.
#
#     for spec in \\
#         # compression.type=lz4 ON EVERY TOPIC RESTATE SUBSCRIBES TO
#         "raw-sensor-stream|-p 1 -r 1 ..." \\
#
# The backslash joins the next line, `#` eats the rest of it, the `for` loses
# its word list, and the WHOLE SCRIPT is a parse error -- so the Job runs
# nothing at all, not merely the loop.
#
# Every layer upstream said yes: valid YAML, clean `helm template`, clean
# `helm lint`, manifest applied, Job created, image pulled, container started.
# The only reader that ever objects is a shell asked to parse it, and nothing
# in the pipeline was asking one.
#
# Cost, measured 2026-09-17: topic-init failed 7 times to BackoffLimitExceeded;
# that failed the post-upgrade hook, wedging the release in `pending-upgrade`
# for eight hours; which stopped the OTHER post-upgrade hook -- the bootstrap
# registering Restate's deployments and Kafka subscriptions -- from running at
# all. The comment described a compression fix. Because of where it sat, that
# fix never applied: a comment explaining a fix prevented the fix.
#
# RED-CHECKED against the real pre-fix chart (git stash of the actual broken
# template, not a convenient edit): FAIL naming Job/openddil-topic-init and
# the offending line, then clean after the fix. 34 scripts checked either way.
echo
echo "guard 4: rendered shell scripts parse"
# A VARIANT PER OPTIONAL BLOCK, same discipline as guards 1-3. `tierNode.
# enabled` defaults to FALSE, so a plain render omits every script in
# tier-node.yaml: the first version of this guard reported "34 scripts, 0
# failures" having never parsed one of the 27 that live there. A guard that
# only inspects the default render has agreed not to look at the optional
# half of the chart -- which is where the per-tier machinery lives, i.e.
# most of what this system now is.
#
# Status captured explicitly rather than through a `| sed` pipeline. pipefail
# is set and would carry it, but a guard against "looked like it ran" should
# not itself depend on a shell option someone could drop from line 15.
for variant in "default:" "tiernode:--set tierNode.enabled=true" "releasability:--set releasability.enabled=true"; do
  vname="${variant%%:*}"
  vargs="${variant#*:}"
  # shellcheck disable=SC2086
  if guard4_out=$("$PY" "$(dirname "$0")/check_shell_syntax.py" "$CHART" $vargs 2>&1); then
    printf '  [%s] %s\n' "$vname" "$(printf '%s' "$guard4_out" | tail -1)"
  else
    printf '  [%s] FAILED\n' "$vname"
    printf '%s\n' "$guard4_out" | sed 's/^/    /'
    fail=1
  fi
done

echo
[ "$fail" -eq 0 ] && echo "chart render guards: clean" || echo "chart render guards: FAILED"
exit "$fail"
