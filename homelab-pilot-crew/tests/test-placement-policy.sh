#!/usr/bin/env bash
# Render tests for the crew's CrewSchedulingPolicy: the placement policy value, the
# per-phase model selection rules, that the chart ships no Model of its own (the
# cluster's model catalog supplies them), and that the EmbeddingModel and the gateway
# tool index name no server. Needs helm and yq.
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
