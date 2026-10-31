{{- /*
==============================================================================
Element state declarations (values: elementState).

Three helpers, all reading .Values.elementState:
  openddil.elementState.validate   fails the render on a bad declaration
  openddil.elementState.stateJson  ELEMENT_STATE_JSON for the tier projectors
  openddil.elementState.bandsJson  ELEMENT_BANDS_JSON for faust-edge

Validate is called from templates/element-state-guard.yaml, which always
renders, so a bad declaration is refused whether or not a consumer is on.
==============================================================================
*/ -}}

{{- define "openddil.elementState.validate" -}}
{{- $es := .Values.elementState | default dict -}}
{{- $kinds := $es.kinds | default dict -}}
{{- $dest := $es.destinations | default dict -}}
{{- /* Refusal 3: upstream never carries a value window. */ -}}
{{- $up := $dest.upstream | default dict -}}
{{- if hasKey $up "valueWindowS" -}}
{{- fail "elementState.destinations.upstream.valueWindowS is not allowed: element rows never cross above the owning tier, so upstream has no value window (only valueWindow: none)" -}}
{{- end -}}
{{- if and (hasKey $up "valueWindow") (ne (toString $up.valueWindow) "none") -}}
{{- fail (printf "elementState.destinations.upstream.valueWindow must be none, got %q" (toString $up.valueWindow)) -}}
{{- end -}}
{{- /* Every declared field: a class, windows only on value fields, value fields measured. */ -}}
{{- $sigs := dict -}}
{{- range $profile, $layers := $kinds -}}
{{- range $layer, $fields := $layers -}}
{{- $sig := dict -}}
{{- range $field, $spec := $fields -}}
{{- if not (kindIs "map" $spec) -}}
{{- fail (printf "elementState.kinds.%s.%q.%s must be a map with a class" $profile $layer $field) -}}
{{- end -}}
{{- $class := toString (index $spec "class" | default "") -}}
{{- if not (has $class (list "value" "band" "transition")) -}}
{{- fail (printf "elementState.kinds.%s.%q.%s has no valid class (got %q; want value, band or transition)" $profile $layer $field $class) -}}
{{- end -}}
{{- if ne $class "value" -}}
{{- range $key, $_ := $spec -}}
{{- if or (hasPrefix "valueWindow" $key) (hasPrefix "window" $key) -}}
{{- fail (printf "elementState.kinds.%s.%q.%s: window key %q is not allowed on a %s field" $profile $layer $field $key $class) -}}
{{- end -}}
{{- end -}}
{{- else -}}
{{- $db := float64 0 -}}
{{- if hasKey $spec "deadband" -}}{{- $db = float64 $spec.deadband -}}{{- end -}}
{{- if le $db (float64 0) -}}
{{- fail (printf "elementState.kinds.%s.%q.%s: a value field needs a deadband greater than 0" $profile $layer $field) -}}
{{- end -}}
{{- if eq (toString (index $spec "measured" | default "")) "" -}}
{{- fail (printf "elementState.kinds.%s.%q.%s: a value field needs a non-empty measured note" $profile $layer $field) -}}
{{- end -}}
{{- $_ := set $sig $field $db -}}
{{- end -}}
{{- end -}}
{{- /* Refusal 6: the projector keys deadbands by layer name alone. */ -}}
{{- $sigJson := toJson $sig -}}
{{- if hasKey $sigs $layer -}}
{{- $prev := index $sigs $layer -}}
{{- if ne $prev.sig $sigJson -}}
{{- fail (printf "elementState.kinds: layer %q has different value-field deadbands in profiles %s and %s (%s vs %s); the projector keys deadbands by layer name" $layer $prev.profile $profile $prev.sig $sigJson) -}}
{{- end -}}
{{- else -}}
{{- $_ := set $sigs $layer (dict "profile" $profile "sig" $sigJson) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- /* Refusals 1 and 4: coverage of the profiles the sim runs, and the publish tier. */ -}}
{{- if .Values.logisticsSim.enabled -}}
{{- $cfg := .Values.logisticsSim.config | default dict -}}
{{- $pubTier := toString ($cfg.element_publish_tier | default "") -}}
{{- if or (eq $pubTier "") (eq $pubTier "hq") -}}
{{- fail (printf "logisticsSim.config.element_publish_tier must be edge (got %q): element rows never cross above the owning tier" (default "absent" $pubTier)) -}}
{{- end -}}
{{- range $p := ($cfg.asset_profiles | default list) -}}
{{- $pk := index $kinds $p.name | default dict -}}
{{- range $l := ($p.layers | default list) -}}
{{- if not (hasKey $pk $l.name) -}}
{{- fail (printf "elementState.kinds.%s has no entry for layer %q (declared in logisticsSim.config.asset_profiles)" $p.name $l.name) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- end -}}

{{- define "openddil.elementState.stateJson" -}}
{{- $es := .Values.elementState -}}
{{- $db := dict -}}
{{- range $profile, $layers := $es.kinds -}}
{{- range $layer, $fields := $layers -}}
{{- $d := dict -}}
{{- range $field, $spec := $fields -}}
{{- if eq $spec.class "value" -}}{{- $_ := set $d $field (float64 $spec.deadband) -}}{{- end -}}
{{- end -}}
{{- $_ := set $db $layer $d -}}
{{- end -}}
{{- end -}}
{{- $h := $es.healthBands -}}
{{- dict "deadbands" $db "bands" (dict "health" (dict "limits" $h.limits "names" $h.names "hysteresis" $h.hysteresis)) "heartbeat_s" $es.heartbeatS | toJson -}}
{{- end -}}

{{- define "openddil.elementState.bandsJson" -}}
{{- $h := .Values.elementState.healthBands -}}
{{- dict "health" (dict "limits" $h.limits "names" $h.names "hysteresis" $h.hysteresis "severity" $h.severity) | toJson -}}
{{- end -}}
