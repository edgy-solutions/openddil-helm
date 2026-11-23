#!/usr/bin/env bash
# ===========================================================================
# test_pep_label_registry_render.sh -- offline render proof for the PEP's
# label-registry refresh interval and maximum staleness, declared per tier.
#
# Every render is piped straight into the checker or its stderr is read with
# stdout discarded: the render holds Secrets and is never written to a file.
#
# Cases:
#   A. defaults: the hub PEP and every tier PEP render "2.5" and "5".
#   B. one edge declares {10, 60}: only its PEP changes.
#   C. an edge declares only maxStaleSeconds 20: it renders 2.5 / 20.
#   D. releasability.pep.labelRegistry changes the hub and every undeclared tier.
#   E. the explicit tiers: path carries a tier's labelRegistry through.
#   F. the render refuses, naming the tier, for refresh 0, -1, max == refresh,
#      max < refresh, and a string; and refuses a bad hub block.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHART="${CHART:-$HERE/../../openddil-demo}"

PY=""
for c in python python3 py; do
  if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
[ -n "$PY" ] || { echo "SKIP: no python with PyYAML"; exit 2; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FAIL=0

# Values files hold no Secret; only renders do.
cat > "$TMP/base.yaml" <<'YEOF'
releasability: {enabled: true, oidc: {enabled: true}}
tierNode: {enabled: true}
YEOF
cat > "$TMP/edge-decl.yaml" <<'YEOF'
edges:
  - {id: edge-01, region: region-east, udpPort: 62040, labelRegistry: {refreshSeconds: 10, maxStaleSeconds: 60}}
  - {id: edge-02, region: region-east, udpPort: 62041, labelRegistry: {maxStaleSeconds: 20}}
  - {id: edge-03, region: region-west, udpPort: 62042}
YEOF
cat > "$TMP/region-decl.yaml" <<'YEOF'
regions:
  - {id: region-east, labelRegistry: {refreshSeconds: 3, maxStaleSeconds: 9}}
  - {id: region-west}
YEOF
cat > "$TMP/tiers.yaml" <<'YEOF'
tiers:
  - {id: region-a, kind: region, parent: root, hasChildren: true, label: region-a, publicOrigin: "http://region-a.test", directIngest: false, region: region-a, labelRegistry: {refreshSeconds: 4, maxStaleSeconds: 30}}
  - {id: edge-a1, kind: edge, parent: region-a, hasChildren: false, label: edge-a1, publicOrigin: "http://edge-a1.test", directIngest: true, region: region-a}
YEOF

# One line per PEP container: <deployment> <refresh> <max stale>, sorted.
facts() {  # helm args; the render goes down the pipe
  helm template t "$CHART" -f "$TMP/base.yaml" "$@" 2>"$TMP/err" | "$PY" -c '
import sys, yaml
out = []
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") != "Deployment":
        continue
    for c in d["spec"]["template"]["spec"]["containers"]:
        if c["name"] != "pep":
            continue
        env = {}
        n = {}
        for e in c.get("env", []):
            env[e["name"]] = e.get("value", "")
            n[e["name"]] = n.get(e["name"], 0) + 1
        r, m = "OPENDDIL_LABEL_REGISTRY_REFRESH_S", "OPENDDIL_LABEL_REGISTRY_MAX_STALE_S"
        once = n.get(r) == 1 and n.get(m) == 1
        out.append("%s %s %s%s" % (d["metadata"]["name"], env.get(r, "-"), env.get(m, "-"), "" if once else " NOT-ONCE"))
print("\n".join(sorted(out)))
' | tr -d '\r'
}

refusal() {  # helm args; stdout discarded, stderr returned (empty if it rendered)
  if helm template t "$CHART" -f "$TMP/base.yaml" "$@" 2>&1 >/dev/null | tr -d '\r' > "$TMP/refusal"; then :; fi
  cat "$TMP/refusal"
}

check() {  # $1 = case, $2 = got, $3 = want
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ';')"; echo "  want: $(echo "$3" | tr '\n' ';')"; FAIL=1; fi
}

all() {  # $1 = refresh, $2 = max: the expected line for every name in $3...
  local r="$1" m="$2"; shift 2
  for n in "$@"; do echo "$n $r $m"; done
}

E1=t-tier-pep-edge-01; E2=t-tier-pep-edge-02; E3=t-tier-pep-edge-03
RE=t-tier-pep-region-east; RW=t-tier-pep-region-west; HUB=t-pep
ALL5="$E1 $E2 $E3 $RE $RW"

# A
got="$(facts)"
check "A hub and 5 tier PEPs at 2.5 / 5" "$got" "$(all 2.5 5 $HUB $E1 $E2 $E3 $RE $RW | sort)"

# B and C
got="$(facts -f "$TMP/edge-decl.yaml")"
want="$( { all 10 60 $E1; all 2.5 20 $E2; all 2.5 5 $HUB $E3 $RE $RW; } | sort)"
check "B/C edge-01 {10,60}, edge-02 max only {2.5,20}, the rest default" "$got" "$want"

# regions carry it too
got="$(facts -f "$TMP/region-decl.yaml")"
want="$( { all 3 9 $RE; all 2.5 5 $HUB $E1 $E2 $E3 $RW; } | sort)"
check "B region-east {3,9}, the rest default" "$got" "$want"

# D
got="$(facts --set releasability.pep.labelRegistry.refreshSeconds=1 --set releasability.pep.labelRegistry.maxStaleSeconds=7 -f "$TMP/edge-decl.yaml")"
want="$( { all 10 60 $E1; all 1 20 $E2; all 1 7 $HUB $E3 $RE $RW; } | sort)"
check "D block {1,7}: hub and undeclared tiers follow; declared keys win" "$got" "$want"
got="$(facts --set-json 'releasability.pep.labelRegistry.maxStaleSeconds=12.5')"
check "D block max 12.5 renders as 12.5 everywhere" "$got" "$(all 2.5 12.5 $HUB $E1 $E2 $E3 $RE $RW | sort)"

# E
got="$(facts -f "$TMP/tiers.yaml")"
want="$( { all 4 30 t-tier-pep-region-a; all 2.5 5 $HUB t-tier-pep-edge-a1; } | sort)"
check "E explicit tiers: region-a {4,30}, edge-a1 and hub default" "$got" "$want"

# F
pre="$TMP/bad.yaml"
refuse_edge() {  # $1 = labelRegistry flow map; $2 = case; $3 = key the message must name
  printf 'edges:\n  - {id: edge-01, region: region-east, udpPort: 62040, labelRegistry: %s}\n' "$1" > "$pre"
  local msg; msg="$(refusal -f "$pre")"
  if printf '%s' "$msg" | grep -q "tier edge-01: labelRegistry\.$3"; then echo "PASS F $2 refused, names edge-01 and $3"; else echo "FAIL F $2: got: $(printf '%s' "$msg" | head -c 300)"; FAIL=1; fi
}
refuse_edge '{refreshSeconds: 0}' "refresh 0" refreshSeconds
refuse_edge '{refreshSeconds: -1}' "refresh -1" refreshSeconds
refuse_edge '{refreshSeconds: 5}' "max == refresh" maxStaleSeconds
refuse_edge '{refreshSeconds: 10, maxStaleSeconds: 9}' "max < refresh" maxStaleSeconds
refuse_edge '{maxStaleSeconds: "5"}' "string value" maxStaleSeconds
refuse_edge '{maxStaleSeconds: 2}' "max below the inherited refresh" maxStaleSeconds

msg="$(refusal --set tierNode.enabled=false --set releasability.pep.labelRegistry.refreshSeconds=0)"
if printf '%s' "$msg" | grep -q "tier hub: labelRegistry\.refreshSeconds"; then echo "PASS F bad hub block refused, names hub"; else echo "FAIL F bad hub block: got: $(printf '%s' "$msg" | head -c 300)"; FAIL=1; fi

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
