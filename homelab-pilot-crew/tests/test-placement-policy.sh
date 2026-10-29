#!/usr/bin/env bash
# Render tests for the crew's CrewSchedulingPolicy: the placement policy value, the
# per-phase model selection rules, that the chart ships no Model of its own (the
# cluster's model catalog supplies them), and that the EmbeddingModel and the gateway
# tool index name no server, and that the documentation advisors bind the RAG sources the
# chart declares for them (and nothing binds when RAG is off). Needs helm and yq.
# Run from anywhere: homelab-pilot-crew/tests/test-placement-policy.sh
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
render() {
  helm template t "$chart" --set ragSources.enabled=false --set vectorStore.host=db.test "$@"
}
policy() {
  render "$@" | yq -N 'select(.kind == "CrewSchedulingPolicy") | .spec.placementPolicy'
}
# rule PHASE EXPR: evaluates yq EXPR against the rule for PHASE.
rule() {
  render | yq -N -o=json "select(.kind == \"CrewSchedulingPolicy\") | .spec.rules[] | select(.phase == \"$1\") | $2"
}

# Placement policy.
[ "$(policy)" = "null" ] || fail "an empty value should leave placementPolicy unset, so the crew inherits the default"
for mode in algorithm learned shadow; do
  [ "$(policy --set "crew.placementPolicy=$mode")" = "$mode" ] || fail "placementPolicy $mode not rendered"
done
echo "PASS: placement policy render tests"

# The chart ships no Model, so the crew selects from the cluster's catalog.
out="$(render)"
models="$(yq -N 'select(.kind == "Model") | .metadata.name' <<<"$out")"
[ -z "$models" ] || fail "the chart renders Model objects: $models"
# A stale models value from an older install must not bring one back.
legacy="$(render --set 'models[0].name=x' --set 'models[0].model=x' --set 'models[0].providerRef=p' | yq -N 'select(.kind == "Model") | .metadata.name')"
[ -z "$legacy" ] || fail "a models value still renders a Model: $legacy"
! grep -q 'latencyClass' <<<"$out" || fail "latencyClass appears in the rendered chart"
[ "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .metadata.name' <<<"$out" | grep -c .)" = "1" ] || fail "expected exactly one CrewSchedulingPolicy"
echo "PASS: no Model and no latencyClass rendered"

# Mulling: tool-calling is a hard need; size follows qualityBias, so no prefer and no speed term.
[ "$(rule mulling '.require.matchLabels["capability/tool-calling"]')" = '"true"' ] || fail "mulling must require capability/tool-calling"
[ "$(rule mulling '.require.matchLabels | length')" = "1" ] || fail "mulling must require only capability/tool-calling"
[ "$(rule mulling '.prefer')" = "null" ] || fail "mulling must have no prefer block, so qualityBias applies"
[ "$(rule mulling '.preferFaster')" = "null" ] || fail "mulling must not set preferFaster"
bias="$(render | yq -N -o=json -I=0 'select(.kind == "CrewSchedulingPolicy") | .spec.qualityBias')"
[ "$bias" = '{"reasoning":"0.7","tool-calling":"0.5","observability":"0.4","kubernetes":"0.4","default":"0.4"}' ] || fail "qualityBias changed: $bias"
echo "PASS: mulling rule"

# Triage: tool-calling is a hard need, speed is the wish, and size plays no part.
[ "$(rule triage '.require.matchLabels["capability/tool-calling"]')" = '"true"' ] || fail "triage must require capability/tool-calling"
[ "$(rule triage '.require.matchLabels | length')" = "1" ] || fail "triage must require only capability/tool-calling"
[ "$(rule triage '.preferFaster')" = "50" ] || fail "triage must set preferFaster 50"
# preferFaster alone makes the rule an explicit preference: no prefer list is needed.
[ "$(rule triage '.prefer')" = "null" ] || fail "triage must have no prefer list"
[ "$(rule triage 'keys | sort | join(",")')" = '"phase,preferFaster,require"' ] || fail "triage must hold only phase, require, and preferFaster"
triage="$(rule triage '.')"
! grep -q 'kubemoot.ai/size' <<<"$triage" || fail "triage must not select on size"
echo "PASS: triage rule"

# The EmbeddingModel names its model and dimensions and no server: the cluster's catalog
# supplies one. Nothing in the chart names a ModelServer or a ModelProvider.
emb="$(yq -N -o=json -I=0 'select(.kind == "EmbeddingModel") | .spec' <<<"$out")"
[ "$emb" = '{"model":"nomic-embed-text","dimensions":768}' ] || fail "EmbeddingModel spec changed: $emb"
# A crew that wants its embeddings on one server pins it, as a crew-local Model does.
[ "$(render --set embeddingModel.serverRef=gpu-vllm | yq -N 'select(.kind == "EmbeddingModel") | .spec.serverRef')" = "gpu-vllm" ] || fail "embeddingModel.serverRef not rendered"
[ "$(render --set embeddingModel.dimensions=1024 | yq -N 'select(.kind == "EmbeddingModel") | .spec.dimensions')" = "1024" ] || fail "embeddingModel.dimensions not rendered"
err="$(render --set embeddingModel.providerRef=ollama-local 2>&1 >/dev/null || true)"
grep -q 'embeddingModel.providerRef is gone' <<<"$err" || fail "a stale embeddingModel.providerRef must fail the render: $err"
! grep -qiE 'modelprovider|providerRef' <<<"$out" || fail "the rendered chart still names a ModelProvider or providerRef"
grep -q '"modelservers"' <<<"$out" || fail "the Kubernetes MCP servers must be able to read ModelServers"
echo "PASS: embedding model names no server"

# The gateway tool index names the model and no endpoint; it reads the server from the
# EmbeddingModel the operator bound. An endpoint set in values still renders.
gw() { yq -N -o=json -I=0 'select(.kind == "MCPGateway") | .spec.toolIndex.embeddingModel' <<<"$1"; }
gwout="$(render --set mcpGateway.toolIndex.vectorStore.host=db.test --set mcpGateway.toolIndex.vectorStore.database=v --set mcpGateway.toolIndex.vectorStore.secretRef=s)"
[ "$(gw "$gwout")" = '{"provider":"ollama","model":"nomic-embed-text"}' ] || fail "the gateway tool index embedding model changed: $(gw "$gwout")"
# The tool index names the chart's EmbeddingModel resource explicitly, not the model name.
ref() { yq -N 'select(.kind == "MCPGateway") | .spec.toolIndex.embeddingModelRef' <<<"$1"; }
embname="$(yq -N 'select(.kind == "EmbeddingModel") | .metadata.name' <<<"$gwout")"
[ "$(ref "$gwout")" = "$embname" ] || fail "the tool index embeddingModelRef is $(ref "$gwout"), want the chart's EmbeddingModel $embname"
[ "$embname" != "nomic-embed-text" ] || fail "this test needs the EmbeddingModel resource name to differ from the model name"
[ "$(ref "$(render --set embeddingModel.name=custom-embed --set mcpGateway.toolIndex.vectorStore.host=db.test --set mcpGateway.toolIndex.vectorStore.database=v --set mcpGateway.toolIndex.vectorStore.secretRef=s)")" = "custom-embed" ] || fail "a renamed EmbeddingModel must be followed by the tool index"
[ "$(ref "$(render --set mcpGateway.toolIndex.embeddingModelRef=pinned-embed --set mcpGateway.toolIndex.vectorStore.host=db.test --set mcpGateway.toolIndex.vectorStore.database=v --set mcpGateway.toolIndex.vectorStore.secretRef=s)")" = "pinned-embed" ] || fail "mcpGateway.toolIndex.embeddingModelRef must override"
gwset="$(render --set mcpGateway.toolIndex.vectorStore.host=db.test --set mcpGateway.toolIndex.vectorStore.database=v --set mcpGateway.toolIndex.vectorStore.secretRef=s --set mcpGateway.toolIndex.embeddingModel.endpoint=http://e:11434)"
[ "$(yq -N 'select(.kind == "MCPGateway") | .spec.toolIndex.embeddingModel.endpoint' <<<"$gwset")" = "http://e:11434" ] || fail "an explicit tool index endpoint must still render"
! grep -q 'http://ollama' <<<"$out$gwout" || fail "the chart defaults still name an Ollama server"
# An empty pin or endpoint renders nothing, so the cluster supplies the server.
[ "$(render --set embeddingModel.serverRef= | yq -N 'select(.kind == "EmbeddingModel") | .spec | has("serverRef")')" = "false" ] || fail "an empty embeddingModel.serverRef must leave serverRef out"
empty="$(render --set mcpGateway.toolIndex.vectorStore.host=db.test --set mcpGateway.toolIndex.vectorStore.database=v --set mcpGateway.toolIndex.vectorStore.secretRef=s --set mcpGateway.toolIndex.embeddingModel.endpoint=)"
[ "$(yq -N 'select(.kind == "MCPGateway") | .spec.toolIndex.embeddingModel | has("endpoint")' <<<"$empty")" = "false" ] || fail "an empty tool index endpoint must be left out"
echo "PASS: gateway tool index names no server"

# network.allowedIngress renders spec.network only when set, so a Crew still applies to a
# Kubemoot whose CRD has no network field.
crew_spec() { render "$@" | yq -N -o=json -I=0 'select(.kind == "Crew") | .spec'; }
[ "$(crew_spec | yq -p=json 'has("network")')" = "false" ] || fail "the default must render no network key"
[ "$(crew_spec --set-json 'network.allowedIngress=[]' | yq -p=json 'has("network")')" = "false" ] || fail "an empty allowedIngress must render no network key"
one="$(crew_spec --set 'network.allowedIngress[0].matchLabels.kubernetes\.io/metadata\.name=homelab-pilot' | yq -p=json -o=json -I=0 '.network')"
[ "$one" = '{"allowedIngress":[{"matchLabels":{"kubernetes.io/metadata.name":"homelab-pilot"}}]}' ] || fail "one selector did not render exactly: $one"
two="$(crew_spec -f - <<'VALUES' | yq -p=json -o=json -I=0 '.network'
network:
  allowedIngress:
    - matchLabels:
        kubernetes.io/metadata.name: homelab-pilot
    - matchExpressions:
        - key: team
          operator: In
          values: [web, edge]
VALUES
)"
[ "$two" = '{"allowedIngress":[{"matchLabels":{"kubernetes.io/metadata.name":"homelab-pilot"}},{"matchExpressions":[{"key":"team","operator":"In","values":["web","edge"]}]}]}' ] \
  || fail "two selectors did not render exactly: $two"
echo "PASS: network.allowedIngress"

# egress.mcpServers.<name> and egress.agents.<name> copy a map verbatim into that resource's
# spec.egress. Nothing renders by default, so a Kubemoot without egress policies still
# applies the chart, and a field the operator adds later needs no chart change.
egress_extra=(--set mcpServers.proxmox.enabled=true --set mcpServers.proxmox.image=x --set mcpServers.codeSandbox.enabled=true --set mcpServers.scheduling.enabled=true)
egress_render() { render "${egress_extra[@]}" "$@"; }
# egress_holders RENDERED: Kind/name of every MCPServer and Agent that has spec.egress.
egress_holders() {
  yq -N 'select(.kind == "MCPServer" or .kind == "Agent") | select(.spec | has("egress")) | .kind + "/" + .metadata.name' <<<"$1" | paste -sd, -
}
egress_out="$(egress_render)"
[ -z "$(egress_holders "$egress_out")" ] || fail "the default renders spec.egress: $(egress_holders "$egress_out")"
want_egress='{"allowedHosts":["api.example.com"],"ports":[443]}'
egress_count=0
for kind in MCPServer Agent; do
  key=mcpServers; other=agents
  if [ "$kind" = Agent ]; then key=agents; other=mcpServers; fi
  for name in $(yq -N "select(.kind == \"$kind\") | .metadata.name" <<<"$egress_out"); do
    # An entry renders on that resource only.
    got="$(egress_render --set-json "egress={\"$key\":{\"$name\":$want_egress}}")"
    [ "$(egress_holders "$got")" = "$kind/$name" ] || fail "egress.$key.$name must render on $kind/$name only, got: $(egress_holders "$got")"
    [ "$(yq -N -o=json -I=0 "select(.kind == \"$kind\" and .metadata.name == \"$name\") | .spec.egress" <<<"$got")" = "$want_egress" ] \
      || fail "egress for $name did not render verbatim"
    # The same name under the other kind renders nothing.
    got="$(egress_render --set-json "egress={\"$other\":{\"$name\":$want_egress}}")"
    [ -z "$(egress_holders "$got")" ] || fail "egress.$other.$name must not reach $kind/$name"
    egress_count=$((egress_count + 1))
  done
done
[ "$egress_count" -gt 0 ] || fail "no MCPServer or Agent found to test"
# An unknown name renders nothing, leaves the output unchanged, and does not fail.
got="$(egress_render --set-json 'egress={"mcpServers":{"no-such-server":{"allowedHosts":["x.example.com"]}},"agents":{"no-such-agent":{"apiServer":true}}}')"
[ "$got" = "$egress_out" ] || fail "an unknown name changed the output"
egress_render --set-json 'egress=null' >/dev/null || fail "egress=null does not render"
# A field the chart does not know copies through unchanged.
first="$(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$egress_out" | sed -n 1p)"
got="$(egress_render --set-json "egress={\"agents\":{\"$first\":{\"apiServer\":true,\"future\":{\"a\":[1,2]}}}}")"
[ "$(yq -N -o=json -I=0 "select(.kind == \"Agent\" and .metadata.name == \"$first\") | .spec.egress" <<<"$got")" = '{"apiServer":true,"future":{"a":[1,2]}}' ] \
  || fail "an unlisted egress field was not copied verbatim"
# egress.agentsDefault gives every Agent without its own egress.agents entry a spec.egress;
# a named entry replaces it entirely; MCP servers never take it.
agent_names="$(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$egress_out" | paste -sd, -)"
mcp_names="$(yq -N 'select(.kind == "MCPServer") | .metadata.name' <<<"$egress_out" | paste -sd, -)"
holders_of() { yq -N "select(.kind == \"$1\") | select(.spec | has(\"egress\")) | .metadata.name" <<<"$2" | paste -sd, -; }
got="$(egress_render --set-json 'egress={"agentsDefault":null}')"
[ "$got" = "$egress_out" ] || fail "a null agentsDefault changed the output"
got="$(egress_render --set-json 'egress={"agentsDefault":{}}')"
[ "$(holders_of Agent "$got")" = "$agent_names" ] || fail "agentsDefault {} must reach every Agent, got: $(holders_of Agent "$got")"
[ -z "$(holders_of MCPServer "$got")" ] || fail "agentsDefault reached an MCPServer: $(holders_of MCPServer "$got")"
[ "$(yq -N -o=json -I=0 'select(.kind == "Agent") | .spec.egress' <<<"$got" | sort -u)" = '{}' ] || fail "agentsDefault {} did not render an empty egress on every Agent"
got="$(egress_render --set-json "egress={\"agentsDefault\":$want_egress}")"
[ "$(holders_of Agent "$got")" = "$agent_names" ] || fail "a non-empty agentsDefault must reach every Agent"
[ "$(yq -N -o=json -I=0 'select(.kind == "Agent") | .spec.egress' <<<"$got" | sort -u)" = "$want_egress" ] || fail "a non-empty agentsDefault did not render verbatim"
[ -z "$(holders_of MCPServer "$got")" ] || fail "a non-empty agentsDefault reached an MCPServer"
named_override='{"apiServer":true}'
for name in ${agent_names//,/ }; do
  got="$(egress_render --set-json "egress={\"agentsDefault\":$want_egress,\"agents\":{\"$name\":$named_override}}")"
  [ "$(yq -N -o=json -I=0 "select(.kind == \"Agent\" and .metadata.name == \"$name\") | .spec.egress" <<<"$got")" = "$named_override" ] || fail "egress.agents.$name did not replace the default"
  others="$(yq -N -o=json -I=0 "select(.kind == \"Agent\" and .metadata.name != \"$name\") | .spec.egress" <<<"$got" | sort -u)"
  [ "$others" = "$want_egress" ] || fail "the override for $name leaked into other agents: $others"
  # an empty named entry is still a value that beats the default
  got="$(egress_render --set-json "egress={\"agentsDefault\":$want_egress,\"agents\":{\"$name\":{}}}")"
  [ "$(yq -N -o=json -I=0 "select(.kind == \"Agent\" and .metadata.name == \"$name\") | .spec.egress" <<<"$got")" = '{}' ] || fail "an empty egress.agents.$name did not beat the default"
done
echo "PASS: egress values (${egress_count} resources)"

# mcpServers.codeSandbox.runtimeClassName renders spec.runtimeClassName on the code-sandbox
# MCPServer only when set, so the MCPServer still applies to an operator whose CRD has no such field.
sandbox_spec() { render "$@" | yq -N -o=json -I=0 'select(.kind == "MCPServer" and .metadata.name == "code-sandbox-mcp") | .spec'; }
[ "$(sandbox_spec | yq -p=json 'has("runtimeClassName")')" = "false" ] || fail "the default must render no runtimeClassName"
[ "$(sandbox_spec --set mcpServers.codeSandbox.runtimeClassName= | yq -p=json 'has("runtimeClassName")')" = "false" ] || fail "an empty runtimeClassName must render nothing"
[ "$(sandbox_spec --set mcpServers.codeSandbox.runtimeClassName=gvisor | yq -p=json '.runtimeClassName')" = "gvisor" ] || fail "runtimeClassName not rendered on the code sandbox"
withrc="$(render --set mcpServers.codeSandbox.runtimeClassName=gvisor)"
[ "$(grep -c 'runtimeClassName' <<<"$withrc")" = "1" ] || fail "runtimeClassName must appear once, on the code sandbox only"
echo "PASS: mcpServers.codeSandbox.runtimeClassName"

# mcpServers.codeSandbox.transport: stdio (the default) renders the bridged setup with an
# explicit tini command; http renders the server's own listener, probes, and no command.
sbx() { render "$@" | yq -N 'select(.kind == "MCPServer" and .metadata.name == "code-sandbox-mcp")'; }
stdio_out="$(sbx)"
[ "$(yq '.spec.transport' <<<"$stdio_out")" = "stdio" ] || fail "the default code sandbox transport must be stdio"
[ "$(yq -o=json -I=0 '.spec.command' <<<"$stdio_out")" = '["/usr/bin/tini","-s","--","/usr/local/bin/code-sandbox"]' ] || fail "stdio must keep the explicit tini command"
[ "$(yq '.spec.env[] | select(.name == "MCP_TRANSPORT" or .name == "PORT") | .name' <<<"$stdio_out")" = "" ] || fail "stdio must set no MCP_TRANSPORT or PORT"
[ "$(yq '.spec | has("healthPath") or has("readinessPath")' <<<"$stdio_out")" = "false" ] || fail "stdio must render no health paths"
[ "$(sbx --set mcpServers.codeSandbox.transport=stdio)" = "$stdio_out" ] || fail "an explicit stdio must render the same as the default"
http_out="$(sbx --set mcpServers.codeSandbox.transport=http)"
[ "$(yq '.spec.transport' <<<"$http_out")" = "http" ] || fail "http transport not rendered"
[ "$(yq '.spec.port' <<<"$http_out")" = "3000" ] || fail "http must use port 3000"
[ "$(yq '.spec | has("command")' <<<"$http_out")" = "false" ] || fail "http must render no bridge command"
[ "$(yq '.spec.healthPath' <<<"$http_out")" = "/healthz" ] || fail "http healthPath"
[ "$(yq '.spec.readinessPath' <<<"$http_out")" = "/readyz" ] || fail "http readinessPath"
[ "$(yq '.spec.env[] | select(.name == "MCP_TRANSPORT") | .value' <<<"$http_out")" = "http" ] || fail "http must set MCP_TRANSPORT=http"
[ "$(yq '.spec.env[] | select(.name == "PORT") | .value' <<<"$http_out")" = "3000" ] || fail "http PORT must match the port"
[ "$(yq '.spec.env[] | select(.name == "EXECUTION_TIMEOUT") | .value' <<<"$http_out")" = "25" ] || fail "http must keep EXECUTION_TIMEOUT"
[ "$(yq '.spec.sidecars[0].name' <<<"$http_out")" = "artifact-access" ] || fail "http must keep the artifact-access sidecar"
[ "$(yq '.spec.emptyDirVolumes[0].mountPath' <<<"$http_out")" = "/artifacts" ] || fail "http must keep the /artifacts volume"
http_rc="$(sbx --set mcpServers.codeSandbox.transport=http --set mcpServers.codeSandbox.runtimeClassName=gvisor)"
[ "$(yq '.spec.runtimeClassName' <<<"$http_rc")" = "gvisor" ] || fail "http must keep runtimeClassName"
err="$(render --set mcpServers.codeSandbox.transport=grpc 2>&1 >/dev/null || true)"
grep -q 'mcpServers.codeSandbox.transport must be stdio or http, got "grpc"' <<<"$err" || fail "an unknown transport must fail the render with a clear message: $err"
echo "PASS: mcpServers.codeSandbox.transport"

# compute.workspaceQuery: off by default; on adds workspace_query to the compute agent only.
tools() { yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.enabledTools | join(\",\")"; }
wq_off="$(render)"
wq_on="$(render --set compute.workspaceQuery=true)"
! grep -q 'workspace_query' <<<"$wq_off" || fail "workspace_query rendered with the default"
[ "$(tools compute <<<"$wq_on")" = "execute_code,validate_code,artifact_head,artifact_tail,artifact_grep,artifact_count,artifact_rows,artifact_select,artifact_jq,workspace_query" ] || fail "compute.workspaceQuery=true must append workspace_query to compute"
[ "$(grep -c 'workspace_query' <<<"$wq_on")" = "1" ] || fail "workspace_query must appear only in the compute agent"
[ "$(diff <(echo "$wq_off") <(echo "$wq_on") | grep -c '^[<>]')" = "2" ] || fail "compute.workspaceQuery=true must change only the compute enabledTools line"
echo "PASS: compute.workspaceQuery"

# The compute prompt treats inputs stated in the question as data, and NO_DATA applies only
# when neither the question nor the discussion has any.
compute_prompt="$(render | yq -N 'select(.kind == "PromptModule" and .metadata.name == "compute-system") | .spec.content')"
[ -n "$compute_prompt" ] || fail "compute-system PromptModule did not render"
grep -q 'stated in the question' <<<"$compute_prompt" || fail "compute prompt must accept data stated in the question"
grep -q 'NEITHER the question NOR the discussion' <<<"$compute_prompt" || fail "NO_DATA must apply only when neither the question nor the discussion has data"
echo "PASS: compute prompt accepts inputs in the question"

# The read-ops server selects Kubemoot's built-in artifact-access image (the operator takes
# it from KubemootConfig and wires the query engine); the code sandbox sidecar keeps naming
# its image from mcpServers.artifactAccess.image.
ro_out="$(render | yq -N 'select(.kind == "MCPServer" and .metadata.name == "artifact-readops-mcp")')"
[ "$(yq '.spec.kubemootImage' <<<"$ro_out")" = "artifactAccess" ] || fail "read-ops must select kubemootImage artifactAccess"
[ "$(yq '.spec | has("image")' <<<"$ro_out")" = "false" ] || fail "read-ops must render no image beside kubemootImage"
[ "$(yq '.spec.transport' <<<"$ro_out")" = "stdio" ] || fail "read-ops must keep the stdio transport"
[ "$(yq '.spec.command[0]' <<<"$ro_out")" = "/cnb/process/web" ] || fail "read-ops must keep the Buildpacks launcher command"
[ "$(yq '.spec.env[] | select(.name == "ARTIFACT_MODE") | .value' <<<"$ro_out")" = "mcp" ] || fail "read-ops must keep ARTIFACT_MODE=mcp"
ro_override="$(render --set mcpServers.artifactAccess.image=reg.test/x/artifact-access:1.2.3)"
[ "$(yq -N 'select(.metadata.name == "artifact-readops-mcp") | .spec | has("image")' <<<"$ro_override")" = "false" ] || fail "the artifactAccess image value must not reach the read-ops server"
[ "$(yq -N 'select(.kind == "MCPServer" and .spec.sidecars) | .spec.sidecars[0].image' <<<"$ro_override")" = "reg.test/x/artifact-access:1.2.3" ] || fail "the code sandbox sidecar must use the artifactAccess image value"
[ "$(yq -N 'select(.kind == "MCPServer" and .spec.sidecars) | .spec.sidecars[0].image' <<<"$out")" = "ghcr.io/kubemoot/artifact-access:0.0.0" ] || fail "the code sandbox sidecar must keep the stamped default image"
echo "PASS: read-ops server selects kubemootImage artifactAccess"

# RAG bindings: an advisor's spec.ragSources lists the sources whose agents map names it, with
# the declared topK; no other agent binds a source; RAG off, or a source that lists no agent,
# binds nothing.
rag_out="$(render --set ragSources.enabled=true --set vectorStore.host=db.test --set vectorStore.existingSecret=s)"
refs() { yq -N -o=json -I0 "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.ragSources" <<<"$2"; }
[ "$(refs k8s-advisor "$rag_out")" = '[{"name":"kubectl-reference","topK":2},{"name":"helm-reference","topK":2},{"name":"talos-reference","topK":2},{"name":"kubernetes-concepts","topK":3}]' ] || fail "k8s-advisor must bind its four documentation sources"
[ "$(refs nvidia-gpu-advisor "$rag_out")" = '[{"name":"nvidia-gpu-reference","topK":3}]' ] || fail "nvidia-gpu-advisor must bind nvidia-gpu-reference"
[ "$(refs obs-advisor "$rag_out")" = '[{"name":"prometheus-reference","topK":3}]' ] || fail "obs-advisor must bind prometheus-reference"
[ "$(refs proxmox-advisor "$rag_out")" = '[{"name":"proxmox-api-reference","topK":2},{"name":"proxmox-pve-docs","topK":3}]' ] || fail "proxmox-advisor must bind the two Proxmox sources"
bound="$(yq -N 'select(.kind == "Agent" and .spec.ragSources) | .metadata.name' <<<"$rag_out" | sort | tr '\n' ' ')"
[ "$bound" = "k8s-advisor nvidia-gpu-advisor obs-advisor proxmox-advisor " ] || fail "only the four advisors may bind sources, got: $bound"
# Every bound name is a RAGSource the chart renders, so no agent queries an endpoint that does not exist.
rendered="$(yq -N 'select(.kind == "RAGSource") | .metadata.name' <<<"$rag_out" | sort -u)"
for n in $(yq -N 'select(.kind == "Agent") | .spec.ragSources[].name' <<<"$rag_out" | sort -u); do
  grep -qx "$n" <<<"$rendered" || fail "an agent binds $n, which the chart does not render as a RAGSource"
done
! grep -q 'kubernetes-mcp-tools' <<<"$(yq -N 'select(.kind == "Agent") | .spec.ragSources' <<<"$rag_out")" || fail "kubernetes-mcp-tools lists no agent and must not be bound"
off="$(render | yq -N 'select(.kind == "Agent" and .spec.ragSources) | .metadata.name')"
[ -z "$off" ] || fail "ragSources.enabled=false must bind nothing, got: $off"
# A source with no agents map binds nothing, and an agents entry sets topK and priority.
none="$(render --set ragSources.enabled=true --set vectorStore.host=db.test --set vectorStore.existingSecret=s --set 'ragSources.sources[0].name=solo' --set 'ragSources.sources[0].gitUrl=https://x.test/r' --set 'ragSources.sources[0].paths[0]=.' | yq -N 'select(.kind == "Agent" and .metadata.name == "obs-advisor") | .spec.ragSources[].name')"
[ "$none" != "solo" ] && ! grep -qx solo <<<"$none" || fail "a source with no agents map must bind no agent"
prio="$(render --set ragSources.enabled=true --set vectorStore.host=db.test --set vectorStore.existingSecret=s --set 'ragSources.sources[0].name=solo' --set 'ragSources.sources[0].gitUrl=https://x.test/r' --set 'ragSources.sources[0].paths[0]=.' --set 'ragSources.sources[0].agents.obs-advisor.priority=7' | yq -N -o=json -I0 'select(.kind == "Agent" and .metadata.name == "obs-advisor") | .spec.ragSources[0]')"
[ "$prio" = '{"name":"solo","priority":7}' ] || fail "an agents entry must carry its priority and leave topK to the CRD default, got: $prio"
echo "PASS: advisors bind their declared RAG sources"

# Every agents key in the default values names a rendered Agent, so a typo cannot leave an advisor unbound.
agents_rendered="$(yq -N 'select(.kind == "Agent") | .metadata.name' <<<"$rag_out" | sort -u)"
for a in $(yq '.ragSources.sources[].agents // {} | keys | .[]' "$chart/values.yaml" | sort -u); do
  grep -qx "$a" <<<"$agents_rendered" || fail "values.yaml binds a source to $a, which is not a rendered Agent"
done
# topK and priority: an explicit value is forwarded, bad values fail the render, null unbinds.
bind() { render --set ragSources.enabled=true --set vectorStore.host=db.test --set vectorStore.existingSecret=s --set 'ragSources.sources[0].name=solo' --set 'ragSources.sources[0].gitUrl=https://x.test/r' --set 'ragSources.sources[0].paths[0]=.' "$@"; }
[ "$(bind --set 'ragSources.sources[0].agents.obs-advisor.topK=8' | yq -N -o=json -I0 'select(.metadata.name == "obs-advisor") | .spec.ragSources[0]')" = '{"name":"solo","topK":8}' ] || fail "an explicit topK must be forwarded"
bind --set 'ragSources.sources[0].agents.obs-advisor.topK=0' >/dev/null 2>&1 && fail "topK 0 must fail the render"
bind --set 'ragSources.sources[0].agents.obs-advisor.topK=abc' >/dev/null 2>&1 && fail "a non-numeric topK must fail the render"
bind --set 'ragSources.sources[0].agents.obs-advisor.priority=high' >/dev/null 2>&1 && fail "a non-numeric priority must fail the render"
[ "$(bind --set-json 'ragSources.sources[0].agents={"obs-advisor":{}}' | yq -N -o=json -I0 'select(.metadata.name == "obs-advisor") | .spec.ragSources[-1]')" = '{"name":"solo"}' ] || fail "an empty agents entry must bind with defaults"
[ "$(bind --set 'ragSources.sources[0].agents.obs-advisor=null' | yq -N -o=json -I0 'select(.metadata.name == "obs-advisor") | .spec.ragSources')" = 'null' ] || fail "a null agents entry must unbind"
echo "PASS: RAG binding values are validated"
