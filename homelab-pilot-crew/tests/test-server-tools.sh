#!/usr/bin/env bash
# Render tests for the tool names the pilot crew uses against the tools its MCP servers list
# (tests/server-tools.yaml, read from each server at the image the chart pins): every tool an
# agent enables is listed by some server, a Kubernetes tool is one the server's read-only
# mode registers unless writeAccess is on, and every toolOverride names a tool of its own
# server (the gateway ignores an override for a name the server does not list).
# Each server's rendered image must be the one the fixture was read from. It also pins the
# Kubernetes server's config file and the k8s-helm and nvidia-gpu-meta tools. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-server-tools.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
fixture="$chart/tests/server-tools.yaml"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"
listed() { yq -N ".servers.\"$1\".$2 // [] | .[]" "$fixture"; }
every_listed() { yq -N '.servers[] | (.tools // []) + (.write // []) | .[]' "$fixture" | sort -u; }
missing() { comm -23 <(sort -u <<<"$1") <(sort -u <<<"$2") | tr '\n' ' ' | sed 's/ $//'; }
overrides() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"$1\") | .spec.toolOverrides // [] | .[].name" <<<"$2"; }

out="$(render)"
out_all="$(render "${all_on[@]}")"
k8s_read="$(listed kubernetes tools)"
k8s_all="$(printf '%s\n%s\n' "$k8s_read" "$(listed kubernetes write)")"
known="$(every_listed)"

# Each server renders the image its tool list was read from; a changed pin fails here until
# tests/server-tools.yaml is read again from the new image. Proxmox records none: the user
# supplies its image.
rendered_image() {
  yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"$1\") | .spec.image // (\"kubemootImage:\" + .spec.kubemootImage)" <<<"$out_all"
}
for server in $(yq -N '.servers | keys | .[]' "$fixture"); do
  want="$(yq -N ".servers.\"$server\".image // \"\"" "$fixture")"
  [ -n "$want" ] || continue
  check "$server: the chart renders the image the tool list was read from" "$want" \
    "$(rendered_image "$(yq -N ".servers.\"$server\".mcpServer" "$fixture")")"
done
check "fixture: every server but proxmox records its image" "proxmox" \
  "$(yq -N '.servers | to_entries | .[] | select(.value.image == null) | .key' "$fixture" | tr '\n' ' ' | sed 's/ $//')"
check "every MCPServer the chart renders is in the fixture" "" \
  "$(missing "$(yq -N 'select(.kind == "MCPServer") | .metadata.name' <<<"$out_all")" "$(yq -N '.servers[].mcpServer' "$fixture")")"

# Every enabled tool is one a server lists.
check "default values: every enabled tool is listed by a server" "" "$(missing "$(agent_tools "$out")" "$known")"
check "optional tools on: every enabled tool is listed by a server" "" "$(missing "$(agent_tools "$out_all")" "$known")"

# Read-only by default: no agent enables a Kubernetes tool that only write mode registers.
check "default values: no agent enables a Kubernetes write tool" "" \
  "$(comm -12 <(agent_tools "$out") <(listed kubernetes write | sort -u) | tr '\n' ' ' | sed 's/ $//')"

# Each override names a tool of its own server.
check "kubernetes overrides name the server's tools" "" "$(missing "$(overrides t-kubernetes-mcp "$out")" "$k8s_all")"
check "prometheus overrides name the server's tools" "" "$(missing "$(overrides prometheus-mcp "$out")" "$(listed prometheus tools)")"
check "proxmox overrides name the server's tools" "" "$(missing "$(overrides proxmox-mcp "$out_all")" "$(listed proxmox tools)")"
check "the proxmox allow list names the server's tools" "" "$(missing "$(yq -N 'select(.kind == "MCPServer" and .metadata.name == "proxmox-mcp")
  | .spec.env[] | select(.name == "PROXMOX_TOOLS_ALLOW") | .value | split(",") | .[]' <<<"$out_all")" "$(listed proxmox tools)")"

# The Kubernetes server reads only a config file: no runtime flags, the core and helm
# toolsets, read-only unless writeAccess, and no port (stdio through the bridge).
k8s() { yq -N "select(.kind == \"MCPServer\" and .metadata.name == \"t-kubernetes-mcp\") | $1" <<<"$2"; }
config() { yq -N 'select(.kind == "Secret" and .metadata.name == "t-kubernetes-mcp-config") | .stringData."config.toml"' <<<"$1"; }
check "kubernetes: the command passes only --config" "/app/kubernetes-mcp-server --config /etc/kubernetes-mcp/config.toml" \
  "$(k8s '.spec.command | join(" ")' "$out")"
check "kubernetes: the config Secret is mounted where --config points" "t-kubernetes-mcp-config /etc/kubernetes-mcp" \
  "$(k8s '.spec.secretVolumes[0] | .name + " " + .mountPath' "$out")"
check "kubernetes: the config loads the core and helm toolsets" 1 "$(grep -cxF 'toolsets = ["core", "helm"]' <<<"$(config "$out")" || true)"
check "kubernetes: read_only by default" 1 "$(grep -cxF 'read_only = true' <<<"$(config "$out")" || true)"
check "kubernetes: read_only off with writeAccess" 1 \
  "$(grep -cxF 'read_only = false' <<<"$(config "$(render --set kubernetesAccess.writeAccess=true)")" || true)"
check "kubernetes: the config sets no port, so the server speaks stdio" 0 "$(grep -c '^port' <<<"$(config "$out")" || true)"
check "kubernetes: a changed config changes the pod" no \
  "$([ "$(k8s '.spec.env[] | select(.name == "CONFIG_SHA256") | .value' "$out")" = \
      "$(k8s '.spec.env[] | select(.name == "CONFIG_SHA256") | .value' "$(render --set kubernetesAccess.writeAccess=true)")" ] && echo yes || echo no)"
check "kubernetes: the image is pinned by digest" 1 "$(k8s '.spec.image' "$out" | grep -c '@sha256:[0-9a-f]\{64\}$' || true)"

# k8s-helm lists releases with helm_list and nothing else read-only; write adds install and uninstall.
helm_tools() { yq -N 'select(.kind == "Agent" and .metadata.name == "k8s-helm") | .spec.enabledTools | join(" ")' <<<"$1"; }
check "k8s-helm: helm_list only by default" "helm_list" "$(helm_tools "$out")"
check "k8s-helm: helm_list only with secretRead" "helm_list" "$(helm_tools "$(render --set kubernetesAccess.secretRead=true)")"
check "k8s-helm: install and uninstall with writeAccess" "helm_list helm_install helm_uninstall" \
  "$(helm_tools "$(render --set kubernetesAccess.writeAccess=true)")"

# The scrape-target listing is dropped: nothing narrows it and it outgrows a tool result.
check "no agent enables get_targets" 0 "$(agent_tools "$out_all" | grep -cx get_targets || true)"
check "nvidia-gpu-meta: list_metrics and execute_query" "list_metrics execute_query" \
  "$(yq -N 'select(.kind == "Agent" and .metadata.name == "nvidia-gpu-meta") | .spec.enabledTools | join(" ")' <<<"$out")"

# The fixture itself: a missing server or an empty list would make every check above pass.
check "fixture: the kubernetes server lists helm_list read-only" 1 "$(grep -cx helm_list <<<"$k8s_read" || true)"
check "fixture: nine servers, each with tools" 9 "$(yq -N '[.servers[] | select((.tools // []) | length > 0)] | length' "$fixture")"
# The comparison itself reports what it should: a name no server lists, and a write tool.
check "self-test: a name no server lists is reported" "no_such_tool" "$(missing "$(printf 'pods_list\nno_such_tool')" "$known")"
check "self-test: pods_exec is not a read-only Kubernetes tool" "pods_exec" "$(missing pods_exec "$k8s_read")"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
