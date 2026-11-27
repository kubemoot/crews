#!/usr/bin/env bash
# Render tests for the four domain advisors, the crew's fact-checkers. Each is an analyst with
# domains, loads the advisor contract, and has read and compute tools only: the workspace read
# tools, execute_code, its documentation, and with advisors.liveRead the read tools of its domain's
# live source. The separate fact-checker agent is gone. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-advisors.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
checker="$chart/../scripts/check-module-tools.sh"
# shellcheck source=homelab-pilot-crew/tests/lib.sh
. "$chart/tests/lib.sh"

agent() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$2\") | $3" <<<"$1"; }
tools() { agent "$1" "$2" '.spec.enabledTools | join(" ")'; }
count() { grep -c . || true; }
advisors=(k8s-advisor nvidia-gpu-advisor obs-advisor proxmox-advisor)
proxmox=(--set mcpServers.proxmox.enabled=true --set mcpServers.proxmox.image=x)

out="$(render "${proxmox[@]}")"
check "no fact-checker agent" 0 "$(agent "$out" fact-checker .metadata.name | count)"
check "no fact-checker module" 0 "$(yq -N 'select(.kind == "PromptModule" and .metadata.name == "fact-checker-system") | .metadata.name' <<<"$out" | count)"

base='execute_code workspace_head workspace_tail workspace_grep workspace_query workspace_describe'
declare -A live=(
  [k8s-advisor]='resources_list resources_get pods_list pods_list_in_namespace events_list'
  [nvidia-gpu-advisor]='execute_query'
  [obs-advisor]='execute_query'
  [proxmox-advisor]='list_nodes list_vms get_cluster_resources'
)
nolive="$(render "${proxmox[@]}" --set advisors.liveRead=false)"
noquery="$(render "${proxmox[@]}" --set advisors.workspaceQuery=false)"
allowed="$base ${live[*]}"
for a in "${advisors[@]}"; do
  check "$a: an analyst, so it reviews and never gathers" analyst "$(agent "$out" "$a" .spec.discussRole)"
  check "$a: declares domains, so it reviews its own domain" yes "$([ -n "$(agent "$out" "$a" '.spec.domains // [] | .[]')" ] && echo yes || echo no)"
  check "$a: loads the advisor contract" "crew-invariants,advisor,$a-system" "$(agent "$out" "$a" '.spec.promptRefs | join(",")')"
  check "$a: workspace access is read" read "$(agent "$out" "$a" .spec.workspace.access)"
  check "$a: calls tools" "reasoning,tool-calling" "$(agent "$out" "$a" '.spec.capabilities | join(",")')"
  check "$a: its tools" "$base ${live[$a]}" "$(tools "$out" "$a")"
  check "$a: liveRead off leaves the stored results and code" "$base" "$(tools "$nolive" "$a")"
  check "$a: workspaceQuery off drops the query tools" "execute_code workspace_head workspace_tail workspace_grep ${live[$a]}" "$(tools "$noquery" "$a")"
  check "$a: workspaceQuery off denies the query tools" "workspace_query workspace_describe" "$(agent "$noquery" "$a" '.spec.disabledTools | join(" ")')"
  check "$a: every tool is a read or compute tool" "" "$(for x in $(agent "$out" "$a" '.spec.enabledTools[]'); do grep -qwF -- "$x" <<<"$allowed" || echo "$x"; done)"
  check "$a: no write tool" 0 "$(agent "$out" "$a" '.spec.enabledTools[]' | grep -vE '^execute_(code|query)$' | grep -cE 'create|delete|patch|apply|install|scale|exec|restart' || true)"
  check "$a: sets no triage prompt of its own" 0 "$(agent "$out" "$a" '.spec.deployment.env // [] | .[] | select(.name == "KUBEMOOT_DISCUSS_TRIAGE_PROMPT") | .name' | count)"
done
# A live source that is off gives its advisor no live tools.
noprom="$(render --set mcpServers.prometheus.enabled=false)"
check "prometheus off: nvidia-gpu-advisor has no live tool" "$base" "$(tools "$noprom" nvidia-gpu-advisor)"
check "proxmox off: proxmox-advisor has no live tool" "$base" "$(tools "$(render)" proxmox-advisor)"

# Switching liveRead off changes only the advisors' tool lists.
strip() { yq -N '(select(.kind == "Agent" and (.metadata.name | test("-advisor$")) and .metadata.name != "scheduler-advisor") | .spec.enabledTools) |= []' <<<"$1"; }
check "liveRead off: the rest of the render is unchanged" "$(strip "$out")" "$(strip "$nolive")"
check "modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" "${proxmox[@]}" >/dev/null 2>&1; echo $?)"
check "liveRead off: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" "${proxmox[@]}" --set advisors.liveRead=false >/dev/null 2>&1; echo $?)"

# Each advisor's own module says what it checks, against what, and where its documentation comes from.
for a in "${advisors[@]}"; do
  mod="$(yq -N "select(.kind == \"PromptModule\" and .metadata.name == \"$a-system\") | .spec.content" <<<"$out")"
  check "$a-system: checks against the stored results and the live source" yes "$(has "$mod" 'against the stored results, the live')"
  check "$a-system: says where its documentation comes from" yes "$(has "$mod" 'the documentation you are given arrives with the question')"
  check "$a-system: no longer says it has no tools" 0 "$(grep -c 'NO tools' <<<"$mod" || true)"
  check "$a-system: lists no answerable questions" 0 "$(grep -c '^WHEN asked' <<<"$mod" || true)"
done

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
