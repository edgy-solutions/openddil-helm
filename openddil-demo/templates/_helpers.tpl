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
{{- $out = append $out (dict
      "id" .id
      "kind" "edge"
      "parent" (default .region .parent)
      "hasChildren" (default false .hasChildren)
      "label" (default .id .label)
      "publicOrigin" (default "" .publicOrigin)
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
      "region" .id) -}}
{{- end }}
{{- toYaml $out }}
{{- end }}
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
