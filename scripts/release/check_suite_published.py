#!/usr/bin/env python3
"""Check that every image in a suite manifest, and the bundle, already carries
its version tag at the listed digest. Never tags anything.

Usage: check_suite_published.py MANIFEST [--fixtures DIR]
The registry tag is the version part of the git tag (after any "<name>/"); the
bundle uses the suite version. Exit 1 naming each image that differs.
"""
import argparse
import os
import sys

import yaml

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import release_common as rc  # noqa: E402


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("manifest")
    ap.add_argument("--fixtures", default=None)
    a = ap.parse_args()
    rc.configure(fixtures=a.fixtures)
    with open(a.manifest, encoding="utf-8") as f:
        m = yaml.safe_load(f)
    items = [(i["name"], i["image"], str(i["tag"]).split("/")[-1], i["digest"]) for i in m["images"]]
    items.append(("bundle", m["bundle"]["image"], str(m["suite"]), m["bundle"]["digest"]))
    bad = 0
    for name, image, tag, digest in items:
        got = (rc.fetch("digest", "%s:%s" % (image, tag)) or {}).get("digest")
        if got != digest:
            print("FAIL %s: %s:%s is %s, manifest says %s" % (name, image, tag, got or "absent", digest))
            bad = 1
    if not bad:
        print("PASS: %d images and the bundle carry their tags at the listed digests" % (len(items) - 1))
    return bad


if __name__ == "__main__":
    sys.exit(main())
