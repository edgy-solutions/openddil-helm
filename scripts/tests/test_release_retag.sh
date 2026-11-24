#!/usr/bin/env bash
# ===========================================================================
# test_release_retag.sh -- offline tests for the retag release tooling:
#   scripts/release/find_build.py, check_suite_manifest.py,
#   check_suite_published.py, the release workflow's static properties, and
#   the build workflows no longer rebuilding on version tags.
# No network: crane and gh answers come from fixture files.
# ===========================================================================
set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
REL="$ROOT/scripts/release"
MANIFEST="$ROOT/release/suite-v2.0.0-rc1.yaml"
WF="$ROOT/.github/workflows/release-retag.yml"

PY=""
for c in python3 python "py -3"; do
  if $c -c 'import yaml' >/dev/null 2>&1; then PY="$c"; break; fi
done
if [ -z "$PY" ]; then
  for c in python3 python "py -3"; do
    if $c -c 'pass' >/dev/null 2>&1; then PY="$c"; break; fi
  done
fi
[ -n "$PY" ] || { echo "FAIL: no python"; exit 1; }
HAVE_YAML=0
$PY -c 'import yaml' >/dev/null 2>&1 && HAVE_YAML=1

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FAIL=0
pass() { echo "PASS: $1"; }
fail() { echo "FAIL: $1"; FAIL=1; }

C="$(printf 'a%.0s' $(seq 1 39))1"
D1="sha256:$(printf '1%.0s' $(seq 1 64))"
D2="sha256:$(printf '2%.0s' $(seq 1 64))"

# ---- find_build.py ---------------------------------------------------------
find_case() { # case [extra args] -> sets OUT, ERR, RC
  local case="$1"; shift
  local d="$TMP/fx-$case"
  rm -rf "$d"; mkdir -p "$d"
  $PY "$HERE/release_retag_fixtures.py" "$d" "$case" || { fail "fixture $case"; return 1; }
  OUT="$($PY "$REL/find_build.py" --image projector --repo edgy-solutions/openddil-projector \
        --commit "$C" --fixtures "$d" "$@" 2>"$TMP/err")"
  RC=$?
  ERR="$(cat "$TMP/err")"
}

find_case sha_tag
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "\"digest\": \"$D1\"" && echo "$OUT" | grep -q '"run_id": "111"'; then
  pass "find_build: sha tag plus provenance gives that digest"
else fail "find_build: sha tag case (rc=$RC out=$OUT)"; fi

find_case one_of_three
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "\"digest\": \"$D1\""; then
  pass "find_build: no sha tag, one of three versions matches"
else fail "find_build: one of three (rc=$RC err=$ERR)"; fi

find_case two_match
if [ $RC -ne 0 ] && echo "$ERR" | grep -q "$D1" && echo "$ERR" | grep -q "$D2" && echo "$ERR" | grep -q 'expected'; then
  pass "find_build: two matches without expected fails, naming both"
else fail "find_build: two matches (rc=$RC err=$ERR)"; fi

find_case two_match --expected "$D2"
if [ $RC -eq 0 ] && echo "$OUT" | grep -q "\"digest\": \"$D2\""; then
  pass "find_build: two matches with expected picks one"
else fail "find_build: two matches with expected (rc=$RC err=$ERR)"; fi

find_case two_match --expected "sha256:$(printf '9%.0s' $(seq 1 64))"
if [ $RC -ne 0 ]; then pass "find_build: expected not among the builds fails"
else fail "find_build: a wrong expected digest passed"; fi

find_case pull_request
if [ $RC -ne 0 ] && echo "$ERR" | grep -q 'retags, it does not build' && echo "$ERR" | grep -q 'pull_request'; then
  pass "find_build: a pull_request build is dropped, 0 found fails"
else fail "find_build: pull_request (rc=$RC err=$ERR)"; fi

find_case repo_mismatch
if [ $RC -ne 0 ] && echo "$ERR" | grep -q 'github_repository' && echo "$ERR" | grep -q 'retags, it does not build'; then
  pass "find_build: a repo mismatch is dropped"
else fail "find_build: repo mismatch (rc=$RC err=$ERR)"; fi

find_case no_attestation
if [ $RC -ne 0 ] && echo "$ERR" | grep -q 'no attestation' && echo "$ERR" | grep -q 'retags, it does not build'; then
  pass "find_build: an index without an attestation is dropped"
else fail "find_build: no attestation (rc=$RC err=$ERR)"; fi

# ---- check_suite_manifest.py ----------------------------------------------
if [ "$HAVE_YAML" -eq 0 ]; then
  echo "SKIP: PyYAML not installed; manifest, published and workflow YAML checks not run"
else
  CHK="$REL/check_suite_manifest.py"
  if $PY "$CHK" "$MANIFEST"; then pass "manifest: release/suite-v2.0.0-rc1.yaml passes"
  else fail "manifest: the real manifest fails"; fi

  sed '0,/tag: v2.0.0-rc1}/s//tag: latest}/' "$MANIFEST" > "$TMP/m-latest.yaml"
  grep -q 'tag: latest' "$TMP/m-latest.yaml" || fail "manifest: latest fixture not built"
  if ! $PY "$CHK" "$TMP/m-latest.yaml" > "$TMP/o"; then
    grep -q 'latest' "$TMP/o" && pass "manifest: latest in a tag fails" || fail "manifest: failed, but not for latest"
  else fail "manifest: latest in a tag passed"; fi

  sed '0,/digest: "sha256:330d0efb/s//digest: "sha256:33/' "$MANIFEST" > "$TMP/m-bad.yaml"
  if ! $PY "$CHK" "$TMP/m-bad.yaml" > "$TMP/o"; then
    grep -q 'projector digest malformed' "$TMP/o" && pass "manifest: a malformed digest fails" || fail "manifest: failed, but not for the digest"
  else fail "manifest: a malformed digest passed"; fi

  sed 's/^status: proposed/status: tagged/' "$MANIFEST" > "$TMP/m-tagged.yaml"
  if ! $PY "$CHK" "$TMP/m-tagged.yaml" > "$TMP/o"; then
    grep -q 'requires empty blockers' "$TMP/o" && pass "manifest: status tagged with blockers fails" || fail "manifest: failed, but not for blockers"
  else fail "manifest: tagged with blockers passed"; fi

  # A promoted final beside its rc. Control first: identical digests pass.
  P="$TMP/promo"; mkdir -p "$P"
  cp "$MANIFEST" "$P/suite-v2.0.0-rc1.yaml"
  sed 's/v2\.0\.0-rc1/v2.0.0/g; s/^promotedFrom: ""/promotedFrom: v2.0.0-rc1/' "$MANIFEST" > "$P/suite-v2.0.0.yaml"
  # the sed above also rewrote the bundle and image digests? no: digests hold no version text
  if $PY "$CHK" "$P/suite-v2.0.0.yaml"; then pass "manifest: a promoted final with identical digests passes"
  else fail "manifest: the promoted control fails"; fi
  sed -i '0,/digest: "sha256:330d0efb/s//digest: "sha256:440d0efb/' "$P/suite-v2.0.0.yaml"
  if ! $PY "$CHK" "$P/suite-v2.0.0.yaml" > "$TMP/o"; then
    grep -q 'differ' "$TMP/o" && pass "manifest: a promoted final with a different digest fails" || fail "manifest: failed, but not for the digest difference"
  else fail "manifest: a promoted final with a different digest passed"; fi

  # ---- thirdParty ----
  V2="$ROOT/release/suite-v2.0.0.yaml"
  if $PY "$CHK" "$V2"; then pass "manifest: release/suite-v2.0.0.yaml passes"
  else fail "manifest: suite-v2.0.0.yaml fails"; fi
  tp_case() { # label, python statement mutating m, grep pattern
    $PY - "$V2" "$TMP/m-tp.yaml" "$2" <<'PY'
import sys, yaml
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
exec(sys.argv[3])
open(sys.argv[2], "wb").write(yaml.safe_dump(m, sort_keys=False).encode())
PY
    if ! $PY "$CHK" "$TMP/m-tp.yaml" > "$TMP/o"; then
      grep -q "$3" "$TMP/o" && pass "manifest: $1 fails" || fail "manifest: $1 failed, but not as named: $(cat "$TMP/o")"
    else fail "manifest: $1 passed"; fi
  }
  tp_case "thirdParty entry missing pinned" 'del m["thirdParty"][0]["pinned"]' 'thirdParty\[redpanda\] missing pinned'
  tp_case "thirdParty pinned as a string" 'm["thirdParty"][0]["pinned"] = "yes"' 'redpanda pinned is not a bool'
  tp_case "thirdParty openddil-owned image" 'm["thirdParty"][0]["image"] = "ghcr.io/edgy-solutions/openddil/x"' 'openddil-owned'
  tp_case "thirdParty name equal to an images name" 'm["thirdParty"][0]["name"] = "projector"' 'also an images name'
  tp_case "an extra unknown top-level key" 'm["extra"] = 1' 'unknown top-level key extra'
  $PY "$REL/make_notes.py" suite --repo r --tag v2.0.0 --manifest "$V2" > "$TMP/n2"
  n="$(grep -c '^- .*@ `sha256' "$TMP/n2")"
  if grep -q 'Third-party images' "$TMP/n2" && [ "$n" = 14 ]; then pass "notes: suite v2.0.0 lists 14 third-party images"
  else fail "notes: suite v2.0.0 third-party section wrong ($n lines)"; fi
  $PY "$REL/make_notes.py" suite --repo r --tag v2.0.0-rc1 --manifest "$MANIFEST" > "$TMP/n1"
  if grep -q 'Third-party' "$TMP/n1"; then fail "notes: rc1 prints a third-party heading"
  else pass "notes: rc1 prints no third-party heading"; fi

  # ---- check_suite_published.py ------------------------------------------
  PUB="$ROOT/scripts/release/check_suite_published.py"
  $PY - "$MANIFEST" "$TMP/pub-ok" "$TMP/pub-bad" <<'PY'
import json, os, shutil, sys
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(sys.argv[1])), "..", "scripts", "release"))
import yaml
from release_common import fixture_name
m = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
items = [(i["image"], i["tag"].split("/")[-1], i["digest"]) for i in m["images"]]
items.append((m["bundle"]["image"], m["suite"], m["bundle"]["digest"]))
for out in sys.argv[2:]:
    os.makedirs(out, exist_ok=True)
    for image, tag, dig in items:
        if out.endswith("pub-bad") and image.endswith("/cm-service"):
            dig = "sha256:" + "0" * 64
        with open(os.path.join(out, fixture_name("digest", image + ":" + tag)), "w", encoding="utf-8", newline="\n") as f:
            json.dump({"digest": dig}, f)
PY
  if $PY "$PUB" "$MANIFEST" --fixtures "$TMP/pub-ok" > "$TMP/o"; then pass "published: all digests match"
  else fail "published: all-match case failed: $(cat "$TMP/o")"; fi
  if ! $PY "$PUB" "$MANIFEST" --fixtures "$TMP/pub-bad" > "$TMP/o"; then
    grep -q 'cm-service' "$TMP/o" && pass "published: one differing digest fails, naming the image" || fail "published: failed without naming the image"
  else fail "published: a differing digest passed"; fi
fi

# ---- the workflows, static -------------------------------------------------
if [ "$HAVE_YAML" -eq 1 ]; then
  if $PY -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$WF" \
     && $PY -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$ROOT/.github/workflows/release.yml" \
     && $PY -c 'import sys,yaml; yaml.safe_load(open(sys.argv[1], encoding="utf-8"))' "$ROOT/release/caller-template.yml"; then
    pass "workflow: the release workflows parse"
  else fail "workflow: a release workflow does not parse"; fi
  # Why: a version tag must retag, never rebuild a new digest under the version.
  if $PY - "$ROOT/.github/workflows/build-reset-runner.yml" "$ROOT/.github/workflows/build-bundle.yml" <<'PY'
import sys, yaml
bad = 0
for p in sys.argv[1:]:
    w = yaml.safe_load(open(p, encoding="utf-8"))
    on = w.get(True, w.get("on"))
    if "tags" in (on.get("push") or {}):
        print("%s: push still has tags" % p)
        bad = 1
sys.exit(bad)
PY
  then pass "workflow: neither build workflow triggers on version tags"
  else fail "workflow: a build workflow still has push tags"; fi
else
  echo "SKIP: PyYAML not installed; workflow parse and push-tags checks not run"
fi

n="$(grep -n 'crane ' "$WF" | grep -c latest)"
if [ "$n" = "0" ]; then pass "workflow: no crane command line names latest"
else fail "workflow: $n crane lines name latest"; fi

# ---- Parse step, behavioural ------------------------------------------------
if [ "$HAVE_YAML" -eq 0 ]; then
  echo "SKIP: PyYAML not installed; Parse step behavioural cases not run"
else
  PARSE="$TMP/parse.sh"
  $PY - "$WF" "$PARSE" <<'PY'
import sys, yaml
w = yaml.safe_load(open(sys.argv[1], encoding="utf-8"))
st = w["jobs"]["release"]["steps"][0]
assert st.get("id") == "tag", st
open(sys.argv[2], "w", encoding="utf-8", newline="\n").write(st["run"])
PY
  [ -s "$PARSE" ] || fail "parse: could not extract the Parse step"
  C40="$(printf 'c%.0s' $(seq 1 40))"
  S1="$(printf 'd%.0s' $(seq 1 40))"
  HEX64="$(printf 'e%.0s' $(seq 1 64))"
  mkdir -p "$TMP/bin"
  cat > "$TMP/bin/gh" <<'GH'
#!/usr/bin/env bash
# stub: ignores --jq, prints a fixed answer per path
p="$2"
R="$GITHUB_REPOSITORY"
case "$p" in
  "repos/$R") echo master ;;
  "repos/$R/git/ref/tags/projector/v2.0.0") echo "tag $STUB_S1" ;;
  "repos/$R/git/ref/tags/projector/v3.0.0") echo "commit $STUB_C40" ;;
  "repos/$R/git/ref/tags/projector/v4.0.0") echo "tag $STUB_S1" ;;
  "repos/$R/git/tags/$STUB_S1") echo "${STUB_PEEL:-commit} $STUB_C40" ;;
  "repos/$R/commits/"*) echo "$STUB_C40" ;;
  *) exit 1 ;;
esac
GH
  chmod +x "$TMP/bin/gh"
  PN=0
  # parse_case ENV... -> sets RC, POUT (output file), PLOG
  parse_case() {
    PN=$((PN + 1))
    POUT="$TMP/out.$PN"; : > "$POUT"
    PLOG="$(env -i PATH="$TMP/bin:$PATH" HOME="$TMP" \
      STUB_S1="$S1" STUB_C40="$C40" \
      GITHUB_OUTPUT="$POUT" GITHUB_REPOSITORY=o/r GITHUB_SHA="$C" \
      GITHUB_REF=refs/heads/master GITHUB_REF_NAME=master GITHUB_EVENT_NAME=workflow_dispatch \
      IMAGES="projector cm-service" EXPECTED="" DRY_RUN=false SUITE_MANIFEST="" COMMIT_IN="" \
      "$@" bash "$PARSE" 2>&1)"
    RC=$?
  }
  has() { grep -qx "$1" "$POUT"; }
  EXP="projector=sha256:$HEX64"

  parse_case GITHUB_REF=refs/tags/projector/v2.0.0 GITHUB_REF_NAME=projector/v2.0.0 GITHUB_EVENT_NAME=push
  if [ $RC -eq 0 ] && has mode=retag && has scope=projector && has version=v2.0.0 \
     && has reltag=projector/v2.0.0 && has "srcref=$C"; then
    pass "parse a: tag push projector/v2.0.0"
  else fail "parse a: tag push (rc=$RC log=$PLOG)"; fi

  parse_case DRY_RUN=true GITHUB_REF=refs/heads/feature GITHUB_REF_NAME=feature
  if [ $RC -eq 0 ] && has version=v0.0.0-dryrun && has reltag=feature; then
    pass "parse b: dispatch dry run"
  else fail "parse b: dry run (rc=$RC log=$PLOG)"; fi

  parse_case COMMIT_IN=projector/v2.0.0 EXPECTED="$EXP"
  if [ $RC -eq 0 ] && has "commit=$C40" && has "srcref=$C40" && has reltag=projector/v2.0.0 \
     && has scope=projector && has version=v2.0.0 && has mode=retag; then
    pass "parse c: real dispatch of an annotated tag, peeled"
  else fail "parse c: real dispatch (rc=$RC log=$PLOG)"; fi

  parse_case COMMIT_IN=projector/v3.0.0 EXPECTED="  $EXP  "
  if [ $RC -eq 0 ] && has "commit=$C40" && has reltag=projector/v3.0.0; then
    pass "parse c2: real dispatch of a lightweight tag, padded expected"
  else fail "parse c2: lightweight tag (rc=$RC log=$PLOG)"; fi

  parse_case GITHUB_REF=refs/heads/feature GITHUB_REF_NAME=feature COMMIT_IN=projector/v2.0.0 EXPECTED="$EXP"
  if [ $RC -eq 1 ] && echo "$PLOG" | grep -q 'default branch'; then
    pass "parse d: real dispatch off the default branch refused"
  else fail "parse d: (rc=$RC log=$PLOG)"; fi

  parse_case COMMIT_IN=projector/v9.9.9 EXPECTED="$EXP"
  if [ $RC -eq 1 ] && echo "$PLOG" | grep -q 'does not exist'; then
    pass "parse e: a missing tag refused"
  else fail "parse e: (rc=$RC log=$PLOG)"; fi

  parse_case COMMIT_IN="$C40" EXPECTED="$EXP"
  if [ $RC -eq 1 ] && echo "$PLOG" | grep -q 'names an existing'; then
    pass "parse f: a sha refused"
  else fail "parse f: (rc=$RC log=$PLOG)"; fi

  parse_case COMMIT_IN=v2.0.0 EXPECTED="$EXP"
  if [ $RC -eq 1 ] && echo "$PLOG" | grep -q 'names an existing'; then
    pass "parse g: a plain suite tag refused"
  else fail "parse g: (rc=$RC log=$PLOG)"; fi

  parse_case COMMIT_IN=projector/v2.0.0 EXPECTED=""
  r1=$RC; l1="$PLOG"
  parse_case COMMIT_IN=projector/v2.0.0 EXPECTED="cm-service=sha256:$HEX64"
  if [ $r1 -eq 1 ] && [ $RC -eq 1 ] && echo "$l1" | grep -q 'needs expected for' && echo "$PLOG" | grep -q 'needs expected for'; then
    pass "parse h: expected empty or for another image refused"
  else fail "parse h: (rc=$r1/$RC log=$PLOG)"; fi

  parse_case COMMIT_IN=other/v2.0.0 EXPECTED="other=sha256:$HEX64"
  if [ $RC -eq 1 ] && echo "$PLOG" | grep -q 'not in images'; then
    pass "parse i: an image outside images refused"
  else fail "parse i: (rc=$RC log=$PLOG)"; fi

  parse_case GITHUB_REF=refs/tags/projector/v2.0.0 GITHUB_REF_NAME=projector/v2.0.0 GITHUB_EVENT_NAME=push COMMIT_IN="$C40"
  if [ $RC -eq 1 ] && echo "$PLOG" | grep -q 'the commit input is for dry runs only'; then
    pass "parse j: tag push with a commit input refused"
  else fail "parse j: (rc=$RC log=$PLOG)"; fi

  parse_case COMMIT_IN=projector/v2.0.0 EXPECTED="$EXP" STUB_PEEL=tree
  if [ $RC -eq 1 ] && echo "$PLOG" | grep -q 'does not point at a commit'; then
    pass "parse k: a tag peeling to a non-commit refused"
  else fail "parse k: (rc=$RC log=$PLOG)"; fi

  # m. mutation: remove the guard-1 check from a copy; case d must then pass.
  sed '/GITHUB_REF" != "refs\/heads\/\$default_branch"/,/^  fi$/d' "$PARSE" > "$TMP/parse-mut.sh"
  if cmp -s "$PARSE" "$TMP/parse-mut.sh"; then fail "parse m: mutation did not change the script"
  else
    SAVE="$PARSE"; PARSE="$TMP/parse-mut.sh"
    parse_case GITHUB_REF=refs/heads/feature GITHUB_REF_NAME=feature COMMIT_IN=projector/v2.0.0 EXPECTED="$EXP"
    PARSE="$SAVE"
    if [ $RC -eq 0 ]; then pass "parse m: mutation: without the default-branch guard, case d would pass"
    else fail "parse m: mutated script still refused (rc=$RC log=$PLOG)"; fi
  fi

  # no GITHUB_REF_NAME outside the Parse step
  m="$($PY - "$WF" <<'PY'
import sys
lines = open(sys.argv[1], encoding="utf-8").read().split("\n")
start = next(i for i, l in enumerate(lines) if "- name: Parse the tag" in l)
end = next(i for i, l in enumerate(lines) if "- name: Check out the tagged commit" in l)
print(sum("GITHUB_REF_NAME" in l for i, l in enumerate(lines) if not start <= i < end))
PY
)"
  if [ "$m" = "0" ]; then pass "workflow: GITHUB_REF_NAME is used only in the Parse step"
  else fail "workflow: $m lines outside the Parse step use GITHUB_REF_NAME"; fi
fi

n=0
for f in "$ROOT/release/caller-template.yml" "$ROOT/.github/workflows/release.yml"; do
  grep -q "commit: \${{ inputs.commit || '' }}" "$f" || n=$((n + 1))
done
if [ "$n" = "0" ]; then pass "workflow: the callers pass the commit input through"
else fail "workflow: $n caller(s) do not pass the commit input"; fi

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
