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

{{/*
spec.ragSources for one Agent: every entry of ragSources.sources that lists the agent under
its agents map, in the order the sources are declared. The map is keyed by the agent's
rendered metadata.name; its value may set topK (at least 1) and priority, both numbers.
An entry set to null (for example --set ragSources.sources[0].agents.x=null) unbinds that
agent; {} binds it with the CRD defaults. Renders nothing when
ragSources.enabled is false or no source lists the agent, so a crew without RAG renders
agents with no ragSources and the runtime queries no endpoint. Call as:
include "homelab-pilot-crew.ragSources" (dict "root" $ "name" "<name>").
Rendered directly after "spec:" (and after the egress helper) at a two-space indent, so
it starts with a newline.
*/}}
{{- define "homelab-pilot-crew.ragSources" -}}
{{- $agent := .name -}}
{{- $refs := list -}}
{{- if .root.Values.ragSources.enabled -}}
{{- range .root.Values.ragSources.sources -}}
{{- $src := .name -}}
{{- $use := index (default dict .agents) $agent -}}
{{- if not (kindIs "invalid" $use) -}}
{{- $ref := dict "name" $src -}}
{{- range $k := list "topK" "priority" -}}
{{- if hasKey $use $k -}}
{{- $v := index $use $k -}}
{{- if not (or (kindIs "float64" $v) (kindIs "int64" $v) (kindIs "int" $v)) -}}
{{- fail (printf "ragSources.sources[%s].agents.%s.%s must be a number, got %v" $src $agent $k $v) -}}
{{- end -}}
{{- if and (eq $k "topK") (lt (float64 $v) 1.0) -}}
{{- fail (printf "ragSources.sources[%s].agents.%s.topK must be at least 1" $src $agent) -}}
{{- end -}}
{{- $_ := set $ref $k $v -}}
{{- end -}}
{{- end -}}
{{- $refs = append $refs $ref -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- if $refs }}
  ragSources:
    {{- toYaml $refs | nindent 4 }}
{{- end }}
{{- end }}

{{/* Fails the render unless the value is a list of non-empty strings (the namespaces of a
tier). Arguments: path (for the message) and value. A string such as "a,b", a map, or an empty
entry would otherwise bind in the wrong places or, for an empty entry, cluster-wide. */}}
{{- define "homelab-pilot-crew.namespaceList" -}}
{{- if not (kindIs "slice" .value) -}}
{{- fail (printf "%s must be a list of namespaces, for example [kube-system, monitoring]" .path) -}}
{{- end -}}
{{- range .value -}}
{{- if or (not (kindIs "string" .)) (eq . "") -}}
{{- fail (printf "%s must hold only non-empty namespace names" $.path) -}}
{{- end -}}
{{- end -}}
{{- end }}

{{/* The namespaces and tiers of Kubernetes access this release grants (values.yaml,
kubernetesAccess). Each helper renders "true" when its tier is on and nothing when it is off,
so it works as a condition. A boolean where a tier now has a list of namespaces fails the
render with the new shape instead of a template error; a boolean false, the old default, is
off, so values written for the old shape still render. A tier set to null is off. */}}
{{- define "homelab-pilot-crew.accessTier" -}}
{{- $tier := index .root.Values.kubernetesAccess .name | default dict -}}
{{- if and (kindIs "bool" $tier) $tier -}}
{{- fail (printf "kubernetesAccess.%s is now a list of namespaces: kubernetesAccess.%s.namespaces. Set the namespaces that get the access; see the chart README, Cluster permissions." .name .name) -}}
{{- end -}}
{{- if kindIs "bool" $tier }}{{ $tier = dict }}{{ end -}}
{{- include "homelab-pilot-crew.namespaceList" (dict "path" (printf "kubernetesAccess.%s.namespaces" .name) "value" ($tier.namespaces | default list)) -}}
{{- if $tier.namespaces }}true{{ end -}}
{{- end }}

{{/* "true" when the Secret read tier names at least one namespace. */}}
{{- define "homelab-pilot-crew.secretReadOn" -}}
{{- include "homelab-pilot-crew.accessTier" (dict "root" . "name" "secretRead") -}}
{{- end }}

{{/* "true" when the write tier names at least one namespace. It registers the write tools
and takes the Kubernetes MCP servers out of read-only mode. */}}
{{- define "homelab-pilot-crew.writeOn" -}}
{{- include "homelab-pilot-crew.accessTier" (dict "root" . "name" "write") -}}
{{- end }}

{{/* One binding of a ClusterRole to a ServiceAccount of this release. A RoleBinding grants the
role in its namespace only; a ClusterRoleBinding, asked for only with cluster set to true,
grants it everywhere. A missing namespace never turns into a ClusterRoleBinding: it fails the
render. Creating the binding is the consent: whoever installs the chart needs the right to
create it in that namespace. Arguments: root, role, account (the ServiceAccount name), and
either namespace or cluster. */}}
{{- define "homelab-pilot-crew.binding" -}}
{{- if and (not .cluster) (not .namespace) -}}
{{- fail (printf "the binding of %s needs a namespace" .role) -}}
{{- end -}}
apiVersion: rbac.authorization.k8s.io/v1
kind: {{ if .cluster }}ClusterRoleBinding{{ else }}RoleBinding{{ end }}
metadata:
  name: {{ .role }}
  {{- if not .cluster }}
  namespace: {{ .namespace }}
  {{- end }}
  labels:
    {{- include "homelab-pilot-crew.labels" .root | nindent 4 }}
subjects:
  - kind: ServiceAccount
    name: {{ .account }}
    namespace: {{ .root.Release.Namespace }}
roleRef:
  kind: ClusterRole
  name: {{ .role }}
  apiGroup: rbac.authorization.k8s.io
{{- end }}

{{/* The bindings of one role to one account for a tier: one RoleBinding in each listed
namespace, or when clusterWide is true one ClusterRoleBinding instead. Arguments: root, role,
account, namespaces, path (the values path, for messages), and optionally clusterWide. Renders
nothing for an empty list that is not clusterWide. */}}
{{- define "homelab-pilot-crew.tierBindings" -}}
{{- include "homelab-pilot-crew.namespaceList" (dict "path" .path "value" (.namespaces | default list)) -}}
{{- if .clusterWide }}
---
{{ include "homelab-pilot-crew.binding" (dict "root" .root "role" .role "account" .account "cluster" true) }}
{{- else }}
{{- range uniq (.namespaces | default list) }}
---
{{ include "homelab-pilot-crew.binding" (dict "root" $.root "role" $.role "account" $.account "namespace" .) }}
{{- end }}
{{- end }}
{{- end }}
