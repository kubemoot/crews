#!/usr/bin/env bash
# Shared helpers for the pilot crew's render tests. Source it after setting chart to the
# chart directory. Needs helm and yq.
# shellcheck disable=SC2034  # failures and all_on are read by the scripts that source this
: "${chart:?set chart to the chart directory before sourcing lib.sh}"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}
render() { helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@"; }
# The tools every Agent in a rendering enables, one per line, sorted.
agent_tools() { yq -N 'select(.kind == "Agent") | .spec.enabledTools // [] | .[]' <<<"$1" | sort -u; }
has() { if grep -q -F -- "$2" <<<"$1"; then echo yes; else echo no; fi; }
# Every optional tool and server switched on.
all_on=(--set kubernetesAccess.secretRead=true --set kubernetesAccess.writeAccess=true --set compute.workspaceQuery=true
  --set mcpServers.proxmox.enabled=true --set mcpServers.proxmox.image=x --set mcpServers.scheduling.enabled=true)
