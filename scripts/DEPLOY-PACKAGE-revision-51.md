# Deploy package — revision 51

**Nothing here has been executed against any cluster.** No `helm upgrade`, no
`kubectl`, no query. The chart renders and diffs below were produced locally
from the repository; every number attributed to the cluster is a *prediction*
carried forward from the ledger, and every one of them has a check-back query
so it is settled by measurement rather than by argument afterwards.

Baseline is **helm revision 50**, deployed 2026-09-19 from chart
`openddil-demo-0.1.56` at `openddil-helm@d43e9ef`. Target is
`openddil-demo-0.1.57` at `openddil-helm@dae37c8`.

---

## 0. Read this first — the three things that decide the deploy

**(a) This is a full-stack rolling restart, not a two-pod change.**
`helm.sh/chart` is in the pod template label set of **95 of the chart's 96
workloads**. The version bump 0.1.56 to 0.1.57 changes that label, which
changes every pod template, which rolls every workload. The values diff is
tiny and the blast radius is total; those two facts are not connected, and
reading the first as evidence for the second is the mistake this section
exists to prevent.

That matters because of UD-14: the helm rollout is the trigger that preceded
the 3.5-hour wedge and had never been watched. Revision 50 was the first one
watched — 92 group-on-broker rows, eight clean samples over 1h43m, 0 wedged.
Revision 51 is the second opportunity, and a bigger one, because it restarts
more.

**(b) If the lab does not pass `restate.ephemeralOnUpgrade: true`, the wipe
silently does not happen.** The default is now false. Rendered and counted:
the rev-50 chart emits 11 `restate-wipe` lines with the lab values; the
rev-51 chart with the same values emits **0**. Handler-code changes between
deploys then meet Virtual Object journals written by the old code, which is
`VMException(570)` on every event for those assets — and it arrives as data
that stops moving, not as an upgrade that failed.

This is the first deploy where that flag has to be passed. Passing it
restores the exact revision-50 behaviour; the change is to what happens when
nobody decides, not to what happens when somebody does.

**(c) dis-sim now needs its image on the nodes before it will start.**
`openddil/dis-sim:1.0` is built by `tools/dis-sim/build.sh --load`, and there
is no registry behind the name. Without it the simulator pods
ImagePullBackOff, no DIS traffic is produced, and **the relabel predictions in
section 2 cannot be checked at all** — they are all downstream of assets
emitting. Build and load before `deploy.sh`, not after noticing.

---

## 1. Values diff, 50 to 51

Two commits touch the chart. The complete substantive diff:

### 1.1 `restate.ephemeralOnUpgrade: true` to `false` (dae37c8)

```diff
-  ephemeralOnUpgrade: true
+  ephemeralOnUpgrade: false
```

Everything else in that hunk is comment. The reasoning is recorded in the
values file itself and in `PILOT-RUNBOOK.md` section 3, which now carries the
explicit lab setting.

**One trap, stated because the two blocks look alike:** the key is
**top-level `restate:`**, not `tierNode.restate`. Setting it under `tierNode`
does nothing at all, silently, and presents exactly as (b) above.

### 1.2 `tierNode.postgres.image` gains digest/pullPolicy (792febe)

```diff
       repository: postgres
       tag: "15"
+      digest: ""
+      pullPolicy: IfNotPresent
```

Empty digest renders `repo:tag`, identical to revision 50. This is a
capability, not a change: it is the one image block that previously had
nowhere to put a digest.

### 1.3 The template change with an actual effect (792febe)

Six tier-node call sites now pass the image block to
`openddil.thirdPartyImage` instead of taking it apart first, so a tier's
digests are read. Five image references change:

| workload | rev 50 | rev 51 |
|---|---|---|
| `tier-topaz-edge-01` | `topaz:0.33.16` | `topaz@sha256:835868c0...` |
| `tier-topaz-edge-02` | `topaz:0.33.16` | `topaz@sha256:835868c0...` |
| `tier-topaz-edge-03` | `topaz:0.33.16` | `topaz@sha256:835868c0...` |
| `tier-topaz-region-east` | `topaz:0.33.16` | `topaz@sha256:835868c0...` |
| `tier-topaz-region-west` | `topaz:0.33.16` | `topaz@sha256:835868c0...` |
| `topaz-hq` (root) | `topaz@sha256:835868c0...` | unchanged — already honoured |

**The one thing not verifiable from here:** that `sha256:835868c0...` *is* tag
`0.33.16`. The root has run this digest since it was pinned, so the risk is
low, but it has never been the tier's image. If the digest resolves to a
different build, five tier authorizers change behaviour at once. `topaz-hq` is
the control: it already runs this digest, so a tier that disagrees with HQ
after the deploy is the signal.

### 1.4 Rendered diff, in full

At lab values (`releasability`, `tierNode`, `sensorIngest.externalAccess` on,
wipe explicitly true), rev-50 and rev-51 renders are both 17,448 lines and
differ in exactly two ways: the `helm.sh/chart` label, everywhere, and the
five Topaz references above. **No resource is added or removed. No schema
migration is implied by the chart.**

---

## 2. Every predicted delta already in the ledger

One table, one check-back each. Sources:
`openddil-contracts/decisions/FOLLOW-UPS.md`, rows "the next deploy relabels
two simulated assets" (2026-09-21) and "before the SISO-aligned tuples deploy"
(2026-09-21).

Every row is **a prediction from reading code**. None has been measured.

| # | predicted delta | expected | check-back query |
|---|---|---|---|
| 1 | **Relabels: 2.** `dis:1:1:1004` and `dis:2:1:1004` move RCV-M to AH-64E-V6 | exactly 2 ids differ from rev 50; no others | `SELECT asset_id, platform_variant FROM telemetry_latest_state ORDER BY asset_id;` — diff against the rev-50 snapshot |
| 2 | **Fleet size unchanged: 14 to 14** | 14 | `SELECT count(*) FROM telemetry_latest_state;` |
| 3 | **Per variant: RCV-M 2 to 0, AH-64E-V6 2 to 4**, all others unchanged | as stated | `SELECT platform_variant, count(*) FROM telemetry_latest_state GROUP BY 1 ORDER BY 1;` |
| 4 | **CM baseline mismatches: 0.** `dis:1:1:1001`, `dis:1:1:1006`, `dis:2:1:1001` keep M1A2-SEPv3 / UH-60M / M1A2-SEPv3; the two relabelled ids have no baseline | 0 | `SELECT asset_id, baseline_id, platform_variant FROM asset_cm_state WHERE baseline_id IS NOT NULL;` |
| 5 | **Wear clears: 1.** `dis:1:1:1004` was CRITICAL at rev 50 on a fully-consumed RCV-M track; AH-64E-V6 declares `[engine, barrel]` and no track | region critical count **2 to 1** | region rollup critical count; if 1004 is still CRITICAL, read *which factor* drives it before narrating anything |
| 6 | **`dis:2:1:1004` clears nothing** — it was not CRITICAL | unchanged | same query as 5 |
| 7 | **Releasability unchanged** — declared per id, not per platform | no change | `SELECT originator_nation, releasable_to, count(*) FROM telemetry_latest_state GROUP BY 1,2;` |
| 8 | **Display unchanged** — both ids showed the Unknown badge as RCV-M and still do as AH-64E-V6; the schematic registry keys `AH-64E`, not `AH-64E-V6` | Unknown badge, before and after | visual, or the registry key list |
| 9 | **All 14 ids change their raw DIS tuple** (SISO-REF-010-v37); the ontology resolves each new tuple to the variant it already had | variant names stable, tuples all new | `SELECT DISTINCT dis_entity_type FROM telemetry_latest_state;` against the current ontology |
| 10 | **`asset-logistics-status` keeps earlier tuples indefinitely** where an asset stops emitting — compacted, retention -1 | count reaches 0 once every live asset re-emits | count records whose tuple is not in the current ontology; re-count after a full emission cycle |
| 11 | **`ingress-dis-raw` ages out within 24h**; a replay before then resolves earlier tuples to `_default`, giving UNKNOWN | 0 after 24h | topic age / replay check, only if replaying |
| 12 | **`tactical_events`, `region_fleet_summary` unaffected** — neither carries a tuple nor groups by variant | no change | row counts before/after |
| 13 | **Restate `AssetLogistics.latest_telemetry_dict` discards tuple+variant only where the wipe actually fires** | discarded if and only if the section 0(b) flag was passed | see 2.1 below |

### 2.1 The row that changed meaning this week

Row 13 was written when `ephemeralOnUpgrade` defaulted to **true**, so "where
the wipe actually fires" meant "everywhere". After 1.1 it means "where
somebody passed the flag". The ledger row is still correct as written, and its
*answer* is now a deploy-time decision rather than a property of the chart.

If the flag is not passed, rows 9 and 13 diverge: stored tuples are
re-resolved in postgres while Restate keeps per-asset state written under the
earlier ontology **and** under earlier handler code. That divergence is not
visible in any of the queries above — it shows up as events that stop being
processed for particular assets, which is why section 0(b) is a pre-deploy
checklist item rather than a post-deploy check.

### 2.2 One ledger row this deploy partially closes

`OPEN 2026-09-23 — the DIS fixture reaches PyPI at container start`. Its close
list item 2 was "bake generator and dependency into one small image". The
**dependency** is now baked (`tools/dis-sim/Dockerfile`, verified by importing
`opendis` under `--network none`); the **generator** deliberately is not — it
stays in the ConfigMap so there is exactly one copy of it. Remaining gap: the
image is built locally, not published, so the row closes on the PyPI clause
and stays open on the registry clause.

---

## 3. Severance re-rehearsal plan

**Why re-rehearse at all.** The 2026-09-19 rehearsal was against revision 50,
15 of 16 predictions held, and the substrate has not been wiped since. What
revision 51 changes is not the severance logic — it is that **every pod
restarts**, including all five tier Topaz pods on a *new image reference*.
Severance is decided by each tier serving from its own store, its own broker
and **its own authorizer**; revision 51 replaces the last of those three under
all five tiers at once. A rehearsal that was true of the old authorizer pods
is not automatically true of the new ones.

**Scope: re-run both dimensions, do not re-derive the predictions.** The
predictions in `PREDICTION-2026-09-19-severance-rehearsal.md` stand as
written. Re-deriving them after seeing revision 51 behave would be writing the
prediction after the fact.

**Plan, in order.**

1. **Pre-flight 5 of 5 before the first cut** — `check-advancing.sh`,
   `check-derive-stage.sh`, tier feed, `check-shape-sizes.sh`,
   `check-releasability-completeness.sh`. These are the five that have twice
   been green while something was broken, and they found it both times.

2. **Dimension 1 — region-east from HQ** (`sever-tier.sh region-east on`).
   Expect the eight rev-50 results to reproduce: HQ holds its rows *stale*,
   not fresh and not gone; heal converges in ~45s. Falsifiers unchanged —
   *fresh* means a path crosses the boundary that the default-deny does not
   cover; *gone* means an absence rendered as a deletion.

3. **Heal, verify, and only then Dimension 2** — edge-01 (`--from-parent`).
   The visible beat is edge-01 stale beside edge-02 fresh on one screen.

4. **The one prediction that was WRONG at rev 50, carried forward as a known
   result rather than as a new prediction.** 2.6 predicted 0 bridge restarts
   on the reasoning that buffering is the designed degraded mode. The relay
   crash-looped 6 times: redpanda-connect exits at *startup* unable to init
   its Kafka output, so it never runs long enough to be probed. Expect the
   crash-loop again.

   It cost nothing then, and the reason is the thing to re-confirm, not the
   restart count: `bridge-group-edge-01` reached TOTAL-LAG 3020 while severed
   and drained to 3 on heal, group Stable. **The Kafka topic is the buffer.**
   Re-measure the lag-and-drain, because that is the claim; the restart count
   is a symptom of a relay that holds no state, which is why losing it is
   safe.

5. **The run ends connected.** Pre-flight 5 of 5 after the last heal. A
   rehearsal that leaves the fleet severed has tested the cut and not the
   heal, and the heal is half the claim.

**Added for revision 51 specifically:** run `snapshot-consumers.sh` across the
rollout itself, before any severance work — sampling every 10 minutes for at
least an hour after the rollout completes, as at revision 50. With 95 pod
templates rolling instead of a handful, this is the strongest test UD-14 has
had. Compare against the rev-50 baseline of 92 group-on-broker rows: 0 wedged,
0 state changes, 0 groups disappeared.

---

## 4. Rollback path

**Capture before upgrading — the values file matters more than the revision
number.** `helm rollback` restores the chart, *not* any values passed with
`-f`.

```bash
helm get values "$REL" -n "$NS" > /tmp/values-before-51.yaml   # KEEP THIS
helm history "$REL" -n "$NS" | tail -5                          # confirm 50 is there
kubectl -n "$NS" exec "$REL-postgres-hq-0" -- \
  psql -U postgres -d openddil -tAc "SELECT count(*) FROM telemetry_latest_state;"
```

Also capture the rev-50 variant snapshot, or section 2 rows 1-3 have nothing
to be diffed against:

```bash
kubectl -n "$NS" exec "$REL-postgres-hq-0" -- \
  psql -U postgres -d openddil -tAc \
  "SELECT asset_id, platform_variant FROM telemetry_latest_state ORDER BY asset_id;" \
  > /tmp/variants-rev50.txt
```

**Rollback:**

```bash
helm rollback "$REL" 50 -n "$NS"
```

**What rollback does and does not return.**

| returns | does **not** return |
|---|---|
| the chart at 0.1.56 | values passed with `-f` — re-pass them |
| the five Topaz references to `:0.33.16` | Restate state wiped by the pre-upgrade hook, if the flag was passed |
| the `helm.sh/chart` label, rolling every pod a second time | schema migrations applied forward |
| | the ontology re-resolution — rows re-emitted under the new tuples stay |

**The asymmetry worth naming.** Rolling back the chart does not roll back the
*data* consequences in section 2. Assets that re-emitted under the new
ontology keep their new tuples; `dis:1:1:1004` stays AH-64E-V6 as long as
dis-sim is running the pinned map, because the relabel comes from the
simulator and the ontology, not from the chart. To undo the relabel you roll
back `openddil-customer-bundle-example` and redeploy dis-sim — a separate act,
and one that then needs `flush-assets.sh` for anything that stopped emitting.

**Rollback is a second full rolling restart.** If the reason for rolling back
is instability during the rollout, rolling back costs another 95-pod roll.
Decide against section 2's check-backs, not against pod status — "pods are
Running" is not verification, and it is exactly what was green through both
prior incidents.

---

## 5. Pre-deploy checklist

- [ ] `tools/dis-sim/build.sh --load` has run; `openddil/dis-sim:1.0` is on the nodes (0c)
- [ ] The values file passed with `-f` contains **top-level** `restate.ephemeralOnUpgrade: true` (0b, 1.1)
- [ ] Every `-f` originally installed with is being re-passed
- [ ] `/tmp/values-before-51.yaml` and `/tmp/variants-rev50.txt` captured (4)
- [ ] `snapshot-consumers.sh` baseline taken immediately before the upgrade (3)
- [ ] Pre-flight 5 of 5 green before starting

## 6. Post-deploy, in order

1. Pods settle; **do not accept "Running" as verification**.
2. Section 2 rows 1-8 — the per-asset checks. Any difference beyond the two
   predicted relabels is a finding.
3. `snapshot-consumers.sh` every 10 minutes for at least an hour (section 3,
   UD-14).
4. Pre-flight 5 of 5.
5. Severance re-rehearsal (section 3), one dimension at a time, ending
   connected.
6. Write the measured results back into the ledger rows they answer. The rows
   are written to be *closed by measurement*, and a prediction that is never
   checked back is worse than none, because it reads as settled.
