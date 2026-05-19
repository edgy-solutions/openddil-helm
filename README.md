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

## One-time: build and publish the runtime bundle image

The bundle image bakes content from four sibling OSS repos that
docker-compose bind-mounts. It needs to be built once per content change
and published to a registry the cluster can pull from.

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

```bash
./openddil-helm/scripts/publish-chart.sh
```

Pushes `oci://ghcr.io/edgy-solutions/openddil/charts/openddil-demo` at
the version in `Chart.yaml`. Requires `gh auth login` or `docker login
ghcr.io` for write access to the org.

## Known smells / follow-ups

- The published `hub-restate-projector` image bakes `hub_restate_projector.py`,
  but docker-compose runs `restate_hub.py` via bind mount. Helm preserves
  the docker-compose runtime behavior by mounting `restate_hub.py` from
  the bundle. Long-term fix: decide which script is canonical and bake
  the right one into the image in openddil-tactical-agents.
- Customer overlay (sim-a feed) not yet ported — first-cut OSS only.
  Pattern is identical (a second connect deployment + amqp producer);
  follow-up to layer in.
