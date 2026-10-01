#!/usr/bin/env bash
# ===========================================================================
# check-pull-credentials.sh — will an upgrade to a chart where every pod
# names global.imagePullSecrets itself stop reaching a secret it reaches
# TODAY only because its ServiceAccount carries it?
# ===========================================================================
# Usage:
#   check-pull-credentials.sh <namespace> -- <helm template args: -f values... --set ...>
#
# WHY THIS EXISTS (see c:\tmp\overnight-0930\FINDINGS.md §5d and the chart's
# global.imagePullSecrets usage, e.g. openddil-demo/templates/edge.yaml):
# every pod spec in this chart names `global.imagePullSecrets` itself
# (`{{- with $root.Values.global.imagePullSecrets }} imagePullSecrets: ... {{- end }}`).
# Kubernetes admission copies a ServiceAccount's imagePullSecrets into a pod
# ONLY when that pod names none of its own. Today, with global.imagePullSecrets
# empty, the chart's pods name none and admission fills them in from whatever
# the ServiceAccount carries. The moment a deployment sets
# global.imagePullSecrets to anything, every pod names that list explicitly —
# and admission stops filling in anything else the ServiceAccount carries.
# Any OTHER secret reaching a pod only via its ServiceAccount today silently
# stops reaching it after that upgrade.
#
# WHAT THIS CHECKS, in two halves:
#   1. Every secret the render DECLARES (via global.imagePullSecrets) must
#      actually exist in the namespace — a declared-but-absent secret means
#      every pod image pull fails from the first rollout.
#   2. Every LIVE pod's own imagePullSecrets, and the imagePullSecrets of
#      every ServiceAccount the render uses (default, if a pod names none),
#      must be a subset of {declared secrets} ∪ {*-dockercfg-* — the
#      auto-generated legacy image-pull token, not a named secret}. Anything
#      else is a secret this upgrade would stop delivering.
#
# TESTABILITY: set PULLCHECK_FIXTURE_DIR to a directory holding pods.json,
# serviceaccounts.json and secrets.json (each the `kubectl get <kind> -n <ns>
# -o json` shape: {"items": [...]}) to exercise the live-side logic without a
# cluster that happens to have a ServiceAccount in this state. The render
# step always uses the real local chart — only the "live" half is swapped.
#
# EXIT: 0 PASS, 1 FAIL (named), 3 GATE NOT RUN (kubectl/helm unavailable, the
# namespace does not exist, or the chart would not render). 3 is never
# reported as a PASS — an unanswered question is not a clean bill of health.
# ===========================================================================
set -uo pipefail

NS="${1:-}"
if [ -z "$NS" ] || [ "${2:-}" != "--" ]; then
  echo "usage: $0 <namespace> -- <helm template args>" >&2
  exit 2
fi
shift 2
# "$@" is now whatever helm template args the caller supplied (may be empty).

RELEASE="${OPENDDIL_RELEASE:-openddil}"
CHART="$(cd "$(dirname "$0")/.." && pwd)/openddil-demo"
PY=$(command -v python3 || command -v python || echo py)
FIXTURE_DIR="${PULLCHECK_FIXTURE_DIR:-}"

command -v "$PY" >/dev/null 2>&1 || { echo "no python interpreter found — GATE NOT RUN" >&2; exit 3; }
command -v helm >/dev/null 2>&1 || { echo "helm not found — GATE NOT RUN" >&2; exit 3; }

if [ -n "$FIXTURE_DIR" ]; then
  for f in pods.json serviceaccounts.json secrets.json; do
    [ -r "$FIXTURE_DIR/$f" ] || { echo "PULLCHECK_FIXTURE_DIR is set but $FIXTURE_DIR/$f is not readable — GATE NOT RUN" >&2; exit 3; }
  done
  echo "fixture mode: reading pods/serviceaccounts/secrets from $FIXTURE_DIR (no live cluster read)"
else
  command -v kubectl >/dev/null 2>&1 || { echo "kubectl not found — GATE NOT RUN" >&2; exit 3; }
  kubectl get ns "$NS" >/dev/null 2>&1 || { echo "namespace '$NS' not found (or cluster unreachable) — GATE NOT RUN" >&2; exit 3; }
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

if ! helm template "$RELEASE" "$CHART" "$@" > "$TMP/render.yaml" 2> "$TMP/helm.err"; then
  echo "helm template failed — GATE NOT RUN:" >&2
  cat "$TMP/helm.err" >&2
  exit 3
fi

if [ -n "$FIXTURE_DIR" ]; then
  cp "$FIXTURE_DIR/pods.json" "$TMP/pods.json"
  cp "$FIXTURE_DIR/serviceaccounts.json" "$TMP/serviceaccounts.json"
  cp "$FIXTURE_DIR/secrets.json" "$TMP/secrets.json"
else
  if ! kubectl get pods -n "$NS" -o json > "$TMP/pods.json" 2>"$TMP/kc.err"; then
    echo "kubectl get pods failed — GATE NOT RUN:" >&2; cat "$TMP/kc.err" >&2; exit 3
  fi
  if ! kubectl get serviceaccounts -n "$NS" -o json > "$TMP/serviceaccounts.json" 2>"$TMP/kc.err"; then
    echo "kubectl get serviceaccounts failed — GATE NOT RUN:" >&2; cat "$TMP/kc.err" >&2; exit 3
  fi
  if ! kubectl get secrets -n "$NS" -o json > "$TMP/secrets.json" 2>"$TMP/kc.err"; then
    echo "kubectl get secrets failed — GATE NOT RUN:" >&2; cat "$TMP/kc.err" >&2; exit 3
  fi
fi

echo "pull-credential gate — namespace '$NS', release '$RELEASE'"
echo

"$PY" - "$TMP/render.yaml" "$TMP/pods.json" "$TMP/serviceaccounts.json" "$TMP/secrets.json" <<'PY'
import fnmatch, json, sys
import yaml

render_path, pods_path, sa_path, secrets_path = sys.argv[1:5]

def pod_spec(doc):
    kind, spec = doc.get("kind"), doc.get("spec") or {}
    if kind == "Pod":
        return spec
    if kind in ("Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "Job"):
        return (spec.get("template") or {}).get("spec")
    if kind == "CronJob":
        return (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec")
    return None

with open(render_path, encoding="utf-8") as fh:
    docs = [d for d in yaml.safe_load_all(fh) if d]

declared = set()
sa_used = {}   # sa name -> set of "Kind/name" that use it
for doc in docs:
    ps = pod_spec(doc)
    if ps is None:
        continue
    for s in ps.get("imagePullSecrets") or []:
        n = s.get("name")
        if n:
            declared.add(n)
    sa_name = ps.get("serviceAccountName") or "default"
    sa_used.setdefault(sa_name, set()).add(f"{doc.get('kind')}/{(doc.get('metadata') or {}).get('name')}")

with open(secrets_path, encoding="utf-8") as fh:
    secrets_live = {i["metadata"]["name"] for i in (json.load(fh).get("items") or [])}

with open(pods_path, encoding="utf-8") as fh:
    pods_live = json.load(fh).get("items") or []

with open(sa_path, encoding="utf-8") as fh:
    sa_live = {i["metadata"]["name"]: i for i in (json.load(fh).get("items") or [])}

rows = []     # (ok, text)
fail = 0

def is_excused(name):
    return fnmatch.fnmatch(name, "*-dockercfg-*")

print(f"declared secrets (global.imagePullSecrets, as rendered): {sorted(declared) or '(none)'}")
print(f"ServiceAccounts the render uses: {sorted(sa_used)}")
print()

print("-- declared secrets must exist --")
if not declared:
    print("  (none declared — nothing to check here)")
for name in sorted(declared):
    if name in secrets_live:
        print(f"  PASS  secret/{name} exists")
    else:
        print(f"  FAIL  secret/{name} is declared in global.imagePullSecrets but does NOT exist in the namespace")
        fail += 1

print()
print("-- live pods must carry nothing this upgrade would drop --")
if not pods_live:
    print("  (no live pods in this namespace)")
for pod in pods_live:
    pname = (pod.get("metadata") or {}).get("name", "<unnamed>")
    pull = [s.get("name") for s in ((pod.get("spec") or {}).get("imagePullSecrets") or []) if s.get("name")]
    if not pull:
        print(f"  PASS  pod/{pname} carries no imagePullSecrets of its own")
        continue
    for name in pull:
        if name in declared:
            print(f"  PASS  pod/{pname} carries '{name}' — already in global.imagePullSecrets")
        elif is_excused(name):
            print(f"  PASS  pod/{pname} carries '{name}' — matches *-dockercfg-* (legacy token, not a named secret)")
        else:
            print(f"  FAIL  pod/{pname} carries '{name}', which is not declared and not a *-dockercfg-* token:")
            print(f"        would stop reaching this pod after the upgrade; add it to global.imagePullSecrets")
            fail += 1

print()
print("-- ServiceAccounts the render uses must carry nothing this upgrade would drop --")
for sa_name, users in sorted(sa_used.items()):
    sa = sa_live.get(sa_name)
    if sa is None:
        print(f"  NOTE  ServiceAccount/{sa_name} not found live — cannot verify (used by {sorted(users)})")
        continue
    pull = [s.get("name") for s in (sa.get("imagePullSecrets") or []) if s.get("name")]
    if not pull:
        print(f"  PASS  ServiceAccount/{sa_name} carries no imagePullSecrets")
        continue
    for name in pull:
        if name in declared:
            print(f"  PASS  ServiceAccount/{sa_name} carries '{name}' — already in global.imagePullSecrets")
        elif is_excused(name):
            print(f"  PASS  ServiceAccount/{sa_name} carries '{name}' — matches *-dockercfg-* (legacy token, not a named secret)")
        else:
            print(f"  FAIL  ServiceAccount/{sa_name} carries '{name}', which is not declared and not a *-dockercfg-* token:")
            print(f"        would stop reaching pods using it ({sorted(users)}) after the upgrade; add it to global.imagePullSecrets")
            fail += 1

print()
if fail:
    print(f"RESULT: FAIL ({fail} finding(s))")
    sys.exit(1)
print("RESULT: PASS")
sys.exit(0)
PY
exit $?
