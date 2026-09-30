#!/usr/bin/env python3
"""check_consumer_declarations.py — does the render declare exactly the
consumer groups the lab census measured, one owner each?

SPEC-consumer-declarations.md Part A. `helm template` writes
`openddil.io/consumer-groups` onto each Deployment/StatefulSet's own
metadata (never spec.template — that would roll pods on every annotation
edit). This script reads the rendered manifest, extracts every
(broker-id/group-id, workload) pair from that annotation, and checks it
against a TSV of what the lab actually measured
(expected-declared.tsv: "<broker>/<group>\\tab<workload>", one row per pair).

Three ways this can fail, and all three are real reset-scenario.sh hazards
if they slip through unnoticed:

  1. MISSING / EXTRA pair — a consumer group the lab has that nothing
     declares (or a declared pair the lab does not have) is exactly the
     defect the whole spec exists to close: an undeclared consumer that a
     reset silently skips because IP-based ownership resolution never
     named it.
  2. DUPLICATE OWNER — two different workloads declaring the SAME
     (broker, group) is worse than a missing declaration: reset-scenario.sh
     cannot pick one, and Part B's assert_consumers_declared is specified to
     FAIL loudly on exactly this rather than guess.

Usage:
    helm template openddil ./openddil-demo -n openddil -f <values.yaml> \\
        | python3 scripts/check_consumer_declarations.py <expected.tsv>

Exit 0 and prints the sorted pair list on a match. Exit 1 (nothing printed
about "OK") on any mismatch or duplicate owner, with the specifics.
"""
from __future__ import annotations

import sys
from collections import defaultdict

import yaml

WORKLOAD_KINDS = {"Deployment", "StatefulSet"}
ANNOTATION_KEY = "openddil.io/consumer-groups"


def extract_declared(render_text: str) -> tuple[list[tuple[str, str]], dict[str, list[str]]]:
    """Parse a `helm template` render and return:
      - pairs: list of (broker/group, workload) tuples, one per annotation entry
      - owners_by_pair: broker/group -> list of declaring workload names
        (len > 1 means a duplicate owner)
    """
    pairs: list[tuple[str, str]] = []
    owners_by_pair: dict[str, list[str]] = defaultdict(list)

    for doc in yaml.safe_load_all(render_text):
        if not doc or not isinstance(doc, dict):
            continue
        if doc.get("kind") not in WORKLOAD_KINDS:
            continue
        metadata = doc.get("metadata") or {}
        annotations = metadata.get("annotations") or {}
        value = annotations.get(ANNOTATION_KEY)
        if not value:
            continue
        workload = f"{doc['kind']}/{metadata.get('name')}"
        # Value is space-separated "<broker-id>/<group-id>" entries (Part A).
        for entry in value.split():
            pairs.append((entry, workload))
            owners_by_pair[entry].append(workload)

    return pairs, owners_by_pair


def load_expected(path: str) -> set[tuple[str, str]]:
    expected: set[tuple[str, str]] = set()
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not line:
                continue
            broker_group, workload = line.split("\t", 1)
            expected.add((broker_group, workload))
    return expected


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: check_consumer_declarations.py <expected.tsv>  (render on stdin)", file=sys.stderr)
        return 2

    expected_path = sys.argv[1]
    render_text = sys.stdin.read()

    pairs, owners_by_pair = extract_declared(render_text)
    # Rendered workload names carry a "Deployment/" or "StatefulSet/" prefix
    # (Part B's `Kind/Name` shape, used later by reset-scenario.sh); the
    # expected TSV records the bare workload name — strip the kind prefix
    # for comparison, since expected-declared.tsv was measured from
    # `kubectl get deploy,statefulset` output, not from this render's Kind.
    actual = {(bg, w.split("/", 1)[1]) for bg, w in pairs}
    expected = load_expected(expected_path)

    dup_pairs = {bg: sorted(set(owners)) for bg, owners in owners_by_pair.items() if len(set(owners)) > 1}

    for bg, workload in sorted(actual):
        print(f"{bg}\t{workload}")

    ok = True

    missing = expected - actual
    extra = actual - expected
    if missing:
        ok = False
        print(f"MISSING ({len(missing)}): in expected, not declared:", file=sys.stderr)
        for bg, workload in sorted(missing):
            print(f"  {bg}\t{workload}", file=sys.stderr)
    if extra:
        ok = False
        print(f"EXTRA ({len(extra)}): declared, not in expected:", file=sys.stderr)
        for bg, workload in sorted(extra):
            print(f"  {bg}\t{workload}", file=sys.stderr)
    if dup_pairs:
        ok = False
        print(f"DUPLICATE OWNER ({len(dup_pairs)}): more than one workload declares the same pair:", file=sys.stderr)
        for bg, owners in sorted(dup_pairs.items()):
            print(f"  {bg}: {', '.join(owners)}", file=sys.stderr)

    if not ok:
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
