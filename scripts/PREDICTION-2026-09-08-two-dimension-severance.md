# Two-dimension severance — prediction, and a blocker found before cutting

Written before anything is cut. **Nothing has been severed**; the cluster is
in its connected state, verified by `sever-tier.sh region-east status`.

## BLOCKER — CLEARED 2026-09-08. Kept for the record.

### The sever script assumed a LEAF

`sever-tier.sh` renders a default-deny NetworkPolicy over the tier's
discovered site, allowing same-site traffic, DNS, and the central simulators
(which stand in for on-site sensors). For a leaf that is exactly right: "cut
from the root" and "cut from everything above" are the same policy.

**A region is an intermediate, and for it those are different policies.** The
allow-list contains no entry for the region's CHILDREN, so applying it to
region-east would also cut edge-01 and edge-02 from it.

That does not merely test the wrong thing — it tests something that *looks
like the right thing from the region's own screen*. A region serving its own
data while its children are cut renders identically to a region serving its
own data with its children attached. The failure would be invisible at
exactly the surface the test is watching, and the rollups would drift down as
edges stopped arriving while the screen stayed green and fresh.

The regional-node design said this in advance: **a severed region is not
isolated, it is a node with dependants.** The script predates that sentence.

**The fix is small and specific:** the allow-list gains the bridge component
of every tier whose parent is the severed one, discovered from the deployed
bridge configs (a child's bridge config names `redpanda-<parent>:`), never
hardcoded. Attempted and reverted tonight rather than left half-applied — an
edit that left `${child_sel}` referenced and undefined would have failed at
`apply` time under `set -u`, mid-sever, which is the one moment this script
must not be improvised in.

## The prediction, by classification, for when it runs

### Dimension 1 — region-east cut from HQ (children still attached)

* **region-east serves its own data.** Its PEP, Electric and Postgres are
  intra-site; the tier projector keeps writing from its own broker. The
  sample timestamp on the region's screen must ADVANCE during the cut — not
  merely be present, which a frozen cache also satisfies.
* **Edges keep reaching it.** `bridge-group-edge-0N` lag stays bounded and
  the region's `asset-cm-state` high-watermark keeps climbing. This is the
  assertion the current script cannot satisfy, and the reason for the
  blocker above.
* **Rollups keep composing.** All three class partials keep updating at the
  region; `asset_count` stays 14. A partial going missing means the cut
  reached a child.
* **HQ's region view goes stale WITH AN INDICATOR**, never wrong and never
  empty. Under the two-hop design it carries BOTH ages: the leaf observation
  age and the region relay age, unfused. The relay age is the one that grows.
* **`uplink-group-region-east` lag climbs** — the uplink is the cut link and
  its failure is corroboration, not a fault. The readiness gate must not
  require it healthy during a sever.
* **A NEW LOGIN AT THE REGION WILL FAIL, and that is correct.** Keycloak is
  at the root, so a severed region cannot mint sessions; an existing cookie
  keeps working for its TTL. **Consequence for the recording: log into all
  four screens BEFORE the first cut.** A demo that severs and then logs in
  demonstrates an outage nobody intended to show.
* **Heal converges non-vacuously** — the uplink drains, HQ's region view
  returns to fresh, and the assertion must be that HQ's numbers MOVED, not
  merely that they exist.

### Dimension 2 — edge-01 cut from region-east

* **edge-01 serves locally.** Its own PEP/Electric/pg keep serving and its
  sample time advances.
* **The region's view of edge-01 goes stale**, while its view of edge-02
  stays fresh — the discriminating pair. If both go stale the cut was wider
  than intended.
* **The rollup partials keep composing from edge-02 alone.** `asset_count`
  DROPS from 14 to edge-02's share. That drop is correct and must be
  rendered as a drop with a stale indicator on the missing contributor, not
  as a smaller fleet.
* **HQ sees TWO-HOP staleness attributed correctly:** edge-01's observation
  age grows while the region's relay age stays small. That is the exact pair
  the two-hop design exists to distinguish — *observed 6m ago, via
  region-east 3s ago* is a quiet edge, and this is that case, produced
  deliberately.

## Standing conditions

Every path crossing each boundary is cut, and the site is RESTARTED after the
policy so established connections do not survive it — conntrack lets an open
connection through a new default-deny, which is how the first severance
rehearsal passed while the link was still up.

**A half-cut region is the ruled-out end state.** Each dimension heals before
the next begins, and the run ends connected.


---

## Resolution 2026-09-08 — two modes, and the dry-run that proved them

`sever-tier.sh` now takes `--from-parent` (default) and `--isolate`.

* **`--from-parent`** cuts the tier's uplink and leaves its subtree attached.
  It is the default because it is the scenario that names a DDIL event: the
  link to higher echelon is lost and the tier keeps serving what it is
  responsible for.
* **`--isolate`** cuts everything, subtree included — a site-loss scenario.

The subtree is discovered from what is DEPLOYED: a child's bridge config
names its parent's broker, so the tiers whose bridge points at this one are
exactly its children. A leaf finds none, which is why both modes render
identically there — correct, and the reason the flag is not restricted to
intermediates.

**One bug the dry-run caught before any policy existed.** A bridge config
names its own broker on the INPUT side and its parent's on the OUTPUT side,
so a bare match found edge-01 as a child of itself. Left in, a leaf would have
reported a one-member subtree and its two modes would have rendered
differently — a leaf pretending to have dependants. Same shape as the
self-parent `bridgeTarget` refused when the tier list was built: **a relation
that must be irreflexive, discovered from a string that appears on both ends
of it.**

Verified by dry-run, four cases, nothing applied:

| case | result |
|---|---|
| edge-01, either mode | `subtree: none — a leaf, both modes identical` |
| region-east `--from-parent` | 6 child-bridge lines in the policy body |
| region-east `--isolate` | 0 |

**And the login preamble is in the usage text**, not only in a readback:
Keycloak runs at the root, so a severed tier cannot mint new sessions. An
existing cookie works for its TTL; a fresh login does not. Every screen the
demonstration uses is opened and authenticated BEFORE the first cut, or the
recording shows an identity outage nobody intended to demonstrate.

---

# RESULT 2026-09-09 — both dimensions passed, run ended connected

Predicted by classification before either cut. Every assertion below is a
measurement taken during the cut, not after it.

## Dimension 1 — region-east `--from-parent`

| assertion | measured |
|---|---|
| region serves its own FRESH data | sample advanced **02:13:37 → 02:14:38** while severed |
| edges still reach it | region inbound **+128** over 45s; `bridge-group-edge-01` lag 2 |
| rollups keep composing | **3 partials, 14 assets**, updating 02:13:32 → 02:14:32 |
| HQ stale WITH INDICATOR, not wrong | HQ rollup **frozen at 02:09:14**, 12m00s stale — the pre-cut value, never a wrong one and never empty |
| heal converges NON-VACUOUSLY | HQ **moved** 02:09:14 → 02:23:02; stale 12m → **20s** |

**And the relay probe's must-not-fire, proven live under a real policy cut:**
11 minutes severed, `tier-uplink-region-east` **restarts=0**, the probe stating
its own reasoning — *"destination openddil-toxiproxy:8474 unreachable —
buffering, not stalled"*. Without the third term this would have restarted the
uplink every three minutes for the length of the cut, rendering a demonstrated
DDIL behaviour as a crash loop.

The `--from-parent` mode is what the second row proves. Under `--isolate` the
subtree would have been cut too, and **the region's own screen would have
looked identical** — fresh local data either way — while its rollups quietly
drifted down. That is why the modes exist.

## Dimension 2 — edge-01

| assertion | measured |
|---|---|
| edge serves locally | edge-01 store **0.31s** behind throughout |
| region's edge-01 view goes stale | **4m46s** stale |
| region's edge-02 view stays fresh | **0.6s** — the discriminating pair; both stale would mean the cut was wider than intended |
| HQ attributes two-hop staleness correctly | edge-01 **4m47s** stale, edge-02 **0.8s** fresh, region rollup **updated 6s ago** |
| heal converges NON-VACUOUSLY | region's edge-01 view **02:24:21 → 02:32:13**, now 0.6s |

That third HQ row is the two-hop design paying out: *observed 4m ago · via
region-east 6s ago* is **a quiet edge, not a downed uplink**, and HQ can tell
which. Under a single fused age those two are the same number.

`edge-hq-bridge-edge-01` restarts during the cut: **0**.

## End state

Zero severance policies remain; both tiers report `connected`; the advancing
pre-flight is green across all nine stages. **The run ended connected.**
