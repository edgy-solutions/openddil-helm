# Two-dimension severance — prediction, and a blocker found before cutting

Written before anything is cut. **Nothing has been severed**; the cluster is
in its connected state, verified by `sever-tier.sh region-east status`.

## BLOCKER: the sever script assumes a LEAF

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
