#!/usr/bin/env bash
# Render tests for the fitness crew's model selection: the chart ships no Model and
# names no model server (the cluster's model catalog supplies the judge's model), and
# its CrewSchedulingPolicy requires reasoning, ranks by size through qualityBias, and
# reads nothing that changes between runs. Needs helm and yq.
# Run from anywhere: kubemoot-fitness-crew/tests/test-render.sh
set -euo pipefail
chart="$(cd "$(dirname "$0")/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }
render() {
  helm template t "$chart" "$@"
}
# csp EXPR [helm args...]: evaluates yq EXPR against the rendered CrewSchedulingPolicy.
csp() {
  local expr="$1"; shift
  render "$@" | yq -N -o=json -I=0 "select(.kind == \"CrewSchedulingPolicy\") | $expr"
}
# agent_env NAME VAR: the value of env VAR on Agent NAME.
agent_env() {
  yq -N "select(.kind == \"Agent\" and .metadata.name == \"$1\") | .spec.deployment.env[] | select(.name == \"$2\") | .value" <<<"$out"
}

out="$(render)"

# No Model, no model server, no retired label: the judge selects from the catalog.
models="$(yq -N 'select(.kind == "Model") | .metadata.name' <<<"$out")"
[ -z "$models" ] || fail "the chart renders Model objects: $models"
# A stale models value from an older install must not bring one back.
legacy="$(render --set 'models[0].name=x' --set 'models[0].model=x' --set 'models[0].serverRef=s' | yq -N 'select(.kind == "Model") | .metadata.name')"
[ -z "$legacy" ] || fail "a models value still renders a Model: $legacy"
! grep -q 'serverRef' <<<"$out" || fail "serverRef appears in the rendered chart"
! grep -qiE 'providerRef|modelprovider' <<<"$out" || fail "the rendered chart names a ModelProvider or providerRef"
! grep -q 'latencyClass' <<<"$out" || fail "latencyClass appears in the rendered chart"
! grep -q '^models:' "$chart/values.yaml" || fail "values.yaml still has models"
echo "PASS: no Model, serverRef, or latencyClass rendered"

# One policy; qualityBias 0.9 ranks large over medium over small.
[ "$(yq -N 'select(.kind == "CrewSchedulingPolicy") | .metadata.name' <<<"$out" | grep -c .)" = "1" ] || fail "expected exactly one CrewSchedulingPolicy"
[ "$(csp '.spec.crewRef')" = '"kubemoot-fitness"' ] || fail "crewRef changed"
bias="$(csp '.spec.qualityBias')"
[ "$bias" = '{"reasoning":"0.9","default":"0.9"}' ] || fail "qualityBias changed: $bias"
echo "PASS: qualityBias leans to the largest model"

# Every phase requires only reasoning and states no explicit preference, so the size
# score applies and nothing measured at run time (preferFaster) moves the pick.
phases="$(csp '.spec.rules[].phase' | tr -d '"' | paste -sd, -)"
[ "$phases" = "triage,mulling,synthesis" ] || fail "phases changed: $phases"
for phase in triage mulling synthesis; do
  rule="$(csp ".spec.rules[] | select(.phase == \"$phase\")")"
  [ "$(yq -N -o=json -I=0 '.require' <<<"$rule")" = '{"matchLabels":{"capability/reasoning":"true"}}' ] \
    || fail "$phase must require only capability/reasoning: $rule"
  [ "$(yq -N 'keys | sort | join(",")' <<<"$rule")" = "phase,require" ] \
    || fail "$phase must hold only phase and require (no prefer, preferFaster, or requireExpressions): $rule"
done
! grep -q 'kubemoot.ai/size' <<<"$out" || fail "no rule may require or prefer a size: a cluster without a large model must still run the judge"
echo "PASS: every phase requires reasoning, with no explicit preference"

# scheduling.requireLabels narrows every phase to the labeled catalog entry.
for phase in triage mulling synthesis; do
  got="$(csp ".spec.rules[] | select(.phase == \"$phase\") | .require.matchLabels" --set 'scheduling.requireLabels.kubemoot\.ai/fitness-judge=true')"
  [ "$got" = '{"capability/reasoning":"true","kubemoot.ai/fitness-judge":"true"}' ] || fail "$phase did not take requireLabels: $got"
done
# A value cannot drop the reasoning requirement.
got="$(csp '.spec.rules[0].require.matchLabels' --set-string 'scheduling.requireLabels.capability/reasoning=false')"
[ "$got" = '{"capability/reasoning":"true"}' ] || fail "requireLabels overrode capability/reasoning: $got"
# A non-string value renders as a string, as a label selector needs.
got="$(csp '.spec.rules[0].require.matchLabels.tier' --set 'scheduling.requireLabels.tier=1')"
[ "$got" = '"1"' ] || fail "a numeric requireLabels value must render as a string: $got"
echo "PASS: scheduling.requireLabels"

# Both agents keep to the bound model's score: no lower-scoring warm stand-in.
for agent in fitness-judge fitness-coordinator; do
  [ "$(agent_env "$agent" KUBEMOOT_MODEL_CANDIDATE_TOLERANCE)" = "0" ] || fail "$agent must set KUBEMOOT_MODEL_CANDIDATE_TOLERANCE to 0"
  [ "$(yq -N "select(.kind == \"Agent\" and .metadata.name == \"$agent\") | .spec.capabilities | join(\",\")" <<<"$out")" = "reasoning" ] \
    || fail "$agent must declare reasoning"
done
echo "PASS: both agents hold the candidate tolerance at 0"

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
egress_extra=()
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

helm lint "$chart" >/dev/null || fail "helm lint"
echo "PASS: helm lint"
