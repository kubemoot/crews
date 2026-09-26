{{/*
Chart name.
*/}}
{{- define "kubemoot-fitness-crew.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Chart name + version label value.
*/}}
{{- define "kubemoot-fitness-crew.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels. Includes kubemoot.ai/crew so the operator's namespace controller,
resume sync, and scheduler group these resources by crew.
*/}}
{{- define "kubemoot-fitness-crew.labels" -}}
helm.sh/chart: {{ include "kubemoot-fitness-crew.chart" . }}
app.kubernetes.io/name: {{ include "kubemoot-fitness-crew.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
kubemoot.ai/crew: {{ .Values.crew.name }}
{{- end }}
