#!/usr/bin/env python3
"""Offline checks of a suite manifest. See release/suite-manifest.schema.md.

Usage: check_suite_manifest.py FILE...   Exit 1 on any failure; one line each.
"""
import os
import re
import sys

import yaml

TOP = ["suite", "status", "promotedFrom", "chart", "bundle", "images", "blockers"]
OPTIONAL = ["thirdParty"]
TP_KEYS = {"name", "image", "tag", "digest", "pinned"}
OWN_PREFIX = "ghcr.io/edgy-solutions/openddil/"
VERSION = re.compile(r"^v\d+\.\d+\.\d+(-rc\.?\d+)?$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
COMMIT = re.compile(r"^[0-9a-f]{40}$")


def check_third_party(tp, image_names):
    errs = []
    if not isinstance(tp, list):
        return ["thirdParty is not a list"]
    seen = set()
    for i, e in enumerate(tp):
        if not isinstance(e, dict):
            errs.append("thirdParty[#%d] is not a mapping" % i)
            continue
        n = e.get("name", "#%d" % i)
        for k in sorted(TP_KEYS - set(e)):
            errs.append("thirdParty[%s] missing %s" % (n, k))
        for k in sorted(set(e) - TP_KEYS, key=str):
            errs.append("thirdParty[%s] unknown key %s" % (n, k))
        if n in seen:
            errs.append("duplicate thirdParty name " + str(n))
        seen.add(n)
        if n in image_names:
            errs.append("thirdParty name %s is also an images name" % n)
        if "digest" in e and not DIGEST.match(str(e["digest"])):
            errs.append("thirdParty %s digest malformed" % n)
        if "pinned" in e and not isinstance(e["pinned"], bool):
            errs.append("thirdParty %s pinned is not a bool" % n)
        if "tag" in e:
            t = e["tag"]
            if not isinstance(t, str) or not t:
                errs.append("thirdParty %s tag is not a non-empty string" % n)
            elif t == "latest":
                errs.append("thirdParty %s tag is latest" % n)
        if "image" in e and str(e["image"]).startswith(OWN_PREFIX):
            errs.append("thirdParty %s image %s is openddil-owned; list it under images" % (n, e["image"]))
    return errs


def check(path):
    errs = []
    with open(path, encoding="utf-8") as f:
        m = yaml.safe_load(f)
    if not isinstance(m, dict):
        return ["not a mapping"]
    for k in TOP:
        if k not in m:
            errs.append("missing key " + k)
    for k in m:
        if k not in TOP and k not in OPTIONAL:
            errs.append("unknown top-level key " + str(k))
    if errs:
        return errs
    suite = str(m["suite"])
    if not VERSION.match(suite):
        errs.append("suite %r is not a version" % suite)
    if m["status"] not in ("proposed", "tagged", "promoted"):
        errs.append("status %r is not proposed|tagged|promoted" % m["status"])
    chart, bundle = m["chart"], m["bundle"]
    for k in ("name", "version", "commit"):
        if not isinstance(chart, dict) or k not in chart:
            errs.append("chart.%s missing" % k)
    for k in ("image", "digest", "loaderPins", "sources"):
        if not isinstance(bundle, dict) or k not in bundle:
            errs.append("bundle.%s missing" % k)
    if errs:
        return errs
    cc = str(chart["commit"] or "")
    if cc and not COMMIT.match(cc):
        errs.append("chart.commit is not 40 hex")
    if not DIGEST.match(str(bundle["digest"])):
        errs.append("bundle.digest malformed")
    for p in bundle["loaderPins"] or []:
        if not DIGEST.match(str(p)):
            errs.append("bundle.loaderPins entry malformed: %s" % p)
    for k, v in (bundle["sources"] or {}).items():
        if not COMMIT.match(str(v)):
            errs.append("bundle.sources.%s is not 40 hex" % k)
    seen = set()
    for i, im in enumerate(m["images"] or []):
        n = im.get("name", "#%d" % i)
        for k in ("name", "image", "digest", "repo", "commit", "tag"):
            if k not in im:
                errs.append("images[%s] missing %s" % (n, k))
        if n in seen:
            errs.append("duplicate image name " + str(n))
        seen.add(n)
        if not DIGEST.match(str(im.get("digest"))):
            errs.append("image %s digest malformed" % n)
        if not COMMIT.match(str(im.get("commit"))):
            errs.append("image %s commit is not 40 hex" % n)
        if str(im.get("tag")) not in (suite, "%s/%s" % (n, suite)):
            errs.append("image %s tag %r is neither %s nor %s/%s" % (n, im.get("tag"), suite, n, suite))
    # no 'latest' in any digest or tag field
    fields = [suite, bundle["digest"]] + list(bundle["loaderPins"] or [])
    for im in m["images"] or []:
        fields += [im.get("digest", ""), im.get("tag", "")]
    if any("latest" in str(x) for x in fields):
        errs.append("a digest or tag field contains 'latest'")
    if "thirdParty" in m:
        errs += check_third_party(m["thirdParty"], seen)
    if m["status"] != "proposed":
        if m["blockers"]:
            errs.append("status %s requires empty blockers" % m["status"])
        if not cc:
            errs.append("status %s requires chart.commit" % m["status"])
    pf = str(m["promotedFrom"] or "")
    if pf and "-rc" not in suite:
        other = os.path.join(os.path.dirname(os.path.abspath(path)), "suite-%s.yaml" % pf)
        if os.path.exists(other):
            with open(other, encoding="utf-8") as f:
                o = yaml.safe_load(f)
            a = {i["name"]: i["digest"] for i in m["images"] or []}
            b = {i["name"]: i["digest"] for i in o.get("images") or []}
            if a != b:
                errs.append("image digests differ from %s: %s"
                            % (pf, ", ".join(sorted(k for k in set(a) | set(b) if a.get(k) != b.get(k)))))
            if bundle["digest"] != o["bundle"]["digest"]:
                errs.append("bundle digest differs from " + pf)
    return errs


def main(argv):
    bad = 0
    for p in argv:
        try:
            es = check(p)
        except Exception as e:  # unreadable or malformed YAML
            es = ["cannot read: %s" % e]
        for e in es:
            print("%s: %s" % (p, e))
            bad = 1
    return bad


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
