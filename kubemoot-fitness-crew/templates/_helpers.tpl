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

{{/*
spec.egress for one MCPServer or Agent, copied verbatim from the egress value:
egress.mcpServers.<name> or egress.agents.<name>, keyed by the resource's rendered
metadata.name. An Agent with no entry of its own takes egress.agentsDefault when that is
set (an empty map included); a named entry replaces the default entirely, with no merging.
MCP servers never take the default. Call as: include "kubemoot-fitness-crew.egress" (dict "root" $ "kind" "agents" "name" "<name>").
Renders nothing (not even a blank line) when nothing applies, so a chart with the
default values renders exactly as it did before the setting existed. An empty map is
a value, not an absence: it renders "egress: {}". Rendered directly after "spec:" at a
two-space indent, so it starts with a newline.
*/}}
{{- define "kubemoot-fitness-crew.egress" -}}
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
