#!/usr/bin/env bash
# Render tests for the tools the pilot crew's prompts name: the shared modules list an
# agent's tools with the ${agent.tools} placeholder instead of naming tools, and no agent's
# PromptModules name a tool the agent does not have, with the optional tools switched on and
# off (kubernetesAccess.secretRead.namespaces and kubernetesAccess.write.namespaces, compute.workspaceQuery, advisors.workspaceQuery, mcpServers.proxmox).
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

# The modules that describe the workspace call lines say, in these exact words, what an
# [EMPTY RESULT] block means and that a shortened args= text still ran with the full arguments,
# and that a call line carries data only when a [RESULT] or [EMPTY RESULT] block follows or comes after it.
empty_sentence='an [EMPTY RESULT] block after a call line means the call succeeded and returned nothing'
# shellcheck disable=SC2016
args_sentence='args= may end with "(args cut at <n> of <m> chars)": the call ran with the full arguments'
for name in analyst-review-protocol compute-system; do
  check "$name pins the [EMPTY RESULT] sentence" yes "$(has "$(module "$name")" "$empty_sentence")"
  check "$name pins the cut args sentence" yes "$(has "$(module "$name")" "$args_sentence")"
  check "$name names the [RESULT] or [EMPTY RESULT] block" yes "$(has "$(module "$name")" '[RESULT] or [EMPTY RESULT] block')"
  check "$name does not say nothing is stored after an empty result" no "$(has "$(module "$name")" 'nothing stored to read')"
done

# The shared modules name no tool: each agent's own tool list comes from the placeholder.
vocab='resources_list|resources_get|pods_list|pods_list_in_namespace|list_api_resources|list_metrics|get_targets|get_metric_metadata|execute_code|workspace_head|workspace_grep|workspace_query'
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
check "secret namespaces only: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set 'kubernetesAccess.secretRead.namespaces={kube-system}' >/dev/null 2>&1; echo $?)"
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
with_secrets="$(render --set 'kubernetesAccess.secretRead.namespaces={kube-system}')"
check "overrides: the list, top, and helm tools" "events_list helm_list pods_list pods_list_in_namespace pods_top resources_list" "$(names "$out")"
check "overrides: the same tools with secret namespaces" "events_list helm_list pods_list pods_list_in_namespace pods_top resources_list" "$(names "$with_secrets")"
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
check "overrides: resources_list fieldSelector says a term is field=value" yes \
  "$(has "$(override resources_list .parameters.fieldSelector.description)" 'never a field name alone')"
check "overrides: resources_list fieldSelector says memory and CPU cannot be selected" yes \
  "$(has "$(override resources_list .parameters.fieldSelector.description)" 'memory, CPU, capacity and allocatable cannot be selected')"
# The fieldSelector rules the gateway applies before the call: RE2 patterns, searched anywhere in
# the text, first match answers. tests/fixtures/field-selector-rules.json holds the patterns and the
# selectors each must reject or let through; the Kubemoot gateway runs a copy of it with the real
# RE2 engine. Here the rendered patterns must equal the fixture's, and grep -P (every pattern is in
# the syntax RE2 and PCRE share) must agree with the fixture on each selector.
fixture="$chart/tests/fixtures/field-selector-rules.json"
rule_patterns() { override resources_list '.parameters.fieldSelector.rules[].reject'; }
rule_messages() { override resources_list '.parameters.fieldSelector.rules[] | .message | @json'; }
rendered_patterns="$(rule_patterns)"
first_rule() { # the index of the first rendered rule that rejects the selector, or "allowed"
  local pattern index=0
  while IFS= read -r pattern; do
    if grep -qP -- "$pattern" <<<"$1"; then echo "$index"; return; fi
    index=$((index + 1))
  done <<<"$rendered_patterns"
  echo allowed
}
check "rules: the rendered patterns equal the fixture's, in order" "$(yq -p=json -o=y -N '.rules[].reject' "$fixture")" "$(rule_patterns)"
check "rules: resources_list fieldSelector has four rules" 4 "$(rule_patterns | wc -l | tr -d ' ')"
check "rules: only the list tools' fieldSelector and limit carry rules" "pods_list.limit pods_list_in_namespace.limit resources_list.fieldSelector resources_list.limit" \
  "$(k8s_mcp '.spec.toolOverrides[] | select(.parameters) | .name as $t | .parameters | to_entries[] | select(.value.rules) | $t + "." + .key' "$out" | tr '\n' ' ' | sed 's/ $//')"
check "rules: every rule has a pattern and an ADL message" 4 \
  "$(override resources_list '.parameters.fieldSelector.rules[] | select(.reject != "" and (.message | test("^ASSERT "))) | .reject' | wc -l | tr -d ' ')"
while IFS=$'\t' read -r input want; do
  check "rules: rejects '$input' with rule $want" "$want" "$(first_rule "$input")"
done < <(yq -p=json -o=y -N '.reject[] | .input + "\t" + (.rule | tostring)' "$fixture")
while IFS= read -r input; do
  check "rules: allows '$input'" allowed "$(first_rule "$input")"
done < <(yq -p=json -o=y -N '.pass[]' "$fixture")
check "rules: memory selectors get the metrics alternative" yes "$(has "$(rule_messages | sed -n 1p)" 'use a metrics tool')"
check "rules: regex operators get the table alternative" yes "$(has "$(rule_messages | sed -n 2p)" 'read the matching rows in the table')"
check "rules: a bare field name is told to use field=value" yes "$(has "$(rule_messages | sed -n 4p)" 'a field name alone is an error')"
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
# A positive limit cuts a list and delivers no later page, so the gateway refuses it; a count is the
# rows of a list with no limit. One text serves every list tool, so the descriptions cannot drift apart.
limit_fixture="$chart/tests/fixtures/limit-rule.json"
limit_pattern="$(yq -p=json -o=y -N '.reject' "$limit_fixture")"
for tool in pods_list pods_list_in_namespace resources_list; do
  check "overrides: $tool says a count is the rows of a list with no limit" yes \
    "$(has "$(override "$tool" .description)" 'list with no limit and count the rows')"
  check "overrides: $tool no longer counts through remainingItemCount" no \
    "$(has "$(override "$tool" .description)" 'remainingItemCount')"
  check "overrides: $tool limit says a positive limit is refused" yes \
    "$(has "$(override "$tool" .parameters.limit.description)" 'A positive limit is refused')"
  check "rules: $tool limit carries the fixture's one pattern" "$limit_pattern" \
    "$(override "$tool" '.parameters.limit.rules | map(.reject) | join("|")')"
  check "rules: $tool limit message is ADL and names the alternative" yes \
    "$(has "$(override "$tool" '.parameters.limit.rules[0].message')" 'WHEN you need every row, or a count, THEN call again with no limit')"
done
check "overrides: the three limit descriptions are one text" 1 \
  "$(yq ea -N '[select(.kind == "MCPServer" and .metadata.name == "t-kubernetes-mcp") | .spec.toolOverrides[].parameters.limit.description | select(. != null)] | unique | length' <<<"$out")"
while IFS= read -r value; do
  if grep -qP -- "$limit_pattern" <<<"$value"; then got=rejected; else got=allowed; fi
  check "rules: limit '$value' is rejected" rejected "$got"
done < <(yq -p=json -o=y -N '.rejectValues[]' "$limit_fixture")
while IFS= read -r value; do
  if [ -n "$value" ] && grep -qP -- "$limit_pattern" <<<"$value"; then got=rejected; else got=allowed; fi
  check "rules: limit '$value' is allowed" allowed "$got"
done < <(yq -p=json -o=y -N '.passValues[]' "$limit_fixture")
# The Node table has no capacity column: the descriptions and the rule message send an agent to resources_get.
check "overrides: resources_list says the Node table has no capacity column" yes \
  "$(has "$(override resources_list .description)" 'the Node table has no CPU, memory, capacity or allocatable column')"
check "rules: memory selectors are sent to resources_get for the Node" yes \
  "$(has "$(rule_messages | sed -n 1p)" 'call resources_get with apiVersion v1, kind Node')"
check "overrides: resources_list labelSelector says an absent label matches nothing" yes \
  "$(has "$(override resources_list .parameters.labelSelector.description)" 'a worker Node usually has no node-role label')"
check "prompt: k8s-nodes does not promise capacity columns in the node list" 0 \
  "$(render | yq -N 'select(.kind == "PromptModule" and .metadata.name == "k8s-nodes-system") | .spec.content' | grep -c 'with the capacity/allocatable columns' || true)"
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

# What the coordinator reads per agent when it picks: the description, and for the resume
# search also the summary, keywords, and prompt. Each agent that fetches live data says so,
# compute says it fetches nothing, the texts name no cluster of their own, and no two agents
# share a description.
agent_field() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.$2" <<<"$out_all"; }
data_agents=(k8s-config k8s-helm k8s-metrics k8s-nodes k8s-scaling k8s-services k8s-storage k8s-workloads k8sgpt
  nvidia-gpu-history nvidia-gpu-meta nvidia-gpu-now obs-metrics proxmox-pve proxmox-qm)
for name in "${data_agents[@]}"; do
  description="$(agent_field "$name" description)"
  check "descriptions: $name says it fetches live data" yes "$([[ $description == "Fetches "* ]] && echo yes || echo no)"
done
for phrase in 'Cannot fetch data' 'no cluster API' 'no kubectl' 'Select it together with the agents that fetch the data'; do
  check "descriptions: compute says '$phrase'" yes "$(has "$(agent_field compute description)" "$phrase")"
done
check "descriptions: compute's summary says a live-data question needs the fetching agents" yes \
  "$(has "$(agent_field compute triageSummary)" 'also needs the agents that fetch that data')"
check "descriptions: k8s-nodes names capacity and allocatable" yes \
  "$(has "$(agent_field k8s-nodes description)" 'capacity and allocatable')"
check "descriptions: k8s-workloads names requests and limits" yes \
  "$(has "$(agent_field k8s-workloads description)" 'CPU and memory requests and limits')"
for setting in false true; do
  write_ns=null; [ "$setting" = true ] && write_ns="{apps}"
  write_on="$(render "${all_on[@]}" --set kubernetesAccess.write.namespaces="$write_ns")"
  check "descriptions: k8s-helm mentions install only with write access ($setting)" "$setting" \
    "$(yq -N 'select(.kind == "Agent" and .metadata.name == "k8s-helm") | .spec.description | test("Installs and uninstalls")' <<<"$write_on")"
  check "descriptions: k8s-scaling mentions scaling only with write access ($setting)" "$setting" \
    "$(yq -N 'select(.kind == "Agent" and .metadata.name == "k8s-scaling") | .spec.description | test("Scales a")' <<<"$write_on")"
done
# The texts the resume embeds: each specialist's description and summary, and each agent
# module's DESCRIPTION lines.
specialist_texts() {
  yq -N 'select(.kind == "Agent" and .spec.discussRole != "coordinator") | (.spec.description, .spec.triageSummary)' <<<"$out_all"
  yq -N 'select(.kind == "PromptModule" and (.metadata.name | test("-system$"))) | .spec.content' <<<"$out_all" | grep '^DESCRIPTION '
}
texts="$(specialist_texts)"
check "descriptions: every data agent's text was rendered" yes \
  "$([ "$(grep -c '^Fetches ' <<<"$texts")" -ge "${#data_agents[@]}" ] && echo yes || echo no)"
check "descriptions: no specialist text names Talos or a homelab" 0 "$(grep -ciE 'talos|homelab' <<<"$texts" || true)"
check "descriptions: no specialist text holds a non-ASCII character" 0 "$(LC_ALL=C grep -c '[^[:print:][:space:]]' <<<"$texts" || true)"
check "descriptions: no two agents share a description" 0 \
  "$(yq -N 'select(.kind == "Agent") | .spec.description' <<<"$out_all" | sort | uniq -d | grep -c . || true)"

# The advisory describes memberTasks as an output field, as a schema and not as a rule about tools.
advisory="$(module advisory-prompt)"
check "advisory: has a member-tasks component that names memberTasks" 1 \
  "$(sed -n '/DEFINE COMPONENT step-3-member-tasks/,/DEFINE COMPONENT step-4/p' <<<"$advisory" | grep -c memberTasks | sed 's/^[1-9][0-9]*$/1/')"
check "advisory: the member-tasks component adds no NEVER or ALWAYS rule" 0 \
  "$(sed -n '/DEFINE COMPONENT step-3-member-tasks/,/DEFINE COMPONENT step-4/p' <<<"$advisory" | grep -cE '^ *(NEVER|ALWAYS)' || true)"

# The discussion protocol is ADL and keeps the signal words agents emit.
discussion="$(module discussion-protocol)"
check "discussion-protocol is ADL" 1 "$(grep -c -x -F 'DEFINE DOMAIN discussion-protocol' <<<"$discussion" || true)"
for word in NOTHING_TO_ADD TOOL_GAP CONCERN; do
  check "discussion-protocol carries $word" yes "$(has "$discussion" "$word")"
done
check "discussion-protocol says how to raise a concern" yes "$(has "$discussion" 'CONCERN: <the claim')"
check "discussion-protocol names no bare 'raise a CONCERN'" 0 "$(grep -c 'raise a CONCERN' <<<"$discussion" || true)"
check "discussion-protocol has no Markdown headings" 0 "$(grep -c '^#' <<<"$discussion" || true)"

# A failed gather leaves only its own part unknown; the answer still covers the rest.
coord="$(yq -N 'select(.kind == "PromptModule" and .metadata.name == "coordinator-decision-logic") | .spec.content' <<<"$out")"
check "a retrieval failure makes only its own part unknown" 1 "$(grep -c 'makes UNKNOWN only the part' <<<"$coord")"
check "the coordinator answers the parts the gathered data answers" 1 "$(grep -c 'answer first every part' <<<"$coord")"
check "no unscoped rule makes the whole answer unknown" 0 "$(grep -c 'means the answer is UNKNOWN' <<<"$coord" || true)"

# peer-verification: off by default (no module, no reference); on adds the module and lists it
# right after discussion-protocol in every agent that uses discussion-protocol.
pv_refs() { yq -N 'select(.kind == "Agent") | .spec.promptRefs | join(",")' <<<"$1"; }
check "peer-verification is off by default: no module" 0 \
  "$(yq -N 'select(.kind == "PromptModule" and .metadata.name == "peer-verification") | .metadata.name' <<<"$out" | grep -c . || true)"
check "peer-verification is off by default: no agent lists it" 0 "$(pv_refs "$out" | grep -c 'peer-verification' || true)"
pv_on="$(render --set discussion.peerVerification.enabled=true)"
pv_module="$(yq -N 'select(.kind == "PromptModule" and .metadata.name == "peer-verification") | .spec.content' <<<"$pv_on")"
check "peer-verification on: the module renders" 1 "$(grep -c 'DEFINE COMPONENT peer-verification' <<<"$pv_module")"
check "peer-verification names no agent's tool" 0 "$(grep -cEw "$vocab" <<<"$pv_module" || true)"
check "peer-verification has no Markdown headings" 0 "$(grep -c '^#' <<<"$pv_module" || true)"
check "peer-verification says how to raise a concern" 2 "$(grep -c 'CONCERN: <the claim' <<<"$pv_module" || true)"
check "peer-verification names no bare 'raise a CONCERN'" 0 "$(grep -c 'raise a CONCERN' <<<"$pv_module" || true)"
for word in CONCERN NEVER ALWAYS; do
  check "peer-verification carries $word" yes "$(has "$pv_module" "$word")"
done
with_dp="$(pv_refs "$pv_on" | grep -c 'discussion-protocol' || true)"
check "peer-verification on: every agent with discussion-protocol lists it right after" "$with_dp" \
  "$(pv_refs "$pv_on" | grep -c 'discussion-protocol,peer-verification,' || true)"
check "peer-verification on: the coordinator is untouched" 0 \
  "$(yq -N 'select(.kind == "Agent" and .metadata.name == "t-coordinator") | .spec.promptRefs[]' <<<"$pv_on" | grep -c 'peer-verification' || true)"
# Switching it on changes nothing but the module and the references.
strip() { yq -N 'select(.kind != "PromptModule" or .metadata.name != "peer-verification") | (select(.kind == "Agent") | .spec.promptRefs) |= map(select(. != "peer-verification"))' <<<"$1"; }
check "peer-verification on: the rest of the render is unchanged" "$(strip "$out")" "$(strip "$pv_on")"
check "peer-verification on: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set discussion.peerVerification.enabled=true >/dev/null 2>&1; echo $?)"

# The tool names themselves are checked against what each server lists (CI runs this script).
bash "$chart/tests/test-server-tools.sh" || failures=$((failures + 1))

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
