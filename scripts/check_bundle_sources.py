#!/usr/bin/env python3
"""check_bundle_sources.py -- does the runtime bundle carry every path the chart loads?

Every bundle-loader initContainer `cp`s paths named as `"src" "<path>"` in the
templates from /bundle/<path>. bundle/Dockerfile decides what /bundle holds,
and it COPYs file by file or directory by directory. The two lists are written
by hand in different files, so they can drift apart.

Nothing else sees that drift. The render is correct, the image exists, and the
pins check passes. The first sign is every pod that loads the missing path
failing in Init with "can't stat". Measured: the three declaration intakes
(ADR-0050) on their first roll, because the Dockerfile never learned
declaration-intake.yaml.

A src passes when /bundle/<src> is a COPY destination, or lies under a
directory destination (one ending in "/").

Exit 0 when every src is covered; 1 with one line per uncovered src.
"""
from __future__ import annotations

import argparse
import pathlib
import re
import sys

HERE = pathlib.Path(__file__).resolve().parent
SRC_RE = re.compile(r'"src"\s+"([^"]+)"')
COPY_RE = re.compile(r"^\s*COPY\s+(?:--\S+\s+)*\S+\s+(/bundle/\S*)\s*$")


def template_sources(templates: pathlib.Path) -> set[str]:
    out: set[str] = set()
    for f in sorted(templates.rglob("*")):
        if f.suffix in (".yaml", ".tpl") and f.is_file():
            out.update(SRC_RE.findall(f.read_text(encoding="utf-8")))
    return out


def copy_destinations(dockerfile: pathlib.Path) -> list[str]:
    return [m.group(1) for line in dockerfile.read_text(encoding="utf-8").splitlines()
            if (m := COPY_RE.match(line))]


def covered(src: str, dests: list[str]) -> bool:
    path = "/bundle/" + src.strip("/")
    for d in dests:
        if d.endswith("/"):
            if path == d.rstrip("/") or path.startswith(d):
                return True
        elif path == d:
            return True
    return False


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("--dockerfile", type=pathlib.Path, default=HERE.parent / "bundle" / "Dockerfile")
    ap.add_argument("--templates", type=pathlib.Path, default=HERE.parent / "openddil-demo" / "templates")
    a = ap.parse_args()

    srcs = template_sources(a.templates)
    dests = copy_destinations(a.dockerfile)
    if not srcs or not dests:
        # An empty side would pass vacuously; a check that cannot fail is not one.
        print(f"FAIL: parsed {len(srcs)} template src path(s) and {len(dests)} COPY destination(s)")
        return 1
    missing = sorted(s for s in srcs if not covered(s, dests))
    for s in missing:
        print(f"MISSING: templates load {s!r} but {a.dockerfile.name} copies nothing to /bundle/{s}")
    if missing:
        return 1
    print(f"OK: {len(srcs)} template src path(s) covered by {len(dests)} COPY destination(s)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
