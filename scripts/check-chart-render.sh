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

# --- guard 5: setup hooks also run on rollback ------------------------------
# THE DEFECT MODELLED: `helm rollback` fires pre-rollback/post-rollback
# hooks, NOT pre-upgrade/post-upgrade. A hook annotated only post-upgrade
# (or pre-upgrade) is invisible to a rollback -- it renders, it is valid
# YAML, `helm lint` is silent, and the hook simply never runs.
#
# Before this guard, hook-restate-wipe.yaml was pre-install/pre-upgrade-only
# and every registration Job (cm-service-bootstrap, logistics-fusion-
# bootstrap, topic-init, tier-restate-bootstrap-<tier>,
# redpanda-auto-create-off) was post-install/post-upgrade-only: a rollback
# left Restate's old journals in place -- wrong, since a rollback is a code
# change too and an old journal does not replay against changed code -- and
# re-registered nothing against the wipe that normally follows.
#
# ALLOWLIST: postgres-schema-init and tier-schema-init-<tier> stay
# post-install/post-upgrade ONLY, on purpose. Atlas migrations are
# forward-only -- an older migration dir cannot take the DB back, and a
# re-apply Atlas refuses FAILS the hook, blocking every registration Job at
# a later weight (20/21). See the comment at each one's own annotation.
#
# hook-restate-wipe.yaml's pre-install/pre-upgrade/pre-rollback hooks are
# gated by `restate.ephemeralOnUpgrade` (default false), so this guard sets
# it true -- otherwise the wipe Job never renders in any variant below and
# the pre-rollback check would pass vacuously, having checked nothing.
echo
echo "guard 5: setup hooks also run on rollback"
for variant in "default:" "tiernode:--set tierNode.enabled=true" "releasability:--set releasability.enabled=true"; do
  vname="${variant%%:*}"
  vargs="${variant#*:}"
  # shellcheck disable=SC2086
  guard5_out=$(render $vargs --set restate.ephemeralOnUpgrade=true | "$PY" -c '
import sys, re, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
allow_re = re.compile(r"-postgres-schema-init$|-tier-schema-init-")
checked = 0
bad = []
for d in docs:
    meta = d.get("metadata") or {}
    ann = meta.get("annotations") or {}
    hook = ann.get("helm.sh/hook")
    if not hook:
        continue
    name = meta.get("name") or "<unnamed>"
    kind = d.get("kind")
    hooks = [h.strip() for h in hook.split(",")]
    if "pre-upgrade" in hooks:
        checked += 1
        if "pre-rollback" not in hooks:
            bad.append(f"FAIL: {kind}/{name}: pre-upgrade without pre-rollback ({hook})")
    if "post-upgrade" in hooks:
        checked += 1
        if "post-rollback" not in hooks:
            if allow_re.search(name):
                print(f"  ok   : {kind}/{name} allowlisted -- Atlas schema migrations are forward-only, a refused re-apply must not run on rollback")
            else:
                bad.append(f"FAIL: {kind}/{name}: post-upgrade without post-rollback ({hook})")
if checked == 0:
    print("FAIL: 0 hooks checked in this variant -- proves nothing (vacuous-pass floor)")
    sys.exit(1)
for b in bad:
    print(b)
print(f"  hooks checked: {checked}")
sys.exit(1 if bad else 0)
')
  status=$?
  printf '%s\n' "$guard5_out" | sed "s/^/  [$vname] /"
  [ "$status" -ne 0 ] && fail=1
done

# Guard 6: the egress gate resolves each route's destination from topaz-hq
# once, at startup. A registry change that rolls topaz-hq but not the gate
# leaves the gate on the old registry (an unknown destination, nations=[]),
# with nothing failing loudly. The gate must carry the same registry checksum
# as topaz-hq, and that checksum must move when the destinations registry moves.
# Defect model: drop checksum/registries from the gate, or key it to something
# other than releasability.destinations.
echo
echo "guard 6: egress gate rolls with the destinations registry"
g6() { render --set releasability.enabled=true "$@" | "$PY" -c '
import sys, yaml
want = {"openddil-egress-gate-c2": "checksum/registries", "openddil-topaz-hq": "checksum/policy"}
got = {}
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Deployment":
        n = d["metadata"]["name"].replace("t-", "openddil-", 1)
        if n in want:
            got[n] = ((d["spec"]["template"]["metadata"].get("annotations") or {}).get(want[n]) or "")
print(" ".join(got.get(n, "") or "MISSING" for n in want))
'; }
read -r g6_gate g6_topaz <<<"$(g6)"
read -r g6_gate2 g6_topaz2 <<<"$(g6 --set releasability.destinations.version=guard6-changed)"
if [ "$g6_gate" = MISSING ] || [ "$g6_topaz" = MISSING ] || [ -z "$g6_gate" ]; then
  echo "  FAIL: gate=$g6_gate topaz-hq=$g6_topaz -- an annotation is missing (or neither rendered: vacuous)"; fail=1
elif [ "$g6_gate" != "$g6_topaz" ]; then
  echo "  FAIL: gate checksum/registries ($g6_gate) != topaz-hq checksum/policy ($g6_topaz)"; fail=1
elif [ "$g6_gate2" = "$g6_gate" ]; then
  echo "  FAIL: changing releasability.destinations did not change the gate's checksum/registries"; fail=1
elif [ "$g6_gate2" != "$g6_topaz2" ]; then
  echo "  FAIL: after a destinations change, gate ($g6_gate2) != topaz-hq ($g6_topaz2)"; fail=1
else
  echo "  ok   : gate == topaz-hq, and both move with releasability.destinations"
fi


# Guard 7: the intake process, the stub sink's artifacts and the hub's
# released-records panes render (or don't) exactly as values.yaml says.
echo
echo "guard 7: intake / stub artifacts / released-records panes"

# 7a: default values render no intake Deployment at all -- checked plain,
# and again with releasability.enabled=true alone (egress.yaml's own gate),
# so egress.intake.enabled's own default is what is under test, not merely
# releasability's.
for g7a_args in "" "--set releasability.enabled=true"; do
  # shellcheck disable=SC2086
  render $g7a_args | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
bad = [ (d["metadata"] or {}).get("name","") for d in docs
        if d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("-egress-intake") ]
if bad:
    print("  FAIL [7a]: egress.intake.enabled defaults to rendering a Deployment: " + ", ".join(bad)); sys.exit(1)
print("  ok   [7a]: egress.intake.enabled default renders no egress-intake Deployment")
' || fail=1
done

# 7b: enabling intake renders one Deployment, carrying the five documented
# env vars and a checksum/registries annotation equal to the gate's own
# (same computation, same releasability.destinations input).
render --set releasability.enabled=true --set egress.intake.enabled=true | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
want_env = {"OPENDDIL_EGRESS_BROKERS", "OPENDDIL_EGRESS_INTAKE_CONFIG",
            "OPENDDIL_EGRESS_KINDS_DIR", "POSTGRES_DSN", "OPENDDIL_TOPAZ_URL"}
intake = gate = None
for d in docs:
    if d.get("kind") != "Deployment":
        continue
    n = d["metadata"]["name"]
    if n.endswith("-egress-intake"):
        intake = d
    elif n.endswith("-egress-gate-c2"):
        gate = d
if intake is None:
    print("  FAIL [7b]: egress.intake.enabled=true rendered no egress-intake Deployment"); sys.exit(1)
if gate is None:
    print("  FAIL [7b]: no egress-gate-c2 Deployment rendered -- cannot compare checksums"); sys.exit(1)
envs = {e["name"] for e in intake["spec"]["template"]["spec"]["containers"][0]["env"]}
missing = want_env - envs
if missing:
    print("  FAIL [7b]: intake missing env vars: " + ", ".join(sorted(missing))); sys.exit(1)
iann = intake["spec"]["template"]["metadata"].get("annotations") or {}
gann = gate["spec"]["template"]["metadata"].get("annotations") or {}
ireg, greg = iann.get("checksum/registries"), gann.get("checksum/registries")
if not ireg:
    print("  FAIL [7b]: intake has no checksum/registries annotation"); sys.exit(1)
if ireg != greg:
    print(f"  FAIL [7b]: intake checksum/registries ({ireg}) != gate checksum/registries ({greg})"); sys.exit(1)
print("  ok   [7b]: intake has the five env vars and checksum/registries matching the gate")
' || fail=1

# 7c: a stub artifacts value change changes the stub's checksum/artifacts.
g7c() { render --set releasability.enabled=true --set egress.stubSink.enabled=true "$@" | "$PY" -c '
import sys, yaml
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("-egress-stub-sink"):
        ann = d["spec"]["template"]["metadata"].get("annotations") or {}
        print(ann.get("checksum/artifacts") or "MISSING")
        sys.exit(0)
print("MISSING")
'; }
g7c_before=$(g7c)
g7c_after=$(g7c --set-json 'egress.stubSink.artifacts=[{"kind":"K","id":"1"}]')
if [ "$g7c_before" = MISSING ] || [ "$g7c_after" = MISSING ]; then
  echo "  FAIL [7c]: stub-sink checksum/artifacts annotation missing"; fail=1
elif [ "$g7c_before" = "$g7c_after" ]; then
  echo "  FAIL [7c]: changing egress.stubSink.artifacts did not change checksum/artifacts"; fail=1
else
  echo "  ok   [7c]: stub-sink checksum/artifacts moves with egress.stubSink.artifacts"
fi

# 7d: default render has no hub frontend deployment-config ConfigMap at all.
render | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
bad = [ d["metadata"]["name"] for d in docs
        if d.get("kind") == "ConfigMap" and d["metadata"]["name"].endswith("-frontend-deployment-config") ]
if bad:
    print("  FAIL [7d-default]: default render has a hub deployment-config ConfigMap: " + ", ".join(bad)); sys.exit(1)
print("  ok   [7d-default]: default render has no hub frontend deployment-config ConfigMap")
' || fail=1

# 7e: a non-empty frontend.releasedRecordsPanes appears in the hub frontend's
# deployment.json and in no tier's tier-frontend-config.
render --set tierNode.enabled=true --set-json 'frontend.releasedRecordsPanes=[{"title":"t","destination":"system:x","kind":"K","columns":[]}]' \
  | G7E_JSON='[{"title": "t", "destination": "system:x", "kind": "K", "columns": []}]' "$PY" -c '
import sys, os, yaml, json
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
want = json.loads(os.environ["G7E_JSON"])
hub = None
tiers = []
for d in docs:
    if d.get("kind") != "ConfigMap":
        continue
    n = d["metadata"]["name"]
    if n.endswith("-frontend-deployment-config"):
        hub = d
    elif "-tier-frontend-config-" in n:
        tiers.append(d)
if hub is None:
    print("  FAIL [7e]: no hub frontend-deployment-config ConfigMap rendered"); sys.exit(1)
got = json.loads(hub["data"]["deployment.json"])
gotPanes = got.get("releasedRecordsPanes")
if gotPanes != want:
    print("  FAIL [7e]: hub deployment.json releasedRecordsPanes = " + repr(gotPanes) + ", want " + repr(want)); sys.exit(1)
if set(got.keys()) != {"releasedRecordsPanes"}:
    print(f"  FAIL [7e]: hub deployment.json has extra keys: {sorted(got.keys())}"); sys.exit(1)
if not tiers:
    print("  FAIL [7e]: no tier-frontend-config ConfigMaps rendered with tierNode.enabled=true -- cannot check absence"); sys.exit(1)
leaked = [d["metadata"]["name"] for d in tiers if "releasedRecordsPanes" in (d["data"].get("deployment.json") or "")]
if leaked:
    print("  FAIL [7e]: releasedRecordsPanes leaked into tier config(s): " + ", ".join(leaked)); sys.exit(1)
print(f"  ok   [7e]: hub carries releasedRecordsPanes; {len(tiers)} tier-frontend-config(s) do not")
' || fail=1

echo
[ "$fail" -eq 0 ] && echo "chart render guards: clean" || echo "chart render guards: FAILED"
exit "$fail"
