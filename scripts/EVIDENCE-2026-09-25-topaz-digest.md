# Evidence — is the pinned Topaz digest actually tag 0.33.16?

Raised by `DEPLOY-PACKAGE-revision-51.md` section 1.3 as "the one thing not
verifiable from here". Revision 51 makes five tier Topaz pods read
`tierNode.topaz.image.digest` for the first time — the field held a real
sha256 that had never been used — so if the digest named a different build,
five tier authorizers would change behaviour at once.

Measured 2026-09-25 against ghcr.io. Registry pulls only; no cluster
involved.

## Result: they are the same image. The section 1.3 risk is retired.

```
pin = sha256:835868c04bdd7129127ea43642ffff7363d0bd26d5e1a37631fa881431054360

docker pull ghcr.io/aserto-dev/topaz:0.33.16
  Digest: sha256:835868c0...4360          <- the tag resolves TO the pin
docker pull ghcr.io/aserto-dev/topaz@sha256:835868c0...4360
  Digest: sha256:835868c0...4360

image ID, by tag:     sha256:835868c04bdd7129127ea43642ffff7363d0bd26d5e1a37631fa881431054360
image ID, by digest:  sha256:835868c04bdd7129127ea43642ffff7363d0bd26d5e1a37631fa881431054360
                      identical

RepoDigests: ["ghcr.io/aserto-dev/topaz@sha256:835868c0...4360"]   (exactly one)
RepoTags:    ["ghcr.io/aserto-dev/topaz:0.33.16", "…@sha256:835868c0...4360"]
built:       2026-08-05T10:01:50Z
```

## The part worth having checked, which was not the identity

The pin is an **OCI image index**, not a single-platform manifest:

```
MediaType: application/vnd.oci.image.index.v1+json
  linux/amd64        sha256:5024be8a…
  linux/arm64        sha256:a34a6972…
  unknown/unknown    sha256:99964069…  (attestation manifest for the amd64 child)
```

This is the answer to a question the identity check does not reach. **Pinning
this digest does not freeze the architecture.** The kubelet still resolves the
index and selects a child manifest per node, exactly as it does for the tag,
so a mixed-architecture cluster keeps working after revision 51.

Had the pin been one of the child digests instead — `5024be8a…`, the amd64
manifest — the identity check above would have passed just as cleanly while
the deploy quietly became amd64-only. An arm64 node would then fail to run a
tier's authorizer, and it would present as one tier's Topaz not starting
rather than as an architecture pin. That is the failure this check was worth
running for, and it is not the one it was written to look for.

## What this does and does not settle

* **Settles:** the five tier Topaz pods in revision 51 run the same image they
  run today, on any architecture the tag would have served. The tag-to-digest
  substitution is behaviour-neutral.
* **Does not settle:** that the tag will keep resolving here. A tag can be
  moved and a digest cannot — which is the whole point of the pin, and means
  this check answers "is the pin correct now", which is the question that
  matters before deploying it.
* **Unchanged control:** `topaz-hq` has run this digest since it was pinned.
  It stays the control. A tier whose authorization decisions disagree with
  HQ's after the deploy is still a finding, because this check rules out the
  image as the cause and not the wiring.
