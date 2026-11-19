"""Write find_build.py fixtures for one test case.

Usage: release_retag_fixtures.py DIR CASE
Layout follows scripts/release/release_common.py: DIR/<kind>__<key>.json.
Digests: d1.. are 'sha256:' + 64 copies of the hex digit; attestation and blob
digests are derived from them.
"""
import json
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "release"))
from release_common import fixture_name, REGISTRY  # noqa: E402

REPO = "edgy-solutions/openddil-projector"
COMMIT = "a" * 39 + "1"
REF = REGISTRY + "/projector"
DATE = "2026-11-10T12:00:00Z"
OLD = "2026-10-01T12:00:00Z"


def d(c):
    return "sha256:" + c * 64


def put(base, kind, key, obj):
    with open(os.path.join(base, fixture_name(kind, key)), "w", encoding="utf-8", newline="\n") as f:
        json.dump(obj, f)


def build(base, dig, repo=REPO, sha=COMMIT, event="push", att=True, run="111"):
    att_d = "sha256:" + "e" + dig[7:-1]
    blob_d = "sha256:" + "f" + dig[7:-1]
    entries = [{"digest": "sha256:" + "c" * 64, "annotations": {}}]
    if att:
        entries.append({"digest": att_d, "annotations": {"vnd.docker.reference.type": "attestation-manifest"}})
    put(base, "manifest", "%s@%s" % (REF, dig), {"mediaType": "application/vnd.oci.image.index.v1+json", "manifests": entries})
    if not att:
        return
    put(base, "manifest", "%s@%s" % (REF, att_d), {"layers": [
        {"digest": "sha256:" + "9" * 64, "annotations": {"in-toto.io/predicate-type": "https://spdx.dev/Document"}},
        {"digest": blob_d, "annotations": {"in-toto.io/predicate-type": "https://slsa.dev/provenance/v1"}}]})
    put(base, "blob", "%s@%s" % (REF, blob_d), {"predicate": {
        "buildDefinition": {"internalParameters": {
            "github_repository": repo, "github_workflow_sha": sha,
            "github_event_name": event, "github_run_id": run}},
        "runDetails": {"metadata": {"startedOn": DATE}}}})


def main():
    base, case = sys.argv[1], sys.argv[2]
    put(base, "commitdate", COMMIT, DATE)
    versions = []
    sha_tag = False
    if case == "sha_tag":
        sha_tag = True
        build(base, d("1"))
    elif case == "one_of_three":
        versions = [{"name": d("1"), "created_at": DATE}, {"name": d("2"), "created_at": DATE},
                    {"name": d("3"), "created_at": OLD}]
        build(base, d("1"))
        build(base, d("2"), sha="b" * 40)
        build(base, d("3"))  # matches, but older than the commit date minus a day
    elif case == "two_match":
        versions = [{"name": d("1"), "created_at": DATE}, {"name": d("2"), "created_at": DATE}]
        build(base, d("1"))
        build(base, d("2"), run="222")
    elif case == "pull_request":
        sha_tag = True
        build(base, d("1"), event="pull_request")
    elif case == "repo_mismatch":
        sha_tag = True
        build(base, d("1"), repo="edgy-solutions/other")
    elif case == "no_attestation":
        sha_tag = True
        build(base, d("1"), att=False)
    else:
        sys.exit("unknown case " + case)
    if sha_tag:
        put(base, "digest", "%s:sha-%s" % (REF, COMMIT[:7]), {"digest": d("1")})
    put(base, "versions", "projector", versions)


main()
