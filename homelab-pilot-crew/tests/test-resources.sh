#!/usr/bin/env bash
# Render tests for the sizes of the pilot crew's Go MCP servers: scheduling-mcp asks for 5m and
# 16Mi, and workspace-mcp has a memory limit and no CPU limit, so a query burst is not throttled.
# Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-resources.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"

out="$(render "${all_on[@]}")"
res() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"$1\") | .spec.resources | $2" <<<"$out"; }

check "scheduling-mcp CPU request" "5m" "$(res scheduling-mcp .requests.cpu)"
check "scheduling-mcp memory request" "16Mi" "$(res scheduling-mcp .requests.memory)"
check "scheduling-mcp keeps its 200m CPU limit" "200m" "$(res scheduling-mcp .limits.cpu)"
check "scheduling-mcp keeps its 64Mi memory limit" "64Mi" "$(res scheduling-mcp .limits.memory)"
check "workspace-mcp has no CPU limit" "null" "$(res workspace-mcp .limits.cpu)"
check "workspace-mcp keeps its 512Mi memory limit" "512Mi" "$(res workspace-mcp .limits.memory)"
check "workspace-mcp still asks for 50m CPU and 256Mi" "50m 256Mi" "$(res workspace-mcp .requests.cpu) $(res workspace-mcp .requests.memory)"
# A limit a user sets is rendered as written.
out="$(render "${all_on[@]}" --set mcpServers.workspace.resources.limits.cpu=2)"
check "a CPU limit the user sets is kept" "2" "$(res workspace-mcp .limits.cpu)"

[ "$failures" = 0 ] || exit 1
echo "all passed"
