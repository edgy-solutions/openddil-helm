# Deploy package — chart `openddil-demo-0.1.71` at `openddil-helm@458d39b`

> **This supersedes `DEPLOY-PACKAGE-chart-0.1.68.md` as the procedure.** §2 of that file still holds
> for every row this file does not replace. §2.9 here lists which rows those are. Where the two
> disagree, this one was written later and against later measurements.

Baseline is **chart 0.1.63** (`openddil-helm@b8dd645`), the version the work cluster runs. Target is
**`openddil-helm@458d39b`**.

**Pin the commit, not the version string.** The chart reads `0.1.71`, but ten chart commits landed after
the 0.1.71 bump (`91c1758`) without bumping it, so two different charts carry the same string. Until the
string is bumped, `0.1.71` alone does not identify what you are installing. Quote the commit in every
prediction and every change record.

The lab has been on `458d39b` since 2026-10-03 (lab revision 77), and all six predicted sections
matched. It took the commits one at a time (revisions 69–77), never the whole jump at once. The jump
work makes is therefore a **render** here and has not been measured.

Every count in this file is either a **render** (produced from the repository, reproducible on any
machine) or a **lab measurement** (dated). As in the 0.1.68 package, the renders use work-shaped
values:
- the tier-node topology;
- per-tier UIs on edge-01, edge-02 and region-east;
- one declared pull secret;
- `imageTag: latest`, `imagePullPolicy: Always`;
- `restate.ephemeralOnUpgrade: false`;
- releasability **on**, as at work;
- everything new in §1 left at its default (off).

The renders were made with `helm template` (Helm 3.14.3) against `b8dd645`, `ba7a663` and `458d39b`.
They reproduce the 0.1.68 package's 34 changed pod specs name for name. That package's "of 82" also
counted the chart's 7 `helm test` Pods. This file counts Deployments, StatefulSets and Jobs only,
which gives 75 at 0.1.63 and 0.1.68.

---

## 0. Read this first

**(a) What rolls, by render.**

Counts are of Deployments, StatefulSets and Jobs, all at the same work-shaped values:

| from → to | pod specs | changed | added | removed |
|---|---|---|---|---|
| 0.1.63 → 0.1.68 | 75 → 75 | 34 | 0 | 0 |
| 0.1.68 → `458d39b` | 75 → 79 | 12 | 4 | 0 |
| **0.1.63 → `458d39b`, the jump work makes** | **75 → 79** | **37** | **4** | **0** |

**The 37 changed** are the 34 from the 0.1.68 package §0(a), plus three that change only after 0.1.68:
- `egress-gate-c2`: `checksum/registries`, so it rolls with the registry;
- the hub `postgres-schema-init`: `--tx-mode none` and the pre-upgrade phase;
- the hub `topic-init`: the pre-upgrade phase. The `parts-availability` topic is added under
  releasability.

**The 12 changed between 0.1.68 and `458d39b`** are:
- `egress-gate-c2`;
- the HQ `frontend` and the `pep` (the egress pane through the PEP);
- `topaz-hq` and the three tier Topaz Deployments (they load the destination registry);
- `postgres-schema-init`, `topic-init`, and the three `tier-schema-init` Jobs.

The commit for each change is assigned by reading the commits. There is no per-commit render behind
it.

**The 4 added** are new per-tier topic-init Jobs: `topic-init-edge-01`, `-edge-02`, `-edge-03` and
`-region-east`. Each picks its hook phase per §2.2.

**Other objects (0.1.63 → `458d39b`):**
- added: the ConfigMaps `frontend-deployment-config` and `keycloak-theme`, and the NetworkPolicy
  `egress-pane-pep-only`;
- removed: nothing;
- Ingresses and Services: no change (4 and 50).

The 0.1.68 package's "adds three Ingresses" was the switch onto per-tier-UI values. It was not a
chart change, and it does not happen again here.

**Images: no new image reference** at work-shaped values (24 distinct in all three renders). The
mirror needs nothing new unless you turn TAK on (§2.4).

**Restate: G4 renders 0 wipe lines in all three.** The upgrade wipes no Restate state.

**Bundle: 49 references to `runtime-bundle:latest`, 0 pinned, in all three renders.** §0(c) applies
unchanged.

**If you turn TAK on.** `egress.tak.enabled`, `tak.tls.enabled`, a Secret name and one CN add:
- 2 pod specs, `tak-server` (with the ghostunnel sidecar) and `egress-cot-adapter-c2`;
- 3 objects, the `tak-server-readers-only` NetworkPolicy and the `tak-server` and `tak-server-tls`
  Services;
- 2 images, `openddil/tak-server` and `ghostunnel/ghostunnel@sha256:2599b8a0…`.

Setting `egress.credentials.existingSecret` alone changes nothing. It mounts only into
egress-forwarder and egress-intake, and both are off by default.

**Hook phases differ between a render and the upgrade.**
- The hub `postgres-schema-init` and hub `topic-init` are `post-install,pre-upgrade` in every render.
- The tier schema-init and per-tier topic-init Jobs show `post-install` only under `helm template`.
  That is the install branch: `helm template` cannot query the cluster.
- The upgrade decides these per backend (§2.2). G6 is the only way to see that decision before the
  upgrade.

**(b) Gates, in this order. Each is a command whose output is read before the next.**

G1–G5 are unchanged from the 0.1.68 package §0(b): routing, pull credentials, cluster config, the wipe
render, and the bundle pin. Three gates are new. G7 and G8 apply only if you turn the matching feature
on.

| # | gate | expect | why |
|---|---|---|---|
| G1 | `PROBE_IMAGE=<mirrored busybox> scripts/check-service-routing.sh [ns]` | every node routes a new Service | 0.1.68 §2.3 |
| G2 | `scripts/check-pull-credentials.sh "$NS" -- -f "$VALUES"` | PASS, exit 0 | 0.1.68 §2.1 |
| G3 | `scripts/check-cluster-config.sh "$NS"` | PASS on every broker | 0.1.68 §2.2 |
| G4 | `helm template "$REL" ./openddil-demo -n "$NS" -f "$VALUES" \| grep -c restate-wipe` | **0** at work | 0.1.68 §2.4 |
| G5 | `bundle.image.digest` in `$VALUES` | the digest of record (§1) | 0.1.68 §0(c) |
| **G6** | `helm upgrade "$REL" ./openddil-demo -n "$NS" -f "$VALUES" --dry-run=server` and read every init Job's `helm.sh/hook` | each schema-init and topic-init Job whose backend already exists says **`pre-upgrade`** | §2.2: the hook phase is decided by a live lookup that only a server-side render performs |
| **G7** | TAK TLS only: `kubectl -n "$NS" get secret <egress.tak.tls.secretName> -o jsonpath='{.data}' \| grep -o '"[a-z.]*"'` | exactly `"ca.pem"`, `"server.key"`, `"server.pem"`. Also `allowedClientCNs` is non-empty in `$VALUES` | §2.4 |
| **G8** | client credentials only: `kubectl -n "$NS" get secret <egress.credentials.existingSecret> -o jsonpath='{.data}' \| grep -o '"[a-z-]*"'` | `"client-secret"` | §2.5. A missing Secret does not stop the pods; it shows up later as `no_credential` |

G7 and G8 list key **names** only. Neither prints a value, and neither should be changed to.

**(c) The bundle still floats at work. Pin it.** This is unchanged from 0.1.68 §0(c), with a new digest
of record in §1.

---

## 1. What changed since 0.1.68, by chart commit

The changes from 0.1.63 to 0.1.68 are in the 0.1.68 package §1 and are not repeated here.

| commit | version string | change |
|---|---|---|
| `c977f91` | 0.1.69 | Under releasability, the hub's egress pane is reached only through the PEP, filtered by the viewer's nations. Under `lockDownElectric`, the NetworkPolicy `egress-pane-pep-only` admits only the PEP |
| `5c9e011` | 0.1.70 | TAK server and Cursor-on-Target adapter on the hub, behind `egress.tak.enabled` (default off). A readers-only NetworkPolicy under `lockDownElectric` |
| `91c1758` | 0.1.71 | Atlas applies migrations with `--tx-mode none` (§2.3) |
| `4128341` | (0.1.71) | `cmReports.enabled`: a cm-intake per tier and at the hub, admitted only from that tier's PEP |
| `7f3a588` | (0.1.71) | Every Topaz loads the destination registry, plus a deployment overlay when `releasability.destinations.entries` is non-empty. The overlay is folded into the policy checksum |
| `cd3eb47` | (0.1.71) | An edge's connect can turn DIS Event Reports into CM events (`cmReports.eventReport`) |
| `cca2d38` | (0.1.71) | Egress routes, kinds, assembler, forwarder and stub sink, all opt-in. Under releasability the hub topic-init gains the compacted `parts-availability` topic |
| `0833538` | (0.1.71) | The egress gate rolls with the destination registry (`checksum/registries`, guard 6) |
| `d802c6e` | (0.1.71) | Egress intake, stub artifacts, and released-records panes on the hub (guard 7) |
| `6f17554` | (0.1.71) | Under releasability, the hub view gets the egress admission pane |
| `9bc7145` | (0.1.71) | The schema/topic-init hook phase is chosen per backend at render time (§2.2, guard 8) |
| `81e8570` | (0.1.71) | Mutual-TLS listener for TAK devices, admitted per certificate CN (§2.4, guards 9 and 10) |
| `458d39b` | (0.1.71) | A destination's client secret mounts from an existing Secret and is never rendered (§2.5, guard 11) |

`scripts/check-chart-render.sh` passes all 11 guards on `458d39b`. Each guard added in this range was
made to fail on purpose by breaking the template it covers.

**Bundle of record (lab, 2026-10-03, revisions 76–77):** runtime-bundle
`sha256:ff2d5fd42b1367c8477409bc12f6247b7e034422fbcf3e92130d43019cb65f89`.
It supersedes `sha256:0f94d16c…` from the 0.1.68 package. It carries:
- the Atlas migrations up to `20261003000000`, including `intake_records`;
- the destination registry;
- the CM intake configuration.

**Images of record on the lab at revision 77,** for the components this range added or changed. Each
row is `<registry>/<image>@sha256:…`:

| image | digest |
|---|---|
| `openddil/egress` | `sha256:c43dd555ecb3eb325172a35b38d5d9d6d69e3343a0d21246f09c0d9b6cb18f99` |
| `openddil/frontend` | `sha256:4436c59b411bd2180882dc76c1f4f8c67b80cdc3ecb8a26a5d4ceb0db860c865` |
| `openddil/cm-service` | `sha256:37fde7591ea9c45510978dd3ffd625f5a4976384adde3ea679d7d84da57129d7` |
| `openddil/sensor-ingest` | `sha256:fbaf35aebf5f09166ab353b1fb17bb6f15375e64ac008a9235064b8982e606ab` |
| `openddil/logistics-sim` | `sha256:820dbc5de63f5209f9d563fca4a19f4a2a5f65dd262caab07194d38deb311995` |
| `openddil/tak-server` | `sha256:4fa7e872726c55be3b46420ba1c151a957eb0cf7e5f79123f9358e1993e66305` |
| `ghostunnel/ghostunnel` (Docker Hub, `v1.11.3`; pinned in the chart) | `sha256:2599b8a04bae16d70a4209495618dea61b46a00a9a05fcf74da282688ad3517f` |
| `topaz` | `sha256:835868c04bdd7129127ea43642ffff7363d0bd26d5e1a37631fa881431054360` |

---

## 2. What is different at work — new rows

### 2.1 Egress now lives in the chart, at the hub

0.1.68 §2.8 said "the egress gate is compose-only". **That line is replaced.** Under
`releasability.enabled` and the `egress.*` values, the hub runs the following egress Deployments:
- the gate;
- the assembler;
- the forwarder;
- the intake;
- the pane API;
- the stub sink;
- with TAK on, the CoT adapter and the TAK server.

At work-shaped values, where releasability is on, **two of these already render, and did at 0.1.63
too:** the gate (`egress-gate-c2`) and the pane API, with the pane's PEP-only NetworkPolicy from
0.1.69. At these values the 0.1.68 line does not hold for those two. Everything else
in that list is off by default. A work cluster that sets none of the new `egress.*` values gets the
gate and the pane API and nothing more. §0(a) is that render.

If you turn them on, the destinations come from the registry, plus your deployment overlay
(`releasability.destinations.entries`). Keep the overlay out of this repository. A destination with
no real endpoint yet points at the stub sink, which stands in for it. What the stub received lives in
an emptyDir: it survives a container restart but not a reschedule.

### 2.2 Init hooks: the phase is decided by a live lookup

From `9bc7145`, each schema-init and topic-init Job takes its hook phase from a `lookup` of its
backend's Service at render time:

| case | phase |
|---|---|
| the backend exists (every backend, on a normal upgrade at work) | `pre-upgrade` |
| the backend is new in this release | `post-upgrade` (a pre-upgrade hook against a broker or database that does not exist yet would fail the release) |
| install | `post-install` |

Consequences:
- **`helm template` and `--dry-run=client` cannot see the cluster.** Every Job then renders as if its
  backend were new. Their hook annotations are not what the upgrade will do. G6 uses
  `--dry-run=server`, which performs the lookup.
- **The account running helm needs `get` on Services in `$NS`.**
  - Helm's `lookup` returns an empty result only for NotFound. Any other error, Forbidden included,
    fails the render. So a missing permission stops the upgrade before anything is applied; it does not
    silently fall back.
  - This comes from reading Helm's lookup, not from a restricted account. G6 is where you find out.
- **`--dry-run=server` needs Helm 3.13 or later.** An older client has only the client-side dry run,
  which cannot do the lookup.
- **If you suspect a Job ran `post-upgrade` against an existing backend:** that is the pre-0.1.71
  ordering, where a consumer whose table or topic is new can start before the table or topic exists.
  An egress pod then prints `STARTUP_REFUSED missing_topic <name>` or `missing_table <name>` and exits
  3. It restarts until the post-upgrade hook creates the topic or table. The restart count is the
  evidence.
- **Migrations and topic changes must stay expand-only across one release.** Pre-upgrade schema-init
  runs while the old pods are still serving.

Measured on the lab at revisions 76 and 77: every init hook ran pre-upgrade, in the same order both
times, and the egress pods logged 0 `STARTUP_WAITING` and 0 `STARTUP_REFUSED`.

### 2.3 Atlas: `--tx-mode none`

Six migrations carry their own `BEGIN`/`COMMIT`. Under Atlas's default per-file transaction, a fresh
store failed once per such file and only succeeded on the seventh run. With `--tx-mode none` it
succeeds on the first run, with the same schema. This matches the schema-init exit 1 reported from
the work cluster. Reproduced on a fresh postgres:15 under atlas 0.32.0 and latest.

Nothing to do except know that the schema-init Job is now expected to succeed **first time**. A retry
is a finding.

### 2.4 Pre-deploy: the TAK package (only if `egress.tak.enabled`)

Three things must be done before the upgrade.

1. **Mirror two images.** `openddil/tak-server` (GHCR) and, for TLS, `ghostunnel/ghostunnel:v1.11.3`
   from Docker Hub, at the pinned digest in §1. ghostunnel is a new mirror row. Docker Hub is a
   registry the work mirror may not have pulled from before.
2. **Make the certificates outside any repository.** `scripts/tak-client-certs.sh` builds:
   - the CA;
   - the server certificate;
   - one client certificate per device CN;
   - an ATAK/WinTAK data package for each device.

   It refuses to write inside a git work tree. It prints, but does not run, the
   `kubectl create secret generic <egress.tak.tls.secretName> …` command. Run that command yourself.
   The Secret's keys are `server.pem`, `server.key` and `ca.pem` (G7). Keep the CA key off the cluster.
3. **Values.** Set the following:
   - `egress.tak.enabled: true`;
   - `egress.tak.tls.enabled: true`;
   - `egress.tak.tls.secretName`;
   - `egress.tak.tls.allowedClientCNs: [<device-cn>, …]`.

   The Service is `LoadBalancer` on port **8089** by default. Ask for an address before the cut. A
   TLS listener with no Secret name, or with an empty CN list, **fails the render on purpose**.

Behaviour to know before you hand a device over:
- **Admitting a device admits it to the whole audience** of the one destination this TAK server serves
  (`egress.destination`). There is no per-track filter. Treat every listed CN as trusted with
  everything this TAK server emits (`docs/tak-client-setup.md` §7).
- **Revoking a device means removing its CN and running `helm upgrade`.** The CN list rolls the pod.
  Deleting the device's certificate file revokes nothing.
- **The data package imports with the stream disabled.** On the device, enable the stream after
  import. Client steps are in `docs/tak-client-setup.md`.
- The plaintext TAK port (8087) stays inside the cluster, behind the readers-only NetworkPolicy.

Measured on the lab, revision 77 (2026-10-03):
- the demo device's certificate received the picture (9 tracks);
- another device's certificate was refused (`bad certificate`);
- a connection without a certificate was refused (`certificate required`);
- plaintext from outside was refused.

The picture includes destroyed assets. On the lab, the one destroyed asset is still a track. A brief
that says "8 tracks" will count 9.

### 2.5 Pre-deploy: a destination's client secret (only if a route or poll carries `auth`)

The secret **never touches values, a rendered manifest, or a file that outlives the command**.

```bash
# the file lives outside any repository, and only for as long as the command
kubectl -n "$NS" create secret generic <name> --from-file=client-secret=<path-outside-any-repo>
rm <path-outside-any-repo>
```

Then set `egress.credentials.existingSecret: <name>`. The chart mounts the whole Secret read-only at
`/etc/openddil/egress-credentials/` into egress-forwarder and egress-intake only, and renders no Secret
of that name (guard 11). The route or poll names the file:

```yaml
auth:
  token_url: <token endpoint>
  client_id: <client id>
  client_secret_file: /etc/openddil/egress-credentials/client-secret
```

Behaviour:
- **A missing Secret does not stop the pods.** The mount is optional, so the forwarder and intake run,
  and every delivery or poll that needs the credential records `no_credential`. G8 is the only place
  this shows before the upgrade.
- **The mount is `defaultMode: 0440` and is readable only because the egress image runs as root.** If
  your platform forces non-root, as a restricted PodSecurity profile or an OpenShift SCC does, set
  `fsGroup` on those pods or the secret is unreadable. That also shows as `no_credential` forever, not
  as a crash. Check it before the cut on any cluster that rewrites pod security contexts.
- With `existingSecret` empty, the render is byte-identical to before.

### 2.6 Topaz and the gate roll together but are not ordered

A registry change rolls every Topaz and the egress gate (and intake) on the same upgrade (guard 6). The
gate resolves each destination from topaz-hq **once, at startup**. If the gate starts before the new
topaz-hq serves, it holds the old registry. A destination then can resolve to no nations, and every
record bound for it is refused.

There is no ordering fix in this chart. After any upgrade that changes the registry or its overlay,
read the gate's startup line:

```bash
kubectl -n "$NS" logs deploy/<release>-egress-gate-c2 | grep REGISTRY_VERSIONS
```

The line must name the registry version you just shipped. If it names the old one, restart the gate.
Also, Topaz reads its users file only at start, so every users-file change must predict a Topaz roll.

### 2.7 Released-records panes and the hub egress pane

`frontend.releasedRecordsPanes` mounts panes on the hub view from configuration. Each pane has a title,
a destination and a kind. The titles and destinations are deployment-specific; put them in your
overlay, not here. With releasability on, the hub view also renders the egress admission pane, reached
only through the PEP. Its counts are filtered by the viewer's nations: admitted, refused, and
withheld (unlabelled, shown to nobody).

### 2.8 The scenario reset

0.1.68 §2.8 said that the reset was not yet proven end to end. **That line is replaced.**

**It round-tripped on the lab at `458d39b` on 2026-10-03**, with `scripts/reset-scenario.sh` unchanged since
`b7f4ff7` (an earlier round trip on 2026-10-01 at 0.1.68 gave the same shape).

- The red check ran first. `--verify-only` against the live store gave rc=1 with 163 FAIL, so the zero
  assertion can fail.
- The run was `--red-check-topic-config`, rc=1 (the expected rc).
  - The cluster was asserted, and pre-flight passed: 100 consumer groups, 0 undeclared.
  - The derived quiesce set was 26 workloads, the egress gate, assembler, forwarder and CoT adapter
    among them.
  - All 4 Restate instances cleared in 1–2 passes. 66 topics were recreated, 0 "already exists".
- **Phase 8**, read while the producers are quiesced: 627 PASS and 1 FAIL.
  - Every store, topic, Restate and Electric reading was zero, and audit_log was unchanged.
  - The FAIL is the regional aggregator line. The check cannot measure it, because the aggregator emits
    nothing from an empty state.
- **180 s after the restore**, the workload set was unchanged and the whole fleet was operational at every
  store.
  - The regional rollup showed no destroyed asset. That is the evidence that the aggregator had been
    emptied.
  - Registrations, the four-profile login, sign-out, the per-viewer egress panes, the PEP bypass block
    and the TAK reader all matched the state before the reset.
  - The egress pods came back with 0 restarts and 0 `STARTUP_REFUSED`. The gate logged one
    `REGISTRY_VERSIONS` line, with the same versions.
- **After the simulator's scripted destroy fired**, the baseline read was identical to the one taken
  before the reset, apart from volume counters.
- **Egress after the restore.** Within 21 s, a telemetry-derived fault event was rebuilt and admitted by
  both routes. The stub received it once.
  - Its event id is the same as before the reset, because ids are derived, not random. A destination
    sees it as a re-send.
- The five pre-flight checks passed afterwards.

What the reset does **not** cover, as measured on that run:

| state | reset today | effect |
|---|---|---|
| `intake_records` (hub store) | not in the reset's table list | survived the reset with its rows; phase 8 does not look at it |
| the stub sink's received log (emptyDir) | outside the reset | survives a reset until that pod restarts |
| the TAK server's in-memory picture | outside the reset; the CoT adapter is quiesced and restarts | the server keeps running; its replay history after a reset is shorter |
| reported faults (Restate) | cleared | a filed report is gone after a reset and must be filed again; telemetry-derived faults come back on their own |

Whether `intake_records` belongs in the reset is open. Until it is decided, a reset at work leaves returned
artifacts in place.

### 2.9 Still true from the 0.1.68 package §2

- 2.1 pull credentials;
- 2.2 cluster config;
- 2.3 node routing;
- 2.4 rollback and Restate;
- 2.5 DIS removal;
- 2.6 branding;
- 2.7 lifecycle in the regional rollup;
- 2.8, apart from its egress line (replaced by §2.1 here) and its reset line (replaced by §2.8 here).

---

## 3. Pre-deploy checklist

- [ ] `kubectl config current-context` is the work cluster, and `.expected-context` was set deliberately
- [ ] `helm get values "$REL" -n "$NS" > values-before.yaml` — **keep it**
- [ ] `helm history "$REL" -n "$NS" | tail -3` — the 0.1.63 revision is there to roll back to
- [ ] The chart is checked out at `458d39b`, and `git -C openddil-helm rev-parse --short HEAD` says so
      (the version string cannot tell you)
- [ ] G1 routing: every node ok
- [ ] G2 pull credentials: PASS with the exact `-f` files the upgrade will pass
- [ ] G3 cluster config: result recorded
- [ ] G4 wipe render: **0**
- [ ] G5 bundle digest pinned to §1
- [ ] G6 server dry run: every existing backend's init Job is `pre-upgrade`; the account has `get` on Services
- [ ] **TAK, if on:** both images mirrored; certificates made outside any repo; the Secret created from
      the script's printed command; G7 key names; `allowedClientCNs` lists exactly the devices you
      intend; an address for the 8089 LoadBalancer
- [ ] **Client secret, if any route or poll carries `auth`:** the Secret created from a file that was then
      deleted; G8 key name; the non-root check from §2.5 if the platform rewrites security contexts
- [ ] Predictions written: what rolls (§0(a)), hook phases (G6), store counts after, and the four-profile
      login. With egress on, also the `REGISTRY_VERSIONS` line each gate and intake will print

## 4. Rollback

```bash
helm rollback "$REL" <0.1.63 revision> -n "$NS"
```

| returns | does not return |
|---|---|
| chart 0.1.63 and its pod specs | `-f` values — re-pass them |
| init hooks at their 0.1.63 phases | schema migrations applied forward (`intake_records` stays) |
| no egress, TAK or cm-intake workloads (if you had turned them on) | the TAK and client-credential Secrets — created out of band, they stay until you delete them |

0.1.68 §2.4 still governs Restate. With the wipe flag unset, a rollback wipes nothing and re-registers
the Restate deployments.

## 5. Post-deploy, in order

1. `kubectl rollout status` on every rolled workload from §0(a). "Running" is not verification.
2. G3 again: PASS on every broker. Then G1 again.
3. `helm history` shows the release `deployed`. Read the init Jobs' order from the release events.
   Each schema-init should have succeeded first time (§2.3).
4. Store counts per tier against the prediction, and the 0.1.68 §2.5 removal counters.
5. Four-profile login: one per tier UI and the HQ operator.
6. **With egress on:**
   - each gate and intake prints exactly one `REGISTRY_VERSIONS` line, naming the shipped versions;
   - 0 `STARTUP_WAITING` and 0 `STARTUP_REFUSED` across the egress pods;
   - `scripts/check_egress_pane.py <hub> --user <viewer> --require-viewer-filter` passes for each
     viewer you predicted counts for.
7. **With TAK on:** `scripts/tak_probe.py` from a pod labelled `openddil.io/tak-reader` sees the
   predicted uids. From outside, a client with a listed certificate connects on 8089, and a client
   without one is refused. Both results are required; a pass on the first alone proves nothing.
8. Write the measured results next to the predictions.
