#!/usr/bin/env bash
# =============================================================================
# check-mirror-coverage.sh — the chart's images ARE the mirror's inventory
# =============================================================================
#
# WHY THIS EXISTS
# ---------------
# mirror-to-artifactory.ps1 carries a hand-written list of every image an
# air-gapped site must copy into its own registry. The chart carries the
# images. Nothing tied the two together, and between 2026-06-13 and
# 2026-09-23 the chart gained four images the mirror never learned about —
# roughly 30 chart versions of silence. One of them, the kubectl image the
# restate-wipe PRE-INSTALL hook runs, is on by default: an air-gapped
# install reaches docker.io before a single workload starts, and helm
# reports it only as "timed out waiting for the condition".
#
# So this check does not read either list. It RENDERS the chart, with every
# optional stack enabled, and holds what comes out against the inventory.
#
# WHAT IT ASSERTS, in four passes -- three over the rendered manifests and
# one over a manifest the chart does not own:
#
#   1. COVERAGE. Every image reference, with its tag, appears in the
#      mirror inventory. Catches a new image, and catches a version bump
#      the mirror was never told about.
#   2. PINNABLE. Rendered again with the digests the mirror's values-path
#      mapping would write, every reference resolves by @sha256. Catches a
#      mapping entry that is missing, and catches a template that takes an
#      image block apart and drops the digest on the way through.
#   3. REDIRECTABLE. Rendered with values-artifactory.yaml, every reference
#      points at the mirror registry at the inventory's own destination
#      path. Catches an image the overlay forgot to remap, which is how
#      restate.wipe, releasability.* and tierNode.* stayed pointed at
#      public registries.
#
#   4. NOT-ONLY-THE-CHART. Every image a k8s manifest in
#      openddil-customer-bundle-example deploys is in the inventory too. One
#      image lives there: dis-sim, the DIS generator that feeds the
#      pipeline's front door. Mirror everything the chart renders and nothing
#      else, and an air-gapped site gets a stack with nothing arriving at it
#      -- which presents as a pipeline fault, not a missing image.
#
# Pass 1 is coverage; 2 and 3 are the reasons coverage is worth having; 4 is
# there because the chart render is not the whole deploy.
#
# Pass 4 reads k8s manifests only. `docker-compose.customer.yml` in that repo
# names two more images (a connect and a rabbitmq) and they are deliberately
# out of scope: this inventory is what a site copies to run the CHART, and
# that compose file is a different deployment whose registry story is the
# customer's. Stated so the gap is a decision rather than an oversight.
#
# USAGE
#   ./scripts/check-mirror-coverage.sh [--extra-values FILE]
#
# --extra-values layers one more values file onto every pass. It exists for
# the CI red-check, which plants an unmirrored image and requires this
# script to FAIL. A check nobody has watched fail is a check nobody has
# tested.
#
# The sibling repo is found at ../openddil-customer-bundle-example, or
# wherever OPENDDIL_BUNDLE_EXAMPLE points. If it is not there, pass 4 says so
# on its own line and in the RESULT line rather than vanishing -- a check that
# quietly stops asserting something is the failure mode this file was written
# after. CI checks the sibling out, so the skip cannot happen where it counts.
#
# EXIT: 0 = every pass clean. 1 = at least one finding, each printed with
# the image and the pass that rejected it.
# =============================================================================
set -uo pipefail

cd "$(dirname "$0")/.."

CHART="./openddil-demo"
MIRROR_SCRIPT="./scripts/mirror-to-artifactory.ps1"
ARTIFACTORY_VALUES="./values-artifactory.yaml"

# Any registry host works — nothing is contacted. It only has to be a value
# no real repository in the chart could collide with.
MIRROR_REGISTRY="mirror.invalid"

EXTRA_VALUES=""
while [ $# -gt 0 ]; do
    case "$1" in
        --extra-values)
            EXTRA_VALUES="${2:-}"
            if [ -z "$EXTRA_VALUES" ] || [ ! -f "$EXTRA_VALUES" ]; then
                echo "--extra-values needs a readable file" >&2
                exit 2
            fi
            shift 2
            ;;
        *)
            echo "unknown argument: $1" >&2
            exit 2
            ;;
    esac
done

command -v helm >/dev/null 2>&1 || { echo "helm is required" >&2; exit 2; }
# Same idiom as the other chart checks, so this runs on a Windows box too.
PY=$(command -v python3 || command -v python || echo py)

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# -----------------------------------------------------------------------------
# Every optional stack ON. The point of the check is the images a default
# install never pulls — those are exactly the ones nobody notices are
# missing until a customer enables the stack inside an air gap.
#
# tierNode.tiers stays empty, which means every configured edge takes the
# kit. That renders the per-tier store, atlas job, restate, electric, topaz,
# PEP and frontend. The one tier path it does not reach is the uplink relay
# (needs hasChildren), whose image is redpandadata/connect via
# edgeHqBridge.image — already rendered by the edge bridge in every pass.
# -----------------------------------------------------------------------------
cat > "$TMP/ci-enable.yaml" <<'YAML'
releasability:
  enabled: true
  oidc:
    enabled: true
  keycloak:
    enabled: true
tierNode:
  enabled: true
sensorIngest:
  externalAccess:
    enabled: true
restate:
  # The restate-wipe PRE-UPGRADE hook, and with it the kubectl image this
  # whole check was written because the mirror had never heard of.
  #
  # This line was NOT here while the chart defaulted the flag to true: the
  # hook rendered for free and the image came with it. The default is now
  # false (a flag that destroys data should have to be asked for), and the
  # flip alone would have taken alpine/k8s out of every pass -- leaving the
  # check green, still running, and no longer asserting anything about the
  # one image whose absence caused it to exist. Measured, not assumed: the
  # rendered image set loses exactly docker.io/alpine/k8s when the flag goes
  # false.
  #
  # So the hook is enabled here for the same reason every other stack above
  # is. This file's job is to render EVERYTHING the chart can emit; a value
  # that is off by default is precisely what it exists to turn on.
  ephemeralOnUpgrade: true
YAML

# Parse the PowerShell inventory and values-path mapping. Both are plain
# literal tables; reading them is a regex, not an interpreter.
"$PY" - "$MIRROR_SCRIPT" "$TMP" <<'PY'
import re, sys, pathlib

mirror = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
tmp = pathlib.Path(sys.argv[2])

images = re.findall(r"@\{\s*src='([^']+)'\s*;\s*dst='([^']+)'\s*\}", mirror)
if not images:
    sys.exit("could not parse any image from the mirror inventory")
tmp.joinpath("inventory.txt").write_text(
    "".join(f"{s}\t{d}\n" for s, d in images), encoding="utf-8")

# 'name' = @('a.b.digest', 'c.d.digest') — the list may wrap across lines.
table = mirror.split("$SrcShortNameToValuesPaths = @{", 1)[1].split("\n}", 1)[0]
paths = []
for m in re.finditer(r"'([^']+)'\s*=\s*@\(([^)]*)\)", table, re.S):
    paths.extend(re.findall(r"'([^']+)'", m.group(2)))
if not paths:
    sys.exit("could not parse any values path from the mapping table")

# A digest per short name, distinct so a mis-wired path is visible in the
# failure text rather than blending into one repeated sha.
tree = {}
for i, dotted in enumerate(sorted(set(paths))):
    node = tree
    segs = dotted.split(".")
    for seg in segs[:-1]:
        node = node.setdefault(seg, {})
    node[segs[-1]] = "sha256:" + f"{i:02d}" * 32

def emit(node, indent=0):
    out = []
    for key in sorted(node):
        val = node[key]
        if isinstance(val, dict):
            out.append(f"{' ' * indent}{key}:")
            out.extend(emit(val, indent + 2))
        else:
            out.append(f"{' ' * indent}{key}: \"{val}\"")
    return out

tmp.joinpath("digests.yaml").write_text("\n".join(emit(tree)) + "\n", encoding="utf-8")
PY
[ $? -eq 0 ] || exit 2

sed "s|<ARTIFACTORY>|$MIRROR_REGISTRY|g" "$ARTIFACTORY_VALUES" > "$TMP/artifactory.yaml"

render() {
    # $1 = output file, rest = extra -f arguments
    local out="$1"; shift
    local args=(-f "$TMP/ci-enable.yaml" "$@")
    if [ -n "$EXTRA_VALUES" ]; then args+=(-f "$EXTRA_VALUES"); fi
    if ! helm template openddil "$CHART" "${args[@]}" > "$out" 2> "$TMP/helm.err"; then
        echo "helm template failed:" >&2
        cat "$TMP/helm.err" >&2
        exit 2
    fi
}

render "$TMP/pass1.yaml"
render "$TMP/pass2.yaml" -f "$TMP/digests.yaml"
render "$TMP/pass3.yaml" -f "$TMP/artifactory.yaml" -f "$TMP/digests.yaml"

# Pass 4's input is not a render. It is the `image:` lines of every k8s
# manifest in the customer bundle example -- collected here rather than in the
# analyser so that a missing sibling is a shell-level fact, not a parse.
BUNDLE_EXAMPLE="${OPENDDIL_BUNDLE_EXAMPLE:-../openddil-customer-bundle-example}"
if [ -d "$BUNDLE_EXAMPLE" ]; then
    find "$BUNDLE_EXAMPLE" -path '*/k8s/*'          \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null       | xargs -0 -r grep -h -E '^[[:space:]]*image:[[:space:]]'       > "$TMP/pass4.yaml" 2>/dev/null
    # An existing but empty file is itself a finding: the manifests were
    # found and named no image, which means this pass is watching the wrong
    # directory. Keep the file so the analyser can say that.
    touch "$TMP/pass4.yaml"
fi

"$PY" - "$TMP" "$MIRROR_REGISTRY" <<'PY'
import pathlib, re, sys

tmp = pathlib.Path(sys.argv[1])
registry = sys.argv[2]

inventory = [line.split("\t") for line in
             tmp.joinpath("inventory.txt").read_text(encoding="utf-8").splitlines()]

def canonical(ref):
    """Docker's own defaulting: bare names are docker.io, single-segment
    names are docker.io/library. Without it, `postgres:15` in values.yaml
    and `postgres:15` in the inventory match by luck, and
    `docker.io/alpine/k8s` against `alpine/k8s` does not match at all."""
    first = ref.split("/", 1)[0]
    if "/" not in ref:
        return "docker.io/library/" + ref
    if "." not in first and ":" not in first and first != "localhost":
        return "docker.io/" + ref
    return ref

def split_ref(ref):
    if "@" in ref:
        repo, digest = ref.split("@", 1)
        return canonical(repo), digest
    repo, _, tag = ref.rpartition(":")
    if not repo or "/" in tag:          # no tag at all
        return canonical(ref), None
    return canonical(repo) + ":" + tag, None

SRC = {split_ref(s)[0] for s, _ in inventory}
# Repository alone, for a reference the chart already pins by digest in
# values.yaml (releasability.topaz does). There is no tag on such a
# reference to hold against the inventory's tag — the digest IS the
# version — so coverage asks only that the repository is mirrored.
SRC_REPOS = {r.rsplit(":", 1)[0] for r in SRC}
DST = {registry + "/" + d.rsplit(":", 1)[0] for _, d in inventory}

def images(path):
    out = []
    for line in tmp.joinpath(path).read_text(encoding="utf-8").splitlines():
        m = re.match(r"\s*image:\s*[\"']?([^\"'\s]+)[\"']?\s*$", line)
        if m:
            out.append(m.group(1))
    return sorted(set(out))

findings = []

for ref in images("pass1.yaml"):
    repo, digest = split_ref(ref)
    if digest is not None:
        if repo not in SRC_REPOS:
            findings.append(("1 coverage", ref, "repository absent from the mirror inventory"))
    elif repo not in SRC:
        hint = ("absent from the mirror inventory"
                if repo.rsplit(":", 1)[0] not in SRC_REPOS
                else "mirrored at a different tag than the chart renders")
        findings.append(("1 coverage", ref, hint))

for ref in images("pass2.yaml"):
    if "@sha256:" not in ref:
        findings.append(("2 pinnable", ref,
                         "rendered by tag although every mapped digest was set: "
                         "no values-path mapping, or the template drops .digest"))

for ref in images("pass3.yaml"):
    repo, digest = split_ref(ref)
    if digest is None:
        findings.append(("3 redirectable", ref, "not digest-pinned under values-artifactory.yaml"))
    elif repo not in DST:
        findings.append(("3 redirectable", ref,
                         "not redirected to the mirror registry by values-artifactory.yaml"))

# Pass 4: the same coverage question as pass 1, asked of a manifest the chart
# does not own. Nothing about pinning or redirection -- that manifest has no
# values file to overlay, which is precisely why its image has to be in the
# inventory by hand and precisely why nothing noticed that it was not.
pass4_state = "skipped"
if (tmp / "pass4.yaml").exists():
    refs4 = images("pass4.yaml")
    if not refs4:
        findings.append(("4 not-only-the-chart", "(no image found)",
                         "the bundle example's k8s manifests named no image: "
                         "this pass is looking at the wrong directory"))
        pass4_state = "0 refs"
    else:
        pass4_state = f"{len(refs4)} refs"
    for ref in refs4:
        repo, digest = split_ref(ref)
        if digest is not None:
            if repo not in SRC_REPOS:
                findings.append(("4 not-only-the-chart", ref,
                                 "repository absent from the mirror inventory"))
        elif repo not in SRC:
            hint = ("absent from the mirror inventory"
                    if repo.rsplit(":", 1)[0] not in SRC_REPOS
                    else "mirrored at a different tag than the manifest deploys")
            findings.append(("4 not-only-the-chart", ref, hint))

counts = {p: len(images(f"pass{i}.yaml")) for i, p in
          ((1, "coverage"), (2, "pinnable"), (3, "redirectable"))}
print(f"inventory: {len(inventory)} images")
print("rendered:  " + ", ".join(f"{n} refs ({p})" for p, n in counts.items()))
if pass4_state == "skipped":
    print("pass 4:    NOT RUN -- no ../openddil-customer-bundle-example "
          "(set OPENDDIL_BUNDLE_EXAMPLE)")
else:
    print(f"pass 4:    {pass4_state} from the bundle example's k8s manifests")

if findings:
    print()
    for pas, ref, why in findings:
        print(f"  FAIL [pass {pas}] {ref}\n         {why}")
    print(f"\nRESULT: FAIL ({len(findings)})")
    sys.exit(1)

print("RESULT: PASS"
      + (" -- but pass 4 did not run" if pass4_state == "skipped" else ""))
PY
