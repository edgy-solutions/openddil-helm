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
