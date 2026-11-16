#!/usr/bin/env bash
# ===========================================================================
# test_bundle_content_checksums.sh -- offline render proof that each
# Deployment's checksum annotations and the realm version follow the CONTENT
# of the bundle files it reads, not the bundle image reference.
#
# Render: one region and one edge (tier node, own publicOrigin, identity
# replica), releasability + keycloak + oidc enabled, so the hub PEP, tier PEP,
# keycloak, tier keycloak, topaz, tier topaz, cm-intakes, declaration intake
# and egress all render.
#
# helm's stdout goes straight through a Python filter that drops every
# `kind: Secret` document and keeps only the extracted checksum/realm-version
# values; nothing unfiltered is written to disk.
#
# Cases:
#   A. digest change, same content: nothing moves.
#   B. one file (demo/gateway) changes: only the two PEP checksum/policy move.
#   C. the realm file changes: keycloak, tier keycloak, the realm-version
#      annotation, the tier import env and the PEP env move; one value
#      everywhere; PEP checksum/policy, topaz, intakes, egress do not.
#   D. egress checksum/registries does not move with the bundle digest, even
#      in the fallback mode.
#   E. fallback (no content digests, or digests for another bundle): the
#      bundle digest moves every bundle-path caller and the realm version.
#   F. unpinned: the realm version follows the tag.
#   G. a missing digest fails the render and names the path.
#   H. the topaz policy-loader reads (variant corpus, destinations.yaml).
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

DA="sha256:$(printf 'a%.0s' $(seq 64))"
DB="sha256:$(printf 'b%.0s' $(seq 64))"
DC="sha256:$(printf 'c%.0s' $(seq 64))"

SRCS="contracts/proto demo/cm-intake.yaml demo/declaration-intake.yaml demo/policy/.manifest demo/policy/releasability.rego demo/gateway contracts/ontology demo/ontology contracts/baselines demo/policy/realm-openddil.json demo/policy/users.yaml demo/policy/destinations.yaml"

# Values (no secrets in them). $1 = bundle digest ("" = unpinned),
# $2 = contentDigests.bundleDigest ("" = no contentDigests block),
# $3 = src whose digest differs, $4 = src to leave out.
write_values() {
  local out="$1" bd="$2" cdb="$3" change="${4:-}" omit="${5:-}" i=0 src h
  {
    echo "regions:"; echo "  - id: region-east"
    echo "edges:"
    echo "  - id: edge-01"; echo "    region: region-east"; echo "    udpPort: 62040"
    echo "    publicOrigin: http://edge-01.example.test"
    echo "    identity: { replica: true }"
    echo "tierNode: { enabled: true }"; echo "cmReports: { enabled: true }"; echo "egress: { intake: { enabled: true } }"
    echo "releasability: { enabled: true, keycloak: { enabled: true }, oidc: { enabled: true } }"
    echo "bundle:"
    echo "  image: { digest: \"$bd\" }"
    if [ -n "$cdb" ]; then
      echo "  contentDigests:"; echo "    bundleDigest: \"$cdb\""; echo "    paths:"
      for src in $SRCS; do
        i=$((i+1))
        [ "$src" = "$omit" ] && continue
        h="$(printf '%064x' "$i")"
        [ "$src" = "$change" ] && h="$(printf 'f%.0s' $(seq 64))"
        echo "      \"$src\": $h"
      done
    fi
  } > "$out"
}

# helm stdout -> filter. Prints JSON: {"x": {"<deployment>": {"<key>": value}},
# "all": sha256 of the Secret-free render}. Secrets are dropped in the pipe.
FILTER="$TMP/filter.py"
cat > "$FILTER" <<'PYEOF'
import sys, json, hashlib, yaml
x = {}
h = hashlib.sha256()
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") == "Secret":
        continue
    h.update(yaml.safe_dump(d, sort_keys=True).encode())
    if d.get("kind") != "Deployment":
        continue
    n = d["metadata"]["name"]
    t = d["spec"]["template"]
    v = {}
    for k, val in (t["metadata"].get("annotations") or {}).items():
        if k.startswith("checksum/") or k == "openddil.io/realm-version":
            v[k] = val
    for grp in ("containers", "initContainers"):
        for c in t["spec"].get(grp) or []:
            for e in c.get("env") or []:
                if e["name"] == "OPENDDIL_REALM_VERSION":
                    v["env:%s/%s" % (c["name"], e["name"])] = e.get("value")
    if v:
        x[n] = v
print(json.dumps({"x": x, "all": h.hexdigest()}))
PYEOF

# render <name> <values-file> [extra helm args]: out in $TMP/<name>.json,
# helm's exit status in $TMP/<name>.rc, stderr in $TMP/<name>.err.
render() {
  local name="$1" vf="$2"; shift 2
  helm template t "$CHART" -f "$vf" "$@" 2> "$TMP/$name.err" | "$PY" "$FILTER" > "$TMP/$name.json" 2>> "$TMP/$name.err"
  echo "${PIPESTATUS[0]}" > "$TMP/$name.rc"
}
rc() { cat "$TMP/$1.rc"; }

# changed <a> <b>: sorted "<deployment> <key>" pairs whose value differs.
changed() {
  "$PY" - "$TMP/$1.json" "$TMP/$2.json" <<'PYEOF'
import sys, json
a = json.load(open(sys.argv[1]))["x"]; b = json.load(open(sys.argv[2]))["x"]
out = []
for n in sorted(set(a) | set(b)):
    for k in sorted(set(a.get(n, {})) | set(b.get(n, {}))):
        if a.get(n, {}).get(k) != b.get(n, {}).get(k):
            out.append("%s %s" % (n, k))
print("\n".join(out))
PYEOF
}
# values <a> <regex-on-key>: distinct values of matching keys across Deployments.
distinct() {
  "$PY" - "$TMP/$1.json" "$2" <<'PYEOF'
import sys, json, re
a = json.load(open(sys.argv[1]))["x"]
s = {v for n in a for k, v in a[n].items() if re.search(sys.argv[2], k)}
print(len(s))
PYEOF
}
keys() {  # <a> <regex>: "<deployment> <key>" pairs present
  "$PY" - "$TMP/$1.json" "$2" <<'PYEOF'
import sys, json, re
a = json.load(open(sys.argv[1]))["x"]
print("\n".join(sorted("%s %s" % (n, k) for n in a for k in a[n] if re.search(sys.argv[2], k))))
PYEOF
}

check() {  # $1 = case, $2 = got, $3 = want
  set -- "$1" "$(printf '%s' "$2" | tr -d '\r')" "$(printf '%s' "$3" | tr -d '\r')"
  if [ "$2" = "$3" ]; then echo "PASS $1"; else echo "FAIL $1:"; echo "  got:  $(echo "$2" | tr '\n' ';')"; echo "  want: $(echo "$3" | tr '\n' ';')"; FAIL=1; fi
}
must_render() {  # <name>...
  local n
  for n in "$@"; do
    [ "$(rc "$n")" = 0 ] || { echo "FAIL render $n:"; tail -3 "$TMP/$n.err"; echo "OVERALL FAIL"; exit 1; }
  done
}

write_values "$TMP/pA.yaml"  "$DA" "$DA" ""
write_values "$TMP/pB.yaml"  "$DB" "$DB" ""
write_values "$TMP/gB.yaml"  "$DB" "$DB" "demo/gateway"
write_values "$TMP/rB.yaml"  "$DB" "$DB" "demo/policy/realm-openddil.json"
write_values "$TMP/fA.yaml"  "$DA" ""
write_values "$TMP/fB.yaml"  "$DB" ""
write_values "$TMP/mB.yaml"  "$DB" "$DC"
write_values "$TMP/uX.yaml"  "" ""
write_values "$TMP/nB.yaml"  "$DB" "$DB" "" "contracts/proto"
write_values "$TMP/vB.yaml"  "$DB" "$DB" "demo/policy/users.yaml"
write_values "$TMP/dB.yaml"  "$DB" "$DB" "demo/policy/destinations.yaml"

render pA "$TMP/pA.yaml"; render pB "$TMP/pB.yaml"; render gB "$TMP/gB.yaml"; render rB "$TMP/rB.yaml"
render fA "$TMP/fA.yaml"; render fB "$TMP/fB.yaml"; render mB "$TMP/mB.yaml"
render uX "$TMP/uX.yaml" --set bundle.image.tag=x; render uY "$TMP/uX.yaml" --set bundle.image.tag=y
render nB "$TMP/nB.yaml"
render vB "$TMP/vB.yaml"; render dB "$TMP/dB.yaml"
must_render pA pB gB rB fA fB mB uX uY vB dB

# The render must carry what the cases are about.
want_deps="t-cm-intake t-egress-gate-c2 t-egress-intake t-keycloak t-pep t-tier-cm-intake-edge-01 t-tier-declaration-intake-edge-01 t-tier-keycloak-edge-01 t-tier-pep-edge-01 t-tier-pep-region-east t-tier-topaz-edge-01 t-tier-topaz-region-east t-topaz-hq"
got_deps="$("$PY" -c 'import json,sys;print(" ".join(sorted(json.load(open(sys.argv[1]))["x"])))' "$TMP/pA.json")"
for d in $want_deps; do case " $got_deps " in *" $d "*) ;; *) echo "NOTE: $d not among the extracted Deployments: $got_deps";; esac; done

# A
check "A digest change, same content: no checksum or realm version moves" "$(changed pA pB)" ""

# B
check "B demo/gateway changes: only the hub and tier PEPs checksum/policy move" "$(changed pB gB)" "t-pep checksum/policy
t-tier-pep-edge-01 checksum/policy
t-tier-pep-region-east checksum/policy"

# C
want_c="$(keys pB 'realm-version|REALM_VERSION')
t-keycloak checksum/policy
t-tier-keycloak-edge-01 checksum/policy"
check "C realm file changes: keycloak checksums, the realm-version annotation and the env move" "$(changed pB rB)" "$(printf '%s\n' "$want_c" | LC_ALL=C sort)"
check "C the realm version is one value on every object that carries it" "$(distinct rB 'realm-version|REALM_VERSION')" "1"
check "C the realm version differs from the unchanged-realm render" "$([ "$(keys pB 'realm-version|REALM_VERSION')" != "" ] && [ "$(distinct pB 'realm-version|REALM_VERSION')" = 1 ] && echo ok)" "ok"
check "C realm version carriers: annotation x2, tier import env, hub and tier PEP env" "$(keys pB 'realm-version|REALM_VERSION' | wc -l | tr -d ' ')" "5"

# D
check "D egress checksum/registries is the same at both digests (fallback mode)" "$(changed fA fB | grep -c 'egress.*checksum/registries')" "0"
check "D egress checksum/registries is the same at both digests (pinned mode)" "$(changed pA pB | grep -c 'egress.*checksum/registries')" "0"
check "D egress checksum/registries is rendered" "$(keys fA 'checksum/registries' | grep -c egress)" "2"

# E
want_e="$(keys fA 'checksum/(policy|bundle)'; keys fA 'realm-version|REALM_VERSION')"
check "E fallback: the bundle digest moves every bundle-path caller and the realm version" "$(changed fA fB)" "$(printf '%s\n' "$want_e" | LC_ALL=C sort)"
check "E digests for another bundle render exactly the no-contentDigests render" \
  "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["all"])' "$TMP/mB.json")" \
  "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["all"])' "$TMP/fB.json")"

# F
check "F unpinned: the realm version follows the tag" "$(changed uX uY | grep -c 'realm-version\|REALM_VERSION')" "$(keys uX 'realm-version|REALM_VERSION' | wc -l | tr -d ' ')"
check "F unpinned: the realm version is rendered" "$([ "$(keys uX 'realm-version|REALM_VERSION' | wc -l | tr -d ' ')" -gt 0 ] && echo ok)" "ok"

# H (topaz policy-loader reads, outside bundleInit)
check "H the default variant corpus (users.yaml) changes: only topaz-hq and tier topaz move" "$(changed pB vB)" "t-tier-topaz-edge-01 checksum/policy
t-tier-topaz-region-east checksum/policy
t-topaz-hq checksum/policy"
check "H destinations.yaml changes: only topaz-hq and tier topaz move" "$(changed pB dB)" "$(changed pB vB)"

# G
if [ "$(rc nB)" = 0 ]; then
  echo "FAIL G: a pinned render with a missing digest succeeded"; FAIL=1
elif grep -q 'contracts/proto' "$TMP/nB.err"; then
  echo "PASS G missing digest: the render fails and names contracts/proto"
else
  echo "FAIL G: the render failed for another reason:"; tail -3 "$TMP/nB.err"; FAIL=1
fi

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
