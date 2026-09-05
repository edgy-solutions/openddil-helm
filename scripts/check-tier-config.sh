#!/usr/bin/env bash
# Tier-parameterized presentation — does the chart emit a config the frontend
# will accept? (ADR-0033 §Tier-parameterized presentation)
#
#   ./scripts/check-tier-config.sh
#
# ---------------------------------------------------------------------------
# WHY THIS EXISTS: UD-9 WAS EXACTLY THIS GAP
# ---------------------------------------------------------------------------
# The chart used to set a per-tier `ELECTRIC_URL` env var that the frontend
# read from a Vite BUILD-TIME constant instead. Two artifacts in two
# repositories, agreeing by convention and by nothing else, and the
# disagreement produced no error at any layer — every tier's UI silently read
# the root's store.
#
# The tier parameter is the same shape of contract: the chart WRITES
# `deployment.json`, the frontend PARSES it, and nothing else compares them.
# So this check reads what the chart actually renders and asserts the
# frontend's rules against it.
#
# ---------------------------------------------------------------------------
# THIS CHECK OWNS ONE HALF ONLY
# ---------------------------------------------------------------------------
# It validates the CONFIG the chart emits: present, parseable, complete,
# distinct per tier. It does NOT reimplement the shape→instance decision —
# that lives in `openddil-demo/frontend/src/lib/tierShape.ts` and is tested
# there (`src/lib/__tests__/tierShape.test.ts`).
#
# Copying the decision here would create a second version to keep in sync,
# which is the failure this whole family of checks is about. Two checks, one
# half each, neither duplicating the other.
set -uo pipefail

CHART="$(cd "$(dirname "$0")/.." && pwd)/openddil-demo"
PY=$(command -v python3 || command -v python || echo py)
fail=0

if ! command -v helm >/dev/null 2>&1; then
  echo "helm not found — this check would pass vacuously" >&2
  exit 1
fi

# A FOURTH TIER, supplied at render time and present in no committed values
# file. This is ADR-0033's forcing function made mechanical: the moment a
# deployment configures a fourth tier, "which of the three hardcoded views
# does it get?" must have an answer.
#
# It is an INTERMEDIATE hanging off another intermediate — a depth this
# deployment has never had — so nothing about it can be satisfied by the
# two-level assumptions the rest of the system carries.
render() {
  helm template t "$CHART" \
    --set tierNode.enabled=true \
    --set 'edges[0].id=edge-01' --set 'edges[0].region=region-east' --set 'edges[0].udpPort=62040' \
    --set 'edges[1].id=region-east' --set 'edges[1].region=hq' \
    --set 'edges[1].hasChildren=true' \
    --set 'edges[2].id=sector-7' --set 'edges[2].parent=region-east' \
    --set 'edges[2].hasChildren=true' \
    2>/dev/null
}

echo "tier config check"
OUT="$(render)"
if [ -z "$OUT" ]; then
  echo "  FAIL: chart rendered nothing — the checks below would be vacuous" >&2
  exit 1
fi

printf '%s\n' "$OUT" | "$PY" -c '
import sys, yaml, json

docs = [d for d in yaml.safe_load_all(sys.stdin) if d]
cms = [d for d in docs
       if d.get("kind") == "ConfigMap"
       and "tier-frontend-config-" in (d.get("metadata") or {}).get("name", "")]

if not cms:
    print("  FAIL: no tier frontend ConfigMap rendered. Either the tier node")
    print("        stopped shipping one, or this check stopped finding it —")
    print("        and a green result here would mean neither was noticed.")
    sys.exit(1)

# The frontend parser rejects a config that is not COMPLETE. A partial tier
# identity gives a UI that confidently believes it is a tier it is not, which
# is UD-9 arriving through the door built to stop it. These rules mirror
# parseTier() deliberately and are stated, not imported, because the two
# artifacts live in different repositories — which is the whole reason this
# check exists rather than being unnecessary.
bad = []
seen = {}
for cm in cms:
    name = cm["metadata"]["name"]
    raw = (cm.get("data") or {}).get("deployment.json")
    if not raw:
        bad.append(f"{name}: no deployment.json key"); continue
    try:
        cfg = json.loads(raw)
    except Exception as exc:
        bad.append(f"{name}: deployment.json is not valid JSON ({exc})"); continue
    t = cfg.get("tier")
    if not isinstance(t, dict):
        bad.append(f"{name}: no tier block"); continue
    if not isinstance(t.get("id"), str) or not t["id"].strip():
        bad.append(f"{name}: tier.id missing or empty")
    if not isinstance(t.get("has_children"), bool):
        bad.append(name + ": has_children must be a bool, got " + repr(t.get("has_children")))
    # scope must be PRESENT and explicitly null, or a valid pair. Omission is
    # rejected by the frontend because it reads as an oversight, and an
    # unscoped read at a tier WITH children would show the whole subtree
    # under a leaf label.
    if "scope" not in t:
        bad.append(f"{name}: scope omitted (must be explicit null or a pair)")
    elif t["scope"] is not None:
        sc = t["scope"]
        if not isinstance(sc, dict) or sc.get("column") not in ("edge_id", "region_id"):
            bad.append(f"{name}: scope.column must be edge_id or region_id")
    if "parent" not in t:
        bad.append(f"{name}: parent omitted (must be explicit null or an id)")
    seen[t.get("id")] = (t.get("has_children"), t.get("parent"))

if bad:
    for b in bad:
        print("  FAIL: " + b)
    sys.exit(1)

print(f"  ok   {len(cms)} tier config(s), all complete and parseable")

# THE FORCING FUNCTION. A fourth tier — an intermediate under another
# intermediate — must be present and well-formed, with no code change.
if "sector-7" not in seen:
    print("  FAIL: the fourth tier rendered no config. ADR-0033s forcing")
    print("        function is that a fourth tier HAS an answer; if it has")
    print("        no config it has no answer.")
    sys.exit(1)
has_children, parent = seen["sector-7"]
if not has_children or parent != "region-east":
    print(f"  FAIL: fourth tier shape wrong: has_children={has_children!r} parent={parent!r}")
    sys.exit(1)
print("  ok   the FOURTH TIER renders a well-formed config with no code change")
print("       (sector-7: intermediate under region-east, a depth this")
print("        deployment has never had)")

# Distinctness. Two tiers whose shapes differ must produce configs that
# differ — otherwise the parameter is carried and unused, which looks exactly
# like a parameter that works.
shapes = set(seen.values())
if len(shapes) < 2:
    print("  FAIL: every tier rendered the SAME shape. The parameter is being")
    print("        carried and not varied, which is indistinguishable from a")
    print("        parameter that works.")
    sys.exit(1)
print(f"  ok   {len(shapes)} distinct shapes across {len(seen)} tiers")
' || fail=1

echo
if [ "$fail" -eq 0 ]; then
  cat <<'NOTE'
tier config check: clean

WHAT THIS DID NOT CHECK, and it matters:

  * The shape→instance DECISION. That lives in the frontend and is tested
    there; this check deliberately does not copy it.
  * That a fourth tier can be SCOPED. It cannot — the read model has
    `edge_id` and `region_id` and no tier path, so a fourth tier renders a
    valid config and still has no left-hand side to be filtered by. That is
    GD-01, and it is why the arc blocks on it rather than owning it. A tier
    node reads its own store unscoped, which is why the fourth tier is
    nonetheless useful today.
  * That the UI actually reads the store its config names. That is the
    conjunction pilot rung (i) infers rather than observes.
NOTE
else
  echo "tier config check: FAILED"
fi
exit "$fail"
