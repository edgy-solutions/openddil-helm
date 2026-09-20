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
bash scripts/check-derive-stage.sh 60            # must say COMPLETING
python scripts/check_tier_feed.py openddil       # must exit 0
bash scripts/check-shape-sizes.sh openddil       # read path: shapes under ceiling
bash scripts/check-releasability-completeness.sh -n openddil   # every store by default
```

**If `check-advancing` reports any stage FROZEN, do not record.** That is the
outage that ran invisible for 3½ hours; it is cheap to fix by restarting the
named component and expensive to discover mid-take.

**If `check-derive-stage` says NOT COMPLETING, do not record either — whatever
the other three say.** On 2026-09-17 all nine advancing stages were green and
45 consumers were clean while fusion had received zero invocations, ever. The
other checks cannot see that: they measure whether topics advance, and the
derive stage sits between two of them. Consumed is not completed.

**The gate covers every store by default now** — it used to default to the
root and need `--all-tiers`, the checklist invoked the narrow form, and that
run was once recorded as readiness while two tier stores held unlabelled
rows. `--root-only` is the narrow answer you now ask for by name.

**`check-derive-stage` must run BEFORE the gate**, not merely with it: it
publishes the verdict the gate reads to decide whether an empty
`tactical_events` is *sparse* (the fleet is quiet) or *stopped* (the producer
died). A verdict older than 30 minutes is refused, so the order in that block
is load-bearing rather than tidy.

**And if `check-shape-sizes` fails, do not record.** Every check above this
line measures the WRITE path. On 2026-09-18 all of them were green while
every panel on every screen read FEED UNAVAILABLE, because one table's shape
had grown to 10 MiB and the PEPs serving it were being OOMKilled. Nothing in
the suite measured a byte of what the read path carries. This one does.

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

## READ THIS BEFORE BEAT 3 — the one indicator that disagrees

`sever-tier.sh` cuts with a **NetworkPolicy**. The LINK UP / LINK DOWN
indicator on the screens is driven by `hq_link_severed`, which probes
**toxiproxy's `hq-link`** — the frontend's WAN toggle, a different mechanism
entirely.

**So during a script-driven cut the indicator will read LINK UP while the
data visibly stops.** Measured 2026-09-19 through a full severance: the flag
stayed `false` the whole time, while `bridge_group_lag` climbed 2713 → 3020
and `probe_healthy` went false beside it — both live, both correct.

Two honest ways to handle it, and one dishonest one:

* **Drive the beat from the WAN toggle instead**, so the indicator agrees
  with the story. Simplest if the toggle severs what you want severed.
* **Say plainly what it tracks** — "that indicator follows the WAN simulator;
  the buffer depth climbing is the real reading" — and point at the buffer.
* **Do not let it pass unremarked.** This demo's whole claim is that the
  screens refuse to show something they cannot support. An indicator
  contradicting the story, in the beat about honest degradation, is the one
  thing it cannot afford.

Recorded as a finding, not fixed: whether that flag should track reachability
rather than the simulator is a semantics decision, not a typo.

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

**Choose the heal mode before you start. Both are honest; they demonstrate
different things, and the difference is visible on camera.**

**Option 1 — DEFAULT. Shows the real worst case.**

```
bash scripts/sever-tier.sh edge-01 off openddil
```

Convergence is **seconds to ~5 minutes**, and which one you get is a race you
do not control. The relay initialises its Kafka output lazily, so if it
happened to be running when the cut landed it retries in place and returns in
seconds; if it booted into the cut it exited, crash-looped, and is sitting in
a **CrashLoopBackOff capped at 300s** that does not end early just because the
network came back. Measured 2026-09-19: a 311s gap, and the heal landed
25–45s before the timer expired — the relay returned 36s later **by luck of
timing, not by reacting.**

*If you take this option, say so while it converges*, because a heal that
takes four minutes looks like a broken demo and is in fact the system telling
the truth: **the relay holds no state, so losing it is safe — and the cost of
that choice is paid in reconnect latency, not in data.** That is a better
sentence than silence, and it is the same honesty the staleness indicators
exist to demonstrate.

**Option 2 — MEASURED. Shows convergence, not a timer.**

```
bash scripts/sever-tier.sh edge-01 off openddil --restart-relay-on-heal
```

Replaces the relay pod on heal so no backoff is waited out. **Measured 8s**
(2026-09-19: heal `03:26:19Z`, region's edge-01 view 2s old at t+8s, lag
2534 → 5). Use this if the recording needs a predictable close.

**Do not present Option 2 as the system self-healing in 8 seconds.** It is the
operator clearing a backoff, and the flag is off by default precisely so that
choice stays visible.

Either way: **say the number moved.** Region's edge-01 view goes from minutes
stale to seconds — convergence that cannot be seen to move is
indistinguishable from a screen that was never stale.

*Close:* four tiers, one codebase, each authoritative for its own subtree;
partitioned by entitlement, degraded honestly under a cut, converged on heal.

---

## Optional beat — the negative case (~30s)

Log in as `observer.unlisted` / `demo`. Authentication succeeds; the screen
serves nothing. **Authentication is not authorisation**, and the subject who
is entitled to nothing sees nothing rather than everything.

## Do not, during the recording

* **Do not `helm upgrade` — now for TWO reasons.**
  * **UD-14**, narrowed 2026-09-19 to "rollout tested, not reproduced" (92
    consumer groups snapshotted across a rollout: 0 wedged). Narrowed, not
    closed — one clean rollout is not proof against an intermittent wedge.
  * **The wipe hook fires on every upgrade**, and now covers all four
    Restates rather than only the root. Correct and safe on the lab, where
    Restate state is rebuildable — and it means an upgrade mid-session
    discards CM history and re-bootstraps. Not something to do on camera.
* **Do not restart `faust-regional`** — ~2 minutes of changelog recovery,
  during which the region emits no rollups.
* **Do not narrate `asset-telemetry-windows`** — still `investigate`, still
  empty, not part of the story.
* **If the tactical event feed is empty, that is SPARSE, not broken.** Events
  fire on transitions; a stable fleet emits none, and cm-service deliberately
  will not re-emit while a status holds. The gate distinguishes this from a
  stopped producer by checking the derive stage, so a blank feed alongside a
  green pre-flight is the fleet being quiet. Say that plainly if asked —
  it is a better answer than narrating around it, and it is the same honesty
  the staleness indicators are there to demonstrate.
* **Do not explain the four root-side reachbacks** unless asked; they are
  correct at this stage and retire with their own components.

## If something looks wrong on camera

Stop and check rather than narrate around it. Every panel in this demo is
built to render an absence as an absence, so **a screen that looks wrong
probably is** — and the recording is worth less than the property that makes
it worth recording.
