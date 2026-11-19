#!/usr/bin/env python3
"""Find the image of one GHCR package that was built from a given commit.

A release retags; it never builds. Candidates are the sha-<7> tag and recent
package versions. Each must carry SLSA provenance naming this repo, this
commit as the workflow sha, and a push or workflow_dispatch event.
Prints one JSON line on success; exits 1 with a reason on failure.
"""
import argparse
import datetime
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_common as rc  # noqa: E402

MAX_VERSIONS = 300


def log(msg):
    print(msg, file=sys.stderr)


def provenance(ref, digest):
    """Return (params, run_id, created) or raise ValueError with the reason."""
    idx = rc.fetch("manifest", "%s@%s" % (ref, digest))
    if not idx or "manifests" not in idx:
        raise ValueError("not an OCI index")
    att = None
    for m in idx["manifests"]:
        if (m.get("annotations") or {}).get("vnd.docker.reference.type") == "attestation-manifest":
            att = m.get("digest")
            break
    if not att:
        raise ValueError("index has no attestation manifest")
    am = rc.fetch("manifest", "%s@%s" % (ref, att))
    layer = None
    for l in (am or {}).get("layers", []):
        pt = (l.get("annotations") or {}).get("in-toto.io/predicate-type", "")
        if pt.startswith("https://slsa.dev/provenance/"):
            layer = l
            break
    if not layer:
        raise ValueError("attestation has no SLSA provenance layer")
    blob = rc.fetch("blob", "%s@%s" % (ref, layer["digest"]))
    pred = (blob or {}).get("predicate") or {}
    params = (pred.get("buildDefinition") or {}).get("internalParameters") or {}
    created = ((pred.get("runDetails") or {}).get("metadata") or {}).get("startedOn", "")
    return params, str(params.get("github_run_id", "")), created


def parse_date(s):
    return datetime.datetime.fromisoformat(s.replace("Z", "+00:00"))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--image", required=True)
    ap.add_argument("--repo", required=True)
    ap.add_argument("--commit", required=True)
    ap.add_argument("--expected", default="")
    ap.add_argument("--fixtures", default=None)
    a = ap.parse_args()
    rc.configure(fixtures=a.fixtures, repo=a.repo)
    ref = "%s/%s" % (rc.REGISTRY, a.image)

    cands = []
    t = rc.fetch("digest", "%s:sha-%s" % (ref, a.commit[:7]))
    if t and t.get("digest"):
        cands.append(t["digest"])
    cdate = rc.fetch("commitdate", a.commit)
    if cdate:
        floor = parse_date(cdate) - datetime.timedelta(days=1)
        n = 0
        for v in rc.fetch("versions", a.image) or []:
            if n >= MAX_VERSIONS:
                break
            n += 1
            if parse_date(v["created_at"]) >= floor and v["name"] not in cands:
                cands.append(v["name"])
    else:
        log("commit date unavailable; using the sha tag only")

    found = {}
    for d in cands:
        try:
            params, run_id, created = provenance(ref, d)
        except ValueError as e:
            log("drop %s: %s" % (d, e))
            continue
        if params.get("github_repository") != a.repo:
            log("drop %s: github_repository %r is not %s" % (d, params.get("github_repository"), a.repo))
        elif params.get("github_workflow_sha") != a.commit:
            log("drop %s: github_workflow_sha %r is not the commit" % (d, params.get("github_workflow_sha")))
        elif params.get("github_event_name") not in ("push", "workflow_dispatch"):
            log("drop %s: github_event_name %r" % (d, params.get("github_event_name")))
        else:
            found[d] = (run_id, created)

    F = sorted(found)
    if a.expected:
        if a.expected not in found:
            sys.exit("FAIL %s: expected %s is not among the builds of %s: %s"
                     % (a.image, a.expected, a.commit, ", ".join(F) or "none"))
        pick = a.expected
    elif len(F) == 1:
        pick = F[0]
    elif not F:
        sys.exit("FAIL: no image of %s built from %s in %s; a release retags, it does not build"
                 % (a.image, a.commit, a.repo))
    else:
        sys.exit("FAIL %s: %d builds from %s: %s. Re-run with `expected`."
                 % (a.image, len(F), a.commit, ", ".join(F)))
    print(json.dumps({"image": a.image, "digest": pick, "commit": a.commit,
                      "run_id": found[pick][0], "created": found[pick][1]}))


if __name__ == "__main__":
    main()
