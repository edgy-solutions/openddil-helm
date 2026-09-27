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

### 2.0 Variant resolution is broken on the lab — settle this at work FIRST

**This supersedes what §2.1 and the rev-51 checkback rows say about variants,
and it corrects a result this package reported as passed.**

Measured after the deploy: **every one of the lab's 14 assets resolves to
`platform_variant = UNKNOWN`, on all four stores.** At revision 50 they
resolved correctly, so the upgrade is the event. The ontology's DIS tuples were
realigned to SISO-REF-010-v37 on 2026-09-21 and the 0.1.58 bundle carried that
to the cluster; the lab's simulator still emits the pre-realignment tuples; the
two sets **do not intersect at all** (arriving ∩ current ontology = **0**,
arriving ∩ removed = **8 of 8**). Every asset takes the unconditional
`.or($doc.mappings._default)` fallback at `sim-dis-mapping.yaml:75`.

**What this package got wrong.** It reports the relabel checkback as *"Relabels
2, mismatches 0"*. That is wrong, and the contradicting log predated the
report. Treat every variant-dependent row in the checkback as **void**, not
passed — CM baseline mismatches included, since a baseline comparison against
`UNKNOWN` establishes nothing.

**The hopeful part, and it is a hypothesis rather than a measurement.** The
realignment is correct in direction and the *lab's* simulator is the stale
party: it emits hand-authored legacy tuples, while a live DIS simulator emits
SISO-conformant ones — which is what the ontology now expects. Work may resolve
**better** than before.

**So this is the highest-value pre-flight check at work, it is read-only, and it
takes a minute.** With the simulator running:

```bash
kubectl exec -n openddil <edge-broker-0> -- \
  rpk topic consume ingress-dis-raw -p 0 -o <hw-20>:<hw> -f '%v\n' \
  | grep -o '"dis_entity_type":{[^}]*}'
```

Compare what it prints against the 11 keys in
`openddil-contracts/ontology/dis_entity_types.yaml`. Three outcomes:

1. **they match** — variant resolution works at work; the lab's `UNKNOWN` is a
   lab-simulator artifact. Proceed, fix the lab afterwards.
2. **they do not match** — work is in the lab's state, and every
   variant-dependent panel, CM baseline and fuel% figure is meaningless **on
   camera**. This has to be known before recording, not discovered during it.
3. **`kind=2` entries appear too** — then the munition finding applies on top,
   and each tracked round becomes a **permanent** UNKNOWN fleet member, because
   the wipe flag is false here (§2.2) and there is no eviction path (§2.3).
   **Proven end-to-end under compose 2026-09-26**, not inferred: one `kind=2`
   PDU in, one asset out, `platform_variant='UNKNOWN'`, `kind=2` still intact in
   the payload. And the part that bites on camera: **`kind` is not in the
   `asset_id`** (`dis:<site>:<app>:<entity>`), so there is **no key pattern that
   excludes munitions from a fleet count** — the only discriminator is a payload
   field nothing reads. If this outcome occurs, the asset count on screen
   includes every round fired, and it grows for the length of the recording.
   `FINDING-2026-09-26-kind2-munition-resolution.md` §8.

Full measurement, both ends of the path:
`FINDING-2026-09-26-variant-resolution-is-broken.md`. Note also that `RCV-M`'s
tuple was removed **with no replacement** (11 keys removed, 10 added), so that
entity cannot resolve by construction on either cluster.

### 2.1 A COTS DIS simulator replaces `dis-sim`

The lab's entity feed is the `dis-sim` fixture. At work it is a live COTS DIS
simulator. Consequences, in order of how likely they are to bite:

* **Entity types will not be the lab's.** The lab's variant resolution is
  exercised against a known fixture list. A live simulator emits DIS
  enumerations the resolver has never seen, and an unresolved tuple lands as an
  asset rather than as an error. **Corrected 2026-09-26:** it does **not** land
  with a null `platform_variant` — it lands as the literal string
  **`UNKNOWN`**, from `_default`, together with an empty
  `configuration_baseline` and the nomenclature *"Unrecognized DIS entity type
  — requires ontology curation"*. A check looking for nulls finds none and
  reads as clean. Count `platform_variant = 'UNKNOWN'` instead, and see §2.0 —
  on the lab that count is currently **14 of 14**.
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
**Two decoys around this flag, both measured on the lab.**

*The flag has a lookalike in the live values.* Revision 50's user-supplied values
contain `tierNode.restate.useEmptyDir: false` — a **nested `restate:` block that
is not where the flag goes** — while `ephemeralOnUpgrade` appears **0 times**
anywhere in those values. Reading live values at work, you will see a `restate:`
key and it is the wrong one. The flag is **top-level** `restate:`; under
`tierNode:` it renders 0 wipe lines and wipes nothing.

*There is no post-hoc way to confirm the wipe ran.* The wipe is a Helm **hook**
(`pre-install,pre-upgrade`, `hook-delete-policy: before-hook-creation,hook-succeeded`),
so both obvious after-the-fact checks are blind:

* **`helm get manifest` never shows it** — hooks are excluded from the stored
  manifest. Measured: `grep -c restate-wipe` returns **0 for revision 51**, the
  revision whose values *do* carry the flag and whose `helm template` gate
  rendered **11** lines. A zero there means nothing at all.
* **`kubectl get jobs` never shows it either**, because `hook-succeeded` deletes
  the Job on success.

So `helm template` — the §0(b) gate — is the only thing that sees the wipe, and
only *before* the fact. **Render the gate and read the number before you
upgrade.** Afterwards, the only evidence is Restate's own state.


### 2.3 Aggregates keep a withdrawn asset's contribution

**A design now exists for this**, written 2026-09-26 after the lab measurements:
`openddil-contracts/decisions/DESIGN-2026-09-26-asset-lifecycle.md`. Nothing is
built, so everything below still holds at work; read the design for the *shape*
of the fix and, more usefully here, for the measurement that changes the
procedure — a null-valued record means **three different things** to the three
readers, and on a projector-fed topic it is **safe but ineffective** (the decode
error is caught, logged once and the offset commits), so "produce a tombstone" is
not a procedure until it names the topic.

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
**And the state you would have to reach into is not where its name says it is.**
The aggregator's table lives in a Faust changelog topic, and on the lab that
topic exists **twice under the same name on two brokers**: the live one with
111,976 retained records and 15 keys on the *region* broker, and a **frozen twin
holding 14 records** on the HQ broker. The env var that selects it is called
`REGIONAL_HQ_BROKERS` and it resolves to the *region* broker. A tombstone sent to
the HQ-named broker is accepted, changes nothing, and looks like a completed fix.
Check which broker actually carries the moving watermark before you write to it.

Also, when you read that topic: `rpk topic consume -o start` **under-reads it**
— on the lab it returned only the last 30 offsets on a topic reporting
`LOG-START-OFFSET 0`, which twice produced a confident and wrong "the key is not
there". Use the range form `-o <start>:<end>`.
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

### 2.9 The ingress kind gate — REQUIRED, and already on

**This is a required setting, not an option, and the reason is §2.0 outcome 3
plus §2.2 plus §2.3 acting together.** A live DIS simulator emits munition
PDUs (`kind=2`). Measured under compose on 2026-09-26: a `kind=2` entity is
admitted as a **full fleet asset**, indistinguishable downstream from a tank,
because

* its variant resolves to `UNKNOWN` like everything else right now (§2.0), and
* **`kind` is not part of `asset_id`** — the id is
  `dis:<site>:<application>:<entity>` — so **no fleet query can filter
  munitions out by key pattern**, and
* the wipe flag is **false** at work (§2.2) and there is no eviction path
  (§2.3), so each round is a **permanent** member.

On camera that means the asset count includes every round fired, and it grows
for the length of the recording, with no query available to hide it.

**What ships.** `openddil-demo/dynamic-mappings/dis-kind-gate.yaml` admits a
declared set of DIS entity kinds, **defaults to `[1]` (PLATFORM)**, drops
everything else before reshaping, and **counts each drop per kind** in
`dis_ingress_kind_dropped{kind="N"}`. Gated messages do **not** go to the DLQ —
a refused kind is policy, not malformed data, and DLQ depth has to stay
meaningful.

**It needs no chart change and no values change.** It is a new file in the
bundle's `dynamic-mappings/`, and Connect already runs `-r /mappings/*.yaml`,
so the glob picks it up. It is wired into `openddil-base-connect.yaml` **ahead
of** `sim_dis_mapping`, which is the only correct position: once that resource
has run, `dis_entity_type.kind` has moved under `asset.` and the message is an
asset-shaped event — gating there would be refusing something already built.

**Verified both directions under compose, not just wired:** with the gate in,
`kind=2` and `kind=9` were absent from `raw-sensor-stream`, the counter read
`{kind="2"} 1` and `{kind="9"} 1`, the DLQ stayed at 0, and `kind=1` still
landed. With the gate removed, `dis:1:1:54002` (`kind=2`) landed — so the
topic-leak assertion is live, not decorative. Guarded by
`tests/hero_scenario_v3/test_54_dis_kind_gate.py`; `test_04` confirms normal
resolution is undisturbed (`variant=M1A2-SEPv3`).

**Two things to know before you rely on it at work.**

1. **You cannot change the admitted set at work without a chart change.** The
   gate reads `${DIS_ADMITTED_ENTITY_KINDS:1}`, but the connect container's
   `env:` block in `templates/edge.yaml:205` is hardcoded to `REDPANDA_BROKER`
   and **the chart has no `extraEnv` hook anywhere.** So the default is in
   reach of a bundle rebuild and any override is not. That makes the gate
   required by construction — and it also means that if work's feed
   legitimately carries a kind you want (say `kind=3`), there is **no quick
   escape hatch**, and you will be looking at a silently thinner fleet. Adding
   `extraEnv` to that container is the one-line chart change that buys the
   escape hatch; consider it before the recording, not during.
2. **Nothing scrapes the counter.** Connect's Prometheus endpoint is on by
   default at `:4196/metrics`, and there is no `ServiceMonitor` and no
   `prometheus.io/scrape` annotation in the chart. Read it by hand:

   ```bash
   kubectl exec -n openddil <connect-pod> -- \
     wget -qO- http://localhost:4196/metrics | grep dis_ingress_kind_dropped
   ```

   **An absent series and an absent scrape produce the same empty output**, so
   "no munitions were refused" and "nobody is looking" are indistinguishable
   from that command — and the first is the answer you will assume. If the
   output is empty, confirm the endpoint answers at all before concluding
   anything about munitions.

**What the gate does not do.** It stops munitions becoming assets; it does not
give assets a lifecycle. Everything already in the stores stays there, and a
platform that leaves the field still never departs. That is
`DESIGN-2026-09-26-asset-lifecycle.md`, and this gate is explicitly the guard
until it lands. Munition rows remain in the ontology overlay for resolution, so
variant coverage on them still matters and should still read zero `UNKNOWN`.

---

## 3. Order of operations at work

1. Set the kubeconfig and confirm `kubectl config current-context`; make
   `.expected-context` right **deliberately**.
2. Pre-flight 5 of 5. Do not proceed on 4.
3. `helm get values` to capture live values; **render the §0(b) gate and expect
   the number you intend.** Confirm at the same time that the bundle image you
   are deploying carries `dynamic-mappings/dis-kind-gate.yaml` (§2.9) — it is
   required, it is default-on, and it arrives via the bundle, not via values,
   so `helm get values` will never mention it. Revision 50's captured values contain no
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
   chart version back into the pod templates. **Rollback is state-neutral for
   Restate** — measured, not assumed: the wipe hook registers only
   `pre-install,pre-upgrade` and nothing in the chart registers `pre-rollback`,
   so `helm rollback` fires no wipe even though 0.1.56 defaults
   `ephemeralOnUpgrade` to **true**. Rolling back does not clear state, and it
   does not need a decision about the flag.

**Revision 51 is the last fleet-wide rollout you get by accident.** Removing the
chart version from pod labels is itself a pod-spec change, so 0.1.56→0.1.58 rolls
all 95; 0.1.58→0.1.59 rolls **0** while still labelling all 206 objects. Watch
this one.

---

## 4. Open, and not mine to close

* ~~**The lab is left with the aggregate residue**~~ — **CLEARED 2026-09-26**,
  and durably: a tombstone at offset **9345227** on the **region-east**
  changelog (`VALUE_BYTES=0`), 6 orphaned rows deleted across both stores, and
  both stores reading **3 classes / 14 assets** — confirmed across a further
  cold restart, because the tombstone lives in the changelog and every future
  recovery replays the delete. The cleanest evidence was a *frozen* timestamp
  beside *advancing* siblings before anything was deleted. One correction to
  carry forward: **readiness is not recovery** — the deployment reported
  `readyReplicas: 1` after 4s while Faust recovery had 50s left, so wait on
  `Recovery complete` in the log, never on `1/1`. Full record:
  `RESULT-2026-09-26-residue-cleanup.md`. The original bullet follows, as
  written, because the broker correction in it is the part worth keeping:
* **The procedure I first wrote for the residue named the wrong broker.** `region_fleet_summary`, `region_wear_trends`
  and `region_top_factors` each carry a `releasability_class=''` partial on HQ and
  region-east, from a spurious entity otherwise fully removed. Measured since:
  the key is **`dis:1:1:1099`** (range-bounded scan: 15 distinct keys over 111,976
  records), and the **live changelog is on the region-east broker**, not the HQ
  one. Full detail and the exact commands are in
  `FINDING-2026-09-26-changelog-broker-and-wipe-hook.md` §7. `kubectl scale` is
  now permitted and the scale cycle is measured safe (`Recovery complete` in ~5s,
  0 non-healthy after), and the tombstone has since been produced (see the CLEARED note
  above), so this is **done, not yours.** I scaled the aggregator down, was refused the produce,
  and scaled it straight back rather than leave it at 0 — the cluster is in its
  exact prior state. A tombstone is the *supported* semantics here:
  null-means-delete-this-key is Faust's own changelog recovery contract, unlike
  the ingress topics, where the projector has no null handling and a null is an
  untested input class.
* A stale, frozen twin of that changelog topic sits on the HQ broker under the
  identical name. Inert, but it is why a correct-looking tombstone can be a
  silent no-op. Worth deleting when attended. **Measured 2026-09-26:** the HQ
  twin holds **14,368,522** records, last written **2026-09-08 02:51:26Z**; the
  live region-east one holds **9,362,307**, last written 2026-09-26. **The dead
  twin is the larger of the two and 18.8 days stale** — size and partition
  metadata both point at the wrong answer, and only a record timestamp
  separates them. Indexed as a row in
  `openddil-contracts/decisions/FOLLOW-UPS.md`.
* Three ingress `compact` topics still retain a last record for the same key.
  Inert unless a consumer group is reset or a store is rebuilt from the topics.
  Clearing it is an attended job.
* The aggregator module docstring says it owns "RocksDB Tables"; the app is
  constructed with `store="memory://"`. Doc drift.
* ~~`region_top_factors` reports 4 rows while a per-class query returns none~~ —
  **resolved, not a defect.** It holds 4 classed rows (BDR, ATL, `ATL,BDR`, `''`);
  the earlier contradiction was a fault in my query, not the data.
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
* ~~`helm history` is blocked, so revision 50's existence is unverified~~ —
  **closed.** Confirmed first-hand once `helm history` was permitted:
  `50  Fri Sep 18 22:58:31 2026  superseded  openddil-demo-0.1.56`, and
  `51 ... deployed openddil-demo-0.1.58` with `helm status` `REVISION: 51`.
  Rollback to 50 is a real target. It returns the chart to **0.1.56**, where
  `restate.ephemeralOnUpgrade` defaults **true** — but that does **not** mean a
  rollback wipes Restate: the wipe hook registers only
  `pre-install,pre-upgrade`, and nothing in the chart registers `pre-rollback`,
  so `helm rollback` fires no wipe. **Rollback is state-neutral for Restate.**
* The simulator-side fix (`DIS_ENTITY_TYPES_PATH` JSON drop with the
  SISO-conformant list) was **not** done tonight — and per §2.0 this is not a
  tidy-up but **the open half of a breaking change**: variant resolution has not
  returned, and the lab is not a valid proving ground for anything
  variant-dependent until it does. Also owed, and missing entirely: **a gate
  comparing the arriving tuples to the ontology's keys.** `check-ontology-siso.py`
  verifies the ontology against SISO and says honestly that it establishes
  nothing about the wire; `ontology_check.py` was meant for this neighbourhood
  and is a no-op that logs *"Ontology consistency check OK"*
  (`FINDING-2026-09-26-kind2-munition-resolution.md` §7).
* `operator.regioneast` exists in `users.yaml:157` and the realm export but is not
  exercised by the partition demo, and is still absent from
  `users-promoted.yaml` — yours.
* **The scenario reset is not a tool you can lean on yet — do not run it here.**
  `reset-scenario.sh` was run against the lab on 2026-09-26 and **phase 4 has
  never completed, on any cluster**: `rpk topic trim-prefix` returns
  `POLICY_VIOLATION` on `cleanup.policy=compact` topics, and the compacted topics
  are the state topics. Phases 1–3 *do* mutate (six producers to 0, Restate state
  clear enqueued on all four runtimes), so an aborted run leaves a quiesced
  cluster. It self-heals once the producers are scaled back to 1 — measured twice,
  worked twice — but that is an operator step, not the script's. Four ways to
  finish the mechanism, and the one decision blocking it, are in
  `FINDING-2026-09-26-trim-refused-on-compacted-topics.md`. **Consequence for the
  recording: there is no proven one-command restart yet.** Plan the demo so a
  restart means a fresh namespace or an attended sequence, not this script.
* **Updated 2026-09-27: the mechanism is now written, and that does not change
  the advice above.** Phase 4 takes the mixed strategy — trim where
  `cleanup.policy` contains `delete`, capture-delete-recreate-assert where it is
  pure `compact` — and an `--red-check-topic-config` flag makes the assertion
  falsifiable on demand. It also now has a single EXIT trap that restores every
  scaled-down workload on an abort, so the quiesced-cluster residue described
  above should no longer need an operator step. **None of that has executed.**
  The script has not been run end to end since the change; only the trap's three
  cases were exercised, and in a standalone harness rather than in the script.
  Until it has round-tripped once on the lab — baseline, reset, re-seed, same
  counts — treat it exactly as the bullet above says: do not run it here.
* **Seven state topics are `compact` on `edge-01/02/03/hq` and `delete` on
  `region-east`** — one broker of five, all seven, same direction, so it is one
  creation path that did not carry the topic configs. Independent of the reset,
  that broker's state topics grow without bound and anything rebuilding from the
  start of those logs reads full history instead of latest-per-key. **Check it here
  before the recording** (`rpk topic describe <topic> -p` per broker); if the work
  cluster reproduces it, the regional tier is the one that shows it.
* **Images: nothing needs a push, and CI has already built everything.** As of
  2026-09-27 every relevant commit is pushed and green — the kind gate is in the
  published `runtime-bundle:latest` (built on that commit; the bundle COPYs
  `openddil-demo/dynamic-mappings/`), and the zstd→lz4 producer fix is in the
  published `cm-service` and `logistics-fusion-service` images. The chart pins
  `:latest` with `pullPolicy: Always`, so **a fresh deploy here picks all of it up
  with no chart change.** The lab is the case that needs care, not work: its
  cm/fusion pods predate the fixed images by hours, so they still run the
  zstd-producing code until those deployments are restarted.
