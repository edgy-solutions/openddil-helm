# Prediction — scenario reset, before the script exists

**Date:** 2026-09-26 · **Status: PREDICTED, not measured.** Every number below
is written before the script runs, so the run can disagree with it.

A live demo that restarts a scenario twice needs a reset that is a mechanism,
not a ritual. Today the second run of the day starts with the first run's
fleet: every store upserts, the carrying topics compact, the Restate Virtual
Objects are durable by design, and the regional aggregator holds every key it
has ever seen.

---

## 1. What "reset" has to mean, stated before choosing tools

Five components hold scenario state, and they fail differently:

| # | component | why it survives a restart | where that was established |
|---|---|---|---|
| 1 | **Restate** | per-Virtual-Object journals on a PVC; `AssetLogistics` re-arms its own timer every tick, forever | `FINDING-2026-09-26-no-asset-eviction.md`; `asset_logistics.py:477` |
| 2 | **Topics** | the three carrying topics are `cleanup.policy=compact`, so the last record per key is retained indefinitely | same finding |
| 3 | **Stores** | 12 of 13 projector tables are `mode: upsert` with no `retention_hours`; latest state does not expire | `DESIGN-2026-09-26-asset-lifecycle.md` §2 |
| 4 | **Aggregator** | the Faust table is `store="memory://"` with a **changelog topic**; a pod bounce restores every key from it | `aggregator_app.py:121`; changelog delete measured 2026-09-26 |
| 5 | **Electric shapes** | shape logs are append-only, so a bulk delete must be followed by shape re-creation | `hooks/electric.ts`; the append-only rule |

**A reset that misses any one of them is not a reset, and misses it silently.**
That is why this is a script with a verification pass rather than a list of
commands in a runbook.

## 2. The multiplicity is the first finding, and it is larger than expected

Counted on `edgy-lab` at revision 51, read-only, before writing anything:

| component | instances | names |
|---|---|---|
| Postgres | **4** | `postgres-hq`, `tier-pg-edge-01`, `tier-pg-edge-02`, `tier-pg-region-east` |
| Restate (PVC-backed) | **4** | `restate-server`, `tier-restate-edge-01`, `tier-restate-edge-02`, `tier-restate-region-east` |
| Electric | **4** | `electric-sync`, `tier-electric-edge-01`, `tier-electric-edge-02`, `tier-electric-region-east` |
| Redpanda brokers | **5** | `hq` (36 topics), `edge-01` (27), `edge-02`, `edge-03`, `region-east` (16) |
| Faust | **5** | `faust-edge-{01,02,03}`, `faust-regional-{region-east,region-west}` |

So "clear Postgres" is four connections, "wipe Restate" is four PVCs, and
"clear the topics" is five brokers.

This is the same shape as the wipe hook's own 2026-09-17 correction —
*"EVERY RESTATE, NOT JUST THE ROOT'S"* — and as `check-advancing.sh`'s Connect
pods: **the script discovers its targets and never carries a hardcoded list**,
because a hardcoded list is what goes stale the day a tier is added, and the
omission then reads as a clean reset.

`edge-03` is deliberately asymmetric: a projector and a broker, no tier stack.
A script that assumes tiers are uniform either fails looking for
`tier-pg-edge-03` or skips `edge-03` altogether.

## 3. Mechanism per component, and why not the obvious alternative

### 3.1 Topics — trim, do not delete-and-recreate

The obvious move is delete + recreate. **Rejected.** A recreate must restate
every topic's partition count and cleanup policy, which means a second copy of
the chart's topic matrix living in a script — and a second copy drifts. When it
drifts, the reset recreates topics with the wrong config and the failure
surfaces later, as consumers that quietly stop.

`rpk topic trim-prefix` sets the partition's log start offset instead. It needs
**no knowledge of the topic's config at all**, so there is nothing to drift.
The offset is read per partition from the live high watermark, so the trim is
exact rather than guessed.

**Consequence, stated so the verification is not written wrong:** a trim does
**not** return the high watermark to 0. It makes the log start offset equal the
high watermark — zero *readable* records, with the offset counter intact. The
predicted value is therefore `log_start == high_watermark`, and a check
asserting `high_watermark == 0` would fail against a correct reset.

### 3.2 Aggregator — the changelog, not a bounce

Bouncing the Faust pods is not a reset: Faust replays the changelog on startup
and restores every key. The changelog topics must be trimmed **before** the
pods restart, or the restart re-reads them. The order is load-bearing, and
getting it backwards produces a reset that looks complete and is not.

### 3.3 Restate — PVC, and re-registration without the bootstrap package

Restate state is only clearable by scaling to 0, deleting `data-<sts>-0`, and
scaling back. On the way up, services must be re-registered. The chart does
that in post-install hook Jobs, which cannot be re-run out of band, and the
`openddil_bootstrap` package is mounted only into those Jobs — a call from any
other pod fails `ModuleNotFoundError`.

So the script registers through Restate's **admin HTTP API directly**. One
dependency (an endpoint) instead of two (an endpoint and a package that is not
there), and it is the same call the hook makes.

### 3.4 Stores — `DELETE`, never `TRUNCATE`, and never `audit_log`

`TRUNCATE` emits a single WAL message that Electric's client does not reliably
honour; per-row `DELETE` propagates. The net effect of getting this wrong is
"postgres says 0 rows and the UI still shows the old fleet", which is the exact
failure this script exists to prevent.

**`audit_log` is excluded, permanently.** It is the ADR-0029 decision log. A
reset that clears the record of who was allowed to see what is not a reset; the
one table whose purpose is to outlive operator acts must outlive this one. The
script carries it in an explicit exclusion list with that sentence beside it.

### 3.5 Electric — restart, because there is no volume

`electric-sync` and every `tier-electric-*` run with **no PVC and no mounted
volume** (`hub.yaml:99-120`), so shape logs live in the container filesystem.
Deleting the pod discards every shape and clients re-create them on the next
request against a new shape handle. No API call, no storage surgery.

## 4. Predicted zero counts

Written before the run. Each has the exact reading that confirms it.

| # | component | predicted after reset | how it is read |
|---|---|---|---|
| 1 | Restate, each of 4 | `0` keyed service states; the same service count registered again | admin API `/services` + state introspection |
| 2 | Topics, each data topic on 5 brokers | `log_start == high_watermark` (zero readable) | `rpk topic describe -p` |
| 3 | Stores, 13 tables x 4 Postgres | `0` rows in all but `audit_log`; `audit_log` **unchanged** | `SELECT count(*)` per table |
| 4 | Aggregator | the first rollup after restart carries `asset_count = 0` | `region-fleet-summary` record body |
| 5 | Electric, each of 4 | a new shape handle per shape; `0` rows returned | `/v1/shape?table=...&offset=-1` header + body |

And the claim the whole thing exists for:

> **Run a scenario, reset, re-run: the second run's baseline counts equal the
> first run's — not first plus second.**

Predicted equal on `telemetry_latest_state`, `asset_cm_state` and
`asset_logistics_status` row counts, and on the rollup's `asset_count`.

## 5. The red-check

A reset is only trustworthy if a *partial* reset is visibly not one. The check
skips exactly one component and shows the residue it leaves.

**Skipped: the aggregator's changelog** (`--skip-aggregator`). Chosen because
it is the component the obvious implementation misses, so the residue is not
hypothetical — it is what a reset built the natural way leaves behind.

**Predicted residue:** stores read `0`, topics read trimmed, Restate reads
clean — and the first rollup after the restart carries the **pre-reset**
`asset_count`, restored from the changelog. A fleet that is empty in every
store and full in the regional rollup.

If that residue does not appear, the red-check has failed and the aggregator
step was never load-bearing.

## 6. What this does not claim

* **Nothing about the work cluster.** `restate.ephemeralOnUpgrade` is `false`
  there and the tier layout differs. Predicted and measured on `edgy-lab` only.
* **Not a lifecycle mechanism.** This script is the one real delete in the
  system, and it operates on the *deployment*, never on an asset. Removing an
  asset because it left the fleet is the lifecycle question, and the lifecycle
  ADR's answer to it is "no deletes".
* **No claim that a trim equals an empty topic** for a consumer holding
  committed offsets past the trim point. Consumer-group handling is its own
  step and is verified separately.
