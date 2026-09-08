# Expected state AFTER the cutover — by classification, not by count

Written before the deploy. Counts wander with rebalances; classifications do
not, which is why the assertions below are about what each consumer IS.

## What this step does

1. The edge -> region bridge carries **six more topics**, so every consumer
   region-east renders has an input (`asset-capability-snapshot`,
   `asset-telemetry-windows`, `asset-element-telemetry`,
   `asset-element-inventory`, `derived-sustainment`, `asset-registry-events`).
   `cm-events` is deliberately NOT among them: it is a raw ingest topic, the
   region's `cm-service-cm-events` subscription is gated off, so nothing there
   would read it.
2. The region -> HQ uplink carries **three more** (`region-fleet-summary`,
   `region-top-factors`, `region-wear-trends`) — what the relocated
   aggregator produces, which HQ's projectors already read.
3. `faust-regional` for region-east points **both** of its source addresses at
   the region's own broker instead of at each edge and HQ.

## Consumer census — by classification

* **edge-01, edge-02** — `region-region-east-source-edge-0N` **is gone from
  both**. That is the cutover's whole point: the aggregator stops reaching
  down. Each edge retains exactly two reachbacks, `asset-registry-edge-0N`
  and `logistics-sim-edge-0N`, which are separate root-side components and
  retire on their own terms. **Six becomes four, not zero** — claiming zero
  here would be claiming work this step does not do.
* **edge-03** — untier-ed, rule N/A, unchanged in every respect.
* **region-east** — **zero reachbacks**, and specifically: the two aggregator
  groups that now appear here (`region-region-east-source-region-east`,
  `region-region-east-hq-source`) must classify as **local, not ROOT**.
  A bare prefix test calls them reachbacks and reports the cutover as having
  made things worse; ownership is relative to the broker, and a group naming
  the tier it sits on belongs to that tier. This was caught by predicting the
  census before running it, which is the only reason it was caught before it
  produced two confident false positives.
* **Two Empty residue groups** (`cm-service-silver-region-east`,
  `fusion-service-silver-region-east`) persist until the broker expires them.
  Residue, not violations — the trace that the retirement happened.

## Feed check — by classification

* **edge-01, edge-02** — every rendered consumer fed, direct-ingest **yes**.
* **region-east** — every rendered consumer fed, **zero unentitled**,
  direct-ingest **no**. Twelve rendered (eight projectors, four
  subscriptions), and after the six new topics land, twelve fed.

## What a wrong outcome looks like

* **A reachback on region-east** — a root component followed the data up, or
  the ownership rule is wrong.
* **`region-region-east-source-edge-0N` still present** — the aggregator did
  not take its new env, which after this month means: ask the pod what it
  holds before believing anything else.
* **HQ's regional views empty** — the uplink is not carrying the rollups, or
  the aggregator is not producing them to the region broker.
* **An unfed consumer at region-east** — a topic in the input set is not
  actually arriving; a topic that exists at high-watermark 0 passes the feed
  check and starves the consumer just the same.

---

# CONFIRMED 2026-09-08 — census exact, feed check short, and the reason matters

## Consumer census: every classification as predicted

    edge-01     REACHBACK asset-registry-edge-01, logistics-sim-edge-01
                residue   region-region-east-source-edge-01  (retired)
    edge-02     REACHBACK asset-registry-edge-02, logistics-sim-edge-02
                residue   region-region-east-source-edge-02  (retired)
    edge-03     untier-ed, rule N/A, unchanged
    region-east ZERO reachbacks

    consumer census: 4 REACHBACK(S)          six became four, as predicted

The reachbacks the cutover targeted did not merely disappear — they appear as
**residue**, Empty groups holding their last committed offsets. That is the
on-broker trace that a retirement happened rather than a consumer that was
never there, and it is why the residue distinction was worth restoring.

And the three aggregator groups now on region-east's own broker —
`region-region-east-aggregator`, `-hq-source`, `-source-region-east` — all
classify **local**. Under the old bare-prefix rule every one of them would
have read as a reachback and the cutover would have scored as a regression on
the tier it just cleaned. Predicting by classification is what caught that;
a prediction by count would have said "fewer than six" and passed.

The relocated aggregator's outputs reach HQ: `region-fleet-summary` at
79031 with `projector-region-fleet-summary` at **lag 0**.

## Feed check: predicted 12 of 12, measured 8 of 12

Wrong, and the cause is upstream rather than in this step.

    UNFED  fusion-service-capability-region-east      <- asset-capability-snapshot
    UNFED  tier-projector-capability-region-east      <- asset-capability-snapshot
    UNFED  tier-projector-element-inventory-region-east <- asset-element-inventory
    UNFED  tier-projector-element-telemetry-region-east <- asset-element-telemetry

Those three topics were added to the bridge and the bridge IS subscribed to
them — they appear in `bridge-group-edge-01` with lag `-`. They are **empty at
edge-01 itself**: `asset-capability-snapshot`, `asset-element-telemetry`,
`asset-element-inventory` all sit at high-watermark **0** on the edge broker.
A bridge cannot carry what was never produced, and a topic nothing produced to
is never created at the destination.

**So the input contract is satisfied by configuration and not by data.** Four
pipelines are idle FLEET-WIDE, not merely at the region — and the feed check
reports edge-01 as 15 of 15 because the topics EXIST there at watermark 0.
That is precisely the caveat the check prints about itself: *a topic that
exists at high-watermark 0 passes here and starves the consumer just the
same.* The caveat was written before it was needed and then it was needed.

Two of the six new topics did materialise empty at the region
(`asset-telemetry-windows`, `asset-registry-events`, both hw 0), so their
consumers count as fed while being equally starved. **Fed is not flowing**,
and the gap between those two words is now the honest description of four
consumers this check calls green.

`derived-sustainment` is the one that flowed: 587,950 messages at the region
within a minute of the cutover — which is the topic the reachback existed to
fetch.

## What this leaves

* **Four reachbacks remain** — `asset-registry-edge-0N` and
  `logistics-sim-edge-0N`, root-side components that retire on their own
  terms. Predicting zero would have claimed work this step does not do.
* **Four consumers unfed, upstream** — whether an idle
  `asset-capability-snapshot` is expected for this scenario or a defect in
  what the edge produces is a question for the edge, not the bridge. Named
  here rather than absorbed into "the cutover is done".
* **`raw-sensor-stream` is now carried to the region for no consumer.** After
  the detection gate, the only groups touching it there are the two Empty
  retired ones. It is the highest-volume topic on the wire (3.78M at edge-01)
  crossing a DDIL link for nobody. Removing it is a separate change with its
  own verification — the same topic list feeds edge-03 -> HQ — and is
  recorded rather than folded in here.
