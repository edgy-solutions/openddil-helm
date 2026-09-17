# Unwedging the 2026-09-17 stack — operator steps

Three defects, each hiding the next, each of which made the one below it
invisible. The chart fixes are landed and gated. **The cluster steps below
need a human — every one of them was refused to the agent as a cluster
mutation.**

    export KUBECONFIG=~/git/edgy-infra/ansible/kubeconfig
    cd ~/git/openddil/openddil-helm

---

## What was actually wrong

**1 — Restate OOM.** `1Gi` limit, ~1600 restarts. Fixed (`2Gi`), landed in
revision 46, confirmed live: `limits.memory=2Gi`.

**2 — zstd on Restate-subscribed topics.** Restate's librdkafka has no zstd;
one zstd batch kills the consumer task forever. Fix authored
(`compression.type=lz4` on the six subscribed topics). **NEVER APPLIED** —
see 3.

**3 — the comment that prevented its own fix.** The comment block explaining
2 was placed *inside a line continuation*:

```sh
for spec in \
    # compression.type=lz4 ON EVERY TOPIC RESTATE SUBSCRIBES TO
    ...
    "raw-sensor-stream|-p 1 -r 1 ..." \
```

The backslash joins the next line, `#` eats the rest of it, the `for` loses
its word list, and **the whole script is a parse error** — so `topic-init`
ran nothing. 7 retries → `BackoffLimitExceeded` → the `post-upgrade` hook
failed → **the release wedged in `pending-upgrade` for eight hours** → the
*other* `post-upgrade` hook, `tier-restate-bootstrap-*`, never ran either.

Verified with `sh -n`, not by reading. Fixed; guard 4 added.

**4 — and underneath all of it, the tier Restate was unrecoverable.**
`POST /query` on edge-01's Restate answered:

    Datafusion error: External error: node N1:1645 was shut down or removed

Its cluster metadata still referenced node generations destroyed by the 1600
OOM restarts, so an invocation could be neither created nor enumerated.
Not "invocations failing", not "invocations absent" — a third state, where
the substrate cannot answer questions about itself.

It survived every upgrade because `hook-restate-wipe.yaml` wiped
`data-<release>-restate-server-0` and **mentioned `tier-restate` zero times**.
`ephemeralOnUpgrade: true` meant *ephemeral* at the root and *durable
forever* at all three tiers — one flag, one name, no warning. Fixed.

---

## Current cluster state (left mid-repair — read this before acting)

| thing | state |
|---|---|
| release `openddil` | **revision 47 `pending-upgrade`**, 8h, never completed |
| `openddil-topic-init` Job | **Failed**, `BackoffLimitExceeded`, pods GC'd |
| `data-openddil-tier-restate-edge-01-0` | **deleted and recreated empty** by me |
| edge-01 Restate deployments | **`[]` — wiped, NOT re-registered** |
| edge-01 Restate subscriptions | **`[]` — wiped, NOT re-registered** |
| edge-02 / region-east Restate | untouched, still carrying old metadata |

**edge-01 is deliberately mid-surgery.** Its Restate is clean but empty; it
will stay inert until a bootstrap registers services against it. That is the
`helm upgrade` below.

---

## Step 1 — clear the wedged release

`helm upgrade` refuses while another operation is in progress. Drop the
never-completed v47 record so Helm treats v46 (the last `deployed`) as
current:

```bash
kubectl -n openddil delete secret sh.helm.release.v1.openddil.v47
helm list -n openddil            # openddil must now appear, STATUS=deployed
```

`helm rollback openddil 46` also works and is the more conventional remedy;
it is avoided here only because it would re-apply revision 46's manifests
for no benefit — v47's non-hook content is already live.

## Step 2 — verify the fixes before touching the cluster

```bash
bash scripts/check-chart-render.sh        # guards 1-4, must end "clean"
```

Guard 4 is new and is the one that matters: it parses all 34 rendered shell
scripts with a real shell. Red-checked against the actual broken template.

## Step 3 — upgrade

```bash
helm upgrade openddil ./openddil-demo -n openddil --timeout 15m
```

This does four things in order, and **all four are the repair**:

1. `restate-wipe` (pre-upgrade, weight -100) now wipes the root **and all
   three tier Restates** — discarding the corrupt node-generation metadata on
   edge-02 and region-east too;
2. StatefulSets recreate every Restate PVC empty;
3. `topic-init` (post-upgrade) **actually runs**, applying
   `compression.type=lz4` to the six Restate-subscribed topics;
4. `tier-restate-bootstrap-<id>` re-registers deployments + subscriptions
   against each fresh Restate.

**Give it the full 15m and do not Ctrl-C it.** A killed `helm upgrade`
mid-hook is exactly what produced the eight-hour wedge above.

## Step 4 — confirm the derive stage is actually alive

The thing that has never once been true:

```bash
kubectl -n openddil exec openddil-redpanda-edge-01-0 -c redpanda -- \
  rpk topic describe asset-cm-state -c | grep compression   # expect lz4

bash scripts/check-advancing.sh openddil 60                 # nine stages
python scripts/check_tier_feed.py openddil
bash scripts/check-releasability-completeness.sh -n openddil
```

`asset-cm-state` and `asset-logistics-status` must show a **non-zero delta**.
Every previous green reading on the surrounding checks coexisted with both
sitting at `+0`, which is the whole reason for the derive-stage check still
open as follow-up (2).

## Step 5 — then, and only then

Measure Restate RSS against the **167 MiB** baseline. `2Gi` was set as
headroom during an outage, not as a sizing decision; the number that replaces
it should come from a Restate that is actually processing invocations, which
none has been.

---

## Still open after this

* **Follow-up (2)** — derive-stage pre-flight: consumed-vs-completed per
  subscription, with deployment reachability as the third term. Every check
  in the suite was green while fusion received zero invocations; none of them
  asks whether the derive stage *completes* anything.
* **Follow-up (3)** — which client writes zstd. `lz4` on the topic makes the
  broker re-encode, so the defect cannot recur, but the producer is still
  unidentified and the reasoning for a declared codec is still unwritten.
* **Follow-up (5)** — nightly cron for `check-advancing` + the gate.
* **No recording until step 4 passes.** `RECORDING-READINESS.md` §D is stale:
  it records the nine advancing stages green, which they were, while the
  derive stage produced nothing.
