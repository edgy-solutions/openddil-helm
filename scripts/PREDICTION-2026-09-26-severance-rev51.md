# Prediction — severance re-rehearsal on revision 51, both dimensions

Written **2026-09-26, before either cut**, on `edgy-lab` running chart
**0.1.58** (revision 51, deployed and measured earlier today). Heal step on.
Ends connected, with pre-flight 5 of 5.

This does not re-predict §E row by row from scratch. Each of §E's rows is
**classified** by whether revision 51 can reach the mechanism it measures, and
the prediction follows from the class. A class is falsifiable: if a class-M row
moves, the classification was wrong, and that is the finding.

## The classification

**M — mechanism revision 51 cannot reach.** Predicted identical to §E.
Revision 51 changes exactly three things: `helm.sh/chart` leaves the pod
labels, `restate.ephemeralOnUpgrade` defaults to false (passed true here), and
five tier Topaz digests. None of them touches NetworkPolicy, the uplink and
bridge relays, the projectors, the brokers, or the staleness arithmetic.

**S — revision-51 sensitive.** Something revision 51 did touch.

**R — a race, unpredictable by construction.** §E already established the relay
is bimodal; a prediction that names one mode would be a guess dressed as a
prediction.

## The one S row, and why it is the row to check first

`sever-tier.sh` cuts by applying a default-deny NetworkPolicy whose
`podSelector` matches **`app.kubernetes.io/component`** (three places: the
subject set, the same-site ingress allowance, the same-site egress allowance).
Revision 51 removed a label from all 95 pod templates. Had the selector read
`helm.sh/chart`, or read the composite `openddil.labels`, the policy would now
select **nothing** — and a default-deny policy that selects nothing is not an
error. It applies cleanly, reports success, and cuts **nothing**. Every
downstream row would then read "fresh", which §E's row 1.5 specifically warns
is the signature of *a sever that is a lie*. The rehearsal would pass while
measuring an uncut cluster.

It is fine, and checked rather than assumed, twice:

* Revision 51's label work deliberately left `openddil.selectorLabels`
  untouched, because a changed selector is immutable and would fail the upgrade
  outright — so the selector key survives by design, not by luck.
* Measured live, before the cut: `region-east status` resolves a **12-component
  site**, and all three simulator-exception selectors match running pods —
  `logistics-sim`, `dis-sim-edge-northpoint`, `dis-sim-edge-capeverdant`. The
  simulator exception matters as much as the subject set: if it silently
  matched nothing, the site's own sensor feed would be cut, the tier would
  freeze, and the run would report a false negative that looks exactly like the
  failure the test is for.

**Predicted: the cut bites. Row 1.5 reads stale-with-rows, not fresh.**

## Dimension 1 — region-east severed from HQ (`--from-parent`)

| # | class | predicted |
|---|---|---|
| 1.1 | M | region serves its own data, telemetry 0–1s throughout |
| 1.2 | M | region keeps computing severity, `asset_logistics_status` 1–3s |
| 1.3 | M | subtree stays attached — edge-01 and edge-02 both ~0s at the region |
| 1.4 | M | rollup composes — 3 partials / 14 assets |
| 1.5 | **M, discriminating** | **HQ stale, rows retained** — 14 rows, age ≈ cut duration |
| 1.6 | M | both edges producing throughout |
| 1.7 | S′ | `tier-uplink-region-east` restarts **0** — but the baseline is now 0 as of today's 09:2x roll, so "0" is a weaker statement than it was on 2026-09-19; the number recorded is restarts **accrued during the cut** |
| 1.8 | M | heal converges non-vacuously, back to ~0s within ~45s |

## Dimension 2 — edge-01 severed (parent is region-east)

| # | class | predicted |
|---|---|---|
| 2.1 | M | edge serves locally, ~1s throughout |
| 2.2 | M | region's edge-01 view stale with rows kept — 8 rows |
| 2.3 | M | region's edge-02 view fresh — 6 rows, ~0s |
| 2.4 | M | two ages on one screen |
| 2.5 | M | two-hop at HQ — edge-01 old while the region's own rollup is young |
| 2.6 | **R** | relay mode **not predicted**. Mode A (exits, crash-loops, 300s backoff cap) or mode B (Running, retries in place) — a race on whether the Kafka output initialised before the output went away. **What is predicted is the discriminator**: `lastState.terminated` empty ⇒ B; `restartCount` climbing ⇒ A. Heal-to-fresh is **seconds under B, 0–300s under A**, and a slow heal is not a data-path finding until that field has been read |
| 2.7 | M, conditional on 2.6 | lag drains to single digits once the relay is actually up; the topic is the buffer |
| — | M | `hq_link_severed` stays **false** through both cuts while the data visibly stops — it probes toxiproxy's `hq-link`, which a NetworkPolicy knows nothing about |

## What would stop the run

* Row 1.5 reading **fresh** → the cut is not biting; stop and check the
  selector before touching dimension 2, because every later row would be a
  true statement about an uncut cluster.
* A heal that does not converge after the 2.6 discriminator has been read and
  says mode B → a real finding; record it and stop.
* Anything left severed. **The end state is connected**, pre-flight 5 of 5.
