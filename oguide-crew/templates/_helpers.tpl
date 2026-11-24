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
metadata.name. An Agent with no entry of its own takes egress.agentsDefault when that is
set (an empty map included); a named entry replaces the default entirely, with no merging.
MCP servers never take the default. Call as: include "oguide-crew.egress" (dict "root" $ "kind" "agents" "name" "<name>").
Renders nothing (not even a blank line) when nothing applies, so a chart with the
default values renders exactly as it did before the setting existed. An empty map is
a value, not an absence: it renders "egress: {}". Rendered directly after "spec:" at a
two-space indent, so it starts with a newline.
*/}}
{{- define "oguide-crew.egress" -}}
{{- $egress := default dict .root.Values.egress -}}
{{- $named := default dict (get $egress .kind) -}}
{{- $entry := index $named .name -}}
{{- if and (eq .name "workspace-mcp") (kindIs "invalid" $entry) -}}
{{- $entry = index $named "artifact-readops-mcp" -}}
{{- end -}}
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

{{/*
The agent's declared workspace access (Agent.spec.workspace.access): the discussion's
shared scratch data. Renders nothing when workspace.declareAccess is false, so an agent
then behaves as it did before access was declared.
Usage: discussRole: tooler{{ include "oguide-crew.workspaceAccess" (dict "root" $ "access" "write") }}
*/}}
{{- define "oguide-crew.workspaceAccess" -}}
{{- if .root.Values.workspace.declareAccess }}
  workspace:
    access: {{ .access }}
{{- end }}
{{- end }}

{{/*
Denies workspace tools a chart switch turned off. A declared access grants every workspace
tool it allows unless disabledTools names it, so a switch that is off must name its tools.
Renders nothing when the switch is on or workspace.declareAccess is false (no grant is made then).
Usage: enabledTools: [...]{{ include "oguide-crew.workspaceDisabled" (dict "root" $ "on" .Values.compute.workspaceQuery "tools" (list "workspace_query")) }}
*/}}
{{- define "oguide-crew.workspaceDisabled" -}}
{{- if and .root.Values.workspace.declareAccess (not .on) }}
  disabledTools: [{{ join ", " .tools }}]
{{- end }}
{{- end }}

{{/* Warning for the pre-workspace egress key that still applies for one release. */}}
{{- define "oguide-crew.workspaceDeprecations" -}}
{{- if hasKey .Values.mcpServers "artifactReadOps" }}
DEPRECATED: mcpServers.artifactReadOps is renamed mcpServers.workspace (queryMemory, resources). The old value still applies for one release and is then removed.
{{- end }}
{{- if hasKey (default dict (default dict .Values.egress).mcpServers) "artifact-readops-mcp" }}
DEPRECATED: egress.mcpServers.artifact-readops-mcp is renamed egress.mcpServers.workspace-mcp. The old key still applies for one release.
{{- end }}
{{- end }}

{{/* The MCPServer's spec.smokeInputs, read from mcp-smoke/<name>.yaml (run through tpl) and
rendered at the spec's indent. Renders nothing when the server has no file. The tool smoke
that runs first in every CrewFitnessSuite calls each listed tool with its input. */}}
{{- define "oguide-crew.smokeInputs" -}}
{{- $file := .root.Files.Get (printf "mcp-smoke/%s.yaml" .name) -}}
{{- if $file -}}
{{- with (tpl $file .root | fromYaml).smokeInputs }}
  smokeInputs:
    {{- toYaml . | nindent 4 }}
{{- end -}}
{{- end -}}
{{- end }}

{{/*
Resolve a Kubemoot image reference. A bare "name:tag" is prefixed with global.imageRegistry;
a reference that already names a registry (contains "/") is used as written.
Usage: include "oguide-crew.image" (dict "root" $ "image" .Values.mcpServers.codeSandbox.image)
An image this crew's repository builds takes global.crewImageRegistry instead:
include "oguide-crew.image" (dict "root" $ "image" .Values.mcpServers.search.go.image "registry" .Values.global.crewImageRegistry)
*/}}
{{- define "oguide-crew.image" -}}
{{- if contains "/" .image -}}
{{- .image -}}
{{- else -}}
{{- printf "%s/%s" (default .root.Values.global.imageRegistry .registry) .image -}}
{{- end -}}
{{- end }}

{{/*
"true" when the Expert tools are offered: with Expert Intelligence on, and with per-person
O'Reilly access on (the per-person server's primary endpoint is the Expert MCP). Empty
otherwise. Usage: if include "oguide-crew.expertOn" $
*/}}
{{- define "oguide-crew.expertOn" -}}
{{- if or .Values.oreilly.expert.enabled .Values.perPerson.enabled -}}true{{- end -}}
{{- end }}

{{/*
The Crew's discussion access with the per-person O'Reilly verifier added. Off, the value as
given. On, serviceTokens holds one entry (the verifier the per-person MCPServer names) and
hashKeySecretRef names the installer's Secret; the chart never holds a key.
*/}}
{{- define "oguide-crew.access" -}}
{{- $access := deepCopy (.Values.crew.discussion.access | default dict) -}}
{{- if .Values.perPerson.enabled -}}
{{- $p := .Values.perPerson -}}
{{- $v := dict "name" $p.verifier.name "verifyURL" (required "perPerson.verifier.verifyURL is required" $p.verifier.verifyURL) "verifyMethod" "McpInitialize" "subjectClaim" (required "perPerson.verifier.subjectClaim is required" $p.verifier.subjectClaim) "maxCacheSeconds" ($p.verifier.maxCacheSeconds | int) "passToTools" true -}}
{{- with $p.verifier.audiences }}{{- $_ := set $v "audiences" . }}{{- end -}}
{{- $_ := set $access "serviceTokens" (list $v) -}}
{{- $_ := set $access "hashKeySecretRef" (dict "name" (required "perPerson.hashKeySecret.name is required: the Secret you create that holds the install's hash key" $p.hashKeySecret.name) "key" $p.hashKeySecret.secretKey) -}}
{{- end -}}
{{- if $access -}}{{- toYaml $access -}}{{- end -}}
{{- end }}
