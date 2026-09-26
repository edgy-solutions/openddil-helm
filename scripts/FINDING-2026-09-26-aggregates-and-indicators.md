# Finding 03 — a withdrawn asset survives in the rollups, and two freshness
# indicators point the wrong way during a cut

Measured on `edgy-lab` at revision 51 (chart `openddil-demo-0.1.58`), 2026-09-26,
during item 4's severance re-rehearsal. Three separate findings, grouped because
all three are things a C2 screen shows wrongly while every gate passes.

---

## 3a. Deleting an asset's source rows does not withdraw its contribution
## from an aggregate

This extends `FINDING-2026-09-26-no-asset-eviction.md` ("no eviction") from the per-asset tables into the
rollups, where it is worse, because the rollups are what gets rendered.

§E of `RECORDING-READINESS.md` records `region_fleet_summary` as **3 partials /
14 assets**. Tonight it reads **4 partials / 15 assets**, at HQ and in
region-east's own copy, and the fourth row is the residue of the injected
`dis:1:1:1099` that item 3 removed:

| region_id | class | assets | degraded | originator_nation | releasable_to |
|---|---|---|---|---|---|
| region-east | `''` | 1 | 1 | NULL | `{}` |
| region-east | … | 1 | … | NULL | `{ATL,BDR}` |
| region-east | … | 7 | … | NULL | `{ATL}` |
| region-east | … | 6 | … | NULL | `{BDR}` |

1099 has **no source rows anywhere** — `telemetry_latest_state`,
`asset_logistics_status`, `asset_cm_state` and `tactical_events` were all
verified empty of it, on all four stores, and its Restate Virtual Object was
cancelled and its state cleared on all three servers that held it. The row
persists anyway, and region-east's copy was still **advancing** (`updated_at`
moving) with the asset count stuck at 1.

The mechanism: the projector **upserts per releasability class** and has no
operation that removes a class whose membership has fallen to zero. The primary
key is `(region_id, releasability_class)`, so a class that ever existed owns a
row forever. This is the aggregate-shaped case of the same absence the no-eviction finding
names — the pipeline has no deletion semantics — but the per-asset version is at
least invisible once the asset stops being queried, whereas an aggregate row is
**summed into what the operator sees**. The fleet reads 15 assets in a 14-asset
fleet.

Note the empty class is not a second bug: 1099 was injected without a
releasability declaration, so `''` is the correct class for an undeclared asset.
The finding is that the class outlives its only member.

### The completeness gate passes this correctly, not by oversight

Worth stating precisely, because "a gate that misses it" is the wrong lesson.
`check-releasability-completeness.sh:532`:

```
AGGREGATE_TABLES=" region_fleet_summary region_top_factors region_wear_trends "
```

For these tables the test **inverts**: `releasable_to` must be non-null and
`originator_nation` must be **NULL**. A nation on a rollup is the finding there,
because a rollup that claimed authorship would bypass ADR-0043 §4's disjunctive
predicate. The residue row has nation NULL and `releasable_to {}` — non-null,
empty — so it satisfies the aggregate rule exactly. The gate is right. The cost
of the exemption is that **no gate in the suite can see a stale aggregate
partition**, and none is claimed to.

### Why this matters at work and not only here

At work `restate.ephemeralOnUpgrade` is false, so the blunt lever that would
have cleared this — the upgrade wipe — is switched off (see the no-eviction finding). A single
spurious or misconfigured entity on the wire therefore leaves a permanent
phantom partition in the rollups that survives deleting the asset, survives the
upgrade, and is invisible to the completeness gate. Removing it is a direct
`DELETE` against each tier store that holds a copy, per region.

---

## 3b. An "HQ freshness" indicator computed over the whole table cannot see a
## single-edge cut

Measured at both cuts:

| indicator during the cut | region-east cut | edge-01 cut |
|---|---|---|
| HQ `telemetry_latest_state` **TOTAL** age | **254s → 305s, frozen** ✅ detects | **0s** ❌ blind |
| HQ age **filtered to the severed edge** | 254s frozen | **260s → 305s, frozen** ✅ |
| HQ age for the **peer** edge | frozen (same subtree) | 0s ✅ correctly unaffected |

Cutting region-east freezes the whole table, because both edges sit in its
subtree, so a total-freshness number happens to work. Cutting one edge leaves
the peer edge feeding HQ, and `max(last_sample_at)` over the table is pinned to
**now** by the healthy edge while the severed edge's 8 rows sit 5 minutes stale.

Any dashboard tile of the form "HQ last updated" is therefore a **region-cut
detector that silently passes a single-edge cut** — the more likely failure of
the two. The per-edge read is the one that has to be on the screen.
`check-severance-acceptance.sh` gets this right: its `HQ_NEWEST` filters
`where edge_id='${TIER}'`.

This is the same shape as the `hq_link_severed` finding already in §E (that flag
probes toxiproxy's `hq-link`, which a NetworkPolicy cut does not touch, so the
on-screen LINK indicator stays UP through a proven cut). Two of the three
obvious "is the link healthy" indicators contradict a real severance.

---

## 3c. Staleness gets worse for ~50s **after** the heal

Dimension 1, healed 15:50:38Z, HQ's newest sample:

```
15:50:56Z  2026-09-26 15:42:51.798  age=485
15:51:11Z  2026-09-26 15:42:51.798  age=500
15:51:27Z  2026-09-26 15:42:49.297  age=518   <- newest went BACKWARDS
15:51:42Z  2026-09-26 15:51:42.276  age=0     <- converged
```

Two things to read here. First, convergence is **64 seconds** (row 1.8), and it
arrives as a step, not a ramp. Second, and the part that matters on camera: the
edge buffer replays **oldest-first**, so for the first ~50s after the heal HQ is
writing rows whose sample times are from just after the cut, and
`max(last_sample_at)` can **regress** — here from 15:42:51 to 15:42:49 — pushing
the staleness number *up* while recovery is in fact underway.

An operator who heals and watches staleness as the recovery indicator sees it
get worse before it snaps to zero, and the natural reading of that is that the
heal did not take. The indicator that moves promptly and monotonically is the
one `sever-tier.sh` already prints — root reachability — and the backlog
draining is visible as rows arriving at all, not as the max advancing.
