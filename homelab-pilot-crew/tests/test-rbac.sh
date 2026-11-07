#!/usr/bin/env bash
# Render tests for the pilot crew's ServiceAccounts and RBAC. Namespaced reads, Secret reads and
# write access come from the Kubemoot operator, bound per namespace that consents with a label,
# so this chart holds no cluster-wide binding to them. What it keeps is a small read-only
# ClusterRole of cluster-scoped kinds for each ServiceAccount, and the annotation that asks the
# operator for the extra access. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-rbac.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"

out="$(render)"
doc() { yq -N "select(.kind == \"$2\" and .metadata.name == \"$3\") | $4" <<<"$1"; }
sa_of() { doc "$1" MCPServer "$2" .spec.serviceAccountName; }
access_of() { doc "$1" MCPServer "$2" '.metadata.annotations["kubemoot.ai/kubernetes-access"] // ""'; }
# The resources a ClusterRole names, one per line, sorted; its verbs, sorted and joined.
res_of() { doc "$1" ClusterRole "$2" '.rules[].resources[]' | sort | paste -sd, -; }
verbs_of() { doc "$1" ClusterRole "$2" '.rules[].verbs[]' | sort -u | paste -sd, -; }
groups_of() { doc "$1" ClusterRole "$2" '.rules[].apiGroups[] | select(. == "") = "(core)"' | sort -u | paste -sd, -; }

# Each server keeps its own ServiceAccount; k8sgpt does not share the Kubernetes servers' one.
check "k8sgpt runs as its own ServiceAccount" "t-k8sgpt-mcp" "$(sa_of "$out" k8sgpt-mcp)"
check "the ServiceAccount k8sgpt names is rendered" "t-k8sgpt-mcp" "$(doc "$out" ServiceAccount t-k8sgpt-mcp .metadata.name)"
check "the Kubernetes MCP server keeps the shared ServiceAccount" "t-kubernetes-mcp" "$(sa_of "$out" t-kubernetes-mcp)"
check "k8sgpt does not share the Kubernetes servers' ServiceAccount" "no" \
  "$([ "$(sa_of "$out" k8sgpt-mcp)" = "$(sa_of "$out" t-kubernetes-mcp)" ] && echo yes || echo no)"

# Every ClusterRoleBinding here joins one account to its own small role, in the release namespace.
for who in kubernetes k8sgpt; do
  name="t-$who-mcp"
  check "the $who binding names its own role" "$name" "$(doc "$out" ClusterRoleBinding "$name" .roleRef.name)"
  check "the $who binding names its ServiceAccount" "$name" "$(doc "$out" ClusterRoleBinding "$name" .subjects[0].name)"
  check "the $who binding names the release namespace" "default" "$(doc "$out" ClusterRoleBinding "$name" .subjects[0].namespace)"
done
check "no binding reaches the view role" "0" "$(yq -N 'select(.kind == "ClusterRoleBinding" and .roleRef.name == "view") | .metadata.name' <<<"$out" | grep -c . || true)"
check "this chart renders exactly two ClusterRoleBindings" "2" "$(yq -N 'select(.kind == "ClusterRoleBinding") | .metadata.name' <<<"$out" | grep -c .)"

# The Kubernetes servers' cluster-scoped kinds, each read by an agent (see the template header).
check "the Kubernetes role names only the reviewed cluster-scoped kinds" \
  "clusterrolebindings,clusterroles,customresourcedefinitions,nodes,persistentvolumes,storageclasses" "$(res_of "$out" t-kubernetes-mcp)"
check "the Kubernetes role only reads" "get,list,watch" "$(verbs_of "$out" t-kubernetes-mcp)"
check "the Kubernetes role names only reviewed API groups" "(core),apiextensions.k8s.io,rbac.authorization.k8s.io,storage.k8s.io" "$(groups_of "$out" t-kubernetes-mcp)"

# Every kind the Kubernetes role keeps is one an agent is told to read: the prompt modules and
# agents name it, so a kind nobody reads cannot stay.
for kind in 'kind="Node"' 'kind="PersistentVolume"' 'kind="StorageClass"' 'kind="CustomResourceDefinition"' 'ClusterRoleBinding'; do
  check "an agent reads $kind" "yes" "$(has "$(cat "$chart"/templates/promptmodule-specialists.yaml "$chart"/templates/agent-k8s-*.yaml)" "$kind")"
done

# k8sgpt: the cluster-scoped kinds its analyzers read, read-only, and nothing namespaced.
check "the k8sgpt role names the reviewed cluster-scoped kinds" \
  "gatewayclasses,ingressclasses,mutatingwebhookconfigurations,nodes,persistentvolumes,storageclasses,validatingwebhookconfigurations" \
  "$(res_of "$out" t-k8sgpt-mcp)"
check "k8sgpt can only read" "get,list,watch" "$(verbs_of "$out" t-k8sgpt-mcp)"
check "the k8sgpt role names the reviewed API groups" \
  "(core),admissionregistration.k8s.io,gateway.networking.k8s.io,networking.k8s.io,storage.k8s.io" "$(groups_of "$out" t-k8sgpt-mcp)"

# Default values ask the operator for nothing beyond the read role.
check "default values: the Kubernetes server asks for no extra access" "" "$(access_of "$out" t-kubernetes-mcp)"
check "default values: the legacy server asks for no extra access" "" "$(access_of "$out" t-kubernetes-legacy-mcp)"
check "default values: k8sgpt asks for no extra access" "" "$(access_of "$out" k8sgpt-mcp)"

# Secret reads and write access are asked for by annotation, never by a role in this chart.
all="$(render "${all_on[@]}")"
check "secretRead and writeAccess on: the Kubernetes server asks for secrets and write" "secrets,write" "$(access_of "$all" t-kubernetes-mcp)"
check "secretRead and writeAccess on: the legacy server asks the same" "secrets,write" "$(access_of "$all" t-kubernetes-legacy-mcp)"
check "secretRead and writeAccess on: k8sgpt asks only to get one Secret" "secret-get" "$(access_of "$all" k8sgpt-mcp)"
check "secretRead and writeAccess on: the Kubernetes role is unchanged" \
  "$(res_of "$out" t-kubernetes-mcp)" "$(res_of "$all" t-kubernetes-mcp)"
check "secretRead and writeAccess on: no role in this chart names secrets or exec" "0" \
  "$(yq -N 'select(.kind == "ClusterRole" or .kind == "Role") | .rules[].resources[]' <<<"$all" | grep -c -x -e secrets -e pods/exec || true)"
read_only="$(render --set kubernetesAccess.secretRead=true)"
check "secretRead only: the Kubernetes server asks for secrets" "secrets" "$(access_of "$read_only" t-kubernetes-mcp)"
write_only="$(render --set kubernetesAccess.writeAccess=true)"
check "writeAccess only: the Kubernetes server asks for write" "write" "$(access_of "$write_only" t-kubernetes-mcp)"
check "writeAccess only: k8sgpt asks for nothing" "" "$(access_of "$write_only" k8sgpt-mcp)"

# Switching k8sgpt off removes all three objects and leaves the Kubernetes servers alone.
off="$(render --set mcpServers.k8sgpt.enabled=false)"
check "k8sgpt off: no k8sgpt ServiceAccount" "" "$(doc "$off" ServiceAccount t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: no k8sgpt ClusterRole" "" "$(doc "$off" ClusterRole t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: no k8sgpt ClusterRoleBinding" "" "$(doc "$off" ClusterRoleBinding t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: the Kubernetes ServiceAccount stays" "t-kubernetes-mcp" "$(doc "$off" ServiceAccount t-kubernetes-mcp .metadata.name)"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
