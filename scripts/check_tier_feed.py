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

# Topics a tier RECEIVES RAW rather than derives.
#
# FED IS NECESSARY AND NOT SUFFICIENT. A relayed raw topic is present on a
# parent's broker for PRESENTATION -- the leaf-under-region view, HQ's fleet
# picture -- and a detection consumer there would be deriving state for an
# asset it does not ingest. ADR-0032 §a: a tier derives only for assets it
# ingests directly; below it, it consumes derived state and never re-derives.
#
# So relayed raw topics are TERMINAL FOR DETECTION, and "does this consumer
# have a topic" becomes "does this consumer have a topic it is ENTITLED to
# derive from".
RAW_INGEST_TOPICS = {"raw-sensor-stream", "cm-events"}

# Group prefixes that constitute DETECTION. Projectors are excluded on
# purpose: projecting a relayed row into a read model is presentation, which
# is the one thing relayed raw topics are for.
DETECTION_PREFIXES = ("cm-service-", "fusion-service-")


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
        print("  kubectl config current-context > "
              + str(root / ".expected-context"),
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


def direct_ingest(ns: str, tier: str) -> bool | None:
    """Does this tier ingest directly? Read from what is DEPLOYED.

    Taken from the tier's restate-bootstrap Job rather than from chart values,
    because entitlement is a property of the running deployment and this check
    exists to catch a deployment that disagrees with intent.

    None means the Job could not be read. Not False -- defaulting an
    unreadable answer to "no direct ingest" would report every edge's silver
    consumers as unentitled, which is a false positive big enough to get the
    check switched off.
    """
    raw = kubectl("get", "job", "openddil-tier-restate-bootstrap-" + tier,
                  "-n", ns, "-o",
                  "jsonpath={.spec.template.spec.containers[*].env[?(@.name=='TIER_DIRECT_INGEST')].value}")
    v = raw.strip().strip('"').lower()
    if not v:
        return None
    return v in ("1", "true", "yes", "on")


def group_topics(ns: str, tier: str, group: str) -> set[str]:
    pod = "openddil-redpanda-" + tier + "-0"
    out = subprocess.run(
        ["kubectl", "exec", "-n", ns, pod, "--", "rpk", "group", "describe",
         group, "--brokers", "localhost:9092"],
        capture_output=True, text=True)
    if out.returncode != 0:
        return set()
    topics, seen = set(), False
    for line in out.stdout.splitlines():
        if line.startswith("TOPIC"):
            seen = True
            continue
        if seen and line.split():
            topics.add(line.split()[0])
    return topics


def unentitled_detection(ns: str, tier: str, topics: set[str]) -> list[tuple[str, str]]:
    """Detection groups ATTACHED to a relayed raw topic at a non-ingesting tier.

    Checked against the BROKER, not against the rendered set, because the
    rendered set is what should happen and this is what did. The subscription
    gate stops these being created; this is what notices if one exists anyway
    -- a hand-made subscription, a stale one the pruner missed, or a bootstrap
    that ran with the env absent before the gate landed.
    """
    if not (RAW_INGEST_TOPICS & topics):
        return []
    pod = "openddil-redpanda-" + tier + "-0"
    out = subprocess.run(
        ["kubectl", "exec", "-n", ns, pod, "--", "rpk", "group", "list",
         "--brokers", "localhost:9092"],
        capture_output=True, text=True)
    if out.returncode != 0:
        return []
    bad = []
    for line in out.stdout.splitlines()[1:]:
        parts = line.split()
        if len(parts) < 3:
            continue
        g = parts[1]
        if not g.startswith(DETECTION_PREFIXES):
            continue
        for t in sorted(group_topics(ns, tier, g) & RAW_INGEST_TOPICS):
            bad.append((g, t))
    return bad


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
    unentitled: list[tuple[str, str, str]] = []
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

        di = direct_ingest(ns, tier)
        if di is None:
            print("tier " + tier + ": TIER_DIRECT_INGEST unreadable -- refusing",
                  file=sys.stderr)
            print("      to judge entitlement from a default", file=sys.stderr)
            return 1

        # The rendered set is gated the same way the bootstrap gates it, so
        # "rendered" here means what the tier actually registers -- not the
        # full leaf topology it would register if it ingested.
        subs = [(t, g) for t, g in TIER_SUBSCRIPTIONS
                if di or t not in RAW_INGEST_TOPICS]
        consumers = proj + [(t, g + "-" + tier) for t, g in subs]
        fed = [(t, g) for t, g in consumers if t in topics]
        gap = [(t, g) for t, g in consumers if t not in topics]
        checked += len(consumers)

        print("tier " + tier + "  (" + str(len(fed)) + " fed of "
              + str(len(consumers)) + " rendered, " + str(len(topics))
              + " topics on its broker, direct-ingest="
              + ("yes" if di else "no") + ")")
        for t, g in sorted(gap):
            print("  UNFED      " + g + "   <- " + t)
            unfed.append((tier, g, t))
        if not di:
            for g, t in unentitled_detection(ns, tier, topics):
                print("  UNENTITLED " + g + "   <- " + t + " (relayed raw)")
                unentitled.append((tier, g, t))
        print()

    if not unfed and not unentitled:
        print("tier feed: clean -- all " + str(checked) + " rendered consumers"
              " have a topic they are entitled to derive from")
        return 0

    if unentitled:
        print("tier feed: " + str(len(unentitled)) + " UNENTITLED DETECTION"
              " CONSUMER(S)")
        print("  A detection consumer at a tier with no direct ingest, bound")
        print("  to a RELAYED RAW topic. It derives state for an asset it does")
        print("  not observe, competing with the tier that does, and nothing")
        print("  chooses between the two answers. This is the reachback")
        print("  inverted -- the raw data came UP rather than the consumer")
        print("  reaching DOWN -- so the consumer census calls it correct.")
        print()

    if not unfed:
        return 1

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
    print("  * That a projector on a relayed raw topic is right. Projection is")
    print("    presentation and is allowed here by design; whether a given")
    print("    read model belongs at a given tier is a separate question.")
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
