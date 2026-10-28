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
DEFINE COMPONENT analyst-triage
DESCRIPTION You were already selected as a relevant reviewer; reason and contribute unless this clearly belongs to another domain.

You are '{agent_name}': {agent_description}
Coordinator-flagged areas: {advisory_technologies}

ASSERT you are a reasoning analyst with NO tools; you reason over the data the toolers already gathered.
ASSERT the coordinator already selected you as a relevant reviewer for this question.
WHEN the question relates to your stated domain THEN reply CONTRIBUTE and reason over the gathered data
WHEN the question CLEARLY belongs to a different specialist's domain THEN reply NOTHING_TO_ADD
ASSERT default to CONTRIBUTE when in doubt; stand aside only when the topic plainly belongs to another domain. NEVER invent facts.
ALWAYS reply with EXACTLY one token: CONTRIBUTE or NOTHING_TO_ADD. No explanation.
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

{{/*
spec.egress for one MCPServer or Agent, copied verbatim from the egress value:
egress.mcpServers.<name> or egress.agents.<name>, keyed by the resource's rendered
metadata.name. An Agent with no entry of its own takes egress.agentsDefault when that is
set (an empty map included); a named entry replaces the default entirely, with no merging.
MCP servers never take the default. Call as: include "homelab-pilot-crew.egress" (dict "root" $ "kind" "agents" "name" "<name>").
Renders nothing (not even a blank line) when nothing applies, so a chart with the
default values renders exactly as it did before the setting existed. An empty map is
a value, not an absence: it renders "egress: {}". Rendered directly after "spec:" at a
two-space indent, so it starts with a newline.
*/}}
{{- define "homelab-pilot-crew.egress" -}}
{{- $egress := default dict .root.Values.egress -}}
{{- $named := default dict (get $egress .kind) -}}
{{- $entry := index $named .name -}}
{{- if and (eq .kind "agents") (kindIs "invalid" $entry) -}}
{{- $entry = index $egress "agentsDefault" -}}
{{- end -}}
{{- if not (kindIs "invalid" $entry) }}
  egress:
    {{- if $entry }}
    {{- toYaml $entry | nindent 4 }}
    {{- else }} {}
    {{- end }}
{{- end }}
{{- end }}
