{{/*
Expand the name of the chart.
*/}}
{{- define "oguide-crew.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "oguide-crew.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels. managed-by is .Release.Service because Helm and Flux's Helm controller
set it to "Helm" on apply whatever the chart renders.
*/}}
{{- define "oguide-crew.labels" -}}
helm.sh/chart: {{ include "oguide-crew.chart" . }}
{{ include "oguide-crew.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: {{ .Values.crew.name }}
{{- if .Chart.Version }}
kubemoot.ai/crew-version: {{ .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" | quote }}
{{- end }}
{{- end }}

{{/*
Selector labels. The MCPGateway selects this release's MCPServers by the instance label.
*/}}
{{- define "oguide-crew.selectorLabels" -}}
app.kubernetes.io/name: {{ include "oguide-crew.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels of an Agent: the common labels, the crew, and the agent's role.
Usage: include "oguide-crew.agentLabels" (dict "root" $ "role" "tooler")
*/}}
{{- define "oguide-crew.agentLabels" -}}
{{ include "oguide-crew.labels" .root }}
kubemoot.ai/crew: {{ .root.Values.crew.name }}
kubemoot.ai/role: {{ .role }}
{{- end }}

{{/*
Resolve an image reference. A bare "name:tag" or "name@sha256:..." is prefixed with
global.imageRegistry; a reference that already names a registry (contains "/") is used
as-is.
Usage: include "oguide-crew.image" (dict "root" $ "image" .Values.mcpServers.x.image)
*/}}
{{- define "oguide-crew.image" -}}
{{- if contains "/" .image -}}
{{- .image -}}
{{- else -}}
{{- printf "%s/%s" .root.Values.global.imageRegistry .image -}}
{{- end -}}
{{- end }}

{{/*
The name of the Secret that holds the O'Reilly subscriber key, after checking the auth
values. The chart names the Secret and never holds a key.
*/}}
{{- define "oguide-crew.authSecretName" -}}
{{- $auth := .Values.oreilly.auth -}}
{{- if not (has $auth.secretKey (list "bearer-token" "api-key")) -}}
{{- fail (printf "oreilly.auth.secretKey must be bearer-token or api-key, the key names the operator reads; got %q" $auth.secretKey) -}}
{{- end -}}
{{- if and $auth.header (ne $auth.secretKey "api-key") -}}
{{- fail "oreilly.auth.header applies only with oreilly.auth.secretKey api-key; a bearer-token is always sent as Authorization: Bearer" -}}
{{- end -}}
{{- required "oreilly.auth.secretName is required: the Secret that holds your O'Reilly subscriber key" $auth.secretName -}}
{{- end }}

{{/*
The triage prompt of an analyst, an agent that reasons over the results the search
agents gathered and runs no catalog search. One definition for every analyst of the crew.
*/}}
{{- define "oguide-crew.analystTriagePrompt" -}}
DEFINE COMPONENT analyst-triage
DESCRIPTION You were already selected as a relevant reviewer; reason and contribute unless this clearly belongs to another domain.

You are '{agent_name}': {agent_description}
Coordinator-flagged areas: {advisory_technologies}

ASSERT you are a reasoning analyst with NO catalog search tool; you reason over the results the search agents already gathered.
ASSERT the coordinator already selected you as a relevant reviewer for this question.
WHEN the question asks to rank, compare, dedupe, order, or plan over O'Reilly material THEN reply CONTRIBUTE and reason over the gathered results
WHEN the question has nothing to do with O'Reilly library material THEN reply NOTHING_TO_ADD
ASSERT default to CONTRIBUTE when in doubt. NEVER invent facts.
ALWAYS reply with EXACTLY one token: CONTRIBUTE or NOTHING_TO_ADD. No explanation.
{{- end -}}

{{/*
spec.egress for one MCPServer or Agent, copied verbatim from the egress value:
egress.mcpServers.<name> or egress.agents.<name>, keyed by the resource's rendered
metadata.name. Call as: include "oguide-crew.egress" (dict "root" $ "kind" "agents" "name" "<name>").
Renders nothing (not even a blank line) when no entry matches, so a chart with the
default values renders exactly as it did before the setting existed. Rendered directly
after "spec:" at a two-space indent, so it starts with a newline.
*/}}
{{- define "oguide-crew.egress" -}}
{{- $egress := default dict .root.Values.egress -}}
{{- $entry := get (default dict (get $egress .kind)) .name -}}
{{- if $entry }}
  egress:
    {{- toYaml $entry | nindent 4 }}
{{- end }}
{{- end }}
