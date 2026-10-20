{{/*
Expand the name of the chart.
*/}}
{{- define "ocrew-crew.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "ocrew-crew.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels. managed-by is .Release.Service because Helm and Flux's Helm controller
set it to "Helm" on apply whatever the chart renders.
*/}}
{{- define "ocrew-crew.labels" -}}
helm.sh/chart: {{ include "ocrew-crew.chart" . }}
{{ include "ocrew-crew.selectorLabels" . }}
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
{{- define "ocrew-crew.selectorLabels" -}}
app.kubernetes.io/name: {{ include "ocrew-crew.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Labels of an Agent: the common labels, the crew, and the agent's role.
Usage: include "ocrew-crew.agentLabels" (dict "root" $ "role" "tooler")
*/}}
{{- define "ocrew-crew.agentLabels" -}}
{{ include "ocrew-crew.labels" .root }}
kubemoot.ai/crew: {{ .root.Values.crew.name }}
kubemoot.ai/role: {{ .role }}
{{- end }}

{{/*
Resolve an image reference. A bare "name:tag" or "name@sha256:..." is prefixed with
global.imageRegistry; a reference that already names a registry (contains "/") is used
as-is.
Usage: include "ocrew-crew.image" (dict "root" $ "image" .Values.mcpServers.x.image)
*/}}
{{- define "ocrew-crew.image" -}}
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
{{- define "ocrew-crew.authSecretName" -}}
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
{{- define "ocrew-crew.analystTriagePrompt" -}}
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
