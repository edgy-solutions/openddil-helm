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
# ALLOWLIST: postgres-schema-init and tier-schema-init-<tier> run
# post-install,pre-upgrade with NO rollback stage at all, on purpose. Atlas
# migrations are forward-only -- an older migration dir cannot take the DB
# back, and a re-apply Atlas refuses FAILS the hook, blocking every
# registration Job at a later weight (20/21). See the comment at each one's
# own annotation.
#
# topic-init runs post-install,pre-upgrade,post-rollback: pre-upgrade so a
# topic exists before the consumer that needs it starts, and the SAME
# post-rollback it already carried before this phase moved from
# post-upgrade to pre-upgrade -- topic creation is idempotent, so re-running
# it after a rollback is still a correct no-op, and it needs no NEW
# pre-rollback stage to cover a case post-rollback already covers. The
# allowlist below accepts "pre-upgrade without pre-rollback" for exactly
# these three Jobs, for exactly these reasons, not as a blanket exemption.
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
allow_re = re.compile(r"-postgres-schema-init$|-tier-schema-init-|-topic-init$")
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
            if allow_re.search(name):
                print(f"  ok   : {kind}/{name} allowlisted -- schema-init carries no rollback stage at all (Atlas is forward-only); topic-init keeps its existing post-rollback rather than gaining a new pre-rollback")
            else:
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

# --- guard 8: schema-init / topic-init choose their hook phase correctly ---
# THE DEFECT MODELLED: a new release's consumer (a projector, a Restate
# subscription) starting against a table or topic that doesn't exist yet,
# because the Job that creates it was a post-upgrade hook -- which fires
# AFTER the new Deployments/StatefulSets are already applied and their pods
# are starting, not before. postgres-schema-init and the hub topic-init stay
# hard-coded post-install,pre-upgrade: the hub backend always exists, so
# there is no "new backend" case for them to get wrong. tier-schema-init-
# <tier> and topic-init-<tier> cannot be hard-coded the same way, because a
# pre-upgrade hook against a tier backend that doesn't exist yet (a tier
# added in this same upgrade) would fail that hook and fail the whole
# release. Each picks its OWN phase at RENDER TIME via `lookup "v1"
# "Service" <namespace> <that tier's own Service>`: non-empty (an existing
# backend) means pre-upgrade, empty (install, or a backend new this
# upgrade) means post-install or post-upgrade respectively. Registration
# Jobs (cm-service-bootstrap, logistics-fusion-bootstrap,
# tier-restate-bootstrap-<tier>) stay post-upgrade on purpose -- they
# register the NEW deployments, which must already be running.
#
# `lookup` returns empty under plain `helm template` (no live cluster), so
# the ONLY way to exercise the pre-upgrade branch at all is a server-side
# dry run or a real upgrade against a cluster that already has the
# Service -- neither of which this script can do offline. What IS checked
# offline, across two renders:
#   - IsInstall (no --is-upgrade): lookup is empty AND Release.IsInstall is
#     true, so every tier Job must render post-install.
#   - --is-upgrade: lookup is still empty (no live cluster) but
#     Release.IsInstall is now false, so every tier Job must render
#     post-upgrade -- this is the "every tier looks new" case the real
#     lookup would also produce against a cluster with no Service for it.
# A hard-coded annotation would pass the IsInstall render (it can hard-code
# "post-install") and then fail to move to "post-upgrade" under
# --is-upgrade -- which is exactly what guard 8 checks -- but a hard-coded
# "pre-upgrade" would ALSO never appear in either offline render, so a
# content check on the TEMPLATE SOURCE (not the rendered YAML -- `lookup`
# calls are consumed at render time and leave no trace in the output) also
# confirms the lookup gate itself is still there in the file, not bypassed
# by something that happens to render identically in these two cases.
#
# Second half of the guard: the bounded wait each of these Jobs runs before
# creating anything (SCHEMA_INIT_REFUSED / TOPIC_INIT_REFUSED) must still be
# present and still bounded at 300s (150 x 2s) -- a blanked bound or a
# deleted REFUSED string would make an unready backend wedge the hook
# forever instead of failing it loudly, same risk this whole guard exists
# to catch for the hook-phase choice itself.
echo
echo "guard 8: schema-init / topic-init choose their hook phase correctly"

TIER_NODE_TPL="$CHART/templates/tier-node.yaml"
INFRA_TPL="$CHART/templates/infrastructure.yaml"
g8_lookup_gate() {
  # Template-SOURCE check: `lookup` is resolved away during rendering, so
  # this cannot be checked against rendered YAML at all. Two call sites
  # expected, in TWO DIFFERENT FILES: tier-schema-init-<tier> (against the
  # tier's postgres Service) gates in tier-node.yaml, because tier postgres
  # only exists under tierNode. topic-init-<id> (against that broker's
  # Service) gates in infrastructure.yaml, co-located with the broker
  # StatefulSet loop it must never drift from (round 4) -- it is NOT in
  # tier-node.yaml any more.
  local n_schema n_topic
  n_schema=$(grep -c '{{- if lookup "v1" "Service"' "$TIER_NODE_TPL")
  n_topic=$(grep -c '{{- if lookup "v1" "Service"' "$INFRA_TPL")
  local bad=0
  if [ "$n_schema" -lt 1 ]; then
    echo "  FAIL: templates/tier-node.yaml has $n_schema {{- if lookup(\"v1\",\"Service\",...)}} gate(s), expected >= 1 (tier-schema-init-<tier>)"
    bad=1
  fi
  if [ "$n_topic" -lt 1 ]; then
    echo "  FAIL: templates/infrastructure.yaml has $n_topic {{- if lookup(\"v1\",\"Service\",...)}} gate(s), expected >= 1 (topic-init-<id>, co-located with the broker StatefulSet loop)"
    bad=1
  fi
  [ "$bad" -ne 0 ] && return 1
  echo "  lookup gate present: tier-node.yaml ($n_schema, schema-init) + infrastructure.yaml ($n_topic, topic-init)"
  return 0
}

g8() { render "$@" | "$PY" -c '
import os, sys, re, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]

# Hub Jobs are NOT lookup-gated -- matched by exact name, so a tier Job
# cannot borrow their always-static expectation by coincidence.
HUB_SCHEMA_RE = re.compile(r"-postgres-schema-init$")
HUB_TOPIC_RE = re.compile(r"-topic-init$")
# Tier Jobs ARE lookup-gated -- matched by the trailing -<tier-id>, which is
# exactly what distinguishes them from the hub names above.
TIER_SCHEMA_RE = re.compile(r"-tier-schema-init-.+$")
TIER_TOPIC_RE = re.compile(r"-topic-init-.+$")

def classify(name):
    if HUB_SCHEMA_RE.search(name):
        return "hub_schema"
    if TIER_SCHEMA_RE.search(name):
        return "tier_schema"
    if TIER_TOPIC_RE.search(name):
        return "tier_topic"
    if HUB_TOPIC_RE.search(name):
        return "hub_topic"
    return None

def script_text(d):
    pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
    text = []
    for c in (pod.get("initContainers") or []) + (pod.get("containers") or []):
        text.extend(str(x) for x in (c.get("command") or []) + (c.get("args") or []))
    return "\n".join(text)

BOUND_RE = re.compile(r"attempts.{0,20}-ge\s+150")
is_upgrade_mode = os.environ.get("GUARD8_IS_UPGRADE") == "1"
mode_label = "is-upgrade" if is_upgrade_mode else "install"

jobs = []
for d in docs:
    if d.get("kind") != "Job":
        continue
    name = (d.get("metadata") or {}).get("name") or ""
    tag = classify(name)
    if tag:
        jobs.append((tag, d))

if not jobs:
    print("FAIL: no schema-init/topic-init Jobs matched in this render -- guard proved nothing (vacuous-pass floor)")
    sys.exit(1)

bad = []
tier_seen = 0
for tag, d in jobs:
    name = d["metadata"]["name"]
    ann = (d.get("metadata") or {}).get("annotations") or {}
    hook = ann.get("helm.sh/hook") or ""
    hooks = set(h.strip() for h in hook.split(",") if h.strip())

    if tag == "hub_schema":
        expect = {"post-install", "pre-upgrade"}
        if hooks != expect:
            bad.append(f"FAIL: Job/{name} (hub, not lookup-gated) expected exactly {sorted(expect)}, got {sorted(hooks)}")
    elif tag == "hub_topic":
        expect = {"post-install", "pre-upgrade", "post-rollback"}
        if hooks != expect:
            bad.append(f"FAIL: Job/{name} (hub, not lookup-gated) expected exactly {sorted(expect)}, got {sorted(hooks)}")
    elif tag == "tier_schema":
        tier_seen += 1
        expect = {"post-upgrade"} if is_upgrade_mode else {"post-install"}
        if hooks != expect:
            bad.append(f"FAIL: Job/{name} (lookup-gated, {mode_label} render) expected exactly {sorted(expect)}, got {sorted(hooks)}")
    elif tag == "tier_topic":
        tier_seen += 1
        base = "post-upgrade" if is_upgrade_mode else "post-install"
        expect = {base, "post-rollback"}
        if hooks != expect:
            bad.append(f"FAIL: Job/{name} (lookup-gated, {mode_label} render) expected exactly {sorted(expect)}, got {sorted(hooks)}")

    # Content-level checks on the bounded-wait logic -- the hook-annotation
    # checks above cannot tell a gutted wait script from an intact one.
    script = script_text(d)
    if tag in ("tier_schema",):
        if not BOUND_RE.search(script):
            bad.append(f"FAIL: Job/{name} wait-postgres has no 300s (150-attempt) bound")
        if "SCHEMA_INIT_REFUSED" not in script:
            bad.append(f"FAIL: Job/{name} wait-postgres never logs SCHEMA_INIT_REFUSED on timeout")
    if tag in ("hub_topic", "tier_topic"):
        if not BOUND_RE.search(script):
            bad.append(f"FAIL: Job/{name} broker wait has no 300s (150-attempt) bound")
        if "TOPIC_INIT_REFUSED" not in script:
            bad.append(f"FAIL: Job/{name} broker wait never logs TOPIC_INIT_REFUSED on timeout")

if os.environ.get("GUARD8_EXPECT_TIER_JOBS") == "1" and tier_seen == 0:
    bad.append("FAIL: tierNode.enabled=true rendered no tier schema-init/topic-init Jobs -- vacuous-pass floor")

for b in bad:
    print("  " + b)
print(f"  jobs checked: {len(jobs)}, tier jobs: {tier_seen}")
sys.exit(1 if bad else 0)
'; }

g8_lookup_gate_out=$(g8_lookup_gate)
g8_lookup_gate_status=$?
printf '%s\n' "$g8_lookup_gate_out"
[ "$g8_lookup_gate_status" -ne 0 ] && fail=1

for variant in "install:" "tiernode-install:--set tierNode.enabled=true" "tiernode-upgrade:--set tierNode.enabled=true --is-upgrade"; do
  vname="${variant%%:*}"
  vargs="${variant#*:}"
  # shellcheck disable=SC2086
  case "$vname" in
    tiernode-install) g8_out=$(GUARD8_EXPECT_TIER_JOBS=1 g8 $vargs) ;;
    tiernode-upgrade) g8_out=$(GUARD8_EXPECT_TIER_JOBS=1 GUARD8_IS_UPGRADE=1 g8 $vargs) ;;
    *) g8_out=$(g8 $vargs) ;;
  esac
  status=$?
  printf '%s\n' "$g8_out" | sed "s/^/  [$vname] /"
  [ "$status" -ne 0 ] && fail=1
done

# --- guard 8 (extended): every broker the chart creates gets exactly one ---
# ---                     topic-init Job -----------------------------------
# THE DEFECT MODELLED (round 3, found by inspection before it shipped):
# topic-init-<id> rendered from tier-node.yaml, gated by `tierNode.enabled`
# AND `tierNode.tiers` -- a predicate strictly narrower than the broker
# StatefulSet loop's own (infrastructure.yaml: every edge unconditionally, a
# region only when tier-managed). A default render, or a `tierNode.tiers`
# subset excluding an edge, rendered that edge's broker with NO topic-init:
# every topic on it would then exist only through auto-create, at broker
# defaults (`cleanup.policy=delete` on a topic that must be retained by
# KEY). Round 4 moved the Job into infrastructure.yaml, into the SAME
# range/if the broker StatefulSet renders from, so the two cannot drift
# apart by construction. This guard checks that structurally, across both
# the default chart shape and the shape that most directly models the
# defect (a tier-node subset that excludes an edge), rather than trusting
# the file move by inspection.
#
# Three things checked per render:
#   1. the set of non-hq <rel>-redpanda-<id> StatefulSets equals the set of
#      <rel>-topic-init-<id> Jobs -- same cardinality AND same ids, not just
#      the same count (a swapped id would pass a count-only check);
#   2. each such Job's `rpk ... -X brokers=` target names ITS OWN tier's
#      broker Service, not another tier's or the hub's;
#   3. the topic spec set (the quoted "name|args" strings fed to the create
#      loop) is IDENTICAL across every per-broker Job, and that common set
#      is a subset of the hub Job's spec set -- the hub's extra specs are
#      its HQ-only block (egress-c2-status et al.), never named here by
#      value so this guard does not have to track that list by hand.
echo
echo "guard 8 (extended): every broker gets exactly one topic-init Job"

g8_coverage() { render "$@" | "$PY" -c '
import re, sys, yaml

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]

STS_RE = re.compile(r"^t-redpanda-(?!hq$)(.+)$")
JOB_RE = re.compile(r"^t-topic-init-(.+)$")

def script_text(d):
    pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
    text = []
    for c in (pod.get("initContainers") or []) + (pod.get("containers") or []):
        text.extend(str(x) for x in (c.get("command") or []) + (c.get("args") or []))
    return "\n".join(text)

broker_ids = set()
job_ids = set()
job_by_id = {}
hub_job = None
for d in docs:
    name = (d.get("metadata") or {}).get("name") or ""
    if d.get("kind") == "StatefulSet":
        m = STS_RE.match(name)
        if m:
            broker_ids.add(m.group(1))
    elif d.get("kind") == "Job":
        if name == "t-topic-init":
            hub_job = d
        m = JOB_RE.match(name)
        if m:
            job_ids.add(m.group(1))
            job_by_id[m.group(1)] = d

bad = []
if not broker_ids:
    bad.append("FAIL: no non-hq redpanda StatefulSets matched -- vacuous-pass floor")
if hub_job is None:
    bad.append("FAIL: no hub topic-init Job (t-topic-init) matched -- vacuous-pass floor")

if broker_ids != job_ids:
    missing = broker_ids - job_ids
    extra = job_ids - broker_ids
    if missing:
        bad.append(f"FAIL: broker(s) with NO topic-init Job: {sorted(missing)}")
    if extra:
        bad.append(f"FAIL: topic-init Job(s) with NO matching broker: {sorted(extra)}")

SPEC_RE = re.compile(r"\"([a-z0-9][a-z0-9.-]*\|[^\"]*)\"")

def specs_of(d):
    return set(SPEC_RE.findall(script_text(d)))

for tid, d in job_by_id.items():
    text = script_text(d)
    if f"brokers=t-redpanda-{tid}" not in text:
        bad.append(f"FAIL: Job/t-topic-init-{tid} rpk broker does not target its own tier (t-redpanda-{tid})")

tier_spec_sets = {tid: specs_of(d) for tid, d in job_by_id.items()}
distinct = set(frozenset(s) for s in tier_spec_sets.values())
if len(distinct) > 1:
    bad.append(f"FAIL: per-broker topic spec sets are not identical across tiers: {sorted(len(s) for s in tier_spec_sets.values())} spec counts seen")
elif tier_spec_sets:
    common = next(iter(distinct))
    if not common:
        bad.append("FAIL: per-broker topic spec set is empty -- vacuous-pass floor")
    elif hub_job is not None:
        hub_specs = specs_of(hub_job)
        if not common <= hub_specs:
            bad.append(f"FAIL: per-broker topic spec set is not a subset of the hub Jobs spec set: extra={sorted(common - hub_specs)}")

common_count = len(next(iter(distinct))) if distinct and len(distinct) == 1 else "n/a"
for b in bad:
    print("  " + b)
print(f"  brokers: {len(broker_ids)}, topic-init Jobs: {len(job_ids)}, common spec count: {common_count}")
sys.exit(1 if bad else 0)
'; }

for variant in "default:" "default-upgrade:--is-upgrade" "tiernode-all:--set tierNode.enabled=true" "tiernode-subset:--set tierNode.enabled=true --set tierNode.tiers={edge-01\\,edge-03}"; do
  vname="${variant%%:*}"
  vargs="${variant#*:}"
  # shellcheck disable=SC2086
  out=$(g8_coverage $vargs)
  status=$?
  printf '%s\n' "$out" | sed "s/^/  [$vname] /"
  [ "$status" -ne 0 ] && fail=1
done


# --- guard 9: TAK mutual-TLS sidecar --------------------------------------
# THE SHAPE BEING GUARDED: taky (egress.tak) stays plaintext on its own port
# always; a ghostunnel sidecar terminating mutual TLS is strictly OPT IN
# (egress.tak.tls.enabled), and even then only renders with BOTH a cert
# Secret name and at least one admitted CN -- a half-configured listener
# (open port, no way to admit or refuse anyone) must never render quietly.
echo
echo "guard 9: TAK mutual-TLS sidecar"

echo "  9a: default render, and tak-enabled-without-tls, carry no trace of it"
for g9a_variant in "default:" \
    "tak-only:--set releasability.enabled=true --set releasability.lockDownElectric=true --set egress.tak.enabled=true"; do
  vname="${g9a_variant%%:*}"
  vargs="${g9a_variant#*:}"
  # shellcheck disable=SC2086
  g9a_out=$(render $vargs | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
bad = []
for d in docs:
    pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
    kind = d.get("kind")
    name = (d.get("metadata") or {}).get("name", "")
    for c in pod.get("containers") or []:
        if c.get("name") == "tls-proxy":
            bad.append(f"tls-proxy container on {kind}/{name}")
    if kind == "Service" and name.endswith("-tak-server-tls"):
        bad.append(f"Service {name}")
    if kind == "NetworkPolicy":
        for rule in (d.get("spec") or {}).get("ingress") or []:
            for p in rule.get("ports") or []:
                if p.get("port") == 8089:
                    bad.append(f"NetworkPolicy {name} has port 8089")
if bad:
    print("FAIL: " + "; ".join(bad)); sys.exit(1)
print("ok: no tls-proxy container, no -tak-server-tls Service, no 8089 in any NetworkPolicy")
')
  status=$?
  printf '%s\n' "$g9a_out" | sed "s/^/  [$vname] 9a: /"
  [ "$status" -ne 0 ] && fail=1
done

TAK_ARGS="--set releasability.enabled=true --set releasability.lockDownElectric=true --set egress.tak.enabled=true"
TLS_ARGS="$TAK_ARGS --set egress.tak.tls.enabled=true --set egress.tak.tls.secretName=guard9-secret --set-json egress.tak.tls.allowedClientCNs=[\"guard9-cn-a\",\"guard9-cn-b\"]"

g9_rule87() { "$PY" -c '
import sys, yaml, json
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
for d in docs:
    if d.get("kind") == "NetworkPolicy" and (d.get("metadata") or {}).get("name", "").endswith("-tak-server-readers-only"):
        for rule in (d.get("spec") or {}).get("ingress") or []:
            if any(p.get("port") == 8087 for p in (rule.get("ports") or [])):
                print(json.dumps(rule, sort_keys=True)); sys.exit(0)
print("MISSING")
'; }
# shellcheck disable=SC2086
g9_rule_tak=$(render $TAK_ARGS | g9_rule87)
# shellcheck disable=SC2086
g9_rule_tls=$(render $TLS_ARGS | g9_rule87)
if [ "$g9_rule_tak" = MISSING ] || [ "$g9_rule_tls" = MISSING ]; then
  echo "  FAIL [9b]: readers-only 8087 rule missing in one of the two renders (tak-only or tak+tls)"; fail=1
elif [ "$g9_rule_tak" != "$g9_rule_tls" ]; then
  echo "  FAIL [9b]: the readers-only 8087 rule differs between tak-only and tak+tls renders"
  echo "    tak-only: $g9_rule_tak"
  echo "    tak+tls : $g9_rule_tls"
  fail=1
else
  echo "  ok   [9b]: readers-only 8087 rule is byte-for-byte identical with TLS on or off"
fi

# shellcheck disable=SC2086
render $TLS_ARGS | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
bad = []
sidecar = None
for d in docs:
    if d.get("kind") == "Deployment" and (d.get("metadata") or {}).get("name", "").endswith("-tak-server"):
        for c in d["spec"]["template"]["spec"].get("containers") or []:
            if c.get("name") == "tls-proxy":
                sidecar = c
if sidecar is None:
    print("  FAIL [9c]: no tls-proxy sidecar in the tak-server Deployment"); sys.exit(1)
args = sidecar.get("args") or []
for cn in ("guard9-cn-a", "guard9-cn-b"):
    if not any(a == "--allow-cn" and i + 1 < len(args) and args[i + 1] == cn for i, a in enumerate(args)):
        bad.append(f"no --allow-cn {cn}")
if "127.0.0.1:8087" not in args:
    bad.append("sidecar does not target 127.0.0.1:<tak.port>")
tls_svc = next((d for d in docs if d.get("kind") == "Service"
                 and (d.get("metadata") or {}).get("name", "").endswith("-tak-server-tls")), None)
if tls_svc is None:
    bad.append("no -tak-server-tls Service rendered")
elif not any(p.get("port") == 8089 for p in tls_svc["spec"]["ports"]):
    svc_ports = tls_svc["spec"]["ports"]
    bad.append(f"TLS Service port != tls.port (8089): {svc_ports}")
rule_count = 0
for d in docs:
    if d.get("kind") == "NetworkPolicy" and (d.get("metadata") or {}).get("name", "").endswith("-tak-server-readers-only"):
        for rule in (d.get("spec") or {}).get("ingress") or []:
            if any(p.get("port") == 8089 for p in (rule.get("ports") or [])):
                rule_count += 1
if rule_count != 1:
    bad.append(f"expected exactly one ingress rule on tls.port (8089), found {rule_count}")
if bad:
    print("  FAIL [9c]: " + "; ".join(bad)); sys.exit(1)
print("  ok   [9c]: sidecar carries --allow-cn per CN and targets 127.0.0.1:8087; TLS Service on 8089; exactly one NetworkPolicy rule on 8089")
' || fail=1

g9_fail_check() {
  local desc="$1"; shift
  local err status
  err=$(helm template t "$CHART" "$@" 2>&1 >/dev/null)
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "  FAIL [9d]: $desc did not fail the render"
    fail=1
  else
    echo "  ok   [9d]: $desc fails the render ($(printf '%s' "$err" | grep -m1 'egress.tak.tls' | sed 's/^Error: execution error at.*: //'))"
  fi
}
g9_fail_check "empty secretName" --set releasability.enabled=true --set egress.tak.enabled=true \
  --set egress.tak.tls.enabled=true --set-json 'egress.tak.tls.allowedClientCNs=["guard9-cn"]'
g9_fail_check "empty allowedClientCNs" --set releasability.enabled=true --set egress.tak.enabled=true \
  --set egress.tak.tls.enabled=true --set egress.tak.tls.secretName=guard9-secret

# --- guard 10: hub frontend deployment-config carries the egress pane ------
# ---           destination (wiring committed in 6f17554) ------------------
# Persists the check that was run once by hand when 6f17554 landed:
# releasability.enabled=true must put the SAME egress.destination the gate
# and topaz-hq already use into the hub frontend's deployment.json, as valid
# JSON, under egressPane.destination -- and a default render must carry no
# such ConfigMap at all (nothing for a non-releasability deployment to leak).
echo
echo "guard 10: hub frontend deployment-config carries the egress pane destination"

render | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
bad = [d["metadata"]["name"] for d in docs
       if d.get("kind") == "ConfigMap" and d["metadata"]["name"].endswith("-frontend-deployment-config")]
if bad:
    print("  FAIL [10 default]: default render has a hub deployment-config ConfigMap: " + ", ".join(bad)); sys.exit(1)
print("  ok   [10 default]: no hub frontend-deployment-config ConfigMap by default")
' || fail=1

g10_dest() { render --set releasability.enabled=true "$@" | "$PY" -c '
import sys, yaml, json
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "ConfigMap" and d["metadata"]["name"].endswith("-frontend-deployment-config"):
        try:
            parsed = json.loads(d["data"]["deployment.json"])
        except Exception as e:
            print("PARSE_ERROR:" + str(e)); sys.exit(0)
        print((parsed.get("egressPane") or {}).get("destination") or "MISSING")
        sys.exit(0)
print("NO_CONFIGMAP")
'; }
g10_default_dest=$(g10_dest)
g10_changed_dest=$(g10_dest --set egress.destination=guard10-changed-destination)
case "$g10_default_dest$g10_changed_dest" in
  *PARSE_ERROR:*)
    echo "  FAIL [10 enabled]: deployment.json did not parse as JSON ($g10_default_dest / $g10_changed_dest)"; fail=1 ;;
  *NO_CONFIGMAP*)
    echo "  FAIL [10 enabled]: no hub frontend-deployment-config ConfigMap with releasability.enabled=true"; fail=1 ;;
  *)
    if [ "$g10_changed_dest" != "guard10-changed-destination" ]; then
      echo "  FAIL [10 enabled]: egressPane.destination ($g10_changed_dest) did not follow an egress.destination override"
      fail=1
    else
      echo "  ok   [10 enabled]: deployment.json parses; egressPane.destination == egress.destination ($g10_default_dest by default, follows overrides)"
    fi
    ;;
esac


# --- guard 11: a destination's client secret mounts only into the --------
# ---           forwarder and intake, read-only, and the chart never ------
# ---           renders it -------------------------------------------------
# THE SHAPE BEING GUARDED: egress.credentials.existingSecret names a Secret
# created OUT OF BAND for a destination's OAuth2 client_credentials grant.
# The chart's only job is the mount: the whole Secret, read-only, at
# /etc/openddil/egress-credentials/, into egress-forwarder and egress-intake
# ONLY -- never creating, rendering or reading the Secret's own value, and
# never mounting it into any other pod. Empty (the default) must leave no
# trace of it anywhere.
echo
echo "guard 11: destination client-secret mounts only into forwarder/intake"

CRED_ARGS="--set releasability.enabled=true --set egress.forwarder.enabled=true --set egress.intake.enabled=true --set egress.credentials.existingSecret=example-creds"

# shellcheck disable=SC2086
render $CRED_ARGS | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
CRED_PATH = "/etc/openddil/egress-credentials"
bad = []
mounted = []
for d in docs:
    kind = d.get("kind")
    name = (d.get("metadata") or {}).get("name", "")
    if kind == "Secret" and name == "example-creds":
        bad.append("rendered Secret/" + name + " -- the chart must never create this Secret")
    if kind != "Deployment":
        continue
    pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
    for c in pod.get("containers") or []:
        cname = c.get("name")
        for vm in c.get("volumeMounts") or []:
            mp = (vm.get("mountPath") or "").rstrip("/")
            if mp == CRED_PATH:
                mounted.append((name, cname))
                if not vm.get("readOnly"):
                    bad.append(name + "/" + str(cname) + ": mount is not readOnly")
expected_suffixes = ("-egress-forwarder", "-egress-intake")
unexpected = [n for n, _ in mounted if not n.endswith(expected_suffixes)]
if unexpected:
    bad.append("mounted into unexpected pod(s): " + ", ".join(sorted(set(unexpected))))
missing = [suf for suf in expected_suffixes if not any(n.endswith(suf) for n, _ in mounted)]
if missing:
    bad.append("not mounted into: " + ", ".join(missing))
if bad:
    print("  FAIL: " + "; ".join(bad))
    sys.exit(1)
print("  ok   : mounted read-only into exactly forwarder+intake (" + str(len(mounted)) + " container(s)); no Secret/example-creds rendered")
' || fail=1

# Empty (default) existingSecret: no egress-credentials mount or volume
# anywhere -- the vacuous-pass floor for the guard above.
render --set releasability.enabled=true --set egress.forwarder.enabled=true --set egress.intake.enabled=true | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
CRED_PATH = "/etc/openddil/egress-credentials"
bad = []
for d in docs:
    if d.get("kind") != "Deployment":
        continue
    name = (d.get("metadata") or {}).get("name", "")
    pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
    for c in pod.get("containers") or []:
        for vm in c.get("volumeMounts") or []:
            mp = (vm.get("mountPath") or "").rstrip("/")
            if mp == CRED_PATH:
                bad.append(name + "/" + str(c.get("name")) + " mounts egress-credentials with existingSecret empty")
    for v in pod.get("volumes") or []:
        if "egress-credentials" in (v.get("name") or ""):
            bad.append(name + " declares an egress-credentials volume with existingSecret empty")
if bad:
    print("  FAIL: " + "; ".join(bad))
    sys.exit(1)
print("  ok   : existingSecret empty -- no egress-credentials mount or volume anywhere")
' || fail=1

# --- guard 12: every Kafka-producing workload declares produces-topics -----
# THE DEFECT MODELLED: openddil.io/produces-topics is declared beside
# openddil.io/consumer-groups so reset-scenario.sh can tell which
# Deployment/StatefulSet to quiesce for a topic it finds live local
# writes on. A Deployment/StatefulSet that sets one of the env
# vars below but carries no (or a malformed) produces-topics annotation is
# exactly the gap the writer census halts on, undetected, at render time.
#
# ENV VAR NAMES ENUMERATED (one appearance in any container is enough to
# mark the workload a known Kafka producer):
#   KAFKA_TOPIC                 sensor-ingest
#   FAUST_APP_ID                faust-edge, faust-regional
#   CM_KAFKA_BROKERS             cm-service, tier-cm-<id>
#   FUSION_KAFKA_BROKERS         logistics-fusion-service, tier-fusion-<id>
#   ASSET_REGISTRY_OUTPUT_TOPIC  asset-registry-service
#   LOGISTICS_SIM_HQ_BROKERS     logistics-sim
#   OPENDDIL_EGRESS_SINK_TOPIC   egress-gate-c2
#   REGIONAL_FAN_IN_TOPIC        faust-regional
# This is NOT every writer in the chart (egress-assembler/egress-intake
# carry none of these env vars; guard 13 checks their declarations) and
# bridges are excluded on purpose (their own comment explains why; they
# forward, not originate).
echo
echo "guard 12: every Kafka-producing workload declares produces-topics"
render --set releasability.enabled=true \
       --set egress.assembler.enabled=true \
       --set egress.intake.enabled=true \
       --set tierNode.enabled=true \
       --set-string tierNode.tiers[0]=region-east | "$PY" -c '
import sys, re, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
PRODUCER_ENV_NAMES = {
    "KAFKA_TOPIC", "FAUST_APP_ID", "CM_KAFKA_BROKERS", "FUSION_KAFKA_BROKERS",
    "ASSET_REGISTRY_OUTPUT_TOPIC", "LOGISTICS_SIM_HQ_BROKERS",
    "OPENDDIL_EGRESS_SINK_TOPIC", "REGIONAL_FAN_IN_TOPIC",
}
PAIR_RE = re.compile(r"^[^/\s]+/[^/\s]+$")
missing, malformed, checked = [], [], 0
for d in docs:
    kind = d.get("kind")
    if kind not in ("Deployment", "StatefulSet"):
        continue
    pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
    env_names = set()
    for c in (pod.get("containers") or []) + (pod.get("initContainers") or []):
        for e in c.get("env") or []:
            if e.get("name"):
                env_names.add(e["name"])
    hit = env_names & PRODUCER_ENV_NAMES
    if not hit:
        continue
    checked += 1
    name = (d.get("metadata") or {}).get("name", "")
    ann = ((d.get("metadata") or {}).get("annotations") or {})
    value = ann.get("openddil.io/produces-topics")
    label = kind + "/" + name
    if not value:
        missing.append(label + " (env: " + str(sorted(hit)) + ")")
        continue
    bad_pairs = [p for p in value.split() if not PAIR_RE.match(p)]
    if not value.split() or bad_pairs:
        malformed.append(label + ": " + repr(value))
if checked == 0:
    print("  FAIL: no workload with a known Kafka-producer env var was rendered -- this guard proved nothing")
    sys.exit(1)
if missing or malformed:
    if missing:
        print("  FAIL: missing openddil.io/produces-topics: " + "; ".join(missing))
    if malformed:
        print("  FAIL: malformed openddil.io/produces-topics pair(s): " + "; ".join(malformed))
    sys.exit(1)
print(f"  ok   : {checked} known Kafka-producing workload(s), all declare a well-formed produces-topics annotation")
' || fail=1

# --- guard 13: each declaration covers what its workload writes ------------
# THE DEFECT MODELLED: guard 12 passes on ANY well-formed annotation, so a
# workload that declares one topic but writes four is invisible until a
# live census halts on the other three. This guard renders a fixture with
# two extra egress routes, two assembler entries (one duplicate output) and
# one intake entry, then checks each workload's declaration is a SUPERSET
# of what it writes:
#   faust-edge-<e>         the app's four send targets (code defaults in the
#                          app, pinned here) + its two table changelogs
#   redpanda-connect-<e>   raw-sensor-stream, effector-events, ingress-dlq
#   cm-service / fusion    their state topic + tactical-events
#   egress-gate-c2         every route's sink_topic (c2's + the fixture's)
#   egress-assembler       every entry's output_topic
#   egress-intake          every entry's onward_topic
#   tier-cm / tier-fusion  their state topic + tactical-events, tier broker
#   tier-cm-intake         cm-events, tier broker
#   cm-intake (hub)        cm-events, hub broker
echo
echo "guard 13: each produces-topics declaration covers what its workload writes"
G13_VALUES="$(mktemp)"
cat > "$G13_VALUES" <<'G13'
releasability:
  enabled: true
tierNode:
  enabled: true
  tiers: [region-east]
cmReports:
  enabled: true
egress:
  routes:
    - {name: g13-a, source_topic: g13-src, destination: "system:g13-a", sink_topic: g13-sink-a}
    - {name: g13-b, source_topic: g13-src, destination: "system:g13-b", sink_topic: g13-sink-b}
  assembler:
    enabled: true
    config:
      - {name: g13-a1, trigger_topic: g13-t1, output_topic: g13-out}
      - {name: g13-a2, trigger_topic: g13-t2, output_topic: g13-out}
  intake:
    enabled: true
    config:
      - {name: g13-i1, onward_topic: g13-onward}
G13
render -f "$G13_VALUES" | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
decl = {}
for d in docs:
    if d.get("kind") not in ("Deployment", "StatefulSet"):
        continue
    md = d.get("metadata") or {}
    v = (md.get("annotations") or {}).get("openddil.io/produces-topics")
    decl[md.get("name", "")] = set((v or "").split())
FAUST_EDGE_SENDS = ["telemetry-latest-state", "asset-telemetry-windows",
                    "tactical-events", "derived-sustainment"]
FAUST_EDGE_TABLES = ["asset_state", "prognostics_accumulators"]
CONNECT_SENDS = ["raw-sensor-stream", "effector-events", "ingress-dlq"]
want = {}
for name in decl:
    if "-faust-edge-" in name:
        e = name.split("-faust-edge-", 1)[1]
        want[name] = {f"{e}/{t}" for t in FAUST_EDGE_SENDS} | \
                     {f"{e}/openddil-{e}-{t}-changelog" for t in FAUST_EDGE_TABLES}
    elif "-redpanda-connect-" in name:
        e = name.split("-redpanda-connect-", 1)[1]
        want[name] = {f"{e}/{t}" for t in CONNECT_SENDS}
    elif name.endswith("-cm-service"):
        want[name] = {"hq/asset-cm-state", "hq/tactical-events"}
    elif name.endswith("-logistics-fusion-service"):
        want[name] = {"hq/asset-logistics-status", "hq/tactical-events"}
    elif name.endswith("-egress-gate-c2"):
        want[name] = {"hq/g13-sink-a", "hq/g13-sink-b"}
    elif name.endswith("-egress-assembler"):
        want[name] = {"hq/g13-out"}
    elif name.endswith("-egress-intake"):
        want[name] = {"hq/g13-onward"}
    elif "-tier-cm-intake-" in name:
        t = name.split("-tier-cm-intake-", 1)[1]
        want[name] = {f"{t}/cm-events"}
    elif name.endswith("-cm-intake"):
        want[name] = {"hq/cm-events"}
    elif "-tier-cm-" in name:
        t = name.split("-tier-cm-", 1)[1]
        want[name] = {f"{t}/asset-cm-state", f"{t}/tactical-events"}
    elif "-tier-fusion-" in name:
        t = name.split("-tier-fusion-", 1)[1]
        want[name] = {f"{t}/asset-logistics-status", f"{t}/tactical-events"}
kinds = {"faust-edge", "redpanda-connect", "cm-service", "logistics-fusion-service",
         "egress-gate-c2", "egress-assembler", "egress-intake",
         "tier-cm-intake-", "tier-cm-", "tier-fusion-", "-cm-intake$"}
# A trailing "$" anchors at the end of the name: the hub cm-intake is a
# substring of every tier-cm-intake-<t>, so plain "in" could not tell
# whether the hub one rendered.
seen = {k for k in kinds for n in want
        if (n.endswith(k[:-1]) if k.endswith("$") else k in n)}
fail = False
if seen != kinds:
    print("  FAIL: fixture did not render: " + ", ".join(sorted(kinds - seen)) + " -- this guard proved nothing for them")
    fail = True
for name in sorted(want):
    short = want[name] - decl[name]
    if short:
        print(f"  FAIL: {name} writes but does not declare: {sorted(short)}")
        fail = True
if fail:
    sys.exit(1)
print(f"  ok   : {len(want)} workload(s), every declaration covers its writes")
' || fail=1
rm -f "$G13_VALUES"

echo
[ "$fail" -eq 0 ] && echo "chart render guards: clean" || echo "chart render guards: FAILED"
exit "$fail"
