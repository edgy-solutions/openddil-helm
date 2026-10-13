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

# Guard 6: the egress gate must never sit on an old destinations registry.
# Two ways to meet that, one per releasability.liveReload mode:
#   off -- the gate resolves each route's destination from topaz-hq once, at
#          startup, so it must carry the same registry checksum as topaz-hq
#          and that checksum must move when the destinations registry moves;
#   on  -- the gate re-asks topaz-hq every OPENDDIL_REGISTRY_REFRESH_S, so the
#          refresh must be non-zero, and a destinations change must NOT roll
#          the gate (that roll is exactly what live reload exists to avoid).
# Defect model: drop checksum/registries from the gate or key it to something
# other than releasability.destinations (off); render the refresh as "0", or
# let the destinations leak back into the checksum (on).
echo
echo "guard 6: egress gate follows the destinations registry"
g6() { render --set releasability.enabled=true "$@" | "$PY" -c '
import sys, yaml
want = {"openddil-egress-gate-c2": "checksum/registries", "openddil-topaz-hq": "checksum/policy"}
got = {}
refresh = "MISSING"
for d in yaml.safe_load_all(sys.stdin):
    if d and d.get("kind") == "Deployment":
        n = d["metadata"]["name"].replace("t-", "openddil-", 1)
        if n in want:
            got[n] = ((d["spec"]["template"]["metadata"].get("annotations") or {}).get(want[n]) or "")
        if n == "openddil-egress-gate-c2":
            for c in d["spec"]["template"]["spec"]["containers"]:
                for e in c.get("env") or []:
                    if e.get("name") == "OPENDDIL_REGISTRY_REFRESH_S":
                        refresh = str(e.get("value"))
print(" ".join(got.get(n, "") or "MISSING" for n in want), refresh)
'; }
off=(--set releasability.liveReload.enabled=false)
read -r g6_gate g6_topaz g6_ref <<<"$(g6 "${off[@]}")"
read -r g6_gate2 g6_topaz2 _ <<<"$(g6 "${off[@]}" --set releasability.destinations.version=guard6-changed)"
if [ "$g6_gate" = MISSING ] || [ "$g6_topaz" = MISSING ] || [ -z "$g6_gate" ]; then
  echo "  FAIL [off]: gate=$g6_gate topaz-hq=$g6_topaz -- an annotation is missing (or neither rendered: vacuous)"; fail=1
elif [ "$g6_gate" != "$g6_topaz" ]; then
  echo "  FAIL [off]: gate checksum/registries ($g6_gate) != topaz-hq checksum/policy ($g6_topaz)"; fail=1
elif [ "$g6_gate2" = "$g6_gate" ]; then
  echo "  FAIL [off]: changing releasability.destinations did not change the gate's checksum/registries"; fail=1
elif [ "$g6_gate2" != "$g6_topaz2" ]; then
  echo "  FAIL [off]: after a destinations change, gate ($g6_gate2) != topaz-hq ($g6_topaz2)"; fail=1
else
  echo "  ok   [off]: gate == topaz-hq, and both move with releasability.destinations"
fi
on=(--set releasability.liveReload.enabled=true)
read -r g6_gate g6_topaz g6_ref <<<"$(g6 "${on[@]}")"
read -r g6_gate2 _ _ <<<"$(g6 "${on[@]}" --set releasability.destinations.version=guard6-changed)"
if [ "$g6_gate" = MISSING ] || [ -z "$g6_gate" ]; then
  echo "  FAIL [on]: gate checksum/registries missing (or the gate did not render: vacuous)"; fail=1
elif ! [ "$g6_ref" -gt 0 ] 2>/dev/null; then
  echo "  FAIL [on]: gate OPENDDIL_REGISTRY_REFRESH_S is '$g6_ref' -- with no refresh, an unrolled gate keeps the old registry"; fail=1
elif [ "$g6_gate2" != "$g6_gate" ]; then
  echo "  FAIL [on]: a destinations change rolled the gate (checksum/registries moved) -- live reload should carry it"; fail=1
else
  echo "  ok   [on]: gate refreshes every ${g6_ref}s, and a destinations change does not roll it"
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
            "OPENDDIL_EGRESS_KINDS_DIR", "PGHOST", "PGPASSWORD", "OPENDDIL_TOPAZ_URL"}
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

# 7d: the default render may carry a hub deployment-config for the child-link
# meter (since 0.1.109); it must stay free of releasability or records-pane
# content: only childLinks, and no egressPane or released-records panes.
render | "$PY" -c '
import sys, yaml, json
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms = [d for d in docs if d.get("kind") == "ConfigMap"
       and d["metadata"]["name"].endswith("-frontend-deployment-config")]
for cm in cms:
    try:
        cfg = json.loads((cm.get("data") or {})["deployment.json"])
    except Exception as e:
        print("  FAIL [7d-default]: deployment.json missing or not JSON in " + cm["metadata"]["name"] + ": " + str(e)); sys.exit(1)
    if not isinstance(cfg, dict):
        print("  FAIL [7d-default]: deployment.json is not a JSON object in " + cm["metadata"]["name"]); sys.exit(1)
    extra = sorted(k for k in cfg if k not in ("childLinks", "releasedRecordsPanes", "effectors", "movement"))
    if cfg.get("effectors") != {"declaredLoad": {"asset": {}, "variant": {}}} or cfg.get("movement") != {"standards": {}, "units": []}:
        print("  FAIL [7d-default]: default effectors/movement are not the empty declared inputs: " + json.dumps({k: cfg.get(k) for k in ("effectors", "movement")})); sys.exit(1)
    if extra:
        print("  FAIL [7d-default]: default hub deployment-config carries key: " + ", ".join(extra)); sys.exit(1)
    if cfg.get("releasedRecordsPanes"):
        print("  FAIL [7d-default]: default hub deployment-config carries releasedRecordsPanes"); sys.exit(1)
print("  ok   [7d-default]: default hub deployment-config carries no pane content (child links only)")
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
if set(got.keys()) - {"effectors", "movement"} != {"releasedRecordsPanes"}:
    print(f"  FAIL [7e]: hub deployment.json has extra keys: {sorted(got.keys())}"); sys.exit(1)
if not tiers:
    print("  FAIL [7e]: no tier-frontend-config ConfigMaps rendered with tierNode.enabled=true -- cannot check absence"); sys.exit(1)
leaked = [d["metadata"]["name"] for d in tiers if "releasedRecordsPanes" in (d["data"].get("deployment.json") or "")]
if leaked:
    print("  FAIL [7e]: releasedRecordsPanes leaked into tier config(s): " + ", ".join(leaked)); sys.exit(1)
print(f"  ok   [7e]: hub carries releasedRecordsPanes; {len(tiers)} tier-frontend-config(s) do not")
' || fail=1

# 7f: the move panel's declared inputs (effectors.declaredLoad, movement) reach
# the hub's and every tier's deployment.json unchanged, from one helper. The
# default render carries them empty (7d); here a declared value must arrive
# identically everywhere, or a tier's panel would show other numbers.
render --set tierNode.enabled=true   --set-json 'movement={"standards":{"V1":{"marchOrderS":60,"emplaceS":45,"fuelTank":{"value":300,"unit":"L"},"fuelBurnPerKm":{"value":2,"unit":"L/km"}}},"units":[{"id":"u1","label":"U1","members":["a1","a2"],"plannedMoveKm":0.9}]}'   --set-json 'effectors.declaredLoad={"asset":{"a2":{"1.2.3.4.5.6.7":5}},"variant":{}}'   | "$PY" -c '
import sys, yaml, json
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
want_m = {"standards": {"V1": {"marchOrderS": 60, "emplaceS": 45, "fuelTank": {"value": 300, "unit": "L"}, "fuelBurnPerKm": {"value": 2, "unit": "L/km"}}}, "units": [{"id": "u1", "label": "U1", "members": ["a1", "a2"], "plannedMoveKm": 0.9}]}
want_e = {"declaredLoad": {"asset": {"a2": {"1.2.3.4.5.6.7": 5}}, "variant": {}}}
cms = [d for d in docs if d.get("kind") == "ConfigMap" and (d["metadata"]["name"].endswith("-frontend-deployment-config") or "-tier-frontend-config-" in d["metadata"]["name"])]
hub = [d for d in cms if d["metadata"]["name"].endswith("-frontend-deployment-config")]
tiers = [d for d in cms if "-tier-frontend-config-" in d["metadata"]["name"]]
if len(hub) != 1 or not tiers:
    print(f"  FAIL [7f]: want 1 hub and >=1 tier deployment config, got {len(hub)} and {len(tiers)}"); sys.exit(1)
for cm in cms:
    cfg = json.loads(cm["data"]["deployment.json"])
    if cfg.get("movement") != want_m or cfg.get("effectors") != want_e:
        print("  FAIL [7f]: " + cm["metadata"]["name"] + " carries " + json.dumps({k: cfg.get(k) for k in ("effectors", "movement")})); sys.exit(1)
print(f"  ok   [7f]: declared effectors and movement reach the hub and {len(tiers)} tier config(s) unchanged")
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
# JSON, under egressPane.destination. A default render may carry a
# deployment-config for the child-link meter (since 0.1.109), but never any
# egress pane or released-records pane content.
echo
echo "guard 10: hub frontend deployment-config carries the egress pane destination"

render | "$PY" -c '
import sys, yaml, json
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms = [d for d in docs if d.get("kind") == "ConfigMap"
       and d["metadata"]["name"].endswith("-frontend-deployment-config")]
for cm in cms:
    try:
        cfg = json.loads((cm.get("data") or {})["deployment.json"])
    except Exception as e:
        print("  FAIL [10 default]: deployment.json missing or not JSON in " + cm["metadata"]["name"] + ": " + str(e)); sys.exit(1)
    if not isinstance(cfg, dict):
        print("  FAIL [10 default]: deployment.json is not a JSON object in " + cm["metadata"]["name"]); sys.exit(1)
    extra = sorted(k for k in cfg if k not in ("childLinks", "releasedRecordsPanes", "effectors", "movement"))
    if cfg.get("effectors") != {"declaredLoad": {"asset": {}, "variant": {}}} or cfg.get("movement") != {"standards": {}, "units": []}:
        print("  FAIL [10 default]: default effectors/movement are not the empty declared inputs: " + json.dumps({k: cfg.get(k) for k in ("effectors", "movement")})); sys.exit(1)
    if extra:
        print("  FAIL [10 default]: default hub deployment-config carries key: " + ", ".join(extra)); sys.exit(1)
    if cfg.get("releasedRecordsPanes"):
        print("  FAIL [10 default]: default hub deployment-config carries releasedRecordsPanes"); sys.exit(1)
print("  ok   [10 default]: default hub deployment-config carries no pane content (child links only)")
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
#   LINK_HEARTBEAT_ENABLED       projector-<edge>, tier-projector-<tier>
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
    "OPENDDIL_EGRESS_SINK_TOPIC", "REGIONAL_FAN_IN_TOPIC", "LINK_HEARTBEAT_ENABLED",
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
#   sensor-ingest-<e>      ingress-dis-raw
#   logistics-sim          asset-element-telemetry on each edge (the chart
#                          default element_publish_tier is edge), plus
#                          asset-element-inventory + parts-availability, hq
#   faust-regional-<r>     fan-in, the three region-* outputs and its table
#                          changelog, on the tier broker when <r> is a tier,
#                          else on hq (names as measured on a live broker)
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
TIERS = {"region-east"}
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
    elif "-sensor-ingest-" in name:
        e = name.split("-sensor-ingest-", 1)[1]
        want[name] = {f"{e}/ingress-dis-raw"}
    elif name.endswith("-logistics-sim"):
        edges = {n.split("-faust-edge-", 1)[1] for n in decl if "-faust-edge-" in n}
        want[name] = {f"{e}/asset-element-telemetry" for e in edges} |                      {"hq/asset-element-inventory", "hq/parts-availability"}
    elif "-faust-regional-" in name:
        r = name.split("-faust-regional-", 1)[1]
        b = r if r in TIERS else "hq"
        table = "region_" + r.replace("-", "_") + "_assets_latest"
        want[name] = {f"{b}/{r}-fan-in", f"{b}/region-fleet-summary",
                      f"{b}/region-top-factors", f"{b}/region-wear-trends",
                      f"{b}/region-{r}-aggregator-{table}-changelog"}
    elif "-tier-cm-" in name:
        t = name.split("-tier-cm-", 1)[1]
        want[name] = {f"{t}/asset-cm-state", f"{t}/tactical-events"}
    elif "-tier-fusion-" in name:
        t = name.split("-tier-fusion-", 1)[1]
        want[name] = {f"{t}/asset-logistics-status", f"{t}/tactical-events"}
kinds = {"faust-edge", "redpanda-connect", "cm-service", "logistics-fusion-service",
         "egress-gate-c2", "egress-assembler", "egress-intake",
         "tier-cm-intake-", "tier-cm-", "tier-fusion-", "-cm-intake$",
         "faust-regional-region-east", "faust-regional-region-west",
         "sensor-ingest-", "-logistics-sim$"}
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

# --- guard 14: exercise control renders only when enabled, and validates ---
# its adapter. Mirrors control.py's own startup refusal (empty adapter, or
# an operations key outside pause/resume/stop/restart/run) so a bad map
# fails `helm template`, not a CrashLoop three stages later. See
# templates/exercise-control.yaml and values.yaml exerciseControl.
echo
echo "guard 14: exercise control renders only when enabled, and validates its adapter"

# 14a: default render -- disabled, must be invisible.
render | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
fail = False
pep_env = []
for d in docs:
    name = (d.get("metadata") or {}).get("name") or ""
    if "exercise-control" in name:
        print("  FAIL [14a]: default render has an exercise-control object: " + str(d.get("kind")) + "/" + name)
        fail = True
    if name == "t-pep" and d.get("kind") == "Deployment":
        pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
        for c in pod.get("containers") or []:
            for e in c.get("env") or []:
                pep_env.append(e.get("name"))
if "OPENDDIL_EXERCISE_CONTROL_URL" in pep_env:
    print("  FAIL [14a]: default render root pep carries OPENDDIL_EXERCISE_CONTROL_URL")
    fail = True
if fail:
    sys.exit(1)
print("  ok   [14a]: default render has no exercise-control object and no env on the root pep")
' || fail=1

# 14b: enabled with a valid adapter, and tierNode also on, to prove tier
# peps are excluded. 3 edges in the chart default (edge-01/02/03) -> 3
# rate sources expected.
render --set releasability.enabled=true \
       --set exerciseControl.enabled=true \
       --set exerciseControl.adapter.endpoint=https://example.invalid/api \
       --set exerciseControl.adapter.operations.pause.method=POST \
       --set exerciseControl.adapter.operations.pause.path=/pause \
       --set tierNode.enabled=true \
  | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
fail = False
kinds_seen = set()
pep_env = []
tier_pep_env = []
rate_sources = None
for d in docs:
    kind = d.get("kind")
    name = (d.get("metadata") or {}).get("name") or ""
    if name == "t-exercise-control-adapter" and kind == "ConfigMap":
        kinds_seen.add("ConfigMap")
    if name == "t-exercise-control" and kind == "Service":
        kinds_seen.add("Service")
    if name == "t-exercise-control" and kind == "Deployment":
        kinds_seen.add("Deployment")
        pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
        for c in pod.get("containers") or []:
            for e in c.get("env") or []:
                if e.get("name") == "EXERCISE_RATE_SOURCES":
                    rate_sources = e.get("value") or ""
    if name == "t-exercise-control-only" and kind == "NetworkPolicy":
        kinds_seen.add("NetworkPolicy")
    if name == "t-pep" and kind == "Deployment":
        pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
        for c in pod.get("containers") or []:
            for e in c.get("env") or []:
                pep_env.append(e.get("name"))
    if "tier-pep" in name and kind == "Deployment":
        pod = ((d.get("spec") or {}).get("template") or {}).get("spec") or {}
        for c in pod.get("containers") or []:
            for e in c.get("env") or []:
                tier_pep_env.append(e.get("name"))
want_kinds = {"ConfigMap", "Service", "Deployment", "NetworkPolicy"}
missing_kinds = want_kinds - kinds_seen
if missing_kinds:
    print("  FAIL [14b]: missing object(s): " + str(sorted(missing_kinds)))
    fail = True
if "OPENDDIL_EXERCISE_CONTROL_URL" not in pep_env:
    print("  FAIL [14b]: root pep is missing OPENDDIL_EXERCISE_CONTROL_URL")
    fail = True
if "OPENDDIL_EXERCISE_CONTROL_URL" in tier_pep_env:
    print("  FAIL [14b]: a tier pep carries OPENDDIL_EXERCISE_CONTROL_URL (tier peps never get it)")
    fail = True
edge_count = 3
got = 0 if not rate_sources else len(rate_sources.split(","))
if got != edge_count:
    print("  FAIL [14b]: expected " + str(edge_count) + " rate source(s), got " + str(got) + ": " + str(rate_sources))
    fail = True
if fail:
    sys.exit(1)
print("  ok   [14b]: ConfigMap/Deployment/Service/NetworkPolicy render; root pep env set; tier pep excluded; " + str(got) + " rate source(s) for " + str(edge_count) + " edge(s)")
' || fail=1

# 14c: must-fail scenarios, each naming the reason/key, same pattern as
# g9_fail_check above.
g14_fail_check() {
  local desc="$1" needle="$2"; shift 2
  local err status
  err=$(helm template t "$CHART" "$@" 2>&1 >/dev/null)
  status=$?
  if [ "$status" -eq 0 ]; then
    echo "  FAIL [14c]: $desc did not fail the render"
    fail=1
  elif ! printf '%s' "$err" | grep -q "$needle"; then
    echo "  FAIL [14c]: $desc failed, but did not name the reason (expected to find: $needle)"
    fail=1
  else
    echo "  ok   [14c]: $desc fails the render, naming the reason ($(printf '%s' "$err" | grep -m1 "exerciseControl" | sed 's/^Error: execution error at.*: //'))"
  fi
}
g14_fail_check "empty adapter" "adapter is empty" \
  --set releasability.enabled=true --set exerciseControl.enabled=true
g14_fail_check "bad operations key" 'operations entry "launch"' \
  --set releasability.enabled=true --set exerciseControl.enabled=true \
  --set exerciseControl.adapter.endpoint=https://example.invalid/api \
  --set exerciseControl.adapter.operations.launch.method=POST \
  --set exerciseControl.adapter.operations.launch.path=/launch
g14_fail_check "op with no path" 'operations.pause: call 0 is missing method or path' \
  --set releasability.enabled=true --set exerciseControl.enabled=true \
  --set exerciseControl.adapter.endpoint=https://example.invalid/api \
  --set exerciseControl.adapter.operations.pause.method=POST
g14_fail_check "empty call list" 'operations.restart must not be an empty list' \
  --set releasability.enabled=true --set exerciseControl.enabled=true \
  --set exerciseControl.adapter.endpoint=https://example.invalid/api \
  --set-json 'exerciseControl.adapter.operations.restart=[]'
g14_fail_check "call list entry with no path" 'operations.restart: call 1 is missing method or path' \
  --set releasability.enabled=true --set exerciseControl.enabled=true \
  --set exerciseControl.adapter.endpoint=https://example.invalid/api \
  --set-json 'exerciseControl.adapter.operations.restart=[{"method":"POST","path":"/rewind"},{"method":"POST"}]'

# 14c2: a call list renders into adapter.json as a list, in order.
render --set releasability.enabled=true --set exerciseControl.enabled=true \
       --set exerciseControl.adapter.endpoint=https://example.invalid/api \
       --set-json 'exerciseControl.adapter.operations.restart=[{"method":"POST","path":"/rewind"},{"method":"POST","path":"/run"}]' \
  | "$PY" -c '
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cm = [d for d in docs if d.get("kind") == "ConfigMap"
      and (d.get("metadata") or {}).get("name") == "t-exercise-control-adapter"]
ops = json.loads(cm[0]["data"]["adapter.json"])["operations"] if cm else {}
paths = [c.get("path") for c in ops.get("restart") or []] if isinstance(ops.get("restart"), list) else None
if paths != ["/rewind", "/run"]:
    print("  FAIL [14c2]: restart call list did not render as [/rewind, /run]: " + str(ops.get("restart")))
    sys.exit(1)
print("  ok   [14c2]: restart call list renders in order: " + str(paths))
' || fail=1

# 14d-14g: the reset Job (exerciseControl.resetJob). One checker, four modes.
# 14d is the absence side only: with resetJob off nothing reset-related may
# render. That the control Deployment and NetworkPolicy are byte-identical to
# the previous chart is proven by diffing two renders in the acceptance run,
# not here.
g14_reset_check() {  # $1 = mode (off|on|halt|declare); the rest are helm args
  local mode="$1"; shift
  render --namespace ns9 --set releasability.enabled=true \
         --set exerciseControl.enabled=true \
         --set exerciseControl.adapter.endpoint=https://example.invalid/api \
         --set exerciseControl.adapter.operations.pause.method=POST \
         --set exerciseControl.adapter.operations.pause.path=/pause "$@" \
    | G14_MODE="$mode" "$PY" -c '
import json, os, sys, yaml
mode = os.environ["G14_MODE"]
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
by = {(d.get("kind"), (d.get("metadata") or {}).get("name")): d for d in docs}
fail = False
def bad(msg):
    global fail
    print("  FAIL [14" + {"off": "d", "on": "e", "halt": "f", "declare": "g"}[mode] + "]: " + msg)
    fail = True
ctl = by.get(("Deployment", "t-exercise-control")) or {}
pod = ((ctl.get("spec") or {}).get("template") or {}).get("spec") or {}
cenv = {e["name"]: e.get("value") for c in pod.get("containers") or [] for e in c.get("env") or []}
if mode == "off":
    for k, n in by:
        if "exercise-reset" in n and n != "t-exercise-reset-record":
            bad("resetJob off but an object renders: " + str(k) + "/" + n)
    if "serviceAccountName" in pod:
        bad("resetJob off but the control Deployment has a serviceAccountName")
    if "EXERCISE_RESET_JOB_FILE" in cenv:
        bad("resetJob off but the control Deployment carries EXERCISE_RESET_JOB_FILE")
    if not fail:
        print("  ok   [14d]: resetJob off: no reset object, no serviceAccountName on control")
    sys.exit(1 if fail else 0)

job = None
cm = by.get(("ConfigMap", "t-exercise-reset-job"))
if cm:
    job = json.loads(cm["data"]["job.json"])
if mode == "on":
    for k, n in [("ServiceAccount", "t-exercise-reset"), ("Role", "t-exercise-reset"),
                 ("RoleBinding", "t-exercise-reset"), ("ServiceAccount", "t-exercise-control"),
                 ("Role", "t-exercise-control"), ("RoleBinding", "t-exercise-control"),
                 ("ConfigMap", "t-exercise-reset-job")]:
        if (k, n) not in by:
            bad("missing " + k + "/" + n)
    if job is None:
        bad("no job.json")
        sys.exit(1)
    if job.get("kind") != "Job":
        bad("job.json kind is " + str(job.get("kind")))
    spec = job["spec"]
    if spec.get("backoffLimit") != 0:
        bad("backoffLimit is " + str(spec.get("backoffLimit")))
    if spec["template"]["spec"].get("restartPolicy") != "Never":
        bad("restartPolicy is not Never")
    labels = job["metadata"]["labels"]
    if labels.get("app.kubernetes.io/component") != "exercise-reset" or labels.get("app.kubernetes.io/instance") != "t":
        bad("job labels lack component exercise-reset / instance t")
    c0 = spec["template"]["spec"]["containers"][0]
    if c0["command"][:2] != ["bash", "/opt/openddil/scripts/restart-exercise.sh"]:
        bad("command does not start with bash restart-exercise.sh: " + str(c0["command"][:2]))
    jenv = {e["name"]: e.get("value") for e in c0["env"]}
    if jenv.get("OPENDDIL_EXPECT_CONTEXT") != "in-cluster:ns9":
        bad("OPENDDIL_EXPECT_CONTEXT is " + str(jenv.get("OPENDDIL_EXPECT_CONTEXT")))
    if "RESTART_SUBJECT" not in jenv:
        bad("no RESTART_SUBJECT env")
    if "RESET_HALT_BEFORE_PHASE" in jenv:
        bad("RESET_HALT_BEFORE_PHASE is set by default")
    if cenv.get("EXERCISE_RESET_JOB_FILE") != "/etc/exercise-reset-job/job.json":
        bad("control lacks EXERCISE_RESET_JOB_FILE")
    mounts = [m.get("mountPath") for c in pod.get("containers") or [] for m in c.get("volumeMounts") or []]
    if "/etc/exercise-reset-job" not in mounts:
        bad("control lacks the reset-job mount")
    if pod.get("serviceAccountName") != "t-exercise-control":
        bad("control serviceAccountName is " + str(pod.get("serviceAccountName")))
    np = by.get(("NetworkPolicy", "t-exercise-control-only")) or {}
    froms = [p.get("podSelector", {}).get("matchLabels", {}).get("app.kubernetes.io/component")
             for r in (np.get("spec") or {}).get("ingress") or [] for p in r.get("from") or []]
    if "exercise-reset" not in froms:
        bad("NetworkPolicy has no exercise-reset ingress")
    if not fail:
        print("  ok   [14e]: resetJob on: 6 RBAC objects + ConfigMap; job.json is a Job (backoffLimit 0, Never, in-cluster:ns9); control env/mount/SA; NetworkPolicy admits the Job")
    sys.exit(1 if fail else 0)
if job is None:
    bad("no job.json")
    sys.exit(1)
c0 = job["spec"]["template"]["spec"]["containers"][0]
jenv = {e["name"]: e.get("value") for e in c0["env"]}
if mode == "halt":
    if jenv.get("RESET_HALT_BEFORE_PHASE") != "2":
        bad("RESET_HALT_BEFORE_PHASE is " + str(jenv.get("RESET_HALT_BEFORE_PHASE")))
    else:
        print("  ok   [14f]: haltBeforePhase=2 -> RESET_HALT_BEFORE_PHASE=\"2\"")
else:
    cmd = c0["command"]
    if "--declare-unmeasured" not in cmd or cmd[cmd.index("--declare-unmeasured") + 1] != "a":
        bad("command lacks --declare-unmeasured a: " + str(cmd))
    else:
        print("  ok   [14g]: declareUnmeasured=[a] -> --declare-unmeasured a")
sys.exit(1 if fail else 0)
' || fail=1
}
g14_reset_check off
g14_reset_check on --set exerciseControl.resetJob.enabled=true
g14_reset_check halt --set exerciseControl.resetJob.enabled=true --set-string exerciseControl.resetJob.haltBeforePhase=2
g14_reset_check declare --set exerciseControl.resetJob.enabled=true --set 'exerciseControl.resetJob.declareUnmeasured={a}'

# 14h: exercise sequences (exerciseControl.sequences, sequenceEgress).
G14_BASE=(--set releasability.enabled=true --set exerciseControl.enabled=true
          --set exerciseControl.adapter.endpoint=https://example.invalid/api)
G14_SEQ='{"demo":{"label":"Demo","description":"d","steps":[{"method":"post","url":"http://svc.ns.svc:8080/go?x=1","body":{"k":1},"name":"go"},{"wait_s":30}]}}'

# 14h-a: enabled with no sequences -- sequences.json is "{}", the env var is
# set, and the egress is the two fixed rules only.
render "${G14_BASE[@]}" | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
def get(kind, name):
    return [d for d in docs if d.get("kind") == kind and (d.get("metadata") or {}).get("name") == name]
fail = False
cm = get("ConfigMap", "t-exercise-control-adapter")
sj = cm[0]["data"].get("sequences.json") if cm else None
if sj != "{}":
    print("  FAIL [14h-a]: sequences.json is " + repr(sj) + ", want \"{}\"")
    fail = True
dep = get("Deployment", "t-exercise-control")
env = {e["name"]: e.get("value") for c in dep[0]["spec"]["template"]["spec"]["containers"] for e in c.get("env") or []} if dep else {}
if env.get("EXERCISE_SEQUENCES_FILE") != "/etc/exercise/sequences.json":
    print("  FAIL [14h-a]: EXERCISE_SEQUENCES_FILE is " + repr(env.get("EXERCISE_SEQUENCES_FILE")))
    fail = True
np = get("NetworkPolicy", "t-exercise-control-only")
n = len(np[0]["spec"]["egress"]) if np else -1
if n != 2:
    print("  FAIL [14h-a]: egress has " + str(n) + " rule(s), want 2 (DNS + sensor-ingest)")
    fail = True
if fail:
    sys.exit(1)
print("  ok   [14h-a]: no sequences -> sequences.json \"{}\", EXERCISE_SEQUENCES_FILE set, 2 egress rules")
' || fail=1

# 14h-b: a valid sequence renders and the ConfigMap JSON round-trips; the
# sequenceEgress rule is added after the fixed ones.
render "${G14_BASE[@]}" --set-json "exerciseControl.sequences=$G14_SEQ" \
       --set-json 'exerciseControl.sequenceEgress=[{"to":[{"ipBlock":{"cidr":"10.9.9.9/32"}}],"ports":[{"port":8080}]}]' \
  | G14_WANT="$G14_SEQ" "$PY" -c '
import json, os, sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cm = [d for d in docs if d.get("kind") == "ConfigMap" and (d.get("metadata") or {}).get("name") == "t-exercise-control-adapter"]
got = json.loads(cm[0]["data"]["sequences.json"]) if cm else None
want = json.loads(os.environ["G14_WANT"])
fail = False
if got != want:
    print("  FAIL [14h-b]: sequences.json did not round-trip: " + str(got))
    fail = True
np = [d for d in docs if d.get("kind") == "NetworkPolicy" and (d.get("metadata") or {}).get("name") == "t-exercise-control-only"]
eg = np[0]["spec"]["egress"] if np else []
if len(eg) != 3 or eg[-1]["to"][0].get("ipBlock", {}).get("cidr") != "10.9.9.9/32":
    print("  FAIL [14h-b]: sequenceEgress did not render as the third egress rule: " + str(eg))
    fail = True
if fail:
    sys.exit(1)
print("  ok   [14h-b]: valid sequence round-trips through sequences.json; sequenceEgress rendered")
' || fail=1

# 14h-c: each rejection fails the render and names the reason.
g14_seq_fail() {  # $1 = description, $2 = needle, $3 = sequences JSON
  g14_fail_check "$1" "$2" "${G14_BASE[@]}" --set-json "exerciseControl.sequences=$3"
}
G14_CALL='{"method":"POST","url":"http://h/x"}'
g14_seq_fail "sequence name with a capital" 'name "Bad" must match' "{\"Bad\":{\"label\":\"L\",\"steps\":[$G14_CALL]}}"
g14_seq_fail "sequence named pause" 'name "pause" collides with a built-in op' "{\"pause\":{\"label\":\"L\",\"steps\":[$G14_CALL]}}"
g14_seq_fail "sequence named reset" 'name "reset" collides with a built-in op' "{\"reset\":{\"label\":\"L\",\"steps\":[$G14_CALL]}}"
g14_seq_fail "sequence with no label" "sequences.demo: 'label' must be a non-empty string" "{\"demo\":{\"steps\":[$G14_CALL]}}"
g14_seq_fail "sequence with empty steps" "sequences.demo: 'steps' must be a list of 1..32" '{"demo":{"label":"L","steps":[]}}'
G14_33=$(printf '{"wait_s":1},%.0s' $(seq 33)); G14_33="[${G14_33%,}]"
g14_seq_fail "sequence with 33 steps" "sequences.demo: 'steps' must be a list of 1..32" "{\"demo\":{\"label\":\"L\",\"steps\":$G14_33}}"
g14_seq_fail "a step that is a string" 'sequences.demo step 0: must be an object' '{"demo":{"label":"L","steps":["x"]}}'
g14_seq_fail "wait_s 0" 'sequences.demo step 1: wait_s must be a number > 0 and <= 900' "{\"demo\":{\"label\":\"L\",\"steps\":[$G14_CALL,{\"wait_s\":0}]}}"
g14_seq_fail "wait_s 901" 'sequences.demo step 0: wait_s must be a number > 0 and <= 900' '{"demo":{"label":"L","steps":[{"wait_s":901}]}}'
g14_seq_fail "wait_s a string" 'sequences.demo step 0: wait_s must be a number' '{"demo":{"label":"L","steps":[{"wait_s":"5"}]}}'
g14_seq_fail "total wait 1801" 'sequences.demo: total wait_s 1801 exceeds 1800' '{"demo":{"label":"L","steps":[{"wait_s":900},{"wait_s":900},{"wait_s":1}]}}'
g14_seq_fail "call with no method" "sequences.demo step 0: missing 'method'" '{"demo":{"label":"L","steps":[{"url":"http://h/x"}]}}'
g14_seq_fail "call with no url" "sequences.demo step 0: 'url' must be a string starting http://" '{"demo":{"label":"L","steps":[{"method":"POST"}]}}'
g14_seq_fail "https url" "sequences.demo step 0: 'url' must be a string starting http://" '{"demo":{"label":"L","steps":[{"method":"POST","url":"https://h/x"}]}}'
g14_seq_fail "url with credentials" "sequences.demo step 0: 'url' needs a host and must not carry credentials" '{"demo":{"label":"L","steps":[{"method":"POST","url":"http://u:p@h/x"}]}}'
g14_seq_fail "url with no host" "sequences.demo step 0: 'url' needs a host" '{"demo":{"label":"L","steps":[{"method":"POST","url":"http:///x"}]}}'
g14_seq_fail "body a string" "sequences.demo step 0: 'body' must be an object" '{"demo":{"label":"L","steps":[{"method":"POST","url":"http://h/x","body":"s"}]}}'
g14_seq_fail "description not a string" "sequences.demo: 'description' must be a string" "{\"demo\":{\"label\":\"L\",\"description\":5,\"steps\":[$G14_CALL]}}"
g14_seq_fail "step name not a string" "sequences.demo step 0: 'name' must be a string" '{"demo":{"label":"L","steps":[{"method":"POST","url":"http://h/x","name":5}]}}'

# 14h-d: the checksum differs between the empty and the valid sequences render.
g14_sum() { render "${G14_BASE[@]}" "$@" | grep -m1 'checksum/config:' | tr -d ' '; }
G14_SUM_A=$(g14_sum)
G14_SUM_B=$(g14_sum --set-json "exerciseControl.sequences=$G14_SEQ")
if [ -z "$G14_SUM_A" ] || [ -z "$G14_SUM_B" ]; then
  echo "  FAIL [14h-d]: no checksum/config annotation rendered"
  fail=1
elif [ "$G14_SUM_A" = "$G14_SUM_B" ]; then
  echo "  FAIL [14h-d]: checksum/config did not change with the sequences"
  fail=1
else
  echo "  ok   [14h-d]: checksum/config differs between no sequences and a sequence"
fi

# --- guard 15: per-link heartbeat wiring ------------------------------------
# THE DEFECTS MODELLED:
#  (a) a buffer monitor's BRIDGE_TOPICS differing from the topic list its own
#      relay consumes -- the hub-attached edge's monitor once took the code
#      default while its bridge carried the helper list, and the retired-topic
#      offset read as phantom buffer. Checked for EVERY projector that runs a
#      buffer monitor, against the generated connect config of its relay.
#  (b) link-heartbeat missing from a relay's list or from any topic-init Job:
#      the heartbeat would be produced, never reach HQ, and every link would
#      read down with nothing else wrong.
#  (c) projector-hq's LINK_EXPECTED_IDS drifting from the ids that emit a
#      heartbeat (every edge + every tier-managed region): an unlisted link
#      is silently absent from link_status instead of reading down.
echo
echo "guard 15: per-link heartbeat wiring (bridge lists, topic-init, expected ids)"
G15_VALUES="$(mktemp)"
cat > "$G15_VALUES" <<'G15'
tierNode:
  enabled: true
  tiers: [region-east, edge-01]
edges:
  - {id: edge-01, region: region-east, udpPort: 62040}
  - {id: edge-02, region: region-east, udpPort: 62041, declaredIdle: {reason: g15, revisit: "2099-01-01"}}
  - {id: edge-03, region: region-west, udpPort: 62042}
G15
render -f "$G15_VALUES" | "$PY" -c '
import sys, yaml
docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms, deps, jobs = {}, {}, []
for d in docs:
    n = (d.get("metadata") or {}).get("name", "")
    if d.get("kind") == "ConfigMap":
        cms[n] = d
    elif d.get("kind") == "Deployment":
        deps[n] = d
    elif d.get("kind") == "Job" and "-topic-init" in n:
        jobs.append(d)
def env(d, cname="projector"):
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] == cname:
            return {e["name"]: e.get("value") for e in c.get("env") or []}
    return {}
def relay_topics(cmname):
    cm = cms.get(cmname)
    if cm is None:
        return None
    return yaml.safe_load(cm["data"]["connect.yaml"])["input"]["kafka"]["topics"]
fail = False
def bad(m):
    global fail
    print("  FAIL: " + m)
    fail = True
checked = 0
for n, d in sorted(deps.items()):
    e = env(d)
    if e.get("BUFFER_MONITOR_ENABLED") != "true" or "projector" not in n:
        continue
    if "-tier-projector-" in n:
        tid = n.split("-tier-projector-", 1)[1]
        relay = None
        for cn in ("t-edge-hq-bridge-config-" + tid, "t-tier-uplink-config-" + tid):
            relay = relay_topics(cn) if relay is None else relay
    else:
        tid = n.split("-projector-", 1)[1]
        relay = relay_topics("t-edge-hq-bridge-config-" + tid)
    if relay is None:
        bad(n + ": no relay config found to compare against")
        continue
    checked += 1
    mon = (e.get("BRIDGE_TOPICS") or "").split(",") if e.get("BRIDGE_TOPICS") else None
    if mon is None:
        bad(n + ": no BRIDGE_TOPICS (monitor would use its code default)")
    elif mon != relay:
        bad(n + ": BRIDGE_TOPICS " + ",".join(mon) + " != relay " + ",".join(relay))
    if "link-heartbeat" not in relay:
        bad(n + ": relay list lacks link-heartbeat")
    if e.get("LINK_HEARTBEAT_ENABLED") != "true" or e.get("LINK_ID") != tid:
        bad(n + ": LINK_HEARTBEAT_ENABLED/LINK_ID wrong: " + str((e.get("LINK_HEARTBEAT_ENABLED"), e.get("LINK_ID"))))
if checked < 4:
    bad("only %d buffer-monitor projectors compared (fixture has 4) -- guard proved too little" % checked)
if not jobs:
    bad("no topic-init Jobs rendered")
for j in jobs:
    txt = yaml.safe_dump(j)
    if "link-heartbeat|" not in txt:
        bad((j["metadata"]["name"]) + ": topic-init does not create link-heartbeat")
hq = env(deps["t-projector-hq"])
want = ["edge-01", "edge-02", "edge-03", "region-east"]
got = (hq.get("LINK_EXPECTED_IDS") or "").split(",")
if sorted(got) != sorted(want):
    bad("projector-hq LINK_EXPECTED_IDS " + str(got) + " != edges + tier-managed regions " + str(want))
if hq.get("LINK_DECLARED_IDLE") != "edge-02":
    bad("projector-hq LINK_DECLARED_IDLE is " + repr(hq.get("LINK_DECLARED_IDLE")) + ", want edge-02")
if hq.get("LINK_MONITOR_ENABLED") != "true":
    bad("projector-hq LINK_MONITOR_ENABLED is not true")
if not fail:
    print("  ok   : %d monitors match their relay lists (all carry link-heartbeat); %d topic-init Jobs create it; expected ids = edges + tier regions" % (checked, len(jobs)))
sys.exit(1 if fail else 0)
' || fail=1
rm -f "$G15_VALUES"

# --- guard 16: SSO lifetimes follow the PEP session lifetime ----------------
# THE DEFECT MODELLED: the realm import's SSO idle/max lifetimes drifting from
# releasability.oidc.sessionTtlSeconds -- the realm falling back to Keycloak's
# own defaults (30 min idle, 10 h max), or a PEP (root or a tier's) reading a
# different session lifetime than the realm. The provider's session then
# outlives the PEP's, and the next sign-in returns without a password.
# A second half: a TTL-only change must roll Keycloak (its pod-template
# checksum/policy), or the realm is never re-imported with the new value.
# The check runs on the real render (must pass) and on a doctored copy (one
# PEP env value changed; must report the mismatch), so a check that cannot
# fail is caught here and not in production.
echo
echo "guard 16: Keycloak SSO lifetimes follow the PEP session lifetime"
G16_VALUES="$(mktemp)"
G16_A="$(mktemp)"
G16_B="$(mktemp)"
cat > "$G16_VALUES" <<'G16'
tierNode:
  enabled: true
  tiers: [region-east, edge-01]
edges:
  - {id: edge-01, region: region-east, udpPort: 62040, publicOrigin: "http://edge-01.invalid"}
G16
g16_render() {
  render -f "$G16_VALUES" --set releasability.enabled=true --set releasability.lockDownElectric=true \
    --set releasability.oidc.enabled=true --set releasability.keycloak.enabled=true \
    --set releasability.publicOrigin=http://lab.invalid \
    --set releasability.oidc.sessionTtlSeconds="$1"
}
g16_render 1234 > "$G16_A"
g16_render 1235 > "$G16_B"
"$PY" - "$G16_A" "$G16_B" <<'G16PY' || fail=1
import sys, yaml
def load(p):
    return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
def envs(docs):
    out = []
    for d in docs:
        if d.get("kind") == "Deployment":
            for c in d["spec"]["template"]["spec"].get("containers") or []:
                for e in c.get("env") or []:
                    if e.get("name") == "OPENDDIL_SESSION_TTL_SECONDS":
                        out.append((d["metadata"]["name"], e))
    return out
def check(docs, want):
    errs = []
    realm = 0
    for d in docs:
        if d.get("kind") == "ConfigMap" and (d.get("metadata") or {}).get("name", "").endswith("-keycloak-realm"):
            sh = (d.get("data") or {}).get("substitutions.sh", "")
            realm += 1
            for k in ("ssoSessionIdleTimeout", "ssoSessionMaxLifespan"):
                if ('"%s": %s,' % (k, want)) not in sh:
                    errs.append("realm substitutions.sh lacks %s = %s" % (k, want))
    if realm != 1:
        errs.append("%d keycloak-realm ConfigMaps found, want 1" % realm)
    es = envs(docs)
    for n, e in es:
        if e.get("value") != want:
            errs.append("%s: OPENDDIL_SESSION_TTL_SECONDS=%s, want %s" % (n, e.get("value"), want))
    if len(es) < 2:
        errs.append("only %d PEP session TTL env values found (root + tier needed) -- guard proved too little" % len(es))
    return errs, len(es)
def kc_sum(docs):
    for d in docs:
        if d.get("kind") == "Deployment" and d["metadata"]["name"].endswith("-keycloak"):
            return d["spec"]["template"]["metadata"]["annotations"]["checksum/policy"]
    return None
a, b = load(sys.argv[1]), load(sys.argv[2])
errs, n = check(a, "1234")
berrs, _ = check(b, "1235")
errs += berrs
ka, kb = kc_sum(a), kc_sum(b)
if ka is None or kb is None:
    errs.append("keycloak Deployment checksum/policy not found")
elif ka == kb:
    errs.append("keycloak checksum/policy identical for TTL 1234 vs 1235 -- a TTL-only change would not roll Keycloak")
if sorted(map(str, envs(a))) == sorted(map(str, envs(b))):
    errs.append("PEP env identical for TTL 1234 vs 1235")
for e in errs:
    print("  FAIL: " + e)
# Doctor one PEP env value and require the check to notice.
for _, e in envs(a)[:1]:
    e["value"] = "999"
derrs, _ = check(a, "1234")
if not any("999" in e for e in derrs):
    print("  FAIL: guard 16 did not detect a doctored PEP session lifetime -- it cannot fail")
    errs.append("vacuous")
if not errs:
    print("  ok   : realm idle+max follow the TTL; %d PEP env values match; Keycloak checksum and PEP env differ across TTLs; doctored copy detected" % n)
sys.exit(1 if errs else 0)
G16PY
rm -f "$G16_VALUES" "$G16_A" "$G16_B"

# --- guard 17: protobuf-wire topics decode as their proto -------------------
# THE DEFECT MODELLED: a projector mapping that decodes a protobuf topic as
# json. Every record is refused as "not valid JSON", the table stays empty,
# and nothing else fails -- the projector logs one warning per partition and
# carries on. The table below is the producer side's wire format, declared
# here because the producers live in other repos; extend it when a producer
# moves a topic to protobuf. The check runs on the real render (must pass)
# and on a doctored copy (one mapping set to json; must report it).
echo
echo "guard 17: protobuf-wire topics decode as their proto in every projector config"
G17_VALUES="$(mktemp)"
G17_R="$(mktemp)"
cat > "$G17_VALUES" <<'G17'
tierNode:
  enabled: true
  tiers: [region-east, edge-01]
edges:
  - {id: edge-01, region: region-east, udpPort: 62040, publicOrigin: "http://edge-01.invalid"}
G17
render -f "$G17_VALUES" > "$G17_R"
"$PY" - "$G17_R" <<'G17PY' || fail=1
import copy, sys, yaml
WIRE = {
    "telemetry-latest-state": "openddil.telemetry.v1.EntityTelemetryEvent",
    "asset-logistics-status": "openddil.logistics.v1.AssetLogisticsStatusUpdate",
    "asset-telemetry-windows": "openddil.logistics.v1.WindowedTelemetry",
}
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
def configs(docs):
    out = []
    for d in docs:
        if d.get("kind") == "ConfigMap" and "projector-config" in d["metadata"]["name"]:
            for k, v in (d.get("data") or {}).items():
                if k.endswith(".yaml"):
                    out.append((d["metadata"]["name"], yaml.safe_load(v) or {}))
    return out
def check(cfgs):
    errs, seen = [], {}
    for name, c in cfgs:
        for m in c.get("mappings") or []:
            want = WIRE.get(m.get("topic"))
            if want is None:
                continue
            seen[m["topic"]] = seen.get(m["topic"], 0) + 1
            if m.get("decode_as") != want:
                errs.append("%s: %s decode_as %s, the producer writes %s" % (name, m["topic"], m.get("decode_as"), want))
    for t in WIRE:
        if not seen.get(t):
            errs.append("no projector config maps %s -- guard proved nothing for it" % t)
    return errs, seen
cfgs = configs(docs)
errs, seen = check(cfgs)
for e in errs:
    print("  FAIL: " + e)
bad = copy.deepcopy(cfgs)
for _, c in bad:
    for m in c.get("mappings") or []:
        if m.get("topic") == "asset-telemetry-windows":
            m["decode_as"] = "json"
            break
    else:
        continue
    break
derrs, _ = check(bad)
if not any("asset-telemetry-windows decode_as json" in e for e in derrs):
    print("  FAIL: guard 17 did not detect a json-decoded protobuf topic -- it cannot fail")
    errs.append("vacuous")
if not errs:
    print("  ok   : %d projector configs; %s; doctored copy detected" % (len(cfgs), ", ".join("%s x%d" % kv for kv in sorted(seen.items()))))
sys.exit(1 if errs else 0)
G17PY
rm -f "$G17_VALUES" "$G17_R"

# --- guard 18: a chart-version bump alone does not roll exercise control ----
# THE DEFECT MODELLED: the control Deployment's checksum/reset-job taken over
# a Job template that carries helm.sh/chart (name-version). Every Chart.yaml
# version bump then changed the annotation and rolled exercise control with
# nothing it runs having changed. Helm cannot override Chart.version with
# --set, so the chart is packaged at two versions. A third render changes what
# the Job runs (activeDeadlineSeconds); its annotation MUST differ, or the
# comparison could not fail and the equality above proves nothing.
echo
echo "guard 18: exercise-control reset-job checksum ignores the chart version"
G18_DIR="$(mktemp -d)"
G18_A="$(mktemp)"
G18_B="$(mktemp)"
G18_C="$(mktemp)"
helm package "$CHART" --version 0.0.1 -d "$G18_DIR" >/dev/null
helm package "$CHART" --version 0.0.2 -d "$G18_DIR" >/dev/null
g18_render() {  # $1 = packaged chart; the rest are helm args
  local pkg="$1"; shift
  helm template t "$pkg" --namespace ns9 --set releasability.enabled=true     --set exerciseControl.enabled=true     --set exerciseControl.adapter.endpoint=https://example.invalid/api     --set exerciseControl.adapter.operations.pause.method=POST     --set exerciseControl.adapter.operations.pause.path=/pause     --set exerciseControl.resetJob.enabled=true "$@" 2>/dev/null
}
g18_render "$G18_DIR/openddil-demo-0.0.1.tgz" > "$G18_A"
g18_render "$G18_DIR/openddil-demo-0.0.2.tgz" > "$G18_B"
g18_render "$G18_DIR/openddil-demo-0.0.1.tgz" --set exerciseControl.resetJob.activeDeadlineSeconds=4321 > "$G18_C"
"$PY" - "$G18_A" "$G18_B" "$G18_C" <<'G18PY' || fail=1
import sys, yaml
def ann(p):
    for d in yaml.safe_load_all(open(p, encoding="utf-8")):
        if d and d.get("kind") == "Deployment" and (d.get("metadata") or {}).get("name") == "t-exercise-control":
            return (((d.get("spec") or {}).get("template") or {}).get("metadata") or {}).get("annotations", {}).get("checksum/reset-job")
    return None
a, b, c = (ann(p) for p in sys.argv[1:4])
errs = []
for name, v in (("0.0.1", a), ("0.0.2", b), ("0.0.1 with a changed deadline", c)):
    if not v:
        errs.append("checksum/reset-job missing or empty at " + name + " -- the guard would be vacuous")
if not errs:
    if a != b:
        errs.append("checksum/reset-job differs between chart 0.0.1 and 0.0.2 -- a version-only bump would roll exercise control")
    if c == a:
        errs.append("checksum/reset-job did not change when the reset Job's deadline changed -- guard 18 cannot fail")
for e in errs:
    print("  FAIL: " + e)
if not errs:
    print("  ok   : checksum/reset-job equal across chart 0.0.1 and 0.0.2, and different when the Job's deadline changes")
sys.exit(1 if errs else 0)
G18PY
rm -f "$G18_DIR/openddil-demo-0.0.1.tgz" "$G18_DIR/openddil-demo-0.0.2.tgz" "$G18_A" "$G18_B" "$G18_C"
rmdir "$G18_DIR"

# --- guard 19: store passwords reach containers only by secretKeyRef --------
# THE DEFECT MODELLED: a DSN printf'd from values into a container env or a Job
# arg, which puts the store password into the rendered Deployment/Job (and so
# into the release manifest, `helm get manifest`, and every pod spec). Renders
# with fixed fake sentinels as the passwords, then asserts the sentinel appears
# only inside Secret objects, no rendered line is a URL with an inline password,
# and PGPASSWORD secretKeyRefs exist (a guard that found no consumers has proved
# nothing). A second render names an existing Secret for both stores: no chart
# Secret may then carry the sentinel at all, and every password reference must
# name the existing Secret.
echo
echo "guard 19: store passwords reach containers only by secretKeyRef"
G19_S1="guard19-sentinel-hq"
G19_S2="guard19-sentinel-tier"
G19_S3="guard19-sentinel-kc"
G19_DIR="$(mktemp -d)"
g19_flags=(--set releasability.enabled=true --set releasability.keycloak.enabled=true --set "postgresHq.auth.password=$G19_S1" --set "tierNode.postgres.auth.password=$G19_S2" --set "releasability.keycloak.adminPassword=$G19_S3")
render "${g19_flags[@]}" > "$G19_DIR/default.yaml"
render --set tierNode.enabled=true "${g19_flags[@]}" > "$G19_DIR/tier.yaml"
render --set tierNode.enabled=true "${g19_flags[@]}" --set postgresHq.auth.existingSecret=ext-hq-pg --set tierNode.postgres.auth.existingSecret=ext-tier-pg --set releasability.keycloak.adminExistingSecret=ext-kc-pg > "$G19_DIR/existing.yaml"
"$PY" - "$G19_S1" "$G19_S2" "$G19_S3" "$G19_DIR/default.yaml" "$G19_DIR/tier.yaml" "$G19_DIR/existing.yaml" <<'G19PY' || fail=1
import sys, re, json, yaml
s1, s2, s3, f_def, f_tier, f_ext = sys.argv[1:7]
sentinels = (s1, s2, s3)
url_pw = re.compile(r"://[^/:@ ]+:[^@ $]+@")
errs = []
def docs_of(p):
    return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
def containers(d):
    spec = (((d.get("spec") or {}).get("template") or {}).get("spec") or {})
    for k in ("initContainers", "containers"):
        for c in spec.get(k) or []:
            yield c
def pw_refs(d):
    out = []
    for c in containers(d):
        for e in c.get("env") or []:
            if e.get("name") in ("PGPASSWORD", "POSTGRES_PASSWORD", "KC_BOOTSTRAP_ADMIN_PASSWORD"):
                ref = ((e.get("valueFrom") or {}).get("secretKeyRef")) or {}
                out.append((e["name"], d["metadata"]["name"], c["name"], ref.get("name"), "value" in e))
    return out
# (f) NAME RULE ALLOWLIST: name  object  reason. A rendered container env entry whose
# name looks like a credential and which carries a literal value fails unless it
# is listed here (or is only $(VAR) references plus URL punctuation).
G19_ALLOW = [
]
name_re = re.compile(r"(PASSWORD|SECRET|TOKEN|_KEY|DSN|DATABASE_URL)$")
ref_url = re.compile(r"^postgres(ql)?://:@:/[?]sslmode=$")
def all_containers(o):
    if isinstance(o, dict):
        for k, v in o.items():
            if k in ("containers", "initContainers") and isinstance(v, list):
                for c in v:
                    yield c
            else:
                yield from all_containers(v)
    elif isinstance(o, list):
        for v in o:
            yield from all_containers(v)
def name_rule(label, docs):
    n = 0
    for d in docs:
        for c in all_containers(d):
            for e in c.get("env") or []:
                if not name_re.search(e.get("name", "")) or "value" not in e:
                    continue
                n += 1
                v = str(e["value"])
                if "$(" in v and ref_url.match(re.sub(r"[$][(][A-Z_]+[)]", "", v)):
                    continue
                if any(a[0] == e["name"] and a[1] == d["metadata"]["name"] for a in G19_ALLOW):
                    continue
                errs.append("%s: %s/%s env %s has a literal value (credential-named; empty counts)" % (label, d["metadata"]["name"], c["name"], e["name"]))
    return n
stats = {}
for label, p in (("default", f_def), ("tierNode", f_tier)):
    docs = docs_of(p)
    checked = 0
    consumers = set()
    refs = 0
    for d in docs:
        if d.get("kind") != "Secret":
            checked += 1
            blob = json.dumps(d)
            for s in sentinels:
                if s in blob:
                    errs.append("%s: sentinel password in %s/%s (not a Secret)" % (label, d.get("kind"), d["metadata"]["name"]))
        for name, obj, cont, sec, plain in pw_refs(d):
            if plain:
                errs.append("%s: %s/%s %s is a plain value, not a secretKeyRef" % (label, obj, cont, name))
            elif name == "PGPASSWORD":
                refs += 1
                consumers.add((obj, cont))
    for i, line in enumerate(open(p, encoding="utf-8").read().splitlines(), 1):
        if url_pw.search(line):
            errs.append("%s: line %d is a URL with an inline password" % (label, i))
    if refs == 0:
        errs.append("%s: zero PGPASSWORD secretKeyRefs rendered -- the guard found no consumers" % label)
    nr = name_rule(label, docs)
    print("  %-8s credential-named literal env entries examined=%d, allowlist size=%d" % (label, nr, len(G19_ALLOW)))
    stats[label] = (len(consumers), refs, checked)
    print("  %-8s consumers=%d secretKeyRefs=%d non-Secret objects checked=%d" % (label, len(consumers), refs, checked))
ext_names = {"ext-hq-pg", "ext-tier-pg", "ext-kc-pg"}
text = open(f_ext, encoding="utf-8").read()
for s in sentinels:
    if s in text:
        errs.append("existingSecret: a sentinel password is rendered somewhere (a chart Secret still carries it)")
        break
refs = 0
for d in docs_of(f_ext):
    for name, obj, cont, sec, plain in pw_refs(d):
        if plain:
            errs.append("existingSecret: %s/%s %s is a plain value" % (obj, cont, name))
            continue
        refs += 1
        if sec not in ext_names:
            errs.append("existingSecret: %s/%s %s references %s, not the existing Secret" % (obj, cont, name, sec))
if refs == 0:
    errs.append("existingSecret: zero password secretKeyRefs rendered -- vacuous")
print("  existingSecret render: password secretKeyRefs=%d, all naming the existing Secret" % refs)
for e in errs:
    print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G19PY
rm -rf "$G19_DIR"

# --- guard 20: redpanda --memory leaves headroom below the container limit ---
# THE DEFECT MODELLED: a broker started with no --memory sizes Seastar to the
# whole cgroup limit (--reserve-memory is 0), leaving nothing for allocations
# outside its allocator; it ran at ~85% of the limit and was OOMKilled after a
# reset. Every broker container must carry --memory, with --memory + the
# headroom equal to limits.memory, and at least 256Mi left. Variants cover both
# limit forms (Gi, Mi). A control render with zero headroom must be refused by
# the chart, and the checker is self-tested on a copy with --memory removed.
echo
echo "guard 20: redpanda --memory leaves headroom below the container limit"
G20_DIR="$(mktemp -d)"
render > "$G20_DIR/default.yaml"
render --set tierNode.enabled=true > "$G20_DIR/tier.yaml"
render --set redpandaHq.resources.limits.memory=1536Mi --set redpandaEdge.resources.limits.memory=2Gi > "$G20_DIR/forms.yaml"
cat > "$G20_DIR/check.py" <<'G20PY'
import sys, yaml
def mi(v):
    v = str(v)
    return int(v[:-2]) * (1024 if v.endswith("Gi") else 1)
def check(path, label, headroom):
    errs, n = [], 0
    for d in yaml.safe_load_all(open(path, encoding="utf-8")):
        if not d or d.get("kind") not in ("Deployment", "StatefulSet"):
            continue
        for c in (((d.get("spec") or {}).get("template") or {}).get("spec") or {}).get("containers") or []:
            a = [str(x) for x in (c.get("args") or [])]
            if "redpanda" not in a or "start" not in a:
                continue
            n += 1
            who = "%s/%s" % (d["metadata"]["name"], c["name"])
            if "--memory" not in a:
                errs.append("%s: no --memory" % who)
                continue
            m = int(a[a.index("--memory") + 1].rstrip("M"))
            lim = mi(c["resources"]["limits"]["memory"])
            if m + headroom != lim:
                errs.append("%s: --memory %dM + headroom %d != limit %dMi" % (who, m, headroom, lim))
            elif lim - m < 256:
                errs.append("%s: only %dMi left below the limit" % (who, lim - m))
            else:
                print("  ok   : %s %s --memory %dM, limit %dMi" % (label, who, m, lim))
    if n == 0:
        errs.append("%s: zero brokers checked -- vacuous" % label)
    return errs
errs = []
if sys.argv[1] == "selftest":
    e = check(sys.argv[2], "selftest", 384)
    print("  selftest checker reported %d problem(s)" % len(e))
    sys.exit(0 if e else 1)
for p, l in zip(sys.argv[1:], ("default", "tierNode", "limit-forms")):
    errs += check(p, l, 384)
for e in errs:
    print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G20PY
"$PY" "$G20_DIR/check.py" "$G20_DIR/default.yaml" "$G20_DIR/tier.yaml" "$G20_DIR/forms.yaml" || fail=1
# SELF-TEST: drop --memory and its value from one broker; the checker must object.
"$PY" - "$G20_DIR/default.yaml" "$G20_DIR/mutant.yaml" <<'G20MUT'
import sys
t = open(sys.argv[1], encoding="utf-8").read()
i = t.index("            - --memory\n")
j = t.index("            - --reserve-memory\n", i)
open(sys.argv[2], "w", encoding="utf-8").write(t[:i] + t[j:])
G20MUT
if "$PY" "$G20_DIR/check.py" selftest "$G20_DIR/mutant.yaml"; then
  echo "  ok   : self-test: the checker fails a broker with --memory removed"
else
  echo "  FAIL: the checker passed a broker with --memory removed -- guard 20 cannot fail"; fail=1
fi
# CONTROL: zero headroom must be refused at render time, naming the value.
if helm template t "$CHART" --set redpandaEdge.memoryHeadroomMi=0 >"$G20_DIR/ctl.out" 2>&1; then
  echo "  FAIL: control render with memoryHeadroomMi=0 succeeded -- the chart does not enforce a headroom floor"; fail=1
elif grep -q memoryHeadroomMi "$G20_DIR/ctl.out"; then
  echo "  ok   : control: memoryHeadroomMi=0 is refused, naming memoryHeadroomMi"
else
  echo "  FAIL: control render failed but the error does not name memoryHeadroomMi"; fail=1
fi
rm -rf "$G20_DIR"

# --- guard 21: the images-pullable hook probes exactly the images the render runs
# THE DEFECT MODELLED: a template gains (or changes) an image and
# openddil.renderedImages is not told. The pre-flight hook then proves a
# stale set, and the bad pin it exists to refuse goes through. A hook that
# probes too MUCH is also wrong: it fails an upgrade over an image nothing runs.
#
# R = images of containers and initContainers of every pod template (Pod,
# Deployment, StatefulSet, DaemonSet, Job, CronJob) EXCEPT the images-pullable
# Job, PLUS the same pod kinds embedded as data in any ConfigMap (a value that
# parses as YAML/JSON and is, or contains, such a manifest): the exercise reset
# runner is a Job manifest in a ConfigMap, a pod only when a reset is pressed.
# H = images of the probe Job containers (not its initContainer). FAIL unless
# H == R; FAIL if R is empty.
#
# Variants: default; tierNode; releasability; ephemeralOnUpgrade; and one
# "everything on" variant that turns on every flag that gates an image in the
# renderedImages inventory: linkControl.enabled (toxiproxy),
# restate.ephemeralOnUpgrade (wipe runner), releasability.enabled (pep, topaz,
# egress gate), releasability.keycloak.enabled (keycloak),
# egress.tak.enabled (TAK server + adapter), egress.tak.tls.enabled (TLS
# proxy), tierNode.enabled (tier store), tierNode.topaz.enabled (tier topaz),
# cmReports.enabled (connect on the hub). exerciseControl.enabled (+ adapter
# endpoint) and resetJob.enabled are also on (reset runner).
echo "guard 21: images-pullable hook probes exactly the rendered image set"
G21_DIR="$(mktemp -d)"
render > "$G21_DIR/v1.yaml"
render --set tierNode.enabled=true > "$G21_DIR/v2.yaml"
render --set releasability.enabled=true > "$G21_DIR/v3.yaml"
render --set restate.ephemeralOnUpgrade=true > "$G21_DIR/v4.yaml"
render --set linkControl.enabled=true --set restate.ephemeralOnUpgrade=true \
  --set releasability.enabled=true --set releasability.keycloak.enabled=true \
  --set egress.tak.enabled=true --set egress.tak.tls.enabled=true \
  --set egress.tak.tls.secretName=guard21-secret --set-json 'egress.tak.tls.allowedClientCNs=["guard21-cn"]' \
  --set tierNode.enabled=true --set tierNode.topaz.enabled=true --set cmReports.enabled=true \
  --set exerciseControl.enabled=true --set exerciseControl.adapter.endpoint=https://example.invalid/api \
  --set exerciseControl.resetJob.enabled=true > "$G21_DIR/v5.yaml"
cat > "$G21_DIR/check.py" <<'G21PY'
import sys, yaml
PODS = ("Pod", "Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")
def podspec(d):
    k, s = d.get("kind"), d.get("spec") or {}
    if k == "Pod": return s
    if k == "CronJob": return (((s.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    return (s.get("template") or {}).get("spec") or {}
def is_probe(d):
    return d.get("kind") == "Job" and "-images-pullable-" in (d["metadata"].get("name") or "")
def walk(d, R, H):
    if not isinstance(d, dict): return
    if d.get("kind") == "List":
        for i in d.get("items") or []: walk(i, R, H)
        return
    if d.get("kind") == "ConfigMap":
        for v in (d.get("data") or {}).values():
            try: docs = list(yaml.safe_load_all(v))
            except Exception: continue
            for x in docs:
                if isinstance(x, dict) and x.get("kind") in PODS: walk(x, R, H)
        return
    if d.get("kind") not in PODS: return
    ps = podspec(d)
    if is_probe(d):
        H |= {c["image"] for c in ps.get("containers") or []}
    else:
        R |= {c["image"] for k in ("containers", "initContainers") for c in ps.get(k) or []}
def sets(path):
    R, H = set(), set()
    for d in yaml.safe_load_all(open(path, encoding="utf-8")):
        walk(d, R, H)
    return R, H
def compare(R, H, label):
    errs = []
    if not R: errs.append("%s: no images in the render -- vacuous" % label)
    for i in sorted(R - H): errs.append("%s: run by a workload but NOT probed by the hook: %s" % (label, i))
    for i in sorted(H - R): errs.append("%s: probed by the hook but run by NO workload: %s" % (label, i))
    return errs
if sys.argv[1] == "selftest":
    R, H = sets(sys.argv[2])
    a = compare(R, set(sorted(H)[1:]), "selftest-missing")
    b = compare(R, H | {"example.invalid/bogus:1"}, "selftest-extra")
    print("  selftest: missing-image copy -> %d problem(s); bogus-image copy -> %d problem(s)" % (len(a), len(b)))
    sys.exit(0 if a and b else 1)
errs = []
for p, l in zip(sys.argv[1:], ("default", "tierNode", "releasability", "ephemeralOnUpgrade", "everything-on")):
    R, H = sets(p)
    e = compare(R, H, l)
    print("  %s %-18s: %d workload image(s), %d probed" % ("FAIL" if e else "ok  ", l, len(R), len(H)))
    errs += e
for e in errs: print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G21PY
"$PY" "$G21_DIR/check.py" "$G21_DIR/v1.yaml" "$G21_DIR/v2.yaml" "$G21_DIR/v3.yaml" "$G21_DIR/v4.yaml" "$G21_DIR/v5.yaml" || fail=1
if "$PY" "$G21_DIR/check.py" selftest "$G21_DIR/v5.yaml"; then
  echo "  ok   : self-test: the comparison fails a hook missing one image and a hook with a bogus one"
else
  echo "  FAIL: the comparison passed a mutated hook image set -- guard 21 cannot fail"; fail=1
fi

# --- guard 22: the images-pullable hook runs first among the pre-* hooks ------
# THE DEFECT MODELLED: another hook (or a later edit to this one) gets a weight
# at or below the pre-flight weight, and something is changed before the pull
# is proven. In every variant, for each of pre-install, pre-upgrade and
# pre-rollback: the Job is present in the phase and its weight is STRICTLY
# less than every other hook weight in that phase.
echo "guard 22: images-pullable hook is first among pre-install/pre-upgrade/pre-rollback hooks"
cat > "$G21_DIR/order.py" <<'G22PY'
import sys, yaml
PHASES = ("pre-install", "pre-upgrade", "pre-rollback")
def hooks(docs):
    out = []
    for d in docs:
        a = (d.get("metadata") or {}).get("annotations") or {}
        if "helm.sh/hook" not in a: continue
        ph = [x.strip() for x in str(a["helm.sh/hook"]).split(",")]
        out.append((d.get("kind"), d["metadata"].get("name"), ph, int(str(a.get("helm.sh/hook-weight", "0")))))
    return out
def check(docs, label):
    errs, hs = [], hooks(docs)
    for ph in PHASES:
        mine = [h for h in hs if "-images-pullable-" in h[1] and h[0] == "Job" and ph in h[2]]
        if not mine:
            errs.append("%s/%s: images-pullable Job is not a %s hook" % (label, ph, ph)); continue
        w = mine[0][3]
        for k, n, p, wt in hs:
            if ph in p and n != mine[0][1] and wt <= w:
                errs.append("%s/%s: %s/%s weight %d is not above the pre-flight weight %d" % (label, ph, k, n, wt, w))
    return errs
def load(p): return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
if sys.argv[1] == "selftest":
    docs = load(sys.argv[2])
    for d in docs:
        a = (d.get("metadata") or {}).get("annotations") or {}
        if "pre-upgrade" in str(a.get("helm.sh/hook", "")) and "-images-pullable-" not in d["metadata"]["name"]:
            a["helm.sh/hook-weight"] = "-200"; break
    e = check(docs, "selftest")
    print("  selftest: a pre-upgrade hook at weight -200 -> %d problem(s)" % len(e))
    sys.exit(0 if e else 1)
errs = []
for p, l in zip(sys.argv[1:], ("default", "tierNode", "releasability", "ephemeralOnUpgrade", "everything-on")):
    e = check(load(p), l)
    print("  %s %-18s" % ("FAIL" if e else "ok  ", l))
    errs += e
for e in errs: print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G22PY
"$PY" "$G21_DIR/order.py" "$G21_DIR/v1.yaml" "$G21_DIR/v2.yaml" "$G21_DIR/v3.yaml" "$G21_DIR/v4.yaml" "$G21_DIR/v5.yaml" || fail=1
if "$PY" "$G21_DIR/order.py" selftest "$G21_DIR/v5.yaml"; then
  echo "  ok   : self-test: the ordering check fails when another pre-upgrade hook is at weight -200"
else
  echo "  FAIL: the ordering check passed a hook at weight -200 -- guard 22 cannot fail"; fail=1
fi
rm -rf "$G21_DIR"

# --- guard 23: the Restate wipe is the LAST pre-* hook -------------------------
# THE DEFECT MODELLED: the wipe scales every Restate StatefulSet to zero and
# deletes its PVC. Run first, a later pre-* hook that hung left the upgrade
# unapplied and Restate down at every tier until a rollback. In each variant
# (rendered with restate.ephemeralOnUpgrade=true, else the wipe does not render
# and this check is vacuous), for each of pre-install, pre-upgrade and
# pre-rollback in which the wipe Job appears: its weight is STRICTLY greater
# than every other hook's weight in the phase (its own RBAC excepted), and its
# RBAC objects' weights are strictly less than the Job's. FAIL if no wipe Job
# is found at all.
echo
echo "guard 23: the Restate wipe is the last pre-install/pre-upgrade/pre-rollback hook"
G23_DIR="$(mktemp -d)"
render --set restate.ephemeralOnUpgrade=true > "$G23_DIR/w1.yaml"
render --set tierNode.enabled=true --set restate.ephemeralOnUpgrade=true > "$G23_DIR/w2.yaml"
render --set releasability.enabled=true --set restate.ephemeralOnUpgrade=true > "$G23_DIR/w3.yaml"
cat > "$G23_DIR/last.py" <<'G23PY'
import sys, yaml
PHASES = ("pre-install", "pre-upgrade", "pre-rollback")
def hooks(docs):
    out = []
    for d in docs:
        a = (d.get("metadata") or {}).get("annotations") or {}
        if "helm.sh/hook" not in a: continue
        ph = [x.strip() for x in str(a["helm.sh/hook"]).split(",")]
        out.append((d.get("kind"), d["metadata"].get("name"), ph, int(str(a.get("helm.sh/hook-weight", "0")))))
    return out
def is_wipe(h): return "-restate-wipe" in h[1]
def check(docs, label, show=False):
    errs, hs, found = [], hooks(docs), False
    for ph in PHASES:
        jobs = [h for h in hs if h[0] == "Job" and is_wipe(h) and ph in h[2]]
        if not jobs: continue
        found = True
        w = jobs[0][3]
        if show:
            print("  %s order: %s" % (ph, ", ".join("%d %s" % (x[3], x[1]) for x in sorted((x for x in hs if ph in x[2]), key=lambda x: (x[3], x[1])))))
        for k, n, p, wt in hs:
            if ph not in p or n == jobs[0][1]: continue
            if is_wipe((k, n, p, wt)):
                if wt >= w: errs.append("%s/%s: wipe RBAC %s/%s weight %d is not below the Job weight %d" % (label, ph, k, n, wt, w))
            elif wt >= w:
                errs.append("%s/%s: %s/%s weight %d is not below the wipe Job weight %d" % (label, ph, k, n, wt, w))
    if not found: errs.append("%s: no restate-wipe Job found in any pre-* phase (vacuous)" % label)
    return errs
def load(p): return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
if sys.argv[1] == "selftest":
    docs = load(sys.argv[2]); hit = False
    for d in docs:
        if "postgres-schema-init" in d["metadata"]["name"] and "helm.sh/hook" in (d["metadata"].get("annotations") or {}):
            d["metadata"]["annotations"]["helm.sh/hook-weight"] = "60"; hit = True
    e = check(docs, "selftest") if hit else []
    print("  selftest: postgres-schema-init at weight 60 -> %d problem(s)" % len(e))
    sys.exit(0 if hit and e else 1)
errs = []
for i, (p, l) in enumerate(zip(sys.argv[1:], ("default", "tierNode", "releasability"))):
    e = check(load(p), l, show=(i == 0))
    print("  %s %-18s" % ("FAIL" if e else "ok  ", l))
    errs += e
for e in errs: print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G23PY
"$PY" "$G23_DIR/last.py" "$G23_DIR/w1.yaml" "$G23_DIR/w2.yaml" "$G23_DIR/w3.yaml" || fail=1
if "$PY" "$G23_DIR/last.py" selftest "$G23_DIR/w1.yaml"; then
  echo "  ok   : self-test: the check fails when postgres-schema-init is at weight 60"
else
  echo "  FAIL: the check passed postgres-schema-init at weight 60 -- guard 23 cannot fail"; fail=1
fi
rm -rf "$G23_DIR"


echo "guard 24: sensor-ingest containers get a bounded spool directory"
G24_DIR="$(mktemp -d)"
render > "$G24_DIR/d.yaml"
render --set tierNode.enabled=true > "$G24_DIR/t.yaml"
render --set sensorIngest.spool.enabled=false > "$G24_DIR/off.yaml"
cat > "$G24_DIR/spool.py" <<'G24PY'
import sys, re, yaml
IMG = re.compile(r"(^|/)sensor-ingest[:@]")
def ingest(docs):
    for d in docs:
        # Hook Jobs (images-pullable) name the image only to probe a pull; they do not run it.
        if "helm.sh/hook" in ((d.get("metadata") or {}).get("annotations") or {}): continue
        spec = (((d.get("spec") or {}).get("template") or {}).get("spec")) or {}
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            if IMG.search(str(c.get("image", ""))):
                yield d, spec, c
def load(p): return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
def env(c, k):
    for e in c.get("env") or []:
        if e.get("name") == k: return e.get("value")
def check(docs, label):
    errs, n = [], 0
    for d, spec, c in ingest(docs):
        n += 1
        who = "%s/%s" % (label, d["metadata"]["name"])
        path = env(c, "INGEST_SPOOL_DIR")
        if not path: errs.append("%s: no INGEST_SPOOL_DIR" % who); continue
        mounts = [m for m in c.get("volumeMounts") or [] if m.get("mountPath") == path]
        if not mounts: errs.append("%s: no volumeMount at %s" % (who, path)); continue
        vol = [v for v in spec.get("volumes") or [] if v.get("name") == mounts[0]["name"]]
        ed = vol[0].get("emptyDir") if vol else None
        if not (ed and ed.get("sizeLimit")): errs.append("%s: mount %s is not an emptyDir with a sizeLimit" % (who, path))
    if n == 0: errs.append("%s: 0 sensor-ingest containers found (vacuous)" % label)
    return errs, n
def control(docs):
    errs, n = [], 0
    for d, spec, c in ingest(docs):
        n += 1
        who = d["metadata"]["name"]
        if env(c, "INGEST_SPOOL_DIR") is not None: errs.append("control: %s still has INGEST_SPOOL_DIR" % who)
        if any(m.get("mountPath") == "/var/spool/ingest" for m in c.get("volumeMounts") or []): errs.append("control: %s still mounts the spool" % who)
        if any(v.get("name") == "ingest-spool" for v in spec.get("volumes") or []): errs.append("control: %s still has the ingest-spool volume" % who)
    if n == 0: errs.append("control: 0 sensor-ingest containers found (vacuous)")
    return errs, n
errs = []
for p, l in zip(sys.argv[1:3], ("default", "tierNode")):
    e, n = check(load(p), l)
    print("  %s %-10s %d sensor-ingest container(s)" % ("FAIL" if e else "ok  ", l, n)); errs += e
e, n = control(load(sys.argv[3]))
print("  %s control spool.enabled=false: %d container(s) carry no spool" % ("FAIL" if e else "ok  ", n)); errs += e
for e in errs: print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G24PY
"$PY" "$G24_DIR/spool.py" "$G24_DIR/d.yaml" "$G24_DIR/t.yaml" "$G24_DIR/off.yaml" || fail=1
rm -rf "$G24_DIR"
echo "guard 25: cm-service and logistics-fusion containers carry the stall liveness probe"
G25_DIR="$(mktemp -d)"
render > "$G25_DIR/d.yaml"
render --set tierNode.enabled=true > "$G25_DIR/t.yaml"
render --set cmService.stallProbe.enabled=false --set logisticsFusion.stallProbe.enabled=false --set tierNode.enabled=true > "$G25_DIR/off.yaml"
cat > "$G25_DIR/live.py" <<'G25PY'
import sys, re, yaml
IMG = re.compile(r"(^|/)(cm-service|logistics-fusion-service)[:@]")
NAMES = ("cm-service", "logistics-fusion")
def load(p): return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
def containers(docs, kind):
    # Hook docs are included: bootstrap Jobs are hooks and are checked by the negative guard.
    for d in docs:
        if d.get("kind") != kind: continue
        spec = (((d.get("spec") or {}).get("template") or {}).get("spec")) or {}
        for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
            m = IMG.search(str(c.get("image", "")))
            if m: yield d, c, m.group(2)
def services(docs):
    # Long-running service containers: kind Deployment, container named cm-service/logistics-fusion, matching image.
    return [x for x in containers(docs, "Deployment") if x[1].get("name") in NAMES]
def tally(items):
    t = {}
    for _, _, k in items: t[k] = t.get(k, 0) + 1
    return ", ".join("%d %s" % (v, k) for k, v in sorted(t.items())) or "none"
errs, jobs = [], 0
for p, l in zip(sys.argv[1:3], ("default", "tierNode")):
    items = services(load(p)); e = []
    for d, c, k in items:
        h = (c.get("livenessProbe") or {}).get("httpGet") or {}
        if h.get("path") != "/healthz/live" or h.get("port") != 9464:
            e.append("%s: Deployment/%s container %s: no livenessProbe httpGet /healthz/live:9464 (got %s)" % (l, d["metadata"]["name"], c.get("name"), h or "none"))
    if not items: e.append("%s: 0 service containers found (vacuous)" % l)
    if l == "tierNode" and {k for _, _, k in items} != {"cm-service", "logistics-fusion-service"}:
        e.append("tierNode: expected both images, found: " + tally(items))
    j = list(containers(load(p), "Job")); jobs += len(j)
    e += ["%s: Job/%s container %s must not have a livenessProbe" % (l, d["metadata"]["name"], c.get("name")) for d, c, _ in j if c.get("livenessProbe")]
    print("  %s %-10s %d Deployment container(s): %s; %d Job container(s) on these images, none probed" % ("FAIL" if e else "ok  ", l, len(items), tally(items), len(j))); errs += e
items = services(load(sys.argv[3]))
e = ["control: Deployment/%s container %s still has a livenessProbe" % (d["metadata"]["name"], c.get("name")) for d, c, _ in items if c.get("livenessProbe")]
if not items: e.append("control: 0 containers found (vacuous)")
print("  %s control stallProbe.enabled=false: %d container(s), none with a livenessProbe" % ("FAIL" if e else "ok  ", len(items))); errs += e
if jobs == 0: errs.append("0 Job containers seen on these images (negative check vacuous)")
for e in errs: print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G25PY
"$PY" "$G25_DIR/live.py" "$G25_DIR/d.yaml" "$G25_DIR/t.yaml" "$G25_DIR/off.yaml" || fail=1
rm -rf "$G25_DIR"
echo "guard 26: every Connect relay and the DIS mapper carry the relay-stall liveness probe, reading their own metrics port"
G26_DIR="$(mktemp -d)"
render > "$G26_DIR/d.yaml"
render --set tierNode.enabled=true > "$G26_DIR/t.yaml"
render --set relayStallProbe.enabled=false --set tierNode.enabled=true > "$G26_DIR/off.yaml"
cat > "$G26_DIR/stall.py" <<'G26PY'
import sys, re, yaml
IMG = re.compile(r"(^|/)redpandadata/connect[:@]")
def load(p): return [d for d in yaml.safe_load_all(open(p, encoding="utf-8")) if d]
def hook(d): return "helm.sh/hook" in ((d.get("metadata") or {}).get("annotations") or {})
def selected(docs):
    for d in docs:
        if d.get("kind") != "Deployment" or hook(d): continue
        spec = (((d.get("spec") or {}).get("template") or {}).get("spec")) or {}
        for c in spec.get("containers") or []:
            if IMG.search(str(c.get("image", ""))): yield d, spec, c, docs
def env(c): return {e["name"]: e.get("value", "") for e in c.get("env") or []}
def declared_http(cm_name, docs):
    # True when a mounted connect.yaml sets http.address (so 4195 would NOT be the port).
    for d in docs:
        if d.get("kind") == "ConfigMap" and d["metadata"]["name"] == cm_name:
            for v in (d.get("data") or {}).values():
                try: y = yaml.safe_load(v)
                except Exception: continue
                if isinstance(y, dict) and (y.get("http") or {}).get("address"): return True
    return False
def check(l, d, spec, c, docs):
    n = "Deployment/%s container %s" % (d["metadata"]["name"], c.get("name")); e = []
    cmd = " ".join((c.get("livenessProbe") or {}).get("exec", {}).get("command") or [])
    if "/probe/relay-stall-probe.sh" not in cmd: e.append("%s: %s: no exec livenessProbe running /probe/relay-stall-probe.sh" % (l, n))
    vm = [m for m in c.get("volumeMounts") or [] if m.get("mountPath") == "/probe"]
    vols = {v["name"]: v for v in spec.get("volumes") or []}
    cm = ((vols.get(vm[0]["name"], {}) if vm else {}).get("configMap") or {}).get("name", "")
    if not cm.endswith("-relay-stall-probe"): e.append("%s: %s: no /probe mount from a *-relay-stall-probe configMap (got %r)" % (l, n, cm))
    ev = env(c); url = ev.get("METRICS_URL")
    m = re.match(r"https?://[^/:]+:(\d+)/", url) if url else None
    port = int(m.group(1)) if m else (4195 if not url else None)
    declared = [p.get("containerPort") for p in c.get("ports") or []]
    how = ""
    if port is None: e.append("%s: %s: METRICS_URL %r has no readable port" % (l, n, url))
    elif declared:
        how = "metrics port %d, declared %s" % (port, declared)
        if port not in declared: e.append("%s: %s: METRICS_URL port %d is not a declared containerPort %s (the probe would read nothing and never fire)" % (l, n, port, declared))
    else:
        # No containerPort: provable only if the port is Connect's default 4195 and no mounted config moves it.
        cfgs = [v["configMap"]["name"] for v in vols.values() if v.get("configMap") and "relay-stall" not in v["configMap"]["name"]]
        if port == 4195 and cfgs and not any(declared_http(x, docs) for x in cfgs):
            how = "metrics port 4195 (Connect default; no http.address in %s; no containerPort declared)" % ",".join(cfgs)
        else: e.append("%s: %s: metrics port unproven (port %s, no containerPort declared)" % (l, n, port))
    dh = ev.get("DEST_HOST", "")
    if "-redpanda-connect-" in d["metadata"]["name"]:
        if dh: e.append("%s: %s: the mapper must run two-term, but DEST_HOST=%r" % (l, n, dh))
        how += "; two-term"
    elif not dh: e.append("%s: %s: relay has an empty DEST_HOST" % (l, n))
    else: how += "; DEST_HOST=%s" % dh
    print("  %s %-9s %s: %s" % ("FAIL" if e else "ok  ", l, n, how)); return e
errs = []
for p, l in zip(sys.argv[1:3], ("default", "tierNode")):
    docs = load(p); items = list(selected(docs)); e = []
    for d, spec, c, _ in items: e += check(l, d, spec, c, docs)
    maps = [d for d, _, _, _ in items if "-redpanda-connect-" in d["metadata"]["name"]]
    if not items: e.append("%s: 0 Connect containers found (vacuous)" % l)
    if l == "default" and len(maps) != 3: e.append("default: expected 3 mappers, found %d" % len(maps))
    if l == "tierNode" and not any("uplink" in d["metadata"]["name"] for d, _, _, _ in items): e.append("tierNode: no tier-uplink found")
    print("  %s %-9s %d Connect container(s), %d mapper(s)" % ("FAIL" if e else "ok  ", l, len(items), len(maps))); errs += e
items = list(selected(load(sys.argv[3])))
e = ["control: Deployment/%s container %s still has a livenessProbe" % (d["metadata"]["name"], c.get("name")) for d, _, c, _ in items if c.get("livenessProbe")]
if not items: e.append("control: 0 containers found (vacuous)")
print("  %s control relayStallProbe.enabled=false: %d container(s), none with a livenessProbe" % ("FAIL" if e else "ok  ", len(items))); errs += e
for e in errs: print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G26PY
"$PY" "$G26_DIR/stall.py" "$G26_DIR/d.yaml" "$G26_DIR/t.yaml" "$G26_DIR/off.yaml" || fail=1
rm -rf "$G26_DIR"
echo
echo "guard 27: relay-stall-probe.sh judges correctly on single- and multi-series Connect metrics"
G27_DIR="$(mktemp -d)"
PROBE="$(cd "$(dirname "$0")/.." && pwd)/openddil-demo/files/relay-stall-probe.sh"
g27_fail=0
if ! command -v sh >/dev/null 2>&1 || ! command -v awk >/dev/null 2>&1; then
  echo "  FAIL: sh or awk is missing; the probe cannot be exercised (a skip would be a silent pass)"
  g27_fail=1
else
  mkdir -p "$G27_DIR/bin"
  printf '#!/bin/sh\ncat "$FAKE_METRICS"\n' > "$G27_DIR/bin/wget"
  chmod +x "$G27_DIR/bin/wget"
  g27_mapper() {  # g27_mapper <inputs.0> <cases.2>
    printf '%s\n' \
      "input_received{label=\"\",path=\"root.input.broker.inputs.0\"} $1" \
      'input_received{label="",path="root.input.broker.inputs.1"} 0' \
      'output_sent{label="",path="root.output.switch.cases.0.output"} 0' \
      'output_sent{label="",path="root.output.switch.cases.1.output"} 0' \
      "output_sent{label=\"\",path=\"root.output.switch.cases.2.output\"} $2"
  }
  g27_bridge() {  # g27_bridge <input> <output>
    printf '%s\n' \
      "input_received{label=\"\",path=\"root.input\"} $1" \
      "output_sent{label=\"\",path=\"root.output\"} $2"
  }
  g27_mapper 633 632 > "$G27_DIR/m-a"
  g27_mapper 700 699 > "$G27_DIR/m-flow"
  g27_mapper 700 632 > "$G27_DIR/m-stall"
  g27_bridge 4.059462e+06 4.053927e+06 > "$G27_DIR/s-a"
  g27_bridge 4.0596e+06 4.053927e+06 > "$G27_DIR/s-stall"
  g27_bridge 4.0596e+06 4.0545e+06 > "$G27_DIR/s-flow"
  : > "$G27_DIR/empty"
  # g27_run <name> <fixtureA|-> <fixtureB> <want-exit> <want-substring>
  g27_run() {
    local name="$1" fa="$2" fb="$3" wantrc="$4" wantsub="$5" out rc
    rm -f "$G27_DIR/state"
    if [ "$fa" != "-" ]; then
      FAKE_METRICS="$G27_DIR/$fa" PATH="$G27_DIR/bin:$PATH" STATE_FILE="$G27_DIR/state" DEST_HOST= \
        METRICS_URL=http://x/metrics sh "$PROBE" >/dev/null 2>&1
    fi
    out="$(FAKE_METRICS="$G27_DIR/$fb" PATH="$G27_DIR/bin:$PATH" STATE_FILE="$G27_DIR/state" DEST_HOST= \
      METRICS_URL=http://x/metrics sh "$PROBE" 2>&1)"; rc=$?
    if [ "$rc" = "$wantrc" ] && case "$out" in *"$wantsub"*) true;; *) false;; esac; then
      echo "  ok   $name: exit $rc, \"$out\""
    else
      echo "  FAIL $name: wanted exit $wantrc / \"$wantsub\", got exit $rc, \"$out\""
      g27_fail=1
    fi
  }
  g27_run "multi-series flowing"  m-a m-flow  0 "flowing"
  g27_run "multi-series stalled"  m-a m-stall 1 "STALLED"
  g27_run "multi-series idle"     m-a m-a     0 "input idle"
  g27_run "single-series stalled" s-a s-stall 1 "STALLED"
  g27_run "single-series flowing" s-a s-flow  0 "flowing"
  g27_run "unreadable"            -   empty   0 "not judging"
fi
[ "$g27_fail" -eq 0 ] || fail=1
rm -rf "$G27_DIR"
echo
# --- guard 28: every OpenDDIL image follows global.imageRegistry --------------
# THE DEFECT MODELLED: an OpenDDIL-built image that renders its repository
# verbatim (thirdPartyImage) instead of through openddil.image. A deployment
# that mirrors images overrides global.imageRegistry and is done -- except for
# that one image, which keeps pulling from the default registry: the
# images-pullable hook sits in ImagePullBackOff and the upgrade is refused.
# Render with global.imageRegistry=registry.invalid and every image-adding
# feature on (guard 21's set, plus the reset Job). Refs come from every
# `image:` field in the manifests and from the reset Job's pod spec inside the
# exercise-reset-job ConfigMap's job.json (parsed, not grepped). FAIL on any
# ref under the default image prefix that does not start with
# registry.invalid/. Scope control: FAIL unless a reset-runner ref was seen
# (the check must see the image it exists for) and at least 5 own refs were.
# Compatibility: a non-empty resetJob.image.repository is used verbatim, in
# BOTH the job.json pod spec and the images-pullable hook.
echo "guard 28: every OpenDDIL image follows global.imageRegistry"
G28_DIR="$(mktemp -d)"
G28_ARGS=(--set linkControl.enabled=true --set restate.ephemeralOnUpgrade=true
  --set releasability.enabled=true --set releasability.keycloak.enabled=true
  --set egress.tak.enabled=true --set egress.tak.tls.enabled=true
  --set egress.tak.tls.secretName=guard28-secret --set-json 'egress.tak.tls.allowedClientCNs=["guard28-cn"]'
  --set tierNode.enabled=true --set tierNode.topaz.enabled=true --set cmReports.enabled=true
  --set exerciseControl.enabled=true --set exerciseControl.adapter.endpoint=https://example.invalid/api
  --set exerciseControl.resetJob.enabled=true)
render "${G28_ARGS[@]}" --set global.imageRegistry=registry.invalid > "$G28_DIR/reg.yaml"
render "${G28_ARGS[@]}" --set global.imageRegistry=registry.invalid \
  --set exerciseControl.resetJob.image.repository=example.invalid/x/reset-runner > "$G28_DIR/compat.yaml"
cat > "$G28_DIR/check.py" <<'G28PY'
import sys, json, yaml
PREFIX = "edgy-solutions/openddil/"
def podspec(d):
    k, s = d.get("kind"), d.get("spec") or {}
    if k == "Pod": return s
    if k == "CronJob": return (((s.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    return (s.get("template") or {}).get("spec") or {}
def images(ps):
    return [c["image"] for k in ("containers", "initContainers") for c in ps.get(k) or [] if c.get("image")]
def collect(path):
    """-> (manifest refs, job.json refs, hook refs)"""
    man, job, hook = [], [], []
    def walk(d):
        if not isinstance(d, dict): return
        if d.get("kind") == "List":
            for i in d.get("items") or []: walk(i)
            return
        name = (d.get("metadata") or {}).get("name") or ""
        if d.get("kind") == "ConfigMap" and name.endswith("-exercise-reset-job"):
            job.extend(images(podspec(json.loads((d.get("data") or {})["job.json"]))))
            return
        ps = podspec(d)
        refs = images(ps)
        man.extend(refs)
        if d.get("kind") == "Job" and "-images-pullable-" in name: hook.extend(refs)
    for d in yaml.safe_load_all(open(path, encoding="utf-8")): walk(d)
    return man, job, hook
errs = []
man, job, hook = collect(sys.argv[1])
allrefs = set(man) | set(job)
own = sorted(r for r in allrefs if "/" + PREFIX in r or r.startswith(PREFIX))
for r in own:
    if not r.startswith("registry.invalid/"):
        errs.append("does not follow global.imageRegistry: " + r)
if not any("reset-runner" in r for r in own): errs.append("no reset-runner ref seen -- the check cannot see the image it exists for")
if not any("reset-runner" in r for r in job): errs.append("no reset-runner ref in the exercise-reset-job job.json pod spec")
if len(own) < 5: errs.append("only %d own image ref(s) found (need >= 5)" % len(own))
print("  %d image ref(s), %d own, %d from job.json" % (len(allrefs), len(own), len(job)))
man, job, hook = collect(sys.argv[2])
want = [r for r in sys.argv[3:]]
for w in want:
    if w not in job: errs.append("compat: %s missing from the job.json pod spec" % w)
    if w not in hook: errs.append("compat: %s missing from the images-pullable hook" % w)
for e in errs: print("  FAIL: " + e)
sys.exit(1 if errs else 0)
G28PY
if ! command -v helm >/dev/null 2>&1 || ! command -v "$PY" >/dev/null 2>&1; then
  echo "  FAIL: helm or python is missing; guard 28 cannot run (a skip would be a silent pass)"; fail=1
else
  "$PY" "$G28_DIR/check.py" "$G28_DIR/reg.yaml" "$G28_DIR/compat.yaml" example.invalid/x/reset-runner:latest || fail=1
fi
rm -rf "$G28_DIR"
echo
[ "$fail" -eq 0 ] && echo "chart render guards: clean" || echo "chart render guards: FAILED"
exit "$fail"
