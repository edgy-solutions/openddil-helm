# Finding — the residue key, the broker it lives on, and two blind checks

Measured 2026-09-26 between ~20:05Z and ~20:36Z on `edgy-lab`, after
`kubectl scale`, `helm history`, `helm get` and `helm status` were permitted.
Everything here is a first-hand read. Three items correct earlier records of
mine, and one corrects a procedure that would have failed silently.

---

## 1. The residue key is `dis:1:1:1099`, and it is now measured

A range-bounded scan of the live changelog returned **111,976 retained records
over 15 distinct keys**, the 15th being `"dis:1:1:1099"`. Keys are
**JSON-quoted** strings on the wire, confirmed against live records.

The `''` class cannot be any of the 14 real assets: every one carries a
non-empty `originator_nation` (ATL x8, BDR x6), and
`_partition_by_audience` is a strict partition (`buckets.setdefault(...).append`),
so the 14 fall exactly into ATL 7 / `ATL,BDR` 1 / BDR 6. The `''` class is a
**15th contributor**, not a double-count of a real one. An earlier framing of
mine that briefly entertained a double-count is settled against.

## 2. The live changelog is on the region-east broker — the HQ copy is a stale twin

**This is the correction that matters.** The procedure recorded in
`HANDOFF-2026-09-26.md` and `WORK-DEPLOY-revision-51.md` named the changelog
*topic* but not the *broker*. There are **two topics with that exact name on two
different brokers**:

| broker | HIGH-WATERMARK | retained records | holds `1099`? |
|---|---|---|---|
| `openddil-redpanda-region-east-0` | 9,326,629 → moving | **111,976** | **yes** |
| `openddil-redpanda-hq-0` | 14,368,522, **frozen** | **14** | no |

The aggregator's env var is `REGIONAL_HQ_BROKERS`, and the app is built with
`broker=f"kafka://{hq_brokers}"` — but it resolves to the **region-east** broker.
The name says HQ; the wire says region-east. Its output topic
(`region-fleet-summary`) is likewise advancing on the region-east broker.

So a tombstone produced to the HQ broker would have been accepted, changed
nothing, and left the residue in place — a silent no-op that looks like a
completed fix. **Aim at the region-east broker.**

The HQ-broker twin is itself worth cleaning up: a same-named, frozen changelog
is a trap for exactly this class of work.

## 3. `rpk topic consume -o start` under-reads here — use the range form

`rpk topic describe -p` reported `LOG-START-OFFSET 0`, but `-o start` returned
records beginning at offset **14,368,492** — the last 30 offsets only. Twice
tonight that produced "14 keys, no 1099" and twice it was **not evidence of
absence**. It is the same error recorded earlier in the run, re-encountered from
a different direction.

The reliable form is the **range**: `-o <start>:<end>`, which terminates cleanly
at the end offset (exit 0) instead of blocking for records that compaction has
removed. `-n <count>` blocks whenever fewer than `count` records survive in the
range, which is what made the earlier attempts time out and look conclusive.

## 4. The wipe is a hook, so the two obvious post-deploy checks are both blind

`openddil-demo/templates/hook-restate-wipe.yaml` carries:

```yaml
"helm.sh/hook": pre-install,pre-upgrade
"helm.sh/hook-weight": "-100"
"helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
```

Two consequences for anyone trying to confirm after the fact that the wipe ran:

* **`helm get manifest` never shows it.** Hooks are excluded from the stored
  manifest. Measured: `grep -c restate-wipe` on the stored manifest returns
  **0 for revision 51** — the revision whose values *do* carry the flag and whose
  `helm template` gate rendered **11** lines — and 0 for revision 50. A zero here
  means nothing at all.
* **`kubectl get jobs` never shows it either**, because `hook-succeeded` deletes
  the Job on success.

So the only thing that sees the wipe is `helm template` — the §0(b) gate — and it
only sees it **before** the fact. There is no post-hoc confirmation from Helm or
from the Job. If you need to know afterwards whether the wipe happened, the
evidence has to come from Restate's own state, not from Helm.

A third consequence, on the rollback path: the hook registers **only**
`pre-install,pre-upgrade`, and nothing in the chart registers `pre-rollback`.
So `helm rollback openddil 50` fires **no wipe**, even though it returns the
chart to 0.1.56 where the flag defaults true. **Rollback is state-neutral for
Restate.** I had this backwards in a first draft of the work-deploy note and
corrected it against the annotations.

## 5. Revision 50 is a confirmed rollback target, and rev-50 values carry a decoy `restate:` block

`helm history` was blocked when the deploy prediction was written, so revision
50's existence was taken from the 2026-09-19 handoff. It is now confirmed
first-hand:

```
50   Fri Sep 18 22:58:31 2026   superseded   openddil-demo-0.1.56   Upgrade complete
51   Sat Sep 26 09:30:16 2026   deployed     openddil-demo-0.1.58   Upgrade complete
```

`helm status` reports `STATUS: deployed`, `REVISION: 51`. The one unverified
rollback input in `PREDICTION-2026-09-26-rev51-lab.md` is closed.

And the trap named in that prediction is live: revision 50's user-supplied values
contain **`tierNode.restate.useEmptyDir: false`** — a nested `restate:` block
that is *not* where the flag goes — while `ephemeralOnUpgrade` appears
**0 times** anywhere in those values. An operator reading live values at work
will see a `restate:` key and may reasonably put `ephemeralOnUpgrade` inside it,
which renders **0** wipe lines. The flag is **top-level** `restate:`.

## 6. Corrected: "the rollup is a live emission" proved less than I said

`_emit_rollups` is driven by `@app.timer(interval=_HEARTBEAT_S)` and recomputes
from `list(assets_latest.items())`. So `observed_at` and `updated_at` advancing
together every 30s proves **the heartbeat is alive** — it does *not* prove that
input is still arriving for any particular key. The residue needs no new input;
the timer re-publishes the whole table's classes forever. My earlier note that
the `''` row "is a live emission" is true but was over-read as evidence about
that key's input.

Related: `region_top_factors` does hold **4 classed rows** (BDR, ATL, `ATL,BDR`,
`''`). The earlier "4 rows but a per-class query returns none" was a fault in my
query, not in the data. That open item is closed.

## 7. The scale cycle is safe and fast; the produce is not permitted

Measured tonight, third cycle of the night:

* scale to 0 → pod gone, changelog frozen at 9,328,084
* scale to 1 → `Recovery complete` in **~5s** (20:34:54.857 → 20:34:59.665),
  replaying ~111k records
* 0 non-healthy pods, same 4 classes emitting afterwards

**The tombstone produce was denied** by the permission classifier
(`[Modify Shared Resources]`), so the cleanup remains unfinished and the cluster
was returned to its exact prior state rather than left with the aggregator at 0.
`kubectl scale` is now permitted; producing to a topic is not.

What is needed to finish it, on the **region-east** broker:

```bash
kubectl scale deploy openddil-faust-regional-region-east -n openddil --replicas=0
printf '\n' | kubectl exec -i -n openddil openddil-redpanda-region-east-0 -- \
  rpk topic produce \
  region-region-east-aggregator-region_region_east_assets_latest-changelog \
  -k '"dis:1:1:1099"' -Z
kubectl scale deploy openddil-faust-regional-region-east -n openddil --replicas=1
```

Then delete the leftover `releasability_class=''` rows from
`region_fleet_summary`, `region_wear_trends` and `region_top_factors` on **both**
the region-east store and HQ — the projector is stateless and upsert-only, so
those rows outlive the emission regardless of the tombstone.

Predictions for that run are written in `/c/tmp/rev51-run/26-PREDICTION-residue-cleanup.md`.
