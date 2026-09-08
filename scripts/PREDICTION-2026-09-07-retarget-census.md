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

---

# CONFIRMED 2026-09-07 — nine of ten lines, and one instructive miss

| prediction | measured | |
|---|---|---|
| 6 reachbacks, unchanged | **6** | correct |
| edge-01: 3 reachback / 20 stable | 3 / 20 | correct |
| edge-02: 3 reachback / 20 stable | 3 / 20 | correct |
| edge-03: unchanged, 23 stable, 14 root-correct | 23 / 14 | correct |
| residue 4 (edge-01) + 1 (edge-02) | 4 + 1 | correct |
| region-east: **0 reachback** | **0** | correct |
| no `connect-dis-mapper`, no `bridge-group-` on region-east | absent | correct |
| 4 brokers enumerated | 4 | correct |
| region-east: **16 groups** | **8 (7 stable)** | **WRONG** |

## The miss, and what it actually shows

Predicted by structural parallel with a leaf tier: 8 projectors + 7 restate
subscriptions + 1 uplink. Measured 8 groups, of which the four projectors are
exactly `cm-state`, `logistics-status`, `tactical-events`, `telemetry-latest`.

Those are exactly the four topics the bridge carries upward. The region's
broker holds five topics; a leaf holds twenty-seven. The missing consumers —
`capability`, `element-inventory`, `element-telemetry`, `windows`, and most
of the restate subscriptions — are subscribed to topics that do not exist on
this broker, so they never form a group.

**The finding is not the number, it is what the number means.** A region's
tier node renders the FULL leaf topology and only the subset whose inputs
the bridge carries can attach. The rest are running processes with nothing to
read. That is survivable now — the region relays and projects rather than
computing — but it is a standing mismatch between what the tier node deploys
and what a tier at this depth is fed, and the cutover has to face it: moving
`faust-regional` into the region means the region will need inputs it is not
currently sent.

## Two corrections to the record

**The high-watermark numbers cited while diagnosing the checksum bug were
read from the wrong column.** `rpk topic describe -p` puts LOG-START-OFFSET
at `$5` and HIGH-WATERMARK at `$6`; the "high-watermark 0 on all four topics"
in the checksum-fix commit message was `$5`. The conclusion was independently
established and stands — the bridge pods were 2d8h old, the active ReplicaSet
predated the upgrade, and both renders produced byte-identical checksums —
but that one line of corroboration was misread and should not be cited.
Correct figures after the fix: region-east advancing on all five topics
(raw-sensor-stream 387->425, telemetry-latest-state 389->425, asset-cm-state
750->844, asset-logistics-status 69->75 over 14 seconds), uplink consuming
with lag 2-3.

**Group counts fluctuate between runs.** Three consecutive censuses gave
region-east 6, then 8 groups, and edge-01 briefly showed a
`fusion-service-cm-state-edge-01` that was gone on the next run. Consumers
attach and rebalance. The REACHBACK count was stable at 6 across every run;
the totals were not. So a count is a weaker assertion than a classification,
and predictions should be stated about classifications where possible.

## One-time rollout note

All three bridges rolled, including edge-03, which was predicted not to.
Switching the checksum from a hand-listed tuple to a hash of the rendered
config changes every checksum once. The prediction that edge-03 must not roll
is about before/after under the SAME scheme, and it was verified that way at
render time. The one-time roll is the cost of the fix, not a regression.
