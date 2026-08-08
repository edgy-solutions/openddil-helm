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

## Pre-flight — three parked items, same credentials

Do these first. They are unrelated to the pilot but need the same access,
and each has been waiting on a cluster session.

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

**If the count is 0:** the tier projector is not writing. Check
`kubectl -n $NS logs deploy/$REL-tier-projector-$PILOT`.

### (ii) Parity with the root's view of the same site

```bash
# tier's own view
kubectl -n $NS exec $REL-tier-pg-$PILOT-0 -- psql -U openddil -d openddil -tAc \
  "SELECT count(*) FROM telemetry_latest_state;"

# root's view of that same site
kubectl -n $NS exec $REL-postgres-hq-0 -- psql -U openddil -d openddil -tAc \
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

> **Honest caveat to watch for:** the buffer monitor's lag probe reads
> the tier's own broker (works while severed), but its toxiproxy probe
> reaches a root-tier service. If the *link-down flag* fails to appear
> while the *buffer count still climbs*, that is a known seam — record it
> and report; the buffer number is the load-bearing signal.

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
