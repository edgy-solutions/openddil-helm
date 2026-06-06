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
      # {{ .src }} -> /shared/{{ .dst }}
      mkdir -p "$(dirname /shared/{{ .dst }})"
      if [ -f "/bundle/{{ .src }}" ]; then
        cp "/bundle/{{ .src }}" "/shared/{{ .dst }}"
      else
        cp -r "/bundle/{{ .src }}" "/shared/{{ .dst }}"
      fi
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
