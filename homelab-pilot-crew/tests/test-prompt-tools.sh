#!/usr/bin/env bash
# Render tests for the tools the pilot crew's prompts name: the shared modules list an
# agent's tools with the ${agent.tools} placeholder instead of naming tools, and no agent's
# PromptModules name a tool the agent does not have, with the optional tools switched on and
# off (kubernetesAccess.secretRead and writeAccess, compute.workspaceQuery). Needs helm and yq.
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
all_on=(--set kubernetesAccess.secretRead=true --set kubernetesAccess.writeAccess=true --set compute.workspaceQuery=true)
export VOCAB_ARGS="${all_on[*]}"
check "default values: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" >/dev/null 2>&1; echo $?)"
check "optional tools on: modules name only the agent's own tools" 0 "$(bash "$checker" "$chart" "${all_on[@]}" >/dev/null 2>&1; echo $?)"
check "secretRead only: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set kubernetesAccess.secretRead=true >/dev/null 2>&1; echo $?)"
check "workspaceQuery only: modules name only the agent's own tools" 0 \
  "$(bash "$checker" "$chart" --set compute.workspaceQuery=true >/dev/null 2>&1; echo $?)"

# The compute module is the same text whether or not the workspace_query tool is offered.
a="$(render | yq -N 'select(.kind == "PromptModule" and .metadata.name == "compute-system") | .spec.content')"
b="$(render --set compute.workspaceQuery=true | yq -N 'select(.kind == "PromptModule" and .metadata.name == "compute-system") | .spec.content')"
check "compute-system does not differ between the workspace_query arms" "$a" "$b"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
