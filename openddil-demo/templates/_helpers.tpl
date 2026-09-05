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
