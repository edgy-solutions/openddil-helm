# Deploy package — revision 51

> **EXECUTED ON THE LAB 2026-09-26 — this is now the work-deploy package.**
> Revision 51 was deployed to `edgy-lab` by this procedure and measured against
> the predictions below. The line that used to open this document ("nothing here
> has been executed against any cluster") no longer holds and has been removed
> rather than softened. **Before running this at work, read
> `WORK-DEPLOY-revision-51.md`** — it carries what was measured, what came back
> different from the prediction, the two check-back queries in this document that
> **cannot run as written**, and the list of ways the work cluster differs from
> the lab. Predictions and their measured outcomes are in
> `PREDICTION-2026-09-26-rev51-lab.md`; severance at revision 51 is in
> `RECORDING-READINESS.md` §E.

The chart renders and diffs below were produced locally from the repository.
Every number attributed to the cluster began as a *prediction* with a check-back
query, so it is settled by measurement rather than by argument afterwards — and
as of 2026-09-26 those check-backs have been run on the lab.

Baseline is **helm revision 50**, deployed 2026-09-19 from chart
`openddil-demo-0.1.56` at `openddil-helm@d43e9ef`. Target is
`openddil-demo-0.1.58` at `openddil-helm@2dd2256` — the chart's last change.
`0f67690` is the repo tip and touches only scripts and CI.

**Revised 2026-09-25**, after three things landed that this document had listed
as open or taken on trust. The chart version left every pod template (0a and
1.5 — and it does *not* make this a smaller deploy). The Topaz digest was
verified against the registry (1.3). dis-sim's image is published (0c), which
closes 2.2 outright. Section 0's wipe flag is now a render assertion rather
than a checkbox, and section 3 samples the rollout instead of only what
follows it.

---

## 0. Read this first — the three things that decide the deploy

**(a) This is a full-stack rolling restart — and the last one that packaging
will ever cause.**

`helm.sh/chart` was in the pod template label set of **95 of the chart's 96
workloads**. 0.1.58 takes it out of all 95 (2dd2256). That does *not* make
revision 51 a smaller deploy: **removing a pod label is itself a change to the
pod spec**, so every workload still rolls. What it changes is everything after
this one.

Measured — the rev-50 chart against the rev-51 chart, rendered at lab values:

| | rev 50 | rev 51 |
|---|---|---|
| objects rendered | 206 | 206, none added, none removed |
| pod templates | 95 | 95 |
| ...carrying `helm.sh/chart` | 95 | **0** |
| pod templates whose labels differ 50 to 51 | — | **95** (the label is removed) |
| objects differing for any **other** reason | — | **5**, the tier Topaz digests (1.3) |
| render size | 17,448 lines | 17,353 — exactly 95 fewer |

And forward, which is the reason for doing it at all: 0.1.58 to a hypothetical
0.1.59 changes **0** pod templates while still updating the label on all 206
objects. `app.kubernetes.io/version` stays in the pod labels deliberately — it
carries `appVersion`, and an application version change *should* roll pods. A
packaging version should not.

That matters because of UD-14: the helm rollout is the trigger that preceded
the 3.5-hour wedge and had never been watched. Revision 50 was the first one
watched — 92 group-on-broker rows, eight clean samples over 1h43m, 0 wedged.
Revision 51 is the second opportunity, it restarts more, and it is **the
largest that will ever arrive by accident**. After this, no version bump
produces a fleet-wide roll to watch. If the rollout is not sampled while it is
happening (section 3), that natural experiment is spent, and the next one has
to be manufactured on purpose.

**(b) GATE — the wipe flag, asserted by a render before the upgrade runs.**

The default is now false, and this is the first deploy where the flag has to be
passed. Passing it restores the exact revision-50 behaviour: the change is to
what happens when nobody decides, not to what happens when somebody does.

Do not tick a box. Render the release from the values the upgrade will actually
pass, and read the number:

```bash
# VALUES: exactly the -f files the upgrade will pass, in the same order
helm template "$REL" ./openddil-demo -f "$VALUES" | grep -c restate-wipe
```

**Expect `11`. Anything else: stop, and do not upgrade.**

Measured at 0.1.58: **11** lines with top-level
`restate.ephemeralOnUpgrade: true`, **0** without it. The rev-50 chart emits
the same 11 at the same values, so this assertion says revision 51 wipes
exactly where revision 50 did — not merely that some hook exists somewhere.

* **0** means the hook is not in the release at all. Handler-code changes then
  meet Virtual Object journals written by the old code: `VMException(570)` on
  every event for those assets, arriving as data that stopped moving rather
  than as an upgrade that failed.
* **Neither 0 nor 11** means the hook rendered differently from either revision
  this was measured against. Read the render — the number is not the finding,
  the diff is.

Why a render rather than a checklist line: the failure mode is a flag that was
silently not passed, and a checkbox gets ticked by the same person who would
have passed it. The trap in 1.1 — the key under `tierNode` instead of at top
level — also produces **0** here, and that is exactly what a checkbox cannot
catch.

**(c) dis-sim's image is published now — confirm the tag instead of building
it.** This was a pre-deploy hazard when the package was written, and is not
one any more:

```
ghcr.io/edgy-solutions/openddil/dis-sim:1.0
  digest  sha256:862dd904ec638921088693bdfcdbc4899128cca82ea92184901edd3d9a08ceeb
  pushed  2026-09-25, by openddil-helm's build-bundle workflow
  single-platform linux/amd64, on purpose -- see that job's comment
  anonymously pullable from ghcr.io: checked, so no pull secret is needed
```

The manifest in `openddil-customer-bundle-example` points at that ref
(`e72784f`), so on a cluster with egress to ghcr.io there is nothing to do
before `deploy.sh`. In an air gap it comes from the mirror: it is a row in
`scripts/mirror-to-artifactory.ps1`, and pass 4 of `check-mirror-coverage.sh`
holds the manifest's reference against that row so the two cannot drift.
`build.sh --load` still works and still builds the same ref — it is for
iterating on the Dockerfile now, not a prerequisite.

**What has not changed:** if the simulator pods do not start, no DIS traffic is
produced and **the relabel predictions in section 2 cannot be checked at
all** — they are all downstream of assets emitting. And amd64-only means an
arm64 node reports "no matching manifest" rather than a pull failure.

---

## 1. Values diff, 50 to 51

Three commits touch the chart: `792febe` (tier image blocks), `dae37c8` (the
wipe default) and `2dd2256` (chart 0.1.58, the pod-label change). The complete
substantive diff:

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

**This risk is retired.** When the package was written, that
`sha256:835868c0...` *is* tag `0.33.16` was the one thing not verifiable from
here. It was then checked against ghcr.io and it holds — pulled both ways, the
image IDs are identical, so the tag-to-digest substitution is behaviour-neutral
for all five tiers. Evidence:
`scripts/EVIDENCE-2026-09-25-topaz-digest.md`.

The same check turned up something the identity question does not reach: the
pin is an **OCI image index**, carrying linux/amd64 and linux/arm64. So pinning
it does *not* freeze the architecture — the kubelet still resolves the index
per node. Had the pin been the amd64 *child* digest instead, the identity check
would have passed just as cleanly while the deploy quietly became amd64-only,
and an arm64 node would have presented it as one tier's authorizer failing to
start rather than as an architecture pin.

`topaz-hq` remains the control: it already runs this digest, so a tier whose
decisions disagree with HQ's after the deploy is still a finding — the check
rules out the image, not the wiring.

### 1.4 Rendered diff, in full

At lab values (`releasability`, `tierNode`, `sensorIngest.externalAccess` on,
wipe explicitly true), the rev-50 render is 17,448 lines and the rev-51 render
is 17,353. They differ in exactly two ways: the `helm.sh/chart` pod label,
removed from all 95 pod templates, and the five Topaz references above. **No
resource is added or removed. No schema migration is implied by the chart.**

### 1.5 `helm.sh/chart` leaves every pod template (2dd2256)

`openddil.labels` is now *defined as* `openddil.podLabels` plus
`helm.sh/chart`, so the two sets cannot drift apart, and 38 pod-template call
sites switched to `openddil.podLabels`. The 86 object-metadata call sites are
untouched: every object still carries the chart version, which is what makes a
deployed object traceable to its release.

Two things checked rather than assumed, because both would present as an
outage:

* **Selectors are unaffected.** They read `app.kubernetes.io/component` from
  `openddil.selectorLabels`, never from `openddil.labels`, so no Deployment or
  StatefulSet selector changes — which matters, as a selector is immutable and
  a changed one fails the upgrade outright. `sever-tier.sh`'s NetworkPolicy
  selects by component too.
* **206 objects render before and after, with none added or removed** (0a). The
  render shrinks by exactly the 95 label lines it drops.

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

### 2.2 One ledger row this deploy closes outright

`OPEN 2026-09-23 — the DIS fixture reaches PyPI at container start`. Its close
list item 2 was "bake generator and dependency into one small image". **Both
clauses are now closed, which they were not when this package was written.**

The **dependency** is baked (`tools/dis-sim/Dockerfile`), verified by importing
`opendis` under `--network none` — locally, and again in CI before the push, so
a build that would still reach PyPI fails in the pipeline rather than in a lab.
The **generator** deliberately is not baked: it stays in the ConfigMap so there
is exactly one copy of it, and baking it would make the Dockerfile a second
place it lives.

The registry clause closed on 2026-09-25 (0c): the image is in GHCR, in the
mirror inventory, and pass 4 of `check-mirror-coverage.sh` fails if the
manifest and the inventory ever stop agreeing. **The row can be closed in the
ledger, with that check named as what keeps it closed.**

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

**Added for revision 51: sample ACROSS the rollout, not only after it.**

At revision 50 the sampling started once the rollout had finished, which
answers "did the fleet end up wedged". It cannot answer "did anything wedge
while the pods were restarting and then recover", and the trigger under
investigation is the rollout itself. With 95 pod templates rolling, and with
this being the last fleet-wide roll a version bump will produce (0a), a group
that wedges mid-roll and heals before the first post-rollout sample is
invisible for good.

**1. Baseline, the last thing before the upgrade** (also in section 5):

```bash
export OPENDDIL_SNAPSHOT_DIR=~/openddil-snapshots-rev51   # somewhere that survives
./scripts/snapshot-consumers.sh pre-51
```

**2. During the roll — a second terminal, started BEFORE `helm upgrade`:**

```bash
for i in $(seq -w 1 15); do
  ./scripts/snapshot-consumers.sh "roll-$i"
  sleep 120
done
```

**3. After `kubectl rollout status` is clean on the last workload:** `post-00`,
then every 10 minutes to `post-60`, as at revision 50.

**4. The diffs, because which pairs you compare is the whole design:**

```bash
# consecutive pairs through the roll -- the only thing that catches a group
# that wedged mid-roll and recovered. pre-51 -> post-60 cannot see it.
for i in $(seq -w 1 14); do
  j=$(printf '%02d' $((10#$i + 1)))
  ./scripts/snapshot-consumers.sh --diff "roll-$i" "roll-$j"
done
./scripts/snapshot-consumers.sh --diff pre-51 post-00   # what the roll cost
./scripts/snapshot-consumers.sh --diff pre-51 post-60   # did it end clean
./scripts/snapshot-consumers.sh --diff post-00 post-60  # the rev-50 comparison
```

**What each category means, and it is not the same mid-roll as after:**

* **`STATE` and `GONE` mid-roll are expected, not findings.** 95 pods
  restarting means groups rebalance and members leave. `GONE` in particular
  goes wholesale: the script enumerates groups by exec-ing into each redpanda
  pod, so while a broker is restarting it contributes no rows at all and every
  group on it reads `GONE`. Mid-roll, that is the rollout working.
* **`WEDGED` is the finding at any point** — Stable, committed offset frozen,
  lag waiting — and the diff exits non-zero on it. That is the UD-14 signature:
  the broker still counts the group as a healthy member, the pod reads
  `1/1 Running`, there is work waiting, and nothing is being committed.
* **One caveat, stated so a false positive is not narrated as a wedge.** The
  signature was tuned at 10-minute spacing; at 2 minutes a group that is merely
  slow can look frozen. So a mid-roll `WEDGED` row is a **lead, not a result**:
  take another snapshot immediately and diff again. A wedge that holds across
  three consecutive samples is the thing. One sample is not.
* **After the roll settles, the categories mean what they meant at revision
  50.** Compare against that baseline: 92 group-on-broker rows, 0 wedged, 0
  state changes, 0 groups disappeared.

**Keep the snapshot directory.** It is the only record that the trigger was
watched, and this is the last rollout of this size that will happen by itself.

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
| the `helm.sh/chart` pod label, rolling every pod a second time | schema migrations applied forward |
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

**And it puts the chart version back into the pod templates.** 0.1.56 labels
pod templates with `helm.sh/chart`, so rolling back restores the behaviour 0a
describes: every subsequent version bump rolls the whole fleet again, whatever
it contains. That is a reason to prefer fixing forward over rolling back, not a
reason to refuse a rollback that is otherwise warranted — but it should be a
decision rather than a surprise two chart versions later.

---

## 5. Pre-deploy checklist

**The first item is a gate, not a checkbox.** It is the one failure here that
nothing downstream would reveal, so it is asserted by a command whose output is
read before the upgrade runs:

```bash
helm template "$REL" ./openddil-demo -f "$VALUES" | grep -c restate-wipe
# expect exactly 11. 0 = the flag did not arrive. Anything else: read the
# render. Do not upgrade on a number you did not expect. (0b)
```

- [ ] **GATE:** that render prints `11` with the exact `-f` files, in the exact order, that the upgrade will pass (0b, 1.1)
- [ ] Every `-f` the release was originally installed with is being re-passed
- [ ] `ghcr.io/edgy-solutions/openddil/dis-sim:1.0` is reachable from the cluster, or mirrored in an air gap (0c) — no local build needed any more
- [ ] `/tmp/values-before-51.yaml` and `/tmp/variants-rev50.txt` captured (4)
- [ ] `OPENDDIL_SNAPSHOT_DIR` set somewhere that survives, and `snapshot-consumers.sh pre-51` taken as the last act before `helm upgrade` (3)
- [ ] The every-2-minutes sampling loop is already running in a second terminal (3)
- [ ] Pre-flight 5 of 5 green before starting

## 6. Post-deploy, in order

1. Pods settle; **do not accept "Running" as verification**. The sampling loop
   from section 3 keeps running while they do — that window is the experiment,
   and it is not repeatable.
2. `kubectl rollout status` clean on the last workload, then `post-00`, and the
   consecutive-pair diffs across the `roll-*` snapshots (section 3, step 4).
   Do this before the per-asset checks: a wedge found here changes what every
   query below means.
3. Section 2 rows 1-8 — the per-asset checks. Any difference beyond the two
   predicted relabels is a finding.
4. `snapshot-consumers.sh` every 10 minutes for at least an hour (section 3,
   UD-14), then `--diff pre-51 post-60`.
5. Pre-flight 5 of 5.
6. Severance re-rehearsal (section 3), one dimension at a time, ending
   connected.
7. Write the measured results back into the ledger rows they answer. The rows
   are written to be *closed by measurement*, and a prediction that is never
   checked back is worse than none, because it reads as settled.
