# Recording readiness — checklist with evidence

Every line carries the measurement that settles it, not an assertion that it
was checked. Dated 2026-09-09, against `edgy-lab`.

**Re-run the two gates immediately before recording** — `check-advancing.sh`
and `check_tier_feed.py`. Everything else in this file is stable across a
night; those two are the ones that were green four hours before the pipeline
was found dead, and they are the ones that found it.

---

## A. The four endpoints

| endpoint | evidence |
|---|---|
| `openddil.cortex.edgy-solutions.com` | Ingress rendered, root/HQ |
| `edge-01.openddil.cortex.edgy-solutions.com` | Ingress rendered |
| `edge-02.openddil.cortex.edgy-solutions.com` | Ingress rendered |
| `region-east.openddil.cortex.edgy-solutions.com` | Ingress rendered |

**DNS is the operator's step.** All four must resolve to the ingress IP
(`192.168.1.230`). The fourth was added on 2026-09-08; if the region screen
does not load, check DNS before checking the cluster.

## B. Identity

* **Per-tier OIDC clients exist and each PEP is wired to its own:** verified
  `openddil-pep-edge-01`, `-edge-02`, `-region-east` present in Keycloak
  (`kcadm get clients`), and each tier's PEP carries its matching
  `OPENDDIL_OIDC_CLIENT_ID`.
* **Five realm users**, four entitled and one deliberately not:

| user | password | nations | role |
|---|---|---|---|
| `operator.atlantia` (Ada) | `demo` | ATL | edge-operator |
| `operator.borduria` (Bram) | `demo` | BDR | edge-operator |
| `operator.regioneast` (Rhea) | `demo` | ATL, BDR | regional-operator |
| `liaison.coalition` | `demo` | ATL, BDR | regional-operator |
| `observer.unlisted` | `demo` | — | **absent from the corpus on purpose** |

`observer.unlisted` authenticates successfully and is entitled to nothing.
It is the negative case: **authentication is not authorisation**, and it is
worth one beat on camera if there is room.

## C. Releasability

* **Completeness gate PASSES** — 8 populated tables, **zero unlabelled**, and
  the three rollups classified `aggregate — composed, claims no originator`.
* **Rollups partitioned by releasability class**, and the arithmetic matches
  what each subject sees:

| subject | partials served | assets |
|---|---|---|
| Ada (ATL) | `ATL` + `ATL,BDR` | **8** |
| Bram (BDR) | `BDR` + `ATL,BDR` | **7** |
| liaison / Rhea (ATL,BDR) | all three | **14** |

* **Phantom-partial detector armed and red-checked** (PASSES → inject →
  FAILS naming the region → remove → PASSES).
* **Stale-key detector armed and red-checked** (inject `id='edge'` → `STALE
  KEY edge`, exit 1 → remove → clean).

## D. Pipeline liveness

* **`check-advancing.sh` green across all nine stages** — ingest, mapper,
  derived at both edges; region inbound; region rollups; HQ inbound.
* **`check_tier_feed.py` clean** — 45 rendered consumers, zero unfed, zero
  unentitled, zero null-keyed, zero stale-keyed; declared-idle
  `declared=2, held=2, investigate=1`.
* **Consumer census: 4 reachbacks**, all root-side (`asset-registry-edge-0N`,
  `logistics-sim-edge-0N`); **region-east zero**. Those four are correct by
  design at this stage and retire with their own components.

## E. Severance, both dimensions

Run 2026-09-09, predicted by classification before either cut, ended
connected. Full table in `PREDICTION-2026-09-08-two-dimension-severance.md`.

* **Region from HQ:** region served fresh data while severed, edges still
  reached it, rollups kept composing (3 partials / 14 assets), HQ went stale
  **with an indicator at its pre-cut value**, heal converged non-vacuously
  (12m stale → 20s).
* **edge-01:** edge served locally at 0.31s; at the region edge-01's rows
  went **4m46s stale while edge-02's stayed 0.6s fresh**; HQ attributed the
  two-hop staleness correctly (edge-01 4m47s stale, **region rollup 6s ago**).
* **Relay probes did not fire under severance** — 11 minutes severed, uplink
  restarts **0**, probe reporting *"destination unreachable — buffering, not
  stalled"*.

## F. Known and declared, so nothing on screen is a surprise

* **Declared idle — will never populate in this fleet, and the panels say
  so:** weapons-capability (DIS carries no loadout, ADR-0038).
* **Held (known defect, deferred):** `asset-element-telemetry` /
  `-inventory` — the logistics-sim profile cannot match DIS ids.
* **Investigate (open):** `asset-telemetry-windows` at watermark 0 on every
  broker. Prints on every feed check. Not blocking; do not narrate it.
* **Four root-side reachbacks** remain by design.
* **UD-14 open:** four clients once wedged at `1/1 Running` for 3½ hours.
  Broker restart is exonerated by test; a helm rollout is untested. **Do not
  run a helm upgrade during or immediately before the recording.**

## G. Things that will bite if forgotten

1. **LOG IN TO ALL FOUR SCREENS BEFORE THE FIRST CUT.** Keycloak runs at the
   root, so a severed tier cannot mint new sessions. An existing cookie works
   for its TTL (12h); a fresh login does not. A demo that severs and then logs
   in shows an identity outage nobody intended to demonstrate.
2. **Do not restart `faust-regional` mid-demo.** It replays its changelog on
   every start — measured at ~2 minutes, during which the region emits no
   rollups and its panels read as awaiting.
3. **Do not helm upgrade.** See UD-14.
4. **The sever script restarts the site.** That is deliberate — conntrack
   lets established connections through a new policy — so expect ~30-60s of
   pods restarting after each cut before the screens settle.
