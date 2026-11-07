{{/*
Declared analytic units (values: algorithms).

  openddil.algorithms.validate     fails the render on a bad enabled list, a
                                   missing or mismatched chart copy of a
                                   declaration, or an override that the
                                   declaration does not allow
  openddil.algorithms.paramsJson   ALGORITHM_PARAMS_JSON: {unit: overrides}
  openddil.algorithms.enabledCsv   ALGORITHMS_ENABLED
  openddil.algorithms.outputTopics distinct output topics of enabled units
  openddil.algorithms.stateTables  Faust table of each enabled unit

The chart reads files/algorithms/<unit>/unit.yaml ONLY to validate overrides
at render. The pod loads the unit from the bundle (/bundle/agents/algorithms),
never from a ConfigMap; scripts/check-algorithm-declarations.sh keeps the two
copies the same file.
*/}}

{{/* openddil.algorithms.decl -- the declaration of one unit as YAML, or {}
   when the chart has no copy (validate reports that). Usage:
   include "openddil.algorithms.decl" (dict "root" . "unit" "wear") | fromYaml */}}
{{- define "openddil.algorithms.decl" -}}
{{- $text := .root.Files.Get (printf "files/algorithms/%s/unit.yaml" .unit) -}}
{{- if $text }}{{ $text }}{{ else }}{}{{ end -}}
{{- end }}

{{- define "openddil.algorithms.enabledList" -}}
{{- $alg := .Values.algorithms | default dict -}}
{{- if kindIs "slice" $alg.enabled }}{{ toYaml $alg.enabled }}{{ else }}[]{{ end -}}
{{- end }}

{{- define "openddil.algorithms.enabledCsv" -}}
{{- include "openddil.algorithms.enabledList" . | fromYamlArray | join "," -}}
{{- end }}

{{- define "openddil.algorithms.paramsJson" -}}
{{- $alg := .Values.algorithms | default dict -}}
{{- $units := $alg.units | default dict -}}
{{- $out := dict -}}
{{- range (include "openddil.algorithms.enabledList" . | fromYamlArray) -}}
{{- $ud := index $units . | default dict -}}
{{- $p := $ud.params | default dict -}}
{{- if $p }}{{ $_ := set $out . $p }}{{ end -}}
{{- end -}}
{{- toJson $out -}}
{{- end }}

{{- define "openddil.algorithms.outputTopics" -}}
{{- $root := . -}}
{{- $topics := list -}}
{{- range (include "openddil.algorithms.enabledList" . | fromYamlArray) -}}
{{- $d := include "openddil.algorithms.decl" (dict "root" $root "unit" .) | fromYaml -}}
{{- range ($d.outputs | default list) -}}
{{- if not (has .topic $topics) }}{{ $topics = append $topics .topic }}{{ end -}}
{{- end -}}
{{- end -}}
{{- if $topics }}{{ toYaml $topics }}{{ else }}[]{{ end -}}
{{- end }}

{{- define "openddil.algorithms.stateTables" -}}
{{- $root := . -}}
{{- $tables := list -}}
{{- range (include "openddil.algorithms.enabledList" . | fromYamlArray) -}}
{{- $d := include "openddil.algorithms.decl" (dict "root" $root "unit" .) | fromYaml -}}
{{- if and $d.state $d.state.table }}{{ $tables = append $tables $d.state.table }}{{ end -}}
{{- end -}}
{{- if $tables }}{{ toYaml $tables }}{{ else }}[]{{ end -}}
{{- end }}

{{- define "openddil.algorithms.validate" -}}
{{- $root := . -}}
{{- $fe := .Values.faustEdge | default dict -}}
{{- /* 1. the retired override map */ -}}
{{- if hasKey $fe "prognosticsEnv" -}}
{{- fail "faustEdge.prognosticsEnv was removed; set algorithms.units.wear.params.<name> instead (TRACK_LIFE_TOTAL_KM -> track_life_total_km, ENGINE_LIFE_TOTAL_HOURS -> engine_life_total_hours, TERRAIN_TOTAL_DEG_KM -> terrain_total_deg_km, BARREL_LIFE_TOTAL_ROUNDS -> barrel_life_total_rounds)" -}}
{{- end -}}
{{- $alg := .Values.algorithms | default dict -}}
{{- /* 2. the enabled list */ -}}
{{- $enabled := $alg.enabled -}}
{{- if not (kindIs "slice" $enabled) -}}
{{- fail (printf "algorithms.enabled must be a non-empty list of unit names, got %s; the runner refuses an empty list, so set it to [wear]" (kindOf $enabled)) -}}
{{- end -}}
{{- if not $enabled -}}
{{- fail "algorithms.enabled must not be empty; the runner refuses an empty list at startup, so set it to [wear]" -}}
{{- end -}}
{{- if ne (len (uniq $enabled)) (len $enabled) -}}
{{- fail (printf "algorithms.enabled has a duplicate entry: %s" (join "," $enabled)) -}}
{{- end -}}
{{- $decls := dict -}}
{{- range $enabled -}}
{{- if not (kindIs "string" .) -}}
{{- fail (printf "algorithms.enabled entries must be strings, got %s" (kindOf .)) -}}
{{- end -}}
{{- /* 3. a chart copy per enabled unit */ -}}
{{- if not . -}}
{{- fail "algorithms.enabled must not hold an empty name (--set algorithms.enabled={} gives [\"\"]); the runner refuses an empty list at startup, so set it to [wear]" -}}
{{- end -}}
{{- $path := printf "files/algorithms/%s/unit.yaml" . -}}
{{- if not ($root.Files.Get $path) -}}
{{- fail (printf "algorithms.enabled names %q but the chart has no declaration at %s (copy it from openddil-tactical-agents/algorithms/%s/unit.yaml)" . $path .) -}}
{{- end -}}
{{- $d := $root.Files.Get $path | fromYaml -}}
{{- /* 4. identity */ -}}
{{- if ne (toString $d.apiVersion) "openddil.io/algorithm/v1" -}}
{{- fail (printf "%s: apiVersion must be openddil.io/algorithm/v1, got %q" $path (toString $d.apiVersion)) -}}
{{- end -}}
{{- if ne (toString $d.unit) . -}}
{{- fail (printf "%s: unit is %q but the directory is %q" $path (toString $d.unit) .) -}}
{{- end -}}
{{- $_ := set $decls . $d -}}
{{- end -}}
{{- $units := $alg.units | default dict -}}
{{- range $u, $ud := $units -}}
{{- /* 5. a configured unit must be enabled */ -}}
{{- if not (has $u $enabled) -}}
{{- fail (printf "algorithms.units.%s is set but %q is not in algorithms.enabled (%s); the runner refuses params for a unit that is not enabled" $u $u (join "," $enabled)) -}}
{{- end -}}
{{- if not (kindIs "map" $ud) -}}
{{- fail (printf "algorithms.units.%s must be a map holding only params, got %s" $u (kindOf $ud)) -}}
{{- end -}}
{{- /* 6. only params under a unit */ -}}
{{- range $k, $_ := $ud -}}
{{- if ne $k "params" -}}
{{- fail (printf "algorithms.units.%s.%s is not allowed: only algorithms.units.%s.params exists" $u $k $u) -}}
{{- end -}}
{{- end -}}
{{- $p := $ud.params | default dict -}}
{{- if not (kindIs "map" $p) -}}
{{- fail (printf "algorithms.units.%s.params must be a map, got %s" $u (kindOf $p)) -}}
{{- end -}}
{{- $declared := (index $decls $u).params | default dict -}}
{{- range $name, $v := $p -}}
{{- /* 7. only declared names */ -}}
{{- if not (hasKey $declared $name) -}}
{{- fail (printf "algorithms.units.%s.params.%s is not declared by unit %s; declared params: %s" $u $name $u (keys $declared | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $pd := index $declared $name -}}
{{- $key := printf "algorithms.units.%s.params.%s" $u $name -}}
{{- /* 8. type, by kindOf: --set gives int64, -f gives float64, --set-string and true give string and bool */ -}}
{{- $kind := kindOf $v -}}
{{- if eq $pd.type "number" -}}
{{- if not (has $kind (list "int" "int64" "float64")) -}}
{{- fail (printf "%s must be a number (declared type number), got %s %v" $key $kind $v) -}}
{{- end -}}
{{- else if eq $pd.type "integer" -}}
{{- if not (or (has $kind (list "int" "int64")) (and (eq $kind "float64") (eq (floor $v) $v))) -}}
{{- fail (printf "%s must be an integer (declared type integer), got %s %v" $key $kind $v) -}}
{{- end -}}
{{- else -}}
{{- fail (printf "%s: declared type %q is not supported by the chart check (number or integer)" $key (toString $pd.type)) -}}
{{- end -}}
{{- /* 9. declared bounds */ -}}
{{- if and (hasKey $pd "minimum") (lt (float64 $v) (float64 $pd.minimum)) -}}
{{- fail (printf "%s is %v, below the declared minimum %v" $key $v $pd.minimum) -}}
{{- end -}}
{{- if and (hasKey $pd "maximum") (gt (float64 $v) (float64 $pd.maximum)) -}}
{{- fail (printf "%s is %v, above the declared maximum %v" $key $v $pd.maximum) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /* 10. resources ceiling. A CEILING check, not a fit proof: the app's own
   measured use (92-125 Mi on a lab cluster) is not in the sum, so passing here does not
   mean the pod fits its limit. */ -}}
{{- $memSum := 0.0 -}}
{{- $cpuSum := 0.0 -}}
{{- range $enabled -}}
{{- $r := (index $decls .).resources | default dict -}}
{{- $memSum = addf $memSum ($r.memory_mi | default 0) -}}
{{- $cpuSum = addf $cpuSum ($r.cpu_m | default 0) -}}
{{- end -}}
{{- $lim := ($fe.resources | default dict).limits | default dict -}}
{{- if hasKey $lim "memory" -}}
{{- $m := toString $lim.memory -}}
{{- $limMi := 0.0 -}}
{{- if regexMatch "^[0-9]+Mi$" $m -}}
{{- $limMi = float64 (trimSuffix "Mi" $m) -}}
{{- else if regexMatch "^[0-9]+Gi$" $m -}}
{{- $limMi = mulf (float64 (trimSuffix "Gi" $m)) 1024.0 -}}
{{- else -}}
{{- fail (printf "faustEdge.resources.limits.memory %q has unsupported suffix %q; the algorithms ceiling check reads only Mi or Gi" $m (regexFind "[A-Za-z]*$" $m)) -}}
{{- end -}}
{{- if gt $memSum $limMi -}}
{{- fail (printf "enabled algorithm units declare %v Mi of memory, above faustEdge.resources.limits.memory %s" $memSum $m) -}}
{{- end -}}
{{- end -}}
{{- if hasKey $lim "cpu" -}}
{{- $c := toString $lim.cpu -}}
{{- $limM := 0.0 -}}
{{- if regexMatch "^[0-9]+m$" $c -}}
{{- $limM = float64 (trimSuffix "m" $c) -}}
{{- else if regexMatch "^[0-9]+(\\.[0-9]+)?$" $c -}}
{{- $limM = mulf (float64 $c) 1000.0 -}}
{{- else -}}
{{- fail (printf "faustEdge.resources.limits.cpu %q has unsupported suffix %q; the algorithms ceiling check reads only <n>m or plain cores" $c (regexFind "[A-Za-z]*$" $c)) -}}
{{- end -}}
{{- if gt $cpuSum $limM -}}
{{- fail (printf "enabled algorithm units declare %vm of cpu, above faustEdge.resources.limits.cpu %s" $cpuSum $c) -}}
{{- end -}}
{{- end -}}
{{- end }}
