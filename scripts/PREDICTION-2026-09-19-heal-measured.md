# Prediction — dimension 2, with the heal step ON

**Committed BEFORE the cut.** Baseline re-measured immediately before writing,
at `03:16:36Z`: region sees edge-01 8 rows / **0s** and edge-02 6 rows / **0s**;
HQ sees edge-01 8 / 0s, edge-02 6 / 1s, rollup 3 / 7s; edge-01's own store
8 rows / 0s; bridge `Running restarts=7`; `bridge-group-edge-01` Stable,
TOTAL-LAG **6**.

## What this run is for

Not to re-prove severance — that held 6 of 7 on 2026-09-19. It is to turn
**heal-to-fresh** from a number that depended on where the heal happened to
fall inside a CrashLoopBackOff window into a measured property.

So the cut must be **long enough for the relay to reach the 300s cap**: the
ladder is 10+20+40+80+160 = **310s of backoff** before the cap is entered, so
a cut of **at least 7 minutes** guarantees the heal lands in a capped window
— the condition under which the default path is at its worst and the flag has
something to prove.

## Predictions

| # | prediction |
|---|---|
| 3.1 | edge-01 serves locally throughout — its own store stays **0–3s**, 8 rows |
| 3.2 | region's edge-01 view **stale, rows retained** — 8 rows, age ≥ **420s** by heal |
| 3.3 | region's edge-02 view stays **fresh**, 6 rows, 0–3s |
| 3.4 | both ages on one screen — the beat |
| 3.5 | two-hop at HQ: edge-01 stale by roughly the cut length **while the region's own rollup stays fresh (<60s)**, because region→HQ is untouched |
| 3.6 | **the relay crash-loops into the cap.** `on` restarts the site, so a NEW bridge pod starts at `restarts=0`; by heal it should read **5–7** and its last gap should be ~300s |
| 3.7 | `bridge-group-edge-01` TOTAL-LAG climbs far above the baseline 6 — predict **>1500** after ~7–8 min |
| 3.8 | **DISCRIMINATING — heal with `--restart-relay-on-heal`.** The relay pod is deleted and replaced, so no backoff is waited out. **Region's edge-01 view returns to <5s within 90s of the heal**, against a default-path range of 0–300s that depends only on timing luck |
| 3.9 | lag drains back to single digits after heal |
| 3.10 | end state **connected: 0 sever policies, pre-flight 5 of 5**, bridge Running |

## Failure modes, named in advance

* **Cut too short to reach the cap** → 3.6 shows a last gap well under 300s.
  The heal figure would then be measuring an uncapped window and must not be
  reported as the with-flag number. Re-run longer rather than reinterpret.
* **The flag finds no relay** → the script says so explicitly and restarts
  nothing; any heal figure from that run is a default-path figure.
* **Heal-to-fresh still slow with the flag** → the backoff was not the
  binding constraint, and the 300s story is wrong or incomplete. That would
  be the interesting result, and it falsifies the reason the flag exists.

## What this cannot establish

That the relay would recover *without* the flag in under 300s — this run
deliberately does not take the default path, because the default path's worst
case was already measured on 2026-09-19 (311s observed gap) and re-measuring
it costs five minutes of a severed edge to learn nothing new.
