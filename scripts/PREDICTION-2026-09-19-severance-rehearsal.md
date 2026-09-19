# Prediction — severance rehearsal against revision 50

**Written before either cut.** §E's previous measurements are from 2026-09-09,
against a substrate that has since been wiped and re-bootstrapped three times,
had retention declared, and had every PEP replaced. Those are measurements
about a different system, so this rehearsal re-derives them.

Predicted **by classification**, not by recalling the last run's numbers — the
point is whether the architecture's rules still produce the behaviour, not
whether the same digits reappear.

---

## The rules being predicted from

1. **A tier serves from its own store, its own authorizer, its own broker.**
   (ADR-0032 §d.) A severed tier therefore keeps serving; its local
   timestamps keep advancing.
2. **A tier derives only from its direct ingest; parents consume children's
   derived state.** (ADR-0032 §a.) Cutting a link stops the *flow of derived
   state upward*, not the child's own derivation.
3. **An absence is rendered as an absence, with its age.** (ADR-0036 clause 1,
   ADR-0035 class 2.) A parent that stops hearing shows its last known value
   *labelled old* — never a blank, never a silently-current number.
4. **`--from-parent` cuts the tier's uplink; its subtree stays attached.**
5. **A relay under severance buffers by design**, so its stall probe must not
   fire — the destination-unreachable term exists for exactly this.

## Dimension 1 — region-east severed from HQ (`--from-parent`)

| # | subject | prediction | rule |
|---|---|---|---|
| 1.1 | region-east's own store | **stays live**, newest sample advances | 1 |
| 1.2 | region-east's derived tables | **keep computing** — severity moves | 1, 2 |
| 1.3 | region-east's view of its edges | **stays fresh** — subtree attached | 4 |
| 1.4 | rollup composition | **still 3 partials / 14 assets** | 4 |
| 1.5 | HQ's view of region-east | **freezes at its pre-cut value and ages** — rows do NOT disappear | 3 |
| 1.6 | edge-01 / edge-02 | **unaffected** | 4 |
| 1.7 | uplink relay restarts | **0** — buffering is the designed mode | 5 |
| 1.8 | on heal | HQ converges **non-vacuously** — the age must be seen to fall from a large number, not merely be small | 3 |

**The discriminating one is 1.5.** Three outcomes, one correct:
*fresh* means a path still crosses the boundary and the sever is a lie;
*gone* means absence rendered as deletion; *stale with rows* is correct.

## Dimension 2 — edge-01 severed (`--from-parent`, default)

edge-01's parent is **region-east**, not HQ. That is the whole point of the
cutover, so the discriminating measurement is at the REGION.

| # | subject | prediction | rule |
|---|---|---|---|
| 2.1 | edge-01's own store | **stays live**, serving locally | 1 |
| 2.2 | region-east's view of edge-01 | **goes stale**, rows retained | 3 |
| 2.3 | region-east's view of edge-02 | **stays fresh** | 2 |
| 2.4 | **two ages on one screen** | edge-01 stale **while** edge-02 fresh — the pair, not either alone | 2, 3 |
| 2.5 | HQ, two-hop | edge-01 stale **while the region's own rollup is recent** | 3 |
| 2.6 | bridge relay restarts | **0** | 5 |
| 2.7 | on heal | region's edge-01 view converges non-vacuously | 3 |

**2.4 and 2.5 are the beat.** A single "last updated" collapses *a quiet edge*
and *a downed region uplink* into one number, and they call for opposite
responses — one sends someone to the edge, the other to the region.

## What would falsify each

* **1.1 / 2.1 frozen** → the tier does not actually serve independently; the
  severance story is wrong, not the script.
* **1.5 / 2.2 fresh** → a path crosses the boundary that the NetworkPolicy
  does not cover. This is the failure the toxiproxy version had, and finding
  it again would mean the default-deny has a hole.
* **1.5 / 2.2 gone** → an absence rendered as a deletion. Worse than stale:
  a parent that deletes what it cannot see is claiming the assets do not
  exist.
* **1.7 / 2.6 non-zero** → the stall probe's destination-reachable term is not
  doing its job, and a severance becomes a crash loop.
* **1.8 / 2.7 vacuous** → convergence that cannot be seen to move is
  indistinguishable from a screen that was never stale.

## Run discipline

* Pre-flight 5 of 5 before the first cut and after the last heal.
* One dimension at a time, healed and verified before the next.
* **The run ends connected.** A rehearsal that leaves the fleet severed has
  tested the cut and not the heal, and the heal is half the claim.
