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

**Required: chart ≥ 0.1.41.** If the cluster is on anything earlier, stop
and upgrade before running a single step below.

```bash
helm list -n "$NS" -f "^${REL}$" -o json | python -c \
  "import json,sys; r=json.load(sys.stdin)[0]; print(r['chart'], '|', r['status'])"
# expect: openddil-demo-0.1.41 (or later) | deployed
```

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

```bash
kubectl -n $NS port-forward svc/$REL-tier-frontend-$PILOT 8090:80
```

Open `http://localhost:8090`.

**Expect:** the maintainer view loads and shows assets. Confirm it is
reading tier-locally:

```bash
kubectl -n $NS exec $REL-tier-pg-$PILOT-0 -- \
  psql -U openddil -d openddil -tAc \
  "SELECT count(*), count(DISTINCT edge_id) FROM telemetry_latest_state;"
```

**Expect:** a non-zero count, and **`edge_id` distinct = 1**. More than
one means the tier is receiving other tiers' data — **stop and report**.

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

---

## 6. Report back

- P2's cardinality number.
- Whether every rung passed, and any "stop and report" branch you hit.
- **The rung (iii) recording.**
- Whether the link-down flag appeared during severance (the caveat above).

**Do not** roll out to other tiers yet. The pilot is deliberately one
site; fleet rollout is the phase after this one, and it templates from
whatever this session learns.
