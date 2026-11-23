# Suite manifest

A suite manifest names, by digest, every image and the runtime bundle that make
up one release. File name: `release/suite-<suite>.yaml`. Checked offline by
`scripts/release/check_suite_manifest.py`; checked against the registry by
`scripts/release/check_suite_published.py` (suite mode of the release workflow).

```yaml
suite: v2.0.0-rc1            # ^v\d+\.\d+\.\d+(-rc\.?\d+)?$
status: proposed             # proposed | tagged | promoted
promotedFrom: ""             # for a final version: the rc it promotes; its digests must be identical
chart: {name: openddil-demo, version: "0.1.165", commit: ""}   # commit "" while unknown
bundle:
  image: ghcr.io/edgy-solutions/openddil/runtime-bundle
  digest: sha256:…           # the chart's bundle.image.digest
  loaderPins: []             # other bundle digests that per-workload loader pins name; empty when all use digest
  sources: {contracts: <sha>, demo: <sha>, stack: <sha>, tactical-agents: <sha>, helm: <sha>}
images:
  - {name: projector, image: ghcr.io/edgy-solutions/openddil/projector, digest: sha256:…, repo: edgy-solutions/openddil-projector, commit: <40 hex>, tag: v2.0.0-rc1}
thirdParty:                  # optional
  - {name: postgres, image: postgres, tag: "15", digest: sha256:…, pinned: true}
blockers:                    # free text, public-safe; must be empty when status != proposed
  - "…"
```

Rules:

- Exactly these top-level keys; no others. `thirdParty` is the one optional key.
- Every digest matches `^sha256:[0-9a-f]{64}$`; every commit matches `^[0-9a-f]{40}$`
  (`chart.commit` may be `""` while proposed).
- Image names are unique.
- Each image `tag` is the git tag of its release: `<suite>` for a repo with one image,
  `<name>/<suite>` for an image-scoped tag. The registry tag is the version part
  (`<suite>`). The bundle carries the registry tag `<suite>`.
- No digest or tag field contains `latest`.
- `status` other than `proposed` requires empty `blockers` and a set `chart.commit`.
- A final version (no `-rc`) with `promotedFrom` set must have the same image digests and
  bundle digest as `suite-<promotedFrom>.yaml` beside it, when that file exists.
- `thirdParty` (optional) lists third-party images the chart can run. Each entry has exactly
  `name`, `image`, `tag`, `digest`, `pinned`. `pinned: true` means the chart's values name this
  digest; `pinned: false` means the chart pulls by tag and the digest is what the tag named on
  the date the manifest was written. Names are unique and differ from every `images` name; `tag`
  is a non-empty string other than `latest`; `pinned` is a YAML bool.
- `check_suite_published.py` does not check `thirdParty` against the registry.
- `thirdParty` holds no openddil-owned images (`ghcr.io/edgy-solutions/openddil/...`); those
  belong in `images`.
