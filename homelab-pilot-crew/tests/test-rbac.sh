#!/usr/bin/env bash
# Render tests for the pilot crew's ServiceAccounts and RBAC. The chart ships the Kubernetes MCP
# servers' ServiceAccount and k8sgpt's own, their roles, and the bindings: a RoleBinding in each
# namespace listed in kubernetesAccess, or one ClusterRoleBinding with clusterWide, a Secret tier
# and a write tier per namespace, and a small read-only ClusterRole of the cluster-scoped kinds
# that stays cluster-wide. Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-rbac.sh   (exit 0 = all passed)
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=SCRIPTDIR/lib.sh
. "$chart/tests/lib.sh"

out="$(render)"
doc() { yq -N "select(.kind == \"$2\" and .metadata.name == \"$3\") | $4" <<<"$1"; }
sa_of() { doc "$1" MCPServer "$2" .spec.serviceAccountName; }
# The resources a ClusterRole names, one per line, sorted; its verbs, sorted and joined.
res_of() { doc "$1" ClusterRole "$2" '.rules[].resources[]' | sort | paste -sd, -; }
verbs_of() { doc "$1" ClusterRole "$2" '.rules[].verbs[]' | sort -u | paste -sd, -; }
groups_of() { doc "$1" ClusterRole "$2" '.rules[].apiGroups[] | select(. == "") = "(core)"' | sort -u | paste -sd, -; }
# The bindings that name a role, as "Kind namespace" lines, sorted and joined by commas.
bound() { yq -N "select((.kind == \"RoleBinding\" or .kind == \"ClusterRoleBinding\") and .roleRef.name == \"$2\") | .kind + \" \" + (.metadata.namespace // \"-\")" <<<"$1" | sort | paste -sd, -; }
# The ServiceAccounts a role's bindings name, as "namespace/name", sorted and unique.
subjects() { yq -N "select((.kind == \"RoleBinding\" or .kind == \"ClusterRoleBinding\") and .roleRef.name == \"$2\") | .subjects[] | .namespace + \"/\" + .name" <<<"$1" | sort -u | paste -sd, -; }
count() { grep -c . || true; }

# Each server keeps its own ServiceAccount; k8sgpt does not share the Kubernetes servers' one.
check "k8sgpt runs as its own ServiceAccount" "t-k8sgpt-mcp" "$(sa_of "$out" k8sgpt-mcp)"
check "the ServiceAccount k8sgpt names is rendered" "t-k8sgpt-mcp" "$(doc "$out" ServiceAccount t-k8sgpt-mcp .metadata.name)"
check "the Kubernetes MCP server keeps the shared ServiceAccount" "t-kubernetes-mcp" "$(sa_of "$out" t-kubernetes-mcp)"
check "k8sgpt does not share the Kubernetes servers' ServiceAccount" "no" \
  "$([ "$(sa_of "$out" k8sgpt-mcp)" = "$(sa_of "$out" t-kubernetes-mcp)" ] && echo yes || echo no)"

# Defaults: nothing listed and clusterWide false. Each account is bound to its small
# cluster-scoped role and to nothing namespaced, so the tool servers read nothing in a namespace.
check "default values: the Kubernetes cluster-scoped role is bound cluster-wide" "ClusterRoleBinding -" "$(bound "$out" t-kubernetes-mcp)"
check "default values: the k8sgpt cluster-scoped role is bound cluster-wide" "ClusterRoleBinding -" "$(bound "$out" t-k8sgpt-mcp)"
check "default values: the Kubernetes servers have no read binding" "" "$(bound "$out" t-kubernetes-mcp-read)"
check "default values: k8sgpt has no read binding" "" "$(bound "$out" t-k8sgpt-mcp-read)"
check "default values: no RoleBinding is rendered" "0" "$(yq -N 'select(.kind == "RoleBinding") | .metadata.name' <<<"$out" | count)"
check "default values: this chart renders exactly two ClusterRoleBindings" "2" "$(yq -N 'select(.kind == "ClusterRoleBinding") | .metadata.name' <<<"$out" | count)"
check "default values: no Secret or write role is rendered" "0" \
  "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$out" | grep -c -e -secrets -e -secret-get -e -write || true)"
check "no binding reaches the view role" "0" "$(yq -N 'select(.kind == "ClusterRoleBinding" and .roleRef.name == "view") | .metadata.name' <<<"$out" | count)"
notes="$(helm install t "$chart" --dry-run=client --set ragSources.enabled=false --set vectorStore.host=db.test 2>&1 | sed -n '/^NOTES:/,$p')"
check "default values: the install notes say the servers read no namespace" yes "$(has "$notes" "binds no")"
notes_wide="$(helm install t "$chart" --dry-run=client --set ragSources.enabled=false --set vectorStore.host=db.test --set kubernetesAccess.clusterWide=true 2>&1 | sed -n '/^NOTES:/,$p')"
check "clusterWide: the install notes carry no warning" no "$(has "$notes_wide" "WARNING")"

# The Kubernetes servers' cluster-scoped kinds, each read by an agent (see the template header).
check "the Kubernetes role names only the reviewed cluster-scoped kinds" \
  "clusterrolebindings,clusterroles,customresourcedefinitions,namespaces,nodes,persistentvolumes,storageclasses" "$(res_of "$out" t-kubernetes-mcp)"
check "the Kubernetes role only reads" "get,list,watch" "$(verbs_of "$out" t-kubernetes-mcp)"
check "the Kubernetes role names only reviewed API groups" "(core),apiextensions.k8s.io,rbac.authorization.k8s.io,storage.k8s.io" "$(groups_of "$out" t-kubernetes-mcp)"

# Every kind the Kubernetes role keeps is one an agent is told to read: the prompt modules and
# agents name it, so a kind nobody reads cannot stay.
for kind in 'kind="Node"' 'kind="PersistentVolume"' 'kind="StorageClass"' 'kind="CustomResourceDefinition"' 'ClusterRoleBinding'; do
  check "an agent reads $kind" "yes" "$(has "$(cat "$chart"/templates/promptmodule-specialists.yaml "$chart"/templates/agent-k8s-*.yaml)" "$kind")"
done

# k8sgpt: the cluster-scoped kinds its analyzers read, read-only, and nothing namespaced.
check "the k8sgpt role names the reviewed cluster-scoped kinds" \
  "gatewayclasses,ingressclasses,mutatingwebhookconfigurations,namespaces,nodes,persistentvolumes,storageclasses,validatingwebhookconfigurations" \
  "$(res_of "$out" t-k8sgpt-mcp)"
check "k8sgpt can only read" "get,list,watch" "$(verbs_of "$out" t-k8sgpt-mcp)"
check "the k8sgpt role names the reviewed API groups" \
  "(core),admissionregistration.k8s.io,gateway.networking.k8s.io,networking.k8s.io,storage.k8s.io" "$(groups_of "$out" t-k8sgpt-mcp)"

# The namespaced read roles never name Secrets, a write verb or a cluster-scoped kind.
for who in kubernetes k8sgpt; do
  role="t-$who-mcp-read"
  check "the $who read role only reads" "get,list,watch" "$(verbs_of "$out" "$role")"
  check "the $who read role names no Secret, exec, namespace or node" "0" \
    "$(doc "$out" ClusterRole "$role" '.rules[].resources[]' | grep -c -x -e secrets -e pods/exec -e namespaces -e nodes -e persistentvolumes || true)"
done

# Namespaces listed: one RoleBinding per namespace, for both accounts, and no wide binding.
listed="$(render --set 'kubernetesAccess.namespaces={kube-system,apps}')"
check "namespaces listed: the Kubernetes read role is bound in each" "RoleBinding apps,RoleBinding kube-system" "$(bound "$listed" t-kubernetes-mcp-read)"
check "namespaces listed: the k8sgpt read role is bound in each" "RoleBinding apps,RoleBinding kube-system" "$(bound "$listed" t-k8sgpt-mcp-read)"
check "namespaces listed: the bindings name the release namespace's accounts" "default/t-kubernetes-mcp" "$(subjects "$listed" t-kubernetes-mcp-read)"
check "namespaces listed: the k8sgpt bindings name the k8sgpt account" "default/t-k8sgpt-mcp" "$(subjects "$listed" t-k8sgpt-mcp-read)"
check "namespaces listed: the only ClusterRoleBindings are the two cluster-scoped roles" "2" \
  "$(yq -N 'select(.kind == "ClusterRoleBinding") | .metadata.name' <<<"$listed" | count)"
check "namespaces listed: the RoleBinding names its ClusterRole" "ClusterRole t-kubernetes-mcp-read" \
  "$(yq -N 'select(.kind == "RoleBinding" and .metadata.namespace == "apps" and .metadata.name == "t-kubernetes-mcp-read") | .roleRef.kind + " " + .roleRef.name' <<<"$listed")"
check "namespaces listed: no Secret or write role is rendered" "0" \
  "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$listed" | grep -c -e -secrets -e -secret-get -e -write || true)"

# clusterWide: one ClusterRoleBinding for each read role, no RoleBinding, and namespaces ignored.
wide="$(render --set kubernetesAccess.clusterWide=true --set 'kubernetesAccess.namespaces={kube-system}')"
check "clusterWide: the Kubernetes read role has one ClusterRoleBinding" "ClusterRoleBinding -" "$(bound "$wide" t-kubernetes-mcp-read)"
check "clusterWide: the k8sgpt read role has one ClusterRoleBinding" "ClusterRoleBinding -" "$(bound "$wide" t-k8sgpt-mcp-read)"
check "clusterWide: no RoleBinding is rendered" "0" "$(yq -N 'select(.kind == "RoleBinding") | .metadata.name' <<<"$wide" | count)"
check "clusterWide: no Secret or write role is rendered" "0" \
  "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$wide" | grep -c -e -secrets -e -secret-get -e -write || true)"

# Secret tier: per namespace only. The Kubernetes servers list Secrets there; k8sgpt gets one.
secrets="$(render --set 'kubernetesAccess.namespaces={kube-system,apps}' --set 'kubernetesAccess.secretRead.namespaces={kube-system}')"
check "secretRead: the Secret role is bound only in the listed namespace" "RoleBinding kube-system" "$(bound "$secrets" t-kubernetes-mcp-secrets)"
check "secretRead: the Secret role names Secrets with get, list, watch" "secrets get,list,watch" \
  "$(doc "$secrets" ClusterRole t-kubernetes-mcp-secrets '.rules[0].resources[0] + " " + (.rules[0].verbs | join(","))')"
check "secretRead: the Secret role has one rule" "1" "$(doc "$secrets" ClusterRole t-kubernetes-mcp-secrets '.rules | length')"
check "secretRead: k8sgpt gets one Secret, in the listed namespace only" "RoleBinding kube-system" "$(bound "$secrets" t-k8sgpt-mcp-secret-get)"
check "secretRead: the k8sgpt Secret role is get only" "secrets get" \
  "$(doc "$secrets" ClusterRole t-k8sgpt-mcp-secret-get '.rules[0].resources[0] + " " + (.rules[0].verbs | join(","))')"
check "secretRead: the read bindings stay as listed" "RoleBinding apps,RoleBinding kube-system" "$(bound "$secrets" t-kubernetes-mcp-read)"
check "secretRead: no write role is rendered" "0" "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$secrets" | grep -c -e -write || true)"
check "secretRead: the read roles still name no Secret" "0" \
  "$(for r in t-kubernetes-mcp t-kubernetes-mcp-read t-k8sgpt-mcp t-k8sgpt-mcp-read; do doc "$secrets" ClusterRole "$r" '.rules[].resources[]'; done | grep -c -x secrets || true)"
secrets_wide="$(render --set kubernetesAccess.clusterWide=true --set 'kubernetesAccess.secretRead.namespaces={kube-system}')"
check "secretRead with clusterWide: Secrets stay in the listed namespace" "RoleBinding kube-system" "$(bound "$secrets_wide" t-kubernetes-mcp-secrets)"

# Write tier: per namespace, the Kubernetes servers only, and the servers leave read-only mode.
write="$(render --set 'kubernetesAccess.namespaces={apps}' --set 'kubernetesAccess.write.namespaces={apps}')"
check "write: the write role is bound only in the listed namespace" "RoleBinding apps" "$(bound "$write" t-kubernetes-mcp-write)"
check "write: the write role names exec, patch and scale on workloads only" \
  "daemonsets,deployments,deployments/rollout,deployments/scale,pods/exec,replicasets,replicasets/scale,statefulsets,statefulsets/scale" \
  "$(res_of "$write" t-kubernetes-mcp-write)"
check "write: the write role holds no read-wide verb" "create,get,patch,update" "$(verbs_of "$write" t-kubernetes-mcp-write)"
check "write: k8sgpt gets no write binding" "0" "$(yq -N 'select(.kind == "RoleBinding" and (.roleRef.name | test("k8sgpt.*write")))' <<<"$write" | count)"
check "write: the config leaves read-only mode" 1 \
  "$(yq -N 'select(.kind == "Secret" and .metadata.name == "t-kubernetes-mcp-config") | .stringData["config.toml"]' <<<"$write" | grep -cxF 'read_only = false' || true)"
check "write: no Secret role is rendered" "0" "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$write" | grep -c -e -secrets -e -secret-get || true)"
check "write off: no write role is rendered" "0" "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$out" | grep -c -e -write || true)"
check "write off: the config stays read-only" 1 \
  "$(yq -N 'select(.kind == "Secret" and .metadata.name == "t-kubernetes-mcp-config") | .stringData["config.toml"]' <<<"$out" | grep -cxF 'read_only = true' || true)"

# Both tiers together bind the roles where listed and nowhere else.
all="$(render "${all_on[@]}")"
check "both tiers: the Secret role is bound in kube-system only" "RoleBinding kube-system" "$(bound "$all" t-kubernetes-mcp-secrets)"
check "both tiers: the write role is bound in apps only" "RoleBinding apps" "$(bound "$all" t-kubernetes-mcp-write)"
check "both tiers: no read binding appears without a listed namespace" "" "$(bound "$all" t-kubernetes-mcp-read)"

# The annotations crews #62 added to ask the operator for access are gone.
check "no MCPServer carries a kubemoot.ai/kubernetes-access annotation" "0" \
  "$(yq -N 'select(.kind == "MCPServer") | .metadata.annotations["kubemoot.ai/kubernetes-access"] // ""' <<<"$all" | count)"
check "nothing names a namespace consent label" "0" \
  "$(grep -c -e 'kubemoot.ai/crew-read' -e 'kubemoot.ai/crew-write' <<<"$all" || true)"

# The old boolean shape: false, the old default, is off and renders; true fails with the new
# shape named, because it cannot say which namespaces get the access.
old_false="$(render --set kubernetesAccess.secretRead=false --set kubernetesAccess.writeAccess=false)"
check "a boolean false secretRead and a stale writeAccess render with the tiers off" "0" \
  "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$old_false" | grep -c -e -secrets -e -secret-get -e -write || true)"
err="$(render --set kubernetesAccess.secretRead=true 2>&1 >/dev/null || true)"
check "a boolean true secretRead fails the render and names the new shape" yes "$(has "$err" "kubernetesAccess.secretRead.namespaces")"
err="$(render --set kubernetesAccess.write=true 2>&1 >/dev/null || true)"
check "a boolean true write fails the render and names the new shape" yes "$(has "$err" "kubernetesAccess.write.namespaces")"

# Malformed namespaces fail the render, and never become a cluster-wide binding. An empty entry
# or a string would otherwise widen a Secret or write grant.
values_file="$(mktemp)"
trap 'rm -f "$values_file"' EXIT
for tier in namespaces secretRead.namespaces write.namespaces; do
  case "$tier" in
    namespaces) path="kubernetesAccess:\n  namespaces: [\"\"]\n" ;;
    secretRead.namespaces) path="kubernetesAccess:\n  secretRead:\n    namespaces: [\"\"]\n" ;;
    *) path="kubernetesAccess:\n  write:\n    namespaces: [\"\"]\n" ;;
  esac
  printf '%b' "$path" >"$values_file"
  err="$(render -f "$values_file" 2>&1 >/dev/null || true)"
  check "an empty entry in kubernetesAccess.$tier fails the render" yes "$(has "$err" "non-empty namespace names")"
  err="$(render --set "kubernetesAccess.$tier=a\\,b" 2>&1 >/dev/null || true)"
  check "a string in kubernetesAccess.$tier fails the render" yes "$(has "$err" "must be a list of namespaces")"
done
dup="$(render --set 'kubernetesAccess.namespaces={apps,apps}')"
check "a namespace listed twice renders one RoleBinding" "RoleBinding apps" "$(bound "$dup" t-kubernetes-mcp-read)"
nulled="$(render --set kubernetesAccess.secretRead=null --set kubernetesAccess.write=null)"
check "a tier set to null is off" "0" "$(yq -N 'select(.kind == "ClusterRole") | .metadata.name' <<<"$nulled" | grep -c -e -secrets -e -secret-get -e -write || true)"

# k8sgpt reads a subset of what the Kubernetes servers read, so a kind added to one list only
# cannot widen k8sgpt unnoticed.
only_k8sgpt="$(comm -13 <(doc "$out" ClusterRole t-kubernetes-mcp-read '.rules[].resources[]' | sort -u) \
  <(doc "$out" ClusterRole t-k8sgpt-mcp-read '.rules[].resources[]' | sort -u) | paste -sd, -)"
check "k8sgpt's read role names nothing the Kubernetes read role does not" "" "$only_k8sgpt"

# The install notes flag a Secret or write namespace that is not also readable.
notes_gap="$(helm install t "$chart" --dry-run=client --set ragSources.enabled=false --set vectorStore.host=db.test \
  --set 'kubernetesAccess.namespaces={apps}' --set 'kubernetesAccess.write.namespaces={other}' 2>&1 | sed -n '/^NOTES:/,$p')"
check "a write namespace outside namespaces is flagged in the notes" yes "$(has "$notes_gap" "lists other")"
check "a covered write namespace is not flagged" no "$(has "$(helm install t "$chart" --dry-run=client --set ragSources.enabled=false --set vectorStore.host=db.test --set 'kubernetesAccess.namespaces={apps}' --set 'kubernetesAccess.write.namespaces={apps}' 2>&1 | sed -n '/^NOTES:/,$p')" "NOTE:")"

# Switching k8sgpt off removes its objects at every tier and leaves the Kubernetes servers alone.
off="$(render --set mcpServers.k8sgpt.enabled=false "${all_on[@]}" --set 'kubernetesAccess.namespaces={apps}')"
check "k8sgpt off: no k8sgpt ServiceAccount" "" "$(doc "$off" ServiceAccount t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: no k8sgpt ClusterRole" "" "$(doc "$off" ClusterRole t-k8sgpt-mcp .metadata.name)"
check "k8sgpt off: no k8sgpt binding of any kind" "0" "$(yq -N 'select(.kind == "RoleBinding" or .kind == "ClusterRoleBinding") | .metadata.name' <<<"$off" | grep -c k8sgpt || true)"
check "k8sgpt off: the Kubernetes ServiceAccount stays" "t-kubernetes-mcp" "$(doc "$off" ServiceAccount t-kubernetes-mcp .metadata.name)"
check "k8sgpt off: the Kubernetes read binding stays" "RoleBinding apps" "$(bound "$off" t-kubernetes-mcp-read)"

[ "$failures" -eq 0 ] || { echo "$failures failed"; exit 1; }
echo "all passed"
