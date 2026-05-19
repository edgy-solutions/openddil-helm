# =============================================================================
# openddil-runtime-bundle — config bundle image
# =============================================================================
# Bakes the docker-compose bind-mounted content from 4 sibling OSS repos
# into one image. Helm init containers cp /bundle/<subtree> into a shared
# emptyDir, then the consumer container reads from that emptyDir.
#
# This obviates the need to clone the sibling repos onto the k8s node —
# only THIS image needs to be in the registry. The same image is pulled
# by every consumer's init container; the registry's content-addressed
# pull dedups across pods.
#
# BUILD CONTEXT must be the PARENT directory containing all four OSS
# repos (openddil-contracts, openddil-stack, openddil-tactical-agents,
# openddil-demo). See ../README.md for the build command.
# =============================================================================

FROM alpine:3.20

WORKDIR /bundle

# ----- openddil-contracts -------------------------------------------------
# Heavy use across the stack: proto, ontology, generated python bindings,
# bootstrap helpers, baselines. Subtrees the bind mounts reference are
# listed in openddil-demo/docker-compose.yml — keep this in sync.
COPY openddil-contracts/proto       /bundle/contracts/proto/
COPY openddil-contracts/ontology    /bundle/contracts/ontology/
COPY openddil-contracts/gen/python  /bundle/contracts/gen/python/
COPY openddil-contracts/bootstrap   /bundle/contracts/bootstrap/
COPY openddil-contracts/baselines   /bundle/contracts/baselines/

# ----- openddil-stack -----------------------------------------------------
COPY openddil-stack/schema    /bundle/stack/schema/
COPY openddil-stack/electric  /bundle/stack/electric/

# ----- openddil-tactical-agents -------------------------------------------
# ONLY restate_hub.py is mounted at runtime in the docker-compose base
# (line 742). This is a smell — the production hub-restate-projector
# image bakes a DIFFERENT script (hub_restate_projector.py). Helm
# preserves the compose runtime behavior by mounting this file from the
# bundle over /app/restate_hub.py. Address with a Dockerfile fix in
# openddil-tactical-agents later.
COPY openddil-tactical-agents/hub/restate_hub.py /bundle/agents/hub/restate_hub.py

# ----- openddil-demo configs ----------------------------------------------
# Inline-mounted yaml/json configs for redpanda-connect (DIS mappers),
# toxiproxy bootstrap, restate config, and dynamic Bloblang mappings.
COPY openddil-demo/openddil-base-connect.yaml    /bundle/demo/openddil-base-connect.yaml
COPY openddil-demo/redpanda-connect-edge-01.yaml /bundle/demo/redpanda-connect-edge-01.yaml
COPY openddil-demo/redpanda-connect-edge-02.yaml /bundle/demo/redpanda-connect-edge-02.yaml
COPY openddil-demo/redpanda-connect-edge-03.yaml /bundle/demo/redpanda-connect-edge-03.yaml
COPY openddil-demo/redpanda-connect.yaml         /bundle/demo/redpanda-connect.yaml
COPY openddil-demo/restate-config.toml           /bundle/demo/restate-config.toml
COPY openddil-demo/toxiproxy.json                /bundle/demo/toxiproxy.json
COPY openddil-demo/dynamic-mappings              /bundle/demo/dynamic-mappings/

# Permissions — readable by any non-root UID.
RUN find /bundle -type d -exec chmod 755 {} \; \
 && find /bundle -type f -exec chmod 644 {} \;

# No CMD. This image only serves as a source for init container cp.
# Run with `sleep infinity` in debug mode to inspect:
#   kubectl run bundle-debug --image=ghcr.io/edgy-solutions/openddil/runtime-bundle:latest \
#     --command -- sleep infinity
