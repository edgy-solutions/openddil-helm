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
Image reference for the exercise reset runner (exerciseControl.resetJob.image).
Follows global.imageRegistry/imagePrefix like every other OpenDDIL image, so
a deployment that mirrors images overrides the registry once. A non-empty
.repository is a full override and is used verbatim (thirdPartyImage).

Usage: include "openddil.resetRunnerImage" $   (the root context)
*/}}
{{- define "openddil.resetRunnerImage" -}}
{{- $i := .Values.exerciseControl.resetJob.image -}}
{{- if $i.repository -}}
{{ include "openddil.thirdPartyImage" (dict "repository" $i.repository "tag" $i.tag "digest" $i.digest) }}
{{- else -}}
{{ include "openddil.image" (dict "name" $i.name "tag" $i.tag "digest" $i.digest "root" .) }}
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
      {{- if and (include "openddil.ontologyDeploymentActive" .) (include "openddil.hasOntologyDst" .) }}
      {{- /* The DIS condition baselines file, when set, is added beside the
         bundle's dis_condition.yaml for the sidecar to merge; each file is
         copied only when its value is set. Said here, not in the rendered
         shell comment below, so a deployment that sets neither renders the
         same script and rolls no ontology reader. */}}
      # DEPLOYMENT LAYER, LAST: the deployment's whole releasability.yaml
      # replaces the bundle's copy (no merge). See
      # releasability.deploymentLayer in values.yaml.
      {{- if .root.Values.releasability.deploymentLayer.releasabilityYaml }}
      cp /ontology-deployment/releasability.yaml /shared/ontology/releasability.yaml
      echo "ontology deployment layer: releasability.yaml ($(wc -c < /ontology-deployment/releasability.yaml | tr -d ' ') bytes)"
      {{- end }}
      {{- if .root.Values.releasability.deploymentLayer.disConditionBaselinesYaml }}
      cp /ontology-deployment/dis_condition_baselines.yaml /shared/ontology/dis_condition_baselines.yaml
      echo "ontology deployment layer: dis_condition_baselines.yaml ($(wc -c < /ontology-deployment/dis_condition_baselines.yaml | tr -d ' ') bytes)"
      {{- end }}
      {{- end }}
  resources:
    {{- toYaml .root.Values.bundle.initResources | nindent 4 }}
  volumeMounts:
    - name: bundle-shared
      mountPath: /shared
    {{- if and (include "openddil.ontologyDeploymentActive" .) (include "openddil.hasOntologyDst" .) }}
    - name: ontology-deployment
      mountPath: /ontology-deployment
      readOnly: true
    {{- end }}
{{- end }}

{{/*
Deployment-side ontology layer (releasability.deploymentLayer). Accepts the
bundleInit dict or the chart root. Renders "true" when releasabilityYaml or
disConditionBaselinesYaml is set (both are files copied into the staged
ontology; usersYaml is not, and stays out).
*/}}
{{- define "openddil.ontologyDeploymentActive" -}}
{{- $r := . -}}
{{- if hasKey . "root" -}}{{- $r = .root -}}{{- end -}}
{{- if or $r.Values.releasability.deploymentLayer.releasabilityYaml $r.Values.releasability.deploymentLayer.disConditionBaselinesYaml -}}true{{- end -}}
{{- end }}

{{/* Takes the bundleInit dict; non-empty when some path entry has dst "ontology". */}}
{{- define "openddil.hasOntologyDst" -}}
{{- range .paths -}}{{- if eq .dst "ontology" -}}true{{- end -}}{{- end -}}
{{- end }}

{{/*
The pod-level volume for a pod whose bundleInit produces `ontology`.
Include in that pod's `volumes:` (nindent 8). Takes the chart root.
*/}}
{{- define "openddil.ontologyDeploymentVolume" -}}
{{- if include "openddil.ontologyDeploymentActive" . -}}
- name: ontology-deployment
  configMap:
    name: {{ .Release.Name }}-ontology-deployment
{{- end -}}
{{- end }}

{{/*
sha256 of the releasability layer string only. Takes the chart root. Its
consumers (openddil.ontologyDeploymentAnnotation, on hub, edge, logistics-sim
and tier pods) copy only releasability.yaml (bundleInit). users.yaml is
consumed by topaz, which tracks it through checksum/policy (liveReload off) or
the policy-sync sidecar (liveReload on). The DIS condition baselines are left
out on purpose, so a deployment that never sets them renders the same value
and rolls nothing; see openddil.disConditionBaselinesAnnotation.
*/}}
{{- define "openddil.ontologyDeploymentChecksum" -}}
{{- list .Values.releasability.deploymentLayer.releasabilityYaml | toJson | sha256sum -}}
{{- end }}

{{/*
Pod-template annotation line for a pod that mounts the layer. Takes the
chart root; renders nothing when the layer is unset.
*/}}
{{- define "openddil.ontologyDeploymentAnnotation" -}}
{{- if include "openddil.ontologyDeploymentActive" . -}}
checksum/ontology-deployment: {{ include "openddil.ontologyDeploymentChecksum" . | quote }}
{{- end -}}
{{- end }}

{{/*
Pod-template annotation line for the sensor-ingest pod only; renders nothing
when disConditionBaselinesYaml is unset. Takes the chart root. Only
sensor-ingest reads dis_condition_baselines.yaml (its DIS sidecar merges it
over the ontology's empty emission.baselines); the other pods that stage the
ontology also receive the file and ignore it, so a baselines change must not
roll them.
*/}}
{{- define "openddil.disConditionBaselinesAnnotation" -}}
{{- with .Values.releasability.deploymentLayer.disConditionBaselinesYaml -}}
checksum/dis-condition-baselines: {{ . | sha256sum | quote }}
{{- end -}}
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
openddil.linkControlEnabled -- renders "true" or empty. Gates every
link-control object: the toxiproxy ConfigMap/Deployment/Service, the
`uplink_<n>` listeners on the brokers, and the PEP's OPENDDIL_WAN_* env.
Off (the default): every bridge dials its parent broker directly.

Usage: {{- if include "openddil.linkControlEnabled" . }}
*/}}
{{- define "openddil.linkControlEnabled" -}}
{{- if .Values.linkControl.enabled -}}true{{- end -}}
{{- end }}

{{/*
openddil.toxiproxyConfigJson -- toxiproxy.json's content, as content.

EXTRACTED SO THE CHECKSUM CAN HASH THE THING ITSELF, same reasoning as
openddil.edgeBridgeConnectYaml: toxiproxy reads -config only at process
start (see infrastructure.yaml's own comment on the container args), so a
link-set change with no pod roll leaves new config on disk and the OLD set
of proxies in the running process. Both the ConfigMap and the Deployment's
checksum/config annotation render THIS, so the next field anyone adds to a
proxy entry is covered automatically rather than covered if they remember.

One `uplink-<id>` proxy per entry of openddil.uplinkLinks -- same port for
toxiproxy's own listen address and for the upstream broker's dedicated
listener, so no second port value needs to agree with it. Empty when link
control is off (uplinkLinks is then empty).
*/}}
{{- define "openddil.toxiproxyConfigJson" -}}
{{- $root := . -}}
{{- $proxies := list -}}
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
openddil.otherStackIds — every OTHER tier id that actually renders a tier
stack (tier-node.yaml), for logistics-fusion-service's OTHER_STACK_IDS env
(one writer per asset at every fusion, from record provenance -- see that
service's module docstring).

"Actually renders a tier stack" is the same gate+filter tier-node.yaml and
edge.yaml's $eventReportOn use: tierNode.enabled, and (tierNode.tiers empty
or containing the id). openddil.isTierManaged IS that gate+filter, by id,
so this reuses it over the full openddil.tierList rather than re-deriving
the condition a third time.

"OTHER" means excluding `.self` — empty for the root fusion (root is never
itself a tier, so there is nothing to exclude), or that tier's own id for
a tier fusion (a tier never defers to itself). ONE definition for both
callers (hub.yaml's root env and tier-node.yaml's per-tier env), so the
full set and each tier's own-id-excluded set can never disagree about
which ids have a stack.

Usage:
  {{- include "openddil.otherStackIds" (dict "root" $ "self" "") | fromYamlArray }}
  {{- include "openddil.otherStackIds" (dict "root" $root "self" $tier.id) | fromYamlArray }}
*/}}
{{- define "openddil.otherStackIds" -}}
{{- $root := .root -}}
{{- $self := .self | default "" -}}
{{- $out := list -}}
{{- range (include "openddil.tierList" $root | fromYamlArray) }}
{{- if and (include "openddil.isTierManaged" (dict "id" .id "root" $root)) (ne .id $self) }}
{{- $out = append $out .id }}
{{- end }}
{{- end }}
{{- toYaml $out }}
{{- end }}

{{/*
openddil.effectiveParent -- the parent broker a tier publishes to.

Resolution: `.parent | .region`, self-parent refused (a region's own
`region: <own id>` is not a parent), and a parent with no tier node of its
own (not openddil.isTierManaged) collapses to hq. Accepts an entry from
EITHER source: a tier-list entry carries an explicit `parent`; a raw
`.Values.edges` entry carries `region`, which for an edge IS its parent.

Returns YAML: { host: <parent id or "hq">, service: <release>-redpanda-<host> }
(no svcDomain suffix -- callers append their own).

Usage: include "openddil.effectiveParent" (dict "tier" $tier "root" $root) | fromYaml
*/}}
{{- define "openddil.effectiveParent" -}}
{{- $root := .root -}}
{{- $parent := .tier.parent | default .tier.region | default "" -}}
{{- if eq $parent (.tier.id | toString) }}{{- $parent = "" -}}{{- end -}}
{{- $parentManaged := "" -}}
{{- if $parent }}
{{- $parentManaged = include "openddil.isTierManaged" (dict "id" $parent "root" $root) -}}
{{- end }}
{{- $host := "hq" -}}
{{- if $parentManaged }}{{- $host = $parent -}}{{- end }}
host: {{ $host | quote }}
service: {{ printf "%s-redpanda-%s" $root.Release.Name $host | quote }}
{{- end }}

{{/*
openddil.uplinkLinks -- one entry per tier that bridges upward through its
own severable proxy. EMPTY unless link control is on
(openddil.linkControlEnabled); with it off nothing here exists, and a
bridge dials its parent broker directly (openddil.bridgeTarget).

THE LINK SET is every tier of kind "edge", plus every region that is
tier-managed (openddil.isTierManaged) -- exactly the tiers that run a
bridge (edge.yaml's edge-hq-bridge, or tier-node.yaml's tier-uplink-bridge
for a managed region with children). Filtered from openddil.tierList, so
entries keep its order.

PORT is `.Values.toxiproxy.uplinkPortBase` plus THIS link's own index in
THIS filtered list (not tierList's index), so ports are contiguous for
the links that actually exist. Deterministic -- no state needed, and
the same number is reused for toxiproxy's listen port, the parent
broker's extra listener and that broker's Service port.

EFFECTIVE PARENT is resolved by openddil.effectiveParent, the same rule
openddil.bridgeTarget uses.

SHAPE. Each entry:
    id                    the tier's own id
    port                  int; see above
    parentBrokerHost      the parent's bare id, or "hq" for the fallback --
                           matches against a broker loop's own tier id
                           ($tier.id, or the literal "hq" for redpanda-hq)
                           to find the links THAT broker must carry
    parentBrokerService   the parent broker's k8s Service name
                           (<release>-redpanda-<parent-id-or-hq>), with no
                           svcDomain suffix -- callers append their own
    listenerName           "uplink_<index>" -- underscore, not dash: this
                           is a Kafka listener name, not a k8s object name

Usage: {{- range (include "openddil.uplinkLinks" $root | fromYamlArray) }}
*/}}
{{- define "openddil.uplinkLinks" -}}
{{- $root := . -}}
{{- $out := list -}}
{{- if include "openddil.linkControlEnabled" $root }}
{{- range (include "openddil.tierList" $root | fromYamlArray) }}
{{- if or (eq .kind "edge") (include "openddil.isTierManaged" (dict "id" .id "root" $root)) }}
{{- if eq (.id | toString) "uplink" }}
{{- fail "openddil.uplinkLinks: a tier id may not be literally \"uplink\" while linkControl is on -- the PEP's /proxies/uplink route would shadow it" -}}
{{- end }}
{{- $p := include "openddil.effectiveParent" (dict "tier" . "root" $root) | fromYaml -}}
{{- $index := len $out -}}
{{- $out = append $out (dict
      "id" .id
      "port" (add (int $root.Values.toxiproxy.uplinkPortBase) $index)
      "parentBrokerHost" $p.host
      "parentBrokerService" $p.service
      "listenerName" (printf "uplink_%d" $index)) -}}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml $out -}}
{{- end }}

{{/*
openddil.childTierIds -- comma-joined ids of the tiers whose effective parent
is this tier. Called as (dict "tier" $tier "root" $root).

Separate from openddil.uplinkLinks on purpose: uplinkLinks is EMPTY unless
linkControl is on (it describes severable proxies), but a tier measures
heartbeat arrival from its children whether or not toggles exist. Same
filter (an edge, or a tier-managed tier), same order, no linkControl gate.
*/}}
{{- define "openddil.childTierIds" -}}
{{- $self := .tier.id | toString -}}
{{- $root := .root -}}
{{- $ids := list -}}
{{- range (include "openddil.tierList" $root | fromYamlArray) }}
{{- if or (eq .kind "edge") (include "openddil.isTierManaged" (dict "id" .id "root" $root)) }}
{{- $p := include "openddil.effectiveParent" (dict "tier" . "root" $root) | fromYaml -}}
{{- if eq $p.host $self }}{{- $ids = append $ids (.id | toString) -}}{{- end }}
{{- end }}
{{- end }}
{{- join "," $ids -}}
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
openddil.bridgeTarget -- where a tier's bridge publishes.

A tier publishes its derived state to ITS PARENT, not to HQ. That is what
makes the tree recursive rather than two-level: an edge under a
tier-managed region bridges to the REGION, and the region bridges to HQ.
The parent is resolved by openddil.effectiveParent.

LINK CONTROL ON (linkControl.enabled): every tier in openddil.uplinkLinks
(every edge, plus every tier-managed region) publishes through its OWN
toxiproxy proxy, `uplink-<id>`, at its own deterministic port
(openddil.uplinkPort), so each uplink is severable on its own. A tier with
no uplink port in that case is a render error naming the tier.

LINK CONTROL OFF (the default): no proxy exists; the bridge dials the
parent broker's PLAINTEXT Service directly -- redpanda-hq on
redpandaHq.kafkaPort, or a tier-managed parent's broker on
redpandaEdge.internalPort.

Usage: include "openddil.bridgeTarget" (dict "tier" $tier "root" $root)
*/}}
{{- define "openddil.bridgeTarget" -}}
{{- $root := .root -}}
{{- if include "openddil.linkControlEnabled" $root -}}
{{- $port := include "openddil.uplinkPort" (dict "tier" .tier "root" $root) -}}
{{- if not $port -}}
{{- fail (printf "openddil.bridgeTarget: tier %q has no uplink (not in openddil.uplinkLinks)" (.tier.id | toString)) -}}
{{- end -}}
{{- printf "%s-toxiproxy%s:%s" $root.Release.Name (include "openddil.svcDomain" $root) $port -}}
{{- else -}}
{{- $p := include "openddil.effectiveParent" (dict "tier" .tier "root" $root) | fromYaml -}}
{{- if eq $p.host "hq" -}}
{{- printf "%s%s:%d" $p.service (include "openddil.svcDomain" $root) (int $root.Values.redpandaHq.kafkaPort) -}}
{{- else -}}
{{- printf "%s%s:%d" $p.service (include "openddil.svcDomain" $root) (int $root.Values.redpandaEdge.internalPort) -}}
{{- end -}}
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

{{/*
openddil.ingressAnnotations — the annotations map for ONE Ingress object.

Starts from ingress.annotations (the operator's own, shared by every
Ingress this chart renders). When .redirect is true, this particular
Ingress serves a TLS host and ingress.httpsRedirect.enabled is set, so the
Traefik middleware that does the http->https redirect is referenced via
traefik.ingress.kubernetes.io/router.middlewares -- appended with a comma
if the operator already set that key (Traefik reads a comma-joined list),
set outright otherwise.

deepCopy is required: sprig's `set` mutates the map it is given, and
ingress.annotations is read twice in one render (root Ingress, each tier
Ingress) -- without the copy the second call would see the first call's
middleware already appended and double it.

Returns "" (nothing) when the resulting map is empty, so the call site's
`with` skips the `annotations:` key entirely -- today's behaviour when
ingress.annotations is {}.

Usage: {{ include "openddil.ingressAnnotations" (dict "root" $root "redirect" $redirect) }}
*/}}
{{- define "openddil.ingressAnnotations" -}}
{{- $root := .root -}}
{{- $ann := deepCopy (.root.Values.ingress.annotations | default dict) -}}
{{- if .redirect -}}
{{- $key := "traefik.ingress.kubernetes.io/router.middlewares" -}}
{{- $mw := printf "%s-%s-https-redirect@kubernetescrd" $root.Release.Namespace $root.Release.Name -}}
{{- if hasKey $ann $key -}}
{{- $ann = set $ann $key (printf "%s,%s" (get $ann $key) $mw) -}}
{{- else -}}
{{- $ann = set $ann $key $mw -}}
{{- end -}}
{{- end -}}
{{- if $ann }}
{{ toYaml $ann }}
{{- end -}}
{{- end }}

{{- define "openddil.isTierManaged" -}}
{{- if .root.Values.tierNode.enabled -}}
{{- if empty .root.Values.tierNode.tiers -}}true
{{- else if has .id .root.Values.tierNode.tiers -}}true
{{- end -}}
{{- end -}}
{{- end }}

{{- /*
openddil.regionAggBrokerId — the broker a region's faust-regional aggregator
reads and writes: the region's own broker when it is tier-managed, else hq.
Takes (dict "id" <region id> "root" $).
*/ -}}
{{- define "openddil.regionAggBrokerId" -}}
{{- if include "openddil.isTierManaged" (dict "id" .id "root" .root) -}}
{{- .id -}}
{{- else -}}
hq
{{- end -}}
{{- end }}

{{- /*
openddil.regionFanInTopic — the topic a region's source sub-apps fan state in
to, for its aggregator to read. Takes the region id.
*/ -}}
{{- define "openddil.regionFanInTopic" -}}
{{- printf "%s-fan-in" . -}}
{{- end }}

{{- /*
openddil.regionFanInSpecs — topic-init spec strings ("name|args") for the
fan-in topics whose aggregator broker is .brokerId, as a JSON list; pass it to
openddil.topicInitCreateLoop as .extra via fromJsonArray. Takes
(dict "brokerId" <id> "root" $).

Why topic-init declares these: faust-regional declares its fan-in topic only
at pod start, and broker auto-create is off. A broker that later loses its
topics (volume wipe) would otherwise never get it back, and the aggregator
would stay stuck until a restart. Ranges the same .Values.regions list as
regional.yaml, so the two cannot disagree. The args match what Faust creates
(1 partition, delete, 7 d), so enforcing them on a live topic changes nothing.
*/ -}}
{{- define "openddil.regionFanInSpecs" -}}
{{- $specs := list -}}
{{- range .root.Values.regions -}}
{{- if eq (include "openddil.regionAggBrokerId" (dict "id" .id "root" $.root)) $.brokerId -}}
{{- $specs = append $specs (printf "%s|-p 1 -r 1 -c cleanup.policy=delete -c retention.ms=604800000" (include "openddil.regionFanInTopic" .id)) -}}
{{- end -}}
{{- end -}}
{{- toJson $specs -}}
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

A region's uplink carries summaries AND the telemetry window
(asset-telemetry-windows), so HQ's asset_telemetry_windows fills and the HQ
fleet summary can read element-level counts; the per-element tree still stays
at the owning edge, only the window, which carries the element rollup, travels up.
*/}}
{{- define "openddil.edgeBridgeTopics" -}}
{{- $edge := .edge -}}
{{- $root := .root -}}
{{- $managed := include "openddil.isTierManaged" (dict "id" $edge.id "root" $root) -}}
{{- $t := list -}}
{{- if not $managed }}{{- $t = append $t "raw-sensor-stream" -}}{{- end -}}
{{- $t = append $t "tactical-events" -}}
{{- $t = append $t "effector-events" -}}
{{- $t = append $t "munition-tracks" -}}
{{- $t = append $t "link-heartbeat" -}}
{{- if $managed -}}
{{- /* ADR-0050: an unmanaged edge's declarations are written at the root directly. */ -}}
{{- $t = concat $t (list "asset-declarations" "asset-fielding") -}}
{{- /* The per-element tree stays at the owning edge; its rollup rides asset-telemetry-windows. */ -}}
{{- $t = concat $t (list "asset-logistics-status" "asset-cm-state" "telemetry-latest-state" "asset-capability-snapshot" "asset-telemetry-windows" "asset-element-inventory" "derived-sustainment") -}}
{{- else -}}
{{- /* ADR-0050: fielding lands on the fielded-to edge's broker at every edge, so an
       edge with no tier must bridge it too or the record is stranded there. */ -}}
{{- $t = append $t "asset-fielding" -}}
{{- end -}}
{{- join "," $t -}}
{{- end }}

{{- define "openddil.tierUplinkTopics" -}}
{{- join "," (list "asset-logistics-status" "asset-cm-state" "telemetry-latest-state" "asset-telemetry-windows" "tactical-events" "effector-events" "munition-tracks" "asset-declarations" "asset-fielding" "region-fleet-summary" "region-top-factors" "region-wear-trends" "link-heartbeat") -}}
{{- end }}

{{/*
openddil.relayTopics -- the topics one tier's relay carries to its parent: a
tier that rolls up carries the uplink set, a leaf carries its edge bridge set.
One definition, shared with the monitor: BRIDGE_TOPICS and the link traffic
meter both render from it.

Usage: include "openddil.relayTopics" (dict "tier" $t "root" $root)
*/}}
{{- define "openddil.relayTopics" -}}
{{- if .tier.hasChildren -}}
{{- include "openddil.tierUplinkTopics" .root -}}
{{- else -}}
{{- include "openddil.edgeBridgeTopics" (dict "edge" .tier "root" .root) -}}
{{- end -}}
{{- end }}

{{/*
openddil.linkTrafficTopics -- what a link's traffic meter counts: the topics
its own relay carries, minus link-heartbeat. The heartbeat is excluded because
it is produced every period whatever else moves; counting it would read every
link as active. Order is the relay's order.

Usage: include "openddil.linkTrafficTopics" (dict "tier" $t "root" $root)
*/}}
{{- define "openddil.linkTrafficTopics" -}}
{{- $out := list -}}
{{- range (splitList "," (include "openddil.relayTopics" .)) }}
{{- if ne . "link-heartbeat" }}{{- $out = append $out . -}}{{- end }}
{{- end -}}
{{- join "," $out -}}
{{- end }}

{{/*
openddil.validateLinkStatus -- refuses a value the chart no longer reads, so a
stale override fails the render instead of being silently ignored. Called
unconditionally from hub.yaml.
*/}}
{{- define "openddil.validateLinkStatus" -}}
{{- if hasKey .Values.linkStatus "trafficTopics" -}}
{{- fail "linkStatus.trafficTopics is no longer read: each link counts the topics its relay carries (openddil.linkTrafficTopics); remove it" -}}
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
             bridges to HQ. Falls back to HQ when the parent has no tier
             node, which is today's topology for an untier-ed subtree and
             stays correct. Goes through this edge's own severable proxy
             when linkControl.enabled. See openddil.bridgeTarget. */}}
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
15-topic consumer-group set (SPEC-consumer-declarations.md Part A).

CODE DEFAULT, NOT SHIPPED IN THIS CHART. projector-{{ edge.id }} (edge.yaml,
non-tier-managed edges only) and projector-hq (hub.yaml) both run the same
"openddil-projector" image with no PROJECTOR_CONFIG override, so both fall
back to the image's baked-in root config at
/app/src/config/projector_config.yaml in the openddil-projector repo. That
file is this list's source of truth; this is a mirror of it, written once so
every caller shares one list instead of re-typing 15 names.

Values measured from the live lab census (expected-declared.tsv), since the
source file lives in a different repo this chart does not vendor. The 13th
(projector-parts-availability) was added the same way the other 12 were: by
reading the handler list that file actually carries, not by re-deriving it
from this chart.

Per-edge projectors also carry the parts-availability mapping (the root
config is shared), but their broker has no such topic, so that group sits
idle there, same as the regional rollups.
*/}}
{{- define "openddil.projectorGroupIds" -}}
projector-asset-correlation projector-asset-declaration projector-asset-element-inventory projector-asset-element-telemetry projector-asset-fielding projector-capability-state projector-cm-state projector-effector-launch projector-logistics-status projector-munition-track projector-parts-availability projector-region-fleet-summary projector-region-top-factors projector-region-wear-trends projector-tactical-events projector-telemetry-latest projector-telemetry-windows
{{- end }}

{{/*
openddil.faustChangelogTopic -- Faust's own naming rule for a table's
changelog topic, `<app id>-<table name>-changelog`. This is Faust's default
behaviour (every Table gets a compacted changelog topic named from its
owning app's id and the table's own name), not a value this chart sets.
Usage: include "openddil.faustChangelogTopic" (dict "appId" ... "table" ...)
*/}}
{{- define "openddil.faustChangelogTopic" -}}
{{- printf "%s-%s-changelog" .appId .table -}}
{{- end }}

{{/*
openddil.faustEdgeTables -- the Faust table names faust-edge's app keeps:
one holding each asset's latest decoded state, one holding the running
prognostics accumulators. CODE DEFAULTS baked into the faust-edge app's own
table definitions (not visible in this chart, which has no Faust source to
read them from) -- confirmed from a live topic census of the resulting
changelog topics, not invented here.
*/}}
{{- define "openddil.faustEdgeTables" -}}
- asset_state
- prognostics_accumulators
{{- end }}

{{/*
openddil.faustRegionalAggregatorTable -- the one Faust table the regional
aggregator sub-app ("region-<id>-aggregator", see regional.yaml) keeps: the
region's latest per-asset rollup. CODE DEFAULT baked into the faust-regional
app's own table definition, named from the SAME region id value the rest of
regional.yaml already uses (hyphens become underscores the way the measured
changelog topic shows), never a second literal. Usage:
include "openddil.faustRegionalAggregatorTable" $region.id
*/}}
{{- define "openddil.faustRegionalAggregatorTable" -}}
{{- printf "region_%s_assets_latest" (. | replace "-" "_") -}}
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
    # faust-edge writes WindowedTelemetry as protobuf; decoding it as json
    # refuses every record and the table stays empty.
    decode_as: openddil.logistics.v1.WindowedTelemetry
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
  # DIS Fire/Detonation launch records. mode: custom,
  # same as the root default's entry (openddil-projector
  # src/config/projector_config.yaml) -- the handler owns its own Postgres
  # I/O, so NO retention_hours/asset_ttl_hours here either: see that file's
  # comment for why ageing this table out would make
  # effector_launcher_counts.expended (a running SUM) rebound upward.
  - topic: effector-events
    handler: effector_launch
    table: effector_launch
    consumer_group: tier-projector-effector-launch-{{ $tier.id }}
    decode_as: json
    mode: custom
  # In-flight munition tracks (ADR-0049). mode: custom with no
  # retention_hours/asset_ttl_hours, as effector_launch above: the handler
  # owns its own Postgres I/O and ageing rows out is its call, not the pruner's.
  - topic: munition-tracks
    handler: munition_track
    table: munition_track
    consumer_group: tier-projector-munition-track-{{ $tier.id }}
    decode_as: json
    mode: custom
  # Asset arrivals (ADR-0050). The declaration and its correlation record
  # share one topic and are projected by two groups; the fielding list is
  # its own topic. Records of intent: no retention_hours/asset_ttl_hours.
  - topic: asset-declarations
    handler: asset_declaration
    table: asset_declaration
    consumer_group: tier-projector-asset-declaration-{{ $tier.id }}
    decode_as: json
    mode: upsert
  - topic: asset-declarations
    handler: asset_correlation
    table: asset_correlation
    consumer_group: tier-projector-asset-correlation-{{ $tier.id }}
    decode_as: json
    mode: upsert
  - topic: asset-fielding
    handler: asset_fielding
    table: asset_fielding
    consumer_group: tier-projector-asset-fielding-{{ $tier.id }}
    decode_as: json
    mode: upsert
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
openddil.effectorDeclaredLoadYaml -- the declared-load
fixture, as ConfigMap content (effector-declared-load.yaml).

Rendered from .Values.effectors.declaredLoad once and reused by every
ConfigMap that mounts it (hub.yaml's projector-hq, edge.yaml's per-edge
root projector, tier-node.yaml's tier projector) -- same values, same
bytes, every instance, because declared load is a property of the
launcher asset/variant, not of which projector happens to admit its Fire.
openddil-projector/src/effector_declared_load.py accepts either top-level
key, `asset` and/or `variant`.
*/}}
{{- define "openddil.effectorDeclaredLoadYaml" -}}
{{- $dl := .Values.effectors.declaredLoad | default (dict) -}}
asset:
{{- if $dl.asset }}
{{ toYaml $dl.asset | indent 2 }}
{{- else }}
  {}
{{- end }}
variant:
{{- if $dl.variant }}
{{ toYaml $dl.variant | indent 2 }}
{{- else }}
  {}
{{- end }}
{{- end }}

{{/*
openddil.hqChildLinks -- HQ's direct children with their shape, as a JSON
array of {id, hasChildren}, in openddil.childTierIds order; "[]" when HQ has
no children. Read by the hub frontend's deployment.json, and by the gate that
decides whether that file is rendered at all, so the two cannot disagree.
*/}}
{{- define "openddil.hqChildLinks" -}}
{{- $tiers := include "openddil.tierList" . | fromYamlArray -}}
{{- $out := list -}}
{{- range (splitList "," (include "openddil.childTierIds" (dict "tier" (dict "id" "hq") "root" .))) }}
{{- $cid := . }}
{{- range $tiers }}
{{- if eq (.id | toString) $cid }}{{- $out = append $out (dict "id" $cid "hasChildren" (.hasChildren | default false)) }}{{- end }}
{{- end }}
{{- end }}
{{- toJson $out -}}
{{- end }}

{{/*
openddil.frontendMoveInputsJson -- the move panel's declared inputs as a JSON
object with the two keys `effectors` and `movement`. Always both keys, empty
maps/list when undeclared. One definition for the hub and every tier.
*/}}
{{- define "openddil.frontendMoveInputsJson" -}}
{{- $dl := .Values.effectors.declaredLoad | default dict -}}
{{- toJson (dict "effectors" (dict "declaredLoad" (dict "asset" ($dl.asset | default dict) "variant" ($dl.variant | default dict))) "movement" (dict "standards" (.Values.movement.standards | default dict) "units" (.Values.movement.units | default list))) -}}
{{- end }}

{{/*
openddil.frontendDeploymentJsonWanted -- "true" when the hub frontend gets a
deployment.json: any configured pane or FOB, releasability, any HQ child
link (whose shape places its header row), or any declared move-panel input
(movement units/standards, effector declared load). Empty otherwise.
*/}}
{{- define "openddil.frontendDeploymentJsonWanted" -}}
{{- if or .Values.frontend.releasedRecordsPanes .Values.frontend.fobs .Values.releasability.enabled (ne (include "openddil.hqChildLinks" .) "[]") .Values.movement.units .Values.movement.standards .Values.effectors.declaredLoad.asset .Values.effectors.declaredLoad.variant }}true{{- end -}}
{{- end }}

{{/*
The hub frontend's deployment.json: configured released-records panes, plus
the egress admission pane when releasability is on (the pane is then served
through the hub PEP), plus the declared edge attachments (DECLARED ONLY,
never inferred — an edge that says nothing about `attachment` is simply
omitted from the list, same as the OSS default). One definition, so the
ConfigMap and the pod's checksum annotation cannot disagree.

Always carries `effectors` and `movement` (empty when undeclared), so the
browser can tell "declared empty" from "an older chart".
*/}}
{{- define "openddil.frontendDeploymentJson" -}}
{{- $d := dict "releasedRecordsPanes" (.Values.frontend.releasedRecordsPanes | default list) -}}
{{- $_ := merge $d (include "openddil.frontendMoveInputsJson" . | fromJson) -}}
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
{{- if .Values.frontend.fobs -}}
{{- $_ := set $d "fobs" .Values.frontend.fobs -}}
{{- end -}}
{{- /* Each direct child's SHAPE (not its name): a child that rolls up sits on
       the hub->HQ segment, a leaf child on a direct edge->HQ line. */ -}}
{{- $childLinks := include "openddil.hqChildLinks" . | fromJsonArray -}}
{{- if $childLinks -}}
{{- $_ := set $d "childLinks" $childLinks -}}
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

Takes .broker — the host:port string passed to `-X brokers=`, and an optional
.extra — a list of further "name|args" spec strings for this broker only (the
region fan-in topics, see openddil.regionFanInSpecs), emitted after the fixed
entries.
*/ -}}
{{- define "openddil.topicInitCreateLoop" -}}
{{- $B := .broker }}
echo "INFO: Initializing topics on {{ $B }}"
drift=0
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
# Partition drift (spec -p N vs the live count) is logged after each
# topic below. It is not fixed and not fatal: topic-init never alters
# partitions, and a mismatch must not fail the hook (a failed hook leaves
# the release pending-upgrade). The hook's log is deleted on success, so
# scripts/check-topic-partitions.sh is the durable report.
for spec in \
  "raw-sensor-stream|-p 1 -r 1 -c retention.ms=86400000 -c compression.type=lz4" \
  "ingress-dlq|-p 1 -r 1 -c retention.ms=604800000" \
  "telemetry-latest-state|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000" \
  "tactical-events|-p 4 -r 1 -c retention.ms=2592000000" \
  "effector-events|-p 4 -r 1 -c retention.ms=2592000000" \
  "munition-tracks|-p 4 -r 1 -c retention.ms=86400000"   "asset-declarations|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1"   "asset-fielding|-p 8 -r 1 -c cleanup.policy=compact -c min.cleanable.dirty.ratio=0.1 -c segment.ms=60000 -c retention.ms=-1" \
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
  "link-heartbeat|-p 1 -r 1 -c retention.ms=3600000 -c cleanup.policy=delete" \
{{- range .extra }}
  {{ . | quote }} \
{{- end }}
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
  {{- include "openddil.topicInitDriftCheck" (dict "broker" $B) | nindent 2 }}
done
{{- include "openddil.topicInitDriftSummary" (dict "broker" $B) | nindent 0 }}
echo "INFO: Topics initialized on {{ $B }}"
{{- end -}}

{{/*
openddil.topicInitDriftCheck / openddil.topicInitDriftSummary -- partition
drift is LOGGED here, never fixed and never fatal. `topic create` leaves an
existing topic's partition count alone, so a spec that later said -p 8 over a
topic created at 1 stays at 1 forever; raising it on a compacted keyed topic
restarts offsets and needs a cold reset. The hook's log is deleted when the
hook succeeds, so scripts/check-topic-partitions.sh is the durable report.
Every command is safe under `set -e` when it matches nothing.
Takes .broker -- the host:port string (or shell variable) used for `-X brokers=`.
*/ -}}
{{- define "openddil.topicInitDriftCheck" -}}
want=$(printf '%s' "$args" | sed -n -E 's/.*-p ([0-9]+).*/\1/p')
livelist=$(rpk -X brokers={{ .broker }} topic list 2>/dev/null) || livelist=""
if [ -n "$want" ] && [ -n "$livelist" ]; then
  have=$(printf '%s\n' "$livelist" | awk -v t="$topic" '$1 == t { print $2; exit }')
  if [ "$have" != "$want" ]; then
    echo "TOPIC_INIT_PARTITION_DRIFT topic=$topic spec=$want live=${have:-missing} broker={{ .broker }}"
    drift=$((drift + 1))
  fi
fi
{{- end -}}

{{- define "openddil.topicInitDriftSummary" -}}
echo "INFO: partition drift on {{ .broker }}: $drift topic(s); topic-init never changes partition counts; scripts/check-topic-partitions.sh reports it"
{{- end -}}

{{/*
openddil.egressConfigTopics -- space-separated "hq/<topic>" pairs, one per
distinct value of `field` across an egress config list (assembler
output_topic, intake onward_topic), for the openddil.io/produces-topics
annotation. Reads only that one field; the rest of each entry stays opaque
to the chart. Empty when no entry carries the field.
*/}}
{{- define "openddil.egressConfigTopics" -}}
{{- $out := list -}}
{{- range .entries -}}
{{- $t := get . $.field -}}
{{- if $t -}}{{- $out = append $out (printf "hq/%s" $t) -}}{{- end -}}
{{- end -}}
{{- $out | uniq | join " " -}}
{{- end }}

{{/*
openddil.pictureValidate — fail the render on a malformed picture.serviceClients.

Emits nothing. Called wherever the list is consumed so a bad entry stops the
render whichever consumer is reached first. Checks: clientId, destination and
existingSecret.name/key present; clientIds unique; and no collision with a
client the realm already carries (the PEP client, the tier clients derived
from it, and the bundle realm's own PEP client).
*/}}
{{- define "openddil.pictureValidate" -}}
{{- $root := . -}}
{{- if $root.Values.picture.enabled -}}
{{- $taken := dict $root.Values.releasability.oidc.clientId true "openddil-pep" true -}}
{{- range $tier := (include "openddil.tierList" $root | fromYamlArray) -}}
{{- $_ := set $taken (include "openddil.tierClientId" (dict "id" $tier.id "root" $root)) true -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $i, $c := $root.Values.picture.serviceClients -}}
{{- if not $c.clientId -}}{{- fail (printf "picture.serviceClients[%d]: clientId is required" $i) -}}{{- end -}}
{{- if not $c.destination -}}{{- fail (printf "picture.serviceClients[%d] (%s): destination is required" $i $c.clientId) -}}{{- end -}}
{{- if not (and $c.existingSecret $c.existingSecret.name $c.existingSecret.key) -}}{{- fail (printf "picture.serviceClients[%d] (%s): existingSecret.name and existingSecret.key are required" $i $c.clientId) -}}{{- end -}}
{{- if hasKey $seen $c.clientId -}}{{- fail (printf "picture.serviceClients[%d]: duplicate clientId %q" $i $c.clientId) -}}{{- end -}}
{{- if hasKey $taken $c.clientId -}}{{- fail (printf "picture.serviceClients[%d]: clientId %q collides with an existing realm client" $i $c.clientId) -}}{{- end -}}
{{- $_ := set $seen $c.clientId true -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
openddil.pictureServiceClients — realm client fragment, one client per
picture.serviceClients entry, each followed by a comma (it is spliced ahead of
the bundle realm's own clients, like openddil.keycloakTierClients). The secret
is the placeholder __SVC_CLIENT_SECRET_<i>__; prepare-realm substitutes it
from an env var fed by the referenced Secret, so the value is never rendered.
*/}}
{{- define "openddil.pictureServiceClients" -}}
{{- $root := . }}
{{- include "openddil.pictureValidate" $root }}
{{- if $root.Values.picture.enabled }}
{{- range $i, $c := $root.Values.picture.serviceClients }}
    {
      "clientId": {{ $c.clientId | quote }},
      "name": {{ printf "Picture service client (%s)" $c.clientId | quote }},
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "__SVC_CLIENT_SECRET_{{ $i }}__",
      "serviceAccountsEnabled": true,
      "standardFlowEnabled": false,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "protocolMappers": [
        {
          "name": "picture-audience",
          "protocol": "openid-connect",
          "protocolMapper": "oidc-audience-mapper",
          "consentRequired": false,
          "config": {
            "included.custom.audience": {{ $root.Values.picture.audience | quote }},
            "access.token.claim": "true",
            "id.token.claim": "false"
          }
        }
      ]
    },
{{- end }}
{{- end }}
{{- end }}

{{/*
openddil.externalClientsValidate — fail the render on a malformed
releasability.keycloak.externalClients.

Emits nothing. Called wherever the list is consumed. Checks: clientId,
redirectUris and existingSecret.name/key present; every redirect URI is https
and has no wildcard; clientIds unique; and no collision with a client the realm
already carries (the PEP clients, the tier clients, the picture service clients).
*/}}
{{- define "openddil.externalClientsValidate" -}}
{{- $root := . -}}
{{- $taken := dict $root.Values.releasability.oidc.clientId true "openddil-pep" true -}}
{{- range $tier := (include "openddil.tierList" $root | fromYamlArray) -}}
{{- $_ := set $taken (include "openddil.tierClientId" (dict "id" $tier.id "root" $root)) true -}}
{{- end -}}
{{- if $root.Values.picture.enabled -}}
{{- range $p := $root.Values.picture.serviceClients -}}
{{- $_ := set $taken $p.clientId true -}}
{{- end -}}
{{- end -}}
{{- $seen := dict -}}
{{- range $i, $c := $root.Values.releasability.keycloak.externalClients -}}
{{- if not $c.clientId -}}{{- fail (printf "releasability.keycloak.externalClients[%d]: clientId is required" $i) -}}{{- end -}}
{{- if not $c.redirectUris -}}{{- fail (printf "releasability.keycloak.externalClients[%d] (%s): redirectUris is required and must not be empty" $i $c.clientId) -}}{{- end -}}
{{- if not (and $c.existingSecret $c.existingSecret.name $c.existingSecret.key) -}}{{- fail (printf "releasability.keycloak.externalClients[%d] (%s): existingSecret.name and existingSecret.key are required" $i $c.clientId) -}}{{- end -}}
{{- range $u := $c.redirectUris -}}
{{- if not (hasPrefix "https://" (toString $u)) -}}{{- fail (printf "releasability.keycloak.externalClients[%d] (%s): redirect URI %q must start with https://" $i $c.clientId $u) -}}{{- end -}}
{{- if contains "*" (toString $u) -}}{{- fail (printf "releasability.keycloak.externalClients[%d] (%s): redirect URI %q must not contain a wildcard" $i $c.clientId $u) -}}{{- end -}}
{{- end -}}
{{- if hasKey $seen $c.clientId -}}{{- fail (printf "releasability.keycloak.externalClients[%d]: duplicate clientId %q" $i $c.clientId) -}}{{- end -}}
{{- if hasKey $taken $c.clientId -}}{{- fail (printf "releasability.keycloak.externalClients[%d] (%s): clientId collides with an existing realm client" $i $c.clientId) -}}{{- end -}}
{{- $_ := set $seen $c.clientId true -}}
{{- end -}}
{{- end }}

{{/*
openddil.keycloakExternalClients — realm client fragment, one confidential
authorization-code client per releasability.keycloak.externalClients entry, each
followed by a comma (spliced after the picture clients, ahead of the bundle
realm's own). The secret is the placeholder __EXT_CLIENT_SECRET_<i>__;
prepare-realm substitutes it from an env var fed by the referenced Secret, so
the value is never rendered. The realm database is ephemeral and re-imported on
every start, so a client added by hand in the admin console would not survive.
PKCE is accepted but not required: a brokering identity provider may not send
it, and the client is confidential with exact redirect URIs.
*/}}
{{- define "openddil.keycloakExternalClients" -}}
{{- $root := . }}
{{- include "openddil.externalClientsValidate" $root }}
{{- range $i, $c := $root.Values.releasability.keycloak.externalClients }}
    {
      "clientId": {{ $c.clientId | quote }},
      "name": {{ printf "External relying party (%s)" $c.clientId | quote }},
      "description": "Confidential authorization-code client for an external relying party.",
      "enabled": true,
      "protocol": "openid-connect",
      "publicClient": false,
      "clientAuthenticatorType": "client-secret",
      "secret": "__EXT_CLIENT_SECRET_{{ $i }}__",
      "standardFlowEnabled": true,
      "implicitFlowEnabled": false,
      "directAccessGrantsEnabled": false,
      "serviceAccountsEnabled": false,
      "redirectUris": [ {{ range $j, $u := $c.redirectUris }}{{ if $j }}, {{ end }}{{ $u | quote }}{{ end }} ],
      "webOrigins": [],
      "attributes": { "post.logout.redirect.uris": "+" },
      "fullScopeAllowed": false,
      "defaultClientScopes": ["openid", "profile", "email"]
    },
{{- end }}
{{- end }}

{{/*
openddil.pictureClientMap — JSON object {clientId: destination} for the PEP.
*/}}
{{- define "openddil.pictureClientMap" -}}
{{- $m := dict -}}
{{- range $c := .Values.picture.serviceClients -}}
{{- $_ := set $m $c.clientId $c.destination -}}
{{- end -}}
{{- toJson $m -}}
{{- end }}

{{/*
openddil.linkExpectedIds — the link ids projector-hq expects a heartbeat from,
comma-separated: every edge, plus every region that runs a tier node. These are
exactly the ids that emit one (projector-<edge>, tier-projector-<tier>), so
the HQ monitor reports a silent link as down instead of omitting it.
*/}}
{{- define "openddil.linkExpectedIds" -}}
{{- $root := . -}}
{{- $ids := list -}}
{{- range $root.Values.edges }}{{- $ids = append $ids .id -}}{{- end -}}
{{- range $root.Values.regions }}
{{- if include "openddil.isTierManaged" (dict "id" .id "root" $root) }}{{- $ids = append $ids .id -}}{{- end -}}
{{- end -}}
{{- join "," $ids -}}
{{- end }}

{{/*
openddil.linkDeclaredIdleIds — ids of edges carrying `declaredIdle`
(edges[].declaredIdle: {reason, revisit}), comma-separated.
*/}}
{{- define "openddil.linkDeclaredIdleIds" -}}
{{- $ids := list -}}
{{- range .Values.edges }}{{- if .declaredIdle }}{{- $ids = append $ids .id -}}{{- end }}{{- end -}}
{{- join "," $ids -}}
{{- end }}

{{/*
Store connection parts as libpq environment. Takes a dict: host, port,
database, user, sslmode, secretName, secretKey. Renders PGHOST, PGPORT,
PGDATABASE, PGUSER, PGSSLMODE, then PGPASSWORD by secretKeyRef: the password
never appears as a rendered value. Indent with nindent at the call site.
*/}}
{{- define "openddil.pgEnv" -}}
- name: PGHOST
  value: {{ .host | quote }}
- name: PGPORT
  value: {{ .port | toString | quote }}
- name: PGDATABASE
  value: {{ .database | quote }}
- name: PGUSER
  value: {{ .user | quote }}
- name: PGSSLMODE
  value: {{ .sslmode | quote }}
- name: PGPASSWORD
  valueFrom:
    secretKeyRef:
      name: {{ .secretName | quote }}
      key: {{ .secretKey | quote }}
{{- end }}

{{/*
Env for the root (HQ) store, via openddil.pgEnv. The password
comes from postgresHq.auth.existingSecret when set, else the chart Secret.
Use: include "openddil.pgHqEnv" $root | nindent N
*/}}
{{- define "openddil.pgHqEnv" -}}
{{- $a := .Values.postgresHq.auth -}}
{{- include "openddil.pgEnv" (dict
    "host" (printf "%s-postgres-hq%s" .Release.Name (include "openddil.svcDomain" .))
    "port" (int .Values.postgresHq.port)
    "database" $a.database
    "user" $a.username
    "sslmode" .Values.postgresHq.sslmode
    "secretName" ($a.existingSecret | default (printf "%s-postgres-hq" .Release.Name))
    "secretKey" $a.passwordKey) -}}
{{- end }}

{{/*
Same for one tier store. Takes a dict: root, tier (the tier id string).
All tiers share tierNode.postgres.auth, so one Secret serves them all.
*/}}
{{- define "openddil.pgTierEnv" -}}
{{- $root := .root -}}
{{- $p := $root.Values.tierNode.postgres -}}
{{- include "openddil.pgEnv" (dict
    "host" (printf "%s-tier-pg-%s%s" $root.Release.Name .tier (include "openddil.svcDomain" $root))
    "port" (int $p.port)
    "database" $p.auth.database
    "user" $p.auth.username
    "sslmode" $p.sslmode
    "secretName" ($p.auth.existingSecret | default (printf "%s-tier-pg" $root.Release.Name))
    "secretKey" $p.auth.passwordKey) -}}
{{- end }}

{{/*
Redpanda --memory value, e.g. "640M": limits.memory (Mi) minus headroomMi.
Called with (dict "resources" <resources> "headroomMi" <int> "who" "<values path>").
Accepts <n>Gi and <n>Mi only; anything else, or no limit, fails the render.
*/}}
{{- define "openddil.redpandaMemory" -}}
{{- $lim := dig "limits" "memory" "" (.resources | default dict) | toString -}}
{{- $mi := 0 -}}
{{- if regexMatch "^[0-9]+Gi$" $lim -}}
{{- $mi = mul (trimSuffix "Gi" $lim | int) 1024 -}}
{{- else if regexMatch "^[0-9]+Mi$" $lim -}}
{{- $mi = trimSuffix "Mi" $lim | int -}}
{{- else -}}
{{- fail (printf "%s.resources.limits.memory=%q: set it as <n>Gi or <n>Mi (the broker's --memory is derived from it)" .who $lim) -}}
{{- end -}}
{{- $h := int .headroomMi -}}
{{- if lt $h 256 -}}
{{- fail (printf "%s.memoryHeadroomMi=%d: must be at least 256" .who $h) -}}
{{- end -}}
{{- $m := sub $mi $h -}}
{{- if lt $m 512 -}}
{{- fail (printf "%s: limits.memory %dMi minus memoryHeadroomMi %d leaves %dMi; the broker needs at least 512Mi (raise the limit)" .who $mi $h $m) -}}
{{- end -}}
{{- printf "%dM" $m -}}
{{- end }}

{{/*
openddil.renderedImages -- every image reference this release's workloads
run, newline-separated (duplicates possible; the caller de-duplicates).

Consumed only by templates/hook-images-pullable.yaml, which turns each into
a container that must pull and start before any other pre-* hook runs.

Built from the SAME values and the SAME enable conditions the workload
templates use, one block per condition:
  - always on: the bundle, hub, and database images, the utilities
    (atlas, alpine, curl for the helm test pods);
  - per edge / per region: sensor ingest, edge faust, edge-HQ bridge,
    regional faust;
  - linkControl.enabled: toxiproxy;
  - logisticsSim.enabled: the element simulator;
  - restate.ephemeralOnUpgrade: the restate-wipe hook's runner;
  - releasability.enabled: pep, topaz, the egress gate; keycloak when
    releasability.keycloak.enabled; the TAK server and adapter when
    egress.tak.enabled, its TLS proxy when egress.tak.tls.enabled;
  - exerciseControl.enabled with resetJob.enabled (under releasability): the
    reset runner, which only becomes a pod when a reset is pressed;
  - tierNode.enabled: the tier store, and the tier topaz when
    tierNode.topaz.enabled.


THIS LIST MUST CHANGE WHENEVER A TEMPLATE GAINS AN IMAGE. Guard 21 in
scripts/check-chart-render.sh renders the chart in several variants and
refuses the render when the images the workloads use and the images this
hook probes are not the same set.
*/}}
{{- define "openddil.renderedImages" -}}
{{- $root := . -}}
{{- $v := .Values -}}
{{- $o := list -}}
{{- range $k := (list "bundle" "restateHub" "cmService" "assetRegistry" "logisticsFusion" "projector" "frontend") -}}
{{- $i := (get $v $k).image -}}
{{- $o = append $o (include "openddil.image" (dict "name" $i.name "tag" $i.tag "digest" $i.digest "root" $root)) -}}
{{- end -}}
{{- range $i := (list $v.redpandaEdge.image $v.redpandaHq.image $v.postgresHq.image $v.electric.image $v.restate.image $v.utilities.atlas $v.utilities.alpine $v.utilities.curl) -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $i) -}}
{{- end -}}
{{- if $v.edges -}}
{{- range $k := (list "sensorIngest" "faustEdge") -}}
{{- $i := (get $v $k).image -}}
{{- $o = append $o (include "openddil.image" (dict "name" $i.name "tag" $i.tag "digest" $i.digest "root" $root)) -}}
{{- end -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.edgeHqBridge.image) -}}
{{- end -}}
{{- if or $v.edges $v.cmReports.enabled -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.redpandaConnect.image) -}}
{{- end -}}
{{- if $v.regions -}}
{{- $o = append $o (include "openddil.image" (dict "name" $v.faustRegional.image.name "tag" $v.faustRegional.image.tag "digest" $v.faustRegional.image.digest "root" $root)) -}}
{{- end -}}
{{- if include "openddil.linkControlEnabled" $root -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.toxiproxy.image) -}}
{{- end -}}
{{- if $v.logisticsSim.enabled -}}
{{- $i := $v.logisticsSim.image -}}
{{- $o = append $o (include "openddil.image" (dict "name" $i.name "tag" $i.tag "digest" $i.digest "root" $root)) -}}
{{- end -}}
{{- if $v.restate.ephemeralOnUpgrade -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.restate.wipe.image) -}}
{{- end -}}
{{- if $v.releasability.enabled -}}
{{- $i := $v.egress.image -}}
{{- $o = append $o (include "openddil.image" (dict "name" $i.name "tag" $i.tag "digest" $i.digest "root" $root)) -}}
{{- range $img := (list $v.releasability.pep.image $v.releasability.topaz.image) -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $img) -}}
{{- end -}}
{{- if $v.releasability.keycloak.enabled -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.releasability.keycloak.image) -}}
{{- end -}}
{{- if and $v.exerciseControl.enabled $v.exerciseControl.resetJob.enabled -}}
{{- $o = append $o (include "openddil.resetRunnerImage" $root) -}}
{{- end -}}
{{- if $v.egress.tak.enabled -}}
{{- $t := $v.egress.tak.image -}}
{{- $o = append $o (include "openddil.image" (dict "name" $t.name "tag" $t.tag "digest" $t.digest "root" $root)) -}}
{{- if $v.egress.tak.tls.enabled -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.egress.tak.tls.proxy.image) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $v.tierNode.enabled -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.tierNode.postgres.image) -}}
{{- if $v.tierNode.topaz.enabled -}}
{{- $o = append $o (include "openddil.thirdPartyImage" $v.tierNode.topaz.image) -}}
{{- end -}}
{{- end -}}
{{- join "\n" $o -}}
{{- end }}

{{/*
Asset arrivals (ADR-0050). openddil.arrivalsRootEdges -- the edge ids whose
declarations the ROOT PEP takes: every edge that is NOT tier-managed (a
managed edge's own tier PEP takes its declarations). Comma-joined; empty when
every edge is tier-managed. Takes the chart root.
*/}}
{{- define "openddil.arrivalsRootEdges" -}}
{{- $root := . -}}
{{- $ids := list -}}
{{- range $root.Values.edges -}}
{{- if not (include "openddil.isTierManaged" (dict "id" .id "root" $root)) -}}{{- $ids = append $ids .id -}}{{- end -}}
{{- end -}}
{{- join "," $ids -}}
{{- end }}

{{/*
openddil.arrivalsPepEnv -- the env block every PEP gets for the arrivals
routes. Takes (dict "root" $root "url" <intake URL or ""> "edges" <csv>
"owningTier" <id>). Roles and units come from values `arrivals`.
*/}}
{{- define "openddil.arrivalsPepEnv" -}}
- name: OPENDDIL_DECLARATION_INTAKE_URL
  value: {{ .url | quote }}
- name: OPENDDIL_ARRIVALS_EDGES
  value: {{ .edges | quote }}
- name: OPENDDIL_ARRIVALS_OWNING_TIER
  value: {{ .owningTier | quote }}
- name: OPENDDIL_ARRIVALS_DECLARE_ROLES
  value: {{ join "," .root.Values.arrivals.declareRoles | quote }}
- name: OPENDDIL_ARRIVALS_UNITS
  value: {{ .root.Values.arrivals.units | toJson | quote }}
- name: OPENDDIL_RELEASABILITY_FILE
  value: /ontology/releasability.yaml
- name: OPENDDIL_BASELINES_DIRS
  value: /baselines
{{- end }}

{{/*
openddil.declarationIntake -- one declaration-intake (ADR-0050 s2): a connect
Deployment taking the PEP's POST on 4198 and producing to asset-declarations
on its tier's broker, its Service, and a NetworkPolicy admitting only that
tier's PEP. A transport, not a gate. Takes (dict "root" $root "name" <suffix
after the release name> "component" <label component> "pepComponent" <the
PEP's label component> "broker" <host:port> "brokerId" <hq or tier id>).
*/}}
{{- define "openddil.declarationIntake" -}}
{{- $root := .root -}}
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ $root.Release.Name }}-{{ .name }}
  labels:
    {{- include "openddil.labels" $root | nindent 4 }}
    {{- include "openddil.selectorLabels" (dict "component" .component "root" $root) | nindent 4 }}
  annotations:
    openddil.io/produces-topics: {{ printf "%s/asset-declarations" .brokerId | quote }}
spec:
  replicas: 1
  selector:
    matchLabels:
      {{- include "openddil.selectorLabels" (dict "component" .component "root" $root) | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "openddil.podLabels" $root | nindent 8 }}
        {{- include "openddil.selectorLabels" (dict "component" .component "root" $root) | nindent 8 }}
      annotations:
        # declaration-intake.yaml ships as a static bundle file the init
        # container copies once at pod start; same staleness hazard and fix as
        # cm-intake.
        checksum/bundle: {{ include "openddil.policyChecksum" (dict "root" $root "extra" (list "declaration-intake" .name)) | sha256sum | quote }}
    spec:
      {{- with $root.Values.global.imagePullSecrets }}
      imagePullSecrets:
        {{- toYaml . | nindent 8 }}
      {{- end }}
      initContainers:
        {{- include "openddil.bundleInit" (dict "paths" (list
            (dict "src" "demo/declaration-intake.yaml" "dst" "connect.yaml")
          ) "root" $root) | nindent 8 }}
      containers:
        - name: connect
          image: "{{ include "openddil.thirdPartyImage" $root.Values.redpandaConnect.image }}"
          imagePullPolicy: {{ include "openddil.pullPolicy" (dict "policy" $root.Values.redpandaConnect.image.pullPolicy "root" $root) }}
          args: ["--chilled", "run", "/connect.yaml"]
          env:
            - name: REDPANDA_BROKER
              value: {{ .broker | quote }}
          ports:
            - name: http
              containerPort: 4198
          volumeMounts:
            - name: bundle-shared
              mountPath: /connect.yaml
              subPath: connect.yaml
          resources:
            {{- toYaml $root.Values.redpandaConnect.resources | nindent 12 }}
      volumes:
        - name: bundle-shared
          emptyDir: {}
---
apiVersion: v1
kind: Service
metadata:
  name: {{ $root.Release.Name }}-{{ .name }}
  labels:
    {{- include "openddil.labels" $root | nindent 4 }}
spec:
  ports:
    - port: 4198
      name: http
  selector:
    {{- include "openddil.selectorLabels" (dict "component" .component "root" $root) | nindent 4 }}
---
# BYPASS PREVENTION, SAME SHAPE AS cm-intake-pep-only. The intake trusts its
# caller's identity unchecked; only this tier's PEP may reach it.
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: {{ $root.Release.Name }}-{{ .name }}-pep-only
  labels:
    {{- include "openddil.labels" $root | nindent 4 }}
spec:
  podSelector:
    matchLabels:
      {{- include "openddil.selectorLabels" (dict "component" .component "root" $root) | nindent 6 }}
  policyTypes: [Ingress]
  ingress:
    - from:
        - podSelector:
            matchLabels:
              {{- include "openddil.selectorLabels" (dict "component" .pepComponent "root" $root) | nindent 14 }}
      ports:
        - protocol: TCP
          port: 4198
{{- end }}
