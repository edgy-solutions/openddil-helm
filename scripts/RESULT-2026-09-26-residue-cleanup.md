# RESULT — the aggregate residue is cleared

2026-09-26, ~21:26–21:32 Z, on `edgy-lab`. Closes the item that stood open as
"yours" in `HANDOFF-2026-09-26.md` and as unfixed in
`WORK-DEPLOY-revision-51.md` §4. Predicted first in
`/c/tmp/rev51-run/26-PREDICTION-residue-cleanup.md`; that file was not edited
afterwards.

## What was done

1. `kubectl scale deploy openddil-faust-regional-region-east --replicas=0` —
   pod gone, deploy `0/0`.
2. A **tombstone** produced to the changelog on the **`openddil-redpanda-region-east-0`**
   broker — the correction that made this a real fix rather than an accepted
   no-op against the frozen HQ twin:

   ```
   rpk topic produce region-region-east-aggregator-region_region_east_assets_latest-changelog \
     -k '"dis:1:1:1099"' -Z
   ```

   `Produced to partition 0 at offset 9345227`; high-watermark 9345227 →
   9345228. Verified on the wire before scaling back up:

   ```
   KEY="dis:1:1:1099" VALUE_BYTES=0 OFFSET=9345227
   ```

   Key JSON-quoted as the live records are, value length **0** — a true
   tombstone, not an empty-string record.
3. Scaled back to 1. Recovery replayed ~105k records and logged
   **`Recovery complete`** with **0** error or traceback lines.
4. Deleted the orphaned rows the upsert-only projector cannot remove:
   `DELETE 1` × 3 tables × 2 stores = **6 rows**.
5. **Restarted the aggregator once more** and re-measured, which is what makes
   this durable rather than momentary.

## Measured against the predictions

| # | prediction | measured | |
|---|---|---|---|
| 2 | table keys after recovery | **14** (7 + 1 + 6) | PASS |
| 3 | classes emitted | **3** — ATL, `ATL,BDR`, BDR; no `''` | PASS |
| 4 | `asset_count` sum | **14** (was 15) | PASS |
| 5 | recovery duration ~4–10s | **51s** (21:27:21 → 21:28:12) | **MISS** |
| 6 | `''` rows still present before the DELETE | yes, frozen | PASS |
| 7 | `''` rows after the DELETE | **0** on both stores | PASS |
| 8 | completeness gate still passes | **ALL 4 STORES PASS**, 7 tables, zero unlabelled, exit 0 | PASS |
| 9 | pods non-healthy at end | **0** (64 Running, 6 Completed) | PASS |
| 10 | other 14 assets unchanged in shape | 7 / 1 / 6 throughout | PASS |

**The user's "3/14" is confirmed: 3 classes, 14 assets.**

## The single cleanest piece of evidence

The tombstone's effect is visible as a *frozen* row beside *advancing* ones,
before anything was deleted. Two samples of `region_fleet_summary` 45s apart,
after recovery:

| class | `asset_count` | `observed_at` sample 1 | `observed_at` sample 2 |
|---|---|---|---|
| `''` | 1 | 21:15:59 | **21:15:59 — frozen** |
| ATL | 7 | 21:15:59 | 21:29:12 |
| `ATL,BDR` | 1 | 21:15:59 | 21:29:12 |
| BDR | 6 | 21:15:59 | 21:29:12 |

`21:15:59` is the last emission before the scale-down. So the three real classes
resumed emitting and the `''` class stopped — which distinguishes "the key is
gone from the table" from "the row is stale for some other reason". This is the
measurement the earlier over-reading needed: a timestamp that *stops* while its
siblings advance is evidence about a specific key, where an advancing timestamp
alone only proves the heartbeat is alive.

## Confirmed across a restart

Scaled 0 → 1 again at ~21:30. `Recovery complete`, **0** error/traceback lines.
Both stores, freshly written at **21:31:54**:

```
ATL|7        ATL,BDR|1        BDR|6
```

**The `''` class did not return.** That is the point of the restart: the
tombstone lives in the changelog, so every future recovery replays the delete.
The fix is durable rather than a one-off edit of a materialised row — and it is
durable *because* it was a tombstone and not a `DELETE`, which is why the
supported semantics were worth waiting for the permission.

## The miss, recorded as a miss

Prediction 5 said recovery would take ~4–10s, from an earlier observation of
"~5s replaying ~111k records". It took **51s**. The earlier figure was almost
certainly a *warm* recovery reading few records; this one read from offset `-1`
and replayed ~105k. Also worth separating, because I conflated them at first:
the deployment reported `readyReplicas: 1` after **4s**, while recovery was
still 50s from finishing. **Readiness is not recovery** — a check that waits on
the deployment and then measures state will read a half-recovered table. For
the work cluster, wait on `Recovery complete` in the log, not on `1/1`.

## What is still not cleared

The three ingress `compact` topics still retain a last record for
`dis:1:1:1099`. Unchanged and deliberately out of scope — inert unless a
consumer group is reset or a store is rebuilt from the topics. Still an
attended job, and now the *only* remaining trace of the key.
