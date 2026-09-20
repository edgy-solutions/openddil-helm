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

**RE-RUN 2026-09-19 (later, fresh session): 5 of 5 again**, all four stores
pass. Deltas held their shape — edge-01 +99/+17, edge-02 +75/+14, region-east
+175/+60. §C re-measured and unchanged (ATL 7 / ATL,BDR 1 / BDR 6 → Ada 8,
Bram 7, liaison 14), all four ingress hosts present, Restate 4 nodes / 0
restarts, PEPs 4 / 0 restarts.

**One measured number moved: shape sizes are now 75 / 45 / 121 KiB** (was
81 / 45 / 83). The growth is region-east `tactical_events` — real rows under
the newly-corrected 168h retention, not Electric log accumulation: the table
reports 19 live tuples and **0 dead**, last autovacuum 2026-09-19. Still 17x
under the 2048 KiB ceiling, so it is a trend to know about rather than a
problem — but it is the number to re-read first if a panel ever slows.

**What the region-east `asset-cm-state` row does NOT establish.** Nothing at
region-east produces that topic. The tier bootstrap deliberately binds no
AssetCM subscription at an intermediate tier (*"NO DIRECT INGEST — detection
not bound to relayed raw topics; keeping 4 of 7 subscriptions"*), all four of
its live subscriptions sink to `AssetLogistics`, and `tier-cm-region-east` has
served **zero invocations** since it started. That row advances because the
edges bridge their state up: measured twice, edge-01 +99 and edge-02 +75 sum
to the region's +174 / +175, to within one message of sampling skew — while
`asset-logistics-status` over the same windows was +17/+14 at the edges
against **+60** at the region, because *that* one the region really does
derive. **So "6 advancing" is five completion terms and one arrival term.**
It is not a false green — a region fusion stall still freezes
`asset-logistics-status` and fails the check — but do not read it as evidence
that the region's CM service is working, and if it ever goes frozen, suspect
the **children** first. Recorded in `FOLLOW-UPS.md`, not fixed.

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

**IT DID COST SOMETHING, AND BEAT 6 IS WHERE IT SHOWS (measured 2026-09-19).**
"Cost nothing" was true of the DATA and false of the CLOCK. The relay
crash-looped into Kubernetes' **CrashLoopBackOff, which caps at 300s**, and a
container in backoff does not retry the moment the network returns — it waits
out the timer. Reconstructed from the live container status:

| | |
|---|---|
| pod created (sever restarted the site) | `15:50:12Z` |
| `restartCount` | **7** (8 runs; each died ~1s in, `exitCode 1`) |
| last failed run | started `15:56:09Z`, died `15:56:10Z` |
| next — and successful — start | `16:01:21Z` |
| gap | **311s** = the 300s cap plus scheduling |

The backoff ladder is 10 → 20 → 40 → 80 → 160 → **300 (capped)**, so the
final wait was the maximum one. The dimension-2 heal converged "635s → 0s
within 45s" from a cut that began at ~`15:50:12`, putting the heal at
roughly **`16:00:45`** — which lands about **25–45s before the 300s timer
expired at ~`16:01:10`**, in the last ~10% of the window. The relay came back
36s after the heal because it was nearly out of backoff anyway, **not because
it reacted to the heal.**

**Worst case is the whole window: up to ~300s.** Had the heal landed just
after the `15:56:10` crash instead of just before the timer expired, the
relay would have sat idle for a further five minutes with the network
perfectly healthy, and the region's edge-01 view would have stayed frozen for
all of it. **On camera that is BEAT 6 appearing not to converge.** If a heal
looks stuck, read `kubectl get pod -o jsonpath='{...lastState.terminated}'`
on the bridge before concluding anything about the data path — the lag drains
in seconds once the relay is actually up, as the 3020 → 3 above shows.

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
  **The feed IS empty right now, and it was checked rather than assumed
  (2026-09-19).** The newest tactical event at every tier is
  `2026-09-19 03:59`, ~22h ago, and the `tactical-events` watermark is frozen
  on all four brokers. That is the quiet fleet, not a dead producer: the two
  services that emit these — `tier-cm-edge-01` and `tier-cm-edge-02` — are
  being invoked continuously, **3926 and 4318 log lines per 30 minutes**, all
  `POST /invoke/AssetCM/observe` returning 200, while `asset-cm-state` keeps
  advancing. States are being recomputed and are holding, and cm-service will
  not re-emit while a status holds. **Row counts, if a panel is questioned:**
  root 11, edge-01 14, edge-02 3, region-east 19.
  **RETRACTED 2026-09-19, same day, before it was recorded as readiness.**
  An earlier revision of this bullet argued the feed is quiet *because*
  `tier-cm-edge-01` restarted at 15:50:18Z and emitted nothing, which a
  RAM-held cache would not have done. **That reasoning does not
  discriminate.** Silence after a restart is predicted equally well by
  durable suppression working AND by an emit path that has been dead since
  revision 50, and `POST /invoke/AssetCM/observe 200` does not separate them
  either — 200 is the handler returning, not an event being published.
  Nothing in the pre-flight touches the publish step. What replaces it:

  **The suppression mechanism is real, and its scope is narrower than
  "durable."** It is a `last_alerted_status` field persisted on the AssetCM
  Virtual Object, and `test_15_no_realert_on_stable_critical` pins it by
  restarting cm-service between two identical observations. But that state
  lives in **Restate's per-Virtual-Object journal, on the StatefulSet's
  PVC** — and `hook-restate-wipe.yaml` **deletes that PVC on every
  `pre-install,pre-upgrade`, for the root and all three tiers**, gated by
  `restate.ephemeralOnUpgrade`, which is **`true`** on this release. So:
  **durable across a restart, destroyed by an upgrade.**

  **That is what the 03:59 timestamp is.** Every event cluster in the whole
  retained history sits 45–90s after a helm upgrade, and there is not one
  event in between:

  | revision | deployed (UTC) | cluster |
  |---|---|---|
  | 47 | 09-17 12:01:13 | 12:02:00 |
  | 48 | 09-17 18:14:46 | 18:15:32–40 |
  | 49 | 09-19 03:42:51 | 03:43:43–51 |
  | 50 | 09-19 03:58:31 | 03:59:15–24 |

  Each cluster is **one event per non-nominal asset per axis** — at 03:59,
  CM discrepancies for `1001`, `1006`, `2:1:1001` (the three assets that
  carry a CM baseline) and logistics CRITICAL for `1002`, `1004` (the two
  the region rollup counts critical). The same subjects re-fire at every
  cluster because the wipe erased what had suppressed them. **These are
  re-emission artifacts of the upgrade, not fleet transitions.**

  **So is the feed sparse or is the emit path dead? STILL OPEN.** One
  injected `CmEvent` was fired at `dis:1:1:1000` to settle it. It did not:
  that asset has **no `baseline_id`**, and `_reanalyze` returns early when
  `not record.baseline_id`, so the handler returned **200 having done
  nothing** — no status change, no event, no log line. A mis-aimed test,
  not a result; CM baseline coverage is 3 of 14 assets (GD-14), which is what
  the target should have been picked for. **Treat the feed as unverified
  rather than as either answer**, and if a blank panel needs narrating on
  camera, say the events fire on transitions and the last burst was the
  deploy — which is true and checkable — rather than asserting a live
  producer this has not established.

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
