#!/usr/bin/env bash
# Render tests for the tool smoke inputs (mcp-smoke/<server>.yaml, rendered into each MCPServer's
# spec.smokeInputs): every declared tool is one the server lists, none is a write tool, a file's
# inputs reach only its own server, and the namespace placeholder is filled. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-smoke-inputs.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$chart/tests/server-tools.yaml"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"

out_all="$(render "${all_on[@]}" -n crew-smoke)"
declared() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"$1\") | .spec.smokeInputs // [] | .[].name" <<<"$out_all" | sort -u; }
listed() { yq -N ".servers.\"$1\".$2 // [] | .[]" "$fixture" | sort -u; }
outside() { comm -23 <(printf '%s\n' "$1" | sed '/^$/d') <(printf '%s\n' "$2" | sed '/^$/d') | tr '\n' ' ' | sed 's/ $//'; }

# fixture key -> rendered MCPServer name (the kubernetes server is named after the release).
for pair in kubernetes:t-kubernetes-mcp prometheus:prometheus-mcp proxmox:proxmox-mcp k8sgpt:k8sgpt-mcp; do
  key="${pair%%:*}"; name="${pair#*:}"
  mine="$(declared "$name")"
  check "$key: at least one smoke input is declared" yes "$([ -n "$mine" ] && echo yes || echo no)"
  check "$key: every declared tool is one the server lists" "" "$(outside "$mine" "$(listed "$key" tools)")"
  check "$key: no declared tool is a write tool" "" "$(outside "$mine" "$(comm -23 <(printf '%s\n' "$mine") <(listed "$key" write))")"
done

# Servers with no file declare nothing.
check "servers without a file declare no inputs" "" \
  "$(yq -N 'select(.kind == "MCPServer" and (.metadata.name | test("workspace|web-search|code-sandbox|scheduling"))) | select((.spec.smokeInputs // []) | length > 0) | .metadata.name' <<<"$out_all" | tr '\n' ' ' | sed 's/ $//')"

# The placeholder is the release namespace.
check "kubernetes smoke reads the release namespace" crew-smoke \
  "$(yq -N 'select(.kind == "MCPServer" and .metadata.name == "t-kubernetes-mcp") | .spec.smokeInputs[] | select(.name == "pods_list_in_namespace") | .arguments.namespace' <<<"$out_all")"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
