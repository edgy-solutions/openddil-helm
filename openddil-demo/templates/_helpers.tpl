{{/*
Common labels — for an OBJECT'S OWN metadata. Not for a pod template: use
openddil.podLabels there, and read why below before changing either.
*/}}
{{- define "openddil.labels" -}}
{{ include "openddil.podLabels" . }}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
{{- end }}

{{/*
Pod-template labels — openddil.labels MINUS helm.sh/chart.

WHY THE CHART VERSION IS NOT IN A POD LABEL
-------------------------------------------
A pod template label is part of the pod's spec, so changing it changes the
template hash and rolls the workload. helm.sh/chart carries the chart
version, so while it lived here EVERY chart version bump rolled EVERY
workload -- 95 of the chart's 96 -- whether or not that bump touched them.

That is not a cosmetic cost. It made the blast radius of a release
independent of its content: a one-line comment fix and a rewrite of the
projector were the same deploy, so the rollout could never be reasoned about
from the diff. Worse, it kept putting the whole fleet through the one event
UD-14 names as the trigger that preceded the 3.5-hour wedge, for no reason
connected to what was being released.

The chart version still belongs on the objects -- that is the question
"which chart made this?", and answering it is what the label is for. It does
not belong in the answer to "what should this pod be running?", because the
chart version is not part of that.

WHAT IS DELIBERATELY STILL HERE
-------------------------------
app.kubernetes.io/version, which is .Chart.AppVersion. That one SHOULD roll
pods: appVersion changing means the application changed, and a rollout is
the correct response rather than an accident. The distinction being drawn is
not "no version labels on pods", it is "the packaging version is not the
application version".

So: a chart version bump now rolls nothing by itself. Images, config
checksums and appVersion still roll what they should.
*/}}
{{- define "openddil.podLabels" -}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
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
      # IDEMPOTENT, because this init container runs more than once against
      # the SAME emptyDir. The volume survives container restarts within a
      # pod, so on any rerun `/shared/<dst>` already exists -- and `cp -r src
      # dst` on an existing directory copies INTO it, producing
      # /shared/proto/proto/openddil/... instead of replacing the tree.
      #
      # MEASURED 2026-09-16: the DIS mapper at edge-01 sat in
      # CrashLoopBackOff with 949 restarts, failing to start on
      #   symbol "openddil.common.v1.Quantity" already defined at
      #   openddil/common/v1/quantity.proto
      # -- the same file reachable under two import paths because the tree had
      # been nested. Each retry nested it one level deeper, so the failure fed
      # itself. A fresh pod (clean emptyDir) came up immediately with a single
      # tree, which is what identified the cause.
      #
      # The OVERLAY branch below already guards this hazard with `/.` and an
      # explicit mkdir, and its comment describes the exact failure -- for the
      # ontology tree. This branch never got the same treatment, so the guard
      # existed beside the hole it was written for.
      rm -rf "/shared/{{ .dst }}"
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
Content input for the identity pods' `checksum/policy` annotation
(topaz-hq, pep, keycloak, tier-pep — see each pod template's WHY comment).
Pipe the result through `sha256sum` at the call site, same as every other
checksum/* annotation in this chart.

MEASURED 2026-09-30: those four pod specs carried an annotation stamping
`{{ "{{" }} .Release.Revision {{ "}}" }}` on every render, which rolled all 6 identity pods (3 root + 3 per-tier) on EVERY helm
upgrade — because the entitlements corpus and the OIDC realm both arrive
inside the runtime-bundle image under a rolling tag, so the chart cannot
see whether the CONTENT behind that tag changed, only that an upgrade
happened. This replaces "did a revision happen" with "did the content an
identity pod actually loads change".

Usage:
  checksum/policy: {{ "{{" }} include "openddil.policyChecksum" (dict "root" $root "extra" (list ...)) | sha256sum {{ "}}" }}

Input, for every call site:
  - the fully resolved bundle-image reference, via the SAME openddil.image
    include openddil.bundleInit resolves it with (name/tag/digest/registry)
    — not re-derived, so the two can never disagree about what "the
    bundle" means.
  - `.extra`, a list of strings the CALLER supplies: every value under
    `.Values.releasability` (and, for tier-pep, the tier's own id and
    publicOrigin) that pod actually consumes and that is NOT already
    rendered literally into its own pod spec. A value already in the pod
    spec changes the rendered YAML by itself and Kubernetes rolls it
    without this helper's help — the only thing worth hashing here is
    what the pod spec does NOT show, e.g. `releasability.oidc.clientSecret`,
    which every consumer reaches through a Secret NAME, never its value.

CONSERVATIVE FALLBACK — the rolling-tag hazard must not come back by a
different door. A tag-only bundle reference can point at new content
without the reference TEXT changing at all, which is the exact hazard
above; content-addressing needs content to address, and a tag is not
content. So when `bundle.image.digest` is empty, `.Release.Revision` is
folded into the input too, i.e. an unpinned install keeps rolling
identity pods on every upgrade exactly like the revision-stamped
annotation this replaces. Pinning `bundle.image.digest` is how an install
opts in to rolling on content instead of on revision.
*/}}
{{- define "openddil.policyChecksum" -}}
{{- $root := .root -}}
{{- $digest := $root.Values.bundle.image.digest -}}
{{- $bundleImage := include "openddil.image" (dict "name" $root.Values.bundle.image.name "tag" $root.Values.bundle.image.tag "digest" $digest "root" $root) -}}
bundleImage={{ $bundleImage }}
{{- range $i, $v := (.extra | default list) }}
extra[{{ $i }}]={{ $v }}
{{- end }}
{{- if not $digest }}
revision={{ $root.Release.Revision }}
{{- end -}}
{{- end }}

{{/*
Keycloak realm per-tier clients (the keycloak-realm ConfigMap's tier-clients.json;
see the WHY comment there). A named template so keycloak's checksum/policy can
hash exactly what the ConfigMap renders: the realm substitutions come from the
tier list, not from anything in the keycloak pod spec, so without this a
digest-pinned install would leave keycloak on a stale realm when a tier's
publicOrigin changed.
*/}}
{{- define "openddil.keycloakTierClients" -}}
{{- $root := . }}
{{- range $tier := (include "openddil.tierList" $root | fromYamlArray) }}
{{- if and (include "openddil.isTierManaged" (dict "id" $tier.id "root" $root)) $tier.publicOrigin }}
{{- if $root.Values.releasability.oidc.enabled }}
    {
      "clientId": {{ include "openddil.tierClientId" (dict "id" $tier.id "root" $root) | quote }},
      "name": {{ printf "OpenDDIL tier PEP (%s)" $tier.id | quote }},
      "description": "Backend-for-frontend for one tier. Confidential: the browser never holds a token.",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "__PEP_CLIENT_SECRET__",
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "redirectUris": [
        {{ printf "%s/auth/callback" ($tier.publicOrigin | trimSuffix "/") | quote }}
      ],
      "webOrigins": [],
      "attributes": {
        "pkce.code.challenge.method": "S256",
        "post.logout.redirect.uris": "+"
      },
      "fullScopeAllowed": false,
      "defaultClientScopes": ["openid", "profile", "email", "roles"]
    },
{{- end }}
{{- end }}
{{- end }}
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
openddil.toxiproxyConfigJson — toxiproxy.json's content, as content.

EXTRACTED SO THE CHECKSUM CAN HASH THE THING ITSELF, same reasoning as
openddil.edgeBridgeConnectYaml: toxiproxy reads -config only at process
start (see infrastructure.yaml's own comment on the container args), so a
link-set change with no pod roll leaves new config on disk and the OLD set
of proxies in the running process. Both the ConfigMap and the Deployment's
checksum/config annotation render THIS, so the next field anyone adds to a
proxy entry is covered automatically rather than covered if they remember.

hq-link first (unconditional, unchanged shape), then one `uplink-<id>`
proxy per entry of openddil.uplinkLinks — same port for toxiproxy's own
listen address and for the upstream broker's dedicated listener, so no
second port value needs to agree with it.
*/}}
{{- define "openddil.toxiproxyConfigJson" -}}
{{- $root := . -}}
{{- $proxies := list (dict
      "name" "hq-link"
      "listen" (printf "0.0.0.0:%d" (int $root.Values.toxiproxy.apiPort))
      "upstream" (printf "%s-redpanda-hq%s:%d" $root.Release.Name (include "openddil.svcDomain" $root) (int $root.Values.redpandaHq.kafkaPort))
      "enabled" true) -}}
{{- range (include "openddil.uplinkLinks" $root | fromYamlArray) }}
{{- $port := (.port | int) -}}
{{- $proxies = append $proxies (dict
      "name" (printf "uplink-%s" .id)
      "listen" (printf "0.0.0.0:%d" $port)
      "upstream" (printf "%s%s:%d" .parentBrokerService (include "openddil.svcDomain" $root) $port)
      "enabled" true) -}}
{{- end }}
{{- toPrettyJson $proxies -}}
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

{{/*
cmReports.faultCodes retired in favour of cmReports.faultCatalog: the flat
list let an asset be offered, and the gateway accept, another platform
variant's fault code. Called unconditionally, before any enabled-gating in
every template that touches cmReports, so a values file still carrying the
old key fails fast on `helm template`/`helm install` rather than silently
being ignored.
*/}}
{{- define "openddil.cmReportsFaultCodesGuard" -}}
{{- if .Values.cmReports.faultCodes }}
{{- fail "cmReports.faultCodes (a global list) was replaced by cmReports.faultCatalog, generated per variant from the manual's fault-isolation modules" }}
{{- end }}
{{- end -}}

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
openddil.uplinkLinks — one entry per tier that bridges upward through
toxiproxy (P5: a severable link PER TIER, not one shared hq-link).

THE LINK SET is every tier of kind "edge", plus every region that is
tier-managed (openddil.isTierManaged) — exactly the tiers that run a
bridge (edge.yaml's edge-hq-bridge, or tier-node.yaml's tier-uplink-bridge
for a managed region with children). Filtered from openddil.tierList, so
entries keep its order.

PORT is `.Values.toxiproxy.uplinkPortBase` plus THIS link's own index in
THIS filtered list (not tierList's index), so ports are contiguous for
the links that actually exist. Deterministic — no state needed, and
the same number is reused for toxiproxy's listen port, the parent
broker's extra listener and that broker's Service port.

EFFECTIVE PARENT is the same resolution openddil.bridgeTarget has always
made: `.parent | .region`, self-parent refused (a region's own `region:
<own id>` is not a parent), falling back to hq when the resolved parent
has no tier node of its own.

SHAPE. Each entry:
    id                    the tier's own id
    port                  int; see above
    parentBrokerHost      the parent's bare id, or "hq" for the fallback —
                           matches against a broker loop's own tier id
                           ($tier.id, or the literal "hq" for redpanda-hq)
                           to find the links THAT broker must carry
    parentBrokerService   the parent broker's k8s Service name
                           (<release>-redpanda-<parent-id-or-hq>), with no
                           svcDomain suffix — callers append their own
    listenerName           "uplink_<index>" — underscore, not dash: this
                           is a Kafka listener name, not a k8s object name

Usage: {{- range (include "openddil.uplinkLinks" $root | fromYamlArray) }}
*/}}
{{- define "openddil.uplinkLinks" -}}
{{- $root := . -}}
{{- $out := list -}}
{{- range (include "openddil.tierList" $root | fromYamlArray) }}
{{- if or (eq .kind "edge") (include "openddil.isTierManaged" (dict "id" .id "root" $root)) }}
{{- $parent := .parent | default .region | default "" -}}
{{- if eq $parent (.id | toString) }}{{- $parent = "" -}}{{- end -}}
{{- $parentManaged := "" -}}
{{- if $parent }}
{{- $parentManaged = include "openddil.isTierManaged" (dict "id" $parent "root" $root) -}}
{{- end }}
{{- $parentBrokerHost := "hq" -}}
{{- $parentBrokerService := printf "%s-redpanda-hq" $root.Release.Name -}}
{{- if $parentManaged }}
{{- $parentBrokerHost = $parent -}}
{{- $parentBrokerService = printf "%s-redpanda-%s" $root.Release.Name $parent -}}
{{- end }}
{{- $index := len $out -}}
{{- $out = append $out (dict
      "id" .id
      "port" (add (int $root.Values.toxiproxy.uplinkPortBase) $index)
      "parentBrokerHost" $parentBrokerHost
      "parentBrokerService" $parentBrokerService
      "listenerName" (printf "uplink_%d" $index)) -}}
{{- end }}
{{- end }}
{{- toYaml $out -}}
{{- end }}

{{/*
openddil.uplinkPort — one tier's own uplink port, or "" if it has none.

Usage: include "openddil.uplinkPort" (dict "tier" $tier "root" $root)
*/}}
{{- define "openddil.uplinkPort" -}}
{{- $id := .tier.id -}}
{{- $result := "" -}}
{{- range (include "openddil.uplinkLinks" .root | fromYamlArray) }}
{{- if eq .id $id }}{{- $result = (.port | int) -}}{{- end }}
{{- end }}
{{- $result -}}
{{- end }}

{{/*
openddil.bridgeTarget — where a tier's bridge publishes.

A tier publishes its derived state to ITS PARENT, not to HQ. That is what
makes the tree recursive rather than two-level: an edge under a
tier-managed region bridges to the REGION, and the region bridges to HQ.

P5: EVERY UPLINK IS SEVERABLE, not just the one to HQ. Before P5, a bridge
to a MANAGED parent went direct to `redpanda-<parent>:9092` — nothing but
sever-tier.sh's NetworkPolicy could cut it. Now every tier in
openddil.uplinkLinks (every edge, plus every tier-managed region) publishes
through its OWN toxiproxy proxy, `uplink-<id>`, at its own deterministic
port (openddil.uplinkPort). The managed-parent direct path is gone.

Falls back to the old shared hq-link port only for a tier NOT in the link
set — which, as of P5, SHOULD NOT HAPPEN: every caller today (an edge via
edge.yaml, or a tier-managed region's uplink via tier-node.yaml) is always
in openddil.uplinkLinks. Kept so an unanticipated caller degrades to a
real (if unseverable) address instead of rendering an empty one.

Usage: include "openddil.bridgeTarget" (dict "tier" $tier "root" $root)
*/}}
{{- define "openddil.bridgeTarget" -}}
{{- $root := .root -}}
{{- /* Accepts an entry from EITHER source. A tier-list entry carries an
       explicit `parent`; a raw `.Values.edges` entry carries `region`,
       which for an edge IS its parent. edge.yaml still ranges over
       `.Values.edges` for its udpPort and friends, so both spellings
       arrive here. openddil.uplinkLinks resolves the same way, from the
       same two spellings. */ -}}
{{- $port := include "openddil.uplinkPort" (dict "tier" .tier "root" $root) -}}
{{- if $port -}}
{{- printf "%s-toxiproxy%s:%s" $root.Release.Name (include "openddil.svcDomain" $root) $port -}}
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
openddil.validateEdgeAttachment — render-time guard for `edges[].attachment`.

An edge MAY declare `attachment: tier | hq` (see values.yaml's `edges:`
comment). The declaration is optional, but when made it must agree with
how the edge is actually deployed: `hq` for an edge that is NOT tier-managed
(writes straight to HQ postgres), `tier` for one that is (projects into its
own tier store). A declaration that disagrees with the topology, or spells
the value wrong, fails the render outright — same reasoning as
openddil.cmReportsFaultCodesGuard: a silently wrong label on the HQ screens
is worse than a loud failure at template time.

Called unconditionally from hub.yaml so a values file with a bad declaration
fails `helm template`/`helm install` regardless of what else is enabled.

Usage: {{ include "openddil.validateEdgeAttachment" . }}
*/}}
{{- define "openddil.validateEdgeAttachment" -}}
{{- $root := . -}}
{{- range $edge := $root.Values.edges }}
{{- if $edge.attachment }}
{{- if not (has $edge.attachment (list "tier" "hq")) }}
{{- fail (printf "edge %s declares attachment: %s (must be \"tier\" or \"hq\")" $edge.id $edge.attachment) }}
{{- end }}
{{- $managed := eq (include "openddil.isTierManaged" (dict "id" $edge.id "root" $root)) "true" }}
{{- if and (eq $edge.attachment "hq") $managed }}
{{- fail (printf "edge %s is declared attachment: hq but has a tier node (tierNode.tiers)" $edge.id) }}
{{- end }}
{{- if and (eq $edge.attachment "tier") (not $managed) }}
{{- fail (printf "edge %s is declared attachment: tier but has no tier node" $edge.id) }}
{{- end }}
{{- end }}
{{- end }}
{{- end }}


{{/*
openddil.edgeBridgeTopics / openddil.tierUplinkTopics — the relay's topic
list, as a comma-separated string, from ONE definition.

WHY THESE EXIST. The bridge's topics were written out in the connect YAML,
and the buffer monitor's BRIDGE_TOPICS was a separate hand-list that the
chart never even set — so it kept the code default
"raw-sensor-stream,tactical-events" while the bridge had moved on.

The two could disagree, and did. Removing `raw-sensor-stream` from a
tier-managed edge left the monitor still counting it, and because the
consumer group keeps an offset on a topic it no longer consumes, that offset
falls behind FOREVER. The result was a healthy link reporting 106,409
messages of DDIL buffer — on the exact indicator a severance test watches.

One definition, two consumers, no opportunity to disagree. Same shape as
`openddil.publicOrigin`, and for the same reason: a value that must match in
three places must be written in one.
*/}}
{{- define "openddil.edgeBridgeTopics" -}}
{{- $edge := .edge -}}
{{- $root := .root -}}
{{- $managed := include "openddil.isTierManaged" (dict "id" $edge.id "root" $root) -}}
{{- $t := list -}}
{{- if not $managed }}{{- $t = append $t "raw-sensor-stream" -}}{{- end -}}
{{- $t = append $t "tactical-events" -}}
{{- if $managed -}}
{{- $t = concat $t (list "asset-logistics-status" "asset-cm-state" "telemetry-latest-state" "asset-capability-snapshot" "asset-telemetry-windows" "asset-element-telemetry" "asset-element-inventory" "derived-sustainment") -}}
{{- end -}}
{{- join "," $t -}}
{{- end }}

{{- define "openddil.tierUplinkTopics" -}}
{{- join "," (list "asset-logistics-status" "asset-cm-state" "telemetry-latest-state" "tactical-events" "region-fleet-summary" "region-top-factors" "region-wear-trends") -}}
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
{{/*
=============================================================================
THE RELAY INVARIANT — binding on every relay in this chart
=============================================================================

    A RELAY PRESERVES KEY, HEADERS AND TIMESTAMP.
    IT APPENDS ITS OWN relay_chain HOP.
    IT CHANGES NOTHING ELSE.

Stated here, at the boundary, because the failure it prevents is not visible
from either side of that boundary.

WHAT HAPPENED. The relays produced with no `key`, so every relayed record
arrived null-keyed. The projector coalesces each drained batch by key,
latest-wins, under a comment stating precisely the invariant that makes that
safe: "only messages sharing a key are dropped, so dedup never risks skipping
another key's message." A relay that nulls every key makes every message
share one, and the batch collapses to its last record.

NEITHER COMPONENT WAS WRONG ON ITS OWN TERMS. The invariant one relied on was
the one the other could violate, and nothing declared it at the boundary
between them. An invariant one component relies on and another can break must
be DECLARED WHERE THEY MEET, or it is a coincidence that has not ended yet.

AND IT SELF-HEALED, WHICH IS WHY IT SURVIVED. `telemetry-latest-state` had
been losing all but one asset's update per drained batch since the relays
existed — invisible in steady state because every asset re-emits seconds
later. A defect that repairs itself by re-emission looks exactly like a
working system: every screen correct, every batch lossy. It surfaced only
when three distinct rows shared one topic in one batch and could not repair
each other, and the first trace was three tables disagreeing about how many
partials existed.

The second consequence had not surfaced at all: null-keyed records cannot be
compacted, so every compacted destination log grows without bound. That is a
disk-pressure incident with a long fuse, found before it lit.

ENFORCED, NOT TRUSTED. check_tier_feed's `keyed` dimension reads the relayed
topics on each tier broker and reports any null key on a keyed topic as a
finding — so the next relay added to this chart cannot quietly lack what
these four now have.
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
      {{- /* FROM ONE DEFINITION. The buffer monitor reads the same helper
             for BRIDGE_TOPICS, so the relay and the thing that measures it
             cannot disagree about what it carries. They did: the monitor
             kept counting raw-sensor-stream after the bridge stopped
             consuming it, and the group offset on a retired topic falls
             behind forever - 106,409 messages of phantom DDIL buffer on a
             healthy link, on the indicator a severance test watches. */ -}}
      {{- range splitList "," (include "openddil.edgeBridgeTopics" (dict "edge" $edge "root" $root)) }}
      - {{ . }}
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
      {{- /* One definition, shared with the monitor. See the bridge above. */ -}}
      {{- range splitList "," (include "openddil.tierUplinkTopics" .) }}
      - {{ . }}
      {{- end }}
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

{{/*
openddil.halfMemoryBytes -- half of a Kubernetes memory quantity, in BYTES.

Restate's `rocksdb-total-memory-size` defaults to 100% of the process memory
limit and warns that it must be under 50%. This computes the 50% figure from
the SAME value that sets the limit, so the two cannot drift: raising the limit
raises the budget, and there is no second place to remember to edit.

Emits plain bytes because the env override rejects unit strings that the TOML
field accepts, and a rejected value is silently ignored -- which would leave
the 100% default in place while every rendered artifact said otherwise.

Accepts Gi / Mi / G / M and bare bytes. Anything else FAILS THE RENDER rather
than guessing: a wrong memory budget is exactly the defect this exists to stop,
and a helper that silently returns 0 on an unrecognised unit would reintroduce
it with more steps.
*/}}
{{- define "openddil.halfMemoryBytes" -}}
{{- $q := . | toString -}}
{{- $bytes := 0 -}}
{{- if hasSuffix "Gi" $q -}}
{{-   $bytes = mulf (trimSuffix "Gi" $q | float64) 1073741824.0 -}}
{{- else if hasSuffix "Mi" $q -}}
{{-   $bytes = mulf (trimSuffix "Mi" $q | float64) 1048576.0 -}}
{{- else if hasSuffix "G" $q -}}
{{-   $bytes = mulf (trimSuffix "G" $q | float64) 1000000000.0 -}}
{{- else if hasSuffix "M" $q -}}
{{-   $bytes = mulf (trimSuffix "M" $q | float64) 1000000.0 -}}
{{- else if regexMatch "^[0-9]+$" $q -}}
{{-   $bytes = $q | float64 -}}
{{- else -}}
{{-   fail (printf "openddil.halfMemoryBytes: cannot parse memory quantity %q. Use Gi, Mi, G, M or plain bytes. Refusing to guess -- a wrong RocksDB budget is what this helper exists to prevent." $q) -}}
{{- end -}}
{{- divf $bytes 2.0 | float64 | printf "%.0f" -}}
{{- end }}

{{/*
openddil.projectorGroupIds -- the "openddil-projector" service's fixed
11-topic consumer-group set (SPEC-consumer-declarations.md Part A).

CODE DEFAULT, NOT SHIPPED IN THIS CHART. projector-{{ edge.id }} (edge.yaml,
non-tier-managed edges only) and projector-hq (hub.yaml) both run the same
"openddil-projector" image with no PROJECTOR_CONFIG override, so both fall
back to the image's baked-in root config at
/app/src/config/projector_config.yaml in the openddil-projector repo. That
file is this list's source of truth; this is a mirror of it, written once so
every caller shares one list instead of re-typing 11 names.

Values measured from the live lab census (expected-declared.tsv), since the
source file lives in a different repo this chart does not vendor.
*/}}
{{- define "openddil.projectorGroupIds" -}}
projector-asset-element-inventory projector-asset-element-telemetry projector-capability-state projector-cm-state projector-logistics-status projector-region-fleet-summary projector-region-top-factors projector-region-wear-trends projector-tactical-events projector-telemetry-latest projector-telemetry-windows
{{- end }}

{{/*
openddil.tierProjectorGroupIds -- a tier projector's consumer-group ids, as a
space-separated list (SPEC-consumer-declarations.md Part A).

PARSED FROM THE RENDERED CONFIG, not re-typed. openddil.tierProjectorConfig
above already carries the authoritative `consumer_group` field per mapping
(fed straight to the ConfigMap this Deployment mounts); this reads them back
out with fromYaml so the declared-consumer-groups annotation and the running
config can never disagree about what a tier-projector actually consumes.

Usage: include "openddil.tierProjectorGroupIds" (dict "tier" $tier "root" $root)
*/}}
{{- define "openddil.tierProjectorGroupIds" -}}
{{- $cfg := include "openddil.tierProjectorConfig" . | fromYaml -}}
{{- $ids := list -}}
{{- range $cfg.mappings -}}
{{- $ids = append $ids .consumer_group -}}
{{- end -}}
{{- join " " $ids -}}
{{- end }}

{{/*
openddil.tierProjectorConfig -- a tier projector's mapping set, as content.

HASHED BY THE DEPLOYMENT THAT MOUNTS IT, for the reason recorded on
openddil.edgeBridgeConnectYaml and openddil.tierRestateToml: a checksum over a
hand-listed tuple of values misses the first change to anything outside the
tuple, and a config with NO checksum at all misses every change.

THE SECOND CASE IS THE ONE THAT BIT. This document had no checksum annotation,
so adding `retention_hours` to it on 2026-09-18 rendered correctly, applied
correctly, updated the live ConfigMap correctly -- and never reached the
running process. Nothing in the pod template changed, Kubernetes correctly
rolled nothing, helm reported success, and the projector kept the mapping set
it had loaded at startup.

Same shape as the bridge retarget: every rendered artifact said the new thing
while the process held the old one. Extracted here so the document IS the
hash input, and the next field anyone adds is covered by construction rather
than by remembering.
*/}}
{{- define "openddil.tierProjectorConfig" -}}
{{- $tier := .tier -}}
{{- $root := .root -}}
{{- $tn := $root.Values.tierNode -}}
# Tier-scoped projector mapping for {{ $tier.id }}.
# Root-only rollup topics (region-fleet-summary, region-top-factors,
# region-wear-trends) are deliberately ABSENT: they are produced by the
# aggregator to the root broker and would never arrive here.
settings:
  rate_limit_per_sec: 10
mappings:
  - topic: telemetry-latest-state
    handler: telemetry_latest
    table: telemetry_latest_state
    consumer_group: tier-projector-telemetry-latest-{{ $tier.id }}
    decode_as: openddil.telemetry.v1.EntityTelemetryEvent
    mode: upsert
    asset_ttl_hours: 24
  - topic: asset-cm-state
    handler: cm_state
    table: asset_cm_state
    consumer_group: tier-projector-cm-state-{{ $tier.id }}
    decode_as: json
    mode: upsert
  - topic: asset-logistics-status
    handler: logistics_status
    table: asset_logistics_status
    consumer_group: tier-projector-logistics-status-{{ $tier.id }}
    decode_as: openddil.logistics.v1.AssetLogisticsStatusUpdate
    mode: upsert
    asset_ttl_hours: 24
  - topic: asset-capability-snapshot
    handler: capability_state
    table: asset_capability_state
    consumer_group: tier-projector-capability-{{ $tier.id }}
    decode_as: json
    mode: upsert
  - topic: asset-telemetry-windows
    handler: telemetry_windows
    table: asset_telemetry_windows
    consumer_group: tier-projector-windows-{{ $tier.id }}
    decode_as: json
    mode: upsert
  - topic: tactical-events
    handler: tactical_events
    table: tactical_events
    consumer_group: tier-projector-tactical-events-{{ $tier.id }}
    decode_as: cloudevents.json
    mode: append
    # DECLARED RETENTION, per tier kind (values.yaml eventRetention).
    # Absent, this is None and the pruner skips the table entirely -- which
    # is how one region store reached 18,573 rows with the oldest ten days
    # old while the handler's docstring promised pruning. An intermediate
    # accumulates its whole subtree's events plus its own, so it keeps a
    # SHORTER window than a leaf, not a longer one: the region is where the
    # volume lands and where the shape is read from.
    retention_hours: {{ if $tier.hasChildren }}{{ $root.Values.eventRetention.regionHours }}{{ else }}{{ $root.Values.eventRetention.edgeHours }}{{ end }}
  - topic: asset-element-telemetry
    handler: asset_element_telemetry
    table: asset_element_telemetry
    consumer_group: tier-projector-element-telemetry-{{ $tier.id }}
    decode_as: json
    mode: upsert
  - topic: asset-element-inventory
    handler: asset_element_inventory
    table: inventory_items
    consumer_group: tier-projector-element-inventory-{{ $tier.id }}
    decode_as: json
    mode: upsert
{{- if $tier.hasChildren }}
  #
  # AN INTERMEDIATE PROJECTS ITS OWN ROLLUPS. The eight mappings above
  # are the LEAF shape: what a tier receives about assets. A tier with
  # children also PRODUCES a regional picture, and after the cutover the
  # aggregator lives here — so its outputs land on this broker and this
  # store is where they belong.
  #
  # Without these the region's own screen read "awaiting first emission"
  # while HQ held three class partials of the very numbers this tier
  # computed. The aggregator's home was the one place its work did not
  # appear.
  #
  # Rendered only for a tier with children, because a leaf produces no
  # rollups and a projector subscribed to topics its broker never carries
  # is an unfed consumer at 1/1 — the shape check_tier_feed exists to
  # find.
  - topic: region-fleet-summary
    handler: region_fleet_summary
    table: region_fleet_summary
    consumer_group: tier-projector-region-fleet-{{ $tier.id }}
    decode_as: openddil.regional.v1.RegionFleetSummary
    mode: upsert
  - topic: region-top-factors
    handler: region_top_factors
    table: region_top_factors
    consumer_group: tier-projector-region-factors-{{ $tier.id }}
    decode_as: openddil.regional.v1.RegionTopFactors
    mode: upsert
  - topic: region-wear-trends
    handler: region_wear_trends
    table: region_wear_trends
    consumer_group: tier-projector-region-wear-{{ $tier.id }}
    decode_as: openddil.regional.v1.RegionWearTrends
    mode: upsert
{{- end }}
{{- end }}

{{/*
The hub frontend's deployment.json: configured released-records panes, plus
the egress admission pane when releasability is on (the pane is then served
through the hub PEP), plus the declared edge attachments (DECLARED ONLY,
never inferred — an edge that says nothing about `attachment` is simply
omitted from the list, same as the OSS default). One definition, so the
ConfigMap and the pod's checksum annotation cannot disagree.
*/}}
{{- define "openddil.frontendDeploymentJson" -}}
{{- $d := dict "releasedRecordsPanes" (.Values.frontend.releasedRecordsPanes | default list) -}}
{{- if .Values.releasability.enabled -}}
{{- $_ := set $d "egressPane" (dict "destination" .Values.egress.destination) -}}
{{- end -}}
{{- $declaredEdges := list -}}
{{- range .Values.edges }}
{{- if .attachment }}
{{- $declaredEdges = append $declaredEdges (dict "id" .id "attachment" .attachment) }}
{{- end }}
{{- end }}
{{- if $declaredEdges -}}
{{- $_ := set $d "edges" $declaredEdges -}}
{{- end -}}
{{- toJson $d -}}
{{- end -}}

{{- /*
openddil.topicInitCreateLoop — the one shared topic spec list

Every topic-init Job — the hub-only one in infrastructure.yaml (hq broker)
and each tier's topic-init-<id> in infrastructure.yaml (that tier's own
broker, rendered from the same range/if as that tier's broker StatefulSet)
— must create and config-enforce the identical set of topics. This
is the only form of that fact that cannot drift the way the pre-split
broker list once did: infrastructure.yaml's topic-init used to range over
a SEPARATE predicate from the broker StatefulSet loop, and a tier-managed
region got a broker and never got topic-init because the two lists were
kept in parallel (see infrastructure.yaml's "BROKER LIST" history
comment). A hub edit and a tier edit of two copies of this spec list would
be the same failure mode one level up.

Takes .broker — the host:port string passed to `-X brokers=`.
*/ -}}
{{- define "openddil.topicInitCreateLoop" -}}
{{- $B := .broker }}
echo "INFO: Initializing topics on {{ $B }}"
# ---------------------------------------------------------
# compression.type=lz4 ON EVERY TOPIC RESTATE SUBSCRIBES TO
# ---------------------------------------------------------
# Restate's Kafka ingress is built on a librdkafka WITHOUT
# zstd support. One zstd batch on a subscribed topic kills
# the consumer task with
#   Decompression (codec 0x4) ... Local: Not implemented
# Restate restarts the task from its stored position, hits
# the same batch, and dies again -- forever. Fusion then
# receives ZERO invocations while every pod reads Running:
# no severity, no transitions, no tactical events, and a
# completeness gate refusing an empty table downstream.
#
# `compression.type=producer` -- the default these topics
# carried -- means "store whatever codec the CLIENT chose",
# and one of the clients chooses zstd. The default is not
# neutral here: it delegates a correctness-critical choice
# to whichever library happens to write the batch.
#
# NOT the ingress-*-raw topics' explicit zstd below. Those
# are deliberate for volume and Restate subscribes to none
# of them. Stated because that setting is the obvious
# suspect and is NOT the cause -- HQ's asset-cm-state,
# never altered by hand, read `producer (DEFAULT_CONFIG)`.
#
# Measured 2026-09-17 on the lab. This reaches the work
# cluster on upgrade, so it is a P0.1 gate, not a lab
# curiosity.
# A COMMENT MAY NOT LIVE INSIDE A LINE CONTINUATION.
# These notes sat between `for spec in \` and the first
# item. The backslash joins the next line, `#` then eats
# the rest of it, and the `for` loses its word list: the
# WHOLE script becomes a parse error, so nothing in this
# Job runs -- including the fix the comment documents.
# Cost: 7 backoff retries, a Failed hook, a release stuck
# in pending-upgrade, and the post-upgrade bootstrap that
# re-registers Restate never firing. Verified with `sh -n`
# (2026-09-17) rather than by reading. Keep prose ABOVE the
# `for`, and syntax-check this script when it changes.
for spec in \
  "raw-sensor-stream|-p 1 -r 1 -c retention.ms=86400000 -c compression.type=lz4" \
  "ingress-dlq|-p 1 -r 1 -c retention.ms=604800000" \
  "telemetry-latest-state|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000" \
  "tactical-events|-p 4 -r 1 -c retention.ms=2592000000" \
  "asset-cm-state|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1 -c compression.type=lz4" \
  "cm-items|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
  "cm-events|-p 8 -r 1 -c cleanup.policy=compact,delete -c retention.ms=2592000000 -c compression.type=lz4" \
  "ingress-dis-raw|-p 8 -r 1 -c retention.ms=86400000 -c compression.type=zstd" \
  "ingress-proprietary-raw|-p 8 -r 1 -c retention.ms=86400000 -c compression.type=zstd" \
  "ingress-sim-a-raw|-p 8 -r 1 -c retention.ms=86400000 -c compression.type=zstd" \
  "ingress-weapons-capability-raw|-p 8 -r 1 -c retention.ms=86400000 -c compression.type=zstd" \
  "asset-capability-snapshot|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1 -c compression.type=lz4" \
  "asset-telemetry-windows|-p 8 -r 1 -c retention.ms=86400000 -c cleanup.policy=delete -c compression.type=lz4" \
  "asset-logistics-status|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
  "derived-sustainment|-p 1 -r 1 -c retention.ms=86400000 -c compression.type=lz4" \
  "region-fleet-summary|-p 1 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
  "region-top-factors|-p 1 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
  "region-wear-trends|-p 1 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
  "asset-registry-events|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
  "asset-element-telemetry|-p 1 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1 -c max.message.bytes=16777216" \
  "asset-element-inventory|-p 1 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
  ; do
  topic="${spec%%|*}"
  args="${spec##*|}"
  # Create idempotently. BUT: if the topic was already auto-
  # created by redpanda (a producer/consumer connected before
  # this post-install hook completed), the create no-ops with
  # `|| true` and the intended -c configs are NEVER applied --
  # the topic silently keeps redpanda defaults (1MB
  # max.message.bytes, cleanup.policy=delete). That breaks
  # large-message topics like asset-element-telemetry (per-
  # asset element snapshots run several MB): the sim's produce
  # fails with MessageSizeTooLargeError and NO tiles ever land.
  # Observed on openddil-test 2026-07-31.
  #
  # So ALSO enforce the -c configs via alter-config, which
  # corrects a pre-existing/auto-created topic to the intended
  # spec. Idempotent: re-setting a config to its current value
  # is a no-op, so this is safe to run on every install/upgrade
  # and self-heals a topic that lost the create race. -p/-r are
  # stripped (partition/replica counts aren't config-altered
  # here); each `-c k=v` becomes `--set k=v`.
  rpk -X brokers={{ $B }} topic create $topic $args || true
  setargs=$(printf ' %s' "$args" | sed -E 's/ -p [0-9]+//; s/ -r [0-9]+//; s/ -c / --set /g')
  if [ -n "$setargs" ]; then
    rpk -X brokers={{ $B }} topic alter-config $topic $setargs || true
  fi
done
echo "INFO: Topics initialized on {{ $B }}"
{{- end -}}
