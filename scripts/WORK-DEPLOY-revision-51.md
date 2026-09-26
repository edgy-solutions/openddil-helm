# Revision 51 on the work cluster — read this before touching it

The lab proved this deploy on 2026-09-26. Revision 51 is now the **work-deploy
package**, so this file is the difference list: what the lab measured, what the
lab *could not* measure, and what is different at work. Read it top to bottom
before the first command.

Companion files: `DEPLOY-PACKAGE-revision-51.md` (the procedure),
`PREDICTION-2026-09-26-rev51-lab.md` (what was predicted and what came back),
`RECORDING-READINESS.md` §E (severance, re-rehearsed at 51), and the two
findings files from the run.

---

## 1. What the lab actually proved

| | measured at revision 51 |
|---|---|
| gate §0(b) — wipe lines rendered | **11** with the flag, **0** without |
| pod templates rolled | **95**, 0 non-healthy at the end |
| consumer groups across the roll | **92 rows at all 15 samples**, **0 WEDGED at every consecutive pair**, 0 disappeared |
| relabels | **2** (`dis:1:1:1004`, `dis:2:1:1004`), mismatches **0**, wear clears **1** |
| partition after | **14 / 8 / 7**, 16 passed / 0 failed |
| four-profile login | all four confirmed in the PEP log |
| severance, both dimensions | cut and healed, ended connected |
| pre-flight | **5 of 5** before and after |

**The roll was quieter than predicted.** I predicted mid-roll `STATE`/`GONE`
perturbations as normal. Measured: **0 GONE** across the whole roll and exactly
**2** `STATE` transitions, both the same group (`fusion-service-cm-state-edge-01`,
Empty→Stable→Empty). A benign miss, recorded because a prediction that was wrong
in the safe direction is still a prediction that was wrong.

---

## 2. What is different at work — the actual list

### 2.1 A COTS DIS simulator replaces `dis-sim`

The lab's entity feed is the `dis-sim` fixture. At work it is a live COTS DIS
simulator. Consequences, in order of how likely they are to bite:

* **Entity types will not be the lab's.** The lab's variant resolution is
  exercised against a known fixture list. A live simulator emits DIS
  enumerations the resolver has never seen, and an unresolved tuple lands as an
  asset with **no `platform_variant`** rather than as an error. Check variant
  coverage early: an asset with a null variant is an unmapped enumeration, not a
  broken pipeline.
* **Volume and cadence differ.** Every timing number in this package — the
  derive-stage deltas, the 64s and 56s heal convergences, the CrashLoopBackOff
  arithmetic — was measured at the lab's rate. Treat them as shapes, not
  thresholds.
* **The multicast site filter matters there and not here.** See
  `RUNBOOK-NOTE-dis-multicast-site-filter.md`.

### 2.2 The wipe flag is **false** at work — and that is the important one

Revision 51 flips `restate.ephemeralOnUpgrade` to default **false**. The lab
deployed with it explicitly **true**, so the lab got clean Restate state on
upgrade. **At work it will not.**

This is not a tidiness point. It is the difference between two remedies existing
and one:

* **In the lab**, a spurious entity was cleared by the upgrade wipe.
* **At work**, the wipe is off, so a spurious entity persists, and the only two
  remedies are (a) declare it in `releasability.yaml`, or (b) cancel its timer
  and clear its Restate Virtual Object state, per server that holds it.

Why it persists: `AssetLogistics` is a Restate Virtual Object keyed by
`asset_id` whose `on_timer` re-emits with `force_emit=True` and **reschedules
unconditionally**. One PDU creates a self-sustaining emitter. And
`STALE_INPUT_SECONDS=300` does **not** evict it — it is a severity rule
(`rules.py:834`) that adds a DEGRADED `stale_inputs` factor and keeps emitting.
The pipeline has no deletion semantics at all: zero matches for tombstones,
null-value guards or `DELETE FROM` across the projector templates and dynamic
mappings.

**So at work, deleting an asset's DB rows does not remove the asset.** Cancel the
invocation, then clear the object state, on every Restate server that holds it —
cancel first, or the timer re-creates the state you just cleared.

### 2.3 Aggregates keep a withdrawn asset's contribution

Worse than 2.2, because this is what gets rendered. The regional aggregator's
Faust table is keyed by `asset_id`, `_emit_rollups` iterates **every key it has
ever seen** (`list(assets_latest.items())`), and there is **no eviction anywhere
in that file** — no `pop`, `del`, `ttl` or `expires`. The projector downstream is
**stateless** and only upserts, on key `(region_id, releasability_class)`, so it
never removes a class either.

Measured in the lab: after one spurious entity was fully removed from all four
stores and from Restate, `region_fleet_summary` still reads **4 partials / 15
assets** where the aggregator's own docstring and §E both record **3 / 14** — and
it is **live**, not stale residue: `observed_at` advances every 30s, and
`asset_count` sums over a strict partition, so the table really does hold 15
keys. It survived **two** cold restarts of the aggregator pod (container started
15:42:54, then again at 16:15), so **a restart is not the remedy.**

The completeness gate passes this **correctly, not by oversight**:
`check-releasability-completeness.sh:532` sets

```
AGGREGATE_TABLES=" region_fleet_summary region_top_factors region_wear_trends "
```

and for those tables the test **inverts** — `releasable_to` non-null,
`originator_nation` **NULL** — because a nation on a rollup would open the first
branch of ADR-0043 §4's disjunction and leak an aggregate to a viewer not
entitled to its inputs. So no gate in the suite can see a stale aggregate
partition, and none claims to.

**At work this means one spurious entity permanently inflates the rollups**, and
neither a gate nor a pod restart will tell you or fix it.

### 2.4 The mirror

Pass 4 asserts that every image a bundle-example k8s manifest deploys is in the
mirror inventory. It cannot see images deployed by another repo's manifest, and
compose images in that repo are out of scope by a stated comment. At work,
confirm the images actually pulled rather than trusting a green pass 4.

### 2.5 The egress gate is compose-only

It does not run against the cluster. Nothing in the pre-flight covers egress, so
an egress regression is invisible to 5-of-5. If egress matters to the session,
check it separately.

### 2.6 Kubeconfig and the cluster guard

The lab needs `KUBECONFIG=/c/Users/cnogr/git/edgy-infra/ansible/kubeconfig`
(context `edgy-lab`); the default `.kube/config` is **not** the lab. The work
cluster will have its own. Three things that cost time here:

* **Shell state does not persist between tool calls**, so the export has to be on
  every invocation.
* Every script is guarded by `require-cluster.sh`: `$OPENDDIL_EXPECT_CONTEXT`,
  else `<repo>/.expected-context`, compared against the current context, **exit
  78** on mismatch. `.expected-context` contains `edgy-lab`. At work it must name
  the work context — **that file is a deliberate operator act, not something to
  change on a guess.**
* `snapshot-consumers.sh --diff a b` takes snapshot **names**, not paths,
  resolved under `${OPENDDIL_SNAPSHOT_DIR:-/tmp/openddil-snapshots}` — and it is
  cluster-guarded even though a diff is pure file comparison.

### 2.7 Indicators that point the wrong way during a cut

If severance is shown at work, know these in advance:

* **`hq_link_severed` stays `false` under a `sever-tier.sh` cut.** It probes
  toxiproxy's `hq-link`; a NetworkPolicy knows nothing about it. The on-screen
  LINK UP/DOWN indicator will contradict the story being told.
* **A whole-table "HQ last updated" tile detects a region cut and is blind to a
  single-edge cut.** Measured: with edge-01 severed, HQ's *total* freshness read
  **0s** while HQ's edge-01 rows sat **305s** stale, because the healthy peer
  pins `max(last_sample_at)` to now. Read per-edge, as
  `check-severance-acceptance.sh` does.
* **Staleness gets worse for ~50s after a heal.** The edge buffer replays
  oldest-first, so `max(last_sample_at)` can *regress* — measured 15:42:51 →
  15:42:49 — before snapping to 0. Watch root reachability, not staleness.
* **Heal is instant; recovery is not.** The bridge fails at startup-init, so it
  crash-loops with a backoff capping at **300s**, and a heal landing deep in that
  backoff waits it out. Measured at 51: 56s total, **42s of it pure backoff
  wait**. Heal early in the dwell on camera.
* **Read `restartCount` before cutting.** edge-01's bridge stood at 2 restarts
  before anything was severed; `sever-tier.sh` then replaces the pod, so the
  severed bridge counts from 0. Without the pre-cut read there is no way to tell
  a pre-existing count from the cut's own.

### 2.8 What CI has validated, and what it has not

The chart you deploy at work is `openddil-demo-0.1.58`. The last commit that
`Chart checks` and `Package and publish openddil-demo chart` actually ran against
is **`0f67690`**, both green. Every commit pushed after it — the whole overnight
write-up, including this file — touches `scripts/*.md` only, and both workflows
filter on `openddil-demo/**`, four named `scripts/*.sh`/`.ps1` files,
`values-artifactory.yaml` and their own workflow files. So the absence of CI runs
for `ad28c8e` and `0df3175` is the path filters working, not a failure. Do not go
looking for a broken pipeline in the morning.

Two consequences that do bear on the deploy:

* The **runtime-bundle image** was last built by the daily scheduled run, not by
  a change. If the projector has moved ahead of the bundle's Atlas migrations,
  the symptom at work is a postgres `column "X" does not exist`. If you want a
  fresh bundle before deploying, use the `workflow_dispatch` button on
  `notify-bundle-rebuild.yml` in `openddil-contracts` — it exists for the case
  where the `paths-ignore` filter legitimately skipped a rebuild.
* A green CI history says the chart renders and publishes. It says nothing about
  the cluster. The pre-flight is the only thing that speaks for the cluster, and
  it is 5 of 5 on the lab, not at work.

---

## 3. Order of operations at work

1. Set the kubeconfig and confirm `kubectl config current-context`; make
   `.expected-context` right **deliberately**.
2. Pre-flight 5 of 5. Do not proceed on 4.
3. `helm get values` to capture live values; **render the §0(b) gate and expect
   the number you intend.** Revision 50's captured values contain no
   `restate.ephemeralOnUpgrade` at all, so re-passing them unchanged under 0.1.58
   renders **0** wipe lines and wipes nothing, silently. Decide whether you want
   the wipe at work and pass the flag accordingly — top-level, not under
   `tierNode`, which renders 0 either way.
4. Baseline: partition counts, row counts, `snapshot-consumers.sh` as `pre-51`.
5. Upgrade. Snapshot across the roll; diff **consecutive pairs**, not
   first-against-last — a group that wedges mid-roll and recovers is invisible to
   a first/last diff.
6. Post: pre-flight 5 of 5, partition re-measured, four-profile login.
7. If it wedges across three consecutive samples: **roll back to 50.** A
   half-rolled cluster is ruled out as an end state. Rolling back also puts the
   chart version back into the pod templates.

**Revision 51 is the last fleet-wide rollout you get by accident.** Removing the
chart version from pod labels is itself a pod-spec change, so 0.1.56→0.1.58 rolls
all 95; 0.1.58→0.1.59 rolls **0** while still labelling all 206 objects. Watch
this one.

---

## 4. Open, and not mine to close

* **The lab is left with the aggregate residue.** `region_fleet_summary` and
  `region_wear_trends` each carry a `releasability_class=''` partial on HQ and
  region-east, from a spurious entity that is otherwise fully removed. The
  surgical fix is: scale the regional aggregator to 0, write a **tombstone** for
  changelog key `"dis:1:1:1099"` on
  `region-region-east-aggregator-region_region_east_assets_latest-changelog`,
  scale back to 1 so recovery applies the delete, **then** delete the leftover
  `class=''` rows from both stores — the stateless projector never deletes, so
  the rows outlive the emission and need the explicit delete either way. I was
  denied permission to scale the deployment and to produce into the changelog, so
  this is **unfixed and yours.** A tombstone is the *supported* semantics here:
  null-means-delete-this-key is Faust's own changelog recovery contract, unlike
  the ingress topics, where the projector has no null handling and a null is an
  untested input class.
* Three ingress `compact` topics still retain a last record for the same key.
  Inert unless a consumer group is reset or a store is rebuilt from the topics.
  Clearing it is an attended job.
* The aggregator module docstring says it owns "RocksDB Tables"; the app is
  constructed with `store="memory://"`. Doc drift.
* `region_top_factors` reports **4** rows while my per-class query over it
  returned none — unresolved, low stakes, recorded so it is not met as a surprise.
* Two check-back queries in the rev-51 package cannot run as written, found by
  running them before the deploy: row 4 selects `platform_variant` from
  `asset_cm_state`, which has no such column (join `telemetry_latest_state`
  instead); row 9 selects `dis_entity_type` from `telemetry_latest_state`, and the
  raw DIS tuple is **not stored in that table at all** — `provenance` carries
  `source_protocol`, `producer_id`, `ingest_time`, `sample_time`,
  `classification`, `originator_nation` and no tuple. Row 9 is recorded
  **unverified**, not passed.
* Row 5's expected value is ambiguous: it says "region critical 2 to 1", but since
  ADR-0029 `region_fleet_summary` is partitioned by releasability class. Total
  critical is 3; the ATL slice is 2. It was checked back as the ATL slice.
* `helm history` is blocked in this session, so revision 50's existence is taken
  from the 2026-09-19 handoff rather than confirmed live — the one unverified
  rollback input.
* The simulator-side fix (`DIS_ENTITY_TYPES_PATH` JSON drop with the
  SISO-conformant list) was **not** done tonight.
* `operator.regioneast` exists in `users.yaml:157` and the realm export but is not
  exercised by the partition demo, and is still absent from
  `users-promoted.yaml` — yours.
