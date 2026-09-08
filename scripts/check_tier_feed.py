#!/usr/bin/env python3
"""check_tier_feed.py -- does every consumer a tier renders have a fed topic?

THE RULE (decisions/DESIGN-2026-09-07-region-input-contract.md):

    Every consumer a tier RENDERS must have a fed topic, or must not be
    rendered. There is no third option.

WHY THE CONSUMER CENSUS CANNOT ANSWER THIS, AND THAT IS THE WHOLE POINT.
check_consumer_census.py enumerates consumer GROUPS on a broker. A consumer
subscribed to a topic that does not exist on its broker never forms a group,
so it is invisible in exactly the data the census reads. It is also 1/1
Running, healthy on every probe, and indistinguishable from working.

That is UD-10 in a different costume. The census finds a consumer reading a
broker it should not; this finds a consumer reading nothing at all.

Measured on region-east the day the region deployed: 16 consumers rendered,
8 attached. The eight silent ones were not a malfunction -- they were the
absence of an input contract, and nothing in the system said so.

SECOND SOURCE REQUIRED. A broker cannot report an absence, so the rendered
configuration is read as well: the tier's projector ConfigMap for projector
consumers, and the subscription table below for Restate consumers. Comparing
one source against itself is how the census could report clean over a silent
tier.
"""
from __future__ import annotations

import json
import os
import pathlib
import subprocess
import sys

# Restate subscriptions a tier node registers, as (topic, consumer-group stem).
# Mirrored from openddil-contracts/bootstrap/register_tier_subscriptions.py.
#
# DUPLICATION IS THE COST OF THE SECOND SOURCE, and it is deliberate: this
# file must be able to DISAGREE with what is deployed, which it cannot do if
# it derives from it. The mirror is small and changes rarely; a drift shows up
# as a consumer this check does not know about, which is why the summary
# prints counts rather than only failures.
TIER_SUBSCRIPTIONS = [
    ("raw-sensor-stream",         "cm-service-silver"),
    ("cm-events",                 "cm-service-cm-events"),
    ("raw-sensor-stream",         "fusion-service-silver"),
    ("asset-telemetry-windows",   "fusion-service-windows"),
    ("derived-sustainment",       "fusion-service-derived"),
    ("asset-capability-snapshot", "fusion-service-capability"),
    ("asset-cm-state",            "fusion-service-cm-state"),
]


def kubectl(*args: str) -> str:
    return subprocess.run(["kubectl", *args], capture_output=True, text=True).stdout


def require_cluster(ctx: str) -> None:
    """Refuse to run against a cluster nobody named. See lib/require-cluster.sh."""
    root = pathlib.Path(__file__).resolve().parent.parent
    expect = os.environ.get("OPENDDIL_EXPECT_CONTEXT", "").strip()
    if not expect:
        f = root / ".expected-context"
        if f.is_file():
            expect = f.read_text(encoding="utf-8").strip()
    if not expect:
        print("REFUSING TO RUN: no expected kube-context is declared.",
              file=sys.stderr)
        print("  echo edgy-lab > " + str(root / ".expected-context"),
              file=sys.stderr)
        raise SystemExit(78)
    if ctx != expect:
        print("REFUSING TO RUN: wrong cluster.", file=sys.stderr)
        print("    expected context : " + expect, file=sys.stderr)
        print("    current context  : " + (ctx or "(none)"), file=sys.stderr)
        raise SystemExit(78)


def tiers(ns: str) -> list[str]:
    raw = kubectl("get", "sts", "-n", ns, "-o",
                  "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    return sorted(n.split("-tier-pg-", 1)[1] for n in raw.split()
                  if "-tier-pg-" in n)


def broker_topics(ns: str, tier: str) -> set[str] | None:
    """Topics on a tier's broker, or None if the probe failed.

    NONE IS NOT AN EMPTY SET. A failed exec returning "" would otherwise read
    as a broker holding no topics and report every consumer unfed -- a false
    positive spectacular enough to train the reader to ignore this check.
    """
    pod = "openddil-redpanda-" + tier + "-0"
    out = subprocess.run(
        ["kubectl", "exec", "-n", ns, pod, "--",
         "rpk", "topic", "list", "--brokers", "localhost:9092"],
        capture_output=True, text=True)
    if out.returncode != 0 or "NAME" not in out.stdout:
        return None
    return {l.split()[0] for l in out.stdout.splitlines()[1:] if l.split()}


def projector_mappings(ns: str, tier: str) -> list[tuple[str, str]] | None:
    """(topic, consumer_group) per projector mapping this tier renders."""
    raw = kubectl("get", "cm", "openddil-tier-projector-config-" + tier,
                  "-n", ns, "-o", "jsonpath={.data}")
    if not raw.strip():
        return None
    try:
        body = json.loads(raw)["projector_config.yaml"]
    except Exception:
        return None
    out: list[tuple[str, str]] = []
    topic = None
    for line in body.splitlines():
        s = line.strip()
        if s.startswith("- topic:"):
            topic = s.split(":", 1)[1].strip()
        elif s.startswith("consumer_group:") and topic:
            out.append((topic, s.split(":", 1)[1].strip()))
            topic = None
    return out or None


def main() -> int:
    ns = sys.argv[1] if len(sys.argv) > 1 else "openddil"
    ctx = kubectl("config", "current-context").strip()
    require_cluster(ctx)
    print("tier feed check -- namespace " + ns)
    print("  cluster: " + ctx + " (asserted)")
    print()

    ts = tiers(ns)
    if not ts:
        print("FAIL: no tier nodes found. Either none are deployed or the",
              file=sys.stderr)
        print("      selector is wrong -- refusing to report 'every rendered",
              file=sys.stderr)
        print("      consumer is fed' over zero consumers.", file=sys.stderr)
        return 1

    unfed: list[tuple[str, str, str]] = []
    checked = 0
    for tier in ts:
        topics = broker_topics(ns, tier)
        if topics is None:
            print("tier " + tier + ": BROKER PROBE FAILED -- not clean",
                  file=sys.stderr)
            return 1
        proj = projector_mappings(ns, tier)
        if proj is None:
            print("tier " + tier + ": projector config unreadable -- refusing",
                  file=sys.stderr)
            print("      to judge a tier whose rendered consumers are unknown",
                  file=sys.stderr)
            return 1

        consumers = proj + [(t, g + "-" + tier) for t, g in TIER_SUBSCRIPTIONS]
        fed = [(t, g) for t, g in consumers if t in topics]
        gap = [(t, g) for t, g in consumers if t not in topics]
        checked += len(consumers)

        print("tier " + tier + "  (" + str(len(fed)) + " fed of "
              + str(len(consumers)) + " rendered, " + str(len(topics))
              + " topics on its broker)")
        for t, g in sorted(gap):
            print("  UNFED      " + g + "   <- " + t)
            unfed.append((tier, g, t))
        print()

    if not unfed:
        print("tier feed: clean -- all " + str(checked)
              + " rendered consumers have a fed topic")
        return 0

    print("tier feed: " + str(len(unfed)) + " UNFED CONSUMER(S) of "
          + str(checked) + " rendered")
    print("  Each is a process at 1/1, subscribed to a topic its broker does")
    print("  not hold. It forms no consumer group, so the consumer census")
    print("  cannot see it, and no probe distinguishes it from working.")
    print("  Feed it or stop rendering it -- there is no third option.")
    print("  See DESIGN-2026-09-07-region-input-contract.md.")
    print()
    print("WHAT THIS DOES NOT ESTABLISH:")
    print("  * That a fed topic carries anything. A topic that exists at")
    print("    high-watermark 0 passes here and starves the consumer just")
    print("    the same.")
    print("  * That the subscription mirror above matches what the bootstrap")
    print("    registers. A drift hides a consumer from this check entirely.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
