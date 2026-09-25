# Runbook note — one DIS multicast feed, one sidecar per site

Written for the operator standing up a DIS feed on the work side. Intended
to fold into `PILOT-RUNBOOK.md` as a pre-flight item wherever the DIS
ingest is brought up.

## What changed, in one line

`sensor-ingest` can now join a multicast group and ingest **one DIS site**,
set by `DIS_SITE_ID`. Both are off by default; a deployment that sets
neither behaves exactly as before.

## Why it was needed

Separation used to be a property of the wire: each sidecar had its own UDP
port, the simulator addressed the right one, and one port had one reader.
That holds for **unicast only**. A DIS exercise distributed on a multicast
group delivers every site to every joined listener, so there is no
addressing decision left at the sender to separate with. `DIS_SITE_ID` is
the smallest thing that restores the separation: one equality test on the
site field the PDU already carries.

## Settings

| Variable | Default | Meaning |
|---|---|---|
| `DIS_MULTICAST_GROUP` | *(unset)* | Group to join. Unset = unicast, unchanged behaviour. |
| `DIS_MULTICAST_IFACE` | `0.0.0.0` | Interface carrying the exercise. Name it explicitly on a multi-homed node. |
| `DIS_SITE_ID` | *(unset)* | The one site this sidecar publishes. Unset = publish everything. |
| `UDP_HOST` | `0.0.0.0` | Unicast listen address, used when no group is set. |

Two sidecars may share one group and one port — `SO_REUSEADDR` is set when
a group is configured, which is what lets them coexist, including inside a
single pod. See `openddil-sensor-ingest/examples/two-sidecar-multicast-pod.yaml`.

## Pre-flight

1. **Confirm PDUs arrive at all before touching the filter.**
   ```
   kubectl exec <pod> -c <container> -- \
     python -c "import urllib.request;print(urllib.request.urlopen('http://127.0.0.1:8080/metrics').read().decode())" \
     | grep -E 'dis_pdus_(received|decoded|filtered)_total'
   ```
   `dis_pdus_received_total` flat means the **network** is not delivering,
   not that the filter is wrong. No amount of `DIS_SITE_ID` tuning fixes it.

2. **Confirm the scope the sidecar thinks it has.** It says so once at
   startup:
   ```
   kubectl logs <pod> -c <container> | grep -E 'multicast group|Site filter'
   ```
   Expect a `Joined multicast group ...` line and a `Site filter: site N
   ONLY` line. A sidecar on a group with the filter OFF will publish every
   site it hears into one topic, which is a releasability problem as much
   as a data one.

3. **Confirm the split is real, not assumed.** `dis_pdus_decoded_total`
   should be roughly EQUAL on every sidecar on the group — they all see
   everything — while the published counts differ. Decoded counts that
   differ mean the sidecars are not actually on the same feed.

## The trap this note exists for

**Most CNI plugins do not forward multicast into pod networks.** Where
yours does not, the sidecar joins a group that never delivers, reports
itself healthy, and ingests nothing — silence indistinguishable from an
exercise that has not started yet. `hostNetwork: true` is the usual answer,
and its price is that UDP 62040 becomes a node-wide resource: one such pod
per node, colliding with anything else already on that port.

Check step 1 before believing any part of the pipeline downstream of it.

## What it deliberately does not do

* **No default site.** Unset means "publish everything", not "publish
  site 1". A default would silently discard an operator's traffic on
  upgrade.
* **No ranges, no ontology lookup.** One equality test on one field. Entity
  ranges remain test-side discipline.
* **Filtered PDUs do not count as this sidecar's input.** This is
  load-bearing for liveness: the stall condition is *input advanced and
  output did not*, so counting another site's traffic as ours would make a
  correctly-quiet sidecar look wedged and get it restarted every window for
  as long as the other site kept talking. Filtered PDUs are counted in
  `dis_pdus_filtered_total` instead, so they are visible without being
  mistaken for work.

## Verification

`openddil-sensor-ingest/tests/multicast_site_filter/` brings up two sidecars
on one group under compose, sends 5 PDUs for site 1, 7 for site 2 and 3 for
an unclaimed site 3, and checks all of it both ways: each sidecar must see
all 15, publish exactly its own, and the site-3 PDUs must land nowhere.

```
python tests/multicast_site_filter/test_multicast_site_filter.py
```

Red-checked by disabling one sidecar's filter: the run then reports four
violations, including the site-3 leak.
