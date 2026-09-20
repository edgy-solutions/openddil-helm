# Prediction — does the tactical-event emit path still work under revision 50?

**Written and committed BEFORE the injection.** Baseline re-measured
immediately before predicting, at `2026-09-20T02:55:16Z`.

## Why this test exists

The earlier claim — "the feed is empty because the fleet is quiet, and the
durable `last_alerted_status` proves it" — **does not discriminate.** Silence
after the `tier-cm-edge-01` restart at 15:50:18Z is predicted equally well by:

* **(a)** durable suppression working as designed, and
* **(b)** an emit path dead since revision 50.

`POST /invoke/AssetCM/observe 200` does not separate them either: 200 is the
handler returning, not an event being published. Nothing measured so far
touches the publish step. One injected transition does.

## The lever

`cli/submit_cm_event.py`, present at `/app/cli/` in the tier-cm image, with
`/proto` and `confluent_kafka` both available in that container. One CmEvent,
produced once to edge-01's `cm-events` topic — a topic that is **declared
idle (hw 0)**, so nothing else is disturbed.

```
--asset-id dis:1:1:1000 --manual-discrepancy 'CRITICAL|<desc>'
--brokers openddil-redpanda-edge-01:9092 --topic cm-events
```

## Target, and why this asset

`dis:1:1:1000` — edge-01, `originator_nation=ATL`, `releasable_to={BDR}`,
currently `CONFIG_STATUS_UNSPECIFIED` in all three stores that hold it.

It is the **single asset in the `ATL,BDR` releasability class** (the region
rollup's middle partial, 1 asset). So one transition on it is unambiguous in
the rollup and is the one event every entitled subject should see.

## The chain being tested, traced in source first

`cm-events` → `AssetCM/apply_cm_event` (group `cm-service-cm-events-edge-01`)
→ appends a `SEVERITY_CRITICAL` manual discrepancy → `_reanalyze` →
`overall_status()` returns `NOT_MISSION_CAPABLE` →
`_persist_and_emit_transitions`, whose gate is

```
current >= CONFIG_STATUS_MAJOR_DISCREPANCY and prev_alerted < MAJOR   -> "detected"
```

`current = NOT_MISSION_CAPABLE`, `prev_alerted = UNSPECIFIED (0)`, so the gate
opens. Publish goes to `CM_KAFKA_BROKERS=openddil-redpanda-edge-01:9092`.

## Predictions, by classification

| # | prediction |
|---|---|
| **1** | **DISCRIMINATING — an event is emitted at all.** cm-service logs `Alert detected for dis:1:1:1000: CONFIG_STATUS_UNSPECIFIED -> CONFIG_STATUS_NOT_MISSION_CAPABLE`. If the emit path died at revision 50, this is where it fails. |
| **2** | edge-01 `tactical_events` **14 → 15** (+1) |
| **3** | region-east **19 → 20** (+1), bridged from edge-01 |
| **4** | root **11 → 12** (+1), two hops up |
| **5** | edge-02 **3 → 3** (+0) — a different site, nothing crosses |
| **6** | type `openddil.configuration.discrepancy.detected`, subject `dis:1:1:1000`, source `/openddil/cm-service`, severity `CONFIG_STATUS_NOT_MISSION_CAPABLE`, `edge_id=edge-01` |
| **7** | the row carries `originator_nation=ATL`, `releasable_to={BDR}` — ADR-0029 labels on the event, which is what HEAD `7fea8b5` added |
| **8** | `asset_cm_state` for `dis:1:1:1000` flips `UNSPECIFIED → NOT_MISSION_CAPABLE` in all three stores |
| **9** | **subjects who see it:** Ada (ATL, by originator), Bram (BDR, by releasable_to), Rhea and the liaison (ATL,BDR). `observer.unlisted` does not. The one asset all four entitled subjects share. |
| **10** | **the region rollup does NOT move.** `region_fleet_summary` counts LOGISTICS severity; CM status is the orthogonal axis (ADR-0026). Lower confidence than the rest, and stated precisely so it can be wrong. |

## Failure modes, kept distinguishable

Stated in advance so a null result cannot be read as whatever is convenient:

* **VO state absent** → `apply_cm_event` logs `Dropping CM event for unknown
  asset dis:1:1:1000` and returns. +0 everywhere, but with a *named* cause.
  Not evidence about the emit path either way; the test would have to be
  re-aimed, not reinterpreted.
* **Computed but not published** → the `Alert detected` log line appears and
  the row deltas are all +0. That isolates the break to the publish step
  rather than the handler, and it is exactly the case `200` could not see.
* **Published but not projected** → `tactical-events` high-watermark on the
  edge-01 broker advances while edge-01's store stays at 14. Breaks the
  projector, not cm-service.

## What this does NOT establish

That the fleet generates transitions on its own. It establishes the path from
a transition to four stores. **Whether the sim still drives assets across
thresholds unattended is a separate question and this test does not answer
it** — it injects the transition rather than waiting for one.
