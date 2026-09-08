{{/*
Common labels — applied to every resource.
*/}}
{{- define "openddil.labels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/part-of: openddil
{{- end }}

{{/*
Selector labels for a single component (used in service selectors and
deployment/statefulset templates).
Usage: include "openddil.selectorLabels" (dict "component" "redpanda-edge-01" "root" .)
*/}}
{{- define "openddil.selectorLabels" -}}
app.kubernetes.io/name: {{ .root.Chart.Name }}
app.kubernetes.io/component: {{ .component }}
{{- end }}

{{/*
Cluster domain suffix (or empty for in-namespace resolution).
*/}}
{{- define "openddil.svcDomain" -}}
{{- .Values.global.clusterDomain | default "" -}}
{{- end }}

{{/*
Compose a full image reference for openddil-owned images.

Resolution order:
  - If `.digest` is non-empty -> "<registry>/<prefix>/<name>@<digest>"
    Digest pinning is fully reproducible across mirror registries:
    `docker push` preserves the content digest, so the same sha256
    pulled from ghcr.io or from a customer's Artifactory mirror
    resolves to identical content. This is the path
    `mirror-to-artifactory.ps1` emits values-pinned.yaml for, so a
    helm install/upgrade ships a known-good content hash to every
    node and the ":latest pulled at slightly different times got
    different content on different nodes" drift class disappears.

  - Else "<registry>/<prefix>/<name>:<tag>" with `tag` falling back
    to `global.imageTag` when the per-image tag is empty.

Usage:
  include "openddil.image" (dict
      "name" "frontend"
      "tag" .Values.frontend.image.tag
      "digest" .Values.frontend.image.digest
      "root" .)
*/}}
{{- define "openddil.image" -}}
{{- if .digest -}}
{{ .root.Values.global.imageRegistry }}/{{ .root.Values.global.imagePrefix }}/{{ .name }}@{{ .digest }}
{{- else -}}
{{- $tag := .tag | default .root.Values.global.imageTag -}}
{{ .root.Values.global.imageRegistry }}/{{ .root.Values.global.imagePrefix }}/{{ .name }}:{{ $tag }}
{{- end -}}
{{- end }}

{{/*
Resolve a pullPolicy with global fallback.
Usage: include "openddil.pullPolicy" (dict "policy" .Values.frontend.image.pullPolicy "root" .)
*/}}
{{- define "openddil.pullPolicy" -}}
{{- .policy | default .root.Values.global.imagePullPolicy -}}
{{- end }}

{{/*
Compose a full image reference for THIRD-PARTY images (where the chart
references a fixed repository, not an openddil-owned composition).

  - If .digest is non-empty, returns "<repository>@<digest>" (digest-pinned;
    fully reproducible across registry mirrors because content-addressable
    digests are preserved by `docker push`).
  - Else returns "<repository>:<tag>" (semver/tag-pinned).

Usage:
  image: "{{ include "openddil.thirdPartyImage" .Values.redpandaEdge.image }}"

Pass the .image block directly (NOT wrapped in a dict) — the helper reads
.repository, .tag, and .digest off the passed value.
*/}}
{{- define "openddil.thirdPartyImage" -}}
{{- if .digest -}}
{{ .repository }}@{{ .digest }}
{{- else -}}
{{ .repository }}:{{ .tag }}
{{- end -}}
{{- end }}

{{/*
Bundle-image initContainer. Copies subtrees out of the runtime-bundle
image into a shared emptyDir, with explicit src→dst path mapping so
hardcoded paths in connect yaml (/proto, /ontology) can be honored via
subPath mounts in the main container.

Usage:
  initContainers:
    {{- include "openddil.bundleInit" (dict "paths" (list
        (dict "src" "contracts/gen/python" "dst" "proto")
        (dict "src" "contracts/ontology"   "dst" "ontology")
      ) "root" .) | nindent 8 }}
  volumes:
    - name: bundle-shared
      emptyDir: {}
  volumeMounts:               # in the main container
    - name: bundle-shared
      mountPath: /proto
      subPath: proto
    - name: bundle-shared
      mountPath: /ontology
      subPath: ontology

Each entry: src is the path under /bundle/ in the bundle image; dst is
the top-level name under /shared/ in the emptyDir. Main container then
subPath-mounts /shared/<dst> at the target absolute path.
*/}}
{{- define "openddil.bundleInit" -}}
- name: bundle-loader
  image: {{ include "openddil.image" (dict "name" .root.Values.bundle.image.name "tag" .root.Values.bundle.image.tag "digest" .root.Values.bundle.image.digest "root" .root) }}
  imagePullPolicy: {{ include "openddil.pullPolicy" (dict "policy" .root.Values.bundle.image.pullPolicy "root" .root) }}
  command:
    - sh
    - -c
    - |
      set -e
      {{- range .paths }}
      # {{ .src }} -> /shared/{{ .dst }}{{ if .overlay }} (OVERLAY){{ end }}
      mkdir -p "$(dirname /shared/{{ .dst }})"
      {{- if .overlay }}
      # OVERLAY: merge CONTENTS into an existing destination directory.
      # `cp -r src dst` on an existing dst copies the directory INTO it
      # (/shared/ontology/ontology/), which is silent and produces a tree
      # nothing reads. The trailing `/.` is what makes this a merge.
      #
      # Overlay entries must be listed AFTER the base they overlay; the
      # later copy wins on a filename collision, which is the intended
      # precedence (a deployment may override a shipped default).
      mkdir -p "/shared/{{ .dst }}"
      cp -r "/bundle/{{ .src }}/." "/shared/{{ .dst }}/"
      {{- else }}
      if [ -f "/bundle/{{ .src }}" ]; then
        cp "/bundle/{{ .src }}" "/shared/{{ .dst }}"
      else
        cp -r "/bundle/{{ .src }}" "/shared/{{ .dst }}"
      fi
      {{- end }}
      {{- end }}
  resources:
    {{- toYaml .root.Values.bundle.initResources | nindent 4 }}
  volumeMounts:
    - name: bundle-shared
      mountPath: /shared
{{- end }}

{{/*
Toxiproxy proxy bootstrap. Runs once at install-time to register the
hq-link proxy with the toxiproxy daemon (so the DDIL sever button on
the frontend has a real proxy to enable/disable). Idempotent — POST to
/proxies returns 409 if it already exists.
*/}}
{{- define "openddil.toxiproxyTarget" -}}
{{ .Release.Name }}-redpanda-hq{{ include "openddil.svcDomain" . }}:{{ .Values.redpandaHq.kafkaPort }}
{{- end }}

{{/*
ADR-0029 Slice 1 — the app's public origin, and the two URLs derived from it.

DERIVED IN ONE PLACE, ON PURPOSE. The OIDC redirect URI must match EXACTLY
between three artifacts: the Keycloak client registration, the URL the
gateway sends to the authorization endpoint, and the URL the browser is
returned to. A mismatch in any one of them fails at the callback with an
error that names none of the three, and the usual repair is to widen the
client to a wildcard — which is the misconfiguration this whole design
declines. One template, three consumers, no opportunity to disagree.
*/}}
{{- define "openddil.publicOrigin" -}}
{{- if .Values.releasability.publicOrigin -}}
{{ .Values.releasability.publicOrigin | trimSuffix "/" }}
{{- else if .Values.ingress.enabled -}}
{{ printf "%s://%s" (ternary "https" "http" (not (empty .Values.ingress.tls))) .Values.ingress.host }}
{{- else -}}
{{ fail "releasability with OIDC needs a public origin: enable ingress or set releasability.publicOrigin" }}
{{- end -}}
{{- end }}

{{- define "openddil.pepRedirectUri" -}}
{{ printf "%s/auth/callback" (include "openddil.publicOrigin" .) }}
{{- end }}

{{- define "openddil.keycloakPublicUrl" -}}
{{ printf "%s%s" (include "openddil.publicOrigin" .) (.Values.releasability.keycloak.basePath | trimSuffix "/") }}
{{- end }}

{{- define "openddil.keycloakIssuer" -}}
{{ printf "%s/realms/%s" (include "openddil.keycloakPublicUrl" .) .Values.releasability.keycloak.realm }}
{{- end }}

{{/*
Where a TIER's browser read path goes.

THE PEP WHEN ENFORCEMENT IS ON, THE TIER'S OWN ELECTRIC WHEN IT IS NOT — and
never the root's `electric-sync` alias, which is what it silently was before
2026-09-05 (UD-9).

Two callers derive from this one helper (the frontend's nginx upstream and
the NetworkPolicy's allowed source), so the enforcement path and the network
path cannot disagree. Pointing nginx at Electric while enforcement is on
would be a complete bypass that looked like everything working; the policy
makes that combination fail visibly instead.
*/}}
{{- define "openddil.tierReadUpstream" -}}
{{- if .root.Values.releasability.enabled -}}
{{ printf "%s-tier-pep-%s" .root.Release.Name .tier.id }}
{{- else -}}
{{ printf "%s-tier-electric-%s" .root.Release.Name .tier.id }}
{{- end -}}
{{- end }}

{{- define "openddil.tierReadPort" -}}
{{- if .root.Values.releasability.enabled -}}8080{{- else -}}3000{{- end -}}
{{- end }}

{{/*
Is this edge managed by a tier node of its own?

THE DETECTION CUTOVER (UD-10). An edge with a tier node computes its own
severity and CM state locally. The root MUST NOT also compute them from the
same raw stream — and this predicate is the one place that decides, so the
root's subscription list and the bridge's topic list cannot disagree about
which edges those are.

`tierNode.tiers` empty means every edge, matching the tier-node kit's own
rule.

Usage: include "openddil.isTierManaged" (dict "id" $edge.id "root" $root)
       -> "true" or ""
*/}}
{{/*
openddil.tierList — ONE list of tiers, derived from the topology already declared.

WHY THIS EXISTS. `tier-node.yaml` ranged over `.Values.edges`, so a REGION
could not be a tier node at all: regions live in `.Values.regions` and never
entered the loop. That is the framework-vs-instantiation split showing up in
the chart — a two-level hardcode in values, sibling of GD-01's two-level
schema — and it is why "a second tier is configuration" was false for a
region (regional package §1, Finding B).

ADDITIVE ON PURPOSE. Nothing here changes `.Values.edges` or
`.Values.regions`; the nine other range sites keep working untouched. This
composes a THIRD view over the same declarations so the tier machinery can
range over tiers instead of over edges, and a fourth level becomes a values
entry rather than a template change.

SHAPE. Each entry carries what tier-node.yaml consumes, plus `kind`:

    id            the tier's id
    kind          "edge" | "region"  — what it IS, not what it does
    parent        the tier above it; empty means the root is its parent
    hasChildren   does it roll anything up? Derived from kind, overridable.
    label/publicOrigin/region  passed through from the source entry

`kind` and `hasChildren` are kept SEPARATE deliberately. Kind is identity;
hasChildren is shape, and the presentation resolves by shape (ADR-0033). An
edge that one day aggregates something would set hasChildren true and still
be an edge — collapsing them would make the fourth tier unanswerable again.

An explicit `.Values.tiers` wins entirely, so a deployment whose topology is
not "edges under regions" can state it directly rather than being derived
into a shape it does not have.

Usage:
  {{- $tiers := include "openddil.tierList" . | fromYamlArray }}
*/}}
{{- define "openddil.tierList" -}}
{{- if .Values.tiers }}
{{- toYaml .Values.tiers }}
{{- else }}
{{- $out := list -}}
{{- range .Values.edges }}
{{- /* DIRECT INGEST -- does this tier observe assets itself?

       ADR-0032 a, as an actionable rule: A TIER DERIVES STATE ONLY FOR
       ASSETS IT INGESTS DIRECTLY. For assets below it, it consumes their
       DERIVED state and never re-derives.

       Region-east arrived with cm-service-silver and fusion-service-silver
       attached to `raw-sensor-stream` -- at the REGION. The tier node
       renders the full leaf topology, and the relayed raw stream gave those
       consumers something to read. That is the reachback inverted: instead
       of a parent reaching DOWN to a child's broker, the child's raw data
       came UP, and a consumer above the edge derived from it anyway. Same
       violation, topic delivered rather than fetched, and invisible to a
       census that looks for consumers on the wrong broker.

       So detection binds to DIRECT ingest only. Relayed raw topics are
       terminal for detection: they exist on a parent's broker for
       PRESENTATION -- the leaf-under-region view, HQ's fleet picture -- and
       no detection consumer at a parent attaches to them.

       Defaults to true for an edge and false for a region, which is what
       the deployed topology means today, and is overridable because a
       region with its own sensors is a real thing and should be declarable
       rather than assumed away. */ -}}
{{- $out = append $out (dict
      "id" .id
      "kind" "edge"
      "parent" (default .region .parent)
      "hasChildren" (default false .hasChildren)
      "label" (default .id .label)
      "publicOrigin" (default "" .publicOrigin)
      "directIngest" (default true .directIngest)
      "region" (default "" .region)) -}}
{{- end }}
{{- range .Values.regions }}
{{- /* A region's parent is the ROOT NODE, not nothing.

       `parent: ""` renders as null, and the presentation resolves
       `has_children && !parent` as ROOT — so a region would have rendered
       the HQ instance instead of an intermediate one. The root is a real
       tier with a real id; "no parent" belongs to the root alone, which is
       the one node genuinely above everything.

       Caught by reading the rendered shape against `instanceForShape`, not
       by the render failing: it produced a well-formed config for the
       wrong instance. */ -}}
{{- $rootId := default "root" $.Values.tierNode.rootId -}}
{{- $out = append $out (dict
      "id" .id
      "kind" "region"
      "parent" (default $rootId .parent)
      "hasChildren" (default true .hasChildren)
      "label" (default .id .label)
      "publicOrigin" (default "" .publicOrigin)
      "directIngest" (default false .directIngest)
      "region" .id) -}}
{{- end }}
{{- toYaml $out }}
{{- end }}
{{- end }}

{{/*
openddil.bridgeTarget — where a tier's bridge publishes.

A tier publishes its derived state to ITS PARENT, not to HQ. That is what
makes the tree recursive rather than two-level: an edge under a
tier-managed region bridges to the REGION, and the region bridges to HQ.

Falls back to HQ (via toxiproxy, which is the severable link) when the
parent has no tier node — an edge whose region is not tier-managed still
reaches HQ directly, which is today's topology and stays correct.

⚠ THE FALLBACK IS THE COMPATIBILITY PATH, NOT THE MODEL. If every tier in a
subtree is managed, nothing should be addressing HQ but the top of that
subtree. A bridge still pointing at toxiproxy under a managed region means
the retarget did not reach it.

Usage: include "openddil.bridgeTarget" (dict "tier" $tier "root" $root)
*/}}
{{- define "openddil.bridgeTarget" -}}
{{- $root := .root -}}
{{- /* Accepts an entry from EITHER source. A tier-list entry carries an
       explicit `parent`; a raw `.Values.edges` entry carries `region`,
       which for an edge IS its parent. edge.yaml still ranges over
       `.Values.edges` for its udpPort and friends, so both spellings
       arrive here.

       SELF-PARENT IS REFUSED, not resolved. `region: <own id>` is how a
       region is shaped, and treating that as a parent would have a tier
       bridge to itself — the same violation the tier config hit an hour
       ago, wearing a different value. No parent belongs to the root
       alone, so anything that resolves to itself is treated as having
       none and falls back to HQ. */ -}}
{{- $parent := .tier.parent | default .tier.region | default "" -}}
{{- if eq $parent (.tier.id | toString) }}{{- $parent = "" -}}{{- end -}}
{{- $parentManaged := "" -}}
{{- if $parent }}
{{- $parentManaged = include "openddil.isTierManaged" (dict "id" $parent "root" $root) -}}
{{- end }}
{{- if $parentManaged -}}
{{- printf "%s-redpanda-%s%s:%d" $root.Release.Name $parent (include "openddil.svcDomain" $root) (int $root.Values.redpandaEdge.internalPort) -}}
{{- else -}}
{{- printf "%s-toxiproxy%s:%d" $root.Release.Name (include "openddil.svcDomain" $root) (int $root.Values.toxiproxy.apiPort) -}}
{{- end -}}
{{- end }}

{{/*
openddil.tierClientId — the OIDC client id for a tier.

ONE DEFINITION, READ BY BOTH SIDES OF THE BOUNDARY. The chart configures
the tier PEP with a client id, and the Keycloak realm has to CONTAIN a
client by that name. Before this helper the chart derived the id inline
and the realm defined exactly one hand-written client, so the two could
not disagree at render time -- only one of them was rendered -- and the
disagreement surfaced three components away, as a login failure against a
client Keycloak had never heard of.

Adding the missing client by hand would have fixed edge-01 and left the
COUPLING broken for edge-02. Deriving both from here is what closes it.

Usage: include "openddil.tierClientId" (dict "id" $tier.id "root" $root)
*/}}
{{- define "openddil.tierClientId" -}}
{{- printf "%s-%s" .root.Values.releasability.oidc.clientId .id -}}
{{- end }}

{{/*
openddil.tierCookieSecure — "true" when a tier is served over HTTPS.

Derived from the TIER's own publicOrigin, not copied from the root's
ingress. A cookie's Secure flag has to follow the scheme the browser
actually used; a tier inheriting the root's answer is right only while the
two happen to match, and wrong silently when they do not -- Secure on
plain HTTP means the browser drops the session cookie and the user lands
back at the login screen with no error to read.
*/}}
{{- define "openddil.tierCookieSecure" -}}
{{- ternary "true" "false" (hasPrefix "https://" .origin) -}}
{{- end }}

{{- define "openddil.isTierManaged" -}}
{{- if .root.Values.tierNode.enabled -}}
{{- if empty .root.Values.tierNode.tiers -}}true
{{- else if has .id .root.Values.tierNode.tiers -}}true
{{- end -}}
{{- end -}}
{{- end }}


{{/*
openddil.edgeBridgeConnectYaml — the edge->parent bridge config, as content.

EXTRACTED SO THE CHECKSUM CAN HASH THE THING ITSELF.

The bridge Deployment carries a checksum annotation whose stated purpose is
"a config change that does not reach the process is not a change" -- Connect
reads its file once at startup and never re-reads it, so a ConfigMap edit
with no pod roll leaves NEW CONFIG ON DISK AND OLD CONFIG IN THE PROCESS.

That annotation was computed over a hand-listed tuple of INPUTS (edge id,
edge broker, tier-managed flag). The retarget changes the OUTPUT address and
nothing else, so the hash was byte-identical before and after, the pod
template did not change, Kubernetes correctly rolled nothing, and the bridges
kept publishing to the old target for two days while every rendered artifact
said otherwise. Measured: region-east high-watermark 0 on all four topics
after a "successful" upgrade.

Hand-listing the inputs to a hash of a generated document is the bug. The
document is the input. This template exists so both the ConfigMap and the
checksum consume the same rendered text, which makes the next field anyone
adds covered automatically rather than covered if they remember.

Usage: include "openddil.edgeBridgeConnectYaml" (dict "edge" $edge "root" $root "edgeBroker" $edgeBroker)
*/}}
{{- define "openddil.edgeBridgeConnectYaml" -}}
{{- $edge := .edge -}}
{{- $root := .root -}}
{{- $edgeBroker := .edgeBroker -}}
# {{ $edge.id }} → HQ bridge (ADR-0023 Phase 6a). GENERATED by the chart.
# Consumer group is distinct per edge so `rpk group describe` reads
# per-edge bridge lag without ambiguity.
input:
  kafka:
    addresses:
      - {{ $edgeBroker }}
    topics:
      {{- if not (include "openddil.isTierManaged" (dict "id" $edge.id "root" $root)) }}
      # RAW CROSSES A LINK ONLY TO WHERE DERIVATION HAPPENS, OR TO A DECLARED
      # CONSUMER. This edge has no tier node, so the ROOT derives its state
      # directly and needs the raw stream. That is the derivation happening at
      # the other end, and it is why raw belongs on this link.
      #
      # A TIER-MANAGED EDGE SENDS NONE. It derives its own state and publishes
      # the result; its parent consumes that and, under the detection gate, is
      # forbidden from re-deriving from relayed raw. So after the gate landed
      # the only groups touching `raw-sensor-stream` on region-east were the
      # two EMPTY retired ones, and zero groups on the HQ broker read it at
      # all (all 16 enumerated and described). 3.78M messages on edge-01 alone
      # were crossing a DDIL link to feed nobody.
      #
      # This is the rule, not an optimisation: carrying a topic no consumer
      # reads is the same defect as rendering a consumer no topic feeds,
      # pointed the other way. If a declared consumer appears at a parent —
      # archival, replay, an ADR-0034 training unit — it is DECLARED, and this
      # condition changes to name it rather than being quietly relaxed.
      - raw-sensor-stream
      {{- end }}
      - tactical-events
      {{- if include "openddil.isTierManaged" (dict "id" $edge.id "root" $root) }}
      # THE TIER'S DERIVED STATE, carried up because the root no longer
      # computes it for this edge (see hub.yaml, the detection cutover).
      #
      # The root's cm-service and fusion have retired their downward
      # subscriptions here; this is what replaces them. Same topic names
      # on the HQ broker as when the root produced them, so the HQ
      # projector and fusion's HQ-cluster subscription are unchanged —
      # only the producer moved, from the root reaching down to the tier
      # publishing up.
      #
      # Labels are already stamped: the tier's own fusion and cm-service
      # propagate releasability onto these rows before they leave the
      # edge, so the completeness gate's question is answered at the tier
      # and the answer travels with the data.
      - asset-logistics-status
      - asset-cm-state
      #
      # AND THE ONE THAT IS NOT DERIVED STATE, carried for a different
      # reason: `telemetry-latest-state` is what HQ's `telemetry_latest_state`
      # table is projected FROM, and on the HQ broker that topic had never
      # been produced to at all (high-watermark 0, measured 2026-09-05).
      # Every row HQ held for this edge was written by the downward
      # per-edge projector below. Retire that projector without bridging
      # this topic and HQ's view of the edge does not go stale — IT GOES
      # EMPTY, and "no rows" is not the degraded mode ADR-0036 clause 4
      # specifies. `projector-hq` is already subscribed to this topic and
      # has simply been sitting on an empty partition; bridging it is what
      # gives that subscription something to read.
      - telemetry-latest-state
      #
      # THE REGION'S INPUT CONTRACT (DESIGN-2026-09-07-region-input-contract).
      # The rule these satisfy: EVERY CONSUMER A TIER RENDERS MUST HAVE A FED
      # TOPIC, OR MUST NOT BE RENDERED. region-east came up rendering 16
      # consumers and attaching 8; the other eight were processes at 1/1
      # Running subscribed to topics their broker did not hold, which no probe
      # distinguishes from working.
      #
      # Six for the tier's own rendered consumers:
      - asset-capability-snapshot   # tier-projector-capability, fusion-service-capability
      - asset-telemetry-windows     # tier-projector-windows, fusion-service-windows
      - asset-element-telemetry     # tier-projector-element-telemetry
      - asset-element-inventory     # tier-projector-element-inventory
      - derived-sustainment         # fusion-service-derived
      #
      # Measured rather than assumed: faust-regional reads
      # asset-telemetry-windows and derived-sustainment FROM EACH EDGE BROKER
      # DIRECTLY. Those two ARE the reachback — it reached down for exactly
      # what nothing carried up — so retiring the reachback and feeding the
      # relocated aggregator are one act, not two. Both are above.
      #
      # `asset-registry-events` WAS listed here and has been removed: it runs
      # the WRONG DIRECTION. The asset registry is root-owned, and its events
      # are distributed DOWN to tiers rather than gathered UP from them —
      # putting it on this bridge asked edges to supply reference data they
      # never author, which is why it sat at watermark 0 on every edge broker.
      #
      # A tier's inputs have TWO directions: derived state UP from children,
      # reference data DOWN from the root (registry, CM baselines, policy).
      # This list is the upward half only. The downward half is the
      # distribution seam, and faust-regional's registry source waits on it.
      #
      # NOT ADDED, and deliberately: `cm-events`. It is a RAW INGEST topic,
      # and detection binds to direct ingest only — the region's
      # cm-service-cm-events subscription is gated off, so nothing there would
      # read it. Carrying a topic no rendered consumer reads is the same
      # defect as rendering a consumer no topic feeds, pointed the other way.
      {{- end }}
    consumer_group: "bridge-group-{{ $edge.id }}"

output:
  kafka:
    addresses:
      {{- /* PUBLISHES TO ITS PARENT, not unconditionally to HQ. An edge
             under a tier-managed region bridges to the REGION; the region
             bridges to HQ. Falls back to HQ via toxiproxy when the parent
             has no tier node, which is today's topology for an untier-ed
             subtree and stays correct. See openddil.bridgeTarget. */}}
      - {{ include "openddil.bridgeTarget" (dict "tier" $edge "root" $root) }}
    topic: "${! meta(\"kafka_topic\") }"
    # PRESERVE THE KEY. Without this the relay produces NULL-keyed records,
    # and two things downstream treat the key as the row's identity:
    #
    #   * the destination topics are COMPACTED, so null-keyed records cannot
    #     be compacted and the log grows without bound; and
    #   * the projector COALESCES each drained batch by key, latest wins. Its
    #     own comment states the invariant it relies on -- "only messages
    #     sharing a key are dropped, so dedup never risks skipping another
    #     key's message". A relay that nulls every key makes every message
    #     share one, and the batch collapses to its last record.
    #
    # Latent until distinct rows started sharing a topic. Measured the day the
    # rollups were partitioned by releasability class: the aggregator emitted
    # all three partials every heartbeat, all three reached HQ intact, and
    # Postgres held TWO -- wear_trends holding three and top_factors one,
    # because which partial survived depended on where the batch boundary
    # fell. Nothing errored anywhere.
    key: "${! meta(\"kafka_key\") }"
    max_retries: 0
{{- end }}


{{/*
openddil.hubRestateConfigToml -- the ROOT Restate server's Kafka cluster set, as content.

HASHED BY THE DEPLOYMENT THAT MOUNTS IT. Extracted for the reason recorded
on openddil.edgeBridgeConnectYaml: a checksum annotation that hashes a
HAND-LISTED TUPLE of the values feeding a generated document will miss the
first change to anything outside the tuple. The bridge annotation hashed
edge id + broker + tier-managed flag while the retarget changed the OUTPUT
address; the hash was byte-identical, the pod template did not change,
Kubernetes correctly rolled nothing, helm reported success, and the process
held two-day-old config while every rendered artifact said otherwise.

Concretely here: the annotation hashed `.Values.edges` alone, while the
body also depends on redpandaEdge.internalPort, redpandaHq.kafkaPort and
the service domain. Changing a broker PORT would have left the root
Restate booted on the old cluster set, and Restate reads that set at BOOT
with no runtime reload -- so subscription creation fails against a cluster
the operator can plainly see in the ConfigMap.

The document is the input. Both the ConfigMap and the checksum consume this
template, so the next field anyone adds is covered automatically rather than
covered if they remember.
*/}}
{{- define "openddil.hubRestateConfigToml" -}}
{{- $root := . -}}
# Restate server configuration for the openddil-demo stack.
# GENERATED by the chart from .Values.edges — do not bake a copy.
#
# ADR-0023 Phase 6b §A: Kafka clusters are defined statically so the
# bootstrap scripts' subscription source URIs (kafka://openddil-<edge_id>/…)
# resolve to a known cluster.
{{- range .Values.edges }}

[[ingress.kafka-clusters]]
name = "openddil-{{ .id }}"
brokers = ["{{ printf "%s-redpanda-%s%s:%d" $.Release.Name .id (include "openddil.svcDomain" $) (int $.Values.redpandaEdge.internalPort) }}"]
{{- end }}

[[ingress.kafka-clusters]]
name = "openddil-hq"
brokers = ["{{ printf "%s-redpanda-hq%s:%d" .Release.Name (include "openddil.svcDomain" .) (int .Values.redpandaHq.kafkaPort) }}"]
{{- end }}


{{/*
openddil.tierRestateToml -- a tier Restate server's own-broker-only cluster set, as content.

HASHED BY THE DEPLOYMENT THAT MOUNTS IT. Extracted for the reason recorded
on openddil.edgeBridgeConnectYaml: a checksum annotation that hashes a
HAND-LISTED TUPLE of the values feeding a generated document will miss the
first change to anything outside the tuple. The bridge annotation hashed
edge id + broker + tier-managed flag while the retarget changed the OUTPUT
address; the hash was byte-identical, the pod template did not change,
Kubernetes correctly rolled nothing, helm reported success, and the process
held two-day-old config while every rendered artifact said otherwise.

This one was COMPLETE by luck rather than by construction: the body is two
substitutions and the tuple happened to name both. That is the argument
for changing it -- the next line added to the body would silently escape
a hash nobody would think to revisit.

The document is the input. Both the ConfigMap and the checksum consume this
template, so the next field anyone adds is covered automatically rather than
covered if they remember.
*/}}
{{- define "openddil.tierRestateToml" -}}
{{- $tier := .tier -}}
{{- $broker := .broker -}}
# Tier-scoped: names ONLY this tier's broker, so a subscription here
# cannot accidentally resolve to a sibling tier's cluster.
[[ingress.kafka-clusters]]
name = "openddil-{{ $tier.id }}"
brokers = ["{{ $broker }}"]

{{- end }}


{{/*
openddil.tierUplinkConnectYaml -- the intermediate tier -> parent uplink config, as content.

HASHED BY THE DEPLOYMENT THAT MOUNTS IT. Extracted for the reason recorded
on openddil.edgeBridgeConnectYaml: a checksum annotation that hashes a
HAND-LISTED TUPLE of the values feeding a generated document will miss the
first change to anything outside the tuple. The bridge annotation hashed
edge id + broker + tier-managed flag while the retarget changed the OUTPUT
address; the hash was byte-identical, the pod template did not change,
Kubernetes correctly rolled nothing, helm reported success, and the process
held two-day-old config while every rendered artifact said otherwise.

Concretely here: the annotation hashed tier id + broker + bridge target and
NOT the TOPIC LIST, which is written out in the body. The cutover changes
exactly that list -- it is the region's input contract -- so this is the
annotation that would have failed next, in the very step that needs it.

The document is the input. Both the ConfigMap and the checksum consume this
template, so the next field anyone adds is covered automatically rather than
covered if they remember.
*/}}
{{- define "openddil.tierUplinkConnectYaml" -}}
{{- $tier := .tier -}}
{{- $root := .root -}}
{{- $broker := .broker -}}
# {{ $tier.id }} → parent uplink. GENERATED by the chart.
input:
  kafka:
    addresses:
      - {{ $broker }}
    topics:
      # THE REGION'S OWN DERIVED STATE, which for an intermediate is a
      # rollup of what its children sent plus whatever it ingests
      # directly. Same topic names as an edge publishes, because the
      # parent's projector does not care which tier produced them —
      # only the producer moved.
      - asset-logistics-status
      - asset-cm-state
      - telemetry-latest-state
      - tactical-events
      #
      # AND WHAT THIS TIER ITSELF PRODUCES. HQ runs projector-region-fleet-
      # summary, -top-factors and -wear-trends against these topics. Before
      # the cutover faust-regional produced them onto the HQ broker directly;
      # once it lives in the region it produces them here, and if the uplink
      # does not carry them HQ's regional views go EMPTY on cutover day —
      # which is not the degraded mode ADR-0036 clause 4 specifies, and looks
      # like a region with no assets rather than a relay with a gap.
      - region-fleet-summary
      - region-top-factors
      - region-wear-trends
    consumer_group: "uplink-group-{{ $tier.id }}"

output:
  kafka:
    addresses:
      - {{ include "openddil.bridgeTarget" (dict "tier" $tier "root" $root) }}
    topic: "${! meta(\"kafka_topic\") }"
    # PRESERVE THE KEY. Without this the relay produces NULL-keyed records,
    # and two things downstream treat the key as the row's identity:
    #
    #   * the destination topics are COMPACTED, so null-keyed records cannot
    #     be compacted and the log grows without bound; and
    #   * the projector COALESCES each drained batch by key, latest wins. Its
    #     own comment states the invariant it relies on -- "only messages
    #     sharing a key are dropped, so dedup never risks skipping another
    #     key's message". A relay that nulls every key makes every message
    #     share one, and the batch collapses to its last record.
    #
    # Latent until distinct rows started sharing a topic. Measured the day the
    # rollups were partitioned by releasability class: the aggregator emitted
    # all three partials every heartbeat, all three reached HQ intact, and
    # Postgres held TWO -- wear_trends holding three and top_factors one,
    # because which partial survived depended on where the batch boundary
    # fell. Nothing errored anywhere.
    key: "${! meta(\"kafka_key\") }"
    max_retries: 0
{{- end }}
