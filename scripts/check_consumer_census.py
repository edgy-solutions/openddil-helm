#!/usr/bin/env python3
"""check_consumer_census.py — who is reading whose broker?

THE RULE, and it is UD-10's rule generalised to a tree:

    NO CONSUMER ABOVE A TIER READS THAT TIER'S BROKER.
    A parent consumes its child's DERIVED state, through the bridge.

UD-10 was two detection planes sharing a consumer group on one broker: the
tier froze while reporting healthy, and INVERTED under severance so it
worked only while cut. UD-11 was the same disease in the projection plane,
invisible to a severance test because the projector bypassed the proxy the
sever used.

A region introduces a SECOND HOME for that trap. Once edges bridge to a
region rather than to HQ there are two boundaries a root-owned consumer can
sit across instead of one, and from HQ the failure looks identical: fresh
data, no error, and a tier that is not actually authoritative for its own
subtree.

WHY A CENSUS RATHER THAN A SEVER. A sever proves something about the paths
it cuts. This enumerates every consumer on every tier broker and asks who
owns it, so a path nobody thought to cut still shows up. The two are
complements: the census finds the reachback, the sever proves the cut.

⚠ GROUP NAMES ARE NOT OWNERSHIP. A tier's own Restate subscriptions use
unsuffixed `cm-service-*` / `fusion-service-*` ids — the same names the root
would use — so a prefix test reads them as root-owned. Ownership is decided
by KNOWN ROOT-OWNED PREFIXES, which were established by client library and
topic rather than by name (that census corrected "four reachbacks" to six).

TWO HOLES FOUND BY RUNNING IT, 2026-09-07, both in its own subject matter:

  1. WHICH CLUSTER. Bare `kubectl` follows current-context, which on this
     workstation is a different k3s cluster with no `openddil` namespace.
     The first run reported "no per-tier brokers found" -- the same shape a
     torn-down deployment produces. The cluster is now printed on every run
     and named in that failure. This matters most for the scripts that
     WRITE: `sever-tier.sh` applies NetworkPolicies.

  2. `projector-` WAS UNCLASSIFIED, so a root downward projector reattached
     to a tier broker would have printed `ok` -- a false clean in precisely
     the condition this file exists to detect. It was masked because the
     five surviving bare-projector groups are all Empty, and only Stable
     groups are judged: the evidence that the UD-11 repoint had WORKED was
     what hid the hole. Found by asking the broker whether those groups
     existed, not by reading this script's output.


WHY PYTHON. This began as bash. Three separate constructs — `mapfile` from a
multi-line process substitution, a `while read` fed by one, and an outer loop
containing `kubectl exec` — each misbehaved from inside the script while
behaving correctly in an interactive shell, and EVERY failure presented as a
clean census. A check whose parse can fail into "pass" is the defect this
file exists to detect, so it is written in the language whose parsing is
observable.
"""
from __future__ import annotations

import os
import pathlib
import subprocess
import sys

# ORDER MATTERS: LOCAL is tested first, so `tier-projector-*` resolves local
# via `tier-` before `projector-` can claim it. That is not incidental — the
# two differ by prefix alone and mean opposite things.
LOCAL_PREFIXES = ("connect-", "bridge-", "uplink-", "tier-", "openddil-")

# `projector-` was MISSING here until 2026-09-07, and the omission sat in the
# check's own subject matter: a root downward projector reattached to a tier
# broker would have printed `ok`. It was invisible because the five surviving
# bare-projector groups are all Empty (see RESIDUE below) and only Stable
# groups are judged — so the hole was masked by the very evidence that the
# repoint had worked. Found by probing whether the groups existed at all
# rather than by reading the census output, which is the only way it could
# have been found.
ROOT_OWNED_PREFIXES = ("region-", "asset-registry-", "logistics-sim-",
                       "projector-")


def kubectl(*args: str) -> str:
    out = subprocess.run(["kubectl", *args], capture_output=True, text=True)
    return out.stdout


def brokers(ns: str) -> list[str]:
    raw = kubectl("get", "sts", "-n", ns, "-o",
                  "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    return [b for b in raw.split()
            if "redpanda-" in b and not b.endswith("redpanda-hq")]


def groups(ns: str, sts: str) -> list[tuple[str, str]]:
    raw = kubectl("exec", "-n", ns, f"{sts}-0", "--",
                  "rpk", "group", "list", "--brokers", "localhost:9092")
    out = []
    for line in raw.splitlines()[1:]:
        parts = line.split()
        if len(parts) >= 3:
            out.append((parts[1], parts[2]))
    return out


def tier_managed(ns: str) -> set[str]:
    """Tiers that actually have a tier node deployed.

    THE RULE APPLIES ONLY TO THESE. An untier-ed edge has no local
    detection plane, so the root reading its broker is not a reachback —
    it is the only thing reading it, and that is today's correct topology.
    Flagging it would make the check cry wolf on every deployment that has
    not finished tiering, which is every deployment during the migration
    this check exists to supervise.

    Read from the cluster (a tier-pg StatefulSet per tier) rather than from
    chart values, because what is DEPLOYED is the thing the census is about.
    """
    raw = kubectl("get", "sts", "-n", ns, "-o",
                  "jsonpath={range .items[*]}{.metadata.name}{\"\\n\"}{end}")
    out = set()
    for name in raw.split():
        if "-tier-pg-" in name:
            out.add(name.split("-tier-pg-", 1)[1])
    return out


def owner_of(group: str) -> str:
    """'ROOT' when a component above the tier owns it, else 'local'."""
    for p in LOCAL_PREFIXES:
        if group.startswith(p):
            return "local"
    for p in ROOT_OWNED_PREFIXES:
        if group.startswith(p):
            return "ROOT"
    return "local"


def which_cluster() -> tuple[str, str]:
    """The context and API server this run will actually talk to.

    WHY THIS IS PRINTED AND NOT ASSUMED. Bare `kubectl` resolves against
    whatever ~/.kube/config names as current-context, and on this workstation
    that is NOT the cluster OpenDDIL runs on: the default context is a
    different k3s cluster with no `openddil` namespace at all. The first run
        print(f"FAIL: no per-tier brokers found in {ns} on context '{ctx}'.",
              file=sys.stderr)
        print("      THREE different causes share this one shape: the wrong",
              file=sys.stderr)
        print("      CLUSTER, a torn-down deployment, or a broken selector.",
              file=sys.stderr)
        print("      Check the cluster line above FIRST -- bare kubectl uses",
              file=sys.stderr)
        print("      current-context, which is not necessarily the lab.",
              file=sys.stderr)
        print("      Refusing to report an empty census as a clean one.",
              file=sys.stderr)
    A read against the wrong cluster wastes a minute. A WRITE against the
    wrong cluster breaks the standing ground rule, and `sever-tier.sh`
    applies NetworkPolicies. So the cluster stops being inherited and starts
    being stated: every run prints where it went.
    """
    ctx = kubectl("config", "current-context").strip() or "(none)"
    server = kubectl("config", "view", "--minify", "-o",
                     "jsonpath={.clusters[0].cluster.server}").strip()
    return ctx, server or "(unknown)"


def require_cluster(ctx: str) -> None:
    """Refuse to run against a cluster nobody named.

    The bash counterpart is lib/require-cluster.sh and the reasoning lives
    there. Duplicated rather than shelled out to, because a Python script
    that invokes a bash guard to decide whether Python may proceed has two
    ways to fail open instead of one.

    UNSET IS A REFUSAL, not a default. Falling back to "whatever is current"
    would restore the exact behaviour this exists to remove, while looking
    like a guard.
    """
    root = pathlib.Path(__file__).resolve().parent.parent
    expect = os.environ.get("OPENDDIL_EXPECT_CONTEXT", "").strip()
    if not expect:
        f = root / ".expected-context"
        if f.is_file():
            expect = f.read_text(encoding="utf-8").strip()

    err = lambda m: print(m, file=sys.stderr)

    if not expect:
        err("REFUSING TO RUN: no expected kube-context is declared.")
        err("  This script reads a cluster, and which cluster is not")
        err("  something it will infer from current-context.")
        err("  Declare it once:")
        err("      echo edgy-lab > " + str(root / ".expected-context"))
        err("  or per-invocation: OPENDDIL_EXPECT_CONTEXT=<ctx> ...")
        raise SystemExit(78)

    if not ctx or ctx == "(none)":
        err("REFUSING TO RUN: kubectl reports no current-context.")
        err("  Expected " + expect + ". An empty context matches nothing;")
        err("  it is a kubeconfig that cannot answer.")
        raise SystemExit(78)

    if ctx != expect:
        err("REFUSING TO RUN: wrong cluster.")
        err("    expected context : " + expect)
        err("    current context  : " + ctx)
        err("  Nothing has been read. This census once ran against a")
        err("  cluster with no openddil namespace and reported 'no")
        err("  per-tier brokers found' -- a sentence indistinguishable")
        err("  from a torn-down deployment. That is what this prevents.")
        raise SystemExit(78)


def main() -> int:
    ctx, server = which_cluster()
    require_cluster(ctx)
    ns = sys.argv[1] if len(sys.argv) > 1 else "openddil"
    print(f"consumer census — namespace {ns}")
    print(f"  cluster: {ctx}  ({server})")
    print()

    bs = brokers(ns)
    if not bs:
        print("FAIL: no per-tier brokers found. Either the deployment is not "
              "up or the selector is wrong — refusing to report an empty "
              "census as a clean one.", file=sys.stderr)
        return 1

    managed = tier_managed(ns)
    # WHY THIS LINE IS PRINTED. The rule is scoped to tier-managed tiers, so
    # the scope IS part of the result: "clean" over an empty managed set is
    # the vacuous pass again, one level up. Print what was in scope.
    managed_str = ", ".join(sorted(managed)) or "(none)"
    print("tier-managed: " + managed_str)
    print()

    reachbacks: list[tuple[str, str]] = []
    for sts in bs:
        tier = sts.split("redpanda-", 1)[1]
        gs = groups(ns, sts)
        stable = [g for g, state in gs if state == "Stable"]
        # RESIDUE. A group with no members survives its consumer, holding the
        # committed offsets until the broker expires it. For a root-owned
        # group on a tier broker that is POSITIVE evidence: the reachback was
        # retired and left its offsets behind. Dropping it silently would
        # discard the only on-broker trace that a retirement happened, so it
        # is printed — as corroboration, never as a pass.
        residue = [g for g, state in gs
                   if state != "Stable" and owner_of(g) == "ROOT"]
        scope = "tier-managed" if tier in managed else "untier-ed — rule N/A"
        print(f"broker {tier}  ({len(stable)} stable of {len(gs)} groups)  [{scope}]")
        if not gs:
            print("  note: no groups read — broker idle or unreachable, "
                  "NOT proof of a clean census.")
            continue
        for g in sorted(stable):
            if owner_of(g) == "ROOT" and tier in managed:
                print(f"  REACHBACK  {g}")
                reachbacks.append((tier, g))
            elif owner_of(g) == "ROOT":
                print(f"  root       {g}   (correct — no tier node here)")
            else:
                print(f"  ok         {g}")
        for g in sorted(residue):
            print(f"  residue    {g}   (root-owned, no members — retired)")
        print()

    if not reachbacks:
        print("consumer census: clean — no root-owned consumer on a tier broker")
    else:
        print(f"consumer census: {len(reachbacks)} REACHBACK(S)")
        print("  Each is a component running ABOVE a tier, reading that "
              "tier's broker directly. That is UD-10/UD-11's condition: it "
              "works, it looks healthy, and it makes the tier "
              "non-authoritative for its own subtree.")
    print("\nWHAT THIS DOES NOT ESTABLISH:")
    print("  * That the bridges carry what the parent needs. A clean census "
          "with a silent bridge is a subtree HQ cannot see.")
    print("  * That an absent consumer is retired. An Empty root-owned "
          "group is now printed as residue, so a retirement that COMMITTED "
          "leaves a trace -- but a consumer that never committed, or whose "
          "group has aged out, leaves none, and reads as clean here.")

    # A slice edit removed this line once, and main() then fell off
    # the end returning None: SIX reachbacks reported, exit 0. The
    # finding and the verdict must not be able to disagree.
    return 1 if reachbacks else 0


if __name__ == "__main__":
    raise SystemExit(main())
