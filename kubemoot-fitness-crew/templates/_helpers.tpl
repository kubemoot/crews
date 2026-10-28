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
metadata.name. Call as: include "kubemoot-fitness-crew.egress" (dict "root" $ "kind" "agents" "name" "<name>").
Renders nothing (not even a blank line) when no entry matches, so a chart with the
default values renders exactly as it did before the setting existed. Rendered directly
after "spec:" at a two-space indent, so it starts with a newline.
*/}}
{{- define "kubemoot-fitness-crew.egress" -}}
{{- $egress := default dict .root.Values.egress -}}
{{- $entry := get (default dict (get $egress .kind)) .name -}}
{{- if $entry }}
  egress:
    {{- toYaml $entry | nindent 4 }}
{{- end }}
{{- end }}
