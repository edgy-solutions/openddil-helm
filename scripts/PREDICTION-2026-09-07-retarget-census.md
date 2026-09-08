# Expected consumer census AFTER the bridge retarget

Written **before** the deploy, from the rendered chart and the measured
pre-state. Confirmed after. If any line below is wrong, the step did
something other than what it was understood to do.

## What this step is, exactly

Promoting `region-east` into `tierNode.tiers` and deploying. The render diff
is **28 new objects, 0 removed, 3 changed** — and of the three, one is a
trailing-newline artifact. The two real changes are one line each:

    edge-01 bridge output:  openddil-toxiproxy:8474  ->  openddil-redpanda-region-east:9092
    edge-02 bridge output:  openddil-toxiproxy:8474  ->  openddil-redpanda-region-east:9092

The 28 new objects are region-east's whole tier node: its own broker, pg,
restate, projector, fusion, cm, electric, pep, topaz, frontend, and the
uplink bridge region-east -> HQ (via toxiproxy, which keeps the severable
link at the top of the subtree where it now belongs).

**This is more than "the retarget".** Promotion is what makes
`openddil.bridgeTarget` resolve to the region at all, so the tier node and
the retarget necessarily land together. Saying so plainly because "one line
per edge" describes the diff and badly misdescribes the deploy.

## THE SIX REACHBACKS DO NOT MOVE

They retire with the **cutover**, not this step. The retarget changes where
each edge bridge *publishes*; it does not touch the root-side components that
read edge brokers directly. Predicting six after is not predicting failure —
predicting fewer would be predicting something this step does not do, and
would quietly launder the cutover's work into the retarget's result.

## Per broker

### edge-01 — tier-managed — **3 REACHBACK, 20 stable**
    REACHBACK  asset-registry-edge-01
    REACHBACK  logistics-sim-edge-01
    REACHBACK  region-region-east-source-edge-01
    ok         bridge-group-edge-01, connect-dis-mapper,
               7 restate groups, 8 tier-projector-*-edge-01
    residue    up to 4 Empty bare projector-* (fewer is broker expiry, not a change)

### edge-02 — tier-managed — **3 REACHBACK, 20 stable**
Same shape; residue up to 1.

### edge-03 — untier-ed — **rule N/A, 23 stable, 14 root-correct**
**Unchanged in every respect.** Its bridge still falls back to toxiproxy
because region-west is not tier-managed. If edge-03 moves at all, the
fallback path was disturbed by a change that had no business reaching it.

### region-east — tier-managed — **0 REACHBACK, 16 groups**
    8  tier-projector-{capability,cm-state,element-inventory,
       element-telemetry,logistics-status,tactical-events,
       telemetry-latest,windows}-region-east
    7  restate subscriptions: cm-service-cm-events-, cm-service-silver-,
       fusion-service-{capability,derived,silver,windows}-, openddil-
    1  uplink-group-region-east
    -  NO connect-dis-mapper: a region has no DIS ingress
    -  NO bridge-group-region-east: edges bridge, regions uplink

**Total: 4 brokers, 6 reachbacks, region-east clean.**

## What a wrong outcome looks like

* **region-east shows ANY reachback** — a root component followed the data
  up. That is the second home for UD-10 opening exactly as feared, and it is
  the single most important line in this file.
* **region-east shows 0 groups** — the tier node did not start. The census
  prints "broker idle or unreachable, NOT proof of a clean census"; that note
  is a failure, not a pass, and 0 reachbacks over 0 groups is vacuous.
* **edge-01/02 reachbacks != 3** — something attached or retired that this
  step does not touch.
* **edge-03 differs at all** — see above.
* **a `bridge-group-edge-0N` missing** — the bridge died rather than
  retargeted. The config checksum annotation should roll it; a rolled bridge
  reappears, a broken one does not.

## Two consequences worth stating

**`raw-sensor-stream` stops reaching HQ from edge-01/02.** The edge bridge
carries it; the uplink does not forward it, so it now terminates at the
region. Measured before deciding this was acceptable: **zero** consumer
groups on the HQ broker read `raw-sensor-stream` (all 16 HQ groups
enumerated and described). So it costs nothing today — but it is a real
change in what HQ receives, and it is recorded here rather than discovered
later.

**Everything else now reaches HQ through two hops instead of one, unstamped.**
`asset-logistics-status`, `asset-cm-state`, `telemetry-latest-state` and
`tactical-events` travel edge -> region -> HQ. Until `relay_chain` is stamped
at the bridges, HQ cannot tell a quiet edge from a downed region uplink. That
is the gap DESIGN-2026-09-07-two-hop-freshness.md exists to close, and this
deploy is the step that opens it.
