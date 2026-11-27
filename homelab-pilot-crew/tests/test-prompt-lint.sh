#!/usr/bin/env bash
# The prompt lint (scripts/check-prompt-rules.sh): no PromptModule line or relevance hint of the
# pilot crew names a tool its MCP servers list (tests/server-tools.yaml) or defers to another
# agent, with the optional tools and switches on and off. What a tool does belongs in the tool's
# description (the MCPServers' toolOverrides), never in a prompt rule. The lint must also catch
# a planted rule, so a lint that silently passes everything fails here. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-prompt-lint.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
lint="$chart/../scripts/check-prompt-rules.sh"
fixture="$chart/tests/server-tools.yaml"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"
# The lint's exit code, and for a failure whether it printed a FAIL line: 0, "1 FAIL", or 2 when it could not run.
verdict() { local err rc=0; err="$(bash "$lint" "$@" 2>&1 >/dev/null)" || rc=$?; if [ "$rc" = 1 ] && grep -q '^FAIL ' <<<"$err"; then echo "1 FAIL"; else echo "$rc"; fi; }
runs() { verdict "$chart" "$fixture" "$@"; }

check "default values: no prompt names a tool or defers" 0 "$(runs)"
check "optional tools on: no prompt names a tool or defers" 0 "$(runs "${all_on[@]}")"
check "signal tool on: no prompt names a tool or defers" 0 "$(runs --set discussion.signalTool.enabled=true)"
check "on-demand documentation: no prompt names a tool or defers" 0 "$(runs --set ragSources.enabled=true --set ragSources.retrieval=tool)"

# A copy of the chart with planted lines: each must fail the lint on its own.
plant() {
  local probe
  probe="$(mktemp -d)"
  cp -r "$chart/." "$probe/"
  printf '%s\n' 'apiVersion: kubemoot.ai/v1alpha1' 'kind: PromptModule' 'metadata:' '  name: planted' 'spec:' '  order: 99' '  content: |' "    $1" >"$probe/templates/planted.yaml"
  verdict "$probe" "$fixture"
  rm -rf "$probe"
}
check "lint catches a WHEN/THEN tool rule" "1 FAIL" "$(plant 'WHEN listing ConfigMaps THEN use resources_list(apiVersion="v1", kind="ConfigMap")')"
check "lint catches a bare tool name" "1 FAIL" "$(plant 'ASSERT pods_get returns restart counts')"
check "lint catches a defer line" "1 FAIL" "$(plant 'WHEN the question is about Helm THEN defer to k8s-helm')"
check "lint passes a role statement" 0 "$(plant 'ASSERT you report a host by its name, not by its address')"
check "lint ignores ordinary words that are also tool names" 0 "$(plant 'ASSERT you search the web and analyze what you find')"
allow="$(mktemp)"
echo 'ASSERT pods_get returns restart counts' >"$allow"
check "lint honors an allowed line" 0 "$(ALLOW_LINES="$allow" plant 'ASSERT pods_get returns restart counts')"
rm -f "$allow"
empty="$(mktemp)"
echo 'servers: {}' >"$empty"
check "lint cannot run with no tools to check for" 2 "$(verdict "$chart" "$empty")"
rm -f "$empty"
check "lint cannot run when the chart does not render" 2 "$(verdict "$chart" "$fixture" --set rbac.render=nonsense)"
skill="$(verdict "$chart" "$fixture" --set skills.promqlResourceUsage.enabled=true --set skills.dcgmGpuMetrics.enabled=true)"
check "the Skills name no tool" 0 "$skill"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
