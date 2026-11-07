#!/usr/bin/env bash
# Shared helpers for the pilot crew's render tests. Source it after setting chart to the
# chart directory. Needs helm and yq.
# shellcheck disable=SC2034  # failures and all_on are read by the scripts that source this
: "${chart:?set chart to the chart directory before sourcing lib.sh}"
command -v helm >/dev/null || { echo "helm is required"; exit 1; }
command -v yq >/dev/null || { echo "yq is required"; exit 1; }

# A command that fails (a helm error, say) prints a FAIL line with its command instead of ending
# the script silently under set -e. -E lets the trap fire inside $( ).
set -E
trap 'echo "FAIL: command failed (exit $?) at ${BASH_SOURCE[1]:-?}:${BASH_LINENO[0]}: $BASH_COMMAND" >&2' ERR

failures=0
check() {
  if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; failures=$((failures + 1)); fi
}
render() { helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@"; }
# The tools every Agent in a rendering enables, one per line, sorted.
agent_tools() { yq -N 'select(.kind == "Agent") | .spec.enabledTools // [] | .[]' <<<"$1" | sort -u; }
has() { if grep -q -F -- "$2" <<<"$1"; then echo yes; else echo no; fi; }
# Every optional tool and server switched on.
all_on=(--set 'kubernetesAccess.secretRead.namespaces={kube-system}' --set 'kubernetesAccess.write.namespaces={apps}' --set compute.workspaceQuery=true
  --set mcpServers.proxmox.enabled=true --set mcpServers.proxmox.image=x --set mcpServers.scheduling.enabled=true)

# The install notes a render prints. NOTES.txt only includes a helper, so a copy of the chart
# renders the same helper into a ConfigMap that helm template keeps. Arguments are helm --set
# flags. Works on Helm 3 and 4 with no cluster.
notes() {
  local probe
  probe="$(mktemp -d)"
  trap 'rm -rf "$probe"' RETURN
  cp -r "$chart/." "$probe/"
  printf '%s\n' 'apiVersion: v1' 'kind: ConfigMap' 'metadata:' '  name: notes-probe' 'data:' \
    '  notes: {{ include "homelab-pilot-crew.accessNotes" . | toJson }}' >"$probe/templates/notes-probe.yaml"
  helm template t "$probe" --set ragSources.enabled=false --set vectorStore.host=db.test "$@" \
    | yq -N 'select(.metadata.name == "notes-probe") | .data.notes'
}
