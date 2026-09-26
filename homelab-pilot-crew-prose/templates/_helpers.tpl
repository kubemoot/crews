{{/*
Expand the name of the chart.
*/}}
{{- define "homelab-pilot-crew.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "homelab-pilot-crew.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "homelab-pilot-crew.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "homelab-pilot-crew.labels" -}}
helm.sh/chart: {{ include "homelab-pilot-crew.chart" . }}
{{ include "homelab-pilot-crew.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
{{/*
  managed-by stays as `.Release.Service` (renders to "Helm") because Helm and
  Flux's Helm controller enforce this label on apply — any other value gets
  overridden to "Helm" regardless of what the chart template renders. Tested
  empirically: setting `kubemoot` here had no effect on the deployed labels.
  The runtime owner concept (Kubemoot operator reconciles Crew behavior) is
  captured by the `kubemoot.ai` API group of the CR itself; no separate label
  needed.
*/}}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: homelab-pilot
{{- if .Chart.Version }}
kubemoot.ai/crew-version: {{ .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "homelab-pilot-crew.selectorLabels" -}}
app.kubernetes.io/name: {{ include "homelab-pilot-crew.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "homelab-pilot-crew.analystTriagePrompt" -}}
You are '{agent_name}': {agent_description}. The coordinator flagged these areas: {advisory_technologies}.

You are a reasoning analyst with no tools of your own; you reason over the data the toolers already gathered, and the coordinator has already selected you as a relevant reviewer. Reply CONTRIBUTE and reason over the gathered data whenever the question relates to your domain. Only reply NOTHING_TO_ADD if the question clearly belongs to a different specialist's domain. When in doubt, contribute, and never invent facts. Reply with exactly one word, CONTRIBUTE or NOTHING_TO_ADD, and nothing else.
{{- end -}}

{{/*
Resolve an image reference. A bare "name:tag" or "name@sha256:..." is prefixed with
global.imageRegistry; a reference that already names a registry (contains "/") is used
as-is, so third-party images and homelab-built images pass through unchanged.
Usage: include "homelab-pilot-crew.image" (dict "root" $ "image" .Values.mcpServers.x.image)
*/}}
{{- define "homelab-pilot-crew.image" -}}
{{- if contains "/" .image -}}
{{- .image -}}
{{- else -}}
{{- printf "%s/%s" .root.Values.global.imageRegistry .image -}}
{{- end -}}
{{- end }}
