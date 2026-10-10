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

## Demo-day checklist — in this order; stop at the first miss

Run it from a shell where `kubectl` resolves against the demo cluster. Python 3.8 or later is needed on the
laptop; the name differs by platform (`python3`, `python`, or `py -3` on a Windows shell that has only the launcher),
so pick it once by running each candidate, not by trusting PATH (a Windows `python3` can be a store stub that
resolves and then fails):
```
PY=; for c in python3 python "py -3"; do $c -c 'import sys; sys.exit(sys.version_info < (3, 8))' 2>/dev/null && PY=$c && break; done
echo "PY=${PY:?no Python 3.8+ found: install one before the checklist}"
```
Pass: one `PY=` line. `$PY` stays unquoted below so `py -3` works.

**1. Pre-flight** (BEAT 0 says what each failure means):
```
bash scripts/check-advancing.sh openddil 30 && bash scripts/check-derive-stage.sh 60 \
  && $PY scripts/check_tier_feed.py openddil && bash scripts/check-shape-sizes.sh openddil \
  && bash scripts/check-releasability-completeness.sh -n openddil && echo "PRE-FLIGHT 5/5"
```
Pass: `PRE-FLIGHT 5/5`. Each check exits non-zero on a miss, so the chain stops at the first one.
The gate measures each store's effector-launch consumer itself (about a minute per store whose effector_launch is empty, so the chain can take ~5 minutes right after a reset); do not set OPENDDIL_EFFECTOR_CONSUMER_RESULT here, a caller-set file is read for every store and cannot name each store's group.

**2. Four logins** (the scripted round trip; then sign in the four browser profiles, BEAT 1):
```
H=<hub-host>
for p in "$H liaison.coalition" "region-east.$H operator.regioneast" "edge-01.$H operator.atlantia" "edge-02.$H operator.borduria"; do
  set -- $p; $PY scripts/oidc_login.py "https://$1" "$2" >/dev/null && echo "login $2 ok" || echo "login $2 FAILED"
done
```
Pass: four `ok` lines.

**3. Reset** and **4. Exercise restart**: one action, because the restart is refused unless this reset reached a
measured zero. Primary path: sign in as the supervisor and press **Restart exercise** in the exercise panel (the button
shows only with `exerciseControl.resetJob.enabled`). It runs the reset as an in-cluster Job, so no laptop is needed;
about 13 minutes on the lab. A second press while it runs is refused (`reset_running`). Then read the result:
```
J=$(kubectl -n openddil get jobs -l app.kubernetes.io/component=exercise-reset \
  --sort-by=.metadata.creationTimestamp -o name | tail -1)
kubectl -n openddil wait --for=condition=complete "$J" --timeout=25m
kubectl -n openddil logs "$J" | tail -1
kubectl -n openddil get cm openddil-exercise-reset-record -o jsonpath='{.data.record\.json}'
```
Fallback, from a laptop with the lab kubeconfig (same guards, same output):
```
bash scripts/restart-exercise.sh --release openddil --namespace openddil \
  --declare-unmeasured aggregator-region-fleet-summary
```
The one declared exception (on the Job too) is the region fleet summary aggregator; the output prints it as
`DECLARED UNMEASURED`, never as a pass. Any other declaration needs a reason before the recording.
Pass (3): the Job completes (or the fallback exits 0); no `RESET HALTED` in the log; the record reads
`"verdict": "PASS"` with `measured_zero_at` after the press. Pass (4): the last log line is
`RESTART SENT (adapter 200)`. `RESTART NOT SENT`, `RESTART REFUSED` or `RESTART NOT ACCEPTED` means the exercise did
not restart: do not record. A failed Job leaves `kubectl wait` to time out (`kubectl -n openddil get "$J"` shows it
at once), and its log ends with the `RESET HALTED` block naming the state; read it, and do not press again until it
is understood.
The reset stops and restarts every simulator whose Deployment carries the label `openddil.io/role=simulator`,
whatever its name. A simulator Deployment without that label keeps running through the reset and keeps its own
schedule; the reset prints a `NOT A PRODUCER` line naming each one it leaves running.

**5. TAK device connected:**
```
kubectl -n openddil exec deploy/openddil-tak-server -c tak-server -- python -c \
  "print(sum(1 for l in open('/proc/net/tcp').readlines()[1:] if l.split()[1].endswith(':1F99') and l.split()[3]=='01'))"
```
Pass: 1 or more (established connections on the TLS port 8089, `1F99` in hex), and the device's server entry shows
connected with the stream enabled. 0 means no device is on.
`<dry run: the count with the device connected>`

**6. Consumer endpoint reachable** (the egress forwarder's destination; the request carries no credential):
```
kubectl -n openddil exec deploy/openddil-egress-forwarder -c forwarder -- python -c '
import json,os,urllib.request as u,urllib.error as e
r=json.load(open(os.environ["OPENDDIL_FORWARD_CONFIG"]))[0]
try: print("consumer reachable, HTTP", u.urlopen(u.Request(r["url"],method="HEAD"),timeout=10).status)
except e.HTTPError as x: print("consumer reachable, HTTP", x.code)
except Exception as x: print("consumer NOT reachable:", type(x).__name__)'
```
Pass: `consumer reachable, HTTP <any code>`. A 401 or 405 still counts: the endpoint answered. `NOT reachable` means
stop. It prints no URL.

## Caveats from the full run-through (2026-10-05) — read before recording

Every beat was run in order with four profiles. BEAT 3 was cut from the WAN
slider and again with `sever-tier.sh`; BEAT 5 with `sever-tier.sh`. Where the
beats below disagree with what was measured, the measurement is here:

* **BEAT 0:** the advancing check can report `region rollups … FROZEN` over
  its 20 s window while the rollup is moving: it emits in bursts. Re-run
  once; a second FROZEN is real.
* **BEAT 2 numbers have moved** (the fleet grew to 20): **Ada sees 12, the
  liaison 20**. Bram sees **5 on the Edge-02 screen** and **9 on the HQ
  screen**. Region partials are `ATL` 11, `ATL,BDR` 1, `BDR` 8 (sum 20)
  (measured 2026-10-10, rev 136). The beats below carry these numbers.
* **Region screen header** now counts the fleet placed on the 3D scene, and
  the scene centres on the fleet when no FOBs are configured: the header
  read `20 ASSETS` against 20 live rows in the region store (measured
  2026-10-08, rev 118). It used to read `0 ASSETS`; that is fixed.
* **`LINK: STALE` at rest is an HTTP/1.1 effect, and the lab does not show
  it.** Over HTTP/1.1 a browser opens at most six connections to a host, the
  edge page holds eight live feeds, and the link row waits its turn. Served
  over HTTP/2 (TLS), the feeds share one connection: 0 `LINK: STALE` in 363
  one-second samples on two edge screens, link healthy. The same edge screen
  forced to HTTP/1.1 showed `LINK: STALE` once for ~10 s in 180 s (measured
  2026-10-10, rev 136). If a viewer's path downgrades to HTTP/1.1 (a proxy
  in between) and it shows on camera, say it is the screen's feed, not the
  link.
* **The LINK indicator now follows reachability** (probe plus the age of the
  last exchange), so it agrees with the story under the slider AND under
  `sever-tier.sh`. Measured times to flip: **region ~10 s, the HQ view of
  the HQ-attached edge ~16 s**; back up in **~9 s and ~15 s**. Leave that
  long before pointing at a screen.
* **Every link has its own row now.** HQ's link card lists edge-01,
  edge-02, edge-03 and region-east; the region's lists edge-01 and edge-02;
  each edge and the region carry their own uplink. Each row has a toggle
  and `LAT` / `JIT` / `BW` with `SET` and `CLR`. Any signed-in viewer can
  use them (the role gate is gone). Nothing restarts; every screen stays
  reachable. **The reset does not restore the rows or clear the toxics**:
  set every row back on and `CLR` every toxic by hand before the next beat.
* **BEAT 3 from HQ's region-east row** (measured 2026-10-10, rev 133): no
  `SEVERED and PROVEN` and no 60 s wait. The region screen stays reachable
  and reads `REGIONAL↔HQ: SEVERED`. **The edge screens stay `LINK UP`**:
  their link is to the region, which is still there.
* **BEAT 3 from `sever-tier.sh --from-parent`** restarts the region's pods
  and closes its ingress: **the region screen becomes unreachable** (502 at
  login) for the length of the cut, and **both edge rows read severed for
  ~5 s** while their parent restarts. Use HQ's region-east row for BEAT 3.
* **BEAT 4 from the slider:** HQ converged in **under 10 s** (measured
  2026-10-05: 464 s stale → 4 s), not ~2 minutes. Still say the number
  moved.
* **BEAT 5 from the region's edge-01 row** (measured 2026-10-10, rev 133):
  the row cuts edge-01 from the region without restarting anything, so
  **edge-01's own screen stays up** and reads `DDIL: LINK SEVERED`.
  `sever-tier.sh edge-01` is the heavier cut: it restarts edge-01's pods and
  closes its ingress, so edge-01's screen is unreachable (502 at login).
  Under either, edge-02, the region and HQ stay `LINK UP`.
* **A row heal flickers before it settles.** After turning a row back on,
  the heartbeats queued during the cut arrive in a burst: the row reads up
  while its data age is still minutes old, drops back to down once the
  burst ends, then reads up with fresh data. Measured 2026-10-10 (rev 136)
  on both heals: region-east at HQ up at +10 and +20 s, down at +30 s, idle
  and fresh by ~+2.5 min; edge-01 up at +20 and +30 s, down at +40 s, up and
  fresh (0.4 s) at +50 s. **Point at the healed row at ~+60 s**, not before.
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
$PY scripts/check_tier_feed.py openddil          # must exit 0 (PY: see the checklist)
bash scripts/check-shape-sizes.sh openddil       # read path: shapes under ceiling
bash scripts/check-releasability-completeness.sh -n openddil   # every store; probes each store's effector consumer itself
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

**The effector-launch producer is different.** The gate runs
`check-effector-consumer.sh` itself for each store, against that store's own
consumer group, so nothing needs to run before it for that table. Right after
a reset every `effector_launch` is empty, and measuring each store's own
consumer is what lets the gate pass then.

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

* **Ada sees 12 assets. Bram sees 5 at edge-02 and 9 at the hub. The
  liaison sees 20.** (Measured 2026-10-10, rev 136: Ada's radar draws 12,
  Bram's hub header reads `9 ASSETS`.)
* Same screen, same role at their own tier, different fleets — **not two
  filtered views of one list; two different answers to the same query**,
  decided by the subject's entitlements and the data's labels.
* On the region screen: the rollup is composed of **three class partials**
  (`ATL` 11, `ATL,BDR` 1, `BDR` 8). Rhea sees all three summed to 20; Ada
  would see 12 of the same rollup.
* **Region screen, 3D scene** — the fleet placed on the map, with the header
  counting what it placed: `20 ASSETS` against 20 live rows in the region
  store (measured 2026-10-08, rev 118). Click an asset to drill in.
* **One radar's condition, the same at every tier.** `dis:1:1:1008` steps
  through its condition on the simulator's schedule (120 s steps, a 2400 s
  cycle). At the `damage moderate` step edge-01 reads it CRITICAL from its
  appearance, and the HQ fleet summary's element counts for region-east read
  **160 critical / 1745 degraded**, the same as edge-01's bands for that
  asset (measured 2026-10-09, rev 130: edge, region and HQ equal on 20 of 20
  steps; again 160 / 1745 at all three on 2026-10-10, rev 136). HQ holds the counts, not the elements: the element tree stays at
  the owning edge and only its rollup crosses.

*The beat:* the aggregate is no more visible than its least visible input.

## BEAT 2a — the C2 picture: the fleet on TAK, and what crossed the boundary (~3 min)

Connected; no cut yet. Two screens: the **TAK device** and the **HQ view**.

1. **TAK device — the fleet with readiness.** 12 tracks: `dis:1:1:1000`–`1009`
   and two more ATL tracks (measured 2026-10-10, rev 136, read at the TAK
   server; the device itself was not on the lab). `1005` is destroyed and
   still shown — a C2 viewer needs to see the loss. Twelve is right, not
   eleven. The destroyed track
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
   count, and a **withheld** line. Measured 2026-10-10 (rev 136) for the C2
   destination, one viewer at a time at the hub:

   | viewer | admitted | refused | withheld |
   |---|---|---|---|
   | `liaison.coalition` | 12 | 8 | 1 |
   | `operator.regioneast` | 12 | 8 | 1 |
   | `operator.atlantia` | 12 | 0 | 1 |
   | `operator.borduria` | 1 | 8 | 1 |

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
5. **Resupply, on the simulator's schedule.** The launcher `dis:1:1:1009`
   expends 4 of its load of 5 in three launches by t+300: edge-01, the
   region and HQ read it DEGRADED, the effector factor saying `remaining 1/5
   (expended 4)`. A resupply arrives every 600 s from t+660, and the
   launcher reads OK again at all three tiers (measured 2026-10-09; again
   2026-10-10, rev 136: three resupplies seen by t+1886, OK at all three). The
   factor clears above 25 %, so the screen says OK from the first resupply;
   the climb itself, 1 → 2 → 3 → 4 → 5 at t+660 / 1260 / 1860 / 2460 and
   never past 5, is in the launcher's state, not on a card. The reset
   restarts this count with the launcher.

*The beat:* the boundary keeps a ledger, and each viewer reads only the part
of it about records they could see anyway. Bram's 1 of 9 is the same gate,
reading the same records, as the liaison's 12 of 20.

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
4. **HQ — the action arrives** on the actions pane, the released-records
   pane the deployment configures for the action destination. The row reads
   **remove and replace array module, section 3**; part
   `part:array-module`, **from region-east**; outcome approved; two
   approvals (a regional officer and the coalition supervisor); it cites
   three modules (fault isolation, remove, install). Decision: **ADMIT**.
   Report to answer: 1 s; report to admitted action: 30 s, one intake poll
   (measured 2026-10-10, rev 134; again under 1 s and 27 s on rev 136).
   **FIGURE** on the row opens the cited figure, "Detail A, Section 3", with
   section 3 highlighted.
   If BIT already raised this fault, Ada's report joins that fault's event
   (same event id, her report as a second source). The row is the same
   action, re-stamped, not a new row. Say "the action updates"; don't
   wait for a second row.

*The beat:* HQ sees the edge's report come back as an approved action:
replace the array module in section 3 with the spare from region-east. The
report was filed at the edge, crossed the boundary once, under a label,
and came back as an action, and HQ can show which records went out and which
did not.

## Between BEAT 2b and BEAT 3 — Restart exercise (off camera, ~13 min)

Sign in as the supervisor and press **Restart exercise** in the exercise
panel; read the result as in pre-flight steps 3 and 4. Measured 2026-10-10
(rev 136): the Job took **647 s**, **731 s** on the dry run and **769 s** on the
round trip after it; verdict
PASS, last line `RESTART SENT (adapter 200)`, one `DECLARED UNMEASURED`.
Budget ~13 minutes; the spread is in the last phase (waiting for
subscriptions to show live after the restart). It stops and restarts every simulator labelled
`openddil.io/role=simulator` (six on the lab, 0 `NOT A PRODUCER`), so every
schedule starts again from its own t0: the launcher reads `emplaced` from
its container's start at all three tiers, and BEAT 3m's clock starts here.
Then:

* **Reload every screen.** The four profiles stay signed in (no new sign-in
  needed), but a screen left open across the reset goes `LINK: STALE` while
  the producers are stopped, then `LINK: UNKNOWN` with an empty fleet once
  the stores are cleared, and does **not** refill on its own. Measured
  2026-10-10 (rev 136): the open edge-01 screen still read 0 assets 3.5 min
  after the reset finished; a reloaded one read 12 at once. Run the
  four-profile login check anyway (4/4 on the dry run).
* **Links:** set every row on every link card back on and `CLR` every
  toxic; the reset leaves them as they were.
* **Wait 5 minutes** before BEAT 3 for the reasons in the pre-flight notes.

## Before BEAT 3 — what the LINK indicator tracks

The LINK indicator on every screen follows **reachability**: the tier's own
probe of its uplink, plus the age of the last exchange over it, with
hysteresis so one late exchange does not flip it. It no longer follows the
WAN simulator alone, so a cut made by either mechanism reads the same way.
It takes **~10 s** to read severed on the region and **~16 s** for HQ's view
of the HQ-attached edge; wait that long before pointing at a screen.

## BEAT 3 — dimension 1, region cut from HQ (~4 min)

On the HQ screen as `liaison.coalition`, turn off **region-east's row** on
the link card. Measured 2026-10-10 (rev 133): HQ's row reads down by +20 s,
HQ's summary `1 UP · 0 IDLE · 2 DOWN` (edge-01 and edge-02 ride
region-east), the region screen `REGIONAL↔HQ: SEVERED`.

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

Turn region-east's row back on. The row reads up at +30 s and HQ's summary
`3 UP · 0 IDLE · 0 DOWN` (measured 2026-10-10, rev 133); on the dry run
(rev 136) the row flickered up, down, then up (see the caveats), so point
at it at ~+60 s. HQ's region view converged in **under 10 s** after the old
slider's heal (2026-10-05); after the row heal on the dry run HQ's launcher
row caught up at **+41 s**, carrying the edge's time (BEAT 3m). **Say the number
moved** — minutes stale to seconds — because convergence that cannot be seen
to move is indistinguishable from a screen that was never stale.

## BEAT 3m — the move: march order, move, emplace (~6 min) — DRAFT

Connected at the start; BEAT 3's cut and BEAT 4's heal sit inside this beat.
Screens: **Edge-01**, **Region**, **HQ** (as `liaison.coalition`). Asset: the
interceptor launcher `dis:1:1:1009` at edge-01.

**Lab stand-in (dis-sim).** Every time below is the lab stand-in's, measured on
the lab. None of it is the co-located simulator's (see the placeholders).

The stand-in drives the launcher from a posture schedule. Its clock, `t0`, is
the schedule start: the launcher's `posture schedule fired ... t+0` log line.
The reset (Restart exercise) restarts this clock: it stops and restarts every
Deployment labelled `openddil.io/role=simulator`, the launcher included. After
a reset the launcher reads `emplaced` at t0+4 at all three tiers, from the
first record into the emptied stores (measured 2026-10-10; on the dry run
its posture-since equalled the container's start time). Without a reset,
to start the beat on a known clock, restart the launcher and read t0:

```
kubectl -n openddil rollout restart deploy/dis-sim-launcher
kubectl -n openddil rollout status deploy/dis-sim-launcher
kubectl -n openddil logs deploy/dis-sim-launcher --timestamps | grep -m1 'posture schedule fired'
```

t0 is about 1 s after the new container starts: the DIS library is in the
image, so nothing installs at start (measured 0.5 s and 1.1 s, 2026-10-08).
The old pod is gone 1 s after the restart. Posture is decided once, at edge-01, and every other tier
carries that decision and its time.

| t0 + | sim action | posture at edge-01 — lab stand-in (dis-sim) | logistics picture — **drafted, not built** |
|---|---|---|---|
| 0 | raise | `emplaced` at **t0+20** after a restart (20 s hold; measured 2026-10-08). A launcher already `emplaced` stays so, its posture-since unchanged (measured 2026-10-10) | *drafted, not built:* launcher ready, 5/5 on hand |
| 120 / 180 / 240 | fires 2, 1, 1 | `emplaced` | *drafted, not built:* remaining 1/5 (expended 4), DEGRADED |
| 300 | stow | `march_ordered` at **t0+299**, immediate (measured 2026-10-10) | *drafted, not built:* unchanged; the launcher is packing up |
| 330 | move | `moving` at **t0+339** (10 s hold; measured 2026-10-10) | *drafted, not built:* unchanged; the asset is in transit |
| 390 | stop | `emplacing` at **t0+409** (20 s hold; measured 2026-10-10) | *drafted, not built:* unchanged |
| 420 | raise | `emplaced` at **t0+419**, immediate (measured 2026-10-10) | *drafted, not built:* ready again, still 1/5 |

Each change reached the edge-01, region and HQ stores within the same second and was on all three at the first
5 s poll after it (measured 2026-10-10): with the links up, the tiers agree to within 5 s.

On screen, each tier shows the posture with its time in state, ticking: edge-01's **Posture** card (`EMPLACED 40s`),
a posture badge on every row of the region and HQ asset lists, and posture counts per region (the region's fleet
panel and HQ's fleet summary: emplaced / march ord. / moving / emplacing). Platforms other than the launcher read
`moving` by the speed rule; that is expected. Give the region screen ~35 s after load before reading it (its rows
sync after the page renders; at 20 s it showed none, 2026-10-10).

The logistics-picture column is the intended picture, not a screen that
exists. Do not narrate it on camera until a dry run shows it.

From the new container starting: `march_ordered` at about +301 s and
`moving` at about +341 s (measured after a reset, 2026-10-08). If the
launcher is restarted again during the move, `emplaced` follows at t0+20 of
the new clock, about +21 s from that container's start (the 20 s hold plus
the 1 s start; not re-measured on the baked image).

**The cut, tied to the move:**

1. Wait until HQ shows `march_ordered` (from ~t0+300).
2. At ~t0+320, on HQ, turn off **region-east's row** (BEAT 3). HQ's row
   reads down by +20 s and the region reads severed.
3. **While cut**, edge-01 and the region see `moving` (t0+339), then
   `emplacing` (t0+409), then `emplaced` (t0+419). HQ holds `march_ordered`,
   labelled stale, its age growing.
4. At ~t0+430, heal (BEAT 4). HQ converges to `emplaced`, and its
   posture-since reads **t0+419: the edge's time, not the heal time.**

Dry run 2026-10-10 (rev 136), t0 = the launcher container's start after the
reset: `march_ordered` t0+300 at all three; cut at t0+321, HQ's row down at
+20 s, HQ `1 UP · 0 IDLE · 2 DOWN`, region `REGIONAL↔HQ: SEVERED`; while
cut, edge-01 and the region read `moving` t0+340, `emplacing` t0+410,
`emplaced` t0+420, and HQ held `march_ordered`; HQ's own consumers stayed
Stable and kept reading. Heal at t0+432: HQ read `emplaced` at +41 s, its
posture-since **equal to the edge's to the second** (t0+420), not the heal
time.

*The beat:* the move happened while HQ could not see it. When the link came
back, HQ shows not only where the launcher is now but when it got there, as
decided at the edge.

Placeholders (do not record over one that is still open):

- `<co-located simulator: the route, the emplacement site, the march order's
  issuing echelon and its timing, authored on the simulator side. The times
  above are the lab stand-in's schedule, not the scenario's.>`
- `<co-located simulator: whether the fires come before the move (as in the
  stand-in) or after re-emplacement.>`

## BEAT 5 — dimension 2, edge-01 cut (~4 min)

On the region screen (as `operator.regioneast`), turn off **edge-01's row**
on the link card. Nothing restarts. Measured 2026-10-10 (rev 133): edge-01
reads down in the region store and at HQ by +20 s while edge-02 stays up;
**edge-01's own screen stays up and reads `DDIL: LINK SEVERED`**; HQ's
summary reads `2 UP · 0 IDLE · 1 DOWN` with an edge-01 `DOWN` badge.
Again on the dry run (rev 136): down at both stores at +20 s, the same two
screens; after 120 s edge-01's data age was 132.7 s in the region store
against edge-02's 0.2 s.

The heavier cut, if the beat needs edge-01 gone entirely:
```
bash scripts/sever-tier.sh edge-01 on openddil
```
Expect `SEVERED and PROVEN` (~40 s; the script restarts edge-01's pods). It
closes edge-01's ingress too, so **edge-01's own screen will not load**;
show that version from the region and HQ screens.

**Watch the discriminating pair — this is the strongest beat in the demo:**

1. **Region screen — edge-01 reads severed, edge-02 stays `LINK UP`.**
   Edge-01's assets go stale while edge-02's stay fresh: two groups of rows
   on one screen with different ages. Measured under `sever-tier.sh`: 4m46s
   vs 0.6s.
2. **HQ — the two-hop read.** Edge-01 stale by minutes, **while the region's
   own rollup is seconds old**.
3. **Optional, before the cut — a slow link is not a cut.** On the same row,
   set `LAT` 2000 and `SET`. edge-01's data age rises while edge-02's holds:
   region store 0.8 → 2.8 s, HQ 0.4 → 2.5 s, edge-02 1.0 / 0.7 s; the row
   stays up and its `LAT` field shows 2000 (measured 2026-10-10, rev 133;
   dry run rev 136: region store 0.6 → 2.6 s, edge-02 0.5 s). `CLR` before
   you cut.

*The beat, and say it plainly:* HQ can tell **a quiet edge from a downed
region uplink**, because it carries both ages instead of fusing them. Under
a single "last updated" those two situations are the same number — and they
call for opposite responses: one sends someone to the edge, the other to the
region.

## BEAT 6 — heal and close (~1 min)

**If BEAT 5 cut from the row:** turn edge-01's row back on. edge-01 reads up
in the region store and at HQ at +40 s (measured 2026-10-10, rev 133); on
the dry run (rev 136) it flickered up at +20 s, down at +40 s, and was up
with fresh data at +50 s, so say "back" at ~+60 s. Its own screen returns
to `UPLINK: LINK UP`. Nothing restarted, so there is no backoff
to wait out. The two options below apply only after `sever-tier.sh`.

**After `sever-tier.sh`, choose the heal mode before you start. Both are
honest; they demonstrate different things, and the difference is visible on
camera.**

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
