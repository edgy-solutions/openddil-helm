# Recording script — beat order

Four browser profiles, four logins, two cuts, two heals. Roughly 12–15
minutes of recording. Every number below was measured on 2026-09-09; if one
disagrees on the day, **stop and check rather than narrate around it** —
that disagreement is the finding.

Commands assume `KUBECONFIG=~/git/edgy-infra/ansible/kubeconfig` and
`cd ~/git/openddil/openddil-helm`.

---

## BEAT 0 — pre-flight (before the camera)

```
bash scripts/check-advancing.sh openddil 30      # must exit 0, nine stages
py -3 scripts/check_tier_feed.py openddil        # must exit 0
bash scripts/check-releasability-completeness.sh -n openddil   # GATE PASSES
```

**If `check-advancing` reports any stage FROZEN, do not record.** That is the
outage that ran invisible for 3½ hours; it is cheap to fix by restarting the
named component and expensive to discover mid-take.

## BEAT 1 — four profiles, four logins (before any cut)

Separate browser profiles, not tabs — they need separate cookies.

| profile | URL | login |
|---|---|---|
| **HQ** | `openddil.cortex.edgy-solutions.com` | `liaison.coalition` / `demo` |
| **Region** | `region-east.openddil.cortex.edgy-solutions.com` | `operator.regioneast` / `demo` |
| **Edge-01** | `edge-01.openddil.cortex.edgy-solutions.com` | `operator.atlantia` / `demo` |
| **Edge-02** | `edge-02.openddil.cortex.edgy-solutions.com` | `operator.borduria` / `demo` |

**All four must be logged in before the first cut.** Keycloak is at the root;
a severed tier cannot mint sessions.

*Narration:* four nodes, one codebase, each serving from its own store.

## BEAT 2 — the partition, at rest (~2 min)

Show Ada and Bram side by side.

* **Ada sees 8 assets. Bram sees 7. The liaison sees 14.**
* Same screen, same role at their own tier, different fleets — **not two
  filtered views of one list; two different answers to the same query**,
  decided by the subject's entitlements and the data's labels.
* On the region screen: the rollup is composed of **three class partials**
  (`ATL` 7, `ATL,BDR` 1, `BDR` 6). Rhea sees all three summed to 14; Ada
  would see 8 of the same rollup.

*The beat:* the aggregate is no more visible than its least visible input.

## BEAT 3 — dimension 1, region cut from HQ (~4 min)

```
bash scripts/sever-tier.sh region-east on openddil --from-parent
```

Expect `SEVERED and PROVEN`. Then **wait ~60s** for the site to restart under
the policy before pointing at screens.

**Watch, in this order:**

1. **Region screen — still live.** Its sample time keeps advancing. It is
   serving from its own store, its own authorizer, its own broker.
2. **Region still receiving its edges.** Fleet counts hold at 14; the rollup
   keeps updating. *This is the point of `--from-parent`: the region lost its
   parent, not its children.*
3. **HQ screen — stale, with an indicator.** HQ's region view freezes at its
   pre-cut value and the age grows. **Not wrong, not empty** — the last thing
   HQ knew, labelled as old.
4. **Edge screens — unaffected.**

*The beat:* a severed tier is not a failed tier. HQ says "I last heard this
12 minutes ago," which is true, rather than showing a number it cannot
support or a blank where a fleet was.

## BEAT 4 — heal (~1 min)

```
bash scripts/sever-tier.sh region-east off openddil
```

HQ's region view converges within ~2 minutes. **Say the number moved** — 12
minutes stale to 20 seconds — because convergence that cannot be seen to move
is indistinguishable from a screen that was never stale.

## BEAT 5 — dimension 2, edge-01 cut (~4 min)

```
bash scripts/sever-tier.sh edge-01 on openddil
```

**Watch the discriminating pair — this is the strongest beat in the demo:**

1. **Edge-01 screen — still live**, serving its own assets locally.
2. **Region screen — edge-01's assets go stale, edge-02's stay fresh.** Two
   groups of rows on one screen with different ages. Measured: 4m46s vs 0.6s.
3. **HQ — the two-hop read.** Edge-01 stale by ~4m, **while the region's own
   rollup is 6 seconds old**.

*The beat, and say it plainly:* HQ can tell **a quiet edge from a downed
region uplink**, because it carries both ages instead of fusing them. Under
a single "last updated" those two situations are the same number — and they
call for opposite responses: one sends someone to the edge, the other to the
region.

## BEAT 6 — heal and close (~1 min)

```
bash scripts/sever-tier.sh edge-01 off openddil
```

Region's edge-01 view converges (measured 02:24:21 → 02:32:13, then 0.6s).

*Close:* four tiers, one codebase, each authoritative for its own subtree;
partitioned by entitlement, degraded honestly under a cut, converged on heal.

---

## Optional beat — the negative case (~30s)

Log in as `observer.unlisted` / `demo`. Authentication succeeds; the screen
serves nothing. **Authentication is not authorisation**, and the subject who
is entitled to nothing sees nothing rather than everything.

## Do not, during the recording

* **Do not `helm upgrade`** — UD-14: four clients once wedged for 3½ hours
  after a rollout, cause still open.
* **Do not restart `faust-regional`** — ~2 minutes of changelog recovery,
  during which the region emits no rollups.
* **Do not narrate `asset-telemetry-windows`** — still `investigate`, still
  empty, not part of the story.
* **Do not explain the four root-side reachbacks** unless asked; they are
  correct at this stage and retire with their own components.

## If something looks wrong on camera

Stop and check rather than narrate around it. Every panel in this demo is
built to render an absence as an absence, so **a screen that looks wrong
probably is** — and the recording is worth less than the property that makes
it worth recording.
