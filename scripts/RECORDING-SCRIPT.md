# Recording script — beat order

Four browser profiles, four logins, two connected beats (the C2 picture; a
fault report to an action), two cuts, two heals. Roughly 18–22 minutes of
recording. Every number below was measured on 2026-09-09 unless dated
otherwise (BEATS 2a and 2b: 2026-10-03); if one disagrees on the day, **stop
and check rather than narrate around it** — that disagreement is the finding.
Lines marked `<dry run: …>` are placeholders the dry run fills in; do not
record over one that is still open.

Commands assume `KUBECONFIG=~/git/edgy-infra/ansible/kubeconfig` and
`cd ~/git/openddil/openddil-helm`.

## Caveats from the full run-through (2026-10-05) — read before recording

Every beat was run in order with four profiles. BEAT 3 was cut from the WAN
slider and again with `sever-tier.sh`; BEAT 5 with `sever-tier.sh`. Where the
beats below disagree with what was measured, the measurement is here:

* **BEAT 0:** the advancing check can report `region rollups … FROZEN` over
  its 20 s window while the rollup is moving: it emits in bursts. Re-run
  once; a second FROZEN is real.
* **BEAT 2 numbers have moved** (the fleet gained one ATL asset): **Ada sees
  9, the liaison 15**. Bram sees **6 on the Edge-02 screen** and **7 on the
  HQ screen**. Region partials are `ATL` 8, `ATL,BDR` 1, `BDR` 6 (sum 15).
* **Region screen header** reads `AREA OF RESPONSIBILITY: REGION-EAST 0
  ASSETS` (sometimes `—` for the region) while the list below reads `AOR
  ASSETS (15)`. The header counts assets placed on the map, and there is no
  FOB topology. Point at the list, not the header.
* **An edge screen can show `LINK: STALE` for a second at rest.** Measured
  once in 150 s on one edge screen, link healthy, on two separate runs. The
  cause is the browser, not the link: over plain HTTP a browser opens at most
  six connections to a host, the edge page holds eight live feeds, and the
  link row waits its turn for up to ~20 s. The region screen's feeds change
  every second and do not show it. If it shows on camera, say it is the
  screen's feed, not the link.
* **The LINK indicator now follows reachability** (probe plus the age of the
  last exchange), so it agrees with the story under the slider AND under
  `sever-tier.sh`. Measured times to flip: **region ~10 s, the HQ view of
  the HQ-attached edge ~16 s**; back up in **~9 s and ~15 s**. Leave that
  long before pointing at a screen.
* **BEAT 3 from the slider** (supervisor only: `liaison.coalition` on the HQ
  screen): no `SEVERED and PROVEN` and no 60 s wait; nothing restarts. The
  region screen stays reachable and reads severed. **The edge screens stay
  `LINK UP`**: their link is to the region, which is still there.
* **BEAT 3 from `sever-tier.sh --from-parent`** restarts the region's pods
  and closes its ingress: **the region screen becomes unreachable** (502 at
  login) for the length of the cut, and **both edge rows read severed for
  ~5 s** while their parent restarts. Use the slider for BEAT 3.
* **BEAT 4 from the slider:** HQ converges in **under 10 s** (measured 464 s
  stale → 4 s), not ~2 minutes. Still say the number moved.
* **BEAT 5 needs `sever-tier.sh edge-01`.** The slider has one link and
  cannot cut edge-01 from the region. Under the script cut **edge-01's own
  screen is unreachable** (502 at login), so show the beat from the region
  and HQ screens: edge-01 reads severed ~8 s after its probe fails, and
  edge-02, the region and HQ stay `LINK UP` throughout.
* **The HQ-attached edge is invisible.** Under a cut HQ keeps edge-03 fresh
  (1–5 s) while the tier edges go stale, but edge-03's only asset is
  unlabelled and shown to no one, so no screen draws its row or its
  HQ-ATTACHED label. Do not promise it on camera.
* **BEAT 6 options 1 and 2** are about the relay's backoff after a
  `sever-tier.sh` cut. `--restart-relay-on-heal` brought edge-01 back in
  ~5 s after the heal was proven.
* **At rest, HQ's region rollup row** can trail the edge rows by ~25 s
  (bursty emission). It is not a stall.

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

**For BEATS 2a and 2b, also before the camera:**

* The TAK device has the connection package imported
  (`tak-client-certs.sh` output, `docs/tak-client-setup.md` §3–§4) **and the
  stream enabled** — the package imports it disabled. The device's server
  entry shows connected.
* **No `helm upgrade` between the last fault report and the take.** Every
  upgrade wipes Restate, and fault reports are not yet replayed from the
  topic: after an upgrade the asset carries its BIT fault only, and BEAT 2b's
  report must be filed again (measured 2026-10-03: the BIT-only event
  re-appeared 3.5 minutes after the egress pods started).
* **A scenario reset clears filed reports too**, by design. The BIT-only
  event came back 21 s after the reset's restore (measured 2026-10-03). Wait
  5 minutes after an upgrade or a reset before rolling, so the HQ pane shows
  the BIT-only event before BEAT 2b files the report.

## BEAT 1 — four profiles, four logins (before any cut)

Separate browser profiles, not tabs — they need separate cookies.

| profile | URL | login |
|---|---|---|
| **HQ** | `<hub-host>` | `liaison.coalition` / `demo` |
| **Region** | `region-east.<hub-host>` | `operator.regioneast` / `demo` |
| **Edge-01** | `edge-01.<hub-host>` | `operator.atlantia` / `demo` |
| **Edge-02** | `edge-02.<hub-host>` | `operator.borduria` / `demo` |

`<hub-host>` is the deployment's hub ingress host; each tier is served at `<tier>.<hub-host>`.

**All four must be logged in before the first cut.** Keycloak is at the root;
a severed tier cannot mint sessions.

*Narration:* four nodes, one codebase, each serving from its own store.

*Identity, rung 1 — say it here, because BEATS 3 and 5 prove it:* each tier
**decides locally and enforces locally**, against its own policy engine and
its own copy of the entitlements, so a severed tier keeps answering for the
people already signed in to it — **and it cannot log anybody new in.** That
last clause is why all four logins happen now.

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

## BEAT 2a — the C2 picture: the fleet on TAK, and what crossed the boundary (~3 min)

Connected; no cut yet. Two screens: the **TAK device** and the **HQ view**.

1. **TAK device — the fleet with readiness.** 9 tracks, `dis:1:1:1000`–`1008`
   (measured 2026-10-03; `1005` is destroyed and still shown — a C2 viewer
   needs to see the loss). Nine is right, not eight. The destroyed track
   stays on the picture because it says destroyed: operational status and
   reporting status are two columns so that it can. **Point at `1005` and
   say:** "that one's dead and still beaconing." Readiness reads as
   `<dry run: how a track shows readiness on the device — icon, colour, remarks>`. `<dry run: whether
   1008's array fault is visible on the device; point at it only if so>`.
2. **The connection is the credential.** The device holds a client
   certificate for exactly one CN; a device without it, or with a cert the
   server does not list, is refused at the TLS handshake (measured
   2026-10-03: no cert → *certificate required*, other device's cert → *bad
   certificate*, 0 bytes either way).
3. **HQ view — the egress admission pane.** "**N of M admitted**", a refused
   count, and a **withheld** line. Measured 2026-10-03 for the C2 destination,
   one viewer at a time at the hub:

   | viewer | admitted | refused | withheld |
   |---|---|---|---|
   | `liaison.coalition` | 9 | 6 | 1 |
   | `operator.regioneast` | 9 | 6 | 1 |
   | `operator.atlantia` | 9 | 0 | 1 |
   | `operator.borduria` | 1 | 6 | 1 |

   Show two of these: the HQ profile (the liaison) and `operator.borduria`
   in a **fifth browser profile** at `<hub-host>`, logged in before any cut.
   `<dry run: confirm the fifth profile, or name the viewer switch used>`.
4. **Say what each number means:**
   * **admitted** — released to that destination, because the record's label
     allows it;
   * **refused** — the record exists and this viewer may see it, but its label
     does not reach the destination's nations (`no_nation_overlap`), so it did
     not cross;
   * **withheld** — records with no label at all: counted, never described.
     Not even the liaison is shown what they are.

*The beat:* the boundary keeps a ledger, and each viewer reads only the part
of it about records they could see anyway. Bram's 1 of 7 is the same gate,
reading the same records, as the liaison's 9 of 15.

## BEAT 2b — one fault, connected: from a technician's report to an action (~3 min)

Connected; no cut yet. Screens: **Edge-01** (Ada, `operator.atlantia`) and
**HQ**.

1. **Edge-01 — Ada files a fault report** on `dis:1:1:1008`: slot
   `tr_module`, fault code `MRAD-ARR-0417`, a one-line note. The form answers
   with an event id (HTTP 202).
2. **Within about a minute, the event crosses the boundary** toward the
   consumer's destination. It carries the asset's picture and the spares
   view: four sites with on-hand counts and lead times, and the **nearest
   spare: region-east, 2 on hand, 3 days** (measured 2026-10-03; every lead
   time is from the parts-availability stand-in, and the event says so,
   `lead_time_source: stand-in`).
3. **The same report from Bram's side** (`dis:2:1:1001`, a BDR asset) is
   released to a destination whose nations include BDR, and **refused** by an
   ATL-only one, `no_nation_overlap` (measured 2026-10-03). Optional on
   camera; it is the same ledger as BEAT 2a.
4. **HQ — the action arrives** on `<actions pane>` (the released-records pane
   the deployment configures for the action destination):
   `<dry run: the action shown — task, part, source of the part — and the
   time from report to action>`.
   `<dry run: whether the figure the action cites is shown with the faulted
   section highlighted; until then, do not mention a figure>`.

*The beat:* `<dry run: one sentence, from what the action actually says>` —
the report was filed at the edge, crossed the boundary once, under a label,
and came back as an action, and HQ can show which records went out and which
did not.

## Before BEAT 3 — what the LINK indicator tracks

The LINK indicator on every screen follows **reachability**: the tier's own
probe of its uplink, plus the age of the last exchange over it, with
hysteresis so one late exchange does not flip it. It no longer follows the
WAN simulator alone, so a cut made by either mechanism reads the same way.
It takes **~10 s** to read severed on the region and **~16 s** for HQ's view
of the HQ-attached edge; wait that long before pointing at a screen.

## BEAT 3 — dimension 1, region cut from HQ (~4 min)

On the HQ screen as `liaison.coalition`, move the **WAN slider** to cut.

**Watch, in this order:**

1. **Region screen — still live, and says it is cut.** Its sample time keeps
   advancing and its uplink reads severed within ~10 s. It is serving from
   its own store, its own authorizer, its own broker.
2. **Region still receiving its edges.** Fleet counts hold; the rollup keeps
   updating. *The region lost its parent, not its children.*
3. **HQ screen — stale, with an indicator.** HQ's region view freezes at its
   pre-cut value and the age grows. **Not wrong, not empty** — the last thing
   HQ knew, labelled as old.
4. **Edge screens — unaffected**, `LINK UP`: their uplink is the region.

*The beat:* a severed tier is not a failed tier. HQ says "I last heard this
12 minutes ago," which is true, rather than showing a number it cannot
support or a blank where a fleet was.

## BEAT 4 — heal (~1 min)

Move the WAN slider back. HQ's region view converges in **under 10 s**, and
the region's indicator reads `LINK UP` again within ~10 s. **Say the number
moved** — minutes stale to seconds — because convergence that cannot be seen
to move is indistinguishable from a screen that was never stale.

## BEAT 5 — dimension 2, edge-01 cut (~4 min)

```
bash scripts/sever-tier.sh edge-01 on openddil
```

Expect `SEVERED and PROVEN` (~40 s; the script restarts edge-01's pods).
**Do not show edge-01's own screen**: the cut closes its ingress too, so it
will not load. Show the beat from the region and HQ screens.

**Watch the discriminating pair — this is the strongest beat in the demo:**

1. **Region screen — edge-01 reads severed, edge-02 stays `LINK UP`.**
   Edge-01's assets go stale while edge-02's stay fresh: two groups of rows
   on one screen with different ages. Measured: 4m46s vs 0.6s.
2. **HQ — the two-hop read.** Edge-01 stale by minutes, **while the region's
   own rollup is seconds old**.

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
