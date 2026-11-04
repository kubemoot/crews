#!/usr/bin/env bash
# Render tests for the tools the pilot crew's prompts name: the shared modules list an
# agent's tools with the ${agent.tools} placeholder instead of naming tools, and no agent's
# PromptModules name a tool the agent does not have, with the optional tools switched on and
# off (kubernetesAccess.secretRead and writeAccess, compute.workspaceQuery, mcpServers.proxmox).
# It also pins the MCPServers' toolOverrides (ADL descriptions that steer calls to the narrow
# forms each server supports). Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-prompt-tools.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
checker="$chart/../scripts/check-module-tools.sh"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"
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
# agents see name the selectors the server accepts and the limit that counts. The server has
# no option for fewer columns, so its config sets no list_output (its yaml form is larger).
k8s_mcp() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"t-kubernetes-mcp\") | $1" <<<"$2"; }
override() { k8s_mcp ".spec.toolOverrides[] | select(.name == \"$1\") | $2" "$out"; }
names() { k8s_mcp '.spec.toolOverrides[].name' "$1" | sort | tr '\n' ' ' | sed 's/ $//'; }
with_secrets="$(render --set kubernetesAccess.secretRead=true)"
check "overrides: the list, top, and helm tools" "events_list helm_list pods_list pods_list_in_namespace pods_top resources_list" "$(names "$out")"
check "overrides: the same tools with secretRead" "events_list helm_list pods_list pods_list_in_namespace pods_top resources_list" "$(names "$with_secrets")"
check "overrides: helm_list says it lists the server's own namespace by default" yes \
  "$(has "$(override helm_list .description)" "only the server's own namespace")"
check "overrides: helm_list says a forbidden error means no Secret read" yes \
  "$(has "$(override helm_list .description)" "fails with a forbidden error")"
check "overrides: the server config sets no list_output" 0 \
  "$(yq -N 'select(.kind == "Secret" and .metadata.name == "t-kubernetes-mcp-config") | .stringData."config.toml"' <<<"$out" | grep -c 'list_output' || true)"
check "overrides: resources_list namespace says all and * are not wildcards" yes \
  "$(has "$(override resources_list .parameters.namespace.description)" 'NEVER pass all or * as a namespace')"
check "overrides: pods_list_in_namespace namespace says all and * are not wildcards" yes \
  "$(has "$(override pods_list_in_namespace .parameters.namespace.description)" 'NEVER pass all or * as a namespace')"
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
  "$(has "$(override pods_top .parameters.all_namespaces.description)" 'defaults to true')"
check "overrides: pods_top says the Metrics API ignores limit" yes \
  "$(has "$(override pods_top .description)" 'ignores limit')"
# A count is limit=1 with no selector: the header carries remainingItemCount, which a selector
# suppresses. One text serves every list tool, so the descriptions cannot drift apart.
for tool in pods_list pods_list_in_namespace resources_list; do
  check "overrides: $tool says limit=1 counts through remainingItemCount" yes \
    "$(has "$(override "$tool" .description)" 'pass limit=1 with no labelSelector and no fieldSelector')"
  check "overrides: $tool limit says a selector suppresses remainingItemCount" yes \
    "$(has "$(override "$tool" .parameters.limit.description)" 'reports no remainingItemCount')"
done
check "overrides: the three limit descriptions are one text" 1 \
  "$(yq ea -N '[select(.kind == "MCPServer" and .metadata.name == "t-kubernetes-mcp") | .spec.toolOverrides[].parameters.limit.description | select(. != null)] | unique | length' <<<"$out")"
# One pod field list serves every pod tool, so the three descriptions cannot drift apart.
pod_fields="$(override pods_list .parameters.fieldSelector.description | grep -o 'Accepted fields: [^;]*')"
check "overrides: pods_list_in_namespace fieldSelector lists the same pod fields" "$pod_fields" \
  "$(override pods_list_in_namespace .parameters.fieldSelector.description | grep -o 'Accepted fields: [^;]*')"
check "overrides: resources_list fieldSelector lists the same pod fields" yes \
  "$(has "$(override resources_list .parameters.fieldSelector.description)" "Pod: ${pod_fields#Accepted fields: }.")"

# The Prometheus and Proxmox servers' overrides steer to the narrow forms each server has.
server_override() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"$1\") | .spec.toolOverrides[] | select(.name == \"$2\") | $3" <<<"$out_all"; }
out_all="$(render "${all_on[@]}")"
check "prometheus: execute_query names topk" yes "$(has "$(server_override prometheus-mcp execute_query .description)" 'topk(5, ...)')"
check "prometheus: execute_query forbids a bare range vector in an aggregation" yes \
  "$(has "$(server_override prometheus-mcp execute_query .description)" 'NEVER pass a bare range vector')"
check "prometheus: execute_range_query carries the same range-vector rule" yes \
  "$(has "$(server_override prometheus-mcp execute_range_query .description)" 'NEVER pass a bare range vector')"
check "prometheus: execute_query answers scrape health with count by (job) (up)" yes \
  "$(has "$(server_override prometheus-mcp execute_query .description)" 'count by (job) (up)')"
check "prometheus: list_metrics asks for filter_pattern and limit" yes \
  "$(has "$(server_override prometheus-mcp list_metrics .description)" 'ALWAYS pass filter_pattern and limit')"
check "prometheus: no override for get_targets" 0 \
  "$(yq -N 'select(.kind == "MCPServer" and .metadata.name == "prometheus-mcp") | .spec.toolOverrides[].name' <<<"$out" | grep -cx get_targets || true)"
for tool in get_node_rrd_data get_vm_rrd_data; do
  check "proxmox: $tool timeframe gives the exact values" yes \
    "$(has "$(server_override proxmox-mcp "$tool" .parameters.timeframe.description)" 'exactly one of: hour, day, week, month, year')"
  check "proxmox: $tool cf gives the exact values" yes \
    "$(has "$(server_override proxmox-mcp "$tool" .parameters.cf.description)" 'exactly AVERAGE or MAX')"
  check "proxmox: $tool says it takes no limit" yes \
    "$(has "$(server_override proxmox-mcp "$tool" .description)" 'there is no limit, field or step argument')"
done
for tool in list_nodes list_vms get_cluster_resources; do
  check "proxmox: $tool verbose stays off" yes \
    "$(has "$(server_override proxmox-mcp "$tool" .parameters.verbose.description)" 'NEVER pass verbose=true')"
done

# The checks below count offenders, so first make sure there is something to count.
override_count="$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[].name' <<<"$out_all" | grep -c . || true)"
check "overrides: the three servers' overrides were rendered (6 + 4 + 5)" 15 "$override_count"

# Every override on every server is ADL: a tool description opens with DESCRIPTION, and every
# line of a tool or parameter description starts with an ADL keyword.
all_overrides() { yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[]' <<<"$1"; }
check "overrides: every tool description opens with DESCRIPTION" 0 \
  "$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[] | select(has("description")) | .description | split("\n") | .[0]' <<<"$out_all" \
    | grep -vc '^DESCRIPTION ' || true)"
check "overrides: every description line starts with an ADL keyword" 0 \
  "$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[] | [.description, (.parameters // {} | .[].description)] | .[] | select(. != null)' <<<"$out_all" \
    | grep -v '^$' | grep -cvE '^(DESCRIPTION|ASSERT|WHEN|ALWAYS|NEVER) ' || true)"
# CRD limits: a description is at most 4000 characters, a parameter description at most 2000.
check "overrides: no description over 4000 characters" 0 \
  "$(all_overrides "$out_all" | yq -N '.description // "" | length' | awk '$1 > 4000' | wc -l | tr -d ' ')"
check "overrides: no parameter description over 2000 characters" 0 \
  "$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[] | .parameters // {} | .[].description | length' <<<"$out_all" | awk '$1 > 2000' | wc -l | tr -d ' ')"
# An override names a tool some agent has, so none describes a tool no agent can call.
enabled="$(agent_tools "$out_all")"
check "overrides: agents enable tools" yes "$([ -n "$enabled" ] && echo yes || echo no)"
for tool in $(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[].name' <<<"$out_all"); do
  check "overrides: $tool is enabled on an agent" yes "$(grep -qxF "$tool" <<<"$enabled" && echo yes || echo no)"
done

# The tool names themselves are checked against what each server lists (CI runs this script).
bash "$chart/tests/test-server-tools.sh" || failures=$((failures + 1))

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
