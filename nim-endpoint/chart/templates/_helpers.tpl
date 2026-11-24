{{- define "nim.model" -}}
{{- $m := index .Values.models .Values.model -}}
{{- if not $m }}{{ fail (printf "unknown model %q" .Values.model) }}{{ end -}}
{{- toYaml $m -}}
{{- end -}}
