#!/usr/bin/env bash
# Render tests for the pilot crew's ServiceAccounts and RBAC: k8sgpt runs as its own
# ServiceAccount with a read-only ClusterRole that never reaches Secrets by default, and the
# Kubernetes MCP servers keep theirs. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-rbac.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"

out="$(render)"
doc() { yq -N "select(.kind == \"$2\" and .metadata.name == \"$3\") | $4" <<<"$1"; }
sa_of() { doc "$1" MCPServer "$2" .spec.serviceAccountName; }
# How many rules of the k8sgpt role name a resource; the verbs of all its rules, sorted.
rules_for() { doc "$1" ClusterRole t-k8sgpt-mcp ".rules[] | select(.resources[] == \"$2\") | .resources[0]" | grep -c . || true; }
verbs() { doc "$1" ClusterRole t-k8sgpt-mcp '.rules[].verbs[]' | sort -u | paste -sd, -; }

# k8sgpt has its own ServiceAccount, and the Kubernetes servers keep the shared one.
check "k8sgpt runs as its own ServiceAccount" "t-k8sgpt-mcp" "$(sa_of "$out" k8sgpt-mcp)"
check "the ServiceAccount k8sgpt names is rendered" "t-k8sgpt-mcp" "$(doc "$out" ServiceAccount t-k8sgpt-mcp .metadata.name)"
check "the Kubernetes MCP server keeps the shared ServiceAccount" "t-kubernetes-mcp" "$(sa_of "$out" t-kubernetes-mcp)"
check "k8sgpt does not share the Kubernetes servers' ServiceAccount" "no" \
  "$([ "$(sa_of "$out" k8sgpt-mcp)" = "$(sa_of "$out" t-kubernetes-mcp)" ] && echo yes || echo no)"

# The binding joins that ServiceAccount to its own ClusterRole, in the release namespace.
check "the binding names the k8sgpt role" "t-k8sgpt-mcp" "$(doc "$out" ClusterRoleBinding t-k8sgpt-mcp .roleRef.name)"
check "the binding names the k8sgpt ServiceAccount" "t-k8sgpt-mcp" "$(doc "$out" ClusterRoleBinding t-k8sgpt-mcp .subjects[0].name)"
check "the binding names the release namespace" "default" "$(doc "$out" ClusterRoleBinding t-k8sgpt-mcp .subjects[0].namespace)"
check "k8sgpt is not bound to the view role" "0" \
  "$(yq -N 'select(.kind == "ClusterRoleBinding" and .roleRef.name == "view") | .subjects[].name' <<<"$out" | grep -c k8sgpt || true)"

# Read-only, and the objects the analyzers inspect.
check "k8sgpt can only read" "get,list,watch" "$(verbs "$out")"
for resource in pods nodes services endpoints namespaces ingresses ingressclasses persistentvolumeclaims \
  deployments statefulsets replicasets cronjobs events pods/log horizontalpodautoscalers poddisruptionbudgets \
  networkpolicies mutatingwebhookconfigurations validatingwebhookconfigurations gatewayclasses gateways httproutes \
  jobs configmaps persistentvolumes storageclasses serviceaccounts roles rolebindings; do
  check "k8sgpt reads $resource" 1 "$(rules_for "$out" "$resource")"
done

# No Secrets by default, no exec, no write.
# The exact API groups: any new group (OLM's operators.coreos.com included) fails here until
# its analyzer is enabled and the role is reviewed.
check "k8sgpt names exactly the reviewed API groups" \
  "(core),admissionregistration.k8s.io,apps,autoscaling,batch,gateway.networking.k8s.io,networking.k8s.io,policy,rbac.authorization.k8s.io,storage.k8s.io" \
  "$(doc "$out" ClusterRole t-k8sgpt-mcp '.rules[].apiGroups[] | select(. == "") = "(core)"' | sort -u | paste -sd, -)"
check "default values: k8sgpt reads no Secrets" 0 "$(rules_for "$out" secrets)"
check "default values: k8sgpt has no exec rule" 0 "$(rules_for "$out" pods/exec)"
out_all="$(render "${all_on[@]}")"
check "writeAccess on: k8sgpt still only reads" "get,list,watch" "$(verbs "$out_all")"
check "writeAccess on: k8sgpt still has no exec rule" 0 "$(rules_for "$out_all" pods/exec)"
check "secretRead on: k8sgpt gets Secrets (get only)" "get" \
  "$(doc "$out_all" ClusterRole t-k8sgpt-mcp '.rules[] | select(.resources[] == "secrets") | .verbs | join(",")')"

# Switching k8sgpt off removes all three objects and leaves the Kubernetes servers alone.
off="$(render --set mcpServers.k8sgpt.enabled=false)"
check "k8sgpt off: no k8sgpt ServiceAccount" "" "$(doc "$off" ServiceAccount t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: no k8sgpt ClusterRole" "" "$(doc "$off" ClusterRole t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: no k8sgpt ClusterRoleBinding" "" "$(doc "$off" ClusterRoleBinding t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: the Kubernetes ServiceAccount stays" "t-kubernetes-mcp" "$(doc "$off" ServiceAccount t-kubernetes-mcp .metadata.name)"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
