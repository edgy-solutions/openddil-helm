# openddil-helm

Helm chart + runtime bundle image for deploying the OpenDDIL Tactical
Telemetry Edge demo to a Kubernetes cluster. Ports the docker-compose
stack at `../openddil-demo/` to k8s.

## Layout

```
openddil-helm/
├── README.md                          (this file)
├── bundle/                            Runtime bundle image (alpine + COPYs)
│   ├── Dockerfile
│   └── .dockerignore
├── openddil-demo/                     The Helm chart itself
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── _helpers.tpl
│       ├── NOTES.txt
│       └── <one yaml per concern>
└── scripts/
    ├── build-bundle.sh                Build + push the runtime bundle image
    └── publish-chart.sh               Package + push the chart as OCI artifact
```

## Prerequisites

- k8s 1.27+ with a default StorageClass that supports `ReadWriteOnce`
- An ingress controller (NGINX, Traefik, etc.) if `ingress.enabled=true`
- Pull access to `ghcr.io/edgy-solutions/openddil/*` (public, or via
  imagePullSecret if pulling from a mirror)

## Image-build flow (where do the images come from?)

Every per-service image (`frontend`, `cm-service`, `logistics-fusion-
service`, `projector`, `sensor-ingest`, `faust-edge`, `faust-regional`,
`hub-restate-projector`) is built and published to ghcr.io by a GitHub
Actions workflow living in **its own service repo** — typically
`.github/workflows/docker-build.yml`, triggered on push to `master`.
The helm chart pulls those images by tag (`global.imageTag`, default
`latest`). You don't build them locally — push the service repo to
GitHub and GHA does it.

The ONE exception is `runtime-bundle` — see below. It's a multi-repo
image with no GHA workflow yet.

## One-time: build and publish the runtime bundle image

The bundle image bakes content from four sibling OSS repos that
docker-compose bind-mounts. It needs to be built once per content change
and published to a registry the cluster can pull from. There's no GHA
workflow for it yet (it'd need a multi-repo checkout), so for now it's
a local build.

Layout the build context expects (siblings under one parent):
```
~/git/openddil/
├── openddil-contracts/      ← bundled (proto, ontology, gen, bootstrap, baselines)
├── openddil-stack/          ← bundled (schema, electric)
├── openddil-tactical-agents/← bundled (hub/restate_hub.py only)
├── openddil-demo/           ← bundled (configs, dynamic-mappings)
└── openddil-helm/           ← this repo
```

Build + push:
```bash
cd ~/git/openddil
./openddil-helm/scripts/build-bundle.sh v0.1.0
```

This tags `ghcr.io/edgy-solutions/openddil/runtime-bundle:v0.1.0` (plus
`:latest`) and pushes both. Pass a different version on subsequent runs.

## Install the chart

From local checkout:
```bash
helm install openddil ./openddil-helm/openddil-demo \
  --namespace openddil --create-namespace \
  --set ingress.host=openddil.mycluster.local
```

From OCI registry (after `publish-chart.sh` has been run):
```bash
helm install openddil oci://ghcr.io/edgy-solutions/openddil/charts/openddil-demo \
  --version 0.1.0 \
  --namespace openddil --create-namespace
```

## Common adjustments via values.yaml

| Want to | Change |
|---|---|
| Different image registry (mirror) | `global.imageRegistry: registry.mycorp.local` |
| Smaller footprint | Drop entries from `edges:` / `regions:` lists |
| BYO Postgres | `postgresHq.enabled: false` + `externalPostgresql.host: ...` (TODO) |
| Different storage class | `persistence.storageClass: fast-ssd` |
| Disable ingress | `ingress.enabled: false` (use port-forward) |

## Publishing the chart as an OCI artifact

**Automated (GHA-driven, the normal path)**: every push to `master` that
touches `openddil-demo/**` (or the workflow file itself) triggers
`.github/workflows/publish-chart.yml`. It lints, packages, and pushes
the chart at the version in `Chart.yaml` to
`oci://ghcr.io/edgy-solutions/openddil/charts/openddil-demo`. Verifies
by re-pulling. No manual step — just bump `version:` in `Chart.yaml`
and push.

**Manual (local dev iteration)**:
```bash
./openddil-helm/scripts/publish-chart.sh
```
Same destination + behavior, but local-build-and-push. Requires
`gh auth login` or `docker login ghcr.io` for write access.

## Known smells / follow-ups

- **`hub-restate-projector` image divergence**: the published image bakes
  `hub_restate_projector.py`, but docker-compose runs `restate_hub.py`
  via bind mount. Helm preserves the docker-compose runtime behavior by
  mounting `restate_hub.py` from the bundle. Long-term fix: decide which
  script is canonical and bake the right one into the image in
  `openddil-tactical-agents`.

- **External DIS UDP ingress is opt-in**. `sensorIngest.externalAccess.
  enabled=false` by default — services are ClusterIP, no NodePort. If an
  external simulator needs to push UDP into the cluster, flip it on (and
  widen `--service-node-port-range` if your defaults are 30000-32767 only).

- **Customer overlay (sim-a feed) not yet ported** — first-cut OSS only.
  Pattern is identical (a second connect deployment + amqp producer);
  follow-up to layer in.

- **No GHA workflow for the runtime-bundle image yet**. Building it
  requires checking out four sibling repos (openddil-contracts,
  openddil-stack, openddil-tactical-agents, openddil-demo) side-by-side
  in the build context, which is more than a single `actions/checkout`
  step. Doable (multiple `actions/checkout@v4` with `repository:` and
  `path:`), just not yet written. Until then, the bundle image is a
  local build via `scripts/build-bundle.sh`.

- **helm-test postgres pod checks the wrong publication name**.
  `templates/tests/connectivity.yaml`'s `test-postgres-hq` pod asserts
  the Electric publication exists by querying
  `pg_publication WHERE pubname='electric_publication_default'`. The
  actual publication created by `openddil-stack/electric/electrify.sql`
  is named `electric_publication` (no `_default` suffix — confirmed
  against the running stack 2026-05-20). The check therefore
  false-fails: `helm test` reports the postgres pod failed even when
  the publication is correctly in place. ONE-LINE FIX — change the
  pubname literal in connectivity.yaml. Deliberately tracked rather
  than fixed inline to avoid bumping the chart version mid-deploy-
  cycle; fold into the next natural chart change. Affects `helm test`
  only — install and the data path are unaffected.
