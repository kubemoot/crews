#!/usr/bin/env bash
# Render tests for the pilot crew's prompts and tool descriptions. The prompts say each agent's
# role and purpose and name no tool: the shared modules (crew-invariants, worker, advisor), the
# coordinator's modules and every agent's own module. What a tool does lives in its description,
# the MCPServers' toolOverrides, which state facts (DESCRIPTION and ASSERT lines) and no rules.
# No agent's PromptModules name a tool the agent does not have, with the optional tools switched
# on and off. The agents' declarations (description, triageSummary) say what each one answers,
# since the coordinator's selection reads the description. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-prompt-tools.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
checker="$chart/../scripts/check-module-tools.sh"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"
module_of() { yq -N "select(.kind == \"PromptModule\" and .metadata.name == \"$1\") | .spec.content" <<<"$2"; }
module() { module_of "$1" "$out"; }
count() { grep -c . || true; }

out="$(render)"
out_all="$(render "${all_on[@]}")"
shared=(crew-invariants worker advisor compute-system coordinator-convene coordinator-answer)

# The modules the crew renders, and the ones the refactor removed.
modules="$(yq -N 'select(.kind == "PromptModule") | .metadata.name' <<<"$out_all" | sort | tr '\n' ' ' | sed 's/ $//')"
for name in "${shared[@]}" ratify-prompt; do
  check "module $name renders" yes "$(grep -qw -- "$name" <<<"$modules" && echo yes || echo no)"
done
for name in discussion-protocol peer-verification response-style tooler-discipline analyst-review-protocol \
  advisory-prompt coordinator-decision-logic synthesis-prompt fact-checker-system; do
  check "module $name is gone" no "$(grep -qw -- "$name" <<<"$modules" && echo yes || echo no)"
done
check "no module is left unloaded but ratify-prompt (a template while ratification is off)" "ratify-prompt" \
  "$(comm -23 <(yq -N 'select(.kind == "PromptModule") | .metadata.name' <<<"$out_all" | sort -u) \
    <(yq -N 'select(.kind == "Agent") | .spec.promptRefs // [] | .[]' <<<"$out_all" | sort -u) | tr '\n' ' ' | sed 's/ $//')"

# Each agent loads its role's contracts and its own module, in that order.
refs() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.promptRefs | join(\",\")" <<<"$out_all"; }
for agent in k8s-config k8s-helm k8s-metrics k8s-nodes k8s-scaling k8s-services k8s-storage k8s-workloads k8sgpt \
  nvidia-gpu-history nvidia-gpu-meta nvidia-gpu-now proxmox-pve proxmox-qm internet-search; do
  check "refs: $agent is a worker" "crew-invariants,worker,$agent-system" "$(refs "$agent")"
done
check "refs: obs-metrics is a worker" "crew-invariants,worker,obs-metrics-system" "$(refs obs-metrics)"
for agent in k8s-advisor nvidia-gpu-advisor obs-advisor proxmox-advisor; do
  check "refs: $agent is an advisor" "crew-invariants,advisor,$agent-system" "$(refs "$agent")"
done
check "refs: compute is the calculator" "crew-invariants,compute-system" "$(refs compute)"
check "refs: the coordinator" "coordinator-convene,coordinator-answer" "$(refs homelab-coordinator)"

# The shared modules name no tool, no agent's prompt carries the old tool placeholder, and the
# modules are short: the role, not a manual.
vocab="$(yq -N '.servers[] | (.tools // []) + (.write // []) | .[]' "$chart/tests/server-tools.yaml" | grep -vxE 'analyze|search|config' | sort -u | paste -sd'|' -)"
for name in "${shared[@]}"; do
  check "$name names no tool" 0 "$(module "$name" | grep -cEw "$vocab" || true)"
  check "$name has no Markdown headings" 0 "$(module "$name" | grep -c '^#' || true)"
  check "$name is ADL: opens with DEFINE DOMAIN" yes "$(module "$name" | head -1 | grep -q '^DEFINE DOMAIN ' && echo yes || echo no)"
done
# shellcheck disable=SC2016  # the placeholder is literal text
check "no module lists tools with the placeholder" 0 "$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out_all" | grep -cF '${agent.tools}' || true)"
check "no agent's prompt is over 3000 characters" "" \
  "$(for agent in $(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$out_all"); do
       n=0; for m in $(yq -N "select(.kind == \"Agent\" and .metadata.name == \"$agent\") | .spec.promptRefs[]" <<<"$out_all"); do
         n=$((n + $(module_of "$m" "$out_all" | wc -c))); done
       [ "$n" -le 3000 ] || echo "$agent=$n"; done | tr '\n' ' ' | sed 's/ $//')"

# The contracts: read only, no invented values, calculated values marked, rechecks answered.
invariants="$(module crew-invariants)"
check "invariants: the crew never changes the systems it reads" yes "$(has "$invariants" 'this crew reads the systems it answers about and never changes them')"
check "invariants: no agent creates information" yes "$(has "$invariants" 'no agent creates information')"
check "invariants: a calculated value says how it was made" yes "$(has "$invariants" '(calculated with code) or (inferred from <what>)')"
check "invariants: an agent looks at what it got before acting on it" yes "$(has "$invariants" 'you look at what a tool gave you (its format, its fields, how much) before you act on it')"
check "invariants: a failure changes the assumption before a retry" yes "$(has "$invariants" 'you change the assumption before you retry')"
check "invariants: a finding claims no more than what was examined" yes "$(has "$invariants" 'a finding says what you examined, and claims no more')"
check "invariants: not being able to determine is a complete finding" yes "$(has "$invariants" 'I could not determine this, because ...')"
check "invariants: the lessons carry no test's numbers" no "$(has "$invariants" '1500')"
check "invariants: no Secret contents" yes "$(has "$invariants" 'NEVER read or report a credential or the contents of a Secret')"
check "invariants without the scheduler: no schedules mentioned" no "$(has "$invariants" 'reminders and follow-up discussions')"
sched="$(render --set mcpServers.scheduling.enabled=true)"
check "invariants with the scheduler: schedules are the one thing the crew keeps" yes \
  "$(has "$(module_of crew-invariants "$sched")" "reminders and follow-up discussions are the one thing the crew keeps for them")"
write_on="$(render --set 'kubernetesAccess.write.namespaces={apps}')"
check "invariants with write access: changes only on request, with a write tool" yes \
  "$(has "$(module_of crew-invariants "$write_on")" 'changes a system it reads only with a write tool it has, and only when the person asks')"
check "invariants with write access: no read-only claim" no "$(has "$(module_of crew-invariants "$write_on")" 'never changes them')"
check "answer with write access: no decline on principle" no "$(has "$(module_of coordinator-answer "$write_on")" 'decline on principle')"
check "answer read-only: declines a change to a system the crew reads" yes "$(has "$(module coordinator-answer)" 'change a system the crew reads THEN decline on principle')"
check "answer with the scheduler: a cancelled reminder is not a change to decline" yes \
  "$(has "$(module_of coordinator-answer "$sched")" "cancelling the person's reminders and follow-ups is the scheduler's work, not a change to a system")"
worker="$(module worker)"
check "worker: a finding holds only tool results" yes "$(has "$worker" 'a finding states only what a tool result in this discussion holds')"
check "worker: an empty result is a finding, not a failure" yes "$(has "$worker" 'an empty result from a call that ran is a finding, none; it is not a failure to retrieve')"
check "worker: never counts by eye" yes "$(has "$worker" 'NEVER count, total or order a result yourself')"
advisor="$(module advisor)"
check "advisor: is the domain's fact-checker" yes "$(has "$advisor" "You are your domain's fact-checker")"
check "advisor: checks against stored result, live source and documentation" yes \
  "$(has "$advisor" 'against the stored result it came from, the live source where your tools read it, and the documentation you are given')"
check "advisor: adds no data" yes "$(has "$advisor" 'you never change its data or add data of your own')"
check "advisor: computes a checked number with code" yes "$(has "$advisor" 'computed with code from the stored values')"
check "advisor: a failed read leaves a claim unverified" yes "$(has "$advisor" 'a failed read leaves it unverified')"
compute="$(module compute-system)"
check "compute: every number is code output, marked" yes "$(has "$compute" 'the output of code you ran in this discussion, marked (calculated with code)')"
check "compute: fetches nothing" yes "$(has "$compute" 'you fetch nothing')"
check "compute-system does not differ between the workspace_query arms" "$compute" "$(module_of compute-system "$(render --set compute.workspaceQuery=false)")"

# The scheduler has its own role: it keeps the person's schedules and gathers nothing.
check "scheduler: no worker contract" "crew-invariants,scheduler-advisor-system" \
  "$(yq -N 'select(.kind == "Agent" and .metadata.name == "scheduler-advisor") | .spec.promptRefs | join(",")' <<<"$sched")"
scheduler="$(module_of scheduler-advisor-system "$sched")"
check "scheduler: a confirmation question is its reply" yes "$(has "$scheduler" 'your reply is the question that confirms it')"
check "scheduler: stands aside through the signal tool" yes "$(has "$scheduler" 'stand aside with the signal tool')"
check "scheduler: the threadId rule lives in the tool's own description" 0 "$(grep -c 'threadId' <<<"$scheduler" || true)"

# The verdicts. The signal tool is the default: a Kubemoot whose archetype declares signals offers
# it, and then no module teaches a reply word and an agent asked a question rechecks. The reply
# words are for a crew on an older Kubemoot, in the exact forms its runtime parses: compute's bare
# NO_DATA (the compute contract accepts only that), NO_DATA: and TOOL_GAP: at the start of a
# worker's reply, CONCERN: at the start of an advisor's, NOTHING_TO_ADD anywhere. There is no
# recheck round then, so a questioned value is reported as unverified.
replywords='NOTHING_TO_ADD|NO_DATA|TOOL_GAP|CONCERN'
for name in crew-invariants worker advisor compute-system coordinator-convene coordinator-answer; do
  check "signal arm (default): $name teaches no reply word" 0 "$(module "$name" | grep -cE "$replywords" || true)"
done
check "signal arm (default): the scheduler teaches no reply word" 0 "$(grep -cE "$replywords" <<<"$scheduler" || true)"
check "signal arm: the invariants say to record the verdict with the signal tool" yes "$(has "$invariants" 'you record your verdict with the signal tool')"
check "signal arm: the advisor asks the agent to recheck through the signal tool" yes "$(has "$advisor" 'ask the agent that made it, with the signal tool, to recheck it')"
check "signal arm: the worker answers a recheck by reading again" yes "$(has "$worker" 'WHEN an agent asks you to recheck a finding THEN read it again with your tools')"
check "signal arm: compute answers a recheck by running the code again" yes "$(has "$compute" 'WHEN an agent asks you to recheck a number THEN run the code again')"
check "signal arm: a questioned value counts only after a recheck" yes "$(has "$(module coordinator-answer)" 'counts only after the agent that reported it rechecked it')"
old="$(render --set discussion.signalTool.enabled=false)"
oworker="$(module_of worker "$old")"; oadvisor="$(module_of advisor "$old")"; ocompute="$(module_of compute-system "$old")"
check "words arm: compute replies with the bare word NO_DATA" yes "$(has "$ocompute" 'reply exactly NO_DATA, with nothing else')"
check "words arm: compute never writes NO_DATA:" 0 "$(grep -c 'NO_DATA:' <<<"$ocompute" || true)"
check "words arm: the worker starts its reply with NO_DATA:" yes "$(has "$oworker" 'start your reply with NO_DATA: <what, and why>')"
check "words arm: the worker starts its reply with TOOL_GAP:" yes "$(has "$oworker" 'start your reply with TOOL_GAP: <the capability>')"
check "words arm: the advisor starts its reply with CONCERN:" yes "$(has "$oadvisor" 'start your reply with CONCERN: <the claim')"
check "words arm: the reply words are upper case as the runtime matches them" 0 \
  "$(printf '%s\n%s\n%s\n' "$oworker" "$oadvisor" "$ocompute" | grep -ciE "$replywords" | awk -v u="$(printf '%s\n%s\n%s\n' "$oworker" "$oadvisor" "$ocompute" | grep -cE "$replywords")" '{print $1 - u}')"
check "words arm: no recheck line anywhere" 0 "$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$old" | grep -ci 'recheck' || true)"
check "words arm: a questioned value is reported as unverified" yes "$(has "$(module_of coordinator-answer "$old")" 'you report it as unverified')"
check "words arm: no module mentions the signal tool" 0 "$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$old" | grep -c 'signal tool' || true)"
strip_modules() { yq -N 'select(.kind != "PromptModule")' <<<"$1"; }
check "the switch changes only the PromptModules" "$(strip_modules "$out")" "$(strip_modules "$old")"
check "signal switch: a null value is off" "$(module_of crew-invariants "$old")" "$(module_of crew-invariants "$(render --set discussion.signalTool=null)")"
# The flag and the archetype must agree: the signal tool needs an archetype that declares signals.
check "routing: the coordinator's pre-filter passes every agent (at least the crew's size)" yes \
  "$(n=$(yq -N 'select(.kind == "Agent" and .spec.discussRole != "coordinator") | .metadata.name' <<<"$out" | grep -c .); k=$(yq -N 'select(.kind == "Agent" and .spec.discussRole == "coordinator") | .spec.deployment.env[] | select(.name == "KUBEMOOT_DISCUSS_RESUME_PRE_FILTER_TOP_K") | .value' <<<"$out"); [ -n "$k" ] && [ "$k" -ge "$n" ] && echo yes || echo "no (agents $n, top-k ${k:-unset})")"
check "archetype: the policy names crew.archetype" consent-3 "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.archetypeRef' <<<"$out")"
bad="$(render --set crew.archetype=quorum-2 2>&1 >/dev/null || true)"
check "archetype: the signal tool with an archetype not known to declare signals fails the render" yes \
  "$(has "$bad" 'is not in discussion.signalTool.archetypes')"
check "archetype: the reply words render under any archetype" quorum-2 \
  "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.archetypeRef' <<<"$(render --set crew.archetype=quorum-2 --set discussion.signalTool.enabled=false)")"
check "archetype: a listed archetype renders with the signal tool" quorum-2 \
  "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.archetypeRef' <<<"$(render --set crew.archetype=quorum-2 --set 'discussion.signalTool.archetypes={consent-3,quorum-2}')")"

# The coordinator: who to convene, and an answer only from what the agents found.
convene="$(module coordinator-convene)"
answer="$(module coordinator-answer)"
check "convene: selects by described capability" yes "$(has "$convene" 'whose description says they answer this kind of question')"
check "convene: never says the crew cannot" yes "$(has "$convene" 'NEVER state that the crew cannot do something')"
check "convene: a member task names no other agent" yes "$(has "$convene" 'names no other agent')"
check "convene: no skill line without Skills" no "$(has "$convene" 'select a skill')"
check "convene: a skill line with a Skill on" yes "$(has "$(module_of coordinator-convene "$(render --set skills.dcgmGpuMetrics.enabled=true)")" 'select a skill')"
check "answer: only from the findings" yes "$(has "$answer" 'you answer only from the findings')"
check "answer: a failed listing is not zero" yes "$(has "$answer" 'a failed listing is not zero items')"
check "answer: never mentions agents or signals" yes "$(has "$answer" 'never mention agents, signals or the discussion')"
check "coordinator modules name no cluster" 0 "$(printf '%s\n%s\n' "$convene" "$answer" | grep -ciE 'rig[0-9]|talos|proxmox|homelab|gateway' || true)"
# The host-name line needs the join the PromQL Skill carries.
for m in k8s-metrics-system obs-metrics-system; do
  check "$m: no host-name rule without the PromQL Skill" no "$(has "$(module "$m")" 'by its name, not by its address')"
  check "$m: the host-name rule with the PromQL Skill" yes "$(has "$(module_of "$m" "$(render --set skills.promqlResourceUsage.enabled=true)")" 'by its name, not by its address')"
done

# No agent's modules name a tool the agent lacks, whichever optional tools are on.
export VOCAB_ARGS="${all_on[*]}"
check "default values: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" >/dev/null 2>&1; echo $?)"
check "optional tools on: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" "${all_on[@]}" >/dev/null 2>&1; echo $?)"
check "words arm: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" --set discussion.signalTool.enabled=false >/dev/null 2>&1; echo $?)"
check "proxmox only: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set mcpServers.proxmox.enabled=true --set mcpServers.proxmox.image=x >/dev/null 2>&1; echo $?)"

# The Kubernetes server's tool overrides: lists get narrowed on the server, so the descriptions
# agents see name the selectors the server accepts and how a large list is paged.
# The server has no option for fewer columns, so its config sets no list_output.
k8s_mcp() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"t-kubernetes-mcp\") | $1" <<<"$2"; }
override() { k8s_mcp ".spec.toolOverrides[] | select(.name == \"$1\") | $2" "$out"; }
names() { k8s_mcp '.spec.toolOverrides[].name' "$1" | sort | tr '\n' ' ' | sed 's/ $//'; }
check "overrides: the Kubernetes tools" "api_resources_list events_list helm_list pods_get pods_list pods_list_in_namespace pods_top resources_get resources_list" "$(names "$out")"
check "overrides: helm_list says it lists the server's own namespace by default" yes \
  "$(has "$(override helm_list .description)" "only the server's own namespace")"
check "overrides: helm_list says a forbidden error means no Secret read" yes \
  "$(has "$(override helm_list .description)" "fails with a forbidden error")"
check "overrides: the server config sets no list_output" 0 \
  "$(yq -N 'select(.kind == "Secret" and .metadata.name == "t-kubernetes-mcp-config") | .stringData."config.toml"' <<<"$out" | grep -c 'list_output' || true)"
check "overrides: resources_list namespace says all and * are not wildcards" yes \
  "$(has "$(override resources_list .parameters.namespace.description)" 'all and * are not wildcards')"
check "overrides: pods_list_in_namespace namespace says all and * are not wildcards" yes \
  "$(has "$(override pods_list_in_namespace .parameters.namespace.description)" 'all and * are not wildcards')"
check "overrides: resources_list says one kind per call and no names-only mode" yes \
  "$(has "$(override resources_list .description)" 'there is no names-only or fewer-columns mode')"
check "overrides: resources_list says its table never holds ConfigMap data" yes \
  "$(has "$(override resources_list .description)" "never a ConfigMap's data")"
check "overrides: resources_get returns a ConfigMap's keys and values" yes \
  "$(has "$(override resources_get .description)" 'for a ConfigMap its data keys and values')"
check "overrides: pods_get holds the restart counts" yes "$(has "$(override pods_get .description)" 'restartCount')"
check "overrides: resources_get says a CRD holds its kind's schema" yes "$(has "$(override resources_get .description)" 'spec.versions[].schema.openAPIV3Schema')"
check "overrides: api_resources_list says kind is required and there is no full listing" yes "$(has "$(override api_resources_list .description)" 'there is no listing of every kind at once')"
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
check "rules: only resources_list fieldSelector carries rules" "resources_list.fieldSelector" \
  "$(k8s_mcp '.spec.toolOverrides[] | select(.parameters) | .name as $t | .parameters | to_entries[] | select(.value.rules) | $t + "." + .key' "$out" | tr '\n' ' ' | sed 's/ $//')"
check "rules: every rule has a pattern and an ASSERT message" 4 \
  "$(override resources_list '.parameters.fieldSelector.rules[] | select(.reject != "" and (.message | test("^ASSERT "))) | .reject' | wc -l | tr -d ' ')"
while IFS=$'\t' read -r input want; do
  check "rules: rejects '$input' with rule $want" "$want" "$(first_rule "$input")"
done < <(yq -p=json -o=y -N '.reject[] | .input + "\t" + (.rule | tostring)' "$fixture")
while IFS= read -r input; do
  check "rules: allows '$input'" allowed "$(first_rule "$input")"
done < <(yq -p=json -o=y -N '.pass[]' "$fixture")
check "rules: memory selectors get the metrics alternative" yes "$(has "$(rule_messages | sed -n 1p)" 'comes from a metrics tool')"
check "rules: regex operators get the table alternative" yes "$(has "$(rule_messages | sed -n 2p)" 'whose rows show which ones match')"
check "rules: a bare field name is told to use field=value" yes "$(has "$(rule_messages | sed -n 4p)" 'a field name alone is an error')"
check "rules: memory selectors are sent to resources_get for the Node" yes \
  "$(has "$(rule_messages | sed -n 1p)" 'call resources_get with apiVersion v1, kind Node')"
check "overrides: pods_list fieldSelector says phase Running does not narrow" yes \
  "$(has "$(override pods_list .parameters.fieldSelector.description)" 'status.phase=Running matches nearly every pod')"
check "overrides: pods_list fieldSelector names spec.nodeName" yes \
  "$(has "$(override pods_list .parameters.fieldSelector.description)" 'spec.nodeName=<node>')"
check "overrides: events_list fieldSelector gives type=Warning" yes \
  "$(has "$(override events_list .parameters.fieldSelector.description)" 'type=Warning')"
check "overrides: pods_top says one row per container" yes "$(has "$(override pods_top .description)" 'one row per container')"
check "overrides: pods_top all_namespaces says it defaults to true" yes \
  "$(has "$(override pods_top .parameters.all_namespaces.description)" 'defaults to true')"
check "overrides: pods_top says the Metrics API ignores limit and continue" yes "$(has "$(override pods_top .description)" 'ignores limit and continue')"
# The server pages a large list with limit and continue and caps one response at 4 MiB, so the
# descriptions say how a count is made and how the next page is asked for. One text serves every
# list tool, so the descriptions cannot drift apart, and no rule refuses a limit any more.
for tool in pods_list pods_list_in_namespace resources_list; do
  check "overrides: $tool says a count is the rows of a reply with no limit" yes \
    "$(has "$(override "$tool" .description)" 'limit returns every matching row in one reply, so its rows are the count')"
  check "overrides: $tool states the 4 MiB cap" yes "$(has "$(override "$tool" .description)" '4 MiB')"
  check "overrides: $tool limit says a partial reply carries a continue line" yes \
    "$(has "$(override "$tool" .parameters.limit.description)" '# continue: <token>')"
  check "overrides: $tool continue says how to get the next page" yes \
    "$(has "$(override "$tool" .parameters.continue.description)" 'sent unchanged with the same limit, namespace and selectors')"
  check "rules: $tool limit carries no rule" 0 "$(override "$tool" '.parameters.limit.rules // [] | length')"
done
check "overrides: the three limit descriptions are one text" 1 \
  "$(yq ea -N '[select(.kind == "MCPServer" and .metadata.name == "t-kubernetes-mcp") | .spec.toolOverrides[].parameters.limit.description | select(. != null)] | unique | length' <<<"$out")"
check "overrides: the three continue descriptions are one text" 1 \
  "$(yq ea -N '[select(.kind == "MCPServer" and .metadata.name == "t-kubernetes-mcp") | .spec.toolOverrides[].parameters.continue.description | select(. != null)] | unique | length' <<<"$out")"
check "overrides: events_list pages too" yes "$(has "$(override events_list .description)" 'limit and continue page the events')"
check "overrides: resources_list says the Node table has no capacity column" yes \
  "$(has "$(override resources_list .description)" 'the Node table has no CPU, memory, capacity or allocatable column')"
check "overrides: resources_list labelSelector says an absent label matches nothing" yes \
  "$(has "$(override resources_list .parameters.labelSelector.description)" 'a worker Node usually has no node-role label')"
# One pod field list serves every pod tool, so the three descriptions cannot drift apart.
pod_fields="$(override pods_list .parameters.fieldSelector.description | grep -o 'Accepted fields: [^;]*')"
check "overrides: pods_list_in_namespace fieldSelector lists the same pod fields" "$pod_fields" \
  "$(override pods_list_in_namespace .parameters.fieldSelector.description | grep -o 'Accepted fields: [^;]*')"
check "overrides: resources_list fieldSelector lists the same pod fields" yes \
  "$(has "$(override resources_list .parameters.fieldSelector.description)" "Pod: ${pod_fields#Accepted fields: }.")"

# The other servers' overrides: what their tools return, and the facts the prompts used to carry.
server_override() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"$1\") | .spec.toolOverrides[] | select(.name == \"$2\") | $3" <<<"$out_all"; }
check "prometheus: execute_query names topk" yes "$(has "$(server_override prometheus-mcp execute_query .description)" 'topk(5, ...)')"
check "prometheus: execute_query says a bare range vector is rejected" yes \
  "$(has "$(server_override prometheus-mcp execute_query .description)" 'Prometheus rejects a bare range vector')"
check "prometheus: execute_range_query carries the same range-vector fact" yes \
  "$(has "$(server_override prometheus-mcp execute_range_query .description)" 'Prometheus rejects a bare range vector')"
check "prometheus: execute_query answers scrape health with count by (job) (up)" yes \
  "$(has "$(server_override prometheus-mcp execute_query .description)" 'count by (job) (up)')"
check "prometheus: an empty result points at list_metrics" yes \
  "$(has "$(server_override prometheus-mcp execute_query .description)" 'an empty result usually means a wrong metric name or label value')"
check "prometheus: list_metrics says filter_pattern and limit keep the reply small" yes \
  "$(has "$(server_override prometheus-mcp list_metrics .description)" 'filter_pattern and limit keep the reply small')"
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
  check "proxmox: $tool verbose says what it adds" yes \
    "$(has "$(server_override proxmox-mcp "$tool" .parameters.verbose.description)" 'adds disk and network IO counters')"
done
check "proxmox: get_cluster_resources tells VMs and LXC containers apart" yes \
  "$(has "$(server_override proxmox-mcp get_cluster_resources .description)" 'the type field of each row tells them apart (qemu or lxc)')"
check "k8sgpt: analyze lists the filters" yes "$(has "$(server_override k8sgpt-mcp analyze .description)" 'HorizontalPodAutoscaler')"
explain_rule="$(server_override k8sgpt-mcp analyze '.parameters.explain.rules[0].reject')"
check "k8sgpt: explain=true is refused" yes "$(grep -qP -- "$explain_rule" <<<'true' && echo yes || echo no)"
check "k8sgpt: explain=false passes" no "$(grep -qP -- "$explain_rule" <<<'false' && echo yes || echo no)"
check "k8sgpt: any backend is refused" yes "$(grep -qP -- "$(server_override k8sgpt-mcp analyze '.parameters.backend.rules[0].reject')" <<<'openai' && echo yes || echo no)"
check "code sandbox: execute_code says standard library only" yes \
  "$(has "$(server_override code-sandbox-mcp execute_code .description)" 'Python has the standard library only')"
check "code sandbox: execute_code says a stored result is read in full by key" yes \
  "$(has "$(server_override code-sandbox-mcp execute_code .description)" 'name its key in inputs')"
check "code sandbox: execute_code says only this discussion's results can be named" yes \
  "$(has "$(server_override code-sandbox-mcp execute_code .description)" "only this discussion's stored results can be named")"
for tool in workspace_head workspace_tail workspace_grep; do
  check "workspace: $tool says a call line carries no data" yes "$(has "$(server_override workspace-mcp "$tool" .description)" 'the line carries no data')"
  check "workspace: $tool says what [EMPTY RESULT] means" yes \
    "$(has "$(server_override workspace-mcp "$tool" .description)" 'an [EMPTY RESULT] block after a call line means the call succeeded and returned nothing')"
  check "workspace: $tool says a cut args= text ran in full" yes \
    "$(has "$(server_override workspace-mcp "$tool" .description)" 'args= may end with "(args cut at <n> of <m> chars)": the call ran with the full arguments')"
done
check "workspace: the query tools keep the server's own descriptions" 0 \
  "$(yq -N 'select(.kind == "MCPServer" and .metadata.name == "workspace-mcp") | .spec.toolOverrides[].name' <<<"$out_all" | grep -cE 'workspace_(query|list|describe)' || true)"

# The checks below count offenders, so first make sure there is something to count.
override_count="$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[].name' <<<"$out_all" | count)"
check "overrides: every server's overrides were rendered (9 + 4 + 6 + 1 + 1 + 3)" 24 "$override_count"
# A description states facts: every line is DESCRIPTION or ASSERT, never a rule (WHEN, THEN,
# ALWAYS, NEVER), and so is every message a rule answers with.
override_texts() {
  yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[] | [.description, (.parameters // {} | .[] | .description), (.parameters // {} | .[] | .rules // [] | .[] | .message)] | .[] | select(. != null)' <<<"$1"
}
check "overrides: every tool description opens with DESCRIPTION" 0 \
  "$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[] | select(has("description")) | .description | split("\n") | .[0]' <<<"$out_all" \
    | grep -vc '^DESCRIPTION ' || true)"
check "overrides: every line is DESCRIPTION or ASSERT" 0 "$(override_texts "$out_all" | grep -v '^$' | grep -cvE '^(DESCRIPTION|ASSERT) ' || true)"
check "overrides: no WHEN, THEN, ALWAYS or NEVER" 0 "$(override_texts "$out_all" | grep -cwE 'WHEN|THEN|ALWAYS|NEVER' || true)"
# CRD limits: a description is at most 4000 characters, a parameter description at most 2000.
check "overrides: no description over 4000 characters" 0 \
  "$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[] | .description // "" | length' <<<"$out_all" | awk '$1 > 4000' | wc -l | tr -d ' ')"
check "overrides: no parameter description over 2000 characters" 0 \
  "$(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[] | .parameters // {} | .[].description | length' <<<"$out_all" | awk '$1 > 2000' | wc -l | tr -d ' ')"
# An override names a tool some agent has, so none describes a tool no agent can call.
enabled="$(agent_tools "$out_all")"
check "overrides: agents enable tools" yes "$([ -n "$enabled" ] && echo yes || echo no)"
for tool in $(yq -N 'select(.kind == "MCPServer") | .spec.toolOverrides // [] | .[].name' <<<"$out_all"); do
  check "overrides: $tool is enabled on an agent" yes "$(grep -qxF "$tool" <<<"$enabled" && echo yes || echo no)"
done

# What the coordinator reads per agent when it picks: the description. Each worker says what it
# reads, each advisor that it reviews and fact-checks, compute that it fetches nothing; the texts
# name no cluster of their own, and no two agents share a description.
agent_field() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.$2" <<<"$out_all"; }
workers=(k8s-config k8s-helm k8s-metrics k8s-nodes k8s-scaling k8s-services k8s-storage k8s-workloads k8sgpt
  nvidia-gpu-history nvidia-gpu-meta nvidia-gpu-now obs-metrics proxmox-pve proxmox-qm)
for name in "${workers[@]}"; do
  check "descriptions: $name says what it reads" yes \
    "$(grep -qE '^(Reads|Measures|Finds|Fetches) ' <<<"$(agent_field "$name" description)" && echo yes || echo no)"
done
for name in k8s-advisor nvidia-gpu-advisor obs-advisor proxmox-advisor; do
  check "descriptions: $name reviews and fact-checks" yes "$(grep -q '^Reviews and fact-checks ' <<<"$(agent_field "$name" description)" && echo yes || echo no)"
  check "descriptions: $name says it adds no data" yes "$(has "$(agent_field "$name" triageSummary)" 'Adds no data of its own')"
  check "descriptions: $name no longer says it has no tools" 0 "$({ agent_field "$name" description; agent_field "$name" triageSummary; } | grep -ciE 'no live tools|fetches no live data' || true)"
done
for phrase in 'with code' 'it fetches nothing' 'select it with the agents that fetch the data'; do
  check "descriptions: compute says '$phrase'" yes "$(has "$(agent_field compute description)" "$phrase")"
done
check "descriptions: compute's summary says a live-data question needs the fetching agents" yes \
  "$(has "$(agent_field compute triageSummary)" 'also needs the agents that fetch that data')"
check "descriptions: k8s-config says it reads ConfigMap contents" yes \
  "$(has "$(agent_field k8s-config description)" 'ConfigMap contents (keys and values, such as a setting, a schedule or a policy)')"
check "descriptions: k8s-config never reads Secret values" yes "$(has "$(agent_field k8s-config description)" 'never their values')"
keywords() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.discussKeywords // [] | .[]" <<<"$out_all"; }
check "descriptions: without Secret reads k8s-config claims no Secrets" 0 \
  "$(yq -N 'select(.kind == "Agent" and .metadata.name == "k8s-config") | (.spec.description, .spec.triageSummary, (.spec.discussKeywords | join(" ")))' <<<"$out" | grep -ci 'secret' || true)"
check "keywords: the advisors carry no teaching words" 0 \
  "$(for a in k8s-advisor proxmox-advisor; do keywords "$a"; done | grep -cxE 'concept|explain|tutorial|howto|cli|guide|setup|configure|recommend|troubleshoot|debug|pvesh|qm|pct' || true)"
check "keywords: the scheduler does not claim the recheck words" 0 "$(keywords scheduler-advisor | grep -cxE 'recheck|check again' || true)"
check "nvidia-gpu-now can list the metric names" yes "$(agent_field nvidia-gpu-now 'enabledTools | join(" ")' | grep -qw list_metrics && echo yes || echo no)"
for other in k8s-helm k8sgpt; do
  check "descriptions: $other does not claim ConfigMap contents" 0 \
    "$({ agent_field "$other" description; agent_field "$other" triageSummary; } | grep -ci 'configmap' || true)"
done
check "descriptions: k8s-helm reads releases only" yes "$(has "$(agent_field k8s-helm description)" 'Reads Helm releases only')"
check "descriptions: k8s-nodes names capacity and allocatable" yes "$(has "$(agent_field k8s-nodes description)" 'capacity and allocatable')"
check "descriptions: k8s-workloads names requests and limits" yes "$(has "$(agent_field k8s-workloads description)" 'CPU and memory requests and limits')"
for setting in false true; do
  write_ns=null; [ "$setting" = true ] && write_ns="{apps}"
  write_out="$(render "${all_on[@]}" --set kubernetesAccess.write.namespaces="$write_ns")"
  check "descriptions: k8s-helm mentions install only with write access ($setting)" "$setting" \
    "$(yq -N 'select(.kind == "Agent" and .metadata.name == "k8s-helm") | .spec.description | test("Installs and uninstalls")' <<<"$write_out")"
  check "descriptions: k8s-scaling mentions scaling only with write access ($setting)" "$setting" \
    "$(yq -N 'select(.kind == "Agent" and .metadata.name == "k8s-scaling") | .spec.description | test("Scales a")' <<<"$write_out")"
done
# The keywords the sheet removed: words every agent shares, and the scheduler's weekdays.
keywords() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.discussKeywords // [] | .[]" <<<"$out_all"; }
check "keywords: k8s-workloads no longer claims generic words" 0 "$(keywords k8s-workloads | grep -cxE 'kubernetes|k8s|status|error|healthy' || true)"
check "keywords: the scheduler names no weekday" 0 "$(keywords scheduler-advisor | grep -cxE 'monday|tuesday|wednesday|thursday|friday|saturday|sunday|daily|weekly|tomorrow|tonight' || true)"
check "keywords: internet-search does not match every question" 0 "$(keywords internet-search | grep -cxF '*' || true)"
check "keywords: k8s-helm does not claim install" 0 "$(keywords k8s-helm | grep -cxE 'install|uninstall|values' || true)"
check "relevance: the scheduler's hint is ADL" yes \
  "$(agent_field scheduler-advisor discussRelevance.promptHint | head -1 | grep -q '^DEFINE COMPONENT ' && echo yes || echo no)"
check "triage: no agent overrides the runtime's triage prompt" 0 \
  "$(yq -N 'select(.kind == "Agent") | .spec.deployment.env // [] | .[] | select(.name == "KUBEMOOT_DISCUSS_TRIAGE_PROMPT") | .name' <<<"$out_all" | count)"
# The texts the resume embeds: each agent's description and summary, and each module's DESCRIPTION lines.
specialist_texts() {
  yq -N 'select(.kind == "Agent" and .spec.discussRole != "coordinator") | (.spec.description, .spec.triageSummary)' <<<"$out_all"
  yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$out_all"
}
texts="$(specialist_texts)"
check "descriptions: no agent text or module names Talos, a rig or a homelab" 0 "$(grep -ciE 'talos|homelab|rig[0-9]' <<<"$texts" || true)"
check "descriptions: no agent text or module holds a non-ASCII character" 0 "$(LC_ALL=C grep -c '[^[:print:][:space:]]' <<<"$texts" || true)"
check "descriptions: no two agents share a description" 0 \
  "$(yq -N 'select(.kind == "Agent") | .spec.description' <<<"$out_all" | sort | uniq -d | count)"

# The removed values do nothing but print a note: the render is the same with them set.
old="$(render --set discussion.peerVerification.enabled=true --set discussion.factChecker.enabled=true --set discussion.factChecker.liveRead=true)"
check "removed values: discussion.peerVerification and discussion.factChecker change nothing" "$out" "$old"
old_notes="$(notes --set discussion.peerVerification.enabled=true --set discussion.factChecker.enabled=false)"
check "removed values: the notes say peerVerification was removed" yes "$(has "$old_notes" 'REMOVED: discussion.peerVerification')"
check "removed values: the notes say factChecker was removed" yes "$(has "$old_notes" 'REMOVED: discussion.factChecker')"
check "removed values: no note without them" no "$(has "$(notes)" 'REMOVED:')"
check "removed values: the notes say kubernetesLegacy was removed" yes "$(has "$(notes --set mcpServers.kubernetesLegacy.enabled=true)" 'REMOVED: mcpServers.kubernetesLegacy')"
check "removed values: kubernetesLegacy renders no second server" "$out" "$(render --set mcpServers.kubernetesLegacy.enabled=true)"

# The tool names themselves are checked against what each server lists (CI runs this script).
bash "$chart/tests/test-server-tools.sh" || failures=$((failures + 1))

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
