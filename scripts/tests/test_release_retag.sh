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

if grep -q 'GITHUB_EVENT_NAME" = workflow_dispatch ] && \[ "\$DRY_RUN" = true ]' "$WF" \
   && grep -q 'the commit input is for dry runs only' "$WF"; then
  pass "workflow: off a tag, and with a commit input, only a dry run proceeds"
else fail "workflow: a real run could start off a tag or on a named commit"; fi

n=0
for f in "$ROOT/release/caller-template.yml" "$ROOT/.github/workflows/release.yml"; do
  grep -q "commit: \${{ inputs.commit || '' }}" "$f" || n=$((n + 1))
done
if [ "$n" = "0" ]; then pass "workflow: the callers pass the commit input through"
else fail "workflow: $n caller(s) do not pass the commit input"; fi

if [ "$FAIL" -eq 0 ]; then echo "ALL PASS"; else echo "SOME FAILED"; exit 1; fi
