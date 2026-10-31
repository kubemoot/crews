#!/usr/bin/env bash
# Render tests for the tools the pilot crew's prompts name: the shared modules list an
# agent's tools with the ${agent.tools} placeholder instead of naming tools, and no agent's
# PromptModules name a tool the agent does not have, with the optional tools switched on and
# off (kubernetesAccess.secretRead and writeAccess, compute.workspaceQuery, mcpServers.proxmox).
# It also pins the Kubernetes MCPServer's toolOverrides, which steer list calls to the narrow
# forms the server supports. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-prompt-tools.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
checker="$chart/../scripts/check-module-tools.sh"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}
render() { helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@"; }
module() { yq -N "select(.kind == \"PromptModule\" and .metadata.name == \"$1\") | .spec.content" <<<"$out"; }
mentions() { grep -c -F -- "$2" <<<"$(module "$1")" || true; }

out="$(render)"

# The modules that list an agent's tools use the placeholder, which Helm leaves as written.
for name in tooler-discipline analyst-review-protocol compute-system scheduler-advisor-system; do
  # shellcheck disable=SC2016
  check "$name lists the agent's tools with the placeholder" 1 "$(mentions "$name" '${agent.tools}')"
done

# The shared modules name no tool: each agent's own tool list comes from the placeholder.
vocab='resources_list|resources_get|pods_list|pods_list_in_namespace|list_api_resources|list_metrics|get_targets|get_metric_metadata|execute_code|artifact_head|artifact_jq|workspace_query'
for name in tooler-discipline analyst-review-protocol compute-system discussion-protocol response-style advisory-prompt coordinator-decision-logic synthesis-prompt; do
  check "$name names no agent's tool" 0 "$(module "$name" | grep -cEw "$vocab" || true)"
done

# A module that survives an older runtime leaving the placeholder in place: the token sits at
# the end of a sentence, never inside a call, so the text around it still reads.
check "no module puts the placeholder inside a call" 0 \
  "$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out" | grep -cE '\([^)]*\$\{agent\.tools\}'|| true)"

# No agent's modules name a tool the agent lacks, whichever optional tools are on.
all_on=(--set kubernetesAccess.secretRead=true --set kubernetesAccess.writeAccess=true --set compute.workspaceQuery=true --set mcpServers.proxmox.enabled=true --set mcpServers.proxmox.image=x)
export VOCAB_ARGS="${all_on[*]}"
check "default values: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" >/dev/null 2>&1; echo $?)"
check "optional tools on: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" "${all_on[@]}" >/dev/null 2>&1; echo $?)"
check "secretRead only: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set kubernetesAccess.secretRead=true >/dev/null 2>&1; echo $?)"
check "proxmox only: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set mcpServers.proxmox.enabled=true --set mcpServers.proxmox.image=x >/dev/null 2>&1; echo $?)"
check "workspaceQuery only: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set compute.workspaceQuery=true >/dev/null 2>&1; echo $?)"

# The compute module is the same text whether or not the workspace_query tool is offered.
a="$(render | yq -N 'select(.kind == "PromptModule" and .metadata.name == "compute-system") | .spec.content')"
b="$(render --set compute.workspaceQuery=true | yq -N 'select(.kind == "PromptModule" and .metadata.name == "compute-system") | .spec.content')"
check "compute-system does not differ between the workspace_query arms" "$a" "$b"

# The Kubernetes server's tool overrides: lists get narrowed on the server, so the descriptions
# agents see name the selectors the server accepts. The server has no option for fewer
# columns, so the command carries no --list-output flag (its yaml form is larger than the table).
k8s_mcp() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"t-kubernetes-mcp\") | $1" <<<"$2"; }
override() { k8s_mcp ".spec.toolOverrides[] | select(.name == \"$1\") | $2" "$out"; }
has() { if grep -q -F -- "$2" <<<"$1"; then echo yes; else echo no; fi; }
names() { k8s_mcp '.spec.toolOverrides[].name' "$1" | sort | tr '\n' ' ' | sed 's/ $//'; }
with_secrets="$(render --set kubernetesAccess.secretRead=true)"
check "overrides: the list and top tools" "events_list pods_list pods_list_in_namespace pods_top resources_list" "$(names "$out")"
check "overrides: helm_list is added with secretRead" "events_list helm_list pods_list pods_list_in_namespace pods_top resources_list" "$(names "$with_secrets")"
check "overrides: helm_list text kept" yes \
  "$(has "$(k8s_mcp '.spec.toolOverrides[] | select(.name == "helm_list") | .description' "$with_secrets")" "only the server's own namespace")"
check "overrides: the server gets no --list-output flag" 0 "$(k8s_mcp '.spec.command[]' "$out" | grep -c -- '--list-output' || true)"
check "overrides: resources_list namespace says all and * are not wildcards" yes \
  "$(has "$(override resources_list .parameters.namespace.description)" 'all and * are not wildcards')"
check "overrides: pods_list_in_namespace namespace says it is not a wildcard" yes \
  "$(has "$(override pods_list_in_namespace .parameters.namespace.description)" 'Not a wildcard')"
check "overrides: resources_list fieldSelector names the Node fields" yes \
  "$(has "$(override resources_list .parameters.fieldSelector.description)" 'Node: metadata.name, spec.unschedulable')"
check "overrides: resources_list labelSelector gives the label syntax" yes \
  "$(has "$(override resources_list .parameters.labelSelector.description)" 'key in (a,b)')"
check "overrides: pods_list fieldSelector says phase Running does not narrow" yes \
  "$(has "$(override pods_list .parameters.fieldSelector.description)" 'status.phase=Running matches nearly every pod')"
check "overrides: pods_list fieldSelector names spec.nodeName" yes \
  "$(has "$(override pods_list .parameters.fieldSelector.description)" 'spec.nodeName=<node>')"
check "overrides: events_list fieldSelector gives type=Warning" yes \
  "$(has "$(override events_list .parameters.fieldSelector.description)" 'type=Warning')"
check "overrides: pods_top says one row per container" yes "$(has "$(override pods_top .description)" 'one row per container')"
check "overrides: pods_top all_namespaces says it defaults to true" yes \
  "$(has "$(override pods_top .parameters.all_namespaces.description)" 'Defaults to true')"
# One pod field list serves every pod tool, so the three descriptions cannot drift apart.
pod_fields="$(override pods_list .parameters.fieldSelector.description | grep -o 'Accepted fields: [^;]*')"
check "overrides: pods_list_in_namespace fieldSelector lists the same pod fields" "$pod_fields" \
  "$(override pods_list_in_namespace .parameters.fieldSelector.description | grep -o 'Accepted fields: [^;]*')"
check "overrides: resources_list fieldSelector lists the same pod fields" yes \
  "$(has "$(override resources_list .parameters.fieldSelector.description)" "Pod: ${pod_fields#Accepted fields: }.")"
# CRD limits: a description is at most 4000 characters, a parameter description at most 2000.
check "overrides: no description over 4000 characters" 0 \
  "$(k8s_mcp '.spec.toolOverrides[].description | length' "$with_secrets" | awk '$1 > 4000' | wc -l | tr -d ' ')"
check "overrides: no parameter description over 2000 characters" 0 \
  "$(k8s_mcp '.spec.toolOverrides[].parameters[].description | length' "$with_secrets" | awk '$1 > 2000' | wc -l | tr -d ' ')"
# An override names a tool some agent has, so none describes a tool no agent can call.
agent_tools="$(yq -N 'select(.kind == "Agent") | .spec.enabledTools // [] | .[]' <<<"$out" | sort -u)"
for tool in $(k8s_mcp '.spec.toolOverrides[].name' "$out"); do
  check "overrides: $tool is enabled on an agent" yes "$(has "$agent_tools" "$tool")"
done

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
