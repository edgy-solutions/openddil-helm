#!/usr/bin/env bash
# ===========================================================================
# test_bundle_loader_pinning.sh -- offline render proof that a Deployment's or
# StatefulSet's bundle-loader init container names the OLDEST earlier bundle
# digest from which the files it copies are unchanged (bundle.contentDigest
# History), that Jobs always use the current bundle, and that a bundle bump
# therefore leaves an unchanged workload's pod template byte-identical.
#
# Render: one region and one edge (tier node, own publicOrigin, identity
# replica), releasability + keycloak + oidc enabled, as in
# test_bundle_content_checksums.sh.
#
# helm's stdout goes straight through a Python filter that drops every
# `kind: Secret` document and keeps only the loader image, the srcs the loader
# copies, a sha256 of the pod template and the checksum annotations per
# (kind, name). Nothing unfiltered is written to disk; the pod-template
# comparison of case H happens in one Python process, in memory.
#
# Cases:
#   A. no history: every loader (Deployments, StatefulSets, Jobs) is at the
#      current bundle.
#   B. history [A], every src digest equal: Deployment and StatefulSet loaders
#      at A, Job loaders at B, checksum annotations equal case A's.
#   C. history [A], demo/gateway differs: readers of it at B, the rest at A.
#   D. history [C, A], C differs from A in one src: its readers at A, the rest
#      at C (a contiguous run only).
#   E. fallback (contentDigests for another bundle) with a history: all at B.
#   F. a malformed, duplicate or current-equal history digest fails the render
#      naming the entry index.
#   G. a history entry missing one src: its readers are not pinned past it.
#   H. the point of the change: current A, no history, against current B,
#      history [A], same content: no Deployment or StatefulSet pod template
#      differs.
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

# Every src any bundle-loader copies: a src missing from the digests never pins.
SRCS="contracts/proto demo/cm-intake.yaml demo/declaration-intake.yaml demo/policy/.manifest demo/policy/releasability.rego demo/gateway contracts/ontology demo/ontology contracts/baselines demo/policy/realm-openddil.json demo/policy/users.yaml demo/policy/destinations.yaml agents/hub/restate_hub.py contracts/bootstrap contracts/gen/python contracts/gen/python/openddil demo/dynamic-mappings demo/exercise demo/openddil-base-connect.yaml stack/electric stack/schema"

# paths_block <indent> <change-src> <omit-src> <fill-char>: the `<src>: <hex>`
# lines. A src's digest is its list index in hex; the changed one is 64 x
# <fill-char>.
paths_block() {
  local ind="$1" change="$2" omit="$3" fill="$4" i=0 src h
  for src in $SRCS; do
    i=$((i+1))
    [ "$src" = "$omit" ] && continue
    h="$(printf '%064x' "$i")"
    [ "$src" = "$change" ] && h="$(printf "$fill%.0s" $(seq 64))"
    echo "${ind}\"$src\": $h"
  done
}

# write_values <out> <bundle digest> <contentDigests.bundleDigest> <change-src>
#   [history entries...], each "<digest>|<change-src>|<omit-src>" (the
#   history digests are written as given, so a bad one can be passed).
write_values() {
  local out="$1" bd="$2" cdb="$3" change="$4" e dg ch om
  shift 4
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
    echo "  contentDigests:"; echo "    bundleDigest: \"$cdb\""; echo "    paths:"
    paths_block "      " "$change" "" "f"
    if [ "$#" -gt 0 ]; then
      echo "  contentDigestHistory:"
      for e in "$@"; do
        IFS='|' read -r dg ch om <<< "$e"
        echo "    - bundleDigest: \"$dg\""; echo "      paths:"
        paths_block "        " "$ch" "$om" "e"
      done
    fi
  } > "$out"
}

# helm stdout -> filter. Prints JSON {"ld": {"<Kind>/<name>": {"img": the
# bundle-loader image, "srcs": [srcs it copies]}}, "tpl": {"<Kind>/<name>":
# sha256 of the pod template}, "ann": {"<Kind>/<name>": {checksum/*}}}. Secrets
# are dropped in the pipe.
FILTER="$TMP/filter.py"
cat > "$FILTER" <<'PYEOF'
import sys, json, hashlib, re, yaml
ld, tpl, ann = {}, {}, {}
for d in yaml.safe_load_all(sys.stdin):
    if not d or d.get("kind") not in ("Deployment", "StatefulSet", "Job"):
        continue
    k = "%s/%s" % (d["kind"], d["metadata"]["name"])
    t = d["spec"]["template"]
    tpl[k] = hashlib.sha256(yaml.safe_dump(t, sort_keys=True).encode()).hexdigest()
    ann[k] = {a: v for a, v in ((t.get("metadata") or {}).get("annotations") or {}).items() if a.startswith("checksum/")}
    for c in t["spec"].get("initContainers") or []:
        if c["name"] == "bundle-loader":
            srcs = re.findall(r"^\s*# (\S+) -> /shared/", "\n".join(c["command"]), re.M)
            ld[k] = {"img": c["image"], "srcs": srcs}
print(json.dumps({"ld": ld, "tpl": tpl, "ann": ann}))
PYEOF

render() {  # <name> <values-file>: $TMP/<name>.json, .rc, .err
  local name="$1" vf="$2"; shift 2
  helm template t "$CHART" -f "$vf" "$@" 2> "$TMP/$name.err" | "$PY" "$FILTER" > "$TMP/$name.json" 2>> "$TMP/$name.err"
  echo "${PIPESTATUS[0]}" > "$TMP/$name.rc"
}
rc() { cat "$TMP/$1.rc"; }
must_render() {
  local n
  for n in "$@"; do
    [ "$(rc "$n")" = 0 ] || { echo "FAIL render $n:"; tail -3 "$TMP/$n.err"; echo "OVERALL FAIL"; exit 1; }
  done
}

# loaders <case> <json> <ds-digest> <job-digest> [<read-src> <reader-digest>]
# Every Deployment/StatefulSet loader must name <ds-digest>, every Job loader
# <job-digest>; with a read-src, the Deployments and StatefulSets whose loader
# copies it must name <reader-digest> instead, and both sets must be non-empty.
LCHECK="$TMP/lcheck.py"
cat > "$LCHECK" <<'PYEOF'
import sys, json
case, path, dsd, jobd = sys.argv[1:5]
rsrc, rd = (sys.argv[5], sys.argv[6]) if len(sys.argv) > 6 else (None, None)
ld = json.load(open(path))["ld"]
bad, readers, others, jobs = [], [], [], 0
for k in sorted(ld):
    img = ld[k]["img"]
    if k.startswith("Job/"):
        jobs += 1
        want = jobd
    elif rsrc and rsrc in ld[k]["srcs"]:
        readers.append(k); want = rd
    else:
        others.append(k); want = dsd
    if not img.endswith("@" + want) or "@" not in img:
        bad.append("%s is %s, want @%s" % (k, img.rsplit("/", 1)[-1][:40], want[:14]))
if rsrc and not (readers and others):
    bad.append("need both readers and others of %s: %d / %d" % (rsrc, len(readers), len(others)))
if not ld:
    bad.append("no bundle-loader found")
if bad:
    print("FAIL " + case); [print("  " + b) for b in bad]; sys.exit(1)
extra = ""
if rsrc:
    extra = "\n  at %s (read %s): %s\n  at %s: %s" % (rd[:14], rsrc, " ".join(readers), dsd[:14], " ".join(others))
else:
    extra = " (%d Deployment/StatefulSet loaders, %d Job loaders)" % (len(ld) - jobs, jobs)
print("PASS " + case + extra)
PYEOF
loaders() {
  local out; out="$("$PY" "$LCHECK" "$@" | tr -d '\r')"; echo "$out"
  case "$out" in FAIL*) FAIL=1;; esac
}

failed() {  # <case> <name> <needle>: the render must fail and name <needle>
  if [ "$(rc "$2")" = 0 ]; then echo "FAIL $1: the render succeeded"; FAIL=1
  elif grep -qF -- "$3" "$TMP/$2.err"; then echo "PASS $1 (names $3)"
  else echo "FAIL $1: failed without naming $3:"; tail -3 "$TMP/$2.err"; FAIL=1; fi
}

# --- values and renders ---------------------------------------------------
write_values "$TMP/a.yaml"  "$DB" "$DB" ""
write_values "$TMP/b.yaml"  "$DB" "$DB" "" "$DA||"
write_values "$TMP/c.yaml"  "$DB" "$DB" "demo/gateway" "$DA||"
write_values "$TMP/d.yaml"  "$DB" "$DB" "" "$DC|demo/cm-intake.yaml|" "$DA||"
write_values "$TMP/e.yaml"  "$DB" "$DC" "" "$DA||"
write_values "$TMP/g.yaml"  "$DB" "$DB" "" "$DA||demo/gateway"
write_values "$TMP/f1.yaml" "$DB" "$DB" "" "$DA||" "sha256:zz||"
write_values "$TMP/f2.yaml" "$DB" "$DB" "" "$DA||" "$DA||"
write_values "$TMP/f3.yaml" "$DB" "$DB" "" "$DB||"
write_values "$TMP/h1.yaml" "$DA" "$DA" ""
write_values "$TMP/h2.yaml" "$DB" "$DB" "" "$DA||"

for n in a b c d e g f1 f2 f3 h1; do render "$n" "$TMP/$n.yaml"; done
must_render a b c d e g h1

# --- A ----------------------------------------------------------------------
loaders "A no history: every loader is at the current bundle" "$TMP/a.json" "$DB" "$DB"
# --- B ----------------------------------------------------------------------
loaders "B history [A], same content: Deployment/StatefulSet loaders at A, Jobs at B" "$TMP/b.json" "$DA" "$DB"
if [ "$("$PY" -c 'import json,sys;print(json.load(open(sys.argv[1]))["ann"]==json.load(open(sys.argv[2]))["ann"])' "$TMP/a.json" "$TMP/b.json" | tr -d '\r')" = True ]; then
  echo "PASS B the checksum annotations equal case A's"
else echo "FAIL B the checksum annotations differ from case A's"; FAIL=1; fi
# --- C ----------------------------------------------------------------------
loaders "C history [A], demo/gateway differs: readers of it at B, the rest at A" "$TMP/c.json" "$DA" "$DB" demo/gateway "$DB"
# --- D ----------------------------------------------------------------------
loaders "D history [C, A], C differs in demo/cm-intake.yaml: its readers at A, the rest at C" "$TMP/d.json" "$DC" "$DB" demo/cm-intake.yaml "$DA"
# --- E ----------------------------------------------------------------------
loaders "E fallback (digests for another bundle) with a history: every loader at the current bundle" "$TMP/e.json" "$DB" "$DB"
# --- F ----------------------------------------------------------------------
failed "F a malformed history digest fails the render" f1 "contentDigestHistory[1]"
failed "F a duplicate history digest fails the render" f2 "contentDigestHistory[1]"
failed "F a history entry equal to the current digest fails the render" f3 "contentDigestHistory[0]"
# --- G ----------------------------------------------------------------------
loaders "G history [A] lacking demo/gateway: its readers at B, the rest at A" "$TMP/g.json" "$DA" "$DB" demo/gateway "$DB"

# --- H: the point of the change ---------------------------------------------
HCMP="$TMP/hcmp.py"
cat > "$HCMP" <<'PYEOF'
import sys, subprocess, hashlib, json, yaml
chart, v1, v2 = sys.argv[1:4]
def render(vf):
    p = subprocess.run(["helm", "template", "t", chart, "-f", vf], capture_output=True, text=True)
    if p.returncode:
        print("FAIL H render: " + p.stderr.strip()[-200:]); sys.exit(1)
    out = {}
    for d in yaml.safe_load_all(p.stdout):
        if d and d.get("kind") in ("Deployment", "StatefulSet"):
            out["%s/%s" % (d["kind"], d["metadata"]["name"])] = d["spec"]["template"]
    return out
def diff(a, b, path=""):
    if isinstance(a, dict) and isinstance(b, dict):
        for k in sorted(set(a) | set(b)):
            yield from diff(a.get(k), b.get(k), "%s.%s" % (path, k))
    elif isinstance(a, list) and isinstance(b, list) and len(a) == len(b):
        for i, (x, y) in enumerate(zip(a, b)):
            yield from diff(x, y, "%s[%d]" % (path, i))
    elif a != b:
        yield path
r1, r2 = render(v1), render(v2)
bad = []
for k in sorted(set(r1) | set(r2)):
    if k not in r1 or k not in r2:
        bad.append("%s exists in only one render" % k); continue
    if hashlib.sha256(yaml.safe_dump(r1[k], sort_keys=True).encode()).digest() != hashlib.sha256(yaml.safe_dump(r2[k], sort_keys=True).encode()).digest():
        bad.append("%s differs at %s" % (k, ", ".join(diff(r1[k], r2[k]))))
if not r1:
    bad.append("no Deployment or StatefulSet rendered")
if bad:
    print("FAIL H a bundle bump with the same content changes %d pod template(s):" % len(bad)); [print("  " + b) for b in bad]; sys.exit(1)
print("PASS H bundle A -> B, same content, history [A]: all %d Deployment/StatefulSet pod templates are identical" % len(r1))
PYEOF
out="$("$PY" "$HCMP" "$CHART" "$TMP/h1.yaml" "$TMP/h2.yaml")"; hrc=$?
printf '%s\n' "$out" | tr -d '\r'
[ "$hrc" = 0 ] || FAIL=1

[ "$FAIL" = 0 ] && echo "OVERALL PASS" || echo "OVERALL FAIL"
exit "$FAIL"
