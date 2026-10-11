#!/usr/bin/env bash
# ===========================================================================
# test_external_clients_render.sh -- offline render proof for
# releasability.keycloak.externalClients (confidential OIDC clients for
# external relying parties).
#
# Cases:
#   A. one entry   -> realm fragment, substitution line + guard, and the
#                     prepare-realm env are all rendered for index 0.
#   B. empty list  -> no external-client placeholder anywhere in the render.
#   C. checksum    -> keycloak checksum/policy changes with a redirect URI.
#   D. refusals    -> wildcard, http://, missing secret ref, duplicate
#                     clientId, collision with the PEP client all fail.
#   E. guard       -> the rendered case block refuses a secret with a
#                     character outside [A-Za-z0-9._~-] and passes a hex one.
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

BASE=(--set releasability.enabled=true --set releasability.oidc.enabled=true --set releasability.keycloak.enabled=true)
ENTRY=(--set 'releasability.keycloak.externalClients[0].clientId=partner-broker'
       --set 'releasability.keycloak.externalClients[0].existingSecret.name=ext-sec'
       --set 'releasability.keycloak.externalClients[0].existingSecret.key=client-secret')
URI_A='https://idp.example.org/realms/partner/broker/openddil/endpoint'
URI_B='https://idp.example.org/realms/other/broker/openddil/endpoint'

render() {  # $1 = out file, rest = extra --set flags
  local out="$1"; shift
  helm template t "$CHART" "${BASE[@]}" "$@" > "$out" 2> "$out.err"
}

# pick <file> <what>: print one extracted fact from a render.
pick() {
  "$PY" - "$1" "$2" <<'EOF'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1], encoding="utf-8")) if d]
what = sys.argv[2]
for d in docs:
    n = d["metadata"]["name"]
    if what in ("tier-clients.json", "substitutions.sh") and d["kind"] == "ConfigMap" and what in (d.get("data") or {}):
        print(d["data"][what]); sys.exit(0)
    if d["kind"] == "Deployment" and n.endswith("-keycloak"):
        pod = d["spec"]["template"]
        if what == "checksum":
            print(pod["metadata"]["annotations"]["checksum/policy"]); sys.exit(0)
        if what == "env":
            for ic in pod["spec"]["initContainers"]:
                if ic["name"] == "prepare-realm":
                    for e in ic.get("env", []):
                        if e["name"] == "OPENDDIL_EXT_CLIENT_SECRET_0":
                            r = e["valueFrom"]["secretKeyRef"]
                            print("%s/%s" % (r["name"], r["key"])); sys.exit(0)
            print("<absent>"); sys.exit(0)
print("<none>")
EOF
}

ok() {  # $1 = case, $2 = condition result (0 = pass), $3 = detail
  if [ "$2" = 0 ]; then echo "PASS $1"; else echo "FAIL $1: $3"; FAIL=1; fi
}

# ---- A -------------------------------------------------------------------
render "$TMP/a.yaml" "${ENTRY[@]}" --set "releasability.keycloak.externalClients[0].redirectUris[0]=$URI_A" \
  || { echo "render A failed:"; cat "$TMP/a.yaml.err"; exit 1; }
pick "$TMP/a.yaml" tier-clients.json > "$TMP/a.clients"
pick "$TMP/a.yaml" substitutions.sh  > "$TMP/a.subst"
miss=""
grep -q '"clientId": "partner-broker"' "$TMP/a.clients"          || miss="$miss clientId"
grep -q '"publicClient": false' "$TMP/a.clients"                 || miss="$miss publicClient"
grep -qF "\"$URI_A\"" "$TMP/a.clients"                           || miss="$miss uri"
grep -q '__EXT_CLIENT_SECRET_0__' "$TMP/a.clients"               || miss="$miss placeholder"
grep -qF 's|__EXT_CLIENT_SECRET_0__|${OPENDDIL_EXT_CLIENT_SECRET_0}|g' "$TMP/a.subst" || miss="$miss sed"
grep -qF 'case "${OPENDDIL_EXT_CLIENT_SECRET_0}" in' "$TMP/a.subst" || miss="$miss guard"
[ "$(pick "$TMP/a.yaml" env)" = "ext-sec/client-secret" ]        || miss="$miss env"
ok "A one entry" "$([ -z "$miss" ] && echo 0 || echo 1)" "missing:$miss"

# ---- B -------------------------------------------------------------------
render "$TMP/b.yaml" || { echo "render B failed:"; cat "$TMP/b.yaml.err"; exit 1; }
n="$(grep -c '__EXT_CLIENT_SECRET_\|OPENDDIL_EXT_CLIENT_SECRET' "$TMP/b.yaml")"
ok "B empty list" "$([ "$n" = 0 ] && echo 0 || echo 1)" "$n matches"

# ---- C -------------------------------------------------------------------
render "$TMP/c.yaml" "${ENTRY[@]}" --set "releasability.keycloak.externalClients[0].redirectUris[0]=$URI_B" \
  || { echo "render C failed:"; cat "$TMP/c.yaml.err"; exit 1; }
ca="$(pick "$TMP/a.yaml" checksum)"; cc="$(pick "$TMP/c.yaml" checksum)"
ok "C checksum" "$([ -n "$ca" ] && [ "$ca" != "<none>" ] && [ "$ca" != "$cc" ] && echo 0 || echo 1)" "a=$ca c=$cc"

# ---- D -------------------------------------------------------------------
refuse() {  # $1 = case, $2 = expected message fragment, rest = --set flags
  local name="$1" want="$2"; shift 2
  if render "$TMP/d.yaml" "$@"; then echo "FAIL $name: render succeeded"; FAIL=1; return; fi
  if grep -qF -- "$want" "$TMP/d.yaml.err"; then echo "PASS $name"; else echo "FAIL $name: message lacks '$want'"; FAIL=1; fi
}
U0="releasability.keycloak.externalClients[0].redirectUris[0]"
refuse "D wildcard"   "must not contain a wildcard" "${ENTRY[@]}" --set "$U0=https://idp.example.org/*"
refuse "D http"       "must start with https://"    "${ENTRY[@]}" --set "$U0=http://idp.example.org/x"
refuse "D no secret"  "existingSecret.name and existingSecret.key are required" \
  --set 'releasability.keycloak.externalClients[0].clientId=partner-broker' --set "$U0=$URI_A"
refuse "D duplicate"  "duplicate clientId" "${ENTRY[@]}" --set "$U0=$URI_A" \
  --set 'releasability.keycloak.externalClients[1].clientId=partner-broker' \
  --set 'releasability.keycloak.externalClients[1].existingSecret.name=s2' \
  --set 'releasability.keycloak.externalClients[1].existingSecret.key=k' \
  --set "releasability.keycloak.externalClients[1].redirectUris[0]=$URI_B"
refuse "D collision"  "collides with an existing realm client" \
  --set 'releasability.keycloak.externalClients[0].clientId=openddil-pep' \
  --set 'releasability.keycloak.externalClients[0].existingSecret.name=ext-sec' \
  --set 'releasability.keycloak.externalClients[0].existingSecret.key=client-secret' --set "$U0=$URI_A"

# ---- E -------------------------------------------------------------------
# The whole script is bound to absolute image paths, so run only its rendered
# case block (the guard); the sed line is covered by case A.
awk '/case "\$\{OPENDDIL_EXT_CLIENT_SECRET_0\}" in/{p=1} p{print} /^ *esac/{if(p)exit}' "$TMP/a.subst" > "$TMP/guard.sh"
if [ ! -s "$TMP/guard.sh" ]; then
  echo "FAIL E guard: block not found in rendered substitutions.sh"; FAIL=1
else
  out="$(OPENDDIL_EXT_CLIENT_SECRET_0='ab|cd' sh "$TMP/guard.sh" 2>&1)"; rc=$?
  ok "E bad secret refused" "$([ "$rc" = 1 ] && echo "$out" | grep -q 'FATAL: externalClients\[0\]' && echo 0 || echo 1)" "rc=$rc"
  out="$(OPENDDIL_EXT_CLIENT_SECRET_0='' sh "$TMP/guard.sh" 2>&1)"; rc=$?
  ok "E empty secret refused" "$([ "$rc" = 1 ] && echo 0 || echo 1)" "rc=$rc"
  good="$(printf 'ab%.0s' $(seq 1 32))"
  out="$(OPENDDIL_EXT_CLIENT_SECRET_0="$good" sh "$TMP/guard.sh" 2>&1)"; rc=$?
  ok "E 64-hex secret passes" "$([ "$rc" = 0 ] && [ -z "$out" ] && echo 0 || echo 1)" "rc=$rc"
fi

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
