# AGENTS.md — OpenDDIL Helm

Guidelines and safety constraints for AI agents working in this repository.

## Repository Scope

This repo is the **orchestration hub**: the `openddil-demo` Helm chart, the
operator scripts under `scripts/`, and the CI that builds and publishes the
runtime bundle image and the chart. There is no service code here — every
service lives in its own sibling repo.

## Cluster Safety — read this before anything else

- ❌ **Never run a cluster-touching script without the guard.** Anything that
  reaches a cluster sources `scripts/lib/require-cluster.sh`, which refuses to
  run until the operator has *declared* which cluster they mean. Bare `kubectl`
  resolves against whatever `~/.kube/config` currently points at; that has come
  up wrong before, and a wrong write lands in someone else's namespace.
- ❌ **Never commit `.expected-context`.** It is the operator's local
  declaration and is gitignored on purpose. Baking one lab's context name into
  a chart other people deploy makes the guard wrong for everyone else.
- ❌ **Never run `helm upgrade` or `helm rollback` mid-session.** The running
  release is the demo surface. Ask first, every time.
- ❌ **Never run `sever-tier.sh` without a written prediction.** See below.
- ❌ **Never push.** Commit locally; the user decides every push.

## What You CAN Do

- **Edit the chart** under `openddil-demo/` — `values.yaml`, `templates/*.yaml`,
  `Chart.yaml`.
- **Run `helm template` / `helm lint`**, or `scripts/check-chart-render.sh`, to
  validate a chart change without touching a cluster.
- **Run the read-only pre-flight gates** — `scripts/check-*.sh` — once a cluster
  is declared.
- **Add or edit scripts** under `scripts/`, sourcing the cluster guard in any
  that reach a cluster.

## Cut Discipline (`sever-tier.sh`)

`sever-tier.sh` applies NetworkPolicies and deletes pods. It is a write, and it
is the demo's most visible mechanism. Before any cut:

1. **Predict.** Write `scripts/PREDICTION-<date>-<topic>.md` stating what you
   expect to happen, *before* the cut runs. The point is to score the outcome
   against a prior claim instead of rationalising it afterwards.
2. **Log in.** Open and authenticate every screen you intend to watch. A cut is
   not the moment to discover an expired session.
3. **Cut, then verify heal.** Record the actual result against the prediction.

## Known Coupling

- `scripts/flush-assets.sh` embeds a parallel copy of the topic specs in
  `openddil-demo/templates/infrastructure.yaml`. **Change both**, or a cold-open
  recreates topics with the wrong configuration.
- The runtime bundle image is built from `bundle/Dockerfile` by
  `.github/workflows/build-bundle.yml`, triggered by a `repository_dispatch`
  from `openddil-contracts`. If the projector reports a Postgres "column X does
  not exist", the bundle's migrations are lagging the code — fix the chain, not
  just the column.

## Current State Comes From a Pre-Flight Run

`scripts/HANDOFF-*.md`, `RUNBOOK-*.md`, `COVERAGE-*.md` and `README.md` are
snapshots of when they were written. **Never report cluster state from a
document.** Run the `check-*.sh` gates and report what they return. Likewise, a
clean working tree is not a pushed repo — check `git log @{u}..`.

## Do Not Modify Sibling Repos

Never edit `openddil-contracts`, `openddil-demo`, `openddil-projector`, or any
other sibling from this repo's context. Each has its own agent guidelines.

## Documentation Maintenance

After ANY change to this repo, update:

1. `README.md` — keep the layout, prerequisites, and install commands current.
2. This file (`AGENTS.md`) — update the safety constraints if a new dangerous
   operation becomes possible.
