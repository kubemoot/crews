#!/usr/bin/env bash
# Render tests for the optional fact-checker agent (discussion.factChecker.enabled, on by
# default): set false it renders no agent and no module; on renders one analyst with no domains, the
# fact-checker-system module, read-only tools, and the CONCERN reply convention. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-fact-checker.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
checker="$chart/../scripts/check-module-tools.sh"
# shellcheck source=homelab-pilot-crew/tests/lib.sh
. "$chart/tests/lib.sh"

agent() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"fact-checker\") | $2" <<<"$1"; }
module() { yq -N 'select(.kind == "PromptModule" and .metadata.name == "fact-checker-system") | .spec.content' <<<"$1"; }
count() { grep -c . || true; }

off="$(render --set discussion.factChecker.enabled=false)"
default="$(render)"
check "off: no fact-checker agent" 0 "$(agent "$off" .metadata.name | count)"
check "off: no fact-checker module" 0 "$(module "$off" | count)"
check "off: no agent lists the module" 0 "$(yq -N 'select(.kind == "Agent") | .spec.promptRefs[]' <<<"$off" | grep -c fact-checker || true)"

check "default: the fact-checker is on" 1 "$(agent "$default" .metadata.name | count)"
on="$(render --set discussion.factChecker.enabled=true)"
check "on: one fact-checker agent" 1 "$(agent "$on" .metadata.name | count)"
check "on: an analyst, so it reviews and never gathers" analyst "$(agent "$on" .spec.discussRole)"
check "on: declares no domains, so it reviews every discussion" 0 "$(agent "$on" '.spec.domains // [] | .[]' | count)"
check "on: workspace access is read" read "$(agent "$on" .spec.workspace.access)"
check "on: lists the module" yes "$(has "$(agent "$on" '.spec.promptRefs | join(",")')" fact-checker-system)"
check "on: lists ratify-prompt, so it traces the draft answer" yes "$(has "$(agent "$on" '.spec.promptRefs | join(",")')" ratify-prompt)"
check "on: sets its own triage prompt" 1 "$(agent "$on" '.spec.deployment.env[] | select(.name == "KUBEMOOT_DISCUSS_TRIAGE_PROMPT") | .name' | count)"
check "on: its tools" "workspace_head workspace_tail workspace_grep workspace_query workspace_describe resources_list resources_get pods_list pods_list_in_namespace events_list" \
  "$(agent "$on" '.spec.enabledTools | join(" ")')"
allowed='workspace_head workspace_tail workspace_grep workspace_query workspace_describe resources_list resources_get pods_list pods_list_in_namespace events_list'
check "on: every tool is on the read allow-list" "" "$(for x in $(agent "$on" '.spec.enabledTools[]'); do grep -qwF "$x" <<<"$allowed" || echo "$x"; done)"
check "on: the module never reads a Secret" yes "$(has "$(module "$on")" 'NEVER read the contents of a Secret; a claim about one is UNVERIFIED')"
check "on: the override names the NOTHING_TO_ADD invariant" yes "$(has "$(module "$on")" 'NEVER say NOTHING_TO_ADD just because someone else already spoke')"
check "on: the module reuses the call line notes" yes "$(has "$(module "$on")" 'an [EMPTY RESULT] block after a call line means the call succeeded')"
check "on: the module never counts by eye" yes "$(has "$(module "$on")" 'never count by eye')"
check "on: the triage stands aside on no [CALL line" yes "$(has "$(agent "$on" '.spec.deployment.env[] | select(.name == "KUBEMOOT_DISCUSS_TRIAGE_PROMPT") | .value')" 'shows no [CALL ...] line THEN reply NOTHING_TO_ADD')"
check "on: the module renders" 1 "$(grep -c 'DEFINE DOMAIN fact-checker' <<<"$(module "$on")")"
check "on: the module carries the CONCERN form" yes "$(has "$(module "$on")" 'CONCERN: <the claim, why it is wrong or unverified, the source you checked>')"
check "on: the module stands aside in evaluation" yes "$(has "$(module "$on")" 'reply exactly NOTHING_TO_ADD')"
check "on: the module makes a failed read a concern" yes "$(has "$(module "$on")" 'a failed read is never an agree')"
check "on: the module makes a claim with no stored result a concern" yes "$(has "$(module "$on")" 'has no stored result behind it THEN it is a concern')"
check "on: the module never supplies its own value" yes "$(has "$(module "$on")" 'NEVER supply a value')"
# shellcheck disable=SC2016  # the placeholder is literal text
check "on: the module lists the tools with the placeholder" 1 "$(grep -c -F '${agent.tools}' <<<"$(module "$on")")"
check "on: the module has no Markdown headings" 0 "$(grep -c '^#' <<<"$(module "$on")" || true)"
check "on: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" --set discussion.factChecker.enabled=true >/dev/null 2>&1; echo $?)"

# Switching it on adds the agent and the module and changes nothing else.
strip() { yq -N 'select((.kind != "Agent" or .metadata.name != "fact-checker") and (.kind != "PromptModule" or .metadata.name != "fact-checker-system"))' <<<"$1"; }
check "on: the rest of the render is unchanged" "$(strip "$off")" "$(strip "$on")"
# Its domains are the only ones still undeclared beside compute and scheduler-advisor.
check "on: the other agents keep their domains" "" \
  "$(for a in $(yq -N 'select(.kind == "Agent" and (.spec.discussRole == "tooler" or .spec.discussRole == "analyst")) | .metadata.name' <<<"$on" | sort); do
       [ -n "$(yq -N "select(.kind == \"Agent\" and .metadata.name == \"$a\") | .spec.domains // [] | .[]" <<<"$on")" ] || echo "$a"
     done | grep -vxE 'compute|scheduler-advisor|fact-checker' || true)"

# liveRead=false leaves the workspace tools alone.
nolive="$(render --set discussion.factChecker.enabled=true --set discussion.factChecker.liveRead=false)"
check "liveRead off: workspace tools only" "workspace_head workspace_tail workspace_grep workspace_query workspace_describe" "$(agent "$nolive" '.spec.enabledTools | join(" ")')"
check "liveRead off: still has tool-calling, for the workspace tools" "reasoning,tool-calling" "$(agent "$nolive" '.spec.capabilities | join(",")')"

# advisors.workspaceQuery=false drops the query tools and denies them.
noq="$(render --set discussion.factChecker.enabled=true --set advisors.workspaceQuery=false)"
check "workspaceQuery off: no query tools" "workspace_head workspace_tail workspace_grep resources_list resources_get pods_list pods_list_in_namespace events_list" "$(agent "$noq" '.spec.enabledTools | join(" ")')"
check "workspaceQuery off: the query tools are denied" "workspace_query workspace_describe" "$(agent "$noq" '.spec.disabledTools | join(" ")')"

# It composes with peer verification: both modules listed, peer-verification right after discussion-protocol.
both="$(render --set discussion.factChecker.enabled=true --set discussion.peerVerification.enabled=true)"
check "with peer-verification: refs" "discussion-protocol,peer-verification,ratify-prompt,response-style,fact-checker-system" "$(agent "$both" '.spec.promptRefs | join(",")')"

# The coordinator answers only from values a finding or a concern holds (the checker's concerns feed it).
logic="$(yq -N 'select(.kind == "PromptModule") | .spec.content' <<<"$default")"
check "coordinator: values come from a finding, a concern or a stored result" yes \
  "$(has "$logic" 'every number, name and status in the answer comes from a finding, a concern, or a stored result')"
check "coordinator: a concern's correct value replaces the disputed one" yes \
  "$(has "$logic" "the answer uses the concern's value")"
check "coordinator: a disputed value with no verified value is reported undetermined" yes \
  "$(has "$logic" 'the answer says the value could not be determined instead of stating one')"
check "coordinator: no credit for a check no finding shows was run" yes \
  "$(has "$logic" 'NEVER credit a check, query or calculation in the answer unless a finding shows it was run')"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
