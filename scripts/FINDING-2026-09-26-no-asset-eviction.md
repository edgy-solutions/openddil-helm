# Finding 2 — an asset, once seen on the wire, is permanent; and at work the one blunt lever that clears it is switched off

Found while restoring the lab after item 3's `1099` injection. Measured on
`edgy-lab` at revision 51, not read off code.

## What happened

Deleting `dis:1:1:1099` from the stores held for four tables and failed for the
fifth. `asset_logistics_status` was back within 60 s and kept advancing:

```
dis:1:1:1099 | updated_at 2026-09-26 15:26:27.84358+00
dis:1:1:1099 | updated_at 2026-09-26 15:27:27.88265+00   <- 60s later, still arriving
```

...while the asset's own telemetry had been frozen since `15:06:55` — twenty
minutes, against `STALE_INPUT_SECONDS=300`.

## Why — two separate mistakes, one mine and one structural

**Mine:** I had read `STALE_INPUT_SECONDS=300` as "fusion stops emitting an
asset 300 s after its last input." It is the opposite. `rules.py:834` is a
**severity rule**: past the threshold the asset acquires a DEGRADED
`stale_inputs` constraining factor, *and goes on being emitted*. The setting
makes the asset permanent-and-flagged, never absent.

**Structural:** `AssetLogistics` is a Restate Virtual Object keyed by
`asset_id` (ADR-0014). Its `on_timer` handler calls
`_recompute_and_maybe_emit(..., force_emit=True)` and then
`_schedule_next_timer(...)` unconditionally — so the object re-arms itself
every tick forever. One 144-byte PDU creates a self-sustaining emitter. The
object's own docstring already says the consequence out loud: "State is durable
across restarts (verified by Phase 3 — `restate state clear` is required to
wipe state, Kafka topic purge alone is insufficient)."

And there is **no deletion path anywhere downstream**: grepping the projector
templates and the dynamic mappings for `tombstone`, a null-value guard, or
`DELETE FROM` returns nothing. The pipeline can create and update a row. It has
no vocabulary for withdrawing one.

## Why this matters tomorrow, not just tonight

The three carrying topics are `cleanup.policy=compact`, so the last record per
key is retained indefinitely; the Virtual Object is durable; the stores have no
delete semantics. So on the work cluster, with a live COTS DIS simulator:

**Any entity that ever appears on the wire becomes a permanent row.** A
mistyped entity id in a scenario file, an entity from a neighbouring exercise
leaking in on multicast, a one-off test injection during setup — each becomes an
asset that is emitted on every cadence from then on. If it is not in
`releasability.yaml`, it is unlabelled, and the ADR-0029 completeness gate
**stays red until something removes it.**

The sharp edge: on the lab, `restate.ephemeralOnUpgrade: true` would have
cleared it as a side effect of the next upgrade. **At work that flag is false**
— it is on the lab-vs-work difference list for good reasons. So at work the
blunt lever is switched off, and the only remedies are:

1. **Declare it** in `releasability.yaml` — correct when the asset is real and
   was simply missed. Wrong when it is spurious, because it launders a mistake
   into deployment data.
2. **Clear the Virtual Object**, per the procedure below. Correct when the
   asset should never have existed.

There is no third option, and neither is in the runbook today.

## The procedure, as actually executed (three servers, in this order)

Order is not a detail. **Cancel the scheduled timer first, then clear the
state.** Clearing first lets the next tick fire against empty state, emit "No
telemetry observed for this asset yet" as DEGRADED, and reschedule — which
re-creates everything just cleared.

Admin API, Restate 1.6.2, reached from a pod that has `curl`
(`openddil-redpanda-hq-0`; the restate pods are distroless and have no shell):

```bash
S=openddil-restate-server            # then each -tier-restate-<tier>
KEY=dis:1:1:1099

# 1. find the scheduled invocation (the id changes every tick — re-read it)
curl -s -H 'Content-Type: application/json' -H 'Accept: application/json' \
  -d "{\"query\":\"SELECT id, status FROM sys_invocation \
       WHERE target_service_key='$KEY' AND status<>'completed'\"}" \
  http://$S:9070/query

# 2. cancel it
curl -X DELETE "http://$S:9070/invocations/<inv_id>?mode=cancel"

# 3. clear the object's state, per service that holds any
curl -X POST -H 'Content-Type: application/json' \
  -d "{\"object_key\":\"$KEY\",\"new_state\":{}}" \
  http://$S:9070/services/AssetLogistics/state
curl -X POST ... http://$S:9070/services/AssetCM/state

# 4. verify BOTH are empty before moving to the next server
curl ... -d "{\"query\":\"SELECT service_name, count(*) FROM state \
       WHERE service_key='$KEY' GROUP BY service_name\"}" http://$S:9070/query
```

Measured footprint of one injected asset — worth knowing because it is not one
place:

| Restate server | state keys | scheduled `on_timer` |
|---|---|---|
| `openddil-restate-server` (hq) | 5 (AssetLogistics) | 1 |
| `openddil-tier-restate-edge-01` | 7 (AssetLogistics 5, **AssetCM 2**) | 1 |
| `openddil-tier-restate-edge-02` | 0 — never saw it | 0 |
| `openddil-tier-restate-region-east` | 6 (AssetLogistics) | 1 |

All six `DELETE`/`POST` calls returned `HTTP 202`; all three servers verified to
zero state rows and zero non-completed invocations.

## Left undone, deliberately, and stated rather than hidden

**No tombstones were produced onto the three `compact` topics.** They are the
textbook way to stop a compacted topic resurrecting a key, and the reason not to
is the grep above: with no null-value handling anywhere in the projectors, a
null value is an **untested input class**, and its plausible failure — a decoder
erroring and blocking a partition — is exactly the `WEDGED` signature item 2
exists to detect. Risking that unattended, on the cluster that has to be
provably clean in the morning, buys less than it costs.

**The residue that leaves:** `telemetry-latest-state`, `asset-logistics-status`
and `asset-cm-state` still retain a last record for key `dis:1:1:1099`. It is
inert — nothing replays a compacted topic on the normal path, and the deletes
have held. It would come back only under an explicit consumer-group reset or a
store rebuilt from the topics. Clearing it properly is an attended job: produce
the tombstones while watching the projector consumer groups for a partition
that stops advancing.
