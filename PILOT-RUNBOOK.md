# Pilot runbook — tier presentation node, one site

**Audience:** an operator with cluster credentials. Assumes **no prior
context** — every step gives the exact command, what you should see, and
what to do if you see something else.

**Why this is a runbook and not a plan:** the author has no cluster
access, so execution is yours. Steps are copy-paste; judgement calls are
flagged as such.

**What this proves:** a site's operators can see their own site's truth
from their own site's resources — *and keep seeing it when the uplink is
cut.* Step 5 is the reason the whole arc exists; **it produces a
recording, and the recording is a deliverable, not a byproduct.**

Set these once:

```bash
export NS=openddil-test          # your namespace
export REL=openddil              # your helm release name
export PILOT=edge-01             # the pilot site (see §1)
```

---

## Rehearsal substitutions — one procedure, declared translations

This runbook was **rehearsed end-to-end on a lab k3s cluster before being
handed to an operator**, so the steps below have been executed rather than
merely written. The lab differs from the work cluster in four known ways.
They are listed here as *substitutions*, not as a second procedure: the
rehearsed document and the operator document are the same document, and
every divergence is declared.

| | work cluster | lab | note |
|---|---|---|---|
| edge ids | `edge-01…03` | `edge-northpoint`, `edge-capeverdant` | **name-parameterized.** Everything below uses `$PILOT`; nothing depends on the literal name (that became true in 0.1.40 — see GD-09). |
| P1 Atlas re-baseline | **required** | not applicable | work-cluster-only: the lab store is created fresh by this chart, so there is no pre-existing schema to re-baseline. |
| P2/P3 measurements | real ORBAT data | synthetic sim data | work-cluster-only for *values*. The lab confirms the **queries run**; it cannot confirm the numbers mean anything. |
| fleet | populated | logistics-sim generated | affects rung (ii) parity richness, not the mechanism. |

**What the lab does prove, at full strength:** it is genuine Kubernetes, and
**toxiproxy is the severance mechanism at both sites**. So rungs (iii)–(iv)
exercise the identical mechanism — the credibility gap between a rehearsal
recording and the official one is *data realism only*, not fidelity of the
thing being demonstrated.

The work-cluster recording remains the official proof artifact. The
rehearsal recording is internal validation, and a serviceable backup demo.

---

## Pre-flight — a version gate, then three parked items

**P0 gates everything below it.** The three parked items are unrelated to
the pilot but need the same access, and each has been waiting on a cluster
session.

### P0. Chart version — **HARD GATE, check before anything else**

**Two different numbers, and they are not interchangeable.**

| | number | what it means |
|---|---|---|
| **Hard minimum** | **≥ 0.1.42** | Below this the runbook's own claims are void — rung (iv) cannot be proven. **Stop and upgrade.** |
| **Session target** | **0.1.46** *(current)* | What to actually upgrade to. Nothing below §5 *requires* it; see the note. |

The minimum is 0.1.42 and **stays** 0.1.42, because that is where the thing
this runbook depends on landed. Later versions are worth having; they are
not preconditions, and stating them as preconditions would make a gate
nobody can distinguish from a real one.

> **If this cluster is on a pre-0.1.42 chart, its buffer signal is blind
> RIGHT NOW.** The edge→HQ buffer counter has read 0 since the feature
> shipped — not because buffering fails, but because the monitor queried a
> consumer group that never existed (see 0.1.42 below). Any prior observation
> that "the buffer never moves" is an artefact of the instrument, not
> evidence about the link.

**Why upgrade to 0.1.46 anyway, and one case where it is not optional:**

- **0.1.45** — the Topaz gate. An **Arc 2** precondition, not used by
  anything here: Arc 1 runs open-access and the sidecar decides nothing.
- **0.1.46** — bounds the NFS `emptyDir` escape hatch with `sizeLimit`.
  **If this cluster sets `persistence.redpandaUseEmptyDir` or
  `restateUseEmptyDir`, treat 0.1.46 as required, not preferred.** Below it
  those volumes are unbounded against node ephemeral storage, and a broker
  that fills the node evicts pods *chosen by usage* — so the casualties are
  frequently other components, on a node where nothing local looks wrong.
  A long severance rung is exactly the condition that grows a broker's
  on-disk backlog. (ADR-0036 **UD-7**.)

```bash
helm list -n "$NS" -f "^${REL}$" -o json | python -c \
  "import json,sys; r=json.load(sys.stdin)[0]; print(r['chart'], '|', r['status'])"
# hard gate: openddil-demo-0.1.42 or later | deployed
# target:    openddil-demo-0.1.46

# Does this cluster use the escape hatch? If either prints true, 0.1.46 is required:
helm get values "$REL" -n "$NS" -a -o json | python -c \
  "import json,sys; p=json.load(sys.stdin).get('persistence',{}); \
   print('redpandaUseEmptyDir:', p.get('redpandaUseEmptyDir')); \
   print('restateUseEmptyDir:', p.get('restateUseEmptyDir'))"
```

### P0.1 The upgrade itself — REHEARSED 2026-08-10, RE-REHEARSED 2026-08-19

> **Re-run 2026-08-19 on the lab, 0.1.45 → 0.1.46, so every expected output
> below was observed THIS WEEK rather than three weeks ago.**
>
> | | observed |
> |---|---|
> | duration | **60s** wall clock, `helm upgrade` to `deployed` |
> | revision | 2 → 3 |
> | migrations | **none fired.** 11 applied before and after, latest `20260807000000` unchanged |
> | re-baseline | **not needed for this hop** — the §a checksum gate did not trigger |
> | rows | `telemetry_latest_state` and `asset_logistics_status` intact across the upgrade |
> | rung (i) | passes — 14 rows updated within 3 minutes of the upgrade |
> | unhealthy pods | **one**, and it was not the chart — see below |
>
> **THE FINDING, and it is about image references rather than the chart.**
> One `sensor-ingest` pod went `CrashLoopBackOff` after the upgrade. The
> chart was innocent: the deployment references
> `ghcr.io/…/sensor-ingest:latest`, a **rolling tag**, with
> `imagePullPolicy: IfNotPresent`. The pod that restarted pulled a *newer*
> `:latest` than its siblings were already running.
>
> Digests, taken from the three pods in the same release at the same moment:
>
> ```
> sensor-ingest-edge-01   sha256:5c89ffc0e62b
> sensor-ingest-edge-02   sha256:2ad9f52e71ca   <-- restarted, pulled newer
> sensor-ingest-edge-03   sha256:5c89ffc0e62b
> ```
>
> **Three pods, one tag, two images.** The upgrade did not deploy new code —
> *a pod restart did*, and it pulled something nobody reviewed as part of
> this change. Any restart — eviction, node drain, OOM, a severance rung —
> is a silent deploy.
>
> **This is why the pilot cluster pins by digest, and the check belongs
> BEFORE the upgrade, not after:**
>
> ```bash
> kubectl -n "$NS" get deploy,statefulset -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.spec.template.spec.containers[*].image}{"\n"}{end}' \
>   | grep -v '@sha256:' || echo "all images digest-pinned"
> ```
>
> Anything printed is a component whose next restart is an unreviewed
> deploy. On a digest-pinned cluster this prints nothing and the hazard
> does not exist — which is the difference between the pilot cluster and
> the lab, and the reason the lab found it first.
>
> **How it recovered is the sharper half.** Deleting the pod fixed it — the
> replacement scheduled onto a node that still had the OLD image cached and
> came up on `5c89ffc0`, matching its siblings. `imagePullPolicy:
> IfNotPresent` means **which image you run depends on which node you land
> on**, so the same manifest yields different code per node, and a delete/
> recreate is a coin flip rather than a remedy.
>
> *That is the part to carry into a maintenance window:* if a pod fails
> after a restart and the image is a rolling tag, **do not treat a
> successful recreate as a fix** — it may only mean you landed somewhere
> with an older cache, and the next eviction puts you back. Pin the digest,
> then restart.


If P0 says you are behind, this is the procedure. It was executed end to end
on a lab cluster: a from-scratch install of an older chart, populated with
live DIS traffic, then upgraded in place. The chart transition took **65
seconds**, ended with **zero unhealthy pods**, and **every data row
survived**.

Read the whole section before running anything — one step (P0.1.c) is a
safety gate that must be evaluated, not assumed.

#### a. Establish what you are actually on

Two facts are needed and they can disagree:

```bash
# 1. the CHART version (drives template/topology changes)
helm list -n "$NS"

# 2. the BUNDLE digest (drives SCHEMA MIGRATIONS — this is the one that bites)
kubectl -n "$NS" get statefulset,deploy -o jsonpath='{range .items[*]}{.spec.template.spec.initContainers[*].image}{"\n"}{end}' \
  | grep -i runtime-bundle | sort -u
```

**These are independent.** A deployment can carry a June chart with a July
bundle if images were re-mirrored without a chart change — which is exactly
the case this rehearsal was built against. **The Atlas hazard tracks the
bundle, not the chart**, and reasoning about it from the chart version alone
produces a confident wrong answer. (It did here, twice, until the pinned
digests were checked.)

#### b. Expect exactly two schema events

Determined by comparing the migration set in the pinned bundle against
current — not by observation, so it is knowable *before* the maintenance
window:

| event | what it is |
|---|---|
| **new migrations applied forward** | normal; count them from the diff between the pinned bundle's migration directory and current |
| **a checksum mismatch on an already-applied migration** | `atlas migrate apply` refuses. This is the re-baseline trigger. |

To compute both before touching the cluster, in the schema repo:

```bash
PIN=$(git rev-list -1 --before="<your bundle's mirror date>" HEAD)
# migrations added since the pin:
diff <(git ls-tree -r --name-only $PIN schema/migrations | grep '\.sql$' | xargs -n1 basename | sort) \
     <(ls schema/migrations/*.sql | xargs -n1 basename | sort) | grep '^>'
# already-applied migrations whose CONTENT changed since the pin:
for f in $(git ls-tree -r --name-only $PIN schema/migrations | grep '\.sql$'); do
  git diff --quiet $PIN HEAD -- "$f" || echo "CHANGED: $(basename $f)"
done
```

#### c. ⚠ SAFETY GATE — is the re-baseline legitimate?

**Re-baselining tells Atlas "trust the new checksum for a migration already
applied." That is correct ONLY if the SQL is unchanged.** If real SQL
changed, re-baselining silently records schema you never applied — the
drift becomes invisible instead of loud.

Prove it rather than assume it. For each CHANGED file from (b):

```bash
F=schema/migrations/<the-changed-migration>.sql
a=$(git show "$PIN:$F" | grep -vE '^\s*--' | grep -vE '^\s*$' | md5sum)
b=$(git show "HEAD:$F"  | grep -vE '^\s*--' | grep -vE '^\s*$' | md5sum)
[ "$a" = "$b" ] && echo "comment-only — re-baseline SAFE" \
                || echo "SQL DIFFERS — STOP, do not re-baseline"
```

**If any file reports SQL DIFFERS, stop and escalate.** A re-baseline over a
real schema change is the failure this gate exists to prevent, and it is not
recoverable by inspection afterwards.

#### d. Capture rollback state first

```bash
helm get values "$REL" -n "$NS" > /tmp/values-before.yaml   # KEEP THIS
helm history "$REL" -n "$NS" | tail -5                      # note the revision
kubectl -n "$NS" exec "$REL-postgres-hq-0" -- \
  psql -U postgres -d openddil -tAc "SELECT count(*) FROM telemetry_latest_state;"
```

The values file matters more than the revision number: `helm rollback`
restores the chart, not any values you passed with `-f`.

#### e. Upgrade

```bash
helm upgrade "$REL" <path-to-openddil-demo-chart> -n "$NS" \
  -f <your values file(s), including any digest-pinned overlay> \
  --timeout 15m
```

Keep passing every `-f` you originally installed with. Helm does not
remember file-supplied values across an upgrade; omitting one silently
reverts those settings to chart defaults.

**Rehearsed result:** completes in ~1 minute. Hooks run from the NEW chart,
so a hook image that has been withdrawn from a registry since the old chart
shipped does **not** block the upgrade — it blocks fresh *installs* of the
old chart only.

#### f. If the re-baseline fires

The schema-init job fails on the checksum mismatch predicted in (b). With
gate (c) passed, apply the re-baseline procedure from the helm README, then
re-run the job:

```bash
kubectl -n "$NS" delete job "$REL-postgres-schema-init" --ignore-not-found
helm upgrade "$REL" <chart> -n "$NS" -f <values...>   # re-runs the hook
```

#### f.2 Expect one silent repair: topic configs

Upgrading across **0.1.34** changes topic-init from create-only to
create-then-`alter-config`. That is not cosmetic — it **self-heals topics
that lost the create race**.

The failure it repairs: if a producer or consumer connects before the
post-install topic-init hook completes, redpanda auto-creates the topic with
DEFAULT config. The old `rpk topic create … || true` then no-ops (the topic
exists), so the intended `-c` settings — including
`max.message.bytes=16777216` — never land. Per-asset element snapshots are
several MB, exceed the 1 MB default ceiling, `publish_snapshot` fails with
`MessageSizeTooLargeError`, and **no per-element data ever reaches the
topic** — the maintainer 3D tiles stay empty fleet-wide.

**A cluster deployed before 0.1.34 may be in that state right now**, and it
presents as a UI problem rather than a topic problem.

Check before upgrading, so you can tell repair from coincidence:

```bash
kubectl -n "$NS" exec "$REL-redpanda-edge-01-0" -- \
  rpk topic describe asset-element-telemetry -c | grep -E "max.message.bytes|cleanup.policy"
# 1048576 means the topic lost the create race and has been dropping snapshots
```

Then re-check after (g). The alter-config is idempotent — setting a value to
itself is a no-op — and **partition/replica counts are deliberately not
altered**, only configs. Safe on every install and upgrade.

If you would rather not wait for the upgrade, the same repair applies live
with no redeploy:

```bash
rpk topic alter-config asset-element-telemetry --set max.message.bytes=16777216 …
```

#### g. Verify — and do not accept "pods are Running" as verification

```bash
kubectl -n "$NS" get pods | grep -vE "Running|Completed"     # expect: nothing
kubectl -n "$NS" exec "$REL-postgres-hq-0" -- \
  psql -U postgres -d openddil -tAc "SELECT count(*) FROM telemetry_latest_state;"
# compare against the count captured in (d)
```

Then run **§4 rung (i)** below as the real smoke test: it exercises the
store, the projector and the UI path rather than pod status.

#### h. Rollback

```bash
helm rollback "$REL" <previous-revision> -n "$NS"
```

**Rollback returns the chart, not the schema.** Migrations applied forward in
(b) are not reversed, and a re-baseline is not undone. For a comment-only
re-baseline that is harmless — the schema was already correct. It is another
reason gate (c) is a gate and not a formality.

This is not routine hygiene. Every fix below is **load-bearing for a rung
of this runbook**, and each was found by deploying to a real cluster on
2026-08-08 — the first time the tier node had ever executed anywhere:

| chart | fix | which rung breaks without it |
|---|---|---|
| 0.1.37 | loop-boundary `---` in `tier-node.yaml` | **all of §3–§5.** Every tier but the last silently lost objects at render time. On a multi-tier deployment you would deploy, see no error, and be missing components. |
| 0.1.38 | restate-wipe hook image (`bitnami/kubectl:1.30` was withdrawn from Docker Hub and now 404s) | **install itself** — fails as `failed pre-install: timed out waiting for the condition`, which names no image and sends you hunting. |
| 0.1.39 | `wal_level=logical` on tier-pg; schema-init shell/atlas invocation; topaz defaulted off | **§4 rung (i).** Without the first, tier-electric crash-loops and the tier UI never streams — *while tier-pg looks perfectly healthy*. Without the second, the tier store is never migrated. |
| 0.1.40 | per-edge bridge config and root restate clusters generated from values | **§5 rungs (iii)–(iv).** The bridge is the buffering path being severed and drained; before this it read a baked file keyed by edge name. |
| 0.1.41 | comment/record correction only | none — no behaviour change. |
| 0.1.42 | **buffer monitor consumer-group name** | **§5 rungs (iii)–(iv), load-bearing.** The monitor queried `bridge-group`; the bridge commits under `bridge-group-<edge_id>`, so the probe read a group that never existed and reported 0 permanently. Rung (iv)'s entire proof is that this number climbs and drains. Measured before/after on a real cluster: `0 0 0 0 0` vs `30 65 97 130 165` against a broker-confirmed `32 66 99 132 165`. |

**If the release is older than 0.1.41,** upgrade first (P1's re-baseline
applies to that upgrade too — do P1, then upgrade, then return here). An
operator session spent rediscovering bugs already fixed in git is the
worst possible use of credentialed time.

### P1. Atlas re-baseline (REQUIRED before any `helm upgrade`)

A migration comment was reworded; the DDL is byte-identical but Atlas
checksums file *content*, so an existing cluster will fail its next
`migrate apply` with a checksum mismatch and the upgrade will stop.

```bash
kubectl -n $NS exec $REL-postgres-hq-0 -- \
  psql -U openddil -d openddil -c \
  "SELECT version, hash FROM atlas_schema_revisions.atlas_schema_revisions
     WHERE version = '20260520010000';"
```

**Expect:** one row. Note the hash.
**Then** follow `openddil-helm/README.md` §"Upgrading an EXISTING
cluster" to re-baseline that revision.
**If the query errors with "relation does not exist":** this cluster has
never run Atlas — skip P1 entirely and tell the author.

### P2. Factor-cardinality measurement (retires a parked estimate)

The top-N composability finding
(`AUDIT-2026-08-07-aggregation-composability.md`) recommends propagating
untruncated factor counts, and its affordability rests on cardinality
being modest. That is currently **an estimate from structure, not a
measurement**.

```bash
kubectl -n $NS exec $REL-postgres-hq-0 -- \
  psql -U openddil -d openddil -tAc \
  "SELECT count(DISTINCT f->>'factor_id')
     FROM asset_logistics_status,
          LATERAL jsonb_array_elements(constraining_factors) f;"
```

**Report the number.** Under ~100 confirms the recommendation; a few
hundred or more means revisiting the fix shape.

### P3. Baseline row counts (sizing evidence, optional)

```bash
kubectl -n $NS exec $REL-postgres-hq-0 -- \
  psql -U openddil -d openddil -tAc \
  "SELECT count(*) FROM telemetry_latest_state;"
```

---

## 0.5 VR-Forces preparation — do this BEFORE the session

Every parameter below was established by driving this pipeline with real
IEEE 1278.1 traffic in rehearsal. Treat this as configuration to apply, not
investigation to perform. **One genuine unknown remains — the enumeration
coverage check in step 4. Walk in holding its answer.**

### 1. Wire settings VR-Forces must emit

| setting | value | why |
|---|---|---|
| DIS protocol version | **7** | `sensor-ingest` decodes via `opendis` `dis7`. Version 6 PDUs are structurally close but not verified here. |
| PDU type | **1** (Entity State) | the only type the ingestor extracts. Fire/Detonation PDUs are received and ignored. |
| Exercise ID | **1** (or match `DIS_EXERCISE_ID`) | not currently filtered on — recorded so a later filter does not surprise anyone. |
| Heartbeat | **~5 s** | VR-Forces default. Also what fusion's gone-quiet staleness detection is tuned against; much faster floods the buffer and proves less. |
| Transport | **UDP unicast** to the ingest Service | see step 2 — broadcast/multicast is the thing most likely to bite. |

### 2. Network path to sensor-ingest

Each edge runs its own listener on its own port:

```bash
kubectl -n $NS get svc | grep sensor-ingest
# edge-01 -> 62040/UDP, edge-02 -> 62041/UDP, edge-03 -> 62042/UDP
```

**The reachability question, stated plainly:** VR-Forces normally emits DIS as
**broadcast or multicast** on a simulation LAN. A Kubernetes ClusterIP Service
is **unicast only** — broadcast will not reach it, and multicast requires
cluster network support that should not be assumed. Resolve one of:

- point VR-Forces at a **unicast** destination (the NodePort on any node, or
  a LoadBalancer address), **or**
- run a small relay on the simulation LAN that joins the multicast group and
  forwards unicast to the Service.

Confirm before the session — this is configuration on the VR-Forces side and
cannot be fixed from inside the cluster.

```bash
# NodePorts, if unicast-to-node is the chosen path
kubectl -n $NS get svc -o wide | grep sensor-ingest
```

### 3. Confirm arrival — the two counters that matter

```bash
kubectl -n $NS logs deploy/$REL-sensor-ingest-$PILOT --tail=3
# Stats snapshot — received=N.0 decoded=N.0 decode_errors=0.0
```

**`received` rising but `decoded` flat** means PDUs arrive and fail to parse —
almost always a protocol-version or PDU-type mismatch, not a network problem.
**Both flat** means nothing is arriving: go back to step 2.

### 4. ⚠ Enumeration coverage — THE OPEN QUESTION

Platform variant resolution runs off the DIS entity-type 7-tuple. An
unrecognised tuple **does not error** — it falls to `_default`, resolves to
`UNKNOWN`, and the asset loses its platform metadata and effectively vanishes
from meaningful display. Silent, and indistinguishable from an asset that is
merely uninteresting.

The recognised set lives in
`openddil-contracts/ontology/dis_entity_types.yaml` and is currently **11
entries**, all `country=225` (US):

```
1_1_225_1_1_1_0   M1A1              1_2_225_20_1_3_0  AH-64E-V6
1_1_225_1_3_1_0   M1A2-SEPv3        1_2_225_21_1_2_0  UH-60M
1_1_225_2_1_1_0   M2A3-Bradley      1_2_225_22_1_1_0  CH-47F-BlockII
1_1_225_3_1_1_0   HMMWV-M1151A1     1_2_225_40_1_5_0  F-35A-Block4
1_1_225_80_1_1_0  RCV-M             1_2_225_41_1_1_0  F-16C-Block50
                                    1_2_225_50_1_1_0  MQ-9A-Block5
```

Print the same list from the generator (they are kept in step):

```bash
python openddil-customer-bundle-example/tools/dis-sim/dis_sim.py --list-types
```

**Before the session, answer:** which entity types will the VR-Forces
scenario actually emit, and is each one in that list? Every gap is either a
scenario change or an ontology addition — and ontology additions are
deployment configuration, so they belong in the deployment's overlay rather
than in a hurried edit to the shared file.

After traffic starts, the same question answered empirically:

```bash
kubectl -n $NS exec $REL-tier-pg-$PILOT-0 -- psql -U openddil -d openddil -tAc \
  "SELECT platform_variant, count(*) FROM telemetry_latest_state GROUP BY 1 ORDER BY 2 DESC;"
```

**A large `UNKNOWN` bucket is the coverage gap made visible.** That query is
the fastest read on whether the ontology matches the scenario.

### 5. No VR-Forces yet? Use the rehearsal generator

`openddil-customer-bundle-example/tools/dis-sim/` emits real EntityState PDUs
using the same library the ingestor decodes with, so the wire format is not
in question. It is **not a simulation** — no physics, no behaviours — but it
is sufficient to prove the chain end to end, and it produced this runbook's
rung (iii)/(iv) evidence.

```bash
cd openddil-customer-bundle-example/tools/dis-sim && ./deploy.sh $NS
```

> **`rpk produce` onto `raw-sensor-stream` is a debugging tool for one stage,
> NOT a proof path.** It skips decode and mapping and requires reproducing an
> internal wire shape by inspection. Entering at the DIS socket keeps the
> format an open published standard the pipeline already decodes.

---

## 1. Choose the pilot site

**Recommendation: `edge-01`.** Reasoning, so you can overrule it:

- Its data shape is the one both Arc 1 gates already exercised end to end
  (fusion and cm-service both ran against an `edge-01`-scoped Restate),
  so a failure here is far more likely to be *deployment* than *data*.
- It is a leaf tier with its own broker, which is the rule's requirement
  (`ADR-0032 §a`): a severance-tolerant presentation needs that tier's
  own broker.

**Overrule if:** `edge-01` is your busiest site. Pick a quieter one —
nothing in the procedure depends on which.

---

## 2. Pre-checks

```bash
kubectl -n $NS get pods | grep -E "redpanda-$PILOT|toxiproxy|postgres-hq"
```

**Expect:** the pilot's redpanda broker `Running`, toxiproxy `Running`.
**If the pilot broker is missing:** stop. The tier node requires that
tier's own broker; without it this pilot cannot demonstrate severance
tolerance and the deployment would be architecturally wrong, not just
broken.

```bash
kubectl -n $NS exec $REL-redpanda-$PILOT-0 -- \
  rpk topic list | head -20
```

**Expect:** `telemetry-latest-state`, `raw-sensor-stream` present.

### 2.5 Confirm data is actually FLOWING — not just that topics exist

**Do not skip this.** Everything in §4 and §5 measures rows and lag. If
nothing is being produced, every rung reads as a failure of the thing you
just deployed, and the runbook will appear to indict the tier node.

```bash
# High-watermark on the pilot's raw sensor topic. Run twice, ~30s apart.
kubectl -n $NS exec $REL-redpanda-$PILOT-0 -- \
  rpk topic describe raw-sensor-stream -p
```

**Expect:** `HIGH-WATERMARK` non-zero, and **larger on the second run**.

**If it is 0 and stays 0, STOP — the site has no data feed.** Nothing below
will pass, and none of it will be the tier node's fault. Confirm with:

```bash
kubectl -n $NS logs deploy/$REL-sensor-ingest-$PILOT --tail=3
# "Stats snapshot — received=0.0 decoded=0.0" means no DIS PDUs are arriving
```

Telemetry originates as **DIS UDP traffic from the upstream simulator**
(NodePorts 62040–62042). It is not generated by this stack — there is no
seed script and none is missing. A site whose feed is not yet wired looks
byte-for-byte identical to a broken deployment from inside the cluster.
Resolve the feed first, then return here.

*Found by rehearsal: a lab cluster with no upstream feed produced zeros at
every rung, and the original §4 text attributed them to the tier projector.*

### 2.6 Expect alarming, self-healing errors in the first ~60 seconds

The tier projector starts before `tier-schema-init` finishes, so early logs
contain lines like:

```
edge_buffer_status write failed: relation "edge_buffer_status" does not exist
Subscribed topic not available: asset-cm-state: UNKNOWN_TOPIC_OR_PART
```

**These are a startup race and they resolve themselves.** Both the table and
the topics are created moments later by the schema-init Job and topic-init
hook. Judge by `--since=2m` rather than by the log tail, which shows the
noisiest minute of the pod's life forever.

**Escalate only if they are still appearing after ~2 minutes.**

---

## 3. Deploy the tier node to the pilot only

Create `pilot-values.yaml`:

```yaml
tierNode:
  enabled: true
  tiers:
    - edge-01          # <-- must equal $PILOT
  postgres:
    useEmptyDir: true  # set false if you have a default StorageClass
  restate:
    defaultNumPartitions: 6   # PROVISION-TIME ONLY — see note below
    useEmptyDir: true
  topaz:
    enabled: true
```

> **`defaultNumPartitions` cannot be changed after the node first
> boots.** 6 is the measured tier profile (~167 MiB idle vs ~389 MiB at
> the product default of 24). If you want a different value, set it
> **now** — changing it later means destroying and recreating the tier's
> Restate volume.

```bash
helm upgrade --install $REL ./openddil-helm/openddil-demo \
  -n $NS -f pilot-values.yaml
```

**Expect:** upgrade succeeds.
**If it fails on an Atlas checksum error:** you skipped **P1**. Go back.

```bash
kubectl -n $NS get pods | grep tier-
```

**Expect, all `Running`/`Completed`:** `tier-pg-$PILOT`,
`tier-restate-$PILOT`, `tier-projector-$PILOT`, `tier-fusion-$PILOT`,
`tier-cm-$PILOT`, `tier-electric-$PILOT`, `tier-frontend-$PILOT`,
`tier-topaz-$PILOT`, plus completed jobs `tier-schema-init-$PILOT` and
`tier-restate-bootstrap-$PILOT`.

**If `tier-restate-bootstrap` is failing:** check its logs —

```bash
kubectl -n $NS logs job/$REL-tier-restate-bootstrap-$PILOT
```

Expect `201` responses for deployments and subscriptions. A message
containing *"specified cluster in the source URI does not exist"* means
the tier's `restate.toml` did not mount — **stop and report**, that is a
chart bug, not an environment issue.

---

## 4. Verification ladder, rungs (i) and (ii)

### (i) The tier serves its own UI from its own store

**THE HEADING IS NOW WHAT THE RUNG CHECKS.** Until 2026-09-05 it was not:
the procedure opened the UI, confirmed assets loaded, and then ran `psql`
**against the tier's postgres** — two facts verified separately, with the
join between them inferred. Under UD-9 the UI was reading the ROOT's
Electric while the tier's store was independently perfect, so both halves
passed and the heading was false.

*The general form is worth keeping:* **a check that verifies A, verifies B,
and concludes "A is joined to B" is not a check on the join.** Both halves
were well constructed. Neither measured the conjunction, and the conjunction
was the whole property.

```bash
kubectl -n $NS port-forward svc/$REL-tier-frontend-$PILOT 8090:80
```

#### 1. The UI states which tier it believes it is

Open `http://localhost:8090`.

**Expect:** the header shows `TIER <PILOT>` and, beside it, the data source
this instance is configured to read.

That claim is only possible because something told it — the tier parameter
arrives at runtime in `/deployment/deployment.json`, served from that tier's
own ConfigMap. A UI that had no tier config renders the demo shell and says
`DEMO SHELL · all tiers composed`, which is the honest answer and is **not**
a tier instance.

**If you see the demo-shell label on a tier node, stop.** The tier config
was rejected or never mounted, and the parser refuses a partial one rather
than guessing — a half-applied tier identity is a UI that confidently
believes it is a tier it is not.

Confirm the config the browser actually fetched, rather than the one the
chart meant to send:

```bash
curl -s http://localhost:8090/deployment/deployment.json
```

**Expect:** a `tier` block whose `id` is `$PILOT`.

#### 2. The UI's OWN read path returns this tier's data, and only this tier's

This is the join. It goes **through the same URL the browser uses** — not to
the database beside it.

```bash
# The frontend proxies /electric/ to this tier's read path. Ask it for the
# fleet exactly as the page does.
curl -s "http://localhost:8090/electric/v1/shape?table=telemetry_latest_state&offset=-1" \
  | grep -o '"edge_id":"[^"]*"' | sort -u
```

**Expect:** exactly one distinct `edge_id`, and it is `$PILOT`.

**More than one, or a different one, means the UI is reading somewhere
else** — which is precisely the defect this rung previously could not see.
Stop and report.

> **With enforcement enabled** (`releasability.enabled=true`) that request is
> refused without a session, which is correct and is itself a result: a bare
> `curl` returning `TOPAZ AUTHZ DENIED` proves the tier's PEP is in the path.
> Log in through the tier's own endpoint and repeat with the session cookie;
> `--tier` on the completeness gate covers the data half.

#### 3. Cross-check against the tier's store — now as a SECOND source, not the only one

```bash
kubectl -n $NS exec $REL-tier-pg-$PILOT-0 -- \
  psql -U openddil -d openddil -tAc \
  "SELECT count(*), count(DISTINCT edge_id) FROM telemetry_latest_state;"
```

**Expect:** a non-zero count, `edge_id` distinct = 1, and the same value step
2 returned. Two paths to one fact, compared — which is what makes this a
check on the join rather than two checks that happen to agree.

**If the count is 0 — check §2.5 FIRST, before suspecting the tier.**

A zero here means "no rows arrived", which has two very different causes and
the unhelpful one is far more common:

1. **Nothing is being produced at all** (no DIS feed at this site, or the
   upstream sim is not running). Then the ROOT store is *also* empty for this
   site, every tier looks broken, and nothing is wrong with the tier node.
   §2.5 distinguishes this in one command.
2. **The tier projector is not writing** — only worth investigating once
   §2.5 shows data actually flowing:
   `kubectl -n $NS logs deploy/$REL-tier-projector-$PILOT`.

An earlier version of this runbook named cause 2 only, which sends you to
read logs of a component that is behaving correctly. Rehearsal walked
straight into it.


### (ii) Parity with the root's view of the same site

```bash
# tier's own view
kubectl -n $NS exec $REL-tier-pg-$PILOT-0 -- psql -U openddil -d openddil -tAc \
  "SELECT count(*) FROM telemetry_latest_state;"

# root's view of that same site
# NOTE the different -U: the ROOT store's superuser is `postgres`, the TIER
# store's is `openddil`. They are not symmetric. Using -U openddil here fails
# with: FATAL: role "openddil" does not exist
kubectl -n $NS exec $REL-postgres-hq-0 -- psql -U postgres -d openddil -tAc \
  "SELECT count(*) FROM telemetry_latest_state WHERE edge_id = '$PILOT';"
```

**Expect:** the two counts agree, or differ by a small number of
in-flight rows. A large divergence means one projector is behind —
note both numbers and report.

**Also confirm severity is computing locally** (this is what the whole
(a) decision bought):

```bash
kubectl -n $NS exec $REL-tier-pg-$PILOT-0 -- psql -U openddil -d openddil -tAc \
  "SELECT overall_severity, count(*) FROM asset_logistics_status GROUP BY 1;"
```

**Expect:** rows. **If empty**, tier fusion is not producing — check
`kubectl -n $NS logs deploy/$REL-tier-fusion-$PILOT`.

---

## 5. ⭐ Rung (iii) — the severance proof. **RECORD THIS.**

This is the arc's proof artifact. **Start a screen recording before you
sever**, and keep the maintainer view visible throughout.

Recommended framing: browser at `http://localhost:8090` on the pilot's
maintainer view, with a terminal visible beside it for the sever command
and a live row count.

### Sever

```bash
curl -X POST http://localhost:8474/proxies/hq-link \
  -H 'Content-Type: application/json' -d '{"enabled": false}'
```

*(port-forward toxiproxy first: `kubectl -n $NS port-forward svc/$REL-toxiproxy 8474:8474`)*

### What to capture, in order

1. **The UI stays live.** Reload the page *while severed*. It must still
   load — this is the point of serving the UI from the tier. A cached tab
   surviving is not the proof; a **reload** is.

   > **VALID AGAIN AS OF 2026-09-05, and the history is worth one paragraph
   > because the failure was invisible.** This capture was briefly worthless:
   > the sever is `toxiproxy` on `hq-link`, which sits on the **Kafka** path,
   > while the tier UI was reading the ROOT's Electric over **HTTP** — which
   > that sever does not touch. The reload succeeded for the opposite of the
   > stated reason, and a recording would have asserted tier-local
   > presentation while the UI read the root throughout (UD-9).
   >
   > Two things had to change before this meant anything. The read path now
   > goes to the tier's own Electric through the tier's own PEP, and **the
   > tier's PEP now decides against the tier's OWN Topaz** — because pointing
   > it at the root's made the UI severance-INTOLERANT: cut the link and the
   > enforcement point could not reach its decision point, so it failed
   > closed and the screen showed DENIED instead of data. That was ADR-0036
   > clause 4 violated by the enforcement point, and it regressed this very
   > rung.
   >
   > **Run rung (i) step 2 while severed.** If the UI's own read path still
   > returns this tier's data, the reload below is proving what it claims.
2. **Telemetry keeps flowing.** Re-run the tier row-count query; the
   `last_sample_at` values keep advancing.
3. **Severity keeps computing.** Re-run the severity query. Values still
   update — the tier's own fusion is doing this, with no root involvement.
4. **The severance indicator shows the tier's OWN uplink.** The header
   should show the link down and a **climbing buffer count**. This is the
   inversion (`ADR-0032 §f`): previously that banner was the root's view
   of this site, computed centrally and unavailable here precisely when
   it mattered. Now it is the site describing itself.

**CROSS-CHECK THE BUFFER AGAINST THE BROKER.** Do not trust the UI counter
alone — read the number the broker itself holds:

```bash
kubectl -n $NS exec $REL-redpanda-$PILOT-0 -- \
  rpk group describe bridge-group-$PILOT | grep TOTAL-LAG
```

**Expect:** climbing steadily while severed, collapsing to ~0 within one
probe interval of the heal. Measured in rehearsal: 32 → 265 over 160s of
severance at ~1.65 msg/s, then back to 1 within 20 seconds of healing.

> **Fixed in chart 0.1.42 — and worth knowing if you are on anything older.**
> The buffer counter read **0 permanently**, on every cluster, since the
> feature shipped. `edge_buffer_monitor.py` defaults its consumer group to
> the bare `bridge-group`, while the bridge commits under
> `bridge-group-<edge_id>` — so the probe queried a group that never
> existed. A missing group returns no offsets, and the probe's contract is
> "0 if the group has not committed offsets yet", so a broken lookup and a
> quiet link are indistinguishable. **The DDIL buffering was working the
> whole time; only the instrument was blind.** 0.1.42 passes the correct
> per-edge group name from the chart.
>
> If the counter stays 0 while the `rpk` command above shows real lag, you
> are on a pre-0.1.42 chart. The buffering is fine — believe `rpk`.

> **Second caveat, still open:** the monitor's lag probe reads the tier's own
> broker (works while severed) but its toxiproxy probe reaches a root-tier
> service. In rehearsal the link-down flag appeared correctly at +20s but
> flapped back to `false` at +80s on a pre-0.1.42 build. The buffer number
> is the load-bearing signal; record any flag flapping and report it.

### Heal — rung (iv)

```bash
curl -X POST http://localhost:8474/proxies/hq-link \
  -H 'Content-Type: application/json' -d '{"enabled": true}'
```

**Expect:** buffered data drains upward, the root's count for `$PILOT`
converges with the tier's, and **the tier UI never flickered** — no
reconnect, no reload, no gap. Keep recording until convergence.

> ### AMENDMENT 2026-09-05 — what rung (iv) actually established
>
> **As written and as run, this rung proved that the bridge buffers and
> drains. It did NOT prove that HQ's view depends on the bridge, and it
> was read as if it had.**
>
> The sever above cuts `hq-link`, the toxiproxy the bridge publishes
> through. The root ALSO ran a per-edge projector that read the edge
> broker **directly**, never through that proxy, and wrote the root
> store. So through every severance ever run here, HQ stayed fresh.
> **HQ was never observed to diverge, so "converges" was convergence onto
> a value it had never left** — and a convergence check that cannot fail
> is not evidence of convergence.
>
> The buffer growing 32 → 165 and draining is real and still stands: the
> bridge does buffer, and it does drain. That is a claim about the
> bridge. The claim this rung was being cited for — that a severed site
> keeps HQ's picture correct-but-stale and heals — was never tested.
>
> **Two things had to change before this rung means what it says.**
> 1. The downward projector is retired for a tier-managed edge, and HQ's
>    view of it is projected from the BRIDGED topics instead (UD-11), so
>    there is exactly one writer and it is behind the bridge.
> 2. The sever must cut **every** path across the boundary, not one link.
>    `scripts/sever-tier.sh <tier> on` applies a default-deny
>    NetworkPolicy to the site and **proves the cut both ways** before
>    returning. Keep toxiproxy for the buffer demonstration — it is the
>    right instrument for showing the bridge queue — but it is not the
>    instrument for isolating a site.
>
> **The rung is not runnable as evidence until step (c) below can fail.**
> Add to the expectations, and treat a miss as a stop-and-report:
>
> - **(c) During severance, HQ's view of `$PILOT` goes STALE — its
>   freshness indicator degrades and its timestamps stop advancing.**
>   Not fresh (a path is still open), and not empty (nothing is writing
>   it at all — which is a different defect, and not the degraded mode
>   ADR-0036 clause 4 specifies). Record the HQ timestamp at sever and
>   again a minute later; it must not have moved.
> - **(d) Only then is the heal meaningful**, because divergence was
>   observed first and convergence now has somewhere to converge from.
>
> *The rule, which is not about this rung:* **a sever measures only the
> paths it cuts.** Any component crossing the boundary by another route
> makes the site look severance-tolerant for the wrong reason, and the
> stronger the result looks, the less anyone re-examines it.

---

## 6. Report back

- P2's cardinality number.
- Whether every rung passed, and any "stop and report" branch you hit.
- **The rung (iii) recording.**
- Whether the link-down flag appeared during severance (the caveat above).

**Do not** roll out to other tiers yet. The pilot is deliberately one
site; fleet rollout is the phase after this one, and it templates from
whatever this session learns.
