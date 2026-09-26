# Prediction — revision 51 onto `edgy-lab`, written before the upgrade

Written **2026-09-26, before any write to the cluster.** Everything in the
"measured at rev 50" column was measured tonight against `edgy-lab`; everything
in "predicted at rev 51" is written down here *first* so the deploy is settled
by measurement rather than by argument afterwards.

Chart: `openddil-demo-0.1.56` (live, confirmed on 63 pods) → `0.1.58`
(`openddil-helm@38140e8`, working tree clean).

Upgrade invocation, with the values re-passed as the package requires:

```bash
helm upgrade openddil ./openddil-demo -n openddil \
  -f /c/tmp/rev51-run/values-upgrade-base.yaml \
  -f /c/tmp/rev51-run/wipe-on.yaml
```

`values-upgrade-base.yaml` is rev 50's live user-supplied values, captured with
`helm get values`. `wipe-on.yaml` is the one thing added: top-level
`restate.ephemeralOnUpgrade: true`.

## Gate (§0b) — passed before deploying

| | lines of `restate-wipe` rendered |
|---|---|
| captured values **+ flag** | **11** ✅ expected |
| captured values alone | **0** |

**Rev 50's values contain no `restate.ephemeralOnUpgrade` at all.** Under 0.1.56
it defaulted to true, so the wipe happened by itself; under 0.1.58 it defaults
to false. Upgrading with the captured values unchanged would have rendered 0
wipe lines and wiped nothing, silently. That is the failure §0(b) was written
for, and it was live here.

## Baseline measured at rev 50

| what | measured |
|---|---|
| pre-flight | **5 of 5 green**, `edgy-lab` asserted by every script |
| advancing | 6 stages advancing, 0 frozen over 60s |
| tier feed | edge-01 15/15, edge-02 15/15, region-east 11/15 |
| completeness | 4 stores pass, 0 unlabelled rows |
| partition | liaison **14**, operator.atlantia **8**, operator.borduria **7** (16 passed / 0 failed) |
| origin rollup | ATL 8 / BDR 6, shared `dis:1:1:1000` → ATL-only 7 / shared 1 / BDR 6 |
| consumer groups | **92 group-on-broker rows** (`pre-51`), same as rev 50's baseline |
| pods | 0 non-healthy |
| sever policies | 0 |
| `telemetry_latest_state` | 14 rows |
| variants | RCV-M 2, AH-64E-V6 2, M1A1 2, M1A2-SEPv3 2, M2A3-Bradley 2, HMMWV-M1151A1 2, UH-60M 1, CH-47F-BlockII 1 |
| CM baselines | 3 non-null: `dis:1:1:1001`, `dis:1:1:1006`, `dis:2:1:1001`; both `…:1004` ids have none |
| releasability | ATL/{} 7, ATL/{BDR} 1, BDR/{} 6 |
| region rollup critical | ATL **2**, ATL+BDR **0**, BDR **1** (total 3) |
| `tactical_events` | 0 rows |
| `region_fleet_summary` | 3 rows |
| CM status | NOT_MISSION_CAPABLE 3, UNSPECIFIED 11 |

## Predicted at rev 51

| # | prediction | expected |
|---|---|---|
| 1 | relabels | exactly **2** ids differ: `dis:1:1:1004`, `dis:2:1:1004` RCV-M → AH-64E-V6 |
| 2 | fleet size | 14 → **14** |
| 3 | per variant | RCV-M 2 → **0**, AH-64E-V6 2 → **4**, all others unchanged |
| 4 | CM baseline mismatches | **0** — the 3 baselines above keep their variants |
| 5 | wear clears | ATL critical **2 → 1** (`dis:1:1:1004` clears) |
| 6 | `dis:2:1:1004` | clears nothing — was not critical |
| 7 | releasability | unchanged: 7 / 1 / 6 |
| 12 | `tactical_events`, `region_fleet_summary` | unchanged: 0 and 3 |
| 13 | Restate tuple+variant | discarded — the flag **is** being passed (11 lines) |
| — | pod templates rolled | **95** — the label is being removed, so every one changes |
| — | pods non-healthy at end | **0** |
| — | consumer groups | `WEDGED` **0** at every sample; mid-roll `STATE`/`GONE` expected |

## Two check-back queries in the package cannot run as written

Found by running them tonight, against rev 50, before the deploy. §2 says every
row is "a prediction from reading code. None has been measured" — these are the
cost of that.

* **Row 4** — `SELECT asset_id, baseline_id, platform_variant FROM asset_cm_state`
  → `ERROR: column "platform_variant" does not exist`. `asset_cm_state` has no
  such column. Corrected by joining, and the baseline above was captured with it:

  ```sql
  SELECT c.asset_id, c.baseline_id, t.platform_variant
    FROM asset_cm_state c JOIN telemetry_latest_state t USING (asset_id)
   WHERE c.baseline_id IS NOT NULL ORDER BY 1;
  ```

* **Row 9** — `SELECT DISTINCT dis_entity_type FROM telemetry_latest_state`
  → `ERROR: column "dis_entity_type" does not exist`, and this one is not a
  naming slip: the raw DIS tuple is **not stored in this table at all**.
  `provenance` carries `source_protocol`, `producer_id`, `ingest_time`,
  `sample_time`, `classification`, `originator_nation` — no tuple. So "all 14
  ids change their raw DIS tuple" is **not verifiable from `telemetry_latest_state`**
  and needs the raw topic or `asset-logistics-status`. Row 9 is recorded as
  unverified rather than passed or failed.

* **Row 5's expected value is ambiguous.** It says "region critical count 2 to
  1", but since ADR-0029 `region_fleet_summary` is partitioned by releasability
  class and reports three rows, not one. Total critical is **3**, the ATL slice
  is **2**. The prediction matches the ATL slice; it is being checked back as
  ATL 2 → 1, with the total recorded alongside.

## What would stop the deploy

* Gate ≠ 11 → do not upgrade. (Measured 11. Cleared.)
* `WEDGED` across three consecutive samples → roll back to 50 and record.
* A half-rolled cluster is ruled out as an end state: either 51 settles with 0
  non-healthy, or it goes back to 50.

Rollback prerequisites captured: `values-before-51.yaml`, `variants-rev50.txt`.
`helm history` is blocked in this session, so revision 50's existence is taken
from the 2026-09-19 handoff rather than confirmed live — noted as the one
unverified rollback input.
