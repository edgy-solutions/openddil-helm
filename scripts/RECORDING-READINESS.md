# Recording readiness — checklist with evidence

Every line carries the measurement that settles it, not an assertion that it
was checked. **Re-measured in full 2026-09-19 against the repaired cluster**
(helm revision 50), replacing the 2026-09-09 version whose §C and §D had both
been superseded.

**Re-run the five pre-flight checks immediately before recording.** Everything
else here is stable across a night; those five are the ones that have twice
been green while something was broken, and they are the ones that found it
both times.

---

## The pre-flight — five checks, in this order

```
bash scripts/check-advancing.sh openddil 40
bash scripts/check-derive-stage.sh 60        # publishes the verdict §5 reads
python scripts/check_tier_feed.py openddil
bash scripts/check-shape-sizes.sh openddil
bash scripts/check-releasability-completeness.sh -n openddil
```

**Measured 2026-09-19, all five green:**

| # | check | result |
|---|---|---|
| 1 | advancing, nine stages | every measured stage moved over 40s |
| 2 | **derive stage** | **COMPLETING** — see table below |
| 3 | tier feed | 45 consumers, zero unfed / unentitled / null-keyed |
| 4 | **shape sizes** | 81 / 45 / 83 KiB per client load, all under ceiling |
| 5 | completeness gate | **ALL 4 STORES PASS** (root + 3 tier) |

Derive-stage deltas over 60s:

| tier | asset-cm-state | asset-logistics-status |
|---|---|---|
| edge-01 | +101 | +16 |
| edge-02 | +75 | +12 |
| region-east | +177 | +56 |

**Two of these five did not exist a week ago, and each was added after a green
suite coexisted with an outage.** `check-derive-stage` after nine advancing
stages read green while fusion had received zero invocations, ever.
`check-shape-sizes` after that whole write-path suite read green while every
panel on every screen showed FEED UNAVAILABLE. Neither absence was visible
from inside the suite.

**The gate covers every store by default now.** It used to default to the root
and require `--all-tiers`; the flag existed, the checklist did not use it, and
that single-store run was once recorded here as readiness while two tier
stores held unlabelled rows. `--root-only` is now the thing you ask for.

## A. The four endpoints

| endpoint | evidence |
|---|---|
| `openddil.cortex.edgy-solutions.com` | ingress rule present, root/HQ |
| `edge-01.openddil.cortex.edgy-solutions.com` | ingress rule present |
| `edge-02.openddil.cortex.edgy-solutions.com` | ingress rule present |
| `region-east.openddil.cortex.edgy-solutions.com` | ingress rule present |

**DNS is the operator's step.** All four must resolve to the ingress IP
(`192.168.1.230`). If a screen does not load, check DNS before the cluster.

## B. Identity

Each PEP carries its own OIDC client, verified from the running deployments:

| PEP | `OPENDDIL_OIDC_CLIENT_ID` |
|---|---|
| root | `openddil-pep` |
| edge-01 | `openddil-pep-edge-01` |
| edge-02 | `openddil-pep-edge-02` |
| region-east | `openddil-pep-region-east` |

Five realm users, four entitled and one deliberately not:

| user | password | nations | role |
|---|---|---|---|
| `operator.atlantia` (Ada) | `demo` | ATL | edge-operator |
| `operator.borduria` (Bram) | `demo` | BDR | edge-operator |
| `operator.regioneast` (Rhea) | `demo` | ATL, BDR | regional-operator |
| `liaison.coalition` | `demo` | ATL, BDR | regional-operator |
| `observer.unlisted` | `demo` | — | **absent from the corpus on purpose** |

`observer.unlisted` authenticates and is entitled to nothing. **Authentication
is not authorisation**, and it is worth one beat if there is room.

## C. Releasability — re-measured 2026-09-19

* **Gate passes on all four stores**, zero unlabelled values anywhere.
* **Rollups partitioned by releasability class**, measured in the region store:

| partition | assets |
|---|---|
| `ATL` | 7 |
| `ATL,BDR` | 1 |
| `BDR` | 6 |

  summing, by subject entitlement, to:

| subject | partials served | assets |
|---|---|---|
| Ada (ATL) | `ATL` + `ATL,BDR` | **8** |
| Bram (BDR) | `BDR` + `ATL,BDR` | **7** |
| liaison / Rhea (ATL,BDR) | all three | **14** |

* **Phantom-partial detector** armed and red-checked.
* **Stale-key detector** armed and red-checked.
* **The projector now REFUSES a tactical event with no resolvable subject**
  and counts the refusal. The old `or ""` fallback wrote 18,562 empty-subject
  rows into one region store from a single burst; the relay bug that fed it
  was already fixed, and the refusal is what stops the next one.

## D. Pipeline liveness

See the pre-flight table above — that *is* this section now, and it is not
green unless the derive stage and the shape sizes are in it.

* **Restate: four nodes, zero restarts**, under an explicit RocksDB budget of
  50% of the container limit. The ~1600-restart era is fixed at its cause, not
  out-scaled: Restate had been budgeting RocksDB at 100% of its own cap.
* **PEPs: streaming, bounded, measured.** Four at ~17 Mi, zero restarts, where
  they had been OOMKilled in a loop at a 256 Mi cap.

## E. Severance, both dimensions — REHEARSED 2026-09-19 against revision 50

Predicted by classification **before either cut**
(`PREDICTION-2026-09-19-severance-rehearsal.md`), run one dimension at a time,
each healed and verified before the next, **ended connected** with pre-flight
5 of 5. This replaces the 2026-09-09 measurements, which were taken against a
substrate since wiped three times with every PEP replaced.

### Dimension 1 — region-east severed from HQ (`--from-parent`)

| # | prediction | measured | |
|---|---|---|---|
| 1.1 | region serves its own data | telemetry 0–1s old throughout | ✓ |
| 1.2 | region keeps computing severity | `asset_logistics_status` 1–3s old | ✓ |
| 1.3 | subtree stays attached | edge-01 **0s**, edge-02 **0s** at the region | ✓ |
| 1.4 | rollup still composes | **3 partials / 14 assets** | ✓ |
| 1.5 | **HQ stale, rows retained** | **14 rows, 403s stale**; rollups 3/14 at 422s | ✓ |
| 1.6 | edges unaffected | both producing throughout | ✓ |
| 1.7 | uplink restarts 0 | `tier-uplink-region-east` restarts **0** | ✓ |
| 1.8 | heal converges non-vacuously | **420s → 0s within 45s** | ✓ |

**1.5 is the discriminating one** — three outcomes, only one correct. *Fresh*
would mean a path still crosses the boundary and the sever is a lie; *gone*
would mean an absence rendered as a deletion. **Stale with rows** is what it
did.

### Dimension 2 — edge-01 severed (parent is region-east)

| # | prediction | measured | |
|---|---|---|---|
| 2.1 | edge serves locally | telemetry 1s old throughout | ✓ |
| 2.2 | region's edge-01 view stale, rows kept | **8 rows, 398s** | ✓ |
| 2.3 | region's edge-02 view fresh | **6 rows, 0s** | ✓ |
| 2.4 | **two ages on one screen** | **edge-01 398s beside edge-02 0s** | ✓ |
| 2.5 | **two-hop at HQ** | **edge-01 418s while the region's own rollup is 14s** | ✓ |
| 2.6 | bridge restarts 0 | **CrashLoopBackOff, 6 restarts — PREDICTION WRONG** | ✗ |
| 2.7 | heal converges non-vacuously | **635s → 0s within 45s** | ✓ |

**2.4 and 2.5 are the beat.** A single "last updated" collapses *a quiet edge*
and *a downed region uplink* into one number, and they call for opposite
responses.

### 2.6 — the prediction that was wrong, and what it actually means

Predicted 0 restarts on the reasoning that buffering is the designed degraded
mode. The bridge instead **crash-looped, 6 restarts**, and the log says why:

```
service closing due to: failed to init output ... kafka: client has run out of
available brokers to talk to: dial tcp ...:9092: connect: connection refused
```

redpanda-connect exits at **startup** because it cannot initialise its output.
It never runs long enough to be probed, so the stall probe's
destination-reachable clause is **not** falsified — it simply never ran. What
is falsified is the assumption that this relay buffers in place. It cannot;
it cannot start.

**That cost nothing, and this was verified rather than assumed.** The backlog
lives in the edge broker's own log, not in the relay: `bridge-group-edge-01`
reached **TOTAL-LAG 3020** while severed and drained to **3** on heal, group
Stable. *The Kafka topic is the buffer*, which is why a relay that cannot hold
state is still safe to lose. A relay that buffered in memory would be the
design worth worrying about.

### A finding for the camera: `hq_link_severed` tracks a different mechanism

edge-01's own `edge_buffer_status` row, updated every 2s throughout the cut,
reported **`bridge_group_lag` climbing 2713 → 3020** and **`probe_healthy`
false** — both true and both live. But **`hq_link_severed` stayed `false`**
while the edge was demonstrably severed.

It is not wrong so much as answering a different question:
`edge_buffer_monitor._probe_hq_link_severed()` probes **toxiproxy's
`hq-link`**, the frontend's WAN toggle. `sever-tier.sh` cuts with a
NetworkPolicy, which toxiproxy knows nothing about.

**On camera this matters:** the screens render a LINK UP / LINK DOWN indicator
from that field, so during a `sever-tier.sh` beat it will read **LINK UP**
while the data visibly stops. The buffer count and health flag beside it tell
the true story. Either drive the beat from the toxiproxy toggle so the
indicator agrees, or say plainly that the indicator tracks the WAN simulator
and the buffer depth is the real reading. **Do not let it pass unremarked** —
an indicator contradicting the story being told is the one thing this demo
cannot afford, given what the demo is about.

## F. Known and declared, so nothing on screen is a surprise

* **Declared idle** — weapons-capability (DIS carries no loadout, ADR-0038);
  `asset_telemetry_windows`; `inventory_items`; `asset_element_telemetry`.
* **Declared empty AT TIERS ONLY** — `asset_registry` (root-side component,
  ADR-0028). Scoped, so the root's copy keeps being checked.
* **Declared empty AT LEAVES ONLY** — `region_fleet_summary`,
  `region_top_factors`, `region_wear_trends`. Produced by a tier with
  children; scoped so the intermediate's copies keep being checked.
* **Declared SPARSE** — `tactical_events`. Events fire on TRANSITIONS, so a
  stable fleet emits none and the table is legitimately empty for stretches.
  **This is conditional, not a suppression:** the gate permits it only while
  `check-derive-stage` reports the producer completing, and refuses on a
  stopped producer OR on a verdict older than 30 minutes.
  If a panel is blank and the gate says `SPARSE, producer completing`, that
  is the fleet being quiet — say so plainly rather than narrating around it.
* **Retention is declared per tier kind**: root 720h, intermediates 168h,
  leaves 72h. The gradient was inverted until 2026-09-19 (the archival tier
  kept the least), which is why the root's alert feed used to empty in a day.
* **UD-14: rollout tested 2026-09-19, NOT reproduced.** See §G.
* **`hq_link_severed` tracks toxiproxy, not the NetworkPolicy sever** — it
  reads LINK UP during a `sever-tier.sh` cut. See §E.

## G. Things that will bite if forgotten

1. **LOG IN TO ALL FOUR SCREENS BEFORE THE FIRST CUT.** Keycloak runs at the
   root, so a severed tier cannot mint new sessions. An existing cookie works
   for its TTL (12h); a fresh login does not.
2. **Do not restart `faust-regional` mid-demo** — ~2 minutes of changelog
   recovery during which the region emits no rollups.
3. **Do not `helm upgrade` during the session — now for TWO reasons.**
   * **UD-14**, narrowed but still open (below).
   * **The wipe hook fires on every upgrade** and now covers all four
     Restates, not just the root. That is correct and safe on the lab, where
     Restate state is rebuildable — and it means an upgrade mid-session
     discards CM history and re-bootstraps, which is not something to do on
     camera. It is also the reason `ephemeralOnUpgrade` must stay false
     anywhere intent custody will ever live (ADR-0042).
4. **The sever script restarts the site** — deliberate, conntrack lets
   established connections through a new policy — so expect 30–60s of pods
   restarting after each cut.
5. **After any bulk correction to a store, restart that tier's Electric.**
   Electric serves from an append-only log: deleting rows APPENDS operations,
   and a cleanup can make the served shape *bigger*. Measured: a table went
   11 MB → 64 kB while its shape stayed at 10 MB until Electric restarted.
   `check-shape-sizes.sh` is the only instrument that sees this.

### UD-14, narrowed 2026-09-19

Four clients once sat at `1/1 Running` for 3.5 hours having stopped consuming.
Broker restart was exonerated by test (6s and 150s, clean recovery both
times); the helm rollout that preceded it had **never been tested**, because
nobody was watching the right thing while one happened.

**Now it has been.** `snapshot-consumers.sh` captured all 92 group-on-broker
rows before and after the revision-50 rollout (completed 03:59:54Z), then
re-checked every 10 minutes for the next **1h43m** — eight consecutive
samples through 05:42:43Z:

* **0 wedged** at every sample (Stable + committed frozen + lag waiting)
* **0 state changes, 0 groups disappeared**
* **0 containers terminated in the window** — checked against
  `lastState.terminated.finishedAt`, not the RESTARTS column, which counts
  lifetime restarts and would have reported nine pods that last restarted
  five days ago
* pre-flight **5 of 5** afterwards, derive stage still COMPLETING

**That narrows UD-14 honestly to "rollout tested, not reproduced."** It does
not close it, for a reason worth stating: the original wedge was *noticed*
at 3.5 hours, which is not the same as having *begun* at 3.5 hours, and this
window is 1h43m. One clean rollout is not proof against an intermittent
fault. The instrument now exists, so the next occurrence is caught in the act
instead of inferred hours later. **Keep rule 3.**
