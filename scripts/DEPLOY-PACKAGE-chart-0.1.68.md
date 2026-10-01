# Deploy package — chart `openddil-demo-0.1.68`

> **This supersedes `DEPLOY-PACKAGE-chart-0.1.58.md` as the procedure, and §2 here supersedes
> `WORK-DEPLOY-revision-51.md` §2 as the difference list.** The older files are kept because they
> hold the measurements behind several rows below. Where this file and an older one disagree, this
> one was written later and against later measurements.

Baseline is **chart 0.1.63** (`openddil-helm@b8dd645`), the version the work cluster runs. Target is
**chart 0.1.68** (`openddil-helm@ba7a663`), the chart's last change. Later commits touch only
`scripts/`. The lab has been on 0.1.68 since 2026-10-01 (lab revision 65, all predictions matched), and on the §1 bundle since lab revision 66 (bundle-only upgrade, all predictions matched).

Every count in this file is either a **render** (produced from the repository, reproducible on any
machine) or a **lab measurement** (dated). Nothing is a count taken at work, because nothing here has
run there yet. The render counts below were made with work-shaped values: the tier-node topology,
per-tier UIs on edge-01, edge-02 and region-east, one declared pull secret, `imageTag: latest`,
`imagePullPolicy: Always`, and no `restate.ephemeralOnUpgrade`.

---

## 0. Read this first

**(a) What rolls: 34 pod specs of 82, by render.**

| from → to, same work-shaped values | pod specs changed |
|---|---|
| 0.1.63 → 0.1.66 | 33 |
| 0.1.66 → 0.1.68 | 5 (all four frontends + Keycloak, branding) |
| **0.1.63 → 0.1.68, the jump work makes** | **34** (the 33, plus the HQ frontend) |

The 34 are as follows:
- the releasability trio: `keycloak`, `pep`, `topaz-hq`;
- the HQ `frontend`;
- per tier on edge-01, edge-02 and region-east: `tier-cm`, `tier-electric`, `tier-frontend`,
  `tier-fusion`, `tier-pep`, `tier-projector`, `tier-topaz` (Deployments), `tier-pg` and
  `tier-restate` (StatefulSets), and the `tier-schema-init` post-upgrade hook Job.

The other 48 are unchanged. That includes all of edge-03, the HQ core, every broker, and
`postgres-hq`.

The upgrade also adds three Ingresses, one per tier UI. Under `imageTag: latest` +
`pullPolicy: Always`, the 34 pull whatever `latest` is at upgrade time and the other 48 do not.
This is why §0(c) matters.

**(b) Five gates, in this order. Each one is a command whose output is read before the next.**

| # | gate | expect | why |
|---|---|---|---|
| G1 | `PROBE_IMAGE=<mirrored busybox> scripts/check-service-routing.sh [ns]` | every node routes a new Service | 2.3 — a node that cannot route a Service created mid-upgrade fails the post-upgrade hooks, and a restart does not fix it |
| G2 | `scripts/check-pull-credentials.sh "$NS" -- -f "$VALUES"` | PASS, exit 0 | 2.1 — from 0.1.66 every pod names its own pull secret, so anything it inherited from its ServiceAccount stops arriving |
| G3 | `scripts/check-cluster-config.sh "$NS"` | PASS, every broker `auto_create_topics_enabled=false` | 2.2 — the setting is cluster state that no rendered manifest controls |
| G4 | `helm template "$REL" ./openddil-demo -n "$NS" -f "$VALUES" \| grep -c restate-wipe` | **0** at work, unless you decide otherwise | 2.4 — the number states what the upgrade and a rollback will do to Restate state |
| G5 | bundle digest pinned in `$VALUES` | the digest of record (§1) | 0(c) |

Each gate returns 0 for PASS, 1 for FAIL and 3 for "did not run" (no cluster, no tool, no namespace).
**Never read 3 as a pass.** All four scripts were made to fail on purpose before being trusted:

| gate | made to fail on purpose by | result | then |
|---|---|---|---|
| G1 | lab nodes that could not route | FAIL, exit 1 | green 6/6 after the node fix |
| G2 | a ServiceAccount fixture carrying an undeclared secret | FAIL naming the SA and the secret | |
| G2 | a declared secret that does not exist | FAIL | lab values: PASS |
| G3 | `EXPECT=true` | FAIL on 5 of 5 brokers | lab: PASS 5/5 |

**(c) The bundle and the images float at work. Pin the bundle.** Work-shaped values set no
`bundle.image.digest`, so the runtime bundle resolves to `runtime-bundle:latest` (49 references in
the render). The bundle carries the dynamic mappings, including the ingress kind gate, the Atlas
migrations and the ontology. An unpinned upgrade takes whatever was last published, which is a
deploy nobody predicted. Set `bundle.image.digest` to the digest of record in §1 and check that
`helm template … | grep -c 'runtime-bundle@sha256'` is non-zero. The lab has run pinned since
2026-10-01.

---

## 1. What changed since 0.1.63, by chart version

| version | change | rolls at work |
|---|---|---|
| 0.1.64 | each workload declares its consumer groups on its own metadata (reset finds consumers by declaration, never by address) | nothing (object metadata, not pod template) |
| 0.1.65 | identity pods (PEP, Topaz, tier Topaz) roll on policy content, not on every revision | the identity pods, once |
| 0.1.66 | `global.imagePullSecrets` on every pod spec (releasability + tier-node had been missing it) | 33 |
| 0.1.67 | optional branding ConfigMap mounted on every frontend | 4 frontends |
| 0.1.68 | Keycloak sign-in theme from the branding ConfigMap, defaults from the frontend image | Keycloak |
| (unversioned, in 0.1.68) | Restate wipe + registration hooks also run on rollback (2.4); guard 5 in the render guards | nothing on upgrade |

**Bundle and images of record (lab, 2026-10-01):** runtime-bundle
`sha256:0f94d16cba75643d9408bd46f83218e87dae5cdd1ef277f9d97dd9873b8547b7`. This carries the kind
gate's stateless removal handling (2.5) and the lifecycle rollup with its migration
`20261001000000_region_fleet_summary_terminal_status` (2.7). It supersedes `sha256:ee6540de…`,
which carries 2.5 only. Chart 0.1.68 is unchanged by 2.7: only the bundle pin moves.

---

## 2. What is different at work — the current list

### 2.1 Pull credentials: anything a pod inherited from its ServiceAccount stops arriving at 0.1.66

Kubernetes admission copies a ServiceAccount's `imagePullSecrets` into a pod **only when the pod names
none**. On 0.1.63, the 33 pod specs in §0(a) name none, so whatever pull secret they use today may be
arriving through their ServiceAccount. From 0.1.66 every pod names `<pull-secret>` itself. Any other
secret the ServiceAccount carries then **stops reaching those pods**. The failure is an
`ImagePullBackOff` on the 34 rolled pods while the other 48 keep running. It looks partial, and it is.

G2 checks this before the upgrade. It renders the chart with your values, lists the declared secrets
and the ServiceAccounts the pods use, and then reads the live namespace:
- a declared secret that does not exist fails the gate;
- an undeclared secret that a live pod or ServiceAccount carries fails the gate, except
  `*-dockercfg-*`, which the platform injects.

The fix for a FAIL is to add the named secret to `global.imagePullSecrets`. Do not remove it from the
ServiceAccount.

A ServiceAccount that only a hook uses and that does not exist between upgrades is reported as a
NOTE, not a FAIL. The chart creates it, so nothing can be inherited through it.

If you want the raw view the gate is built on:
```bash
kubectl -n "$NS" get pods -o custom-columns='POD:.metadata.name,SA:.spec.serviceAccountName,PULL:.spec.imagePullSecrets[*].name'
```
If the PULL column shows only `*-dockercfg-*` or `<none>`, credentials come from the node (a
cluster-wide pull secret) or from an anonymous mirror. With `pullPolicy: Always`, "it was cached" does
not explain a successful pull, because the registry is still checked.

### 2.2 Cluster config: `auto_create_topics_enabled` — and the runbook note was wrong about its name

`--set redpanda.auto_create_topics_enabled=false` on `redpanda start` only seeds the value at
first cluster formation. After that, the value is cluster state that no rendered manifest controls.

The chart's post-upgrade hook `openddil-redpanda-auto-create-off` (weight 6) sets it and reads it
back. G3 runs the same script in assert-only mode (`ASSERT_ONLY=1`, no `set` is ever issued). Run it:
- **before** the upgrade, which tells you what the cluster is today;
- **after** the upgrade, which tells you the hook did its job.

Two corrections, both measured on the lab on 2026-10-01:
- **The property name for `rpk cluster config` is `auto_create_topics_enabled`.** Every broker
  rejects `redpanda.auto_create_topics_enabled` as an unknown property.
  `RUNBOOK-NOTE-cluster-config-not-applied-by-chart.md` used the prefixed name in its `set` and `get`
  commands and is corrected alongside this file. The prefix is right only for `redpanda start --set`.
- **HQ's admin port depends on how you reach it.** Through the Service (another pod, Service DNS),
  HQ answers on **19644** and 9644 is not exposed. From inside the HQ pod at `localhost`, it is
  **9644**. Edge and region answer on 9644 both ways. The older note measured the second path, and the
  chart script documents the first; both were right for their own path. G3 derives each broker's
  admin port from that broker's own Service, so you never choose one.

Also printed by every broker, and informational only: `core_balancing_continuous` and
`partition_auto_balancing_continuous` are flagged as enterprise-licensed features in use. Nothing is
enforced today. Know it is there before someone reads it as an error during the cut.

### 2.3 Node routing: a node that cannot route a new Service fails the hooks, not the pods

Lab revision 62 failed at its post-upgrade hooks. Restate pods were wiped and replaced, the hooks
could not reach them, and on two nodes kube-proxy never programmed the new Service.

The cause was measured: kube-proxy's full `iptables-restore` batch was larger than the node's socket
send-buffer cap, so every full sync failed (`EMSGSIZE`) and only partial syncs landed. **Restarting
the node agent does not fix it.** The cap is a host setting.

G1 creates a throwaway Service and checks that every node routes it. Its probe objects go in a
namespace the script creates and deletes (default `openddil-preflight`), so the account running it
needs that permission, or pass an existing namespace. In an air gap, set `PROBE_IMAGE` to a
busybox-compatible image the nodes can pull from the mirror. Run it before every upgrade, on any
cluster where you do not own the host kernel settings.

### 2.4 Rollback now re-runs setup; it wipes Restate only where upgrades do

Since `ab9e623`, the Restate wipe hook also registers `pre-rollback`, and the setup Jobs also
register `post-rollback`. At work-shaped values that is **7 Jobs**: `topic-init`,
`redpanda-auto-create-off`, the CM and logistics bootstraps, and the three tier Restate bootstraps. The two
schema-inits do not, by design: a rollback must not re-run a migration forward.

`1d69f98` asserts this in the render guards. It was red-checked by reverting one bootstrap: FAIL in
all three variants.

At work-shaped values, G4 renders **0** wipe lines, and the 7 Jobs above carry `post-rollback`. So at
work:
- **an upgrade does not wipe Restate**;
- **a rollback does not wipe Restate either**, but now re-registers the deployments afterwards.

Earlier packages called rollback "state-neutral for Restate". That stays true at work. It is no
longer true on a cluster that sets `restate.ephemeralOnUpgrade: true`, as the lab does, where a
rollback now wipes too.

If you decide to set the flag at work, G4 must read the lab's number (11), not 0, and every
prediction must include the Restate pods being replaced.

### 2.5 DIS removal: admitted by kind, dropped by key if nothing knows the asset

The ingress kind gate (`WORK-DEPLOY-revision-51.md` §2.9, still required and still default-on) now
lets every Remove Entity PDU through. Entity-bearing PDUs are still gated by kind.

The decision moves downstream, to the services that own the asset's state. When a removal names an
asset the service has never seen:
- the projector writes no row and counts the drop in `projector_removal_unknown_asset_dropped_total{table}`;
- the CM and logistics services return without creating state and count the drop on their own
  metrics endpoint, `:9464`.

This replaced a design in which the gate remembered admitted ids in a cache. That design lost its
memory on every connector restart.

The change arrives through the **bundle** (the gate mapping) and the **images** (projector, CM,
logistics). Neither arrives through values, so `helm get values` will never show it. On the lab, an
admitted id's removal reached the stores, and a never-admitted id's removal was dropped and counted
(0 → 1).

What to watch at work: the three counters should sit at 0 or near it. A climbing counter means
removals for assets this cluster never admitted, which is a finding about the simulator's id space.
It is not a fault in the gate.

### 2.6 Branding: five pods roll, and Keycloak now pulls the frontend image

From 0.1.67, every frontend mounts an **optional** branding ConfigMap. When the ConfigMap is absent,
the UI renders the defaults shipped in the frontend image. From 0.1.68, Keycloak's sign-in theme comes
from the same ConfigMap, through an init container that runs **the frontend image**.

This matters in an air gap: Keycloak now cannot start unless the frontend image is pullable. The
frontend image is already in the mirror for the four frontends, so this adds no mirror row. It does
add a dependency that is new at 0.1.68.

If your deployment supplies its own branding ConfigMap, check the result after the upgrade with
`scripts/check-brand-scope.sh` in the openddil-demo repository. It fails when a fallback, an autoindex or an alias
variant leaks.

### 2.7 Lifecycle in the regional rollup (ADR-0044 §3)

`region_fleet_summary` gains `destroyed`, `deactivated` and `removed`.
- The four severity buckets now count only assets **without** a terminal operational-status claim.
- `asset_count` still counts every asset, so a destroyed asset is counted as destroyed. It is not
  absent, and it is not a severity bucket.

The columns are additive (`NOT NULL DEFAULT 0`), and the migration arrives with the bundle. A frontend
older than the columns shows them as 0.

**Status: measured, in the §1 bundle.** It needs the projector and faust-regional images built from
the same day (pulled on `:latest`) and the bundle at the §1 digest. No chart change.

Measured, every predicted line matched:
- **Compose:** one fresh entity was destroyed on a 45 s schedule. Its class went from
  22 | 20 | 0 | 0 | 2 to 22 | 19 | 1 | 0 | 2 (`asset_count` | buckets | destroyed | deactivated |
  removed). The region summed 31 | 25 | 2 | 1 | 3, and buckets = `asset_count` − terminal held in
  every class.
- **Lab:** the bundle-only upgrade replaced exactly the predicted Deployments plus the 4 Restate pods.
  The migration landed at the HQ and regional stores, and the rows were unchanged with zeros. One
  asset was then destroyed by the DIS sim schedule (`DIS_DESTROY_SCHEDULE=<asset>@300`). Its row
  went to `destroyed | reporting` at the edge, regional and HQ stores. Its class read 7 | 6 | 1 | 0 | 0
  at both the regional store and HQ, and fleet counts were unchanged.

What changes for an operator: a destroyed asset now leaves the severity buckets. Before this bundle
it was folded into one of them.

### 2.8 Still true from `WORK-DEPLOY-revision-51.md` §2

These are unchanged by anything since. Read them there:
- 2.0: verify variant resolution before trusting any variant-dependent check;
- 2.1: the COTS simulator in place of `dis-sim`;
- 2.2: the wipe flag is false at work (now asserted by G4);
- 2.5: the egress gate is compose-only. The Cursor on Target bridge built on 2026-10-01 is also
  compose-only;
- 2.6: kubeconfig and the cluster guard;
- 2.7: indicators that point the wrong way during a cut;
- 2.9: the kind gate.

From its §4, these are also still open:
- **seven state topics are `delete` on region-east and `compact` everywhere else.** G3 does not check
  topic configs; check them per broker with `rpk topic describe <topic> -p`;
- **the scenario reset is not yet proven end to end.** Do not run it at work until it has round-tripped
  on the lab (baseline, reset, re-seed, same counts). That round trip is scheduled. This line changes
  only when it is measured.

---

## 3. Pre-deploy checklist

- [ ] `kubectl config current-context` is the work cluster, and `.expected-context` was set deliberately
- [ ] `helm get values "$REL" -n "$NS" > values-before.yaml` — **keep it**; `helm rollback` restores
      the chart, not the `-f` files
- [ ] `helm history "$REL" -n "$NS" | tail -3` — the 0.1.63 revision is there to roll back to
- [ ] G1 routing: every node ok
- [ ] G2 pull credentials: PASS, exit 0, with the exact `-f` files the upgrade will pass
- [ ] G3 cluster config: result recorded (FAIL here is information before the upgrade; it must PASS after)
- [ ] G4 wipe render: **0**, or 11 if you decided to wipe, and the predictions say which
- [ ] G5 bundle digest pinned; `grep -c 'runtime-bundle@sha256'` non-zero in the render
- [ ] Predictions written: 34 pods roll, 3 Ingresses added, which Restate pods (none at 0), the
      store counts after, and the four-profile login

## 4. Rollback

```bash
helm rollback "$REL" <0.1.63 revision> -n "$NS"
```

| returns | does not return |
|---|---|
| chart 0.1.63, so the 34 pods roll back | `-f` values — re-pass them |
| pods without their own pull secrets (ServiceAccount inheritance resumes) | schema migrations applied forward |
| frontends without the branding mount | Restate state, if the flag was set (2.4) |

With the flag unset, a rollback wipes nothing and re-registers the Restate deployments (2.4). It is a
second 34-pod roll, so decide against the post-deploy checks, not against pod status.

## 5. Post-deploy, in order

1. `kubectl rollout status` on the 34. "Running" is not verification.
2. G3 again: **PASS on every broker** (the hook ran).
3. G1 again (cheap, and it catches a node that went bad during the roll).
4. Store counts per tier against the prediction. Then the three removal counters from 2.5 (expect 0
   or near it).
5. Four-profile login: one per tier UI and the HQ operator. On a branded deployment, also
   `check-brand-scope.sh`.
6. Write the measured results next to the predictions. A prediction that is never checked back reads
   as settled, and it isn't.
