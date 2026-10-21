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
